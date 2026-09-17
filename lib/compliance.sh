#!/bin/bash
#############################################
# Cipi — Compliance evidence
#
# Cipi is not certified and cannot be: ISO 27001 certifies an organisation's
# ISMS, SOC 2 attests a service organisation. What an organisation under
# audit needs from its deploy platform is *evidence* that the controls are
# in place. `cipi compliance report` collects it into one bundle:
#
#   <dir>/<host>-<timestamp>/
#       report.md          human-readable, for the auditor
#       report.json        same data, machine-readable
#       evidence/<control>/…  raw command output each finding is based on
#       SHA256SUMS
#   <dir>/<host>-<timestamp>.tar.gz (+ .sha256)
#
# Read-only: no check changes the server. Evidence never contains secrets
# (no token hashes, no password hashes, no key material, no vault content).
# Controls map to ISO/IEC 27001:2022 Annex A and SOC 2 (2017 TSC) criteria
# as a starting point for the auditor, not as a claim of conformity.
#############################################

[[ -z "${COMPLIANCE_DIR:-}" ]] && readonly COMPLIANCE_DIR="${CIPI_LOG}/compliance"

# id|title|ISO 27001:2022 Annex A|SOC 2 TSC — one per line, report order
_cmp_catalog() {
    cat <<'EOF'
ssh|SSH hardening|A.8.5, A.8.20|CC6.1, CC6.6
firewall|Host firewall|A.8.20, A.8.22|CC6.6
intrusion|Brute-force protection|A.8.16, A.8.20|CC6.6, CC7.2
patching|OS security patches|A.8.8, A.8.19|CC7.1
kernel|Kernel network hardening|A.8.9, A.8.20|CC6.6, CC7.1
tls|TLS configuration and certificates|A.8.24|CC6.1, CC6.7
accounts|Local accounts and privileges|A.5.15, A.5.18, A.8.2|CC6.2, CC6.3
ssh_keys|SSH authorized keys|A.5.17, A.8.5|CC6.1, CC6.2
api_tokens|Panel API tokens|A.5.17, A.5.18, A.8.5|CC6.1, CC6.2, CC6.3
gui_2fa|Panel multi-factor authentication|A.8.5|CC6.1
secrets|Configuration encryption at rest|A.8.24, A.5.33|CC6.1
deploys|Change log (deploys and rollbacks)|A.8.32|CC8.1
backups|Backups|A.8.13|A1.2, A1.3
logging|Logging and retention|A.8.15|CC7.2
monitoring|Monitoring and alerting|A.8.16|CC7.2, CC7.3
time|Clock synchronisation|A.8.17|CC7.2
malware|Malware scanning|A.8.7|CC6.8
EOF
}

# ── Result / evidence helpers ──────────────────────────────────
# Contract: each _cmp_check_<id> prints one JSON object on stdout:
#   {"status":"pass|warn|fail|info|na", "summary":"one line", "detail":"text"}
# writes raw evidence under $CMP_EV, and always exits 0 — a check that cannot
# run reports "warn", it never aborts the report (cipi runs under set -e).

_cmp_result() {
    local status="$1" summary="$2" detail="${3:-}"
    jq -n --arg s "$status" --arg m "$summary" --arg d "$detail" \
        '{status:$s, summary:$m, detail:$d}'
}

_cmp_ev() { printf '%s/%s' "${CMP_EV:-/dev/null}" "$1"; }

# Append a line to a newline-separated list held in the named variable.
_cmp_add() {
    local -n _ref="$1"
    _ref="${_ref}${_ref:+$'\n'}$2"
}

# Worst status wins: fail > warn > pass. info/na never downgrade a pass.
_cmp_worse() {
    local a="$1" b="$2"
    case "$a:$b" in
        fail:*|*:fail) echo fail ;;
        warn:*|*:warn) echo warn ;;
        *)             echo "$a" ;;
    esac
}

# Laravel SQLite database path from a panel's .env (API or GUI).
_cmp_sqlite_path() {
    local root="$1" envf raw
    envf="${root}/.env"
    [[ -f "$envf" ]] || return 1
    grep -q '^DB_CONNECTION=sqlite' "$envf" 2>/dev/null || return 1
    raw=$(grep '^DB_DATABASE=' "$envf" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '[:space:]"\r')
    [[ -z "$raw" || "$raw" == "null" ]] && raw="database/database.sqlite"
    if [[ "$raw" =~ ^/ ]]; then
        echo "$raw"
    else
        echo "${root}/${raw}"
    fi
}

# _cmp_sqlite_json <db> <sql> — rows as a JSON array. Runs as the file owner
# (www-data for the panels): root opening a WAL database would leave root-owned
# -shm/-wal files behind and break the panel's own writes.
_cmp_sqlite_json() {
    local db="$1" sql="$2" owner out
    [[ -f "$db" ]] || return 1
    owner=$(stat -c %U "$db" 2>/dev/null || echo root)
    local -a as=()
    [[ "$owner" != "root" ]] && command -v sudo >/dev/null 2>&1 && as=(sudo -u "$owner")
    if command -v sqlite3 >/dev/null 2>&1; then
        out=$("${as[@]}" sqlite3 -readonly -json "$db" "$sql" 2>/dev/null) && {
            [[ -z "$out" ]] && out="[]"
            jq -c . <<<"$out" 2>/dev/null && return 0
        }
    fi
    command -v php >/dev/null 2>&1 || return 1
    out=$("${as[@]}" php -r '
        $p = new PDO("sqlite:" . $argv[1], null, null, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
        echo json_encode($p->query($argv[2])->fetchAll(PDO::FETCH_ASSOC));
    ' -- "$db" "$sql" 2>/dev/null) || return 1
    jq -c . <<<"$out" 2>/dev/null
}

# Columns of <table> that exist, from a wanted list — panels of different ages
# have different schemas, and SELECT * would pull password / 2FA secrets.
_cmp_sqlite_columns() {
    local db="$1" table="$2"; shift 2
    local have want cols=""
    have=$(_cmp_sqlite_json "$db" "SELECT name FROM pragma_table_info('${table}')" | jq -r '.[].name' 2>/dev/null) || return 1
    for want in "$@"; do
        grep -qx "$want" <<<"$have" && cols="${cols}${cols:+, }${want}"
    done
    echo "$cols"
}

# ── Checks ─────────────────────────────────────────────────────

_cmp_check_ssh() {
    if ! command -v sshd >/dev/null 2>&1; then
        _cmp_result warn "sshd not found — cannot read the SSH configuration"
        return 0
    fi
    local eff
    if ! eff=$(sshd -T 2>/dev/null); then
        _cmp_result warn "sshd -T failed — effective SSH configuration unreadable"
        return 0
    fi
    sort <<<"$eff" > "$(_cmp_ev sshd-effective.txt)" 2>/dev/null || true
    cp /etc/ssh/sshd_config "$(_cmp_ev sshd_config)" 2>/dev/null || true

    local status=pass detail="" v
    _sshv() { awk -v k="$1" '$1 == k { $1=""; sub(/^ /, ""); print; exit }' <<<"$eff"; }

    v=$(_sshv permitrootlogin)
    case "$v" in
        no) ;;
        prohibit-password|without-password)
            status=$(_cmp_worse "$status" warn)
            _cmp_add detail "PermitRootLogin is '${v}' (key-only root login allowed; expected 'no')" ;;
        *)  status=fail; _cmp_add detail "PermitRootLogin is '${v:-?}' (expected 'no')" ;;
    esac
    [[ "$(_sshv passwordauthentication)" == "no" ]] \
        || { status=fail; _cmp_add detail "PasswordAuthentication is '$(_sshv passwordauthentication)' globally (expected 'no')"; }
    [[ "$(_sshv permitemptypasswords)" == "no" ]] \
        || { status=fail; _cmp_add detail "PermitEmptyPasswords is not 'no'"; }
    [[ "$(_sshv pubkeyauthentication)" == "yes" ]] \
        || { status=$(_cmp_worse "$status" warn); _cmp_add detail "PubkeyAuthentication is not 'yes'"; }
    [[ "$(_sshv x11forwarding)" == "no" ]] \
        || { status=$(_cmp_worse "$status" warn); _cmp_add detail "X11Forwarding is not 'no'"; }
    v=$(_sshv maxauthtries)
    [[ "$v" =~ ^[0-9]+$ && "$v" -le 4 ]] \
        || { status=$(_cmp_worse "$status" warn); _cmp_add detail "MaxAuthTries is '${v:-?}' (expected 4 or less)"; }

    # Cipi's documented exception: SFTP app users may log in with a password.
    if grep -qE '^[[:space:]]*Match[[:space:]]+Group[[:space:]]+cipi-apps' /etc/ssh/sshd_config 2>/dev/null; then
        _cmp_add detail "Note: password authentication is allowed for group cipi-apps (SFTP app users) by design; the cipi admin user is key-only."
    fi
    v=$(_sshv allowgroups)
    [[ -n "$v" ]] && _cmp_add detail "AllowGroups: ${v}"

    if [[ "$status" == "pass" ]]; then
        _cmp_result pass "root login off, key-only authentication, MaxAuthTries $(_sshv maxauthtries)" "$detail"
    else
        _cmp_result "$status" "SSH configuration deviates from the Cipi baseline" "$detail"
    fi
}

_cmp_check_firewall() {
    if ! command -v ufw >/dev/null 2>&1; then
        _cmp_result fail "ufw not installed — no host firewall"
        return 0
    fi
    local out
    out=$(ufw status verbose 2>/dev/null) || out=""
    printf '%s\n' "$out" > "$(_cmp_ev ufw-status.txt)" 2>/dev/null || true
    ufw show added > "$(_cmp_ev ufw-rules.txt)" 2>/dev/null || true
    if ! grep -q '^Status: active' <<<"$out"; then
        _cmp_result fail "ufw is not active"
        return 0
    fi
    local open
    open=$(awk '/ALLOW IN/ && $1 !~ /\(v6\)/ { print $1 }' <<<"$out" | sort -u | paste -sd' ' -)
    if ! grep -qE '^Default:.*deny \(incoming\)' <<<"$out"; then
        _cmp_result fail "ufw is active but the default incoming policy is not deny" "Allowed in: ${open:-none}"
        return 0
    fi
    _cmp_result pass "ufw active, default deny incoming, allowed in: ${open:-none}"
}

_cmp_check_intrusion() {
    local status=pass detail="" summary
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        local jails
        jails=$(fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list:[[:space:]]*//p' | tr -d ' ')
        { fail2ban-client status 2>/dev/null
          local j
          for j in ${jails//,/ }; do echo; fail2ban-client status "$j" 2>/dev/null; done
        } > "$(_cmp_ev fail2ban-status.txt)" 2>/dev/null || true
        cp /etc/fail2ban/jail.local "$(_cmp_ev jail.local)" 2>/dev/null || true
        if [[ ",${jails}," == *",sshd,"* ]]; then
            summary="fail2ban active, jails: ${jails//,/, }"
        else
            status=warn
            summary="fail2ban active but the sshd jail is not enabled"
        fi
    else
        status=fail
        summary="fail2ban is not running"
    fi
    if systemd_unit_exists crowdsec; then
        if systemctl is-active --quiet crowdsec 2>/dev/null; then
            _cmp_add detail "CrowdSec IP reputation: active"
            crowdsec-cli bouncers list > "$(_cmp_ev crowdsec-bouncers.txt)" 2>/dev/null || true
        else
            _cmp_add detail "CrowdSec is installed but not running"
            status=$(_cmp_worse "$status" warn)
        fi
    else
        _cmp_add detail "CrowdSec IP reputation: not enabled (optional — cipi crowdsec enable)"
    fi
    _cmp_result "$status" "$summary" "$detail"
}

_cmp_check_patching() {
    local status=pass detail="" uu_state periodic
    {
        lsb_release -ds 2>/dev/null
        echo "kernel $(uname -r)"
    } > "$(_cmp_ev os.txt)" 2>/dev/null || true

    uu_state=$(dpkg-query -W -f='${Status}' unattended-upgrades 2>/dev/null || true)
    periodic=$(apt-config dump 2>/dev/null | sed -n 's/^APT::Periodic::Unattended-Upgrade "\(.*\)";/\1/p' | tail -1)
    apt-config dump 2>/dev/null | grep -E '^(APT::Periodic|Unattended-Upgrade)' > "$(_cmp_ev unattended-upgrades-config.txt)" 2>/dev/null || true
    tail -n 200 /var/log/unattended-upgrades/unattended-upgrades.log > "$(_cmp_ev unattended-upgrades-log.txt)" 2>/dev/null || true

    if [[ "$uu_state" != "install ok installed" ]]; then
        status=fail; _cmp_add detail "unattended-upgrades is not installed"
    elif [[ "$periodic" != "1" ]]; then
        status=fail; _cmp_add detail "unattended-upgrades is installed but APT::Periodic::Unattended-Upgrade is '${periodic:-unset}'"
    else
        _cmp_add detail "unattended-upgrades enabled (security origins; nginx, databases, Valkey and PHP are upgraded by explicit cipi commands)"
    fi

    local last_run
    last_run=$(grep -h 'Starting unattended upgrades script' /var/log/unattended-upgrades/unattended-upgrades.log 2>/dev/null | tail -1 | cut -c1-19)
    [[ -n "$last_run" ]] && _cmp_add detail "Last unattended-upgrades run: ${last_run}"

    # Package lists as of the last apt update — never refreshed here, a report
    # must not change the server.
    local lists_age upgradable sec_count
    lists_age=$(( ($(date +%s) - $(stat -c %Y /var/lib/apt/lists 2>/dev/null || date +%s)) / 86400 ))
    upgradable=$(apt list --upgradable 2>/dev/null | tail -n +2)
    printf '%s\n' "$upgradable" > "$(_cmp_ev apt-upgradable.txt)" 2>/dev/null || true
    sec_count=$(grep -c -- '-security' <<<"$upgradable" || true)
    [[ "$sec_count" =~ ^[0-9]+$ ]] || sec_count=0
    if (( sec_count > 0 )); then
        status=$(_cmp_worse "$status" warn)
        _cmp_add detail "${sec_count} pending security update(s) (package lists ${lists_age} day(s) old)"
    else
        _cmp_add detail "No pending security updates (package lists ${lists_age} day(s) old)"
    fi
    if [[ -f /var/run/reboot-required ]]; then
        status=$(_cmp_worse "$status" warn)
        _cmp_add detail "Reboot required for: $(paste -sd' ' /var/run/reboot-required.pkgs 2>/dev/null || echo '?')"
    fi

    local summary
    case "$status" in
        pass) summary="automatic security updates on, nothing pending" ;;
        warn) summary="automatic security updates on, action pending" ;;
        *)    summary="automatic security updates are not active" ;;
    esac
    _cmp_result "$status" "$summary" "$detail"
}

_cmp_check_kernel() {
    # key|accepted values (space-separated)
    local expected="net.ipv4.tcp_syncookies|1
net.ipv4.conf.all.accept_redirects|0
net.ipv4.conf.default.accept_redirects|0
net.ipv4.conf.all.send_redirects|0
net.ipv4.conf.all.accept_source_route|0
net.ipv4.conf.all.rp_filter|1 2
net.ipv4.icmp_echo_ignore_broadcasts|1
net.ipv6.conf.all.accept_redirects|0
kernel.randomize_va_space|2"
    local status=pass detail="" key accept val ok=0 total=0
    : > "$(_cmp_ev sysctl.txt)" 2>/dev/null || true
    while IFS='|' read -r key accept; do
        [[ -z "$key" ]] && continue
        total=$((total + 1))
        val=$(sysctl -n "$key" 2>/dev/null || echo "?")
        echo "${key} = ${val}  (expected: ${accept// / or })" >> "$(_cmp_ev sysctl.txt)" 2>/dev/null || true
        if [[ " ${accept} " == *" ${val} "* ]]; then
            ok=$((ok + 1))
        else
            status=warn
            _cmp_add detail "${key} = ${val} (expected ${accept// / or })"
        fi
    done <<<"$expected"
    [[ "$status" == "warn" ]] && _cmp_add detail "Baseline follows the CIS Ubuntu Linux benchmark network parameters. Set them in /etc/sysctl.d/ if your policy requires it."
    _cmp_result "$status" "${ok}/${total} kernel network parameters match the baseline" "$detail"
}

_cmp_check_tls() {
    local status=pass detail="" conf
    if command -v nginx >/dev/null 2>&1 && conf=$(nginx -T 2>/dev/null); then
        nginx -v 2>&1 | head -1 > "$(_cmp_ev nginx-version.txt)" 2>/dev/null || true
        awk '
            /^# configuration file / { file = $4; sub(/:$/, "", file); next }
            /^[[:space:]]*(ssl_protocols|ssl_ciphers|ssl_prefer_server_ciphers|ssl_session_tickets|ssl_certificate[[:space:]]|add_header[[:space:]]+Strict-Transport-Security)/ {
                line = $0; sub(/^[[:space:]]+/, "", line); print file ": " line
            }' <<<"$conf" > "$(_cmp_ev nginx-tls-directives.txt)" 2>/dev/null || true

        local weak
        weak=$(awk '
            /^# configuration file / { file = $4; sub(/:$/, "", file); next }
            /^[[:space:]]*ssl_protocols/ {
                for (i = 2; i <= NF; i++) {
                    p = $i; sub(/;$/, "", p)
                    if (p == "SSLv2" || p == "SSLv3" || p == "TLSv1" || p == "TLSv1.1") print file ": " p
                }
            }' <<<"$conf" | sort -u)
        if [[ -n "$weak" ]]; then
            status=fail
            _cmp_add detail "Deprecated protocols enabled:"$'\n'"${weak}"
        elif grep -qE '^[[:space:]]*ssl_protocols' <<<"$conf"; then
            _cmp_add detail "ssl_protocols: TLSv1.2+ only"
        else
            _cmp_add detail "No explicit ssl_protocols directive — nginx built-in default applies ($(nginx -v 2>&1 | head -1))"
        fi
        local hsts
        hsts=$(grep -cE '^[[:space:]]*add_header[[:space:]]+Strict-Transport-Security' <<<"$conf" || true)
        _cmp_add detail "HSTS headers configured: ${hsts:-0} (set per app if required by policy)"
    else
        status=warn
        _cmp_add detail "nginx -T failed — TLS directives not collected"
    fi

    shopt -s nullglob
    local certs=(/etc/letsencrypt/live/*/cert.pem)
    shopt -u nullglob
    local cert name end end_ts left algo expired=0 soon=0 now
    now=$(date +%s)
    : > "$(_cmp_ev certificates.txt)" 2>/dev/null || true
    for cert in "${certs[@]}"; do
        name=$(basename "$(dirname "$cert")")
        end=$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | cut -d= -f2-)
        end_ts=$(date -d "$end" +%s 2>/dev/null) || continue
        left=$(( (end_ts - now) / 86400 ))
        algo=$(openssl x509 -noout -text -in "$cert" 2>/dev/null \
            | awk -F': ' '/Public Key Algorithm/ { a = $2 } /Public-Key:/ { k = $2 } END { print a " " k }')
        {
            echo "== ${name}"
            openssl x509 -noout -subject -issuer -startdate -enddate -ext subjectAltName -in "$cert" 2>/dev/null
            echo "key: ${algo}"
            echo "days left: ${left}"
            echo
        } >> "$(_cmp_ev certificates.txt)" 2>/dev/null || true
        if (( left < 0 )); then
            expired=$((expired + 1)); status=fail
            _cmp_add detail "${name}: EXPIRED $(( -left )) day(s) ago"
        elif (( left <= 14 )); then
            soon=$((soon + 1)); status=$(_cmp_worse "$status" warn)
            _cmp_add detail "${name}: expires in ${left} day(s)"
        fi
    done
    _cmp_add detail "Let's Encrypt certificates: ${#certs[@]} (expired ${expired}, expiring within 14 days ${soon})"

    local summary
    case "$status" in
        pass) summary="TLS 1.2+ only, ${#certs[@]} certificate(s) valid" ;;
        warn) summary="TLS configuration needs attention" ;;
        *)    summary="weak protocols or expired certificates" ;;
    esac
    _cmp_result "$status" "$summary" "$detail"
}

_cmp_check_accounts() {
    local status=pass detail=""
    local uid0
    uid0=$(awk -F: '$3 == 0 && $1 != "root" { print $1 }' /etc/passwd | paste -sd' ' -)
    if [[ -n "$uid0" ]]; then
        status=fail
        _cmp_add detail "Accounts with UID 0 besides root: ${uid0}"
    fi

    local app_users
    app_users=$(vault_read apps.json 2>/dev/null | jq -r 'keys[]' 2>/dev/null || true)

    local user uid shell home pw groups kind last logins empty=""
    {
        printf '%-20s %-6s %-8s %-10s %-20s %s\n' USER UID TYPE PASSWORD LAST_LOGIN GROUPS
        while IFS=: read -r user _ uid _ _ home shell; do
            [[ "$uid" =~ ^[0-9]+$ ]] || continue
            (( uid == 0 || uid >= 1000 )) || continue
            [[ "$user" == "nobody" ]] && continue
            case "$shell" in */nologin|*/false|"") continue ;; esac
            pw=$(passwd -S "$user" 2>/dev/null | awk '{print $2}')
            case "$pw" in
                P)  pw="set" ;;
                L)  pw="locked" ;;
                NP) pw="EMPTY"; empty="${empty}${empty:+ }${user}" ;;
                *)  pw="${pw:-?}" ;;
            esac
            if [[ "$user" == "root" ]]; then kind="root"
            elif [[ "$user" == "cipi" ]]; then kind="admin"
            elif grep -qx "$user" <<<"$app_users"; then kind="app"
            else kind="other"
            fi
            last=$(lastlog -u "$user" 2>/dev/null | awk 'NR == 2 { if ($0 ~ /Never logged in/) print "never"; else { $1 = ""; $2 = ""; $3 = ""; sub(/^ +/, ""); print } }')
            groups=$(id -nG "$user" 2>/dev/null | tr ' ' ',')
            printf '%-20s %-6s %-8s %-10s %-20s %s\n' "$user" "$uid" "$kind" "$pw" "${last:-?}" "$groups"
        done < /etc/passwd
    } > "$(_cmp_ev accounts.txt)" 2>/dev/null || true
    logins=$(( $(wc -l < "$(_cmp_ev accounts.txt)" 2>/dev/null || echo 1) - 1 ))
    if [[ -n "$empty" ]]; then
        status=fail
        _cmp_add detail "Login accounts with an empty password: ${empty}"
    fi
    local others
    others=$(awk 'NR > 1 && $3 == "other" { print $1 }' "$(_cmp_ev accounts.txt)" 2>/dev/null | paste -sd' ' -)
    if [[ -n "$others" ]]; then
        status=$(_cmp_worse "$status" warn)
        _cmp_add detail "Login accounts not managed by Cipi (review them): ${others}"
    fi

    # Privileged access: sudo group and sudoers drop-ins (rules only, no secrets live here).
    local sudo_members
    sudo_members=$(getent group sudo admin 2>/dev/null | awk -F: '$4 != "" { print $4 }' | tr ',' '\n' | sort -u | paste -sd' ' -)
    _cmp_add detail "sudo/admin group members: ${sudo_members:-none}"
    {
        local f
        for f in /etc/sudoers /etc/sudoers.d/*; do
            [[ -f "$f" ]] || continue
            echo "== ${f}"
            grep -vE '^[[:space:]]*(#|$)' "$f" 2>/dev/null || true
            echo
        done
    } > "$(_cmp_ev sudoers.txt)" 2>/dev/null || true
    _cmp_add detail "App users: $(grep -c . <<<"$app_users" || true) (SFTP, no sudo; Deployer runs as the app user)"

    _cmp_result "$status" "${logins} login account(s), $(awk 'NR > 1 && $3 == "app"' "$(_cmp_ev accounts.txt)" 2>/dev/null | wc -l) app user(s)" "$detail"
}

_cmp_check_ssh_keys() {
    local status=pass detail="" total=0 weak=""
    local f user line fp bits type comment
    : > "$(_cmp_ev authorized-keys.txt)" 2>/dev/null || true
    shopt -s nullglob
    for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
        user=$(stat -c %U "$f" 2>/dev/null || echo "?")
        [[ "$f" == /root/* ]] && user=root
        echo "== ${user} (${f})" >> "$(_cmp_ev authorized-keys.txt)"
        while IFS= read -r line; do
            [[ -z "$line" || "$line" == \#* ]] && continue
            bits=""; fp=""; type=""; comment=""
            read -r bits fp type comment < <(ssh-keygen -lf - <<<"$line" 2>/dev/null \
                | awk '{ t = $NF; gsub(/[()]/, "", t); c = ""; for (i = 3; i < NF; i++) c = c (c == "" ? "" : " ") $i; print $1, $2, t, (c == "" ? "-" : c) }')
            [[ -z "${fp:-}" ]] && continue
            total=$((total + 1))
            echo "${type} ${bits} ${fp} ${comment}" >> "$(_cmp_ev authorized-keys.txt)"
            if [[ "$type" == "DSA" ]] || [[ "$type" == "RSA" && "$bits" =~ ^[0-9]+$ && "$bits" -lt 3072 ]]; then
                weak="${weak}${weak:+$'\n'}${user}: ${type}-${bits} ${fp} ${comment}"
            fi
        done < "$f"
        echo >> "$(_cmp_ev authorized-keys.txt)"
    done
    shopt -u nullglob
    if [[ -n "$weak" ]]; then
        status=warn
        _cmp_add detail "Keys below the recommended strength (RSA < 3072 bits or DSA):"$'\n'"${weak}"
    fi
    if [[ -s /root/.ssh/authorized_keys ]]; then
        _cmp_add detail "root has authorized_keys (unused while PermitRootLogin is 'no', but should be removed)"
        status=$(_cmp_worse "$status" warn)
    fi
    _cmp_add detail "Fingerprints only — no key material is stored in this report."
    _cmp_result "$status" "${total} authorized key(s) across all accounts" "$detail"
}

_cmp_check_api_tokens() {
    local root="${CIPI_API_ROOT:-/opt/cipi/api}" db
    if [[ ! -f "${root}/artisan" ]]; then
        _cmp_result na "REST API not installed on this server"
        return 0
    fi
    if ! db=$(_cmp_sqlite_path "$root") || [[ ! -f "$db" ]]; then
        _cmp_result warn "API installed but its SQLite database was not found — tokens not inventoried"
        return 0
    fi
    local cols rows stale_days="${CMP_DAYS:-90}"
    cols=$(_cmp_sqlite_columns "$db" personal_access_tokens id name abilities created_at last_used_at expires_at) || cols=""
    if [[ -z "$cols" ]] || ! rows=$(_cmp_sqlite_json "$db" "SELECT ${cols} FROM personal_access_tokens ORDER BY id"); then
        _cmp_result warn "could not read personal_access_tokens (sqlite3 or php-sqlite3 missing?)"
        return 0
    fi
    jq . <<<"$rows" > "$(_cmp_ev api-tokens.json)" 2>/dev/null || true

    local status=pass detail="" now total no_expiry expired stale wildcard
    now=$(date -u '+%Y-%m-%d %H:%M:%S')
    total=$(jq 'length' <<<"$rows")
    no_expiry=$(jq -r '[.[] | select((.expires_at // null) == null) | .name] | join(", ")' <<<"$rows")
    expired=$(jq -r --arg now "$now" '[.[] | select(.expires_at != null and .expires_at < $now) | .name] | join(", ")' <<<"$rows")
    stale=$(jq -r --arg cut "$(date -u -d "-${stale_days} days" '+%Y-%m-%d %H:%M:%S')" \
        '[.[] | select((.last_used_at // "") == "" or .last_used_at < $cut) | .name] | join(", ")' <<<"$rows")
    wildcard=$(jq -r '[.[] | select((.abilities // "") | test("\"\\*\"")) | .name] | join(", ")' <<<"$rows")

    [[ -n "$no_expiry" ]] && { status=warn; _cmp_add detail "Tokens without an expiry date: ${no_expiry}"; }
    [[ -n "$expired" ]]   && { status=warn; _cmp_add detail "Expired tokens still stored (revoke them): ${expired}"; }
    [[ -n "$stale" ]]     && { status=warn; _cmp_add detail "Tokens unused for ${stale_days}+ days: ${stale}"; }
    [[ -n "$wildcard" ]]  && { status=warn; _cmp_add detail "Tokens with every ability (*): ${wildcard}"; }

    local wl="${CIPI_CONFIG}/api-ip-whitelist"
    if [[ -f "$wl" ]]; then
        cp "$wl" "$(_cmp_ev api-ip-whitelist.txt)" 2>/dev/null || true
        if grep -qx '\*' "$wl" 2>/dev/null; then
            status=$(_cmp_worse "$status" warn)
            _cmp_add detail "API IP allowlist is '*' — reachable from any address (cipi api ip-whitelist)"
        else
            _cmp_add detail "API IP allowlist: $(grep -vcE '^[[:space:]]*(#|$)' "$wl" 2>/dev/null || echo 0) entr(y/ies)"
        fi
    fi
    _cmp_add detail "Token hashes are never exported; revoke with: cipi api token revoke <name>"
    _cmp_result "$status" "${total} API token(s)" "$detail"
}

_cmp_check_gui_2fa() {
    local root="${CIPI_GUI_ROOT:-/opt/cipi/gui}" db
    if [[ ! -f "${root}/artisan" ]]; then
        _cmp_result na "Web GUI not installed on this server"
        return 0
    fi
    if ! db=$(_cmp_sqlite_path "$root") || [[ ! -f "$db" ]]; then
        _cmp_result warn "GUI installed but its SQLite database was not found — users not inventoried"
        return 0
    fi
    local cols rows
    cols=$(_cmp_sqlite_columns "$db" users id name email two_factor_enabled two_factor_confirmed_at created_at) || cols=""
    if [[ "$cols" != *two_factor_enabled* ]] || ! rows=$(_cmp_sqlite_json "$db" "SELECT ${cols} FROM users ORDER BY id"); then
        _cmp_result warn "could not read GUI users / 2FA state"
        return 0
    fi
    jq . <<<"$rows" > "$(_cmp_ev gui-users.json)" 2>/dev/null || true
    local total without
    total=$(jq 'length' <<<"$rows")
    without=$(jq -r '[.[] | select((.two_factor_enabled | tostring) as $e | ($e != "1" and $e != "true")) | .email] | join(", ")' <<<"$rows")
    if [[ -n "$without" ]]; then
        _cmp_result fail "GUI user(s) without 2FA" "Enable Google Authenticator 2FA from Settings for: ${without}"
    else
        _cmp_result pass "all ${total} GUI user(s) have 2FA enabled"
    fi
}

_cmp_check_secrets() {
    local status=pass detail="" f mode owner enc plain=""
    {
        printf '%-32s %-5s %-8s %s\n' FILE MODE OWNER ENCRYPTED
        shopt -s nullglob
        for f in "${CIPI_CONFIG}"/*.json; do
            mode=$(stat -c %a "$f" 2>/dev/null); owner=$(stat -c %U "$f" 2>/dev/null)
            if jq empty "$f" 2>/dev/null; then enc=no; else enc=yes; fi
            printf '%-32s %-5s %-8s %s\n' "$(basename "$f")" "$mode" "$owner" "$enc"
        done
        shopt -u nullglob
    } > "$(_cmp_ev config-files.txt)" 2>/dev/null || true

    # apps-public.json is a deliberate plaintext projection without secrets.
    plain=$(awk 'NR > 1 && $4 == "no" && $1 != "apps-public.json" { print $1 }' "$(_cmp_ev config-files.txt)" 2>/dev/null | paste -sd' ' -)
    if [[ -n "$plain" ]]; then
        status=warn
        _cmp_add detail "Plaintext config files (run any cipi command that rewrites them, or report a bug): ${plain}"
    fi
    local world
    world=$(awk 'NR > 1 && $1 != "apps-public.json" && substr($2, length($2), 1) != "0" { print $1 }' "$(_cmp_ev config-files.txt)" 2>/dev/null | paste -sd' ' -)
    if [[ -n "$world" ]]; then
        status=fail
        _cmp_add detail "World-readable config files: ${world}"
    fi

    mode=$(stat -c %a "$CIPI_CONFIG" 2>/dev/null)
    [[ "$mode" == "700" ]] || { status=$(_cmp_worse "$status" warn); _cmp_add detail "${CIPI_CONFIG} mode is ${mode:-?} (expected 700)"; }

    local key
    for key in "${CIPI_CONFIG}/.vault_key" "${CIPI_CONFIG}/.backup_key"; do
        [[ -f "$key" ]] || continue
        mode=$(stat -c %a "$key" 2>/dev/null); owner=$(stat -c %U "$key" 2>/dev/null)
        echo "$(basename "$key") mode=${mode} owner=${owner}" >> "$(_cmp_ev key-files.txt)" 2>/dev/null || true
        if [[ "$owner" != "root" || ! "$mode" =~ ^[4-6]00$ ]]; then
            status=fail
            _cmp_add detail "$(basename "$key") is ${mode} ${owner} (expected root-only)"
        fi
    done
    [[ -f "${CIPI_CONFIG}/.vault_key" ]] || { status=fail; _cmp_add detail "Vault key missing — config cannot be encrypted"; }

    # Honest about the cipher: CBC without a MAC gives confidentiality, not
    # integrity. An auditor will ask; the report says it first.
    _cmp_add detail "Cipher: ${VAULT_CIPHER:-aes-256-cbc} with PBKDF2, key file root-only. Not authenticated (no MAC/AEAD): tampering with an encrypted file is not detected cryptographically — access to ${CIPI_CONFIG} already requires root."
    status=$(_cmp_worse "$status" warn)

    local summary
    case "$status" in
        fail) summary="configuration secrets are exposed" ;;
        *)    summary="config encrypted at rest, root-only (cipher not authenticated)" ;;
    esac
    _cmp_result "$status" "$summary" "$detail"
}

# Deploy log banners (lib/deploy.sh):
#   [ts] ===== deploy start  app=X trigger=T branch=B from-release=R =====
#   [ts] ===== deploy [ROLLBACK ]OK|FAILED  app=X release=R duration=Ns exit=N =====
_cmp_parse_deploy_log() {
    local log="$1" since="$2"
    awk -v since="$since" '
        function kv(k,   i) { for (i = 1; i <= NF; i++) if (index($i, k "=") == 1) return substr($i, length(k) + 2); return "" }
        /===== deploy start / {
            ts = substr($0, 2, 19); trig = kv("trigger"); br = kv("branch"); from = kv("from-release"); started = 1; next
        }
        /===== deploy (ROLLBACK )?(OK|FAILED) / && started {
            started = 0
            if (ts < since) next
            res = ($0 ~ /deploy (ROLLBACK )?OK /) ? "OK" : "FAILED"
            printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", ts, kv("app"), trig, br, from, res, kv("release"), kv("exit")
        }' "$log" 2>/dev/null
}

# ── Deploy audit ledger (lib/cipi-deploy-audit.sh) ──────────────
# /var/log/cipi/deploys.jsonl, one JSON record per published / failed /
# rolled-back release, each carrying the SHA-256 of the line before it.

[[ -z "${CMP_DEPLOY_LEDGER:-}" ]] && CMP_DEPLOY_LEDGER="${CIPI_LOG}/deploys.jsonl"
[[ -z "${CMP_DEPLOY_SINCE_FILE:-}" ]] && CMP_DEPLOY_SINCE_FILE="/var/lib/cipi/deploy-audit-since"

# "ok <records>" or "broken <line> <reason>" — the first break only.
_cmp_ledger_verify() {
    local ledger="$1" line n=0 prev="" seq last_seq=0 want
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$((n + 1))
        if ! jq -e . <<<"$line" >/dev/null 2>&1; then
            echo "broken ${n} not valid JSON"; return 0
        fi
        want=$(jq -r '.prev // ""' <<<"$line")
        if [[ "$want" != "$prev" ]]; then
            echo "broken ${n} previous-record hash mismatch (a record before it was changed or removed)"; return 0
        fi
        seq=$(jq -r '.seq // 0' <<<"$line")
        if [[ "$seq" != "$((last_seq + 1))" ]]; then
            echo "broken ${n} sequence jumps from ${last_seq} to ${seq}"; return 0
        fi
        last_seq="$seq"
        prev=$(printf '%s' "$line" | sha256sum | awk '{print $1}')
    done < "$ledger"
    echo "ok ${n}"
}

# TSV of ledger records at or after <since> (UTC ISO-8601):
# ts app event release commit origin trigger operator ip claimed_source claimed_actor attempted_release
_cmp_ledger_rows() {
    local ledger="$1" since="$2"
    jq -r --arg since "$since" 'select(.ts >= $since) | [
        .ts, .app, .event, (.release // ""), (.commit // ""), (.origin // ""), (.trigger // ""),
        (.operator // ""), (.ip // ""), (.claimed.source // ""), (.claimed.actor // ""),
        (.deployer.release // "")
    ] | map(if . == "" then "-" else . end) | @tsv' "$ledger" 2>/dev/null
}

# Releases Deployer created for <app> since <since> (UTC ISO) that the ledger
# never saw — as published/rolled back, or as the attempted release of a
# failed deploy. Prints "<release>\t<created_at>" per missing release.
_cmp_unaudited_releases() {
    local app="$1" since="$2" ledger="$3" rlog="/home/${1}/.dep/releases_log"
    [[ -f "$rlog" ]] || return 0
    local seen name created created_utc
    seen=$(jq -r --arg a "$app" 'select(.app == $a) | .release, (.deployer.release // "")' "$ledger" 2>/dev/null | grep -v '^$' | sort -u)
    while IFS=$'\t' read -r name created; do
        [[ -z "$name" ]] && continue
        created_utc=$(date -u -d "$created" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || continue
        [[ "$created_utc" < "$since" ]] && continue
        grep -qx "$name" <<<"$seen" && continue
        printf '%s\t%s\n' "$name" "$created_utc"
    done < <(jq -r '[(.release_name // "" | tostring), (.created_at // "")] | @tsv' "$rlog" 2>/dev/null)
}

_cmp_check_deploys() {
    local days="${CMP_DAYS:-90}" since since_utc
    since=$(date -d "-${days} days" '+%Y-%m-%d %H:%M:%S')
    since_utc=$(date -u -d "-${days} days" '+%Y-%m-%dT%H:%M:%SZ')
    local status=pass detail="" ledger="$CMP_DEPLOY_LEDGER"
    _cmp_add detail "Period: last ${days} days (since ${since})"

    # ── ledger: every deploy, whatever started it
    local rows="" total=0 have_ledger=false
    if [[ -f "$ledger" && -x /usr/local/bin/cipi-deploy-audit ]]; then
        have_ledger=true
        local verdict; verdict=$(_cmp_ledger_verify "$ledger")
        echo "$verdict" > "$(_cmp_ev deploy-audit-chain.txt)" 2>/dev/null || true
        if [[ "$verdict" == broken* ]]; then
            status=fail
            _cmp_add detail "Audit ledger chain BROKEN at record ${verdict#broken }"
        else
            _cmp_add detail "Audit ledger: ${verdict#ok } record(s), hash chain intact (${ledger}; also sent to syslog as cipi-deploy)"
            _cmp_add detail "The chain proves nothing was changed or removed before the newest record. Root can still rewrite the newest records or the whole file — the syslog copy, forwarded off the server (see: logging), is the independent one."
        fi
        jq -c --arg since "$since_utc" 'select(.ts >= $since)' "$ledger" > "$(_cmp_ev deploy-audit.jsonl)" 2>/dev/null || true
        rows=$(_cmp_ledger_rows "$ledger" "$since_utc")
        {
            printf 'TIME\tAPP\tEVENT\tRELEASE\tCOMMIT\tORIGIN\tTRIGGER\tOPERATOR\tIP\tCLAIMED_SOURCE\tCLAIMED_ACTOR\tATTEMPTED_RELEASE\n'
            [[ -n "$rows" ]] && printf '%s\n' "$rows"
        } > "$(_cmp_ev deploy-audit.tsv)" 2>/dev/null || true
    else
        status=warn
        _cmp_add detail "Deploy audit ledger not installed (${ledger}) — deploys started outside cipi deploy / the webhook are not recorded. Run: cipi self-update"
    fi

    if [[ -n "$rows" ]]; then
        total=$(grep -c . <<<"$rows")
        local published failed rollbacks apps with_sha
        published=$(awk -F'\t' '$3 == "published"' <<<"$rows" | wc -l)
        failed=$(awk -F'\t' '$3 == "failed"' <<<"$rows" | wc -l)
        rollbacks=$(awk -F'\t' '$3 == "rollback"' <<<"$rows" | wc -l)
        apps=$(cut -f2 <<<"$rows" | sort -u | wc -l)
        with_sha=$(awk -F'\t' '$3 != "failed" && $5 != "-"' <<<"$rows" | wc -l)
        _cmp_add detail "Recorded: ${total} across ${apps} app(s) — ${published} published, ${failed} failed, ${rollbacks} rollback(s)"
        _cmp_add detail "By origin: $(cut -f6 <<<"$rows" | sort | uniq -c | awk '{ printf "%s%s %s", (NR > 1 ? ", " : ""), $2, $1 }')"
        _cmp_add detail "Commit SHA recorded for ${with_sha}/$((published + rollbacks)) published or rolled-back release(s)"
        local ops; ops=$(awk -F'\t' '$8 != "-" { print $8 }' <<<"$rows" | sort -u | paste -sd, -)
        [[ -n "$ops" ]] && _cmp_add detail "Login users behind deploys (audit login uid): ${ops}"
    fi

    # ── completeness: every app's recipe carries the hook, and Deployer made no
    # release the ledger did not see
    if [[ "$have_ledger" == true ]]; then
        local audit_since="$since_utc" started="" df app missing_hook="" missing_rule="" unaudited="" u
        [[ -s "$CMP_DEPLOY_SINCE_FILE" ]] && started=$(head -c 20 "$CMP_DEPLOY_SINCE_FILE" 2>/dev/null)
        [[ -z "$started" ]] && started=$(head -n 1 "$ledger" 2>/dev/null | jq -r '.ts // empty' 2>/dev/null)
        [[ -n "$started" && "$started" > "$audit_since" ]] && audit_since="$started"
        shopt -s nullglob
        for df in /home/*/.deployer/deploy.php; do
            app=$(basename "$(dirname "$(dirname "$df")")")
            grep -q 'cipi:deploy-audit' "$df" 2>/dev/null || missing_hook="${missing_hook}${missing_hook:+, }${app}"
            grep -qs "cipi-deploy-audit ${app} " "/etc/sudoers.d/cipi-${app}" || missing_rule="${missing_rule}${missing_rule:+, }${app}"
            if [[ -n "$started" ]]; then
                u=$(_cmp_unaudited_releases "$app" "$audit_since" "$ledger")
                [[ -n "$u" ]] && unaudited="${unaudited}$(sed "s/^/${app}\t/" <<<"$u")"$'\n'
            fi
        done
        shopt -u nullglob
        {
            echo "Auditing since: ${started:-unknown}"
            echo "deploy.php without the audit hook: ${missing_hook:-none}"
            echo "sudoers without the audit rule: ${missing_rule:-none}"
        } > "$(_cmp_ev deploy-audit-hooks.txt)" 2>/dev/null || true
        if [[ -n "$missing_hook" || -n "$missing_rule" ]]; then
            status=$(_cmp_worse "$status" warn)
            [[ -n "$missing_hook" ]] && _cmp_add detail "deploy.php without the audit hook (edited by hand?): ${missing_hook}"
            [[ -n "$missing_rule" ]] && _cmp_add detail "sudoers without the audit rule: ${missing_rule}"
        fi
        unaudited=$(grep -v '^$' <<<"$unaudited" || true)
        {
            printf 'APP\tRELEASE\tCREATED\n'
            [[ -n "$unaudited" ]] && printf '%s\n' "$unaudited"
        } > "$(_cmp_ev deploy-audit-unaudited.tsv)" 2>/dev/null || true
        if [[ -n "$unaudited" ]]; then
            status=$(_cmp_worse "$status" warn)
            _cmp_add detail "$(grep -c . <<<"$unaudited") release(s) created by Deployer with no audit record: $(cut -f1,2 <<<"$unaudited" | tr '\t' '#' | paste -sd, - | cut -c1-300)"
        elif [[ -n "$started" ]]; then
            _cmp_add detail "Every release Deployer created since ${started} has an audit record"
        fi
    fi

    # ── deploy.log banners (human-readable log; history from before the ledger)
    local tsv="" log lrows
    shopt -s nullglob
    for log in /home/*/logs/deploy.log; do
        lrows=$(_cmp_parse_deploy_log "$log" "$since")
        [[ -n "$lrows" ]] && tsv="${tsv}${tsv:+$'\n'}${lrows}"
    done
    shopt -u nullglob
    local out="" ts lapp trig br from res rel rc sha
    while IFS=$'\t' read -r ts lapp trig br from res rel rc; do
        [[ -z "$ts" ]] && continue
        sha="-"
        [[ -n "$rel" && "$rel" != "?" && -f "/home/${lapp}/releases/${rel}/REVISION" ]] \
            && sha=$(head -c 40 "/home/${lapp}/releases/${rel}/REVISION" 2>/dev/null)
        out="${out}${out:+$'\n'}${ts}"$'\t'"${lapp}"$'\t'"${trig}"$'\t'"${br}"$'\t'"${from}"$'\t'"${rel}"$'\t'"${sha}"$'\t'"${res}"$'\t'"${rc}"
    done < <(sort <<<"$tsv")
    {
        printf 'TIME\tAPP\tTRIGGER\tBRANCH\tFROM_RELEASE\tRELEASE\tCOMMIT\tRESULT\tEXIT\n'
        [[ -n "$out" ]] && printf '%s\n' "$out"
    } > "$(_cmp_ev deploys.tsv)" 2>/dev/null || true
    grep -hE 'DEPLOY|ROLLBACK' "${CIPI_LOG}/cipi.log" 2>/dev/null \
        | awk -v since="$since" 'substr($0, 2, 19) >= since' > "$(_cmp_ev cipi-log-deploys.txt)" 2>/dev/null || true
    local log_total=0
    [[ -n "$out" ]] && log_total=$(grep -c . <<<"$out")
    _cmp_add detail "deploy.log banners (cipi deploy + webhook only): ${log_total} run(s) in the period"
    [[ "$have_ledger" == false && -n "$out" ]] && total="$log_total"

    _cmp_add detail "Deploys are atomic (symlink switch) with rollback. \"origin\", \"operator\" and \"ip\" are read by root from the process chain; \"claimed\" fields come from the app (e.g. cipi/agent) and are not verified."
    local summary
    case "$status" in
        fail) summary="deploy audit ledger has been tampered with" ;;
        warn) if [[ "$have_ledger" == false ]]; then summary="${total} deploy(s) in the log, but no audit ledger"
              else summary="${total} deploy record(s) — audit coverage incomplete"; fi ;;
        *)    if (( total == 0 )); then
                  _cmp_result info "no deploys in the last ${days} days" "$detail"; return 0
              fi
              summary="${total} deploy record(s) in the last ${days} days, every release audited" ;;
    esac
    _cmp_result "$status" "$summary" "$detail"
}

_cmp_check_backups() {
    local cfg="${CIPI_CONFIG}/backup.json"
    if [[ ! -f "$cfg" ]]; then
        _cmp_result fail "no backup configured" "Configure one: cipi backup configure"
        return 0
    fi
    local conf state
    conf=$(vault_read backup.json 2>/dev/null || echo '{}')
    state=$(vault_read backup-state.json 2>/dev/null || echo '{}')
    # Profiles and destination names only — credentials stay in the vault.
    jq '{s3_bucket: (.bucket // null), s3_endpoint: (.endpoint_url // null), profiles: (.profiles // {})}' <<<"$conf" \
        > "$(_cmp_ev backup-profiles.json)" 2>/dev/null || true
    jq . <<<"$state" > "$(_cmp_ev backup-state.json)" 2>/dev/null || true

    local status=pass detail="" now p enabled interval last dests encrypt profiles=0
    now=$(date +%s)
    local bucket; bucket=$(jq -r '.bucket // ""' <<<"$conf")
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        enabled=$(jq -r --arg p "$p" '.profiles[$p].enabled != false' <<<"$conf")
        [[ "$enabled" == "true" ]] || { _cmp_add detail "${p}: disabled"; continue; }
        profiles=$((profiles + 1))
        interval=$(jq -r --arg p "$p" '.profiles[$p].interval_seconds // 86400' <<<"$conf")
        [[ "$interval" =~ ^[0-9]+$ ]] || interval=86400
        last=$(jq -r --arg p "$p" '.[$p].last_success_epoch // 0' <<<"$state")
        [[ "$last" =~ ^[0-9]+$ ]] || last=0
        dests=$(jq -r --arg p "$p" '(.profiles[$p].destinations // ["s3"]) | join(",")' <<<"$conf")
        encrypt=$(jq -r --arg p "$p" '.profiles[$p].encrypt == true' <<<"$conf")

        local line="${p}: every $(( interval / 3600 ))h to ${dests}, encrypted=${encrypt}"
        if (( last == 0 )); then
            status=fail; line="${line}, never succeeded"
        else
            line="${line}, last success $(date -d "@${last}" '+%Y-%m-%d %H:%M' 2>/dev/null) ($(( (now - last) / 3600 ))h ago)"
            (( now - last > interval * 2 )) && { status=fail; line="${line} — OVERDUE"; }
        fi
        if [[ ",${dests}," != *",s3,"* || -z "$bucket" ]]; then
            status=$(_cmp_worse "$status" warn); line="${line} — no off-site copy"
        fi
        [[ "$encrypt" == "true" ]] || { status=$(_cmp_worse "$status" warn); line="${line} — not encrypted"; }
        _cmp_add detail "$line"
    done < <(jq -r '.profiles // {} | keys[]' <<<"$conf" 2>/dev/null)

    if (( profiles == 0 )); then
        _cmp_result fail "backup configured but no enabled profile" "$detail"
        return 0
    fi
    grep -hE 'BACKUP (OK|ERROR)' "${CIPI_LOG}/cipi.log" 2>/dev/null | tail -n 200 > "$(_cmp_ev backup-runs.txt)" 2>/dev/null || true
    _cmp_add detail "Restore tests are not recorded by Cipi: run 'cipi backup verify --deep' periodically and keep its output with this report."
    local summary
    case "$status" in
        pass) summary="${profiles} profile(s) on schedule, off-site and encrypted" ;;
        warn) summary="${profiles} profile(s) on schedule, hardening advised" ;;
        *)    summary="backups overdue or never completed" ;;
    esac
    _cmp_result "$status" "$summary" "$detail"
}

_cmp_check_logging() {
    local status=pass detail=""
    # Remote forwarding — a log that only lives on the host it describes can be
    # erased by whoever compromised that host.
    local fwd
    fwd=$(grep -hsE '^[[:space:]]*[^#].*(@@?[A-Za-z0-9\[]|omfwd)' /etc/rsyslog.conf /etc/rsyslog.d/*.conf 2>/dev/null | head -5)
    if [[ -n "$fwd" ]]; then
        _cmp_add detail "Remote syslog forwarding configured:"$'\n'"${fwd}"
    elif systemctl is-active --quiet vector 2>/dev/null || systemctl is-active --quiet fluent-bit 2>/dev/null \
        || systemctl is-active --quiet promtail 2>/dev/null || systemctl is-active --quiet elastic-agent 2>/dev/null; then
        _cmp_add detail "Log shipping agent running (vector / fluent-bit / promtail / elastic-agent)"
    else
        status=warn
        _cmp_add detail "No remote log forwarding: logs exist only on this server. Forward auth.log and ${CIPI_LOG} to a SIEM or remote syslog."
    fi

    local oldest age
    oldest=$(ls -1tr /var/log/auth.log* 2>/dev/null | head -1)
    if [[ -n "$oldest" ]]; then
        age=$(( ($(date +%s) - $(stat -c %Y "$oldest" 2>/dev/null || date +%s)) / 86400 ))
        _cmp_add detail "auth.log history on disk: ${age} day(s) (oldest: $(basename "$oldest"))"
    else
        status=$(_cmp_worse "$status" warn)
        _cmp_add detail "/var/log/auth.log not found"
    fi
    if [[ -d /var/log/journal ]]; then
        _cmp_add detail "systemd journal: persistent"
    else
        _cmp_add detail "systemd journal: volatile (lost on reboot)"
    fi
    local f
    for f in cipi.log events.log backup.log; do
        [[ -f "${CIPI_LOG}/${f}" ]] && _cmp_add detail "${CIPI_LOG}/${f}: $(wc -l < "${CIPI_LOG}/${f}") line(s)"
    done
    systemctl is-active --quiet auditd 2>/dev/null \
        && _cmp_add detail "auditd: active" \
        || _cmp_add detail "auditd: not running (optional)"

    {
        for f in /etc/logrotate.d/rsyslog /etc/logrotate.d/cipi* /etc/logrotate.d/fail2ban*; do
            [[ -f "$f" ]] || continue
            echo "== ${f}"; cat "$f"; echo
        done
    } > "$(_cmp_ev logrotate.txt)" 2>/dev/null || true
    [[ -n "$fwd" ]] && printf '%s\n' "$fwd" > "$(_cmp_ev rsyslog-forwarding.txt)" 2>/dev/null
    tail -n 500 "${CIPI_LOG}/events.log" > "$(_cmp_ev cipi-events-tail.txt)" 2>/dev/null || true

    local summary
    [[ "$status" == "pass" ]] && summary="logs retained and forwarded off-host" || summary="logs retained locally only"
    _cmp_result "$status" "$summary" "$detail"
}

_cmp_check_monitoring() {
    local status=pass detail=""
    if [[ -f /etc/cron.d/cipi-monitor && -x /usr/local/bin/cipi-monitor ]]; then
        _cmp_add detail "System monitor: cron every 5 minutes"
    else
        status=fail
        _cmp_add detail "System monitor cron is not installed (run: cipi monitor)"
    fi
    local mcfg disabled
    mcfg=$(vault_read monitor.json 2>/dev/null || echo '{}')
    disabled=$(jq -r '[.checks // {} | to_entries[] | select(.value.enabled == false) | .key] | join(", ")' <<<"$mcfg" 2>/dev/null)
    if [[ -n "$disabled" ]]; then
        status=$(_cmp_worse "$status" warn)
        _cmp_add detail "Disabled monitor checks: ${disabled}"
    fi
    local st id failing=""
    shopt -s nullglob
    for st in "${CIPI_LOG}"/monitor/*.state; do
        id=$(basename "$st" .state)
        case "$(cat "$st" 2>/dev/null)" in
            warn|crit) failing="${failing}${failing:+, }${id}=$(cat "$st")" ;;
        esac
    done
    shopt -u nullglob
    if [[ -n "$failing" ]]; then
        status=$(_cmp_worse "$status" warn)
        _cmp_add detail "Checks currently failing: ${failing}"
    fi
    jq '{reminder_minutes, checks}' <<<"$mcfg" > "$(_cmp_ev monitor-config.json)" 2>/dev/null || true

    # Delivery: an alert nobody receives is not monitoring.
    local smtp=false channels=0
    [[ "$(vault_read smtp.json 2>/dev/null | jq -r '.enabled // false' 2>/dev/null)" == "true" ]] && smtp=true
    channels=$(vault_read alerts.json 2>/dev/null | jq '[.channels // [] | .[] | select(.enabled != false)] | length' 2>/dev/null || echo 0)
    [[ "$channels" =~ ^[0-9]+$ ]] || channels=0
    vault_read alerts.json 2>/dev/null | jq '[.channels // [] | .[] | {id, type, enabled: (.enabled != false)}]' \
        > "$(_cmp_ev alert-channels.json)" 2>/dev/null || true
    if [[ "$smtp" != "true" && "$channels" -eq 0 ]]; then
        status=fail
        _cmp_add detail "No alert delivery: SMTP not configured and no chat/webhook channel (cipi smtp configure / cipi notifications channel add)"
    else
        _cmp_add detail "Alert delivery: email=${smtp}, channels=${channels}"
    fi
    local muted
    muted=$(vault_read notifications.json 2>/dev/null | jq -r '[.triggers // {} | to_entries[] | select(.value == false) | .key] | join(", ")' 2>/dev/null)
    [[ -n "$muted" ]] && _cmp_add detail "Muted notification triggers: ${muted}"

    local health=0
    health=$(vault_read apps.json 2>/dev/null | jq '[.[] | select((.health_url // "") != "")] | length' 2>/dev/null || echo 0)
    _cmp_add detail "App HTTP healthchecks configured: ${health}"

    local summary
    case "$status" in
        pass) summary="server checks every 5 min, alerts delivered" ;;
        warn) summary="monitoring active with gaps" ;;
        *)    summary="monitoring or alert delivery missing" ;;
    esac
    _cmp_result "$status" "$summary" "$detail"
}

_cmp_check_time() {
    local out sync ntp
    out=$(timedatectl show 2>/dev/null) || { _cmp_result warn "timedatectl unavailable — clock sync not verified"; return 0; }
    { timedatectl status 2>/dev/null; echo; timedatectl show-timesync 2>/dev/null; } > "$(_cmp_ev timedatectl.txt)" 2>/dev/null || true
    sync=$(sed -n 's/^NTPSynchronized=//p' <<<"$out")
    ntp=$(sed -n 's/^NTP=//p' <<<"$out")
    local tz; tz=$(sed -n 's/^Timezone=//p' <<<"$out")
    if [[ "$sync" == "yes" ]]; then
        _cmp_result pass "clock synchronised via NTP (timezone ${tz:-?})"
    elif [[ "$ntp" == "yes" ]]; then
        _cmp_result warn "NTP enabled but the clock is not synchronised yet"
    else
        _cmp_result fail "NTP synchronisation disabled — log timestamps are unreliable"
    fi
}

_cmp_check_malware() {
    if [[ -f /etc/cron.d/cipi-scan ]]; then
        local last
        last=$(ls -1t "${CIPI_LOG}"/scan/* 2>/dev/null | head -1)
        grep -v '^[[:space:]]*#' /etc/cron.d/cipi-scan > "$(_cmp_ev scan-cron.txt)" 2>/dev/null || true
        [[ -n "$last" ]] && tail -n 100 "$last" > "$(_cmp_ev last-scan-report.txt)" 2>/dev/null
        _cmp_result pass "nightly integrity and upload scan enabled" \
            "${last:+Last report: $(basename "$last") ($(date -r "$last" '+%Y-%m-%d %H:%M' 2>/dev/null))}"
    else
        _cmp_result warn "malware scanning not enabled" "Opt-in: cipi scan enable (ClamAV on uploads + integrity manifest of app code)"
    fi
}

# ── Runner ─────────────────────────────────────────────────────

# _cmp_run_all <evidence-root> — every control, JSON array on stdout.
_cmp_run_all() {
    local ev_root="$1" results="[]"
    local id title iso soc out status summary detail files
    while IFS='|' read -r id title iso soc; do
        [[ -z "$id" ]] && continue
        mkdir -p "${ev_root}/${id}"
        out=$(CMP_EV="${ev_root}/${id}" "_cmp_check_${id}" 2>/dev/null) \
            || out=$(_cmp_result warn "check '${id}' failed to run")
        jq -e . >/dev/null 2>&1 <<<"$out" || out=$(_cmp_result warn "check '${id}' produced invalid output")
        # Empty evidence files are noise in an audit bundle.
        find "${ev_root}/${id}" -type f -empty -delete 2>/dev/null || true
        rmdir "${ev_root}/${id}" 2>/dev/null || true
        files=$(cd "$ev_root" 2>/dev/null && find "$id" -type f 2>/dev/null | sort | sed 's|^|evidence/|' | jq -R . | jq -sc . 2>/dev/null)
        [[ -n "$files" ]] || files="[]"
        status=$(jq -r '.status // "warn"' <<<"$out")
        summary=$(jq -r '.summary // ""' <<<"$out")
        detail=$(jq -r '.detail // ""' <<<"$out")
        results=$(jq -c --arg id "$id" --arg t "$title" --arg iso "$iso" --arg soc "$soc" \
            --arg s "$status" --arg m "$summary" --arg d "$detail" --argjson f "$files" \
            '. + [{id:$id, title:$t, iso27001:($iso | split(", ")), soc2:($soc | split(", ")),
                   status:$s, summary:$m, detail:$d, evidence:$f}]' <<<"$results")
    done < <(_cmp_catalog)
    echo "$results"
}

_cmp_meta_json() {
    local days="$1"
    jq -n \
        --arg host "$(hostname)" \
        --arg fqdn "$(hostname -f 2>/dev/null || hostname)" \
        --arg os "$(lsb_release -ds 2>/dev/null || echo unknown)" \
        --arg kernel "$(uname -r)" \
        --arg cipi "${CIPI_VERSION:-unknown}" \
        --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        --arg by "${SUDO_USER:-$(id -un)}" \
        --arg mid "$(cat /etc/machine-id 2>/dev/null || echo unknown)" \
        --argjson days "$days" \
        '{generator:"cipi compliance report", cipi_version:$cipi, hostname:$host, fqdn:$fqdn,
          machine_id:$mid, os:$os, kernel:$kernel, generated_at:$at, generated_by:$by, period_days:$days}'
}

_cmp_disclaimer() {
    echo "Automated technical evidence for one server, collected read-only by Cipi. It supports — it does not replace — an ISO/IEC 27001 or SOC 2 audit: organisational controls (policies, risk assessment, HR, suppliers, incident response) are out of scope. Control mappings are indicative."
}

_cmp_render_md() {
    local report="$1"
    jq -r --arg disc "$(_cmp_disclaimer)" '
        def icon: {"pass":"✅ PASS","warn":"⚠️ WARN","fail":"❌ FAIL","info":"ℹ️ INFO","na":"➖ N/A"}[.] // .;
        "# Compliance evidence report — \(.meta.hostname)",
        "",
        "| | |",
        "|---|---|",
        "| Server | \(.meta.fqdn) (machine-id `\(.meta.machine_id)`) |",
        "| OS / kernel | \(.meta.os) / \(.meta.kernel) |",
        "| Cipi | v\(.meta.cipi_version) |",
        "| Generated | \(.meta.generated_at) by \(.meta.generated_by) |",
        "| Change / log period | last \(.meta.period_days) days |",
        "",
        "> \($disc)",
        "",
        "## Summary",
        "",
        "**\(.summary.pass) pass · \(.summary.warn) warn · \(.summary.fail) fail · \(.summary.info) info · \(.summary.na) n/a**",
        "",
        "| Control | ISO 27001:2022 | SOC 2 | Result | Finding |",
        "|---|---|---|---|---|",
        (.controls[] | "| \(.title) | \(.iso27001 | join(", ")) | \(.soc2 | join(", ")) | \(.status | icon) | \(.summary | gsub("\\|"; "\\|")) |"),
        "",
        "## Controls",
        (.controls[] |
            "",
            "### \(.title) — \(.status | icon)",
            "",
            "- **ID:** `\(.id)`",
            "- **ISO/IEC 27001:2022 Annex A:** \(.iso27001 | join(", "))",
            "- **SOC 2 TSC:** \(.soc2 | join(", "))",
            "- **Finding:** \(.summary)",
            (if .detail != "" then "", "```", .detail, "```" else empty end),
            (if (.evidence | length) > 0 then "", "Evidence:", "", (.evidence[] | "- `\(.)`") else empty end)
        ),
        "",
        "---",
        "",
        "Integrity: `sha256sum -c SHA256SUMS` inside the report directory. Record the archive SHA-256 outside this server to make later tampering evident."
    ' "$report"
}

_cmp_status_icon() {
    case "$1" in
        pass) printf "${GREEN}●${NC}" ;;
        warn) printf "${YELLOW}●${NC}" ;;
        fail) printf "${RED}●${NC}" ;;
        info) printf "${CYAN}●${NC}" ;;
        na)   printf "${DIM}○${NC}" ;;
        *)    printf "${DIM}?${NC}" ;;
    esac
}

_cmp_print_table() {
    local results="$1" row id status summary
    while IFS= read -r row; do
        [[ -z "$row" ]] && continue
        id=$(jq -r '.id' <<<"$row")
        status=$(jq -r '.status' <<<"$row")
        summary=$(jq -r '.summary' <<<"$row")
        printf "  %b %-11s %-5s %s\n" "$(_cmp_status_icon "$status")" "$id" "$status" "${DIM}${summary}${NC}"
    done < <(jq -c '.[]' <<<"$results")
}

_cmp_summary_json() {
    jq -c '{pass: map(select(.status == "pass")) | length,
            warn: map(select(.status == "warn")) | length,
            fail: map(select(.status == "fail")) | length,
            info: map(select(.status == "info")) | length,
            na:   map(select(.status == "na"))   | length}' <<<"$1"
}

_cmp_days_arg() {
    local days="${ARG_days:-90}"
    [[ "$days" =~ ^[0-9]+$ && "$days" -ge 1 && "$days" -le 3650 ]] \
        || { error "--days must be a whole number between 1 and 3650"; exit 1; }
    echo "$days"
}

# ── CLI ────────────────────────────────────────────────────────

_cmp_check_cmd() {
    parse_args "$@"
    local days; days=$(_cmp_days_arg)
    local tmp; tmp=$(mktemp -d)
    chmod 700 "$tmp"
    local results
    results=$(CMP_DAYS="$days" _cmp_run_all "$tmp")
    rm -rf "$tmp"
    if [[ "${ARG_json:-}" == "true" ]]; then
        jq -n --argjson meta "$(_cmp_meta_json "$days")" --argjson c "$results" \
            --argjson s "$(_cmp_summary_json "$results")" \
            '{meta:$meta, summary:$s, controls:$c}'
    else
        echo -e "\n${BOLD}Compliance check${NC} ${DIM}— $(hostname), $(date '+%Y-%m-%d %H:%M:%S %Z')${NC}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        _cmp_print_table "$results"
        local s; s=$(_cmp_summary_json "$results")
        echo -e "\n  $(jq -r '"\(.pass) pass · \(.warn) warn · \(.fail) fail · \(.info) info · \(.na) n/a"' <<<"$s")"
        echo -e "  ${DIM}Evidence bundle for an auditor: cipi compliance report${NC}\n"
    fi
    # Exit 1 on any fail — usable as a CI / cron gate.
    jq -e 'map(select(.status == "fail")) | length == 0' <<<"$results" >/dev/null
}

_cmp_report_cmd() {
    parse_args "$@"
    local days; days=$(_cmp_days_arg)
    local base="${ARG_out:-$COMPLIANCE_DIR}"
    [[ "$base" == /* ]] || { error "--out must be an absolute path"; exit 1; }
    local json="${ARG_json:-false}"
    # --json keeps stdout machine-readable: progress goes to stderr.
    local fd=1; [[ "$json" == "true" ]] && fd=2

    local name dir
    name="$(hostname -s 2>/dev/null || hostname)-$(date -u '+%Y%m%dT%H%M%SZ')"
    dir="${base}/${name}"
    ( umask 077; mkdir -p "${dir}/evidence" ) || { error "Cannot create ${dir}"; exit 1; }
    chmod 700 "$base" "$dir" 2>/dev/null || true

    step "Collecting evidence (${days}-day period)..." >&"$fd"
    local results meta summary
    results=$(umask 077; CMP_DAYS="$days" _cmp_run_all "${dir}/evidence")
    meta=$(_cmp_meta_json "$days")
    summary=$(_cmp_summary_json "$results")

    jq -n --argjson meta "$meta" --argjson s "$summary" --argjson c "$results" \
        --arg disc "$(_cmp_disclaimer)" \
        '{meta:$meta, disclaimer:$disc, summary:$s, controls:$c}' > "${dir}/report.json"
    _cmp_render_md "${dir}/report.json" > "${dir}/report.md"

    ( cd "$dir" && find . -type f ! -name SHA256SUMS -printf '%P\n' | sort | xargs -d '\n' sha256sum > SHA256SUMS )
    find "$dir" -type f -exec chmod 600 {} + 2>/dev/null || true
    find "$dir" -type d -exec chmod 700 {} + 2>/dev/null || true

    local archive="${base}/${name}.tar.gz" archive_sha=""
    if [[ "${ARG_no_archive:-}" != "true" ]]; then
        ( umask 077; tar -czf "$archive" -C "$base" "$name" ) \
            && archive_sha=$(sha256sum "$archive" | awk '{print $1}') \
            && echo "${archive_sha}  ${name}.tar.gz" > "${archive}.sha256" \
            && chmod 600 "$archive" "${archive}.sha256"
    fi
    log_action "COMPLIANCE REPORT: ${dir} pass=$(jq .pass <<<"$summary") warn=$(jq .warn <<<"$summary") fail=$(jq .fail <<<"$summary")"

    if [[ "$json" == "true" ]]; then
        jq --arg dir "$dir" --arg archive "${archive_sha:+$archive}" --arg sha "$archive_sha" \
            '. + {bundle: {directory:$dir, archive:(if $archive == "" then null else $archive end), archive_sha256:(if $sha == "" then null else $sha end)}}' \
            "${dir}/report.json"
    else
        echo -e "\n${BOLD}Compliance report${NC} ${DIM}— $(hostname)${NC}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        _cmp_print_table "$results"
        echo -e "\n  $(jq -r '"\(.pass) pass · \(.warn) warn · \(.fail) fail · \(.info) info · \(.na) n/a"' <<<"$summary")\n"
        printf "  %-10s %s\n" "Report" "${dir}/report.md"
        printf "  %-10s %s\n" "JSON" "${dir}/report.json"
        if [[ -n "$archive_sha" ]]; then
            printf "  %-10s %s\n" "Archive" "$archive"
            printf "  %-10s %s\n" "SHA-256" "$archive_sha"
            echo -e "\n  ${DIM}Store the SHA-256 outside this server (ticket, audit folder) — it proves the bundle was not altered.${NC}"
        fi
        echo -e "  ${DIM}The bundle has no secrets but does list users, key fingerprints and token names: share it with the auditor only.${NC}\n"
    fi
}

_cmp_list_cmd() {
    parse_args "$@"
    local base="${ARG_out:-$COMPLIANCE_DIR}" r items="[]"
    shopt -s nullglob
    for r in "${base}"/*/report.json; do
        items=$(jq -c --arg dir "$(dirname "$r")" --slurpfile rep "$r" \
            '. + [{directory:$dir, generated_at:$rep[0].meta.generated_at, period_days:$rep[0].meta.period_days, summary:$rep[0].summary}]' \
            <<<"$items" 2>/dev/null || echo "$items")
    done
    shopt -u nullglob
    items=$(jq -c 'sort_by(.generated_at) | reverse' <<<"$items")
    if [[ "${ARG_json:-}" == "true" ]]; then
        jq -n --argjson r "$items" '{reports:$r}'
        return 0
    fi
    echo -e "\n${BOLD}Compliance reports${NC} ${DIM}— ${base}${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [[ "$(jq length <<<"$items")" -eq 0 ]]; then
        echo -e "  ${DIM}None yet — run: cipi compliance report${NC}\n"
        return 0
    fi
    jq -r '.[] | "  \(.generated_at)  \(.summary.pass)✓ \(.summary.warn)! \(.summary.fail)✗  \(.directory)"' <<<"$items"
    echo ""
}

_cmp_controls_cmd() {
    parse_args "$@"
    if [[ "${ARG_json:-}" == "true" ]]; then
        _cmp_catalog | jq -R 'split("|") | {id:.[0], title:.[1], iso27001:(.[2] | split(", ")), soc2:(.[3] | split(", "))}' | jq -s '{controls:.}'
        return 0
    fi
    echo -e "\n${BOLD}Compliance controls${NC} ${DIM}— ISO/IEC 27001:2022 Annex A · SOC 2 TSC${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    local id title iso soc
    while IFS='|' read -r id title iso soc; do
        [[ -z "$id" ]] && continue
        printf "  ${CYAN}%-11s${NC} %-38s ${DIM}%-22s %s${NC}\n" "$id" "$title" "$iso" "$soc"
    done < <(_cmp_catalog)
    echo -e "\n  ${DIM}Mappings are indicative; the auditor decides what evidence satisfies a control.${NC}\n"
}

compliance_command() {
    local sub="${1:-check}"
    if [[ "$sub" == --* ]]; then
        sub="check"
    else
        shift || true
    fi
    case "$sub" in
        check|"")      _cmp_check_cmd "$@" ;;
        report)        _cmp_report_cmd "$@" ;;
        list|ls)       _cmp_list_cmd "$@" ;;
        controls)      _cmp_controls_cmd "$@" ;;
        *)
            error "Use: check report list controls"
            echo -e "  ${DIM}cipi compliance report [--days=90] [--out=/path] [--no-archive] [--json]${NC}"
            exit 1
            ;;
    esac
}

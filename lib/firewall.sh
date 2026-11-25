#!/bin/bash
#############################################
# Cipi — Firewall (UFW) + fail2ban login threshold
#
# 5.14.0 — what the panel's Firewall tab runs:
#   status [--json]           UFW rules, fail2ban (threshold, jails, bans)
#                             and CrowdSec (engine, bouncer, allowlist,
#                             decisions) in one read
#   allow <port> [--from=]    open a port (tcp, or --proto=udp)
#   remove <port> [--from=]   drop an allow (--deny: a deny)
#   block / unblock <ip|cidr> refuse every port to an address, ahead of
#                             every allow
# The ports this server is reached on (its SSH port, 80, 443) are never
# closed to everyone or removed from here, a block never takes in the SSH
# session that runs it, and an allow to everyone never undoes a Zero Trust
# lock. --force gets past these at the server's shell; never from the panel
# (sudo from www-data), whatever it passes.
#############################################

# Failed SSH logins before fail2ban bans the address. Cipi's jail.local sets 3;
# another value lives in this drop-in, which fail2ban reads after jail.local
# (jail.conf, jail.d/*.conf, jail.local, jail.d/*.local), so it wins and a
# migration that rewrites jail.local does not undo it.
[[ -z "${FIREWALL_F2B_ATTEMPTS:-}" ]] && readonly FIREWALL_F2B_ATTEMPTS="/etc/fail2ban/jail.d/cipi-attempts.local"
[[ -z "${FIREWALL_ATTEMPTS_DEFAULT:-}" ]] && readonly FIREWALL_ATTEMPTS_DEFAULT=3
# UFW keeps the rules it was given here: one "### tuple ###" line per rule,
# IPv4 in user.rules and IPv6 in user6.rules — what `status --json` reads.
[[ -z "${FIREWALL_UFW_DIR:-}" ]] && readonly FIREWALL_UFW_DIR="/etc/ufw"

firewall_command() {
    local sub="${1:-}"; shift || true
    case "$sub" in
        allow)          _firewall_allow "$@" ;;
        deny)           _firewall_deny "$@" ;;
        remove|delete)  _firewall_remove "$@" ;;
        block)          _firewall_block "$@" ;;
        unblock)        _firewall_unblock "$@" ;;
        list)           _firewall_list "$@" ;;
        status)         _firewall_status "$@" ;;
        attempts)
               if [[ -z "${1:-}" || "${1:-}" == "--json" ]]; then _firewall_attempts_show "$@"; else _firewall_attempts_set "$1"; fi ;;
        *) error "Use: allow deny remove block unblock list status attempts"; exit 1 ;;
    esac
}

# ── Arguments ─────────────────────────────────────────────────────

# The first argument that is not an --option: `allow --from=X 8080` reads as
# well as `allow 8080 --from=X`.
_firewall_arg() {
    local a
    for a in "$@"; do
        [[ "$a" == --* ]] || { printf '%s' "$a"; return 0; }
    done
    return 0
}

# A port, or a range (8000:8100), as ufw takes it — without leading zeros.
_firewall_port() {
    local p="${1:-}" lo hi
    [[ "$p" =~ ^([0-9]{1,5})(:([0-9]{1,5}))?$ ]] || return 1
    lo=$((10#${BASH_REMATCH[1]}))
    hi="${BASH_REMATCH[3]}"
    (( lo >= 1 && lo <= 65535 )) || return 1
    if [[ -n "$hi" ]]; then
        hi=$((10#$hi))
        (( hi > lo && hi <= 65535 )) || return 1
        echo "${lo}:${hi}"
    else
        echo "$lo"
    fi
}

# An IPv4 or IPv6 address, or a CIDR range. Nothing else reaches ufw (or a
# command line): no option, no hostname, no shell character.
_firewall_valid_net() {
    local n="${1:-}" ip mask="" o
    [[ -n "$n" && "$n" != -* && ${#n} -le 49 ]] || return 1
    ip="${n%%/*}"
    if [[ "$n" == */* ]]; then
        mask="${n#*/}"
        [[ -n "$mask" ]] || return 1
    fi
    if [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        for o in "${BASH_REMATCH[@]:1}"; do
            (( 10#$o <= 255 )) || return 1
        done
        [[ -z "$mask" ]] && return 0
        [[ "$mask" =~ ^[0-9]{1,2}$ ]] && (( 10#$mask <= 32 )) && return 0
        return 1
    fi
    if [[ "$ip" == *:* && "$ip" =~ ^[0-9A-Fa-f:.]+$ && ${#ip} -le 45 ]]; then
        [[ -z "$mask" ]] && return 0
        [[ "$mask" =~ ^[0-9]{1,3}$ ]] && (( 10#$mask <= 128 )) && return 0
        return 1
    fi
    return 1
}

# A range so wide that blocking it would take in a good part of the Internet.
_firewall_too_wide() {
    local n="$1" m
    [[ "$n" == */* ]] || return 1
    m=$((10#${n##*/}))
    if [[ "$n" == *:* ]]; then (( m < 16 )); else (( m < 8 )); fi
}

# --force is for whoever stands at the server's shell: the panel runs these
# through sudo as www-data, and never gets past a guard, whatever it passes.
_firewall_forced() {
    [[ "${ARG_force:-}" == "true" && "${SUDO_USER:-}" != "www-data" ]]
}

_firewall_require_ufw() {
    command -v ufw >/dev/null 2>&1 || { error "UFW is not installed"; exit 1; }
}

_firewall_ufw_failed() {
    error "ufw refused it: $(printf '%s' "${1:-}" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    exit 1
}

# ── What must stay open ───────────────────────────────────────────

# The ports sshd listens on (sshd -T), 22 when it cannot be read.
_firewall_ssh_ports() {
    local ports=""
    if command -v sshd >/dev/null 2>&1; then
        ports=$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2 }' | sort -un | paste -sd' ' -) || ports=""
    fi
    echo "${ports:-22}"
}

# How this server is reached: SSH, and HTTP/HTTPS for its apps, the API and the panel.
_firewall_protected_ports() {
    echo "$(_firewall_ssh_ports) 80 443"
}

# True when the port or the range takes in one of those.
_firewall_touches_protected() {
    local spec="$1" lo hi q
    lo="${spec%%:*}"; hi="${spec##*:}"
    for q in $(_firewall_protected_ports); do
        if (( q >= lo && q <= hi )); then return 0; fi
    done
    return 1
}

# Zero Trust's locks (cipi zt lock http|ssh): 80/443 to Cloudflare only, 22 closed.
_firewall_zt_lock() {
    local st=""
    declare -f vault_read >/dev/null 2>&1 || { echo false; return 0; }
    st=$(vault_read zt.json 2>/dev/null) || st=""
    [[ -n "$st" ]] || st='{}'
    jq -r --arg k "lock_$1" '.[$k] // false' <<< "$st" 2>/dev/null || echo false
}

# An allow to everyone must not reopen what a lock keeps closed.
_firewall_zt_guard() {
    local spec="$1" lo hi q
    _firewall_forced && return 0
    lo="${spec%%:*}"; hi="${spec##*:}"
    if [[ "$(_firewall_zt_lock http)" == "true" ]] && { (( lo <= 80 && hi >= 80 )) || (( lo <= 443 && hi >= 443 )); }; then
        error "Zero Trust keeps 80/443 to Cloudflare (cipi zt lock http): an allow to everyone would reopen them"
        echo "  Reopen them with: cipi zt unlock http"
        exit 1
    fi
    if [[ "$(_firewall_zt_lock ssh)" == "true" ]]; then
        for q in $(_firewall_ssh_ports); do
            if (( lo <= q && hi >= q )); then
                error "Zero Trust keeps SSH closed (cipi zt lock ssh): an allow to everyone would reopen port ${q}"
                echo "  Reopen it with: cipi zt ssh unlock"
                exit 1
            fi
        done
    fi
}

# The address of the SSH session that runs this, when there is one.
_firewall_session_ip() {
    local ip=""
    ip=$(_get_client_ip 2>/dev/null) || ip=""
    [[ "$ip" == "local" ]] && ip=""
    if [[ -z "$ip" ]]; then
        ip=$(who am i 2>/dev/null | sed -n 's/.*(\([^)]*\)).*/\1/p') || ip=""
        ip="${ip%%$'\n'*}"
    fi
    if [[ -n "$ip" ]] && _firewall_valid_net "$ip"; then echo "$ip"; fi
    return 0
}

_firewall_ip4_int() {
    local IFS=.
    # shellcheck disable=SC2086
    set -- $1
    echo $(( (10#$1 << 24) + (10#$2 << 16) + (10#$3 << 8) + 10#$4 ))
}

# True when the address or the range takes in the IP. IPv6: the same address.
_firewall_net_has() {
    local net="$1" ip="$2" base mask n i m
    [[ -n "$ip" ]] || return 1
    if [[ "$net" != *:* && "$ip" != *:* ]]; then
        base="${net%%/*}"; mask=32
        [[ "$net" == */* ]] && mask=$((10#${net##*/}))
        (( mask == 0 )) && return 0
        n=$(_firewall_ip4_int "$base"); i=$(_firewall_ip4_int "$ip")
        m=$(( (0xFFFFFFFF << (32 - mask)) & 0xFFFFFFFF ))
        if (( (n & m) == (i & m) )); then return 0; fi
        return 1
    fi
    [[ "${net,,}" == "${ip,,}" ]]
}

# Never shut out the SSH session that gives the command.
_firewall_guard_self() {
    local net="$1" me
    _firewall_forced && return 0
    me=$(_firewall_session_ip)
    if [[ -n "$me" ]] && _firewall_net_has "$net" "$me"; then
        error "${net} takes in ${me}, the address of this SSH session: you would cut yourself off"
        echo "  At the server's shell, --force does it anyway."
        exit 1
    fi
}

# A deny goes before every allow — UFW stops at the first rule that matches,
# so a deny added after an allow lets the traffic in all the same.
# `ufw prepend` (0.36+) puts it first among the IPv4 or IPv6 rules.
_firewall_ufw_first() {
    local out
    if out=$(ufw prepend "$@" 2>&1); then printf '%s' "$out"; return 0; fi
    if out=$(ufw insert 1 "$@" 2>&1); then printf '%s' "$out"; return 0; fi
    printf '%s' "$out"
    return 1
}

_firewall_inactive_note() {
    local st
    st=$(ufw status 2>/dev/null) || st=""
    if ! grep -q '^Status: active' <<< "$st"; then
        warn "UFW is not active: the rule applies once it is (ufw enable)"
    fi
    return 0
}

# ufw answered "Rule added", "Rule inserted", "Rule deleted" or, while it is
# inactive, "Rules updated" — for IPv4 or IPv6. "Skipping …" and "Could not
# delete non-existent rule" are about one family only when the other changed.
_firewall_ufw_changed() {
    grep -qiE '^rules? (added|inserted|deleted|updated)' <<< "${1:-}"
}

# ── Rules ─────────────────────────────────────────────────────────

_firewall_allow() {
    local raw p proto from out
    raw=$(_firewall_arg "$@")
    parse_args "$@"
    [[ -n "$raw" ]] || { error "Usage: cipi firewall allow <port|from:to> [--from=IP|CIDR] [--proto=tcp|udp]"; exit 1; }
    p=$(_firewall_port "$raw") || { error "Not a port or a port range (1-65535, 8000:8100): ${raw}"; exit 1; }
    proto="${ARG_proto:-tcp}"
    [[ "$proto" == "tcp" || "$proto" == "udp" ]] || { error "--proto is tcp or udp"; exit 1; }
    from="${ARG_from:-}"
    _firewall_require_ufw
    if [[ -n "$from" ]]; then
        _firewall_valid_net "$from" || { error "Not an IP address or a CIDR range: ${from}"; exit 1; }
        out=$(ufw allow from "$from" to any port "$p" proto "$proto" 2>&1) || _firewall_ufw_failed "$out"
    else
        _firewall_zt_guard "$p"
        out=$(ufw allow "${p}/${proto}" 2>&1) || _firewall_ufw_failed "$out"
    fi
    log_action "firewall allow ${p}/${proto}${from:+ from ${from}}"
    if ! _firewall_ufw_changed "$out" && grep -qi 'skipping' <<< "$out"; then
        info "Already allowed: ${p}/${proto}${from:+ from ${from}}"
    else
        success "Allowed ${p}/${proto}${from:+ from ${from}}"
    fi
    _firewall_inactive_note
}

_firewall_deny() {
    local raw p proto from out
    local -a spec
    raw=$(_firewall_arg "$@")
    parse_args "$@"
    [[ -n "$raw" ]] || { error "Usage: cipi firewall deny <port|from:to> [--from=IP|CIDR] [--proto=tcp|udp]"; exit 1; }
    p=$(_firewall_port "$raw") || { error "Not a port or a port range (1-65535, 8000:8100): ${raw}"; exit 1; }
    proto="${ARG_proto:-tcp}"
    [[ "$proto" == "tcp" || "$proto" == "udp" ]] || { error "--proto is tcp or udp"; exit 1; }
    from="${ARG_from:-}"
    _firewall_require_ufw
    if [[ -n "$from" ]]; then
        _firewall_valid_net "$from" || { error "Not an IP address or a CIDR range: ${from}"; exit 1; }
        local q
        for q in $(_firewall_ssh_ports); do
            if [[ "${p%%:*}" -le "$q" && "${p##*:}" -ge "$q" ]]; then _firewall_guard_self "$from"; break; fi
        done
        spec=(from "$from" to any port "$p" proto "$proto")
    else
        if _firewall_touches_protected "$p" && ! _firewall_forced; then
            error "Port ${p} is how this server is reached (SSH, HTTP, HTTPS): denying it to everyone would cut it off"
            echo "  Deny it to one address with --from=, or close it with Zero Trust: cipi zt lock http|ssh"
            echo "  At the server's shell, --force denies it anyway."
            exit 1
        fi
        spec=("${p}/${proto}")
    fi
    out=$(_firewall_ufw_first deny "${spec[@]}") || _firewall_ufw_failed "$out"
    log_action "firewall deny ${p}/${proto}${from:+ from ${from}}"
    if ! _firewall_ufw_changed "$out" && grep -qi 'skipping' <<< "$out"; then
        info "Already denied: ${p}/${proto}${from:+ from ${from}}"
    else
        success "Denied ${p}/${proto}${from:+ from ${from}} — ahead of every allow"
    fi
    _firewall_inactive_note
}

# Drop a rule `allow` (or `deny`, with --deny) made: the same port, --from and --proto.
_firewall_remove() {
    local raw p proto from action=allow out what
    local -a spec
    raw=$(_firewall_arg "$@")
    parse_args "$@"
    [[ -n "$raw" ]] || { error "Usage: cipi firewall remove <port|from:to> [--from=IP|CIDR] [--proto=tcp|udp|any] [--deny]"; exit 1; }
    p=$(_firewall_port "$raw") || { error "Not a port or a port range (1-65535, 8000:8100): ${raw}"; exit 1; }
    proto="${ARG_proto:-tcp}"
    case "$proto" in
        tcp|udp) ;;
        any) [[ "$p" != *:* ]] || { error "A port range always has a protocol (--proto=tcp|udp)"; exit 1; } ;;
        *) error "--proto is tcp, udp or any"; exit 1 ;;
    esac
    [[ "${ARG_deny:-}" == "true" ]] && action=deny
    from="${ARG_from:-}"
    _firewall_require_ufw
    if [[ -n "$from" ]]; then
        _firewall_valid_net "$from" || { error "Not an IP address or a CIDR range: ${from}"; exit 1; }
        spec=(from "$from" to any port "$p")
        [[ "$proto" == "any" ]] || spec+=(proto "$proto")
    else
        if [[ "$action" == "allow" ]] && _firewall_touches_protected "$p" && ! _firewall_forced; then
            error "Port ${p} is how this server is reached (SSH, HTTP, HTTPS): it is not closed from here"
            echo "  To close it to the world, Zero Trust keeps it working: cipi zt lock http|ssh"
            echo "  At the server's shell, --force removes the rule anyway."
            exit 1
        fi
        if [[ "$proto" == "any" ]]; then spec=("$p"); else spec=("${p}/${proto}"); fi
    fi
    what="${action} ${p}${proto:+/${proto}}${from:+ from ${from}}"
    what="${what/\/any/}"
    out=$(ufw --force delete "$action" "${spec[@]}" 2>&1) || _firewall_ufw_failed "$out"
    if ! _firewall_ufw_changed "$out" && grep -qi 'non-existent' <<< "$out"; then
        error "No such rule: ${what}"
        echo "  The rules as they are: cipi firewall list"
        exit 1
    fi
    log_action "firewall remove ${what}"
    success "Removed: ${what}"
}

# Every port refused to an address — a scanner, an abuser. Before every allow.
_firewall_block() {
    local net out
    net=$(_firewall_arg "$@")
    parse_args "$@"
    [[ -n "$net" ]] || { error "Usage: cipi firewall block <ip|cidr>"; exit 1; }
    _firewall_valid_net "$net" || { error "Not an IP address or a CIDR range: ${net}"; exit 1; }
    if _firewall_too_wide "$net"; then
        error "${net} is too wide a range to block (IPv4 /8, IPv6 /16 at most)"
        exit 1
    fi
    _firewall_guard_self "$net"
    _firewall_require_ufw
    out=$(_firewall_ufw_first deny from "$net") || _firewall_ufw_failed "$out"
    log_action "firewall block ${net}"
    if ! _firewall_ufw_changed "$out" && grep -qi 'skipping' <<< "$out"; then
        info "${net} is already blocked"
    else
        success "Blocked ${net}: no port of this server answers it"
    fi
    _firewall_inactive_note
}

_firewall_unblock() {
    local net out
    net=$(_firewall_arg "$@")
    parse_args "$@"
    [[ -n "$net" ]] || { error "Usage: cipi firewall unblock <ip|cidr>"; exit 1; }
    _firewall_valid_net "$net" || { error "Not an IP address or a CIDR range: ${net}"; exit 1; }
    _firewall_require_ufw
    out=$(ufw --force delete deny from "$net" 2>&1) || _firewall_ufw_failed "$out"
    if ! _firewall_ufw_changed "$out" && grep -qi 'non-existent' <<< "$out"; then
        error "${net} is not blocked"
        exit 1
    fi
    log_action "firewall unblock ${net}"
    success "Unblocked ${net}"
}

# ── Reading the rules ─────────────────────────────────────────────

# One line per rule as ufw keeps it, tab-separated:
# family action proto dport dst sport src dapp sapp direction comment(hex)
_firewall_rules_tsv() {
    local fam f
    for fam in v4 v6; do
        f="${FIREWALL_UFW_DIR}/user.rules"
        [[ "$fam" == "v6" ]] && f="${FIREWALL_UFW_DIR}/user6.rules"
        [[ -r "$f" ]] || continue
        awk -v fam="$fam" '
            index($0, "### tuple ### ") == 1 {
                n = split(substr($0, 15), t, " ")
                c = ""
                if (n > 0 && t[n] ~ /^comment=/) { c = substr(t[n], 9); n-- }
                if (n == 9)      { dapp = t[7]; sapp = t[8]; dir = t[9] }
                else if (n == 7) { dapp = "-";  sapp = "-";  dir = t[7] }
                else next
                printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", fam, t[1], t[2], t[3], t[4], t[5], t[6], dapp, sapp, dir, c
            }' "$f"
    done
    return 0
}

# ufw stores a comment as the hex of its UTF-8.
_firewall_unhex() {
    local h="${1:-}"
    [[ -n "$h" && "$h" =~ ^([0-9A-Fa-f]{2})+$ ]] || return 0
    printf '%b' "$(sed 's/../\\x&/g' <<< "$h")" | tr '\t\r\n' '   '
}

# The rules as JSON: an IPv4 rule and its IPv6 twin are one rule (family
# "both"). kind "port" is what allow/deny make, "block" what block makes —
# removable from the panel unless a Cipi feature owns it (its comment) or it
# keeps a protected port open; anything else ("other") is the shell's.
_firewall_rules_json() {
    local protected="${1:-}" tsv="" fam action proto dport dst sport src dapp sapp dir c
    while IFS=$'\t' read -r fam action proto dport dst sport src dapp sapp dir c; do
        [[ -n "$fam" ]] || continue
        tsv+="${fam}"$'\t'"${action}"$'\t'"${proto}"$'\t'"${dport}"$'\t'"${dst}"$'\t'"${sport}"$'\t'"${src}"$'\t'"${dapp}"$'\t'"${sapp}"$'\t'"${dir}"$'\t'"$(_firewall_unhex "${c:-}")"$'\n'
    done < <(_firewall_rules_tsv)
    jq -R -s -c --arg protected "$protected" '
        def anyaddr: . == "0.0.0.0/0" or . == "::/0";
        ($protected | split(" ") | map(select(length > 0) | tonumber)) as $prot
        | [ split("\n")[] | select(length > 0) | split("\t") as $f
            | ($f[1] | split("_")) as $a
            | ($f[9] | split("_")) as $d
            | { fam: $f[0], action: $a[0], log: (($a | length) > 1), proto: $f[2], port: $f[3],
                to: (if ($f[4] | anyaddr) then "any" else $f[4] end), sport: $f[5],
                from: (if ($f[6] | anyaddr) then "any" else $f[6] end),
                app: (if $f[7] == "-" then "" else ($f[7] | gsub("%20"; " ")) end),
                sapp: (if $f[8] == "-" then "" else ($f[8] | gsub("%20"; " ")) end),
                direction: $d[0], interface: ($d[1:] | join("_")), comment: ($f[10] // "") } ]
        | to_entries | map(.value + {n: .key})
        | group_by([.action, .log, .proto, .port, .to, .sport, .from, .app, .sapp, .direction, .interface, .comment])
        | map(. as $g | ($g | min_by(.n)) + {family: (if ($g | map(.fam) | unique | length) > 1 then "both" else $g[0].fam end)})
        | sort_by(.n)
        | map(
            (.direction == "in" and .interface == "" and .app == "" and .sapp == "" and .to == "any" and .sport == "any" and (.log | not)) as $plain
            | .comment as $c
            | . + {
                managed_by: (if ($c | startswith("cipi-zt")) then "zero-trust"
                             elif ($c | startswith("cipi metrics")) then "metrics"
                             elif ($c | startswith("cipi-crowdsec")) then "crowdsec"
                             elif ($c | startswith("cipi")) then "cipi"
                             else "" end),
                kind: (if $plain and (.action == "allow" or .action == "deny") and (.port | test("^[0-9]+(:[0-9]+)?$"))
                           and (.proto == "tcp" or .proto == "udp" or (.proto == "any" and (.port | test("^[0-9]+$"))))
                       then "port"
                       elif $plain and .action == "deny" and .port == "any" and .proto == "any" and .from != "any"
                       then "block"
                       else "other" end) }
            | . + {protected: (if .kind == "port" and .action == "allow" and .from == "any"
                               then ((.port | split(":") | map(tonumber)) as $r
                                     | any($prot[]; . >= $r[0] and . <= ($r[1] // $r[0])))
                               else false end)}
            | . + {removable: ((.kind == "port" or .kind == "block") and .managed_by == "" and (.protected | not))}
            | del(.n, .fam, .sport, .sapp))
    ' <<< "$tsv"
}

_firewall_list() {
    parse_args "$@"
    if [[ "${ARG_json:-}" == "true" ]]; then
        _firewall_rules_json "$(_firewall_protected_ports)"
        return 0
    fi
    _firewall_require_ufw
    echo ""; ufw status numbered 2>/dev/null || true; echo ""
}

# ── fail2ban ──────────────────────────────────────────────────────

_firewall_f2b_running() {
    systemctl is-active --quiet fail2ban 2>/dev/null
}

# The drop-in's value, empty when there is none.
_firewall_attempts_custom() {
    [[ -f "$FIREWALL_F2B_ATTEMPTS" ]] || return 0
    sed -n 's/^maxretry[[:space:]]*=[[:space:]]*\([0-9][0-9]*\)[[:space:]]*$/\1/p' "$FIREWALL_F2B_ATTEMPTS" | head -1
}

# A live sshd jail setting, empty when fail2ban is not running.
_firewall_f2b_get() {
    _firewall_f2b_running || return 0
    fail2ban-client get sshd "$1" 2>/dev/null | grep -E '^[0-9]+$' | head -1 || true
}

_firewall_duration() {
    local s="$1"
    if   (( s % 86400 == 0 )); then echo "$((s / 86400))d"
    elif (( s % 3600 == 0 ));  then echo "$((s / 3600))h"
    elif (( s % 60 == 0 ));    then echo "$((s / 60))m"
    else echo "${s}s"; fi
}

# Threshold and live settings of the sshd jail, every jail with its bans.
_firewall_f2b_json() {
    local installed=false running=false custom live n findtime bantime rows="" list jail st
    command -v fail2ban-client >/dev/null 2>&1 && installed=true
    _firewall_f2b_running && running=true
    custom=$(_firewall_attempts_custom) || custom=""
    live=$(_firewall_f2b_get maxretry) || live=""
    n="${live:-${custom:-$FIREWALL_ATTEMPTS_DEFAULT}}"
    findtime=$(_firewall_f2b_get findtime) || findtime=""
    bantime=$(_firewall_f2b_get bantime) || bantime=""
    if [[ "$running" == "true" ]]; then
        list=$(fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list:[[:space:]]*//p' | tr ',' ' ') || list=""
        for jail in $list; do
            [[ "$jail" =~ ^[A-Za-z0-9_.-]+$ ]] || continue
            st=$(fail2ban-client status "$jail" 2>/dev/null) || continue
            rows+="${jail}"$'\t'"$(sed -n '/Currently banned:/{s/.*Currently banned:[[:space:]]*\([0-9]*\).*/\1/p;q}' <<< "$st")"
            rows+=$'\t'"$(sed -n '/Total banned:/{s/.*Total banned:[[:space:]]*\([0-9]*\).*/\1/p;q}' <<< "$st")"
            rows+=$'\t'"$(sed -n '/Currently failed:/{s/.*Currently failed:[[:space:]]*\([0-9]*\).*/\1/p;q}' <<< "$st")"
            rows+=$'\t'"$(sed -n '/Banned IP list:/{s/.*Banned IP list:[[:space:]]*//p;q}' <<< "$st")"$'\n'
        done
    fi
    jq -R -s -c \
        --argjson installed "$installed" --argjson running "$running" \
        --arg n "$n" --arg default "$FIREWALL_ATTEMPTS_DEFAULT" --arg custom "$custom" --arg live "$live" \
        --arg findtime "$findtime" --arg bantime "$bantime" '
        def num: if . == null or . == "" then null else tonumber end;
        { installed: $installed, running: $running,
          attempts: ($n | num), attempts_default: ($default | num), attempts_custom: ($custom | num),
          attempts_pending: (($custom != "" and $live != "" and $custom != $live)),
          findtime: ($findtime | num), bantime: ($bantime | num),
          jails: [ split("\n")[] | select(length > 0) | split("\t") as $f
                   | { jail: $f[0], banned: (($f[4] // "") | split(" ") | map(select(length > 0))),
                       count: (($f[1] | num) // 0), total: (($f[2] | num) // 0), failed: (($f[3] | num) // 0) } ] }
    ' <<< "$rows"
}

_firewall_attempts_show() {
    local custom live n findtime bantime
    parse_args "$@"
    if [[ "${ARG_json:-}" == "true" ]]; then
        _firewall_f2b_json | jq -c '{attempts, default: .attempts_default, custom: .attempts_custom, pending: .attempts_pending, findtime, bantime, running}'
        return 0
    fi
    custom=$(_firewall_attempts_custom)
    live=$(_firewall_f2b_get maxretry)
    n="${live:-${custom:-$FIREWALL_ATTEMPTS_DEFAULT}}"
    findtime=$(_firewall_f2b_get findtime)
    bantime=$(_firewall_f2b_get bantime)

    echo ""
    echo -e "  ${BOLD}SSH login attempts${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [[ -n "$custom" ]]; then
        printf "  %-22s ${CYAN}%s${NC} ${DIM}(set with cipi firewall attempts; default %s)${NC}\n" "Failed logins → ban" "$n" "$FIREWALL_ATTEMPTS_DEFAULT"
    else
        printf "  %-22s ${CYAN}%s${NC} ${DIM}(default)${NC}\n" "Failed logins → ban" "$n"
    fi
    [[ -n "$findtime" ]] && printf "  %-22s %s\n" "Counted over" "$(_firewall_duration "$findtime")"
    [[ -n "$bantime" ]]  && printf "  %-22s %s ${DIM}(longer for repeat offenders)${NC}\n" "Ban" "$(_firewall_duration "$bantime")"
    if ! _firewall_f2b_running; then
        echo -e "  ${YELLOW}fail2ban is not running — nobody is being banned${NC}"
    elif [[ -n "$custom" && -n "$live" && "$custom" != "$live" ]]; then
        echo -e "  ${YELLOW}fail2ban runs with ${live}, the saved value is ${custom} — cipi service restart fail2ban${NC}"
    fi
    echo ""
    echo -e "  ${DIM}Change: cipi firewall attempts <1-100> | default${NC}"
    echo ""
}

_firewall_attempts_set() {
    local want="$1" n=""
    if [[ "$want" != "default" ]]; then
        if [[ ! "$want" =~ ^[0-9]{1,3}$ ]] || (( 10#$want < 1 || 10#$want > 100 )); then
            error "Usage: cipi firewall attempts [<1-100>|default]"
            exit 1
        fi
        n=$((10#$want))
    fi
    command -v fail2ban-client >/dev/null 2>&1 || { error "fail2ban is not installed"; exit 1; }

    local had=false prev=""
    if [[ -f "$FIREWALL_F2B_ATTEMPTS" ]]; then
        had=true
        prev=$(cat "$FIREWALL_F2B_ATTEMPTS")
    fi

    if [[ -z "$n" ]]; then
        rm -f "$FIREWALL_F2B_ATTEMPTS"
    else
        mkdir -p "$(dirname "$FIREWALL_F2B_ATTEMPTS")"
        cat > "$FIREWALL_F2B_ATTEMPTS" <<EOF
# Written by cipi firewall attempts. Read after jail.local, so this value wins.
[sshd]
maxretry = ${n}
EOF
        chmod 644 "$FIREWALL_F2B_ATTEMPTS"
    fi

    # A configuration fail2ban refuses would leave the server without bans at
    # the next restart: put the previous state back.
    if ! fail2ban-client -t >/dev/null 2>&1; then
        if [[ "$had" == true ]]; then
            printf '%s\n' "$prev" > "$FIREWALL_F2B_ATTEMPTS"
        else
            rm -f "$FIREWALL_F2B_ATTEMPTS"
        fi
        error "fail2ban rejected the configuration — nothing changed (check: fail2ban-client -t)"
        exit 1
    fi

    local shown="${n:-$FIREWALL_ATTEMPTS_DEFAULT}"
    if _firewall_f2b_running; then
        fail2ban-client reload >/dev/null 2>&1 || systemctl reload fail2ban >/dev/null 2>&1 || true
        local live; live=$(_firewall_f2b_get maxretry)
        if [[ -n "$n" && "$live" != "$n" ]]; then
            warn "Saved, but fail2ban still runs with '${live:-?}' — run: cipi service restart fail2ban"
        fi
        if [[ -z "$n" && -n "$live" ]]; then shown="$live"; fi
    else
        warn "fail2ban is not running — the value applies when it starts"
    fi

    log_action "firewall attempts ${want}"
    if [[ -z "$n" ]]; then
        success "Back to the default: ${shown} failed SSH logins ban the address"
    else
        success "${shown} failed SSH login(s) now ban the address"
    fi
    if [[ "$n" == "1" ]]; then
        warn "One mistyped password bans its owner too — unban with: cipi ban unban <IP>"
    fi
}

# ── CrowdSec ──────────────────────────────────────────────────────

# Engine, bouncer, rescue, the operator's allowlist and the decisions, and
# what would stop `cipi crowdsec enable` (its RAM and real_ip checks).
_firewall_cs_json() {
    local installed=false running=false bouncer="not installed" unit mode="" rescue="stopped" port=""
    local allow='[]' decisions='[]' raw avail="0" blockers='[]'
    # shellcheck source=/dev/null
    source "${CIPI_LIB}/crowdsec.sh"
    _crowdsec_installed && installed=true
    _crowdsec_running && running=true
    if [[ "$installed" == "true" ]]; then
        unit=$(_crowdsec_bouncer_unit) || unit=""
        if [[ -n "$unit" ]]; then
            bouncer="stopped"
            systemctl is-active --quiet "$unit" 2>/dev/null && bouncer="running"
        fi
        mode=$(_crowdsec_fw_mode) || mode=""
        systemctl is-active --quiet cipi-crowdsec-rescue 2>/dev/null && rescue="listening"
        port=$(_crowdsec_rescue_read_port 2>/dev/null) || port=""
    fi
    if [[ -s "$CROWDSEC_ALLOW_FILE" ]]; then
        allow=$(sed -e '/^[[:space:]]*$/d' -e '/^#/d' "$CROWDSEC_ALLOW_FILE" | jq -R -s -c 'split("\n") | map(select(length > 0))') || allow='[]'
    fi
    if [[ "$running" == "true" ]]; then
        raw=$(cscli decisions list -o json 2>/dev/null) || raw='[]'
        decisions=$(jq -c '[.[]?.decisions[]? | {ip: (.value // ""), scope: (.scope // ""), type: (.type // ""),
                             reason: (.scenario // .origin // ""), origin: (.origin // ""), duration: (.duration // "")}]' \
                    <<< "${raw:-[]}" 2>/dev/null) || decisions='[]'
    fi
    avail=$(_crowdsec_mem_available_kb) || avail=0
    local -a why=()
    if [[ "${avail:-0}" -lt "$CROWDSEC_MIN_RAM_KB" ]]; then
        why+=("Only $(( ${avail:-0} / 1024 )) MB of RAM free: CrowdSec wants $(( CROWDSEC_MIN_RAM_KB / 1024 )) MB")
    fi
    if ! _crowdsec_nginx_has_real_ip && _crowdsec_looks_behind_proxy; then
        why+=("Nginx looks like it is behind a reverse proxy without real_ip: CrowdSec would ban the proxy (behind Cloudflare: cipi nginx real-ip cloudflare)")
    fi
    if (( ${#why[@]} > 0 )); then
        blockers=$(printf '%s\n' "${why[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0))')
    fi
    jq -n -c --argjson installed "$installed" --argjson running "$running" --arg bouncer "$bouncer" \
        --arg mode "$mode" --arg rescue "$rescue" --arg port "$port" --argjson allow "$allow" \
        --argjson decisions "$decisions" --arg avail "${avail:-0}" --arg need "$CROWDSEC_MIN_RAM_KB" \
        --argjson blockers "$blockers" '
        { installed: $installed, running: $running, bouncer: $bouncer, mode: $mode,
          rescue: $rescue, rescue_port: (if $port == "" then null else ($port | tonumber? // null) end),
          allowlist: $allow, decisions: $decisions,
          ram_available_mb: (($avail | tonumber) / 1024 | floor), ram_required_mb: (($need | tonumber) / 1024 | floor),
          enable_blockers: $blockers }'
}

# ── All of it ─────────────────────────────────────────────────────

_firewall_status_json() {
    local installed=false active=false incoming="" outgoing="" verbose="" protected rules f2b cs lockh lockssh
    protected=$(_firewall_protected_ports)
    if command -v ufw >/dev/null 2>&1; then
        installed=true
        verbose=$(ufw status verbose 2>/dev/null) || verbose=""
        grep -q '^Status: active' <<< "$verbose" && active=true
        incoming=$(sed -n '/^Default:/{s/.*[[:space:]]\([a-z]*\) (incoming).*/\1/p;q}' <<< "$verbose")
        outgoing=$(sed -n '/^Default:/{s/.*[[:space:]]\([a-z]*\) (outgoing).*/\1/p;q}' <<< "$verbose")
    fi
    rules=$(_firewall_rules_json "$protected") || rules=""
    f2b=$(_firewall_f2b_json) || f2b=""
    cs=$(_firewall_cs_json) || cs=""
    [[ -n "$rules" ]] || rules='[]'
    [[ -n "$f2b" ]] || f2b='{}'
    [[ -n "$cs" ]] || cs='{}'
    lockh=$(_firewall_zt_lock http); lockssh=$(_firewall_zt_lock ssh)
    [[ "$lockh" == "true" ]] || lockh=false
    [[ "$lockssh" == "true" ]] || lockssh=false
    jq -n -c --argjson installed "$installed" --argjson active "$active" --arg incoming "$incoming" \
        --arg outgoing "$outgoing" --argjson rules "$rules" --arg protected "$protected" \
        --argjson f2b "$f2b" --argjson cs "$cs" --argjson lockh "$lockh" --argjson lockssh "$lockssh" '
        { ufw: { installed: $installed, active: $active,
                 default_incoming: (if $incoming == "" then null else $incoming end),
                 default_outgoing: (if $outgoing == "" then null else $outgoing end),
                 rules: $rules },
          protected_ports: ($protected | split(" ") | map(select(length > 0) | tonumber) | unique),
          zero_trust: { lock_http: $lockh, lock_ssh: $lockssh },
          fail2ban: $f2b, crowdsec: $cs }'
}

_firewall_status() {
    local s
    parse_args "$@"
    s=$(_firewall_status_json)
    if [[ "${ARG_json:-}" == "true" ]]; then
        printf '%s\n' "$s"
        return 0
    fi
    echo ""
    echo -e "  ${BOLD}Firewall${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    jq -r '
        def dur: if . == null then "" elif . % 86400 == 0 then "\(. / 86400)d" elif . % 3600 == 0 then "\(. / 3600)h" elif . % 60 == 0 then "\(. / 60)m" else "\(.)s" end;
        (if .ufw.installed | not then "  UFW                 not installed"
         else "  UFW                 \(if .ufw.active then "active" else "INACTIVE" end) · default \(.ufw.default_incoming // "?") incoming · \(.ufw.rules | length) rule(s)" end),
        "  Kept open           \(.protected_ports | map(tostring) | join(", "))\(if .zero_trust.lock_http then " · 80/443 Cloudflare only (Zero Trust)" else "" end)\(if .zero_trust.lock_ssh then " · SSH closed (Zero Trust)" else "" end)",
        "  Blocked addresses   \([.ufw.rules[] | select(.kind == "block")] | length)",
        (if .fail2ban.running then "  fail2ban            running · \(.fail2ban.attempts) failed SSH logins → ban \(.fail2ban.bantime | dur)"
         elif .fail2ban.installed then "  fail2ban            STOPPED — nobody is being banned"
         else "  fail2ban            not installed" end),
        "  Banned now          \([.fail2ban.jails[]?.count] | add // 0) by fail2ban\(if .crowdsec.running then ", \(.crowdsec.decisions | length) by CrowdSec" else "" end)",
        (if .crowdsec.installed then "  CrowdSec            \(if .crowdsec.running then "running" else "stopped" end) · bouncer \(.crowdsec.bouncer)"
         else "  CrowdSec            not installed" end)
    ' <<< "$s"
    echo ""
    echo -e "  ${DIM}cipi firewall list · cipi ban list · cipi crowdsec status · --json for all of it${NC}"
    echo ""
}

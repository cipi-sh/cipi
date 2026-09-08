#!/bin/bash
# Local regression checks for 5.2.0 — CrowdSec bouncer + integrity/upload scan.
# Run from repo root: bash tests/verify-5.2.0.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/lib"
PASS=0
FAIL=0

pass() { echo "  OK: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# The "must not appear" checks below are about code, not prose: a comment that
# explains why `cipi crowdsec enable` is not called here is documentation, and
# tripping on it would push the explanation out of the file. Line numbers stay
# real because the comment filter runs on grep's output, not on the input.
code_grep() {
    local pat="$1"; shift
    local f found=1
    for f in "$@"; do
        if grep -nE "$pat" "$f" 2>/dev/null \
            | grep -vE '^[0-9]+:[[:space:]]*#' \
            | sed "s|^|${f}:|" | grep . ; then
            found=0
        fi
    done
    return $found
}

echo "=== Cipi 5.2.0 regression checks ==="

[[ "$(tr -d '[:space:]' < "${ROOT}/version.md")" == "5.2.0" ]] \
    && pass "version.md is 5.2.0" || fail "version.md is not 5.2.0"
grep -q '^## \[5.2.0\]' "${ROOT}/CHANGELOG.md" \
    && pass "CHANGELOG has a 5.2.0 entry" || fail "CHANGELOG has no 5.2.0 entry"
[[ -f "${LIB}/migrations/5.2.0.sh" ]] \
    && pass "5.2.0 migration present (sudoers env_keep)" || fail "missing 5.2.0 migration"
grep -q 'SSH_CLIENT' "${LIB}/migrations/5.2.0.sh" \
    && pass "migration patches env_keep for SSH_CLIENT" || fail "migration does not touch SSH_CLIENT"
grep -q 'visudo -cqf' "${LIB}/migrations/5.2.0.sh" \
    && pass "migration validates sudoers before installing it" || fail "migration installs sudoers unvalidated"
if code_grep 'crowdsec enable|scan enable|apt-get install' "${LIB}/migrations/5.2.0.sh"; then
    fail "migration installs or enables an opt-in feature"
else
    pass "migration does not enable CrowdSec or the scan"
fi
[[ ! -f "${LIB}/migrations/5.2.1.sh" ]] \
    && pass "no stray 5.2.1 migration" || fail "stray 5.2.1 migration"

echo "-- syntax"
for f in "${ROOT}/cipi" "${LIB}/crowdsec.sh" "${LIB}/scan.sh" "${LIB}/ban.sh" \
         "${LIB}/notifications.sh" "${LIB}/service.sh" "${LIB}/cipi-scan-manifest.sh" \
         "${LIB}/cipi-crowdsec-rescue-hole.sh" \
         "${LIB}/deploy.sh" "${LIB}/cipi-app-deploy.sh"; do
    if bash -n "$f" 2>/dev/null; then
        pass "syntax $(basename "$f")"
    else
        fail "syntax $(basename "$f")"
        bash -n "$f" || true
    fi
done
if command -v python3 >/dev/null 2>&1; then
    if python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "${LIB}/cipi-crowdsec-rescue.py"; then
        pass "syntax cipi-crowdsec-rescue.py"
    else
        fail "syntax cipi-crowdsec-rescue.py"
    fi
else
    fail "python3 missing — cannot compile rescue listener"
fi

echo "-- dispatch"
grep -q 'crowdsec_command' "${ROOT}/cipi" && pass "cipi dispatches crowdsec" || fail "no crowdsec dispatch"
grep -q 'scan_command' "${ROOT}/cipi" && pass "cipi dispatches scan" || fail "no scan dispatch"

echo "-- as-is: setup.sh / self-update never enable these"
if code_grep 'crowdsec enable|clamav |crowdsec-firewall' "${ROOT}/setup.sh"; then
    fail "setup.sh would install CrowdSec or ClamAV"
else
    pass "setup.sh does not install CrowdSec or ClamAV"
fi
if code_grep 'cipi crowdsec enable|cipi scan enable|clamav |crowdsec-firewall' "${LIB}/self-update.sh"; then
    fail "self-update enables CrowdSec or ClamAV"
else
    pass "self-update does not enable CrowdSec or ClamAV"
fi

echo "-- CrowdSec: bouncer is registered, not just the engine"
grep -q 'cscli bouncers add' "${LIB}/crowdsec.sh" \
    && pass "registers bouncer via cscli bouncers add" || fail "no cscli bouncers add"
grep -q '_crowdsec_register_bouncer' "${LIB}/crowdsec.sh" \
    && pass "_crowdsec_register_bouncer exists" || fail "no register helper"
if grep -A80 '^_crowdsec_enable()' "${LIB}/crowdsec.sh" | grep -q '_crowdsec_register_bouncer'; then
    pass "enable calls bouncer registration"
else
    fail "enable does not register the bouncer"
fi
grep -q 'crowdsec-firewall-bouncer-nftables' "${LIB}/crowdsec.sh" \
    && pass "nftables bouncer package is an option" || fail "no nftables bouncer"
grep -q '_crowdsec_fw_mode' "${LIB}/crowdsec.sh" \
    && pass "firewall mode is detected" || fail "no fw mode detection"
grep -q 'nf_tables' "${LIB}/crowdsec.sh" \
    && pass "nft backend of iptables is detected" || fail "no nf_tables check"
if code_grep 'modsecurity|owasp|libnginx-mod-http-modsecurity|nginx-bouncer|crowdsec-nginx' \
        "${LIB}/crowdsec.sh" "${LIB}/scan.sh" "${ROOT}/cipi"; then
    fail "WAF / nginx module references present"
else
    pass "no ModSecurity / nginx bouncer"
fi

echo "-- disable flushes netfilter before purge"
if grep -A40 '^_crowdsec_disable()' "${LIB}/crowdsec.sh" | grep -q '_crowdsec_flush_firewall'; then
    pass "disable calls flush"
else
    fail "disable does not flush"
fi
dis_flush=$(awk '/^_crowdsec_disable\(\)/,/^_crowdsec_status\(\)/' "${LIB}/crowdsec.sh" \
    | grep -n '_crowdsec_flush_firewall' | head -1 | cut -d: -f1)
dis_purge=$(awk '/^_crowdsec_disable\(\)/,/^_crowdsec_status\(\)/' "${LIB}/crowdsec.sh" \
    | grep -n '_crowdsec_apt purge' | head -1 | cut -d: -f1)
if [[ -n "$dis_flush" && -n "$dis_purge" && "$dis_flush" -lt "$dis_purge" ]]; then
    pass "disable flushes before purge"
else
    fail "flush is not before purge in disable (flush=${dis_flush:-?} purge=${dis_purge:-?})"
fi
grep -q 'nft delete table' "${LIB}/crowdsec.sh" && pass "flush deletes nft tables" || fail "no nft delete"
grep -q 'iptables -F' "${LIB}/crowdsec.sh" && pass "flush clears iptables chains" || fail "no iptables -F"
grep -q 'cscli decisions delete --all' "${LIB}/crowdsec.sh" \
    && pass "flush deletes all decisions" || fail "no decisions delete --all"

echo "-- lockout / proxy / RAM"
grep -q '_crowdsec_allow_this_ssh' "${LIB}/crowdsec.sh" \
    && pass "SSH session is allowlisted" || fail "no SSH allowlist"
grep -q '_get_client_ip' "${LIB}/crowdsec.sh" \
    && pass "SSH IP comes from the current session" || fail "SSH IP not from session"
# sudo's env_reset drops SSH_CLIENT, and PermitRootLogin=no makes `sudo cipi`
# the normal path — so both the sudoers fix and a fallback must be present.
grep -q 'SSH_CLIENT SSH_CONNECTION' "${ROOT}/setup.sh" \
    && pass "sudoers keeps SSH_CLIENT across sudo" || fail "sudoers drops SSH_CLIENT"
grep -q '_crowdsec_ip_from_proc' "${LIB}/crowdsec.sh" \
    && pass "session IP falls back to the sshd process env" || fail "no /proc fallback"
grep -q '_crowdsec_ip_from_utmp' "${LIB}/crowdsec.sh" \
    && pass "session IP falls back to utmp" || fail "no utmp fallback"
if awk '/^_crowdsec_allow_this_ssh\(\)/,/^# ── Rescue/' "${LIB}/crowdsec.sh" | grep -q 'NOT allowlisted'; then
    pass "enable warns when the session IP is unknown"
else
    fail "enable is silent when it cannot allowlist the session"
fi
if awk '/^_crowdsec_write_extra_whitelist\(\)/,/^_crowdsec_write_github_whitelist\(\)/' "${LIB}/crowdsec.sh" \
    | grep -qE 'if \[\[ -n "\$ips" \]\]|if \[\[ -n "\$cidrs" \]\]'; then
    pass "extra allowlist write survives set -e (IPs only, no CIDRs)"
else
    fail "extra allowlist still uses bare [[ ]] && chains (set -e aborts when cidrs is empty)"
fi
grep -q 'set_real_ip_from' "${LIB}/crowdsec.sh" \
    && pass "enable checks nginx real_ip" || fail "no real_ip check"
# Cipi vhosts are sites-available/<app> with no extension: an --include='*.conf'
# filter would only ever read nginx.conf and miss the Cloudflare evidence.
if code_grep "include='\*\.conf'" "${LIB}/crowdsec.sh" >/dev/null; then
    fail "nginx checks still filter on *.conf (vhosts have no extension)"
else
    pass "nginx checks do not filter on *.conf"
fi
grep -q 'sites-enabled' "${LIB}/crowdsec.sh" \
    && pass "nginx checks read sites-enabled" || fail "nginx checks skip vhosts"
grep -q 'CF-Connecting-IP' "${LIB}/crowdsec.sh" \
    && pass "Cloudflare header is part of the proxy heuristic" || fail "no CF heuristic"
grep -q 'CROWDSEC_MIN_RAM_KB' "${LIB}/crowdsec.sh" \
    && pass "RAM floor is defined" || fail "no RAM floor"
grep -q '524288' "${LIB}/crowdsec.sh" && pass "RAM floor is 512MB" || fail "RAM floor is not 512MB"

echo "-- rescue TLS listener (allowlist, not a login)"
grep -q 'cipi-crowdsec-rescue' "${LIB}/crowdsec.sh" \
    && pass "enable wires the rescue listener" || fail "no rescue listener"
grep -q '_crowdsec_rescue_start' "${LIB}/crowdsec.sh" \
    && pass "_crowdsec_rescue_start exists" || fail "no rescue start"
if grep -A90 '^_crowdsec_enable()' "${LIB}/crowdsec.sh" | grep -q '_crowdsec_rescue_start'; then
    pass "enable starts the rescue listener"
else
    fail "enable does not start rescue"
fi
if awk '/^_crowdsec_disable\(\)/,/^_crowdsec_status\(\)/' "${LIB}/crowdsec.sh" \
        | grep -q '_crowdsec_rescue_stop'; then
    pass "disable stops the rescue listener"
else
    fail "disable does not stop rescue"
fi
grep -q 'ExecStartPost' "${LIB}/crowdsec.sh" \
    && pass "bouncer restart re-punches the rescue port" || fail "no ExecStartPost hole"
grep -q 'tcp dport' "${LIB}/cipi-crowdsec-rescue-hole.sh" \
    && pass "hole script inserts nft accept for the rescue port" || fail "no nft dport accept"
grep -q 'cipi-crowdsec-rescue' "${LIB}/cipi-crowdsec-rescue-hole.sh" \
    && pass "hole script tags the iptables ACCEPT" || fail "no iptables comment"
grep -q 'ufw allow' "${LIB}/crowdsec.sh" \
    && pass "rescue opens UFW" || fail "no ufw allow for rescue"
grep -q 'client_address' "${LIB}/cipi-crowdsec-rescue.py" \
    && pass "peer IP comes from the TLS socket" || fail "listener does not use client_address"
if code_grep 'headers\[|headers\.get' "${LIB}/cipi-crowdsec-rescue.py"; then
    fail "listener reads HTTP headers for the client IP"
else
    pass "listener ignores X-Forwarded-For"
fi
grep -q 'hmac.compare_digest' "${LIB}/cipi-crowdsec-rescue.py" \
    && pass "token compare is constant-time" || fail "no compare_digest"
# The throttle must gate wrong tokens only: refusing a correct token because
# the operator fat-fingered the URL defeats the whole break-glass path.
if awk '/def do_GET/,/^class /' "${LIB}/cipi-crowdsec-rescue.py" | grep -q 'if not _rate_ok'; then
    fail "rate limiter can refuse a valid token"
else
    pass "a valid token is never rate-limited"
fi
grep -q 'TimeoutExpired' "${LIB}/cipi-crowdsec-rescue.py" \
    && pass "a slow redeem still yields the new token" || fail "timeout discards the rotated token"
grep -q 'REDEEM_TIMEOUT = 90' "${LIB}/cipi-crowdsec-rescue.py" \
    && pass "redeem timeout leaves room for SMTP" || fail "redeem timeout is still tight"
grep -q 'MAX_TRACKED_PEERS' "${LIB}/cipi-crowdsec-rescue.py" \
    && pass "the failure table is bounded" || fail "unbounded per-peer state"
grep -q 'NoNewPrivileges=yes' "${LIB}/crowdsec.sh" \
    && pass "rescue unit sets NoNewPrivileges" || fail "rescue unit is unhardened"
grep -q 'MemoryHigh' "${LIB}/crowdsec.sh" \
    && pass "rescue unit caps memory" || fail "rescue unit has no memory cap"
# RESCUE_OK must be printed before the mail, or a hanging SMTP server eats the
# replacement token the caller needs.
redeem_body=$(awk '/^_crowdsec_rescue_redeem\(\)/,/^_crowdsec_enable\(\)/' "${LIB}/crowdsec.sh")
ok_line=$(printf '%s\n' "$redeem_body" | grep -n 'echo "RESCUE_OK' | head -1 | cut -d: -f1)
mail_line=$(printf '%s\n' "$redeem_body" | grep -n '_crowdsec_rescue_mail' | head -1 | cut -d: -f1)
if [[ -n "$ok_line" && -n "$mail_line" && "$ok_line" -lt "$mail_line" ]]; then
    pass "redeem prints RESCUE_OK before mailing"
else
    fail "redeem mails before printing RESCUE_OK (ok=${ok_line:-?} mail=${mail_line:-?})"
fi
grep -q '_crowdsec_rescue_write_token' "${LIB}/crowdsec.sh" \
    && pass "token is rotated after use" || fail "no token rotation"
if awk '/^_crowdsec_rescue_redeem\(\)/,/^_crowdsec_enable\(\)/' "${LIB}/crowdsec.sh" \
        | grep -q '_crowdsec_rescue_write_token'; then
    pass "redeem rotates the token (one-shot)"
else
    fail "redeem does not rotate the token"
fi
grep -q 'unbanip' "${LIB}/crowdsec.sh" \
    && pass "redeem unbans fail2ban" || fail "redeem does not unban fail2ban"
grep -q 'decisions delete --ip' "${LIB}/crowdsec.sh" \
    && pass "redeem deletes the CrowdSec decision" || fail "redeem does not delete the decision"
grep -q 'RESCUE_OK' "${LIB}/crowdsec.sh" && grep -q 'RESCUE_OK' "${LIB}/cipi-crowdsec-rescue.py" \
    && pass "listener parses RESCUE_OK from redeem" || fail "no RESCUE_OK handshake"
if code_grep 'authorized_keys|PasswordAuthentication|/bin/bash' "${LIB}/cipi-crowdsec-rescue.py"; then
    fail "rescue listener looks like a login path"
else
    pass "rescue listener is not a login"
fi
grep -q 'cipi-crowdsec-rescue' "${ROOT}/setup.sh" \
    && pass "setup.sh installs the rescue helper" || fail "setup.sh missing rescue helper"
grep -q 'cipi-crowdsec-rescue' "${LIB}/self-update.sh" \
    && pass "self-update installs the rescue helper" || fail "self-update missing rescue helper"
grep -q 'CIPI_RESCUE_REDEEM' "${LIB}/crowdsec.sh" && grep -q 'CIPI_RESCUE_REDEEM' "${LIB}/cipi-crowdsec-rescue.py" \
    && pass "redeem is only callable from the listener" || fail "redeem is a public CLI"
grep -q 'crowdsec rescue' "${ROOT}/cipi" \
    && pass "help documents rescue" || fail "help silent on rescue"

echo "-- GitHub fail-open / GitLab dated"
grep -q '.hooks' "${LIB}/crowdsec.sh" && pass "GitHub uses .hooks not .web" || fail "GitHub key is not hooks"
if grep -A30 '^_crowdsec_write_github_whitelist()' "${LIB}/crowdsec.sh" | grep -q '\[\[ -s "\$out" \]\]'; then
    pass "GitHub fetch keeps the previous file when empty"
else
    fail "GitHub fetch is not fail-open"
fi
grep -q '2026-09-07' "${LIB}/crowdsec.sh" && pass "GitLab CIDRs are dated" || fail "GitLab CIDRs have no date"
grep -q 'rot' "${LIB}/crowdsec.sh" && pass "GitLab CIDRs are documented as rotting" || fail "no rotting note"

echo "-- scan: manifest on code, ClamAV on uploads"
grep -q '_scan_write_manifest' "${LIB}/scan.sh" && pass "manifest writer exists" || fail "no manifest writer"
grep -q '_scan_hash_tree' "${LIB}/scan.sh" && pass "tree hasher exists" || fail "no hasher"
grep -q 'find -P' "${LIB}/scan.sh" && pass "manifest does not follow shared symlinks" || fail "find follows symlinks"
grep -q 'shared/storage/app' "${LIB}/scan.sh" && pass "ClamAV targets shared/storage/app" || fail "no upload path"
grep -q 'wp-content/uploads' "${LIB}/scan.sh" && pass "custom apps scan wp-content/uploads" || fail "no WP uploads path"
if code_grep 'current/public' "${LIB}/scan.sh" >/dev/null; then
    fail "ClamAV still walks current/public (should be manifest-only)"
else
    pass "ClamAV does not walk current/public"
fi
grep -q 'maldet-sigpack' "${LIB}/scan.sh" && pass "rfxn PHP-webshell signatures" || fail "no rfxn sigpack"
grep -q 'scan_incomplete' "${LIB}/scan.sh" && pass "incomplete runs notify" || fail "no scan_incomplete"
grep -q 'scan_integrity' "${LIB}/scan.sh" && pass "integrity drift notifies" || fail "no scan_integrity"
grep -q 'timed out' "${LIB}/scan.sh" && grep -q 'scan_incomplete' "${LIB}/scan.sh" \
    && pass "timeout is incomplete, not clean" || fail "timeout still silent"
grep -q 'open_basedir' "${LIB}/scan.sh" && pass "isolation check looks at open_basedir" || fail "no open_basedir check"
# clamscan loads the whole DB per run; without a floor the 04:40 job OOMs and
# the kernel may pick MariaDB instead.
grep -q 'SCAN_MIN_RAM_KB' "${LIB}/scan.sh" && pass "scan enable has a RAM floor" || fail "scan enable has no RAM floor"
grep -q 'SCAN_MIN_DISK_KB' "${LIB}/scan.sh" && pass "scan enable has a disk floor" || fail "scan enable has no disk floor"
if grep -A4 '^_scan_enable()' "${LIB}/scan.sh" | grep -q '_scan_check_resources'; then
    pass "enable checks resources before installing ClamAV"
else
    fail "enable installs ClamAV without checking resources"
fi
# A lost hash must not read as "clean", and must not be installed as a baseline.
grep -q 'HASH_INCOMPLETE' "${LIB}/scan.sh" \
    && pass "a partial hash pass is reported, not called clean" || fail "partial hash passes are silent"
grep -q 'SCAN_HASH_ERR' "${LIB}/scan.sh" \
    && pass "hash errors are captured" || fail "hash errors go nowhere"
if awk '/^_scan_write_manifest\(\)/,/^_scan_manifest_cmd\(\)/' "${LIB}/scan.sh" | grep -q '_scan_hash_errors'; then
    pass "a truncated manifest is never installed"
else
    fail "_scan_write_manifest installs whatever it produced"
fi
grep -q 'NO_RELEASE' "${LIB}/scan.sh" \
    && pass "an app with no release is not reported as matching" || fail "no-release apps read as clean"
# The rfxn CDN going down is not an incomplete scan when the previous pack is
# still on disk and still loaded.
if awk '/^_scan_refresh_extra_sigs\(\)/,/^_scan_write_cron\(\)/' "${LIB}/scan.sh" | grep -q 'return 0'; then
    pass "sigpack refresh is fail-open when a pack exists"
else
    fail "sigpack refresh always fails (nightly scan_incomplete)"
fi
grep -q 'cipi-scan-manifest' "${LIB}/deploy.sh" && pass "CLI deploy writes a manifest" || fail "deploy.sh no manifest"
# current/ points at an older tree after a rollback, so the manifest must be
# rewritten or every night mails integrity drift.
if awk '/^_deploy_rollback\(\)/,/^_deploy_releases\(\)/' "${LIB}/deploy.sh" | grep -q 'cipi-scan-manifest'; then
    pass "rollback rewrites the manifest"
else
    fail "rollback leaves a stale manifest (guaranteed false scan_integrity)"
fi
grep -q 'cipi-scan-manifest' "${LIB}/cipi-app-deploy.sh" && pass "webhook deploy writes a manifest" || fail "webhook no manifest"
grep -q 'cipi-scan-manifest' "${LIB}/self-update.sh" && pass "self-update installs the helper" || fail "self-update missing helper"
grep -q 'cipi-scan-manifest' "${ROOT}/setup.sh" && pass "setup.sh installs the helper" || fail "setup.sh missing helper"

echo "-- notifications"
for t in crowdsec_enable crowdsec_disable crowdsec_rescue scan_enable scan_hit scan_incomplete scan_integrity; do
    grep -q "^${t}|" "${LIB}/notifications.sh" && pass "trigger ${t}" || fail "missing trigger ${t}"
done

echo "-- changelog does not claim ~100MB engine-only"
if grep -A30 '^## \[5.2.0\]' "${ROOT}/CHANGELOG.md" | grep -q '~100'; then
    fail "changelog still quotes ~100MB"
else
    pass "changelog does not quote ~100MB engine-only"
fi
grep -A30 '^## \[5.2.0\]' "${ROOT}/CHANGELOG.md" | grep -q 'cscli bouncers add' \
    && pass "changelog mentions bouncer registration" || fail "changelog silent on bouncer"
grep -A40 '^## \[5.2.0\]' "${ROOT}/CHANGELOG.md" | grep -qi 'rescue' \
    && pass "changelog mentions the rescue listener" || fail "changelog silent on rescue"

echo "-- functions exist after source"
src_out=$(CIPI_CONFIG="$ROOT" CIPI_LOG="$ROOT" CIPI_LIB="$LIB" bash -euo pipefail -c '
info(){ :; }; warn(){ :; }; error(){ :; }; success(){ :; }; step(){ :; }
confirm(){ return 0; }
log_action(){ :; }; log_event(){ :; }; cipi_notify(){ :; }
parse_args(){ :; }; app_exists(){ return 1; }; app_get(){ echo ""; }
systemd_unit_exists(){ return 1; }
vault_read(){ echo "{}"; }
_get_client_ip(){ echo local; }
source "${CIPI_LIB}/crowdsec.sh"
source "${CIPI_LIB}/scan.sh"
for f in crowdsec_command _crowdsec_enable _crowdsec_disable _crowdsec_flush_firewall \
         _crowdsec_register_bouncer _crowdsec_rescue_start _crowdsec_rescue_redeem \
         scan_command _scan_enable _scan_run \
         _scan_write_manifest _scan_upload_paths; do
    type -t "$f" | grep -qx function || { echo "missing $f"; exit 1; }
done
echo ok
' 2>&1) || true
[[ "$src_out" == "ok" ]] && pass "libraries still define their functions after source" \
    || fail "source lost functions: ${src_out}"

echo "-- manifest is not writable by the app it protects"
grep -q '/var/lib/cipi/manifests' "${LIB}/scan.sh" \
    && pass "manifests live outside /home/<app>" || fail "manifests still inside the app tree"
if code_grep 'shared/\.cipi-manifest|/home/\$\{app\}/\.cipi-manifest' "${LIB}/scan.sh" "${LIB}/cipi-scan-manifest.sh"; then
    fail "a manifest path under /home survives (the app user could rewrite its own baseline)"
else
    pass "no manifest path under /home"
fi
if awk '/^_scan_write_manifest\(\)/,/^_scan_manifest_cmd\(\)/' "${LIB}/scan.sh" | grep -q 'install -m 600 -o root -g root'; then
    pass "manifest is installed root:root 0600"
else
    fail "manifest is not root-owned 0600"
fi
if awk '/^_scan_write_manifest\(\)/,/^_scan_manifest_cmd\(\)/' "${LIB}/scan.sh" | grep -q 'chown "\${owner}'; then
    fail "manifest is still chowned to the app user"
else
    pass "manifest is not chowned to the app user"
fi
grep -q 'id -u.*-eq 0' "${LIB}/cipi-scan-manifest.sh" \
    && pass "cipi-scan-manifest refuses to run unprivileged" || fail "cipi-scan-manifest still runs as the app user"
grep -q '\[\[ $# -eq 1 \]\]' "${LIB}/cipi-scan-manifest.sh" \
    && pass "cipi-scan-manifest takes exactly one argument" || fail "cipi-scan-manifest accepts extra arguments"
# The webhook deploy runs from the app user's crontab, so it needs the sudo hop.
grep -q 'sudo /usr/local/bin/cipi-scan-manifest' "${LIB}/cipi-app-deploy.sh" \
    && pass "webhook deploy reaches the manifest writer via sudo" || fail "webhook deploy calls the root-only writer directly"
grep -q 'NOPASSWD: /usr/local/bin/cipi-scan-manifest \${app_user}' "${LIB}/app.sh" \
    && pass "app creation grants the narrow manifest sudo entry" || fail "app.sh grants no manifest sudo entry"
grep -q 'NOPASSWD: /usr/local/bin/cipi-scan-manifest \${app}' "${LIB}/sync.sh" \
    && pass "sync grants the narrow manifest sudo entry" || fail "sync.sh grants no manifest sudo entry"
grep -q 'events.log' "${LIB}/cipi-scan-manifest.sh" \
    && pass "every re-baseline is recorded" || fail "re-baselines are silent"

echo "-- integrity comparison survives hostile file names"
grep -q '_scan_compare_awk' "${LIB}/scan.sh" \
    && pass "comparison has a dedicated parser" || fail "no comparison parser"
if awk '/^_scan_diff_manifest\(\)/,/^_scan_compare_awk\(\)/' "${LIB}/scan.sh" | grep -q 'seen\[\$2\]'; then
    fail "comparison still splits on whitespace (\$2 truncates names with spaces)"
else
    pass "comparison does not split fields"
fi
cmp_out=$(bash -c '
CIPI_CONFIG=/tmp CIPI_LOG=/tmp CIPI_LIB="'"${LIB}"'"
info(){ :; }; warn(){ :; }; error(){ :; }; success(){ :; }; step(){ :; }
confirm(){ return 0; }; log_action(){ :; }; log_event(){ :; }; cipi_notify(){ :; }
parse_args(){ :; }; app_exists(){ return 1; }; app_get(){ echo ""; }
systemd_unit_exists(){ return 1; }; vault_read(){ echo "{}"; }; _get_client_ip(){ echo local; }
source "${CIPI_LIB}/scan.sh"
H1=$(printf "a%.0s" {1..64}); H2=$(printf "b%.0s" {1..64}); H3=$(printf "c%.0s" {1..64})
d=$(mktemp -d)
{ echo "# header"; printf "%s  %s\n" "$H1" "./index.php"; printf "%s  %s\n" "$H2" "./public/my file.css"; } > "$d/base"
check() { local out rc=0; out=$(awk "$(_scan_compare_awk)" "$d/base" "$d/fresh") || rc=$?; echo "${rc}:${out}"; }
# clean
{ printf "%s  %s\n" "$H1" "./index.php"; printf "%s  %s\n" "$H2" "./public/my file.css"; } > "$d/fresh"
[[ "$(check)" == "0:" ]] || { echo "clean tree not clean"; exit 1; }
# a name with a space must be reported whole, not truncated at the first word
{ printf "%s  %s\n" "$H1" "./index.php"; printf "%s  %s\n" "$H2" "./public/my file.css"; printf "%s  %s\n" "$H3" "./public/my shell.php"; } > "$d/fresh"
check | grep -q "extra: ./public/my shell.php" || { echo "space in name truncated"; exit 1; }
# GNU coreutils escapes names holding a backslash and prefixes the record
{ printf "%s  %s\n" "$H1" "./index.php"; printf "%s  %s\n" "$H2" "./public/my file.css"; printf "\\\\%s  %s\n" "$H3" "./public/sh\\\\ell.php"; } > "$d/fresh"
check | grep -q "extra:" || { echo "escaped record invisible"; exit 1; }
# changed and missing still work
{ printf "%s  %s\n" "$H3" "./index.php"; printf "%s  %s\n" "$H2" "./public/my file.css"; } > "$d/fresh"
check | grep -q "changed: ./index.php" || { echo "changed not detected"; exit 1; }
{ printf "%s  %s\n" "$H1" "./index.php"; } > "$d/fresh"
check | grep -q "missing: ./public/my file.css" || { echo "missing not detected"; exit 1; }
rm -rf "$d"; echo ok
' 2>&1) || true
[[ "$cmp_out" == "ok" ]] && pass "comparison catches spaces, backslashes, changes and deletions" \
    || fail "comparison regression: ${cmp_out}"
grep -q 'SCAN_REPORT_KEEP' "${LIB}/scan.sh" \
    && pass "nightly reports are pruned" || fail "reports accumulate forever"
if code_grep '/tmp/\.cipi-scan-hash-err' "${LIB}/scan.sh"; then
    fail "hash error file still uses a PID-predictable /tmp path"
else
    pass "hash error file comes from mktemp"
fi

echo "-- CrowdSec actually reads the app vhost logs"
grep -q '/home/\*/logs/nginx-access.log' "${LIB}/crowdsec.sh" \
    && pass "acquisition covers per-app access logs" || fail "acquisition misses the per-app access logs"
grep -q '/home/\*/logs/nginx-error.log' "${LIB}/crowdsec.sh" \
    && pass "acquisition covers per-app error logs" || fail "acquisition misses the per-app error logs"
if awk '/^_crowdsec_setup_apt_repo\(\)/,/^_crowdsec_install_packages\(\)/' "${LIB}/crowdsec.sh" | grep -q 'rm -f "\$list"'; then
    pass "a failed repo setup does not leave a broken apt source"
else
    fail "a failed repo setup leaves /etc/apt/sources.list.d/crowdsec.list behind"
fi

echo "-- cscli JSON is a list of alerts, not of decisions"
grep -q 'decisions\[\]?' "${LIB}/ban.sh" \
    && pass "ban list reads .decisions[]" || fail "ban list still reads .value at the top level"
if code_grep "jq -r '\.\[\]\? \| \[\.value" "${LIB}/ban.sh"; then
    fail "ban list still uses the top-level .value path (prints a count and no rows)"
else
    pass "ban list does not use the top-level .value path"
fi
grep -q 'decisions\[\]?' "${LIB}/crowdsec.sh" \
    && pass "crowdsec status counts decisions, not alerts" || fail "crowdsec status counts alerts"
if awk '/^_ban_unban\(\)/,/^}/' "${LIB}/ban.sh" | grep -q 'decisions list --ip'; then
    pass "unban checks before claiming success"
else
    fail "unban reports success even when cscli deleted nothing"
fi
cmp_json=$(printf '%s' '[{"decisions":[{"value":"203.0.113.7","scenario":"crowdsecurity/ssh-bf"},{"value":"198.51.100.4","scenario":"x"}]}]' \
    | jq -r '.[]?.decisions[]? | [.value, (.scenario // .origin // .type // "")] | @tsv' 2>/dev/null | grep -c . || true)
[[ "$cmp_json" == "2" ]] && pass "the jq path yields one row per decision" \
    || fail "the jq path yields ${cmp_json} rows for two decisions"

echo "-- rescue listener cannot be stalled shut"
if code_grep 'wrap_socket\(httpd\.socket' "${LIB}/cipi-crowdsec-rescue.py"; then
    fail "TLS still wraps the listening socket (one idle peer blocks accept)"
else
    pass "TLS does not wrap the listening socket"
fi
grep -q 'def finish_request' "${LIB}/cipi-crowdsec-rescue.py" \
    && pass "handshake runs in the worker thread" || fail "handshake is not moved off the accept loop"
grep -q 'HANDSHAKE_TIMEOUT' "${LIB}/cipi-crowdsec-rescue.py" \
    && pass "the handshake has a deadline" || fail "a stalled handshake never times out"
grep -q 'MAX_CONCURRENT' "${LIB}/cipi-crowdsec-rescue.py" \
    && pass "concurrent connections are bounded" || fail "connection count is unbounded (TasksMax)"
grep -q '_fails_lock' "${LIB}/cipi-crowdsec-rescue.py" \
    && pass "the shared failure table is locked" || fail "the failure table is shared across threads unlocked"

echo "-- the upgrade path installs what 5.2.0 adds"
grep -q 'CIPI_UPDATE_TMP' "${LIB}/migrations/5.2.0.sh" \
    && pass "migration reads the fresh clone" || fail "migration cannot reach the new files"
for h in cipi-scan-manifest cipi-crowdsec-rescue cipi-crowdsec-rescue-hole; do
    grep -q "${h}" "${LIB}/migrations/5.2.0.sh" \
        && pass "migration installs ${h}" || fail "migration does not install ${h}"
done
grep -q 'cipi-scan-manifest %s' "${LIB}/migrations/5.2.0.sh" \
    && pass "migration grants the manifest sudo entry to existing apps" || fail "existing apps get no manifest sudo entry"
grep -q '/var/lib/cipi/manifests' "${LIB}/migrations/5.2.0.sh" \
    && pass "migration creates the manifest store" || fail "migration does not create the manifest store"
grep -q '/var/lib/cipi/manifests' "${ROOT}/setup.sh" \
    && pass "setup.sh creates the manifest store" || fail "setup.sh does not create the manifest store"
grep -q 'cipi-crowdsec-rescue' "${ROOT}/cipi" \
    && pass "cipi status shows the rescue listener" || fail "cipi status hides the rescue listener"

echo "-- shell completion"
[[ -f "${LIB}/completion.sh" ]] \
    && pass "completion.sh present" || fail "no completion.sh"
bash -n "${LIB}/completion.sh" 2>/dev/null \
    && pass "syntax completion.sh" || fail "syntax completion.sh"
grep -q 'completion_command' "${ROOT}/cipi" \
    && pass "cipi dispatches completion" || fail "no completion dispatch"
grep -q 'source "${CIPI_LIB}/completion.sh"' "${ROOT}/cipi" \
    && pass "cipi sources completion.sh" || fail "cipi does not source completion.sh"
grep -q '_completion_install_system' "${ROOT}/setup.sh" \
    && pass "setup.sh installs completion" || fail "setup.sh does not install completion"
grep -q '_completion_install_system' "${LIB}/self-update.sh" \
    && pass "self-update refreshes completion" || fail "self-update does not touch completion"
grep -qE '(^|[^A-Za-z-])bash-completion([^A-Za-z-]|$)' "${ROOT}/setup.sh" \
    && pass "setup.sh installs the bash-completion package" || fail "setup.sh does not install bash-completion"
grep -q '/etc/profile.d/cipi-completion.sh' "${LIB}/completion.sh" \
    && pass "profile.d loader is part of the install" || fail "no /etc/profile.d loader"
gen_sys=$(bash -c 'source "'"${LIB}"'/completion.sh"; type -t _completion_install_system' 2>/dev/null)
[[ "$gen_sys" == function ]] \
    && pass "_completion_install_system is defined" || fail "_completion_install_system missing"

gen=$(bash -c 'source "'"${LIB}"'/completion.sh"; _completion_bash_script' 2>/dev/null)
printf '%s\n' "$gen" | bash -n 2>/dev/null \
    && pass "generated bash completion is valid bash" || fail "generated bash completion does not parse"
printf '%s\n' "$gen" | grep -q 'complete -F _cipi_complete cipi' \
    && pass "generated script registers _cipi_complete" || fail "generated script registers nothing"
zgen=$(bash -c 'source "'"${LIB}"'/completion.sh"; _completion_zsh_script' 2>/dev/null)
printf '%s\n' "$zgen" | head -1 | grep -q '^#compdef cipi' \
    && pass "zsh script carries the #compdef tag" || fail "zsh script has no #compdef tag"
printf '%s\n' "$zgen" | grep -q 'bashcompinit' \
    && pass "zsh script bridges via bashcompinit" || fail "zsh script does not load bashcompinit"

# Drift guard: every verb the completion advertises must dispatch in cipi.
adv=$(printf '%s\n' "$gen" | sed -n 's/.*local commands="\([^"]*\)".*/\1/p')
miss=""
for v in $adv; do
    [[ "$v" == "help" || "$v" == "completion" ]] && continue
    grep -qE "^[[:space:]]+${v}[)|]" "${ROOT}/cipi" || miss="$miss $v"
done
[[ -z "$miss" ]] && pass "completion verbs all dispatch in cipi" \
    || fail "completion advertises verbs cipi does not dispatch:$miss"

echo ""
echo "=== ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]

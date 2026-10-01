#!/bin/bash
# Local regression checks for 5.4.2 — Laravel apps log to one file
# (LOG_CHANNEL=single), logrotate leaves dated logs alone, and the migration
# switches installed apps and folds their dated logs into laravel.log; and
# `cipi firewall attempts` (fail2ban sshd maxretry); the installer names a
# shared-kernel environment instead of failing the Ubuntu version check;
# `cipi disk`; and tab-completion that works behind sudo and in non-login shells.
# Run from repo root: bash tests/verify-5.4.2.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/lib"
PASS=0
FAIL=0

pass() { echo "  OK: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "=== Cipi 5.4.2 regression checks ==="

[[ "$(tr -d '[:space:]' < "${ROOT}/version.md")" == "5.4.2" ]] \
    && pass "version.md is 5.4.2" || fail "version.md is not 5.4.2"
grep -q '^## \[5.4.2\]' "${ROOT}/CHANGELOG.md" \
    && pass "CHANGELOG has a 5.4.2 entry" || fail "CHANGELOG has no 5.4.2 entry"
[[ -f "${LIB}/migrations/5.4.2.sh" ]] && pass "5.4.2 migration present" || fail "missing 5.4.2 migration"

echo "-- syntax"
for f in "${ROOT}/cipi" "${ROOT}/setup.sh" "${LIB}/app.sh" "${LIB}/common.sh" "${LIB}/sync.sh" "${LIB}/firewall.sh" "${LIB}/disk.sh" \
         "${LIB}/monitor.sh" "${LIB}/notifications.sh" \
         "${LIB}/completion.sh" "${LIB}/compliance.sh" "${LIB}/migrations/5.4.2.sh"; do
    bash -n "$f" 2>/dev/null && pass "syntax ${f#"${ROOT}/"}" || { fail "syntax ${f#"${ROOT}/"}"; bash -n "$f"; }
done

# ── 1. defaults ───────────────────────────────────────────────
echo "-- defaults"
grep -q '^LOG_CHANNEL=single$' "${LIB}/app.sh" && ! grep -q '^LOG_CHANNEL=daily' "${LIB}/app.sh" \
    && pass "new Laravel apps get LOG_CHANNEL=single" || fail "app.sh still writes LOG_CHANNEL=daily"
for f in "${ROOT}/setup.sh" "${LIB}/migrations/5.4.2.sh"; do
    grep -q '^/home/\*/shared/storage/logs/\*\[!0-9\]\.log$' "$f" && ! grep -q '^/home/\*/shared/storage/logs/\*\.log$' "$f" \
        && pass "${f#"${ROOT}/"}: logrotate skips logs ending in a date" || fail "${f#"${ROOT}/"}: logrotate still takes *.log"
done
mkdir -p "${TMP}/glob"
touch "${TMP}/glob/laravel.log" "${TMP}/glob/worker.log" "${TMP}/glob/laravel-2026-01-31.log" "${TMP}/glob/laravel-2026-01-31.log.1"
got=$(cd "${TMP}/glob" && echo *[!0-9].log)
[[ "$got" == "laravel.log worker.log" ]] && pass "the pattern matches laravel.log and worker.log only" || fail "pattern matched: ${got}"
[[ "$(grep -c 'laravel_env_single_log' "${LIB}/sync.sh")" -eq 2 && "$(grep -c 'laravel_logs_unify' "${LIB}/sync.sh")" -eq 2 ]] \
    && pass "sync import normalizes the .env and the restored logs" || fail "sync import does not normalize .env / logs"

# ── 2. .env ───────────────────────────────────────────────────
echo "-- laravel_env_single_log"
eval "$(sed -n '/^laravel_env_single_log()/,/^}/p' "${LIB}/common.sh")"
envcase() {   # <name> <expected rc> <expected content> <content>
    printf '%s' "$4" > "${TMP}/env"
    laravel_env_single_log "${TMP}/env"; local rc=$?
    if [[ $rc -eq $2 && "$(cat "${TMP}/env")" == "$3" ]]; then pass "$1"; else fail "$1 (rc=${rc}): $(tr '\n' '|' < "${TMP}/env")"; fi
}
envcase "daily becomes single, other lines untouched" 0 \
    $'APP_NAME="x"\nLOG_CHANNEL=single\nLOG_LEVEL=error\n# LOG_CHANNEL=daily\nDB_PASSWORD=a$b|c\\d' \
    $'APP_NAME="x"\nLOG_CHANNEL=daily\nLOG_LEVEL=error\n# LOG_CHANNEL=daily\nDB_PASSWORD=a$b|c\\d\n'
envcase "quoted value with a comment" 0 $'LOG_CHANNEL=single' $'LOG_CHANNEL="daily"  # per day\n'
envcase "CRLF file" 0 $'A=1\r\nLOG_CHANNEL=single\nB=2\r' $'A=1\r\nLOG_CHANNEL=daily\r\nB=2\r\n'
envcase "LOG_STACK=daily becomes single" 0 $'LOG_CHANNEL=stack\nLOG_STACK=single' $'LOG_CHANNEL=stack\nLOG_STACK=daily\n'
envcase "LOG_STACK keeps its other channels" 0 $'LOG_CHANNEL=stack\nLOG_STACK=single,slack' $'LOG_CHANNEL=stack\nLOG_STACK=daily,slack\n'
envcase "LOG_STACK does not end up with single twice" 0 $'LOG_STACK=single,stderr' $'LOG_STACK=single,daily,stderr\n'
envcase "single is left alone" 1 $'LOG_CHANNEL=single\nLOG_LEVEL=error' $'LOG_CHANNEL=single\nLOG_LEVEL=error\n'
envcase "another channel is left alone" 1 $'LOG_CHANNEL=stderr\nLOG_STACK=single,slack' $'LOG_CHANNEL=stderr\nLOG_STACK=single,slack\n'
envcase "a name that only contains daily is left alone" 1 $'LOG_CHANNEL=mydaily\nLOG_DAILY_DAYS=30' $'LOG_CHANNEL=mydaily\nLOG_DAILY_DAYS=30\n'
laravel_env_single_log "${TMP}/nope"; [[ $? -eq 1 ]] && pass "missing .env: nothing to do" || fail "missing .env not handled"
printf 'LOG_CHANNEL=daily\n' > "${TMP}/env"; chmod 640 "${TMP}/env"; ino=$(ls -i "${TMP}/env" | awk '{print $1}')
laravel_env_single_log "${TMP}/env"
[[ "$(ls -i "${TMP}/env" | awk '{print $1}')" == "$ino" && "$(ls -l "${TMP}/env" | cut -c1-10)" == "-rw-r-----" ]] \
    && pass ".env rewritten in place (owner and mode stay)" || fail ".env was replaced or its mode changed"

# ── 3. logs ───────────────────────────────────────────────────
echo "-- _laravel_logs_unify_dir"
eval "$(sed -n '/^_laravel_logs_unify_dir()/,/^}/p' "${LIB}/common.sh")"
mklogs() {
    rm -rf "${TMP}/logs"; mkdir -p "${TMP}/logs"; L="${TMP}/logs"
    : > "${L}/laravel-2026-08-27.log";          printf 'A\n'  > "${L}/laravel-2026-08-27.log.1"
    printf 'B1\n' | gzip > "${L}/laravel-2026-09-05.log.2.gz"
    printf 'B2\n' > "${L}/laravel-2026-09-05.log.1"; printf 'B3' > "${L}/laravel-2026-09-05.log"
    printf 'C\n'  > "${L}/laravel-2026-09-24.log"
    printf 'other\n' > "${L}/worker.log"
}
mklogs
n=$(_laravel_logs_unify_dir "$L")
[[ "$n" == "6" ]] && pass "six dated files folded in" || fail "folded ${n} files, expected 6"
[[ "$(cat "${L}/laravel.log")" == $'A\nB1\nB2\nB3\nC' ]] \
    && pass "laravel.log holds the history oldest first, rotations before their day's file" \
    || fail "wrong order/content: $(tr '\n' '|' < "${L}/laravel.log")"
[[ "$(cd "$L" && ls -A | tr '\n' ' ')" == "laravel.log worker.log " ]] \
    && pass "dated files, stubs and the work file are gone; other logs untouched" || fail "left behind: $(cd "$L" && ls -A | tr '\n' ' ')"
[[ "$(_laravel_logs_unify_dir "$L")" == "0" && "$(cat "${L}/laravel.log")" == $'A\nB1\nB2\nB3\nC' ]] \
    && pass "a second run changes nothing" || fail "second run changed laravel.log"

mklogs; printf 'X\n' > "${L}/laravel.log"; ino=$(ls -i "${L}/laravel.log" | awk '{print $1}')
_laravel_logs_unify_dir "$L" >/dev/null
[[ "$(cat "${L}/laravel.log")" == $'X\nA\nB1\nB2\nB3\nC' && "$(ls -i "${L}/laravel.log" | awk '{print $1}')" == "$ino" ]] \
    && pass "an existing laravel.log is appended to, never replaced" || fail "existing laravel.log replaced or wrong: $(tr '\n' '|' < "${L}/laravel.log")"

mklogs
n=$(_laravel_logs_unify_dir "$L" laravel-2026-09-24.log)
[[ "$n" == "5" && "$(cat "${L}/laravel-2026-09-24.log")" == "C" && "$(cat "${L}/laravel.log")" == $'A\nB1\nB2\nB3' ]] \
    && pass "a file named as still open is left in place" || fail "open file not left alone (n=${n})"

mklogs; printf 'not gzip' > "${L}/laravel-2026-09-05.log.2.gz"
n=$(_laravel_logs_unify_dir "$L")
[[ "$n" == "5" && -f "${L}/laravel-2026-09-05.log.2.gz" && "$(cat "${L}/laravel.log")" == $'A\nB2\nB3\nC' ]] \
    && pass "an unreadable archive stays, the rest is folded in" || fail "corrupt archive handled wrong (n=${n})"

rm -rf "${TMP}/logs"; mkdir -p "${TMP}/logs"; : > "${TMP}/logs/laravel-2026-08-27.log"; printf 'keep\n' > "${TMP}/logs/laravel-notes.log"
n=$(_laravel_logs_unify_dir "${TMP}/logs")
[[ "$n" == "1" && ! -e "${TMP}/logs/laravel.log" && -f "${TMP}/logs/laravel-notes.log" ]] \
    && pass "only empty stubs: removed, no empty laravel.log created" || fail "empty stubs handled wrong (n=${n})"
grep -q 'sudo -u "\$app" bash -c' "${LIB}/common.sh" \
    && pass "laravel_logs_unify runs as the app user" || fail "laravel_logs_unify does not drop to the app user"

# ── 4. migration, end to end ──────────────────────────────────
echo "-- migration 5.4.2"
S="${TMP}/srv"
mkdir -p "${S}/bin" "${S}/lib" "${S}/etc/cipi" "${S}/logrotate.d"
cat > "${S}/etc/cipi/apps.json" <<'EOF'
{"shop":{"php":"8.4"},"shop2":{"php":"8.4"},"blog":{"php":"8.3"},"fast":{"php":"8.5","octane":"frankenphp"},
 "plain":{"php":"8.4","custom":"true"},"front":{"php":"8.4","runtime":"node"}}
EOF
mkapp() {   # <app> <LOG_CHANNEL> [cached]
    mkdir -p "${S}/home/$1/shared/storage/logs" "${S}/home/$1/current/bootstrap/cache"
    printf 'APP_ENV=production\nLOG_CHANNEL=%s\nLOG_LEVEL=error\n' "$2" > "${S}/home/$1/shared/.env"
    [[ "${3:-}" == cached ]] && : > "${S}/home/$1/current/bootstrap/cache/config.php"
    return 0
}
mkapp shop daily cached; mkapp shop2 single; mkapp blog daily; mkapp fast daily cached; mkapp plain daily; mkapp front daily
: > "${S}/home/shop/shared/storage/logs/laravel-2026-08-27.log"
printf 'old\n' > "${S}/home/shop/shared/storage/logs/laravel-2026-08-27.log.1"
printf 'new\n' > "${S}/home/shop/shared/storage/logs/laravel-2026-09-24.log"
printf 'left\n' > "${S}/home/shop2/shared/storage/logs/laravel-2026-09-01.log.1"
printf 'custom\n' > "${S}/home/plain/shared/storage/logs/laravel-2026-09-01.log.1"

{
    echo 'vault_read() { cat "${CIPI_CONFIG}/$1"; }'
    echo '_cipi_run_timed() { shift; "$@"; }'
    echo 'ensure_app_logs_permissions() { echo "$1" >> "${CIPI_TEST_CALLS}/perms"; }'
    sed -n '/^laravel_env_single_log()/,/^}/p; /^_laravel_logs_unify_dir()/,/^}/p; /^laravel_logs_unify()/,/^}/p' "${LIB}/common.sh" \
        | sed "s#\"/home/#\"${S}/home/#g"
} > "${S}/lib/common.sh"
sed -e "s#\"/home/#\"${S}/home/#g" -e "s#/etc/logrotate.d#${S}/logrotate.d#g" -e "s#\"/usr/bin/php#\"${S}/bin/php#g" \
    "${LIB}/migrations/5.4.2.sh" > "${S}/migration.sh"

cat > "${S}/bin/sudo" <<'EOF'
#!/bin/bash
[[ "$1" == "-u" ]] && shift 2
exec "$@"
EOF
cat > "${S}/bin/id" <<EOF
#!/bin/bash
[[ -d "${S}/home/\$1" ]]
EOF
for v in 8.3 8.4 8.5; do
    printf '#!/bin/bash\necho "php%s $*" >> "%s/calls/php"\n' "$v" "$S" > "${S}/bin/php${v}"
done
cat > "${S}/bin/supervisorctl" <<EOF
#!/bin/bash
if [[ "\$1" == status ]]; then
    echo "shop-worker-default:shop-worker-default_00   RUNNING   pid 11, uptime 1:00:00"
    echo "shop-horizon                                 STOPPED   Not started"
    echo "shop2-worker-default:shop2-worker-default_00 RUNNING   pid 12, uptime 1:00:00"
    echo "fast-octane                                  RUNNING   pid 13, uptime 1:00:00"
    exit 3
fi
echo "\$*" >> "${S}/calls/supervisorctl"
EOF
cat > "${S}/bin/systemctl" <<EOF
#!/bin/bash
[[ "\$1" == is-active ]] && exit 0
echo "\$*" >> "${S}/calls/systemctl"
EOF
chmod +x "${S}/bin/"*
runmig() {
    rm -rf "${S}/calls"; mkdir -p "${S}/calls"
    PATH="${S}/bin:${PATH}" CIPI_LIB="${S}/lib" CIPI_CONFIG="${S}/etc/cipi" CIPI_LOG="${S}/log" CIPI_TEST_CALLS="${S}/calls" \
        bash "${S}/migration.sh" 2>&1
}
out=$(runmig); rc=$?
[[ $rc -eq 0 ]] && grep -q 'Migration 5.4.2 complete' <<< "$out" && pass "migration runs to the end" || fail "migration failed (rc=${rc}): ${out}"
envof() { grep '^LOG_CHANNEL=' "${S}/home/$1/shared/.env"; }
[[ "$(envof shop)" == "LOG_CHANNEL=single" && "$(envof blog)" == "LOG_CHANNEL=single" && "$(envof fast)" == "LOG_CHANNEL=single" ]] \
    && pass "Laravel apps switched to single" || fail "Laravel .env not switched"
[[ "$(envof plain)" == "LOG_CHANNEL=daily" && "$(envof front)" == "LOG_CHANNEL=daily" ]] \
    && pass "custom and Node apps are not touched" || fail "custom/Node .env changed"
[[ -f "${S}/home/plain/shared/storage/logs/laravel-2026-09-01.log.1" ]] \
    && pass "custom app logs are not touched" || fail "custom app logs were folded"
[[ "$(sort "${S}/calls/php")" == $'php8.4 '"${S}"$'/home/shop/current/artisan config:cache\nphp8.5 '"${S}"'/home/fast/current/artisan config:cache' ]] \
    && pass "config cache rebuilt only where the release has one" || fail "config:cache calls: $(tr '\n' '|' < "${S}/calls/php")"
[[ "$(sort "${S}/calls/supervisorctl")" == $'signal TERM fast-octane\nsignal TERM shop-worker-default:shop-worker-default_00' ]] \
    && pass "SIGTERM to running programs of switched apps only (stopped ones and shop2 left alone)" \
    || fail "supervisorctl calls: $(tr '\n' '|' < "${S}/calls/supervisorctl")"
[[ "$(sort "${S}/calls/systemctl")" == $'reload php8.3-fpm\nreload php8.4-fpm' ]] \
    && pass "PHP-FPM reloaded once per version, not for the Octane app" || fail "systemctl calls: $(tr '\n' '|' < "${S}/calls/systemctl")"
[[ "$(cat "${S}/home/shop/shared/storage/logs/laravel.log")" == $'old\nnew' && "$(ls "${S}/home/shop/shared/storage/logs")" == "laravel.log" ]] \
    && pass "dated logs folded into laravel.log" || fail "shop logs: $(ls "${S}/home/shop/shared/storage/logs" | tr '\n' ' ')"
[[ "$(cat "${S}/home/shop2/shared/storage/logs/laravel.log" 2>/dev/null)" == "left" ]] \
    && pass "an app already on single still gets its leftovers folded in" || fail "shop2 leftovers not folded"
grep -q '\*\[!0-9\]\.log' "${S}/logrotate.d/cipi-app-logs" && pass "logrotate rule rewritten" || fail "logrotate rule not written"
out=$(runmig); rc=$?
[[ $rc -eq 0 && ! -e "${S}/calls/php" && ! -e "${S}/calls/supervisorctl" && ! -e "${S}/calls/systemctl" ]] \
    && [[ "$(cat "${S}/home/shop/shared/storage/logs/laravel.log")" == $'old\nnew' ]] \
    && pass "a second run restarts nothing and changes nothing" || fail "second run not idempotent: ${out}"
grep -q 'cipi-worker' <<< "$(grep -v '^#' "${LIB}/migrations/5.4.2.sh")" \
    && fail "migration calls cipi-worker (refuses when logname is not root)" || pass "migration does not go through cipi-worker"

# ── 5. cipi firewall attempts ─────────────────────────────────
echo "-- cipi firewall attempts"
F="${TMP}/f2b"
mkdir -p "${F}/bin"
DROP="${F}/jail.d/cipi-attempts.local"
cat > "${F}/bin/fail2ban-client" <<EOF
#!/bin/bash
case "\$1" in
    -t)     [[ ! -e "${F}/reject" ]] ;;
    reload) echo reload >> "${F}/calls"
            sed -n 's/^maxretry = //p' "${DROP}" 2>/dev/null > "${F}/live"
            [[ -s "${F}/live" ]] || echo 3 > "${F}/live" ;;
    get)    case "\$3" in maxretry) cat "${F}/live" ;; findtime) echo 3600 ;; bantime) echo 86400 ;; esac ;;
esac
EOF
cat > "${F}/bin/systemctl" <<EOF
#!/bin/bash
[[ "\$1" == is-active ]] && { [[ -e "${F}/running" ]]; exit; }
exit 0
EOF
chmod +x "${F}/bin/"*
echo 3 > "${F}/live"; : > "${F}/running"
fw() {
    PATH="${F}/bin:${PATH}" FIREWALL_F2B_ATTEMPTS="$DROP" CIPI_TEST_F="$F" bash -c '
        set -euo pipefail
        BOLD=""; CYAN=""; DIM=""; NC=""; YELLOW=""
        error() { echo "ERROR: $*" >&2; }; warn() { echo "WARN: $*"; }; success() { echo "OK: $*"; }
        log_action() { echo "$*" >> "${CIPI_TEST_F}/log"; }
        source "$0"; firewall_command "$@"' "${LIB}/firewall.sh" "$@" 2>&1
}
out=$(fw attempts); rc=$?
[[ $rc -eq 0 ]] && grep -q 'Failed logins → ban *3 (default)' <<< "$out" && grep -q 'Counted over *1h' <<< "$out" && grep -q 'Ban *1d' <<< "$out" \
    && pass "no drop-in: shows 3 (default), 1h window, 1d ban" || fail "default state not shown (rc=${rc}): ${out}"
[[ ! -e "$DROP" ]] && pass "showing the value writes nothing" || fail "show created the drop-in"

out=$(fw attempts 5); rc=$?
[[ $rc -eq 0 && "$(grep -v '^#' "$DROP")" == $'[sshd]\nmaxretry = 5' && "$(cat "${F}/calls")" == "reload" && "$(cat "${F}/live")" == "5" ]] \
    && pass "attempts 5: sshd drop-in written, fail2ban reloaded" || fail "attempts 5 (rc=${rc}): ${out}"
[[ "$DROP" == *.local && "$(basename "$(dirname "$DROP")")" == "jail.d" ]] && grep -q 'jail.d/cipi-attempts.local"' "${LIB}/firewall.sh" \
    && pass "drop-in is a jail.d/*.local (read after jail.local)" || fail "drop-in would not override jail.local"
grep -q '^firewall attempts 5$' "${F}/log" && pass "change is logged" || fail "change not logged"
out=$(fw attempts)
grep -q 'Failed logins → ban *5 (set with cipi firewall attempts; default 3)' <<< "$out" \
    && pass "shows the custom value and the default" || fail "custom value not shown: ${out}"

for bad in 0 101 abc 5x -1 1000 "3 4"; do
    out=$(fw attempts "$bad"); rc=$?
    [[ $rc -eq 1 && "$(sed -n 's/^maxretry = //p' "$DROP")" == "5" ]] || fail "accepted '${bad}' (rc=${rc})"
done
pass "rejects 0, 101, abc, 5x, -1, 1000 and '3 4' without touching the value"

: > "${F}/reject"
out=$(fw attempts 7); rc=$?
[[ $rc -eq 1 && "$(sed -n 's/^maxretry = //p' "$DROP")" == "5" ]] \
    && pass "configuration refused by fail2ban: previous value put back" || fail "no rollback (rc=${rc}): $(cat "$DROP")"
rm -f "$DROP"
out=$(fw attempts 7); rc=$?
[[ $rc -eq 1 && ! -e "$DROP" ]] && pass "configuration refused with no previous value: drop-in removed" || fail "refused config left a drop-in"
rm -f "${F}/reject"

fw attempts 8 >/dev/null
out=$(fw attempts default); rc=$?
[[ $rc -eq 0 && ! -e "$DROP" && "$(cat "${F}/live")" == "3" ]] && grep -q 'default: 3' <<< "$out" \
    && pass "attempts default: drop-in removed, back to 3" || fail "default not restored (rc=${rc}): ${out}"

rm -f "${F}/running" "${F}/calls"
out=$(fw attempts 4); rc=$?
[[ $rc -eq 0 && "$(sed -n 's/^maxretry = //p' "$DROP")" == "4" && ! -e "${F}/calls" ]] && grep -q 'WARN: fail2ban is not running' <<< "$out" \
    && pass "fail2ban stopped: value saved, no reload, warning" || fail "stopped fail2ban handled wrong (rc=${rc}): ${out}"
out=$(fw attempts)
grep -q 'Failed logins → ban *4' <<< "$out" && grep -q 'fail2ban is not running' <<< "$out" \
    && pass "fail2ban stopped: shows the saved value and says so" || fail "stopped state not shown: ${out}"
: > "${F}/running"
out=$(fw attempts 1)
grep -q 'WARN: One mistyped password' <<< "$out" && pass "attempts 1 warns about locking yourself out" || fail "no warning for 1"
out=$(fw nope); rc=$?
[[ $rc -eq 1 ]] && grep -q 'allow deny list attempts' <<< "$out" && pass "unknown subcommand lists attempts" || fail "usage does not list attempts"

grep -q '^maxretry = 3$' "${ROOT}/setup.sh" && grep -q 'FIREWALL_ATTEMPTS_DEFAULT=3' "${LIB}/firewall.sh" \
    && pass "default in firewall.sh matches setup.sh's jail.local (3)" || fail "default out of step with setup.sh"
grep -q 'cipi firewall attempts' "${ROOT}/cipi" && grep -q 'sub="allow list attempts"' "${LIB}/completion.sh" \
    && pass "help and completion know attempts" || fail "help or completion omit attempts"
grep -q 'cipi-attempts.local' "${LIB}/compliance.sh" && pass "compliance evidence includes the drop-in" || fail "compliance evidence omits the drop-in"

# ── 6. installer requirements ─────────────────────────────────
echo "-- setup.sh requirements"
R="${TMP}/req"
mkdir -p "${R}/bin"
cat > "${R}/bin/systemd-detect-virt" <<EOF
#!/bin/bash
v=\$(cat "${R}/sdv" 2>/dev/null || echo none)
echo "\$v"; [[ "\$v" != none ]]
EOF
chmod +x "${R}/bin/systemd-detect-virt"
{
    echo 'RED=""; GREEN=""; BOLD=""; NC=""'
    echo 'step_msg() { :; }; id() { echo 0; }'
    sed -n '/^detect_container()/,/^}/p; /^check_requirements()/,/^}/p' "${ROOT}/setup.sh" \
        | sed -e "s#/\\.dockerenv#${R}/root/.dockerenv#g" -e "s#/run/#${R}/root/run/#g" \
              -e "s#/proc/#${R}/root/proc/#g" -e "s#/etc/os-release#${R}/root/etc/os-release#g"
} > "${R}/req.sh"
newroot() {   # <ubuntu version> [systemd-detect-virt answer]
    rm -rf "${R}/root"; mkdir -p "${R}/root/etc" "${R}/root/run" "${R}/root/proc/sys/kernel" "${R}/root/proc/1"
    printf 'ID=ubuntu\nVERSION_ID="%s"\n' "$1" > "${R}/root/etc/os-release"
    echo "6.8.0-45-generic" > "${R}/root/proc/sys/kernel/osrelease"
    printf 'HOME=/\0TERM=linux\0' > "${R}/root/proc/1/environ"
    echo "${2:-none}" > "${R}/sdv"
}
req() { PATH="${R}/bin:${PATH}" bash -c 'set -e; set -o pipefail; source "$0"; "$@"' "${R}/req.sh" "$@" 2>&1; }
virt() { [[ "$(req detect_container)" == "$1" ]] && pass "$2" || fail "$2 (got '$(req detect_container)')"; }

newroot 24.04;                                              virt ""        "full VM or bare metal: nothing detected"
newroot 24.04 lxc;                                          virt "lxc"     "systemd-detect-virt answer is used (lxc)"
newroot 24.04 openvz;                                       virt "openvz"  "systemd-detect-virt answer is used (openvz)"
newroot 24.04; : > "${R}/root/.dockerenv";                  virt "docker"  "/.dockerenv without systemd: docker"
newroot 24.04; : > "${R}/root/run/.containerenv";           virt "podman"  "/run/.containerenv: podman"
newroot 24.04; echo "5.15.153.1-microsoft-standard-WSL2" > "${R}/root/proc/sys/kernel/osrelease"; virt "wsl" "Microsoft kernel: wsl"
newroot 24.04; echo "6.12.9-orbstack-00297" > "${R}/root/proc/sys/kernel/osrelease";               virt "orbstack" "OrbStack kernel: orbstack"
newroot 24.04; mkdir "${R}/root/proc/vz";                   virt "openvz"  "/proc/vz without /proc/bc: openvz"
newroot 24.04; mkdir "${R}/root/proc/vz" "${R}/root/proc/bc"; virt ""      "/proc/vz with /proc/bc is the OpenVZ host, not a container"
newroot 24.04; printf 'HOME=/\0container=lxc\0' > "${R}/root/proc/1/environ"; virt "lxc" "container= in PID 1's environment"
newroot 24.04; echo "6.8.0-1017-azure" > "${R}/root/proc/sys/kernel/osrelease"; virt "" "a Hyper-V/Azure VM is not taken for WSL"

newroot 24.04; : > "${R}/root/.dockerenv"
out=$(req check_requirements); rc=$?
[[ $rc -eq 1 ]] && grep -q 'this is a Docker container, not a full server' <<< "$out" && grep -q 'KVM' <<< "$out" \
    && ! grep -q 'requires Ubuntu' <<< "$out" \
    && pass "Docker: specific error with what to use instead, no version error" || fail "Docker error wrong (rc=${rc}): ${out}"
newroot 22.04 lxc
out=$(req check_requirements); rc=$?
[[ $rc -eq 1 ]] && grep -q 'an LXC container (LXD, Incus, Proxmox CT)' <<< "$out" && ! grep -q 'requires Ubuntu' <<< "$out" \
    && pass "LXC on an old release: the container is reported, not the version" || fail "LXC error wrong (rc=${rc}): ${out}"
newroot 24.04 openvz
grep -q 'an OpenVZ / Virtuozzo container' <<< "$(req check_requirements)" && pass "OpenVZ named in the error" || fail "OpenVZ not named"
newroot 24.04 rkt
grep -q 'a container (rkt)' <<< "$(req check_requirements)" && pass "an unknown container type is still named" || fail "unknown container type not named"
for v in 24.04 24.10 26.04; do
    newroot "$v"; out=$(req check_requirements); rc=$?
    [[ $rc -eq 0 ]] && grep -q "Ubuntu ${v}" <<< "$out" && pass "Ubuntu ${v} on a full VM passes" || fail "Ubuntu ${v} rejected (rc=${rc}): ${out}"
done
newroot 22.04; out=$(req check_requirements); rc=$?
[[ $rc -eq 1 ]] && grep -q 'requires Ubuntu 24.04+ (found: 22.04)' <<< "$out" && pass "Ubuntu 22.04 on a full VM: version error" || fail "22.04 not rejected (rc=${rc}): ${out}"
sed -n '/^check_requirements()/,/^}/p' "${ROOT}/setup.sh" | grep -v '^ *#' | grep -qw 'bc' \
    && fail "version check still needs bc (not installed yet at that point)" || pass "version check does not need bc"

# ── 7. cipi disk ──────────────────────────────────────────────
echo "-- cipi disk"
D="${TMP}/disk"
mkdir -p "${D}/bin" "${D}/etc"
cat > "${D}/etc/apps.json" <<'EOF'
{"shop":{"php":"8.4"},"blog":{"php":"8.4","engine":"pgsql"},"front":{"runtime":"node"}}
EOF
cat > "${D}/bin/df" <<'EOF'
#!/bin/bash
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/vda1 104857600 41943040 62914560 40% /"
[[ "$*" == *"-x tmpfs"* ]] && echo "/dev/vda15 106496 6144 100352 6% /boot/efi"
exit 0
EOF
cat > "${D}/bin/du" <<'EOF'
#!/bin/bash
case "${@: -1}" in
    /home/shop)          echo "2097152 x" ;;
    /home/blog)          echo "524288 x" ;;
    /home/front)         echo "104858 x" ;;
    /var/lib/mysql/shop) echo "1048576 x" ;;
    *) exit 1 ;;
esac
EOF
chmod +x "${D}/bin/"*
dk() {
    PATH="${D}/bin:${PATH}" CIPI_CONFIG="${D}/etc" CIPI_LIB="$LIB" bash -c '
        set -euo pipefail
        BOLD=""; CYAN=""; DIM=""; NC=""; YELLOW=""; GREEN=""; RED=""
        error() { echo "ERROR: $*" >&2; }
        vault_read() { cat "${CIPI_CONFIG}/$1"; }
        source "$0"
        _disk_pgsql_sizes() { echo "postgres|7000"; echo "blog|524288"; }
        disk_command "$@"' "${LIB}/disk.sh" "$@" 2>&1
}
out=$(dk); rc=$?
[[ $rc -eq 0 ]] && pass "cipi disk runs" || fail "cipi disk failed (rc=${rc}): ${out}"
sq() { tr -s ' ' <<< "$out"; }
grep -q '^ / 100.00 GB 40.00 GB 60.00 GB 40%$' <<< "$(sq)" && grep -q '^ /boot/efi 0.10 GB' <<< "$(sq)" \
    && pass "server section: every filesystem with size, used and free in GB and use %" || fail "server section wrong: ${out}"
grep -q '^ shop 2.00 GB 1.00 GB 3.00 GB 3.0% —$' <<< "$(sq)" \
    && pass "app row: files + MariaDB database, total in GB and % of the disk" || fail "shop row wrong: ${out}"
grep -q '^ blog 0.50 GB 0.50 GB 1.00 GB 1.0% —$' <<< "$(sq)" \
    && pass "PostgreSQL app: database size from pg_database_size" || fail "blog row wrong: ${out}"
grep -q '^ front 0.10 GB 0.00 GB 0.10 GB 0.1% —$' <<< "$(sq)" \
    && pass "app without a database: files only" || fail "front row wrong: ${out}"
[[ "$(grep -nE '^ (shop|blog|front) ' <<< "$(sq)" | cut -d' ' -f2 | tr '\n' ' ')" == "shop blog front " ]] \
    && pass "apps listed largest first" || fail "apps not sorted by size"
grep -q '^ All apps 4.10 GB 4.1%$' <<< "$(sq)" && grep -q '^ Everything else 35.90 GB 35.9%$' <<< "$(sq)" \
    && pass "totals: all apps, and everything else on the disk" || fail "totals wrong: ${out}"
out=$(dk --json); rc=$?
[[ $rc -eq 0 ]] && jq -e '.disk == {mount:"/",size_gb:100,used_gb:40,free_gb:60,used_percent:40}
        and (.apps | map(.app)) == ["shop","blog","front"]
        and .apps[0] == {app:"shop",files_gb:2,database_gb:1,total_gb:3,percent:3,limit_gb:null,limit_percent:null,over_limit:false}
        and .apps_total_gb == 4.1 and .apps_percent == 4.1 and .other_gb == 35.9 and .other_percent == 35.9' <<< "$out" >/dev/null \
    && pass "--json: same figures, machine-readable" || fail "--json wrong (rc=${rc}): ${out}"
! grep -q 'over the limit' <<< "$out" && pass "no limit set anywhere by default: nobody is flagged" || fail "an app is flagged without a limit"

# soft limits: shop 2 GB (uses 3), blog 1.05 GB (uses 1.00 → 95%), front 5 GB (uses 0.10)
cat > "${D}/etc/apps.json" <<'EOF'
{"shop":{"php":"8.4","disk_limit_gb":2},"blog":{"php":"8.4","engine":"pgsql","disk_limit_gb":1.05},"front":{"runtime":"node","disk_limit_gb":5}}
EOF
out=$(dk); rc=$?
[[ $rc -eq 0 ]] && grep -q '^ shop .* 3.0% 2 GB (150%) over$' <<< "$(sq)" && grep -q '^ blog .* 1.0% 1.05 GB (95%)$' <<< "$(sq)" \
    && grep -q '^ front .* 0.1% 5 GB (2%)$' <<< "$(sq)" && grep -q '1 app(s) over the limit' <<< "$out" \
    && pass "LIMIT column: limit, % of it used, and who is over" || fail "limit column wrong (rc=${rc}): ${out}"
out=$(dk --json)
jq -e '(.apps | map({(.app): [.limit_gb, .limit_percent, .over_limit]}) | add)
        == {shop: [2,150,true], blog: [1.05,95,false], front: [5,2,false]}' <<< "$out" >/dev/null \
    && pass "--json: limit_gb, limit_percent, over_limit" || fail "--json limits wrong: ${out}"

echo '{}' > "${D}/etc/apps.json"
out=$(dk); rc=$?
[[ $rc -eq 0 ]] && grep -q 'No apps yet' <<< "$out" && grep -q 'Everything else *40.00 GB *40.0%' <<< "$out" \
    && pass "no apps: server figures only" || fail "empty server wrong (rc=${rc}): ${out}"
out=$(dk --nope); rc=$?
[[ $rc -eq 1 ]] && grep -q 'Usage: cipi disk' <<< "$out" && pass "unknown option rejected" || fail "unknown option accepted"
grep -qE '^[[:space:]]+disk\)' "${ROOT}/cipi" && grep -q 'source "${CIPI_LIB}/disk.sh"' "${ROOT}/cipi" && grep -q '"cipi disk' "${ROOT}/cipi" \
    && pass "cipi dispatches disk and help lists it" || fail "disk not wired into cipi"

# ── 7b. cipi app limits --disk ────────────────────────────────
echo "-- cipi app limits --disk"
al() {   # <app> <value>: runs _app_disk_limit_set with recorders in place of the vault
    : > "${D}/vault.log"
    PATH="${D}/bin:${PATH}" CIPI_LIB="$LIB" CIPI_CONFIG="${D}/etc" D="$D" bash -c '
        set -euo pipefail
        BOLD=""; CYAN=""; DIM=""; NC=""; YELLOW=""; GREEN=""; RED=""
        error() { echo "ERROR: $*" >&2; }; warn() { echo "WARN: $*"; }; info() { echo "INFO: $*"; }; success() { echo "OK: $*"; }
        log_action() { :; }
        app_set_json() { echo "set $*" >> "$D/vault.log"; }
        app_unset() { echo "unset $*" >> "$D/vault.log"; }
        app_get() { echo ""; }
        vault_read() { return 1; }
        eval "$(sed -n "/^_app_disk_limit_set()/,/^}/p" "$0")"
        _app_disk_limit_set "$@"' "${LIB}/app.sh" "$@" 2>&1
}
out=$(al shop 10); rc=$?
[[ $rc -eq 0 && "$(cat "${D}/vault.log")" == "set shop disk_limit_gb 10" ]] && grep -q 'INFO: It uses 3.00 GB now (30%)' <<< "$out" \
    && pass "--disk=10: stored, current usage reported" || fail "--disk=10 wrong (rc=${rc}): ${out} / $(cat "${D}/vault.log")"
out=$(al shop 2.50); rc=$?
[[ $rc -eq 0 && "$(cat "${D}/vault.log")" == "set shop disk_limit_gb 2.5" ]] && grep -q 'WARN: It already uses 3.00 GB (120%)' <<< "$out" \
    && pass "--disk=2.50: stored as 2.5, warns that the app is already over" || fail "--disk=2.50 wrong (rc=${rc}): ${out}"
al shop 010 >/dev/null
[[ "$(cat "${D}/vault.log")" == "set shop disk_limit_gb 10" ]] && pass "--disk=010 stored as a plain number" || fail "010 stored as $(cat "${D}/vault.log")"
for v in none off 0; do
    out=$(al shop "$v"); rc=$?
    [[ $rc -eq 0 && "$(cat "${D}/vault.log")" == "unset shop disk_limit_gb" ]] || fail "--disk=${v} did not remove the limit (rc=${rc})"
done
pass "--disk=none|off|0 removes the limit"
for v in abc -5 1.234 10GB 0.00 true ""; do
    out=$(al shop "$v"); rc=$?
    [[ $rc -eq 1 && ! -s "${D}/vault.log" ]] || fail "--disk='${v}' accepted (rc=${rc})"
done
pass "rejects abc, -5, 1.234, 10GB, 0.00, true and an empty value"
body=$(sed -n '/^app_limits()/,/^}/p' "${LIB}/app.sh")
[[ "$(grep -n '_app_disk_limit_set' <<< "$body" | head -1 | cut -d: -f1)" -lt "$(grep -n '_create_fpm_pool' <<< "$body" | head -1 | cut -d: -f1)" ]] \
    && grep -q '\[\[ "$disk_changed" == true \]\] && return 0' <<< "$body" \
    && pass "a disk limit alone does not rebuild FPM pools or restart workers" || fail "disk limit goes through the FPM/worker rebuild"
grep -q 'disk_limit_gb' "${LIB}/yml.sh" && fail "cipi.yml can set the disk limit (an app repo must not)" || pass "the limit is not settable from cipi.yml"

# ── 7c. monitor: whole disk and app limits ────────────────────
echo "-- monitor alerts: server disk and app disk limits"
M="${TMP}/mon"
mkdir -p "${M}/bin" "${M}/etc" "${M}/log"
cat > "${M}/bin/df" <<EOF
#!/bin/bash
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/vda1 104857600 0 0 \$(cat "${M}/pct")% /"
EOF
cat > "${M}/bin/du" <<EOF
#!/bin/bash
echo x >> "${M}/du.calls"
case "\${@: -1}" in
    /home/shop) cat "${M}/shop.kb" ;;
    /home/blog) echo "524288 x" ;;
    *) exit 1 ;;
esac
EOF
chmod +x "${M}/bin/"*
cat > "${M}/etc/monitor.json" <<'EOF'
{"checks":{"ssl":{"enabled":false},"services":{"enabled":false},"workers":{"enabled":false},
           "http_5xx":{"enabled":false},"fs":{"enabled":false},"load":{"enabled":false}}}
EOF
echo '{"shop":{"php":"8.4"},"blog":{"php":"8.4"}}' > "${M}/etc/apps.json"
echo 40 > "${M}/pct"; echo "2097152 x" > "${M}/shop.kb"
mon() {   # [fresh]: one monitor run with alerts on; prints the notifications it sent
    : > "${M}/sent"
    PATH="${M}/bin:${PATH}" CIPI_LIB="$LIB" CIPI_CONFIG="${M}/etc" CIPI_LOG="${M}/log" M="$M" FRESH="${1:-}" bash -c '
        set -euo pipefail
        BOLD=""; CYAN=""; DIM=""; NC=""; YELLOW=""; GREEN=""; RED=""
        vault_read() { cat "${CIPI_CONFIG}/$1"; }
        vault_write() { cat > "${CIPI_CONFIG}/$1"; }
        cipi_notify() { echo "$3 | $1 | $2" >> "$M/sent"; }
        hostname() { echo srv; }
        source "${CIPI_LIB}/monitor.sh"
        [[ "$FRESH" == fresh ]] && _MON_FRESH=true
        _mon_run_all true' 2>&1
    cat "${M}/sent"
}
st() { head -1 <<< "$2" | jq -r --arg c "$1" '.[] | select(.check == $c) | .status'; }
out=$(mon)
[[ "$(st disk "$out")" == "ok" && "$(st app_disk "$out")" == "ok" && ! -s "${M}/sent" ]] \
    && grep -q 'no app has a disk limit' <<< "$out" \
    && pass "40% disk, no app limit (the default): all quiet, nothing measured" || fail "quiet state wrong: ${out}"
[[ ! -e "${M}/du.calls" ]] && pass "no limit set: no du is run" || fail "du ran without any limit"

echo 85 > "${M}/pct"; out=$(mon)
grep -q '^monitor_disk | Cipi monitor \[warn\]: Disk usage on srv | .*/ at 85%' "${M}/sent" \
    && pass "server disk at 85%: warning sent (threshold 80%)" || fail "no warning at 85%: ${out}"
out=$(mon); [[ ! -s "${M}/sent" ]] && pass "still 85%: no repeat on the next run" || fail "alert repeated: $(cat "${M}/sent")"
echo 93 > "${M}/pct"; out=$(mon)
grep -q '^monitor_disk | Cipi monitor \[crit\]: Disk usage on srv' "${M}/sent" \
    && pass "server disk at 93%: escalates to critical (threshold 90%)" || fail "no critical at 93%: ${out}"
echo 50 > "${M}/pct"; out=$(mon)
grep -q '^monitor_ok | Cipi monitor recovered: Disk usage on srv' "${M}/sent" \
    && pass "server disk back to 50%: recovery sent" || fail "no recovery: ${out}"
grep -q '^monitor_disk|' "${LIB}/notifications.sh" && grep -q 'disk:     {enabled: true, warn: 80, crit: 90}' "${LIB}/monitor.sh" \
    && grep -q 'cipi-monitor' "${ROOT}/setup.sh" && grep -q 'cipi-monitor' "${LIB}/self-update.sh" \
    && pass "server disk check is on by default (80/90) and its cron helper ships with setup and self-update" \
    || fail "server disk check not on by default"

# app limits: shop 3 GB (uses 2 → 66%), blog has none
echo '{"shop":{"php":"8.4","disk_limit_gb":3},"blog":{"php":"8.4"}}' > "${M}/etc/apps.json"
rm -f "${M}/du.calls"; out=$(mon)
[[ "$(st app_disk "$out")" == "ok" && ! -s "${M}/sent" ]] && grep -q '1 app(s) with a limit, all below 90%' <<< "$out" \
    && pass "app within its limit: no alert" || fail "within-limit state wrong: ${out}"
[[ "$(wc -l < "${M}/du.calls" | tr -d ' ')" == "2" ]] && pass "only the app with a limit is measured (home + database)" || fail "measured $(wc -l < "${M}/du.calls") trees"
echo "2936013 x" > "${M}/shop.kb"                     # 2.80 GB → 93%
out=$(mon); [[ ! -s "${M}/sent" && "$(wc -l < "${M}/du.calls" | tr -d ' ')" == "2" ]] \
    && pass "cron runs reuse the measurement for 30 minutes (no du every 5 minutes)" || fail "measured again within the interval"
out=$(mon fresh)
grep -q '^monitor_app_disk | Cipi monitor \[warn\]: Disk limit of shop on srv | .*shop uses 2.80 GB of its 3 GB limit (93%)' "${M}/sent" \
    && pass "app at 93% of its limit: warning sent (threshold 90%)" || fail "no app warning: ${out} / $(cat "${M}/sent")"
[[ "$(grep -c . "${M}/sent")" == "1" ]] && pass "one notification per app, none for the check as a whole" || fail "sent $(grep -c . "${M}/sent") notifications"
echo "3670016 x" > "${M}/shop.kb"                     # 3.50 GB → 116%
out=$(mon fresh)
grep -q '^monitor_app_disk | Cipi monitor \[crit\]: Disk limit of shop on srv | .*of its 3 GB limit (116%)' "${M}/sent" \
    && grep -q 'Nothing is blocked' "${M}/sent" && [[ "$(st app_disk "$out")" == "crit" ]] \
    && pass "app over its limit: critical alert, and it says nothing is blocked" || fail "no over-limit alert: ${out}"
echo '{"shop":{"php":"8.4","disk_limit_gb":3},"blog":{"php":"8.4","disk_limit_gb":0.25}}' > "${M}/etc/apps.json"
out=$(mon fresh)
[[ "$(grep -c . "${M}/sent")" == "1" ]] && grep -q 'Disk limit of blog on srv' "${M}/sent" \
    && pass "a second app going over alerts on its own while the first is still over" || fail "second app hidden: $(cat "${M}/sent")"
echo "1048576 x" > "${M}/shop.kb"
out=$(mon fresh)
grep -q '^monitor_ok | Cipi monitor recovered: Disk limit of shop on srv' "${M}/sent" \
    && pass "app back under its limit: recovery sent" || fail "no app recovery: $(cat "${M}/sent")"
echo '{"shop":{"php":"8.4"},"blog":{"php":"8.4"}}' > "${M}/etc/apps.json"
out=$(mon fresh)
[[ ! -s "${M}/sent" && "$(st app_disk "$out")" == "ok" ]] && ! ls "${M}/log/monitor/" | grep -q '^app_disk_' \
    && pass "limit removed: alert state dropped, no further messages" || fail "state left after removing limits: $(ls "${M}/log/monitor/")"
grep -q '^monitor_app_disk|' "${LIB}/notifications.sh" && pass "monitor_app_disk is a notification trigger (on by default)" || fail "no monitor_app_disk trigger"

# ── 8. tab-completion ─────────────────────────────────────────
echo "-- tab-completion"
C="${TMP}/comp"
mkdir -p "${C}/bin" "${C}/etc/profile.d" "${C}/etc/bash_completion.d" "${C}/root" "${C}/home/cipi"
bash -c 'source "$0"; _completion_bash_script' "${LIB}/completion.sh" > "${C}/cipi.bash"
bash -n "${C}/cipi.bash" && pass "generated script is valid bash" || fail "generated script does not parse"
cat > "${C}/bin/getent" <<'EOF'
#!/bin/bash
[[ "$1 $2" == "group cipi-apps" ]] && echo "cipi-apps:x:1002:shop,blog,shop2"
exit 0
EOF
chmod +x "${C}/bin/getent"
# comp <prelude> <function> <words…>: what <Tab> offers at the end of the line.
comp() {
    local prelude="$1" fn="$2"; shift 2
    PATH="${C}/bin:${PATH}" bash -c '
        eval "$1"; source "$2"; fn="$3"; shift 3
        COMP_WORDS=("$@"); COMP_CWORD=$(( $# - 1 )); COMPREPLY=()
        $fn; echo "${COMPREPLY[*]}"' _ "$prelude" "${C}/cipi.bash" "$fn" "$@" 2>&1
}
is() { [[ "$1" == "$2" ]] && pass "$3" || fail "$3 (got '$1')"; }
is "$(comp '' _cipi_complete cipi di)" "disk" "cipi di<Tab> → disk"
is "$(comp '' _cipi_complete cipi disk '')" "--json" "cipi disk <Tab> → --json"
is "$(comp '' _cipi_complete cipi app limits shop --d)" "--disk=" "cipi app limits <app> --d<Tab> → --disk="
is "$(comp '' _cipi_complete cipi monitor set app)" "app_disk" "cipi monitor set app<Tab> → app_disk"
is "$(comp '' _cipi_complete cipi app show sh)" "shop shop2" "app names from the cipi-apps group when /etc/cipi is not readable"
is "$(comp '' _cipi_sudo_complete sudo cipi fire)" "firewall" "sudo cipi fire<Tab> without bash-completion"
is "$(comp '' _cipi_sudo_complete sudo cipi deploy b)" "blog" "sudo cipi deploy <Tab> completes app names"
is "$(comp '' _cipi_sudo_complete sudo -u root /usr/local/bin/cipi firewall a)" "allow attempts" "sudo options and a full path are skipped"
is "$(comp '' _cipi_sudo_complete sudo cip | tr ' ' '\n' | grep -cx cipi)" "1" "sudo cip<Tab> offers cipi even though it is root-only"
is "$(comp '' _cipi_sudo_complete sudo ls '')" "" "sudo <other command>: left to file completion"
is "$(comp '' 'complete -p sudo' x)" "complete -o bashdefault -o default -F _cipi_sudo_complete sudo" "no bash-completion: sudo gets the cipi-aware completion"
is "$(comp 'BASH_COMPLETION_VERSINFO=(2 11)' 'complete -p sudo' x 2>&1 | grep -c _cipi_sudo_complete)" "0" "bash-completion loaded: its sudo completion is left alone"
is "$(comp '_command_offset() { COMPREPLY=(delegated); }' _cipi_sudo_complete sudo cipi a)" "delegated" "bash-completion loaded later: sudo completion is handed back to it"
adv=$(sed -n 's/.*local commands="\([^"]*\)".*/\1/p' "${C}/cipi.bash"); miss=""
for v in $adv; do
    [[ "$v" == "help" || "$v" == "completion" ]] && continue
    grep -qE "^[[:space:]]+${v}[)|]" "${ROOT}/cipi" || miss="$miss $v"
done
[[ -z "$miss" && " $adv " == *" disk "* ]] && pass "advertised verbs (incl. disk) all dispatch in cipi" || fail "verbs that do not dispatch:${miss}"

inst() {
    bash -c 'source "$0"
        _CIPI_BASH_COMPLETION="$1/etc/bash_completion.d/cipi"; _CIPI_ZSH_COMPLETION="$1/nozsh/_cipi"
        _CIPI_PROFILE_D="$1/etc/profile.d/cipi-completion.sh"
        getent() { case "$2" in root) echo "root:x:0:0::$C/root:/bin/bash" ;; cipi) echo "cipi:x:1000:1000::$C/home/cipi:/bin/bash" ;; esac; }
        chown() { :; }
        C="$1" _completion_install_system' "${LIB}/completion.sh" "$C"
}
printf 'case $- in *i*) ;; *) return;; esac\nalias ll="ls -al"\n' > "${C}/home/cipi/.bashrc"
inst; inst
[[ -s "${C}/etc/bash_completion.d/cipi" && -s "${C}/etc/profile.d/cipi-completion.sh" ]] \
    && pass "system files written (bash_completion.d, profile.d)" || fail "system files missing"
for rc in "${C}/root/.bashrc" "${C}/home/cipi/.bashrc"; do
    [[ "$(grep -c '^# cipi completion$' "$rc" 2>/dev/null)" == "1" ]] && grep -q 'case \$- in \*i\*) \[ -r /etc/bash_completion.d/cipi \]' "$rc" \
        && pass "${rc#"${C}"}: loader added once, for interactive shells only" || fail "${rc#"${C}"}: loader missing or repeated"
done
grep -q '^alias ll=' "${C}/home/cipi/.bashrc" && pass "existing ~/.bashrc content is kept" || fail "~/.bashrc was overwritten"
grep -q '_completion_install_system' "${ROOT}/setup.sh" && grep -q '_completion_install_system' "${LIB}/self-update.sh" \
    && pass "new servers (setup.sh) and existing ones (self-update) both install it" || fail "setup.sh or self-update does not install completion"

echo "-- docs"
grep -q 'cipi disk' "${ROOT}/README.md" && grep -q 'cipi disk' "${ROOT}/CHANGELOG.md" \
    && pass "README and CHANGELOG document cipi disk" || fail "cipi disk undocumented"
grep -qi 'tab-completion' "${ROOT}/README.md" && grep -q 'sudo cipi' "${ROOT}/CHANGELOG.md" \
    && pass "README and CHANGELOG document tab-completion" || fail "tab-completion undocumented"
grep -q 'OpenVZ' "${ROOT}/README.md" && grep -q 'full virtualization' "${ROOT}/README.md" \
    && pass "README requirements name the virtualization that is supported" || fail "README requirements omit virtualization"
grep -q 'cipi firewall attempts 5' "${ROOT}/README.md" && grep -q 'Failed SSH logins before a ban' "${ROOT}/README.md" \
    && grep -q 'cipi firewall attempts' "${ROOT}/CHANGELOG.md" \
    && pass "README and CHANGELOG document cipi firewall attempts and the default" || fail "cipi firewall attempts undocumented"

echo "=== ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]

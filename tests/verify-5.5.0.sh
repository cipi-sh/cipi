#!/bin/bash
# Local regression checks for 5.5.0 — Laravel apps log to one file
# (LOG_CHANNEL=single), logrotate leaves dated logs alone, and the migration
# switches installed apps and folds their dated logs into laravel.log; and
# `cipi firewall attempts` (fail2ban sshd maxretry); the installer names a
# shared-kernel environment instead of failing the Ubuntu version check;
# `cipi disk`; tab-completion that works behind sudo and in non-login shells;
# `cipi ssh apps` (SSH/SFTP access of app users from outside); and several
# Cloudflare accounts for DNS-01 certificates (`cipi ssl dns`).
# Run from repo root: bash tests/verify-5.5.0.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/lib"
PASS=0
FAIL=0

pass() { echo "  OK: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# Everything below is created, stubbed and removed under $TMP: without it
# those paths would be at the top of the filesystem, so stop here.
TMP=$(mktemp -d) || { echo "mktemp failed" >&2; exit 1; }
[[ -n "$TMP" && -d "$TMP" && "$TMP" != "/" ]] || { echo "no temp directory" >&2; exit 1; }
trap 'rm -rf "${TMP:?}"' EXIT

# A copy of shipped code whose paths were rewritten into $TMP must not keep any
# real one: run as root on a server it would otherwise act on the real thing.
only_test_paths() {   # <file…>  — 0 when no real path is left
    ! grep -nE '"/home/|/etc/logrotate\.d|"/usr/bin/php' "$@"
}

echo "=== Cipi 5.5.0 regression checks ==="

[[ "$(tr -d '[:space:]' < "${ROOT}/version.md")" == "5.5.0" ]] \
    && pass "version.md is 5.5.0" || fail "version.md is not 5.5.0"
grep -q '^## \[5.5.0\]' "${ROOT}/CHANGELOG.md" \
    && pass "CHANGELOG has a 5.5.0 entry" || fail "CHANGELOG has no 5.5.0 entry"
[[ -f "${LIB}/migrations/5.5.0.sh" ]] && pass "5.5.0 migration present" || fail "missing 5.5.0 migration"

echo "-- syntax"
for f in "${ROOT}/cipi" "${ROOT}/setup.sh" "${LIB}/app.sh" "${LIB}/common.sh" "${LIB}/sync.sh" "${LIB}/firewall.sh" "${LIB}/disk.sh" "${LIB}/ssh.sh" "${LIB}/ssl.sh" \
         "${LIB}/monitor.sh" "${LIB}/notifications.sh" \
         "${LIB}/completion.sh" "${LIB}/compliance.sh" "${LIB}/migrations/5.5.0.sh"; do
    bash -n "$f" 2>/dev/null && pass "syntax ${f#"${ROOT}/"}" || { fail "syntax ${f#"${ROOT}/"}"; bash -n "$f"; }
done

# ── 1. defaults ───────────────────────────────────────────────
echo "-- defaults"
grep -q '^LOG_CHANNEL=single$' "${LIB}/app.sh" && ! grep -q '^LOG_CHANNEL=daily' "${LIB}/app.sh" \
    && pass "new Laravel apps get LOG_CHANNEL=single" || fail "app.sh still writes LOG_CHANNEL=daily"
for f in "${ROOT}/setup.sh" "${LIB}/migrations/5.5.0.sh"; do
    grep -q '^/home/\*/shared/storage/logs/\*\[!0-9\]\.log$' "$f" && ! grep -q '^/home/\*/shared/storage/logs/\*\.log$' "$f" \
        && pass "${f#"${ROOT}/"}: logrotate skips logs ending in a date" || fail "${f#"${ROOT}/"}: logrotate still takes *.log"
done
mkdir -p "${TMP}/glob"
touch "${TMP}/glob/laravel.log" "${TMP}/glob/worker.log" "${TMP}/glob/laravel-2026-01-31.log" "${TMP}/glob/laravel-2026-01-31.log.1"
got=$(cd "${TMP}/glob" && echo *[!0-9].log)
[[ "$got" == "laravel.log worker.log" ]] && pass "the pattern matches laravel.log and worker.log only" || fail "pattern matched: ${got}"
[[ "$(grep -c 'laravel_app_env_single_log' "${LIB}/sync.sh")" -eq 2 && "$(grep -c 'laravel_logs_unify' "${LIB}/sync.sh")" -eq 2 ]] \
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
mkdir -p "${TMP}/envdir"
printf 'LOG_CHANNEL=daily\nAPP_KEY=base64:secret\n' > "${TMP}/envdir/.env"; chmod 640 "${TMP}/envdir/.env"
laravel_env_single_log "${TMP}/envdir/.env"
[[ "$(ls -l "${TMP}/envdir/.env" | cut -c1-10)" == "-rw-r-----" && "$(ls -A "${TMP}/envdir")" == ".env" ]] \
    && grep -q '^APP_KEY=base64:secret$' "${TMP}/envdir/.env" \
    && pass ".env replaced through a copy: mode kept, nothing left next to it" || fail "mode changed or a temp file was left: $(ls -lA "${TMP}/envdir")"
if [[ "$(id -u)" != "0" ]]; then
    printf 'LOG_CHANNEL=daily\nAPP_KEY=base64:secret\n' > "${TMP}/envdir/.env"
    chmod 555 "${TMP}/envdir"
    laravel_env_single_log "${TMP}/envdir/.env"; rc=$?
    chmod 755 "${TMP}/envdir"
    [[ $rc -eq 1 && "$(cat "${TMP}/envdir/.env")" == $'LOG_CHANNEL=daily\nAPP_KEY=base64:secret' ]] \
        && pass "the new copy cannot be written: the .env is left exactly as it was" || fail "a failed write damaged the .env (rc=${rc}): $(cat "${TMP}/envdir/.env")"
fi
printf 'LOG_CHANNEL=daily\n' > "${TMP}/envdir/real.env"; ln -s real.env "${TMP}/envdir/link.env"
laravel_env_single_log "${TMP}/envdir/link.env"
[[ -L "${TMP}/envdir/link.env" && "$(cat "${TMP}/envdir/real.env")" == "LOG_CHANNEL=single" ]] \
    && pass "a linked .env stays a link; the file behind it is updated" || fail "linked .env handled wrong: $(ls -lA "${TMP}/envdir")"
body=$(sed -n '/^laravel_env_single_log()/,/^}/p' "${LIB}/common.sh")
grep -q '> "$envf"' <<< "$body" && fail "the .env is still written in place" || pass "the .env is never truncated in place"
grep -q 'sudo -u "$app" bash -c "$(declare -f laravel_env_single_log)' "${LIB}/common.sh" \
    && ! grep -q 'laravel_env_single_log "${home}' "${LIB}/sync.sh" "${LIB}/migrations/5.5.0.sh" \
    && pass "apps' .env files are rewritten as the app user, never as root" || fail "an app .env is rewritten as root"

# ── 3. logs ───────────────────────────────────────────────────
echo "-- _laravel_logs_unify_dir"
eval "$(sed -n '/^_laravel_logs_unify_dir()/,/^}/p' "${LIB}/common.sh")"
mklogs() {
    rm -rf "${TMP:?}/logs"; mkdir -p "${TMP}/logs"; L="${TMP}/logs"
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

rm -rf "${TMP:?}/logs"; mkdir -p "${TMP}/logs"; : > "${TMP}/logs/laravel-2026-08-27.log"; printf 'keep\n' > "${TMP}/logs/laravel-notes.log"
n=$(_laravel_logs_unify_dir "${TMP}/logs")
[[ "$n" == "1" && ! -e "${TMP}/logs/laravel.log" && -f "${TMP}/logs/laravel-notes.log" ]] \
    && pass "only empty stubs: removed, no empty laravel.log created" || fail "empty stubs handled wrong (n=${n})"
grep -q 'sudo -u "\$app" bash -c' "${LIB}/common.sh" \
    && pass "laravel_logs_unify runs as the app user" || fail "laravel_logs_unify does not drop to the app user"

# ── 4. migration, end to end ──────────────────────────────────
echo "-- migration 5.5.0"
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
    sed -n '/^laravel_env_single_log()/,/^}/p; /^laravel_app_env_single_log()/,/^}/p; /^_laravel_logs_unify_dir()/,/^}/p; /^laravel_logs_unify()/,/^}/p' "${LIB}/common.sh" \
        | sed "s#\"/home/#\"${S}/home/#g"
} > "${S}/lib/common.sh"
sed -e "s#\"/home/#\"${S}/home/#g" -e "s#/etc/logrotate.d#${S}/logrotate.d#g" -e "s#\"/usr/bin/php#\"${S}/bin/php#g" \
    "${LIB}/migrations/5.5.0.sh" > "${S}/migration.sh"

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
if only_test_paths "${S}/migration.sh" "${S}/lib/common.sh"; then
    pass "test copy of the migration only touches the test directory"
    MIG_SAFE=true
else
    fail "test copy of the migration still points at real paths — it is not run"
    MIG_SAFE=false
fi
runmig() {
    [[ "$MIG_SAFE" == true ]] || { echo "not run: real paths in the test copy"; return 1; }
    rm -rf "${S:?}/calls"; mkdir -p "${S}/calls"
    PATH="${S}/bin:${PATH}" CIPI_LIB="${S}/lib" CIPI_CONFIG="${S}/etc/cipi" CIPI_LOG="${S}/log" CIPI_TEST_CALLS="${S}/calls" \
        bash "${S}/migration.sh" 2>&1
}
out=$(runmig); rc=$?
[[ $rc -eq 0 ]] && grep -q 'Migration 5.5.0 complete' <<< "$out" && pass "migration runs to the end" || fail "migration failed (rc=${rc}): ${out}"
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
grep -q 'cipi-worker' <<< "$(grep -v '^#' "${LIB}/migrations/5.5.0.sh")" \
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
    rm -rf "${R:?}/root"; mkdir -p "${R}/root/etc" "${R}/root/run" "${R}/root/proc/sys/kernel" "${R}/root/proc/1"
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
mkdir -p "${D}/bin" "${D}/etc" "${D}/lib"
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
    */home/shop)                   echo "2097152 x" ;;
    */home/blog)                   echo "524288 x" ;;
    */home/front)                  echo "104858 x" ;;
    */home/tiny)                   echo "52429 x" ;;
    /var/lib/mysql/shop)           echo "1048576 x" ;;
    /var/lib/mysql/blog)           echo "100 x" ;;
    /var/lib/mysql)                echo "2097152 x" ;;
    /data/mysql/shop)              echo "409600 x" ;;
    /data/mysql)                   echo "614400 x" ;;
    /var/lib/postgresql)           echo "153600 x" ;;
    /var/lib/valkey)               echo "3072 x" ;;
    /var/lib/meilisearch/data.ms)  echo "46080 x" ;;
    *) exit 1 ;;
esac
EOF
# Fake engines: the collectors run for real against stubbed clients.
cat > "${D}/lib/db.sh" <<EOF
_db_mariadb_exec() { cat "${D}/mariadb.out" 2>/dev/null; [[ -e "${D}/mariadb.out" ]]; }
_db_pgsql_exec() { cat "${D}/pgsql.out" 2>/dev/null; [[ -e "${D}/pgsql.out" ]]; }
EOF
cat > "${D}/lib/search.sh" <<EOF
SEARCH_HOME=/var/lib/meilisearch
_search_installed() { [[ -e "${D}/meili.on" ]]; }
_search_running() { [[ -e "${D}/meili.stats" ]]; }
_search_api() { _SEARCH_HTTP_BODY=\$(cat "${D}/meili.stats"); }
EOF
for c in mariadb psql; do printf '#!/bin/bash\nexit 0\n' > "${D}/bin/$c"; done
cat > "${D}/bin/valkey-cli" <<EOF
#!/bin/bash
echo "\${REDISCLI_AUTH:-none} \$*" >> "${D}/valkey.calls"
[[ -e "${D}/valkey.info" ]] || exit 1
case "\$*" in
    *"CONFIG GET dir"*) printf 'dir\r\n/var/lib/valkey\r\n' ;;
    *INFO*)             cat "${D}/valkey.info" ;;
esac
EOF
chmod +x "${D}/bin/"*
echo '{"valkey_password":"s3cret"}' > "${D}/etc/server.json"
# disk.sh with the app homes under the test directory (shared/.env is read from there)
sed "s#\"/home/#\"${D}/home/#g" "${LIB}/disk.sh" > "${D}/disk.sh"
only_test_paths "${D}/disk.sh" && pass "test copy of disk.sh only reads the test directory" || fail "test copy of disk.sh still points at /home"
printf 'datadir|/var/lib/mysql/\ndb|shop|1024\ndb|tiny|4300\n' > "${D}/mariadb.out"
printf 'db|blog|524288\n' > "${D}/pgsql.out"
dk() {
    PATH="${D}/bin:${PATH}" CIPI_CONFIG="${D}/etc" CIPI_LIB="${D}/lib" bash -c '
        set -euo pipefail
        BOLD=""; CYAN=""; DIM=""; NC=""; YELLOW=""; GREEN=""; RED=""
        error() { echo "ERROR: $*" >&2; }
        vault_read() { cat "${CIPI_CONFIG}/$1"; }
        _cipi_run_timed() { shift; "$@"; }
        source "$0"
        disk_command "$@"' "${D}/disk.sh" "$@" 2>&1
}
out=$(dk); rc=$?
[[ $rc -eq 0 ]] && pass "cipi disk runs" || fail "cipi disk failed (rc=${rc}): ${out}"
sq() { tr -s ' ' <<< "$out"; }
grep -q '^ / 100.00 GB 40.00 GB 60.00 GB 40%$' <<< "$(sq)" && grep -q '^ /boot/efi 0.10 GB 6.0 MB 0.10 GB 6%$' <<< "$(sq)" \
    && pass "server section: every filesystem with size, used and free, and use %" || fail "server section wrong: ${out}"
grep -q '^ APP FILES DATABASE TOTAL DISK LIMIT$' <<< "$(sq)" && pass "app table: files, database, total, % of disk, limit" || fail "app table header wrong: ${out}"
grep -q '^ shop 2.00 GB 1.00 GB 3.00 GB 3.0% —$' <<< "$(sq)" \
    && pass "MariaDB app: files + database (the directory wins over a smaller server figure)" || fail "shop row wrong: ${out}"
grep -q '^ blog 0.50 GB 0.50 GB 1.00 GB 1.0% —$' <<< "$(sq)" \
    && pass "PostgreSQL app: database size from pg_database_size" || fail "blog row wrong: ${out}"
grep -q '^ front 0.10 GB 0.00 GB 0.10 GB 0.1% —$' <<< "$(sq)" \
    && pass "app without a database: files only" || fail "front row wrong: ${out}"
[[ "$(grep -nE '^ (shop|blog|front) ' <<< "$(sq)" | cut -d' ' -f2 | tr '\n' ' ')" == "shop blog front " ]] \
    && pass "apps listed largest first" || fail "apps not sorted by size"
grep -q '^ All apps 4.10 GB 4.1%$' <<< "$(sq)" && grep -q '^ Everything else 35.90 GB 35.9%$' <<< "$(sq)" \
    && pass "totals: all apps, and everything else on the disk" || fail "totals wrong: ${out}"
grep -q 'cipi disk db' <<< "$out" && pass "points to cipi disk db for every database" || fail "no pointer to cipi disk db"
out=$(dk --json); rc=$?
[[ $rc -eq 0 ]] && jq -e '.disk == {mount:"/",size_gb:100,used_gb:40,free_gb:60,used_percent:40}
        and (.apps | map(.app)) == ["shop","blog","front"]
        and .apps[0] == {app:"shop",files_gb:2,database_gb:1,total_gb:3,percent:3,files_kb:2097152,database_kb:1048576,total_kb:3145728,
                         limit_gb:null,limit_percent:null,over_limit:false}
        and .apps_total_gb == 4.1 and .apps_percent == 4.1 and .other_gb == 35.9 and .other_percent == 35.9' <<< "$out" >/dev/null \
    && pass "--json: same figures, with the exact KiB" || fail "--json wrong (rc=${rc}): ${out}"
out=$(dk)
! grep -q 'over the limit' <<< "$out" && pass "no limit set anywhere by default: nobody is flagged" || fail "an app is flagged without a limit"

# database sizing
echo '{"tiny":{"php":"8.4"}}' > "${D}/etc/apps.json"
out=$(dk)
grep -q '^ tiny 0.05 GB 4.2 MB 0.05 GB 0.1% —$' <<< "$(sq)" \
    && pass "a 4 MB database shows as 4.2 MB, not 0.00 GB" || fail "small database display wrong: ${out}"
jq -e '.apps[0].database_gb == 0 and .apps[0].database_kb == 4300' <<< "$(dk --json)" >/dev/null \
    && pass "--json keeps the exact size in KiB next to the rounded GB" || fail "--json loses small sizes"
echo '{"shop":{"php":"8.4"}}' > "${D}/etc/apps.json"
printf 'datadir|/var/lib/mysql/\ndb|shop|2097152\n' > "${D}/mariadb.out"
grep -q '^ shop 2.00 GB 2.00 GB 4.00 GB' <<< "$(dk | tr -s ' ')" \
    && pass "MariaDB: the server's figure wins when it is larger than the directory" || fail "server figure ignored"
printf 'datadir|/data/mysql/\ndb|shop|1024\n' > "${D}/mariadb.out"
grep -q '^ shop 2.00 GB 0.39 GB 2.39 GB' <<< "$(dk | tr -s ' ')" \
    && pass "MariaDB: the data directory is the one the server reports" || fail "datadir not taken from the server"
mv "${D}/mariadb.out" "${D}/mariadb.off"
grep -q '^ shop 2.00 GB 1.00 GB 3.00 GB' <<< "$(dk | tr -s ' ')" \
    && pass "MariaDB not answering: the directory in the default data dir is measured" || fail "no fallback without the server"
printf 'datadir|/var/lib/mysql/\ndb|shop|1024\ndb|legacy_db|2097152\n' > "${D}/mariadb.out"
mkdir -p "${D}/home/shop/shared"
printf 'APP_ENV=production\nDB_DATABASE="legacy_db"\n' > "${D}/home/shop/shared/.env"
grep -q '^ shop 2.00 GB 3.00 GB 5.00 GB' <<< "$(dk | tr -s ' ')" \
    && pass "an app pointed at another database (DB_DATABASE) has that one counted too" || fail "DB_DATABASE ignored"
printf 'DB_DATABASE=../../etc\n' > "${D}/home/shop/shared/.env"
grep -q '^ shop 2.00 GB 1.00 GB 3.00 GB' <<< "$(dk | tr -s ' ')" \
    && pass "a DB_DATABASE that is not a plain name (a path, a SQLite file) is ignored" || fail "unsafe DB_DATABASE used"
printf 'APP_ENV=production\n' > "${D}/home/shop/shared/.env"
printf 'datadir|/var/lib/mysql/\ndb|shop|1024\n' > "${D}/mariadb.out"

# soft limits on the total: shop 2 GB (uses 3), blog 1.05 GB (uses 1.00 → 95%), front 5 GB (uses 0.10)
cat > "${D}/etc/apps.json" <<'EOF'
{"shop":{"php":"8.4","disk_limit_gb":2},"blog":{"php":"8.4","engine":"pgsql","disk_limit_gb":1.05},"front":{"runtime":"node","disk_limit_gb":5}}
EOF
out=$(dk); rc=$?
[[ $rc -eq 0 ]] && grep -q '^ shop .* 3.00 GB 3.0% 2 GB (150%) over$' <<< "$(sq)" && grep -q '^ blog .* 1.00 GB 1.0% 1.05 GB (95%)$' <<< "$(sq)" \
    && grep -q '^ front .* 0.1% 5 GB (2%)$' <<< "$(sq)" && grep -q '1 app(s) over the limit' <<< "$out" \
    && pass "LIMIT column: limit, % of it used by files + database, and who is over" || fail "limit column wrong (rc=${rc}): ${out}"
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

# ── 7a. cipi disk db ──────────────────────────────────────────
echo "-- cipi disk db"
printf 'datadir|/var/lib/mysql/\ndb|blog|2048\ndb|empty|0\ndb|shop|102400\n' > "${D}/mariadb.out"
printf 'db|analytics|51200\n' > "${D}/pgsql.out"
printf '# Memory\r\nused_memory:12902400\r\n# Keyspace\r\ndb0:keys=1204,expires=10,avg_ttl=0\r\ndb1:keys=37,expires=0,avg_ttl=0\r\n' > "${D}/valkey.info"
: > "${D}/meili.on"
echo '{"databaseSize":47185920,"indexes":{"shop-products":{"numberOfDocuments":12000,"rawDocumentDbSize":8808038},"blog-posts":{"numberOfDocuments":40}}}' > "${D}/meili.stats"
ddb() {
    PATH="${D}/bin:${PATH}" CIPI_CONFIG="${D}/etc" CIPI_LIB="${D}/lib" bash -c '
        set -euo pipefail
        BOLD=""; CYAN=""; DIM=""; NC=""; YELLOW=""; GREEN=""; RED=""
        error() { echo "ERROR: $*" >&2; }
        vault_read() { cat "${CIPI_CONFIG}/$1"; }
        _cipi_run_timed() { shift; "$@"; }
        # NOENG: a server without any engine, whatever the machine running this has installed.
        if [[ -n "${NOENG:-}" ]]; then
            command() { case "${2:-}" in mariadb|psql|valkey-cli|redis-cli) return 1 ;; *) builtin command "$@" ;; esac; }
        fi
        source "$0"
        disk_command db "$@"' "${LIB}/disk.sh" "$@" 2>&1
}
: > "${D}/valkey.calls"
out=$(ddb); rc=$?
[[ $rc -eq 0 ]] && pass "cipi disk db runs" || fail "cipi disk db failed (rc=${rc}): ${out}"
sec() { awk -v s="$1" '$1 == s {on=1; next} on && /^ *(MariaDB|PostgreSQL|Valkey|Meilisearch)$/ {on=0} on' <<< "$out" | tr -s ' '; }
grep -q '^ shop 1024.0 MB$' <<< "$(sec MariaDB)" && grep -q '^ blog 2.0 MB$' <<< "$(sec MariaDB)" && grep -q '^ empty 0.0 MB$' <<< "$(sec MariaDB)" \
    && pass "MariaDB: every database with its size in MB (the larger of server figure and directory)" || fail "MariaDB rows wrong: $(sec MariaDB)"
grep -q '^ On disk, whole engine 2048.0 MB$' <<< "$(sec MariaDB)" && pass "MariaDB: total of the data directory" || fail "MariaDB total wrong: $(sec MariaDB)"
grep -q '^ analytics 50.0 MB$' <<< "$(sec PostgreSQL)" && grep -q '^ On disk, whole engine 150.0 MB$' <<< "$(sec PostgreSQL)" \
    && pass "PostgreSQL: every database in MB, and the total" || fail "PostgreSQL rows wrong: $(sec PostgreSQL)"
grep -q '^ db0 1204 —$' <<< "$(sec Valkey)" && grep -q '^ db1 37 —$' <<< "$(sec Valkey)" \
    && grep -q '^ Memory in use 12.3 MB$' <<< "$(sec Valkey)" && grep -q '^ On disk, whole engine 3.0 MB$' <<< "$(sec Valkey)" \
    && pass "Valkey: keys per database, memory and disk of the instance in MB" || fail "Valkey rows wrong: $(sec Valkey)"
grep -q '^s3cret ' "${D}/valkey.calls" && ! grep -q -- '-a ' "${D}/valkey.calls" && ! grep -q 's3cret.*s3cret' "${D}/valkey.calls" \
    && pass "Valkey password goes through the environment, not the command line" || fail "Valkey password on the command line: $(cat "${D}/valkey.calls")"
grep -q '^ shop-products 12000 8.4 MB$' <<< "$(sec Meilisearch)" && grep -q '^ blog-posts 40 —$' <<< "$(sec Meilisearch)" \
    && grep -q '^ On disk, whole engine 45.0 MB$' <<< "$(sec Meilisearch)" \
    && pass "Meilisearch: documents per index, size where the server gives one, total in MB" || fail "Meilisearch rows wrong: $(sec Meilisearch)"
out=$(ddb --json); rc=$?
[[ $rc -eq 0 ]] && jq -e '
        .mariadb.databases == [{name:"blog",size_mb:2},{name:"empty",size_mb:0},{name:"shop",size_mb:1024}] and .mariadb.on_disk_mb == 2048
    and .pgsql.databases == [{name:"analytics",size_mb:50}] and .pgsql.on_disk_mb == 150
    and .valkey.databases == [{name:"db0",size_mb:null,keys:1204},{name:"db1",size_mb:null,keys:37}] and .valkey.memory_mb == 12.3 and .valkey.on_disk_mb == 3
    and .meilisearch.databases == [{name:"blog-posts",size_mb:null,documents:40},{name:"shop-products",size_mb:8.4,documents:12000}] and .meilisearch.on_disk_mb == 45' <<< "$out" >/dev/null \
    && pass "--json: the four engines, sizes in MB" || fail "--json wrong (rc=${rc}): ${out}"
printf 'datadir|/data/mysql/\ndb|shop|1024\n' > "${D}/mariadb.out"
out=$(ddb)
grep -q '^ shop 400.0 MB$' <<< "$(sec MariaDB)" && grep -q '^ On disk, whole engine 600.0 MB$' <<< "$(sec MariaDB)" \
    && pass "MariaDB: the data directory is the one the server reports" || fail "datadir not taken from the server: $(sec MariaDB)"
rm -f "${D}/mariadb.out" "${D}/pgsql.out" "${D}/valkey.info" "${D}/meili.stats"
out=$(ddb); rc=$?
[[ $rc -eq 0 && "$(grep -c 'did not answer' <<< "$out")" == "4" ]] && grep -q 'On disk, whole engine *2048.0 MB' <<< "$out" \
    && pass "an engine that does not answer gets a note and its size on disk; the report still runs" || fail "down engines handled wrong (rc=${rc}): ${out}"
rm -f "${D}/bin/mariadb" "${D}/bin/psql" "${D}/bin/valkey-cli" "${D}/meili.on"
out=$(NOENG=1 ddb); rc=$?
[[ $rc -eq 0 ]] && grep -q 'No database engine found' <<< "$out" && [[ "$(NOENG=1 ddb --json)" == "{}" ]] \
    && pass "engines that are not installed are left out" || fail "missing engines handled wrong (rc=${rc}): ${out}"
grep -q 'disk db' "${ROOT}/cipi" && pass "help lists cipi disk db" || fail "help omits cipi disk db"

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
        command() { case "${2:-}" in mariadb|psql) return 1 ;; *) builtin command "$@" ;; esac; }
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
        command() { case "${2:-}" in mariadb|psql) return 1 ;; *) builtin command "$@" ;; esac; }
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
    && grep -q 'Nothing is blocked' "${M}/sent" && grep -q 'Files: 3.50 GB.*Database: 0.00 GB' "${M}/sent" && [[ "$(st app_disk "$out")" == "crit" ]] \
    && pass "app over its limit: critical alert with files and database, and it says nothing is blocked" || fail "no over-limit alert: ${out}"
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

# ── 7d. cipi ssh apps ─────────────────────────────────────────
echo "-- cipi ssh apps"
H="${TMP}/sshapps"
mkdir -p "${H}/bin" "${H}/etc"
echo '{"shop":{"php":"8.4"},"blog":{"php":"8.4"},"front":{"runtime":"node"}}' > "${H}/etc/apps.json"
echo '{"root_password":"keep-me","db_root_password":"keep-me-too"}' > "${H}/etc/server.json"
SSHD_ORIG=$'Include /etc/ssh/sshd_config.d/*.conf\nPermitRootLogin no\nAllowGroups cipi-ssh cipi-apps\n\nMatch Group cipi-apps\n    PasswordAuthentication yes'
printf '%s\n' "$SSHD_ORIG" > "${H}/sshd_config"
: > "${H}/members"; : > "${H}/calls"
cat > "${H}/bin/id" <<EOF
#!/bin/bash
u="\${@: -1}"
jq -e --arg u "\$u" 'has(\$u)' "${H}/etc/apps.json" >/dev/null 2>&1 || exit 1
if [[ "\$1" == "-nG" ]]; then
    g="\$u www-data cipi-apps"
    grep -qx "\$u" "${H}/members" && g="\$g cipi-nossh"
    echo "\$g"
fi
EOF
cat > "${H}/bin/getent" <<EOF
#!/bin/bash
[[ "\$1 \$2" == "group cipi-nossh" && -e "${H}/group.exists" ]]
EOF
cat > "${H}/bin/groupadd" <<EOF
#!/bin/bash
echo "groupadd \$*" >> "${H}/calls"; : > "${H}/group.exists"
EOF
cat > "${H}/bin/gpasswd" <<EOF
#!/bin/bash
[[ -e "${H}/gpasswd.broken" ]] && exit 1
case "\$1" in
    -a) grep -qx "\$2" "${H}/members" || echo "\$2" >> "${H}/members" ;;
    -d) grep -vx "\$2" "${H}/members" > "${H}/members.new"; cat "${H}/members.new" > "${H}/members" ;;
esac
EOF
cat > "${H}/bin/usermod" <<EOF
#!/bin/bash
echo "usermod \$*" >> "${H}/calls"
[[ -e "${H}/gpasswd.broken" ]] && exit 1
exit 0
EOF
cat > "${H}/bin/sshd" <<EOF
#!/bin/bash
if [[ "\$1" == "-t" ]]; then
    echo "sshd -t \$(grep -c '^Match Group cipi-nossh ' "\$3")" >> "${H}/calls"
    [[ ! -e "${H}/reject" ]]; exit
fi
# -T -C user=U,host=H,addr=A
spec="\$3"; u="\${spec#user=}"; u="\${u%%,*}"; a="\${spec##*addr=}"
if grep -q '^Match Group cipi-nossh ' "${H}/sshd_config" && grep -qx "\$u" "${H}/members" && [[ "\$a" != 127.0.0.1 ]]; then
    echo "denyusers *"
fi
EOF
cat > "${H}/bin/systemctl" <<EOF
#!/bin/bash
echo "systemctl \$*" >> "${H}/calls"
EOF
chmod +x "${H}/bin/"*
sa() {
    PATH="${H}/bin:${PATH}" CIPI_CONFIG="${H}/etc" SSH_APPS_SSHD_CONFIG="${H}/sshd_config" H="$H" bash -c '
        set -euo pipefail
        BOLD=""; CYAN=""; DIM=""; NC=""; YELLOW=""; GREEN=""; RED=""
        error() { echo "ERROR: $*" >&2; }; warn() { echo "WARN: $*"; }; info() { echo "INFO: $*"; }; success() { echo "OK: $*"; }
        log_action() { echo "log: $*" >> "$H/calls"; }
        cipi_notify() { echo "notify: $3 | $1" >> "$H/calls"; }
        hostname() { echo srv; }
        vault_read() { [[ ! -e "$H/vault.broken" ]] && cat "${CIPI_CONFIG}/$1"; }
        vault_write() { cat > "${CIPI_CONFIG}/$1"; }
        app_exists() { jq -e --arg a "$1" "has(\$a)" "${CIPI_CONFIG}/apps.json" >/dev/null 2>&1; }
        parse_args() { :; }
        source "$0"
        ssh_command apps "$@"' "${LIB}/ssh.sh" "$@" 2>&1
}
out=$(sa); rc=$?
[[ $rc -eq 0 && "$(grep -c '● enabled' <<< "$out")" == "3" ]] && grep -q 'New apps: enabled' <<< "$out" \
    && pass "list: every app user, all enabled by default" || fail "default list wrong (rc=${rc}): ${out}"
jq -e '.new_apps == "enabled" and (.apps | map(.app)) == ["blog","front","shop"] and all(.apps[]; .ssh_access == "enabled")' <<< "$(sa --json)" >/dev/null \
    && pass "--json: apps and their access" || fail "--json wrong: $(sa --json)"
[[ "$(cat "${H}/sshd_config")" == "$SSHD_ORIG" && ! -s "${H}/calls" ]] && pass "listing changes nothing" || fail "list touched sshd_config or ran commands"

out=$(sa disable shop); rc=$?
[[ $rc -eq 0 ]] && grep -q "OK: SSH/SFTP access from outside disabled for 'shop'" <<< "$out" && grep -qx shop "${H}/members" \
    && pass "disable <app>: the app user joins cipi-nossh" || fail "disable shop wrong (rc=${rc}): ${out}"
[[ "$(head -6 "${H}/sshd_config")" == "$SSHD_ORIG" && "$(grep -c '^Match Group cipi-nossh Address \*,!127.0.0.1,!::1$' "${H}/sshd_config")" == "1" ]] \
    && [[ "$(tail -1 "${H}/sshd_config")" == "    DenyUsers *" ]] \
    && pass "sshd_config: the existing content is kept and the rule is appended once" || fail "sshd_config wrong: $(cat "${H}/sshd_config")"
[[ "$(grep -n 'sshd -t 1' "${H}/calls" | cut -d: -f1)" -lt "$(grep -n 'systemctl reload ssh' "${H}/calls" | cut -d: -f1)" ]] \
    && ! grep -q 'restart' "${H}/calls" \
    && pass "the new sshd_config is validated by sshd before it goes live; sshd is reloaded, not restarted" || fail "validation/reload order wrong: $(cat "${H}/calls")"
[[ -z "$(ls "${H}" | grep '^sshd_config\.')" ]] && pass "no working copy is left next to sshd_config" || fail "leftover: $(ls "${H}")"
grep -q 'notify: app_ssh_access | Cipi app SSH access disabled: shop on srv' "${H}/calls" && grep -q 'log: SSH APPS disable: shop' "${H}/calls" \
    && pass "the change is logged and notified" || fail "no log/notification: $(cat "${H}/calls")"
grep -q 'Deploys keep working' <<< "$out" && ! grep -q 'WARN' <<< "$out" && pass "sshd confirms the rule applies to the user; deploys are said to keep working" || fail "enforcement check wrong: ${out}"
out=$(sa)
grep -q 'shop *○ disabled' <<< "$out" && [[ "$(grep -c '● enabled' <<< "$out")" == "2" ]] && pass "list shows the disabled user" || fail "list after disable wrong: ${out}"

: > "${H}/calls"
out=$(sa disable shop)
grep -q "INFO: SSH/SFTP access of 'shop' is already disabled" <<< "$out" && ! grep -q 'notify' "${H}/calls" \
    && pass "disabling twice: nothing to do, no second notification" || fail "second disable wrong: ${out}"
out=$(sa disable blog)
[[ "$(grep -c '^Match Group cipi-nossh ' "${H}/sshd_config")" == "1" ]] && ! grep -q 'sshd -t\|systemctl' "${H}/calls" && grep -qx blog "${H}/members" \
    && pass "a second user: only a group change, sshd_config is not rewritten or reloaded" || fail "second user rewrote sshd_config: $(cat "${H}/calls")"
out=$(sa enable shop); rc=$?
[[ $rc -eq 0 ]] && ! grep -qx shop "${H}/members" && grep -qx blog "${H}/members" && pass "enable <app>: only that user is back" || fail "enable shop wrong (rc=${rc}): ${out}"

out=$(sa disable --all); rc=$?
[[ $rc -eq 0 && "$(sort "${H}/members" | tr '\n' ' ')" == "blog front shop " ]] \
    && jq -e '.app_ssh_default == "disabled" and .root_password == "keep-me" and .db_root_password == "keep-me-too"' "${H}/etc/server.json" >/dev/null \
    && pass "disable --all: every app user, new apps disabled, server.json keeps its other keys" || fail "disable --all wrong (rc=${rc}): ${out} / $(cat "${H}/etc/server.json")"
grep -q 'New apps: disabled' <<< "$(sa)" && pass "list shows what new apps get" || fail "new-app default not shown"
out=$(sa enable --all); rc=$?
[[ $rc -eq 0 && ! -s "${H}/members" ]] && jq -e '.app_ssh_default == "enabled"' "${H}/etc/server.json" >/dev/null \
    && pass "enable --all: everyone back, whatever the single settings were; new apps enabled" || fail "enable --all wrong (rc=${rc}): ${out}"

# a configuration sshd refuses
printf '%s\n' "$SSHD_ORIG" > "${H}/sshd_config"; : > "${H}/reject"
out=$(sa disable shop); rc=$?
[[ $rc -eq 1 && "$(cat "${H}/sshd_config")" == "$SSHD_ORIG" && ! -s "${H}/members" && -z "$(ls "${H}" | grep '^sshd_config\.')" ]] \
    && pass "sshd rejects the new config: sshd_config untouched, nobody disabled, no leftover" || fail "rejected config handled wrong (rc=${rc}): ${out}"
mv "${H}/reject" "${H}/reject.off"

# the vault cannot be read: server.json must not be overwritten
: > "${H}/vault.broken"; before=$(cat "${H}/etc/server.json")
PATH="${H}/bin:${PATH}" CIPI_CONFIG="${H}/etc" SSH_APPS_SSHD_CONFIG="${H}/sshd_config" H="$H" bash -c '
    warn() { echo "WARN: $*"; }
    vault_read() { return 1; }; vault_write() { cat > "${CIPI_CONFIG}/$1"; }
    source "$0"; _ssh_apps_set_default disabled' "${LIB}/ssh.sh" > "${H}/out" 2>&1
[[ "$(cat "${H}/etc/server.json")" == "$before" ]] && grep -q 'WARN: Could not read server.json' "${H}/out" \
    && pass "server.json unreadable: it is not overwritten" || fail "server.json overwritten after a failed read: $(cat "${H}/etc/server.json")"
mv "${H}/vault.broken" "${H}/vault.broken.off"

: > "${H}/gpasswd.broken"
out=$(sa disable shop); rc=$?
[[ $rc -eq 1 ]] && grep -q 'ERROR: Could not change the group cipi-nossh for: shop' <<< "$out" && ! grep -q 'OK:' <<< "$out" \
    && pass "the group cannot be changed: reported as an error, not as done" || fail "failed group change reported as success (rc=${rc}): ${out}"
mv "${H}/gpasswd.broken" "${H}/gpasswd.broken.off"

for bad in "disable cipi" "disable root" "disable nope" "disable" "enable" "disable shop --all" "frobnicate shop" "disable --force"; do
    # shellcheck disable=SC2086
    out=$(sa $bad); rc=$?
    [[ $rc -eq 1 ]] || fail "accepted: cipi ssh apps ${bad} (rc=${rc}): ${out}"
done
pass "refuses cipi, root, unknown apps, a missing target, <app> with --all, unknown actions and options"

# new apps follow the default
nd() {   # <default in server.json>
    : > "${H}/calls"
    PATH="${H}/bin:${PATH}" H="$H" D="$1" bash -c '
        vault_read() { echo "{\"app_ssh_default\":\"$D\"}"; }
        eval "$(sed -n "/^app_ssh_apply_default()/,/^}/p" "$0")"
        app_ssh_apply_default newapp' "${LIB}/common.sh"
    cat "${H}/calls"
}
[[ "$(nd disabled)" == "usermod -aG cipi-nossh newapp" && -z "$(nd enabled)" ]] \
    && grep -q 'app_ssh_apply_default "$app_user"' "${LIB}/app.sh" && grep -q 'app_ssh_apply_default "$app"' "${LIB}/sync.sh" \
    && pass "after disable --all a new app (create, sync import) starts disabled; otherwise enabled" || fail "new-app default wrong: $(nd disabled)"

# the rule itself, against a real sshd when this machine has one
SSHD_BIN=$(command -v sshd 2>/dev/null || true); [[ -n "$SSHD_BIN" ]] || { [[ -x /usr/sbin/sshd ]] && SSHD_BIN=/usr/sbin/sshd; }
if [[ -n "$SSHD_BIN" ]] && command -v ssh-keygen >/dev/null 2>&1 && ssh-keygen -q -t ed25519 -N '' -f "${H}/hostkey" 2>/dev/null; then
    me=$(id -un); mygroup=$(id -gn)
    printf '%s\n' "$SSHD_ORIG" > "${H}/sshd_config"
    PATH="${H}/bin:${PATH}" CIPI_CONFIG="${H}/etc" SSH_APPS_SSHD_CONFIG="${H}/sshd_config" bash -c '
        error() { :; }; warn() { :; }; source "$0"; _ssh_apps_ensure_block' "${LIB}/ssh.sh" >/dev/null 2>&1
    sed -n '/^Match Group cipi-nossh /,$p' "${H}/sshd_config" | sed "s/Match Group cipi-nossh /Match Group ${mygroup} /" > "${H}/real.conf"
    realsshd() { "$SSHD_BIN" -T -f "${H}/real.conf" -h "${H}/hostkey" -C "user=${1},host=x,addr=${2}" 2>/dev/null | grep -ci '^denyusers \*'; }
    if "$SSHD_BIN" -t -f "${H}/real.conf" -h "${H}/hostkey" 2>/dev/null; then
        [[ "$(realsshd "$me" 203.0.113.10)" == "1" && "$(realsshd "$me" 2001:db8::5)" == "1" \
           && "$(realsshd "$me" 127.0.0.1)" == "0" && "$(realsshd "$me" ::1)" == "0" ]] \
            && pass "real sshd: the rule denies the group from outside (IPv4, IPv6) and not from localhost" \
            || fail "real sshd does not apply the rule as intended"
    else
        fail "real sshd rejects the rule Cipi writes"
    fi
else
    echo "  (no sshd on this machine: the rule is checked against the stub only)"
fi

grep -q '^app_ssh_access|' "${LIB}/notifications.sh" && grep -q 'cipi ssh apps' "${ROOT}/cipi" \
    && pass "notification trigger and help are in place" || fail "trigger or help missing"

# ── 7e. Cloudflare accounts for DNS-01 ────────────────────────
echo "-- cipi ssl dns: several Cloudflare accounts"
W="${TMP}/ssl"
mkdir -p "${W}/bin" "${W}/etc" "${W}/renewal"
# ssl.sh with app homes under the test directory: installing a certificate edits shared/.env
sed "s#\"/home/#\"${W}/home/#g" "${LIB}/ssl.sh" > "${W}/ssl.sh"
only_test_paths "${W}/ssl.sh" && SSL_SAFE=true || SSL_SAFE=false
[[ "$SSL_SAFE" == true ]] && pass "test copy of ssl.sh only touches the test directory" || fail "test copy of ssl.sh still points at /home — not run"
cat > "${W}/bin/dpkg" <<'EOF'
#!/bin/bash
echo "ii  python3-certbot-dns-cloudflare 2.9 all"
EOF
cat > "${W}/bin/certbot" <<EOF
#!/bin/bash
echo "certbot \$*" >> "${W}/calls"
[[ "\$1" == "certonly" ]] || exit 0
[[ -e "${W}/certbot.fail" ]] && exit 1
creds=""; cert=""
while [[ \$# -gt 0 ]]; do
    case "\$1" in
        --dns-cloudflare-credentials) creds="\$2"; shift ;;
        --cert-name) cert="\$2"; shift ;;
    esac
    shift
done
printf '[renewalparams]\nauthenticator = dns-cloudflare\ndns_cloudflare_credentials = %s\n' "\$creds" > "${W}/renewal/\${cert}.conf"
EOF
printf '#!/bin/bash\nexit 0\n' > "${W}/bin/nginx"
printf '#!/bin/bash\nexit 0\n' > "${W}/bin/systemctl"
chmod +x "${W}/bin/"*
echo '{"shop":{"domain":"shop.test"},"saas":{"domain":"*.saas.test"},"blog":{"domain":"blog.test"}}' > "${W}/etc/apps.json"
TOKA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; TOKB="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"; TOKC="cccccccccccccccccccccccccccccccccccccccc"
sl() {   # ssl_command <args…> against the test directory
    [[ "$SSL_SAFE" == true ]] || { echo "not run"; return 1; }
    PATH="${W}/bin:${PATH}" CIPI_CONFIG="${W}/etc" W="$W" SSL_DNS_DEFAULT_CREDS="${W}/etc/cloudflare.ini" \
    SSL_DNS_DIR="${W}/etc/cloudflare" SSL_RENEWAL_DIR="${W}/renewal" bash -c '
        set -euo pipefail
        BOLD=""; CYAN=""; DIM=""; NC=""; YELLOW=""; GREEN=""; RED=""
        error() { echo "ERROR: $*" >&2; }; warn() { echo "WARN: $*"; }; info() { echo "INFO: $*"; }
        success() { echo "OK: $*"; }; step() { echo "STEP: $*"; }
        log_action() { echo "log: $*" >> "$W/calls"; }
        cipi_notify() { echo "notify: $2" >> "$W/calls"; }
        hostname() { echo srv; }
        vault_read() { cat "${CIPI_CONFIG}/$1"; }
        vault_write() { cat > "${CIPI_CONFIG}/$1"; }
        app_exists() { jq -e --arg a "$1" "has(\$a)" "${CIPI_CONFIG}/apps.json" >/dev/null 2>&1; }
        app_get() { jq -r --arg a "$1" --arg k "$2" ".[\$a][\$k] // empty" "${CIPI_CONFIG}/apps.json"; }
        app_set() { jq --arg a "$1" --arg k "$2" --arg v "$3" ".[\$a][\$k] = \$v" "${CIPI_CONFIG}/apps.json" > "$W/apps.new" && cat "$W/apps.new" > "${CIPI_CONFIG}/apps.json"; }
        chown() { :; }
        parse_args() { for a in "$@"; do case "$a" in --*=*) k="${a%%=*}"; k="${k#--}"; printf -v "ARG_${k//-/_}" "%s" "${a#*=}" ;; --*) k="${a#--}"; printf -v "ARG_${k//-/_}" "%s" true ;; esac; done; }
        eval "$(sed -n "/^domain_cert_name()/,/^}/p; /^domain_is_wildcard()/,/^}/p" "$1")"
        source "$0"; shift
        "$@"' "${W}/ssl.sh" "${LIB}/common.sh" "$@" 2>&1
}
out=$(sl ssl_command dns list); rc=$?
[[ $rc -eq 0 ]] && grep -q 'none — add one with' <<< "$out" && pass "no account yet: the list says how to add one" || fail "empty list wrong (rc=${rc}): ${out}"

out=$(sl ssl_command dns set --token="$TOKA"); rc=$?
[[ $rc -eq 0 ]] && grep -q "dns_cloudflare_api_token = ${TOKA}" "${W}/etc/cloudflare.ini" && [[ ! -d "${W}/etc/cloudflare" ]] \
    && pass "dns set without --name: the default account, in the file Cipi always used" || fail "default account wrong (rc=${rc}): ${out}"
out=$(sl ssl_command dns set --name=client-a --token="$TOKB"); rc=$?
[[ $rc -eq 0 ]] && grep -q "dns_cloudflare_api_token = ${TOKB}" "${W}/etc/cloudflare/client-a.ini" \
    && grep -q "dns_cloudflare_api_token = ${TOKA}" "${W}/etc/cloudflare.ini" \
    && pass "dns set --name: a second account in its own file; the default is untouched" || fail "named account wrong (rc=${rc}): ${out}"
[[ "$(ls -l "${W}/etc/cloudflare/client-a.ini" | cut -c1-10)" == "-rw-------" && "$(ls -ld "${W}/etc/cloudflare" | cut -c1-10)" == "drwx------" ]] \
    && pass "credentials are root-only (file 600, directory 700)" || fail "credentials too open: $(ls -ld "${W}/etc/cloudflare" "${W}/etc/cloudflare/client-a.ini")"
! grep -rq "$TOKB" "${W}/calls" 2>/dev/null && ! grep -q "$TOKB" <<< "$out" && pass "the token is not logged or printed" || fail "token leaked into log or output"
for bad in "../evil" "Client" "a b" "x/y" ".hidden"; do
    out=$(sl ssl_command dns set --name="$bad" --token="$TOKC"); rc=$?
    [[ $rc -eq 1 ]] || fail "accepted account name '${bad}' (rc=${rc})"
done
[[ "$(ls -A "${W}/etc/cloudflare")" == "client-a.ini" && ! -e "${W}/etc/evil.ini" ]] \
    && pass "account names that are not plain identifiers are refused (nothing written outside the directory)" || fail "bad name wrote a file: $(ls -A "${W}/etc" "${W}/etc/cloudflare")"
out=$(sl ssl_command dns set --name=client-b --token="short with space"); rc=$?
[[ $rc -eq 1 && ! -e "${W}/etc/cloudflare/client-b.ini" ]] && pass "a token with spaces is refused" || fail "bad token accepted (rc=${rc})"

# issuing: each app with its account
: > "${W}/calls"
out=$(sl _ssl_install_dns01 saas '*.saas.test' cloudflare true client-a); rc=$?
[[ $rc -eq 0 ]] && grep -q -- "--dns-cloudflare-credentials ${W}/etc/cloudflare/client-a.ini" "${W}/calls" \
    && grep -q -- '-d saas.test -d \*.saas.test' "${W}/calls" && jq -e '.saas.ssl_dns_account == "client-a"' "${W}/etc/apps.json" >/dev/null \
    && pass "install --account=client-a: certbot gets that account's credentials; the app remembers it" || fail "install with account wrong (rc=${rc}): ${out} / $(cat "${W}/calls")"
grep -q 'Account: client-a' "${W}/calls" && grep -q 'account=client-a' "${W}/calls" && pass "the account is in the log and the notification" || fail "account not logged/notified"
: > "${W}/calls"
out=$(sl _ssl_install_dns01 shop shop.test cloudflare "" ""); rc=$?
[[ $rc -eq 0 ]] && grep -q -- "--dns-cloudflare-credentials ${W}/etc/cloudflare.ini" "${W}/calls" && jq -e '.shop.ssl_dns_account == "default"' "${W}/etc/apps.json" >/dev/null \
    && pass "install without --account: the default account, as before" || fail "default install wrong (rc=${rc}): ${out}"
: > "${W}/calls"
out=$(sl _ssl_install_dns01 saas '*.saas.test' cloudflare true ""); rc=$?
[[ $rc -eq 0 ]] && grep -q -- "--dns-cloudflare-credentials ${W}/etc/cloudflare/client-a.ini" "${W}/calls" \
    && pass "reissuing without --account keeps the account the app was issued with" || fail "reissue switched account (rc=${rc}): $(cat "${W}/calls")"
: > "${W}/calls"
out=$(sl _ssl_install_dns01 blog blog.test cloudflare "" nope); rc=$?
[[ $rc -eq 1 ]] && grep -q "Cloudflare account 'nope' is not configured" <<< "$out" && grep -q 'Configured accounts: default client-a' <<< "$out" \
    && ! grep -q 'certbot' "${W}/calls" && pass "an account that does not exist: refused before certbot runs, with the list of accounts" || fail "unknown account wrong (rc=${rc}): ${out}"
: > "${W}/certbot.fail"
out=$(sl _ssl_install_dns01 blog blog.test cloudflare "" client-a); rc=$?
[[ $rc -eq 1 ]] && grep -q "account 'client-a' holds the zone of blog.test" <<< "$out" && jq -e '.blog.ssl_dns_account == null' "${W}/etc/apps.json" >/dev/null \
    && pass "issuance fails (zone in another account): says which account was used; the app is not marked" || fail "failed issuance wrong (rc=${rc}): ${out}"
mv "${W}/certbot.fail" "${W}/certbot.fail.off"

out=$(sl ssl_command dns list)
grep -q '^ *default *shop.test *$' <<< "$out" && grep -q '^ *client-a *saas.test *$' <<< "$out" && ! grep -q "$TOKA\|$TOKB" <<< "$out" \
    && pass "list: every account with the certificates that renew with it, never the tokens" || fail "list wrong: ${out}"
jq -e '.accounts == [{account:"default",provider:"cloudflare",certificates:["shop.test"]},{account:"client-a",provider:"cloudflare",certificates:["saas.test"]}]' \
    <<< "$(sl ssl_command dns list --json)" >/dev/null && pass "list --json" || fail "list --json wrong: $(sl ssl_command dns list --json)"

out=$(sl ssl_command dns remove client-a); rc=$?
[[ $rc -eq 1 && -f "${W}/etc/cloudflare/client-a.ini" ]] && grep -q "still used to renew: saas.test" <<< "$out" \
    && pass "remove: refused while a certificate renews with the account" || fail "in-use account removed (rc=${rc}): ${out}"
out=$(sl ssl_command dns set --name=client-a --token="$TOKC"); rc=$?
[[ $rc -eq 0 ]] && grep -q "dns_cloudflare_api_token = ${TOKC}" "${W}/etc/cloudflare/client-a.ini" && grep -q 'token replaced' <<< "$out" \
    && pass "dns set on an existing account replaces its token (rotation)" || fail "token rotation wrong (rc=${rc}): ${out}"
sl ssl_command dns set --name=spare --token="$TOKB" >/dev/null
out=$(sl ssl_command dns remove spare); rc=$?
[[ $rc -eq 0 && ! -e "${W}/etc/cloudflare/spare.ini" && -f "${W}/etc/cloudflare/client-a.ini" && -f "${W}/etc/cloudflare.ini" ]] \
    && pass "remove: an unused account goes, the others stay" || fail "remove wrong (rc=${rc}): ${out}"
for bad in "" "nope" "../cloudflare" "--force"; do
    out=$(sl ssl_command dns remove "$bad"); rc=$?
    [[ $rc -eq 1 && -f "${W}/etc/cloudflare.ini" && -f "${W}/etc/cloudflare/client-a.ini" ]] || fail "dns remove '${bad}' did something (rc=${rc})"
done
pass "remove refuses a missing, unknown or path-like name"
grep -q 'ARG_account:-}" && -z "$dns_provider"' "${LIB}/ssl.sh" && grep -q '_ssl_install_dns01 "$app" "$d" "$dns_provider" "$wildcard" "${ARG_account:-}"' "${LIB}/ssl.sh" \
    && pass "cipi ssl install passes --account on, and refuses it without --dns" || fail "--account not wired into cipi ssl install"
grep -q 'cipi ssl dns list' "${ROOT}/cipi" && pass "help lists the dns account commands" || fail "help omits cipi ssl dns list"

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
is "$(comp '' _cipi_complete cipi disk '')" "db --json" "cipi disk <Tab> → db --json"
is "$(comp '' _cipi_complete cipi ssh ap)" "apps" "cipi ssh ap<Tab> → apps"
is "$(comp '' _cipi_complete cipi ssl dns '')" "set list remove" "cipi ssl dns <Tab> → set list remove"
is "$(comp '' _cipi_complete cipi ssl install shop --a)" "--account=" "cipi ssl install <app> --a<Tab> → --account="
is "$(comp '' _cipi_complete cipi ssh apps dis)" "disable" "cipi ssh apps dis<Tab> → disable"
is "$(comp '' _cipi_complete cipi ssh apps disable '')" "shop blog shop2 --all" "cipi ssh apps disable <Tab> → app names and --all"
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
grep -q -- '--account=' "${ROOT}/README.md" && grep -q 'cipi ssl dns list' "${ROOT}/CHANGELOG.md" \
    && pass "README and CHANGELOG document several Cloudflare accounts" || fail "Cloudflare accounts undocumented"
grep -q 'cipi ssh apps disable' "${ROOT}/README.md" && grep -q 'cipi ssh apps' "${ROOT}/CHANGELOG.md" \
    && pass "README and CHANGELOG document cipi ssh apps" || fail "cipi ssh apps undocumented"
grep -q 'cipi disk' "${ROOT}/README.md" && grep -q 'cipi disk' "${ROOT}/CHANGELOG.md" \
    && grep -q 'cipi disk db' "${ROOT}/README.md" && grep -q 'cipi disk db' "${ROOT}/CHANGELOG.md" \
    && pass "README and CHANGELOG document cipi disk and cipi disk db" || fail "cipi disk / cipi disk db undocumented"
grep -qi 'tab-completion' "${ROOT}/README.md" && grep -q 'sudo cipi' "${ROOT}/CHANGELOG.md" \
    && pass "README and CHANGELOG document tab-completion" || fail "tab-completion undocumented"
grep -q 'OpenVZ' "${ROOT}/README.md" && grep -q 'full virtualization' "${ROOT}/README.md" \
    && pass "README requirements name the virtualization that is supported" || fail "README requirements omit virtualization"
grep -q 'cipi firewall attempts 5' "${ROOT}/README.md" && grep -q 'Failed SSH logins before a ban' "${ROOT}/README.md" \
    && grep -q 'cipi firewall attempts' "${ROOT}/CHANGELOG.md" \
    && pass "README and CHANGELOG document cipi firewall attempts and the default" || fail "cipi firewall attempts undocumented"

echo "=== ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]

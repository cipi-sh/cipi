#!/bin/bash
# Local regression checks for 5.1.2 — WebSocket / Reverb support.
# Run from repo root: bash tests/verify-5.1.2.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/lib"
TMP="$(mktemp -d)"
mkdir -p "${TMP}/bin"
trap 'rm -rf "${TMP}"' EXIT
PASS=0
FAIL=0

pass() { echo "  OK: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

echo "=== Cipi 5.1.2 regression checks ==="

# ── 1. Syntax ───────────────────────────────────────────────────
for f in "${LIB}/common.sh" "${LIB}/app.sh" "${LIB}/nginx.sh" "${LIB}/ssl.sh" \
         "${LIB}/yml.sh" "${LIB}/migrations/5.1.2.sh" "${ROOT}/setup.sh" "${ROOT}/cipi"; do
    bash -n "$f" && pass "syntax $(basename "$f")" || fail "syntax $(basename "$f")"
done

# ── 2. Every function a library defines survives sourcing it ────
# An unterminated heredoc makes the functions behind it disappear (see 5.1.1).
for lib in common.sh app.sh yml.sh nginx.sh ssl.sh; do
    declared=$(grep -oE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' "${LIB}/${lib}" | tr -d '()' | sort -u)
    missing=$(bash -c "
        CIPI_LIB='${LIB}'; CIPI_CONFIG='${TMP}/etc'; CIPI_LOG='${TMP}/log'
        mkdir -p \"\$CIPI_CONFIG\" \"\$CIPI_LOG\"
        source '${LIB}/${lib}' >/dev/null 2>&1 || true
        for fn in ${declared}; do
            declare -f \"\$fn\" >/dev/null 2>&1 || echo \"\$fn\"
        done" 2>/dev/null)
    [[ -z "$missing" ]] && pass "${lib}: all functions defined after sourcing" \
        || fail "${lib}: missing after sourcing: ${missing}"
done

# ── 3. nginx location is a regex, not a greedy prefix ───────────
# `location /app` also matched /appointments, /apple, /application/... and
# proxied real Laravel routes into Reverb.
block=$(bash -c '
    app_get(){ echo 9000; }
    _ensure_nginx_octane_map(){ :; }
    eval "$(sed -n "/^_nginx_reverb_location_block()/,/^}/p" '"${LIB}"'/app.sh)"
    _nginx_reverb_location_block myapp')

grep -qF 'location ~ ^/apps?(/|$)' <<< "$block" \
    && pass "reverb location is the regex ^/apps?(/|\$)" \
    || fail "reverb location is not the expected regex: $(head -1 <<< "$block")"
grep -qE '^\s*location /app \{' <<< "$block" \
    && fail "reverb location is still the greedy prefix /app" \
    || pass "greedy prefix 'location /app' is gone"
grep -q 'proxy_set_header Connection \$connection_upgrade' <<< "$block" \
    && pass "Upgrade/Connection headers present" || fail "missing Connection \$connection_upgrade"
timeout=$(grep -oE 'proxy_read_timeout [0-9]+' <<< "$block" | grep -oE '[0-9]+')
[[ -n "$timeout" && "$timeout" -gt 60 ]] \
    && pass "proxy_read_timeout ${timeout}s is above Reverb's 60s ping interval" \
    || fail "proxy_read_timeout ${timeout:-unset} does not clear the 60s ping interval"

# ── 4. .env: credentials, VITE_ copies, ws:// vs wss:// ─────────
mkdir -p "${TMP}/home/myapp/shared"
printf 'APP_NAME=Laravel\nBROADCAST_CONNECTION=log\nREVERB_APP_KEY=\n' > "${TMP}/home/myapp/shared/.env"

run_sync() {
    # $1 = domain, $2... = extra args for _reverb_sync_env
    local dom="$1"; shift
    bash -c '
        set -uo pipefail
        for fn in _env_read_key _env_set_or_add _env_apply_group _reverb_sync_env; do
            eval "$(sed -n "/^${fn}()/,/^}\$/p" '"${LIB}"'/app.sh \
                 | sed "s#/home/\\\${app}/shared#'"${TMP}"'/home/\\\${app}/shared#")"
        done
        eval "$(sed -n "/^domain_url_host()/,/^}/p" '"${LIB}"'/common.sh)"
        eval "$(sed -n "/^domain_cert_name()/,/^}/p" '"${LIB}"'/common.sh)"
        app_get(){ case "$2" in reverb_port) echo 9000;; domain) echo "'"$dom"'";; esac; }
        chown(){ :; }
        _reverb_sync_env myapp '"$*"
}

# The .env helpers use GNU `sed -i`. On a BSD sed (macOS, where this suite is
# usually run before pushing) stand in for it with python, so these checks
# actually run instead of being skipped on the developer's machine.
if ! sed --version 2>/dev/null | grep -q GNU; then
    cat > "${TMP}/bin/sed" <<'SEDSHIM'
#!/bin/bash
if [[ "${1:-}" == "-i" ]]; then
    shift; expr="$1"; shift
    exec /usr/bin/python3 -c '
import sys, re
expr = sys.argv[1]
for f in sys.argv[2:]:
    lines = open(f).read().split("\n")
    if expr.startswith("s"):
        d = expr[1]
        parts = expr[2:].split(d)
        lines = [re.sub(parts[0], parts[1].replace("\\", "\\\\"), l) for l in lines]
    elif expr.startswith("/") and expr.endswith("/d"):
        lines = [l for l in lines if not re.search(expr[1:-2], l)]
    open(f, "w").write("\n".join(lines))
' "$expr" "$@"
fi
exec /usr/bin/sed "$@"
SEDSHIM
    chmod +x "${TMP}/bin/sed"
    export PATH="${TMP}/bin:${PATH}"
fi

{
    run_sync example.com >/dev/null 2>&1
    envf="${TMP}/home/myapp/shared/.env"
    for k in REVERB_APP_ID REVERB_APP_KEY REVERB_APP_SECRET \
             REVERB_SERVER_HOST REVERB_SERVER_PORT \
             VITE_REVERB_APP_KEY VITE_REVERB_HOST VITE_REVERB_PORT VITE_REVERB_SCHEME; do
        grep -qE "^${k}=.+" "$envf" && pass ".env has ${k}" || fail ".env is missing ${k}"
    done
    grep -q '^BROADCAST_CONNECTION=reverb' "$envf" \
        && pass "BROADCAST_CONNECTION switched to reverb" || fail "BROADCAST_CONNECTION not set"
    [[ "$(grep '^REVERB_APP_KEY=' "$envf")" == "REVERB_APP_KEY=$(grep '^VITE_REVERB_APP_KEY=' "$envf" | cut -d= -f2)" ]] \
        && pass "VITE_REVERB_APP_KEY mirrors REVERB_APP_KEY" || fail "VITE key does not mirror the server key"
    grep -q '^REVERB_SCHEME=http$' "$envf" \
        && pass "no certificate → ws:// (http/80)" || fail "scheme should be http without a certificate"

    key_before=$(grep '^REVERB_APP_KEY=' "$envf")
    run_sync example.com >/dev/null 2>&1
    [[ "$(grep '^REVERB_APP_KEY=' "$envf")" == "$key_before" ]] \
        && pass "credentials are not rotated on a second run" || fail "credentials were rotated"

    sed -i 's|^REVERB_HOST=.*|REVERB_HOST=ws.hand.edited|' "$envf"
    run_sync example.com --fill >/dev/null 2>&1
    grep -q '^REVERB_HOST=ws.hand.edited$' "$envf" \
        && pass "--fill keeps a hand-edited REVERB_HOST" || fail "--fill overwrote REVERB_HOST"
    run_sync example.com >/dev/null 2>&1
    grep -q '^REVERB_HOST=example.com$' "$envf" \
        && pass "a converging run restores REVERB_HOST" || fail "converging run did not reset REVERB_HOST"

    run_sync '*.example.com' >/dev/null 2>&1
    grep -q '^REVERB_HOST=www.example.com$' "$envf" \
        && pass "wildcard domain resolves to a concrete host" || fail "wildcard host was not resolved"
}

# ── 5. Disable puts broadcasting back ──────────────────────────
grep -q 'reverb_prev_broadcast' "${LIB}/app.sh" \
    && pass "the previous broadcast driver is remembered" || fail "reverb_prev_broadcast not tracked"
grep -A4 '_env_remove_keys "\$envf" REVERB_SERVER_HOST REVERB_SERVER_PORT' "${LIB}/app.sh" >/dev/null \
    && pass "disable drops only the two Cipi-owned keys" || fail "disable key removal changed"

# ── 6. File-descriptor headroom ────────────────────────────────
for fn in _ensure_supervisor_fd_limit _supervisor_fd_limit_active _ensure_nginx_ws_limits; do
    grep -q "^${fn}()" "${LIB}/common.sh" && pass "${fn} present" || fail "${fn} missing"
done
# _ensure_nginx_ws_limits reports 0 (nothing to do) / 2 (changed, reload needed)
# / 1 (rolled back). Callers reload nginx only on 2 — a raised
# worker_rlimit_nofile reaches only the workers a reload spawns.
mkdir -p "${TMP}/nx/bin"
printf '#!/bin/bash\nexit 0\n' > "${TMP}/nx/bin/nginx"; chmod +x "${TMP}/nx/bin/nginx"
printf 'user www-data;\nworker_processes 4;\npid /run/nginx.pid;\nevents {\n    worker_connections 2048;\n}\n' \
    > "${TMP}/nx/nginx.conf"
sed -n '/^_ensure_nginx_ws_limits()/,/^}$/p' "${LIB}/common.sh" \
    | sed "s#/etc/nginx/nginx.conf#${TMP}/nx/nginx.conf#" > "${TMP}/nx/fn.sh"
ws_rc() (
    PATH="${TMP}/nx/bin:${PATH}"
    CIPI_WS_NOFILE=65535
    CIPI_WS_WORKER_CONNECTIONS=8192
    # shellcheck source=/dev/null
    source "${TMP}/nx/fn.sh"
    rc=0
    _ensure_nginx_ws_limits || rc=$?
    echo "$rc"
)
[[ "$(ws_rc)" == "2" ]] && pass "a first run reports 2 (changed, reload needed)" || fail "first run did not report 2"
grep -q '^worker_rlimit_nofile 65535;$' "${TMP}/nx/nginx.conf" \
    && pass "worker_rlimit_nofile written after worker_processes" || fail "worker_rlimit_nofile not written"
grep -qE '^\s*worker_connections 8192;$' "${TMP}/nx/nginx.conf" \
    && pass "worker_connections raised to 8192" || fail "worker_connections not raised"
[[ "$(ws_rc)" == "0" ]] && pass "a second run reports 0 (idempotent)" || fail "second run was not idempotent"

printf '#!/bin/bash\nexit 1\n' > "${TMP}/nx/bin/nginx"
printf 'user www-data;\nworker_processes 4;\nevents {\n    worker_connections 2048;\n}\n' > "${TMP}/nx/nginx.conf"
before=$(cat "${TMP}/nx/nginx.conf")
[[ "$(ws_rc)" == "1" ]] && pass "a failing nginx -t reports 1" || fail "a failing nginx -t did not report 1"
[[ "$(cat "${TMP}/nx/nginx.conf")" == "$before" ]] \
    && pass "nginx.conf is rolled back byte-for-byte" || fail "nginx.conf was not rolled back"

grep -q 'worker_rlimit_nofile' "${ROOT}/setup.sh" \
    && pass "setup.sh nginx template sets worker_rlimit_nofile" || fail "setup.sh missing worker_rlimit_nofile"
grep -q 'worker_rlimit_nofile' "${LIB}/nginx.sh" \
    && pass "nginx.sh template sets worker_rlimit_nofile" || fail "nginx.sh missing worker_rlimit_nofile"
grep -q 'LimitNOFILE=65535' "${ROOT}/setup.sh" \
    && pass "setup.sh writes the supervisor drop-in" || fail "setup.sh missing supervisor LimitNOFILE"
grep -qE '^[^#]*minfds[[:space:]]*=' "${LIB}/common.sh" "${ROOT}/setup.sh" \
    && fail "supervisord minfds is set — it makes supervisord refuse to start when unreachable" \
    || pass "supervisord minfds is deliberately not set"

# ── 7. cipi.yml: workers.reverb ────────────────────────────────
# Find the heredoc by its delimiter, not by a line number: the old `NR>=58`
# offset drifted as yml.sh grew and silently extracted shell into the .py.
awk "/<<'CIPIYAMLPY'/{f=1;next} /^CIPIYAMLPY\$/{exit} f" "${LIB}/yml.sh" > "${TMP}/validator.py"

yml_check() { # $1=yaml body, $2=jq filter, $3=expected, $4=label
    printf '%s\n' "$1" > "${TMP}/t.yml"
    local got; got=$(python3 "${TMP}/validator.py" "${TMP}/t.yml" myapp | jq -r "$2" 2>/dev/null)
    [[ "$got" == "$3" ]] && pass "$4" || fail "$4 (got: ${got})"
}

yml_check 'version: 1
workers:
  reverb: true' '.data.workers.reverb' 'true' "workers.reverb: true validates"

yml_check 'version: 1
workers:
  reverb: false' '.data.workers.reverb' 'false' "workers.reverb: false is kept (not swallowed as null)"

yml_check 'version: 1
workers:
  reverb: maybe' '.errors[0]' 'workers.reverb: expected true or false' "a non-boolean reverb is rejected"

yml_check 'version: 1
workers:
  reverbs: true' '.ok' 'false' "an unknown workers key is still rejected"

# The plan reads these with `has()`, not `// empty`: jq's alternative operator
# treats false exactly like a missing key, so `horizon: false` used to be a no-op.
grep -q "jq -r 'if .workers | has(\"horizon\")" "${LIB}/yml.sh" \
    && pass "workers.horizon is read with has(), so 'false' is honoured" \
    || fail "workers.horizon is still read with // empty"
grep -q "jq -r 'if .workers | has(\"reverb\")" "${LIB}/yml.sh" \
    && pass "workers.reverb is read with has()" || fail "workers.reverb read with // empty"
grep -q '_YML_ACTIONS+=("reverb|on|' "${LIB}/yml.sh" && pass "plan emits a reverb action" || fail "no reverb action in the plan"
grep -q '_app_reverb_enable "$app"' "${LIB}/yml.sh" && pass "apply calls _app_reverb_enable" || fail "apply does not call _app_reverb_enable"
grep -q 'Reverb is Laravel only' "${LIB}/yml.sh" && pass "custom apps are blocked from workers.reverb" || fail "no blocker for custom apps"

# ── 8. Cloning a Reverb app ────────────────────────────────────
grep -q 'APP_KEY|APP_URL|DB_\*|DATABASE_URL|CIPI_\*|OCTANE_\*|REVERB_\*|VITE_REVERB_\*' "${LIB}/app.sh" \
    && pass "clone does not copy the source's Reverb credentials" \
    || fail "clone still copies REVERB_* into the new .env"
grep -q '_app_reverb_enable "\$name"' "${LIB}/app.sh" \
    && pass "clone gives the new app its own Reverb" || fail "clone does not enable Reverb on the clone"

# ── 9. SSL and domain changes re-derive the public endpoint ────
[[ $(grep -c '_reverb_sync_env "\$app"' "${LIB}/ssl.sh") -eq 2 ]] \
    && pass "both SSL install paths re-sync Reverb (ws:// → wss://)" \
    || fail "an SSL install path does not re-sync Reverb"
grep -q '_reverb_sync_env "\$app"' "${LIB}/app.sh" \
    && pass "a domain change re-syncs Reverb" || fail "domain change does not re-sync Reverb"

echo ""
echo "=== ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]

#!/bin/bash
# Local regression checks for 5.8.5 — `cipi api ip-whitelist` writes the list
# next to the file and renames it (never a cross-device mv), survives a
# read-only /etc/cipi on read paths and explains it on write paths, and
# vault_write / vault_seal use the same in-place rename. Pure bash 3.2 +
# openssl + jq: nothing outside the temp dir is touched.
# Run from repo root: bash tests/verify-5.8.5.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/lib"
PASS=0
FAIL=0

pass() { echo "  OK: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
extract() { sed -n "/^${2}() {/,/^}/p" "${LIB}/${1}"; }

# Every path below hangs off $TMP: without it, "${TMP}/etc/cipi" would be the real one.
TMP=$(mktemp -d) && [[ -n "$TMP" && -d "$TMP" ]] || { echo "mktemp -d failed" >&2; exit 1; }
RO_DIRS=""
lock() {   # make a directory read-only for this user (root included where possible)
    if [[ "$(uname -s)" == "Darwin" ]]; then
        chflags uchg "$1"
    elif command -v chattr >/dev/null 2>&1 && chattr +i "$1" 2>/dev/null; then
        :
    else
        chmod 555 "$1"
    fi
    RO_DIRS="${RO_DIRS} $1"
}
unlock_all() {
    local d
    for d in ${RO_DIRS}; do
        if [[ "$(uname -s)" == "Darwin" ]]; then
            chflags nouchg "$d" 2>/dev/null || true
        elif command -v chattr >/dev/null 2>&1; then
            chattr -i "$d" 2>/dev/null || true
        fi
        chmod 755 "$d" 2>/dev/null || true
    done
}
trap 'unlock_all; rm -rf "${TMP:?}"' EXIT

echo "=== Cipi 5.8.5 regression checks ==="

[[ "$(tr -d '[:space:]' < "${ROOT}/version.md")" == "5.8.5" ]] \
    && pass "version.md is 5.8.5" || fail "version.md is not 5.8.5"
grep -q '^## \[5.8.5\]' "${ROOT}/CHANGELOG.md" && grep -q 'inter-device move failed' "${ROOT}/CHANGELOG.md" \
    && pass "CHANGELOG has a 5.8.5 entry naming the mv error" || fail "CHANGELOG 5.8.5"
for f in api.sh vault.sh; do
    bash -n "${LIB}/${f}" && pass "${f} parses" || fail "${f} does not parse"
done

# ── 0. static: the shape of the fix ──────────────────────────
echo "--- static"
grep -q 'mktemp "\${dir}/.api-ip-whitelist.XXXXXX"' "${LIB}/api.sh" \
    && pass "whitelist temp file is created next to the target" || fail "whitelist temp not next to target"
calls=$(grep -cE '^[[:space:]]+_api_ipwl_write ' "${LIB}/api.sh")
guarded=$(grep -cE '^[[:space:]]+_api_ipwl_write .*\|\| exit 1$' "${LIB}/api.sh")
[[ "$calls" -ge 8 && "$calls" -eq "$guarded" ]] \
    && pass "every _api_ipwl_write call site exits on failure (${calls})" || fail "call sites: ${calls} total, ${guarded} guarded"
grep -A6 '^_api_ipwl_ensure_writable()' "${LIB}/api.sh" | grep -q '_cipi_ensure_config_writable' \
    && pass "write path reuses _cipi_ensure_config_writable (remount attempt)" || fail "no remount attempt on write path"
for fn in vault_write vault_seal; do
    sed -n "/^${fn}() {/,/^}/p" "${LIB}/vault.sh" | grep -q 'mktemp "\$(dirname "\$file")/.\$(basename "\$file").XXXXXX"' \
        && pass "${fn} temp file is created next to the target" || fail "${fn} temp not next to target"
    sed -n "/^${fn}() {/,/^}/p" "${LIB}/vault.sh" | grep -q 'tmp=$(mktemp)$' \
        && fail "${fn} still uses a /tmp temp" || pass "${fn} no longer uses mktemp in /tmp"
done

# ── fixture ──────────────────────────────────────────────────
CFG="${TMP}/etc/cipi"; WL="${CFG}/api-ip-whitelist"
SYSTMP="${TMP}/systmp"          # TMPDIR during runs: must stay empty
CALLS="${TMP}/calls"
mkdir -p "$CFG" "$SYSTMP"; : > "$CALLS"
FN="${TMP}/ipwl.sh"
{
    echo 'RED=; GREEN=; YELLOW=; CYAN=; DIM=; NC=; BOLD='
    echo 'error() { echo "[ERROR] $*" >&2; }; warn() { echo "[WARN] $*"; }; success() { echo "OK $*"; }'
    echo 'log_action() { :; }'
    echo 'parse_args() { local a; for a in "$@"; do case "$a" in --json) ARG_json=true ;; --allow-all) ARG_allow_all=true ;; --ips=*) ARG_ips="${a#--ips=}" ;; esac; done; }'
    echo "_cipi_remount_rw() { echo remount >> '${CALLS}'; _CIPI_REMOUNT_ERR='mount: / is busy'; return 1; }"
    echo '_api_ipwl_public_ip_hint() { echo HINT-CALLED; }'   # must not run when stdout is not a terminal
    # validation is 5.0.6 code with a PHP block; not under test here
    echo '_api_ipwl_valid_entry() { [[ "$1" == "*" || "$1" =~ ^[0-9.]+(/[0-9]+)?$ ]]; }'
    extract vault.sh _cipi_path_writable
    extract vault.sh _cipi_config_writable
    extract vault.sh _cipi_ensure_config_writable
    for fn in _api_ipwl_ensure_file _api_ipwl_in_private_mount_ns _api_ipwl_caller_unit _api_ipwl_ro_error \
              _api_ipwl_ensure_writable _api_ipwl_entries _api_ipwl_is_allow_all _api_ipwl_write \
              api_ip_whitelist_show api_ip_whitelist_add api_ip_whitelist_remove api_ip_whitelist_set api_ip_whitelist_allow_all; do
        extract api.sh "$fn"
    done
} > "$FN"
for fn in _api_ipwl_ro_error _api_ipwl_write api_ip_whitelist_add; do
    grep -q "^${fn}() {" "$FN" && pass "${fn} extracted" || fail "${fn} not extracted"
done

# The functions under test run on Ubuntu's bash 5. bash < 4.4 (macOS /bin/bash
# is 3.2) rejects "${arr[@]}" on an empty array under set -u, which the
# whitelist commands rely on: prefer a newer bash when one is installed,
# otherwise run them without -u.
RUN_BASH="/bin/bash"; RUN_OPTS="-eo pipefail"
for b in /opt/homebrew/bin/bash /usr/local/bin/bash "$(command -v bash 2>/dev/null)"; do
    [[ -n "$b" && -x "$b" ]] || continue
    v=$("$b" -c 'echo $(( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] ))' 2>/dev/null) || continue
    if [[ "$v" -ge 404 ]]; then RUN_BASH="$b"; RUN_OPTS="-euo pipefail"; break; fi
done
echo "  (functions run under ${RUN_BASH}, set ${RUN_OPTS})"

# run [CFGDIR=dir] <fn> [args…] — its own process like `cipi`; output in $TMP/out
run() {
    local cfg="$CFG"
    if [[ "${1:-}" == CFGDIR=* ]]; then cfg="${1#CFGDIR=}"; shift; fi
    ( cd "$TMP" && TMPDIR="$SYSTMP" CIPI_CONFIG="$cfg" CIPI_API_IP_WHITELIST="${cfg}/api-ip-whitelist" \
        "$RUN_BASH" $RUN_OPTS -c 'source "$1"; shift; "$@"' run "$FN" "$@" ) </dev/null > "${TMP}/out" 2>&1
}
entries() { grep -v '^#' "$1" | grep -v '^$' | tr '\n' ' ' | sed 's/ $//'; }
leftovers() { ls -A "$1" 2>/dev/null | grep -c '^\.api-ip-whitelist\.\|^\..*\.json\.' ; }
systmp_empty() { [[ -z "$(ls -A "$SYSTMP" 2>/dev/null)" ]]; }

# ── 1. writes on a writable /etc/cipi ────────────────────────
echo "--- atomic writes"
run api_ip_whitelist_set --ips=1.2.3.4,10.0.0.0/8 && [[ "$(entries "$WL")" == "1.2.3.4 10.0.0.0/8" ]] \
    && pass "set writes the entries" || { fail "set: $(cat "${TMP}/out")"; }
[[ "$(ls -l "$WL" | cut -c1-10)" == "-rw-r--r--" ]] && pass "file mode is 644" || fail "mode: $(ls -l "$WL")"
[[ "$(leftovers "$CFG")" == "0" ]] && pass "no temporary file left next to the list" || fail "leftovers: $(ls -A "$CFG")"
systmp_empty && pass "nothing was created under TMPDIR (temp lives next to the file)" || fail "TMPDIR used: $(ls -A "$SYSTMP")"
run api_ip_whitelist_add 192.168.1.1 && [[ "$(entries "$WL")" == "1.2.3.4 10.0.0.0/8 192.168.1.1" ]] \
    && grep -q "Added 1 entry" "${TMP}/out" && pass "add appends one entry" || fail "add: $(cat "${TMP}/out")"
run api_ip_whitelist_remove 1.2.3.4 && [[ "$(entries "$WL")" == "10.0.0.0/8 192.168.1.1" ]] \
    && pass "remove drops one entry" || fail "remove: $(cat "${TMP}/out")"
run api_ip_whitelist_allow_all && [[ "$(entries "$WL")" == "*" ]] \
    && pass "allow-all resets to *" || fail "allow-all: $(cat "${TMP}/out")"
run api_ip_whitelist_show --json && [[ "$(jq -r '.allow_all' "${TMP}/out")" == "true" ]] \
    && pass "show --json reports allow_all" || fail "show --json: $(cat "${TMP}/out")"
run api_ip_whitelist_show && grep -q "allow all" "${TMP}/out" && ! grep -q "HINT-CALLED" "${TMP}/out" \
    && pass "show skips the public-IP curl when stdout is not a terminal" || fail "hint computed off-terminal: $(cat "${TMP}/out")"
grep -q '^\[\[ -t 1 \]\] && hint=\$(_api_ipwl_public_ip_hint)' <(sed -n '/^api_ip_whitelist_show() {/,/^}/p' "${LIB}/api.sh" | sed 's/^[[:space:]]*//') \
    && pass "the hint is gated on a terminal" || fail "hint not gated on -t 1"
systmp_empty && pass "TMPDIR still empty after add/remove/allow-all" || fail "TMPDIR used: $(ls -A "$SYSTMP")"
[[ ! -s "$CALLS" ]] && pass "no remount attempted while the directory is writable" || fail "remount attempted on a writable dir"

# ── 2. read-only /etc/cipi ───────────────────────────────────
echo "--- read-only /etc/cipi"
run api_ip_whitelist_set --ips=1.2.3.4 || fail "seed: $(cat "${TMP}/out")"
lock "$CFG"
if touch "${CFG}/.probe" 2>/dev/null; then
    rm -f "${CFG}/.probe"
    echo "  SKIP: cannot make ${CFG} read-only as this user (root without chattr?) — RO cases skipped"
else
    if run api_ip_whitelist_add 5.6.7.8; then
        fail "add on a read-only dir returned 0: $(cat "${TMP}/out")"
    else
        pass "add on a read-only dir fails"
    fi
    grep -q "Cannot write ${WL}: ${CFG} is read-only" "${TMP}/out" \
        && pass "error names the file and the read-only directory" || fail "error text: $(cat "${TMP}/out")"
    grep -q "inter-device" "${TMP}/out" && fail "raw mv noise still printed" || pass "no raw mv message"
    grep -q "Remount read-write failed: mount: / is busy" "${TMP}/out" \
        && pass "remount error is reported" || fail "remount error missing: $(cat "${TMP}/out")"
    grep -q "mount -o remount,rw /" "${TMP}/out" && pass "remount-ro hint printed (not sandboxed)" || fail "hint: $(cat "${TMP}/out")"
    grep -q "^remount" "$CALLS" && pass "a remount was attempted first" || fail "no remount attempt"
    [[ "$(entries "$WL")" == "1.2.3.4" ]] && pass "the list is unchanged" || fail "list changed: $(cat "$WL")"
    [[ "$(leftovers "$CFG")" == "0" ]] && pass "no temporary file left behind" || fail "leftovers: $(ls -A "$CFG")"
    run api_ip_whitelist_set --ips=9.9.9.9 && fail "set on RO returned 0" || pass "set on a read-only dir fails"
    run api_ip_whitelist_allow_all && fail "allow-all on RO returned 0" || pass "allow-all on a read-only dir fails"
    run api_ip_whitelist_show && grep -q "1.2.3.4" "${TMP}/out" \
        && pass "show still works on a read-only dir" || fail "show on RO: $(cat "${TMP}/out")"
    run api_ip_whitelist_show --json && [[ "$(jq -r '.entries[0]' "${TMP}/out")" == "1.2.3.4" ]] \
        && pass "show --json still works on a read-only dir" || fail "show --json on RO: $(cat "${TMP}/out")"

    # a read-only dir with no file at all: reads say allow all, nothing aborts
    CFG2="${TMP}/etc/cipi-empty"; mkdir -p "$CFG2"; lock "$CFG2"
    run CFGDIR="$CFG2" api_ip_whitelist_show --json && [[ "$(jq -r '.allow_all' "${TMP}/out")" == "true" ]] \
        && pass "missing file on a read-only dir reads as allow all" || fail "missing+RO: $(cat "${TMP}/out")"
    [[ ! -e "${CFG2}/api-ip-whitelist" ]] && pass "no default file forced onto a read-only dir" || fail "file created on RO dir"
    run CFGDIR="$CFG2" api_ip_whitelist_add 1.1.1.1 && fail "add on empty RO dir returned 0" \
        || { grep -q "is read-only" "${TMP}/out" && pass "add on an empty read-only dir fails clearly" || fail "add empty RO: $(cat "${TMP}/out")"; }
fi

# ── 3. the sandbox diagnosis ─────────────────────────────────
echo "--- sandboxed caller"
( cd "$TMP" && CIPI_CONFIG="$CFG" CIPI_API_IP_WHITELIST="$WL" bash -c '
    source "$1"
    _api_ipwl_in_private_mount_ns() { return 0; }
    _api_ipwl_caller_unit() { echo php8.3-fpm.service; }
    _api_ipwl_ro_error' x "$FN" ) </dev/null > "${TMP}/out" 2>&1
grep -q "started by php8.3-fpm.service" "${TMP}/out" && grep -q "systemctl show php8.3-fpm.service -p ProtectSystem" "${TMP}/out" \
    && pass "a private mount namespace names the unit and the systemctl check" || fail "sandbox text: $(cat "${TMP}/out")"
grep -q "mount -o remount,rw /" "${TMP}/out" && fail "remount-ro hint printed for a sandboxed caller" || pass "no remount-ro hint when sandboxed"
( cd "$TMP" && CIPI_CONFIG="$CFG" CIPI_API_IP_WHITELIST="$WL" bash -c '
    source "$1"
    _api_ipwl_in_private_mount_ns() { return 0; }
    _api_ipwl_caller_unit() { echo; }
    _api_ipwl_ro_error' x "$FN" ) </dev/null > "${TMP}/out" 2>&1
grep -q "systemctl show <unit> -p ProtectSystem" "${TMP}/out" && pass "unknown unit shows a placeholder" || fail "placeholder: $(cat "${TMP}/out")"
if [[ -r /proc/self/cgroup ]]; then
    u=$(bash -c 'source "$1"; _api_ipwl_caller_unit' x "$FN")
    pass "caller unit on this host: '${u:-<none>}' (no error)"
fi

# ── 4. vault_write / vault_seal rename in place ──────────────
echo "--- vault"
CFGV="${TMP}/etc/cipi-vault"; mkdir -p "$CFGV"
echo "testkey" > "${CFGV}/.vault_key"; chmod 400 "${CFGV}/.vault_key"
vrun() {   # vrun <script> — vault.sh sourced fresh each time (readonly VAULT_*)
    ( cd "$TMP" && TMPDIR="$SYSTMP" CIPI_CONFIG="$CFGV" bash -euo pipefail -c "source '${LIB}/vault.sh'; $1" ) </dev/null > "${TMP}/out" 2>&1
}
vrun 'echo "{\"a\":1}" | vault_write apps.json; vault_read apps.json' && [[ "$(jq -c . "${TMP}/out")" == '{"a":1}' ]] \
    && pass "vault_write then vault_read round-trips" || fail "vault round-trip: $(cat "${TMP}/out")"
jq empty "${CFGV}/apps.json" 2>/dev/null && fail "apps.json left in plaintext" || pass "apps.json is encrypted on disk"
[[ "$(ls -l "${CFGV}/apps.json" | cut -c1-10)" == "-rw-------" ]] && pass "vault file mode is 600" || fail "mode: $(ls -l "${CFGV}/apps.json")"
vrun 'echo "{\"a\":2}" | vault_write apps.json; vault_read apps.json' && [[ "$(jq -c . "${TMP}/out")" == '{"a":2}' ]] \
    && pass "vault_write replaces an existing file" || fail "vault replace: $(cat "${TMP}/out")"
systmp_empty && pass "vault temp lives next to the file (TMPDIR untouched)" || fail "TMPDIR used by vault: $(ls -A "$SYSTMP")"
[[ "$(leftovers "$CFGV")" == "0" ]] && pass "no vault temp left behind" || fail "vault leftovers: $(ls -A "$CFGV")"
# a failed encryption: error, old content intact, nothing left behind
( cd "$TMP" && TMPDIR="$SYSTMP" CIPI_CONFIG="$CFGV" VAULT_CIPHER="no-such-cipher" bash -c "source '${LIB}/vault.sh'; echo '{\"a\":3}' | vault_write apps.json" ) </dev/null > "${TMP}/out" 2>&1 \
    && fail "vault_write with a bad cipher returned 0" || pass "vault_write with a bad cipher fails"
grep -q "vault: encryption of apps.json failed" "${TMP}/out" && pass "failed encryption is reported" || fail "no encryption error: $(cat "${TMP}/out")"
vrun 'vault_read apps.json' && [[ "$(jq -c . "${TMP}/out")" == '{"a":2}' ]] && pass "old content survives a failed write" || fail "content after failure: $(cat "${TMP}/out")"
[[ "$(leftovers "$CFGV")" == "0" ]] && pass "failed write leaves no temp" || fail "leftovers after failure: $(ls -A "$CFGV")"
# vault_seal: plaintext → encrypted, same rename
echo '{"b":2}' > "${CFGV}/server.json"
vrun 'vault_seal server.json; vault_read server.json' && [[ "$(jq -c . "${TMP}/out")" == '{"b":2}' ]] \
    && pass "vault_seal encrypts in place and reads back" || fail "vault_seal: $(cat "${TMP}/out")"
jq empty "${CFGV}/server.json" 2>/dev/null && fail "server.json still plaintext after seal" || pass "server.json sealed"
systmp_empty && [[ "$(leftovers "$CFGV")" == "0" ]] && pass "vault_seal: no temp in TMPDIR, none left behind" || fail "vault_seal temps: $(ls -A "$SYSTMP" "$CFGV")"

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]

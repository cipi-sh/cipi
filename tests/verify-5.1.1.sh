#!/bin/bash
# Local regression checks for 5.1.1 (heredoc termination + wildcard domains).
# Run from repo root: bash tests/verify-5.1.1.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/lib"
PASS=0
FAIL=0

pass() { echo "  OK: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

echo "=== Cipi 5.1.1 regression checks ==="

# ── 1. Syntax ───────────────────────────────────────────────────
for f in "${LIB}"/*.sh "${LIB}/migrations/5.1.1.sh"; do
    bash -n "$f" 2>/dev/null && pass "syntax $(basename "$f")" || fail "syntax $(basename "$f")"
done

# ── 2. Every function a library defines survives sourcing ───────
# An unterminated heredoc (5.1.0 shipped `${overrides}EOF`, which does not end
# one) makes the whole tail of the file part of the heredoc body: the functions
# behind it silently stop existing and only blow up at runtime, with
# "<function>: command not found". Sourcing and comparing catches that.
for f in "${LIB}"/*.sh; do
    base=$(basename "$f")
    case "$base" in cipi-*|fix-common-readonly.sh) continue ;; esac
    defined=$(bash -c "set +eu; source '${LIB}/common.sh' >/dev/null 2>&1; source '$f' >/dev/null 2>&1; declare -F | sed 's/^declare -f //'" 2>/dev/null)
    missing=""
    while read -r fn; do
        [[ -n "$fn" ]] || continue
        grep -qx "$fn" <<< "$defined" || missing="${missing} ${fn}"
    done < <(awk '
        match($0, /<<\047[A-Za-z_][A-Za-z0-9_]*\047/) { d=substr($0, RSTART+3, RLENGTH-4); inh=1; next }
        inh && $0 == d { inh=0; next }
        inh { next }
        { print }
    ' "$f" | grep -oE '^[A-Za-z_][A-Za-z0-9_]*\(\)' | sed 's/()//' | sort -u)
    if [[ -z "$missing" ]]; then
        pass "${base}: every declared function is defined after sourcing"
    else
        fail "${base}: swallowed by a heredoc or a syntax error:${missing}"
    fi
done

# ── 3. The FPM pool writer emits a complete file ────────────────
pool_out=$(bash -c '
    set -euo pipefail
    cd "'"${ROOT}"'"
    source lib/common.sh 2>/dev/null || true
    app_get() { echo ""; }
    vault_read() { echo "{\"t\":{\"ini\":{\"memory_limit\":\"512M\",\"display_errors\":\"Off\"}}}"; }
    _app_limit() { echo 5; }
    source lib/app.sh
    tmp=$(mktemp -d)
    declare -f _create_fpm_pool | sed "s#/etc/php/#${tmp}/etc/php/#g" > "${tmp}/f.sh"
    mkdir -p "${tmp}/etc/php/8.5/fpm/pool.d"
    source "${tmp}/f.sh"
    _create_fpm_pool t 8.5
    cat "${tmp}/etc/php/8.5/fpm/pool.d/t.conf"
    rm -rf "$tmp"
' 2>&1)
if grep -q '^\[t\]' <<< "$pool_out" \
   && grep -q '^php_admin_value\[memory_limit\] = 512M$' <<< "$pool_out" \
   && grep -q '^php_admin_flag\[display_errors\] = Off$' <<< "$pool_out" \
   && ! grep -q 'EOF' <<< "$pool_out"; then
    pass "_create_fpm_pool writes a complete pool with per-app overrides"
else
    fail "_create_fpm_pool output is wrong: ${pool_out}"
fi

# ── 4. Wildcard helpers ─────────────────────────────────────────
# shellcheck source=/dev/null
source "${LIB}/common.sh" >/dev/null 2>&1

for d in "*.example.com" "example.com" "www.example.com" "*.a.b.example.com"; do
    validate_domain_or_wildcard "$d" && pass "validate_domain_or_wildcard accepts ${d}" \
        || fail "validate_domain_or_wildcard rejects ${d}"
done
for d in "*" "*." "*.com" "*example.com" "a b.com"; do
    validate_domain_or_wildcard "$d" && fail "validate_domain_or_wildcard accepts ${d}" \
        || pass "validate_domain_or_wildcard rejects ${d}"
done

domain_is_wildcard "*.example.com"  && pass "domain_is_wildcard *.example.com" || fail "domain_is_wildcard *.example.com"
domain_is_wildcard "example.com"    && fail "domain_is_wildcard example.com"   || pass "domain_is_wildcard example.com is false"
[[ "$(domain_cert_name "*.example.com")" == "example.com" ]]     && pass "domain_cert_name strips the wildcard label" || fail "domain_cert_name strips the wildcard label"
[[ "$(domain_cert_name "example.com")"   == "example.com" ]]     && pass "domain_cert_name leaves a plain domain alone" || fail "domain_cert_name leaves a plain domain alone"
[[ "$(domain_url_host  "*.example.com")" == "www.example.com" ]] && pass "domain_url_host names a tenant host" || fail "domain_url_host names a tenant host"
[[ "$(domain_url_host  "example.com")"   == "example.com" ]]     && pass "domain_url_host leaves a plain domain alone" || fail "domain_url_host leaves a plain domain alone"

# ── 5. No "*" reaches certbot --cert-name or the live directory ─
# certbot rejects a lineage name holding "*" and stores a wildcard cert under
# the bare domain, so every one of these has to go through domain_cert_name.
bad=$(grep -rn -- '--cert-name "\${\?\(d\|domain\|dom\|old_domain\)}\?"' "${LIB}/app.sh" "${LIB}/ssl.sh" 2>/dev/null || true)
[[ -z "$bad" ]] && pass "no raw domain is passed as --cert-name" || fail "raw domain passed as --cert-name:
${bad}"
bad=$(grep -rn 'letsencrypt/live/\${\?\(d\|domain\|dom\|old_domain\)}\?"' "${LIB}/app.sh" "${LIB}/ssl.sh" 2>/dev/null || true)
[[ -z "$bad" ]] && pass "no raw domain is used as a lineage directory" || fail "raw domain used as a lineage directory:
${bad}"

# ── 6. A wildcard primary is accepted where it has to be ────────
for spot in \
    'validate_domain_or_wildcard "$domain" || { error "Invalid domain' \
    'validate_domain_or_wildcard "$new_domain" || { error "Invalid domain'; do
    grep -qF "$spot" "${LIB}/app.sh" && pass "app.sh: ${spot:0:52}…" || fail "app.sh missing: ${spot}"
done
grep -q 'domain_is_wildcard "$d"' "${LIB}/ssl.sh" && pass "ssl.sh refuses HTTP-01 for a wildcard primary" || fail "ssl.sh refuses HTTP-01 for a wildcard primary"
grep -q 'domain_is_wildcard "$domain"' "${LIB}/health.sh" && pass "health.sh asks for an explicit --url on a wildcard app" || fail "health.sh asks for an explicit --url on a wildcard app"
grep -q '_www_reject_wildcard' "${LIB}/app.sh" && pass "www force-* refuses a wildcard primary" || fail "www force-* refuses a wildcard primary"

# ── 7. The vhost renders a wildcard server_name ─────────────────
vhost_out=$(bash -c '
    set -euo pipefail
    cd "'"${ROOT}"'"
    source lib/common.sh 2>/dev/null || true
    app_get() { case "$2" in custom) echo "true" ;; *) echo "" ;; esac; }
    vault_read() { echo "{\"w\":{\"aliases\":[\"*.web.example.com\",\"web.example.com\"]}}"; }
    _ensure_nginx_octane_map() { :; }
    source lib/app.sh
    tmp=$(mktemp -d); mkdir -p "${tmp}/etc/nginx/sites-available"
    declare -f _create_nginx_vhost | sed "s#/etc/nginx/#${tmp}/etc/nginx/#g" > "${tmp}/v.sh"
    source "${tmp}/v.sh"
    _create_nginx_vhost w "*.web.example.com" 8.5
    cat "${tmp}/etc/nginx/sites-available/w"
    rm -rf "$tmp"
' 2>&1)
if grep -q '^    server_name \*\.web\.example\.com web\.example\.com;$' <<< "$vhost_out"; then
    pass "_create_nginx_vhost renders a wildcard server_name"
else
    fail "_create_nginx_vhost wildcard server_name: ${vhost_out}"
fi

# ── 8. Migration 5.1.1 is present and repairs both ──────────────
M="${LIB}/migrations/5.1.1.sh"
[[ -f "$M" ]] && pass "migration 5.1.1 exists" || fail "migration 5.1.1 missing"
grep -q '_create_fpm_pool' "$M"    && pass "migration rebuilds FPM pools"    || fail "migration rebuilds FPM pools"
grep -q '_create_nginx_vhost' "$M" && pass "migration repairs drifted vhosts" || fail "migration repairs drifted vhosts"

# ── 9. Version ──────────────────────────────────────────────────
[[ "$(tr -d '[:space:]' < "${ROOT}/version.md")" == "5.1.1" ]] && pass "version.md is 5.1.1" || fail "version.md is not 5.1.1"
grep -q '^## \[5.1.1\]' "${ROOT}/CHANGELOG.md" && pass "CHANGELOG has a 5.1.1 entry" || fail "CHANGELOG has a 5.1.1 entry"

echo ""
echo "=== ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]

#!/bin/bash
# Local regression checks for 5.5.1 — Cipi writes the HTTPS vhost itself and
# certbot only issues/renews certificates, so wildcard certificates (and
# Cloudflare Origin CA ones) are served; certificate names without the
# redundancy Let's Encrypt refuses; a DNS-01 certificate is reissued over
# DNS-01; renewals reload nginx and keep their own challenge; `cipi app list`
# no longer shows every PHP-FPM app as Octane.
# Run from repo root: bash tests/verify-5.5.1.sh
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
    ! grep -nE '"/home/|/etc/nginx/sites-available|/etc/letsencrypt/live|/etc/ssl/cipi-origin' "$@"
}

# Body of a shell function from a file (one-liners included).
fn() {   # <file> <name>
    if grep -qE "^${2}\(\) *\{.*\} *$" "$1"; then
        grep -E "^${2}\(\) *\{" "$1"
    else
        sed -n "/^${2}() *{/,/^}/p" "$1"
    fi
}

# Same, through bash itself: for functions whose heredocs hold a "}" in column
# one (nginx server blocks), which ends a sed range too early. Sourcing app.sh
# only defines functions and two readonly paths.
fnx() {   # <file> <name…>
    bash -c 'CIPI_LIB="$1"; f="$2"; shift 2; source "$f" >/dev/null 2>&1; declare -f "$@"' _ "$LIB" "$@"
}

# The cipi binary defines these; shipped code prints them under set -u.
export RED="" GREEN="" YELLOW="" CYAN="" DIM="" NC="" BOLD=""

echo "=== Cipi 5.5.1 regression checks ==="

[[ "$(tr -d '[:space:]' < "${ROOT}/version.md")" == "5.5.1" ]] \
    && pass "version.md is 5.5.1" || fail "version.md is not 5.5.1"
grep -q '^## \[5.5.1\]' "${ROOT}/CHANGELOG.md" \
    && pass "CHANGELOG has a 5.5.1 entry" || fail "CHANGELOG has no 5.5.1 entry"
[[ -f "${LIB}/migrations/5.5.1.sh" ]] && pass "5.5.1 migration present" || fail "missing 5.5.1 migration"

echo "-- syntax"
for f in "${ROOT}/cipi" "${ROOT}/setup.sh" "${LIB}/app.sh" "${LIB}/common.sh" "${LIB}/ssl.sh" "${LIB}/zt.sh" \
         "${LIB}/completion.sh" "${LIB}/migrations/5.5.1.sh"; do
    bash -n "$f" 2>/dev/null && pass "syntax ${f#"${ROOT}/"}" || { fail "syntax ${f#"${ROOT}/"}"; bash -n "$f"; }
done

# ── helpers from common.sh ────────────────────────────────────
export CIPI_LE_LIVE="${TMP}/le" CIPI_ORIGIN_CERT_DIR="${TMP}/origin"
export CIPI_NGINX_SSL_SNIPPET="${TMP}/snippets/cipi-ssl.conf" CIPI_CERTBOT_RELOAD_HOOK="${TMP}/hooks/cipi-reload-nginx"
for f in domain_is_wildcard domain_cert_name domain_url_host cert_names_for cert_names_cover app_tls_files app_has_tls \
         app_on_cf_tunnel cert_file_names nginx_ensure_ssl_snippet certbot_ensure_reload_hook nginx_vhost_apply_tls parse_args; do
    body=$(fn "${LIB}/common.sh" "$f")
    [[ -n "$body" ]] || { fail "common.sh has no ${f}()"; continue; }
    eval "$body"
done

echo "-- certificate names (cert_names_for)"
names() { cert_names_for "$@" | tr '\n' ' ' | sed 's/ $//'; }
[[ "$(names shop.test www.shop.test '*.shop.test' app.shop.test other.test a.b.shop.test)" == "shop.test *.shop.test other.test a.b.shop.test" ]] \
    && pass "names one label below a wildcard are dropped, the apex, deeper names and other zones stay" \
    || fail "got: $(names shop.test www.shop.test '*.shop.test' app.shop.test other.test a.b.shop.test)"
[[ "$(names www.shop.test shop.test www.shop.test)" == "www.shop.test shop.test" ]] \
    && pass "no wildcard: every name kept once, in order" || fail "got: $(names www.shop.test shop.test www.shop.test)"
[[ "$(names '*.shop.test')" == "*.shop.test" ]] && pass "a wildcard primary alone" || fail "got: $(names '*.shop.test')"
[[ "$(names x.myshop.test '*.shop.test')" == "x.myshop.test *.shop.test" ]] \
    && pass "a name in a zone that only ends like the wildcard is kept" || fail "got: $(names x.myshop.test '*.shop.test')"

echo "-- cert_names_cover"
cov() { printf '%s\n' "${@:2}" | cert_names_cover "$1"; }
cov tenant.shop.test shop.test '*.shop.test' && pass "a tenant is covered by the wildcard" || fail "tenant not covered"
cov shop.test '*.shop.test' && fail "the apex is not covered by its wildcard" || pass "the apex needs its own name"
cov a.b.shop.test '*.shop.test' && fail "two labels down is not covered" || pass "a wildcard covers one label only"
cov '*.shop.test' '*.shop.test' && pass "a wildcard name covers itself" || fail "wildcard does not cover itself"
cov x.myshop.test '*.shop.test' && fail "another zone is not covered" || pass "a zone that only ends the same is not covered"

# ── vhost generation ──────────────────────────────────────────
echo "-- HTTPS vhost written by Cipi"
mkdir -p "${TMP}/sites" "${TMP}/home" "${TMP}/le" "${TMP}/origin" "${TMP}/cipi"
cat > "${TMP}/apps.json" <<'EOF'
{
  "shop":  {"domain": "shop.test", "aliases": ["www.shop.test", "*.shop.test"], "php": "8.5", "www_redirect": "to-root"},
  "tun":   {"domain": "tun.test", "aliases": [], "php": "8.5", "force_https": "true"},
  "plain": {"domain": "plain.test", "aliases": [], "php": "8.5"},
  "wild":  {"domain": "*.wild.test", "aliases": [], "php": "8.5", "force_https": "true"},
  "orig":  {"domain": "orig.test", "aliases": ["*.orig.test"], "php": "8.5", "ssl_origin_ca": "true"},
  "oct":   {"domain": "oct.test", "aliases": [], "php": "8.5", "octane": "frankenphp", "octane_port": "8100", "reverb": "on", "reverb_port": "8200"},
  "susp":  {"domain": "susp.test", "aliases": ["*.susp.test"], "php": "8.5", "suspended": "true"},
  "cust":  {"domain": "cust.test", "aliases": [], "php": "8.4", "custom": true, "docroot": "www", "redirects": [{"from": "/old", "to": "/new"}]}
}
EOF
echo '{"hostnames": {"tun": {"hostname": "tun.test"}}}' > "${TMP}/zt.json"
vault_read() { cat "${TMP}/${1}" 2>/dev/null; }
app_get() { vault_read apps.json | jq -r --arg a "$1" --arg k "$2" '.[$a][$k] // empty'; }
warn() { echo "WARN: $*" >&2; }
info() { :; }
_ensure_nginx_octane_map() { :; }
_ensure_suspended_page() { :; }
export SUSPENDED_DIR=/var/www/cipi-suspended

for d in shop.test tun.test wild.test oct.test susp.test cust.test; do
    mkdir -p "${TMP}/le/${d}"; : > "${TMP}/le/${d}/fullchain.pem"; : > "${TMP}/le/${d}/privkey.pem"
done
mkdir -p "${TMP}/origin/orig"; echo x > "${TMP}/origin/orig/cert.pem"; echo x > "${TMP}/origin/orig/key.pem"

gen="${TMP}/gen.sh"
fnx "${LIB}/app.sh" _create_nginx_vhost _nginx_vhost_tls _create_nginx_vhost_http _nginx_cipi_yml_deny_block \
        _nginx_reverb_location_block _nginx_redirect_location_blocks _nginx_proxy_location_blocks \
        _routes_regex_escape _www_resolve_pair \
    | sed -e "s#/etc/nginx/sites-available/#${TMP}/sites/#g" -e "s#/home/#${TMP}/home/#g" > "$gen"
[[ -s "$gen" ]] || fail "could not extract the vhost generator"
if only_test_paths "$gen" >/dev/null; then
    # shellcheck source=/dev/null
    source "$gen"
    for a in shop tun plain wild orig oct susp cust; do
        _create_nginx_vhost "$a" "$(app_get "$a" domain)" "$(app_get "$a" php)" 2>"${TMP}/${a}.err"
    done
    V="${TMP}/sites"
    blocks() { grep -c '^server {$' "$1"; }
    count() { grep -c -- "$2" "$1" || true; }

    # shop: www → apex block + app block, wildcard alias, redirect mode
    [[ "$(blocks "$V/shop")" == "3" && "$(count "$V/shop" '^    listen 443 ssl;$')" == "2" && "$(count "$V/shop" '^    listen 80;$')" == "1" ]] \
        && pass "every block of the vhost on :443, one :80 block left" || fail "shop: $(blocks "$V/shop") blocks, $(count "$V/shop" 'listen 443') on 443, $(count "$V/shop" 'listen 80;') on 80"
    tail -n 16 "$V/shop" | grep -q '^    server_name www.shop.test shop.test \*.shop.test;$' \
        && pass ":80 redirect block answers every name, the wildcard included" || fail "redirect block names: $(tail -n 16 "$V/shop" | grep server_name)"
    tail -n 16 "$V/shop" | grep -qF 'return 301 https://$host$request_uri;' \
        && pass "tenants are redirected to HTTPS (no 404 for hosts certbot did not know)" || fail "no https redirect for every host"
    tail -n 16 "$V/shop" | grep -qF 'location ^~ /.well-known/acme-challenge/' \
        && pass "ACME challenges stay reachable on :80" || fail "no ACME location on :80"
    [[ "$(count "$V/shop" "ssl_certificate ${TMP}/le/shop.test/fullchain.pem;")" == "2" \
       && "$(count "$V/shop" "include ${CIPI_NGINX_SSL_SNIPPET};")" == "2" ]] \
        && pass "Let's Encrypt fullchain/privkey and the TLS snippet in every :443 block" || fail "certificate lines wrong in shop"
    grep -qF 'return 301 https://shop.test$request_uri;' "$V/shop" \
        && pass "www → apex redirect points at https once a certificate exists" || fail "www redirect scheme not https"
    [[ -f "$CIPI_NGINX_SSL_SNIPPET" ]] && grep -q '^ssl_protocols TLSv1.2 TLSv1.3;$' "$CIPI_NGINX_SSL_SNIPPET" \
        && pass "TLS snippet written (TLS 1.2/1.3)" || fail "TLS snippet missing"

    # tunnel: plain mode
    [[ "$(count "$V/tun" '^    listen 80;$')" == "1" && "$(count "$V/tun" '^    listen 443 ssl;$')" == "1" ]] \
        && ! grep -qF 'return 301 https://$host' "$V/tun" \
        && pass "an app on the Cloudflare tunnel keeps :80 serving the app, :443 added, no redirect" || fail "tunnel vhost wrong"
    # no certificate
    ! grep -q 'listen 443' "$V/plain" && [[ "$(blocks "$V/plain")" == "1" ]] \
        && pass "no certificate: the vhost stays HTTP-only" || fail "plain got HTTPS without a certificate"
    # wildcard primary: lineage under the bare name
    grep -qF "ssl_certificate ${TMP}/le/wild.test/fullchain.pem;" "$V/wild" && grep -q '^    server_name \*.wild.test;$' "$V/wild" \
        && pass "a wildcard primary is served with the lineage named after the bare domain" || fail "wildcard primary cert path wrong"
    # Origin CA
    grep -qF "ssl_certificate ${TMP}/origin/orig/cert.pem;" "$V/orig" && grep -qF "ssl_certificate_key ${TMP}/origin/orig/key.pem;" "$V/orig" \
        && pass "a Cloudflare Origin CA certificate is served on an app that never had HTTPS" || fail "origin CA not applied"
    # Octane + Reverb, suspended, custom with redirects
    grep -q 'location @octane' "$V/oct" && grep -q 'location ~ \^/apps?' "$V/oct" && [[ "$(count "$V/oct" '^    listen 443 ssl;$')" == "1" ]] \
        && pass "Octane + Reverb vhost on :443" || fail "octane vhost wrong"
    grep -q 'return 503' "$V/susp" && [[ "$(count "$V/susp" '^    listen 443 ssl;$')" == "1" ]] \
        && pass "a suspended app is suspended over HTTPS too" || fail "suspended vhost wrong"
    grep -qF 'location = /old' "$V/cust" && [[ "$(count "$V/cust" '^    listen 443 ssl;$')" == "1" ]] \
        && pass "custom app with redirects on :443" || fail "custom vhost wrong"
    errs=$(cat "${TMP}"/*.err 2>/dev/null)
    [[ -z "$errs" ]] && pass "no warning while writing the vhosts" || fail "warnings: ${errs}"

    # regenerating gives the same file (every caller regenerates)
    cp "$V/shop" "${TMP}/shop.first"
    _create_nginx_vhost shop shop.test 8.5 2>/dev/null
    cmp -s "$V/shop" "${TMP}/shop.first" && pass "regenerating the vhost gives the same file" || fail "regeneration differs"

    # a hand-edited / already-HTTPS file is left alone
    cp "$V/shop" "${TMP}/shop.copy"
    nginx_vhost_apply_tls "${TMP}/shop.copy" /c /k redirect && fail "TLS applied twice" || pass "an HTTPS vhost is not transformed again"
    cmp -s "${TMP}/shop.copy" "$V/shop" && pass "…and left byte for byte as it was" || fail "refused file was modified"
    printf 'server {\n  listen 80;\n  server_name x;\n}\n' > "${TMP}/hand"
    nginx_vhost_apply_tls "${TMP}/hand" /c /k redirect && fail "hand-written vhost transformed" || pass "a vhost not written by Cipi is refused"
    ls "${V}"/*.cipi-tls >/dev/null 2>&1 && fail "temp files left in sites" || pass "no temp file left next to the vhosts"

    if command -v nginx >/dev/null 2>&1 && command -v openssl >/dev/null 2>&1; then
        # Full config test with real files: self-signed certificate, logs in $TMP.
        openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=shop.test" \
            -keyout "${TMP}/key.pem" -out "${TMP}/cert.pem" >/dev/null 2>&1
        mkdir -p "${TMP}/ngx/logs" "${TMP}/home/shop/logs"
        sed -e "s#${TMP}/le/shop.test/fullchain.pem#${TMP}/cert.pem#; s#${TMP}/le/shop.test/privkey.pem#${TMP}/key.pem#" "$V/shop" > "${TMP}/ngx/site"
        printf 'pid %s/ngx/nginx.pid;\nerror_log %s/ngx/logs/error.log;\nevents {}\nhttp {\n map $http_upgrade $connection_upgrade { default upgrade; "" close; }\n include %s/ngx/site;\n}\n' \
            "$TMP" "$TMP" "$TMP" > "${TMP}/ngx/nginx.conf"
        : > "${TMP}/ngx/fastcgi_params"
        if nginx -t -q -p "${TMP}/ngx" -c "${TMP}/ngx/nginx.conf" 2>"${TMP}/ngx/t.err"; then
            pass "nginx -t accepts the generated HTTPS vhost"
        else
            fail "nginx -t: $(cat "${TMP}/ngx/t.err")"
        fi
    else
        echo "  SKIP: nginx not installed here — config test runs on a server"
    fi
else
    fail "rewritten generator still holds a real path — not run"
fi

echo "-- app_tls_files"
app_tls_files plain >/dev/null && fail "plain has no certificate" || pass "no certificate: status 1"
mkdir -p "${TMP}/le/orig.test"; : > "${TMP}/le/orig.test/fullchain.pem"; : > "${TMP}/le/orig.test/privkey.pem"
[[ "$(app_tls_files orig | cut -f1)" == "${TMP}/origin/orig/cert.pem" ]] \
    && pass "Origin CA wins while the app is flagged for it" || fail "origin not preferred"
jq '.orig.ssl_origin_ca = ""' "${TMP}/apps.json" > "${TMP}/apps.json.n" && mv "${TMP}/apps.json.n" "${TMP}/apps.json"
[[ "$(app_tls_files orig | cut -f1)" == "${TMP}/le/orig.test/fullchain.pem" ]] \
    && pass "Let's Encrypt once the Origin CA flag is gone" || fail "LE not used after origin flag cleared"

# ── ssl.sh ────────────────────────────────────────────────────
echo "-- cipi ssl install"
grep -n 'certbot install' "${LIB}/ssl.sh" "${LIB}/app.sh" "${LIB}/zt.sh" | grep -v '^\S*:[0-9]*:#' | grep -v 'is never used' \
    && fail "an app vhost is still handed to certbot install" || pass "certbot install is no longer used on app vhosts"
grep -q 'certbot certonly --nginx "${dargs\[@\]}"' "${LIB}/ssl.sh" \
    && pass "HTTP-01 issues with certbot certonly (nginx authenticator only)" || fail "HTTP-01 does not use certonly"
grep -q '_zt_vhost_install_origin' "${LIB}/zt.sh" && fail "Origin CA still edits the vhost with sed" \
    || pass "Origin CA goes through the vhost generator"

ssl="${TMP}/ssl.sh"
sed -e "s#/etc/nginx/sites-available/#${TMP}/sites/#g" -e "s#/home/#${TMP}/home/#g" -e "s#/etc/letsencrypt/live#${TMP}/le#g" "${LIB}/ssl.sh" > "$ssl"
if only_test_paths "$ssl" >/dev/null; then
    export SSL_DNS_DEFAULT_CREDS="${TMP}/cipi/cloudflare.ini" SSL_DNS_DIR="${TMP}/cipi/cloudflare" SSL_RENEWAL_DIR="${TMP}/renewal"
    mkdir -p "${TMP}/cipi/cloudflare"; : > "${TMP}/cipi/cloudflare.ini"; : > "${TMP}/cipi/cloudflare/client-a.ini"
    run_install() {   # <app> [args…]  → prints the certbot arguments, one per line
        (
            # shellcheck source=/dev/null
            source "$ssl"
            app_exists() { true; }
            nginx() { true; }
            certbot() { printf '%s\n' "$@" > "${TMP}/certbot.args"; }
            _ssl_apply_vhost() { true; }
            _ssl_installed() { true; }
            app_set() { echo "set $1 $2=$3" >> "${TMP}/state"; }
            app_unset() { echo "unset $1 $2" >> "${TMP}/state"; }
            error() { echo "ERROR: $*" >> "${TMP}/state"; }
            step() { :; }; success() { :; }; log_action() { :; }; _ssl_zt_lock_http() { false; }
            _ssl_install "$@"
        ) >/dev/null 2>&1
    }
    : > "${TMP}/sites/shop"
    jq '.shop.ssl_dns_provider = "cloudflare" | .shop.ssl_dns_account = "client-a" | .shop.ssl_wildcard = "true"' \
        "${TMP}/apps.json" > "${TMP}/apps.json.n" && mv "${TMP}/apps.json.n" "${TMP}/apps.json"
    rm -f "${TMP:?}/certbot.args"; : > "${TMP}/state"
    run_install shop
    args=$(tr '\n' ' ' < "${TMP}/certbot.args" 2>/dev/null)
    [[ "$args" == *"--dns-cloudflare-credentials ${TMP}/cipi/cloudflare/client-a.ini"* ]] \
        && pass "no flags on a DNS-01 app: reissued over DNS-01 with its own account" || fail "certbot got: ${args}"
    [[ "$args" == *"-d shop.test -d *.shop.test --cert-name shop.test"* && "$args" != *"www.shop.test"* ]] \
        && pass "names: apex + wildcard, www left out (redundant for Let's Encrypt)" || fail "names wrong: ${args}"
    grep -q 'unset shop ssl_origin_ca' "${TMP}/state" && grep -q 'set shop ssl_wildcard=true' "${TMP}/state" \
        && pass "the wildcard is remembered and Let's Encrypt takes over from Origin CA" || fail "state: $(tr '\n' ';' < "${TMP}/state")"

    rm -f "${TMP:?}/certbot.args"; : > "${TMP}/state"
    run_install shop --http
    args=$(tr '\n' ' ' < "${TMP}/certbot.args" 2>/dev/null)
    [[ "$args" == "certonly --nginx -d shop.test -d www.shop.test --cert-name shop.test"* ]] \
        && grep -q 'unset shop ssl_dns_provider' "${TMP}/state" \
        && pass "--http goes back to HTTP-01, without the wildcard name" || fail "certbot got: ${args}"

    rm -f "${TMP:?}/certbot.args"; : > "${TMP}/state"
    run_install plain --wildcard
    [[ ! -f "${TMP}/certbot.args" ]] && grep -q 'needs DNS-01' "${TMP}/state" \
        && pass "--wildcard without DNS-01 is refused before certbot runs" || fail "--wildcard over HTTP-01 not refused"

    rm -f "${TMP:?}/certbot.args"; : > "${TMP}/state"
    run_install plain --dns=cloudflare --wildcard
    args=$(tr '\n' ' ' < "${TMP}/certbot.args" 2>/dev/null)
    [[ "$args" == *"--dns-cloudflare-credentials ${TMP}/cipi/cloudflare.ini"* && "$args" == *"-d plain.test -d *.plain.test "* ]] \
        && pass "--dns=cloudflare --wildcard: default account, apex + *.apex" || fail "certbot got: ${args}"

    rm -f "${TMP:?}/certbot.args"; : > "${TMP}/state"
    run_install shop --dns=cloudflare --no-wildcard --account=client-a
    args=$(tr '\n' ' ' < "${TMP}/certbot.args" 2>/dev/null)
    [[ "$args" == *"-d shop.test -d *.shop.test --cert-name"* ]] \
        && pass "--no-wildcard keeps a wildcard the app serves as an alias" || fail "certbot got: ${args}"
    grep -q 'unset shop ssl_wildcard' "${TMP}/state" && pass "--no-wildcard forgets the --wildcard flag" || fail "ssl_wildcard kept"
else
    fail "rewritten ssl.sh still holds a real path — not run"
fi

# ── renewals ──────────────────────────────────────────────────
echo "-- renewals"
grep -q 'certbot renew --nginx' "${ROOT}/setup.sh" && fail "setup.sh still renews with --nginx" \
    || pass "setup.sh: weekly renewal keeps each certificate's own challenge"
line='10 4 * * 0 /usr/local/bin/cipi-cron-notify ssl-renew certbot renew --nginx --non-interactive --post-hook "systemctl reload nginx" >> /var/log/cipi/certbot.log 2>&1'
expr=$(grep -o "sed 's|certbot renew --nginx |certbot renew |'" "${LIB}/migrations/5.5.1.sh")
[[ -n "$expr" && "$(sed 's|certbot renew --nginx |certbot renew |' <<< "$line")" == *"certbot renew --non-interactive --post-hook"* ]] \
    && pass "migration rewrites the cron line without --nginx" || fail "migration cron rewrite missing or wrong"
certbot_ensure_reload_hook
hook_setup=$(sed -n "/cipi-reload-nginx <<'HOOKEOF'/,/^HOOKEOF/p" "${ROOT}/setup.sh" | sed '1d;$d')
[[ -x "$CIPI_CERTBOT_RELOAD_HOOK" && "$(cat "$CIPI_CERTBOT_RELOAD_HOOK")" == "$hook_setup" ]] \
    && pass "deploy hook: executable, same content from setup.sh and the migration" || fail "hook differs: $(cat "$CIPI_CERTBOT_RELOAD_HOOK")"
grep -q 'nginx -t -q && exec systemctl reload nginx' "$CIPI_CERTBOT_RELOAD_HOOK" \
    && pass "hook reloads nginx only after a passing config test" || fail "hook content wrong"
ino_hook=$(ls -i "$CIPI_CERTBOT_RELOAD_HOOK" | awk '{print $1}'); ino_snip=$(ls -i "$CIPI_NGINX_SSL_SNIPPET" | awk '{print $1}')
certbot_ensure_reload_hook; nginx_ensure_ssl_snippet
[[ "$(ls -i "$CIPI_CERTBOT_RELOAD_HOOK" | awk '{print $1}')" == "$ino_hook" && "$(ls -i "$CIPI_NGINX_SSL_SNIPPET" | awk '{print $1}')" == "$ino_snip" ]] \
    && pass "hook and snippet are not rewritten when their content is current" || fail "hook or snippet rewritten without a change"
ls "$(dirname "$CIPI_CERTBOT_RELOAD_HOOK")" "$(dirname "$CIPI_NGINX_SSL_SNIPPET")" | grep -q '\.tmp$' && fail "temp file left by the hook/snippet writer" \
    || pass "hook and snippet writers leave nothing behind"

# ── cipi app list ─────────────────────────────────────────────
echo "-- cipi app list"
cat > "${TMP}/apps.json" <<'EOF'
{
  "fpmapp": {"domain": "a.test", "php": "8.5", "created_at": "2026-10-03T10:00:00Z", "octane": ""},
  "octapp": {"domain": "b.test", "php": "8.5", "created_at": "2026-10-03T10:00:00Z", "octane": "frankenphp"},
  "nodeapp": {"domain": "c.test", "php": "8.5", "created_at": "2026-10-03T10:00:00Z", "runtime": "node", "node_mode": "spa"},
  "oldapp": {"domain": "d.test", "php": "8.4", "created_at": "2026-10-03T10:00:00Z"}
}
EOF
eval "$(fnx "${LIB}/app.sh" app_list)"
supervisorctl() { :; }; systemctl() { :; }
out=$(app_list 2>/dev/null)
rt() { awk -v a="$1" '$2 == a { print $5 }' <<< "$out"; }
[[ "$(rt fpmapp)" == "fpm" && "$(rt oldapp)" == "fpm" ]] && pass "an app without Octane is listed as fpm" || fail "fpm apps listed as: $(rt fpmapp) / $(rt oldapp)"
[[ "$(rt octapp)" == "octane" ]] && pass "an Octane app is still listed as octane" || fail "octane app listed as: $(rt octapp)"
[[ "$(rt nodeapp)" == "node-spa" ]] && pass "a Node app is listed with its mode" || fail "node app listed as: $(rt nodeapp)"

# ── docs in the binary ───────────────────────────────────────
echo "-- help"
grep -q "Full (strict), never Flexible" "${ROOT}/cipi" && pass "cipi help ssl warns about Cloudflare Flexible" || fail "no Flexible warning in help"
grep -q -- '--no-wildcard --http' "${LIB}/completion.sh" && pass "completion knows --no-wildcard and --http" || fail "completion not updated"

echo ""
echo "=== ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]

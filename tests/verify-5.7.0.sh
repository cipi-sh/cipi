#!/bin/bash
# Local regression checks for 5.7.0 — a domain of their own for the panel API
# and GUI: `cipi api move`, `cipi gui move`, `cipi api remove`, the domain
# checks between panels and apps, and the certificate of a domain nothing
# serves any more.
#
# The functions under test are extracted from their files, their system paths
# are rewritten into ${TMP}, and they run against stubs (vault, certbot,
# nginx, systemctl, sudo), so nothing outside ${TMP} is touched and bash 3.2
# (macOS) is enough.
# Run from repo root: bash tests/verify-5.7.0.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/lib"
PASS=0
FAIL=0
# No "cipi-" in the name: the path rewrite below matches /tmp/cipi-.
TMP=$(mktemp -d "${TMPDIR:-/tmp}/verify570.XXXXXX") || { echo "mktemp failed" >&2; exit 1; }
[[ -n "$TMP" && -d "$TMP" ]] || { echo "no temp dir" >&2; exit 1; }
trap 'rm -rf "${TMP:?}"' EXIT

pass() { echo "  OK: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# The text of one top-level function of a file ("name() {" … "}"). Skips
# heredoc bodies, where a "}" in column 0 (an nginx block) is not the end.
fn() {
    awk -v n="$2" '
        !on && $0 ~ "^"n"\\(\\) \\{" { on = 1 }
        !on { next }
        { print }
        eot != "" { if ($0 ~ "^[[:space:]]*"eot"$") eot = ""; next }
        match($0, /<<-?[[:space:]]*[\047"]?[A-Za-z_]+[\047"]?/) {
            eot = substr($0, RSTART, RLENGTH); gsub(/^<<-?[[:space:]]*|[\047"]/, "", eot); next
        }
        /^}/ { exit }' "$1"
}

echo "=== Cipi 5.7.0 regression checks ==="

[[ "$(tr -d '[:space:]' < "${ROOT}/version.md")" == "5.7.0" ]] \
    && pass "version.md is 5.7.0" || fail "version.md is not 5.7.0"
grep -q '^## \[5.7.0\]' "${ROOT}/CHANGELOG.md" \
    && pass "CHANGELOG has a 5.7.0 entry" || fail "CHANGELOG has no 5.7.0 entry"
for f in "${LIB}/api.sh" "${LIB}/gui.sh" "${LIB}/common.sh" "${LIB}/app.sh" "${LIB}/sync.sh" \
         "${LIB}/yml.sh" "${LIB}/completion.sh" "${ROOT}/cipi"; do
    bash -n "$f" && pass "$(basename "$f") parses" || fail "$(basename "$f") does not parse"
done

# ── harness ──────────────────────────────────────────────────
R="${TMP}/root"
mkdir -p "${R}/etc/cipi" "${R}/etc/nginx/sites-available" "${R}/etc/nginx/sites-enabled" \
    "${R}/etc/letsencrypt/renewal" "${R}/etc/cron.d" "${R}/etc/logrotate.d" "${R}/etc/systemd/system" \
    "${R}/etc/sudoers.d" "${R}/etc/php/8.5/fpm/pool.d" "${R}/run/php" "${R}/usr/local/bin" \
    "${R}/var/log/nginx" "${R}/tmp" "${R}/opt/cipi/api" "${R}/opt/cipi/gui"

{
    cat <<'EOS'
RED=''; GREEN=''; YELLOW=''; CYAN=''; DIM=''; NC=''; BOLD=''
info(){ echo "INFO $*"; }; warn(){ echo "WARN $*"; }; success(){ echo "OK $*"; }
error(){ echo "ERR $*" >&2; }; step(){ echo "STEP $*"; }
log_action(){ echo "log_action $*" >> "${CALLS}"; }
cipi_notify(){ :; }
confirm(){ return 1; }
# 5.8.2: the moves check the DNS of the new name first; here the name always points at the server.
panel_dns_check(){ echo "panel_dns_check $*" >> "${CALLS}"; return 0; }
# 5.8.6: setup writes the www-data sudoers whitelist and remove drops it with the
# last panel (lib/cipi-api-sudoers.sh, exercised in verify-5.8.6.sh); here a no-op.
_panel_sudoers_ensure(){ echo "_panel_sudoers_ensure" >> "${CALLS}"; }
vault_read(){ cat "${CIPI_CONFIG}/$1"; }
vault_write(){ cat > "${CIPI_CONFIG}/$1.tmp" && mv "${CIPI_CONFIG}/$1.tmp" "${CIPI_CONFIG}/$1"; }
certbot(){
    echo "certbot $*" >> "${CALLS}"
    if [[ "$1" == delete ]]; then rm -f "@@R@@/etc/letsencrypt/renewal/${3}.conf"; return 0; fi
    return "${CERTBOT_RC:-0}"
}
reload_nginx(){
    echo "reload_nginx" >> "${CALLS}"
    if [[ -f "${TMP}/nginx-fail-once" ]]; then rm -f "${TMP}/nginx-fail-once"; return 1; fi
    return 0
}
reload_php_fpm(){ echo "reload_php_fpm $*" >> "${CALLS}"; }
nginx(){ return 0; }
systemctl(){ echo "systemctl $*" >> "${CALLS}"; }
sudo(){ echo "sudo $*" >> "${CALLS}"; }
_api_timeout(){ shift; "$@"; }
# The code is written for GNU sed (Ubuntu); BSD sed needs a suffix after -i.
if ! sed --version >/dev/null 2>&1; then
    sed(){ if [[ "${1:-}" == -i ]]; then shift; command sed -i '' "$@"; else command sed "$@"; fi; }
fi
_gui_cd_safe(){ :; }
EOS
    for f in parse_args validate_domain domain_is_used_by_other_app panel_domain domain_is_used_by_panel \
             panel_domain_check panel_cert_names panel_cert_delete panel_env_set _panel_env_set_do panel_env_read; do
        fn "${LIB}/common.sh" "$f"
    done
    # 5.8.6: in the live trees a .env is edited as www-data (panel_env_set in
    # common.sh — exercised with real users in verify-5.8.6.sh). Here the
    # tree is a temporary directory of the test's own.
    echo '_panel_tree_is_www(){ return 1; }'
    for f in api_setup api_ssl _api_ssl_issue _api_create_nginx_vhost _api_set_app_url api_move _api_is_installed api_remove; do
        fn "${LIB}/api.sh" "$f"
    done
    for f in gui_setup gui_ssl _gui_ssl_issue _gui_zt_domain _gui_require_off_tunnel _gui_set_app_url gui_move \
             _gui_create_nginx_vhost _gui_is_installed gui_remove; do
        fn "${LIB}/gui.sh" "$f"
    done
} | sed -e 's#/etc/#@@R@@/etc/#g' -e 's#/run/php/#@@R@@/run/php/#g' -e 's#/var/log/#@@R@@/var/log/#g' \
        -e 's#/usr/local/bin/cipi-api-#@@R@@/usr/local/bin/cipi-api-#g' -e 's#/tmp/cipi-#@@R@@/tmp/cipi-#g' \
  > "${TMP}/lib.tpl"

# Never run a copy that still names a real system path.
if grep -nE '(^|[^@])/(etc|run/php|var/log|tmp/cipi-|usr/local/bin/cipi-api-)' "${TMP}/lib.tpl" >"${TMP}/leaks"; then
    fail "real system paths left in the extracted code:"; cat "${TMP}/leaks" >&2
    echo "=== ${PASS} passed, ${FAIL} failed (aborted) ==="; exit 1
fi
pass "every system path is rewritten into the temp dir"
sed "s#@@R@@#${R}#g" "${TMP}/lib.tpl" > "${TMP}/lib.sh"
for f in api_move api_remove gui_move panel_cert_delete; do
    grep -q "^${f}() {" "${TMP}/lib.sh" && pass "${f} extracted" || fail "${f} not extracted"
done

CALLS="${TMP}/calls"
# Fresh fixture: API at api.example.com with a certificate, GUI at
# panel.example.com, app shop at shop.example.com (+ www alias).
reset_fixture() {
    : > "${CALLS}"
    mkdir -p "${R}/opt/cipi/api" "${R}/opt/cipi/gui"
    rm -f "${R}/etc/cipi/"*.json "${R}/etc/cipi/api-ip-whitelist" "${R}/etc/letsencrypt/renewal/"*.conf "${TMP}/nginx-fail-once"
    echo '{"shop":{"domain":"shop.example.com","aliases":["www.shop.example.com"]}}' > "${R}/etc/cipi/apps.json"
    echo '{"domain":"api.example.com"}' > "${R}/etc/cipi/api.json"
    echo '{"domain":"panel.example.com"}' > "${R}/etc/cipi/gui.json"
    echo '*' > "${R}/etc/cipi/api-ip-whitelist"
    for d in api.example.com api.example.com-0001 panel.example.com other.example.com; do
        echo "# lineage ${d}" > "${R}/etc/letsencrypt/renewal/${d}.conf"
    done
    printf 'APP_URL=https://api.example.com\nAPP_KEY=base64:x\n' > "${R}/opt/cipi/api/.env"
    touch "${R}/opt/cipi/api/artisan"
    printf 'APP_URL=https://panel.example.com\n' > "${R}/opt/cipi/gui/.env"
    touch "${R}/opt/cipi/gui/artisan"
    printf 'server {\n    server_name api.example.com;\n    ssl_certificate /x;\n}\n' > "${R}/etc/nginx/sites-available/cipi-api"
    printf 'server {\n    server_name panel.example.com;\n    ssl_certificate /x;\n}\n' > "${R}/etc/nginx/sites-available/cipi-gui"
    touch "${R}/etc/sudoers.d/cipi-api"
}
# A process of its own, like `cipi` (set -euo pipefail): a subshell called
# from `run … && pass` would run with errexit ignored.
run() {
    TMP="$TMP" CALLS="$CALLS" R="$R" bash -euo pipefail -c '
        CIPI_CONFIG="${R}/etc/cipi"
        CIPI_API_ROOT="${R}/opt/cipi/api" CIPI_API_CONFIG="${R}/etc/cipi/api.json"
        CIPI_API_IP_WHITELIST="${R}/etc/cipi/api-ip-whitelist"
        CIPI_GUI_ROOT="${R}/opt/cipi/gui" CIPI_GUI_CONFIG="${R}/etc/cipi/gui.json"
        source "${TMP}/lib.sh"
        "$@"' run "$@" </dev/null > "${TMP}/out" 2>&1
}
dom() { jq -r '.domain // empty' "${R}/etc/cipi/$1.json" 2>/dev/null; }

# ── 1. domain checks ─────────────────────────────────────────
echo "-- a panel has a domain of its own"
reset_fixture
run domain_is_used_by_panel api.example.com && pass "API domain is a panel domain" || fail "API domain not detected"
run domain_is_used_by_panel API.Example.com && pass "comparison ignores case" || fail "case-sensitive match"
run domain_is_used_by_panel api.example.com api && fail "skip=api still matches the API" || pass "skip leaves out the panel being moved"
run domain_is_used_by_panel panel.example.com api && pass "GUI domain found while moving the API" || fail "GUI domain missed"
run domain_is_used_by_panel shop.example.com && fail "an app domain reported as a panel" || pass "app domain is not a panel domain"
run panel_domain_check shop.example.com api && fail "API allowed on an app domain" \
    || { grep -q "used by app 'shop'" "${TMP}/out" && pass "API refused on an app domain"; } || fail "app conflict message: $(cat "${TMP}/out")"
refused() { if run "$@"; then return 1; fi; grep -q "is used by" "${TMP}/out"; }
refused panel_domain_check www.shop.example.com gui && pass "GUI refused on an app alias" || fail "alias: $(cat "${TMP}/out")"
refused panel_domain_check panel.example.com api && pass "API refused on the GUI domain" || fail "GUI dom: $(cat "${TMP}/out")"
run panel_domain_check api.newco.io api && pass "a free domain passes" || fail "free domain refused: $(cat "${TMP}/out")"

n=$(grep -c 'domain_is_used_by_panel' "${LIB}/app.sh")
[[ "$n" -ge 5 ]] && pass "app create/edit/alias/clone check panel domains (${n})" || fail "app.sh checks panel domains ${n} times"
grep -q 'domain_is_used_by_panel' "${LIB}/sync.sh" && pass "sync import checks panel domains" || fail "sync import does not check"
grep -q 'domain_is_used_by_panel' "${LIB}/yml.sh" && pass "cipi.yml aliases check panel domains" || fail "yml does not check"

# ── 2. setup refuses a second domain ─────────────────────────
echo "-- cipi api|gui <domain> on a configured panel"
reset_fixture
if run api_setup api.newco.io; then fail "api setup changed domain silently"; else
    grep -q 'cipi api move api.newco.io' "${TMP}/out" && pass "api setup on another domain points to move" \
        || fail "api setup message: $(cat "${TMP}/out")"; fi
[[ "$(dom api)" == api.example.com ]] && pass "api.json untouched" || fail "api.json changed to $(dom api)"
if run gui_setup panel.newco.io; then fail "gui setup changed domain silently"; else
    grep -q 'cipi gui move panel.newco.io' "${TMP}/out" && pass "gui setup on another domain points to move" \
        || fail "gui setup message: $(cat "${TMP}/out")"; fi
rm -f "${R}/etc/cipi/api.json"
if run api_setup shop.example.com; then fail "fresh api setup accepted an app domain"; else
    grep -q "used by app 'shop'" "${TMP}/out" && pass "fresh api setup refuses an app domain" || fail "fresh setup: $(cat "${TMP}/out")"; fi

# ── 3. cipi api move ─────────────────────────────────────────
echo "-- cipi api move"
reset_fixture
run api_move api.newco.io && pass "move succeeds" || fail "move failed: $(cat "${TMP}/out")"
[[ "$(dom api)" == api.newco.io ]] && pass "api.json → api.newco.io" || fail "api.json is $(dom api)"
grep -qx 'APP_URL=https://api.newco.io' "${R}/opt/cipi/api/.env" && grep -q '^APP_KEY=base64:x$' "${R}/opt/cipi/api/.env" \
    && pass ".env APP_URL changed, rest kept" || fail ".env: $(cat "${R}/opt/cipi/api/.env")"
grep -q 'server_name api.newco.io;' "${R}/etc/nginx/sites-available/cipi-api" \
    && ! grep -q 'ssl_certificate' "${R}/etc/nginx/sites-available/cipi-api" \
    && pass "vhost rewritten for the new domain" || fail "vhost: $(cat "${R}/etc/nginx/sites-available/cipi-api")"
[[ -L "${R}/etc/nginx/sites-enabled/cipi-api" ]] && pass "vhost enabled" || fail "vhost not enabled"
grep -q 'certbot delete --cert-name api.example.com --non-interactive' "${CALLS}" \
    && grep -q 'certbot delete --cert-name api.example.com-0001 --non-interactive' "${CALLS}" \
    && pass "old lineages deleted (incl. -0001)" || fail "old cert calls: $(cat "${CALLS}")"
grep -q 'certbot delete --cert-name \(panel\|other\)' "${CALLS}" && fail "unrelated lineage deleted" || pass "other lineages kept"
grep -q 'certbot --nginx -d api.newco.io --cert-name api.newco.io' "${CALLS}" \
    && pass "certificate issued for the new domain" || fail "no certbot for new domain: $(cat "${CALLS}")"
grep -q 'https://api.newco.io/api' "${TMP}/out" && pass "summary shows https URLs" || fail "summary: $(cat "${TMP}/out")"
grep -q 'systemctl restart cipi-queue' "${CALLS}" && pass "queue worker restarted" || fail "queue not restarted"
grep -q 'log_action API MOVED: api.example.com → api.newco.io' "${CALLS}" && pass "move logged" || fail "not logged"

reset_fixture
run api_move api.newco.io --no-ssl && pass "move --no-ssl succeeds" || fail "move --no-ssl failed: $(cat "${TMP}/out")"
grep -q 'certbot --nginx' "${CALLS}" && fail "--no-ssl still ran certbot" || pass "--no-ssl issues no certificate"
grep -q 'http://api.newco.io/api' "${TMP}/out" && grep -q 'cipi api ssl' "${TMP}/out" \
    && pass "--no-ssl summary says http and how to add SSL" || fail "--no-ssl summary: $(cat "${TMP}/out")"

reset_fixture
CERTBOT_RC=1 run api_move api.newco.io; rc=$?
[[ $rc -eq 0 ]] && pass "a failed certificate does not undo the move" || fail "move exit ${rc} on SSL failure"
[[ "$(dom api)" == api.newco.io ]] && grep -q 'No certificate yet' "${TMP}/out" \
    && pass "SSL failure reported with next step" || fail "SSL failure output: $(cat "${TMP}/out")"

reset_fixture
touch "${TMP}/nginx-fail-once"
if run api_move api.newco.io; then fail "move succeeded with nginx rejecting the vhost"; else
    grep -q 'server_name api.example.com;' "${R}/etc/nginx/sites-available/cipi-api" \
        && grep -q 'ssl_certificate' "${R}/etc/nginx/sites-available/cipi-api" \
        && pass "nginx failure restores the old vhost (with SSL)" || fail "vhost after rollback: $(cat "${R}/etc/nginx/sites-available/cipi-api")"
    [[ "$(dom api)" == api.example.com ]] && grep -qx 'APP_URL=https://api.example.com' "${R}/opt/cipi/api/.env" \
        && pass "config and APP_URL untouched" || fail "config changed on rollback"
    grep -q 'certbot' "${CALLS}" && fail "certificates touched on rollback" || pass "no certificate touched"
fi

reset_fixture
refused api_move shop.example.com && pass "move refuses an app domain" || fail "app domain: $(cat "${TMP}/out")"
refused api_move panel.example.com && pass "move refuses the GUI domain" || fail "GUI domain: $(cat "${TMP}/out")"
run api_move api.example.com && grep -q 'already at' "${TMP}/out" && pass "same domain is a no-op" || fail "same domain: $(cat "${TMP}/out")"
grep -q 'certbot' "${CALLS}" && fail "refused moves touched certificates" || pass "refused moves touch nothing"

# A pre-5.7 API that shares its domain with an app: the app keeps the certificate.
reset_fixture
echo '{"domain":"shop.example.com"}' > "${R}/etc/cipi/api.json"
echo "# lineage" > "${R}/etc/letsencrypt/renewal/shop.example.com.conf"
run api_move api.example.org --no-ssl && pass "move off a shared domain succeeds" || fail "shared move: $(cat "${TMP}/out")"
grep -q 'certbot delete --cert-name shop.example.com' "${CALLS}" && fail "app certificate deleted" \
    || { grep -q "kept: app 'shop'" "${TMP}/out" && pass "app certificate kept, and said so"; } || fail "shared: $(cat "${TMP}/out")"

# ── 4. cipi api remove ───────────────────────────────────────
echo "-- cipi api remove"
reset_fixture
touch "${R}/etc/cron.d/cipi-api" "${R}/usr/local/bin/cipi-api-maintain" "${R}/usr/local/bin/cipi-api-update" \
      "${R}/etc/logrotate.d/cipi-api-maintain" "${R}/etc/systemd/system/cipi-queue.service" \
      "${R}/etc/php/8.5/fpm/pool.d/cipi-api.conf" "${R}/var/log/cipi-api-php-error.log" "${R}/var/log/cipi-queue.log"
ln -sf "${R}/etc/nginx/sites-available/cipi-api" "${R}/etc/nginx/sites-enabled/cipi-api"
mkdir -p "${R}/opt/cipi/api.old" "${R}/tmp/cipi-api-backup-1700000000"
run api_remove && grep -q 'Cancelled' "${TMP}/out" && [[ -f "${R}/etc/cipi/api.json" ]] \
    && pass "without --force a declined prompt removes nothing" || fail "declined remove: $(cat "${TMP}/out")"
run api_remove --force && pass "remove --force succeeds" || fail "remove failed: $(cat "${TMP}/out")"
left=""
for p in etc/cipi/api.json etc/cipi/api-ip-whitelist etc/nginx/sites-available/cipi-api etc/nginx/sites-enabled/cipi-api \
         etc/cron.d/cipi-api usr/local/bin/cipi-api-maintain usr/local/bin/cipi-api-update etc/logrotate.d/cipi-api-maintain \
         etc/systemd/system/cipi-queue.service etc/php/8.5/fpm/pool.d/cipi-api.conf var/log/cipi-api-php-error.log \
         var/log/cipi-queue.log opt/cipi/api opt/cipi/api.old tmp/cipi-api-backup-1700000000; do
    [[ -e "${R}/${p}" || -L "${R}/${p}" ]] && left="${left} ${p}"
done
[[ -z "$left" ]] && pass "every API file removed" || fail "left behind:${left}"
[[ -f "${R}/etc/sudoers.d/cipi-api" ]] && pass "base sudoers kept" || fail "sudoers removed"
[[ -f "${R}/etc/cipi/gui.json" && -f "${R}/opt/cipi/gui/artisan" && -f "${R}/etc/cipi/apps.json" ]] \
    && pass "GUI and apps untouched" || fail "remove touched GUI or apps"
grep -q 'certbot delete --cert-name api.example.com ' "${CALLS}" && grep -q 'systemctl stop cipi-queue' "${CALLS}" \
    && pass "certificate deleted and queue stopped" || fail "remove calls: $(cat "${CALLS}")"
grep -q 'certbot delete --cert-name panel' "${CALLS}" && fail "GUI certificate deleted" || pass "GUI certificate kept"
run api_remove --force && grep -q 'nothing to remove' "${TMP}/out" && pass "second remove is a no-op" || fail "second remove: $(cat "${TMP}/out")"
grep -q 'api_remove "\$@"' "${LIB}/api.sh" && grep -q 'move)    api_move "\$@"' "${LIB}/api.sh" \
    && pass "router has move and remove" || fail "router"
grep -q 'cipi api ' "${LIB}/cipi-api-sudoers.sh" && grep -E 'cipi api (move|remove|\*)' "${LIB}/cipi-api-sudoers.sh" >/dev/null \
    && fail "www-data may run api move/remove" || pass "www-data cannot run api move/remove"

# ── 5. cipi gui move / remove ────────────────────────────────
echo "-- cipi gui move"
reset_fixture
run gui_move panel.newco.io && pass "gui move succeeds" || fail "gui move failed: $(cat "${TMP}/out")"
[[ "$(dom gui)" == panel.newco.io ]] && grep -qx 'APP_URL=https://panel.newco.io' "${R}/opt/cipi/gui/.env" \
    && pass "gui.json and APP_URL → panel.newco.io" || fail "gui config: $(dom gui)"
grep -q 'server_name panel.newco.io;' "${R}/etc/nginx/sites-available/cipi-gui" && pass "GUI vhost rewritten" || fail "GUI vhost"
grep -q 'certbot delete --cert-name panel.example.com ' "${CALLS}" \
    && grep -q 'certbot --nginx -d panel.newco.io --cert-name panel.newco.io' "${CALLS}" \
    && pass "old GUI cert deleted, new one issued" || fail "gui cert calls: $(cat "${CALLS}")"
grep -q 'certbot delete --cert-name api' "${CALLS}" && fail "API certificate deleted by gui move" || pass "API certificate kept"
refused gui_move api.example.com && pass "gui move refuses the API domain" || fail "gui onto API: $(cat "${TMP}/out")"

reset_fixture
CERTBOT_RC=1 run gui_move panel.newco.io; rc=$?
[[ $rc -eq 0 ]] && grep -q 'SSL failed' "${TMP}/out" && ! grep -q 'OK SSL installed' "${TMP}/out" \
    && pass "failed GUI certificate is reported, not called a success" || fail "gui SSL failure (rc ${rc}): $(cat "${TMP}/out")"

reset_fixture
echo '{"gui":{"domain":"panel.example.com","dns_id":"x"}}' > "${R}/etc/cipi/zt.json"
run gui_move panel.newco.io && fail "GUI moved while on the tunnel" \
    || { grep -q 'cipi zt hostname remove --gui' "${TMP}/out" && pass "move on the tunnel says to remove the hostname first"; } \
    || fail "zt move: $(cat "${TMP}/out")"
[[ "$(dom gui)" == panel.example.com ]] && pass "GUI config untouched" || fail "GUI moved anyway"
if run gui_remove --force; then fail "GUI removed while on the tunnel"; else
    grep -q 'cipi zt hostname remove --gui' "${TMP}/out" && [[ -f "${R}/opt/cipi/gui/artisan" ]] \
        && pass "remove on the tunnel refused" || fail "zt remove: $(cat "${TMP}/out")"; fi
rm -f "${R}/etc/cipi/zt.json"

reset_fixture
run gui_remove --force && pass "gui remove succeeds" || fail "gui remove: $(cat "${TMP}/out")"
[[ ! -e "${R}/opt/cipi/gui" && ! -f "${R}/etc/cipi/gui.json" ]] && pass "GUI files removed" || fail "GUI left behind"
grep -q 'certbot delete --cert-name panel.example.com ' "${CALLS}" && pass "GUI certificate deleted" || fail "GUI cert: $(cat "${CALLS}")"
[[ -f "${R}/etc/cipi/api.json" && -f "${R}/opt/cipi/api/artisan" ]] && pass "API untouched" || fail "gui remove touched the API"

# ── 6. help, completion, status ─────────────────────────────
echo "-- help and completion"
grep -q 'cipi api move <domain>' "${ROOT}/cipi" && grep -q 'cipi api remove' "${ROOT}/cipi" \
    && grep -q 'cipi gui move <domain>' "${ROOT}/cipi" && pass "help lists the new commands" || fail "help"
grep -q 'sub="ssl move remove update' "${LIB}/completion.sh" && grep -q 'sub="ssl move update refresh-theme' "${LIB}/completion.sh" \
    && pass "completion lists move/remove" || fail "completion"
grep -q 'Shares its domain with app' "${LIB}/api.sh" && grep -q 'Shares its domain with app' "${LIB}/gui.sh" \
    && pass "status warns about a shared domain" || fail "status warning"

echo "=== ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]

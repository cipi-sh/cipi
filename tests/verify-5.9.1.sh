#!/bin/bash
# Local regression checks for 5.9.1: the nginx 1.31.9 security release and
# PHP 8.6.
#
# What is checked, and how. The libraries are the real ones, copied under
# the temp dir with their paths rewritten into a fake root, and sourced
# under `set -euo pipefail` like `cipi` sources them. Every command that
# would act on the machine — apt-get, apt-cache, dpkg, dpkg-query, nginx,
# systemctl, pgrep, curl, gpg, php8.x, sleep — is a stub in front of PATH
# that keeps its state in files: which nginx package is installed and which
# one apt would install, whether the running binary is the one on disk,
# which PHP packages the repository has.
#
#   - PHP 8.6 is a version like the others everywhere a list of versions is
#     written; a release candidate is reported as one, not as patched
#   - `cipi php install` on a branch whose redis / memcached / imagick are
#     not packaged yet installs the rest and remembers the three;
#     `cipi php upgrade` installs them when apt has them; `cipi pending`
#     lists them meanwhile
#   - nginx: the security floor, the Ubuntu archive's build told from
#     nginx.org's, an old binary still in memory after an upgrade, HTTP/2
#     found in the loaded configuration, nginx.conf adapted for mainline
#     with everything else in it kept
#   - the move from the Ubuntu archive's nginx to nginx.org mainline: one
#     simulated transaction first, nothing touched when apt cannot do it
#   - setup.sh installs nginx from nginx.org again
#   - the default PHP: a new server gets 8.6 when the repository has a
#     release of it with every extension, 8.5 until then; an existing
#     server keeps its PHP — the migration does not install 8.6, installing
#     it does not make it the server's PHP, and `cipi app create` without
#     --php uses the server's own
#   - migration 5.9.1, run for real against the fake root: both kinds of
#     server, apt refusing, nginx refusing the vhost, a second run
#
# Not here, because it needs a real Ubuntu with apt and nginx: that apt
# resolves the move from the archive's packages to nginx.org's the way the
# stub does, and what the two packages' maintainer scripts do to a running
# nginx. Nothing outside the temp dir is touched.
# Run from repo root: bash tests/verify-5.9.1.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/lib"
PASS=0
FAIL=0

pass() { echo "  OK: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d) && [[ -n "$TMP" && -d "$TMP" ]] || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "${TMP:?}"' EXIT

echo "=== Cipi 5.9.1 regression checks ==="

# ── 0. release files ─────────────────────────────────────────
[[ "$(tr -d '[:space:]' < "${ROOT}/version.md")" == "5.9.1" ]] \
    && pass "version.md is 5.9.1" || fail "version.md is not 5.9.1"
grep -q '^## \[5.9.1\]' "${ROOT}/CHANGELOG.md" && grep -q 'CVE-2026-123007' "${ROOT}/CHANGELOG.md" && grep -q 'CVE-2026-123633' "${ROOT}/CHANGELOG.md" \
    && pass "CHANGELOG has a 5.9.1 entry naming the two CVEs" || fail "CHANGELOG 5.9.1"
for f in common.sh nginx.sh php.sh pending.sh stack-upgrade.sh api.sh gui.sh app.sh ini.sh yml.sh service.sh self-update.sh completion.sh migrations/5.9.1.sh; do
    bash -n "${LIB}/${f}" && pass "${f} parses" || fail "${f} does not parse"
done
bash -n "${ROOT}/setup.sh" && pass "setup.sh parses" || fail "setup.sh does not parse"
bash -n "${ROOT}/cipi" && pass "cipi parses" || fail "cipi does not parse"

# ── 1. static: 8.6 wherever a list of PHP versions is written ─
echo "--- static: PHP 8.6 in every list"
left=$(grep -nE '8\.3.{1,4}8\.4.{1,6}8\.5' "${ROOT}/cipi" "${ROOT}/setup.sh" "${LIB}"/*.sh | grep -v '8\.6' || true)
[[ -z "$left" ]] && pass "no list of versions stops at 8.5" || fail "lists without 8.6: ${left}"
grep -q '8.3|8.4|8.5|8.6) return 0' "${LIB}/common.sh" && pass "validate_php_version accepts 8.6" || fail "validate_php_version"
grep -q -- "--argjson installable '\[\"8.3\",\"8.4\",\"8.5\",\"8.6\"\]'" "${LIB}/php.sh" \
    && pass "cipi php list --json offers 8.6 as installable" || fail "installable list"
grep -q 'PHP_VERSIONS = {"8.3", "8.4", "8.5", "8.6"}' "${LIB}/yml.sh" && pass ".cipi.yml accepts php: \"8.6\"" || fail "yml PHP_VERSIONS"
grep -q 'for v in 7.4 8.0 8.1 8.2 8.3 8.4 8.5 8.6; do' "${ROOT}/cipi" && pass "cipi status lists a running 8.6, and a legacy one where it still runs" || fail "cipi status PHP loop"
grep -q 'php_ver=\$(php_app_default)' "${LIB}/app.sh" && ! grep -q 'ARG_php:-8\.' "${LIB}/app.sh" \
    && pass "cipi app create without --php takes the server's PHP, not a version written in the code" || fail "app create default PHP"
! grep -n 'reload_php_fpm "8.5"' "${LIB}"/*.sh | grep -q . \
    && pass "nothing restarts PHP-FPM 8.5 by name any more (the panel's pool is on the system PHP)" || fail "reload_php_fpm \"8.5\" is still hardcoded"
grep -c 'reload_php_fpm "\$(php_system_version)"' "${LIB}/api.sh" | grep -qx 3 && pass "cipi api restarts the FPM of the system PHP" || fail "api.sh reload_php_fpm"
grep -q '^readonly PHP_DEFAULT="8.6"$' "${ROOT}/setup.sh" && grep -q '^readonly PHP_FALLBACK="8.5"$' "${ROOT}/setup.sh" \
    && ! grep -qE 'php8\.[0-9]|for VER in 8\.' "${ROOT}/setup.sh" \
    && pass "setup.sh: a new server's PHP is 8.6, 8.5 the fallback, and no version is written anywhere else" || fail "setup.sh default PHP"
grep -q 'PHP \${PHP_DEFAULT} (FPM)' "${ROOT}/setup.sh" && awk '/^final_summary\(\) \{/,/^}/' "${ROOT}/setup.sh" | grep -q 'PHP_DEFAULT_SKIPPED' \
    && pass "setup.sh: the plan names 8.6, and the last screen says when the server got 8.5 instead" || fail "setup.sh plan / final summary"

# ── 2. static: setup.sh installs nginx.org mainline ──────────
echo "--- static: setup.sh nginx"
S="${ROOT}/setup.sh"
! grep -q 'libnginx-mod-http-headers-more-filter' "$S" && ! grep -q 'more_clear_headers' "$S" && ! grep -q 'modules-enabled' "$S" \
    && pass "setup.sh: no Ubuntu nginx module, no headers-more directive, no modules-enabled include" || fail "setup.sh still installs or configures the Ubuntu archive's nginx"
grep -q 'https://nginx.org/packages/mainline/ubuntu' "$S" && grep -q 'https://nginx.org/keys/nginx_signing.key' "$S" \
    && grep -q 'Pin: origin nginx.org' "$S" && grep -q '/etc/apt/preferences.d/99nginx' "$S" \
    && pass "setup.sh: nginx.org mainline repository, key and pin" || fail "setup.sh: nginx.org repository"
grep -q 'apt installed the Ubuntu archive' "$S" && pass "setup.sh stops when apt hands it the archive's nginx anyway" || fail "setup.sh does not check which nginx it got"
tpl_setup=$(awk '/cat > \/etc\/nginx\/nginx.conf <<NGINXEOF/ { f = 1; next } /^NGINXEOF/ { f = 0 } f' "$S" | grep -v '^#' | sed 's/\${CPU_CORES}/N/')
tpl_lib=$(awk '/cat > \/etc\/nginx\/nginx.conf <<NGINXEOF/ { f = 1; next } /^NGINXEOF/ { f = 0 } f' "${LIB}/nginx.sh" | grep -v '^#' | sed 's/\${worker_processes}/N/')
[[ -n "$tpl_setup" && "$tpl_setup" == "$tpl_lib" ]] \
    && pass "setup.sh and lib/nginx.sh write the same nginx.conf" || fail "the two nginx.conf templates differ: $(diff <(echo "$tpl_setup") <(echo "$tpl_lib") | head -5)"
grep -q 'max_headers 1000;' <<< "$tpl_setup" && pass "a new server has max_headers" || fail "setup.sh nginx.conf without max_headers"
! awk '/_api_create_nginx_vhost\(\) \{/,/^}/' "${LIB}/api.sh" | grep -qE '^[[:space:]]*alias ' \
    && awk '/_api_create_nginx_vhost\(\) \{/,/^}/' "${LIB}/api.sh" | grep -q 'location /api-docs' \
    && pass "the panel API vhost serves /api-docs without an alias" || fail "api.sh vhost still has alias + try_files"

# ── fake root, rewritten libs, stubs ─────────────────────────
FAKE="${TMP}/root"; STATE="${TMP}/state"; BIN="${TMP}/bin"; LIBT="${TMP}/lib"
mkdir -p "$BIN" "${LIBT}/migrations"
rewrite() {
    sed -e "s#/etc/nginx/#${FAKE}/etc/nginx/#g" \
        -e "s#/usr/share/keyrings/#${FAKE}/usr/share/keyrings/#g" \
        -e "s#/etc/apt/#${FAKE}/etc/apt/#g" \
        -e "s#/var/www/html#${FAKE}/var/www/html#g" \
        -e "s#/etc/php/#${FAKE}/etc/php/#g" \
        -e "s#/var/lib/cipi/#${FAKE}/var/lib/cipi/#g" \
        -e "s#/run/cipi-#${FAKE}/run/cipi-#g" "$1"
}
for f in "${LIB}"/*.sh; do rewrite "$f" > "${LIBT}/$(basename "$f")"; done
rewrite "${LIB}/migrations/5.9.1.sh" > "${LIBT}/migrations/5.9.1.sh"
# The PHP repository helpers would configure apt for real.
cat > "${LIBT}/php-apt.sh" <<'EOF'
php_setup_apt_sources() { return 0; }
php_apt_source_label() { echo "packages.sury.org"; }
EOF

stub() { cat > "${BIN}/$1"; chmod +x "${BIN}/$1"; }

stub apt-get <<'EOF'
#!/bin/bash
S="$STATE"
echo "apt-get $*" >> "$S/apt.log"
sim=0; only=0; cmd=""; skip=0; pkgs=""
for a in "$@"; do
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    case "$a" in
        -o) skip=1 ;;
        -s) sim=1 ;;
        --only-upgrade) only=1 ;;
        -*) ;;
        install|update|purge|autoremove) if [ -z "$cmd" ]; then cmd="$a"; else pkgs="$pkgs $a"; fi ;;
        *) pkgs="$pkgs $a" ;;
    esac
done
[ "$cmd" = install ] || exit 0
ok=1
for p in $pkgs; do
    case "$p" in php*) if [ -f "$S/apt.available" ] && ! grep -qx "$p" "$S/apt.available"; then ok=0; fi ;; esac
done
if [ "$sim" = 1 ]; then
    [ "$ok" = 1 ] || exit 100
    rc=$(cat "$S/apt.sim.rc" 2>/dev/null || echo 0)
    [ "$rc" = 0 ] || exit "$rc"
    for p in $pkgs; do
        if [ "$p" = nginx ] && [ "$(cat "$S/nginx.pkg")" != "$(cat "$S/nginx.cand")" ]; then
            echo "Inst nginx [$(cat "$S/nginx.pkg")] ($(cat "$S/nginx.cand") nginx:mainline [amd64])"
        fi
    done
    exit 0
fi
[ "$ok" = 1 ] || { echo "E: Unable to locate package" >&2; exit 100; }
rc=$(cat "$S/apt.install.rc" 2>/dev/null || echo 0)
[ "$rc" = 0 ] || exit "$rc"
for p in $pkgs; do
    case "$p" in
        nginx)
            if [ "$(cat "$S/nginx.pkg")" != "$(cat "$S/nginx.cand")" ]; then
                cp "$S/nginx.cand" "$S/nginx.pkg"
                sed 's/-.*//' "$S/nginx.cand" > "$S/nginx.ver"
                # What an upgrade leaves behind: the old binary still running…
                rm -rf "$S/proc"; mkdir -p "$S/proc/100"; ln -s "/usr/sbin/nginx (deleted)" "$S/proc/100/exe"
                # …or, when the archive's packages go, nginx stopped.
                if [ -f "$S/apt.stops.nginx" ]; then echo no > "$S/nginx.active"; rm -rf "$S/proc"; mkdir -p "$S/proc"; fi
            fi ;;
        libnginx-mod-http-headers-more-filter-) rm -f "$S/headers-more" ;;
        php*-fpm)
            v=${p#php}; v=${v%-fpm}
            mkdir -p "$FAKE/etc/php/$v/fpm/conf.d" "$FAKE/etc/php/$v/fpm/pool.d"
            grep -qx "$v" "$S/php.installed" 2>/dev/null || echo "$v" >> "$S/php.installed"
            grep -qx "$p" "$S/apt.installed" 2>/dev/null || echo "$p" >> "$S/apt.installed" ;;
        php*-cli)
            # An alternative left on automatic goes to the version just installed.
            if [ -f "$S/alt.auto" ]; then v=${p#php}; echo "${v%-cli}" > "$S/php.sys"; fi
            grep -qx "$p" "$S/apt.installed" 2>/dev/null || echo "$p" >> "$S/apt.installed" ;;
        php*) grep -qx "$p" "$S/apt.installed" 2>/dev/null || echo "$p" >> "$S/apt.installed" ;;
    esac
done
[ "$only" = 1 ] && echo "$(cat "$S/apt.upgraded" 2>/dev/null || echo 0) upgraded, 0 newly installed, 0 to remove and 0 not upgraded."
exit 0
EOF

stub apt-cache <<'EOF'
#!/bin/bash
[ "$1" = policy ] || exit 0
case "$2" in
    nginx) printf 'nginx:\n  Installed: %s\n  Candidate: %s\n' "$(cat "$STATE/nginx.pkg")" "$(cat "$STATE/nginx.cand")" ;;
    php*-fpm) [ -f "$STATE/$2.cand" ] && printf '%s:\n  Installed: (none)\n  Candidate: %s\n' "$2" "$(cat "$STATE/$2.cand")" ;;
esac
exit 0
EOF

# The `php` alternative: --set makes that version the php command.
stub update-alternatives <<'EOF'
#!/bin/bash
echo "update-alternatives $*" >> "$STATE/alt.log"
if [ "$1" = "--set" ] && [ "$2" = php ]; then echo "${3##*/php}" > "$STATE/php.sys"; fi
exit 0
EOF

stub dpkg <<'EOF'
#!/bin/bash
[ "$1" = "-l" ] || exit 0
v=${2#php}; v=${v%-fpm}
grep -qx "$v" "$STATE/php.installed" 2>/dev/null
EOF

stub dpkg-query <<'EOF'
#!/bin/bash
S="$STATE"; fmt=""; last=""
for a in "$@"; do case "$a" in -f=*) fmt="${a#-f=}" ;; -W) ;; *) last="$a" ;; esac; done
case "$fmt" in
    *'Status-Status} ${Package}'*)
        echo "installed nginx"
        case "$(cat "$S/nginx.pkg")" in *ubuntu*) echo "installed nginx-common" ;; esac
        exit 0 ;;
    *'${Package}'*) cat "$S/apt.installed" 2>/dev/null; exit 0 ;;
    *'Status-Status'*)
        if [ "$last" = libnginx-mod-http-headers-more-filter ] && [ -f "$S/headers-more" ]; then printf installed; exit 0; fi
        exit 1 ;;
    *'${Version}'*)
        case "$last" in
            nginx) tr -d '\n' < "$S/nginx.pkg" 2>/dev/null ;;
            php*-fpm) tr -d '\n' < "$S/${last}.pkg" 2>/dev/null ;;
        esac
        exit 0 ;;
esac
exit 0
EOF

stub nginx <<'EOF'
#!/bin/bash
S="$STATE"; conf="$FAKE/etc/nginx/nginx.conf"
case "$1" in
    -v) echo "nginx version: nginx/$(cat "$S/nginx.ver")" >&2 ;;
    -t)
        echo "nginx -t" >> "$S/nginx.log"
        [ -f "$S/nginx.t.fail" ] && { echo "nginx: [emerg] refused" >&2; exit 1; }
        case "$(cat "$S/nginx.pkg")" in
            *ubuntu*) grep -q 'max_headers' "$conf" && { echo 'nginx: [emerg] unknown directive "max_headers"' >&2; exit 1; } ;;
            *) grep -qE 'more_clear_headers|modules-enabled|only_on_ubuntu' "$conf" && { echo 'nginx: [emerg] unknown directive' >&2; exit 1; } ;;
        esac
        if grep -q 'map \$http_upgrade' "$conf" && [ -f "$FAKE/etc/nginx/conf.d/cipi-octane-map.conf" ]; then
            echo 'nginx: [emerg] duplicate "connection_upgrade" variable' >&2; exit 1
        fi
        exit 0 ;;
    -T) cat "$S/nginx.T" 2>/dev/null ;;
esac
exit 0
EOF

stub systemctl <<'EOF'
#!/bin/bash
S="$STATE"; echo "systemctl $*" >> "$S/systemctl.log"
case "$1" in
    is-active)
        u="${@: -1}"
        [ "$u" = nginx ] || exit 0
        [ "$(cat "$S/nginx.active" 2>/dev/null)" = yes ] ;;
    restart)
        if [ "$2" = nginx ]; then
            [ -f "$S/nginx.wont.start" ] && exit 1
            echo yes > "$S/nginx.active"
            rm -rf "$S/proc"; mkdir -p "$S/proc/200"; ln -s /usr/sbin/nginx "$S/proc/200/exe"
        fi
        exit 0 ;;
    *) exit 0 ;;
esac
EOF

stub pgrep <<'EOF'
#!/bin/bash
ls "$STATE/proc" 2>/dev/null
exit 0
EOF

stub sleep <<'EOF'
#!/bin/bash
echo "sleep $*" >> "$STATE/sleep.log"
# The old workers closing their last connection while we wait.
if [ -f "$STATE/sleep.clears" ]; then
    rm -rf "$STATE/proc"; mkdir -p "$STATE/proc/200"; ln -s /usr/sbin/nginx "$STATE/proc/200/exe"
fi
exit 0
EOF

stub curl <<'EOF'
#!/bin/bash
[ -f "$STATE/curl.fail" ] && exit 22
echo "KEY-$(cat "$STATE/curl.key" 2>/dev/null || echo 1)"
EOF
stub gpg <<'EOF'
#!/bin/bash
cat
EOF
stub lsb_release <<'EOF'
#!/bin/bash
echo noble
EOF
stub nproc <<'EOF'
#!/bin/bash
echo 4
EOF
stub flock <<'EOF'
#!/bin/bash
exit 0
EOF
stub php <<'EOF'
#!/bin/bash
n=$(basename "$0")
case "$2" in
    *PHP_EXTRA_VERSION*)   printf '%s' "$(cat "$STATE/$n.extra" 2>/dev/null)" ;;
    *PHP_RELEASE_VERSION*) printf '%s' "$(cat "$STATE/$n.full" 2>/dev/null)" ;;
    *)                     printf '%s' "$(cat "$STATE/php.sys" 2>/dev/null || echo 8.5)" ;;
esac
EOF
for v in 8.1 8.2 8.3 8.4 8.5 8.6; do cp "${BIN}/php" "${BIN}/php${v}"; done

reset_state() {
    rm -rf "${STATE:?}" "${FAKE:?}"
    mkdir -p "${STATE}/proc/200" "${FAKE}/etc/nginx/conf.d" "${FAKE}/etc/nginx/sites-available" "${FAKE}/etc/nginx/sites-enabled" \
        "${FAKE}/etc/apt/sources.list.d" "${FAKE}/etc/apt/preferences.d" "${FAKE}/usr/share/keyrings" \
        "${FAKE}/var/lib/cipi" "${FAKE}/run" "${FAKE}/etc/cipi" "${FAKE}/var/log/cipi"
    ln -s /usr/sbin/nginx "${STATE}/proc/200/exe"
    echo yes > "${STATE}/nginx.active"
    : > "${STATE}/apt.log"; : > "${STATE}/systemctl.log"; : > "${STATE}/nginx.log"; : > "${STATE}/sleep.log"
}
set_nginx() {   # <upstream version> <installed package> <package apt would install>
    echo "$1" > "${STATE}/nginx.ver"; echo "$2" > "${STATE}/nginx.pkg"; echo "${3:-$2}" > "${STATE}/nginx.cand"
}
proc_stale() { rm -rf "${STATE}/proc"; mkdir -p "${STATE}/proc/100"; ln -s "/usr/sbin/nginx (deleted)" "${STATE}/proc/100/exe"; }
set_php() {     # <branch> <x.y.z> [extra]
    echo "$2" > "${STATE}/php${1}.full"; printf '%s' "${3:-}" > "${STATE}/php${1}.extra"
    grep -qx "$1" "${STATE}/php.installed" 2>/dev/null || echo "$1" >> "${STATE}/php.installed"
    echo "${2}-1+ubuntu24.04.1+deb.sury.org+1" > "${STATE}/php${1}-fpm.pkg"
}

# Runs a snippet the way `cipi` would: the libraries sourced, set -euo pipefail.
L() {
    PATH="${BIN}:${PATH}" STATE="$STATE" FAKE="$FAKE" CIPI_LIB="$LIBT" CIPI_CONFIG="${FAKE}/etc/cipi" CIPI_LOG="${FAKE}/var/log/cipi" \
        _NGINX_PROC="${STATE}/proc" _NGINX_STALE_WAIT=2 \
        bash -c 'set -euo pipefail
                 RED=""; GREEN=""; YELLOW=""; CYAN=""; DIM=""; NC=""; BOLD=""
                 source "$CIPI_LIB/common.sh"
                 cipi_notify() { echo "NOTIFY $1" >> "$STATE/notify.log"; }
                 '"$1"
}
MIG() {
    PATH="${BIN}:${PATH}" STATE="$STATE" FAKE="$FAKE" CIPI_LIB="$LIBT" CIPI_CONFIG="${FAKE}/etc/cipi" CIPI_LOG="${FAKE}/var/log/cipi" \
        _NGINX_PROC="${STATE}/proc" _NGINX_STALE_WAIT=2 bash "${LIBT}/migrations/5.9.1.sh" 2>&1
}

# nginx.conf as the setup.sh of 4.6.5–5.9.0 wrote it (Ubuntu archive nginx),
# with one line an admin added.
ubuntu_conf() {
    cat > "${FAKE}/etc/nginx/nginx.conf" <<'EOF'
user www-data;
worker_processes 2;
worker_rlimit_nofile 65535;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 8192;
    multi_accept on;
}

http {
    sendfile on;
    server_tokens off;
    more_clear_headers 'Server' 'X-Powered-By';
    client_body_timeout 33s;

    include /etc/nginx/mime.types;
    limit_req_zone $binary_remote_addr zone=global:10m rate=30r/s;

    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF
}
mainline_conf() {
    cat > "${FAKE}/etc/nginx/nginx.conf" <<'EOF'
user www-data;
worker_processes 2;
http {
    server_tokens off;
    max_headers 1000;
    include /etc/nginx/sites-enabled/*;
}
EOF
}
api_vhost() {   # [alias target]
    cat > "${FAKE}/etc/nginx/sites-available/cipi-api" <<EOF
server {
    listen 443 ssl;
    server_name panel.example.com;
    root /opt/cipi/api/public;
    index index.php;
    location /api-docs {
        alias ${1:-/opt/cipi/api/public/api-docs};
        try_files \$uri =404;
    }
    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }
}
EOF
}

# ── 3. PHP 8.6: accepted, and a release candidate is not "patched" ──
echo "--- functional: PHP 8.6"
reset_state
out=$(L 'validate_php_version 8.6 && validate_php_version_known 8.6 && ! validate_php_version 8.7 && ! validate_php_version 8.2 && echo ok' 2>&1)
[[ "$out" == "ok" ]] && pass "8.6 is a valid version for apps; 8.7 and 8.2 are not" || fail "validate_php_version: ${out}"
[[ "$(L 'php_security_floor 8.6')" == "8.6.0" ]] && pass "the security floor of 8.6 is its first release" || fail "php_security_floor 8.6"
set_php 8.6 8.6.0 RC5
[[ "$(L 'php_security_state 8.6')" == "prerelease 8.6.0RC5" ]] && pass "8.6.0RC5 is reported as a pre-release, not as patched" || fail "RC5: $(L 'php_security_state 8.6')"
set_php 8.6 8.6.0 -dev
[[ "$(L 'php_security_state 8.6')" == "prerelease 8.6.0-dev" ]] && pass "…and so is a -dev build" || fail "-dev: $(L 'php_security_state 8.6')"
set_php 8.6 8.6.0 ""
[[ "$(L 'php_security_state 8.6')" == "patched 8.6.0" ]] && pass "8.6.0 itself is patched" || fail "8.6.0: $(L 'php_security_state 8.6')"
set_php 8.6 8.6.1 "+local"
[[ "$(L 'php_security_state 8.6')" == "patched 8.6.1" ]] && pass "a packager's own suffix does not make a release a pre-release" || fail "suffix: $(L 'php_security_state 8.6')"
set_php 8.5 8.5.1 ""
[[ "$(L 'php_security_state 8.5')" == "vulnerable 8.5.1" ]] && pass "the other branches are judged as before (8.5.1 on sury.org: vulnerable)" || fail "8.5.1: $(L 'php_security_state 8.5')"
[[ "$(L 'for v in 8.2 8.3 8.4 8.5 8.6; do printf "%s " "$(php_security_floor $v)"; done')" == "8.2.36 8.3.37 8.4.28 8.5.13 8.6.0 " ]] \
    && pass "the floors are the security releases of 2026-11-19 (8.2.36, 8.3.37, 8.4.28, 8.5.13) and 8.6.0" || fail "php_security_floor: $(L 'for v in 8.2 8.3 8.4 8.5 8.6; do printf "%s " "$(php_security_floor $v)"; done')"
set_php 8.5 8.5.12 ""; set_php 8.4 8.4.27 ""; set_php 8.3 8.3.37 ""; set_php 8.2 8.2.36 ""
[[ "$(L 'php_security_state 8.5')" == "vulnerable 8.5.12" && "$(L 'php_security_state 8.4')" == "vulnerable 8.4.27" ]] \
    && pass "the releases that were the floor until today (8.5.12, 8.4.27) are now reported vulnerable" || fail "old floor: $(L 'php_security_state 8.5') / $(L 'php_security_state 8.4')"
[[ "$(L 'php_security_state 8.3')" == "patched 8.3.37" && "$(L 'php_security_state 8.2')" == "patched 8.2.36" ]] \
    && pass "8.3.37 and 8.2.36 are patched" || fail "new floor: $(L 'php_security_state 8.3') / $(L 'php_security_state 8.2')"
[[ -z "$(L 'php_security_floor 8.1')" ]] && pass "8.1 and older have no floor: end of life" || fail "php_security_floor 8.1"
[[ "$(L 'php_system_version')" == "8.5" ]] && pass "php_system_version is what the php command answers" || fail "php_system_version"

# ── 4. cipi php install on a branch without all its extensions ──
echo "--- functional: extensions the repository does not have yet"
EXT="fpm common cli curl bcmath mbstring mysql sqlite3 pgsql memcached redis zip xml soap gd imagick intl"
avail() {   # <branch> <extensions missing…>
    local v="$1" e m skip; shift
    for e in $EXT; do
        skip=0; for m in "$@"; do [[ "$m" == "$e" ]] && skip=1; done
        [[ "$skip" -eq 1 ]] || echo "php${v}-${e}"
    done
}
reset_state
avail 8.6 redis memcached imagick > "${STATE}/apt.available"
echo "8.6.0" > "${STATE}/php8.6.full"; printf 'RC5' > "${STATE}/php8.6.extra"
out=$(L 'source "$CIPI_LIB/php.sh"; _php_install 8.6' 2>&1); rc=$?
PEND="${FAKE}/var/lib/cipi/php-ext-pending"
real=$(grep -E '^apt-get install -y -qq php8\.6-' "${STATE}/apt.log" || true)
[[ $rc -eq 0 ]] && pass "php install 8.6 succeeds with three extensions missing from the repository" || fail "php install 8.6: rc=${rc}: ${out}"
[[ -n "$real" && "$real" == *"php8.6-fpm"* && "$real" == *"php8.6-intl"* && "$real" != *redis* && "$real" != *memcached* && "$real" != *imagick* ]] \
    && pass "apt is asked for the 14 packages it has, not for the three it lacks" || fail "apt install line: ${real}"
[[ "$(cat "$PEND" 2>/dev/null)" == $'8.6 memcached\n8.6 redis\n8.6 imagick' ]] && pass "the three are remembered in php-ext-pending" || fail "php-ext-pending: $(cat "$PEND" 2>&1)"
grep -q 'installed without: memcached redis imagick' <<< "$out" && grep -q 'phpredis' <<< "$out" \
    && pass "the operator is told which, and what it means for a Laravel app" || fail "no warning about the missing extensions: ${out}"
grep -q 'pre-release (8.6.0RC5)' <<< "$out" && pass "…and that what the repository has is a release candidate" || fail "no pre-release warning: ${out}"
grep -q '^expose_php = Off$' "${FAKE}/etc/php/8.6/fpm/conf.d/99-cipi.ini" && grep -q '^listen.mode = 0600$' "${FAKE}/etc/php/8.6/fpm/pool.d/www.conf" \
    && grep -q 'systemctl restart php8.6-fpm' "${STATE}/systemctl.log" \
    && pass "8.6 gets the same ini, locked www pool and FPM restart as any version" || fail "8.6 install did not write the usual files"

out=$(L 'source "$CIPI_LIB/pending.sh"; PENDING_ITEMS=(); _pending_php; printf "%s\n" "${PENDING_ITEMS[@]+"${PENDING_ITEMS[@]}"}"' 2>&1)
grep -q $'^warning\tphp-8.6-prerelease\t' <<< "$out" && grep -q $'^warning\tphp-8.6-ext\tPHP 8.6 is installed without: memcached redis imagick' <<< "$out" \
    && pass "cipi pending lists the pre-release and the missing extensions" || fail "pending: ${out}"

# redis is published: the daily upgrade installs it and restarts that FPM
echo "php8.6-redis" >> "${STATE}/apt.available"
: > "${STATE}/systemctl.log"
out=$(L 'source "$CIPI_LIB/php.sh"; _php_upgrade' 2>&1); rc=$?
[[ $rc -eq 0 ]] && grep -qx 'php8.6-redis' "${STATE}/apt.installed" && [[ "$(cat "$PEND")" == $'8.6 memcached\n8.6 imagick' ]] \
    && pass "php upgrade installs redis once apt has it and keeps waiting for the other two" || fail "php upgrade (redis): rc=${rc} pending=$(cat "$PEND" 2>&1) :: ${out}"
grep -q 'systemctl restart php8.6-fpm' "${STATE}/systemctl.log" && pass "…and restarts PHP-FPM 8.6 so the extension is loaded" || fail "FPM 8.6 not restarted after a new extension"
grep -q 'without: memcached imagick' <<< "$out" && pass "…and its report says what is still missing" || fail "report: ${out}"
printf '%s\n' php8.6-memcached php8.6-imagick >> "${STATE}/apt.available"
out=$(L 'source "$CIPI_LIB/php.sh"; _php_upgrade' 2>&1)
[[ ! -e "$PEND" ]] && grep -qx 'php8.6-imagick' "${STATE}/apt.installed" && pass "when the last ones arrive the list is gone" || fail "php-ext-pending left behind: $(cat "$PEND" 2>&1)"
out=$(L 'source "$CIPI_LIB/pending.sh"; PENDING_ITEMS=(); _pending_php; printf "%s\n" "${PENDING_ITEMS[@]+"${PENDING_ITEMS[@]}"}"' 2>&1)
! grep -q 'php-8.6-ext' <<< "$out" && pass "…and cipi pending stops listing them" || fail "pending still lists extensions: ${out}"

# PHP itself is not there: nothing is installed
reset_state
avail 8.6 fpm redis > "${STATE}/apt.available"
out=$(L 'source "$CIPI_LIB/php.sh"; _php_install 8.6' 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q 'PHP 8.6 is not available here' <<< "$out" && ! grep -qE '^apt-get install -y -qq php' "${STATE}/apt.log" && [[ ! -e "$PEND" ]] \
    && pass "without php8.6-fpm in the repository the install stops before installing anything" || fail "install without fpm: rc=${rc}: ${out}"

# everything is there: one simulation, no list
reset_state
avail 8.5 > "${STATE}/apt.available"
echo "8.5.13" > "${STATE}/php8.5.full"
out=$(L 'source "$CIPI_LIB/php.sh"; _php_install 8.5' 2>&1); rc=$?
[[ $rc -eq 0 && "$(grep -c -- ' install -s ' "${STATE}/apt.log")" -eq 1 && ! -e "$PEND" ]] && ! grep -q 'without' <<< "$out" \
    && pass "a complete branch installs as before: one simulation, no list, no warning" || fail "complete install: rc=${rc} sims=$(grep -c -- ' install -s ' "${STATE}/apt.log"): ${out}"

# the list itself
reset_state
out=$(L 'source "$CIPI_LIB/php.sh"
         _php_ext_pending_set 8.6 redis imagick; _php_ext_pending_set 8.5 memcached
         printf "8.6 redis; rm -rf /\n../../etc passwd\n8.6 REDIS\n" >> "$PHP_EXT_PENDING"
         echo "[$(php_ext_pending 8.6 | paste -sd" " -)] [$(php_ext_pending 8.5)] [$(php_ext_pending | wc -l | tr -d " ")]"
         _php_ext_pending_set 8.6
         echo "[$(php_ext_pending 8.6)] [$(php_ext_pending 8.5)]"
         _php_ext_pending_set 8.5; [[ ! -e "$PHP_EXT_PENDING" ]] && echo gone' 2>&1)
[[ "$out" == $'[redis imagick] [memcached] [3]\n[] [memcached]\ngone' ]] \
    && pass "the list: per version, lines that are not '<version> <extension>' ignored, removed when empty" || fail "php_ext_pending: ${out}"
grep -q '_php_ext_pending_set "\$v"$' "${LIB}/php.sh" && pass "cipi php remove forgets the version's list" || fail "php remove keeps the list"

# ── 5. nginx: floor, build, running binary, HTTP/2 ───────────
echo "--- functional: nginx security state"
reset_state
[[ "$(L 'nginx_security_floor')" == "1.31.9" ]] && pass "the nginx security floor is 1.31.9" || fail "nginx_security_floor"
out=$(L 'source "$CIPI_LIB/nginx.sh"
         for p in 1.24.0-2ubuntu7.20 1.28.3-2ubuntu1.13 1.18.0-6ubuntu14.6; do nginx_is_distro_build "$p" && echo "distro $p"; done
         for p in "1.31.9-1~noble" "1.31.9-1~resolute" "1.26.3-1+ubuntu24.04.1+deb.sury.org+1" ""; do nginx_is_distro_build "$p" || echo "other $p"; done' 2>&1)
[[ "$(grep -c '^distro ' <<< "$out")" -eq 3 && "$(grep -c '^other ' <<< "$out")" -eq 4 ]] \
    && pass "the Ubuntu archive's packages are told from nginx.org's and from a PPA's" || fail "nginx_is_distro_build: ${out}"
state() { L 'source "$CIPI_LIB/nginx.sh"; nginx_security_state'; }
set_nginx 1.31.8 "1.31.8-1~noble";      [[ "$(state)" == "vulnerable 1.31.8" ]] && pass "1.31.8 from nginx.org: vulnerable" || fail "1.31.8: $(state)"
set_nginx 1.31.9 "1.31.9-1~noble";      [[ "$(state)" == "patched 1.31.9" ]]    && pass "1.31.9: patched" || fail "1.31.9: $(state)"
set_nginx 1.33.0 "1.33.0-1~noble";      [[ "$(state)" == "patched 1.33.0" ]]    && pass "1.33.0: patched (1.33 > 1.31.9, not a string comparison)" || fail "1.33.0: $(state)"
set_nginx 1.31.10 "1.31.10-1~noble";    [[ "$(state)" == "patched 1.31.10" ]]   && pass "1.31.10: patched (10 > 9)" || fail "1.31.10: $(state)"
set_nginx 1.24.0 "1.24.0-2ubuntu7.20";  [[ "$(state)" == "distro 1.24.0" ]]     && pass "1.24.0-2ubuntu7.20: the archive's build — not called vulnerable, not called patched" || fail "ubuntu: $(state)"

stale() { L 'source "$CIPI_LIB/nginx.sh"; nginx_running_binary_stale && echo stale || echo current'; }
[[ "$(stale)" == "current" ]] && pass "running binary = binary on disk: current" || fail "fresh process reported stale"
proc_stale
[[ "$(stale)" == "stale" ]] && pass "/proc/<pid>/exe ending in (deleted): stale" || fail "deleted exe not noticed"
mkdir -p "${STATE}/proc/300"; ln -s /usr/sbin/nginx "${STATE}/proc/300/exe"
[[ "$(stale)" == "stale" ]] && pass "a new master with one old worker left: still stale" || fail "an old worker beside a new master was missed"

activate() { : > "${STATE}/systemctl.log"; : > "${STATE}/sleep.log"; L 'source "$CIPI_LIB/nginx.sh"; rc=0; nginx_activate || rc=$?; echo "rc=$rc"' 2>&1 | tail -n 1; }
acts() { grep -E '^systemctl (reload|restart) nginx' "${STATE}/systemctl.log" | paste -sd, - ; }
reset_state; set_nginx 1.31.9 "1.31.9-1~noble"
[[ "$(activate)" == "rc=0" && "$(acts)" == "systemctl reload nginx" ]] && pass "activate: current binary → a reload, no restart" || fail "activate (current): $(acts)"
proc_stale
[[ "$(activate)" == "rc=0" && "$(acts)" == "systemctl restart nginx" && "$(stale)" == "current" ]] \
    && pass "activate: old binary still running after the wait → restart, and then it is current" || fail "activate (stale): $(acts)"
proc_stale; touch "${STATE}/sleep.clears"
[[ "$(activate)" == "rc=0" && "$(acts)" == "systemctl reload nginx" ]] && pass "activate: old workers gone during the wait → a reload is enough" || fail "activate (workers finish): $(acts)"
rm -f "${STATE}/sleep.clears"; proc_stale; touch "${STATE}/nginx.t.fail"
[[ "$(activate)" == "rc=1" && -z "$(acts)" ]] && pass "activate: config refused → rc 1 and the running nginx is not touched" || fail "activate (bad config): $(acts)"
rm -f "${STATE}/nginx.t.fail"; echo no > "${STATE}/nginx.active"
[[ "$(activate)" == "rc=0" && "$(acts)" == "systemctl restart nginx" ]] && pass "activate: nginx stopped → started" || fail "activate (stopped): $(acts)"
echo no > "${STATE}/nginx.active"; touch "${STATE}/nginx.wont.start"
[[ "$(activate)" == "rc=2" ]] && pass "activate: nginx does not come back → rc 2" || fail "activate (will not start)"

reset_state; set_nginx 1.31.9 "1.31.9-1~noble"
cat > "${STATE}/nginx.T" <<'EOF'
# configuration file /etc/nginx/nginx.conf:
http {
    # http2 on;
    include /etc/nginx/sites-enabled/*;
}
# configuration file /etc/nginx/sites-enabled/shop:
server {
    listen 443 ssl;
    listen [::]:443 ssl;
}
# configuration file /etc/nginx/sites-enabled/legacy:
server {
    listen 443 ssl http2;
}
# configuration file /etc/nginx/conf.d/custom.conf:
server {
    listen 8443 ssl;
    http2 on;
    http2 on;
}
EOF
out=$(L 'source "$CIPI_LIB/nginx.sh"; nginx_http2_listeners' | paste -sd, -)
[[ "$out" == "/etc/nginx/conf.d/custom.conf,/etc/nginx/sites-enabled/legacy" ]] \
    && pass "HTTP/2 is found where it is on (listen … http2, http2 on), not in a comment, not in Cipi's 'listen 443 ssl'" || fail "nginx_http2_listeners: ${out}"

echo "--- functional: nginx.conf for mainline"
reset_state; ubuntu_conf
cp "${FAKE}/etc/nginx/nginx.conf" "${TMP}/before.conf"
L 'source "$CIPI_LIB/nginx.sh"; nginx_conf_for_mainline "$FAKE/etc/nginx/nginx.conf"' > "${TMP}/after.conf"
d=$(diff "${TMP}/before.conf" "${TMP}/after.conf" | grep '^[<>]' || true)
[[ "$d" == $'< include /etc/nginx/modules-enabled/*.conf;\n<     more_clear_headers \'Server\' \'X-Powered-By\';\n>     max_headers 1000;' ]] \
    && pass "adapted in place: modules include and headers-more out, max_headers in — nothing else changes" || fail "nginx_conf_for_mainline: ${d}"
grep -q 'client_body_timeout 33s;' "${TMP}/after.conf" && pass "a line the admin added is still there" || fail "admin line lost"
cp "${TMP}/after.conf" "${FAKE}/etc/nginx/nginx.conf"
L 'source "$CIPI_LIB/nginx.sh"; nginx_conf_for_mainline "$FAKE/etc/nginx/nginx.conf"' | cmp -s - "${TMP}/after.conf" \
    && pass "a second pass changes nothing (max_headers is not added twice)" || fail "nginx_conf_for_mainline is not idempotent"

printf 'user www-data;\nhttp {\n    sendfile on;\n}\n' > "${FAKE}/etc/nginx/nginx.conf"
out=$(L 'source "$CIPI_LIB/nginx.sh"; nginx_conf_for_mainline "$FAKE/etc/nginx/nginx.conf"' | paste -sd'|' -)
[[ "$out" == "user www-data;|http {|    max_headers 1000;|    sendfile on;|}" ]] && pass "without a server_tokens line, max_headers opens the http block" || fail "no server_tokens: ${out}"

echo "--- functional: the nginx.org repository"
reset_state
K="${FAKE}/usr/share/keyrings/nginx-archive-keyring.gpg"
echo "OLD-KEY" > "$K"; touch "${STATE}/curl.fail"
out=$(L 'source "$CIPI_LIB/nginx.sh"; nginx_setup_mainline_repo && echo ok' 2>&1)
[[ "$out" == "ok" && "$(cat "$K")" == "OLD-KEY" ]] && ! ls "${FAKE}/usr/share/keyrings/" | grep -q 'gpg\.' \
    && pass "a failed key download keeps the keyring that is there (it used to be emptied)" || fail "keyring after a failed download: '$(cat "$K")' / ${out}"
rm -f "$K"
out=$(L 'source "$CIPI_LIB/nginx.sh"; nginx_setup_mainline_repo && echo ok || echo "failed"' 2>&1)
grep -q '^failed$' <<< "$out" && [[ ! -e "$K" ]] && pass "no key at all and no download: it fails, and leaves no empty keyring" || fail "repo setup without a key: ${out}"
rm -f "${STATE}/curl.fail"
out=$(L 'source "$CIPI_LIB/nginx.sh"; nginx_setup_mainline_repo && echo ok' 2>&1)
[[ "$out" == "ok" && "$(cat "$K")" == "KEY-1" ]] && grep -q 'nginx.org/packages/mainline/ubuntu noble nginx' "${FAKE}/etc/apt/sources.list.d/nginx.list" \
    && grep -q 'Pin-Priority: 900' "${FAKE}/etc/apt/preferences.d/99nginx" \
    && pass "with the key downloaded: keyring, source and pin are written" || fail "repo setup: ${out}"

# ── 6. from the Ubuntu archive's nginx to nginx.org mainline ──
echo "--- functional: the move to nginx.org mainline"
move() { L 'source "$CIPI_LIB/nginx.sh"; rc=0; nginx_upgrade_mainline_for_http2_bomb || rc=$?; echo "rc=$rc"' 2>&1; }
ubuntu_server() {
    reset_state; ubuntu_conf
    set_nginx 1.24.0 "1.24.0-2ubuntu7.20" "1.31.9-1~noble"
    touch "${STATE}/headers-more"
    # The WebSocket map as a snippet, the way such a server has it.
    printf 'map $http_upgrade $connection_upgrade {\n    default upgrade;\n    %s      close;\n}\n' "''" > "${FAKE}/etc/nginx/conf.d/cipi-octane-map.conf"
}
ubuntu_server
out=$(move)
grep -q '^rc=0$' <<< "$out" && [[ "$(cat "${STATE}/nginx.pkg")" == "1.31.9-1~noble" ]] && pass "an Ubuntu-archive server ends on nginx.org 1.31.9" || fail "move: ${out}"
grep -qE '^apt-get install -s -qq nginx libnginx-mod-http-headers-more-filter-$' "${STATE}/apt.log" \
    && grep -qE '^apt-get .*install -y -qq .*--force-confold nginx libnginx-mod-http-headers-more-filter-$' "${STATE}/apt.log" \
    && [[ ! -e "${STATE}/headers-more" ]] && ! grep -q 'purge' "${STATE}/apt.log" \
    && pass "one transaction, simulated first: nginx in, the headers-more module out, conffiles kept" || fail "apt calls: $(cat "${STATE}/apt.log")"
C="${FAKE}/etc/nginx/nginx.conf"
grep -q 'max_headers 1000;' "$C" && ! grep -qE 'more_clear_headers|modules-enabled' "$C" && grep -q 'client_body_timeout 33s;' "$C" \
    && pass "nginx.conf is adapted, not replaced: the admin's line is kept" || fail "nginx.conf after the move: $(cat "$C")"
bak=$(ls "${FAKE}/etc/nginx/"nginx.conf.cipi-*.bak 2>/dev/null | head -n 1)
[[ -n "$bak" ]] && grep -q 'more_clear_headers' "$bak" && pass "the nginx.conf from before is kept beside it" || fail "no copy of the previous nginx.conf"
[[ -f "${FAKE}/etc/nginx/conf.d/cipi-octane-map.conf" ]] && pass "the WebSocket map snippet stays (the adapted config does not define the map)" || fail "octane map snippet removed"
[[ "$(acts)" == "systemctl restart nginx" && "$(stale)" == "current" ]] \
    && pass "the old binary was still running after the package swap: restarted, now current" || fail "after the move: $(acts)"

ubuntu_server; touch "${STATE}/apt.stops.nginx"
out=$(move)
grep -q '^rc=0$' <<< "$out" && [[ "$(cat "${STATE}/nginx.active")" == "yes" ]] && pass "if removing the archive's packages stops nginx, it is started again" || fail "nginx left stopped: ${out}"

ubuntu_server; echo 100 > "${STATE}/apt.sim.rc"
cp "$C" "${TMP}/before.conf"
out=$(move)
grep -q '^rc=1$' <<< "$out" && cmp -s "$C" "${TMP}/before.conf" && [[ -e "${STATE}/headers-more" ]] \
    && ! grep -qE '^apt-get .*install -y .*nginx' "${STATE}/apt.log" && [[ -z "$(acts)" ]] && [[ "$(cat "${STATE}/nginx.pkg")" == "1.24.0-2ubuntu7.20" ]] \
    && pass "apt cannot resolve the move: nothing is removed, nginx.conf and the running nginx are untouched" || fail "failed simulation was not harmless: ${out}"
grep -q 'apt-get install -s nginx' <<< "$out" && pass "…and it says how to see why" || fail "no hint after a failed simulation: ${out}"

ubuntu_server; echo "1.24.0-2ubuntu7.21" > "${STATE}/nginx.cand"
out=$(move)
grep -q '^rc=1$' <<< "$out" && grep -q 'not available from APT' <<< "$out" && ! grep -q ' install -s' "${STATE}/apt.log" \
    && pass "nginx.org unreachable (apt still offers Ubuntu's package): stops before anything" || fail "candidate check: ${out}"

# a vhost somebody wrote with the headers-more module: nginx.org's nginx would refuse it
ubuntu_server
printf '# configuration file %s/etc/nginx/nginx.conf:\nhttp {\n    more_clear_headers Server;\n}\n# configuration file /etc/nginx/sites-enabled/shop:\nserver {\n    more_set_headers "X-Shop: 1";\n    # more_set_headers "X-Old: 1";\n}\n' "$FAKE" > "${STATE}/nginx.T"
cp "$C" "${TMP}/before.conf"
out=$(move)
grep -q '^rc=1$' <<< "$out" && grep -q '/etc/nginx/sites-enabled/shop: more_set_headers' <<< "$out" && ! grep -q 'nginx.conf: ' <<< "$out" \
    && cmp -s "$C" "${TMP}/before.conf" && ! grep -q ' install ' "${STATE}/apt.log" && [[ "$(cat "${STATE}/nginx.pkg")" == "1.24.0-2ubuntu7.20" ]] \
    && pass "a vhost using headers-more stops the move before anything is touched, and is named (nginx.conf's own line is not: the move removes it)" || fail "headers-more in a vhost: ${out}"

ubuntu_server; touch "${STATE}/nginx.t.fail"
out=$(move)
grep -q '^rc=1$' <<< "$out" && grep -q 'already fails' <<< "$out" && ! grep -q ' install ' "${STATE}/apt.log" \
    && pass "a configuration the archive's nginx already refuses: the move does not start" || fail "broken config before the move: ${out}"

ubuntu_server; touch "${STATE}/curl.fail"
out=$(move)
grep -q '^rc=1$' <<< "$out" && grep -q 'signing key' <<< "$out" && pass "no signing key: stops, with the reason" || fail "no key: ${out}"

# a config the adapted form cannot save: Cipi's template, the old one kept
ubuntu_server
sed -i.x 's/    client_body_timeout 33s;/    only_on_ubuntu on;/' "$C" && rm -f "${C}.x"
out=$(move)
grep -q '^rc=0$' <<< "$out" && grep -q 'worker_rlimit_nofile 65535;' "$C" && grep -q 'map \$http_upgrade' "$C" && ! grep -q 'only_on_ubuntu' "$C" \
    && [[ ! -e "${FAKE}/etc/nginx/conf.d/cipi-octane-map.conf" ]] \
    && pass "an adapted config nginx still refuses is replaced by Cipi's (and the map snippet, now a duplicate, goes)" || fail "template fallback: ${out}"
bak=$(ls "${FAKE}/etc/nginx/"nginx.conf.cipi-*.bak 2>/dev/null | head -n 1)
[[ -n "$bak" ]] && grep -q 'only_on_ubuntu' "$bak" && grep -q "$(basename "$bak")" <<< "$out" && pass "…with the previous one kept and named" || fail "template fallback lost the previous config"

reset_state; mainline_conf; set_nginx 1.31.9 "1.31.9-1~noble"
out=$(move)
grep -q '^rc=0$' <<< "$out" && grep -q 'nothing to do' <<< "$out" && [[ ! -s "${STATE}/apt.log" ]] && pass "a server already on mainline with max_headers: nothing to do" || fail "idempotence: ${out}"

echo "--- functional: nginx_security_upgrade"
secup() { L 'source "$CIPI_LIB/nginx.sh"; rc=0; nginx_security_upgrade || rc=$?; echo "rc=$rc"' 2>&1; }
reset_state; mainline_conf; set_nginx 1.31.8 "1.31.8-1~noble" "1.31.9-1~noble"
out=$(secup)
grep -q '^rc=0$' <<< "$out" && [[ "$(cat "${STATE}/nginx.ver")" == "1.31.9" ]] && grep -qE '^apt-get .*install -y -qq .*--only-upgrade nginx$' "${STATE}/apt.log" \
    && [[ "$(acts)" == "systemctl restart nginx" ]] \
    && pass "mainline 1.31.8 → 1.31.9, and nginx restarted because the old binary was still in memory" || fail "security upgrade: ${out} / $(acts)"
: > "${STATE}/apt.log"; : > "${STATE}/systemctl.log"
out=$(secup)
grep -q '^rc=0$' <<< "$out" && ! grep -q 'install -y' "${STATE}/apt.log" && [[ "$(acts)" == "systemctl reload nginx" ]] && pass "a second run installs nothing and only reloads" || fail "second run: ${out} / $(acts)"
reset_state; mainline_conf; set_nginx 1.31.8 "1.31.8-1~noble"
out=$(secup)
grep -q '^rc=1$' <<< "$out" && grep -q 'still below 1.31.9' <<< "$out" && pass "the repository does not have 1.31.9 yet: it says so and returns 1" || fail "no candidate: ${out}"
reset_state; mainline_conf; set_nginx 1.31.9 "1.31.9-1~noble"; proc_stale
out=$(secup)
grep -q '^rc=0$' <<< "$out" && [[ "$(acts)" == "systemctl restart nginx" ]] && pass "1.31.9 on disk but the old binary in memory: restarted" || fail "stale at the floor: ${out} / $(acts)"
ubuntu_server
out=$(secup)
grep -q '^rc=0$' <<< "$out" && grep -q 'Ubuntu archive build' <<< "$out" && [[ "$(cat "${STATE}/nginx.pkg")" == "1.31.9-1~noble" ]] && pass "an Ubuntu-archive server goes through the move" || fail "security upgrade (ubuntu): ${out}"

# ── 7. cipi pending / cipi nginx upgrade ─────────────────────
echo "--- functional: cipi pending, cipi nginx upgrade"
pend() { L 'source "$CIPI_LIB/pending.sh"; PENDING_ITEMS=(); _pending_nginx; printf "%s\n" "${PENDING_ITEMS[@]+"${PENDING_ITEMS[@]}"}"' 2>&1 | cut -f1,2 | paste -sd, -; }
reset_state; set_nginx 1.31.8 "1.31.8-1~noble"
[[ "$(pend)" == $'critical\tnginx' ]] && pass "pending: nginx below the floor is critical" || fail "pending (vulnerable): $(pend)"
set_nginx 1.24.0 "1.24.0-2ubuntu7.20"
[[ "$(pend)" == $'warning\tnginx-distro' ]] && pass "pending: the archive's nginx is a warning that names the fix" || fail "pending (distro): $(pend)"
set_nginx 1.31.9 "1.31.9-1~noble"
[[ -z "$(pend)" ]] && pass "pending: 1.31.9 running → nothing" || fail "pending (patched): $(pend)"
proc_stale
[[ "$(pend)" == $'critical\tnginx-stale' ]] && pass "pending: patched on disk, old binary running → critical" || fail "pending (stale): $(pend)"
grep -q '^    _pending_nginx$' "${LIB}/pending.sh" && pass "pending_collect looks at nginx" || fail "_pending_nginx is not called"

SU="${LIB}/stack-upgrade.sh"
up() { L 'source "$CIPI_LIB/stack-upgrade.sh"; rc=0; _stack_upgrade nginx --yes || rc=$?; echo "rc=$rc"' 2>&1; }
ubuntu_server
out=$(up)
grep -q '^rc=0$' <<< "$out" && [[ "$(cat "${STATE}/nginx.pkg")" == "1.31.9-1~noble" ]] && ! grep -q -- '--only-upgrade' "${STATE}/apt.log" \
    && grep -q 'NOTIFY Cipi Nginx upgraded' "${STATE}/notify.log" \
    && pass "cipi nginx upgrade --yes on the archive's nginx moves it to mainline (no --only-upgrade of nginx-common)" || fail "stack upgrade (ubuntu): ${out}"
reset_state; mainline_conf; set_nginx 1.31.8 "1.31.8-1~noble" "1.31.9-1~noble"
out=$(up)
grep -q '^rc=0$' <<< "$out" && [[ "$(cat "${STATE}/nginx.ver")" == "1.31.9" && "$(acts)" == "systemctl restart nginx" ]] \
    && pass "cipi nginx upgrade on mainline: upgraded, and restarted when the old binary stays in memory" || fail "stack upgrade (mainline): ${out} / $(acts)"
reset_state; mainline_conf; set_nginx 1.31.9 "1.31.9-1~noble"; proc_stale
out=$(up)
grep -q '^rc=0$' <<< "$out" && grep -q 'up to date' <<< "$out" && [[ "$(acts)" == "systemctl restart nginx" ]] \
    && pass "up to date on disk, old binary in memory: cipi nginx upgrade restarts it" || fail "stack upgrade (stale): ${out} / $(acts)"
reset_state; mainline_conf; set_nginx 1.31.9 "1.31.9-1~noble"
out=$(up)
grep -q '^rc=0$' <<< "$out" && [[ -z "$(acts)" ]] && pass "up to date and current: nothing is reloaded or restarted" || fail "stack upgrade (nothing to do): $(acts)"
grep -q 'nginx_setup_mainline_repo || true' "$SU" && pass "a key download that fails does not stop the nightly update" || fail "ensure_repo is not tolerant"

out=$(L 'source "$CIPI_LIB/nginx.sh"; nginx_command security' 2>&1)
grep -q 'patched' <<< "$out" && grep -q 'HTTP/2 is off' <<< "$out" && pass "cipi nginx security reports the patch level and HTTP/2" || fail "cipi nginx security: ${out}"
grep -q '"cipi nginx security"' "${ROOT}/cipi" && grep -q 'default-server upgrade security' "${LIB}/completion.sh" && pass "help and completion know it" || fail "help/completion"

# ── 8. migration 5.9.1 against the fake root ─────────────────
echo "--- functional: migration 5.9.1"
V="${FAKE}/etc/nginx/sites-available/cipi-api"
reset_state; mainline_conf; api_vhost; set_nginx 1.31.8 "1.31.8-1~noble" "1.31.9-1~noble"; set_php 8.5 8.5.13
echo "php8.5-fpm" > "${STATE}/apt.installed"
out=$(MIG); rc=$?
[[ $rc -eq 0 ]] && grep -q '^Migration 5.9.1 complete$' <<< "$out" && pass "mainline server: the migration completes" || fail "migration (mainline): rc=${rc}: ${out}"
[[ "$(cat "${STATE}/nginx.ver")" == "1.31.9" && "$(stale)" == "current" ]] && pass "nginx is 1.31.9 and the running binary is that one" || fail "nginx after the migration: $(cat "${STATE}/nginx.ver")"
! grep -qE '^[[:space:]]*alias ' "$V" && grep -q 'location /api-docs {' "$V" && grep -q 'try_files \$uri =404;' "$V" && grep -q 'root /opt/cipi/api/public;' "$V" \
    && pass "the panel API vhost lost its alias and nothing else" || fail "vhost after the migration: $(cat "$V")"
grep -q 'HTTP/2 is off on this server' <<< "$out" && pass "it says HTTP/2 is off (the two CVEs could not be reached)" || fail "no HTTP/2 line: ${out}"
grep -q 'PHP 8.5 .*8.5.13.* patched' <<< "$out" && pass "cipi php upgrade ran and printed the patch level" || fail "no PHP report: ${out}"
grep -q 'PHP 8.6 is not installed by this update' <<< "$out" && ! grep -q 'php8\.6' "${STATE}/apt.log" && [[ "$(cat "${STATE}/php.installed")" == "8.5" ]] \
    && [[ ! -e "${STATE}/alt.log" ]] \
    && pass "the migration leaves PHP as it is: 8.6 not installed, the server's PHP not touched, and it says so" || fail "migration and PHP 8.6: $(grep 'php8.6' "${STATE}/apt.log") / ${out}"
: > "${STATE}/apt.log"; : > "${STATE}/systemctl.log"
cp "$V" "${TMP}/vhost.after"
out=$(MIG); rc=$?
[[ $rc -eq 0 ]] && cmp -s "$V" "${TMP}/vhost.after" && ! grep -qE 'install -y -qq .*nginx' "${STATE}/apt.log" && ! grep -q 'restart nginx' "${STATE}/systemctl.log" \
    && pass "a second run changes nothing and does not restart nginx" || fail "migration is not idempotent: ${out}"

ubuntu_server; api_vhost; set_php 8.5 8.5.13; echo "php8.5-fpm" > "${STATE}/apt.installed"
printf '# configuration file /etc/nginx/sites-enabled/legacy:\nserver {\n    listen 443 ssl http2;\n}\n' > "${STATE}/nginx.T"
out=$(MIG); rc=$?
[[ $rc -eq 0 ]] && grep -q '^Migration 5.9.1 complete$' <<< "$out" && [[ "$(cat "${STATE}/nginx.pkg")" == "1.31.9-1~noble" ]] \
    && grep -q 'max_headers 1000;' "$C" && grep -q 'client_body_timeout 33s;' "$C" \
    && pass "Ubuntu-archive server: moved to nginx.org 1.31.9 with its nginx.conf adapted" || fail "migration (ubuntu): rc=${rc}: ${out}"
grep -q 'HTTP/2 is on in configuration Cipi did not write' <<< "$out" && grep -q '/etc/nginx/sites-enabled/legacy' <<< "$out" \
    && pass "a hand-written HTTP/2 listener is named" || fail "HTTP/2 listener not reported: ${out}"

ubuntu_server; api_vhost; echo 100 > "${STATE}/apt.sim.rc"
cp "$C" "${TMP}/before.conf"
out=$(MIG); rc=$?
[[ $rc -eq 0 ]] && grep -q '^Migration 5.9.1 complete$' <<< "$out" && grep -q 'WARNING: nginx is not on 1.31.9' <<< "$out" && cmp -s "$C" "${TMP}/before.conf" \
    && pass "apt cannot move nginx: a warning, the server as it was, and the migration still completes" || fail "migration (apt refuses): rc=${rc}: ${out}"

reset_state; mainline_conf; api_vhost; set_nginx 1.31.9 "1.31.9-1~noble"; touch "${STATE}/nginx.t.fail"
cp "$V" "${TMP}/vhost.before"
out=$(MIG); rc=$?
[[ $rc -eq 0 ]] && cmp -s "$V" "${TMP}/vhost.before" && grep -q 'put back as it was' <<< "$out" && ! grep -qE 'systemctl (reload|restart) nginx' "${STATE}/systemctl.log" \
    && pass "nginx refuses the configuration: the vhost is put back and nginx is not reloaded" || fail "migration (nginx -t fails): rc=${rc}: ${out}"

reset_state; mainline_conf; api_vhost /srv/other/api-docs; set_nginx 1.31.9 "1.31.9-1~noble"
cp "$V" "${TMP}/vhost.before"
out=$(MIG); rc=$?
[[ $rc -eq 0 ]] && cmp -s "$V" "${TMP}/vhost.before" && grep -q 'not the one Cipi wrote' <<< "$out" \
    && pass "an alias that points somewhere else is not Cipi's: left alone" || fail "migration (foreign alias): ${out}"

# ── 9. the default PHP: 8.6 on a new server, its own on an existing one ──
echo "--- functional: default PHP"
# install_php and what it needs, cut out of setup.sh and pointed at the fake
# root; the apt wrappers and the repository helpers of setup.sh replaced.
SETUP_PHP="${TMP}/setup-php.sh"
awk '/^readonly PHP_DEFAULT=/ { f = 1 } /^# ── COMPOSER/ { f = 0 } f' "${ROOT}/setup.sh" | sed "s#/etc/php/#${FAKE}/etc/php/#g" > "$SETUP_PHP"
SP() {
    PATH="${BIN}:${PATH}" STATE="$STATE" FAKE="$FAKE" SETUP_PHP="$SETUP_PHP" bash -c 'set -e; set -o pipefail
        GREEN=""; YELLOW=""; CYAN=""; NC=""; BOLD=""
        step_msg() { :; }
        _cipi_source_apt_helpers() { php_setup_apt_sources() { return 0; }; cipi_sanitize_broken_apt_sources() { return 0; }; }
        _cipi_apt_update() { :; }
        _cipi_apt_install() { apt-get install "$@"; }
        source "$SETUP_PHP"
        install_php
        echo "installed=${PHP_INSTALLED} skipped=[${PHP_DEFAULT_SKIPPED}]"' 2>&1
}
grep -q '^install_php() {$' "$SETUP_PHP" && pass "install_php is cut out of setup.sh for the checks below" || fail "could not extract install_php from setup.sh"

reset_state
{ avail 8.6; avail 8.5; } > "${STATE}/apt.available"
echo "8.6.0-1+0~deb.sury.org.1+ubuntu24.04" > "${STATE}/php8.6-fpm.cand"
out=$(SP); rc=$?
[[ $rc -eq 0 ]] && grep -q '^installed=8.6 skipped=\[\]$' <<< "$out" && [[ "$(cat "${STATE}/php.installed")" == "8.6" ]] \
    && grep -qx 'php8.6-redis' "${STATE}/apt.installed" && ! grep -q 'php8\.5' "${STATE}/apt.installed" \
    && pass "new server, 8.6.0 in the repository with every extension: PHP 8.6 is installed, 8.5 is not" || fail "setup (8.6 ready): rc=${rc}: ${out}"
grep -qx 'update-alternatives --set php /usr/bin/php8.6' "${STATE}/alt.log" && [[ "$(L 'php_system_version')" == "8.6" ]] \
    && pass "…and it is the server's PHP (the php command, set by hand)" || fail "setup alternatives: $(cat "${STATE}/alt.log" 2>&1)"
grep -q '^expose_php = Off$' "${FAKE}/etc/php/8.6/fpm/conf.d/99-cipi.ini" && grep -q '^fatal_error_backtraces = 0$' "${FAKE}/etc/php/8.6/fpm/conf.d/99-cipi.ini" \
    && grep -q '^listen = /run/php/php8.6-fpm.sock$' "${FAKE}/etc/php/8.6/fpm/pool.d/www.conf" && grep -q 'systemctl enable php8.6-fpm' "${STATE}/systemctl.log" \
    && pass "…with the ini, the locked www pool and the FPM service of 8.6" || fail "setup 8.6 files"
[[ "$(L 'php_app_default')" == "8.6" ]] && pass "…and cipi app create without --php creates the app on 8.6" || fail "php_app_default on a new server: $(L 'php_app_default')"
out=$(L 'source "$CIPI_LIB/yml.sh"; _yml_example' 2>&1)
grep -q '^  php: "8.6"$' <<< "$out" && grep -q '(cipi php install 8.6)' <<< "$out" && pass "…and cipi yml example names the PHP the server has" || fail "yml example: $(grep -n 'php' <<< "$out" | head -3)"

reset_state
{ avail 8.6 redis memcached imagick; avail 8.5; } > "${STATE}/apt.available"
echo "8.6.0~rc5-2+0~deb.sury.org.1+ubuntu24.04" > "${STATE}/php8.6-fpm.cand"
out=$(SP); rc=$?
[[ $rc -eq 0 ]] && grep -q '^installed=8.5 skipped=\[the repository only has a pre-release of it (8.6.0~rc5)\]$' <<< "$out" \
    && [[ "$(cat "${STATE}/php.installed")" == "8.5" ]] && ! grep -q 'php8\.6' "${STATE}/apt.installed" \
    && grep -qx 'update-alternatives --set php /usr/bin/php8.5' "${STATE}/alt.log" \
    && pass "new server while the repository only has 8.6.0~rc5 (today): PHP 8.5, no release candidate, and the reason is kept" || fail "setup (rc): rc=${rc}: ${out}"

reset_state
{ avail 8.6 redis imagick; avail 8.5; } > "${STATE}/apt.available"
echo "8.6.0-1+0~deb.sury.org.1+ubuntu24.04" > "${STATE}/php8.6-fpm.cand"
out=$(SP); rc=$?
[[ $rc -eq 0 ]] && grep -q '^installed=8.5 skipped=\[the repository has no php8.6 package of: redis imagick\]$' <<< "$out" && [[ "$(cat "${STATE}/php.installed")" == "8.5" ]] \
    && pass "8.6.0 is out but redis and imagick are not packaged for it yet: PHP 8.5, and the two are named" || fail "setup (extensions): rc=${rc}: ${out}"

reset_state
avail 8.5 > "${STATE}/apt.available"
out=$(SP); rc=$?
[[ $rc -eq 0 ]] && grep -q '^installed=8.5 skipped=\[the repository has no PHP 8.6 yet\]$' <<< "$out" \
    && pass "a repository without any 8.6: PHP 8.5, as before 5.9.1" || fail "setup (no 8.6): rc=${rc}: ${out}"

# An existing server: installed with 8.5, the admin adds 8.6.
reset_state
set_php 8.5 8.5.13
{ avail 8.6; avail 8.5; } > "${STATE}/apt.available"
echo "8.6.0" > "${STATE}/php8.6.full"
out=$(L 'source "$CIPI_LIB/php.sh"; _php_install 8.6' 2>&1); rc=$?
[[ $rc -eq 0 ]] && grep -q "The server's PHP is still 8.5" <<< "$out" && [[ ! -e "${STATE}/alt.log" ]] && [[ "$(L 'php_system_version')" == "8.5" ]] \
    && pass "existing server: cipi php install 8.6 adds it and the server's PHP stays 8.5" || fail "php install 8.6 on an existing server: rc=${rc}: ${out}"
[[ "$(L 'php_app_default')" == "8.5" ]] && pass "…and cipi app create without --php still creates apps on 8.5" || fail "php_app_default with 8.6 installed: $(L 'php_app_default')"

reset_state
set_php 8.5 8.5.13
{ avail 8.6; avail 8.5; } > "${STATE}/apt.available"
echo "8.6.0" > "${STATE}/php8.6.full"; touch "${STATE}/alt.auto"
out=$(L 'source "$CIPI_LIB/php.sh"; _php_install 8.6' 2>&1); rc=$?
[[ $rc -eq 0 ]] && grep -qx 'update-alternatives --set php /usr/bin/php8.5' "${STATE}/alt.log" && [[ "$(L 'php_system_version')" == "8.5" ]] \
    && grep -q "The server's PHP stays 8.5" <<< "$out" \
    && pass "where the php alternative was automatic and apt moved it to 8.6, it is put back on 8.5" || fail "alternative not restored: rc=${rc} sys=$(L 'php_system_version'): ${out}"

# The server's PHP cannot host an app (a legacy 8.2 CLI): the first one that can.
reset_state
set_php 8.2 8.2.36; set_php 8.4 8.4.28; set_php 8.6 8.6.0; echo 8.2 > "${STATE}/php.sys"
[[ "$(L 'php_app_default')" == "8.4" ]] && pass "a server whose php command is 8.2: new apps get the installed 8.4, not 8.6 unasked" || fail "php_app_default (legacy CLI): $(L 'php_app_default')"

# ── 10. legacy PHP (7.4–8.2) on a server installed before 4.5.4 ──
echo "--- legacy PHP: managed where it is installed, never offered"
reset_state
set_php 8.1 8.1.34; set_php 8.2 8.2.36; set_php 8.5 8.5.13
out=$(L 'source "$CIPI_LIB/php.sh"; _php_list --json' 2>&1)
[[ "$(jq -c '[.versions[].version]' <<< "$out" 2>/dev/null)" == '["8.1","8.2","8.5"]' && "$(jq -c '.installable' <<< "$out")" == '["8.3","8.4","8.5","8.6"]' ]] \
    && pass "cipi php list --json lists an installed 8.1 and 8.2, and offers neither" || fail "php list --json (legacy): ${out}"
[[ "$(jq -r '.versions[] | select(.version == "8.1") | .security' <<< "$out" 2>/dev/null)" == "eol" ]] \
    && pass "…with 8.1 marked end of life" || fail "php list --json (8.1 security): ${out}"
out=$(L 'source "$CIPI_LIB/php.sh"; _php_install 8.2' 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q 'Invalid PHP version: 8.2' <<< "$out" && pass "cipi php install 8.2 is refused" || fail "php install 8.2: rc=${rc}: ${out}"
out=$(L 'validate_php_version_known 7.4 && validate_php_version_known 8.2 && ! validate_php_version 7.4 && ! validate_php_version_known 7.3 && echo ok' 2>&1)
[[ "$out" == "ok" ]] && pass "7.4–8.2 are known (list, remove, services) and not valid for an app" || fail "validate_php_version_known: ${out}"

mkdir -p "${FAKE}/etc/php/8.2/fpm/conf.d" "${FAKE}/etc/php/8.2/cli/conf.d" "${FAKE}/etc/php/8.5/fpm/conf.d" "${FAKE}/etc/php/8.5/cli/conf.d"
[[ "$(L 'source "$CIPI_LIB/ini.sh"; _ini_installed_versions | tr "\n" " "')" == "8.2 8.5 " ]] \
    && pass "cipi ini sees the legacy version next to the current one, newest last" || fail "_ini_installed_versions: $(L 'source "$CIPI_LIB/ini.sh"; _ini_installed_versions | tr "\n" " "')"
out=$(L 'source "$CIPI_LIB/ini.sh"; _ini_apply upload_max_filesize 512M "" 8.5 quiet' 2>&1); rc=$?
[[ $rc -eq 0 ]] && grep -qx 'upload_max_filesize = 512M' "${FAKE}/etc/php/8.2/fpm/conf.d/99-cipi.ini" && grep -qx 'upload_max_filesize = 512M' "${FAKE}/etc/php/8.2/cli/conf.d/99-cipi.ini" \
    && grep -qx 'upload_max_filesize = 512M' "${FAKE}/etc/php/8.5/fpm/conf.d/99-cipi.ini" \
    && pass "a server-wide cipi ini set reaches the apps still on 8.2" || fail "ini set server-wide (legacy): rc=${rc}: ${out}"
awk '/echo -e "\\n\$\{BOLD\}PHP\$\{NC\}"/ { f = 1; next } f && /^    done/ { print; exit } f' "${ROOT}/cipi" | sed "s#/etc/php/#${FAKE}/etc/php/#g" > "${TMP}/status-php.sh"
mkdir -p "${FAKE}/etc/php/8.2/fpm/pool.d" "${FAKE}/etc/php/8.5/fpm/pool.d"; : > "${FAKE}/etc/php/8.2/fpm/pool.d/old.conf"; : > "${FAKE}/etc/php/8.5/fpm/pool.d/www.conf"
out=$(L 'systemctl() { [[ "$1" == "is-active" && ( "${3:-}" == "php8.2-fpm" || "${3:-}" == "php8.5-fpm" ) ]]; }; status_php() { source "'"${TMP}/status-php.sh"'"; }; status_php' 2>&1)
grep -q 'PHP 8.2 .*running.*(1 pools)' <<< "$out" && grep -q 'PHP 8.5 .*running' <<< "$out" && ! grep -q 'PHP 8.1' <<< "$out" \
    && pass "cipi status lists the running FPM of 8.2 with its pools" || fail "cipi status PHP (legacy): ${out}"

# ── 11. a PHP still waiting for extensions is not given to an app ──
echo "--- PHP with extensions pending: app create / app edit / cipi.yml"
apps_json() {   # shop: Laravel on 8.5; front: a Node app on 8.5
    printf '%s\n' '{"shop":{"domain":"shop.test","php":"8.5","repository":"git@github.com:a/shop.git","branch":"main"},
                    "front":{"domain":"front.test","php":"8.5","runtime":"node","custom":true}}' > "${FAKE}/etc/cipi/apps.json"
}
reset_state; apps_json; set_php 8.5 8.5.13; set_php 8.6 8.6.0
out=$(L 'php_ext_pending_refuse 8.6 "hint"' 2>&1); rc=$?
[[ $rc -eq 0 && -z "$out" ]] && pass "nothing pending: the guard lets the version through and says nothing" || fail "guard, nothing pending: rc=${rc}: ${out}"
printf '8.6 redis\n8.6 imagick\n' > "$PEND"
out=$(L 'php_ext_pending_refuse 8.6 "the hint"' 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q 'PHP 8.6 is installed without: redis imagick' <<< "$out" && grep -q '^  the hint$' <<< "$out" \
    && pass "extensions pending: refused, the missing ones named, the way on shown" || fail "guard, pending: rc=${rc}: ${out}"
out=$(L 'php_ext_pending_refuse 8.5 "hint"' 2>&1); rc=$?
[[ $rc -eq 0 && -z "$out" ]] && pass "another version on the same server is not affected" || fail "guard, other version: rc=${rc}: ${out}"
out=$(L 'ARG_force=true; php_ext_pending_refuse 8.6 "hint"' 2>&1); rc=$?
[[ $rc -eq 0 ]] && grep -q 'going on because of --force' <<< "$out" && grep -q 'redis imagick' <<< "$out" \
    && pass "--force goes on, and still says what is missing" || fail "guard, --force: rc=${rc}: ${out}"

# cipi app edit: `step` is the first thing app_edit does once the checks are
# behind it — stopping there shows a check was passed without moving pools.
EDIT='source "$CIPI_LIB/app.sh"; step() { echo "REACHED $*"; exit 0; }'
before=$(cat "${FAKE}/etc/cipi/apps.json")
out=$(L "${EDIT}; app_edit shop --php=8.6" 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q 'PHP 8.6 is installed without: redis imagick' <<< "$out" && grep -q 'cipi app edit shop --php=8.6 --force' <<< "$out" \
    && ! grep -q REACHED <<< "$out" && [[ "$(cat "${FAKE}/etc/cipi/apps.json")" == "$before" ]] \
    && pass "cipi app edit --php=8.6 is refused, the app stays on 8.5, the command to force it is shown" || fail "app edit, pending: rc=${rc}: ${out}"
out=$(L "${EDIT}; _app_change_domain() { echo DOMAIN-CHANGED; return 0; }; app_edit shop --domain=new.test --php=8.6" 2>&1); rc=$?
[[ $rc -ne 0 ]] && ! grep -q 'DOMAIN-CHANGED' <<< "$out" \
    && pass "the refusal comes before a --domain given in the same command is applied" || fail "app edit, --domain + --php: rc=${rc}: ${out}"
out=$(L "${EDIT}; app_edit shop --php=8.6 --force" 2>&1); rc=$?
[[ $rc -eq 0 ]] && grep -q 'going on because of --force' <<< "$out" && grep -q 'REACHED PHP 8.5 → 8.6' <<< "$out" \
    && pass "cipi app edit --php=8.6 --force goes on to the switch" || fail "app edit, --force: rc=${rc}: ${out}"
out=$(L "${EDIT}; ARG_force=true; app_edit shop --php=8.6" 2>&1); rc=$?
[[ $rc -ne 0 ]] && ! grep -q REACHED <<< "$out" \
    && pass "a --force left over from the calling command does not count" || fail "app edit, leaked --force: rc=${rc}: ${out}"
out=$(L "${EDIT}; app_edit front --php=8.6" 2>&1); rc=$?
[[ $rc -eq 0 ]] && grep -q 'REACHED PHP 8.5 → 8.6' <<< "$out" && ! grep -q 'installed without' <<< "$out" \
    && pass "a Node app is let through: its PHP only runs Deployer and the webhook" || fail "app edit, node app: rc=${rc}: ${out}"
out=$(L "${EDIT}; app_edit shop --php=8.5" 2>&1); rc=$?
grep -q "PHP already '8.5'" <<< "$out" && ! grep -q 'installed without' <<< "$out" \
    && pass "an edit that does not change PHP is not concerned" || fail "app edit, same PHP: rc=${rc}: ${out}"

# cipi app create: app_exists is what follows the check.
CREATE='source "$CIPI_LIB/app.sh"; app_exists() { echo "REACHED create"; exit 0; }'
CARGS='--user=newapp --domain=newapp.test --repository=git@github.com:a/b.git --branch=main --env=production'
out=$(L "${CREATE}; app_create ${CARGS} --php=8.6" 2>&1 < /dev/null); rc=$?
[[ $rc -ne 0 ]] && grep -q 'PHP 8.6 is installed without: redis imagick' <<< "$out" && grep -q -- '--force' <<< "$out" && ! grep -q REACHED <<< "$out" \
    && pass "cipi app create --php=8.6 is refused before anything is created" || fail "app create, pending: rc=${rc}: ${out}"
out=$(L "${CREATE}; app_create ${CARGS} --php=8.6 --force" 2>&1 < /dev/null); rc=$?
[[ $rc -eq 0 ]] && grep -q 'going on because of --force' <<< "$out" && grep -q 'REACHED create' <<< "$out" \
    && pass "cipi app create --php=8.6 --force goes on" || fail "app create, --force: rc=${rc}: ${out}"
out=$(L "${CREATE}; app_create ${CARGS} --php=8.5" 2>&1 < /dev/null); rc=$?
[[ $rc -eq 0 ]] && grep -q 'REACHED create' <<< "$out" && ! grep -q 'installed without' <<< "$out" \
    && pass "cipi app create on a complete version is as before" || fail "app create, 8.5: rc=${rc}: ${out}"

# cipi.yml: a blocker in the plan, like a version that is not installed.
PLAN='source "$CIPI_LIB/app.sh"; source "$CIPI_LIB/yml.sh"; _YML_DATA="{\"app\":{\"php\":\"8.6\"}}"; _yml_build_plan >/dev/null 2>&1 || true
      printf "B: %s\n" "${_YML_BLOCKERS[@]:-}"; printf "A: %s\n" "${_YML_ACTIONS[@]:-}"'
out=$(L "_YML_APP=shop; ${PLAN}" 2>&1)
grep -q '^B: PHP 8.6 is installed without: redis imagick .*cipi app edit shop --php=8.6 --force$' <<< "$out" && ! grep -q '^A: php|' <<< "$out" \
    && pass "cipi.yml: php: \"8.6\" is a blocker of the plan, not an action, and names the command to force it" || fail "yml plan, pending: ${out}"
out=$(L "_YML_APP=front; ${PLAN}" 2>&1)
grep -q '^A: php|8.6|' <<< "$out" && ! grep -q 'installed without' <<< "$out" \
    && pass "cipi.yml: the same line on a Node app is an ordinary action" || fail "yml plan, node app: ${out}"

# once the extensions are in, the guard is gone by itself
rm -f "$PEND"
out=$(L "${EDIT}; app_edit shop --php=8.6" 2>&1); rc=$?
[[ $rc -eq 0 ]] && grep -q 'REACHED PHP 8.5 → 8.6' <<< "$out" && ! grep -q 'installed without' <<< "$out" \
    && pass "with the list empty (cipi php upgrade installed them) the same edit goes through" || fail "app edit after the extensions: rc=${rc}: ${out}"

echo ""
echo "=== ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]

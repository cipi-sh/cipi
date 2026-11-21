#!/bin/bash
# Local regression checks for 5.10.0: FrankenPHP builds pinned per Octane
# app, and JIT per app.
#
# The libraries are the real ones, copied under the temp dir with their paths
# rewritten into a fake root (/etc/php, /etc/supervisor, /home, /var/lib/cipi,
# /var/log/cipi-apps, /opt/cipi-frankenphp), and sourced under
# `set -euo pipefail` like `cipi` sources them. Every command that would act
# on the machine — supervisorctl, systemctl, curl, runuser, setsid, sudo,
# pgrep, php8.x, php-fpm8.x, sleep — is a stub in front of PATH that keeps
# its state in files. The FrankenPHP "binaries" are shell scripts that answer
# -v, build-info and php-cli the way the real one does.
#
#   - the store: a GitHub release downloaded once, checked against its
#     digest; the binary in a release adopted without a restart; imports
#   - which build an app may get: its own PHP minor, same FrankenPHP major,
#     never a binary adopted from another app's release
#   - upgrade: restart, check, back to the previous build when Octane does
#     not answer; a release on another PHP minor or a new major announced
#     once and not applied; several PHP minors side by side
#   - the deploy link (cipi-frankenphp-link): no pin, a pin, a laravel/octane
#     that asks for more than the pin, a path that is not a release
#   - the Octane program: PHP_INI_SCAN_DIR with the app's own directory,
#     PATH with the live release first
#   - JIT on PHP-FPM: pool line, the server-wide file that makes JIT
#     startable (buffer = the largest asked, a value set with cipi ini kept,
#     "disable" refused), preflight, rollback, off; on Octane: the app's ini
#   - cipi php upgrade's report and cipi pending
#   - migration 5.10.0 against the fake root, twice
#
# Not here, because it needs a real server: a real FrankenPHP binary, PHP's
# own handling of opcache.jit set per pool, Supervisor, and GitHub.
# Run from repo root: bash tests/verify-5.10.0.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/lib"
PASS=0
FAIL=0
pass() { echo "  OK: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d) && [[ -n "$TMP" && -d "$TMP" ]] || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "${TMP:?}"' EXIT

echo "=== Cipi 5.10.0 regression checks ==="

# ── 0. release files, static ─────────────────────────────────
[[ "$(tr -d '[:space:]' < "${ROOT}/version.md")" == "5.10.0" ]] && pass "version.md is 5.10.0" || fail "version.md"
grep -q '^## \[5.10.0\]' "${ROOT}/CHANGELOG.md" && pass "CHANGELOG has a 5.10.0 entry" || fail "CHANGELOG 5.10.0"
for f in common.sh app.sh frankenphp.sh php.sh ini.sh pending.sh autoupdate.sh deploy.sh completion.sh notifications.sh alerts.sh smtp.sh compliance.sh monitor.sh \
         cipi-api-sudoers.sh cipi-frankenphp-link.sh self-update.sh migrations/5.10.0.sh; do
    bash -n "${LIB}/${f}" && pass "${f} parses" || fail "${f} does not parse"
done
bash -n "${ROOT}/cipi" && pass "cipi parses" || fail "cipi does not parse"
bash -n "${ROOT}/setup.sh" && pass "setup.sh parses" || fail "setup.sh does not parse"

R="${LIB}/deployer/laravel-octane.php"
h=$(grep -n "after('deploy:vendors', 'cipi:frankenphp');" "$R" | cut -d: -f1)
m=$(grep -n '__CIPI_HOOK_MIGRATE__' "$R" | cut -d: -f1)
n=$(grep -n "after('deploy:vendors', 'cipi:node_build');" "$R" | cut -d: -f1)
[[ -n "$h" && -n "$m" && -n "$n" && "$h" -lt "$n" && "$h" -lt "$m" ]] \
    && pass "Octane recipe: cipi:frankenphp is the first hook after the vendors (before the migrations)" || fail "hook order h=$h n=$n m=$m"
grep -q "run('\[ ! -x /usr/local/bin/cipi-frankenphp-link \] || /usr/local/bin/cipi-frankenphp-link {{release_path}}');" "$R" \
    && pass "the task runs the helper only where it is installed" || fail "task body"
! grep -q 'cipi:frankenphp' "${LIB}/deployer/laravel.php" && pass "the PHP-FPM recipe is unchanged" || fail "laravel.php has the task"
for e in 'cipi app jit \*' 'cipi frankenphp status,' 'cipi frankenphp status \*' 'cipi frankenphp upgrade \*'; do
    grep -q "/usr/local/bin/${e}" "${LIB}/cipi-api-sudoers.sh" && pass "panel sudoers: ${e//\\/}" || fail "sudoers lacks ${e}"
done
! grep -q 'cipi frankenphp import\|cipi frankenphp use' "${LIB}/cipi-api-sudoers.sh" | grep -v '^#' \
    && pass "panel sudoers: no import, no use" || fail "sudoers has import/use"
grep -q 'cipi-frankenphp-link.sh" /usr/local/bin/cipi-frankenphp-link && chmod 755' "${LIB}/self-update.sh" \
    && grep -q 'cp cipi-install/lib/cipi-frankenphp-link.sh /usr/local/bin/cipi-frankenphp-link' "${ROOT}/setup.sh" \
    && pass "setup.sh and self-update install the link helper 0755" || fail "helper install"
grep -q 'frankenphp|franken) _maybe_cmd_help frankenphp' "${ROOT}/cipi" && grep -q '        jit)     app_jit "\$@" ;;' "${LIB}/app.sh" \
    && pass "dispatch: cipi frankenphp, cipi app jit" || fail "dispatch"
gen=$(bash -c "source '${LIB}/completion.sh'; _completion_bash_script")
grep -q 'local commands=".* frankenphp .*"' <<< "$gen" && grep -q 'limits jit delete' <<< "$gen" \
    && pass "completion knows frankenphp and app jit" || fail "completion"
for t in frankenphp_upgrade frankenphp_available app_jit; do
    grep -q "^${t}|" "${LIB}/notifications.sh" && pass "notification trigger ${t}" || fail "trigger ${t}"
done
grep -q 'AUTOUPDATE_COMPONENTS="composer node frankenphp nginx valkey pgsql mariadb"' "${LIB}/autoupdate.sh" \
    && pass "autoupdate has a frankenphp component" || fail "autoupdate component"

# ── fake root, rewritten libs, stubs ─────────────────────────
FAKE="${TMP}/root"; STATE="${TMP}/state"; BIN="${TMP}/bin"; LIBT="${TMP}/lib"
mkdir -p "$FAKE" "$STATE" "$BIN" "${LIBT}/migrations" "${LIBT}/deployer"
rewrite() {
    sed -e "s#/etc/php/#${FAKE}/etc/php/#g" \
        -e "s#/etc/supervisor/#${FAKE}/etc/supervisor/#g" \
        -e "s#/home/#${FAKE}/home/#g" \
        -e "s#/var/lib/cipi/#${FAKE}/var/lib/cipi/#g" \
        -e "s#/var/lib/cipi\"#${FAKE}/var/lib/cipi\"#g" \
        -e "s#/var/log/cipi-apps/#${FAKE}/var/log/cipi-apps/#g" \
        -e "s#/run/cipi-#${FAKE}/run/cipi-#g" \
        -e "s#/etc/sudoers.d/#${FAKE}/etc/sudoers.d/#g" "$1"
}
for f in "${LIB}"/*.sh; do rewrite "$f" > "${LIBT}/$(basename "$f")"; done
rewrite "${LIB}/migrations/5.10.0.sh" > "${LIBT}/migrations/5.10.0.sh"
cp "${LIB}"/deployer/*.php "${LIBT}/deployer/"
# The rewrite turns the app-name check of the link helper into a path check
# it cannot pass from a temp dir; the helper takes the fake root by itself.
rewrite "${LIB}/cipi-frankenphp-link.sh" > "${TMP}/cipi-frankenphp-link"; chmod +x "${TMP}/cipi-frankenphp-link"

stub() { cat > "${BIN}/$1"; chmod +x "${BIN}/$1"; }

# runuser -u <user> -- cmd…, setsid -w cmd…, timeout N cmd…, sudo -u <u> -- cmd…
stub runuser <<'EOF'
#!/bin/bash
echo "runuser $*" >> "$STATE/runuser.log"
while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done; shift
exec "$@"
EOF
stub setsid <<'EOF'
#!/bin/bash
[ "$1" = "-w" ] && shift
exec "$@"
EOF
stub timeout <<'EOF'
#!/bin/bash
shift; exec "$@"
EOF
stub sudo <<'EOF'
#!/bin/bash
while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done; shift
exec "$@"
EOF
stub id <<'EOF'
#!/bin/bash
case "$1" in
    -un) echo "${FAKE_USER:-root}" ;;
    -u)  if [ -n "${2:-}" ]; then /usr/bin/id -u; else /usr/bin/id -u; fi ;;
    -nG) echo root ;;
    *)   [ -n "${1:-}" ] && exit 0; /usr/bin/id ;;
esac
EOF
stub sleep <<'EOF'
#!/bin/bash
exit 0
EOF
stub getconf <<'EOF'
#!/bin/bash
echo "glibc 2.39"
EOF
stub pgrep <<'EOF'
#!/bin/bash
# pgrep -u <app> -x frankenphp
u=""; while [ $# -gt 0 ]; do case "$1" in -u) u="$2"; shift ;; esac; shift; done
[ -n "$u" ] && [ -f "$STATE/pid.$u" ] && { cat "$STATE/pid.$u"; exit 0; }
exit 1
EOF
stub supervisorctl <<'EOF'
#!/bin/bash
S="$STATE"; echo "supervisorctl $*" >> "$S/supervisorctl.log"
case "$1" in
    status)
        p="$2"; st=$(cat "$S/sup.$p" 2>/dev/null || echo RUNNING)
        # A program that starts on a build listed in $S/bad.builds stays FATAL.
        if [ -f "$S/bad.builds" ] && [ -n "${p%-octane}" ]; then
            a="${p%-octane}"; b=$(basename "$(readlink "$FRANKENPHP_ROOT/apps/$a" 2>/dev/null)" 2>/dev/null)
            grep -qx "$b" "$S/bad.builds" 2>/dev/null && st=FATAL
        fi
        [ -f "$S/bad.jit.$p" ] && [ -f "$FAKE/etc/php/cipi-octane-apps/${p%-octane}/50-cipi-jit.ini" ] && st=FATAL
        echo "$p  $st  pid 123, uptime 0:00:01" ;;
    restart) echo "$2: started" ;;
    stop)  echo "$2: stopped" ;;
    *) ;;
esac
exit 0
EOF
stub systemctl <<'EOF'
#!/bin/bash
S="$STATE"; echo "systemctl $*" >> "$S/systemctl.log"
case "$1" in
    is-active)
        u="${@: -1}"
        [ -f "$S/fpm.dead" ] && grep -q 'php_admin_value\[opcache.jit\]' "$FAKE"/etc/php/*/fpm/pool.d/*.conf 2>/dev/null && exit 3
        exit 0 ;;
esac
exit 0
EOF
for v in 7.4 8.4 8.5 8.6; do
stub "php${v}" <<'EOF'
#!/bin/bash
echo "php $*" >> "$STATE/php.log"
if [ -f "$STATE/php.nojit" ]; then echo "PHP Warning: JIT is incompatible with third party extensions that override zend_execute_ex(). JIT disabled."; echo jit-no; exit 0; fi
echo jit-ok
EOF
stub "php-fpm${v}" <<'EOF'
#!/bin/bash
exit 0
EOF
done
# curl: GitHub API from files, downloads from $STATE/dl, the Octane port from $STATE/port.code.
stub curl <<'EOF'
#!/bin/bash
S="$STATE"; out=""; w=""; url=""
ARGS=""; for a in "$@"; do ARGS="$ARGS$(printf '%s' "$a" | tr '\n' '~')"$'\n'; done
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift ;;
        -w) w="$2"; shift ;;
        -H|-m|--max-time) shift ;;
        -*) ;;
        *) url="$1" ;;
    esac
    shift
done
echo "curl $url" >> "$S/curl.log"
case "$url" in
    */releases/latest) [ -f "$S/gh.latest" ] || exit 22; cat "$S/gh.latest" ;;
    */releases/tags/*) t="${url##*/}"; [ -f "$S/gh.tag.$t" ] || exit 22; cat "$S/gh.tag.$t" ;;
    https://dl.test/*) n="${url##*/}"; [ -f "$S/dl/$n" ] || exit 22; cp "$S/dl/$n" "$out" ;;
    http://127.0.0.1:*) printf '%s' "$(cat "$S/port.code" 2>/dev/null || echo 200)" ;;
    *)
        n=$(ls "$S"/req.*.args 2>/dev/null | wc -l); n=$((n + 1))
        printf '%s\n' "$url" > "$S/req.$n.url"
        printf '%s\n' "$ARGS" > "$S/req.$n.args"
        if printf '%s' "$ARGS" | grep -qx '@-'; then cat > "$S/req.$n.stdin"; fi ;;
esac
exit 0
EOF

# A FrankenPHP "binary": <file> <frankenphp version> <php version>
mkfphp() {
    cat > "$1" <<EOF
#!/bin/bash
# fake frankenphp $2 / $3 $(date +%s%N)
case "\$1" in
    -v) echo "FrankenPHP v$2 PHP $3 Caddy v2.10.2 h1:abc" ;;
    build-info) printf 'go\tgo1.25\ndep\tgithub.com/php/frankenphp\tv$2\th1:x\n' ;;
    php-cli) d="\${PHP_INI_SCAN_DIR#:}"
             if [ -f "\$STATE/fphp.nojit" ] || ! grep -q '^opcache.jit = ' "\$d/jit.ini" 2>/dev/null || [ ! -f "\$2" ]; then echo jit-no; else echo jit-ok; fi ;;
esac
EOF
    chmod 755 "$1"
}
mkdir -p "${STATE}/dl"
# gh_release <tag> <php> [bad-digest]
gh_release() {
    local tag="$1" php="$2" f="${STATE}/dl/frankenphp-${1}" sum
    mkfphp "$f" "${tag#v}" "$php"
    sum=$(sha256sum "$f" | awk '{print $1}')
    [[ -n "${3:-}" ]] && sum="0000"
    jq -n --arg t "$tag" --arg u "https://dl.test/frankenphp-${tag}" --arg d "sha256:${sum}" \
        '{tag_name: $t, assets: [{name: "frankenphp-linux-x86_64-gnu", browser_download_url: $u, digest: $d},
                                 {name: "frankenphp-linux-aarch64-gnu", browser_download_url: "https://dl.test/none", digest: ""}]}' \
        > "${STATE}/gh.latest"
    cp "${STATE}/gh.latest" "${STATE}/gh.tag.v${tag#v}"
}

CFG="${FAKE}/etc/cipi"; mkdir -p "$CFG" "${FAKE}/etc/supervisor/conf.d" "${FAKE}/var/lib/cipi" "${FAKE}/var/log/cipi"
head -c 32 /dev/urandom | base64 > "${CFG}/.vault_key"
FROOT="${FAKE}/opt/cipi-frankenphp"

L() {
    PATH="${BIN}:${PATH}" STATE="$STATE" FAKE="$FAKE" CIPI_LIB="$LIBT" CIPI_CONFIG="$CFG" CIPI_LOG="${FAKE}/var/log/cipi" \
        FRANKENPHP_ROOT="$FROOT" FRANKENPHP_PROC="${STATE}/proc" FRANKENPHP_VERIFY_TRIES=3 \
        FRANKENPHP_GITHUB_API="https://api.github.test/repos/php/frankenphp" \
        bash -c 'set -euo pipefail
                 RED=""; GREEN=""; YELLOW=""; CYAN=""; DIM=""; NC=""; BOLD=""
                 source "$CIPI_LIB/common.sh"
                 cipi_notify() { echo "NOTIFY [$3] $1" >> "$STATE/notify.log"; }
                 reload_supervisor() { :; }
                 '"$1"
}
F() { L 'source "$CIPI_LIB/frankenphp.sh"; '"$1"; }

# apps.json (plain JSON is read as is; writes encrypt it)
cat > "${CFG}/apps.json" <<'EOF'
{
  "shop":  {"php": "8.5", "octane": "frankenphp", "octane_port": "8101", "domain": "shop.test"},
  "blog":  {"php": "8.5", "domain": "blog.test"},
  "news":  {"php": "8.5", "domain": "news.test"},
  "api86": {"php": "8.6", "octane": "frankenphp", "octane_port": "8102", "domain": "api.test"},
  "old":   {"php": "7.4", "domain": "old.test"},
  "spa":   {"php": "8.5", "runtime": "node", "domain": "spa.test"}
}
EOF
for a in shop api86; do
    mkdir -p "${FAKE}/home/${a}/releases/1/vendor/laravel/octane/src/Commands/Concerns" "${FAKE}/home/${a}/.deployer"
    ln -sfn "${FAKE}/home/${a}/releases/1" "${FAKE}/home/${a}/current"
    printf '[program:%s-octane]\ncommand=/usr/bin/php8.5 artisan octane:start\nenvironment=PHP_INI_SCAN_DIR=":/etc/php/cipi-octane.d"\n' "$a" \
        > "${FAKE}/etc/supervisor/conf.d/${a}.conf"
done
for v in 7.4 8.5 8.6; do mkdir -p "${FAKE}/etc/php/${v}/fpm/conf.d" "${FAKE}/etc/php/${v}/fpm/pool.d"; done
printf 'memory_limit = 256M\n' > "${FAKE}/etc/php/8.5/fpm/conf.d/99-cipi.ini"
reset_logs() { : > "${STATE}/supervisorctl.log"; : > "${STATE}/notify.log"; : > "${STATE}/curl.log"; : > "${STATE}/systemctl.log"; }

# ── 1. store ─────────────────────────────────────────────────
echo "--- store"
reset_logs
gh_release v1.13.2 8.5.13
out=$(F 'fphp_fetch' 2>/dev/null); rc=$?
[[ $rc -eq 0 && "$out" == "1.13.2-php8.5.13" ]] && pass "a GitHub release becomes build 1.13.2-php8.5.13" || fail "fetch: rc=$rc out=$out"
B="${FROOT}/builds/1.13.2-php8.5.13"
[[ -x "${B}/frankenphp" && "$(stat -c %a "${B}/frankenphp")" == 755 && "$(stat -c %a "$B")" == 755 ]] \
    && grep -qx 'source=github:v1.13.2' "${B}/meta" && grep -qx 'php=8.5.13' "${B}/meta" && grep -qx 'frankenphp=1.13.2' "${B}/meta" \
    && pass "build 0755, meta records FrankenPHP, PHP and source" || fail "build files: $(ls -la "$B" 2>&1) $(cat "${B}/meta" 2>&1)"
grep -q 'runuser -u nobody' "${STATE}/runuser.log" && pass "a downloaded binary is probed as nobody" || fail "probe user"
grep -q 'out=$(runuser -u "$user" -- setsid -w timeout 10 "$bin" -v 2>/dev/null < /dev/null' "${LIB}/frankenphp.sh" \
    && pass "a FrankenPHP binary is asked its version as a user, without a terminal" || fail "probe without terminal"
n=$(grep -c 'https://dl.test/' "${STATE}/curl.log")
F 'fphp_fetch' >/dev/null 2>&1
[[ "$(grep -c 'https://dl.test/' "${STATE}/curl.log")" == "$n" ]] && pass "a release already in the store is not downloaded again" || fail "downloaded twice"
gh_release v1.13.3 8.5.13 bad
out=$(F 'fphp_fetch' 2>&1); rc=$?
[[ $rc -ne 0 && ! -d "${FROOT}/builds/1.13.3-php8.5.13" ]] && grep -q "does not match GitHub's digest" <<< "$out" \
    && pass "a download that does not match GitHub's digest is refused" || fail "digest: rc=$rc $out"
[[ -z "$(find "$FROOT" -maxdepth 2 -name '.fetch.*' -o -maxdepth 2 -name '.add.*')" ]] && pass "no temp directory left" || fail "temp left"

# ── 2. adopt ─────────────────────────────────────────────────
echo "--- adopt"
reset_logs
mkfphp "${FAKE}/home/shop/releases/1/frankenphp" 1.12.7 8.5.12
out=$(F 'fphp_adopt shop' 2>/dev/null); rc=$?
ADOPT="$out"
[[ $rc -eq 0 && "$out" == 1.12.7-php8.5.12-* ]] && pass "the binary in the live release is adopted ($out)" || fail "adopt: rc=$rc $out"
grep -qx 'source=adopted:shop' "${FROOT}/builds/${ADOPT}/meta" 2>/dev/null && pass "source: adopted:shop" || fail "adopt source"
[[ "$(readlink "${FROOT}/apps/shop")" == "../builds/${ADOPT}" ]] && pass "shop is pinned to it" || fail "pin: $(readlink "${FROOT}/apps/shop")"
[[ -L "${FAKE}/home/shop/current/frankenphp" && "$(readlink "${FAKE}/home/shop/current/frankenphp")" == "${FROOT}/apps/shop/frankenphp" ]] \
    && pass "the release's frankenphp is now a link to the pin" || fail "release link: $(ls -la "${FAKE}/home/shop/current/")"
[[ ! -s "${STATE}/supervisorctl.log" ]] && pass "adopting restarts nothing" || fail "supervisorctl called: $(cat "${STATE}/supervisorctl.log")"
grep -q 'runuser -u shop' "${STATE}/runuser.log" && pass "a binary from an app's home is probed as that app" || fail "adopt probe user"
[[ "$(F 'fphp_adopt shop; echo rc=$?')" == "rc=0" ]] && pass "adopting a pinned app changes nothing" || fail "second adopt"

# ── 3. candidates ────────────────────────────────────────────
echo "--- which build an app may get"
[[ "$(F 'fphp_candidate shop "$(fphp_app_build shop)"')" == "1.13.2-php8.5.13" ]] && pass "shop (8.5): the newest GitHub build on 8.5" || fail "candidate shop"
[[ -z "$(F 'fphp_candidate api86')" ]] && pass "api86 (8.6): nothing on 8.6 yet" || fail "candidate api86"
cp "${CFG}/apps.json" "${STATE}/apps.bak"
F 'f=$(mktemp); vault_read apps.json | jq ".shop2 = {php: \"8.5\", octane: \"frankenphp\", octane_port: \"8103\"}" > "$f"; vault_write apps.json < "$f"; rm -f "$f"
   fphp_build_trusted_for "'"$ADOPT"'" shop2 && echo trusted || echo refused' > "${STATE}/o" 2>&1
grep -qx refused "${STATE}/o" && pass "a build adopted from shop is never offered to another app" || fail "trust: $(cat "${STATE}/o")"
out=$(F '_fphp_use shop2 '"$ADOPT" 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q 'not given to' <<< "$out" && pass "cipi frankenphp use refuses it too" || fail "use adopted: $out"
F 'app_remove shop2 2>/dev/null || { f=$(mktemp); vault_read apps.json | jq "del(.shop2)" > "$f"; vault_write apps.json < "$f"; rm -f "$f"; }' >/dev/null 2>&1

# ── 4. upgrade ───────────────────────────────────────────────
echo "--- upgrade"
reset_logs
gh_release v1.13.2 8.5.13
out=$(F '_fphp_upgrade shop --yes' 2>&1); rc=$?
[[ $rc -eq 0 && "$(readlink "${FROOT}/apps/shop")" == "../builds/1.13.2-php8.5.13" ]] && pass "shop moves to 1.13.2-php8.5.13" || fail "upgrade: rc=$rc $out"
grep -q 'supervisorctl update\|supervisorctl restart shop-octane' "${STATE}/supervisorctl.log" && pass "its Octane restarts" || fail "no restart: $(cat "${STATE}/supervisorctl.log")"
grep -q 'http://127.0.0.1:8101' "${STATE}/curl.log" && pass "and is checked on its port" || fail "no port check"
grep -q 'environment=PHP_INI_SCAN_DIR=":.*cipi-octane.d:.*cipi-octane-apps/shop",PATH="'"${FAKE}"'/home/shop/current:/usr/local/sbin' "${FAKE}/etc/supervisor/conf.d/shop.conf" \
    && [[ "$(grep -c '^environment=' "${FAKE}/etc/supervisor/conf.d/shop.conf")" == 1 ]] \
    && pass "the program is rewritten: the app's ini directory, the live release first on PATH" || fail "program: $(cat "${FAKE}/etc/supervisor/conf.d/shop.conf")"
grep -q 'NOTIFY \[frankenphp_upgrade\]' "${STATE}/notify.log" && pass "notified (frankenphp_upgrade)" || fail "notify"
[[ -d "${FROOT}/builds/${ADOPT}" ]] && pass "the previous build stays: the way back" || fail "previous build pruned too early"

# a build Octane does not come up on
reset_logs
mkfphp "${TMP}/custom" 1.13.2 8.5.14
out=$(F '_fphp_import '"${TMP}/custom" 2>&1); rc=$?
IMP=$(ls "${FROOT}/builds" | grep '^1.13.2-php8.5.14-' || true)
[[ $rc -eq 0 && -n "$IMP" ]] && grep -qx 'source=import:custom' "${FROOT}/builds/${IMP}/meta" && pass "an imported binary is a build ($IMP)" || fail "import: $out"
echo "$IMP" > "${STATE}/bad.builds"
out=$(F '_fphp_upgrade shop --yes --no-fetch' 2>&1); rc=$?
[[ $rc -ne 0 && "$(readlink "${FROOT}/apps/shop")" == "../builds/1.13.2-php8.5.13" ]] && grep -q 'back to 1.13.2-php8.5.13' <<< "$out" \
    && pass "Octane FATAL on the newer build: back to the previous one" || fail "rollback: rc=$rc $out pin=$(readlink "${FROOT}/apps/shop")"
grep -q 'upgrade failed' "${STATE}/notify.log" && pass "the failure is notified" || fail "failure notify: $(cat "${STATE}/notify.log")"
rm -f "${STATE}/bad.builds"
echo 000 > "${STATE}/port.code"
out=$(F '_fphp_use shop '"$IMP" 2>&1); rc=$?
[[ $rc -ne 0 && "$(readlink "${FROOT}/apps/shop")" == "../builds/1.13.2-php8.5.13" ]] && pass "a port that does not answer is a failure too" || fail "port 000: $out"
rm -f "${STATE}/port.code"

# another PHP minor, a new major: announced, not applied
reset_logs
gh_release v1.14.0 8.6.0
out=$(F '_fphp_upgrade --cron --yes' 2>&1)
[[ "$(readlink "${FROOT}/apps/shop")" == "../builds/${IMP}" || "$(readlink "${FROOT}/apps/shop")" == "../builds/1.13.2-php8.5.13" ]] \
    && [[ "$(fphp_m=$(readlink "${FROOT}/apps/shop"); grep '^php=' "${FROOT}/builds/${fphp_m#../builds/}/meta")" == php=8.5.* ]] \
    && pass "a release on PHP 8.6 does not move shop (PHP 8.5)" || fail "shop moved: $(readlink "${FROOT}/apps/shop")"
[[ "$(readlink "${FROOT}/apps/api86")" == "../builds/1.14.0-php8.6.0" ]] && pass "api86 (PHP 8.6) gets it — 8.5 and 8.6 side by side" || fail "api86: $(readlink "${FROOT}/apps/api86") $out"
grep -q 'NOTIFY \[frankenphp_available\]' "${STATE}/notify.log" && pass "shop: the release on another PHP is announced" || fail "available notify: $(cat "${STATE}/notify.log")"
n=$(grep -c 'frankenphp_available' "${STATE}/notify.log")
F '_fphp_upgrade --cron --yes' >/dev/null 2>&1
[[ "$(grep -c 'frankenphp_available' "${STATE}/notify.log")" == "$n" ]] && pass "…once, not every night" || fail "announced twice"
grep -q "FrankenPHP 1.14.0 is out and carries PHP 8.6.0; 'shop' is on PHP 8.5" <<< "$out" && pass "the message says why and what to do" || fail "message: $out"
reset_logs
gh_release v2.0.0 8.6.1
F '_fphp_upgrade --cron --yes' >/dev/null 2>&1
[[ "$(readlink "${FROOT}/apps/api86")" == "../builds/1.14.0-php8.6.0" ]] && grep -q 'new major release' "${STATE}/notify.log" \
    && pass "a new FrankenPHP major is announced, never applied by itself" || fail "major: $(readlink "${FROOT}/apps/api86") $(cat "${STATE}/notify.log")"
out=$(F '_fphp_status --json' 2>/dev/null)
jq -e '.apps | map({(.app): .build_php}) | add | .shop|startswith("8.5")' <<< "$out" >/dev/null \
    && jq -e '.apps[] | select(.app == "api86") | .build_php == "8.6.0" and .state == "ok"' <<< "$out" >/dev/null \
    && jq -e '.autoupdate == true' <<< "$out" >/dev/null \
    && pass "status --json: each app's build and PHP, nightly patches on" || fail "status json: $out"
F '_fphp_status' >/dev/null 2>&1 && pass "status (table) runs" || fail "status table"

# use: the checks
out=$(F '_fphp_use shop 1.14.0-php8.6.0' 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q "carries PHP 8.6.0; 'shop' is on PHP 8.5" <<< "$out" && pass "use: another PHP minor is refused without --force" || fail "use minor: $out"
printf "<?php\n    protected \$requiredFrankenPhpVersion = '1.14.0';\n" > "${FAKE}/home/shop/current/vendor/laravel/octane/src/Commands/Concerns/InstallsFrankenPhpDependencies.php"
out=$(F '_fphp_use shop 1.13.2-php8.5.13' 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q 'needs FrankenPHP 1.14.0 or newer' <<< "$out" && pass "use: a build below what laravel/octane asks for is refused" || fail "use required: $out"

# prune
mkfphp "${TMP}/gone" 1.11.0 8.5.10
GONE=$(F 'fphp_build_add '"${TMP}/gone"' adopted:gone' 2>/dev/null)
F 'fphp_prune'
[[ -d "${FROOT}/builds/${ADOPT}" ]] && pass "prune: shop's adopted build stays as its way back" || fail "adopted pruned"
[[ -n "$GONE" && ! -d "${FROOT}/builds/${GONE}" ]] && pass "prune: an adopted build of an app that is gone goes" || fail "gone kept: $GONE"
left=$(ls "${FROOT}/builds" | tr '\n' ' ')
[[ -d "${FROOT}/builds/$(basename "$(readlink "${FROOT}/apps/shop")")" && -d "${FROOT}/builds/1.14.0-php8.6.0" ]] \
    && pass "prune: what apps use stays ($left)" || fail "prune removed a used build: $left"
n85=$(for b in "${FROOT}"/builds/*; do grep -q '^php=8\.5' "$b/meta" && grep -qE '^source=(github|import):' "$b/meta" && echo x; done | wc -l)
[[ "$n85" -le 2 ]] && pass "prune: on 8.5, the build in use and one more from GitHub or an import" || fail "prune kept $n85 on 8.5"

# ── 5. state, report, pending ────────────────────────────────
echo "--- state, cipi php upgrade, cipi pending"
mkfphp "${TMP}/old" 1.12.0 8.5.11
OLD=$(F 'fphp_build_add '"${TMP}/old"' import:old')
F 'fphp_app_set shop '"$OLD"
[[ "$(F 'fphp_app_state shop' | cut -d' ' -f1)" == vulnerable ]] && pass "PHP 8.5.11 inside: vulnerable (floor 8.5.13)" || fail "state: $(F 'fphp_app_state shop')"
out=$(L 'source "$CIPI_LIB/php.sh"; _php_frankenphp_report || echo rc=$?' 2>&1)
grep -q 'shop  FrankenPHP 1.12.0 on PHP 8.5.11  VULNERABLE — needs a build on PHP 8.5.13: cipi frankenphp upgrade shop' <<< "$out" && grep -q 'rc=1' <<< "$out" \
    && pass "cipi php upgrade: VULNERABLE, with the command that fixes it (not octane:install)" || fail "report: $out"
! grep -q 'octane:install' "${LIB}/php.sh" && pass "the octane:install advice is gone (it does not replace a binary)" || fail "octane:install still advised"
out=$(L 'source "$CIPI_LIB/pending.sh"; PENDING_ITEMS=(); _pending_frankenphp; printf "%s\n" "${PENDING_ITEMS[@]+"${PENDING_ITEMS[@]}"}"' 2>&1)
grep -q $'^critical\tfrankenphp-shop\t' <<< "$out" && pass "cipi pending: critical for shop" || fail "pending: $out"
mkdir -p "${STATE}/proc/77"; ln -sfn /somewhere/else/frankenphp "${STATE}/proc/77/exe"; echo 77 > "${STATE}/pid.shop"
[[ "$(F 'fphp_app_state shop' | cut -d' ' -f4)" == yes ]] && pass "a running binary that is not the pin: restart pending" || fail "restart pending"
ln -sfn "${FROOT}/builds/${OLD}/frankenphp" "${STATE}/proc/77/exe"
[[ "$(F 'fphp_app_state shop' | cut -d' ' -f4)" == no ]] && pass "the pinned binary running: no restart pending" || fail "restart pending false positive"
rm -f "${STATE}/pid.shop"

# ── 6. deploy link ───────────────────────────────────────────
echo "--- cipi-frankenphp-link"
LK() { (cd "${FAKE}/home/$1" && PATH="${BIN}:${PATH}" FAKE_USER="$1" FRANKENPHP_ROOT="$FROOT" "${TMP}/cipi-frankenphp-link" "$2" 2>&1); }
mkdir -p "${FAKE}/home/api86/releases/2"
F 'fphp_app_unset api86'
out=$(LK api86 "${FAKE}/home/api86/releases/2"); rc=$?
[[ $rc -eq 0 && ! -e "${FAKE}/home/api86/releases/2/frankenphp" ]] && grep -q 'no build pinned' <<< "$out" \
    && pass "no pin: nothing linked, the deploy goes on (Octane downloads, as before)" || fail "no pin: rc=$rc $out"
F 'fphp_app_set api86 1.14.0-php8.6.0'
out=$(LK api86 "${FAKE}/home/api86/releases/2"); rc=$?
[[ $rc -eq 0 && "$(readlink "${FAKE}/home/api86/releases/2/frankenphp")" == "${FROOT}/apps/api86/frankenphp" ]] && grep -q 'FrankenPHP 1.14.0 (PHP 8.6.0) linked' <<< "$out" \
    && pass "pin: the release links to it" || fail "link: rc=$rc $out"
mkdir -p "${FAKE}/home/api86/releases/3/vendor/laravel/octane/src/Commands/Concerns"
printf "    protected \$requiredFrankenPhpVersion = '1.15.0';\n" > "${FAKE}/home/api86/releases/3/vendor/laravel/octane/src/Commands/Concerns/InstallsFrankenPhpDependencies.php"
out=$(LK api86 "${FAKE}/home/api86/releases/3"); rc=$?
[[ $rc -eq 1 && ! -e "${FAKE}/home/api86/releases/3/frankenphp" ]] && grep -q 'needs FrankenPHP 1.15.0 or newer' <<< "$out" \
    && pass "laravel/octane asks for more than the pin: the deploy stops, the live release stays" || fail "required: rc=$rc $out"
printf "    protected \$requiredFrankenPhpVersion = '1.13.2';\n" > "${FAKE}/home/api86/releases/3/vendor/laravel/octane/src/Commands/Concerns/InstallsFrankenPhpDependencies.php"
out=$(LK api86 "${FAKE}/home/api86/releases/3"); rc=$?
[[ $rc -eq 0 && -L "${FAKE}/home/api86/releases/3/frankenphp" ]] && pass "…and goes on when the pin is enough" || fail "required ok: $out"
out=$(LK api86 "${TMP}"); rc=$?
[[ $rc -eq 2 ]] && pass "a path that is not one of the app's releases is refused" || fail "outside: rc=$rc $out"

# ── 7. JIT on PHP-FPM ────────────────────────────────────────
echo "--- JIT, PHP-FPM"
reset_logs
J() { L 'source "$CIPI_LIB/app.sh"; '"$1"; }
POOL="${FAKE}/etc/php/8.5/fpm/pool.d/blog.conf"
GJ="${FAKE}/etc/php/8.5/fpm/conf.d/99-zz-cipi-jit.ini"
J '_create_fpm_pool blog 8.5' >/dev/null 2>&1
! grep -q 'opcache.jit' "$POOL" && [[ ! -f "$GJ" ]] && pass "without JIT: no pool line, no server-wide file" || fail "baseline"
out=$(J 'app_jit blog on' 2>&1); rc=$?
grep -qx 'php_admin_value\[opcache.jit\] = tracing' "$POOL" && pass "on: the pool turns JIT on (tracing)" || fail "pool: rc=$rc $out $(cat "$POOL")"
grep -qx 'opcache.jit = off' "$GJ" && grep -qx 'opcache.jit_buffer_size = 128M' "$GJ" \
    && pass "the FPM gets JIT startable and off, buffer 128M" || fail "global: $(cat "$GJ" 2>&1)"
grep -q 'systemctl restart php8.5-fpm' "${STATE}/systemctl.log" && pass "php8.5-fpm restarted" || fail "no restart"
grep -q 'php -d opcache.enable_cli=1 -d opcache.jit_buffer_size=32M -d opcache.jit=tracing' "${STATE}/php.log" && pass "the CLI of 8.5 was asked first" || fail "preflight not run"
grep -q 'NOTIFY \[app_jit\]' "${STATE}/notify.log" && pass "notified (app_jit)" || fail "jit notify"
[[ "$(J 'ARG_json=true; _app_jit_status blog' | jq -r '.enabled and .mode == "tracing" and .runtime == "fpm"')" == true ]] \
    && pass "status --json" || fail "status json: $(J 'ARG_json=true; _app_jit_status blog' 2>&1)"
J '_create_fpm_pool news 8.5' >/dev/null 2>&1
! grep -q 'opcache.jit' "${FAKE}/etc/php/8.5/fpm/pool.d/news.conf" && pass "another app on 8.5 keeps JIT off" || fail "news has jit"
out=$(J 'app_jit news on --buffer=256m --mode=function' 2>&1)
grep -qx 'opcache.jit_buffer_size = 256M' "$GJ" && grep -qx 'php_admin_value\[opcache.jit\] = function' "${FAKE}/etc/php/8.5/fpm/pool.d/news.conf" \
    && pass "the buffer is the largest asked for (256M), each pool its own mode" || fail "buffer max: $(cat "$GJ") $out"
printf 'opcache.jit_buffer_size = 512M\nopcache.jit = tracing\n' >> "${FAKE}/etc/php/8.5/fpm/conf.d/99-cipi.ini"
J '_create_fpm_pool blog 8.5' >/dev/null 2>&1
grep -qx 'opcache.jit_buffer_size = 512M' "$GJ" && ! grep -q '^opcache.jit = ' "$GJ" \
    && pass "a value set with cipi ini wins: buffer kept at 512M, its opcache.jit left alone" || fail "cipi ini kept: $(cat "$GJ")"
printf 'memory_limit = 256M\nopcache.jit = disable\n' > "${FAKE}/etc/php/8.5/fpm/conf.d/99-cipi.ini"
out=$(J 'app_jit blog off; app_jit blog on' 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q 'opcache.jit = disable is set server-wide' <<< "$out" && pass "opcache.jit=disable set server-wide: refused, says how to undo it" || fail "disable: $out"
printf 'memory_limit = 256M\n' > "${FAKE}/etc/php/8.5/fpm/conf.d/99-cipi.ini"
touch "${STATE}/php.nojit"
out=$(J 'app_jit blog on' 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q 'JIT does not start on this PHP' <<< "$out" && ! grep -q 'opcache.jit' "$POOL" \
    && pass "a PHP on which JIT does not start (Xdebug): refused before anything is written" || fail "nojit: $out"
rm -f "${STATE}/php.nojit"
touch "${STATE}/fpm.dead"
out=$(J 'app_jit blog on' 2>&1); rc=$?
[[ $rc -ne 0 ]] && ! grep -q 'opcache.jit' "$POOL" && [[ -z "$(L 'app_jit_mode blog')" ]] \
    && pass "PHP-FPM not active after the restart: the previous setting is back" || fail "fpm rollback: $out"
rm -f "${STATE}/fpm.dead"
out=$(J 'app_jit news off' 2>&1)
! grep -q 'opcache.jit' "${FAKE}/etc/php/8.5/fpm/pool.d/news.conf" && [[ ! -f "$GJ" ]] \
    && pass "off for the last app on 8.5: pool line and server-wide file gone" || fail "off: $(ls "${FAKE}/etc/php/8.5/fpm/conf.d") $out"
out=$(J 'app_jit old on' 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q 'PHP 7.4 has no JIT' <<< "$out" && pass "PHP 7.4: refused" || fail "7.4: $out"
out=$(J 'app_jit spa on' 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q 'Node app' <<< "$out" && pass "a Node app: refused" || fail "node: $out"
out=$(J 'app_jit blog on --buffer=8M' 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q -- '--buffer' <<< "$out" && pass "a buffer outside 16M–1G: refused" || fail "buffer bounds: $out"
# ini overrides: jit owns opcache.jit, a per-app buffer never reaches the pool
J 'app_set_json blog ini "{\"opcache.jit\":\"function\",\"opcache.jit_buffer_size\":\"64M\",\"memory_limit\":\"512M\"}"; app_set_json blog jit "{\"mode\":\"tracing\",\"buffer\":\"128M\"}"; _create_fpm_pool blog 8.5' >/dev/null 2>&1
[[ "$(grep -c 'opcache.jit\]' "$POOL")" == 1 ]] && grep -qx 'php_admin_value\[opcache.jit\] = tracing' "$POOL" && ! grep -q jit_buffer_size "$POOL" \
    && grep -q 'php_admin_value\[memory_limit\] = 512M' "$POOL" \
    && pass "pool: one opcache.jit line (cipi app jit's), no per-app buffer, other overrides kept" || fail "overrides: $(cat "$POOL")"
out=$(L 'jit_fpm_global_sync 8.5 "" blog')
[[ "$out" == changed && ! -f "$GJ" ]] && pass "sync without the app (delete): the file goes, and says it changed" || fail "sync without: $out"
out=$(L 'jit_fpm_global_sync 8.6 blog')
[[ "$out" == changed && -f "${FAKE}/etc/php/8.6/fpm/conf.d/99-zz-cipi-jit.ini" ]] && pass "sync with an app moving to 8.6 (app edit --php)" || fail "sync with: $out"

# ── 8. JIT on Octane ─────────────────────────────────────────
echo "--- JIT, Octane"
reset_logs
F 'fphp_app_set shop 1.13.2-php8.5.13'
OI="${FAKE}/etc/php/cipi-octane-apps/shop/50-cipi-jit.ini"
out=$(J 'app_jit shop on' 2>&1); rc=$?
[[ $rc -eq 0 ]] && grep -qx 'opcache.jit = tracing' "$OI" && grep -qx 'opcache.jit_buffer_size = 128M' "$OI" \
    && pass "on: the app's own Octane ini carries both settings" || fail "octane jit: rc=$rc $out"
grep -q "runuser -u shop -- setsid -w timeout 20 env PHP_INI_SCAN_DIR=:.* ${FROOT}/apps/shop/frankenphp php-cli .*/check.php" "${STATE}/runuser.log" \
    && pass "the FrankenPHP build was asked first, as the app user" || fail "octane preflight: $(tail -n 3 "${STATE}/runuser.log")"
grep -q 'supervisorctl \(update\|restart shop-octane\)' "${STATE}/supervisorctl.log" && pass "Octane restarted" || fail "octane restart"
out=$(J 'app_jit shop --json' 2>&1)
jq -e '.runtime == "octane" and .php == "8.5.13" and .enabled and .mode == "tracing"' <<< "$out" >/dev/null \
    && pass "status --json of an Octane app: the PHP inside its build" || fail "octane status: $out"
[[ ! -f "${FAKE}/etc/php/8.5/fpm/conf.d/99-zz-cipi-jit.ini" ]] && pass "an Octane app does not make JIT startable on PHP-FPM" || fail "octane app wrote the FPM file"
J 'app_jit shop off' >/dev/null 2>&1
touch "${STATE}/bad.jit.shop-octane"
out=$(J 'app_jit shop on' 2>&1); rc=$?
[[ $rc -ne 0 && ! -f "$OI" ]] && [[ -z "$(L 'app_jit_mode shop')" ]] && pass "Octane FATAL with JIT: file removed, setting back to off" || fail "octane rollback: $out"
rm -f "${STATE}/bad.jit.shop-octane"
touch "${STATE}/fphp.nojit"
out=$(J 'app_jit shop on' 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q 'JIT does not start' <<< "$out" && pass "a FrankenPHP build without JIT: refused" || fail "octane nojit: $out"
rm -f "${STATE}/fphp.nojit"
J '_app_jit_drop_on_convert blog' >/dev/null 2>&1
[[ -z "$(L 'app_jit_mode blog')" ]] && pass "convert drops JIT (it was checked for the other runtime)" || fail "convert drop"

# ── 9. migration 5.10.0 ──────────────────────────────────────
echo "--- migration 5.10.0"
reset_logs
rm -rf "${FROOT}"
mkdir -p "${FAKE}/home/api86/releases/9"; ln -sfn "${FAKE}/home/api86/releases/9" "${FAKE}/home/api86/current"
mkfphp "${FAKE}/home/api86/releases/9/frankenphp" 1.13.2 8.6.0
rm -f "${FAKE}/home/shop/current/frankenphp"
for a in shop api86; do
    sed -e "s|__CIPI_APP_USER__|$a|g" -e "s|__CIPI_HOOK_[A-Z_]*__|// hook|g" -e 's|__CIPI_[A-Z_]*__|x|g' "${LIB}/deployer/laravel-octane.php" \
        | grep -v "cipi:frankenphp\|cipi-frankenphp-link\|The FrankenPHP build Cipi\|the release before it goes live\|after the vendors, so a release\|Without the helper (a server" \
        | awk '/^task\(.cipi:frankenphp/{skip=1} skip&&/^}\);/{skip=0; next} !skip' > "${FAKE}/home/${a}/.deployer/deploy.php"
done
grep -q 'cipi:frankenphp' "${FAKE}/home/shop/.deployer/deploy.php" && fail "test setup: old deploy.php still has the task"
MIG() {
    PATH="${BIN}:${PATH}" STATE="$STATE" FAKE="$FAKE" CIPI_LIB="$LIBT" CIPI_CONFIG="$CFG" CIPI_LOG="${FAKE}/var/log/cipi" \
        FRANKENPHP_ROOT="$FROOT" FRANKENPHP_PROC="${STATE}/proc" CIPI_FRANKENPHP_LINK_BIN="${TMP}/installed-link" \
        bash "${LIBT}/migrations/5.10.0.sh" 2>&1
}
out=$(MIG); rc=$?
[[ $rc -eq 0 ]] && grep -q 'Migration 5.10.0 complete' <<< "$out" && pass "migration runs" || fail "migration: rc=$rc $out"
[[ -x "${TMP}/installed-link" && "$(stat -c %a "${TMP}/installed-link")" == 755 ]] && pass "link helper installed 0755" || fail "helper"
[[ "$(readlink "${FROOT}/apps/api86")" == ../builds/1.13.2-php8.6.0-* ]] && grep -q 'api86: pinned to' <<< "$out" \
    && pass "api86: the binary in its live release pinned" || fail "api86 pin: $(readlink "${FROOT}/apps/api86") $out"
grep -q 'shop: no FrankenPHP binary in its live release' <<< "$out" && pass "shop (no binary): said, left for its next deploy" || fail "shop: $out"
[[ ! -s "${STATE}/supervisorctl.log" ]] && pass "nothing restarted" || fail "migration restarted: $(cat "${STATE}/supervisorctl.log")"
dp="${FAKE}/home/shop/.deployer/deploy.php"
h=$(grep -n "after('deploy:vendors', 'cipi:frankenphp');" "$dp" | cut -d: -f1); n=$(grep -n "after('deploy:vendors', 'cipi:node_build');" "$dp" | cut -d: -f1)
[[ -n "$h" && -n "$n" && $((h + 1)) -eq "$n" ]] && grep -q "^task('cipi:frankenphp', function () {" "$dp" \
    && pass "deploy.php: hook before node_build, task added" || fail "deploy.php: $(grep -n frankenphp "$dp")"
cp "$dp" "${STATE}/dp1"
out=$(MIG); rc=$?
[[ $rc -eq 0 ]] && cmp -s "$dp" "${STATE}/dp1" && grep -q 'already links FrankenPHP' <<< "$out" && grep -q 'api86: already pinned' <<< "$out" \
    && pass "a second run changes nothing" || fail "second run: $out"
echo '<?php // hand-written' > "${FAKE}/home/shop/.deployer/deploy.php"
out=$(MIG)
grep -q 'shop: deploy.php does not have the lines of the Octane recipe' <<< "$out" && grep -qx '<?php // hand-written' "${FAKE}/home/shop/.deployer/deploy.php" \
    && pass "a hand-written deploy.php is left alone, with a warning" || fail "hand-written: $out"

# ── 10. notification channels ────────────────────────────────
echo "--- cipi notification"
rm -f "${STATE}"/req.*
N() { L 'source "$CIPI_LIB/notifications.sh"; source "$CIPI_LIB/alerts.sh"; source "$CIPI_LIB/smtp.sh"; '"$1" < /dev/null; }
req() { ls "${STATE}"/req.*.url 2>/dev/null | sort -V | tail -n 1 | sed 's/\.url$//'; }
out=$(N 'notifications_command add resend mail --api-key=re_TestKey_123 --from="Cipi <alerts@example.com>" --to="ops@example.com, dev@example.com"' 2>&1); rc=$?
cfg=$(L 'vault_read alerts.json')
[[ $rc -eq 0 ]] && jq -e '.channels[] | select(.id == "mail") | .type == "resend" and .api_key == "re_TestKey_123" and .to == ["ops@example.com","dev@example.com"] and .from == "Cipi <alerts@example.com>"' <<< "$cfg" >/dev/null \
    && pass "resend: added, recipients as a list" || fail "resend add: $out $cfg"
! grep -q 're_TestKey_123' "${CFG}/alerts.json" && pass "the API key is stored encrypted (vault)" || fail "alerts.json in clear"
out=$(N 'notifications_command add resend bad --api-key=sk_x --from=a@b.it --to=c@d.it' 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q 'Resend API key' <<< "$out" && pass "resend: a key that is not re_… is refused" || fail "resend bad key: $out"
out=$(N 'notifications_command add resend bad2 --api-key=re_x --from=a@b.it --to=not-an-address' 2>&1); rc=$?
[[ $rc -ne 0 ]] && pass "resend: a recipient that is not an address is refused" || fail "resend bad to"
N 'cipi_notify "Deploy failed: shop" "Line one\nLine two" deploy_fail' >/dev/null 2>&1
r=""; for f in "${STATE}"/req.*.url; do grep -q api.resend.com "$f" && r="${f%.url}"; done
[[ -n "$r" ]] && grep -qx 'Authorization: Bearer re_TestKey_123' "${r}.stdin" \
    && ! grep -q 're_TestKey_123' "${r}.args" \
    && pass "resend: delivered, the key on stdin (-H @-), not on the command line" || fail "resend deliver: $(cat "${r}.args" 2>&1)"
body=$(awk 'p { print; exit } $0 == "-d" { p = 1 }' "${r}.args" | tr '~' '\n')
jq -e '.subject == "Deploy failed: shop" and (.text | startswith("Line one\nLine two")) and .to == ["ops@example.com","dev@example.com"]' <<< "$body" >/dev/null \
    && pass "resend: subject, recipients, real newlines in the text" || fail "resend body: $body"

# SES: Signature Version 4, checked by doing it again here
k=$(L 'source "$CIPI_LIB/alerts.sh"; k=$(_alert_hmac "key:AWS4wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY" 20120215); k=$(_alert_hmac "hexkey:$k" us-east-1); k=$(_alert_hmac "hexkey:$k" iam); _alert_hmac "hexkey:$k" aws4_request')
[[ "$k" == f4780e2d9f65fa895f9c67b32ce1baf0b0d8a43505a000a1a9e090d414db404d ]] && pass "SigV4 signing key: AWS's own test vector" || fail "signing key: $k"
SK="wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
out=$(N 'notifications_command add ses aws --region=eu-west-1 --access-key=AKIAIOSFODNN7EXAMPLE --secret-key='"$SK"' --from=alerts@example.com --to=ops@example.com' 2>&1); rc=$?
[[ $rc -eq 0 ]] && pass "ses: added" || fail "ses add: $out"
out=$(N 'notifications_command add ses aws2 --region=mars --access-key=AKIAIOSFODNN7EXAMPLE --secret-key='"$SK"' --from=a@b.it --to=c@d.it' 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q -- '--region' <<< "$out" && pass "ses: a region that is not one is refused" || fail "ses region: $out"
N 'notifications_command disable mail' >/dev/null 2>&1
rm -f "${STATE}"/req.*
N 'cipi_notify "Backup failed" "Profile nightly" backup_fail' >/dev/null 2>&1
r=""; for f in "${STATE}"/req.*.url; do grep -q 'https://email.eu-west-1.amazonaws.com/v2/email/outbound-emails' "$f" && r="${f%.url}"; done
! grep -l api.resend.com "${STATE}"/req.*.url >/dev/null 2>&1 && pass "a disabled channel (mail) gets nothing" || fail "disabled channel delivered"
if [[ -n "$r" ]]; then
    payload=$(cat "${r}.stdin")
    amz=$(grep '^X-Amz-Date: ' "${r}.args" | cut -d' ' -f2)
    auth=$(grep '^Authorization: AWS4-HMAC-SHA256 ' "${r}.args")
    day="${amz:0:8}"
    h() { printf '%s' "$2" | openssl dgst -sha256 -mac HMAC -macopt "$1" | awk '{print $NF}'; }
    sha() { printf '%s' "$1" | openssl dgst -sha256 | awk '{print $NF}'; }
    creq="POST"$'\n'"/v2/email/outbound-emails"$'\n'$'\n'"content-type:application/json"$'\n'"host:email.eu-west-1.amazonaws.com"$'\n'"x-amz-date:${amz}"$'\n'$'\n'"content-type;host;x-amz-date"$'\n'"$(sha "$payload")"
    sts="AWS4-HMAC-SHA256"$'\n'"${amz}"$'\n'"${day}/eu-west-1/ses/aws4_request"$'\n'"$(sha "$creq")"
    kk=$(h "key:AWS4${SK}" "$day"); kk=$(h "hexkey:$kk" eu-west-1); kk=$(h "hexkey:$kk" ses); kk=$(h "hexkey:$kk" aws4_request)
    want=$(h "hexkey:$kk" "$sts")
    [[ "$auth" == "Authorization: AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/${day}/eu-west-1/ses/aws4_request, SignedHeaders=content-type;host;x-amz-date, Signature=${want}" ]] \
        && pass "ses: the request is signed as SigV4 asks (recomputed here)" || fail "ses signature: $auth / want $want"
    jq -e '.FromEmailAddress == "alerts@example.com" and .Destination.ToAddresses == ["ops@example.com"] and .Content.Simple.Subject.Data == "Backup failed"' <<< "$payload" >/dev/null \
        && pass "ses: SendEmail v2 body" || fail "ses body: $payload"
    ! grep -q "$SK" "${r}.args" && pass "ses: the secret key never goes over the wire or the command line" || fail "secret leaked"
else
    fail "ses: nothing sent"
fi

# webhook with a secret, pushover, mattermost, googlechat
N 'notifications_command add webhook siem --url=https://hooks.test/in --secret=s3cr3t' >/dev/null 2>&1
N 'notifications_command add pushover phone --token=azGDORePK8gMaC0QOYAMyEEuzJnyUi --user=uQiRzpo4DXghDmr9QzzfQu27cmVRsG' >/dev/null 2>&1
N 'notifications_command add mattermost mm --url=https://chat.test/hooks/abc' >/dev/null 2>&1
N 'notifications_command add googlechat gc --url=https://chat.googleapis.com/v1/spaces/x/messages?key=k' >/dev/null 2>&1
N 'notifications_command disable aws' >/dev/null 2>&1
rm -f "${STATE}"/req.*
N 'cipi_notify "Scan hit" "1 file" scan_hit' >/dev/null 2>&1
for f in "${STATE}"/req.*.url; do
    b="${f%.url}"
    case "$(cat "$f")" in
        https://hooks.test/in)
            sig=$(grep '^X-Cipi-Signature: sha256=' "${b}.args" | cut -d= -f2)
            [[ -n "$sig" && "$sig" == "$(printf '%s' "$(cat "${b}.stdin")" | openssl dgst -sha256 -mac HMAC -macopt key:s3cr3t | awk '{print $NF}')" ]] \
                && jq -e '.trigger == "scan_hit" and .subject == "Scan hit"' "${b}.stdin" >/dev/null \
                && pass "webhook: JSON body, X-Cipi-Signature is the HMAC-SHA256 of it" || fail "webhook signature" ;;
        https://api.pushover.net/1/messages.json)
            grep -qx 'token=azGDORePK8gMaC0QOYAMyEEuzJnyUi' "${b}.args" && grep -qx 'priority=1' "${b}.args" && grep -qx -- '--form-string' "${b}.args" \
                && pass "pushover: form fields with --form-string, an urgent trigger at priority 1" || fail "pushover: $(cat "${b}.args")" ;;
        https://chat.test/hooks/abc) grep -q '"text"' "${b}.args" && pass "mattermost: Slack's payload" || fail "mattermost" ;;
        https://chat.googleapis.com/*) grep -q '"text"' "${b}.args" && pass "googlechat: text message" || fail "googlechat" ;;
    esac
done
[[ "$(ls "${STATE}"/req.*.url 2>/dev/null | wc -l)" -eq 4 ]] && pass "one request per enabled channel (4)" || fail "requests: $(cat "${STATE}"/req.*.url)"
out=$(N 'notifications_command add webhook w2 --url=http://plain.test' 2>&1); rc=$?
[[ $rc -eq 0 ]] && pass "webhook: http:// allowed (an internal receiver)" || fail "webhook http"
out=$(N 'notifications_command add slack s2 --url=http://hooks.slack.com/x' 2>&1); rc=$?
[[ $rc -ne 0 ]] && pass "slack: http:// refused" || fail "slack http"

# status, secrets, triggers, compatibility
L 'jq -n "{host: \"smtp.test\", port: \"587\", user: \"u\", password: \"pw\", from: \"a@x.it\", to: \"b@x.it, c@x.it\", tls: true, enabled: true}" | vault_write smtp.json' >/dev/null 2>&1
out=$(N 'notifications_command status --json' 2>/dev/null)
jq -e '.channels[0] | .id == "smtp" and .type == "smtp" and .enabled and .to == ["b@x.it","c@x.it"]' <<< "$out" >/dev/null \
    && jq -e '[.channels[].id] | contains(["smtp","mail","aws","siem","phone"])' <<< "$out" >/dev/null \
    && jq -e '.triggers.total > 100 and .triggers.enabled == .triggers.total' <<< "$out" >/dev/null \
    && pass "status --json: SMTP (the smtp.json of before) first, then every channel, the triggers" || fail "status json: $out"
! grep -qE 're_TestKey_123|s3cr3t|wJalrX|azGDORe|"pw"' <<< "$out" && jq -e '.channels[] | select(.id == "mail") | .api_key_set == true' <<< "$out" >/dev/null \
    && pass "status --json shows no secret (api_key_set: true)" || fail "secret in json: $out"
N 'notifications_command status' >/dev/null 2>&1 && pass "status (text) runs" || fail "status text"
out=$(N 'notifications_command disable deploy_fail' 2>&1)
[[ "$(L 'source "$CIPI_LIB/notifications.sh"; _notify_trigger_enabled deploy_fail && echo on || echo off')" == off ]] && pass "disable <trigger>: the older form still toggles the trigger" || fail "trigger toggle: $out"
N 'notifications_command triggers enable deploy_fail' >/dev/null 2>&1
[[ "$(L 'source "$CIPI_LIB/notifications.sh"; _notify_trigger_enabled deploy_fail && echo on || echo off')" == on ]] && pass "triggers enable <trigger>" || fail "triggers enable"
N 'notifications_command disable smtp' >/dev/null 2>&1
[[ "$(L 'vault_read smtp.json | jq -r .enabled')" == false && "$(L 'vault_read smtp.json | jq -r .password')" == pw ]] \
    && pass "disable smtp: the SMTP configuration is kept, only switched off" || fail "smtp toggle"
out=$(N '_smtp_configure() { echo "SMTPCONF $*"; }; notifications_command add smtp --host=h --user=u' 2>&1)
grep -q 'SMTPCONF --host=h --user=u' <<< "$out" && pass "add smtp is cipi smtp configure" || fail "add smtp: $out"
out=$(N 'notifications_command channel add discord legacy --url=https://discord.com/api/webhooks/1/x' 2>&1); rc=$?
[[ $rc -eq 0 ]] && pass "cipi notifications channel add … (before 5.10.0) still works" || fail "legacy channel: $out"
grep -q 'notification|notifications) _maybe_cmd_help notification' "${ROOT}/cipi" && grep -q '        smtp)       _maybe_cmd_help smtp' "${ROOT}/cipi" \
    && pass "dispatch: cipi notification, cipi notifications, cipi smtp" || fail "dispatch notification"
grep -q '/usr/local/bin/cipi smtp configure \*' "${LIB}/cipi-api-sudoers.sh" && pass "the panel's SMTP commands are unchanged" || fail "smtp sudoers"

echo ""
echo "=== ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]

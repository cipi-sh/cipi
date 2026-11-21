#!/bin/bash
# Local regression checks for 5.9.2: Deployer 8 from its GitHub release
# (#519) and the web panel's vhost without snippets/fastcgi-php.conf (#520).
#
# lib/deployer-install.sh and migration 5.9.2 run for real against temp
# paths; curl, php, nginx and systemctl are stubs. A "phar" is a text file
# whose first line is the version the stub php reports for it.
# Run from repo root: bash tests/verify-5.9.2.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/lib"
PASS=0; FAIL=0
pass() { echo "  OK: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
TMP=$(mktemp -d) && [[ -n "$TMP" && -d "$TMP" ]] || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "${TMP:?}"' EXIT

echo "=== Cipi 5.9.2 regression checks ==="
[[ "$(tr -d '[:space:]' < "${ROOT}/version.md")" == "5.9.2" ]] && pass "version.md is 5.9.2" || fail "version.md"
grep -q '^## \[5.9.2\]' "${ROOT}/CHANGELOG.md" && pass "CHANGELOG has 5.9.2" || fail "CHANGELOG"
for f in setup.sh lib/deployer-install.sh lib/deploy.sh lib/gui.sh lib/migrations/5.9.2.sh; do
    bash -n "${ROOT}/${f}" && pass "${f} parses" || fail "${f}"
done

# ── static ───────────────────────────────────────────────────
! grep -q 'deployer.org/deployer.phar -o' "${ROOT}/setup.sh" && pass "setup.sh no longer downloads deployer.org/deployer.phar" || fail "deployer.org still used"
grep -q 'cipi_deployer_install /usr/local/bin/dep' "${ROOT}/setup.sh" && grep -A3 'if ! cipi_deployer_install /usr/local/bin/dep' "${ROOT}/setup.sh" | grep -q 'exit 1' \
    && pass "setup.sh installs the pinned Deployer and stops when it cannot" || fail "setup install_deployer"
grep -q 'refs/heads/${BRANCH}/lib/deployer-install.sh' "${ROOT}/setup.sh" && pass "setup.sh fetches the helper before /opt/cipi exists" || fail "helper bootstrap"
grep -qx 'CIPI_DEPLOYER_VERSION="8.0.5"' "${LIB}/deployer-install.sh" \
    && grep -q 'https://github.com/deployphp/deployer/releases/download/v${CIPI_DEPLOYER_VERSION}/deployer.phar' "${LIB}/deployer-install.sh" \
    && [[ "$(sed -n 's/^CIPI_DEPLOYER_SHA256="\([0-9a-f]*\)"$/\1/p' "${LIB}/deployer-install.sh" | tr -d '\n' | wc -c)" == 64 ]] \
    && pass "Deployer 8.0.5 from GitHub, with a SHA-256" || fail "pin"
! grep -rq 'snippets/fastcgi-php.conf;' "${LIB}/gui.sh" && pass "the panel vhost does not include snippets/fastcgi-php.conf" || fail "gui still includes the snippet"
! grep -rqE '^[^#]*include[[:space:]]+snippets/fastcgi-php' "${LIB}"/*.sh && pass "no vhost of Cipi includes it" || fail "another include"
grep -q 'try_files \\$uri =404;' "${LIB}/gui.sh" && grep -q 'include fastcgi_params;' "${LIB}/gui.sh" \
    && pass "the panel's PHP location: try_files \$uri =404, fastcgi_params" || fail "gui location"

# ── stubs ────────────────────────────────────────────────────
BIN="${TMP}/bin"; S="${TMP}/s"; mkdir -p "$BIN" "$S"
cat > "${BIN}/php" <<'X'
#!/bin/bash
[ "${2:-}" = "--version" ] || exit 1
v=$(head -n 1 "$1" 2>/dev/null); [ -n "$v" ] || exit 1
echo "Deployer $v"
X
cat > "${BIN}/curl" <<'X'
#!/bin/bash
out=""; while [ $# -gt 0 ]; do [ "$1" = "-o" ] && { out="$2"; shift; }; shift; done
[ -f "$S/dl" ] || exit 22
cp "$S/dl" "$out"
X
cat > "${BIN}/nginx" <<'X'
#!/bin/bash
[ -f "$S/nginx.bad" ] && exit 1; exit 0
X
cat > "${BIN}/systemctl" <<'X'
#!/bin/bash
echo "systemctl $*" >> "$S/systemctl.log"
X
chmod +x "$BIN"/*
export PATH="${BIN}:${PATH}" S
I() { bash -c 'set -euo pipefail; source "'"${LIB}"'/deployer-install.sh"; '"$1" 2>&1; }

printf '8.0.5\nphar\n' > "${S}/dl"; SUM=$(sha256sum "${S}/dl" | awk '{print $1}')
D="${TMP}/dep"
printf '6.8.0\n' > "$D"
out=$(I 'cipi_deployer_install '"$D")
[[ $? -ne 0 && "$(head -n 1 "$D")" == 6.8.0 ]] && grep -q 'does not match its SHA-256' <<< "$out" \
    && pass "a download that is not the pinned phar is refused, dep untouched" || fail "checksum: $out"
out=$(I 'CIPI_DEPLOYER_SHA256='"$SUM"'; cipi_deployer_install '"$D"); rc=$?
[[ $rc -eq 0 && "$(head -n 1 "$D")" == 8.0.5 && "$(stat -c %a "$D")" == 755 ]] && pass "the pinned phar is installed 0755" || fail "install: rc=$rc $out"
printf '6.8.0\nphar\n' > "${S}/dl"; SUM6=$(sha256sum "${S}/dl" | awk '{print $1}')
out=$(I 'CIPI_DEPLOYER_SHA256='"$SUM6"'; cipi_deployer_install '"$D"); rc=$?
[[ $rc -ne 0 && "$(head -n 1 "$D")" == 8.0.5 ]] && grep -q "reports version '6.8.0'" <<< "$out" \
    && pass "a phar that is not Deployer 8 is refused, even with a matching checksum" || fail "major: $out"
rm -f "${S}/dl"
out=$(I 'cipi_deployer_install '"$D"); rc=$?
[[ $rc -ne 0 ]] && grep -q 'download failed' <<< "$out" && pass "a failed download says so" || fail "download fail"

# ── cipi deploy refuses Deployer 6 ───────────────────────────
out=$(bash -c 'set -euo pipefail
    error() { echo "ERR $*"; }; warn() { echo "WARN $*"; }; log_action() { :; }
    validate_php_version() { return 0; }; deployer_major_version() { echo 6; }
    source "'"${LIB}"'/deploy.sh"; _deploy_assert_php_compat shop 8.5; echo passed' 2>&1)
grep -q "ERR Deployer 6 is installed" <<< "$out" && ! grep -q passed <<< "$out" \
    && pass "cipi deploy stops on Deployer 6 with what to run" || fail "deploy guard: $out"
out=$(bash -c 'set -euo pipefail
    error() { echo "ERR $*"; }; warn() { :; }; log_action() { :; }
    validate_php_version() { return 0; }; deployer_major_version() { echo 8; }
    source "'"${LIB}"'/deploy.sh"; _deploy_assert_php_compat shop 8.5; echo passed' 2>&1)
grep -q passed <<< "$out" && pass "…and goes on with Deployer 8" || fail "deploy guard 8: $out"

# ── migration 5.9.2 ──────────────────────────────────────────
CFG="${TMP}/cfg"; mkdir -p "$CFG" "${TMP}/log"
VH="${TMP}/cipi-gui"
MIG() {
    CIPI_LIB="$LIB" CIPI_CONFIG="$CFG" CIPI_LOG="${TMP}/log" CIPI_DEP_BIN="$D" CIPI_GUI_VHOST="$VH" \
        bash -c 'source "'"${LIB}"'/deployer-install.sh"; CIPI_DEPLOYER_SHA256="'"$1"'"; export CIPI_DEPLOYER_SHA256
                 sed "s|^source \"\${CIPI_LIB}/deployer-install.sh\"|:|" "'"${LIB}"'/migrations/5.9.2.sh" > "'"${TMP}"'/m.sh"
                 source "'"${LIB}"'/deployer-install.sh" >/dev/null; CIPI_DEPLOYER_SHA256="'"$1"'"
                 set +e; ( set -euo pipefail; source "'"${TMP}"'/m.sh" )' 2>&1
}
printf '8.0.5\nphar\n' > "${S}/dl"
echo '{"shop": {"php": "8.5"}, "legacy": {"php": "7.4"}, "spa": {"php": "7.4", "runtime": "node"}}' > "${CFG}/apps.json"
cat > "$VH" <<'X'
server {
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/cipi-gui.sock;
        include fastcgi_params;
    }
}
X
printf '6.8.0\n' > "$D"
out=$(MIG "$SUM"); rc=$?
[[ "$(head -n 1 "$D")" == 8.0.5 ]] && grep -q 'Deployer 6.8.0 → 8.0.5' <<< "$out" && pass "migration: Deployer 6.8.0 → 8.0.5" || fail "mig dep6: $out"
grep -q '^        try_files \$uri =404;$' "$VH" && ! grep -q snippets "$VH" && grep -q 'systemctl reload nginx' "${S}/systemctl.log" \
    && pass "migration: the panel vhost loses the snippet, nginx reloaded" || fail "mig vhost: $out $(cat "$VH")"
grep -q 'Migration 5.9.2 complete' <<< "$out" && pass "migration completes" || fail "mig complete: $out"
out=$(MIG "$SUM")
grep -q 'Deployer 8.0.5 — nothing to do' <<< "$out" && grep -q 'panel vhost: nothing to do' <<< "$out" && pass "a second run changes nothing" || fail "rerun: $out"
printf '7.3.3\n' > "$D"
out=$(MIG "$SUM")
[[ "$(head -n 1 "$D")" == 7.3.3 ]] && grep -q 'Deployer 7.3.3 kept: Deployer 8 cannot run on the PHP of legacy (PHP 7.4)' <<< "$out" && ! grep -q 'spa' <<< "$out" \
    && pass "Deployer 7 kept while a PHP app is on PHP < 8.3, named (Node apps not counted)" || fail "legacy: $out"
echo '{"shop": {"php": "8.5"}}' > "${CFG}/apps.json"
out=$(MIG "$SUM")
[[ "$(head -n 1 "$D")" == 8.0.5 ]] && pass "Deployer 7 → 8 when every app can run it" || fail "dep7: $out"
printf '6.8.0\n' > "$D"; out=$(MIG "0000")
[[ "$(head -n 1 "$D")" == 6.8.0 ]] && grep -q 'WARNING: Deployer 8.0.5: the download does not match' <<< "$out" && grep -q 'Migration 5.9.2 complete' <<< "$out" \
    && pass "a refused download: warned, dep untouched, the migration goes on" || fail "mig bad sum: $out"
printf 'server {\n        include snippets/fastcgi-php.conf;\n}\n' > "$VH"; cp "$VH" "${TMP}/vh.orig"; touch "${S}/nginx.bad"
out=$(MIG "$SUM")
cmp -s "$VH" "${TMP}/vh.orig" && grep -q 'previous one is back' <<< "$out" && pass "nginx -t refuses: the previous vhost is back" || fail "vhost revert: $out"

echo ""
echo "=== ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]

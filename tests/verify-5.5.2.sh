#!/bin/bash
# Local regression checks for 5.5.2 — `cipi disk` opened to the panel API:
# the www-data sudoers whitelist allows `cipi disk` / `cipi disk *`, and the
# migration regenerates /etc/sudoers.d/cipi-api from it.
# Run from repo root: bash tests/verify-5.5.2.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/lib"
PASS=0
FAIL=0

pass() { echo "  OK: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

echo "=== Cipi 5.5.2 regression checks ==="

[[ "$(tr -d '[:space:]' < "${ROOT}/version.md")" == "5.5.2" ]] \
    && pass "version.md is 5.5.2" || fail "version.md is not 5.5.2"
grep -q '^## \[5.5.2\]' "${ROOT}/CHANGELOG.md" \
    && pass "CHANGELOG has a 5.5.2 entry" || fail "CHANGELOG has no 5.5.2 entry"
[[ -f "${LIB}/migrations/5.5.2.sh" ]] && pass "5.5.2 migration present" || fail "missing 5.5.2 migration"

# ── sudoers whitelist ────────────────────────────────────────
bash -n "${LIB}/cipi-api-sudoers.sh" && pass "cipi-api-sudoers.sh parses" || fail "cipi-api-sudoers.sh does not parse"
grep -qF '/usr/local/bin/cipi disk, \' "${LIB}/cipi-api-sudoers.sh" \
    && pass "sudoers allow 'cipi disk'" || fail "sudoers do not allow 'cipi disk'"
grep -qF '/usr/local/bin/cipi disk *, \' "${LIB}/cipi-api-sudoers.sh" \
    && pass "sudoers allow 'cipi disk *' (--json, db --json)" || fail "sudoers do not allow 'cipi disk *'"
# sudo-rs accepts '*' only as the last token
! grep -qE 'cipi disk \* \*' "${LIB}/cipi-api-sudoers.sh" \
    && pass "no 'disk * *' pattern (sudo-rs)" || fail "'disk * *' is refused by sudo-rs"

# The whitelist written by the function must be the one the file declares.
TMP=$(mktemp -d) || { echo "mktemp failed" >&2; exit 1; }
trap 'rm -rf "${TMP:?}"' EXIT
sed "s|/etc/sudoers.d/cipi-api|${TMP}/cipi-api|g" "${LIB}/cipi-api-sudoers.sh" > "${TMP}/sudoers.sh"
if ! grep -q '/etc/sudoers.d' "${TMP}/sudoers.sh"; then
    # shellcheck source=/dev/null
    source "${TMP}/sudoers.sh"
    write_cipi_api_sudoers
    grep -qE '^\s*/usr/local/bin/cipi disk, \\$' "${TMP}/cipi-api" \
        && pass "written whitelist has the 'cipi disk' line" || fail "written whitelist lacks 'cipi disk'"
    grep -qE '^\s*/usr/local/bin/cipi disk \*, \\$' "${TMP}/cipi-api" \
        && pass "written whitelist has the 'cipi disk *' line" || fail "written whitelist lacks 'cipi disk *'"
    if command -v visudo >/dev/null 2>&1; then
        visudo -cqf "${TMP}/cipi-api" >/dev/null 2>&1 \
            && pass "visudo accepts the whitelist" || fail "visudo rejects the whitelist"
    fi
else
    fail "could not redirect the sudoers path into the temp dir"
fi

# ── migration ────────────────────────────────────────────────
bash -n "${LIB}/migrations/5.5.2.sh" && pass "5.5.2 migration parses" || fail "5.5.2 migration does not parse"
grep -q 'write_cipi_api_sudoers' "${LIB}/migrations/5.5.2.sh" \
    && pass "migration regenerates the API sudoers" || fail "migration does not call write_cipi_api_sudoers"
grep -q 'set -euo pipefail' "${LIB}/migrations/5.5.2.sh" \
    && pass "migration runs with set -euo pipefail" || fail "migration lacks set -euo pipefail"

# ── the command the API runs ─────────────────────────────────
grep -q 'db|dbs|databases)' "${LIB}/disk.sh" && pass "cipi disk db accepted" || fail "cipi disk db missing"
grep -q -- '--json)' "${LIB}/disk.sh" && pass "cipi disk --json accepted" || fail "cipi disk --json missing"

# ── cipi.yml: deploy names, node_build, backup ownership, generate --save ──
echo "-- cipi.yml deploy.node_build / predeploy_snapshot"
bash -n "${LIB}/yml.sh" && pass "yml.sh parses" || fail "yml.sh does not parse"
bash -n "${LIB}/backup.sh" && pass "backup.sh parses" || fail "backup.sh does not parse"
bash -n "${LIB}/deploy.sh" && pass "deploy.sh parses" || fail "deploy.sh does not parse"
bash -n "${LIB}/cipi-app-deploy.sh" && pass "cipi-app-deploy.sh parses" || fail "cipi-app-deploy.sh does not parse"
grep -q '_bk_init_local' "${LIB}/backup.sh" && pass "local backup init exists" || fail "no _bk_init_local"
grep -q '_bk_profile_delete' "${LIB}/backup.sh" && pass "profile delete exists" || fail "no _bk_profile_delete"
grep -q 'backup-profile-remove' "${LIB}/yml.sh" && pass "apply removes dropped backup profiles" || fail "no backup-profile-remove"
grep -q 'cipi.yml-result:' "${LIB}/yml.sh" && pass "auto-apply prints a result line" || fail "no cipi.yml-result line"
grep -q 'cipi.yml:' "${LIB}/deploy.sh" && grep -q 'cipi.yml:' "${LIB}/cipi-app-deploy.sh" \
    && pass "deploy success mail quotes the cipi.yml result" || fail "deploy mail omits cipi.yml"

yml_ok() {
    local f="$1" app="$2"
    RED= GREEN= YELLOW= CYAN= DIM= NC= BOLD=
    # shellcheck source=/dev/null
    source "${LIB}/yml.sh"
    _yml_parse "$f" "$app"
}
printf 'version: 1\ndeploy:\n  node_build: "npm ci && npm run build"\n  predeploy_snapshot: true\n' > "${TMP}/nb.yml"
r=$(yml_ok "${TMP}/nb.yml" sportgrid)
[[ "$(jq -r .ok <<< "$r")" == true ]] && pass "node_build and predeploy_snapshot accepted" || fail "node_build rejected: $(jq -c .errors <<< "$r")"
[[ "$(jq -r '.data.deploy.node_build' <<< "$r")" == "npm ci && npm run build" ]] \
    && pass "node_build kept as a string" || fail "node_build value: $(jq -c .data.deploy <<< "$r")"
[[ "$(jq -r '.data.deploy.predeploy_snapshot' <<< "$r")" == true ]] \
    && pass "predeploy_snapshot is a boolean" || fail "predeploy_snapshot: $(jq -c .data.deploy <<< "$r")"

printf 'version: 1\ndeploy:\n  snapshot: true\n' > "${TMP}/snap.yml"
r=$(yml_ok "${TMP}/snap.yml" sportgrid)
[[ "$(jq -r '.data.deploy.predeploy_snapshot' <<< "$r")" == true ]] \
    && ! jq -e '.data.deploy | has("snapshot")' <<< "$r" >/dev/null \
    && pass "snapshot is still read, stored as predeploy_snapshot" || fail "snapshot alias: $(jq -c .data <<< "$r")"

printf 'version: 1\ndeploy:\n  snapshot: true\n  predeploy_snapshot: false\n' > "${TMP}/both.yml"
r=$(yml_ok "${TMP}/both.yml" sportgrid)
[[ "$(jq -r .ok <<< "$r")" == false ]] && grep -q 'not both' <<< "$(jq -r '.errors[]' <<< "$r")" \
    && pass "snapshot and predeploy_snapshot together are refused" || fail "both names accepted: $(jq -c .errors <<< "$r")"

printf 'version: 1\ndeploy:\n  node_build: false\n' > "${TMP}/nbf.yml"
r=$(yml_ok "${TMP}/nbf.yml" sportgrid)
[[ "$(jq -r '.data.deploy.node_build' <<< "$r")" == "" ]] \
    && pass "node_build: false clears the build" || fail "node_build false: $(jq -c .data.deploy <<< "$r")"

printf 'version: 1\ndeploy:\n  node_build: "rm -rf /"\n' > "${TMP}/badnb.yml"
r=$(yml_ok "${TMP}/badnb.yml" sportgrid)
[[ "$(jq -r .ok <<< "$r")" == false ]] && pass "a free-form node_build is refused" || fail "bad node_build accepted"

echo "-- cipi.yml backup plan: rename drops the old profile"
cat > "${TMP}/plan.sh" <<EOF
export CIPI_LIB="${LIB}" CIPI_CONFIG="${TMP}/cfg" CIPI_LOG="${TMP}/log"
mkdir -p "${TMP}/cfg" "${TMP}/log"
RED=; GREEN=; YELLOW=; CYAN=; DIM=; NC=; BOLD=
source "${LIB}/common.sh" 2>/dev/null
vault_read() {
    case "\$1" in
        apps.json) cat "${TMP}/apps.json" ;;
        backup.json) cat "${TMP}/backup.json" ;;
        *) echo '{}' ;;
    esac
}
source "${LIB}/routes.sh"
source "${LIB}/backup.sh"
source "${LIB}/yml.sh"
_yml_source_libs() { :; }
_YML_APP=sportgrid
_YML_FILE="\$1"
res=\$(_yml_parse "\$1" sportgrid)
_YML_DATA=\$(jq -c .data <<< "\$res")
_yml_build_plan
printf 'A|%s\n' "\${_YML_ACTIONS[@]}"
printf 'B|%s\n' "\${_YML_BLOCKERS[@]}"
EOF

cat > "${TMP}/apps.json" <<'EOF'
{"sportgrid":{"domain":"sportgrid.test","php":"8.4","custom":false,"runtime":"fpm",
  "backup_profiles":["sportgrid-old","sportgrid-keep"]}}
EOF
cat > "${TMP}/backup.json" <<'EOF'
{"bucket":"","profiles":{
  "default":{"scope":"all","cron":"0 2 * * *","destinations":["local"],"retention":{"keep":0,"days":28,"weeks":0},"encrypt":false,"enabled":true},
  "sportgrid-old":{"scope":"db","cron":"*/30 * * * *","destinations":["local"],"retention":{"keep":48,"days":0,"weeks":0},"encrypt":false,"enabled":true},
  "sportgrid-keep":{"scope":"db","cron":"0 3 * * *","destinations":["local"],"retention":{"keep":0,"days":14,"weeks":0},"encrypt":false,"enabled":true}
}}
EOF
mkdir -p "${TMP}/cfg"
cp "${TMP}/backup.json" "${TMP}/cfg/backup.json"
cat > "${TMP}/bk.yml" <<'EOF'
version: 1
backup:
  profiles:
    - name: sportgrid-keep
      scope: db
      cron: "0 3 * * *"
      keep_days: 14
      destinations: [local]
    - name: sportgrid-new
      scope: db
      every: 30m
      keep: 48
      destinations: [local]
EOF
out=$(bash "${TMP}/plan.sh" "${TMP}/bk.yml" 2>"${TMP}/plan.err") || true
grep -q 'backup-profile-remove|sportgrid-old|' <<< "$out" \
    && pass "renamed profile is removed" || fail "old profile stays: ${out} $(cat "${TMP}/plan.err")"
grep -q 'create backup profile sportgrid-new (local)' <<< "$out" \
    && pass "new profile is created on local" || fail "new profile not planned: ${out}"
! grep -q 'backup-profile-remove|default|' <<< "$out" \
    && ! grep -q 'backup-profile-remove|sportgrid-keep|' <<< "$out" \
    && pass "server-wide default and the profile still declared are not removed" \
    || fail "plan removed a profile it should keep: ${out}"
# sportgrid-keep exists and is declared, so it is an update, not a removal.
grep -q 'update backup profile sportgrid-keep' <<< "$out" \
    && pass "declared profile is updated, not removed" || fail "keep profile: ${out}"
! grep -q 'backup-init|' <<< "$out" \
    && pass "an already configured backup is not initialised again" || fail "backup-init on a configured server: ${out}"

# No backup.json yet, local destinations: initialise, do not block.
rm -f "${TMP}/cfg/backup.json"
printf '%s\n' '{"sportgrid":{"domain":"sportgrid.test","php":"8.4","custom":false}}' > "${TMP}/apps.json"
printf '%s\n' '{}' > "${TMP}/backup.json"
cat > "${TMP}/local.yml" <<'EOF'
version: 1
backup:
  profiles:
    - name: sportgrid-db
      scope: db
      databases: ["sportgrid"]
      every: 1d
      keep: 7
      destinations: [local]
EOF
out=$(bash "${TMP}/plan.sh" "${TMP}/local.yml" 2>"${TMP}/plan2.err") || true
grep -q 'backup-init|' <<< "$out" && ! grep -qE '^B\|[^[:space:]]' <<< "$out" \
    && pass "local profiles initialise backup instead of blocking" \
    || fail "local init: ${out} $(cat "${TMP}/plan2.err")"

# S3 with nothing configured is a blocker, not a silent local copy.
cat > "${TMP}/s3.yml" <<'EOF'
version: 1
backup:
  profiles:
    - name: sportgrid-off
      scope: all
      every: 1d
      keep_days: 14
      destinations: [s3]
EOF
out=$(bash "${TMP}/plan.sh" "${TMP}/s3.yml" 2>"${TMP}/plan3.err") || true
grep -q '^B|backup profiles target s3' <<< "$out" \
    && pass "s3 without a bucket blocks the plan" || fail "s3 not blocked: ${out}"

echo "-- cipi yml generate --save"
cat > "${TMP}/gen.sh" <<EOF
set -uo pipefail
RED=; GREEN=; YELLOW=; CYAN=; DIM=; NC=; BOLD=
export CIPI_LIB="${LIB}" CIPI_CONFIG="${TMP}/cfg" CIPI_LOG="${TMP}/log"
info(){ printf 'INFO %s\n' "\$*"; }
warn(){ echo "WARN \$*" >&2; }
error(){ echo "ERR \$*" >&2; }
success(){ printf 'OK %s\n' "\$*"; }
step(){ :; }
parse_args(){ :; }
APPS='{"sportgrid":{"domain":"sportgrid.test","php":"8.4","custom":false}}'
vault_read(){ case "\$1" in apps.json) echo "\$APPS";; *) echo '{}';; esac; }
vault_write(){ cat >/dev/null; }
app_exists(){ [[ "\$1" == sportgrid ]]; }
app_get(){ echo "\$APPS" | jq -r --arg a "\$1" --arg k "\$2" '.[\${a}][\$k] // empty'; }
hostname(){ echo vps-test; }
source "${LIB}/backup.sh"
source "${LIB}/yml.sh"
_yml_source_libs(){ :; }
_bk_configured(){ return 1; }
_deploy_cfg_bool(){ echo "\${3:-true}"; }
_deploy_cfg_keep_releases(){ echo 5; }
_yml_read_workers(){ :; }
# Real parse_args, so --save is seen. The stub above is replaced.
parse_args() {
    for arg in "\$@"; do
        case "\$arg" in
            --*=*) local k="\${arg%%=*}"; k="\${k#--}"; printf -v "ARG_\${k//-/_}" '%s' "\${arg#*=}" ;;
            --*) local k="\${arg#--}"; printf -v "ARG_\${k//-/_}" '%s' true ;;
        esac
    done
}
_yml_generate sportgrid --save="${TMP}/saved.yml"
EOF
gout=$(bash "${TMP}/gen.sh" 2>"${TMP}/gen.err") || true
[[ -f "${TMP}/saved.yml" ]] && pass "generate --save writes the path" || fail "generate --save wrote nothing: ${gout} $(cat "${TMP}/gen.err")"
grep -q '^version: 1' "${TMP}/saved.yml" && grep -q 'predeploy_snapshot:' "${TMP}/saved.yml" \
    && grep -q 'node_build:' "${TMP}/saved.yml" \
    && pass "saved file has predeploy_snapshot and node_build" || fail "saved file contents: $(head -40 "${TMP}/saved.yml" 2>/dev/null)"
! grep -q '^version: 1' <<< "$gout" && pass "generate --save does not dump the file on screen" || fail "yaml still printed"
# second write without --force must refuse
gout2=$(bash "${TMP}/gen.sh" 2>"${TMP}/gen2.err") || true
grep -q 'Refusing to overwrite' "${TMP}/gen2.err" && pass "generate --save refuses to overwrite" || fail "overwrite not refused: ${gout2} $(cat "${TMP}/gen2.err")"

echo ""
echo "Passed: ${PASS}  Failed: ${FAIL}"
[[ "$FAIL" -eq 0 ]]

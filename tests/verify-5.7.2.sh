#!/bin/bash
# Local regression checks for 5.7.2 — post-deploy runner readable by app
# users, forge errors that say why, www on a wildcard primary, `cipi use`,
# CIPI_DEPLOY_BRANCH / REDIS_* in .env, backup profile --purge, deploy
# durations, PHP ini hardening, and migration 5.7.2 with stubs.
# Run from repo root: bash tests/verify-5.7.2.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/lib"
PASS=0
FAIL=0

pass() { echo "  OK: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

echo "=== Cipi 5.7.2 regression checks ==="

[[ "$(tr -d '[:space:]' < "${ROOT}/version.md")" == "5.7.2" ]] \
    && pass "version.md is 5.7.2" || fail "version.md is not 5.7.2"
grep -q '^## \[5.7.2\]' "${ROOT}/CHANGELOG.md" \
    && pass "CHANGELOG has a 5.7.2 entry" || fail "CHANGELOG has no 5.7.2 entry"
grep -q 'lib/migrations/5.7.2.sh' "${ROOT}/CHANGELOG.md" && grep -q 'cipi use' "${ROOT}/CHANGELOG.md" \
    && pass "CHANGELOG names the migration and cipi use" || fail "CHANGELOG content"
for f in common.sh app.sh git.sh deploy.sh backup.sh yml.sh sync.sh use.sh node.sh ini.sh php.sh \
         self-update.sh completion.sh cipi-app-deploy.sh cipi-app-post-deploy.sh migrations/5.7.2.sh; do
    bash -n "${LIB}/${f}" && pass "${f} parses" || fail "${f} does not parse"
done
bash -n "${ROOT}/cipi" && pass "cipi parses" || fail "cipi does not parse"
bash -n "${ROOT}/setup.sh" && pass "setup.sh parses" || fail "setup.sh does not parse"

TMP=$(mktemp -d) || { echo "mktemp failed" >&2; exit 1; }
trap 'rm -rf "${TMP:?}"' EXIT

extract() { sed -n "/^${2}() {/,/^}/p" "${LIB}/${1}"; }
# Since 5.9.0 the functions under test hand file work inside an app's home to
# the app user (app_as: sudo -u, when root). The apps here are directories in
# a temp dir, not users: sudo is a stub that runs the command as whoever runs
# the test, and the helpers travel with the function that calls them.
APP_HELPERS="app_as app_sh app_call app_of_path _app_reown _app_dir_do _app_own_check _app_file_op app_read app_write app_append app_sed app_rm app_mkdir"
mkdir -p "${TMP}/stub"
printf '%s\n' '#!/bin/bash' \
    'while [[ "${1:-}" == -* ]]; do case "$1" in -u) shift 2 ;; --) shift; break ;; *) shift ;; esac; done' \
    'exec "$@"' > "${TMP}/stub/sudo"
if ! sed --version >/dev/null 2>&1; then   # BSD sed, in the helpers' own shells too
    printf '%s\n' '#!/bin/bash' "s='$(command -v sed)'" \
        'if [[ "${1:-}" == "-i" ]]; then shift; exec "$s" -i "" "$@"; fi' 'exec "$s" "$@"' > "${TMP}/stub/sed"
fi
chmod +x "${TMP}/stub/"*
app_helpers() {   # <the directory that stands for />
    local f
    echo "export PATH='${TMP}/stub:'\"\$PATH\""
    for f in $APP_HELPERS; do extract common.sh "$f"; done | sed "s|/home/|${1}/home/|g"
}
mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

# ── 1. PHP ini hardening ─────────────────────────────────────
echo "--- PHP ini hardening"
lines=$(bash -c "$(extract common.sh php_fpm_ini_hardening); php_fpm_ini_hardening")
[[ "$lines" == $'session.upload_progress.enabled = 0\nfatal_error_backtraces = 0' ]] \
    && pass "php_fpm_ini_hardening prints the two advisory lines" || fail "php_fpm_ini_hardening: ${lines}"
grep -q '^\$(php_fpm_ini_hardening)$' "${LIB}/php.sh" \
    && pass "cipi php install writes them to fpm/conf.d/99-cipi.ini" || fail "php.sh 99-cipi.ini lacks the hardening"
awk '/99-cipi.ini" <<INIEOF/,/^INIEOF/' "${ROOT}/setup.sh" | grep -q '^session.upload_progress.enabled = 0$' \
    && awk '/99-cipi.ini" <<INIEOF/,/^INIEOF/' "${ROOT}/setup.sh" | grep -q '^fatal_error_backtraces = 0$' \
    && pass "setup.sh writes them to fpm/conf.d/99-cipi.ini" || fail "setup.sh 99-cipi.ini lacks the hardening"
# Octane ini still carries exactly the pool keys (shared generator).
octane_keys=$(bash -c "$(extract common.sh php_fpm_ini_hardening); $(extract common.sh octane_php_ini_ensure | sed "s|/etc/php/cipi-octane.d|${TMP}/oct|g"); OCTANE_INI_DIR=${TMP}/oct; octane_php_ini_ensure; grep -E '^[a-z]' ${TMP}/oct/99-cipi-hardening.ini | cut -d' ' -f1 | sort | tr '\n' ' '")
[[ "$octane_keys" == "fatal_error_backtraces session.upload_progress.enabled " ]] \
    && pass "Octane ini written from the shared generator" || fail "Octane ini keys: ${octane_keys}"
reason=$(bash -c "$(extract ini.sh _ini_key_denied); $(extract ini.sh _ini_key_deny_reason); _ini_key_deny_reason session.upload_progress.enabled")
[[ "$reason" == *CVE-2026-109619* ]] \
    && pass "cipi ini keys lists session.upload_progress.enabled as not settable, with the reason" || fail "deny reason: ${reason}"
reason=$(bash -c "$(extract ini.sh _ini_key_denied); $(extract ini.sh _ini_key_deny_reason); _ini_key_deny_reason fatal_error_backtraces")
[[ "$reason" == *CVE-2026-109618* ]] \
    && pass "cipi ini keys lists fatal_error_backtraces as not settable" || fail "deny reason: ${reason}"

# Node webhook pool: file_uploads off.
mkdir -p "${TMP}/etc/php/8.4/fpm/pool.d"
(
    NODE_WEBHOOK_PHP=/usr/local/share/cipi/webhook.php
    eval "$(extract common.sh version_at_least)"
    eval "$(extract common.sh fpm_pool_hardening)"
    eval "$(extract node.sh _node_webhook_pool | sed "s|/etc/php|${TMP}/etc/php|g")"
    _node_webhook_pool nodeapp 8.4
)
POOL="${TMP}/etc/php/8.4/fpm/pool.d/nodeapp.conf"
grep -qx 'php_admin_flag\[file_uploads\] = off' "$POOL" 2>/dev/null \
    && grep -qx 'php_admin_flag\[session.upload_progress.enabled\] = off' "$POOL" \
    && pass "Node webhook pool: file_uploads off, upload progress off" || fail "webhook pool: $(cat "$POOL" 2>/dev/null)"

# ── 2. lib readable by app users ─────────────────────────────
echo "--- post-deploy runner"
grep -q 'chmod 644 /opt/cipi/lib/yml.sh' "${LIB}/self-update.sh" \
    && pass "self-update makes yml.sh 0644" || fail "self-update.sh: no chmod 644 yml.sh"
grep -q 'chmod 644 /opt/cipi/lib/yml.sh' "${ROOT}/setup.sh" \
    && pass "setup.sh makes yml.sh 0644" || fail "setup.sh: no chmod 644 yml.sh"

# The runner, pointed at a lib of our choosing, run as whoever runs the test.
sed -e 's/^if \[\[ "\$(id -un)" != "\$APP" && "\$(id -u)" -ne 0 \]\]; then$/if false; then/' \
    "${LIB}/cipi-app-post-deploy.sh" > "${TMP}/runner.sh"
[[ $(grep -c '^if false; then$' "${TMP}/runner.sh") -eq 1 ]] \
    && pass "runner copy prepared" || fail "could not neutralise the user check in the runner copy"
run_runner() { # $1 = lib dir; prints "rc=<n>"; stderr in ${TMP}/runner.err, log in ${TMP}/runner.log
    : > "${TMP}/runner.log"
    local rc=0
    CIPI_LIB="$1" bash "${TMP}/runner.sh" demo 8.4 "${TMP}/runner.log" 2>"${TMP}/runner.err" >/dev/null || rc=$?
    echo "rc=${rc}"
}
mkdir -p "${TMP}/lib-unreadable" "${TMP}/lib-stub" "${TMP}/lib-nofn" "${TMP}/lib-real"
printf 'f() { :; }\n' > "${TMP}/lib-unreadable/yml.sh"; chmod 000 "${TMP}/lib-unreadable/yml.sh"
if [[ "$(id -u)" -ne 0 ]]; then
    out=$(run_runner "${TMP}/lib-unreadable")
    [[ "$out" == "rc=2" ]] && grep -q 'cannot read' "${TMP}/runner.err" \
        && pass "unreadable yml.sh: exit 2 and a message that says so (not 127)" || fail "unreadable lib: ${out} $(cat "${TMP}/runner.err")"
    if (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 2) )); then
        grep -q 'post-deploy summary: runner unavailable (exit=2)' "${TMP}/runner.log" \
            && pass "unreadable yml.sh: summary line says 'runner unavailable'" || fail "log: $(cat "${TMP}/runner.log")"
    else
        echo "  SKIP: bash ${BASH_VERSION} has no printf %(…)T — summary line not checked"
    fi
else
    echo "  SKIP: running as root, an unreadable file cannot be simulated"
fi
chmod 644 "${TMP}/lib-unreadable/yml.sh"
printf '_yml_post_deploy_run() { echo "none declared"; return 0; }\n' > "${TMP}/lib-stub/yml.sh"
out=$(run_runner "${TMP}/lib-stub")
[[ "$out" == "rc=0" ]] && pass "readable lib with the runner function: exit 0" || fail "stub lib: ${out} $(cat "${TMP}/runner.err")"
printf 'other() { :; }\n' > "${TMP}/lib-nofn/yml.sh"
out=$(run_runner "${TMP}/lib-nofn")
[[ "$out" == "rc=2" ]] && grep -q 'no post-deploy runner' "${TMP}/runner.err" \
    && pass "lib without the function: exit 2, says to self-update" || fail "nofn lib: ${out} $(cat "${TMP}/runner.err")"
cp "${LIB}/yml.sh" "${TMP}/lib-real/yml.sh"
out=$(run_runner "${TMP}/lib-real")
[[ "$out" == "rc=0" ]] && pass "the real yml.sh loads as a plain user with no CIPI_* set (no cipi.yml → exit 0)" \
    || fail "real lib: ${out} $(cat "${TMP}/runner.err")"
grep -q 'POST_MARK=' "${LIB}/cipi-app-deploy.sh" && grep -q 'tail -n +"$((POST_MARK + 1))"' "${LIB}/cipi-app-deploy.sh" \
    && pass "cipi-app-deploy reads the summary of this run only" || fail "cipi-app-deploy: summary not scoped"

# ── 3. Forge errors ──────────────────────────────────────────
echo "--- forge errors"
GITFN="${TMP}/gitfn.sh"
{
    echo 'error() { echo "[ERROR] $*" >&2; }'
    for fn in _git_provider_label _git_http_code _github_access_hint _gitlab_access_hint _bitbucket_access_hint \
              _git_api_fail _git_last_message _git_repo_visible; do extract git.sh "$fn"; done
    echo '_bitbucket_ws_repo() { echo "$1"; }'
} > "$GITFN"
msg=$(bash -c "source $GITFN; _git_api_fail github 'deploy key' o/r 404 '{\"message\":\"Not Found\"}'" 2>&1)
[[ "$msg" == *"'o/r' is not visible to the saved token"* && "$msg" == *"Administration: Read and write"* && "$msg" == *"cipi git github-token"* ]] \
    && pass "GitHub 404 says the token cannot see the repository and which permissions it needs" || fail "404 message: ${msg}"
msg=$(bash -c "source $GITFN; _git_api_fail github webhook o/r 401 '{}'" 2>&1)
[[ "$msg" == *"rejected"* && "$msg" == *"github-token"* ]] && pass "GitHub 401 says the token was rejected" || fail "401 message: ${msg}"
msg=$(bash -c "source $GITFN; _git_api_fail github webhook o/r 403 '{\"message\":\"Resource not accessible by personal access token\"}'" 2>&1)
[[ "$msg" == *"Resource not accessible"* && "$msg" == *"Webhooks: Read and write"* ]] && pass "GitHub 403 carries the forge message and the hint" || fail "403 message: ${msg}"
msg=$(bash -c "source $GITFN; _git_api_fail gitlab 'deploy key' g/p 404 '{\"message\":\"404 Project Not Found\"}'" 2>&1)
[[ "$msg" == *"Maintainer"* && "$msg" == *"gitlab-token"* ]] && pass "GitLab 404 names the api scope and the Maintainer role" || fail "gitlab message: ${msg}"
msg=$(bash -c "source $GITFN; _git_api_fail bitbucket webhook w/r 404 '{}'" 2>&1)
[[ "$msg" == *"Repositories: Admin"* ]] && pass "Bitbucket 404 names the token permissions" || fail "bitbucket message: ${msg}"
msg=$(bash -c "source $GITFN; _git_api_fail github webhook o/r '' ''" 2>&1)
[[ "$msg" == *"no answer"* ]] && pass "no HTTP code: 'no answer from the API'" || fail "empty code: ${msg}"
last=$(bash -c "source $GITFN; _git_last_message \"\$(printf 'first\n\033[0;31m[ERROR]\033[0m boom here\n\n')\"")
[[ "$last" == "boom here" ]] && pass "_git_last_message strips colours and the [ERROR] prefix" || fail "last message: '${last}'"
code=$(bash -c "source $GITFN; _github_api() { printf '{}\n404\n'; }; _git_repo_visible github o/r; echo \"rc=\$? code=\$GIT_REPO_VISIBLE_CODE\"")
[[ "$code" == "rc=1 code=404" ]] && pass "_git_repo_visible: 404 → not visible" || fail "repo visible 404: ${code}"
code=$(bash -c "source $GITFN; _github_api() { printf '{}\n200\n'; }; _git_repo_visible github o/r; echo rc=\$?")
[[ "$code" == "rc=0" ]] && pass "_git_repo_visible: 200 → visible" || fail "repo visible 200: ${code}"
code=$(bash -c "source $GITFN; _git_repo_visible origin x; echo rc=\$?")
[[ "$code" == "rc=2" ]] && pass "_git_repo_visible: unknown provider → cannot tell" || fail "repo visible origin: ${code}"
refresh=$(extract git.sh git_refresh_app)
l_vis=$(grep -n '_git_repo_visible "$provider" "$repo_id"' <<< "$refresh" | head -1 | cut -d: -f1)
l_rot=$(grep -n 'deploy key already used on another repo' <<< "$refresh" | head -1 | cut -d: -f1)
[[ -n "$l_vis" && -n "$l_rot" && "$l_vis" -lt "$l_rot" ]] \
    && pass "cipi git refresh checks the repository before rotating the key" || fail "refresh rotation not guarded (vis=${l_vis} rot=${l_rot})"
grep -q 'GIT_SETUP_KEY_ERROR=\$(_git_last_message' "${LIB}/git.sh" && grep -q 'GIT_SETUP_HOOK_ERROR=\$(_git_last_message' "${LIB}/git.sh" \
    && pass "git_setup_repo keeps the forge's answer for the summary" || fail "git_setup_repo: errors not kept"
grep -q '_app_summary_git "$app_user" "$url_host" "$webhook_token" "$repository" "$deploy_key" "Token"' "${LIB}/app.sh" \
    && grep -q 'not created on ${GIT_PROVIDER}' "${LIB}/app.sh" \
    && pass "app create summary says when the webhook was not created, and why" || fail "app.sh summary"

# ── 4. www on a wildcard primary ─────────────────────────────
echo "--- www pair"
WWWFN="${TMP}/www.sh"
{ extract common.sh domain_is_wildcard; extract app.sh _www_resolve_pair; extract app.sh _www_pair_other; } > "$WWWFN"
pair() { bash -c "source $WWWFN; _www_resolve_pair '$1'; echo \"\$WWW_PAIR_APEX \$WWW_PAIR_HOST \$(_www_pair_other '$1')\""; }
[[ "$(pair '*.example.com')" == "example.com www.example.com example.com" ]] \
    && pass "*.example.com → apex example.com, www www.example.com, alias needed: the apex" || fail "wildcard pair: $(pair '*.example.com')"
[[ "$(pair 'example.com')" == "example.com www.example.com www.example.com" ]] \
    && pass "example.com → pair unchanged, alias needed: www" || fail "apex pair: $(pair 'example.com')"
[[ "$(pair 'www.example.com')" == "example.com www.example.com example.com" ]] \
    && pass "www.example.com → pair unchanged, alias needed: the apex" || fail "www pair: $(pair 'www.example.com')"
! grep -q '_www_reject_wildcard' "${LIB}"/*.sh && pass "the wildcard refusal is gone" || fail "_www_reject_wildcard still referenced"
! grep -q 'there is no www/apex pair' "${LIB}/yml.sh" && pass "cipi.yml no longer blocks app.www on a wildcard primary" || fail "yml.sh still blocks www on wildcard"
grep -q '_alias_cert_hint "$app" "$WWW_PAIR_ADDED"' "${LIB}/app.sh" \
    && pass "www force-* prints the certificate hint for a pair alias it added" || fail "no cert hint in www force"

# ── 5. deploy --releases durations ───────────────────────────
echo "--- deploy durations"
DEPFN="${TMP}/dep.sh"
# deploy.log lives in /var/log/cipi-apps/<app> since 5.9.0: here, under the temp dir like the home
{ extract deploy.sh deploy_app_home | sed "s|/home/|${TMP}/home/|"; echo "deploy_log_file() { echo \"${TMP}/home/\${1:-}/logs/deploy.log\"; }"
  extract deploy.sh _deploy_fmt_secs; extract deploy.sh _deploy_release_took; } > "$DEPFN"
mkdir -p "${TMP}/home/demo/logs"
cat > "${TMP}/home/demo/logs/deploy.log" <<'EOF'
[2026-10-24 08:50:00] ===== deploy OK  app=demo release=28 duration=9s exit=0 =====
[2026-10-24 08:55:55] ===== deploy OK  app=demo release=29 duration=40s exit=0 =====
[2026-10-24 09:10:00] ===== deploy FAILED  app=demo release=30 duration=12s exit=1 =====
[2026-10-24 09:20:00] ===== deploy OK  app=demo release=29 duration=54s exit=0 =====
EOF
[[ "$(bash -c "source $DEPFN; _deploy_release_took demo 29")" == "54s" ]] && pass "release 29 took 54s (last banner wins)" || fail "took 29: $(bash -c "source $DEPFN; _deploy_release_took demo 29")"
[[ "$(bash -c "source $DEPFN; _deploy_release_took demo 28")" == "9s" ]] && pass "release 28 took 9s" || fail "took 28"
[[ -z "$(bash -c "source $DEPFN; _deploy_release_took demo 27")" ]] && pass "unknown release: empty" || fail "took 27 not empty"
[[ -z "$(bash -c "source $DEPFN; _deploy_release_took demo 30")" ]] && pass "a failed deploy is not a duration" || fail "took 30 not empty"
[[ "$(bash -c "source $DEPFN; _deploy_fmt_secs 125")" == "2m05s" && "$(bash -c "source $DEPFN; _deploy_fmt_secs 3725")" == "1h02m" ]] \
    && pass "durations formatted (2m05s, 1h02m)" || fail "fmt secs"
grep -q '"RELEASE" "DEPLOYED" "TOOK" "COMMIT" "SUBJECT"' "${LIB}/deploy.sh" && pass "--releases has a TOOK column" || fail "no TOOK column"

# ── 6. .env: CIPI_DEPLOY_BRANCH and REDIS_* ──────────────────
echo "--- .env"
ENVFN="${TMP}/env.sh"
{
    # The helper uses GNU `sed -i` (the servers are Ubuntu); BSD sed wants -i ''.
    if ! sed --version >/dev/null 2>&1; then
        echo 'sed() { if [[ "${1:-}" == "-i" ]]; then shift; command sed -i "" "$@"; else command sed "$@"; fi; }'
    fi
    app_helpers "$TMP"
    extract common.sh app_env_set_deploy_branch | sed "s|/home/|${TMP}/home/|"
} > "$ENVFN"
mkdir -p "${TMP}/home/demo/shared"
printf 'APP_NAME=demo\nCIPI_APP_USER=demo\n' > "${TMP}/home/demo/shared/.env"
bash -c "source $ENVFN; app_env_set_deploy_branch demo main"
grep -qx 'CIPI_DEPLOY_BRANCH=main' "${TMP}/home/demo/shared/.env" && pass "missing key is appended" || fail "append: $(cat "${TMP}/home/demo/shared/.env")"
bash -c "source $ENVFN; app_env_set_deploy_branch demo release/2026 add"
grep -qx 'CIPI_DEPLOY_BRANCH=main' "${TMP}/home/demo/shared/.env" && pass "'add' leaves a key that is there" || fail "add overwrote"
bash -c "source $ENVFN; app_env_set_deploy_branch demo release/2026"
grep -qx 'CIPI_DEPLOY_BRANCH=release/2026' "${TMP}/home/demo/shared/.env" && [[ $(grep -c '^CIPI_DEPLOY_BRANCH=' "${TMP}/home/demo/shared/.env") -eq 1 ]] \
    && pass "default mode replaces it (a branch with a slash included)" || fail "replace: $(cat "${TMP}/home/demo/shared/.env")"
bash -c "source $ENVFN; app_env_set_deploy_branch nosuch main" && pass "an app without .env is left alone (status 0)" || fail "missing env: non-zero"
redis=$(bash -c "vault_read() { echo '{\"valkey_password\":\"s3cr3t\"}'; }; $(extract app.sh _app_redis_env_block); _app_redis_env_block")
[[ "$redis" == *$'\nREDIS_HOST=127.0.0.1\nREDIS_PASSWORD=s3cr3t\nREDIS_PORT=6379' ]] \
    && pass "REDIS_* block from the Valkey password in server.json" || fail "redis block: '${redis}'"
redis=$(bash -c "vault_read() { echo '{}'; }; $(extract app.sh _app_redis_env_block); _app_redis_env_block")
[[ -z "$redis" ]] && pass "no Valkey password: no REDIS_* lines" || fail "redis block without password: '${redis}'"
grep -q '^CIPI_DEPLOY_BRANCH=\${branch}$' "${LIB}/app.sh" && grep -q '^QUEUE_CONNECTION=database\${redis_env}$' "${LIB}/app.sh" \
    && pass "app create .env template carries both" || fail ".env template"
# Since 5.8.0 the branch change goes through app_branch_set (shared with cipi yml apply).
grep -q 'app_branch_set "$app" "${ARG_branch}"' "${LIB}/app.sh" \
    && sed -n '/^app_branch_set() {/,/^}/p' "${LIB}/app.sh" | grep -q 'app_env_set_deploy_branch "$app" "$branch"' \
    && pass "app edit --branch updates .env" || fail "app edit --branch"
# cipi reset valkey-password keeps the generated REDIS_PASSWORD in step.
RSFN="${TMP}/reset.sh"
{
    if ! sed --version >/dev/null 2>&1; then
        echo 'sed() { if [[ "${1:-}" == "-i" ]]; then shift; command sed -i "" "$@"; else command sed "$@"; fi; }'
    fi
    echo "CIPI_CONFIG=${TMP}/rcfg"
    echo 'vault_read() { cat "${CIPI_CONFIG}/apps.json"; }'
    app_helpers "$TMP"
    extract reset.sh _reset_valkey_env_sync | sed "s|/home/|${TMP}/home/|"
} > "$RSFN"
mkdir -p "${TMP}/rcfg" "${TMP}/home/gen/shared" "${TMP}/home/own/shared" "${TMP}/home/none/shared"
echo '{"gen":{},"own":{},"none":{}}' > "${TMP}/rcfg/apps.json"
printf 'REDIS_HOST=127.0.0.1\nREDIS_PASSWORD=oldpass123\nREDIS_PORT=6379\n' > "${TMP}/home/gen/shared/.env"
printf 'REDIS_PASSWORD=mine\n' > "${TMP}/home/own/shared/.env"
printf 'APP_NAME=none\n' > "${TMP}/home/none/shared/.env"
synced=$(bash -c "source $RSFN; _reset_valkey_env_sync oldpass123 newpass456")
[[ "$synced" == "gen" ]] && grep -qx 'REDIS_PASSWORD=newpass456' "${TMP}/home/gen/shared/.env" \
    && grep -qx 'REDIS_PASSWORD=mine' "${TMP}/home/own/shared/.env" && ! grep -q REDIS "${TMP}/home/none/shared/.env" \
    && pass "reset valkey-password: generated REDIS_PASSWORD followed, a hand-set one and an app without it left alone" \
    || fail "reset env sync: synced='${synced}' gen=$(cat "${TMP}/home/gen/shared/.env") own=$(cat "${TMP}/home/own/shared/.env")"
grep -q '_reset_valkey_env_sync "$old_pass" "$new_pass"' "${LIB}/reset.sh" && pass "cipi reset valkey-password calls it" || fail "reset.sh"
[[ $(grep -c 'app_env_set_deploy_branch "$app" "$branch"' "${LIB}/sync.sh") -eq 2 ]] && pass "sync import/update keep .env in step" || fail "sync.sh"

# ── 7. cipi use ──────────────────────────────────────────────
echo "--- cipi use"
USEFN="${TMP}/use-env.sh"
cat > "$USEFN" <<EOF
USE_DEFAULT_FILE="${TMP}/default-app"
RED=''; GREEN=''; YELLOW=''; CYAN=''; DIM=''; NC=''; BOLD=''
app_exists() { [[ "\$1" == demo || "\$1" == other ]]; }
error() { echo "[ERROR] \$*" >&2; }
warn() { echo "[WARN] \$*"; }
info() { echo "[INFO] \$*"; }
success() { echo "OK \$*"; }
log_action() { :; }
show_help() { echo "help \$*"; }
source "${LIB}/use.sh"
EOF
fill() { bash -c "source $USEFN; use_fill_args $1 2>/dev/null; printf '%s|' \"\${USE_ARGV[@]}\"; echo \"#\${USE_FILLED}\""; }
rm -f "${TMP}/default-app"
[[ "$(fill 'deploy')" == "|#" ]] && pass "no default: nothing filled in" || fail "no default: $(fill 'deploy')"
echo demo > "${TMP}/default-app"
[[ "$(fill 'deploy')" == "demo|#demo" ]] && pass "cipi deploy → deploy demo" || fail "deploy: $(fill 'deploy')"
[[ "$(fill 'deploy --rollback')" == "demo|--rollback|#demo" ]] && pass "cipi deploy --rollback → deploy demo --rollback" || fail "deploy --rollback: $(fill 'deploy --rollback')"
[[ "$(fill 'deploy other')" == "other|#" ]] && pass "a named app is kept" || fail "deploy other: $(fill 'deploy other')"
[[ "$(fill 'app logs --type=php')" == "logs|demo|--type=php|#demo" ]] && pass "cipi app logs --type=php → app logs demo --type=php" || fail "app logs: $(fill 'app logs --type=php')"
[[ "$(fill 'app logs read')" == "logs|read|demo|#demo" ]] && pass "cipi app logs read → app logs read demo" || fail "app logs read: $(fill 'app logs read')"
[[ "$(fill 'app webhook recreate --rotate-secret')" == "webhook|recreate|demo|--rotate-secret|#demo" ]] && pass "cipi app webhook recreate → … demo" || fail "webhook recreate: $(fill 'app webhook recreate --rotate-secret')"
[[ "$(fill 'worker horizon status')" == "horizon|status|demo|#demo" ]] && pass "cipi worker horizon status → … demo" || fail "horizon: $(fill 'worker horizon status')"
[[ "$(fill 'yml plan --json')" == "plan|demo|--json|#demo" ]] && pass "cipi yml plan --json → yml plan demo --json" || fail "yml plan: $(fill 'yml plan --json')"
[[ "$(fill 'ssh apps enable')" == "apps|enable|demo|#demo" ]] && pass "cipi ssh apps enable → … demo" || fail "ssh apps: $(fill 'ssh apps enable')"
[[ "$(fill 'git refresh')" == "refresh|#" ]] && pass "cipi git refresh (every app) is left alone" || fail "git refresh: $(fill 'git refresh')"
[[ "$(fill 'app delete')" == "delete|#" ]] && pass "cipi app delete never gets a default" || fail "app delete: $(fill 'app delete')"
[[ "$(fill 'app create')" == "create|#" ]] && pass "cipi app create is left alone" || fail "app create: $(fill 'app create')"
[[ "$(fill 'db create shopdb')" == "create|shopdb|#" ]] && pass "cipi db … is left alone" || fail "db: $(fill 'db create shopdb')"
[[ "$(fill 'deploy --help')" == "--help|#" ]] && pass "--help is never an app slot" || fail "deploy --help: $(fill 'deploy --help')"
out=$(bash -c "source $USEFN; SUDO_USER=www-data use_fill_args deploy 2>/dev/null; echo \"\${USE_ARGV[*]:-}#\${USE_FILLED}\"")
[[ "$out" == "#" ]] && pass "the panel API (www-data) never gets a default" || fail "www-data: ${out}"
out=$(bash -c "source $USEFN; CIPI_APP=other use_fill_args deploy 2>/dev/null; echo \"\${USE_ARGV[*]}#\${USE_FILLED}\"")
[[ "$out" == "other#other" ]] && pass "CIPI_APP wins over the file" || fail "CIPI_APP: ${out}"
echo 'Not-An-App!' > "${TMP}/default-app"
[[ "$(fill 'deploy')" == "|#" ]] && pass "a file that is not an app name is ignored" || fail "bad file: $(fill 'deploy')"
hint=$(bash -c "source $USEFN; echo demo > ${TMP}/default-app; use_fill_args deploy 2>&1 >/dev/null")
[[ "$hint" == *"demo (default app — cipi use)"* ]] && pass "the filled-in app is announced on stderr" || fail "hint: ${hint}"
rm -f "${TMP}/default-app"
bash -c "source $USEFN; _use_set demo" >/dev/null && [[ "$(cat "${TMP}/default-app")" == "demo" && "$(mode "${TMP}/default-app")" == "600" ]] \
    && pass "cipi use demo writes the file (0600)" || fail "use set: $(cat "${TMP}/default-app" 2>/dev/null) mode $(mode "${TMP}/default-app" 2>/dev/null)"
bash -c "source $USEFN; _use_set nosuch" 2>/dev/null && fail "cipi use nosuch accepted" || pass "cipi use <unknown app> is refused"
[[ "$(bash -c "source $USEFN; _use_show")" == *"Default app: demo"* ]] && pass "cipi use shows the default" || fail "use show"
bash -c "source $USEFN; _use_clear" >/dev/null && [[ ! -e "${TMP}/default-app" ]] && pass "cipi use --clear removes it" || fail "use clear"
grep -q 'use)        _maybe_cmd_help use' "${ROOT}/cipi" && grep -q 'use_fill_args "$cmd" "$@"' "${ROOT}/cipi" \
    && pass "cipi dispatches 'use' and fills the default in" || fail "cipi dispatcher"
grep -q '^        use)$' "${LIB}/completion.sh" && grep -q 'service app use node' "${LIB}/completion.sh" \
    && pass "tab-completion knows cipi use" || fail "completion"
grep -q '^        use|default)$' "${ROOT}/cipi" && pass "cipi help use exists" || fail "help topic"

# ── 8. backup profile remove --purge ─────────────────────────
echo "--- backup profile remove"
BKFN="${TMP}/bk.sh"
{
    cat <<EOF
RED=''; GREEN=''; YELLOW=''; CYAN=''; DIM=''; NC=''; BOLD=''
error() { echo "[ERROR] \$*" >&2; }; warn() { echo "[WARN] \$*"; }; info() { echo "[INFO] \$*"; }
success() { echo "OK \$*"; }; step() { echo "-> \$*"; }; log_action() { :; }
_bk_require_config() { :; }
_bk_profile_exists() { [[ -f "${TMP}/bk/profiles/\$1" ]]; }
_bk_list_runs() { cat "${TMP}/bk/runs/\$1" 2>/dev/null; }
_bk_delete_run() { echo "delete \$1/\$2" >> "${TMP}/bk/log"; }
_bk_profile_delete() { rm -f "${TMP}/bk/profiles/\$1"; echo "profile-deleted \$1" >> "${TMP}/bk/log"; }
_bk_orphan_note() { echo "archives kept, pruned after 30 days"; }
_bk_local_root() { echo "${TMP}/bk/local"; }
_BK_PRUNE_ERRORS=""
EOF
    extract common.sh parse_args
    extract backup.sh _bk_valid_profile_name
    extract backup.sh _bk_profile_remove
} > "$BKFN"
bk_setup() {
    rm -rf "${TMP:?}/bk"; mkdir -p "${TMP}/bk/profiles" "${TMP}/bk/runs" "${TMP}/bk/local/nightly"
    : > "${TMP}/bk/profiles/nightly"
    printf '2026-10-20_030000\n2026-10-21_030000\n' > "${TMP}/bk/runs/nightly"
    printf '2026-09-01_030000\n' > "${TMP}/bk/runs/oldone"
    : > "${TMP}/bk/log"
}
bk_setup
out=$(bash -c "source $BKFN; _bk_profile_remove nightly" </dev/null 2>&1)
[[ ! -e "${TMP}/bk/profiles/nightly" ]] && ! grep -q '^delete' "${TMP}/bk/log" && [[ "$out" == *"2 archive run(s) kept"* && "$out" == *"--purge"* ]] \
    && pass "remove without --purge: profile gone, archives kept, how to delete them said" || fail "remove: ${out} / $(cat "${TMP}/bk/log")"
bk_setup
out=$(bash -c "source $BKFN; _bk_profile_remove nightly --purge" </dev/null 2>&1)
[[ ! -e "${TMP}/bk/profiles/nightly" && $(grep -c '^delete nightly/' "${TMP}/bk/log") -eq 2 && ! -d "${TMP}/bk/local/nightly" ]] && [[ "$out" == *"Archives of 'nightly' deleted (2 run(s))"* ]] \
    && pass "remove --purge: profile gone and both runs deleted on every destination" || fail "purge: ${out} / $(cat "${TMP}/bk/log")"
bk_setup
bash -c "source $BKFN; _bk_profile_remove nosuch" </dev/null >/dev/null 2>&1 && fail "unknown profile accepted" || pass "unknown profile without --purge is refused"
out=$(bash -c "source $BKFN; _bk_profile_remove oldone --purge" </dev/null 2>&1)
[[ $(grep -c '^delete oldone/' "${TMP}/bk/log") -eq 1 ]] && [[ "$out" == *"left behind"* ]] \
    && pass "--purge on a profile already gone clears what it left behind" || fail "purge gone: ${out} / $(cat "${TMP}/bk/log")"
bash -c "source $BKFN; _bk_profile_remove 'Bad Name'" </dev/null >/dev/null 2>&1 && fail "bad profile name accepted" || pass "an invalid profile name is refused"
grep -q 'remove \[--purge\]' "${LIB}/backup.sh" && pass "usage line names --purge" || fail "usage"

# ── 9. migration 5.7.2, end to end with stubs ────────────────
echo "--- migration 5.7.2"
M="${TMP}/m"
mkdir -p "${M}/lib" "${M}/bin" "${M}/cfg"
{
    extract common.sh php_fpm_ini_hardening
    extract common.sh fpm_pool_hardening
    extract common.sh version_at_least
    app_helpers "$M"
    extract common.sh app_env_set_deploy_branch | sed "s|/home/|${M}/home/|"
    cat <<EOF
php_is_installed() { [[ -d "${M}/etc/php/\$1" ]]; }
vault_read() { cat "\${CIPI_CONFIG}/apps.json"; }
app_get() { vault_read apps.json | jq -r --arg a "\$1" --arg k "\$2" '.[\$a][\$k] // empty'; }
systemd_unit_exists() { return 0; }
id() { return 0; }
EOF
} > "${M}/lib/common.sh"
{
    echo "NODE_WEBHOOK_PHP=/usr/local/share/cipi/webhook.php"
    extract node.sh _node_webhook_pool | sed "s|/etc/php|${M}/etc/php|g"
} > "${M}/lib/node.sh"
sed -e "s|/etc/php|${M}/etc/php|g" -e "s|/home/|${M}/home/|g" -e "s|/var/lib/cipi|${M}/var/lib/cipi|g" \
    "${LIB}/migrations/5.7.2.sh" > "${M}/migration.sh"
printf '#!/bin/bash\n[[ -f "%s/fpm-fail" ]] && exit 1\nexit 0\n' "$M" > "${M}/bin/php-fpm8.4"
printf '#!/bin/bash\necho "$*" >> "%s/systemctl.log"\n' "$M" > "${M}/bin/systemctl"
chmod +x "${M}/bin/php-fpm8.4" "${M}/bin/systemctl"
old_pool='[nodeapp]
user = nodeapp
pm = ondemand
php_admin_value[post_max_size] = 2M'
m_setup() {
    rm -rf "${M:?}/etc" "${M:?}/home" "${M:?}/var" "${M:?}/fpm-fail" "${M:?}/systemctl.log"
    mkdir -p "${M}/etc/php/8.4/fpm/conf.d" "${M}/etc/php/8.4/fpm/pool.d" \
             "${M}/home/lara/shared" "${M}/home/haskey/shared" "${M}/home/cust/shared" "${M}/home/nodeapp/shared"
    printf 'memory_limit = 256M\nexpose_php = Off\n' > "${M}/etc/php/8.4/fpm/conf.d/99-cipi.ini"
    printf '%s\n' "$old_pool" > "${M}/etc/php/8.4/fpm/pool.d/nodeapp.conf"
    cat > "${M}/cfg/apps.json" <<'EOF'
{"lara":{"php":"8.4","branch":"main"},
 "haskey":{"php":"8.4","branch":"develop"},
 "cust":{"php":"8.4","custom":"true"},
 "nodeapp":{"php":"8.4","runtime":"node","branch":"main"}}
EOF
    printf 'APP_NAME=lara\n' > "${M}/home/lara/shared/.env"
    printf 'APP_NAME=haskey\nCIPI_DEPLOY_BRANCH=mine\n' > "${M}/home/haskey/shared/.env"
    printf 'X=1\n' > "${M}/home/cust/shared/.env"
    printf 'X=1\n' > "${M}/home/nodeapp/shared/.env"
    printf 'yml_command() { :; }\n' > "${M}/lib/yml.sh"; chmod 700 "${M}/lib/yml.sh"
}
run_migration() {
    CIPI_LIB="${M}/lib" CIPI_CONFIG="${M}/cfg" PATH="${M}/bin:${PATH}" bash "${M}/migration.sh" > "${M}/mig.out" 2>&1
}
m_setup
if run_migration; then pass "migration exits 0"; else fail "migration failed: $(cat "${M}/mig.out")"; fi
INI="${M}/etc/php/8.4/fpm/conf.d/99-cipi.ini"
[[ $(grep -c '^session.upload_progress.enabled = 0$' "$INI") -eq 1 && $(grep -c '^fatal_error_backtraces = 0$' "$INI") -eq 1 && $(grep -c '^memory_limit = 256M$' "$INI") -eq 1 ]] \
    && pass "fpm/conf.d/99-cipi.ini: hardening lines appended, the rest kept" || fail "ini: $(cat "$INI")"
grep -qx 'php_admin_flag\[file_uploads\] = off' "${M}/etc/php/8.4/fpm/pool.d/nodeapp.conf" \
    && pass "Node webhook pool rewritten with file_uploads off" || fail "pool: $(cat "${M}/etc/php/8.4/fpm/pool.d/nodeapp.conf")"
[[ -f "${M}/var/lib/cipi/fpm-pool-backup-5.7.2/8.4/nodeapp.conf" ]] && pass "previous webhook pool backed up" || fail "no pool backup"
grep -qx 'CIPI_DEPLOY_BRANCH=main' "${M}/home/lara/shared/.env" && pass "Laravel app: CIPI_DEPLOY_BRANCH=main added" || fail "lara env: $(cat "${M}/home/lara/shared/.env")"
grep -qx 'CIPI_DEPLOY_BRANCH=mine' "${M}/home/haskey/shared/.env" && [[ $(grep -c CIPI_DEPLOY_BRANCH "${M}/home/haskey/shared/.env") -eq 1 ]] \
    && pass "a value already there is left alone" || fail "haskey env: $(cat "${M}/home/haskey/shared/.env")"
! grep -q CIPI_DEPLOY_BRANCH "${M}/home/cust/shared/.env" && ! grep -q CIPI_DEPLOY_BRANCH "${M}/home/nodeapp/shared/.env" \
    && pass "custom and Node apps untouched" || fail "cust/node env touched"
[[ "$(mode "${M}/lib/yml.sh")" == "644" ]] && pass "yml.sh now 0644" || fail "yml.sh mode $(mode "${M}/lib/yml.sh")"
grep -qx 'restart php8.4-fpm' "${M}/systemctl.log" && pass "php8.4-fpm restarted once" || fail "systemctl: $(cat "${M}/systemctl.log" 2>/dev/null)"
grep -q 'CIPI_DEPLOY_BRANCH added' "${M}/mig.out" && grep -q 'webhook pool rewritten' "${M}/mig.out" && pass "migration says what it did" || fail "output: $(cat "${M}/mig.out")"
# second run: nothing to do
rm -f "${M}/systemctl.log"; cp "$INI" "${M}/ini.after1"
run_migration && cmp -s "$INI" "${M}/ini.after1" && [[ ! -e "${M}/systemctl.log" ]] && grep -q 'already hardened' "${M}/mig.out" \
    && pass "second run: ini unchanged, nothing restarted" || fail "second run: $(cat "${M}/mig.out") $(cat "${M}/systemctl.log" 2>/dev/null)"
# refused php-fpm -t: old pool back, no restart
m_setup; touch "${M}/fpm-fail"
run_migration && [[ "$(cat "${M}/etc/php/8.4/fpm/pool.d/nodeapp.conf")" == "$old_pool" ]] && [[ ! -e "${M}/systemctl.log" ]] \
    && grep -q 'restoring the previous webhook pools' "${M}/mig.out" \
    && pass "refused php-fpm -t: previous webhook pool restored, FPM not restarted" || fail "rollback: $(cat "${M}/mig.out")"
# no PHP, no apps: still exits 0
rm -rf "${M:?}/etc"; echo '{}' > "${M}/cfg/apps.json"
run_migration && pass "server without PHP or apps: exits 0" || fail "empty server: $(cat "${M}/mig.out")"

echo
echo "=== ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]

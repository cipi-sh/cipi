#!/bin/bash
# Local regression checks for 5.8.0 — the environment label (cipi app create
# --env), the per-environment cipi-<env>.yml lookup, deploy.branch in
# cipi.yml, the wider nginx deny and migration 5.8.0 with stubs.
# Run from repo root: bash tests/verify-5.8.0.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/lib"
PASS=0
FAIL=0

pass() { echo "  OK: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

echo "=== Cipi 5.8.0 regression checks ==="

[[ "$(tr -d '[:space:]' < "${ROOT}/version.md")" == "5.8.0" ]] \
    && pass "version.md is 5.8.0" || fail "version.md is not 5.8.0"
grep -q '^## \[5.8.0\]' "${ROOT}/CHANGELOG.md" \
    && pass "CHANGELOG has a 5.8.0 entry" || fail "CHANGELOG has no 5.8.0 entry"
grep -q 'cipi app create --env' "${ROOT}/CHANGELOG.md" && grep -q 'deploy.branch' "${ROOT}/CHANGELOG.md" \
    && grep -q 'cipi-<env>.yml' "${ROOT}/CHANGELOG.md" \
    && pass "CHANGELOG names --env, cipi-<env>.yml and deploy.branch" || fail "CHANGELOG content"
for f in common.sh app.sh yml.sh sync.sh cipi-app-post-deploy.sh migrations/5.8.0.sh; do
    bash -n "${LIB}/${f}" && pass "${f} parses" || fail "${f} does not parse"
done
bash -n "${ROOT}/cipi" && pass "cipi parses" || fail "cipi does not parse"

TMP=$(mktemp -d) || { echo "mktemp failed" >&2; exit 1; }
trap 'rm -rf "${TMP:?}"' EXIT

extract() { sed -n "/^${2}() {/,/^}/p" "${LIB}/${1}"; }
# GNU `sed -i` is what the shipped code uses; on macOS the test shims it.
SED_SHIM='sed() { if [[ "${1:-}" == "-i" ]]; then shift; command sed -i "" "$@"; else command sed "$@"; fi; }'
[[ "$(uname)" == "Darwin" ]] || SED_SHIM=''
# Since 5.8.6 the functions under test hand file work inside an app's home to
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

# ── 1. the validator: deploy.branch ──────────────────────────
echo "--- cipi.yml validator: deploy.branch"
awk "/<<'CIPIYAMLPY'/{f=1;next} /^CIPIYAMLPY\$/{exit} f" "${LIB}/yml.sh" > "${TMP}/validator.py"
python3 -m py_compile "${TMP}/validator.py" 2>/dev/null && pass "validator compiles" || fail "validator does not compile"

yml_check() { # $1=yaml body, $2=jq filter, $3=expected, $4=label
    printf '%s\n' "$1" > "${TMP}/t.yml"
    local got; got=$(python3 "${TMP}/validator.py" "${TMP}/t.yml" myapp | jq -r "$2" 2>/dev/null)
    [[ "$got" == "$3" ]] && pass "$4" || fail "$4 (got: ${got})"
}
yml_check $'version: 1\ndeploy:\n  branch: develop' '.ok, .data.deploy.branch' $'true\ndevelop' "branch develop is accepted"
yml_check $'version: 1\ndeploy:\n  branch: "release/2026.1_rc"' '.data.deploy.branch' 'release/2026.1_rc' "slashes, dots and underscores pass"
yml_check $'version: 1\ndeploy:\n  branch: "a..b"' '.ok' 'false' "'..' is refused"
yml_check $'version: 1\ndeploy:\n  branch: "-x"' '.ok' 'false' "a leading '-' is refused"
yml_check $'version: 1\ndeploy:\n  branch: "has space"' '.errors[0]' "deploy.branch: a git branch name: letters, digits, '.', '_', '/' and '-' (max 191 chars), never '..'" "the error names deploy.branch and the rule"
yml_check $'version: 1\ndeploy:\n  branch: 2026' '.data.deploy.branch' '2026' "a bare number is the branch named so (git allows it)"
yml_check $'version: 1\ndeploy:\n  keep_releases: 3' '.ok, (.data.deploy | has("branch"))' $'true\nfalse' "deploy without branch: nothing declared"
yml_check $'version: 1\ndeploy:\n  brnch: main' '.ok' 'false' "unknown deploy keys are still refused"
grep -q 'BRANCH_RE = re.compile(r"\^\[A-Za-z0-9\]\[A-Za-z0-9._/-\]{0,190}\$")' "${LIB}/yml.sh" \
    && pass "BRANCH_RE mirrors validate_git_branch" || fail "BRANCH_RE differs from validate_git_branch"

# ── 2. the lookup: cipi-<env>.yml before cipi.yml ────────────
echo "--- lookup order"
LOOKUP="${TMP}/lookup.sh"
{
    extract yml.sh _yml_env_label | sed "s|/home/|${TMP}/home/|g"
    extract yml.sh _yml_names_for_env
    extract yml.sh _yml_default_name
    extract yml.sh _yml_candidates | sed "s|/home/|${TMP}/home/|g"
    extract yml.sh _yml_find_file
} > "$LOOKUP"
if grep -q '"/home/' "$LOOKUP"; then
    fail "lookup copy still names /home — not run"
else
    mkdir -p "${TMP}/home/shop/shared" "${TMP}/home/shop/current"
    printf 'APP_ENV=staging\nCIPI_ENV="staging"\n' > "${TMP}/home/shop/shared/.env"
    run_lookup() { bash -c "id() { echo ${1}; }; source '$LOOKUP'; ${2}"; }

    [[ "$(run_lookup 1000 '_yml_env_label shop')" == "staging" ]] \
        && pass "app user: the label comes from CIPI_ENV in shared/.env (quotes stripped)" || fail "app user label"
    [[ "$(run_lookup 1000 '_yml_env_label nosuch')" == "production" ]] \
        && pass "app user without .env: production" || fail "app user no env"
    [[ "$(run_lookup 0 'app_get() { echo qa-2; }; _yml_env_label shop')" == "qa-2" ]] \
        && pass "root: the label comes from apps.json" || fail "root label"
    [[ "$(run_lookup 0 'app_get() { echo; }; _yml_env_label shop')" == "production" ]] \
        && pass "root, app without the key: production" || fail "root no key"
    [[ "$(run_lookup 0 'app_get() { echo "../x"; }; _yml_env_label shop')" == "production" ]] \
        && pass "a label that is not a plain word is never used as a path" || fail "bad label used"
    [[ "$(run_lookup 0 '_yml_env_label shop')" == "staging" ]] \
        && pass "root without app_get (post-deploy runner): falls back on .env" || fail "root fallback"
    [[ "$(run_lookup 1000 '_yml_names_for_env staging' | paste -sd, -)" == "cipi-staging.yml,cipi-staging.yaml,cipi.yml,cipi.yaml" ]] \
        && pass "names: the environment's file first, then the plain one" || fail "names order"
    [[ "$(run_lookup 1000 '_yml_default_name production; _yml_default_name staging' | paste -sd, -)" == "cipi.yml,cipi-staging.yml" ]] \
        && pass "the name to commit: cipi.yml for production, cipi-<env>.yml otherwise" || fail "default name"
    cands=$(run_lookup 1000 '_yml_candidates shop' | sed "s|${TMP}||" | paste -sd, -)
    [[ "$cands" == "/home/shop/current/cipi-staging.yml,/home/shop/current/cipi-staging.yaml,/home/shop/current/cipi.yml,/home/shop/current/cipi.yaml,/home/shop/htdocs/cipi-staging.yml,/home/shop/htdocs/cipi-staging.yaml,/home/shop/htdocs/cipi.yml,/home/shop/htdocs/cipi.yaml,/home/shop/shared/cipi-staging.yml,/home/shop/shared/cipi-staging.yaml,/home/shop/shared/cipi.yml,/home/shop/shared/cipi.yaml" ]] \
        && pass "candidates: current, htdocs, shared — env file first in each" || fail "candidates: ${cands}"
    : > "${TMP}/home/shop/current/cipi.yml"
    [[ "$(run_lookup 1000 '_yml_find_file shop')" == "${TMP}/home/shop/current/cipi.yml" ]] \
        && pass "only cipi.yml present: it is used (fallback)" || fail "fallback"
    : > "${TMP}/home/shop/current/cipi-staging.yml"
    [[ "$(run_lookup 1000 '_yml_find_file shop')" == "${TMP}/home/shop/current/cipi-staging.yml" ]] \
        && pass "cipi-staging.yml present: it wins over cipi.yml" || fail "env file wins"
    [[ "$(run_lookup 0 'app_get() { echo production; }; _yml_find_file shop')" == "${TMP}/home/shop/current/cipi.yml" ]] \
        && pass "a production app ignores cipi-staging.yml" || fail "production ignores staging"
    run_lookup 1000 'rm -f "${TMP:?}/home/shop/current/"cipi*; _yml_find_file shop' >/dev/null \
        && fail "no file: find_file should fail" || pass "no file at all: not found"
fi

# ── 3. common.sh: the label and .env ─────────────────────────
echo "--- common.sh: validate_env_label, app_env_label, app_env_set_environment"
ENVFN="${TMP}/envfn.sh"
{
    [[ -n "$SED_SHIM" ]] && echo "$SED_SHIM"
    extract common.sh validate_env_label
    extract common.sh app_env_label
    app_helpers "$TMP"
    extract common.sh app_env_set_environment | sed "s|/home/|${TMP}/home/|"
} > "$ENVFN"
if grep -q '"/home/' "$ENVFN"; then
    fail "env helper copy still names /home — not run"
else
    for l in production staging qa-2 a_b x; do
        bash -c "source '$ENVFN'; validate_env_label '$l'" && pass "label '${l}' accepted" || fail "label '${l}' refused"
    done
    for l in Staging 'st aging' -x '' ../x abcdefghijklmnopqrstuvwxyz0123456; do
        bash -c "source '$ENVFN'; validate_env_label '$l'" && fail "label '${l}' accepted" || pass "label '${l}' refused"
    done
    [[ "$(bash -c "source '$ENVFN'; app_get() { echo; }; app_env_label demo")" == "production" ]] \
        && pass "app_env_label: no key is production" || fail "app_env_label default"
    [[ "$(bash -c "source '$ENVFN'; app_get() { echo staging; }; app_env_label demo")" == "staging" ]] \
        && pass "app_env_label: the key" || fail "app_env_label key"

    mkdir -p "${TMP}/home/demo/shared"
    printf 'APP_NAME=x\nAPP_ENV=production\nCIPI_DEPLOY_BRANCH=main\n' > "${TMP}/home/demo/shared/.env"
    bash -c "source '$ENVFN'; app_env_set_environment demo staging add"
    [[ "$(grep -c '^CIPI_ENV=staging$' "${TMP}/home/demo/shared/.env")" == "1" && "$(grep '^APP_ENV=' "${TMP}/home/demo/shared/.env")" == "APP_ENV=production" ]] \
        && pass "add: CIPI_ENV appended, APP_ENV left alone (migration)" || fail "add mode: $(cat "${TMP}/home/demo/shared/.env")"
    bash -c "source '$ENVFN'; app_env_set_environment demo qa add"
    grep -q '^CIPI_ENV=staging$' "${TMP}/home/demo/shared/.env" \
        && pass "add: a CIPI_ENV already there is kept" || fail "add overwrote"
    bash -c "source '$ENVFN'; app_env_set_environment demo qa"
    [[ "$(grep '^CIPI_ENV=' "${TMP}/home/demo/shared/.env")" == "CIPI_ENV=qa" && "$(grep '^APP_ENV=' "${TMP}/home/demo/shared/.env")" == "APP_ENV=qa" ]] \
        && pass "set: CIPI_ENV and APP_ENV both follow (cipi app edit --env)" || fail "set mode: $(cat "${TMP}/home/demo/shared/.env")"
    [[ "$(grep -c '^CIPI_ENV=' "${TMP}/home/demo/shared/.env")" == "1" ]] \
        && pass "set: one CIPI_ENV line" || fail "duplicate CIPI_ENV"
    printf 'NODE_ENV=production\n' > "${TMP}/home/demo/shared/.env"
    bash -c "source '$ENVFN'; app_env_set_environment demo staging"
    [[ "$(cat "${TMP}/home/demo/shared/.env" | paste -sd, -)" == "NODE_ENV=production,CIPI_ENV=staging" ]] \
        && pass "Node app: CIPI_ENV added, NODE_ENV untouched" || fail "node env: $(cat "${TMP}/home/demo/shared/.env")"
    bash -c "source '$ENVFN'; app_env_set_environment demo 'Bad Label'" && fail "a bad label was written" || pass "a bad label is refused (status 1)"
    bash -c "source '$ENVFN'; app_env_set_environment nosuch staging" && pass "an app without .env is left alone (status 0)" || fail "missing env: non-zero"
fi
grep -q 'env: (.env // "production")' "${LIB}/common.sh" \
    && pass "apps-public.json carries env, production by default (API, GUI, CLI)" || fail "apps-public projection lacks env"

# ── 4. app.sh: create, edit, clone, show, nginx ──────────────
echo "--- app.sh"
grep -q 'local env_label="${ARG_env:-production}"' "${LIB}/app.sh" \
    && pass "cipi app create --env, default production" || fail "create --env default"
grep -q 'validate_env_label "$env_label" || { error "Invalid --env' "${LIB}/app.sh" \
    && pass "create validates the label" || fail "create validation"
[[ "$(grep -c -- '== "true" \]\] && { error "--env needs a value: --env=staging"; exit 1; }' "${LIB}/app.sh")" == "3" ]] \
    && pass "a bare --env (create, edit, clone) is refused instead of becoming the label 'true'" || fail "bare --env guard"
grep -q 'read_input "Environment (production, staging, …)" "$env_label" env_label' "${LIB}/app.sh" \
    && grep -q 'if \[\[ -z "${ARG_env:-}" && -t 0 \]\]; then' "${LIB}/app.sh" \
    && pass "the wizard asks the environment on a terminal only" || fail "wizard prompt"
grep -q '^APP_ENV=${env_label}$' "${LIB}/app.sh" && ! grep -q '^APP_ENV=production$' "${LIB}/app.sh" \
    && pass "Laravel .env: APP_ENV is the label" || fail "APP_ENV template"
[[ "$(grep -c '^CIPI_ENV=${env_label}$' "${LIB}/app.sh")" == "2" ]] \
    && pass "Laravel and Node .env carry CIPI_ENV" || fail "CIPI_ENV templates"
[[ "$(grep -c '"env": "${env_label}",' "${LIB}/app.sh")" == "3" ]] && grep -q 'branch: $branch, env: $env, php: $php,' "${LIB}/app.sh" \
    && pass "apps.json records (custom, Octane, FPM, Node) carry env" || fail "apps.json env"
grep -q '"Environment" "$(app_env_label "$app")"' "${LIB}/app.sh" \
    && pass "cipi app show prints Environment" || fail "app show"
grep -q 'echo -e "  Env:        ${CYAN}${env_label}${NC}"$' "${LIB}/app.sh" \
    && pass "the create summary prints the environment alone on its line (the API parses it)" || fail "create summary"
grep -q '^app_branch_set() {' "${LIB}/app.sh" \
    && grep -q 'app_branch_set "$app" "${ARG_branch}"' "${LIB}/app.sh" \
    && pass "cipi app edit --branch goes through app_branch_set" || fail "app_branch_set"
bs=$(extract app.sh app_branch_set)
grep -q "set('branch', '\${safe_branch}')" <<< "$bs" && grep -q 'app_env_set_deploy_branch "$app" "$branch"' <<< "$bs" \
    && grep -q '_node_webhook_config "$app"' <<< "$bs" \
    && pass "app_branch_set: apps.json, deploy.php, CIPI_DEPLOY_BRANCH or the Node webhook config" || fail "app_branch_set body"
grep -q 'app_set "$app" env "${ARG_env}"' "${LIB}/app.sh" && grep -q 'app_env_set_environment "$app" "${ARG_env}"' "${LIB}/app.sh" \
    && grep -q 'success "Env → ${ARG_env}"' "${LIB}/app.sh" \
    && pass "cipi app edit --env: apps.json, .env, and 'Env → <label>' (what the API parses as changes.env)" || fail "edit --env"
grep -q '\[--branch=B\] \[--env=LABEL\]' "${LIB}/app.sh" && grep -q -- '--branch, --env, --repository' "${LIB}/app.sh" \
    && pass "edit usage names --env" || fail "edit usage"
grep -q 'env_label="${ARG_env:-$(app_env_label "$src")}"' "${LIB}/app.sh" \
    && grep -q -- '--branch="$branch" --env="$env_label" --php="$php_ver"' "${LIB}/app.sh" \
    && pass "cipi app clone --env, default the source's label" || fail "clone --env"
grep -q 'APP_KEY|APP_ENV|APP_URL|DB_\*|DATABASE_URL|CIPI_\*' "${LIB}/app.sh" \
    && pass "clone does not copy the source's APP_ENV" || fail "clone APP_ENV"
grep -q '\[--name=\] \[--branch=\] \[--env=\] \[--with-db|--no-db\]' "${LIB}/app.sh" \
    && pass "clone usage names --env" || fail "clone usage"

deny=$(bash -c "$(extract app.sh _nginx_cipi_yml_deny_block); _nginx_cipi_yml_deny_block")
[[ "$deny" == '    location ~* /cipi(-[a-z0-9_-]+)?\.ya?ml$ { deny all; }' ]] \
    && pass "nginx deny block covers cipi-<env>.yml" || fail "deny block: ${deny}"
deny_re='/cipi(-[a-z0-9_-]+)?\.ya?ml$'
for p in /cipi.yml /cipi.yaml /cipi-staging.yml /sub/Cipi-QA_2.YAML /cipi-production.yaml; do
    grep -Eiq "$deny_re" <<< "$p" && pass "denied: ${p}" || fail "not denied: ${p}"
done
for p in /cipi-.yml /mycipi.yml /cipi.yml.bak /cipi-staging.yml/x; do
    grep -Eiq "$deny_re" <<< "$p" && fail "denied by mistake: ${p}" || pass "still served: ${p}"
done

# ── 5. yml.sh: plan, apply, status, generate, example, node-sync ──
echo "--- yml.sh"
grep -q '_YML_ACTIONS+=("deploy-branch|${br_want}|deploy branch: ${br_cur:-none} → ${br_want} (from the next deploy)")' "${LIB}/yml.sh" \
    && pass "plan: deploy branch action" || fail "plan action"
grep -q "deploy.branch is declared, but '\${app}' has no git repository" "${LIB}/yml.sh" \
    && pass "plan: blocked for an app without a repository" || fail "plan blocker"
ap=$(sed -n '/^        deploy-branch)/,/^            ;;/p' "${LIB}/yml.sh")
grep -q 'validate_git_branch "$nb_branch"' <<< "$ap" && grep -q 'app_branch_set "$app" "$nb_branch"' <<< "$ap" \
    && grep -q 'log_action "BRANCH UPDATED (cipi.yml)' <<< "$ap" \
    && pass "apply: deploy-branch validates again and goes through app_branch_set" || fail "apply deploy-branch: ${ap}"
grep -q "'{app: \$app, env: \$env, file:" "${LIB}/yml.sh" \
    && pass "cipi yml plan --json carries env" || fail "plan json env"
grep -q "'{app: \$app, env: \$env, auto: \$auto, sudoers: \$rule, file:" "${LIB}/yml.sh" \
    && pass "cipi yml auto --json carries env" || fail "auto json env"
grep -q '"Environment" "$yenv" "— reads cipi-${yenv}.yml first, then cipi.yml' "${LIB}/yml.sh" \
    && pass "cipi yml auto status prints the environment" || fail "auto status"
grep -q 'done < <(_yml_names_for_env "$(_yml_env_label "$app")")' "${LIB}/yml.sh" \
    && ! grep -q 'for c in "${release}/cipi.yml" "${release}/cipi.yaml"' "${LIB}/yml.sh" \
    && pass "node-sync reads the release's cipi-<env>.yml first" || fail "node-sync lookup"
grep -q 'echo "  branch: $(_yml_q "$gen_branch")   # the git branch this app deploys' "${LIB}/yml.sh" \
    && grep -q 'echo "  branch: $(_yml_q "$gen_branch")"$' "${LIB}/yml.sh" \
    && pass "generate emits deploy.branch (recipe apps and custom apps with a repository)" || fail "generate branch"
grep -q 'dest="/home/${app}/$(_yml_default_name "$(_yml_env_label "$app")")"' "${LIB}/yml.sh" \
    && pass "generate --save writes cipi-<env>.yml for a non-production app" || fail "generate --save"
grep -q '# Environment: ${gen_env}. This app reads cipi-${gen_env}.yml before cipi.yml' "${LIB}/yml.sh" \
    && pass "generate header names the environment" || fail "generate header"
grep -q '^  # branch: main              # the git branch this app deploys' "${LIB}/yml.sh" \
    && pass "example documents deploy.branch" || fail "example branch"
grep -q 'error "No cipi.yml found for '"'"'${app}'"'"' (environment: ${yenv})."' "${LIB}/yml.sh" \
    && pass "the not-found message names the environment and the files looked for" || fail "not-found message"
grep -q '"snapshot", "node_build", "branch"}, "deploy")' "${LIB}/yml.sh" \
    && pass "deploy.branch is an allowed key" || fail "allowed keys"

# ── 6. sync.sh and the help ──────────────────────────────────
echo "--- sync.sh, cipi help"
[[ "$(grep -c 'app_env_set_environment "$app" "$(app_env_label "$app")" || true' "${LIB}/sync.sh")" == "2" ]] \
    && pass "sync import and update keep CIPI_ENV/APP_ENV in step" || fail "sync env"
grep -q -- '--env=production|staging|…' "${ROOT}/cipi" && grep -q 'cipi-<env>.yml before cipi.yml' "${ROOT}/cipi" \
    && pass "cipi help names --env and cipi-<env>.yml" || fail "help"

# ── 7. migration 5.8.0 ───────────────────────────────────────
echo "--- migration 5.8.0"
MIGFN="${TMP}/migfn.sh"
{
    echo "YML_DENY_OLD='location ~* /cipi\\.ya?ml\$ { deny all; }'"
    echo "YML_DENY_NEW='location ~* /cipi(-[a-z0-9_-]+)?\\.ya?ml\$ { deny all; }'"
    extract migrations/5.8.0.sh _widen_cipi_yml_deny
} > "$MIGFN"
cat > "${TMP}/vhost" <<'VH'
server {
    listen 80;
    server_name shop.test;
    location ~* /cipi\.ya?ml$ { deny all; }
    location ~ /\.(?!well-known) { deny all; }
}
server {
    listen 443 ssl;
    server_name shop.test;
    location ~* /cipi\.ya?ml$ { deny all; }
    location ~ /\.(?!well-known) { deny all; }
}
VH
chmod 600 "${TMP}/vhost"
bash -c "source '$MIGFN'; _widen_cipi_yml_deny '${TMP}/vhost'" \
    && pass "widen: rewrote the vhost (status 0)" || fail "widen: status"
[[ "$(grep -c 'location ~\* /cipi(-\[a-z0-9_-\]+)?\\.ya?ml\$ { deny all; }' "${TMP}/vhost")" == "2" ]] \
    && ! grep -qF 'location ~* /cipi\.ya?ml$' "${TMP}/vhost" \
    && pass "widen: both server blocks (:80 and the :443 clone) carry the new rule" || fail "widen: $(cat "${TMP}/vhost")"
[[ "$(wc -l < "${TMP}/vhost" | tr -d ' ')" == "12" ]] && grep -q 'location ~ /\\.(?!well-known) { deny all; }' "${TMP}/vhost" \
    && pass "widen: every other line kept" || fail "widen: lines changed"
mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
[[ "$(mode "${TMP}/vhost")" == "600" || "$(uname)" == "Darwin" ]] \
    && pass "widen: the vhost keeps its mode" || fail "widen: mode $(mode "${TMP}/vhost")"
bash -c "source '$MIGFN'; _widen_cipi_yml_deny '${TMP}/vhost'" \
    && fail "widen: a second run should have nothing to do" || pass "widen: idempotent (status 1 the second time)"
printf 'server {\n    listen 80;\n}\n' > "${TMP}/vhost2"
bash -c "source '$MIGFN'; _widen_cipi_yml_deny '${TMP}/vhost2'" \
    && fail "widen: a vhost without the rule was rewritten" || pass "widen: a vhost without the rule is left alone"
[[ "$(cat "${TMP}/vhost2" | paste -sd, -)" == "server {,    listen 80;,}" ]] \
    && pass "widen: untouched vhost unchanged" || fail "widen: vhost2 changed"
grep -q 'app_env_set_environment "$app" "$label" add' "${LIB}/migrations/5.8.0.sh" \
    && grep -q 'label=$(app_env_label "$app")' "${LIB}/migrations/5.8.0.sh" \
    && pass "migration adds CIPI_ENV from the app's label, in add mode" || fail "migration CIPI_ENV"
grep -q 'vhost-backup-5.8.0' "${LIB}/migrations/5.8.0.sh" && grep -q 'nginx -t' "${LIB}/migrations/5.8.0.sh" \
    && pass "migration keeps backups and tests nginx before reloading" || fail "migration safety"
grep -q 'Migration 5.8.0 complete' "${LIB}/migrations/5.8.0.sh" \
    && pass "migration ends with its completion line" || fail "migration completion line"

echo ""
echo "=== ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]

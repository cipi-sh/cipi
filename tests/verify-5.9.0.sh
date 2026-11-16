#!/bin/bash
# Local regression checks for 5.9.0 — Horizon detected at deploy (enabled only
# when it is installed, the queues are on Redis and no worker is configured;
# otherwise advice, once; the .env never edited), the optional Git token step
# of setup.sh, the deploy history across the rotated deploy logs (the reason
# the panel lost the duration of webhook deploys) and every app's last
# deploy, databases linked to an app (cipi db create --app=, db link|unlink,
# the APP column a person sees and the four columns a parser keeps, --json),
# a dump opened by the owner of the tree it is in, the backup JSON the
# panel's page is drawn from (never a key), a backup run started in the
# background, and the sudoers rules the panel needs for all of it.
# Pure bash + coreutils + jq. The functions are run for real against a fake
# vault and fake log directories under the temp dir; mariadb, sudo, ps-less
# paths and the cipi binary of the detached run are stubs. What needs the
# machine — systemd-run for the detached backup, logrotate making the rotated
# files, sudo reading the new rules — is not here.
# Nothing outside the temp dir is touched and no mail is sent.
# Run from repo root: bash tests/verify-5.9.0.sh
# No pipefail here: a check is `command | grep -q`, and the command may exit
# non-zero on purpose (a refusal) or be cut short by grep -q.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/lib"
PASS=0
FAIL=0

pass() { echo "  OK: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
fn() { sed -n "/^${2}() {/,/^}/p" "${LIB}/${1}"; }

TMP=$(mktemp -d) && [[ -n "$TMP" && -d "$TMP" ]] || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "${TMP:?}"' EXIT
command -v jq >/dev/null 2>&1 || { echo "jq is required for these checks" >&2; exit 1; }

echo "=== Cipi 5.9.0 regression checks ==="

[[ "$(tr -d '[:space:]' < "${ROOT}/version.md")" == "5.9.0" ]] \
    && pass "version.md is 5.9.0" || fail "version.md is not 5.9.0"
grep -q '^## \[5.9.0\]' "${ROOT}/CHANGELOG.md" && pass "CHANGELOG has a 5.9.0 entry" || fail "CHANGELOG 5.9.0"
for f in deploy.sh db.sh backup.sh app.sh common.sh worker.sh pending.sh node.sh completion.sh cipi-api-sudoers.sh migrations/5.9.0.sh; do
    bash -n "${LIB}/${f}" && pass "${f} parses" || fail "${f} does not parse"
done
bash -n "${ROOT}/setup.sh" && pass "setup.sh parses" || fail "setup.sh does not parse"
bash -n "${ROOT}/cipi" && pass "cipi parses" || fail "cipi does not parse"

# A harness: colours empty, a vault made of files, the real libraries.
mkdir -p "${TMP}/vault" "${TMP}/etc" "${TMP}/log"
cat > "${TMP}/h.sh" <<EOS
set -u
RED=''; GREEN=''; YELLOW=''; CYAN=''; DIM=''; NC=''; BOLD=''
CIPI_LIB="${LIB}"; CIPI_CONFIG="${TMP}/etc"; CIPI_LOG="${TMP}/log"
source "${LIB}/common.sh"
vault_read()  { cat "${TMP}/vault/\$1" 2>/dev/null || return 1; }
vault_write() { cat > "${TMP}/vault/\$1.new" && mv "${TMP}/vault/\$1.new" "${TMP}/vault/\$1"; }
ensure_apps_json_api_access() { :; }
log_action() { echo "\$*" >> "${TMP}/actions"; }
cipi_notify() { :; }
info(){ echo "[INFO] \$*"; }; warn(){ echo "[WARN] \$*"; }; success(){ echo "[OK] \$*"; }; step(){ echo "[STEP] \$*"; }
error(){ echo "[ERROR] \$*"; }
app_exists() { vault_read apps.json | jq -e --arg a "\$1" '.[\$a]' >/dev/null 2>&1; }
app_get() { vault_read apps.json | jq -r --arg a "\$1" --arg k "\$2" '.[\$a][\$k] // empty'; }
app_set() { vault_read apps.json | jq --arg a "\$1" --arg k "\$2" --arg v "\$3" '.[\$a][\$k] = \$v' | vault_write apps.json; }
app_unset() { vault_read apps.json | jq --arg a "\$1" --arg k "\$2" 'del(.[\$a][\$k])' | vault_write apps.json; }
EOS
vault_reset() {
    cat > "${TMP}/vault/apps.json" <<'JSON'
{"shop":{"domain":"shop.test","php":"8.4"},
 "blog":{"domain":"blog.test","php":"8.4","custom":true},
 "api":{"domain":"api.test","php":"8.4","engine":"pgsql"},
 "front":{"domain":"front.test","custom":true,"runtime":"node","node_mode":"ssr"}}
JSON
    echo '{"mariadb":{"wpblog":{"user":"wpblog"},"standalone":{"user":"standalone"}},"pgsql":{}}' > "${TMP}/vault/databases.json"
    rm -f "${TMP}/actions"
}
vault_reset
run() { bash -c "source '${TMP}/h.sh'; $1"; }

# ── 1. Horizon detected at deploy ────────────────────────────
echo "--- Horizon detection"
mkdir -p "${TMP}/sv" "${TMP}/home/shop/current/vendor/laravel/horizon" "${TMP}/home/shop/shared"
cat > "${TMP}/hz.sh" <<EOS
source '${TMP}/h.sh'
$(fn deploy.sh deploy_horizon_state | sed "s|home=\"/home/\$1\"|home=\"${TMP}/home/\$1\"|; s|/etc/supervisor/conf.d/|${TMP}/sv/|")
$(fn deploy.sh _deploy_horizon_detect)
id() { return 0; }
app_as() { shift; "\$@"; }
app_read() { cat "\$2" 2>/dev/null; }
_horizon_enable() { echo "ENABLED \$1"; [[ -e '${TMP}/hz.fail' ]] && exit 1; return 0; }
source() { :; }
EOS
hz() { bash -c "source '${TMP}/hz.sh'; $1"; }
: > "${TMP}/home/shop/current/vendor/laravel/horizon/composer.json"
echo 'QUEUE_CONNECTION=redis' > "${TMP}/home/shop/shared/.env"
[[ "$(hz 'deploy_horizon_state shop')" == "enable" ]] && pass "installed + QUEUE_CONNECTION=redis + no worker → enable" || fail "state enable: $(hz 'deploy_horizon_state shop')"
printf 'APP_ENV=production\nQUEUE_CONNECTION="database"\r\n' > "${TMP}/home/shop/shared/.env"
[[ "$(hz 'deploy_horizon_state shop')" == "env:database" ]] && pass "another queue connection → advice, not enable (quotes and CR dropped)" || fail "state env: $(hz 'deploy_horizon_state shop')"
echo 'APP_ENV=production' > "${TMP}/home/shop/shared/.env"
[[ "$(hz 'deploy_horizon_state shop')" == "env:unset" ]] && pass "no QUEUE_CONNECTION → advice" || fail "state unset: $(hz 'deploy_horizon_state shop')"
echo 'QUEUE_CONNECTION=redis' > "${TMP}/home/shop/shared/.env"
printf '[program:shop-worker-default]\ncommand=php artisan queue:work\n' > "${TMP}/sv/shop.conf"
[[ "$(hz 'deploy_horizon_state shop')" == "workers" ]] && pass "queue:work workers already configured → never replaced by itself" || fail "state workers: $(hz 'deploy_horizon_state shop')"
rm -f "${TMP}/sv/shop.conf"
run 'app_set shop horizon true'; [[ -z "$(hz 'deploy_horizon_state shop')" ]] && pass "Horizon already on → nothing" || fail "state when on"
run 'app_unset shop horizon; app_set shop horizon_auto off'; [[ -z "$(hz 'deploy_horizon_state shop')" ]] && pass "after cipi worker horizon disable → never re-enabled" || fail "state after disable"
run 'app_unset shop horizon_auto'
[[ -z "$(hz 'deploy_horizon_state blog')" ]] && pass "a custom app is not looked at" || fail "custom app state"
rm -f "${TMP}/home/shop/current/vendor/laravel/horizon/composer.json"
[[ -z "$(hz 'deploy_horizon_state shop')" ]] && pass "laravel/horizon not installed → nothing" || fail "state without the package"
: > "${TMP}/home/shop/current/vendor/laravel/horizon/composer.json"
out=$(hz '_deploy_horizon_detect shop'); grep -q 'ENABLED shop' <<< "$out" && pass "detect: the enable case turns Horizon on" || fail "detect enable: $out"
touch "${TMP}/hz.fail"; out=$(hz '_deploy_horizon_detect shop; echo "rc=$?"'); rm -f "${TMP}/hz.fail"
grep -q 'cipi worker horizon enable shop' <<< "$out" && grep -q 'rc=0' <<< "$out" && pass "detect: an enable that fails is a warning, not a failed deploy" || fail "detect enable failure: $out"
echo 'QUEUE_CONNECTION=sync' > "${TMP}/home/shop/shared/.env"
out=$(hz '_deploy_horizon_detect shop'); out2=$(hz '_deploy_horizon_detect shop')
grep -q "QUEUE_CONNECTION is 'sync'" <<< "$out" && grep -q 'cipi app env shop --set=QUEUE_CONNECTION=redis' <<< "$out" && ! grep -q ENABLED <<< "$out" \
    && pass "detect: the .env is only suggested, with the commands to run" || fail "detect advice: $out"
[[ -z "$out2" ]] && pass "detect: the same advice is given once, not at every deploy" || fail "advice repeated: $out2"
echo 'QUEUE_CONNECTION=database' > "${TMP}/home/shop/shared/.env"
[[ -n "$(hz '_deploy_horizon_detect shop')" ]] && pass "detect: a different situation is said again" || fail "advice not renewed"
! grep -qE '_env_set|app_write|sed -i' <<< "$(fn deploy.sh deploy_horizon_state; fn deploy.sh _deploy_horizon_detect)" \
    && pass "neither function writes to the .env" || fail "the Horizon detection writes somewhere"
grep -q '_deploy_horizon_detect "\$app" || true' "${LIB}/deploy.sh" && pass "cipi deploy runs the detection, and never fails because of it" || fail "detection not wired into the deploy"
grep -q 'app_unset "\$app" horizon_auto' <<< "$(fn worker.sh _horizon_enable)" && grep -q 'app_set "\$app" horizon_auto "off"' <<< "$(fn worker.sh _horizon_disable)" \
    && pass "worker horizon disable is remembered, enable forgets it" || fail "horizon_auto not kept by worker.sh"
grep -q '_pending_horizon' <<< "$(fn pending.sh pending_collect)" && grep -q '== "enable"' <<< "$(fn pending.sh _pending_horizon)" \
    && pass "cipi pending names the apps a webhook-only deploy leaves without a worker" || fail "pending has no Horizon item"
vault_reset

# ── 2. setup.sh: the Git token step ──────────────────────────
echo "--- setup: Git token step"
gt=$(sed -n '/^_setup_git_token() {/,/^}/p' "${ROOT}/setup.sh")
[[ -n "$gt" ]] && pass "setup.sh has _setup_git_token" || fail "no _setup_git_token in setup.sh"
grep -q '_setup_git_token || true' "${ROOT}/setup.sh" && pass "it is optional: a failure or a skip does not stop the setup" || fail "the Git token step can stop setup"
grep -q 'read -rs' <<< "$gt" && pass "the token is read without echo" || fail "token read with echo"
for prov in github gitlab bitbucket azure; do
    grep -qi "$prov" <<< "$gt" || fail "provider ${prov} missing from the step"
done
pass "GitHub, GitLab, Bitbucket and Azure DevOps are offered"
! grep -qE 'echo .*\$\{?token' <<< "$gt" && pass "the token is never printed back" || fail "the step echoes the token"

# ── 3. Deploy history across rotated logs ────────────────────
echo "--- deploy history"
L="${TMP}/dl"; mkdir -p "$L/demo" "$L/other" "$L/never"
cat > "${TMP}/dh.sh" <<EOS
source '${TMP}/h.sh'
source '${LIB}/deploy.sh'
deploy_log_file() { echo "${L}/\${1:-}/deploy.log"; }
EOS
dh() { TZ=Europe/Rome bash -c "source '${TMP}/dh.sh'; $1"; }
printf '%s\n' \
 '[2026-11-10 10:00:00] ===== deploy start  app=demo trigger=webhook branch=main from-release=10 =====' \
 '[2026-11-10 10:00:01] some output' \
 '[2026-11-10 10:00:41] ===== deploy OK  app=demo release=11 duration=41s exit=0 =====' > "$L/demo/deploy.log.3"
gzip -f "$L/demo/deploy.log.3"; touch -d '2026-11-11 00:00' "$L/demo/deploy.log.3.gz"
printf '%s\n' \
 '[2026-11-11 09:00:00] ===== deploy start  app=demo trigger=cli branch=main from-release=11 =====' \
 '[2026-11-11 09:01:10] ===== deploy FAILED  app=demo release=11 duration=70s exit=1 =====' \
 '[2026-11-11 23:59:50] ===== deploy start  app=demo trigger=webhook branch=feat/x from-release=11 =====' > "$L/demo/deploy.log.2"
gzip -f "$L/demo/deploy.log.2"; touch -d '2026-11-12 00:00' "$L/demo/deploy.log.2.gz"
printf '%s\n' \
 '[2026-11-12 00:00:35] ===== deploy OK  app=demo release=12 duration=45s exit=0 =====' \
 '[2026-11-12 15:00:00] ===== deploy start  app=demo trigger=cli branch=main from-release=12 =====' \
 '[2026-11-12 15:00:09] ===== deploy ROLLBACK OK  app=demo release=11 duration=9s exit=0 =====' > "$L/demo/deploy.log.1"
touch -d '2026-11-13 00:00' "$L/demo/deploy.log.1"
: > "$L/demo/deploy.log"
: > "$L/other/deploy.log"
printf '%s\n' '[2026-11-01 08:02:05] ===== deploy OK  app=other release=3 duration=7s exit=0 =====' > "$L/other/deploy.log.1"
echo '{"demo":{},"other":{},"never":{}}' > "${TMP}/vault/apps.json"

rows=$(dh '_deploy_history_rows demo 30' | tr $'\x1f' '|')
[[ "$(wc -l <<< "$rows")" == "4" ]] && pass "an empty deploy.log (the morning after rotation): the 4 runs are still there" || fail "history rows: $rows"
[[ "$(sed -n 1p <<< "$rows")" == "2026-11-12 15:00:09|rollback|ok|11|9|0|2026-11-12 15:00:00|cli|main|12" ]] && pass "newest first, a rollback is a rollback" || fail "row 1: $(sed -n 1p <<< "$rows")"
[[ "$(sed -n 2p <<< "$rows")" == "2026-11-12 00:00:35|deploy|ok|12|45|0|2026-11-11 23:59:50|webhook|feat/x|11" ]] \
    && pass "a webhook deploy that started before the rotation and ended after it keeps trigger, branch and duration" || fail "row 2: $(sed -n 2p <<< "$rows")"
[[ "$(sed -n 3p <<< "$rows")" == "2026-11-11 09:01:10|deploy|failed|11|70|1|2026-11-11 09:00:00|cli|main|11" ]] && pass "a failed deploy, with its exit code" || fail "row 3"
[[ "$(dh '_deploy_history_rows demo 2' | wc -l)" == "2" ]] && pass "--limit stops at the newest N" || fail "limit 2"
j=$(dh 'ARG_json=true; ARG_limit=3; _deploy_history demo')
[[ "$(jq -r '.count' <<< "$j")" == "3" && "$(jq -r '.runs[1].duration' <<< "$j")" == "45" && "$(jq -r '.runs[1].trigger' <<< "$j")" == "webhook" ]] \
    && pass "--history --json: count, duration as a number, trigger" || fail "history json: $j"
[[ "$(jq -r '.runs[1].finished_at' <<< "$j")" == "2026-11-12T00:00:35+0100" && "$(jq -r '.runs[1].started_at' <<< "$j")" == "2026-11-11T23:59:50+0100" ]] \
    && pass "times are ISO 8601 with the server's offset" || fail "history times: $(jq -c '.runs[1]' <<< "$j")"
[[ "$(jq -r '.runs[0] | keys | join(",")' <<< "$j")" == "branch,duration,exit,finished_at,from_release,kind,release,result,started_at,trigger" ]] \
    && pass "a run has the keys of \"last\" in --status --json" || fail "history keys: $(jq -r '.runs[0] | keys | join(",")' <<< "$j")"
dh 'ARG_limit=0; _deploy_history demo' 2>&1 | grep -q -- '--limit must be a number' && pass "--limit=0 is refused" || fail "--limit=0 accepted"
printf '%s\n' '[2026-99-99 99:99:99] ===== deploy OK  app=demo release=14 duration=1s exit=0 =====' \
    $'[2026-11-14 09:00:00] ===== deploy OK  app=demo release=15\x1b[31m duration=1s exit=0 =====' >> "$L/demo/deploy.log"
j=$(dh 'ARG_json=true; _deploy_history demo')
[[ "$(jq -r '.runs[0].release' <<< "$j")" == "14" && "$(jq -r '.runs[0].finished_at' <<< "$j")" == "null" ]] \
    && pass "a time date cannot read (the app user writes to its own log) is null, not an error" || fail "bad date: $(jq -c '.runs[0]' <<< "$j")"
! grep -q $'\x1b' <<< "$(dh '_deploy_history_rows demo 30')" && pass "a banner with a control character in a field is not a banner" || fail "escape sequence passed through"
: > "$L/demo/deploy.log"
j=$(dh 'ARG_json=true; _deploy_last ""')
[[ "$(jq -r '.apps.demo.kind' <<< "$j")" == "rollback" && "$(jq -r '.apps.other.duration' <<< "$j")" == "7" && "$(jq -r '.apps.never' <<< "$j")" == "null" ]] \
    && pass "--last --json: every app, from the rotated log when today's is empty, null for one never deployed" || fail "last json: $j"
dh 'ARG_json=""; _deploy_last ""' | grep -q 'never' && pass "--last prints a table, 'never' for an app without deploys" || fail "last table"
[[ "$(dh '_deploy_release_took demo 12')" == "45s" && -z "$(dh '_deploy_release_took demo 99')" ]] \
    && pass "--releases finds a duration in the rotated logs too" || fail "release took: $(dh '_deploy_release_took demo 12')"
# The dispatcher: flag first never deploys; an older Cipi answers "not found".
cat >> "${TMP}/dh.sh" <<'EOS'
_deploy_run() { echo "DEPLOYED $1"; }
EOS
out=$(dh 'deploy_command --last --json'); jq -e '.apps | has("demo")' <<< "$out" >/dev/null 2>&1 && pass "cipi deploy --last" || fail "deploy --last: $out"
out=$(dh 'deploy_command --history demo --json --limit=1'); [[ "$(jq -r '.count' <<< "$out" 2>/dev/null)" == "1" ]] && pass "cipi deploy --history <app> (flag first)" || fail "deploy --history demo: $out"
out=$(dh 'deploy_command demo --history --json'); [[ "$(jq -r '.app' <<< "$out" 2>/dev/null)" == "demo" ]] && pass "cipi deploy <app> --history" || fail "deploy demo --history: $out"
out=$(dh 'deploy_command --history ghost' 2>&1); grep -q "App 'ghost' not found" <<< "$out" && ! grep -q DEPLOYED <<< "$out" && pass "an unknown app is an error" || fail "history ghost: $out"
out=$(dh 'deploy_command --history' 2>&1); grep -q 'Usage: cipi deploy --history <app>' <<< "$out" && pass "--history alone prints its usage" || fail "history alone: $out"
for form in '--history demo' '--last' 'demo --history' 'demo --last --json'; do
    dh "deploy_command ${form}" 2>&1 | grep -q DEPLOYED && fail "cipi deploy ${form} started a deploy"
done
pass "no reading form starts a deploy"
grep -q '\*" --history"\*|\*" --last"\*' <<< "$(fn deploy.sh _deploy_live_pids)" && pass "--status does not take a --history or --last for a running deploy" || fail "_deploy_live_pids counts the reading forms"
vault_reset

# ── 4. Databases linked to an app ────────────────────────────
echo "--- database links"
cat > "${TMP}/db.sh" <<EOS
source '${TMP}/h.sh'
source '${LIB}/db.sh'
db_ensure_engine_state() { :; }
db_engine_is_installed() { [[ "\$1" == "mariadb" || "\$1" == "pgsql" ]]; }
db_get_default_engine() { echo mariadb; }
db_get_root_password() { echo pw; }
db_list_databases() { case "\$1" in mariadb) printf 'shop\nshop_tenant1\nwpblog\nstandalone\n' ;; pgsql) printf 'api\n' ;; esac; }
db_create_database() { echo "\$*" >> '${TMP}/created'; return 0; }
db_drop_database() { echo "\$*" >> '${TMP}/dropped'; return 0; }
generate_password() { echo secretpw; }
mariadb() { printf 'shop\t1.50\nshop_tenant1\t0.10\nstandalone\t0.02\nwpblog\t3.25\n'; }
_db_pgsql_exec() { printf 'api\t0.75\n'; }
EOS
db() { bash -c "source '${TMP}/db.sh'; $1"; }
links() { jq -c 'to_entries | map(select(.value.databases != null) | {(.key): [.value.databases[] | .engine + "/" + .name]}) | add // {}' "${TMP}/vault/apps.json"; }
db '_db_link wpblog blog' | grep -q "linked to app 'blog'" && [[ "$(links)" == '{"blog":["mariadb/wpblog"]}' ]] \
    && pass "cipi db link <db> <app>: one line in the app's entry of apps.json" || fail "link: $(links)"
[[ "$(db 'db_linked_app mariadb wpblog')" == "blog" && -z "$(db 'db_linked_app pgsql wpblog')" ]] && pass "db_linked_app: by engine and name" || fail "db_linked_app"
db '_db_link wpblog blog' | grep -q 'already linked' && pass "linking twice says so" || fail "second link"
db '_db_link wpblog front' | grep -q "it was linked to 'blog'" && [[ "$(links)" == '{"front":["mariadb/wpblog"]}' ]] \
    && pass "a database is linked to one app at most: linking it elsewhere moves it" || fail "relink: $(links)"
db '_db_link shop shop' | grep -q 'already shown as its own' && [[ "$(links)" == '{"front":["mariadb/wpblog"]}' ]] \
    && pass "the database created with a Laravel app needs no link" || fail "own database linked: $(links)"
db '_db_link ghostdb blog' 2>&1 | grep -q "No database 'ghostdb'" && pass "a database that does not exist is refused" || fail "link of a missing database"
db '_db_link wpblog ghost' 2>&1 | grep -q "App 'ghost' not found" && pass "an app that does not exist is refused" || fail "link to a missing app"
db '_db_link wpblog' 2>&1 | grep -q 'Usage: cipi db link' && db '_db_link --json blog' 2>&1 | grep -q 'Usage: cipi db link' && pass "db link wants a database and an app" || fail "db link usage"
db '_db_unlink wpblog' | grep -q "unlinked from app 'front'" && [[ "$(links)" == '{}' ]] && pass "cipi db unlink removes it, and the empty list with it" || fail "unlink: $(links)"
db '_db_unlink wpblog' | grep -q 'not linked' && pass "unlinking what is not linked says so" || fail "second unlink"

rm -f "${TMP}/created"
out=$(db '_db_create --name=wpshop --app=ghost' 2>&1)
grep -q "App 'ghost' not found" <<< "$out" && [[ ! -e "${TMP}/created" ]] && pass "db create --app=<missing>: refused before anything is created" || fail "create --app ghost: $out"
out=$(db '_db_create --name=wpshop --app' 2>&1)
grep -q -- '--app needs a name' <<< "$out" && [[ ! -e "${TMP}/created" ]] && pass "db create --app without a name is refused" || fail "create --app bare: $out"
out=$(db '_db_create --name=wpshop --app=blog')
[[ "$(links)" == '{"blog":["mariadb/wpshop"]}' ]] && grep -q 'App: blog' <<< "$out" && pass "db create --app=<app>: created, registered and linked" || fail "create --app: $out / $(links)"
grep -qE 'Engine: +mariadb +Database: +wpshop +User: +wpshop +Password: +secretpw' <<< "$out" \
    && pass "the line the panel API reads from db create is unchanged" || fail "create output changed: $out"
out=$(db '_db_create --name=plain'); ! grep -q 'App:' <<< "$out" && [[ "$(links)" == '{"blog":["mariadb/wpshop"]}' ]] && pass "db create without --app links nothing" || fail "plain create linked"
db '_db_link wpblog blog' >/dev/null
db '_db_delete wpshop --force' >/dev/null; [[ "$(links)" == '{"blog":["mariadb/wpblog"]}' ]] && pass "db delete drops the link with the database" || fail "delete kept the link: $(links)"

# cipi db list: four columns for a parser, the app in --json.
tbl=$(db '_db_list' < /dev/null)
! grep -q 'APP' <<< "$tbl" && pass "piped, cipi db list keeps its four columns" || fail "APP column without a terminal: $tbl"
bad=0; n=0
while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$line" || "$line" == ─* || "$line" == ━* || "$line" == =* ]] && continue
    [[ "$line" =~ ^(ENGINE|DATABASE|Databases|Name) ]] && continue
    if [[ "$line" =~ ^(mariadb|pgsql)[[:space:]]+([^[:space:]]+)[[:space:]]+([^[:space:]]+)[[:space:]]+([0-9.]+\ MB)$ ]]; then n=$((n + 1)); else bad=$((bad + 1)); fi
done <<< "$tbl"
[[ "$n" == "5" && "$bad" == "0" ]] && pass "every line is one the panel API 1.38 parses (engine, name, user, size): 5 rows, no stray line" || fail "db list lines: ${n} rows, ${bad} unparsed — ${tbl}"
j=$(db '_db_list --json')
got=$(jq -c '[.databases[] | {(.engine + "/" + .name): ((.app // "-") + ":" + (.link // "-"))}] | add' <<< "$j")
[[ "$got" == '{"mariadb/shop":"shop:own","mariadb/shop_tenant1":"shop:namespace","mariadb/standalone":"-:-","mariadb/wpblog":"blog:linked","pgsql/api":"api:own"}' ]] \
    && pass "--json: own (created with the app), namespace (<app>_…), linked, and none" || fail "db list json owners: $got"
[[ "$(jq -r '.databases[] | select(.name == "wpblog") | .size_mb' <<< "$j")" == "3.25" && "$(jq -r '.databases[] | select(.name == "standalone") | .user' <<< "$j")" == "standalone" ]] \
    && pass "--json: size as a number, the user from the registry" || fail "db list json fields: $j"
! grep -q 'Databases' <<< "$j" && jq -e . <<< "$j" >/dev/null 2>&1 && pass "--json prints JSON and nothing else" || fail "db list --json is not clean JSON"
echo '{"shop":{"domain":"s"},"shopping":{"domain":"x","custom":true}}' > "${TMP}/vault/apps.json"
cat >> "${TMP}/db.sh" <<'EOS'
mariadb() { printf 'shopping_cart\t1\nshop_x\t1\nshopping\t1\n'; }
db_engine_is_installed() { [[ "$1" == "mariadb" ]]; }
EOS
got=$(db '_db_list --json' | jq -c '[.databases[] | {(.name): ((.app // "-") + ":" + (.link // "-"))}] | add')
[[ "$got" == '{"shopping_cart":"shopping:namespace","shop_x":"shop:namespace","shopping":"-:-"}' ]] \
    && pass "namespace: the longest app name wins; a custom app has no database of its own" || fail "namespace owners: $got"
grep -q -- '-t 1' <<< "$(fn db.sh _db_list)" && grep -q 'tbl_head "ENGINE" "DATABASE" "USER" "SIZE" "APP"' "${LIB}/db.sh" \
    && pass "the APP column is for a terminal" || fail "APP column not tied to a terminal"
vault_reset

# The app side: shown, projected, and kept when the app goes.
grep -q 'ssl_dns_provider, backup_profiles, search, databases,' "${LIB}/common.sh" && pass "the projection the panel reads carries the links" || fail "apps-public.json without databases"
grep -q '"Databases" "\$linked_dbs"' "${LIB}/app.sh" && pass "cipi app show lists the linked databases" || fail "app show without databases"
grep -q 'Linked database(s) kept: \${kept_dbs}' "${LIB}/app.sh" && pass "cipi app delete says which linked databases it left" || fail "app delete silent about linked databases"

# ── 5. A dump is opened by the owner of its tree ─────────────
echo "--- db restore: who opens the dump"
cat > "${TMP}/rd.sh" <<EOS
source '${TMP}/h.sh'
source '${LIB}/db.sh'
id() { [[ "\${1:-}" == "-u" ]] && { command id -u; return; }; return 0; }
CIPI_API_ROOT='${TMP}/opt/api'; CIPI_GUI_ROOT='${TMP}/opt/gui'
app_as() { echo "AS \$1" >> '${TMP}/as'; shift; "\$@"; }
EOS
rd() { bash -c "source '${TMP}/rd.sh'; $1"; }
if [[ "$(id -u)" -eq 0 ]]; then
    [[ "$(rd 'db_dump_reader /home/shop/dump.sql.gz')" == "shop" ]] && pass "a dump in an app's home is opened by the app user" || fail "reader for a home: $(rd 'db_dump_reader /home/shop/dump.sql.gz')"
    [[ "$(rd "db_dump_reader '${TMP}/opt/api/storage/app/cipi-db-uploads/x.sql.gz'")" == "www-data" ]] && pass "a dump uploaded through the panel is opened by www-data" || fail "reader for the panel tree"
    [[ -z "$(rd 'db_dump_reader /var/log/cipi/backups/x.sql.gz')" ]] && pass "a file of root's is opened by root, as before" || fail "reader for a root path"
else
    [[ -z "$(rd 'db_dump_reader /home/shop/dump.sql.gz')" ]] && pass "not root: nothing to drop (the caller has no more rights than its own)" || fail "reader when not root"
fi
mkdir -p "${TMP}/d"; printf 'SELECT 1;\n' | gzip > "${TMP}/d/a.sql.gz"; printf 'SELECT 2;\n' > "${TMP}/d/b.sql"
rm -f "${TMP}/as"
[[ "$(rd "_db_dump_cat '${TMP}/d/a.sql.gz' shop")" == "SELECT 1;" && "$(rd "_db_dump_cat '${TMP}/d/b.sql' www-data")" == "SELECT 2;" ]] \
    && [[ "$(tr '\n' ' ' < "${TMP}/as")" == "AS shop AS www-data " ]] && pass "_db_dump_cat with a user: gunzip or cat run as that user" || fail "dump cat as a user: $(cat "${TMP}/as" 2>/dev/null)"
rm -f "${TMP}/as"
[[ "$(rd "_db_dump_cat '${TMP}/d/a.sql.gz'")" == "SELECT 1;" && ! -e "${TMP}/as" ]] && pass "_db_dump_cat without a user: as before" || fail "dump cat plain"
rs=$(fn db.sh db_restore_database)
grep -q 'reader=$(db_dump_reader "$file")' <<< "$rs" && [[ "$(grep -c '_db_dump_cat "$file" "$reader"' <<< "$rs")" == "2" ]] \
    && pass "both engines restore through the reader" || fail "db_restore_database does not use the reader"
grep -q 'app_as "$reader" test -f "$file"' <<< "$(fn db.sh _db_restore)" && pass "cipi db restore looks for the file as its owner too" || fail "_db_restore tests the file as root"

# ── 6. Backup: what the panel's page is drawn from ───────────
echo "--- backup JSON"
mkdir -p "${TMP}/bk/local/default/2026-11-16_020000" "${TMP}/bk/local/default/2026-11-14_020000" "${TMP}/bk/local/default/notarun" "${TMP}/bk/bin"
NOW=$(date +%s)
cat > "${TMP}/vault/backup.json" <<JSON
{"bucket":"main-bucket","region":"eu-central-1","endpoint_url":"","aws_key":"AKIASECRETKEY","aws_secret":"topsecret","local_dir":"${TMP}/bk/local",
 "s3_destinations":{"offsite":{"bucket":"off-bucket","region":"fsn1","endpoint_url":"https://fsn1.example.com","aws_key":"K2SECRET","aws_secret":"S2SECRET"}},
 "profiles":{
   "default":{"scope":"all","apps":["*"],"databases":["*"],"exclude_databases":["tmp_*"],"exclude_tables":[],"cron":"0 2 * * *","interval_seconds":86400,"destinations":["s3","local"],"retention":{"keep":0,"days":28,"weeks":0},"encrypt":false,"enabled":true,"created_at":1700000000},
   "fast-db":{"scope":"db","apps":["*"],"databases":["shop","shop_*"],"exclude_databases":[],"exclude_tables":["*.jobs"],"cron":"*/30 * * * *","interval_seconds":1800,"destinations":["offsite"],"retention":{"keep":48,"days":0,"weeks":0},"encrypt":true,"enabled":true,"created_at":1700000000},
   "off":{"scope":"files","apps":["blog"],"databases":[],"exclude_databases":[],"exclude_tables":[],"cron":"0 4 * * 0","interval_seconds":604800,"destinations":["local"],"retention":{"keep":4,"days":0,"weeks":0},"encrypt":false,"enabled":false,"created_at":1700000000},
   "fresh":{"scope":"db","apps":[],"databases":["analytics"],"exclude_databases":[],"exclude_tables":[],"cron":"0 3 * * *","interval_seconds":86400,"destinations":["local"],"retention":{"keep":7,"days":0,"weeks":0},"encrypt":false,"enabled":true,"created_at":${NOW}}
 }}
JSON
cat > "${TMP}/vault/backup-state.json" <<JSON
{"default":{"last_start":"2026-11-16 02:00:00","last_end":"2026-11-16 02:03:10","status":"ok","detail":"3 app(s), 4 database(s)","last_epoch":$((NOW - 3600)),"last_success_epoch":$((NOW - 3600))},
 "fast-db":{"last_start":"a","last_end":"b","status":"error","detail":"dest:offsite","last_epoch":$((NOW - 60)),"last_success_epoch":$((NOW - 7200))}}
JSON
: > "${TMP}/etc/backup.json"
cat > "${TMP}/bk.sh" <<EOS
source '${TMP}/h.sh'
BACKUP_KEY_FILE='${TMP}/bk/nokey'
source '${LIB}/db.sh'
source '${LIB}/backup.sh'
_bk_cfg_write() { vault_write backup.json; }
db_engine_is_installed() { [[ "\$1" == "mariadb" || "\$1" == "pgsql" ]]; }
db_list_databases() { case "\$1" in mariadb) printf 'shop\nshop_tenant1\napi\ntmp_scratch\nwpblog\n' ;; pgsql) printf 'analytics\n' ;; esac; }
_bk_s3_ls_dirs() { case "\$1" in s3) [[ "\$2" == *"/default/" ]] && printf '2026-11-15_020000\n2026-11-16_020000\n' ;; offsite) echo "cannot list (offsite): AccessDenied" >&2; return 1 ;; esac; return 0; }
_bk_write_cron() { :; }
cipi_notify() { echo NOTIFIED >> '${TMP}/notified'; }
_bk_has_s3() { return 0; }
EOS
bk() { bash -c "source '${TMP}/bk.sh'; $1"; }
echo '{"shop":{},"blog":{"custom":true},"api":{}}' > "${TMP}/vault/apps.json"
cp "${TMP}/vault/backup.json" "${TMP}/vault/backup.before"
j=$(bk '_bk_status --json')
jq -e . <<< "$j" >/dev/null 2>&1 && pass "cipi backup status --json is JSON" || fail "status json: $j"
! grep -qE 'topsecret|AKIASECRETKEY|K2SECRET|S2SECRET|aws_key|aws_secret' <<< "$j" && pass "no access key and no secret in it" || fail "status --json leaks credentials"
[[ "$(jq -c '[.destinations[] | .name + ":" + .type + ":" + (.profiles | join("+"))]' <<< "$j")" == '["local:local:default+fresh+off","s3:s3:default","offsite:s3:fast-db"]' ]] \
    && pass "destinations: local, the default bucket, the named ones, and the profiles on each" || fail "destinations: $(jq -c '.destinations' <<< "$j")"
[[ "$(jq -c '.profiles[] | select(.name == "default") | [.covers.apps, [.covers.databases[] | .engine + "/" + .name]]' <<< "$j")" == '[["api","blog","shop"],["mariadb/shop","mariadb/shop_tenant1","mariadb/api","mariadb/wpblog","pgsql/analytics"]]' ]] \
    && pass "a profile's cover: its globs applied to the apps and databases there are now (exclusions out)" || fail "default covers: $(jq -c '.profiles[] | select(.name == "default") | .covers' <<< "$j")"
[[ "$(jq -c '.profiles[] | select(.name == "fast-db") | [.covers.apps, [.covers.databases[].name], .overdue, .last.status, .encrypt]' <<< "$j")" == '[[],["shop","shop_tenant1"],true,"error",true]' ]] \
    && pass "scope db covers no files; no success within twice the interval is overdue" || fail "fast-db: $(jq -c '.profiles[] | select(.name == "fast-db")' <<< "$j")"
[[ "$(jq -c '.profiles[] | select(.name == "off") | [.enabled, .overdue, .last]' <<< "$j")" == '[false,false,null]' ]] && pass "a disabled profile is never overdue" || fail "off profile"
[[ "$(jq -c '.profiles[] | select(.name == "fresh") | [.overdue, .last]' <<< "$j")" == '[false,null]' ]] && pass "a profile created just now is not overdue yet" || fail "fresh profile"
[[ "$(jq -c '.uncovered' <<< "$j")" == '{"apps":[],"databases":[{"engine":"mariadb","name":"tmp_scratch"}]}' ]] \
    && pass "uncovered: what no enabled profile takes (a disabled profile covers nothing)" || fail "uncovered: $(jq -c '.uncovered' <<< "$j")"
[[ ! -e "${TMP}/notified" ]] && cmp -s "${TMP}/vault/backup.json" "${TMP}/vault/backup.before" \
    && pass "it only reads: no overdue mail, no default profile written" || fail "status --json wrote or notified"
touch "${TMP}/unconf"; j0=$(bash -c "source '${TMP}/bk.sh'; _bk_configured() { return 1; }; _bk_status --json")
[[ "$(jq -c '[.configured, (.profiles | length)]' <<< "$j0")" == '[false,0]' ]] && pass "not configured: configured=false, not an error" || fail "unconfigured status: $j0"

jl=$(bk '_bk_list --json')
[[ "$(jq -c '.profiles.default' <<< "$jl")" == '[{"run":"2026-11-16_020000","destinations":["local","s3"]},{"run":"2026-11-15_020000","destinations":["s3"]},{"run":"2026-11-14_020000","destinations":["local"]}]' ]] \
    && pass "cipi backup list --json: runs newest first, the destinations holding each (a stray directory is not a run)" || fail "list json: $(jq -c '.profiles.default' <<< "$jl")"
[[ "$(jq -c '.errors' <<< "$jl")" == '["cannot list (offsite): AccessDenied"]' ]] && pass "a bucket that cannot be listed is an entry in errors, once" || fail "list errors: $(jq -c '.errors' <<< "$jl")"
[[ "$(bk '_bk_list --json --profile=fast-db' | jq -c '.profiles | keys')" == '["fast-db"]' ]] && pass "--profile narrows it" || fail "list --profile"
bk '_bk_list --json --profile=nope' 2>&1 | grep -q 'No such profile' && pass "an unknown profile is an error" || fail "list --profile=nope"

# A run in the background.
cat > "${TMP}/bk/bin/cipi" <<EOS
#!/bin/bash
echo "ran: \$* sid=\$(ps -o sid= -p \$\$ | tr -d ' ') pid=\$\$" >> '${TMP}/bk/ran'
sleep 2
EOS
chmod +x "${TMP}/bk/bin/cipi"
out=$(bash -c "source '${TMP}/bk.sh'; CIPI_BIN='${TMP}/bk/bin/cipi' _bk_run --profile=default --detach")
grep -q 'Backup started in the background' <<< "$out" && pass "cipi backup run --detach returns at once" || fail "detach: $out"
for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -s "${TMP}/bk/ran" ]] && break; sleep 0.2; done
ran=$(cat "${TMP}/bk/ran" 2>/dev/null || true)
if [[ -d /run/systemd/system ]] && command -v systemd-run >/dev/null 2>&1; then
    pass "(systemd here: the run went to a transient unit — not checked by this test)"
else
    [[ "$ran" == "ran: backup run --profile=default sid="* ]] && pass "the run is the same command without --detach" || fail "detached args: $ran"
    sid=$(sed -n 's/.* sid=\([0-9]*\) .*/\1/p' <<< "$ran"); pid=$(sed -n 's/.* pid=\([0-9]*\)$/\1/p' <<< "$ran")
    [[ -n "$sid" && "$sid" == "$pid" ]] && pass "in a session of its own, so it outlives what started it" || fail "detached session: $ran"
fi
rm -f "${TMP}/bk/ran"
out=$(bash -c "source '${TMP}/bk.sh'; CIPI_BIN='${TMP}/bk/bin/cipi' _bk_run --profile=nope --detach" 2>&1); grep -q 'No such profile: nope' <<< "$out" && pass "--detach of an unknown profile is refused now, not in a log nobody reads" || fail "detach nope: $out"
out=$(bash -c "source '${TMP}/bk.sh'; CIPI_BIN='${TMP}/bk/bin/cipi' _bk_run --detach --dry-run" 2>&1); grep -q 'do not go together' <<< "$out" && pass "--detach --dry-run is refused" || fail "detach dry-run: $out"
out=$(bash -c "source '${TMP}/bk.sh'; CIPI_BIN='${TMP}/bk/bin/cipi' _bk_run --detach ghost" 2>&1); grep -q "App 'ghost' not found" <<< "$out" && pass "--detach with an unknown app is refused" || fail "detach ghost: $out"
sleep 0.3; [[ ! -s "${TMP}/bk/ran" ]] && pass "none of the refused ones started anything" || fail "a refused detach ran: $(cat "${TMP}/bk/ran")"
grep -q 'systemd-run --quiet --collect --no-block' "${LIB}/backup.sh" && grep -q 'setsid nohup "\$bin" backup run "\$@"' "${LIB}/backup.sh" \
    && pass "under systemd a unit of its own, a session of its own otherwise" || fail "detach paths"
rn=$(fn backup.sh _bk_running)
grep -q -- '--dry-run' <<< "$rn" && grep -q -- '--detach' <<< "$rn" && pass "a dry run and the command that only detaches are not runs in progress" || fail "_bk_running counts dry runs"

# The exclusion lists can be emptied.
bk '_bk_require_config() { :; }; _bk_profile_show() { :; }; _bk_profile_add edit default --exclude-databases=' >/dev/null 2>&1
[[ "$(jq -c '.profiles.default.exclude_databases' "${TMP}/vault/backup.json")" == '[]' ]] && pass "profile edit --exclude-databases= empties the list" || fail "exclude list not emptied: $(jq -c '.profiles.default.exclude_databases' "${TMP}/vault/backup.json")"
bk '_bk_require_config() { :; }; _bk_profile_show() { :; }; _bk_profile_add edit fast-db --keep=24' >/dev/null 2>&1
[[ "$(jq -c '.profiles["fast-db"] | [.exclude_tables, .retention.keep]' "${TMP}/vault/backup.json")" == '[["*.jobs"],24]' ]] && pass "a flag that is not given leaves its list alone" || fail "edit touched exclude_tables: $(jq -c '.profiles["fast-db"]' "${TMP}/vault/backup.json")"
vault_reset

# ── 7. The panel's sudoers ───────────────────────────────────
echo "--- panel sudoers"
S="${TMP}/sudoers"
sed -n '/^www-data ALL/,/^SUDOEOF/p' "${LIB}/cipi-api-sudoers.sh" | sed '$d' > "$S"
for rule in 'node install \*' 'node default \*' 'node upgrade' 'node upgrade \*' 'node remove \*' 'db link \*' 'db unlink \*' \
            'backup status --json' 'backup list --json' 'backup list --json \*' 'backup run --detach' 'backup run --detach \*' \
            'backup verify \*' 'backup profile add \*' 'backup profile edit \*' 'backup profile remove \*' \
            'backup profile enable \*' 'backup profile disable \*' 'backup destination test' 'backup destination test \*'; do
    grep -qE "/usr/local/bin/cipi ${rule}, \\\\\$" "$S" || fail "sudoers: missing 'cipi ${rule//\\/}'"
done
pass "Node runtimes, database links and backup profiles are in the whitelist"
for no in 'backup configure' 'backup destination add' 'backup destination edit' 'backup destination remove' 'backup key' 'backup fetch' 'backup prune' 'backup run,' 'backup run \*' 'backup status,' 'backup \*'; do
    grep -qE "/usr/local/bin/cipi ${no}" "$S" && fail "sudoers: '${no//\\/}' must not be there"
done
pass "not there: backup configure, destination add|edit|remove (an S3 secret on a command line), key, fetch, prune, a run that is not detached"
! grep -E '\* [^,\\]' "$S" | grep -q . && pass "'*' is the last argument everywhere (sudo-rs)" || fail "a rule has something after '*': $(grep -E '\* [^,\\]' "$S")"
if command -v visudo >/dev/null 2>&1; then
    visudo -cqf "$S" >/dev/null 2>&1 && pass "visudo accepts the whitelist" || fail "visudo refuses the whitelist"
else
    pass "(visudo not here: the whitelist was not parsed)"
fi
m=$(cat "${LIB}/migrations/5.9.0.sh")
grep -q '_cipi_panel_installed' <<< "$m" && grep -q 'ensure_cipi_api_sudoers' <<< "$m" && pass "the migration writes the file only where a panel is installed" || fail "migration writes sudoers unconditionally"
grep -q 'visudo -cqf /etc/sudoers.d/cipi-api' <<< "$m" && grep -q 'cat "\$prev" > /etc/sudoers.d/cipi-api' <<< "$m" \
    && pass "a file sudo would refuse is replaced by the previous one" || fail "migration does not guard the sudoers file"

# ── 8. Help and completion ───────────────────────────────────
echo "--- help and completion"
for s in 'cipi deploy <app> --history' 'cipi deploy --last' 'cipi db link <name> <app>' 'cipi db unlink <name>' 'cipi backup run --detach'; do
    grep -qF "\"${s}" "${ROOT}/cipi" || fail "cipi help does not mention: ${s}"
done
pass "cipi help names the new commands"
grep -q 'create list delete link unlink' "${LIB}/completion.sh" && grep -q -- '--last --history' "${LIB}/completion.sh" && grep -q -- '--profile= --dry-run --detach' "${LIB}/completion.sh" \
    && pass "completion knows them" || fail "completion not updated"
grep -q 'link)      _db_link "\$@"' "${LIB}/db.sh" && grep -q 'unlink)    _db_unlink "\$@"' "${LIB}/db.sh" && pass "cipi db dispatches link and unlink" || fail "db dispatcher"

echo ""
echo "=== ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]

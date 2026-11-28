#!/bin/bash
# 5.17.0:
#  - deploys: storage:link, optimize and migrate once (recipe/laravel.php ran
#    them a second time), and a step turned off in deploy-config really
#    skipped — deployer_flow_ensure_hook, lib/deployer/flow.php, migration;
#  - logrotate: "su root adm" in Cipi's shared rules for the logs directly in
#    /var/log (logrotate_cipi_su), so that `cipi pending` stops calling them
#    skipped, and `cipi app fix-permissions` — its hint — does repair it;
#  - webhook deploys: the branch and the commit in the notification (a release
#    of Deployer 7/8 is an archive: no .git to ask);
#  - notifications: `cipi notification timezone` and `server-name`, one
#    notify_now for every "Time:";
#  - Octane: `cipi frankenphp php <app> <X.Y>`, `restart`, the hint for an app
#    on two PHP versions, `cipi app edit --php` moving the build;
#  - `cipi cache`: the nginx page cache per app (fastcgi_cache / proxy_cache),
#    its clear after a deploy, cipi-cache-clear for the app's own user;
#  - the panel's sudoers: cache, valkey, frankenphp php|restart, notification
#    timezone|server-name.
# nginx, systemctl, supervisorctl, curl and Deployer are stubs; the vault,
# git, jq, awk and visudo (when installed) are real.
# Run from repo root: bash tests/verify-5.17.0.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/lib"
PASS=0; FAIL=0
pass() { echo "  OK: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
TMP=$(mktemp -d) && [[ -n "$TMP" && -d "$TMP" ]] || exit 1
BG=()
trap 'for p in "${BG[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null; done; rm -rf "${TMP:?}"' EXIT
echo "=== Cipi 5.17.0 regression checks ==="

v=$(tr -d "[:space:]" < "${ROOT}/version.md"); [[ "$(printf "%s\n%s\n" 5.17.0 "$v" | sort -V | head -1)" == 5.17.0 ]] && pass "version.md >= 5.17.0" || fail "version.md"
grep -q '^## \[5.17.0\]' "${ROOT}/CHANGELOG.md" && pass "CHANGELOG 5.17.0" || fail "CHANGELOG"
for f in "${ROOT}/cipi" "${ROOT}/setup.sh" "${LIB}/common.sh" "${LIB}/app.sh" "${LIB}/cache.sh" "${LIB}/cipi-cache-clear.sh" \
         "${LIB}/frankenphp.sh" "${LIB}/pending.sh" "${LIB}/php.sh" "${LIB}/notifications.sh" "${LIB}/alerts.sh" \
         "${LIB}/deploy.sh" "${LIB}/cipi-app-deploy.sh" "${LIB}/cipi-app-notify.sh" "${LIB}/cipi-auth-notify.sh" \
         "${LIB}/cipi-cron-notify.sh" "${LIB}/cipi-api-sudoers.sh" "${LIB}/completion.sh" "${LIB}/self-update.sh" \
         "${LIB}/sync.sh" "${LIB}/api.sh" "${LIB}/migrations/5.17.0.sh"; do
    bash -n "$f" && pass "$(basename "$f") parses" || fail "$(basename "$f") parse"
done
command -v jq >/dev/null 2>&1 || { echo "  (jq not installed)"; exit 1; }
command -v php >/dev/null 2>&1 && { php -l "${LIB}/deployer/flow.php" >/dev/null 2>&1 || true; }

stubdir() { mkdir -p "$1"; }
mkstub() { cat > "$1"; chmod +x "$1"; }

# ══ 1. one pass per deploy step ══════════════════════════════
echo "--- deploy flow"
F="${LIB}/deployer/flow.php"
grep -q 'cipi:deploy-flow' "$F" && grep -q "'deploy:prepare'" "$F" && grep -q "'deploy:vendors'" "$F" && grep -q "'deploy:publish'" "$F" \
    && pass "flow.php: prepare, vendors, publish" || fail "flow.php"
! grep -qE "'artisan:(migrate|optimize|storage:link|config:cache|route:cache|view:cache|event:cache)'" "$F" \
    && pass "flow.php names none of the recipe's artisan steps: only the hooks run them" || fail "flow.php still lists an artisan step"
grep -q "tasks->has('artisan:reload')" "$F" && pass "flow.php keeps artisan:reload where the recipe has it (Deployer 8), and only there" || fail "artisan:reload"
grep -q 'deployer_flow_ensure_hook "$an"' "${LIB}/app.sh" && grep -q 'deployer_flow_ensure_hook "$app"' "${LIB}/sync.sh" \
    && grep -q 'deployer_flow_ensure_hook "$u"' "${LIB}/migrations/5.17.0.sh" \
    && pass "the flow goes with a new recipe, an imported one, and every existing one (migration)" || fail "flow hook call sites"

D1="${TMP}/flow"; mkdir -p "$D1/home/shop/.deployer" "$D1/home/blog/.deployer" "$D1/home/mine/.deployer" "$D1/home/hand/.deployer" \
    "$D1/home/static/.deployer" "$D1/home/closed/.deployer" "$D1/cfg" "$D1/bin"
printf '%s\n' '{"shop":{"php":"8.5"},"blog":{"php":"8.5","deploy_migrate":"false"},"mine":{"php":"8.5"},"hand":{"php":"8.5"},"static":{"php":"8.5","custom":"true"},"closed":{"php":"8.5"}}' > "$D1/cfg/apps.json"
gen_recipe() {   # <app> <template> <migrate hook line>
    sed -e "s|__CIPI_APP_USER__|$1|g" -e "s|__CIPI_DEPLOY_PATH__|/home/$1|g" -e "s|__CIPI_PHP_VERSION__|8.5|g" \
        -e "s|__CIPI_REPOSITORY__|git@github.com:acme/$1.git|g" -e "s|__CIPI_BRANCH__|main|g" -e "s|__CIPI_KEEP_RELEASES__|5|g" \
        -e "s|__CIPI_SHARED_FILES__|['.env']|g" -e "s|__CIPI_HOOK_STORAGE_LINK__|after('deploy:vendors', 'artisan:storage:link');|g" \
        -e "s|__CIPI_HOOK_MIGRATE__|$3|g" -e "s|__CIPI_HOOK_OPTIMIZE__|after('deploy:vendors', 'artisan:optimize');|g" \
        -e "s|__CIPI_HOOK_HORIZON_TERMINATE__|before('deploy:symlink', 'horizon:terminate');|g" \
        -e "s|__CIPI_HOOK_QUEUE_RESTART__|after('deploy:symlink', 'artisan:queue:restart');|g" \
        -e "s|__CIPI_HOOK_EXTRA_ARTISAN__|// no extra artisan (deploy-config)|g" -e "/__CIPI_EXTRA_ARTISAN_TASK__/d" \
        -e "s|__CIPI_BUILD_TIMEOUT__|1800|g" -e "s|__CIPI_STEP_TIMEOUT__|300|g" "${LIB}/deployer/$2.php"
}
gen_recipe shop laravel "after('deploy:vendors', 'artisan:migrate');" > "$D1/home/shop/.deployer/deploy.php"
gen_recipe blog laravel-octane "// artisan:migrate disabled (deploy-config)" > "$D1/home/blog/.deployer/deploy.php"
{ gen_recipe mine laravel "after('deploy:vendors', 'artisan:migrate');"; printf "task('deploy', ['deploy:prepare', 'deploy:vendors', 'my:step', 'deploy:publish']);\n"; } > "$D1/home/mine/.deployer/deploy.php"
gen_recipe hand laravel "after('deploy:vendors', 'artisan:migrate');" | grep -v "artisan:optimize" > "$D1/home/hand/.deployer/deploy.php"
cp "${LIB}/deployer/custom.php" "$D1/home/static/.deployer/deploy.php"
{ gen_recipe closed laravel "after('deploy:vendors', 'artisan:migrate');"; echo '?>'; } > "$D1/home/closed/.deployer/deploy.php"
FLOWH() {
    CIPI_LIB="$LIB" CIPI_CONFIG="$D1/cfg" CIPI_LOG="$D1/log" D1="$D1" bash -c 'set -uo pipefail
        RED=; GREEN=; YELLOW=; CYAN=; DIM=; NC=; BOLD=
        source "$CIPI_LIB/common.sh" 2>/dev/null
        vault_read() { cat "$D1/cfg/apps.json"; }
        app_read() { cat -- "${2/#\/home\//$D1/home/}" 2>/dev/null; }
        app_append() { cat >> "${2/#\/home\//$D1/home/}"; }
        eval "$(declare -f deployer_flow_ensure_hook | sed "s|\[\[ -f \"\$df\" \]\]|[[ -f \"\${df/#\\\\/home\\\\//\$D1/home/}\" ]]|")"
        '"$1"
}
out=$(FLOWH 'deployer_flow_ensure_hook shop; echo "rc=$?"')
[[ "$out" == "rc=0" ]] && [[ "$(grep -c 'cipi:deploy-flow' "$D1/home/shop/.deployer/deploy.php")" == 1 ]] && pass "a Laravel recipe gets the flow" || fail "shop: ${out}"
tail -n 12 "$D1/home/shop/.deployer/deploy.php" | grep -q "^task('deploy', array_values" && pass "…appended after the hooks, as the last word on the deploy task" || fail "flow not at the end"
FLOWH 'deployer_flow_ensure_hook shop' >/dev/null; [[ "$(grep -c 'cipi:deploy-flow' "$D1/home/shop/.deployer/deploy.php")" == 1 ]] && pass "a second run adds nothing" || fail "flow appended twice"
out=$(FLOWH 'deployer_flow_ensure_hook blog; echo "rc=$?"')
[[ "$out" == "rc=0" ]] && grep -q 'cipi:deploy-flow' "$D1/home/blog/.deployer/deploy.php" && grep -q '^// artisan:migrate disabled (deploy-config)' "$D1/home/blog/.deployer/deploy.php" \
    && pass "an Octane recipe with migrate off gets it too: the recipe's own artisan:migrate no longer runs" || fail "blog: ${out}"
out=$(FLOWH 'deployer_flow_ensure_hook mine; echo "rc=$?"')
[[ "$out" == "rc=2" ]] && ! grep -q 'cipi:deploy-flow' "$D1/home/mine/.deployer/deploy.php" && pass "a deploy.php with its own deploy task is left alone (2)" || fail "mine: ${out}"
out=$(FLOWH 'deployer_flow_ensure_hook hand; echo "rc=$?"')
[[ "$out" == "rc=2" ]] && ! grep -q 'cipi:deploy-flow' "$D1/home/hand/.deployer/deploy.php" && pass "a deploy.php whose hooks were edited by hand is left alone (2): it would lose a step" || fail "hand: ${out}"
out=$(FLOWH 'deployer_flow_ensure_hook static; echo "rc=$?"')
[[ "$out" == "rc=0" ]] && ! grep -q 'cipi:deploy-flow' "$D1/home/static/.deployer/deploy.php" && pass "a custom app has no such flow" || fail "static: ${out}"
out=$(FLOWH 'deployer_flow_ensure_hook closed; echo "rc=$?"')
[[ "$out" == "rc=1" ]] && ! grep -q 'cipi:deploy-flow' "$D1/home/closed/.deployer/deploy.php" && pass "a deploy.php closed with ?> is not appended to (1)" || fail "closed: ${out}"
if command -v php >/dev/null 2>&1; then
    php -l "$D1/home/shop/.deployer/deploy.php" >/dev/null 2>&1 && php -l "$D1/home/blog/.deployer/deploy.php" >/dev/null 2>&1 \
        && pass "the recipes with the flow are valid PHP" || fail "php -l on a recipe with the flow"
fi
# With the real Deployer, when it is on this machine: one of each.
DEP=""; for c in /usr/local/bin/dep "${CIPI_TEST_DEP:-}"; do [[ -n "$c" && -f "$c" ]] && DEP="$c" && break; done
if [[ -n "$DEP" ]] && command -v php >/dev/null 2>&1 && tree=$(cd "$TMP" && php "$DEP" tree deploy -f "$D1/home/shop/.deployer/deploy.php" 2>/dev/null) && [[ -n "$tree" ]]; then
    [[ "$(grep -c 'artisan:migrate' <<< "$tree")" == 1 && "$(grep -c 'artisan:optimize' <<< "$tree")" == 1 && "$(grep -c 'artisan:storage:link' <<< "$tree")" == 1 ]] \
        && pass "Deployer's own task tree: storage:link, migrate and optimize once each" || fail "task tree: $(grep -c 'artisan:migrate' <<< "$tree") migrate, $(grep -c 'artisan:optimize' <<< "$tree") optimize"
    tree2=$(cd "$TMP" && php "$DEP" tree deploy -f "$D1/home/blog/.deployer/deploy.php" 2>/dev/null)
    ! grep -q 'artisan:migrate' <<< "$tree2" && grep -q 'cipi:frankenphp' <<< "$tree2" && pass "Deployer's own task tree: migrate off means no artisan:migrate at all" || fail "task tree with migrate off"
else
    echo "  (Deployer is not on this machine: its task tree is not checked — CIPI_TEST_DEP=/path/to/deployer.phar)"
fi

# ══ 2. logrotate: su for the logs directly in /var/log ═══════
echo "--- logrotate"
LR="${TMP}/lr"; mkdir -p "$LR/d"
cat > "$LR/d/cipi-app-logs" <<'EOF'
/var/log/cipi-apps/*/worker-*.log
/var/log/cipi-apps/*/deploy.log
/var/log/cipi/*.log
/var/log/cipi-queue.log {
    daily
    missingok
    copytruncate
}
EOF
cat > "$LR/d/cipi-http-logs" <<'EOF'
/var/log/cipi-apps/*/nginx-access.log
/var/log/nginx/*.log {
    daily
    sharedscripts
    postrotate
        [ -f /var/run/nginx.pid ] && kill -USR1 $(cat /var/run/nginx.pid) 2>/dev/null || true
    endscript
}
EOF
cat > "$LR/d/cipi-security-logs" <<'EOF'
/var/log/fail2ban.log {
    daily
    create 0640 root adm
    postrotate
        f() {
            fail2ban-client flushlogs >/dev/null 2>&1 || true
        }
        f
    endscript
}
/var/log/ufw.log {
    daily
    create 0640 syslog adm
}
# kept as it is
/var/log/auth.log
{
    su root syslog
    daily
}
EOF
printf '/home/shop/logs/php-fpm-*.log {\n    su shop shop\n    daily\n}\n' > "$LR/d/cipi-home-shop"
printf '/var/log/other.log {\n    daily\n}\n' > "$LR/d/rsyslog"
cp -r "$LR/d" "$LR/before"
LRH() { CIPI_LOGROTATE_D="$LR/d" bash -c 'install() { local a=(); for x in "$@"; do case "$x" in -o|-g) skip=1 ;; *) if [[ -n "${skip:-}" ]]; then skip=; else a+=("$x"); fi ;; esac; done; command install "${a[@]}"; }
    source <(sed -n "/^logrotate_cipi_su() {/,/^}/p" "'"${LIB}"'/common.sh"); '"$1"; }
out=$(LRH 'logrotate_cipi_su' | sort | paste -sd' ' -)
[[ "$out" == "cipi-app-logs cipi-security-logs" ]] && pass "the two rules with a log directly in /var/log are rewritten, and named" || fail "changed: ${out}"
grp=adm; getent group adm >/dev/null 2>&1 || grp=root
[[ "$(grep -c "^    su root ${grp}\$" "$LR/d/cipi-security-logs")" == 2 ]] && pass "fail2ban.log and ufw.log get su root ${grp}" || fail "security-logs: $(grep -n 'su ' "$LR/d/cipi-security-logs")"
[[ "$(sed -n 2p "$LR/d/cipi-security-logs")" == "    su root ${grp}" ]] && pass "…as the first line of the block" || fail "position: $(sed -n 1,3p "$LR/d/cipi-security-logs")"
grep -q '^    su root syslog$' "$LR/d/cipi-security-logs" && [[ "$(grep -c 'su root' "$LR/d/cipi-security-logs")" == 3 ]] && pass "a block with its own su line keeps it (and a { on a line of its own is read)" || fail "auth.log block"
[[ "$(grep -c 'su root' "$LR/d/cipi-app-logs")" == 1 ]] && pass "cipi-app-logs (cipi-queue.log): one su line for its block" || fail "app-logs"
cmp -s "$LR/before/cipi-http-logs" "$LR/d/cipi-http-logs" && pass "a rule with no log directly in /var/log is not touched (nginx's directory is not group-writable)" || fail "http-logs changed"
cmp -s "$LR/before/cipi-home-shop" "$LR/d/cipi-home-shop" && cmp -s "$LR/before/rsyslog" "$LR/d/rsyslog" && pass "the per-app rules and other packages' rules are not read" || fail "home rule or foreign rule changed"
diff <(grep -v 'su root' "$LR/d/cipi-security-logs") <(grep -v 'su root syslog' "$LR/before/cipi-security-logs") >/dev/null \
    && pass "nothing else in the file changes: a } inside a postrotate script does not end the block" || fail "security-logs differs beyond the su lines"
[[ -z "$(LRH 'logrotate_cipi_su')" ]] && pass "a second run changes nothing" || fail "not idempotent"
for b in fail2ban ufw auth; do
    awk -v p="/var/log/${b}.log {" '$0 == p { getline; print; exit }' "${ROOT}/setup.sh" | grep -q '^    su root adm$' || fail "setup.sh: ${b}.log block has no su line"
done
pass "setup.sh writes the security rule with su root adm"
awk '/\/var\/log\/cipi-queue.log \{/ { getline; print; exit }' "${ROOT}/setup.sh" | grep -q 'su root adm' && pass "setup.sh: cipi-queue.log too" || fail "setup.sh cipi-app-logs"
[[ "$(grep -c '^    su root adm$' "${LIB}/api.sh")" -ge 2 ]] && pass "the panel's own rules (cipi-api-maintain, cipi-api-update) too" || fail "api.sh rules"
grep -q '"cipi app fix-permissions   (it rewrites' "${LIB}/pending.sh" && grep -q 'lr_fixed=$(logrotate_cipi_su' "${LIB}/app.sh" \
    && pass "cipi pending names cipi app fix-permissions, and that command now rewrites the rules" || fail "pending hint / fix-permissions"
awk '/^app_fix_permissions\(\)/, /^}/' "${LIB}/app.sh" | awk '/logrotate_cipi_su/ { a = NR } /info "No apps"/ && !b { b = NR } END { exit !(a && b && a < b) }' \
    && pass "…on a server without apps as well" || fail "fix-permissions returns before the rules when there are no apps"

# ══ 3. webhook deploy: branch and commit ═════════════════════
echo "--- webhook deploy notification"
APP=demoapp
H="${TMP}/home/${APP}"; S="${TMP}/stub"; L="${TMP}/deploy.log"
mkdir -p "$H/.deployer" "$H/.dep" "$H/releases" "$S"; : > "$L"
git init -q -b release/2026 "${TMP}/src" && git -C "${TMP}/src" -c user.email=dev@example.test -c user.name="Ada Dev" commit -q --allow-empty -m "Fix the cart total"
git clone -q --bare "${TMP}/src" "$H/.dep/repo"
cat > "$H/.deployer/deploy.php" <<EOF
<?php
namespace Deployer;
require 'recipe/laravel.php';
set('repository', '${H}/.dep/repo');
set('branch', 'release/2026');
set('git_ssh_command', 'ssh -o StrictHostKeyChecking=accept-new');
EOF
mkstub "${S}/dep" <<'EOF'
#!/bin/bash
cd "$STUB_HOME" || exit 1
n=$(( $(cat .dep/latest_release 2>/dev/null || echo 0) + 1 )); echo "$n" > .dep/latest_release
mkdir -p "releases/$n"; git --git-dir=.dep/repo rev-parse "refs/heads/release/2026" > "releases/$n/REVISION"
echo "task deploy:vendors"; echo "task artisan:migrate"
ln -sfn "releases/$n" current; echo "successfully deployed!"
EOF
mkstub "${S}/sudo" <<EOF
#!/bin/bash
[[ "\$1" == -n ]] && exit 1
if [[ "\$1" == */cipi-app-notify ]]; then printf '%s\n' "\$6" > "${TMP}/notify.detail"; echo "\$3" > "${TMP}/notify.label"; fi
exit 0
EOF
sed -e "s|HOME_DIR=\"/home/\${APP}\"|HOME_DIR=\"${H}\"|" \
    -e "s|LOG=\"/var/log/cipi-apps/\${APP}/deploy.log\"|LOG=\"${L}\"|" \
    -e "s|\"/usr/bin/php\${PHP_VER}\" /usr/local/bin/dep|bash \"${S}/dep\"|" \
    -e "s|sudo /usr/local/bin/|\"${S}/sudo\" /usr/local/bin/|g; s|sudo -n|\"${S}/sudo\" -n|g" \
    -e "s|pgrep -u \"\$APP\"|pgrep -u \"\$(id -u)\"|" \
    -e "s|\"\$(id -un)\" != \"\$APP\"|-z x|" \
    "${LIB}/cipi-app-deploy.sh" > "${TMP}/cipi-app-deploy"
export STUB_HOME="$H"
echo '{"source":"github"}' > "$H/.deploy-trigger.run"
bash "${TMP}/cipi-app-deploy" "$APP" 8.5 webhook; r=$?
[[ $r -eq 0 && "$(readlink "$H/current")" == releases/1 && ! -d "$H/current/.git" ]] && pass "a deploy whose release is an archive (no .git, a REVISION)" || fail "stub deploy: exit ${r}"
grep -qx 'Branch: release/2026' "${TMP}/notify.detail" 2>/dev/null && pass "the notification names the branch (it said: Branch: ?)" || fail "branch: $(grep '^Branch' "${TMP}/notify.detail" 2>/dev/null)"
grep -q 'deploy start  app=demoapp trigger=github branch=release/2026 ' "$L" && pass "…and so does the deploy log (branch=release/2026)" || fail "log: $(grep 'deploy start' "$L")"
sha=$(git --git-dir="$H/.dep/repo" rev-parse --short refs/heads/release/2026)
grep -qx "Commit: ${sha} — Fix the cart total" "${TMP}/notify.detail" && grep -qx 'Author: Ada Dev' "${TMP}/notify.detail" \
    && pass "…and the commit, read from REVISION and Deployer's mirror of the repository" || fail "commit: $(grep -E '^(Commit|Author)' "${TMP}/notify.detail" 2>/dev/null)"
grep -qx 'Trigger: github' "${TMP}/notify.detail" && grep -q '^Release: none -> 1$' "${TMP}/notify.detail" && pass "trigger and release as before" || fail "detail: $(head -5 "${TMP}/notify.detail")"
# a recipe without a branch line falls back to a checkout, then to "?"
sed -i "/set('branch'/d" "$H/.deployer/deploy.php"; rm -f "${TMP}/notify.detail"
bash "${TMP}/cipi-app-deploy" "$APP" 8.5 webhook
grep -qx 'Branch: ?' "${TMP}/notify.detail" && pass "no branch in the recipe and no checkout: still \"?\", not a guess" || fail "fallback: $(grep '^Branch' "${TMP}/notify.detail")"
grep -q 'REVISION" 2>/dev/null < /dev/null | tr -cd' "${LIB}/deploy.sh" && grep -q 'git --git-dir="${home}/.dep/repo"' "${LIB}/deploy.sh" \
    && pass "cipi deploy reads the commit the same way (as the app user)" || fail "deploy.sh _deploy_commit_info"

# ══ 4. notifications: time zone, server name ═════════════════
echo "--- notification settings"
NB="${TMP}/nbin"; NS="${TMP}/nstate"; NC_="${TMP}/ncfg"; mkdir -p "$NB" "$NS" "$NC_" "${TMP}/nlog"
head -c 32 /dev/urandom | base64 > "${NC_}/.vault_key"
mkstub "$NB/hostname" <<'EOF'
#!/bin/bash
echo vmi12334
EOF
mkstub "$NB/curl" <<'EOF'
#!/bin/bash
url=""; data=""
while [[ $# -gt 0 ]]; do case "$1" in -d|--data-binary) data="$2"; shift ;; http*) url="$1" ;; esac; shift; done
[[ "$data" == "@-" ]] && data=$(cat)
printf '%s\n' "$data" > "$STATE/last.body"; echo "$url" >> "$STATE/requests"
EOF
mkstub "$NB/timedatectl" <<'EOF'
#!/bin/bash
echo "Etc/UTC"
EOF
N() {
    PATH="${NB}:${PATH}" STATE="$NS" CIPI_LIB="$LIB" CIPI_CONFIG="$NC_" CIPI_LOG="${TMP}/nlog" TZ=UTC \
    bash -c 'set -euo pipefail
             RED=""; GREEN=""; YELLOW=""; CYAN=""; DIM=""; NC=""; BOLD=""
             source "$CIPI_LIB/common.sh"
             log_action() { :; }; log_event() { :; }
             source "$CIPI_LIB/notifications.sh"; source "$CIPI_LIB/alerts.sh"; source "$CIPI_LIB/smtp.sh"
             '"$1" < /dev/null
}
[[ "$(N 'notify_now -d "@1764169429"')" == "2025-11-26 15:03:49 UTC" ]] && pass "notify_now: the server's zone, with its name" || fail "notify_now: $(N 'notify_now -d "@1764169429"')"
if [[ -f /usr/share/zoneinfo/Europe/Rome ]]; then
    out=$(N 'notifications_command timezone Europe/Rome' 2>&1); rc=$?
    [[ $rc -eq 0 ]] && grep -q 'written in Europe/Rome' <<< "$out" && pass "notification timezone Europe/Rome" || fail "timezone set: ${out}"
    [[ "$(N 'notify_now -d "@1764169429"')" == "2025-11-26 16:03:49 CET" ]] && pass "…the same moment reads 16:03:49 CET" || fail "notify_now Rome: $(N 'notify_now -d "@1764169429"')"
    [[ "$(N 'date -d "@1764169429" "+%H:%M %Z"')" == "15:03 UTC" ]] && pass "…and nothing else of the process changes zone (date is still the server's)" || fail "TZ leaked"
    N 'notifications_command timezone --json' | jq -e '.timezone == "Europe/Rome" and .server_timezone == "Etc/UTC" and (.now | test("CET$"))' >/dev/null \
        && pass "timezone --json: the zone, the server's, now" || fail "timezone --json"
    N 'notifications_command status --json' | jq -e '.settings.timezone == "Europe/Rome" and .settings.hostname == "vmi12334" and .settings.server_name == null' >/dev/null \
        && pass "notification status --json has the settings" || fail "status --json settings"
    out=$(N 'notifications_command timezone server' 2>&1)
    [[ "$(N 'notify_now -d "@1764169429"')" == "2025-11-26 15:03:49 UTC" ]] && N 'vault_read notifications.json' | jq -e 'has("timezone") | not' >/dev/null \
        && pass "timezone server: back to the server's own" || fail "timezone server: ${out}"
else
    echo "  (no /usr/share/zoneinfo/Europe/Rome here: the zone change is not checked)"
fi
for bad in 'Mars/Olympus' '../../etc/passwd' 'Europe/Rome;id' '/etc/localtime' ''"'"'x'; do
    out=$(N 'notifications_command timezone "$0"' 2>&1 <<< "" ; true)
    out=$(PATH="${NB}:${PATH}" STATE="$NS" CIPI_LIB="$LIB" CIPI_CONFIG="$NC_" CIPI_LOG="${TMP}/nlog" BAD="$bad" bash -c 'set -euo pipefail; RED=""; GREEN=""; YELLOW=""; CYAN=""; DIM=""; NC=""; BOLD=""
        source "$CIPI_LIB/common.sh"; log_action() { :; }; source "$CIPI_LIB/notifications.sh"; notifications_command timezone "$BAD"' 2>&1 < /dev/null); rc=$?
    [[ $rc -ne 0 ]] && grep -q 'Unknown time zone' <<< "$out" || fail "timezone accepted '${bad}': rc=${rc} ${out}"
done
pass "an unknown zone, a path and a zone with a command in it are refused"
N 'vault_read notifications.json' 2>/dev/null | jq -e '(.timezone // null) == null' >/dev/null && pass "…and nothing was saved" || fail "a refused zone was saved"

out=$(N 'notifications_command server-name production' 2>&1); rc=$?
[[ $rc -eq 0 ]] && grep -q "name this server 'production'" <<< "$out" && pass "notification server-name production" || fail "server-name: ${out}"
for bad in 'bad;name' 'a"b' '$(id)' ' lead' 'x/y' "$(printf 'a%.0s' {1..41})"; do
    out=$(PATH="${NB}:${PATH}" STATE="$NS" CIPI_LIB="$LIB" CIPI_CONFIG="$NC_" CIPI_LOG="${TMP}/nlog" BAD="$bad" bash -c 'set -euo pipefail; RED=""; GREEN=""; YELLOW=""; CYAN=""; DIM=""; NC=""; BOLD=""
        source "$CIPI_LIB/common.sh"; log_action() { :; }; source "$CIPI_LIB/notifications.sh"; notifications_command server-name "$BAD"' 2>&1 < /dev/null); rc=$?
    [[ $rc -ne 0 ]] && grep -q 'Invalid name' <<< "$out" || fail "server-name accepted '${bad}'"
done
pass "a name with ; \" \$( / a leading space or 41 characters is refused"
[[ "$(N '_notify_server_name')" == "production" ]] && pass "…and the name before them is kept" || fail "name after refusals: $(N '_notify_server_name')"
N 'notifications_command add webhook hook --url=https://example.test/hook' >/dev/null 2>&1
N 'cipi_notify "Cipi deploy succeeded: shop (vmi12334)" "Deploy done.\n\nServer: vmi12334\nSee https://vmi12334.contaboserver.net/x, vmi12334-db, xvmi12334 and on vmi12334." deploy_success' >/dev/null 2>&1
body="${NS}/last.body"
jq -e '.server == "vmi12334" and .server_name == "production"' "$body" >/dev/null && pass "webhook payload: server stays the hostname, server_name is the name" || fail "payload: $(cat "$body")"
jq -e '.subject == "Cipi deploy succeeded: shop (production)"' "$body" >/dev/null && pass "the subject carries the name" || fail "subject: $(jq -r .subject "$body")"
jq -e '.body | contains("Server: production (vmi12334)") and contains("on production (vmi12334).")' "$body" >/dev/null && pass "the body carries the name and the hostname" || fail "body: $(jq -r .body "$body")"
jq -e '.body | contains("https://vmi12334.contaboserver.net/x") and contains(" vmi12334-db,") and contains("xvmi12334 ")' "$body" >/dev/null \
    && pass "a domain, or a longer name, that starts with the hostname is left as it is" || fail "body mangled: $(jq -r .body "$body")"
N 'notifications_command server-name --clear' >/dev/null 2>&1
N 'cipi_notify "Cipi test (vmi12334)" "Server: vmi12334" deploy_success' >/dev/null 2>&1
jq -e '.server_name == null and .subject == "Cipi test (vmi12334)"' "$body" >/dev/null && pass "server-name --clear: the hostname again" || fail "after clear: $(cat "$body")"
left=$(grep -n "Time: \$(date " "${LIB}"/*.sh | grep -v '^.*notify_now' || true)
[[ -z "$left" ]] && [[ "$(grep -c 'notify_now' "${LIB}"/*.sh | awk -F: '{ s += $2 } END { print s }')" -ge 120 ]] \
    && pass "every \"Time:\" of a notification comes from notify_now" || fail "still its own date: ${left}"
grep -q 'NOTIFY_TIME=$(notify_now -d "@${EPOCH}"' "${LIB}/cipi-auth-notify.sh" && grep -q 'at ${NOW}\.' "${LIB}/cipi-app-notify.sh" && grep -q 'notify_now 2>/dev/null' "${LIB}/cipi-cron-notify.sh" \
    && pass "the PAM, deploy-webhook and cron helpers too (their time had no zone at all)" || fail "helpers"

# ══ 5. Octane: one PHP for the app, by its number ════════════
echo "--- frankenphp php"
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
rewrite "${LIB}/migrations/5.17.0.sh" > "${LIBT}/migrations/5.17.0.sh"
cp "${LIB}"/deployer/*.php "${LIBT}/deployer/"
stub() { cat > "${BIN}/$1"; chmod +x "${BIN}/$1"; }
stub runuser <<'EOF'
#!/bin/bash
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
    -u)  /usr/bin/id -u ;;
    -nG) echo root ;;
    -gn) echo root ;;
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
exit 1
EOF
stub dpkg <<'EOF'
#!/bin/bash
# dpkg -l php<X.Y>-fpm: installed when $STATE/php.<X.Y> is there
p="${@: -1}"; v="${p#php}"; v="${v%-fpm}"
[ -f "$STATE/php.$v" ]
EOF
stub crontab <<'EOF'
#!/bin/bash
cat >/dev/null 2>&1 < /dev/null || true
exit 0
EOF
stub supervisorctl <<'EOF'
#!/bin/bash
S="$STATE"; echo "supervisorctl $*" >> "$S/supervisorctl.log"
case "$1" in
    status)
        p="$2"; st=RUNNING
        if [ -f "$S/bad.builds" ]; then
            a="${p%-octane}"; b=$(basename "$(readlink "$FRANKENPHP_ROOT/apps/$a" 2>/dev/null)" 2>/dev/null)
            grep -qx "$b" "$S/bad.builds" 2>/dev/null && st=FATAL
        fi
        echo "$p  $st  pid 123, uptime 0:00:01" ;;
esac
exit 0
EOF
stub systemctl <<'EOF'
#!/bin/bash
echo "systemctl $*" >> "$STATE/systemctl.log"; exit 0
EOF
stub curl <<'EOF'
#!/bin/bash
S="$STATE"; out=""; url=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift ;;
        -w|-H|-m|--max-time) shift ;;
        -*) ;;
        *) url="$1" ;;
    esac
    shift
done
echo "curl $url" >> "$S/curl.log"
case "$url" in
    */releases/latest) [ -f "$S/gh.latest" ] || exit 22; cat "$S/gh.latest" ;;
    https://dl.test/*) n="${url##*/}"; [ -f "$S/dl/$n" ] || exit 22; cp "$S/dl/$n" "$out" ;;
    http://127.0.0.1:*) printf '200' ;;
esac
exit 0
EOF
mkfphp() {
    cat > "$1" <<EOF
#!/bin/bash
# fake frankenphp $2 / $3 $(date +%s%N)
case "\$1" in
    -v) echo "FrankenPHP v$2 PHP $3 Caddy v2.10.2 h1:abc" ;;
esac
EOF
    chmod 755 "$1"
}
mkdir -p "${STATE}/dl"
gh_release() {   # <tag> <php>
    local tag="$1" php="$2" f="${STATE}/dl/frankenphp-${1}" sum
    mkfphp "$f" "${tag#v}" "$php"
    sum=$(sha256sum "$f" | awk '{print $1}')
    jq -n --arg t "$tag" --arg u "https://dl.test/frankenphp-${tag}" --arg d "sha256:${sum}" \
        '{tag_name: $t, assets: [{name: "frankenphp-linux-x86_64-gnu", browser_download_url: $u, digest: $d},
                                 {name: "frankenphp-linux-aarch64-gnu", browser_download_url: $u, digest: $d}]}' > "${STATE}/gh.latest"
}
CFG="${FAKE}/etc/cipi"; mkdir -p "$CFG" "${FAKE}/etc/supervisor/conf.d" "${FAKE}/var/lib/cipi" "${FAKE}/var/log/cipi"
head -c 32 /dev/urandom | base64 > "${CFG}/.vault_key"
FROOT="${FAKE}/opt/cipi-frankenphp"
L5() {
    PATH="${BIN}:${PATH}" STATE="$STATE" FAKE="$FAKE" CIPI_LIB="$LIBT" CIPI_CONFIG="$CFG" CIPI_LOG="${FAKE}/var/log/cipi" \
        FRANKENPHP_ROOT="$FROOT" FRANKENPHP_PROC="${STATE}/proc" FRANKENPHP_VERIFY_TRIES=3 \
        FRANKENPHP_GITHUB_API="https://api.github.test/repos/php/frankenphp" \
        bash -c 'set -euo pipefail
                 RED=""; GREEN=""; YELLOW=""; CYAN=""; DIM=""; NC=""; BOLD=""
                 source "$CIPI_LIB/common.sh"
                 cipi_notify() { echo "NOTIFY [$3] $1" >> "$STATE/notify.log"; }
                 reload_supervisor() { :; }; reload_php_fpm() { :; }
                 _create_supervisor_octane() { printf "[program:%s-octane]\ncommand=/usr/bin/php%s artisan octane:start\n" "$1" "$2" >> "$FAKE/etc/supervisor/conf.d/$1.conf"; }
                 _supervisor_remove_program() { : > "$FAKE/etc/supervisor/conf.d/$1.conf"; }
                 '"$1" < /dev/null
}
FP() { L5 'source "$CIPI_LIB/app.sh"; source "$CIPI_LIB/frankenphp.sh"; '"$1"; }
cat > "${CFG}/apps.json" <<'EOF'
{
  "gameportal": {"php": "8.5", "octane": "frankenphp", "octane_port": "8101", "domain": "game.test"},
  "shop":       {"php": "8.5", "octane": "frankenphp", "octane_port": "8102", "domain": "shop.test"},
  "blog":       {"php": "8.5", "domain": "blog.test"}
}
EOF
for a in gameportal shop; do
    mkdir -p "${FAKE}/home/${a}/releases/1" "${FAKE}/home/${a}/.deployer" "${FAKE}/home/${a}/shared"
    ln -sfn "${FAKE}/home/${a}/releases/1" "${FAKE}/home/${a}/current"
    printf '[program:%s-octane]\ncommand=/usr/bin/php8.5 artisan octane:start\n' "$a" > "${FAKE}/etc/supervisor/conf.d/${a}.conf"
    printf "<?php\nset('bin/php', '/usr/bin/php8.5');\nset('bin/composer', '/usr/bin/php8.5 /usr/local/bin/composer');\n" > "${FAKE}/home/${a}/.deployer/deploy.php"
    printf 'export PATH\nalias php=php8.5\n' > "${FAKE}/home/${a}/.bashrc"
    printf 'APP_NAME=x\nCIPI_PHP_VERSION=8.5\n' > "${FAKE}/home/${a}/shared/.env"
done
for v in 8.5 8.6; do mkdir -p "${FAKE}/etc/php/${v}/fpm/pool.d"; : > "${STATE}/php.${v}"; done
: > "${STATE}/notify.log"

# The case of the report: the app on 8.5, Octane on a build Octane downloaded
# when the release already carried PHP 8.6.
mkfphp "${FAKE}/home/gameportal/releases/1/frankenphp" 1.14.0 8.6.0
B86=$(FP 'fphp_adopt gameportal' 2>/dev/null)
[[ "$B86" == 1.14.0-php8.6.0-* ]] && pass "gameportal (PHP 8.5) runs a build with PHP 8.6.0 inside: ${B86}" || fail "adopt: ${B86}"
[[ "$(FP 'fphp_app_state gameportal' | cut -d' ' -f1)" == "mismatch" ]] && pass "state: mismatch" || fail "state: $(FP 'fphp_app_state gameportal')"
[[ -z "$(FP 'fphp_candidate gameportal "$(fphp_app_build gameportal)"')" ]] && pass "no build on PHP 8.5 on the server: cipi frankenphp upgrade — the old hint — has nothing to move it to" || fail "candidate"
fix=$(FP 'fphp_mismatch_fix gameportal')
[[ "$(cut -f1 <<< "$fix")" == "cipi frankenphp php gameportal 8.6" ]] && grep -q 'no FrankenPHP build on PHP 8.5' <<< "$fix" \
    && pass "the hint names the command that works, and the version: cipi frankenphp php gameportal 8.6" || fail "fix: ${fix}"
out=$(L5 'source "$CIPI_LIB/pending.sh"; source "$CIPI_LIB/frankenphp.sh"; PENDING_ITEMS=(); _pending_frankenphp; printf "%s\n" "${PENDING_ITEMS[@]}"')
grep -q 'frankenphp-gameportal-php' <<< "$out" && grep -q 'cipi frankenphp php gameportal 8.6' <<< "$out" && ! grep -q 'cipi frankenphp upgrade gameportal' <<< "$out" \
    && pass "cipi pending: the same command, not cipi frankenphp upgrade" || fail "pending: ${out}"
grep -q 'Octane answers requests on PHP 8.6.0' <<< "$out" && grep -q 'Composer, artisan, cron and the workers run PHP 8.5' <<< "$out" && pass "…and says what runs on which PHP" || fail "pending text: ${out}"
j=$(FP '_fphp_status --json')
jq -e '.apps[] | select(.app == "gameportal") | .state == "mismatch" and .fix.command == "cipi frankenphp php gameportal 8.6" and .available_php == ["8.6"]' <<< "$j" >/dev/null \
    && pass "frankenphp status --json: fix and available_php per app" || fail "status json: $(jq -c '.apps' <<< "$j")"
jq -e '.apps[] | select(.app == "shop") | .fix == null' <<< "$j" >/dev/null && pass "…fix is null for an app that is not on two versions" || fail "shop fix"
j=$(FP '_fphp_php gameportal --json')
jq -e '.php == "8.5" and .octane_php == "8.6.0" and .state == "mismatch" and (.build | startswith("1.14.0-php8.6.0"))' <<< "$j" >/dev/null && pass "frankenphp php <app> --json: the two versions" || fail "php --json: ${j}"

# cipi frankenphp php gameportal 8.6: the build stays, the rest moves.
: > "${STATE}/supervisorctl.log"
out=$(FP '_fphp_php gameportal 8.6 --yes --no-fetch' 2>&1); rc=$?
[[ $rc -eq 0 ]] && grep -q "is on PHP 8.6" <<< "$out" && pass "frankenphp php gameportal 8.6" || fail "php 8.6: rc=${rc} ${out}"
[[ "$(jq -r '.gameportal.php' <(L5 'vault_read apps.json'))" == "8.6" ]] && pass "…the app is on 8.6" || fail "apps.json php"
grep -q "php8.6" "${FAKE}/home/gameportal/.deployer/deploy.php" && ! grep -q "php8.5" "${FAKE}/home/gameportal/.deployer/deploy.php" \
    && grep -q '^CIPI_PHP_VERSION=8.6$' "${FAKE}/home/gameportal/shared/.env" && grep -q '/usr/bin/php8.6' "${FAKE}/etc/supervisor/conf.d/gameportal.conf" \
    && pass "…Composer, artisan and the workers with it (deploy.php, .env, supervisor)" || fail "the rest did not move"
[[ "$(FP 'fphp_app_build gameportal')" == "$B86" ]] && ! grep -q 'restart gameportal-octane' "${STATE}/supervisorctl.log" \
    && pass "…Octane keeps its build and is not restarted: it was on 8.6 already" || fail "build changed or restarted"
[[ "$(FP 'fphp_app_state gameportal' | cut -d' ' -f1)" == "ok" ]] && pass "state: ok" || fail "state after: $(FP 'fphp_app_state gameportal')"
grep -q 'NOTIFY \[frankenphp_upgrade\] Cipi FrankenPHP: gameportal on PHP 8.6' "${STATE}/notify.log" && pass "notified" || fail "notify: $(cat "${STATE}/notify.log")"
out=$(FP '_fphp_php gameportal 8.6 --yes --no-fetch' 2>&1)
grep -q 'is on PHP 8.6 already' <<< "$out" && pass "a second time: already there, nothing done" || fail "idempotent: ${out}"

# shop: on 8.5 with a build on 8.5; to 8.6 the release GitHub publishes is fetched.
mkfphp "${TMP}/b85" 1.13.2 8.5.13
B85=$(FP '_fphp_import '"${TMP}/b85" 2>&1 | grep -oE '1\.13\.2-php8\.5\.13-[0-9a-f]+' | head -1)
FP 'fphp_app_set shop '"$B85"; FP 'fphp_release_link shop' >/dev/null 2>&1
gh_release v1.14.1 8.6.1
out=$(FP '_fphp_php shop 8.4 --yes' 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q 'PHP 8.4 is not installed' <<< "$out" && pass "a PHP the server does not have: refused, with cipi php install" || fail "8.4 not installed: ${out}"
: > "${STATE}/php.8.4"
out=$(FP '_fphp_php shop 8.4 --yes' 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q "No FrankenPHP build on PHP 8.4 for 'shop'" <<< "$out" && grep -q 'carries PHP 8.6.1' <<< "$out" && grep -q 'cipi frankenphp import' <<< "$out" \
    && pass "no build carries 8.4: refused, saying what the release carries and how to add one" || fail "8.4 no build: rc=${rc} ${out}"
[[ "$(jq -r '.shop.php' <(L5 'vault_read apps.json'))" == "8.5" && "$(FP 'fphp_app_build shop')" == "$B85" ]] && pass "…and nothing changed: the app on 8.5, Octane on its build" || fail "changed after a refusal"
out=$(FP '_fphp_php shop 9.9 --yes' 2>&1); [[ $? -ne 0 ]] && grep -q 'Invalid PHP version' <<< "$out" && pass "an invalid version is refused" || fail "9.9: ${out}"
out=$(FP '_fphp_php blog 8.6 --yes' 2>&1); [[ $? -ne 0 ]] && grep -q 'does not run on Octane' <<< "$out" && pass "an app that is not on Octane is refused" || fail "blog: ${out}"

: > "${STATE}/supervisorctl.log"
out=$(FP '_fphp_php shop 8.6 --yes' 2>&1); rc=$?
NEW="1.14.1-php8.6.1"
[[ $rc -eq 0 && "$(FP 'fphp_app_build shop')" == "$NEW" ]] && pass "frankenphp php shop 8.6: the release is fetched and pinned (${NEW})" || fail "shop 8.6: rc=${rc} build=$(FP 'fphp_app_build shop') ${out}"
[[ "$(jq -r '.shop.php' <(L5 'vault_read apps.json'))" == "8.6" ]] && grep -q 'restart shop-octane\|update' "${STATE}/supervisorctl.log" && pass "…Octane restarted on it, the app on 8.6" || fail "shop not moved"
# back to 8.5 with the build that is still on the server, through cipi app edit
out=$(FP 'app_edit shop --php=8.5' 2>&1); rc=$?
[[ $rc -eq 0 && "$(FP 'fphp_app_build shop')" == "$B85" && "$(jq -r '.shop.php' <(L5 'vault_read apps.json'))" == "8.5" ]] \
    && pass "cipi app edit shop --php=8.5 moves the build too (back to ${B85})" || fail "app edit 8.5: rc=${rc} build=$(FP 'fphp_app_build shop') ${out}"
! grep -q 'Octane still answers' <<< "$out" && pass "…no \"Octane still answers on\" warning left behind" || fail "warning: ${out}"
# Octane does not come up on the new build: back to the old one, nothing else moved
echo "$NEW" > "${STATE}/bad.builds"
out=$(FP 'app_edit shop --php=8.6' 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q "PHP not changed" <<< "$out" && [[ "$(FP 'fphp_app_build shop')" == "$B85" && "$(jq -r '.shop.php' <(L5 'vault_read apps.json'))" == "8.5" ]] \
    && grep -q 'php8.5' "${FAKE}/home/shop/.deployer/deploy.php" \
    && pass "Octane does not answer on the new build: it goes back to its own, and the app stays on 8.5 everywhere" || fail "failed switch: rc=${rc} build=$(FP 'fphp_app_build shop') ${out}"
rm -f "${STATE}/bad.builds"
# no build for the version: app edit refuses before changing; --force moves the rest alone
out=$(FP 'app_edit shop --php=8.4' 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q 'No FrankenPHP build on PHP 8.4' <<< "$out" && grep -q -- '--force' <<< "$out" && [[ "$(jq -r '.shop.php' <(L5 'vault_read apps.json'))" == "8.5" ]] \
    && pass "cipi app edit --php with no build for it: refused before anything changes" || fail "app edit 8.4: rc=${rc} ${out}"
out=$(FP 'app_edit shop --php=8.4 --force' 2>&1); rc=$?
[[ $rc -eq 0 && "$(jq -r '.shop.php' <(L5 'vault_read apps.json'))" == "8.4" && "$(FP 'fphp_app_build shop')" == "$B85" ]] && grep -q 'cipi frankenphp php shop 8.5' <<< "$out" \
    && pass "…--force moves the rest alone, as before, and names the way back" || fail "app edit --force: rc=${rc} ${out}"
out=$(FP '_fphp_restart_cmd shop' 2>&1); [[ $? -eq 0 ]] && grep -q 'restarted and answering' <<< "$out" && pass "frankenphp restart: restarted, checked" || fail "restart: ${out}"
grep -q "php)            _fphp_php" "${LIB}/frankenphp.sh" && grep -q "restart)        _fphp_restart_cmd" "${LIB}/frankenphp.sh" && pass "dispatch: frankenphp php, restart" || fail "dispatch"

# ══ 6. cipi cache ════════════════════════════════════════════
echo "--- page cache"
CG="${TMP}/cache"; mkdir -p "$CG/sites" "$CG/bin" "$CG/cfg" "$CG/log" "$CG/confd" "$CG/root" "$CG/sudoers"
printf '%s\n' '{"wpress":{"domain":"wpress.test","custom":"true","docroot":"","php":"8.5"},"shop":{"domain":"shop.test","php":"8.5"},"fast":{"domain":"fast.test","php":"8.5","octane":"frankenphp","octane_port":"8101"},"spa":{"domain":"spa.test","php":"8.5","runtime":"node"},"off":{"domain":"off.test","php":"8.5","suspended":"true"}}' > "$CG/apps.json"
printf 'user %s;\nhttp { include /etc/nginx/conf.d/*.conf; }\n' "$(id -un)" > "$CG/nginx.conf"
for a in wpress shop fast; do printf '%s ALL=(root) NOPASSWD: /usr/local/bin/cipi-worker restart %s\n' "$a" "$a" > "$CG/sudoers/cipi-$a"; done
# nginx -t: a vhost that names a zone no conf.d file defines is refused, as
# nginx does ("zone ... is unknown"); a file named *.broken refuses everything.
mkstub "$CG/bin/nginx" <<NGINXSTUB
#!/bin/bash
[[ "\${1:-}" == "-t" ]] || exit 0
if [[ -f "$CG/refuse-on" ]] && grep -qs -- "\$(cat "$CG/refuse-on")" "$CG"/confd/*.conf; then
    echo 'nginx: [emerg] invalid parameter "bogus" in $CG/confd/cipi-cache-wpress.conf:2' >&2; exit 1
fi
rc=0
for v in "$CG"/sites/*; do
    [[ -f "\$v" ]] || continue
    for z in \$(grep -oE '(fastcgi|proxy)_cache cipi_[a-z0-9]+' "\$v" | awk '{ print \$2 }' | sort -u); do
        grep -qs "keys_zone=\${z}:" "$CG"/confd/*.conf || { echo "nginx: [emerg] \"fastcgi_cache\" zone \"\${z}\" is unknown in \$v:1" >&2; rc=1; }
    done
    if grep -q 'cipi_cache_skip_' "\$v" && ! grep -qs 'map \$http_cookie \$cipi_cache_skip_cookie' "$CG/confd/cipi-cache-maps.conf"; then
        echo 'nginx: [emerg] unknown "cipi_cache_skip_cookie" variable' >&2; rc=1
    fi
    for m in \$(grep -oE 'cipi_cache_skip_[a-z0-9]+' "\$v" | sort -u); do
        case "\$m" in cipi_cache_skip_cookie|cipi_cache_skip_uri|cipi_cache_skip_args|cipi_cache_skip_auth) continue ;; esac
        grep -qsF "map \\\$request_uri \\\$\${m} {" "$CG"/confd/*.conf || { echo "nginx: [emerg] unknown \"\${m}\" variable" >&2; rc=1; }
    done
done
(( rc == 0 )) && echo "nginx: configuration file /etc/nginx/nginx.conf test is successful" >&2
exit \$rc
NGINXSTUB
mkstub "$CG/bin/systemctl" <<EOF
#!/bin/bash
echo "\$*" >> "$CG/systemctl.log"
EOF
mkstub "$CG/bin/hostname" <<'EOF'
#!/bin/bash
echo box
EOF
cat > "$CG/h.sh" <<CACHEHARNESS
export CIPI_LIB="${LIB}" CIPI_CONFIG="$CG/cfg" CIPI_LOG="$CG/log" PATH="$CG/bin:\$PATH"
export CACHE_CONF_DIR="$CG/confd" CACHE_ROOT="$CG/root" CACHE_NGINX_CONF="$CG/nginx.conf" CACHE_SITES_DIR="$CG/sites" CACHE_SUDOERS_DIR="$CG/sudoers"
RED=; GREEN=; YELLOW=; CYAN=; DIM=; NC=; BOLD=
source "${LIB}/common.sh" 2>/dev/null
vault_read() { cat "$CG/apps.json"; }
vault_write() { local t; t=\$(cat); printf '%s\n' "\$t" > "$CG/apps.json"; }
ensure_apps_json_api_access() { :; }; _ensure_nginx_octane_map() { :; }
app_log_dir_ensure() { :; }; app_log_links_default() { :; }
cipi_notify() { echo "NOTIFY [\$3] \$1" >> "$CG/notify.log"; }; log_action() { echo "\$*" >> "$CG/actions.log"; }; curl() { return 0; }
visudo() { return 0; }
source "${LIB}/routes.sh"
source "${LIB}/app.sh"
source "${LIB}/cache.sh"
eval "\$(declare -f _create_nginx_vhost _create_nginx_vhost_http _nginx_vhost_tls | sed 's|/etc/nginx/sites-available/|$CG/sites/|g')"
_nginx_custom_dir() { echo "$CG/custom"; }
CACHEHARNESS
CH="source '$CG/h.sh';"
cache() { bash -c "$CH cache_command \"\$@\"" _ "$@" 2>&1; }
for a in wpress shop fast; do bash -c "$CH _create_nginx_vhost $a $a.test 8.5" >/dev/null 2>&1; done
[[ -s "$CG/sites/wpress" ]] && ! grep -q 'fastcgi_cache\|X-Cache-Status' "$CG/sites/wpress" && [[ -z "$(ls "$CG/confd" 2>/dev/null)" ]] \
    && pass "off by default: no cache line in a vhost, nothing in conf.d" || fail "a cache without asking: $(ls "$CG/confd")"
cp "$CG/sites/wpress" "$CG/wpress.before"
[[ "$(cache wpress --json | jq -r '[.enabled, .supported, .kind, .ttl, .files] | @tsv')" == $'false\ttrue\tfastcgi\t10m\t0' ]] && pass "cache <app> --json: off, fastcgi, 10m" || fail "status off: $(cache wpress --json)"
grep -q 'OPcache is on already, and it is another cache' <<< "$(cache wpress)" && pass "cache <app>: says what it is not (OPcache)" || fail "status text: $(cache wpress)"

out=$(cache wpress on); rc=$?
[[ $rc -eq 0 ]] && grep -q "Page cache on for 'wpress'" <<< "$out" && pass "cache wpress on" || fail "on: rc=${rc} ${out}"
Z="$CG/confd/cipi-cache-wpress.conf"
grep -qx "fastcgi_cache_path $CG/root/wpress levels=1:2 keys_zone=cipi_wpress:10m max_size=256m inactive=3600s use_temp_path=off;" "$Z" \
    && pass "the zone: fastcgi_cache_path, 256m, inactive an hour" || fail "zone: $(cat "$Z" 2>/dev/null)"
M="$CG/confd/cipi-cache-maps.conf"
for m in 'map $http_cookie $cipi_cache_skip_cookie' 'map $request_uri $cipi_cache_skip_uri' 'map $args $cipi_cache_skip_args' 'map $http_authorization $cipi_cache_skip_auth'; do
    grep -qF "$m {" "$M" || fail "maps: no ${m}"
done
pass "the maps, once for the server: cookie, uri, args, authorization"
grep -q 'wordpress_logged_in_' "$M" && grep -q 'woocommerce_items_in_cart' "$M" && grep -q 'PHPSESSID' "$M" && grep -q '_session)=' "$M" && grep -q 'wp-admin' "$M" && grep -q 'utm_' "$M" \
    && pass "…WordPress and WooCommerce logins and carts, PHP and Laravel sessions, wp-admin, tracking parameters" || fail "maps content"
V="$CG/sites/wpress"
grep -qx '        fastcgi_cache cipi_wpress;' "$V" && grep -qx '        fastcgi_cache_valid 200 301 600s;' "$V" && grep -qx '        fastcgi_cache_valid 404 60s;' "$V" \
    && pass "the vhost: fastcgi_cache, pages 600s, a missing page 60s" || fail "vhost cache lines: $(grep fastcgi_cache "$V")"
skip='$cipi_cache_skip_cookie $cipi_cache_skip_uri $cipi_cache_skip_args $cipi_cache_skip_auth'
grep -qxF "        fastcgi_cache_bypass ${skip};" "$V" && grep -qxF "        fastcgi_no_cache ${skip};" "$V" \
    && pass "bypass and no_cache both: a private page is neither read from the cache nor written to it" || fail "bypass/no_cache"
! grep -q 'ignore_headers' "$V" "$Z" "$M" && pass "no fastcgi_ignore_headers: Set-Cookie and Cache-Control: private keep a response out" || fail "ignore_headers present"
grep -qxF '        fastcgi_cache_key "$scheme$request_method$host$request_uri";' "$V" && grep -qx '        fastcgi_cache_use_stale updating error timeout http_500 http_503;' "$V" \
    && grep -qx '        fastcgi_cache_lock on;' "$V" && grep -qx '        fastcgi_cache_background_update on;' "$V" && pass "key, lock, stale while updating and when PHP is down" || fail "key/lock/stale"
awk '/location ~ \\.php\$ \{/ { p = 1 } p && /fastcgi_cache cipi_wpress;/ { ok = 1 } p && /^    }/ { p = 0 } END { exit !ok }' "$V" && pass "…inside the location that reaches PHP" || fail "cache lines outside the PHP location"
grep -qxF '    add_header X-Cache-Status $upstream_cache_status always;' "$V" && [[ "$(grep -c 'add_header' "$V")" == 4 ]] \
    && ! awk '/location/ { l = 1 } l && /add_header/ { bad = 1 } END { exit !bad }' "$V" \
    && pass "X-Cache-Status at server level, with the three security headers: no add_header in a location to drop them" || fail "X-Cache-Status placement: $(grep -n add_header "$V")"
diff <(grep -v 'fastcgi_cache\|fastcgi_no_cache\|X-Cache-Status' "$V") "$CG/wpress.before" >/dev/null && pass "nothing else in the vhost changed" || fail "vhost differs beyond the cache lines"
grep -q 'reload nginx' "$CG/systemctl.log" && pass "nginx tested and reloaded" || fail "no reload"
grep -qxF 'wpress ALL=(root) NOPASSWD: /usr/local/bin/cipi-cache-clear wpress' "$CG/sudoers/cipi-wpress" && pass "the app's user may empty its own cache: sudoers rule added" || fail "sudoers: $(cat "$CG/sudoers/cipi-wpress")"
grep -q 'NOTIFY \[app_cache\] Cipi page cache on: wpress on box' "$CG/notify.log" && pass "notified (app_cache)" || fail "notify"
[[ "$(cache wpress --json | jq -r '[.enabled, .active, .clear_on_deploy, .clear_command] | @tsv')" == $'true\ttrue\ttrue\tsudo /usr/local/bin/cipi-cache-clear wpress' ]] && pass "status --json: on, active, cleared on deploy, the command" || fail "status on: $(cache wpress --json)"
out=$(cache wpress on); grep -q 'is on already' <<< "$out" && pass "on twice: already on" || fail "on twice: ${out}"

out=$(cache wpress ttl 1d); [[ $? -eq 0 ]] && grep -qx '        fastcgi_cache_valid 200 301 86400s;' "$V" && grep -q 'inactive=86400s' "$Z" && pass "cache wpress ttl 1d: 86400s, and kept that long when idle" || fail "ttl: ${out}"
out=$(cache wpress ttl 20s); grep -qx '        fastcgi_cache_valid 404 20s;' "$V" && pass "a time under a minute is the one for missing pages too" || fail "ttl 20s"
for bad in 10 10x 0m 31d 1.5h '10m;' ''; do
    out=$(cache wpress ttl "$bad"); rc=$?
    if [[ -z "$bad" ]]; then continue; fi
    [[ $rc -ne 0 ]] && grep -q 'Invalid time' <<< "$out" || fail "ttl accepted '${bad}': ${out}"
done
pass "ttl: a bare number, an unknown unit, zero, more than 30 days and a ; are refused"
grep -qx '        fastcgi_cache_valid 200 301 20s;' "$V" && pass "…and the vhost keeps the last good one" || fail "vhost after bad ttl"
cache wpress ttl 10m >/dev/null
out=$(cache wpress size 1g); [[ $? -eq 0 ]] && grep -q 'max_size=1g' "$Z" && pass "cache wpress size 1g" || fail "size: ${out}"
out=$(cache wpress size 8m); [[ $? -ne 0 ]] && grep -q 'Invalid size' <<< "$out" && pass "a size under 16m is refused" || fail "size 8m: ${out}"
out=$(cache wpress on --ttl=5m --size=128m); grep -qx '        fastcgi_cache_valid 200 301 300s;' "$V" && grep -q 'max_size=128m' "$Z" && pass "on --ttl= --size= changes both" || fail "on with options: ${out}"

# paths of its own an app keeps out of the cache
echo "--- page cache: exclude"
nrm() { bash -c "$CH cache_exclude_normalize \"\$1\"" _ "$1" 2>/dev/null; }
rgx() { bash -c "$CH _cache_exclude_regex \"\$1\"" _ "$1" 2>/dev/null; }
[[ "$(nrm 'cart*')" == '/cart*' && "$(nrm '/a**b***')" == '/a*b*' && "$(nrm '/My-Account/')" == '/My-Account/' && "$(nrm '/caff%C3%A8_1.0~x')" == '/caff%C3%A8_1.0~x' && "$(nrm '/')" == '/' ]] \
    && pass "a path: a / is added, ** is *, letters digits . _ ~ % - / *" || fail "normalize: $(nrm 'cart*') $(nrm '/a**b***')"
bad_ok=true
for bad in '' '*' '/*' '/**' '/a b' '/a;b' '/a"b' "/a'b" '/a$b' '/a{b}' '/a|b' '/(a)' '/a\b' '/a?b=1' '/a#b' '/a[b]' '/a^b' '/a+b' '/a,b' "$(printf '/%0128d' 0)" $'/a\nb'; do
    nrm "$bad" >/dev/null && { bad_ok=false; fail "exclude accepted '${bad}'"; }
done
$bad_ok && pass "…a space, a quote, ; \$ { | ( \\ ? # [ ^ + , a line break, 129 characters, and /* (every page) are not paths"
m() { grep -qiE -- "$(rgx "$1")" <<< "$2"; }
m '/cart*' '/cart' && m '/cart*' '/cart/' && m '/cart*' '/Cart/items?x=1' && m '/cart*' '/cartoon' && ! m '/cart*' '/shop/cart' && ! m '/cart*' '/car' \
    && pass "/cart*: everything that starts so, whatever the case — not /shop/cart" || fail "regex /cart*: $(rgx '/cart*')"
m '/feed' '/feed' && m '/feed' '/feed/' && m '/feed' '/feed?utm_source=x' && m '/feed/' '/feed' && ! m '/feed' '/feeds' && ! m '/feed' '/feed/atom' && ! m '/feed' '/a/feed' \
    && pass "/feed: the path itself, with or without its last slash and its query string — not /feeds, not /feed/atom" || fail "regex /feed: $(rgx '/feed')"
m '/shop/*/reviews' '/shop/a/b/reviews' && ! m '/shop/*/reviews' '/shop/reviews' && ! m '/shop/*/reviews' '/shop/a/reviews/2' && ! m '/shop/*/reviews' '/shop/a?x=/reviews' \
    && m '/sitemap*.xml' '/sitemap_index.xml' && m '/sitemap*.xml' '/sitemap.xml' && ! m '/sitemap*.xml' '/sitemap.xml.gz' && ! m '/a.b' '/axb' && m '/' '/' && ! m '/' '/x' \
    && pass "a * in the middle stops at the query string; a . is a dot; / is the home page alone" || fail "regex middle: $(rgx '/shop/*/reviews') $(rgx '/sitemap*.xml')"
cp "$V" "$CG/wpress.noex"
out=$(cache wpress exclude add '/cart*' checkout); rc=$?
[[ $rc -eq 0 ]] && grep -q "Never cached for 'wpress': /cart\* /checkout" <<< "$out" && pass "cache wpress exclude add '/cart*' checkout" || fail "exclude add: rc=${rc} ${out}"
grep -qxF 'map $request_uri $cipi_cache_skip_wpress {' "$Z" && grep -qxF '    default 0;' "$Z" && grep -qxF '    "~*^/cart[^?]*" 1;' "$Z" && grep -qxF '    "~*^/checkout/?(\?|$)" 1;' "$Z" \
    && pass "a map of its own next to the app's zone: one line per path" || fail "exclude map: $(cat "$Z")"
skipx="${skip} \$cipi_cache_skip_wpress"
grep -qxF "        fastcgi_cache_bypass ${skipx};" "$V" && grep -qxF "        fastcgi_no_cache ${skipx};" "$V" \
    && pass "…named in bypass and in no_cache: neither read from the cache nor written to it" || fail "exclude in vhost: $(grep 'bypass\|no_cache' "$V")"
! grep -q 'cipi_cache_skip_wpress' "$M" && pass "…the server's maps are not touched" || fail "exclude in the shared maps"
[[ "$(cache wpress --json | jq -c '[.exclude, .exclude_max]')" == '[["/cart*","/checkout"],50]' && "$(cache wpress exclude --json | jq -c '[.app, .enabled, .exclude]')" == '["wpress",true,["/cart*","/checkout"]]' ]] \
    && pass "status --json and exclude --json carry the list" || fail "exclude json: $(cache wpress --json | jq -c .exclude) $(cache wpress exclude --json)"
grep -q 'Never cached, of its own: /cart\* /checkout' <<< "$(cache wpress)" && grep -q '/wp-admin' <<< "$(cache wpress exclude)" && grep -q '    /cart\*' <<< "$(cache wpress exclude)" \
    && pass "cache <app> and cache <app> exclude show it, the second with Cipi's own rules" || fail "exclude shown: $(cache wpress exclude)"
out=$(cache wpress exclude add /checkout '/cart*'); grep -q 'Nothing to change' <<< "$out" && pass "a path twice: nothing to change" || fail "exclude add twice: ${out}"
cp "$CG/apps.json" "$CG/apps.ex"; cp "$Z" "$CG/zone.ex"
for bad in '/a b' '/x;return 200' '/*' '/a"b'; do
    out=$(cache wpress exclude add /ok "$bad"); rc=$?
    [[ $rc -ne 0 ]] && cmp -s "$CG/apps.json" "$CG/apps.ex" && cmp -s "$Z" "$CG/zone.ex" || fail "exclude add accepted '${bad}': ${out}"
done
pass "a path that is not one refuses the whole command: nothing kept, nothing written"
grep -q 'is every page' <<< "$(cache wpress exclude add '/*')" && pass "/*: said to turn the cache off instead" || fail "exclude /*"
out=$(cache wpress exclude set "$(seq -s, -f '/p%g' 1 51)"); [[ $? -ne 0 ]] && grep -q '50 at most' <<< "$out" && cmp -s "$CG/apps.json" "$CG/apps.ex" && pass "51 paths: refused" || fail "exclude max: ${out}"
echo 'feed/?(' > "$CG/refuse-on"; cp "$V" "$CG/wpress.ex"
out=$(cache wpress exclude add /feed); rc=$?
rm -f "$CG/refuse-on"
[[ $rc -ne 0 ]] && grep -q 'nginx refused the configuration' <<< "$out" && cmp -s "$CG/apps.json" "$CG/apps.ex" && cmp -s "$Z" "$CG/zone.ex" && cmp -s "$V" "$CG/wpress.ex" \
    && pass "nginx refuses a path: the list, the map and the vhost go back" || fail "exclude refusal: rc=${rc} ${out}"
out=$(cache wpress exclude remove /checkout /nothere); [[ $? -eq 0 ]] && ! grep -q 'checkout' "$Z" && grep -qxF '    "~*^/cart[^?]*" 1;' "$Z" && pass "exclude remove: that line goes, the others stay" || fail "exclude remove: ${out}"
grep -q 'Not in the list' <<< "$(cache wpress exclude remove /nothere)" && pass "…a path that is not in the list: said, nothing done" || fail "exclude remove unknown"
out=$(cache wpress exclude set '/a*, /b' /c); [[ "$(cache wpress --json | jq -c .exclude)" == '["/a*","/b","/c"]' ]] && pass "exclude set: the whole list, commas or arguments" || fail "exclude set: ${out}"
out=$(cache wpress on --exclude='/my-account*,/feed'); [[ $? -eq 0 && "$(cache wpress --json | jq -c .exclude)" == '["/my-account*","/feed"]' ]] && grep -qxF '    "~*^/feed/?(\?|$)" 1;' "$Z" \
    && pass "on --exclude=: the whole list with the rest" || fail "on --exclude: ${out}"
out=$(cache wpress on --exclude); [[ $? -ne 0 ]] && grep -q -- '--exclude wants paths' <<< "$out" && pass "on --exclude without paths: refused" || fail "on --exclude bare: ${out}"
out=$(cache wpress exclude remove --all); rc=$?
[[ $rc -eq 0 ]] && ! grep -q 'cipi_cache_skip_wpress' "$Z" "$V" && cmp -s "$V" "$CG/wpress.noex" && [[ "$(cache wpress --json | jq -c .exclude)" == '[]' ]] \
    && pass "exclude remove --all: the map and its name in the vhost are gone, the vhost as before" || fail "exclude remove --all: rc=${rc} ${out}"
out=$(cache shop exclude add '/account*'); [[ $? -eq 0 ]] && grep -q 'when the cache is turned on' <<< "$out" && [[ ! -e "$CG/confd/cipi-cache-shop.conf" ]] && ! grep -q 'cipi_cache' "$CG/sites/shop" \
    && pass "with the cache off the list is kept for later: nothing in nginx" || fail "exclude, cache off: ${out}"
cache shop on >/dev/null; grep -qxF '    "~*^/account[^?]*" 1;' "$CG/confd/cipi-cache-shop.conf" && grep -q 'fastcgi_no_cache .* \$cipi_cache_skip_shop;' "$CG/sites/shop" && ! grep -q 'cipi_cache_skip_shop' "$V" \
    && pass "…and applies when it is turned on — to that app only" || fail "exclude at on: $(cat "$CG/confd/cipi-cache-shop.conf" 2>/dev/null)"
cache shop off >/dev/null; [[ "$(jq -c '.shop.page_cache.exclude' "$CG/apps.json")" == '["/account*"]' ]] && pass "…off keeps the list" || fail "exclude after off"
cache shop exclude remove --all >/dev/null
printf '%s\n' "$(jq '.wpress.page_cache.exclude = ["/ok", "/bad;path", 7, "/x*"]' "$CG/apps.json")" > "$CG/apps.json"
[[ "$(cache wpress --json | jq -c .exclude)" == '["/ok","/x*"]' ]] && pass "a list edited by hand: what is not a path is not read" || fail "tampered list: $(cache wpress --json | jq -c .exclude)"
cache wpress exclude remove --all >/dev/null
# as cipi runs it: set -euo pipefail, where a list that finds nothing must not end the command
out=$(bash -c "set -euo pipefail; $CH cache_command wpress exclude; cache_command wpress exclude add /strict '/s*'; cache_command wpress exclude remove /nope; cache_command wpress exclude set; cache_command wpress exclude --json; cache_command wpress; cache_command wpress on --exclude=/one; cache_command wpress on --exclude=; echo END" 2>&1); rc=$?
[[ $rc -eq 0 ]] && grep -q '^END$' <<< "$out" && grep -q 'Of its own: none' <<< "$out" && grep -q "Never cached for 'wpress': /strict /s\*" <<< "$out" && grep -q 'Not in the list' <<< "$out" && grep -q 'keeps no path of its own' <<< "$out" \
    && [[ "$(cache wpress --json | jq -c .exclude)" == '[]' ]] && ! grep -q 'cipi_cache_skip_wpress' "$Z" "$V" \
    && pass "under set -euo pipefail every exclude command runs to its end" || fail "exclude, strict shell: rc=${rc} ${out}"
out=$(cache spa exclude add /x); [[ $? -ne 0 ]] && grep -q 'is a Node app' <<< "$out" && pass "a Node app: refused" || fail "exclude node: ${out}"
out=$(cache wpress exclude frobnicate); [[ $? -ne 0 ]] && grep -q 'exclude \[add|remove|set' <<< "$out" && pass "an unknown exclude action: the usage" || fail "exclude usage: ${out}"

# pages, and their clear
mkdir -p "$CG/root/wpress/a/bc" "$CG/root/wpress/d/ef"; echo page > "$CG/root/wpress/a/bc/k1"; echo page > "$CG/root/wpress/d/ef/k2"; echo page > "$CG/root/wpress/d/ef/k3"
ln -s /etc/hostname "$CG/root/wpress/d/link"
[[ "$(cache wpress --json | jq -r '.files')" == 3 ]] && pass "status counts the pages (3)" || fail "files: $(cache wpress --json | jq -r '.files')"
out=$(cache wpress clear); [[ $? -eq 0 ]] && grep -q '3 page(s)' <<< "$out" && [[ -z "$(find "$CG/root/wpress" -type f)" && -d "$CG/root/wpress/a/bc" ]] \
    && pass "cache wpress clear: the pages are gone, nginx's directories stay" || fail "clear: ${out} $(find "$CG/root/wpress" -type f)"
[[ -f /etc/hostname ]] && [[ -L "$CG/root/wpress/d/link" ]] && pass "…a symlink in the cache is not followed" || fail "symlink"
echo page > "$CG/root/wpress/a/bc/k1"
out=$(bash -c "$CH cache_after_deploy wpress"); [[ "$out" == "Page cache: emptied (1 page(s))" && -z "$(find "$CG/root/wpress" -type f)" ]] && pass "after a deploy: emptied, and said in one line" || fail "after deploy: ${out}"
[[ -z "$(bash -c "$CH cache_after_deploy shop")" ]] && pass "…nothing for an app whose cache is off" || fail "after deploy, cache off"
cache wpress on --no-deploy-clear >/dev/null; echo page > "$CG/root/wpress/a/bc/k1"
[[ -z "$(bash -c "$CH cache_after_deploy wpress")" && -f "$CG/root/wpress/a/bc/k1" ]] && pass "on --no-deploy-clear: a deploy leaves the pages" || fail "no-deploy-clear"
cache wpress on --deploy-clear >/dev/null
grep -q 'cache_after_deploy "$app"' "${LIB}/deploy.sh" && [[ "$(grep -c 'cache_after_deploy' "${LIB}/deploy.sh")" -ge 4 ]] && grep -q 'CACHE_LINE=$(cache_after_deploy "$APP"' "${LIB}/cipi-app-notify.sh" \
    && pass "cipi deploy, a rollback and the webhook deploy all empty it" || fail "deploy hooks"
awk '/cache_line=\$\(cache_after_deploy/ { a = NR } /purge_line=\$\(zt_purge_after_deploy/ { b = NR } END { exit !(a && b && a < b) }' "${LIB}/deploy.sh" \
    && pass "…before Cloudflare's purge, so the edge fetches the new pages" || fail "order with the Cloudflare purge"

# nginx refuses: everything back
echo 'inactive=7200s' > "$CG/refuse-on"; cp "$V" "$CG/wpress.good"; cp "$CG/apps.json" "$CG/apps.good"
out=$(cache wpress ttl 2h); rc=$?
rm -f "$CG/refuse-on"
[[ $rc -ne 0 ]] && grep -q 'nginx refused the configuration' <<< "$out" && grep -q 'invalid parameter' <<< "$out" && cmp -s "$V" "$CG/wpress.good" && cmp -s "$CG/apps.json" "$CG/apps.good" \
    && pass "nginx refuses the change: the settings and the vhost go back, nginx's words are shown" || fail "refusal: rc=${rc} ${out}"

# Octane: proxy_cache; a Node app: refused
out=$(cache fast on --ttl=30s); rc=$?
VF="$CG/sites/fast"
[[ $rc -eq 0 ]] && grep -q '^proxy_cache_path .* keys_zone=cipi_fast:10m' "$CG/confd/cipi-cache-fast.conf" && grep -qx '        proxy_cache cipi_fast;' "$VF" \
    && grep -qxF "        proxy_cache_bypass ${skip} \$http_upgrade;" "$VF" && grep -qxF "        proxy_no_cache ${skip} \$http_upgrade;" "$VF" \
    && pass "an Octane app: proxy_cache, and a WebSocket handshake is not a page" || fail "octane: rc=${rc} ${out} $(grep proxy_cache "$VF")"
awk '/location @octane \{/ { p = 1 } p && /proxy_cache cipi_fast;/ { ok = 1 } p && /^    }/ { p = 0 } END { exit !ok }' "$VF" && ! grep -q 'fastcgi_cache' "$VF" && pass "…in the location that reaches Octane" || fail "octane placement"
out=$(cache spa on); [[ $? -ne 0 ]] && grep -q 'is a Node app' <<< "$out" && [[ ! -e "$CG/confd/cipi-cache-spa.conf" ]] && pass "a Node app: refused, said why" || fail "node: ${out}"
out=$(cache nosuch on); [[ $? -ne 0 ]] && grep -q "not found" <<< "$out" && pass "an app that does not exist" || fail "nosuch: ${out}"
out=$(cache '../wpress' clear); [[ $? -ne 0 ]] && pass "a name that is a path is refused" || fail "path as app"
j=$(cache --json); jq -e '(.apps | length) == 5 and ([.apps[] | select(.enabled) | .app] == ["fast", "wpress"]) and (.apps[] | select(.app == "spa") | .supported == false)' <<< "$j" >/dev/null \
    && pass "cache --json: every app, which are on, which cannot be" || fail "list json: $(jq -c '[.apps[] | [.app, .enabled, .supported]]' <<< "$j")"
grep -q 'wpress' <<< "$(cache list)" && grep -q 'n/a (Node)' <<< "$(cache)" && pass "cache, cache list: the table" || fail "list"

out=$(cache wpress off); rc=$?
[[ $rc -eq 0 ]] && ! grep -q 'fastcgi_cache\|X-Cache-Status' "$V" && [[ ! -e "$Z" && ! -d "$CG/root/wpress" ]] && cmp -s "$V" "$CG/wpress.before" \
    && pass "cache wpress off: the vhost as it was before, the zone and the pages gone" || fail "off: rc=${rc} ${out}"
[[ -f "$M" ]] && grep -q 'proxy_cache cipi_fast' "$VF" && pass "…the other app's cache is not touched" || fail "off touched another app"
[[ "$(jq -r '.wpress.page_cache | [.enabled, .ttl] | @tsv' "$CG/apps.json")" == $'false\t5m' ]] && pass "…its time is kept for the next on" || fail "settings after off: $(jq -c .wpress.page_cache "$CG/apps.json")"
rm -f "$CG/sites/fast"   # cipi app delete removes the vhost with it
bash -c "$CH cache_remove_app fast"; [[ ! -e "$CG/confd/cipi-cache-fast.conf" && ! -d "$CG/root/fast" ]] && pass "an app that is deleted takes its zone and pages with it" || fail "cache_remove_app"
awk '/step "Nginx\.\.\.";/ { a = index($0, "sites-available/${app}\""); b = index($0, "cache_remove_app \"$app\""); c = index($0, "reload_nginx"); ok = (a && b && c && a < b && b < c) } END { exit !ok }' "${LIB}/app.sh" \
    && pass "cipi app delete: the vhost goes first, then the zone, then nginx reloads" || fail "app delete order"
grep -q 'page_cache,' "${LIB}/common.sh" && pass "apps-public.json (what the panel API reads) carries page_cache" || fail "apps-public projection"

# cipi-cache-clear: the app's own user, by sudo
cache wpress on >/dev/null; mkdir -p "$CG/root/wpress/a"; echo p > "$CG/root/wpress/a/k"
CC() { CIPI_LIB="$CG/clib" CIPI_CONFIG="$CG/cfg" CIPI_LOG="$CG/log" CACHE_ROOT="$CG/root" CACHE_CONF_DIR="$CG/confd" CACHE_NGINX_CONF="$CG/nginx.conf" SUDO_USER="${SU:-root}" bash "$CG/cipi-cache-clear" "$@" 2>&1; }
mkdir -p "$CG/clib"; cp "${LIB}/cache.sh" "$CG/clib/"; printf 'vault_read() { cat "%s/apps.json"; }\n' "$CG" > "$CG/clib/vault.sh"
sed -e 's|\[\[ "$(id -u)" -ne 0 \]\]|[[ -n "" ]]|' "${LIB}/cipi-cache-clear.sh" > "$CG/cipi-cache-clear"
out=$(SU=root CC wpress); [[ $? -eq 0 ]] && grep -q "emptied — 1 page(s)" <<< "$out" && [[ ! -f "$CG/root/wpress/a/k" ]] && pass "cipi-cache-clear <app>: emptied, counted" || fail "helper: ${out}"
out=$(SU=shop CC wpress); [[ $? -eq 2 ]] && grep -q "only 'wpress' (or root)" <<< "$out" && pass "…another app's user is refused" || fail "helper other user: ${out}"
out=$(SU=root CC shop); [[ $? -eq 0 ]] && grep -q 'is off — nothing to empty' <<< "$out" && pass "…cache off: nothing done, said so" || fail "helper off: ${out}"
for bad in '../wpress' 'wpress/..' 'WP' ''; do out=$(SU=root CC "$bad"); [[ $? -eq 2 ]] || fail "helper accepted '${bad}'"; done
out=$(SU=root CC wpress extra); [[ $? -eq 2 ]] && pass "…a path, an upper-case name, no name or a second argument: refused" || fail "helper args"
grep -q 'unset CIPI_LIB CIPI_CONFIG CIPI_LOG CACHE_ROOT' "${LIB}/cipi-cache-clear.sh" && pass "…and it takes nothing from the caller's environment" || fail "helper environment"
grep -q 'cipi-cache-clear.sh /usr/local/bin/cipi-cache-clear' "${ROOT}/setup.sh" && grep -q 'cipi-cache-clear.sh" /usr/local/bin/cipi-cache-clear && chown root:root' "${LIB}/self-update.sh" \
    && grep -q 'NOPASSWD: /usr/local/bin/cipi-cache-clear ${app_user}$' "${LIB}/app.sh" && grep -q 'NOPASSWD: /usr/local/bin/cipi-cache-clear ${app}$' "${LIB}/sync.sh" \
    && pass "installed by setup and self-update; in the sudoers of a new and of an imported app" || fail "helper install / sudoers"

# ══ 7. the panel's sudoers, help, completion ═════════════════
echo "--- sudoers, help, completion"
for e in 'cipi cache,' 'cipi cache \*' 'cipi valkey list --json,' 'cipi valkey isolate \*' 'cipi valkey share \*' 'cipi valkey restart \*' \
         'cipi valkey flush-shared --yes,' 'cipi frankenphp php \*' 'cipi frankenphp restart \*' 'cipi notification timezone \*' 'cipi notification server-name \*'; do
    grep -q "/usr/local/bin/${e}" "${LIB}/cipi-api-sudoers.sh" || fail "sudoers: no ${e}"
done
pass "the panel may run: cache, valkey list|isolate|share|restart|flush-shared --yes, frankenphp php|restart, notification timezone|server-name"
! grep -E '^ +/usr/local/bin/cipi (frankenphp (use|import)|valkey flush-shared( \*|,| --force))' "${LIB}/cipi-api-sudoers.sh" | grep -v 'flush-shared --yes,' | grep -q . \
    && pass "…not frankenphp use|import, and flush-shared only as --yes (no --force: it refuses while an app uses the shared instance)" || fail "sudoers too wide"
if command -v visudo >/dev/null 2>&1; then
    SD="${TMP}/sudo"; mkdir -p "$SD"
    ( export TMPDIR="$SD"; source "${LIB}/cipi-api-sudoers.sh"
      eval "$(declare -f write_cipi_api_sudoers | sed "s#local target=\"/etc/sudoers.d/cipi-api\"#local target=\"$SD/cipi-api\"#")"
      write_cipi_api_sudoers ) && [[ -s "$SD/cipi-api" ]] && pass "visudo accepts the whitelist" || fail "visudo refused the whitelist"
else
    echo "  (visudo is not installed: the whitelist is not checked with it)"
fi
gen=$(bash -c "source '${LIB}/completion.sh'; _completion_script bash" 2>/dev/null || cat "${LIB}/completion.sh")
grep -q 'local commands=".* cache .*"' <<< "$gen" && grep -q 'status php upgrade restart use fetch import adopt remove prune' <<< "$gen" && grep -q 'timezone server-name smtp' <<< "$gen" \
    && pass "completion: cache, frankenphp php|restart, notification timezone|server-name" || fail "completion"
grep -q '_help_cmd "cipi cache <app> on"' "${ROOT}/cipi" && grep -q '_help_cmd "cipi cache <app> clear"' "${ROOT}/cipi" && grep -q '_help_cmd "cipi frankenphp php <app> \[<X.Y>\]"' "${ROOT}/cipi" \
    && grep -q '_help_cmd "cipi notification timezone' "${ROOT}/cipi" && grep -q 'nginx cache smtp notification valkey' "${ROOT}/cipi" \
    && pass "help: cache (its own topic), frankenphp php, notification timezone" || fail "help"
grep -q 'cache)      _maybe_cmd_help cache' "${ROOT}/cipi" && pass "dispatch: cipi cache" || fail "dispatch cache"
grep -q '^app_cache|Apps|' "${LIB}/notifications.sh" && pass "trigger app_cache in the catalog" || fail "trigger"

# ══ 8. the migration ═════════════════════════════════════════
echo "--- migration 5.17.0"
MG="${TMP}/mig"; mkdir -p "$MG/home/shop/.deployer" "$MG/home/blog/.deployer" "$MG/home/hand/.deployer" "$MG/cfg" "$MG/lr" "$MG/lib/migrations" "$MG/bin" "$MG/log"
printf '%s\n' '{"shop":{"php":"8.5"},"blog":{"php":"8.5","deploy_migrate":"false"},"hand":{"php":"8.5"}}' > "$MG/cfg/apps.json"
gen_recipe shop laravel "after('deploy:vendors', 'artisan:migrate');" > "$MG/home/shop/.deployer/deploy.php"
gen_recipe blog laravel "// artisan:migrate disabled (deploy-config)" > "$MG/home/blog/.deployer/deploy.php"
gen_recipe hand laravel "after('deploy:vendors', 'artisan:migrate');" | grep -v "artisan:storage:link" > "$MG/home/hand/.deployer/deploy.php"
cp "$LR/before/cipi-security-logs" "$LR/before/cipi-app-logs" "$MG/lr/"
for f in "${LIB}"/*.sh; do sed -e "s#/home/#${MG}/home/#g" "$f" > "$MG/lib/$(basename "$f")"; done
cp -r "${LIB}/deployer" "$MG/lib/"
sed -e "s#/home/#${MG}/home/#g" "${LIB}/migrations/5.17.0.sh" > "$MG/lib/migrations/5.17.0.sh"
mkstub "$MG/bin/sudo" <<'EOF'
#!/bin/bash
while [ $# -gt 0 ] && [ "$1" != "--" ] && [ "${1#-}" != "$1" ]; do [ "$1" = "-u" ] && shift; shift; done
[ "$1" = "--" ] && shift
exec "$@"
EOF
mkstub "$MG/bin/id" <<'EOF'
#!/bin/bash
case "$1" in -u) echo 0 ;; -un|-gn|-nG) echo root ;; *) exit 0 ;; esac
EOF
mkstub "$MG/bin/install" <<'EOF'
#!/bin/bash
a=(); skip=
for x in "$@"; do case "$x" in -o|-g) skip=1 ;; *) if [ -n "$skip" ]; then skip=; else a+=("$x"); fi ;; esac; done
exec /usr/bin/install "${a[@]}"
EOF
head -c 32 /dev/urandom | base64 > "$MG/cfg/.vault_key"
mig() { PATH="$MG/bin:$PATH" CIPI_LIB="$MG/lib" CIPI_CONFIG="$MG/cfg" CIPI_LOG="$MG/log" CIPI_LOGROTATE_D="$MG/lr" bash "$MG/lib/migrations/5.17.0.sh" 2>&1; }
out=$(mig); rc=$?
[[ $rc -eq 0 ]] && grep -q 'Migration 5.17.0 complete' <<< "$out" && pass "the migration runs" || fail "migration: rc=${rc} ${out}"
grep -q 'logrotate: "su root adm" added to' <<< "$out" && grep -q 'su root' "$MG/lr/cipi-security-logs" && pass "…logrotate rules rewritten, and said" || fail "migration logrotate: ${out}"
grep -q 'cipi:deploy-flow' "$MG/home/shop/.deployer/deploy.php" && grep -q 'cipi:deploy-flow' "$MG/home/blog/.deployer/deploy.php" \
    && grep -q '2 app(s) run storage:link, migrate and optimize once' <<< "$out" && pass "…the flow in every Laravel recipe" || fail "migration flow: ${out}"
grep -q 'blog: off in its deploy-config, and really skipped from the next deploy: artisan:migrate' <<< "$out" && pass "…an app with a step off is told that it is now really skipped" || fail "migration note: ${out}"
grep -q 'hand: deploy.php was edited by hand' <<< "$out" && ! grep -q 'cipi:deploy-flow' "$MG/home/hand/.deployer/deploy.php" && grep -q 'cipi app deploy-config hand --keep-releases=5' <<< "$out" \
    && pass "…a recipe edited by hand is left as it is, with the command that writes it again" || fail "migration hand: ${out}"
out2=$(mig); grep -q "need no change" <<< "$out2" && ! grep -q 'app(s) run' <<< "$out2" && pass "a second run changes nothing" || fail "migration twice: ${out2}"

echo ""
echo "=== ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]

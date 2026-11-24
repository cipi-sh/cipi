#!/bin/bash
# 5.13.0: deploy lock and queue.
#  - a push that arrives while a deploy runs goes back in the queue and deploys
#    after it (it was refused with "Deploy locked", reported as failed, lost);
#  - a lock left by an interrupted deploy is removed by the next one;
#  - an automatic deploy that fails with the code in hand pauses that commit:
#    the same commit does not deploy again by itself, a new one does.
# cipi-app-deploy runs for real against a stub Deployer that keeps the lock,
# .dep/latest_release and REVISION as Deployer 8 does, and a local Git repo as
# the remote. Run from repo root: bash tests/verify-5.13.0.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/lib"
PASS=0; FAIL=0
pass() { echo "  OK: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
TMP=$(mktemp -d) && [[ -n "$TMP" && -d "$TMP" ]] || exit 1
BG=()
trap 'for p in "${BG[@]}"; do kill "$p" 2>/dev/null; done; rm -rf "${TMP:?}"' EXIT
echo "=== Cipi 5.13.0 regression checks ==="

v=$(tr -d "[:space:]" < "${ROOT}/version.md"); [[ "$(printf "%s\n%s\n" 5.13.0 "$v" | sort -V | head -1)" == 5.13.0 ]] && pass "version.md >= 5.13.0" || fail "version.md"
grep -q '^## \[5.13.0\]' "${ROOT}/CHANGELOG.md" && pass "CHANGELOG 5.13.0" || fail "CHANGELOG"
for f in cipi-app-deploy.sh deploy.sh; do bash -n "${LIB}/${f}" && pass "${f} parses" || fail "${f} parse"; done

APP=demoapp
H="${TMP}/home/${APP}"; S="${TMP}/stub"; L="${TMP}/deploy.log"
mkdir -p "$H/.deployer" "$H/.dep" "$H/releases" "$S"
: > "$L"   # the wrapper writes to it when it is there (otherwise ~/logs/deploy.log)

# the remote: a repo with a branch "main"
git init -q -b main "${TMP}/src" && git -C "${TMP}/src" -c user.email=t@t -c user.name=t commit -q --allow-empty -m one
git clone -q --bare "${TMP}/src" "${TMP}/remote.git"
head_of() { git -C "${TMP}/remote.git" rev-parse main; }
push_new() { git -C "${TMP}/src" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "$1" && git -C "${TMP}/src" push -q "${TMP}/remote.git" main; }
cat > "$H/.deployer/deploy.php" <<EOF
<?php
namespace Deployer;
require 'recipe/laravel.php';
set('repository', '${TMP}/remote.git');
set('branch', 'main');
set('git_ssh_command', 'ssh -i ${H}/.ssh/id_ed25519 -o StrictHostKeyChecking=accept-new');
EOF

# Deployer: lock, release, REVISION (from the remote's branch), then the outcome
cat > "${S}/dep" <<'EOF'
#!/bin/bash
cd "$STUB_HOME" || exit 1
[[ "${STUB_MODE:-ok}" == sleep ]] && { sleep 30; exit 0; }
if [[ -f .dep/deploy.lock ]]; then echo "Deploy locked by $(cat .dep/deploy.lock)."; exit 1; fi
echo stub > .dep/deploy.lock
[[ "${STUB_MODE:-ok}" == fail-early ]] && { echo "error before the code"; rm -f .dep/deploy.lock; exit 1; }
n=$(( $(cat .dep/latest_release 2>/dev/null || echo 0) + 1 )); echo "$n" > .dep/latest_release
mkdir -p "releases/$n"; git -C "$STUB_REMOTE" rev-parse main > "releases/$n/REVISION"
if [[ "${STUB_MODE:-ok}" == fail ]]; then echo "composer install failed"; rm -f .dep/deploy.lock; exit 1; fi
ln -sfn "releases/$n" current; rm -f .dep/deploy.lock; echo "successfully deployed!"
EOF
cat > "${S}/sudo" <<EOF
#!/bin/bash
[[ "\$1" == -n ]] && exit 1
echo "\$*" >> "${TMP}/sudo.calls"; exit 0
EOF
chmod +x "${S}/dep" "${S}/sudo"
# the wrapper, with the server's paths pointed at the stubs
sed -e "s|HOME_DIR=\"/home/\${APP}\"|HOME_DIR=\"${H}\"|" \
    -e "s|LOG=\"/var/log/cipi-apps/\${APP}/deploy.log\"|LOG=\"${L}\"|" \
    -e "s|\"/usr/bin/php\${PHP_VER}\" /usr/local/bin/dep|bash \"${S}/dep\"|" \
    -e "s|sudo /usr/local/bin/|\"${S}/sudo\" /usr/local/bin/|g; s|sudo -n|\"${S}/sudo\" -n|g" \
    -e "s|pgrep -u \"\$APP\"|pgrep -u \"\$(id -u)\"|" \
    -e "s|\"\$(id -un)\" != \"\$APP\"|-z x|" \
    "${LIB}/cipi-app-deploy.sh" > "${TMP}/cipi-app-deploy"
grep -q "${S}/dep" "${TMP}/cipi-app-deploy" && grep -q "pgrep -u \"\$(id -u)\"" "${TMP}/cipi-app-deploy" && pass "test copy of the wrapper" || fail "sed on the wrapper did not apply"
export STUB_HOME="$H" STUB_REMOTE="${TMP}/remote.git"
# what the per-minute cron does
cron() { [[ -f "$H/.deploy-trigger" ]] || return 3; mv -f "$H/.deploy-trigger" "$H/.deploy-trigger.run"; bash "${TMP}/cipi-app-deploy" "$APP" 8.4 webhook; }
push() { echo '{"source":"github"}' > "$H/.deploy-trigger"; }
notified() { grep -c "deploy " "${TMP}/sudo.calls" 2>/dev/null || echo 0; }

# 1. a plain push
push; cron; r=$?
[[ $r -eq 0 && "$(readlink "$H/current")" == releases/1 ]] && pass "push deploys (release 1)" || fail "first deploy: exit ${r}"
[[ ! -e "$H/.deploy-running" ]] && pass "nothing left of the run guard" || fail ".deploy-running left behind"

# 2. a push while Deployer runs (cipi deploy / the panel): queued, not lost
STUB_MODE=sleep bash "${S}/dep" deploy -f "$H/.deployer/deploy.php" & BG+=($!); sleep 0.3
n0=$(notified); push; cron; r=$?
[[ $r -eq 0 && -f "$H/.deploy-trigger" ]] && pass "push during a running deploy goes back in the queue" || fail "exit ${r}, trigger $( [[ -f "$H/.deploy-trigger" ]] && echo there || echo gone)"
[[ "$(notified)" == "$n0" && "$(readlink "$H/current")" == releases/1 ]] && pass "…no deploy, no failure reported" || fail "it deployed or notified"
kill "${BG[-1]}" 2>/dev/null; wait "${BG[-1]}" 2>/dev/null
cron; [[ "$(readlink "$H/current")" == releases/2 && ! -f "$H/.deploy-trigger" ]] && pass "…and deploys once that one is over (release 2)" || fail "queued push did not deploy"

# 3. a push while another automatic deploy runs (before, during, after Deployer)
bash -c 'exec -a "cipi-app-deploy demoapp 8.4 webhook" sleep 30' & BG+=($!); sleep 0.2
mkdir "$H/.deploy-running" && echo "${BG[-1]}" > "$H/.deploy-running/pid"
push; cron; r=$?
[[ $r -eq 0 && -f "$H/.deploy-trigger" && "$(readlink "$H/current")" == releases/2 ]] && pass "push during another automatic deploy is queued" || fail "exit ${r}"
kill "${BG[-1]}" 2>/dev/null; wait "${BG[-1]}" 2>/dev/null
cron; [[ "$(readlink "$H/current")" == releases/3 ]] && pass "…a guard whose run is gone (killed) does not block (release 3)" || fail "stale guard blocked the deploy"

# 4. a lock left by an interrupted deploy
echo "trippo" > "$H/.dep/deploy.lock"
push; cron; r=$?
[[ $r -eq 0 && "$(readlink "$H/current")" == releases/4 && ! -f "$H/.dep/deploy.lock" ]] && pass "stale lock removed, push deployed (release 4)" || fail "stale lock: exit ${r}"
grep -q 'removed the lock left by an interrupted deploy (trippo)' "$L" && pass "…and the log says so" || fail "no log line for the stale lock"

# 5. a failing commit pauses itself; the same commit does not deploy again; a new one does
push_new broken; bad=$(head_of)
n0=$(notified); push; STUB_MODE=fail cron; r=$?
[[ $r -ne 0 && "$(cat "$H/.dep/cipi-paused-commit")" == "$bad" ]] && pass "failed deploy pauses its commit" || fail "pause file: $(cat "$H/.dep/cipi-paused-commit" 2>/dev/null)"
[[ "$(notified)" -gt "$n0" ]] && grep -q "paused for commit ${bad:0:12}" "${TMP}/sudo.calls" && pass "…the failure alert says so" || fail "alert without the pause line"
[[ ! -f "$H/.dep/deploy.lock" ]] && pass "…and no lock is left to remove by hand" || fail "lock left after a failure"
rel=$(cat "$H/.dep/latest_release")
push; cron; r=$?
[[ $r -eq 0 && "$(cat "$H/.dep/latest_release")" == "$rel" ]] && pass "same commit again (webhook redelivered): skipped" || fail "the paused commit was deployed again"
grep -q "deploy skipped  app=${APP} trigger=github commit=${bad:0:12}" "$L" && pass "…with a line in the deploy log" || fail "no skip line"
push_new fixed
push; cron; r=$?
[[ $r -eq 0 && "$(cat "$H/releases/$(cat "$H/.dep/latest_release")/REVISION")" == "$(head_of)" && ! -f "$H/.dep/cipi-paused-commit" ]] \
    && pass "a new commit deploys and clears the pause" || fail "fix did not deploy: exit ${r}"

# 6. a failure before the code (no REVISION) pauses nothing
push; STUB_MODE=fail-early cron
[[ ! -f "$H/.dep/cipi-paused-commit" ]] && pass "failure before the code was fetched pauses no commit" || fail "paused on an early failure"

# 7. a remote that does not answer holds nothing back
echo "$(head_of)" > "$H/.dep/cipi-paused-commit"
sed -i "s|set('repository', '.*');|set('repository', '${TMP}/nowhere.git');|" "$H/.deployer/deploy.php"
rel=$(cat "$H/.dep/latest_release"); push; STUB_REMOTE="${TMP}/remote.git" cron
[[ "$(cat "$H/.dep/latest_release")" != "$rel" ]] && pass "unreachable remote: the deploy goes ahead" || fail "unreachable remote blocked the push"

# 8. a newer push is never overwritten by a requeue
STUB_MODE=sleep bash "${S}/dep" deploy -f "$H/.deployer/deploy.php" & BG+=($!); sleep 0.3
echo '{"source":"old"}' > "$H/.deploy-trigger"; mv "$H/.deploy-trigger" "$H/.deploy-trigger.run"
echo '{"source":"new"}' > "$H/.deploy-trigger"
bash "${TMP}/cipi-app-deploy" "$APP" 8.4 webhook
grep -q '"new"' "$H/.deploy-trigger" && [[ ! -e "$H/.deploy-trigger.run" ]] && pass "requeue keeps the newer trigger" || fail "newer trigger overwritten"
kill "${BG[-1]}" 2>/dev/null; wait "${BG[-1]}" 2>/dev/null

# ── cipi-worker: no wait for the jobs in hand (#536) ─────────
W="${TMP}/w"; mkdir -p "${W}/bin" "${W}/conf"
printf '[program:demoapp-worker-default]\n[program:demoapp-horizon]\n[program:demoapp-octane]\n[program:demoapp-reverb]\n' > "${W}/conf/${APP}.conf"
cat > "${W}/bin/supervisorctl" <<STUB
#!/bin/bash
echo "\$*" >> "${W}/calls"
case "\$1" in
    status)
        if [[ -n "\${2:-}" ]]; then grep "^\$2 " "${W}/state" 2>/dev/null; exit 0; fi
        cat "${W}/state" ;;
    restart) [[ "\$2" == demoapp-reverb ]] && sleep 5; exit 0 ;;
    *) exit 0 ;;
esac
STUB
chmod +x "${W}/bin/supervisorctl"
cat > "${W}/state" <<'STATE'
demoapp-worker-default:demoapp-worker-default_00 RUNNING   pid 11, uptime 1:00:00
demoapp-worker-default:demoapp-worker-default_01 RUNNING   pid 12, uptime 1:00:00
demoapp-horizon                  RUNNING   pid 13, uptime 1:00:00
demoapp-octane                   RUNNING   pid 14, uptime 1:00:00
demoapp-reverb                   RUNNING   pid 15, uptime 1:00:00
otherapp-horizon                 RUNNING   pid 16, uptime 1:00:00
STATE
sed -e 's|^CALLER=.*|CALLER=root|' "${LIB}/cipi-worker.sh" > "${W}/cipi-worker"
wk() { PATH="${W}/bin:${PATH}" CIPI_SUPERVISOR_CONF_DIR="${W}/conf" CIPI_WORKER_RESTART_WAIT=1 bash "${W}/cipi-worker" "$@" 2>&1; }
o=$(wk stop "$APP"); r=$?
[[ $r -eq 0 && ! -s "${W}/calls" ]] && pass "cipi-worker stop: returns at once, stops nothing" || fail "stop: exit ${r}, calls: $(cat "${W}/calls" 2>/dev/null)"
t0=$SECONDS; o=$(wk restart "$APP"); r=$?
[[ $r -eq 0 && $(( SECONDS - t0 )) -lt 5 ]] && pass "cipi-worker restart: returns without waiting ($(( SECONDS - t0 ))s)" || fail "restart: exit ${r} after $(( SECONDS - t0 ))s"
grep -qx 'signal TERM demoapp-horizon' "${W}/calls" && grep -qx 'signal TERM demoapp-worker-default:demoapp-worker-default_01' "${W}/calls" \
    && pass "Horizon and queue workers: SIGTERM (finish the job, Supervisor starts them on the new release)" || fail "graceful: $(cat "${W}/calls")"
grep -qE '^(stop|restart) demoapp-(horizon|worker)' "${W}/calls" && fail "Horizon or a worker was stopped/restarted (waits for the jobs)" || pass "…never supervisorctl stop/restart on them"
grep -qx 'restart demoapp-octane' "${W}/calls" && pass "Octane restarted" || fail "Octane not restarted"
grep -q 'otherapp' "${W}/calls" && fail "another app's program was touched" || pass "another app's programs untouched"
grep -q 'demoapp-reverb: still stopping after 1s' <<< "$o" && pass "a restart that takes longer does not hold the deploy" || fail "slow restart: ${o}"
sed -i 's/^demoapp-horizon .*/demoapp-horizon                  STOPPING/' "${W}/state"; : > "${W}/calls"
wk restart "$APP" >/dev/null
sleep 1.5; sed -i 's/^demoapp-horizon .*/demoapp-horizon                  STOPPED/' "${W}/state"; sleep 2.5
grep -qx 'start demoapp-horizon' "${W}/calls" && pass "Horizon left STOPPING is started once it has stopped (in the background)" || fail "STOPPING never started: $(cat "${W}/calls")"

# ── backup: paths left out of the app archives ───────────────
B="${TMP}/b"; mkdir -p "${B}/home/shop/shared/storage/app/uploads/2026" "${B}/home/shop/shared/storage/app/public"
echo x > "${B}/home/shop/shared/storage/app/uploads/2026/big.bin"; echo y > "${B}/home/shop/shared/storage/app/public/v.mp4"
echo z > "${B}/home/shop/shared/storage/app/public/keep.txt"; echo e > "${B}/home/shop/shared/.env"
cat > "${B}/run.sh" <<RUN
source "${LIB}/backup.sh" 2>/dev/null
_bk_profile_list_field() { printf '%s\n' "storage/app/uploads" "blog:wp-content/uploads" "sh*:*.mp4"; }
"\$@"
RUN
ex=$(bash "${B}/run.sh" _bk_app_excludes nightly shop | paste -sd' ' -)
[[ "$ex" == "storage/app/uploads *.mp4" ]] && pass "exclusions for an app: plain ones and those whose app glob matches" || fail "excludes: ${ex}"
args=(); while IFS= read -r x; do args+=("--exclude=${x}"); done < <(bash "${B}/run.sh" _bk_app_excludes nightly shop)
tar -czf "${B}/f.tgz" -C "${B}/home/shop" "${args[@]}" shared 2>/dev/null
list=$(tar -tzf "${B}/f.tgz")
grep -q 'uploads' <<< "$list" && fail "uploads archived" || pass "storage/app/uploads left out of shared/"
grep -q 'v.mp4' <<< "$list" && fail "*.mp4 archived" || pass "*.mp4 left out"
grep -q 'keep.txt' <<< "$list" && grep -q 'shared/.env' <<< "$list" && pass "the rest of shared/ is in the archive" || fail "too much left out: ${list}"
bad=0; for x in "/var/www" "*" "shared" "htdocs" "a;b" "x:"; do bash "${B}/run.sh" _bk_valid_exclude_path "$x" && bad=1; done
ok=1; for x in "storage/app/uploads" "shop:storage/app/uploads" "*.mp4" "my files/a[1]"; do bash "${B}/run.sh" _bk_valid_exclude_path "$x" || ok=0; done
[[ $bad -eq 0 && $ok -eq 1 ]] && pass "--exclude-paths validation (absolute, whole app, shell characters refused)" || fail "validation"
grep -qF '"${tar_excl[@]}" $paths' "${LIB}/backup.sh" && grep -qF 'excluded_paths: $x' "${LIB}/backup.sh" \
    && pass "the run passes them to tar and records them in meta.json" || fail "run wiring"
ys=$(grep -n "<<'CIPIYAMLPY'" "${LIB}/yml.sh" | head -1 | cut -d: -f1)
ye=$(awk -v s="$ys" 'NR > s && /^CIPIYAMLPY$/ { print NR; exit }' "${LIB}/yml.sh")
sed -n "$((ys + 1)),$((ye - 1))p" "${LIB}/yml.sh" > "${B}/v.py"
printf 'version: 1\nbackup:\n  profiles:\n    - name: shop-files\n      scope: files\n      exclude_paths: ["storage/app/uploads", "*.mp4"]\n      every: 1d\n      keep: 7\n      destinations: [local]\n    - name: shop-bad\n      scope: files\n      exclude_paths: ["/srv", "shared"]\n      every: 1d\n      keep: 7\n      destinations: [local]\n' > "${B}/c.yml"
yo=$(python3 "${B}/v.py" "${B}/c.yml" shop 2>&1)
grep -q "exclude_paths\[0\]: invalid pattern '/srv'" <<< "$yo" && grep -q "'shared' would leave the whole app out" <<< "$yo" \
    && ! grep -q 'profiles\[0\]' <<< "$yo" && pass "cipi.yml: exclude_paths validated" || fail "cipi.yml: ${yo}"

# ── cipi db switch: MariaDB ⇄ MySQL on port 3306 ─────────────
D="${TMP}/d"; mkdir -p "${D}/bin" "${D}/cfg" "${D}/log" "${D}/etc/mariadb.conf.d" "${D}/data/mysql" "${D}/sources" "${D}/lib"
cp -r "${LIB}/." "${D}/lib/"
printf 'mariadb_setup_apt_repo() { echo "deb mariadb.org" > "%s/sources/mariadb.list"; echo repo >> "%s/calls"; }\n' "$D" "$D" > "${D}/lib/php-apt.sh"
printf 'mariadb-server\nmariadb-client\nmariadb-common\nmysql-common\ngalera-4\nlibmariadb3\n' > "${D}/pkgs"
echo "seed" > "${D}/data/mysql/ibdata1"; echo "deb mariadb.org" > "${D}/sources/mariadb.list"
printf 'Unattended-Upgrade::Package-Blacklist {\n    "mariadb-common";\n};\n' > "${D}/uu"
echo '{"db_root_password":"S3cret","db_default_engine":"mariadb","db_engines":{"mariadb":{"installed":true,"port":3306}}}' > "${D}/cfg/server.json"
echo '{}' > "${D}/cfg/apps.json"; echo '{"mariadb":{},"pgsql":{}}' > "${D}/cfg/databases.json"
cat > "${D}/bin/apt-get" <<STUB
#!/bin/bash
echo "apt-get \$*" >> "${D}/calls"
args=(); for a in "\$@"; do [[ "\$a" == -* || "\$a" == DPkg::* ]] || args+=("\$a"); done
case "\${args[0]:-}" in
    update) exit 0 ;;
    purge)
        if [[ " \$* " == *" -s "* ]]; then for p in "\${args[@]:1}"; do echo "Purg \$p"; done; [[ -n "\${STUB_SIM_EXTRA:-}" ]] && echo "Remv \${STUB_SIM_EXTRA}"; exit 0; fi
        for p in "\${args[@]:1}"; do sed -i "/^\${p}\\\$/d" "${D}/pkgs"; done ;;
    install)
        for p in "\${args[@]:1}"; do [[ "\$p" == "\${STUB_FAIL_INSTALL:-none}" ]] && exit 100; done
        for p in "\${args[@]:1}"; do echo "\$p" >> "${D}/pkgs"; done
        [[ " \${args[*]} " == *" mysql-server "* ]] && echo mysql-common >> "${D}/pkgs"
        # A fresh data directory starts without a root password; one put back keeps its own.
        [[ -d "${D}/data/mysql" ]] || { mkdir -p "${D}/data/mysql"; : > "${D}/root.pass"; } ;;
esac
exit 0
STUB
cat > "${D}/bin/dpkg-query" <<STUB
#!/bin/bash
while read -r p; do [[ -n "\$p" ]] && echo "installed \$p"; done < "${D}/pkgs"
STUB
# apt-cache as the real one writes: a line at a time, the version table after
# the candidate; and awk as gawk (Ubuntu Server's) reads: as lines come. An
# `awk '…{print; exit}'` on it kills apt-cache with SIGPIPE (5.13.1).
cat > "${D}/bin/apt-cache" <<'STUB'
#!/bin/bash
echo "mysql-server:"; echo "  Installed: (none)"; echo "  Candidate: 8.4.11-0ubuntu0.26.04.1"
sleep 0.2; echo "  Version table:"; echo "     8.4.11-0ubuntu0.26.04.1 500"
STUB
if command -v gawk >/dev/null 2>&1; then ln -sf "$(command -v gawk)" "${D}/bin/awk"
else printf '#!/bin/bash\nexec mawk -W interactive "$@"\n' > "${D}/bin/awk"; fi
cat > "${D}/bin/systemctl" <<STUB
#!/bin/bash
echo "systemctl \$*" >> "${D}/calls"
if [[ "\$1" == cat ]]; then
    case "\$2" in
        mariadb.service) grep -qx mariadb-server "${D}/pkgs" ;;
        mysql.service)   grep -qx mysql-server "${D}/pkgs" ;;
        *) exit 1 ;;
    esac
    exit \$?
fi
exit 0
STUB
cat > "${D}/bin/dbclient" <<STUB
#!/bin/bash
# mariadb / mysql: answers for the installed server only, with the root password once set.
me=\$(basename "\$0")
[[ "\$me" == mariadb ]] && ! grep -qx mariadb-server "${D}/pkgs" && exit 1
[[ "\$me" == mysql ]] && ! grep -qx mysql-server "${D}/pkgs" && ! grep -qx mariadb-server "${D}/pkgs" && exit 1
pw=""; for a in "\$@"; do [[ "\$a" == -p* ]] && pw="\${a#-p}"; done
if [[ -z "\$pw" ]]; then
    sql=\$(cat); echo "\$me: \$sql" >> "${D}/sql"
    p=\$(sed -n "s/.*ALTER USER 'root'@'localhost' .*BY '\\([^']*\\)'.*/\\1/p" <<< "\$sql"); [[ -n "\$p" ]] && echo "\$p" > "${D}/root.pass"; exit 0
fi
[[ "\$pw" == "\$(cat "${D}/root.pass" 2>/dev/null)" ]] || { echo "ERROR 1045 (28000): Access denied" >&2; exit 1; }
for a in "\$@"; do
    case "\$a" in
        *"SELECT VERSION()"*) grep -qx mysql-server "${D}/pkgs" && echo "8.4.11-0ubuntu0.26.04.1" || echo "11.4.4-MariaDB"; exit 0 ;;
        *"schema_name FROM information_schema.schemata"*) [[ -n "\${STUB_DBS:-}" ]] && echo "\$STUB_DBS"; exit 0 ;;
    esac
done
exit 0
STUB
for c in mariadb mysql; do ln -sf dbclient "${D}/bin/${c}"; done
printf '#!/bin/bash\nexit 1\n' > "${D}/bin/pgrep"; printf '#!/bin/bash\necho "Mem: 4096 1000 3000"\n' > "${D}/bin/free"
chmod +x "${D}/bin/"*
echo "S3cret" > "${D}/root.pass"
cat > "${D}/run.sh" <<RUN
# As cipi runs: set -euo pipefail (a failure nothing checks ends it).
set -euo pipefail
RED=\$'\\033[0;31m'; GREEN=\$'\\033[0;32m'; YELLOW=\$'\\033[1;33m'; CYAN=\$'\\033[0;36m'; DIM=\$'\\033[2m'; NC=\$'\\033[0m'; BOLD=\$'\\033[1m'
export CIPI_LIB="${D}/lib" CIPI_CONFIG="${D}/cfg" CIPI_LOG="${D}/log"
export DB_MYSQL_ETC="${D}/etc" DB_MYSQL_DATA="${D}/data/mysql" APT_SOURCES_DIR="${D}/sources" CIPI_UNATTENDED_FILE="${D}/uu"
export PATH="${D}/bin:\${PATH}"
source "${D}/lib/vault.sh" 2>/dev/null; source "${D}/lib/common.sh"; source "${D}/lib/db.sh"
vault_write() { cat > "\${CIPI_CONFIG}/\$1"; }
cipi_notify() { echo "notify \$3" >> "${D}/calls"; }
"\$@"
RUN
sw() { bash "${D}/run.sh" "$@" </dev/null 2>&1; }
swi() { bash "${D}/run.sh" "$@" 2>&1; }   # with stdin
flavor() { jq -r '.db_engines.mariadb.server // "mariadb"' "${D}/cfg/server.json"; }

o=$(STUB_DBS=shop sw _db_switch mysql --yes); r=$?
[[ $r -ne 0 ]] && grep -q 'no databases on port 3306' <<< "$o" && grep -q 'Databases: shop' <<< "$o" && ! grep -q 'purge -y' "${D}/calls" 2>/dev/null \
    && pass "switch refused with a database on MariaDB (nothing touched)" || fail "with databases: exit ${r}: ${o}"
grep -q 'cipi sync' <<< "$o" && pass "…and says how apps move: a new server + cipi sync" || fail "no guidance"
echo '{"shop":{"php":"8.4"}}' > "${D}/cfg/apps.json"
o=$(sw _db_switch mysql --yes); r=$?
[[ $r -ne 0 ]] && grep -q 'Apps on MariaDB: shop' <<< "$o" && pass "switch refused with an app on MariaDB" || fail "with apps: ${o}"
echo '{"site":{"custom":true}}' > "${D}/cfg/apps.json"
o=$(sw _db_switch mysql); r=$?
[[ $r -ne 0 ]] && grep -q -- '--yes' <<< "$o" && ! grep -q 'purge -y' "${D}/calls" 2>/dev/null && pass "never implicit: no terminal, no --yes, nothing done" || fail "without --yes: ${o}"
o=$(STUB_SIM_EXTRA=python3-mysqldb sw _db_switch mysql --yes); r=$?
[[ $r -ne 0 ]] && grep -q 'would also remove: python3-mysqldb' <<< "$o" && [[ -f "${D}/data/mysql/ibdata1" ]] && ! grep -q 'purge -y' "${D}/calls" \
    && pass "a removal that would take other packages: refused before anything stops" || fail "sim guard: ${o}"
o=$(sw _db_install_engine mysql); r=$?
[[ "$o" == *"cipi db switch mysql"* && "$(flavor)" == mariadb ]] && pass "cipi db install mysql (the panel may run it) never switches" || fail "install mysql: ${o}"

: > "${D}/calls"
o=$(sw _db_switch mysql --yes); r=$?
[[ $r -eq 0 && "$(flavor)" == mysql ]] && pass "MariaDB → MySQL on a server without databases" || fail "switch: exit ${r}: ${o}"
grep -qx mysql-server "${D}/pkgs" && ! grep -q '^mariadb-' "${D}/pkgs" && grep -qx libmariadb3 "${D}/pkgs" \
    && pass "…MariaDB packages purged, client library kept, mysql-server installed" || fail "packages: $(paste -sd' ' "${D}/pkgs")"
kept=$(ls -d "${D}/data/mysql.mariadb-"* 2>/dev/null | head -1)
[[ -n "$kept" && -f "${kept}/ibdata1" ]] && pass "…MariaDB data directory kept aside" || fail "datadir not kept"
[[ ! -f "${D}/sources/mariadb.list" ]] && pass "…MariaDB.org repository removed" || fail "mariadb.list still there"
grep -q "mysql: ALTER USER 'root'@'localhost' IDENTIFIED WITH caching_sha2_password BY 'S3cret'" "${D}/sql" && [[ "$(jq -r .db_root_password "${D}/cfg/server.json")" == S3cret ]] \
    && pass "…same root password, caching_sha2_password" || fail "root: $(cat "${D}/sql" 2>/dev/null)"
grep -q 'innodb_redo_log_capacity' "${D}/etc/mysql.conf.d/99-cipi.cnf" && grep -q 'innodb_buffer_pool_size = 1G' "${D}/etc/mysql.conf.d/99-cipi.cnf" \
    && grep -q 'mysqlx-bind-address = 127.0.0.1' "${D}/etc/mysql.conf.d/99-cipi.cnf" && pass "…MySQL tuning (redo log capacity, buffer pool by RAM, X protocol on localhost)" || fail "cnf"
grep -qF '"mysql-.*";' "${D}/uu" && pass "…MySQL kept off unattended-upgrades" || fail "blacklist: $(cat "${D}/uu")"
grep -q 'notify db_switch' "${D}/calls" && pass "…notification db_switch" || fail "no notification"
[[ "$(sw eval 'db_mysql_label; db_mysql_unit; db_mysql_client; db_engine_label mariadb; db_engine_service_name mariadb' | paste -sd' ' -)" == "MySQL mysql mysql MySQL mysql" ]] \
    && pass "labels, unit and client follow the server" || fail "helpers: $(sw eval 'db_mysql_label; db_mysql_unit; db_mysql_client')"
sw db_engine_is_installed mariadb >/dev/null && pass "the engine (id mariadb) is installed: MySQL's unit" || fail "engine not installed after switch"
ej=$(sw _db_engines --json)
[[ "$(jq -c '.engines[] | select(.engine == "mariadb") | [.status, .server, .label, .port]' <<< "$ej")" == '["installed","mysql","MySQL",3306]' ]] \
    && [[ "$(jq -r '.engines[] | select(.engine == "pgsql") | .status' <<< "$ej")" == not_installed ]] && pass "db engines --json: engine mariadb, server mysql, label MySQL" || fail "engines json: ${ej}"
o=$(sw _db_engines); grep -q "^  mariadb " <<< "$o" && pass "db engines (text) keeps its rows for older APIs" || fail "engines text: ${o}"
[[ "$(sw eval 'source "$CIPI_LIB/stack-upgrade.sh"; _stack_upgrade_main_pkg mariadb; _stack_upgrade_unit mariadb; _stack_upgrade_pkg_pattern mariadb; _stack_upgrade_label mariadb' | paste -sd' ' -)" == "mysql-server mysql ^mysql- MySQL" ]] \
    && pass "db upgrade / autoupdate / pending follow MySQL's packages" || fail "stack-upgrade"
[[ "$(sw eval 'source "$CIPI_LIB/credentials.sh" 2>/dev/null; _cred_url mariadb 1.2.3.4 root pw')" == mysql+ssh://* ]] && pass "TablePlus URL: mysql+ssh" || fail "credentials url"
o=$(sw _db_switch mysql --yes); [[ "$o" == *"already runs MySQL"* ]] && pass "switch to the server already there: nothing to do" || fail "idempotent: ${o}"

: > "${D}/calls"
o=$(STUB_FAIL_INSTALL=mariadb-server sw _db_switch mariadb --yes); r=$?
[[ $r -ne 0 && "$(flavor)" == mysql ]] && grep -qx mysql-server "${D}/pkgs" && grep -q 'MySQL is back on port 3306' <<< "$o" \
    && pass "a failed install puts the previous server back (MySQL)" || fail "rollback: exit ${r}: ${o}"
ls -d "${D}/data/mysql.mysql-"* >/dev/null 2>&1 && fail "MySQL data left aside after the rollback" || pass "…its data directory back in place"

o=$(sw _db_switch mariadb --yes); r=$?
[[ $r -eq 0 && "$(flavor)" == mariadb ]] && grep -qx mariadb-server "${D}/pkgs" && ! grep -q '^mysql-server' "${D}/pkgs" \
    && grep -q 'repo' "${D}/calls" && pass "MySQL → MariaDB back (MariaDB.org repository again)" || fail "back: exit ${r}: ${o}"
grep -q 'innodb_log_file_size' "${D}/etc/mariadb.conf.d/99-cipi.cnf" && pass "…MariaDB tuning" || fail "mariadb cnf"

f=$(printf '/*M!999999\\- enable the sandbox mode */ \nCREATE TABLE `p` (`t` varchar(9) COLLATE utf8mb4_uca1400_ai_ci) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_uca1400_ai_ci;\nINSERT INTO `p` VALUES (%s);\n' "'utf8mb4_uca1400_ai_ci'" | swi _db_mysql_restore_filter mysql)
[[ "$(head -1 <<< "$f")" == CREATE* ]] && grep -q 'COLLATE=utf8mb4_0900_ai_ci' <<< "$f" && grep -q "VALUES ('utf8mb4_uca1400_ai_ci')" <<< "$f" \
    && pass "MariaDB dump into MySQL: sandbox line gone, collations mapped, rows untouched" || fail "filter: ${f}"
f=$(printf 'CREATE TABLE t (a int) COLLATE=utf8mb4_0900_ai_ci;\n' | swi _db_mysql_restore_filter mariadb)
grep -q 'utf8mb4_uca1400_ai_ci' <<< "$f" && pass "MySQL dump into MariaDB: 0900 collations mapped" || fail "reverse filter: ${f}"

# ── basicauth status: no exit 1 halfway (5.11.0–5.12.x), --json ──
A="${TMP}/a"; mkdir -p "${A}/cfg" "${A}/log" "${A}/vhosts"
echo '{"shop":{"domain":"shop.test","php":"8.4"},"blog":{"domain":"blog.test","php":"8.4","basic_auth":true,"basic_auth_agent":"protected"}}' > "${A}/cfg/apps.json"
printf 'admin:$apr1$x\nops:$apr1$y\n' > "${A}/blog.htpasswd"
cat > "${A}/run.sh" <<RUN
export CIPI_LIB="${LIB}" CIPI_CONFIG="${A}/cfg" CIPI_LOG="${A}/log"
source "${LIB}/vault.sh" 2>/dev/null; source "${LIB}/common.sh"; source "${LIB}/app.sh"
RED=""; GREEN=""; YELLOW=""; CYAN=""; DIM=""; NC=""; BOLD=""
set -euo pipefail
_basicauth_file() { [[ "\$1" == blog ]] && echo "${A}/blog.htpasswd" || echo "${A}/none"; }
"\$@"
RUN
o=$(bash "${A}/run.sh" basicauth_status shop 2>&1); r=$?
[[ $r -eq 0 ]] && grep -q 'disabled' <<< "$o" && pass "basicauth status: exit 0 on an app whose vhost has no agent marker (was 1 → the panel showed raw output)" || fail "basicauth status exit ${r}: ${o}"
j=$(bash "${A}/run.sh" basicauth_status shop --json 2>&1)
[[ "$(jq -c . <<< "$j")" == '{"app":"shop","enabled":false,"users":[],"agent":{"mode":"public","public_prefix":null}}' ]] && pass "basicauth status --json (disabled)" || fail "json: ${j}"
j=$(bash "${A}/run.sh" basicauth_status blog --json 2>&1)
[[ "$(jq -c '[.enabled, .users, .agent.mode]' <<< "$j")" == '[true,["admin","ops"],"protected"]' ]] && pass "basicauth status --json (enabled, users, agent kept behind it)" || fail "json blog: ${j}"
grep -q "|| true; } \\\\" "${LIB}/app.sh" && pass "the vhost helper never fails the assignment" || fail "helper"

# ── app env --order ──────────────────────────────────────────
E="${TMP}/e"; mkdir -p "$E"
printf '# header\n\nAPP_NAME="Shop"\nAPP_ENV=production\n# the key\nAPP_KEY=base64:abc==\n\n# Database\nDB_HOST=127.0.0.1\nDB_PASSWORD='"'"'p#ss "x"'"'"'\n# about the password\n\nexport QUEUE_CONNECTION=redis\nAPP_ENV=staging\n# end\n' > "${E}/.env"
cp "${E}/.env" "${E}/orig.env"
er() { bash "${A}/run.sh" "$@" 2>&1; }
er _env_reorder "${E}/.env" "DB_HOST,DB_PASSWORD,QUEUE_CONNECTION,APP_KEY,APP_NAME,APP_ENV" >/dev/null; r=$?
[[ $r -eq 0 && "$(er _env_to_json "${E}/.env" | jq -c keys_unsorted)" == '["DB_HOST","DB_PASSWORD","QUEUE_CONNECTION","APP_KEY","APP_NAME","APP_ENV"]' ]] \
    && pass "env --order: keys in the order given" || fail "order: $(cat "${E}/.env")"
[[ "$(head -2 "${E}/.env" | paste -sd'|' -)" == "# header|" && "$(tail -1 "${E}/.env")" == "# end" ]] && pass "…header first, tail last" || fail "header/tail: $(cat "${E}/.env")"
grep -A1 -x '# the key' "${E}/.env" | grep -qx 'APP_KEY=base64:abc==' && grep -B1 -x '# about the password' "${E}/.env" | grep -q "^DB_PASSWORD='p#ss \"x\"'$" \
    && pass "…comments above and below a key move with it; quoted values untouched" || fail "comments: $(cat "${E}/.env")"
grep -q '^export QUEUE_CONNECTION=redis$' "${E}/.env" && [[ "$(grep -c '^APP_ENV=' "${E}/.env")" == 2 ]] && [[ "$(grep -A1 '^APP_ENV=production' "${E}/.env")" == *staging* ]] \
    && pass "…export kept; a key set twice moves as one" || fail "export/dup: $(cat "${E}/.env")"
[[ "$(er _env_to_json "${E}/orig.env" | jq -S -c .)" == "$(er _env_to_json "${E}/.env" | jq -S -c .)" ]] && pass "…the same variables and values" || fail "values changed"
cp "${E}/.env" "${E}/before.env"
for o in "APP_NAME" "DB_HOST,DB_HOST,DB_PASSWORD,QUEUE_CONNECTION,APP_KEY,APP_NAME,APP_ENV" "NOPE,DB_HOST,DB_PASSWORD,QUEUE_CONNECTION,APP_KEY,APP_NAME,APP_ENV" "db-host"; do
    er _env_reorder "${E}/.env" "$o" >/dev/null && fail "order '${o}' accepted"
done
cmp -s "${E}/.env" "${E}/before.env" && pass "…a missing, repeated, unknown or invalid key: refused, file untouched" || fail "refusal changed the file"
grep -q -- '--order=\*) order=' "${LIB}/app.sh" && grep -q 'Order not applied' "${LIB}/app.sh" && pass "cipi app env --order (after --set/--unset)" || fail "--order flag"

# ── cipi deploy (deploy.sh) ──────────────────────────────────
grep -qF '<<< "$(_deploy_live_pids "$app")"' "${LIB}/deploy.sh" && pass "cipi deploy refuses while Deployer runs, removes a stale lock" || fail "deploy.sh lock check"
grep -q 'cipi-paused-commit' "${LIB}/deploy.sh" && grep -q 'paused_commit:' "${LIB}/deploy.sh" && pass "deploy by hand, --unlock and --status know the paused commit" || fail "deploy.sh pause"

echo ""
echo "=== ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]

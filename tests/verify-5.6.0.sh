#!/bin/bash
# Local regression checks for 5.6.0 — the app create wizard opens with menus
# (type, runtime, database engine) and asks for the asset build; the deploy key
# is tested against the repository on create, edit and `cipi git check`, with
# the forge-token offer on a terminal; backup profiles ship to named S3
# destinations (`cipi backup destination`), the existing bucket staying the
# default; a database restore that does not complete is reported as failed
# (psql ON_ERROR_STOP=1, the client's first error shown, a dump that does not
# uncompress fails, a newer PostgreSQL preamble adapted to this server).
# Run from repo root: bash tests/verify-5.6.0.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/lib"
PASS=0
FAIL=0

pass() { echo "  OK: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

echo "=== Cipi 5.6.0 regression checks ==="

# Everything below is created, stubbed and removed under $TMP.
TMP=$(mktemp -d) || { echo "mktemp failed" >&2; exit 1; }
[[ -n "$TMP" && -d "$TMP" && "$TMP" != "/" ]] || { echo "no temp directory" >&2; exit 1; }
trap 'rm -rf "${TMP:?}"' EXIT
mkdir -p "${TMP}/bin" "${TMP}/cfg" "${TMP}/log"

# A command run on a pseudo-terminal with scripted input, for the menus and
# the token prompt: ptyrun <input-file> <timeout-seconds> <cmd...>
cat > "${TMP}/ptyrun.py" <<'PY'
import os, pty, sys, select, subprocess, time, signal
inp = open(sys.argv[1], 'rb').read(); tmo = float(sys.argv[2]); cmd = sys.argv[3:]
m, s = pty.openpty()
p = subprocess.Popen(cmd, stdin=s, stdout=s, stderr=s, close_fds=True, preexec_fn=os.setsid)
os.close(s)
os.write(m, inp)
out = b''; end = time.time() + tmo; rc = None
while True:
    if rc is None and p.poll() is not None:
        rc = p.returncode
    r, _, _ = select.select([m], [], [], 0.2)
    if r:
        try:
            d = os.read(m, 4096)
        except OSError:
            d = b''
        if not d:
            break
        out += d
        continue
    if rc is not None:
        break
    if time.time() > end:
        os.killpg(p.pid, signal.SIGKILL); rc = 124; break
if rc is None:
    p.wait(); rc = p.returncode
sys.stdout.write(out.decode('utf-8', 'replace').replace('\r', ''))
sys.exit(rc)
PY
ptyrun() { python3 -I "${TMP}/ptyrun.py" "$@"; }

# ── syntax ───────────────────────────────────────────────────
echo "-- syntax"
for f in common.sh app.sh git.sh backup.sh yml.sh completion.sh; do
    bash -n "${LIB}/${f}" && pass "${f} parses" || fail "${f} does not parse"
done
bash -n "${ROOT}/cipi" && pass "cipi parses" || fail "cipi does not parse"

# ── read_choice ──────────────────────────────────────────────
echo "-- read_choice: numbered menu with a default"
cat > "${TMP}/rc.sh" <<EOF
export CIPI_LIB="${LIB}" CIPI_CONFIG="${TMP}/cfg" CIPI_LOG="${TMP}/log"
RED=; GREEN=; YELLOW=; CYAN=; DIM=; NC=; BOLD=
source "${LIB}/common.sh" 2>/dev/null
read_choice "App type" "laravel" v "laravel|Laravel app" "custom|Plain site" "ssr|Node server"
echo "CHOSEN=\$v"
EOF
out=$(bash "${TMP}/rc.sh" </dev/null 2>&1)
[[ "$out" == "CHOSEN=laravel" ]] && pass "without a terminal the default is taken, nothing printed" || fail "non-tty: ${out}"
printf '\n' > "${TMP}/in"; out=$(ptyrun "${TMP}/in" 10 bash "${TMP}/rc.sh")
grep -q 'CHOSEN=laravel' <<< "$out" && grep -q '1) laravel' <<< "$out" && grep -q '(default)' <<< "$out" \
    && pass "Enter takes the default, the menu marks it" || fail "tty default: ${out}"
printf '3\n' > "${TMP}/in"; out=$(ptyrun "${TMP}/in" 10 bash "${TMP}/rc.sh")
grep -q 'CHOSEN=ssr' <<< "$out" && pass "a number picks an option" || fail "tty number: ${out}"
printf 'custom\n' > "${TMP}/in"; out=$(ptyrun "${TMP}/in" 10 bash "${TMP}/rc.sh")
grep -q 'CHOSEN=custom' <<< "$out" && pass "the value itself is accepted" || fail "tty value: ${out}"
printf '9\nfoo\n2\n' > "${TMP}/in"; out=$(ptyrun "${TMP}/in" 10 bash "${TMP}/rc.sh")
grep -q 'CHOSEN=custom' <<< "$out" && [[ "$(grep -c 'Choose 1-3' <<< "$out")" -eq 2 ]] \
    && pass "an invalid answer asks again" || fail "tty invalid: ${out}"

# ── app create wiring ────────────────────────────────────────
echo "-- cipi app create: menus, build, access check"
grep -q 'read_choice "App type" "laravel" kind' "${LIB}/app.sh" && pass "the wizard opens with the app type" || fail "no app type menu"
grep -q '"spa|Node, client-side' "${LIB}/app.sh" && grep -q '"static|Node, pre-rendered' "${LIB}/app.sh" \
    && grep -q '"ssr|Node, server-rendered' "${LIB}/app.sh" && grep -q '"custom|Plain PHP' "${LIB}/app.sh" \
    && pass "custom, spa, static and ssr are offered" || fail "menu options missing"
grep -q 'read_choice "Runtime" "fpm" runtime' "${LIB}/app.sh" && grep -q 'ARG_octane="frankenphp"' "${LIB}/app.sh" \
    && pass "Laravel asks FPM or Octane, Octane maps to --octane" || fail "no runtime menu"
grep -q 'read_choice "Database engine" "$default_engine" db_engine' "${LIB}/app.sh" \
    && pass "the database engine is a menu with the server default" || fail "no engine menu"
grep -q 'read_choice "Framework" "next" fw' "${LIB}/app.sh" && grep -q 'read_choice "Framework" "vite" fw' "${LIB}/app.sh" \
    && pass "Node apps choose a framework" || fail "no framework menu"
grep -q '\-t 0 && "$is_custom" != "true" && -z "${ARG_octane+x}" && -z "${ARG_node+x}" && -z "${ARG_framework:-}"' "${LIB}/app.sh" \
    && pass "menus only on a terminal and without a type flag" || fail "menu guard changed"
menu=$(grep -n 'read_choice "App type"' "${LIB}/app.sh" | head -1 | cut -d: -f1)
engine=$(grep -n 'read_choice "Database engine"' "${LIB}/app.sh" | head -1 | cut -d: -f1)
user=$(grep -n 'read_input "App username' "${LIB}/app.sh" | head -1 | cut -d: -f1)
[[ -n "$menu" && -n "$engine" && -n "$user" && "$menu" -lt "$engine" && "$engine" -lt "$user" ]] \
    && pass "order: type, runtime, engine, then the details" || fail "prompt order: menu=${menu} engine=${engine} user=${user}"
grep -q 'read_input "Build command" "" node_build' "${LIB}/app.sh" \
    && grep -q '_validate_node_build_cmd "$node_build"' "${LIB}/app.sh" \
    && grep -q 'app_set "$app_user" node_build "$node_build"' "${LIB}/app.sh" \
    && grep -q '_sync_node_build_script "$app_user"' "${LIB}/app.sh" \
    && pass "the asset build is asked, validated, stored and written to node-build.sh" || fail "build prompt wiring"
grep -q '"--node-build is for Laravel apps' "${LIB}/app.sh" && pass "--node-build refused on custom and Node apps" || fail "no --node-build guard"
php=$(grep -n 'read_input "PHP version"' "${LIB}/app.sh" | head -1 | cut -d: -f1)
build=$(grep -n 'read_input "Build command" "" node_build' "${LIB}/app.sh" | head -1 | cut -d: -f1)
[[ -n "$php" && -n "$build" && "$php" -lt "$build" ]] && pass "the build is asked after the PHP version" || fail "build prompt position"
grep -q 'git_verify_repo_access "$app_user" "$repository" "$branch" "$url_host" "$webhook_token" "$deploy_key"' "${LIB}/app.sh" \
    && grep -q 'git_verify_repo_access "$app_user" "$repository" "$branch" "$url_host" "" "$deploy_key" "skip_webhook"' "${LIB}/app.sh" \
    && pass "app create tests the deploy key (webhook skipped for custom apps)" || fail "create access check"
[[ "$(grep -c '_app_summary_repo_access "$app_user" "$branch"' "${LIB}/app.sh")" -eq 3 ]] \
    && pass "every summary (Laravel, custom, Node) reports the access" || fail "summary access line"
grep -q 'git_verify_repo_access "$app" "$cur_repo" "${cur_branch:-main}"' "${LIB}/app.sh" \
    && [[ "$(grep -c 'repo_changed=true' "${LIB}/app.sh")" -eq 2 ]] \
    && pass "app edit --repository / --branch run the check" || fail "edit access check"
grep -q 'Build: ${node_build:-none}' "${LIB}/app.sh" && grep -q 'Repository access: ${GIT_REPO_ACCESS:-not checked}' "${LIB}/app.sh" \
    && pass "the app-created mail carries build and access" || fail "mail lines"
grep -q 'bitbucket)  echo "Bitbucket: Repository settings' "${LIB}/app.sh" && grep -q 'azure)      echo "Azure DevOps' "${LIB}/app.sh" \
    && ! grep -q 'GitHub: Settings → Deploy keys · GitLab: Settings → Repository → Deploy keys (read access is enough)' "${LIB}/app.sh" \
    && pass "deploy-key hints name Bitbucket and Azure DevOps" || fail "deploy-key hint"

# ── git: repository access check ─────────────────────────────
echo "-- git: can the deploy key read the repository?"
cat > "${TMP}/bin/timeout" <<'EOS'
#!/bin/bash
shift; exec "$@"
EOS
cat > "${TMP}/bin/sudo" <<'EOS'
#!/bin/bash
while [[ $# -gt 0 ]]; do case "$1" in -u) shift 2 ;; -H) shift ;; *) break ;; esac; done
exec "$@"
EOS
cat > "${TMP}/bin/sleep" <<'EOS'
#!/bin/bash
exit 0
EOS
cat > "${TMP}/bin/git" <<EOS
#!/bin/bash
echo "\$*" >> "${TMP}/git.calls"
printf '%s\n' "\${GIT_SSH_COMMAND:-}" > "${TMP}/git.ssh"
mode=\$(cat "${TMP}/git.mode" 2>/dev/null || echo ok)
if [[ "\$mode" == "token" ]]; then
    grep -q github_token "${TMP}/server.json" 2>/dev/null && mode=ok || mode=denied
fi
case "\$mode" in
    ok)       printf 'abc123\trefs/heads/main\n'; exit 0 ;;
    nobranch) exit 2 ;;
    *) echo "ERROR: Repository not found." >&2
       echo "fatal: Could not read from remote repository." >&2
       exit 128 ;;
esac
EOS
cat > "${TMP}/bin/curl" <<'EOS'
#!/bin/bash
url="${*: -1}"
case "$url" in
    */keys)  printf '{"id": 42}\n201\n' ;;
    */hooks) printf '{"id": 7}\n201\n' ;;
    *)       printf '{}\n200\n' ;;
esac
EOS
chmod +x "${TMP}/bin/"*
echo '{}' > "${TMP}/server.json"
echo '{"shop":{"domain":"shop.test","php":"8.4","branch":"main","repository":"git@github.com:acme/shop.git","webhook_token":"wt1"}}' > "${TMP}/apps.json"
cat > "${TMP}/ga.sh" <<EOF
export CIPI_LIB="${LIB}" CIPI_CONFIG="${TMP}/cfg" CIPI_LOG="${TMP}/log"
export PATH="${TMP}/bin:\$PATH"
RED=; GREEN=; YELLOW=; CYAN=; DIM=; NC=; BOLD=
source "${LIB}/common.sh" 2>/dev/null
info(){ echo "INFO \$*"; }; warn(){ echo "WARN \$*"; }; success(){ echo "OK \$*"; }; step(){ :; }
error(){ echo "ERR \$*"; }
vault_read(){ case "\$1" in server.json) cat "${TMP}/server.json" ;; apps.json) cat "${TMP}/apps.json" ;; *) echo '{}' ;; esac; }
# like the real vault_write: a temp file, then mv — the reader of the same pipeline must not see a truncated file
vault_write(){ case "\$1" in server.json|apps.json) cat > "${TMP}/\$1.tmp" && mv "${TMP}/\$1.tmp" "${TMP}/\$1" ;; *) cat >/dev/null ;; esac; }
log_action(){ :; }; cipi_notify(){ :; }; ensure_apps_json_api_access(){ :; }
app_get(){ jq -r --arg a "\$1" --arg k "\$2" '.[\$a][\$k] // empty' "${TMP}/apps.json"; }
app_exists(){ [[ "\$1" == shop ]]; }
domain_url_host(){ printf '%s' "\$1"; }
source "${LIB}/git.sh"
if [[ "\${1:-}" == "check" ]]; then shift; ( _git_check "\$@" ); echo "RC=\$?"; exit 0; fi
git_verify_repo_access "\$@"; rc=\$?
echo "RC=\${rc} ACCESS=\${GIT_REPO_ACCESS} KEY=\${GIT_DEPLOY_KEY_ID:-} HOOK=\${GIT_WEBHOOK_ID:-}"
EOF
ga() { rm -f "${TMP}/git.calls"; bash "${TMP}/ga.sh" "$@" </dev/null 2>&1; }

echo ok > "${TMP}/git.mode"
out=$(ga shop git@github.com:acme/shop.git main)
grep -q 'RC=0 ACCESS=ok' <<< "$out" && grep -q "branch 'main' found" <<< "$out" \
    && pass "a readable repository: ok" || fail "ok case: ${out}"
grep -q 'ls-remote --exit-code --heads git@github.com:acme/shop.git refs/heads/main' "${TMP}/git.calls" \
    && pass "git ls-remote is asked for the exact branch" || fail "git call: $(cat "${TMP}/git.calls")"
grep -q 'id_ed25519' "${TMP}/git.ssh" && grep -q 'BatchMode=yes' "${TMP}/git.ssh" \
    && pass "the deploy key is used, no prompt possible" || fail "ssh command: $(cat "${TMP}/git.ssh")"
[[ "$(wc -l < "${TMP}/git.calls")" -eq 1 ]] && pass "no retry when it works" || fail "calls: $(cat "${TMP}/git.calls")"

echo nobranch > "${TMP}/git.mode"
out=$(ga shop git@github.com:acme/shop.git develop)
grep -q 'RC=1 ACCESS=nobranch' <<< "$out" && grep -q "no branch 'develop'" <<< "$out" && grep -q -- '--branch=<name>' <<< "$out" \
    && pass "a missing branch is told apart from no access" || fail "nobranch case: ${out}"

echo denied > "${TMP}/git.mode"
out=$(ga shop git@github.com:acme/shop.git main)
grep -q 'RC=1 ACCESS=denied' <<< "$out" && grep -q 'Repository not found' <<< "$out" \
    && pass "a refused read is reported with git's reason" || fail "denied case: ${out}"
[[ "$(wc -l < "${TMP}/git.calls")" -eq 2 ]] && pass "a refused read is tried once more" || fail "retry: $(cat "${TMP}/git.calls")"
grep -q 'cipi git github-token <token> && cipi git refresh shop' <<< "$out" && grep -q 'Save a GitHub token' <<< "$out" \
    && grep -q 'cipi git check shop' <<< "$out" \
    && pass "without a token: the command to save one, then refresh" || fail "hints (no token): ${out}"
echo '{"github_token":"ghp_old"}' > "${TMP}/server.json"
out=$(ga shop git@github.com:acme/shop.git main)
grep -q 'Renew the GitHub token' <<< "$out" && grep -q 'cipi git github-token <token> && cipi git refresh shop' <<< "$out" \
    && pass "with a token: renew it, then refresh" || fail "hints (token): ${out}"
echo '{}' > "${TMP}/server.json"
out=$(ga shop git@git.example.com:acme/shop.git main)
grep -q -- '--trust-host' <<< "$out" && grep -q 'cipi deploy shop --key' <<< "$out" \
    && pass "an unknown host: where the key goes and --trust-host" || fail "hints (unknown host): ${out}"
out=$(ga shop git@github.com:acme/shop.git main shop.test wt1 "ssh-ed25519 AAAA shop@cipi")
grep -q 'RC=1 ACCESS=denied' <<< "$out" && ! grep -q 'token:' <<< "$out" \
    && pass "without a terminal no token is asked" || fail "non-tty prompt: ${out}"

# On a terminal: say yes, type the token — the key and webhook are registered and the read works.
echo token > "${TMP}/git.mode"; echo '{}' > "${TMP}/server.json"; rm -f "${TMP}/git.calls"
printf 'y\nghp_new_token\n' > "${TMP}/in"
out=$(ptyrun "${TMP}/in" 20 bash "${TMP}/ga.sh" shop git@github.com:acme/shop.git main shop.test wt1 "ssh-ed25519 AAAA shop@cipi")
grep -q 'Save one now and retry' <<< "$out" && pass "on a terminal the token is offered" || fail "token offer: ${out}"
grep -q 'RC=0 ACCESS=ok KEY=42 HOOK=7' <<< "$out" \
    && pass "token saved, deploy key and webhook registered, repository readable" || fail "token flow: ${out}"
[[ "$(jq -r .github_token "${TMP}/server.json")" == "ghp_new_token" ]] && pass "the token is stored" || fail "server.json: $(cat "${TMP}/server.json")"
echo denied > "${TMP}/git.mode"; echo '{}' > "${TMP}/server.json"
printf 'n\n' > "${TMP}/in"
out=$(ptyrun "${TMP}/in" 20 bash "${TMP}/ga.sh" shop git@github.com:acme/shop.git main shop.test wt1 "ssh-ed25519 AAAA shop@cipi")
grep -q 'RC=1 ACCESS=denied' <<< "$out" && grep -q 'cipi git github-token <token>' <<< "$out" \
    && pass "declining leaves the commands to run" || fail "declined: ${out}"

# cipi git check
echo ok > "${TMP}/git.mode"
out=$(ga check shop)
grep -q 'RC=0' <<< "$out" && grep -q 'Repository reachable' <<< "$out" && pass "cipi git check <app>" || fail "git check app: ${out}"
echo denied > "${TMP}/git.mode"
out=$(ga check)
grep -q 'RC=1' <<< "$out" && grep -q '1 app(s) cannot read their repository' <<< "$out" \
    && pass "cipi git check (all) exits 1 when one cannot be read" || fail "git check all: ${out}"
grep -q 'check)             _git_check' "${LIB}/git.sh" && grep -q 'cipi git check \[app\]' "${ROOT}/cipi" \
    && grep -q 'remove-codecommit refresh check' "${LIB}/completion.sh" \
    && pass "cipi git check is dispatched, in help and completion" || fail "git check wiring"

# ── backup: named S3 destinations ────────────────────────────
echo "-- backup: named S3 destinations"
cat > "${TMP}/bin/aws" <<EOS
#!/bin/bash
echo "KEY=\${AWS_ACCESS_KEY_ID:-} ARGS=\$*" >> "${TMP}/aws.log"
if [[ -f "${TMP}/aws.failbucket" ]] && [[ "\$*" == *"\$(cat "${TMP}/aws.failbucket")"* ]]; then
    echo "An error occurred (AccessDenied) when calling the ListObjectsV2 operation" >&2; exit 1
fi
case " \$* " in
    *" ls "*) if [[ -f "${TMP}/aws.has" ]] && [[ "\$*" == *"\$(cat "${TMP}/aws.has")"* ]]; then cat "${TMP}/aws.out" 2>/dev/null; fi ;;
esac
exit 0
EOS
chmod +x "${TMP}/bin/aws"
mkdir -p "${TMP}/local" "${TMP}/tmp" "${TMP}/home/shop/shared"
echo 'APP_KEY=x' > "${TMP}/home/shop/shared/.env"
touch "${TMP}/cfg/backup.json"
cat > "${TMP}/backup.json" <<EOF
{"aws_key":"AKIADEFAULT","aws_secret":"sdef","bucket":"default-bucket","region":"eu-central-1","endpoint_url":"",
 "tmpdir":"${TMP}/tmp","local_dir":"${TMP}/local",
 "s3_destinations":{"offsite":{"bucket":"off-bucket","aws_key":"AKIAOFF","aws_secret":"soff","region":"us-east-1","endpoint_url":"https://s3.example.test","created_at":1}},
 "profiles":{"nightly":{"scope":"files","apps":["*"],"databases":[],"exclude_databases":[],"exclude_tables":[],
   "cron":"0 2 * * *","interval_seconds":86400,"destinations":["local","s3","offsite"],
   "retention":{"keep":0,"days":14,"weeks":0},"encrypt":false,"enabled":true,"created_at":1}}}
EOF
echo '{"shop":{"domain":"shop.test","php":"8.4","custom":false}}' > "${TMP}/apps.json"
cat > "${TMP}/bk.sh" <<EOF
export CIPI_LIB="${LIB}" CIPI_CONFIG="${TMP}/cfg" CIPI_LOG="${TMP}/log"
export PATH="${TMP}/bin:\$PATH"
RED=; GREEN=; YELLOW=; CYAN=; DIM=; NC=; BOLD=
source "${LIB}/common.sh" 2>/dev/null
info(){ echo "INFO \$*"; }; warn(){ echo "WARN \$*"; }; success(){ echo "OK \$*"; }; step(){ echo "STEP \$*"; }
error(){ echo "ERR \$*"; }
vault_read(){ case "\$1" in backup.json) cat "${TMP}/backup.json" ;; apps.json) cat "${TMP}/apps.json" ;; *) echo '{}' ;; esac; }
vault_write(){ case "\$1" in backup.json) cat > "${TMP}/backup.json.tmp" && mv "${TMP}/backup.json.tmp" "${TMP}/backup.json" ;; *) cat >/dev/null ;; esac; }
log_action(){ :; }; cipi_notify(){ :; }
app_get(){ jq -r --arg a "\$1" --arg k "\$2" '.[\$a][\$k] // empty' "${TMP}/apps.json"; }
db_dump_database_ex(){ return 1; }
source "${LIB}/backup.sh"
_bk_write_cron(){ :; }
_ensure_awscli(){ :; }
_bk_app_home(){ echo "${TMP}/home/\$1"; }
"\$@"
EOF
bk() { bash "${TMP}/bk.sh" "$@" </dev/null 2>&1; }

cat > "${TMP}/bkh.sh" <<'EOF'
[[ "$(_bk_s3_names | paste -sd, -)" == "s3,offsite" ]]                        || exit 10
[[ "$(_bk_s3_bucket)" == "default-bucket" ]]                                 || exit 11
[[ "$(_bk_s3_bucket offsite)" == "off-bucket" ]]                             || exit 12
_bk_s3_exists offsite || exit 13
_bk_s3_exists nope    && exit 14
_bk_s3_exists s3      || exit 15
_bk_valid_dest_name offsite || exit 16
_bk_valid_dest_name local   && exit 17
_bk_valid_dest_name s3      || exit 18   # 5.19.1: s3 is an S3 bucket's name like any other
_bk_valid_dest_name 'Bad;'  && exit 19
[[ "$(_bk_s3_uri offsite nightly 2026-01-01_000000)" == "s3://off-bucket/cipi/nightly/2026-01-01_000000/" ]] || exit 20
[[ "$(_bk_s3_uri offsite)" == "s3://off-bucket/cipi/" ]]                     || exit 21
[[ "$(_bk_s3_uri s3 nightly)" == "s3://default-bucket/cipi/nightly/" ]]     || exit 22
_bk_s3_uri nope && exit 23
[[ "$(_bk_dest_profiles offsite)" == "nightly" ]]                            || exit 24
[[ -z "$(_bk_dest_profiles nope)" ]]                                         || exit 25
exit 0
EOF
if bk source "${TMP}/bkh.sh"; then pass "destination helpers: names, buckets, URIs, validation"
else fail "destination helpers (exit $?)"; fi

rm -f "${TMP}/aws.log"; bk _bk_aws offsite ls s3://off-bucket/ >/dev/null
grep -q 'KEY=AKIAOFF' "${TMP}/aws.log" && grep -q -- '--endpoint-url https://s3.example.test' "${TMP}/aws.log" \
    && grep -q -- '--region us-east-1' "${TMP}/aws.log" \
    && pass "a named destination uses its own keys, region and endpoint" || fail "named aws call: $(cat "${TMP}/aws.log")"
rm -f "${TMP}/aws.log"; bk _bk_aws s3 ls s3://default-bucket/ >/dev/null
# 5.19.1: the bucket "s3" uses its own keys like any other (no /root/.aws profile)
grep -q '^KEY=AKIADEFAULT ARGS=s3 --region eu-central-1 ls' "${TMP}/aws.log" && pass "the bucket s3 uses its own keys" || fail "default aws call: $(cat "${TMP}/aws.log")"
out=$(bk _bk_aws nope ls x); [[ $? -ne 0 ]] && grep -q 'unknown backup destination' <<< "$out" \
    && pass "an unknown destination is refused" || fail "unknown dest: ${out}"

# profiles: a destination must exist
cp "${TMP}/backup.json" "${TMP}/backup.json.orig"
out=$(bk _bk_profile_add add shop-db --scope=files --dest=local,nope --keep=3)
grep -q "Unknown destination 'nope'" <<< "$out" && ! jq -e '.profiles["shop-db"]' "${TMP}/backup.json" >/dev/null \
    && pass "profile add refuses a destination that does not exist" || fail "profile add unknown dest: ${out}"
out=$(bk _bk_profile_add add shop-db --scope=files --dest=local,offsite --keep=3)
[[ "$(jq -c '.profiles["shop-db"].destinations' "${TMP}/backup.json")" == '["local","offsite"]' ]] \
    && pass "profile add accepts a named destination" || fail "profile add named dest: ${out}"
cp "${TMP}/backup.json.orig" "${TMP}/backup.json"

# a run ships to every destination with the right credentials
rm -f "${TMP}/aws.log"
out=$(bk _bk_run_profile nightly)
[[ $? -eq 0 ]] && grep -q "Backup 'nightly' complete" <<< "$out" || fail "run: ${out}"
ts=$(ls -1 "${TMP}/local/nightly" 2>/dev/null | head -1)
[[ -n "$ts" && -f "${TMP}/local/nightly/${ts}/apps/shop/files.tar.gz" ]] && pass "run: local copy written" || fail "run: no local copy ($(ls -R "${TMP}/local" 2>/dev/null))"
grep -q "^KEY=AKIADEFAULT ARGS=s3 --region eu-central-1 cp ${TMP}/tmp/cipi-bk-nightly-${ts}/ s3://default-bucket/cipi/nightly/${ts}/ --recursive" "${TMP}/aws.log" \
    && pass "run: uploaded to the bucket s3 with its own keys" || fail "run default upload: $(cat "${TMP}/aws.log")"
grep -q "^KEY=AKIAOFF ARGS=s3 --region us-east-1 --endpoint-url https://s3.example.test cp ${TMP}/tmp/cipi-bk-nightly-${ts}/ s3://off-bucket/cipi/nightly/${ts}/ --recursive" "${TMP}/aws.log" \
    && pass "run: uploaded to the named destination with its own keys" || fail "run named upload: $(cat "${TMP}/aws.log")"
grep -q "s3://off-bucket/cipi/nightly/${ts}/ (offsite)" <<< "$out" && pass "run: the named destination is reported" || fail "run report: ${out}"
rm -rf "${TMP:?}/local/nightly"
echo off-bucket > "${TMP}/aws.failbucket"
out=$(bk _bk_run_profile nightly); rc=$?
[[ $rc -eq 1 ]] && grep -q 'dest:offsite' <<< "$out" && grep -q 'upload to offsite failed' <<< "$out" \
    && pass "run: a failing destination is named and fails the run" || fail "run failing dest: rc=${rc} ${out}"
rm -f "${TMP}/aws.failbucket"; rm -rf "${TMP:?}/local/nightly"

# list / find: every destination is looked at
echo "off-bucket/cipi/nightly/2026-01-01_000000/" > "${TMP}/aws.has"
echo "2026-01-01 00:00:00        123 manifest.json" > "${TMP}/aws.out"
[[ "$(bk _bk_s3_find_run nightly 2026-01-01_000000)" == "offsite" ]] \
    && pass "a run held only by a named destination is found there" || fail "find run"
bk _bk_s3_find_run nightly 2026-02-02_000000 >/dev/null && fail "find run: missing run found" || pass "a run nobody holds is not found"
echo "off-bucket/cipi/nightly/" > "${TMP}/aws.has"
printf '                           PRE 2026-01-01_000000/\n                           PRE 2026-01-02_000000/\n' > "${TMP}/aws.out"
[[ "$(bk _bk_list_runs nightly | sort | paste -sd, -)" == "2026-01-01_000000,2026-01-02_000000" ]] \
    && pass "runs on a named destination count for retention and list" || fail "list runs: $(bk _bk_list_runs nightly)"
rm -f "${TMP}/aws.has" "${TMP}/aws.out"

# destination add/edit/remove/test
out=$(bk _bk_destination_add add eu2 --bucket=eu2-bucket --key=K2 --secret=S2 --region=eu-west-1); rc=$?
[[ $rc -eq 0 ]] && [[ "$(jq -r '.s3_destinations.eu2.bucket' "${TMP}/backup.json")" == "eu2-bucket" ]] \
    && [[ "$(jq -r '.s3_destinations.eu2.aws_key' "${TMP}/backup.json")" == "K2" ]] \
    && jq -e '.s3_destinations.eu2.created_at | numbers' "${TMP}/backup.json" >/dev/null \
    && pass "destination add saves the bucket with its keys" || fail "destination add: rc=${rc} ${out} $(cat "${TMP}/backup.json")"
grep -q 'KEY=K2 ARGS=s3 --region eu-west-1 ls s3://eu2-bucket' "${TMP}/aws.log" \
    && pass "destination add lists the bucket with those keys first" || fail "add test call: $(tail -3 "${TMP}/aws.log")"
[[ "$(jq -r '.bucket' "${TMP}/backup.json")" == "default-bucket" && "$(jq -r '.s3_destinations.offsite.bucket' "${TMP}/backup.json")" == "off-bucket" ]] \
    && pass "the default bucket and the other destinations are untouched" || fail "config after add: $(cat "${TMP}/backup.json")"
echo eu3-bucket > "${TMP}/aws.failbucket"
out=$(bk _bk_destination_add add eu3 --bucket=eu3-bucket --key=K3 --secret=S3); rc=$?
[[ $rc -ne 0 ]] && grep -q 'nothing saved' <<< "$out" && ! jq -e '.s3_destinations.eu3' "${TMP}/backup.json" >/dev/null \
    && pass "an unreachable bucket is not saved" || fail "add unreachable: rc=${rc} ${out}"
rm -f "${TMP}/aws.failbucket"
out=$(bk _bk_destination_add add eu2 --bucket=x --key=k --secret=s); [[ $? -ne 0 ]] && grep -q 'already exists' <<< "$out" \
    && pass "add refuses an existing name" || fail "add existing: ${out}"
out=$(bk _bk_destination_add add s3 --bucket=x --key=k --secret=s); [[ $? -ne 0 ]] && grep -q 'already exists' <<< "$out" \
    && pass "'s3' exists already: add refuses it like any other name (5.19.1)" || fail "add s3: ${out}"
out=$(bk _bk_destination_add add local --bucket=x --key=k --secret=s); [[ $? -ne 0 ]] && grep -q 'Invalid destination name' <<< "$out" \
    && pass "'local' cannot be a destination name" || fail "add local: ${out}"
out=$(bk _bk_destination_add edit eu2 --endpoint=https://eu2.example.test); rc=$?
[[ $rc -eq 0 && "$(jq -r '.s3_destinations.eu2.endpoint_url' "${TMP}/backup.json")" == "https://eu2.example.test" ]] \
    && [[ "$(jq -r '.s3_destinations.eu2.aws_key' "${TMP}/backup.json")" == "K2" ]] \
    && pass "destination edit changes one value and keeps the rest" || fail "edit: rc=${rc} ${out}"
out=$(bk _bk_destination_remove offsite); [[ $? -ne 0 ]] && grep -q 'still used by: nightly' <<< "$out" \
    && jq -e '.s3_destinations.offsite' "${TMP}/backup.json" >/dev/null \
    && pass "remove is refused while a profile uses the destination" || fail "remove used: ${out}"
out=$(bk _bk_destination_remove eu2); [[ $? -eq 0 ]] && ! jq -e '.s3_destinations.eu2' "${TMP}/backup.json" >/dev/null \
    && pass "remove drops an unused destination" || fail "remove unused: ${out}"
out=$(bk _bk_destination_remove s3); [[ $? -ne 0 ]] && grep -q 'still used by' <<< "$out" && pass "the bucket s3 is not removed while a profile uses it" || fail "remove s3: ${out}"
out=$(bk _bk_destination_list)
grep -q 'offsite' <<< "$out" && grep -q 's3://default-bucket' <<< "$out" && ! grep -q '\[default\]' <<< "$out" && grep -q '← nightly' <<< "$out" \
    && pass "destination list shows every bucket on a par, and who uses what" || fail "list: ${out}"
out=$(bk _bk_destination_show offsite)
grep -q 'off-bucket' <<< "$out" && grep -q 'AKIA…AOFF' <<< "$out" && grep -q 'nightly' <<< "$out" \
    && pass "destination show masks the key" || fail "show: ${out}"
echo off-bucket > "${TMP}/aws.failbucket"
out=$(bk _bk_destination_test); rc=$?
[[ $rc -ne 0 ]] && grep -q 'AccessDenied' <<< "$out" && grep -q 'reachable' <<< "$out" \
    && pass "destination test reaches each bucket and fails on the broken one" || fail "test: rc=${rc} ${out}"
rm -f "${TMP}/aws.failbucket"
# profile list: columns sized from the data — a long name or several
# destinations must not push the rest of the row out of line
jq '.profiles["shop-db-quarterly-long"] = (.profiles.nightly | .destinations = ["local","s3","offsite"])' \
    "${TMP}/backup.json" > "${TMP}/backup.json.tmp" && mv "${TMP}/backup.json.tmp" "${TMP}/backup.json"
out=$(bk _bk_profile_list)
cols=$(grep -E '^  (PROFILE|nightly|shop-db-quarterly-long) ' <<< "$out" | awk '{ match($0, /^  [^ ]+ +/); print RLENGTH }' | sort -u | wc -l)
[[ "$cols" -eq 1 ]] && grep -q 'local,s3,offsite' <<< "$out" \
    && pass "profile list: columns line up whatever the name length" || fail "profile list alignment: ${out}"
out=$(bk _bk_status)
grep -q 'offsite' <<< "$out" && grep -q 'S3 (s3)' <<< "$out" && pass "backup status lists named destinations" || fail "status: ${out}"
grep -q 's3_destinations: {}, sftp_destinations: {}, profiles: {}} + . + {tmpdir: $t, local_dir: $l}' "${LIB}/backup.sh" && pass "cipi backup configure keeps the named destinations" || fail "configure drops s3_destinations"
grep -q 'destination|destinations|dest) _bk_destination_command' "${LIB}/backup.sh" \
    && grep -q 'cipi backup destination add <name>' "${ROOT}/cipi" \
    && grep -q 'destination) sub="list show add edit remove test"' "${LIB}/completion.sh" \
    && pass "cipi backup destination is dispatched, in help and completion" || fail "destination wiring"
grep -q '_aws_s3 cp "${tmp}/"' "${LIB}/backup.sh" && fail "the run still uploads with the default profile only" || pass "no upload bypasses the destination"

# ── cipi db create: engine menu ──────────────────────────────
echo "-- cipi db create: MariaDB or PostgreSQL menu"
cat > "${TMP}/dbc.sh" <<EOF
export CIPI_LIB="${LIB}" CIPI_CONFIG="${TMP}/cfg" CIPI_LOG="${TMP}/log"
source "${LIB}/common.sh" 2>/dev/null
source "${LIB}/db.sh"
RED=; GREEN=; YELLOW=; CYAN=; DIM=; NC=; BOLD=
db_ensure_engine_state(){ :; }
db_engine_is_installed(){ [[ "\$1" == mariadb ]] || [[ ! -e "${TMP}/dbc.one" ]]; }
db_get_default_engine(){ echo pgsql; }
db_require_engine(){ echo "\$1"; }
db_create_database(){ echo "CREATED engine=\$1 name=\$2"; }
_db_meta_set(){ :; }; vault_read(){ echo '{}'; }; log_action(){ :; }; cipi_notify(){ :; }
generate_password(){ echo pw; }; step(){ :; }
_db_create "\$@"
EOF
printf '\n' > "${TMP}/in"; out=$(ptyrun "${TMP}/in" 10 bash "${TMP}/dbc.sh" --name=shopdb)
grep -q 'Database engine' <<< "$out" && grep -q 'pgsql.*(default)' <<< "$out" && grep -q 'CREATED engine=pgsql name=shopdb' <<< "$out" \
    && pass "on a terminal the engine is a menu, Enter takes the server default" || fail "db create menu default: ${out}"
printf '1\n' > "${TMP}/in"; out=$(ptyrun "${TMP}/in" 10 bash "${TMP}/dbc.sh" --name=shopdb)
grep -q 'CREATED engine=mariadb name=shopdb' <<< "$out" && pass "a number picks the other engine" || fail "db create menu pick: ${out}"
printf '1\nshopdb\n' > "${TMP}/in"; out=$(ptyrun "${TMP}/in" 10 bash "${TMP}/dbc.sh")
m=$(grep -n 'Database engine' <<< "$out" | head -1 | cut -d: -f1); n=$(grep -n 'Database name' <<< "$out" | head -1 | cut -d: -f1)
[[ -n "$m" && -n "$n" && "$m" -lt "$n" ]] && grep -q 'CREATED engine=mariadb name=shopdb' <<< "$out" \
    && pass "the engine is asked before the name" || fail "db create order: ${out}"
printf '\n' > "${TMP}/in"; out=$(ptyrun "${TMP}/in" 10 bash "${TMP}/dbc.sh" --name=shopdb --engine=mariadb)
! grep -q 'Database engine' <<< "$out" && grep -q 'CREATED engine=mariadb' <<< "$out" \
    && pass "--engine skips the menu" || fail "db create --engine: ${out}"
out=$(bash "${TMP}/dbc.sh" --name=shopdb </dev/null 2>&1)
! grep -q 'Database engine' <<< "$out" && grep -q 'CREATED engine=pgsql' <<< "$out" \
    && pass "without a terminal the default engine, no menu" || fail "db create non-tty: ${out}"
touch "${TMP}/dbc.one"
printf '\n' > "${TMP}/in"; out=$(ptyrun "${TMP}/in" 10 bash "${TMP}/dbc.sh" --name=shopdb)
! grep -q 'Database engine' <<< "$out" && pass "one engine installed: nothing to choose" || fail "db create one engine: ${out}"
rm -f "${TMP}/dbc.one"

# ── tables: columns sized from the data ──────────────────────
echo "-- tables: columns follow the longest value"
bash -n "${LIB}/table.sh" && pass "table.sh parses" || fail "table.sh does not parse"
grep -q 'source "$(dirname "${BASH_SOURCE\[0\]}")/table.sh"' "${LIB}/common.sh" \
    && pass "common.sh loads table.sh from next to itself" || fail "common.sh does not load table.sh"
cat > "${TMP}/tbl.sh" <<EOF
RED=\$(printf '\e[31m'); NC=\$(printf '\e[0m'); BOLD=\$(printf '\e[1m')
source "${LIB}/table.sh"
tbl_start; tbl_align l r l
tbl_head NAME SIZE NOTE
tbl_row "cernuscoinsieme-db-quarterly" "\${RED}12 MB\${NC}" "x"
tbl_row "db" "1.5 GB" ""
tbl_rule
tbl_line "a free line that is much longer than the table and is not measured"
tbl_print
EOF
out=$(bash "${TMP}/tbl.sh" | sed $'s/\x1b\\[[0-9;]*m//g')
l1=$(sed -n 1p <<< "$out"); l2=$(sed -n 2p <<< "$out"); l3=$(sed -n 3p <<< "$out"); l4=$(sed -n 4p <<< "$out")
[[ "$l1" == "  NAME                            SIZE  NOTE" ]] && [[ "$l2" == "  cernuscoinsieme-db-quarterly   12 MB  x" ]] \
    && [[ "$l3" == "  db                            1.5 GB" ]] \
    && pass "widths from the longest value, colours not counted, right-aligned column" || fail "table layout: $(printf '%s|' "$l1" "$l2" "$l3")"
[[ "$l4" == "  $(printf '─%.0s' $(seq 1 $(( ${#l1} - 2 ))))" ]] && pass "a rule spans the table" || fail "rule: ${l4}"
! grep -q ' $' <<< "$out" && pass "no trailing spaces" || fail "trailing spaces: $(grep -n ' $' <<< "$out")"
grep -q '^  a free line that is much longer' <<< "$out" && pass "free lines are printed as they are" || fail "free line"

# app list with a 32-character app name and a long domain
cat > "${TMP}/al.sh" <<EOF
RED=; GREEN=; YELLOW=; CYAN=; DIM=; NC=; BOLD=
CIPI_LIB="${LIB}"
source "${LIB}/table.sh"
eval "\$(bash -c 'CIPI_LIB="\$1"; source "\$2" >/dev/null 2>&1; declare -f app_list' _ "${LIB}" "${LIB}/app.sh")"
vault_read(){ cat "${TMP}/al-apps.json"; }
info(){ :; }; supervisorctl(){ :; }; systemctl(){ :; }
app_list
EOF
cat > "${TMP}/al-apps.json" <<'EOF'
{"cernuscoinsieme2026landingpages":{"domain":"landing.cernuscoinsieme-associazione.example.it","php":"8.4","created_at":"2026-10-03T10:00:00Z"},
 "shop":{"domain":"shop.test","php":"8.5","created_at":"2026-10-04T10:00:00Z","octane":"frankenphp"}}
EOF
out=$(bash "${TMP}/al.sh" 2>&1 | sed 's/●/*/g')   # awk counts bytes; ● is three
c1=$(awk '/cernuscoinsieme2026landingpages/ { print index($0, "8.4") }' <<< "$out")
c2=$(awk '/ shop / { print index($0, "8.5") }' <<< "$out")
ch=$(awk '/APP/ { print index($0, "PHP") }' <<< "$out")
[[ -n "$c1" && "$c1" == "$c2" && "$c1" == "$ch" ]] && pass "app list: a 32-character name and a long domain keep the columns in line" \
    || fail "app list alignment (${ch}/${c1}/${c2}): ${out}"

# no table left on fixed widths where a value can be longer than its column
fixed=0
for pat in '"APP" "DOMAIN" "PHP" "RUNTIME"' '"MOUNT" "SIZE" "USED"' '"APP" "FILES" "DATABASE" "TOTAL"' \
           '"ENGINE" "DATABASE" "USER" "SIZE"' '"TIME (UTC)" "EVENT"' '"APP" "PROVIDER" "DEPLOY KEY"' \
           '"SETTING" "VALUE" "SET BY"' '"CODE" "MATCH" "FROM" "TO"' '"PREFIX" "UPSTREAM" "OPTIONS"' \
           '"APP" "PREFIX" "INDEXES"' '"APP" "ACCESS"' '"ACCOUNT" "CERTIFICATES"' '"APP" "DOMAIN" "PHP" "DB"' \
           '"PROGRAM" "QUEUE" "PROCS"' '"PROFILE" "SCOPE" "SCHEDULE"'; do
    hit=$(grep -rnF "$pat" "${LIB}" | grep -v 'tbl_head' || true)
    [[ -n "$hit" ]] && { fixed=1; echo "    fixed-width header: ${hit}" >&2; }
done
[[ $fixed -eq 0 ]] && pass "every list with variable values uses the table helper" || fail "fixed-width tables left"

# ── cipi.yml ─────────────────────────────────────────────────
echo "-- cipi.yml: named destinations"
yml_ok() {
    local f="$1" app="$2"
    RED= GREEN= YELLOW= CYAN= DIM= NC= BOLD=
    # shellcheck source=/dev/null
    source "${LIB}/yml.sh"
    _yml_parse "$f" "$app"
}
printf 'version: 1\nbackup:\n  profiles:\n    - name: shop-db\n      scope: db\n      every: 30m\n      keep: 48\n      destinations: [s3, offsite]\n' > "${TMP}/d1.yml"
r=$(yml_ok "${TMP}/d1.yml" shop)
[[ "$(jq -r .ok <<< "$r")" == true && "$(jq -c '.data.backup.profiles[0].destinations' <<< "$r")" == '["s3","offsite"]' ]] \
    && pass "a named destination passes validation" || fail "named dest refused: $(jq -c .errors <<< "$r")"
printf 'version: 1\nbackup:\n  profiles:\n    - name: shop-db\n      scope: db\n      every: 30m\n      keep: 48\n      destinations: ["S3!"]\n' > "${TMP}/d2.yml"
r=$(yml_ok "${TMP}/d2.yml" shop)
[[ "$(jq -r .ok <<< "$r")" == false ]] && grep -q 'name of an S3 destination' <<< "$(jq -r '.errors[]' <<< "$r")" \
    && pass "an invalid destination name is refused" || fail "bad dest accepted: $(jq -c . <<< "$r")"

cat > "${TMP}/plan.sh" <<EOF
export CIPI_LIB="${LIB}" CIPI_CONFIG="${TMP}/cfg" CIPI_LOG="${TMP}/log"
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
_YML_APP=shop
_YML_FILE="\$1"
res=\$(_yml_parse "\$1" shop)
_YML_DATA=\$(jq -c .data <<< "\$res")
_yml_build_plan
printf 'A|%s\n' "\${_YML_ACTIONS[@]}"
printf 'B|%s\n' "\${_YML_BLOCKERS[@]}"
EOF
echo '{"shop":{"domain":"shop.test","php":"8.4","custom":false,"runtime":"fpm"}}' > "${TMP}/apps.json"
out=$(bash "${TMP}/plan.sh" "${TMP}/d1.yml" </dev/null 2>/dev/null)
! grep -qE '^B\|[^[:space:]]' <<< "$out" && grep -q 'create backup profile shop-db (s3,offsite)' <<< "$out" \
    && pass "plan: a configured named destination is accepted" || fail "plan named dest: ${out}"
printf 'version: 1\nbackup:\n  profiles:\n    - name: shop-db\n      scope: db\n      every: 30m\n      keep: 48\n      destinations: [local, nope]\n' > "${TMP}/d3.yml"
out=$(bash "${TMP}/plan.sh" "${TMP}/d3.yml" </dev/null 2>/dev/null)
grep -q "^B|backup profile 'shop-db' targets destination 'nope'" <<< "$out" && grep -q 'cipi backup destination add nope' <<< "$out" \
    && pass "plan: a destination not on the server blocks, with the command to run" || fail "plan unknown dest: ${out}"
grep -q 'destinations: \[local, offsite\]   # local and/or destinations by name' "${LIB}/yml.sh" \
    && pass "cipi yml example mentions named destinations" || fail "example"

# The db restore checks have their own stubs (psql, mariadb): own directory.
TMP_MAIN="$TMP"; TMP="${TMP_MAIN}/db"; mkdir -p "$TMP"
# ── db restore ───────────────────────────────────────────────
echo "-- db restore"
bash -n "${LIB}/db.sh" && pass "db.sh parses" || fail "db.sh does not parse"
grep -q 'ON_ERROR_STOP=0' "${LIB}/db.sh" \
    && fail "a psql call still tolerates SQL errors (ON_ERROR_STOP=0)" || pass "no psql call tolerates SQL errors"
grep -q 'db_restore_database "$engine" "$name" "$file" || { error "Restore failed"; exit 1; }' "${LIB}/db.sh" \
    && pass "cipi db restore exits 1 on a failed restore" || fail "cipi db restore does not fail on a failed restore"

# db.sh against stubbed clients. psql answers the settings query with a fixed
# list, otherwise records what it was fed and fails when asked to.
mkdir -p "${TMP}/bin"
cat > "${TMP}/bin/psql" <<EOS
#!/bin/bash
if [[ "\$*" == *pg_settings* ]]; then
    [[ -e "${TMP}/settings.off" ]] && exit 1
    printf 'statement_timeout\nlock_timeout\nclient_encoding\nstandard_conforming_strings\n'
    exit 0
fi
echo "\$*" > "${TMP}/psql.args"
cat > "${TMP}/psql.in"
if [[ -e "${TMP}/psql.fail" ]]; then echo 'ERROR:  relation "users" already exists' >&2; exit 3; fi
exit 0
EOS
cat > "${TMP}/bin/mariadb" <<EOS
#!/bin/bash
cat > "${TMP}/mariadb.in"
if [[ -e "${TMP}/mariadb.fail" ]]; then echo 'ERROR 1064 (42000) at line 2: You have an error in your SQL syntax' >&2; exit 1; fi
exit 0
EOS
chmod +x "${TMP}/bin/"*
cat > "${TMP}/rs.sh" <<EOS
set -u
RED=''; GREEN=''; YELLOW=''; CYAN=''; DIM=''; NC=''; BOLD=''
CIPI_LIB="${LIB}"
info(){ :; }; warn(){ :; }; success(){ :; }; step(){ :; }
error(){ echo "\$*" >> "${TMP}/errors"; }
vault_read(){ echo '{}'; }
export PATH="${TMP}/bin:\$PATH"
source "${LIB}/db.sh"
# stubs after the source, which defines the real ones
db_get_root_password(){ echo pw; }
db_restore_database "\$@"
EOS
restore() { rm -f "${TMP}/errors" "${TMP}/psql.in" "${TMP}/psql.args" "${TMP}/mariadb.in"; bash "${TMP}/rs.sh" "$@"; }
# What psql was fed: BEGIN, the wipe, the owner, the dump, COMMIT. framed: the
# session is that one transaction. body: the dump part of it. committed: a
# COMMIT went out, so whatever came before it is now in the database.
framed() {
    [[ "$(sed -n 1p "${TMP}/psql.in")" == "BEGIN;" ]] \
        && sed -n 2p "${TMP}/psql.in" | grep -q '^DROP SCHEMA public CASCADE; CREATE SCHEMA public;$' \
        && sed -n 3p "${TMP}/psql.in" | grep -q 'ALTER SCHEMA public OWNER TO %I.*pg_get_userbyid(datdba)' \
        && [[ "$(tail -n1 "${TMP}/psql.in")" == "COMMIT;" ]]
}
body() { sed '1,3d;$d' "${TMP}/psql.in"; }
committed() { grep -q '^COMMIT;$' "${TMP}/psql.in" 2>/dev/null; }

# A pg_dump 17 preamble (unknown transaction_timeout) and a body with traps:
# a COPY data line that looks like SET, and a SET past the preamble whose
# parameter the stubbed server does not know either (must stay).
cat > "${TMP}/dump.sql" <<'SQL'
--
-- PostgreSQL database dump
--

\restrict k3y

-- Dumped from database version 17.2
-- Dumped by pg_dump version 17.2

SET statement_timeout = 0;
SET lock_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);

--
-- Name: notes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notes (body text);

SET default_tablespace = '';

COPY public.notes (body) FROM stdin;
SET weird_param = 1;
\.

\unrestrict k3y
SQL
grep -v '^SET transaction_timeout = 0;$' "${TMP}/dump.sql" > "${TMP}/expected.sql"

rm -f "${TMP}/psql.fail" "${TMP}/settings.off"
if restore pgsql shop "${TMP}/dump.sql"; then pass "pgsql restore succeeds"; else fail "pgsql restore failed (exit $?)"; fi
grep -q 'ON_ERROR_STOP=1' "${TMP}/psql.args" && pass "psql runs with ON_ERROR_STOP=1" || fail "psql args: $(cat "${TMP}/psql.args")"
framed && pass "wipe, owner and dump in one transaction, COMMIT last" \
    || fail "session not framed: $(head -3 "${TMP}/psql.in" | cut -c1-60 | tr '\n' '|') ... $(tail -n1 "${TMP}/psql.in")"
! grep -q 'OWNER TO "shop"' "${TMP}/psql.in" && pass "schema goes to the database's owner, not to a role named after the database" \
    || fail "schema given to a role named after the database"
if cmp -s <(body) "${TMP}/expected.sql"; then
    pass "preamble SET of a parameter this server lacks is dropped; the rest is untouched"
else
    fail "filtered dump differs: $(diff "${TMP}/expected.sql" <(body) | head -5 | tr '\n' '|')"
fi
grep -q '^SET weird_param = 1;$' "${TMP}/psql.in" && pass "COPY data line starting with SET goes through" || fail "COPY data line dropped"
grep -q "^SET default_tablespace = '';$" "${TMP}/psql.in" && pass "SET past the preamble goes through" || fail "body SET dropped"
grep -q '^\\restrict k3y$' "${TMP}/psql.in" && pass "\\restrict kept" || fail "\\restrict dropped"
[[ ! -e "${TMP}/errors" ]] && pass "no error printed on success" || fail "error printed on success: $(cat "${TMP}/errors")"

gzip -c "${TMP}/dump.sql" > "${TMP}/dump.sql.gz"
if restore pgsql shop "${TMP}/dump.sql.gz" && framed && cmp -s <(body) "${TMP}/expected.sql"; then
    pass "gzipped dump restored through the same filter"
else fail "gzipped dump: exit $? / $(diff "${TMP}/expected.sql" <(body) | head -3 | tr '\n' '|')"; fi

touch "${TMP}/settings.off"
if restore pgsql shop "${TMP}/dump.sql" && framed && cmp -s <(body) "${TMP}/dump.sql"; then
    pass "settings unreadable: the dump passes unchanged"
else fail "settings unreadable: dump altered or restore failed"; fi
rm -f "${TMP}/settings.off"

touch "${TMP}/psql.fail"
if restore pgsql shop "${TMP}/dump.sql"; then fail "a failed import reported as restored"
else pass "a failed import returns non-zero"; fi
grep -q 'PostgreSQL restore: ERROR: relation "users" already exists' "${TMP}/errors" 2>/dev/null \
    && pass "psql's first error is shown" || fail "error not shown: $(cat "${TMP}/errors" 2>/dev/null)"
rm -f "${TMP}/psql.fail"

printf 'this is not gzip\n' > "${TMP}/bad.sql.gz"
if restore pgsql shop "${TMP}/bad.sql.gz"; then fail "a dump that does not uncompress reported as restored"
else pass "a dump that does not uncompress fails"; fi
grep -qi 'gzip' "${TMP}/errors" 2>/dev/null && pass "gunzip's error is shown" || fail "gunzip error not shown: $(cat "${TMP}/errors" 2>/dev/null)"
! committed && pass "no COMMIT after a dump that does not uncompress: the wipe rolls back" || fail "COMMIT sent after a broken archive"

# A dump that holds nothing must not commit the wipe. The file's size cannot
# tell: a backup taken while pg_dump failed is a valid 20-byte archive of
# nothing (db_dump_database gzips whatever pg_dump left, errors discarded).
: | gzip > "${TMP}/nothing.sql.gz"
if restore pgsql shop "${TMP}/nothing.sql.gz"; then fail "an archive of nothing reported as restored"
else pass "an archive of nothing fails"; fi
! committed && pass "no COMMIT after an archive of nothing: the wipe rolls back" || fail "COMMIT sent after an archive of nothing"
grep -q 'PostgreSQL restore: the dump is empty' "${TMP}/errors" 2>/dev/null && pass "the empty dump is named as the reason" \
    || fail "reason not shown: $(cat "${TMP}/errors" 2>/dev/null)"
: > "${TMP}/zero.sql"
if restore pgsql shop "${TMP}/zero.sql" || committed; then fail "a zero-byte dump committed the wipe"
else pass "a zero-byte dump fails without COMMIT"; fi
printf '\n  \n' > "${TMP}/blank.sql"
if restore pgsql shop "${TMP}/blank.sql" || committed; then fail "a blank dump committed the wipe"
else pass "a blank dump fails without COMMIT"; fi

printf 'CREATE TABLE t (id int);\n' > "${TMP}/m.sql"
rm -f "${TMP}/mariadb.fail"
if restore mariadb shop "${TMP}/m.sql" && cmp -s "${TMP}/mariadb.in" "${TMP}/m.sql"; then pass "mariadb restore feeds the dump"
else fail "mariadb restore"; fi
gzip -c "${TMP}/m.sql" > "${TMP}/m.sql.gz"
if restore mariadb shop "${TMP}/m.sql.gz" && cmp -s "${TMP}/mariadb.in" "${TMP}/m.sql"; then pass "mariadb gzipped restore"
else fail "mariadb gzipped restore"; fi
touch "${TMP}/mariadb.fail"
if restore mariadb shop "${TMP}/m.sql"; then fail "mariadb failed import reported as restored"
else pass "mariadb failed import returns non-zero"; fi
grep -q 'MariaDB restore: ERROR 1064' "${TMP}/errors" 2>/dev/null && pass "mariadb's error is shown" || fail "mariadb error not shown: $(cat "${TMP}/errors" 2>/dev/null)"
rm -f "${TMP}/mariadb.fail"

if restore sqlite shop "${TMP}/m.sql"; then fail "unknown engine accepted"; else pass "unknown engine refused"; fi
TMP="$TMP_MAIN"

# ── docs ─────────────────────────────────────────────────────
echo "-- docs"
[[ "$(tr -d '[:space:]' < "${ROOT}/version.md")" == "5.6.0" ]] && pass "version.md is 5.6.0" || fail "version.md is not 5.6.0"
grep -q '^## \[5.6.0\]' "${ROOT}/CHANGELOG.md" && pass "CHANGELOG has 5.6.0" || fail "CHANGELOG lacks 5.6.0"
grep -q 'cipi backup destination add' "${ROOT}/README.md" && grep -q 'cipi git check' "${ROOT}/README.md" \
    && grep -q 'a menu: Laravel (default)' "${ROOT}/README.md" \
    && pass "README documents the wizard, destinations and the access check" || fail "README"
grep -q 'cipi backup destination add <name> --bucket=' "${ROOT}/CHANGELOG.md" && grep -q 'cipi git check \[app\]' "${ROOT}/CHANGELOG.md" \
    && grep -q 'read_choice\|numbered menus' "${ROOT}/CHANGELOG.md" \
    && pass "CHANGELOG covers the four changes" || fail "CHANGELOG content"
grep -q '\[--node-build=CMD\]' "${ROOT}/cipi" && pass "help shows --node-build on app create" || fail "help app create"

echo ""
echo "Passed: ${PASS}  Failed: ${FAIL}"
[[ "$FAIL" -eq 0 ]]

#!/bin/bash
# Local regression checks for 5.2.3 — hide cipi.yml from the web, post-deploy.
# Run from repo root: bash tests/verify-5.2.3.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/lib"
PASS=0
FAIL=0

pass() { echo "  OK: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

echo "=== Cipi 5.2.3 regression checks ==="

[[ "$(tr -d '[:space:]' < "${ROOT}/version.md")" == "5.2.3" ]] \
    && pass "version.md is 5.2.3" || fail "version.md is not 5.2.3"
grep -q '^## \[5.2.3\]' "${ROOT}/CHANGELOG.md" \
    && pass "CHANGELOG has a 5.2.3 entry" || fail "CHANGELOG has no 5.2.3 entry"
grep -q 'was a public URL on custom apps' "${ROOT}/CHANGELOG.md" \
    && pass "CHANGELOG documents the cipi.yml web leak" || fail "CHANGELOG omits the cipi.yml web leak"

echo "-- syntax"
for f in "${LIB}/app.sh" "${LIB}/yml.sh" "${LIB}/migrations/5.2.3.sh" \
         "${LIB}/cipi-app-post-deploy.sh" "${LIB}/cipi-app-deploy.sh" \
         "${LIB}/stack-upgrade.sh" "${LIB}/nginx.sh" "${LIB}/db.sh" \
         "${LIB}/service.sh" "${LIB}/git.sh" "${LIB}/crowdsec.sh" \
         "${LIB}/completion.sh" "${LIB}/deploy.sh" "${ROOT}/cipi"; do
    if bash -n "$f" 2>/dev/null; then
        pass "syntax $(basename "$f")"
    else
        fail "syntax $(basename "$f")"
        bash -n "$f" || true
    fi
done

echo "-- nginx denies cipi.yml"
grep -q '_nginx_cipi_yml_deny_block' "${LIB}/app.sh" \
    && pass "helper _nginx_cipi_yml_deny_block exists" || fail "no deny helper"
# Three vhost flavours (custom / octane / php-fpm) must all emit it.
n=$(grep -c '${cipi_yml_deny}' "${LIB}/app.sh" || true)
[[ "$n" -eq 3 ]] && pass "all three vhost templates include the deny" \
    || fail "expected 3 \${cipi_yml_deny} insertions, got ${n}"
grep -qF 'cipi\.ya?ml$' "${LIB}/app.sh" \
    && pass "deny matches cipi.yml and cipi.yaml (any path, any case)" \
    || fail "deny regex is missing or too narrow"

echo "-- rendered vhosts"
_render_vhost() {
    local kind="$1"
    bash -c '
        set -euo pipefail
        cd "'"${ROOT}"'"
        source lib/common.sh 2>/dev/null || true
        kind="'"$kind"'"
        app_get() {
            case "$2" in
                custom) [[ "$kind" == custom ]] && echo "true" || echo "" ;;
                docroot) echo "" ;;
                *) echo "" ;;
            esac
        }
        vault_read() { echo "{}"; }
        _ensure_nginx_octane_map() { :; }
        source lib/app.sh
        tmp=$(mktemp -d); mkdir -p "${tmp}/etc/nginx/sites-available"
        declare -f _nginx_cipi_yml_deny_block _nginx_reverb_location_block _create_nginx_vhost \
            | sed "s#/etc/nginx/#${tmp}/etc/nginx/#g" > "${tmp}/v.sh"
        source "${tmp}/v.sh"
        if [[ "$kind" == custom ]]; then
            _create_nginx_vhost demo example.com 8.5 "" custom
        else
            _create_nginx_vhost demo example.com 8.5
        fi
        cat "${tmp}/etc/nginx/sites-available/demo"
        rm -rf "$tmp"
    ' 2>&1
}

custom_out=$(_render_vhost custom)
if grep -qF 'location ~* /cipi\.ya?ml$ { deny all; }' <<< "$custom_out"; then
    pass "custom vhost denies /cipi.yml"
else
    fail "custom vhost missing deny: ${custom_out}"
fi
grep -q 'root /home/demo/htdocs;' <<< "$custom_out" \
    && pass "custom vhost document root is htdocs/" \
    || fail "custom vhost root is not htdocs/: ${custom_out}"

laravel_out=$(_render_vhost laravel)
if grep -qF 'location ~* /cipi\.ya?ml$ { deny all; }' <<< "$laravel_out"; then
    pass "Laravel vhost denies /cipi.yml too"
else
    fail "Laravel vhost missing deny: ${laravel_out}"
fi
grep -q 'root /home/demo/current/public;' <<< "$laravel_out" \
    && pass "Laravel vhost document root is still current/public" \
    || fail "Laravel vhost root drifted: ${laravel_out}"

echo "-- lookup on custom apps"
grep -q '"/home/${app}/htdocs/cipi.yml"' "${LIB}/yml.sh" \
    && pass "_yml_find_file looks in htdocs/cipi.yml" || fail "_yml_find_file skips htdocs"
grep -q '"/home/${app}/htdocs/cipi.yaml"' "${LIB}/yml.sh" \
    && pass "_yml_find_file looks in htdocs/cipi.yaml" || fail "_yml_find_file skips htdocs yaml"
grep -q 'file=$(_yml_find_file "$app")' "${LIB}/yml.sh" \
    && pass "post-deploy uses _yml_find_file (so htdocs is covered)" \
    || fail "post-deploy still hardcodes current/shared only"
grep -q 'htdocs/cipi.yml' "${ROOT}/cipi" \
    && pass "help lists htdocs/ among lookup paths" || fail "help omits htdocs/"

echo "-- migration injects in place (does not regenerate)"
M="${LIB}/migrations/5.2.3.sh"
[[ -f "$M" ]] && pass "migration 5.2.3 exists" || fail "migration 5.2.3 missing"
grep -q '_inject_cipi_yml_deny' "$M" \
    && pass "migration injects the deny into existing vhosts" || fail "migration does not inject"
grep -q '_create_nginx_vhost' "$M" \
    && fail "migration regenerates vhosts (would drop certbot :443)" \
    || pass "migration does not regenerate vhosts"
grep -q 'vhost-backup-5.2.3' "$M" \
    && pass "migration backs up vhosts before editing" || fail "migration has no vhost backup"

# Exercise the injector against a fixture with HTTP + cloned :443 blocks.
inject_out=$(bash -c '
    set -euo pipefail
    # The migration is a script, not a library — extract only the function.
    eval "$(sed -n "/^_inject_cipi_yml_deny()/,/^}/p" "'"$M"'")"
    tmp=$(mktemp)
    cat > "$tmp" <<'"'"'NGX'"'"'
server {
    listen 80;
    root /home/demo/htdocs;
    location / { try_files $uri /index.php; }
    location ~ /\.(?!well-known) { deny all; }
}
server {
    listen 443 ssl;
    location ~ /\.(?!well-known) { deny all; }
}
NGX
    _inject_cipi_yml_deny "$tmp" || { echo "INJECT_FAIL"; cat "$tmp"; rm -f "$tmp"; exit 0; }
    n=$(grep -c cipi "$tmp" || true)
    echo "COUNT=${n}"
    grep "cipi" "$tmp" || true
    _inject_cipi_yml_deny "$tmp" && echo "NOT_IDEMPOTENT" || echo "IDEMPOTENT"
    rm -f "$tmp"
' 2>&1)
if grep -q 'COUNT=2' <<< "$inject_out" && grep -q 'IDEMPOTENT' <<< "$inject_out"; then
    pass "injector writes one deny per server block and is idempotent"
else
    fail "injector: ${inject_out}"
fi

echo "-- stack upgrades"
SU="${LIB}/stack-upgrade.sh"
[[ -f "$SU" ]] && pass "stack-upgrade.sh present" || fail "no stack-upgrade.sh"
bash -n "$SU" 2>/dev/null && pass "syntax stack-upgrade.sh" || fail "syntax stack-upgrade.sh"

# Source the pure helpers without pulling common.sh / apt.
# shellcheck disable=SC1090
source "$SU"
for pair in "nginx:nginx" "mariadb:mariadb" "mysql:mariadb" "pgsql:pgsql" \
            "postgres:pgsql" "postgresql:pgsql" "valkey:valkey" \
            "valkey-server:valkey" "redis:valkey"; do
    in="${pair%%:*}"
    want="${pair#*:}"
    got=$(_stack_upgrade_normalize "$in") || got=""
    [[ "$got" == "$want" ]] && pass "normalize ${in} → ${want}" \
        || fail "normalize ${in}: got '${got}', want '${want}'"
done
for bad in all php "" foo nginx-full; do
    if _stack_upgrade_normalize "$bad" >/dev/null 2>&1; then
        fail "normalize accepted '${bad}'"
    else
        pass "normalize refuses '${bad}'"
    fi
done

# Patterns must stay scoped: a loose match is how PHP would get upgraded
# by a MariaDB command.
case "$(_stack_upgrade_pkg_pattern nginx)" in
    '^nginx(-|$)') pass "nginx pattern is scoped" ;;
    *) fail "nginx pattern is too loose: $(_stack_upgrade_pkg_pattern nginx)" ;;
esac
echo php-fpm | grep -qE "$(_stack_upgrade_pkg_pattern nginx)" \
    && fail "nginx pattern matches php-fpm" || pass "nginx pattern ignores php"
echo mariadb-server | grep -qE "$(_stack_upgrade_pkg_pattern mariadb)" \
    && pass "mariadb pattern matches mariadb-server" \
    || fail "mariadb pattern misses mariadb-server"
echo php8.5-mysql | grep -qE "$(_stack_upgrade_pkg_pattern mariadb)" \
    && fail "mariadb pattern matches php8.5-mysql" \
    || pass "mariadb pattern ignores php-mysql"
echo postgresql-16 | grep -qE "$(_stack_upgrade_pkg_pattern pgsql)" \
    && pass "pgsql pattern matches postgresql-16" \
    || fail "pgsql pattern misses postgresql-16"
echo valkey-tools | grep -qE "$(_stack_upgrade_pkg_pattern valkey)" \
    && pass "valkey pattern matches valkey-tools" \
    || fail "valkey pattern misses valkey-tools"

grep -q -- '--only-upgrade' "$SU" \
    && pass "uses apt --only-upgrade" || fail "missing --only-upgrade"
grep -q 'force-confold' "$SU" \
    && pass "keeps existing configs (force-confold)" || fail "no force-confold"
grep -q 'confirm ' "$SU" \
    && pass "asks before applying" || fail "no confirm"
if sed -n '/^_stack_upgrade()/,/^}/p' "$SU" | grep -q 'ARG_yes'; then
    pass "--yes skips the prompt"
else
    fail "no --yes path"
fi
grep -q 'Refusing to upgrade every service at once' "$SU" \
    && pass "service upgrade all is refused" || fail "all is not refused"
grep -q 'cipi php upgrade' "$SU" \
    && pass "php is pointed at cipi php upgrade" || fail "no php pointer"
error() { echo "ERROR: $*" >&2; }
RED= GREEN= YELLOW= CYAN= DIM= NC= BOLD=
if _stack_upgrade_service all >/dev/null 2>&1; then
    fail "service upgrade all exited 0"
else
    pass "service upgrade all exits nonzero"
fi
if _stack_upgrade_service php >/dev/null 2>&1; then
    fail "service upgrade php exited 0"
else
    pass "service upgrade php is refused"
fi
if grep -q '_stack_upgrade' "${LIB}/self-update.sh"; then
    fail "self-update invokes a stack upgrade"
else
    pass "self-update does not run stack upgrades"
fi

echo "-- stack upgrades: wiring"
grep -q '_stack_upgrade nginx' "${LIB}/nginx.sh" \
    && pass "cipi nginx upgrade is wired" || fail "nginx.sh omits upgrade"
grep -q '_stack_upgrade_db' "${LIB}/db.sh" \
    && pass "cipi db upgrade is wired" || fail "db.sh omits upgrade"
grep -q '_stack_upgrade_service' "${LIB}/service.sh" \
    && pass "cipi service upgrade is wired" || fail "service.sh omits upgrade"
grep -q 'cipi nginx upgrade' "${ROOT}/cipi" \
    && pass "help documents cipi nginx upgrade" || fail "help omits nginx upgrade"
grep -q 'cipi db upgrade' "${ROOT}/cipi" \
    && pass "help documents cipi db upgrade" || fail "help omits db upgrade"
grep -q 'cipi service upgrade' "${ROOT}/cipi" \
    && pass "help documents cipi service upgrade" || fail "help omits service upgrade"
if sed -n '/^        nginx)/,/^            esac ;;/p' "${LIB}/completion.sh" | grep -q upgrade; then
    pass "completion offers nginx upgrade"
else
    fail "completion omits nginx upgrade"
fi
if sed -n '/^        db)/,/^            esac ;;/p' "${LIB}/completion.sh" | grep -q upgrade; then
    pass "completion offers db upgrade"
else
    fail "completion omits db upgrade"
fi
if sed -n '/^        service)/,/^            esac ;;/p' "${LIB}/completion.sh" | grep -q upgrade; then
    pass "completion offers service upgrade"
else
    fail "completion omits service upgrade"
fi

echo "-- stack upgrades: notifications and sudoers"
for t in nginx_upgrade mariadb_upgrade pgsql_upgrade valkey_upgrade; do
    grep -q "^${t}|" "${LIB}/notifications.sh" \
        && pass "trigger ${t}" || fail "missing trigger ${t}"
    grep -q "$t" "$SU" || fail "stack-upgrade.sh never fires ${t}"
done
for forbidden in "nginx upgrade" "db upgrade" "service upgrade"; do
    if grep -q "cipi ${forbidden}" "${LIB}/cipi-api-sudoers.sh"; then
        fail "sudoers grants '${forbidden}' to www-data"
    else
        pass "sudoers withholds '${forbidden}'"
    fi
done
# No cron for these — the weekly PHP line must stay the only stack-upgrade cron.
if grep -E 'cipi (nginx|db|service) upgrade' "${ROOT}/setup.sh" | grep -q cron; then
    fail "setup.sh cron would auto-run a stack upgrade"
else
    pass "setup.sh does not cron nginx/db/valkey upgrades"
fi
grep -q 'cipi nginx upgrade' "${ROOT}/README.md" \
    && pass "README documents cipi nginx upgrade" || fail "README omits nginx upgrade"
grep -q 'manual stack upgrades' "${ROOT}/CHANGELOG.md" \
    && pass "CHANGELOG documents stack upgrades" || fail "CHANGELOG omits stack upgrades"

echo "-- git forges"
grep -q 'origin.cursor.com' "${LIB}/git.sh" \
    && pass "detects Cursor Origin" || fail "Origin not detected"
grep -q 'bitbucket.org' "${LIB}/git.sh" \
    && pass "detects Bitbucket Cloud" || fail "Bitbucket not detected"
grep -q 'dev.azure.com' "${LIB}/git.sh" \
    && pass "detects Azure DevOps" || fail "Azure not detected"
grep -q 'git-codecommit' "${LIB}/git.sh" \
    && pass "detects CodeCommit" || fail "CodeCommit not detected"
grep -q '_codecommit_app_pubkey' "${LIB}/git.sh" \
    && pass "CodeCommit mints an RSA key for IAM" || fail "no CodeCommit RSA helper"
grep -q 'id_rsa' "${LIB}/git.sh" \
    && pass "CodeCommit SSH config uses id_rsa" || fail "CodeCommit still points at ed25519"
grep -q 'origin-token' "${LIB}/git.sh" \
    && pass "git_command has origin-token" || fail "no origin-token"
grep -q 'bitbucket-token' "${LIB}/git.sh" \
    && pass "git_command has bitbucket-token" || fail "no bitbucket-token"
grep -q 'azure-token' "${LIB}/git.sh" \
    && pass "git_command has azure-token" || fail "no azure-token"
grep -q 'codecommit-token' "${LIB}/git.sh" \
    && pass "git_command has codecommit-token" || fail "no codecommit-token"
grep -q '_git_app_set_id' "${LIB}/git.sh" \
    && pass "string hook/key IDs can be stored" || fail "IDs still forced numeric"
grep -q 'git_seed_app_known_hosts' "${LIB}/git.sh" \
    && pass "known_hosts helper exists" || fail "no known_hosts helper"
grep -q 'git_seed_app_known_hosts' "${LIB}/app.sh" \
    && pass "app create seeds forge hosts" || fail "app create still hardcodes github/gitlab only"
grep -q '_crowdsec_write_bitbucket_whitelist' "${LIB}/crowdsec.sh" \
    && pass "CrowdSec fetches Bitbucket egress CIDRs" || fail "no Bitbucket allowlist"
grep -q 'origin-token' "${LIB}/completion.sh" \
    && pass "completion lists origin-token" || fail "completion omits origin-token"
grep -q 'bitbucket-token' "${LIB}/completion.sh" \
    && pass "completion lists bitbucket-token" || fail "completion omits bitbucket-token"
grep -q 'azure-token' "${LIB}/completion.sh" \
    && pass "completion lists azure-token" || fail "completion omits azure-token"
grep -q 'codecommit-token' "${LIB}/completion.sh" \
    && pass "completion lists codecommit-token" || fail "completion omits codecommit-token"
grep -q 'cipi git origin-token' "${ROOT}/cipi" \
    && pass "help lists origin-token" || fail "help omits origin-token"
grep -q 'cipi git bitbucket-token' "${ROOT}/cipi" \
    && pass "help lists bitbucket-token" || fail "help omits bitbucket-token"
grep -q 'cipi git azure-token' "${ROOT}/cipi" \
    && pass "help lists azure-token" || fail "help omits azure-token"
grep -q 'cipi git codecommit-token' "${ROOT}/cipi" \
    && pass "help lists codecommit-token" || fail "help omits codecommit-token"
grep -q 'Git forges beyond GitHub' "${ROOT}/CHANGELOG.md" \
    && pass "CHANGELOG documents the new forges" || fail "CHANGELOG omits new forges"
grep -q 'Bitbucket' "${ROOT}/README.md" \
    && pass "README mentions Bitbucket" || fail "README omits Bitbucket"

# Run detect/parse without vault (pure functions).
eval "$(sed -n '/^_git_detect_provider()/,/^}/p; /^_git_parse_origin_repo()/,/^}/p; /^_git_parse_bitbucket_repo()/,/^}/p; /^_git_parse_azure_repo()/,/^}/p; /^_git_parse_codecommit_repo()/,/^}/p; /^_git_url_host()/,/^}/p' "${LIB}/git.sh")"
for pair in \
    "git@github.com:acme/app.git:github" \
    "git@gitlab.com:acme/app.git:gitlab" \
    "https://origin.cursor.com/acme/app.git:origin" \
    "git@origin.cursor.com:acme/app.git:origin" \
    "git@bitbucket.org:acme/app.git:bitbucket" \
    "https://bitbucket.org/acme/app.git:bitbucket" \
    "https://dev.azure.com/acme/proj/_git/app:azure" \
    "git@ssh.dev.azure.com:v3/acme/proj/app:azure" \
    "https://acme.visualstudio.com/proj/_git/app:azure" \
    "ssh://git-codecommit.eu-west-1.amazonaws.com/v1/repos/app:codecommit" \
    "https://git-codecommit.us-east-1.amazonaws.com/v1/repos/app:codecommit"
do
    want="${pair##*:}"
    url="${pair%:${want}}"
    got=$(_git_detect_provider "$url")
    [[ "$got" == "$want" ]] && pass "detect ${want} ← ${url}" \
        || fail "detect ${url}: got '${got}', want '${want}'"
done
[[ "$(_git_parse_origin_repo 'git@origin.cursor.com:acme/app.git')" == "acme/app" ]] \
    && pass "parse Origin SSH" || fail "parse Origin SSH"
[[ "$(_git_parse_bitbucket_repo 'git@bitbucket.org:ws/repo.git')" == "ws/repo" ]] \
    && pass "parse Bitbucket SSH" || fail "parse Bitbucket SSH"
[[ "$(_git_parse_azure_repo 'https://dev.azure.com/org/proj/_git/repo')" == "org/proj/repo" ]] \
    && pass "parse Azure HTTPS" || fail "parse Azure HTTPS"
[[ "$(_git_parse_azure_repo 'git@ssh.dev.azure.com:v3/org/proj/repo')" == "org/proj/repo" ]] \
    && pass "parse Azure SSH" || fail "parse Azure SSH"
[[ "$(_git_parse_azure_repo 'https://org.visualstudio.com/proj/_git/repo')" == "org/proj/repo" ]] \
    && pass "parse Azure visualstudio.com" || fail "parse Azure visualstudio.com"
[[ "$(_git_parse_codecommit_repo 'ssh://git-codecommit.eu-west-1.amazonaws.com/v1/repos/MyRepo')" == "eu-west-1/MyRepo" ]] \
    && pass "parse CodeCommit SSH" || fail "parse CodeCommit SSH"
[[ "$(_git_url_host 'git@bitbucket.org:ws/repo.git')" == "bitbucket.org" ]] \
    && pass "url host from git@ SSH" || fail "url host git@"
[[ "$(_git_url_host 'ssh://git-codecommit.eu-west-1.amazonaws.com/v1/repos/x')" == "git-codecommit.eu-west-1.amazonaws.com" ]] \
    && pass "url host from ssh://" || fail "url host ssh://"
[[ -z "$(_git_detect_provider 'git@gitea.example.com:acme/app.git')" ]] \
    && pass "unknown host stays empty (manual)" || fail "unknown host was classified"

echo ""
echo "=== ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]

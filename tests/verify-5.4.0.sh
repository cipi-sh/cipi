#!/bin/bash
# Local regression checks for 5.4.0 — API update notification only on a real
# change, cipi.yml www / basic_auth / redirects / proxies, and the deploy audit
# ledger.
# Run from repo root: bash tests/verify-5.4.0.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/lib"
PASS=0
FAIL=0

pass() { echo "  OK: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

command -v sha256sum >/dev/null 2>&1 || sha256sum() { shasum -a 256; }
export -f sha256sum 2>/dev/null || true

echo "=== Cipi 5.4.0 regression checks ==="

[[ "$(tr -d '[:space:]' < "${ROOT}/version.md")" == "5.4.0" ]] \
    && pass "version.md is 5.4.0" || fail "version.md is not 5.4.0"
grep -q '^## \[5.4.0\]' "${ROOT}/CHANGELOG.md" \
    && pass "CHANGELOG has a 5.4.0 entry" || fail "CHANGELOG has no 5.4.0 entry"
[[ -f "${LIB}/migrations/5.4.0.sh" ]] && pass "5.4.0 migration present" || fail "missing 5.4.0 migration"

echo "-- syntax"
for f in "${ROOT}/cipi" "${ROOT}/setup.sh" "${LIB}/api.sh" "${LIB}/app.sh" "${LIB}/common.sh" "${LIB}/compliance.sh" \
         "${LIB}/deploy.sh" "${LIB}/routes.sh" "${LIB}/sync.sh" "${LIB}/yml.sh" "${LIB}/self-update.sh" \
         "${LIB}/completion.sh" "${LIB}/cipi-app-deploy.sh" "${LIB}/cipi-deploy-audit.sh" "${LIB}/migrations/5.4.0.sh"; do
    bash -n "$f" 2>/dev/null && pass "syntax ${f#"${ROOT}/"}" || { fail "syntax ${f#"${ROOT}/"}"; bash -n "$f"; }
done

# ── 1. API update notification ────────────────────────────────
echo "-- api update: notify only when the locked packages change"
sed -n '/^_api_lock_fingerprint()/,/^}/p' "${LIB}/api.sh" > "${TMP}/fp.sh"
mkdir -p "${TMP}/api"
echo '{"content-hash":"a","packages":[{"name":"cipi/api","version":"1.0.0","dist":{"reference":"r1"}}]}' > "${TMP}/api/composer.lock"
fp() { bash -c "sha256sum() { shasum -a 256 2>/dev/null || command sha256sum; }; command -v sha256sum >/dev/null; CIPI_API_ROOT='${TMP}/api'; source '${TMP}/fp.sh'; _api_lock_fingerprint"; }
f1=$(fp)
sed 's/"a"/"b"/' "${TMP}/api/composer.lock" > "${TMP}/l" && mv "${TMP}/l" "${TMP}/api/composer.lock"
f2=$(fp)
sed 's/r1/r2/' "${TMP}/api/composer.lock" > "${TMP}/l" && mv "${TMP}/l" "${TMP}/api/composer.lock"
f3=$(fp)
[[ -n "$f1" && "$f1" == "$f2" ]] && pass "content-hash alone is not an update" || fail "content-hash change counted as update"
[[ "$f2" != "$f3" ]] && pass "a new package reference is an update" || fail "reference change not detected"
body=$(sed -n '/^api_update() {/,/^}/p' "${LIB}/api.sh")
grep -q 'fp_before=$(_api_lock_fingerprint)' <<< "$body" && grep -q '"$fp_before" == "$fp_after"' <<< "$body" \
    && pass "api_update compares fingerprints" || fail "api_update does not compare fingerprints"
[[ "$(grep -n 'return 0' <<< "$body" | head -1 | cut -d: -f1)" -lt "$(grep -n 'cipi_notify' <<< "$body" | head -1 | cut -d: -f1)" ]] \
    && pass "no-change path returns before cipi_notify" || fail "notification still unconditional"

# ── 2/3. cipi.yml ─────────────────────────────────────────────
echo "-- cipi.yml validator"
sed -n "/<<'CIPIYAMLPY'$/,/^CIPIYAMLPY$/p" "${LIB}/yml.sh" | sed '1d;$d' > "${TMP}/yamlval.py"
val() { python3 "${TMP}/yamlval.py" "$1" shop; }
H12='$2y$12$'"$(printf 'a%.0s' $(seq 53))"
H08='$2y$08$'"$(printf 'a%.0s' $(seq 53))"
cat > "${TMP}/ok.yml" <<EOF
version: 1
app:
  aliases: [ "www.shop.test" ]
  www: to-root
  basic_auth:
    users:
      - admin
      - name: ci
        password_hash: "${H12}"
redirect:
  to: https://new.test
  code: 308
redirects:
  - from: old
    to: /new?x=1
  - from: /blog/
    to: "https://blog.test/"
    keep_path: false
proxies:
  - prefix: api
    upstream: "http://127.0.0.1:3000/v1"
    strip_prefix: true
    timeout: 120
    buffering: false
EOF
r=$(val "${TMP}/ok.yml")
[[ "$(jq -r .ok <<< "$r")" == true ]] && pass "valid file accepted" || fail "valid file rejected: $(jq -c .errors <<< "$r")"
[[ "$(jq -r '.data.redirects[0].from' <<< "$r")" == "/old" ]] && pass "redirect from gets a leading /" || fail "from not normalized"
[[ "$(jq -r '.data.proxies[0].prefix' <<< "$r")" == "/api/" ]] && pass "proxy prefix normalized to /api/" || fail "prefix not normalized"
[[ "$(jq -r '.data.redirect.keep_path' <<< "$r")" == "true" ]] && pass "keep_path defaults to true" || fail "keep_path default wrong"
[[ "$(jq -c '.data.app.basic_auth.users[0]' <<< "$r")" == '{"name":"admin"}' ]] && pass "name-only basic auth user" || fail "name-only user wrong"

bad() {
    printf 'version: 1\n%s\n' "$1" > "${TMP}/bad.yml"
    r=$(val "${TMP}/bad.yml")
    if [[ "$(jq -r .ok <<< "$r")" == false ]] && jq -r '.errors[]' <<< "$r" | grep -qF "$2"; then
        pass "rejects: $3"
    else
        fail "accepts: $3 ($(jq -c .errors <<< "$r"))"
    fi
}
bad $'app:\n  www: sideways' "app.www" "unknown www mode"
bad $'app:\n  basic_auth:\n    users:\n      - name: x\n        password_hash: "$apr1$ab$cd"' "password_hash" "apr1 hash"
bad $'app:\n  basic_auth:\n    users:\n      - name: x\n        password_hash: "'"${H08}"'"' "cost must be at least 10" "bcrypt cost 8"
bad $'app:\n  basic_auth:\n    users:\n      - name: x\n        password: secret' "unknown key" "plain password key"
bad $'app:\n  basic_auth:\n    users: []' "at least one user" "empty user list"
bad $'redirect:\n  code: 302' "'to' is required" "redirect without to"
bad $'redirects:\n  - from: /a b\n    to: /c' "redirects[0].from" "path with a space"
bad $'redirects:\n  - from: /x\n    to: "https://evil;return 200"' "redirects[0].to" "target with ;"
bad $'redirects:\n  - from: /x\n    to: /y\n  - from: /x\n    to: /z' "duplicate redirect" "duplicate from"
bad $'proxies:\n  - prefix: /api/\n    upstream: "http://h/?q=1"' "proxies[0].upstream" "upstream with query"
bad $'proxies:\n  - prefix: /api/\n    upstream: "http://h"\n    timeout: 0' "between 1 and 3600" "timeout 0"

echo "-- cipi.yml plan (routes / www / basic auth)"
cat > "${TMP}/apps.json" <<'EOF'
{"shop":{"domain":"shop.test","aliases":["www.shop.test"],"www_redirect":"to-root","basic_auth":"false","php":"8.4",
  "redirects":[{"from":"/old","to":"/new","code":301,"keep_path":true}],
  "proxies":[{"prefix":"/api/","upstream":"http://127.0.0.1:3000","strip_prefix":true,"preserve_host":false,"timeout":60,"buffering":true}]},
 "other":{"domain":"o.test","octane_port":"8001"}}
EOF
cat > "${TMP}/plan.sh" <<EOF
export CIPI_LIB="${LIB}" CIPI_CONFIG="${TMP}/cfg" CIPI_LOG="${TMP}/log"
mkdir -p "${TMP}/cfg" "${TMP}/log"
RED=; GREEN=; YELLOW=; CYAN=; DIM=; NC=; BOLD=
source "${LIB}/common.sh" 2>/dev/null
vault_read() { cat "${TMP}/apps.json"; }
getent() {
    case "\$2" in
        api.internal) echo "10.0.0.5 STREAM api.internal" ;;
        meta.test)    echo "169.254.169.254 STREAM meta.test" ;;
        *) return 2 ;;
    esac
}
source "${LIB}/routes.sh"
source "${LIB}/yml.sh"
_yml_source_libs() { :; }
_YML_APP=shop; _YML_FILE="\$1"
res=\$(python3 "${TMP}/yamlval.py" "\$1" shop)
_YML_DATA=\$(jq .data <<< "\$res")
_yml_build_plan 2>/dev/null
printf 'A|%s\n' "\${_YML_ACTIONS[@]}"
printf 'B|%s\n' "\${_YML_BLOCKERS[@]}"
EOF
plan() { bash "${TMP}/plan.sh" "$1" 2>/dev/null; }

cat > "${TMP}/p0.yml" <<'EOF'
version: 1
app:
  aliases: [ "www.shop.test" ]
  www: to-root
redirects:
  - from: /old
    to: /new
proxies:
  - prefix: /api/
    upstream: "http://127.0.0.1:3000"
    strip_prefix: true
EOF
out=$(plan "${TMP}/p0.yml")
[[ -z "$(grep -v '^[AB]|$' <<< "$out")" ]] && pass "matching file plans nothing" || fail "no-op plan not empty: ${out}"

cat > "${TMP}/p1.yml" <<'EOF'
version: 1
app:
  aliases: [ "www.shop.test" ]
  www: from-root
redirect:
  to: https://new.test
redirects:
  - from: /old
    to: /new
  - from: /blog/
    to: https://blog.test
proxies:
  - prefix: /api/
    upstream: "http://127.0.0.1:3000"
    strip_prefix: true
    timeout: 90
  - prefix: /svc/
    upstream: "http://api.internal:8080"
EOF
out=$(plan "${TMP}/p1.yml")
grep -q '^A|www|from-root|' <<< "$out" && pass "www change planned" || fail "www change missing: ${out}"
grep -q '^A|routes||.*redirects: +1.*proxies: +1 ~1' <<< "$out" && pass "routes change summarised as one action" || fail "routes action wrong: ${out}"
grep -q '^B|.' <<< "$out" && fail "unexpected blocker: ${out}" || pass "no blockers"

cat > "${TMP}/p2.yml" <<'EOF'
version: 1
app:
  aliases: [ "api.shop.test" ]
  basic_auth:
    users: [ ghost ]
redirect:
  to: https://www.shop.test/x
redirects:
  - from: /api/
    to: https://x.test
  - from: /a
    to: /a
  - from: /.well-known/acme-challenge/x
    to: /b
proxies:
  - prefix: /db/
    upstream: "http://127.0.0.1:3306"
  - prefix: /meta/
    upstream: "http://169.254.169.254"
  - prefix: /m2/
    upstream: "http://meta.test"
  - prefix: /o/
    upstream: "http://localhost:8001"
  - prefix: /n/
    upstream: "http://nowhere.invalid"
  - prefix: /api/
    upstream: "http://10.0.0.9"
EOF
out=$(plan "${TMP}/p2.yml")
blk() { grep -q "^B|.*$1" <<< "$out" && pass "blocks: $2" || fail "not blocked: $2"; }
blk "www redirect (to-root) needs" "aliases dropping the www pair"
blk "basic auth user 'ghost' has no password" "name-only user unknown to the server"
blk "redirect: .*would loop" "app redirect to itself"
blk "redirects\[0\] /api/: .*collides with the proxy" "redirect/proxy collision"
blk "redirects\[1\] /a: .*loop" "path redirect loop"
blk "reserved for Let's Encrypt" "ACME path"
blk "is MariaDB — a project file cannot publish it" "loopback database port"
blk "proxies\[1\] /meta/: .*link-local" "metadata IP"
blk "proxies\[2\] /m2/: .*169.254.169.254" "hostname resolving to metadata"
blk "app 'other' (Octane/Reverb)" "another app's Octane port"
blk "does not resolve" "unresolvable upstream"
grep -q '^A|routes' <<< "$out" && fail "routes planned despite blockers" || pass "no routes action while blocked"

echo "-- cipi.yml search"
bad $'search: maybe' "search: expected true or false" "search not a boolean"
printf 'version: 1\nsearch: true\n' > "${TMP}/s1.yml"
out=$(plan "${TMP}/s1.yml")
grep -q '^B|search is declared, but Meilisearch is not installed' <<< "$out" \
    && pass "search without Meilisearch is blocked (install stays with root)" || fail "search on without engine: ${out}"
jq '.shop.search = "true"' "${TMP}/apps.json" > "${TMP}/a2" && cp "${TMP}/apps.json" "${TMP}/apps.bak" && mv "${TMP}/a2" "${TMP}/apps.json"
printf 'version: 1\nsearch: false\n' > "${TMP}/s2.yml"
out=$(plan "${TMP}/s2.yml")
grep -q '^A|search|off|.*kept' <<< "$out" && pass "search off planned, indexes kept" || fail "search off not planned: ${out}"
printf 'version: 1\nsearch: true\n' > "${TMP}/s3.yml"
[[ -z "$(plan "${TMP}/s3.yml" | grep -v '^[AB]|$')" ]] && pass "search already on plans nothing" || fail "search on/on not a no-op"
mv "${TMP}/apps.bak" "${TMP}/apps.json"
grep -q 'purge' <<< "$(sed -n '/^        search)/,/;;/p' "${LIB}/yml.sh")" \
    && fail "cipi.yml can purge indexes" || pass "cipi.yml never purges indexes"

echo "-- cipi.yml on a non-Laravel app"
jq '.shop.custom = true | .shop.runtime = "node"' "${TMP}/apps.json" > "${TMP}/a3" && cp "${TMP}/apps.json" "${TMP}/apps.bak" && mv "${TMP}/a3" "${TMP}/apps.json"
printf 'version: 1\nschedule: true\nworkers:\n  queues:\n    - default\n' > "${TMP}/c1.yml"
out=$(plan "${TMP}/c1.yml")
grep -q "^B|workers.horizon / workers.queues are declared, but 'shop' is not a Laravel app" <<< "$out" \
    && grep -q "^B|schedule is declared, but 'shop' is not a Laravel app" <<< "$out" \
    && ! grep -q '^A|worker-\|^A|schedule' <<< "$out" \
    && pass "workers and scheduler blocked on custom/Node apps" || fail "custom app workers: ${out}"
mv "${TMP}/apps.bak" "${TMP}/apps.json"

echo "-- cipi.yml deploy config / limits / ssl / env / crons (validator)"
cat > "${TMP}/n1.yml" <<'EOF'
version: 1
app:
  limits:
    memory_limit: 512M
    fpm_max_children: 10
deploy:
  keep_releases: 3
  migrate: false
  extra_artisan: [ "view:clear" ]
  snapshot: true
ssl:
  force_https: true
env:
  required: [ STRIPE_KEY, MAIL_HOST ]
crons:
  - every: 30m
    run: artisan queue:prune-batches
  - cron: "15 3 * * *"
    run: php scripts/cleanup.php
EOF
r=$(val "${TMP}/n1.yml")
[[ "$(jq -r .ok <<< "$r")" == true ]] && pass "new keys accepted" || fail "new keys rejected: $(jq -c .errors <<< "$r")"
[[ "$(jq -r '.data.crons[0].run' <<< "$r")" == "artisan" ]] && pass "crons run parsed through the deploy.post runners" || fail "crons run not parsed"
bad $'deploy:\n  keep_releases: 0' "between 1 and 20" "keep_releases 0"
bad $'deploy:\n  keep_releases: 21' "between 1 and 20" "keep_releases 21"
bad $'deploy:\n  extra_artisan: [ tinker ]' "tinker is never allowed" "extra_artisan tinker"
bad $'app:\n  limits:\n    fpm_max_children: 51' "between 1 and 50" "fpm_max_children above the CLI cap (refused, not clamped)"
bad $'app:\n  limits:\n    memory_limit: lots' "a size such as 256M" "memory_limit not a size"
bad $'ssl:\n  force_https: maybe' "expected true or false" "force_https not a boolean"
bad $'env:\n  required: [ stripe_key ]' "UPPER_CASE" "lowercase env name"
bad $'env:\n  required: [ A, A ]' "duplicate variable" "duplicate env name"
bad $'crons:\n  - every: 30m\n    cron: "1 2 3 4 5"\n    run: artisan x' "not both" "crons with both every and cron"
bad $'crons:\n  - run: artisan inspire' "'every' (30m, 6h, 1d) or 'cron' is required" "crons without a schedule"
bad $'crons:\n  - every: 7m\n    run: artisan inspire' "divide 60 evenly" "crons every 7m"
bad $'crons:\n  - every: 1h\n    run: rm -rf /' "unknown runner" "crons free-form shell command"
bad $'crons:\n  - every: 1h\n    run: artisan tinker' "tinker is not allowed" "crons artisan tinker"

echo "-- cipi.yml deploy config / limits / ssl / env / crons (plan)"
out=$(plan "${TMP}/n1.yml")
grep -q '^A|deploy-cfg|keep_releases=3;migrate=false;snapshot=true;extra_artisan=view:clear|' <<< "$out" \
    && pass "deploy config diff planned as one action" || fail "deploy-cfg action wrong: ${out}"
grep -q '^A|limits|memory_limit=512M;fpm_max_children=10|' <<< "$out" \
    && pass "limits diff planned" || fail "limits action wrong: ${out}"
grep -q "^B|ssl.force_https needs a certificate" <<< "$out" \
    && pass "force_https without a certificate is blocked (cipi ssl install stays with root)" || fail "ssl not blocked: ${out}"
grep -q "^B|env.required: STRIPE_KEY is not set" <<< "$out" \
    && pass "a missing required .env variable blocks the plan" || fail "env.required not blocked: ${out}"
grep -q '^A|crons||scheduled commands — 2 managed cron entries' <<< "$out" \
    && pass "crons planned as one crontab sync" || fail "crons action wrong: ${out}"

# Matching server state plans nothing (ssl/env/crons dropped: cert, .env and
# crontab live outside apps.json).
jq '.shop.limits = {"memory_limit":"512M","fpm_max_children":10} | .shop.keep_releases = "3"
    | .shop.deploy_migrate = "false" | .shop.predeploy_snapshot = "true"
    | .shop.extra_artisan = ["view:clear"]' "${TMP}/apps.json" > "${TMP}/a4" \
    && cp "${TMP}/apps.json" "${TMP}/apps.bak" && mv "${TMP}/a4" "${TMP}/apps.json"
sed '/^ssl:/,$d' "${TMP}/n1.yml" > "${TMP}/n2.yml"
[[ -z "$(plan "${TMP}/n2.yml" | grep -v '^[ABN]|$')" ]] \
    && pass "matching deploy config and limits plan nothing" || fail "deploy-cfg/limits not a no-op: $(plan "${TMP}/n2.yml")"

# force_https already on: true is a no-op, false is refused (nothing turns it off).
jq '.shop.force_https = "true"' "${TMP}/apps.json" > "${TMP}/a5" && mv "${TMP}/a5" "${TMP}/apps.json"
printf 'version: 1\nssl:\n  force_https: true\n' > "${TMP}/s4.yml"
[[ -z "$(plan "${TMP}/s4.yml" | grep -v '^[ABN]|$')" ]] && pass "force_https already on plans nothing" || fail "ssl on/on not a no-op"
printf 'version: 1\nssl:\n  force_https: false\n' > "${TMP}/s5.yml"
grep -q "^B|ssl.force_https is 'false' but the redirect is already forced" <<< "$(plan "${TMP}/s5.yml")" \
    && pass "force_https cannot be turned off from the file" || fail "ssl false not refused"
mv "${TMP}/apps.bak" "${TMP}/apps.json"

# Custom and Node apps: no recipe / no artisan.
jq '.shop.custom = true' "${TMP}/apps.json" > "${TMP}/a6" && cp "${TMP}/apps.json" "${TMP}/apps.bak" && mv "${TMP}/a6" "${TMP}/apps.json"
printf 'version: 1\ndeploy:\n  keep_releases: 3\ncrons:\n  - every: 1h\n    run: artisan inspire\n' > "${TMP}/n3.yml"
out=$(plan "${TMP}/n3.yml")
grep -q "^B|deploy recipe options are declared, but 'shop' is a custom app" <<< "$out" \
    && pass "deploy config blocked on a custom app" || fail "custom deploy-cfg not blocked: ${out}"
grep -q "^B|crons: artisan entries are declared, but 'shop' is not a Laravel app" <<< "$out" \
    && pass "artisan cron blocked on a custom app" || fail "custom artisan cron not blocked: ${out}"
mv "${TMP}/apps.bak" "${TMP}/apps.json"
jq '.shop.runtime = "node"' "${TMP}/apps.json" > "${TMP}/a7" && cp "${TMP}/apps.json" "${TMP}/apps.bak" && mv "${TMP}/a7" "${TMP}/apps.json"
printf 'version: 1\ndeploy:\n  migrate: false\n' > "${TMP}/n4.yml"
grep -q "^B|.*artisan hooks, but 'shop' is a Node app" <<< "$(plan "${TMP}/n4.yml")" \
    && pass "artisan hooks blocked on a Node app" || fail "node hooks not blocked"
mv "${TMP}/apps.bak" "${TMP}/apps.json"

echo "-- cipi.yml crons wiring"
grep -q "grep -v '# cipi-yml\$'" "${LIB}/yml.sh" \
    && pass "apply keeps the crontab lines it does not manage" || fail "crontab replaced wholesale"
sed -n '/^_yml_plan_crons() {/,/^}/p' "${LIB}/yml.sh" | grep -q 'cipi-yml' \
    && pass "plan diffs only the tagged lines" || fail "plan reads the whole crontab"
for case in 'deploy-cfg)' 'limits)' 'sslforce)' 'crons)'; do
    grep -qF "        ${case}" "${LIB}/yml.sh" && pass "apply handles ${case%)}" || fail "apply lacks ${case%)}"
done
sed -n '/^        crons)/,/;;/p' "${LIB}/yml.sh" | grep -q 'schedule:run' \
    && fail "crons apply touches the Laravel scheduler line" || pass "the scheduler line is never touched"
# every → cron: the exact reverse of _yml_cron_to_every
ev=$(bash -c "source /dev/stdin <<< \"\$(sed -n '/^_yml_every_to_cron() {/,/^}/p' '${LIB}/yml.sh')\"; _yml_every_to_cron 30m; _yml_every_to_cron 6h; _yml_every_to_cron 1d")
[[ "$ev" == $'*/30 * * * *\n0 */6 * * *\n0 2 * * *' ]] && pass "every 30m/6h/1d → cron round-trip" || fail "every conversion wrong: ${ev}"

echo "-- CLI and cipi.yml share the route builders"
for fn in redirect_set redirect_add proxy_add; do
    sed -n "/^${fn}() {/,/^}/p" "${LIB}/routes.sh" | grep -q '_routes_build_' \
        && pass "${fn} uses a builder" || fail "${fn} validates on its own"
done
sed -n '/^_routes_build_proxy() {/,/^}/p' "${LIB}/routes.sh" | grep -q 'yml)   error' \
    && pass "no --force from a project file" || fail "yml mode can publish loopback ports"

echo "-- basic auth helpers"
grep -q '^_basicauth_write_hash() {' "${LIB}/app.sh" && grep -q '^_basicauth_remove_user() {' "${LIB}/app.sh" \
    && pass "hash writer and user removal" || fail "basic auth helpers missing"
sed -n '/^_basicauth_write_hash() {/,/^}/p' "${LIB}/app.sh" | grep -q "sed -i \"/^\${user}:/d\"" \
    && fail "user removal still uses a regex" || pass "exact user match"

echo "-- example and generate"
ex=$(bash -c "RED=; NC=; error(){ :; }; validate_username(){ return 0; }; app_exists(){ return 1; }; source '${LIB}/yml.sh'; _yml_example shop" 2>"${TMP}/ex.err")
[[ ! -s "${TMP}/ex.err" ]] && pass "example prints no shell errors" || fail "example stderr: $(cat "${TMP}/ex.err")"
printf '%s\n' "$ex" > "${TMP}/ex.yml"
[[ "$(val "${TMP}/ex.yml" | jq -r .ok)" == true ]] && pass "example validates" || fail "example does not validate"
for k in 'www:' 'basic_auth:' 'redirects:' 'proxies:' 'search:'; do
    grep -q "^ *${k}" <<< "$ex" && pass "example has ${k}" || fail "example lacks ${k}"
done
for k in 'limits:' 'keep_releases:' 'snapshot:' 'ssl:' 'force_https:' 'env:' 'required:' 'crons:'; do
    grep -q "# *${k}" <<< "$ex" && pass "example documents ${k}" || fail "example lacks ${k}"
done
gen=$(sed -n '/^_yml_generate() {/,/^}/p' "${LIB}/yml.sh")
for k in '  www: ' '  basic_auth:' 'redirect:' 'redirects:' 'proxies:' 'search: ' '  limits:' 'ssl:' 'crons:' '  keep_releases: ' '  snapshot: '; do
    grep -qF "echo \"${k}" <<< "$gen" && pass "generate emits ${k# }" || fail "generate omits ${k# }"
done
grep -q 'password_hash' <<< "$gen" && fail "generate would export password hashes" || pass "generate emits user names only"

# ── 4. deploy audit ledger ────────────────────────────────────
echo "-- audit helper"
AUD="${LIB}/cipi-deploy-audit.sh"
bash "$AUD" 'Bad!' published >/dev/null 2>&1; [[ $? -eq 2 ]] && pass "rejects an invalid app name" || fail "accepts an invalid app name"
bash "$AUD" shop deleted >/dev/null 2>&1; [[ $? -eq 2 ]] && pass "rejects an unknown event" || fail "accepts an unknown event"
grep -q 'SUDO_USER" != "$APP"' "$AUD" && pass "only the app itself may record its deploys" || fail "no SUDO_USER check"
grep -q '"cipi-cli"' "$AUD" && grep -q 'origin="webhook"' "$AUD" && grep -q 'origin="app-web"' "$AUD" \
    && grep -q 'origin="ssh"' "$AUD" && grep -q 'origin="panel"' "$AUD" \
    && pass "origins: cipi-cli, panel, webhook, app-web, ssh" || fail "origin classification incomplete"
grep -q 'logger -t cipi-deploy' "$AUD" && pass "records go to syslog too" || fail "no syslog copy"
grep -q 'flock' "$AUD" && pass "appends under a lock" || fail "no lock around the chain"

echo "-- recipe hooks"
grep -q "after('deploy:symlink', 'cipi:audit:published')" "${LIB}/deployer/audit-releases.php" \
    && grep -q "after('deploy:failed', 'cipi:audit:failed')" "${LIB}/deployer/audit-releases.php" \
    && grep -q "after('rollback', 'cipi:audit:rollback')" "${LIB}/deployer/audit-releases.php" \
    && pass "releases recipe: published, failed, rollback" || fail "releases recipe hooks incomplete"
grep -q "fail('deploy', 'cipi:audit:failed')" "${LIB}/deployer/audit-custom.php" \
    && pass "custom recipe: failed via fail()" || fail "custom recipe has no failure hook"
grep -q "runLocally('sudo -n /usr/local/bin/cipi-deploy-audit" "${LIB}/deployer/audit-releases.php" \
    && pass "hook runs locally (keeps the process chain)" || fail "hook does not use runLocally"
grep -q 'catch (\\Throwable' "${LIB}/deployer/audit-releases.php" && pass "hook can never fail a deploy" || fail "hook may fail a deploy"

mkdir -p "${TMP}/home/shop/.deployer"
printf '<?php\nnamespace Deployer;\n' > "${TMP}/home/shop/.deployer/deploy.php"
hook() {
    bash -c "CIPI_LIB='${LIB}'; source '${LIB}/common.sh' 2>/dev/null
        eval \"\$(declare -f deployer_audit_ensure_hook | sed 's|/home/|${TMP}/home/|g')\"
        chown() { :; }
        deployer_audit_ensure_hook shop false"
}
hook && hook
[[ "$(grep -c 'cipi:deploy-audit' "${TMP}/home/shop/.deployer/deploy.php")" == "1" ]] \
    && pass "hook appended once (idempotent)" || fail "hook appended $(grep -c 'cipi:deploy-audit' "${TMP}/home/shop/.deployer/deploy.php") times"
grep -q 'cipi-deploy-audit shop ' "${TMP}/home/shop/.deployer/deploy.php" && pass "app name substituted" || fail "placeholder left in hook"
[[ "$(grep -c 'deployer_audit_ensure_hook "$an"' "${LIB}/app.sh")" == "3" ]] \
    && pass "new recipes (releases, custom, node) get the hook" || fail "template generation does not add the hook"

echo "-- sudoers, cron, triggers"
for f in app.sh sync.sh; do
    grep -q 'NOPASSWD: /usr/local/bin/cipi-deploy-audit \${app' "${LIB}/${f}" \
        && pass "${f}: sudoers rule" || fail "${f}: no sudoers rule"
done
if grep -rn 'deploy-trigger && rm -f' "${LIB}" --include='*.sh' | grep -v '/migrations/' | grep -q .; then
    fail "a trigger cron still deletes the trigger file"
else
    pass "trigger crons hand the file to the wrapper (mv)"
fi
[[ "$(grep -c 'mv -f ${home}/.deploy-trigger ${home}/.deploy-trigger.run' "${LIB}/app.sh")" == "3" ]] \
    && pass "app.sh: every crontab writer (Laravel create, schedule, Node create)" || fail "app.sh crontab writers not updated"
grep -q 'CIPI_DEPLOY_TRIGGER=cli sudo -u' "${LIB}/deploy.sh" && grep -q 'CIPI_DEPLOY_TRIGGER=rollback sudo -u' "${LIB}/deploy.sh" \
    && grep -q 'CIPI_DEPLOY_TRIGGER=auto-rollback sudo -u' "${LIB}/deploy.sh" \
    && pass "cipi deploy / rollback / auto-rollback tag their runs" || fail "root dep runs not tagged"
grep -q 'cipi-deploy-audit' "${LIB}/self-update.sh" && grep -q 'cipi-deploy-audit' "${ROOT}/setup.sh" \
    && pass "helper installed by setup and self-update" || fail "helper not installed"

echo "-- trigger metadata (cipi-app-deploy)"
getter=$(sed -n '/^    _meta_get() {/,/^    }/p' "${LIB}/cipi-app-deploy.sh")
m() { bash -c "meta=\$1; ${getter}; _meta_get \$2" _ "$1" "$2"; }
j='{"source":"mcp","actor":"jane@example.com; rm -rf /","request_id":"r-1"}'
[[ "$(m "$j" source)" == "mcp" ]] && pass "JSON source read" || fail "JSON source not read"
[[ "$(m "$j" actor)" != *";"* ]] && pass "claimed values are sanitized" || fail "metadata not sanitized"
[[ "$(m $'source = webhook\nactor=gh:octo' actor)" == "gh:octo" ]] && pass "KEY=VALUE form read" || fail "KEY=VALUE not read"

echo "-- compliance: ledger chain"
python3 - "${TMP}/ledger.jsonl" <<'PY'
import hashlib, json, sys
prev, out = "", []
for i, (ts, app, ev, rel) in enumerate([("2026-09-01T10:00:00Z", "shop", "published", "4"),
                                        ("2026-09-02T10:00:00Z", "shop", "failed", "4"),
                                        ("2026-09-03T10:00:00Z", "blog", "rollback", "7")], 1):
    line = json.dumps({"seq": i, "ts": ts, "app": app, "event": ev, "release": rel, "commit": "abc",
                       "origin": "webhook", "trigger": "webhook", "operator": app, "ip": "",
                       "deployer": {"release": rel}, "claimed": {"source": "mcp"}, "prev": prev},
                      separators=(",", ":"))
    out.append(line)
    prev = hashlib.sha256(line.encode()).hexdigest()
open(sys.argv[1], "w").write("\n".join(out) + "\n")
PY
sed -n '/^_cmp_ledger_verify()/,/^}/p;/^_cmp_ledger_rows()/,/^}/p' "${LIB}/compliance.sh" > "${TMP}/ledger.sh"
lv() { bash -c "command -v sha256sum >/dev/null || sha256sum() { shasum -a 256; }; source '${TMP}/ledger.sh'; $1"; }
[[ "$(lv "_cmp_ledger_verify '${TMP}/ledger.jsonl'")" == "ok 3" ]] && pass "intact chain verifies" || fail "intact chain rejected"
sed '2d' "${TMP}/ledger.jsonl" > "${TMP}/l-del.jsonl"
[[ "$(lv "_cmp_ledger_verify '${TMP}/l-del.jsonl'")" == broken\ 2* ]] && pass "deleted record detected" || fail "deletion not detected"
sed '1s/"commit":"abc"/"commit":"abd"/' "${TMP}/ledger.jsonl" > "${TMP}/l-edit.jsonl"
[[ "$(lv "_cmp_ledger_verify '${TMP}/l-edit.jsonl'")" == broken\ 2* ]] && pass "edited record detected" || fail "edit not detected"
rows=$(lv "_cmp_ledger_rows '${TMP}/ledger.jsonl' '2026-09-02T00:00:00Z'")
[[ "$(grep -c . <<< "$rows")" == "2" ]] && pass "period filter on ledger rows" || fail "ledger rows: ${rows}"
[[ "$(sed -n 1p <<< "$rows" | cut -f3,6,10)" == $'failed\twebhook\tmcp' ]] && pass "row carries event, origin, claimed source" || fail "row wrong: $(sed -n 1p <<< "$rows")"
cmp=$(sed -n '/^_cmp_check_deploys() {/,/^}/p' "${LIB}/compliance.sh")
grep -q 'status=fail' <<< "$cmp" && grep -q '_cmp_unaudited_releases' <<< "$cmp" && grep -q 'cipi:deploy-audit' <<< "$cmp" \
    && pass "deploys control: chain, unaudited releases, missing hooks" || fail "deploys control incomplete"
grep -qE 'sed -i|> *"\$ledger"|vault_write' <<< "$cmp" && fail "deploys control writes to the server" || pass "deploys control stays read-only"

echo "-- migration"
MIG="${LIB}/migrations/5.4.0.sh"
grep -q 'visudo -cf' "$MIG" && pass "sudoers validated before keeping it" || fail "sudoers not validated"
grep -q 'deployer_audit_ensure_hook' "$MIG" && pass "hooks appended to existing deploy.php" || fail "existing recipes not patched"
grep -q 'deploy-audit-since' "$MIG" && pass "audit start marker" || fail "no start marker"
grep -vE '^[[:space:]]*#' "$MIG" | grep -qE 'systemctl (restart|reload)|dep deploy' && fail "migration restarts or deploys" || pass "migration deploys and restarts nothing"
line='* * * * * test -f /home/shop/.deploy-trigger && rm -f /home/shop/.deploy-trigger && /usr/local/bin/cipi-app-deploy shop 8.4 webhook >/dev/null 2>&1'
app=shop
rew=$(printf '%s\n' "$line" | sed -E "s#test -f (/home/${app}/\\.deploy-trigger) && rm -f /home/${app}/\\.deploy-trigger && #test -f \\1 \\&\\& mv -f \\1 \\1.run \\&\\& #")
[[ "$rew" == '* * * * * test -f /home/shop/.deploy-trigger && mv -f /home/shop/.deploy-trigger /home/shop/.deploy-trigger.run && /usr/local/bin/cipi-app-deploy shop 8.4 webhook >/dev/null 2>&1' ]] \
    && pass "crontab rewrite" || fail "crontab rewrite wrong: ${rew}"
grep -qF 's#test -f (/home/${app}/\\.deploy-trigger) && rm -f /home/${app}/\\.deploy-trigger && #test -f \\1 \\&\\& mv -f \\1 \\1.run \\&\\& #' "$MIG" \
    && pass "migration uses the tested expression" || fail "migration crontab expression differs from the test"

# ── Node frontend apps ────────────────────────────────────────
echo "-- node: syntax and wiring"
for f in "${LIB}/node.sh" "${LIB}/cipi-node-switch.sh" "${LIB}/cipi-node-run.sh"; do
    bash -n "$f" 2>/dev/null && pass "syntax ${f#"${ROOT}/"}" || { fail "syntax ${f#"${ROOT}/"}"; bash -n "$f"; }
done
if command -v php >/dev/null 2>&1; then
    php -l "${LIB}/cipi-webhook.php" >/dev/null 2>&1 && pass "php -l cipi-webhook.php" || fail "cipi-webhook.php does not parse"
    php -l "${LIB}/deployer/node.php" >/dev/null 2>&1 && pass "php -l deployer/node.php" || fail "deployer/node.php does not parse"
fi
grep -q 'source "${CIPI_LIB}/node.sh";        node_command' "${ROOT}/cipi" && pass "cipi dispatches node" || fail "no node dispatch"
grep -q 'show_help_topic node' "${ROOT}/cipi" && pass "help all includes node" || fail "help omits node"
grep -qw node <<< "$(sed -n 's/.*local commands="\([^"]*\)".*/\1/p' "${LIB}/completion.sh" | head -1)" \
    && pass "completion verb node" || fail "completion omits node"
grep -q 'cipi-node-switch ${app_user} \*' "${LIB}/app.sh" && pass "node apps may call cipi-node-switch (sudoers)" || fail "no cipi-node-switch sudoers rule"
grep -q 'node_app_cleanup "$app"' "${LIB}/app.sh" && pass "app delete stops and removes Node slots" || fail "app delete leaves Node slots"
grep -q '${app}-node.conf' "${LIB}/node.sh" && ! grep -q 'conf.d/${APP}.conf' "${LIB}/cipi-node-switch.sh" \
    && pass "slots live outside <app>.conf (cipi-worker restart cannot bounce both)" || fail "slots share the worker conf"
for f in setup.sh lib/self-update.sh; do
    grep -q 'cipi-node-switch' "${ROOT}/${f}" && grep -q 'cipi-node-run' "${ROOT}/${f}" && grep -q 'webhook.php' "${ROOT}/${f}" \
        && pass "${f} installs the Node helpers" || fail "${f} does not install the Node helpers"
done
grep -q "runtime.*== \"node\"" "${LIB}/sync.sh" && pass "sync skips Node apps explicitly" || fail "sync would half-create Node apps"

echo "-- node: options, presets, validation"
NH="export CIPI_LIB='${LIB}' CIPI_CONFIG='${TMP}/cfg' CIPI_LOG='${TMP}/log'; RED=; NC=; source '${LIB}/common.sh' 2>/dev/null; source '${LIB}/node.sh';"
opts() { bash -c "${NH} $1 _node_resolve_create_opts 2>/dev/null && echo \"\$NODE_OPT_MODE|\$NODE_OPT_BUILD|\$NODE_OPT_START|\$NODE_OPT_OUTPUT|\$NODE_OPT_VERSION\""; }
[[ "$(opts 'ARG_framework=next;')" == "ssr|npm run build|npx next start -H 127.0.0.1||22" ]] && pass "next preset" || fail "next preset: $(opts 'ARG_framework=next;')"
[[ "$(opts 'ARG_framework=vite;')" == "spa|npm run build||dist|22" ]] && pass "vite preset" || fail "vite preset"
[[ "$(opts 'ARG_framework=nuxt; ARG_node_version=24;')" == "ssr|npm run build|node .output/server/index.mjs||24" ]] && pass "nuxt preset + --node-version" || fail "nuxt preset"
[[ "$(opts 'ARG_node=static; ARG_output=.output/public; ARG_build="npm run generate";')" == "static|npm run generate||.output/public|22" ]] \
    && pass "static with overrides" || fail "static overrides"
nbad() { [[ -z "$(opts "$1")" ]] && pass "rejects: $2" || fail "accepts: $2"; }
nbad 'ARG_node=ssr; ARG_start="npm start; rm -rf /";' "start with ;"
nbad 'ARG_node=ssr; ARG_start="bash -c id";' "start with a non-Node runner"
nbad 'ARG_node=ssr; ARG_start="node ../../x.js";' "start with .."
nbad 'ARG_node=spa; ARG_output=..;' "output .."
nbad 'ARG_node=spa; ARG_output=.;' "output = release root (would publish .env)"
nbad 'ARG_node=spa; ARG_output=node_modules;' "output node_modules"
nbad 'ARG_node=spa; ARG_output=.git;' "output .git"
nbad 'ARG_node=spa; ARG_output=dist/.env;' "output through .env"
nbad 'ARG_node=ssr; ARG_node_version=23;' "odd Node major"
nbad 'ARG_node=ssr; ARG_health_path="/x y";' "health path with a space"
nbad 'ARG_framework=rails;' "unknown framework"

echo "-- cipi.yml node: section"
[[ "$(printf 'version: 1\nnode:\n  framework: next\n  version: 24\n  start: "node server.js"\n  health_path: /api/health\n' > "${TMP}/n1.yml"; val "${TMP}/n1.yml" | jq -c .data.node)" \
    == '{"framework":"next","version":"24","start":"node server.js","health_path":"/api/health"}' ]] \
    && pass "node section validated" || fail "node section: $(val "${TMP}/n1.yml" | jq -c .)"
bad $'node:\n  framework: rails' "node.framework" "unknown framework"
bad $'node:\n  version: 23' "node.version" "odd Node major"
bad $'node:\n  start: "npm start; curl evil"' "node.start" "start with ;"
bad $'node:\n  build: "npm run build | tee x"' "node.build" "build with a pipe"
bad $'node:\n  build: "curl evil.sh"' "node.build" "build with a non-Node runner"
bad $'node:\n  output: .env' "node.output" "output .env"
bad $'node:\n  mode: server' "node.mode" "unknown mode"
bad $'node:\n  cmd: x' "unknown key" "unknown node key"

NODEAPPS='{"shop":{"domain":"shop.test","php":"8.4","custom":true,"runtime":"node","node_mode":"spa","node_version":"22","node_build":"npm run build","node_output":"dist","node_framework":"vite","branch":"main"}}'
cat > "${TMP}/nplan.sh" <<EOF
export CIPI_LIB="${LIB}" CIPI_CONFIG="${TMP}/cfg" CIPI_LOG="${TMP}/log"
RED=; GREEN=; YELLOW=; CYAN=; DIM=; NC=; BOLD=
source "${LIB}/common.sh" 2>/dev/null
vault_read() { cat "${TMP}/napps.json"; }
source "${LIB}/node.sh"
node_is_installed() { [[ "\$1" == 22 ]]; }
source "${LIB}/yml.sh"
_YML_APP=shop; _YML_FILE="\$1"
_YML_DATA=\$(python3 "${TMP}/yamlval.py" "\$1" shop | jq .data)
_YML_ACTIONS=(); _YML_BLOCKERS=(); _YML_NOTES=()
_yml_plan_node 2>/dev/null
printf 'B|%s\n' "\${_YML_BLOCKERS[@]}"
printf 'N|%s\n' "\${_YML_NOTES[@]}"
EOF
printf 'version: 1\nnode:\n  framework: next\n' > "${TMP}/np1.yml"
echo "$NODEAPPS" > "${TMP}/napps.json"
out=$(bash "${TMP}/nplan.sh" "${TMP}/np1.yml")
grep -q "^N|node: ignored until 'cipi yml auto shop on'" <<< "$out" && pass "plan: node ignored without yml auto" || fail "plan without auto: ${out}"
echo "$NODEAPPS" | jq '.shop.yml_auto = "true"' > "${TMP}/napps.json"
out=$(bash "${TMP}/nplan.sh" "${TMP}/np1.yml")
grep -q '^N|  → mode: spa → ssr' <<< "$out" && grep -q '^N|  → start: - → npx next start -H 127.0.0.1' <<< "$out" \
    && grep -q '^N|  → framework: vite → next' <<< "$out" && ! grep -q '^B|.' <<< "$out" \
    && pass "plan: preset changes listed for the next deploy" || fail "plan with auto: ${out}"
printf 'version: 1\nnode:\n  version: 24\n' > "${TMP}/np2.yml"
grep -q '^B|node.version 24 is not installed — run: cipi node install 24' <<< "$(bash "${TMP}/nplan.sh" "${TMP}/np2.yml")" \
    && pass "plan: a Node major that is not installed blocks (install stays with root)" || fail "missing major not blocked"
echo "$NODEAPPS" | jq '.shop.runtime = null | .shop.custom = null' > "${TMP}/napps.json"
grep -q "^B|node: is declared, but 'shop' is not a Node app" <<< "$(bash "${TMP}/nplan.sh" "${TMP}/np1.yml")" \
    && pass "plan: node: on a Laravel app blocks" || fail "node on Laravel app not blocked"

echo "-- cipi.yml node: applied at deploy time (node-sync)"
NS="$(cd "${TMP}" && pwd -P)/ns"
mkdir -p "${NS}/bin" "${NS}/state" "${NS}/sites" "${NS}/home/shop/releases/7" "${NS}/home/shop/.deployer" "${NS}/home/shop/logs"
printf '#!/bin/bash\n[[ "$1" == -e ]] && shift\n[[ -e "$1" ]] || exit 1\npython3 -c "import os,sys;print(os.path.realpath(sys.argv[1]))" "$1"\n' > "${NS}/bin/realpath"
printf '#!/bin/bash\nexit 0\n' > "${NS}/bin/ss"
chmod +x "${NS}"/bin/*
cat > "${NS}/h.sh" <<EOF
export PATH="${NS}/bin:\$PATH" CIPI_LIB="${LIB}" CIPI_CONFIG="${NS}/cfg" CIPI_LOG="${NS}/log" NODE_STATE_DIR="${NS}/state"
RED=; GREEN=; YELLOW=; CYAN=; DIM=; NC=; BOLD=
source "${LIB}/common.sh" 2>/dev/null
vault_read() { cat "${NS}/apps.json"; }
vault_write() { local t; t=\$(cat); printf '%s\n' "\$t" > "${NS}/apps.json"; }
ensure_apps_json_api_access() { :; }; _update_apps_public() { :; }
cipi_notify() { :; }; log_action() { :; }; chown() { :; }
source "${LIB}/node.sh"
source "${LIB}/app.sh" 2>/dev/null
source "${LIB}/yml.sh"
node_is_installed() { [[ "\$1" == 22 ]]; }
_ensure_nginx_octane_map() { :; }; _nginx_reapply_ssl() { :; }; reload_nginx() { :; }
node_app_cleanup() { echo cleanup >> "${NS}/calls"; }
for fn in _yml_node_sync_cmd _sync_node_build_script _node_recipe_config_write _create_nginx_vhost _node_nginx_vhost _node_upstream_ensure; do
    eval "\$(declare -f \$fn | sed -e 's|/home/|${NS}/home/|g' -e 's|/etc/nginx/sites-available/|${NS}/sites/|g' -e 's|/etc/nginx/conf.d/|${NS}/|g')"
done
EOF
nsync() { bash -c "source '${NS}/h.sh'; _yml_node_sync_cmd shop '${NS}/home/shop/releases/7' $1" 2>&1; }
echo "$NODEAPPS" > "${NS}/apps.json"
printf 'version: 1\nnode:\n  framework: next\n' > "${NS}/home/shop/releases/7/cipi.yml"
nsync "" >/dev/null
[[ "$(jq -r .shop.node_mode "${NS}/apps.json")" == spa ]] && pass "node-sync: nothing without yml auto" || fail "node-sync applied without yml auto"
jq '.shop.yml_auto = "true"' "${NS}/apps.json" > "${NS}/a2" && mv "${NS}/a2" "${NS}/apps.json"
out=$(nsync "")
[[ "$(jq -r '.shop | [.node_mode, .node_start, .node_framework, .node_vhost_pending, (.node_ports | length | tostring)] | join("|")' "${NS}/apps.json")" \
    == "ssr|npx next start -H 127.0.0.1|next|true|2" ]] && grep -q '^\[cipi.yml\] node mode: spa → ssr' <<< "$out" \
    && pass "node-sync: preset applied, ports allocated, vhost change deferred" || fail "node-sync result: ${out} / $(jq -c .shop "${NS}/apps.json")"
[[ "$(jq -r .mode "${NS}/home/shop/.deployer/node.json")" == ssr ]] && pass "node-sync: recipe config (node.json) updated for this deploy" || fail "node.json not updated"
[[ "$(jq -r .start "${NS}/state/shop.json")" == "npx next start -H 127.0.0.1" ]] && pass "node-sync: blue/green state has the new start command" || fail "state not updated"
grep -qx 'npm run build' "${NS}/home/shop/.deployer/node-build.sh" && pass "node-sync: build script rewritten" || fail "build script wrong"
[[ ! -f "${NS}/sites/shop" ]] && pass "node-sync: nginx untouched before the symlink" || fail "vhost changed before the symlink"
nsync "--finalize" >/dev/null
grep -qF 'proxy_pass http://cipi_node_shop;' "${NS}/sites/shop" 2>/dev/null && [[ "$(jq -r '.shop.node_vhost_pending // "none"' "${NS}/apps.json")" == none ]] \
    && pass "finalize: vhost regenerated after the symlink, flag cleared" || fail "finalize did not regenerate the vhost"
printf 'version: 1\nnode:\n  version: 24\n' > "${NS}/home/shop/releases/7/cipi.yml"
before=$(jq -c .shop "${NS}/apps.json")
nsync "" >/dev/null; rc=$?
[[ $rc -eq 1 && "$(jq -c .shop "${NS}/apps.json")" == "$before" ]] \
    && pass "node-sync: missing Node major fails the deploy before the build, nothing changed" || fail "missing major: rc=${rc}"
printf 'version: 1\nnode:\n  mode: spa\n  output: out\n' > "${NS}/home/shop/releases/7/cipi.yml"
nsync "" >/dev/null; nsync "--finalize" >/dev/null
grep -qF 'root /home/shop/current/out;' "${NS}/sites/shop" 2>/dev/null || grep -qF "root ${NS}/home/shop/current/out;" "${NS}/sites/shop" 2>/dev/null
[[ $? -eq 0 && "$(jq -r '.shop.node_ports // "none"' "${NS}/apps.json")" == none ]] && grep -q cleanup "${NS}/calls" 2>/dev/null \
    && pass "ssr → spa: vhost serves the output, slots retired" || fail "ssr → spa: $(jq -c .shop "${NS}/apps.json")"
bash -c "source '${NS}/h.sh'; _yml_node_sync_cmd shop /etc" >/dev/null 2>&1; [[ $? -eq 2 ]] && pass "node-sync: refuses a path outside the releases" || fail "node-sync accepts a foreign path"
bash -c "source '${NS}/h.sh'; SUDO_USER=other _yml_node_sync_cmd shop '${NS}/home/shop/releases/7'" >/dev/null 2>&1; [[ $? -eq 2 ]] && pass "node-sync: other users refused" || fail "node-sync: other user accepted"
grep -q 'cipi yml node-sync ${app} \*' "${LIB}/yml.sh" && pass "sudo rule granted only by 'cipi yml auto on'" || fail "no node-sync sudo rule in yml auto"
grep -q "'node:config'," "${LIB}/deployer/node.php" && grep -q "after('deploy:symlink', 'node:finalize')" "${LIB}/deployer/node.php" \
    && pass "recipe: node:config before install, node:finalize after symlink" || fail "recipe order wrong"

echo "-- node: server-wide default for Laravel apps"
ND="$(cd "${TMP}" && pwd -P)/nd"
mkdir -p "${ND}/shim" "${ND}/node/v24.1.0/bin" "${ND}/home/blog/.deployer"
for b in node npm npx corepack pnpm; do printf '#!/bin/bash\necho 24\n' > "${ND}/node/v24.1.0/bin/${b}"; chmod +x "${ND}/node/v24.1.0/bin/${b}"; done
ln -s "${ND}/node/v24.1.0" "${ND}/node/24"
printf '#!/bin/bash\necho mine\n' > "${ND}/shim/yarn"
echo '{"blog":{"domain":"blog.test","php":"8.4","node_build":"npm run build"},"pin":{"domain":"p.test","php":"8.4","node_version":"24"}}' > "${ND}/apps.json"
NDH="export CIPI_LIB='${LIB}' CIPI_CONFIG='${ND}/cfg' CIPI_LOG='${ND}/log' NODE_ROOT='${ND}/node' NODE_SHIM_DIR='${ND}/shim'; RED=; NC=; CYAN=; DIM=;
    source '${LIB}/common.sh' 2>/dev/null; vault_read() { cat '${ND}/apps.json'; }; log_action() { :; }; cipi_notify() { :; }; chown() { :; }; source '${LIB}/node.sh';
    mv() { if [[ \"\$1\" == -Tf ]] && ! command mv -T /dev/null /dev/null 2>/dev/null; then shift; command mv -f \"\$@\"; else command mv \"\$@\"; fi; };"
bash -c "${NDH} _node_default_cmd 24" >/dev/null 2>&1
[[ "$(readlink "${ND}/shim/node")" == "${ND}/node/24/bin/node" && "$(readlink "${ND}/shim/pnpm")" == "${ND}/node/24/bin/pnpm" ]] \
    && pass "default: node, npm, pnpm… linked to the major (follows cipi node upgrade)" || fail "default shims not linked"
[[ ! -L "${ND}/shim/yarn" && "$(cat "${ND}/shim/yarn")" == *mine* ]] && pass "default: a binary Cipi did not install is left alone" || fail "foreign binary replaced"
[[ "$(bash -c "${NDH} node_default_major")" == 24 ]] && pass "default major detected from the link" || fail "default major not detected"
bash -c "${NDH} _node_remove_cmd 24" >/dev/null 2>&1; [[ $? -ne 0 && -L "${ND}/node/24" ]] && pass "the default major (or a pinned app's) cannot be removed" || fail "default major removed"
[[ "$(bash -c "${NDH} node_bin_for_app blog")" == "${ND}/node/24/bin" ]] && pass "Laravel app follows the server default" || fail "app does not follow the default"
bash -c "${NDH} _node_default_cmd system" >/dev/null 2>&1
[[ ! -e "${ND}/shim/node" && ! -e "${ND}/shim/npm" && -f "${ND}/shim/yarn" ]] && pass "default system: only Cipi's links removed" || fail "default system wrong"
[[ -z "$(bash -c "${NDH} node_bin_for_app blog")" && "$(bash -c "${NDH} node_bin_for_app pin")" == "${ND}/node/24/bin" ]] \
    && pass "system default: unpinned app uses /usr/bin, pinned app keeps its major" || fail "pin resolution wrong"
bash -c "${NDH} eval \"\$(declare -f _sync_node_build_script | sed 's|/home/|${ND}/home/|g')\"; _sync_node_build_script blog"
grep -qx 'export PATH="/usr/local/bin:$PATH"' "${ND}/home/blog/.deployer/node-build.sh" && pass "Laravel build script puts /usr/local/bin first" || fail "build script PATH: $(cat "${ND}/home/blog/.deployer/node-build.sh")"
echo '{"blog":{"domain":"blog.test","php":"8.4","node_build":"npm run build","node_version":"24"}}' > "${ND}/apps.json"
bash -c "${NDH} eval \"\$(declare -f _sync_node_build_script | sed 's|/home/|${ND}/home/|g')\"; _sync_node_build_script blog"
grep -qx 'export PATH="/opt/cipi/node/24/bin:/usr/local/bin:$PATH"' "${ND}/home/blog/.deployer/node-build.sh" && pass "pinned Laravel app builds with its major" || fail "pinned build script PATH wrong"
grep -q 'env_vars+=("PATH=${node_bin}' "${LIB}/app.sh" && pass "cipi app run npm uses the app's Node" || fail "app run ignores the Node version"
grep -q '"${ARG_node_version}" == "default"' "${LIB}/app.sh" && pass "app edit --node-version=default unpins" || fail "no unpin"
grep -q 'PATH=/usr/local/bin:/usr/bin:/bin' "${LIB}/yml.sh" && pass "deploy.post from cron sees the server default" || fail "deploy.post misses /usr/local/bin"

echo "-- migration: server Node 20 → 22"
grep -q 'setup_22.x' "${ROOT}/setup.sh" && ! grep -q 'setup_20.x' "${ROOT}/setup.sh" && pass "fresh installs get Node 22" || fail "setup still installs Node 20"
MG="$(cd "${TMP}" && pwd -P)/mg"
mig_run() { # $1 = system node version ("" = none), $2 = managed default to pre-link ("" = none), $3 = 22 installable (yes/no)
    rm -rf "$MG"; mkdir -p "${MG}/shim" "${MG}/usrbin" "${MG}/node"
    [[ -n "$1" ]] && printf '#!/bin/bash\necho v%s\n' "$1" > "${MG}/usrbin/node" && chmod +x "${MG}/usrbin/node"
    local m
    for m in 20 22 24; do
        [[ "$m" == 22 && "$3" != yes ]] && continue
        mkdir -p "${MG}/node/v${m}.9.0/bin"
        for b in node npm npx; do printf '#!/bin/bash\necho v%s.9.0\n' "$m" > "${MG}/node/v${m}.9.0/bin/${b}"; chmod +x "${MG}/node/v${m}.9.0/bin/${b}"; done
        ln -s "${MG}/node/v${m}.9.0" "${MG}/node/${m}"
    done
    [[ -n "$2" ]] && ln -s "${MG}/node/$2/bin/node" "${MG}/shim/node"
    echo '{}' > "${MG}/apps.json"
    { sed -n '/^RED=/,/^CYAN=/p' "${LIB}/migrations/5.4.0.sh"
      sed -n '/^# ── 6. server Node 20 → 22/,$p' "${LIB}/migrations/5.4.0.sh"; } | sed "s|/usr/bin/node|${MG}/usrbin/node|g" > "${MG}/step.sh"
    bash -c "export CIPI_LIB='${LIB}' CIPI_CONFIG='${MG}/cfg' CIPI_LOG='${MG}/log' NODE_ROOT='${MG}/node' NODE_SHIM_DIR='${MG}/shim'
        source '${LIB}/common.sh' 2>/dev/null
        vault_read() { cat '${MG}/apps.json'; }; log_action() { :; }; cipi_notify() { :; }; curl() { return 22; }
        mv() { if [[ \"\$1\" == -Tf ]]; then shift; command mv -f \"\$@\"; else command mv \"\$@\"; fi; }
        export -f vault_read log_action cipi_notify curl mv
        set -euo pipefail
        source '${MG}/step.sh'" 2>&1
}
out=$(mig_run 20.18.0 "" yes)
[[ "$(readlink "${MG}/shim/node")" == "${MG}/node/22/bin/node" ]] && grep -q 'server Node 20 → 22.9.0' <<< "$out" \
    && pass "system Node 20 → default 22" || fail "system 20 not moved: ${out}"
out=$(mig_run 20.18.0 20 yes)
[[ "$(readlink "${MG}/shim/node")" == "${MG}/node/22/bin/node" ]] && grep -q 'server Node 20 → 22.9.0' <<< "$out" \
    && pass "managed default 20 → 22" || fail "managed 20 not moved: ${out}"
grep -q '^RED=' "${LIB}/migrations/5.4.0.sh" && pass "migration defines the colours common.sh prints with (set -u)" || fail "migration colours missing"
out=$(mig_run 20.18.0 24 yes)
[[ "$(readlink "${MG}/shim/node")" == "${MG}/node/24/bin/node" ]] && grep -q 'server Node: 24 (managed) — unchanged' <<< "$out" \
    && pass "a server already on 24 is left alone" || fail "managed 24 changed: ${out}"
out=$(mig_run 22.3.0 "" yes)
[[ ! -e "${MG}/shim/node" ]] && grep -q 'server Node: 22 (system) — unchanged' <<< "$out" && pass "system Node 22 is left alone" || fail "system 22 changed: ${out}"
out=$(mig_run 20.18.0 "" no); rc=$?
[[ $rc -eq 0 && ! -e "${MG}/shim/node" ]] && grep -q 'still on Node 20. Retry: cipi node default 22' <<< "$out" \
    && pass "download failure: stays on 20, migration continues" || fail "failed download broke the migration (rc=${rc}): ${out}"
out=$(mig_run "" "" yes)
[[ ! -e "${MG}/shim/node" && -z "$(grep -v '^$' <<< "$out")" ]] && pass "no Node on the server: nothing installed" || fail "no-node server: ${out}"

echo "-- node: vhosts"
mkdir -p "${TMP}/nx/sites" "${TMP}/nx/confd" "${TMP}/nx/ba"
echo 'admin:x' > "${TMP}/nx/ba/web.htpasswd"
cat > "${TMP}/nx/apps.json" <<'EOF'
{"web":{"domain":"web.test","aliases":["www.web.test"],"php":"8.4","custom":true,"runtime":"node","node_mode":"spa","node_version":"22","node_output":"dist","basic_auth":"true"},
 "ssr":{"domain":"ssr.test","aliases":[],"php":"8.4","custom":true,"runtime":"node","node_mode":"ssr","node_version":"22","node_start":"node build","node_ports":[3100,3101]}}
EOF
VH="${NH} vault_read() { cat '${TMP}/nx/apps.json'; }; _ensure_nginx_octane_map() { :; }; source '${LIB}/routes.sh';
eval \"\$(declare -f _create_nginx_vhost | sed 's|/etc/nginx/sites-available/|${TMP}/nx/sites/|g; s|/etc/nginx/cipi-basicauth/|${TMP}/nx/ba/|g')\";
eval \"\$(declare -f _node_nginx_vhost | sed 's|/etc/nginx/sites-available/|${TMP}/nx/sites/|g')\";
eval \"\$(declare -f _node_upstream_ensure | sed 's|/etc/nginx/conf.d/|${TMP}/nx/confd/|g')\";"
bash -c "${VH} _create_nginx_vhost web web.test 8.4; _create_nginx_vhost ssr ssr.test 8.4" >/dev/null 2>&1
v="${TMP}/nx/sites/web"
grep -qF 'root /home/web/current/dist;' "$v" && pass "spa root is the build output" || fail "spa root wrong"
grep -qF 'try_files $uri $uri/ /index.html;' "$v" && pass "spa history fallback" || fail "no spa fallback"
grep -qF 'immutable' "$v" && grep -qF 'Cache-Control "no-cache"' "$v" && pass "hashed assets immutable, HTML revalidated" || fail "cache headers wrong"
[[ "$(sed -n '/location = \/cipi\/webhook/,/}/p' "$v" | grep -c auth_basic)" == "0" ]] && [[ "$(grep -c 'auth_basic "Restricted"' "$v")" -ge 1 ]] \
    && pass "basic auth on the site, never on the webhook" || fail "basic auth placement wrong"
grep -qF 'fastcgi_param SCRIPT_FILENAME /usr/local/share/cipi/webhook.php;' "$v" && grep -qF 'limit_except POST' "$v" \
    && pass "webhook routed to the receiver, POST only" || fail "webhook location wrong"
[[ "$(grep -o '{' "$v" | wc -l)" == "$(grep -o '}' "$v" | wc -l)" ]] && pass "spa braces balanced" || fail "spa braces unbalanced"
v="${TMP}/nx/sites/ssr"
grep -qF 'proxy_pass http://cipi_node_ssr;' "$v" && [[ "$(grep -c 'fastcgi_pass' "$v")" == "1" ]] \
    && pass "ssr proxies to the app upstream" || fail "ssr vhost wrong"
grep -qF 'server 127.0.0.1:3100;' "${TMP}/nx/confd/cipi-node-ssr.conf" && pass "upstream created on the first slot" || fail "no upstream"
[[ "$(grep -o '{' "$v" | wc -l)" == "$(grep -o '}' "$v" | wc -l)" ]] && pass "ssr braces balanced" || fail "ssr braces unbalanced"
jq '.web.node_mode = "static"' "${TMP}/nx/apps.json" > "${TMP}/nx/a2" && mv "${TMP}/nx/a2" "${TMP}/nx/apps.json"
bash -c "${VH} _create_nginx_vhost web web.test 8.4" >/dev/null 2>&1
grep -qF 'try_files $uri $uri/ $uri.html =404;' "${TMP}/nx/sites/web" && grep -qF 'error_page 404 /404.html;' "${TMP}/nx/sites/web" \
    && pass "static: real 404s" || fail "static vhost wrong"

echo "-- node: recipe"
mkdir -p "${TMP}/nr/home/ssr/.deployer"
echo '{"ssr":{"domain":"ssr.test","php":"8.4","custom":true,"runtime":"node","node_mode":"ssr","node_version":"24","node_start":"node build","branch":"main"}}' > "${TMP}/nr/apps.json"
bash -c "${NH} vault_read() { cat '${TMP}/nr/apps.json'; }; source '${LIB}/app.sh' 2>/dev/null
    eval \"\$(declare -f _create_deployer_config_from_template | sed 's|/home/|${TMP}/nr/home/|g')\"
    eval \"\$(declare -f deployer_audit_ensure_hook | sed 's|/home/|${TMP}/nr/home/|g')\"
    chown() { :; }
    _create_deployer_config_from_template node ssr git@github.com:a/b.git main 8.4" >/dev/null 2>&1
df="${TMP}/nr/home/ssr/.deployer/deploy.php"
[[ -f "$df" ]] && ! grep -q '__CIPI_' "$df" && pass "recipe rendered, no placeholder left" || fail "recipe placeholders left"
grep -qF "set('cipi_node_version', '24');" "$df" && grep -qF "/opt/cipi/node/' . get('cipi_node_version')" "$df" && pass "recipe uses the app's Node major" || fail "recipe Node path wrong"
grep -qF "sudo -n /usr/local/bin/cipi-node-switch ssr {{release_path}}" "$df" && pass "switch before publish" || fail "no switch in recipe"
grep -qF "'node:switch',"$'\n'"    'deploy:publish'," "$df" && pass "switch runs before deploy:publish (symlink)" || fail "switch order wrong"
grep -q 'cipi:deploy-audit' "$df" && pass "audit hooks on Node recipes too" || fail "Node recipe not audited"
grep -q '.deployer/node.json' <<< "$(sed -n '/^_yml_post_deploy_exec() {/,/^}/p' "${LIB}/yml.sh")" \
    && pass "deploy.post npm/node steps use the app's Node major (node.json)" || fail "deploy.post Node major lookup stale"
command -v php >/dev/null 2>&1 && { php -l "$df" >/dev/null 2>&1 && pass "rendered recipe parses" || fail "rendered recipe does not parse"; }

echo "-- node: process launcher reads .env as data"
NRUN="$(cd "${TMP}" && pwd -P)/nrun"
mkdir -p "${NRUN}/rel"
sed -e 's|if \[\[ "$(id -un)" != "$APP" \]\]; then|if false; then|' -e "s|\"/home/\${APP}/releases/\"\*)|\"${NRUN}/rel\"*)|" \
    "${LIB}/cipi-node-run.sh" > "${NRUN}/run.sh"
cat > "${NRUN}/rel/.env" <<EOF
NEXT_PUBLIC_API="https://api.test/v1"
QUOTED='a b \$HOME'
export FOO=bar # comment
PORT=9999
EVIL=\$(touch ${NRUN}/pwned)
EOF
envout=$(cd "${NRUN}/rel" && env -i PATH=/usr/bin:/bin PORT=3100 CIPI_NODE_START=env bash "${NRUN}/run.sh" shop 2>&1)
grep -qx 'PORT=3100' <<< "$envout" && pass ".env cannot move the slot's PORT" || fail "PORT overridden"
grep -qx 'HOST=127.0.0.1' <<< "$envout" && pass "bound to localhost" || fail "HOST not forced"
grep -qx 'NEXT_PUBLIC_API=https://api.test/v1' <<< "$envout" && grep -qx 'FOO=bar' <<< "$envout" && grep -qx 'QUOTED=a b $HOME' <<< "$envout" \
    && pass ".env values: quotes stripped, no expansion, comments dropped" || fail ".env parsing wrong: ${envout}"
[[ ! -e "${NRUN}/pwned" ]] && pass "\$(…) in .env is never executed" || fail ".env executed a command"
(cd /tmp && env -i PATH=/usr/bin:/bin PORT=3100 CIPI_NODE_START=env bash "${LIB}/cipi-node-run.sh" shop >/dev/null 2>&1)
[[ $? -eq 2 ]] && pass "refuses outside the app's releases / wrong user" || fail "runs outside a release"

echo "-- node: blue/green switch (simulated Supervisor, nginx, curl)"
SW="$(cd "${TMP}" && pwd -P)/sw"
mkdir -p "${SW}/bin" "${SW}/state" "${SW}/sup" "${SW}/home/shop/releases/1" "${SW}/home/shop/releases/2" "${SW}/home/shop/logs" "${SW}/node/22/bin"
printf '#!/bin/bash\n' > "${SW}/node/22/bin/node"; chmod +x "${SW}/node/22/bin/node"
ln -s "${SW}/home/shop/releases/2" "${SW}/home/shop/current"
printf '#!/bin/bash\ncase "$1" in -u) echo 0;; -un) echo root;; *) /usr/bin/id "$@";; esac\n' > "${SW}/bin/id"
cat > "${SW}/bin/supervisorctl" <<EOF
#!/bin/bash
D="${SW}/sup"; cmd=\$1; shift
case "\$cmd" in
  status) for p in "\$@"; do printf '%s %s\n' "\$p" "\$(cat "\$D/\$p" 2>/dev/null || echo STOPPED)"; done ;;
  start)  for p in "\$@"; do echo RUNNING > "\$D/\$p"; done ;;
  stop)   for p in "\$@"; do echo STOPPED > "\$D/\$p"; done ;;
  update) for p in "\$@"; do
            a=\$(awk -v s="[program:\$p]" '\$0==s{f=1;next} /^\[program:/{f=0} f && /^autostart=/{sub("autostart=","");print}' "${SW}/shop-node.conf")
            [[ "\$a" == true ]] && echo RUNNING > "\$D/\$p" || echo STOPPED > "\$D/\$p"
          done ;;
esac
exit 0
EOF
printf '#!/bin/bash\necho "${CURL_CODE:-200}"\n' > "${SW}/bin/curl"
printf '#!/bin/bash\nexit 0\n' > "${SW}/bin/nginx"
for c in systemctl flock sleep ss; do printf '#!/bin/bash\nexit 0\n' > "${SW}/bin/${c}"; done
printf '#!/bin/bash\n[[ "$1" == -e ]] && shift\n[[ -e "$1" ]] || exit 1\npython3 -c "import os,sys;print(os.path.realpath(sys.argv[1]))" "$1"\n' > "${SW}/bin/realpath"
chmod +x "${SW}"/bin/*
sed -e "s|/var/lib/cipi/node/|${SW}/state/|g" -e "s|/etc/supervisor/conf.d/|${SW}/|g" -e "s|/etc/nginx/conf.d/|${SW}/|g" \
    -e "s|/run/lock/|${SW}/|g" -e "s|HOME_DIR=\"/home/\${APP}\"|HOME_DIR=\"${SW}/home/\${APP}\"|" \
    -e "s|\^/home/\${APP}/releases/|^${SW}/home/\${APP}/releases/|" -e "s|/opt/cipi/node/|${SW}/node/|g" \
    "${LIB}/cipi-node-switch.sh" > "${SW}/switch.sh"
echo '{"app":"shop","mode":"ssr","version":"22","start":"node build","health":"/","health_timeout":2,"drain":0,"ports":[3100,3101],"domain":"shop.test","active":-1,"releases":["",""]}' > "${SW}/state/shop.json"
swrun() { local e=(); while [[ "$1" == *=* ]]; do e+=("$1"); shift; done
          env -i HOME="$HOME" PATH="${SW}/bin:/usr/bin:/bin:/usr/sbin:/opt/homebrew/bin:/usr/local/bin" "${e[@]}" bash "${SW}/switch.sh" "$@" >/dev/null 2>&1; }
sup() { cat "${SW}/sup/shop-node-$1" 2>/dev/null || echo STOPPED; }
swrun SUDO_USER=shop shop "${SW}/home/shop/releases/1"
[[ $? -eq 0 && "$(jq -r .active "${SW}/state/shop.json")" == 0 && "$(sup blue)" == RUNNING ]] \
    && grep -q 'server 127.0.0.1:3100;' "${SW}/cipi-node-shop.conf" && pass "first deploy: blue serves" || fail "first deploy switch wrong"
swrun SUDO_USER=shop shop current
[[ $? -eq 0 && "$(jq -r .active "${SW}/state/shop.json")" == 1 && "$(sup green)" == RUNNING && "$(sup blue)" == STOPPED ]] \
    && grep -q 'server 127.0.0.1:3101;' "${SW}/cipi-node-shop.conf" && pass "next deploy: green serves, blue stopped after the switch" || fail "second switch wrong"
grep -A6 '^\[program:shop-node-blue\]' "${SW}/shop-node.conf" | grep -q 'autostart=false' \
    && pass "idle slot does not come back on reboot" || fail "idle slot still autostarts"
swrun CURL_CODE=503 SUDO_USER=shop shop "${SW}/home/shop/releases/1"
[[ $? -eq 1 && "$(jq -r .active "${SW}/state/shop.json")" == 1 && "$(sup green)" == RUNNING && "$(sup blue)" == STOPPED ]] \
    && grep -q 'server 127.0.0.1:3101;' "${SW}/cipi-node-shop.conf" && pass "unhealthy release: deploy fails, old slot keeps serving" || fail "failed health changed the live slot"
swrun SUDO_USER=shop shop /etc; [[ $? -eq 2 ]] && pass "refuses a path outside the app's releases" || fail "accepts a foreign path"
swrun SUDO_USER=shop shop "${SW}/home/shop/releases/1/../../../../../../etc"; [[ $? -eq 2 ]] && pass "refuses traversal" || fail "accepts traversal"
swrun SUDO_USER=other shop current; [[ $? -eq 2 ]] && pass "another app user is refused" || fail "another user may switch"
swrun SUDO_USER=shop shop --stop; [[ $? -eq 2 ]] && pass "--stop is root only" || fail "app user may stop its slots"
grep -q 'environment=.*PORT="${PORTS\[$i\]}"' "${LIB}/cipi-node-switch.sh" && grep -q 'user=${APP}' "${LIB}/cipi-node-switch.sh" \
    && pass "slot runs as the app user on its own port" || fail "slot program definition wrong"

echo "-- node: webhook receiver"
if command -v php >/dev/null 2>&1 && command -v openssl >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
    WH="$(cd "${TMP}" && pwd -P)/wh"
    mkdir -p "${WH}/home/shop/.cipi"
    echo '{"token":"s3cret","branch":"main"}' > "${WH}/home/shop/.cipi/webhook.json"
    sed "s|'/home/' . \$app|'${WH}/home/' . \$app|" "${LIB}/cipi-webhook.php" > "${WH}/webhook.php"
    printf '<?php $_SERVER["CIPI_APP"]="shop"; require __DIR__."/webhook.php";\n' > "${WH}/router.php"
    WPORT=$((20000 + RANDOM % 20000))
    php -S "127.0.0.1:${WPORT}" "${WH}/router.php" >/dev/null 2>&1 & WPID=$!
    for _ in 1 2 3 4 5 6 7 8 9 10; do curl -s -o /dev/null "http://127.0.0.1:${WPORT}/" && break; sleep 0.3; done
    hreq() { curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:${WPORT}/cipi/webhook" "$@"; }
    hsig() { printf 'sha256=%s' "$(printf '%s' "$1" | openssl dgst -sha256 -hmac s3cret | awk '{print $NF}')"; }
    trig="${WH}/home/shop/.deploy-trigger"
    b='{"ref":"refs/heads/main","after":"abcdef1234567890","pusher":{"name":"jane"}}'
    [[ "$(hreq -H 'X-GitHub-Event: push' -H "X-Hub-Signature-256: $(hsig "$b")" --data "$b")" == 202 ]] \
        && [[ "$(jq -r '.source + "|" + .actor + "|" + .ref' "$trig" 2>/dev/null)" == "github|jane|main@abcdef123456" ]] \
        && pass "GitHub push queues a deploy with its claims" || fail "GitHub push not queued"
    rm -f "$trig"
    [[ "$(hreq -H 'X-GitHub-Event: push' -H 'X-Hub-Signature-256: sha256=00' --data "$b")" == 403 && ! -e "$trig" ]] \
        && pass "bad GitHub signature → 403" || fail "bad signature accepted"
    b2='{"ref":"refs/heads/dev"}'
    [[ "$(hreq -H 'X-GitHub-Event: push' -H "X-Hub-Signature-256: $(hsig "$b2")" --data "$b2")" == 202 && ! -e "$trig" ]] \
        && pass "push to another branch is ignored" || fail "other branch triggered a deploy"
    [[ "$(hreq -H 'X-Gitlab-Event: Push Hook' -H 'X-Gitlab-Token: s3cret' --data '{"ref":"refs/heads/main"}')" == 202 && -e "$trig" ]] \
        && pass "GitLab token" || fail "GitLab push not queued"
    rm -f "$trig"
    [[ "$(hreq -H 'X-Gitlab-Event: Push Hook' -H 'X-Gitlab-Token: nope' --data '{"ref":"refs/heads/main"}')" == 403 ]] \
        && pass "bad GitLab token → 403" || fail "bad GitLab token accepted"
    b3='{"push":{"changes":[{"new":{"type":"branch","name":"main","target":{"hash":"ffff"}}}]}}'
    [[ "$(hreq -H 'X-Event-Key: repo:push' -H "X-Hub-Signature: $(hsig "$b3")" --data "$b3")" == 202 && -e "$trig" ]] \
        && pass "Bitbucket signature" || fail "Bitbucket push not queued"
    rm -f "$trig"
    [[ "$(hreq --data "$b")" == 403 ]] && pass "unsigned request → 403" || fail "unsigned request accepted"
    [[ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${WPORT}/cipi/webhook")" == 405 ]] && pass "GET → 405" || fail "GET accepted"
    kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
else
    echo "  (php/openssl/curl missing — webhook receiver not exercised)"
fi
grep -q 'open_basedir\] = /home/${app}/' "${LIB}/node.sh" && grep -q 'disable_functions\] = exec' "${LIB}/node.sh" \
    && pass "webhook pool: open_basedir + no exec" || fail "webhook pool not locked down"

# ── backup retention ──────────────────────────────────────────
echo "-- backup retention: orphaned archives and silent S3 errors"
BK="$(cd "${TMP}" && pwd -P)/bk"
mkdir -p "${BK}/bin" "${BK}/s3/bucket/cipi" "${BK}/local" "${BK}/log/backups"
cat > "${BK}/bin/aws" <<EOF
#!/bin/bash
# aws s3 [--endpoint-url X --region Y] ls|rm s3://bucket/prefix/ [--recursive]
[[ "\$1" == s3 ]] || exit 2; shift
while [[ "\$1" == --* ]]; do shift 2; done
op=\$1; uri=\$2; path="${BK}/s3/\${uri#s3://}"
case "\$op" in
  ls) [[ -n "\${FAIL_LS:-}" ]] && { echo "An error occurred (AccessDenied) when calling the ListObjectsV2 operation: Access Denied" >&2; exit 1; }
      [[ -d "\$path" ]] || exit 1
      for d in "\$path"*/; do [[ -d "\$d" ]] && printf '                           PRE %s/\n' "\$(basename "\$d")"; done; exit 0 ;;
  rm) [[ -n "\${FAIL_RM:-}" ]] && { echo "delete denied" >&2; exit 1; }
      rm -rf "\$path"; exit 0 ;;
esac
EOF
chmod +x "${BK}/bin/aws"
d() { python3 -c "import datetime,sys;print((datetime.date.today()-datetime.timedelta(days=int(sys.argv[1]))).isoformat())" "$1"; }
dn() { d "$1" | tr -d -; }
mkrun() { mkdir -p "${BK}/s3/bucket/cipi/$1/$(d "$2")_020000"; touch "${BK}/s3/bucket/cipi/$1/$(d "$2")_020000/manifest.json"; }
mkrun default 2; mkrun default 10
mkrun shop 3; mkrun shop 40
mkrun oldprof 20
touch "${BK}/log/backups/mariadb_shop_predeploy_$(dn 30)_010101.sql.gz" "${BK}/log/backups/mariadb_shop_predeploy_$(dn 1)_010101.sql.gz"
touch "${BK}/log/backups/mariadb_shop2024_predeploy_$(dn 1)_010101.sql.gz"
BKH="export PATH='${BK}/bin:/usr/bin:/bin' CIPI_LIB='${LIB}' CIPI_CONFIG='${BK}/cfg' CIPI_LOG='${BK}/log'
    RED=; GREEN=; YELLOW=; CYAN=; DIM=; NC=; BOLD=
    source '${LIB}/common.sh' 2>/dev/null
    source '${LIB}/backup.sh'
    _bk_cfg() { echo '{\"bucket\":\"bucket\",\"local_dir\":\"${BK}/local\"}'; }
    _bk_has_s3() { return 0; }
    _bk_require_config() { :; }
    _bk_profiles_json() { echo '{\"default\":{\"destinations\":[\"s3\"],\"retention\":{\"keep\":0,\"days\":0,\"weeks\":1}}}'; }
    log_action() { :; }
    cipi_notify() { printf '%s\n' \"\$1\" >> '${BK}/notified'; }
    set -euo pipefail"
out=$(bash -c "${BKH}; _bk_prune --dry-run" 2>&1)
grep -q "would delete default/$(d 10)_020000" <<< "$out" && grep -q "would delete s3 cipi/shop/$(d 40)_020000 (orphaned)" <<< "$out" \
    && [[ -d "${BK}/s3/bucket/cipi/shop/$(d 40)_020000" ]] && pass "dry-run lists expired profile and pre-5.1 runs, deletes nothing" || fail "dry-run: ${out}"
out=$(bash -c "${BKH}; _bk_prune" 2>&1); rc=$?
[[ $rc -eq 0 && ! -d "${BK}/s3/bucket/cipi/default/$(d 10)_020000" && -d "${BK}/s3/bucket/cipi/default/$(d 2)_020000" ]] \
    && pass "profile retention (1w) still works" || fail "profile prune: rc=${rc} ${out}"
[[ ! -d "${BK}/s3/bucket/cipi/shop/$(d 40)_020000" && -d "${BK}/s3/bucket/cipi/shop/$(d 3)_020000" ]] \
    && pass "pre-5.1 layout (cipi/<app>/) pruned by the longest profile retention" || fail "legacy layout not pruned: ${out}"
[[ ! -d "${BK}/s3/bucket/cipi/oldprof/$(d 20)_020000" ]] && pass "runs of a removed profile are pruned" || fail "removed profile runs kept"
[[ ! -f "${BK}/log/backups/mariadb_shop_predeploy_$(dn 30)_010101.sql.gz" && -f "${BK}/log/backups/mariadb_shop_predeploy_$(dn 1)_010101.sql.gz" ]] \
    && [[ -f "${BK}/log/backups/mariadb_shop2024_predeploy_$(dn 1)_010101.sql.gz" ]] \
    && pass "old pre-deploy snapshots pruned by their date suffix (digits in app names ignored)" || fail "snapshot prune wrong"
rm -f "${BK}/notified"
bash -c "FAIL_LS=1; export FAIL_LS; ${BKH}; _bk_retention_after_run default" >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]] && grep -q 'Cipi backup retention failed: profile default' "${BK}/notified" 2>/dev/null \
    && pass "S3 listing denied: alert sent, backup run not aborted" || fail "listing failure silent or fatal (rc=${rc})"
out=$(bash -c "FAIL_LS=1; export FAIL_LS; ${BKH}; _bk_prune" 2>&1); rc=$?
[[ $rc -eq 1 ]] && grep -q 'AccessDenied' <<< "$out" && pass "cipi backup prune reports the S3 error and exits 1" || fail "prune error not reported: ${out}"
grep -q 'export PATH="/usr/local/bin:${PATH}"' "${LIB}/backup.sh" && pass "cron PATH gets /usr/local/bin (AWS CLI location)" || fail "no PATH fix for cron"
mkrun default 30
bash -c "${BKH}; _bk_profiles_json() { echo '{\"db\":{\"retention\":{\"keep\":48,\"days\":0,\"weeks\":0}}}'; }; _bk_prune_orphans false" >/dev/null 2>&1
[[ -d "${BK}/s3/bucket/cipi/default/$(d 30)_020000" ]] && pass "count-only retention: orphans left alone (no age to go by)" || fail "orphans deleted without an age retention"

echo "-- docs"
grep -q 'deploy <app> --audit' "${ROOT}/cipi" && pass "help documents --audit" || fail "help omits --audit"
grep -q 'audit ledger' "${ROOT}/README.md" && pass "README documents the audit ledger" || fail "README omits the audit ledger"
grep -q -- '--framework=next' "${ROOT}/README.md" && grep -q 'cipi app create --node' "${ROOT}/CHANGELOG.md" \
    && pass "README and CHANGELOG document Node apps" || fail "Node apps undocumented"
grep -q 'basic_auth' "${ROOT}/README.md" && grep -q 'proxies:' "${ROOT}/README.md" \
    && pass "README documents the new cipi.yml keys" || fail "README omits the new cipi.yml keys"
grep -q 'force_https' "${ROOT}/README.md" && grep -q 'crons' "${ROOT}/README.md" \
    && grep -q 'keep_releases' "${ROOT}/README.md" && grep -q 'required: \[STRIPE_KEY\]' "${ROOT}/README.md" \
    && grep -q 'ssl.force_https' "${ROOT}/CHANGELOG.md" && grep -q 'env.required' "${ROOT}/CHANGELOG.md" \
    && pass "README and CHANGELOG document deploy config, limits, ssl, env and crons" \
    || fail "cipi.yml deploy config / limits / ssl / env / crons undocumented"

echo "=== ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]

#!/bin/bash
# Local regression checks for 5.2.2 — opt-in Meilisearch (cipi search).
# Run from repo root: bash tests/verify-5.2.2.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/lib"
SEARCH="${LIB}/search.sh"
PASS=0
FAIL=0

pass() { echo "  OK: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

echo "=== Cipi 5.2.2 regression checks ==="

[[ "$(tr -d '[:space:]' < "${ROOT}/version.md")" == "5.2.2" ]] \
    && pass "version.md is 5.2.2" || fail "version.md is not 5.2.2"
grep -q '^## \[5.2.2\]' "${ROOT}/CHANGELOG.md" \
    && pass "CHANGELOG has a 5.2.2 entry" || fail "CHANGELOG has no 5.2.2 entry"
[[ ! -f "${LIB}/migrations/5.2.2.sh" ]] \
    && pass "no 5.2.2 migration (opt-in, code-only)" || fail "stray 5.2.2 migration"

echo "-- syntax"
for f in "${SEARCH}" "${LIB}/service.sh" "${LIB}/completion.sh" "${LIB}/notifications.sh" \
         "${LIB}/common.sh" "${LIB}/app.sh" "${LIB}/cipi-api-sudoers.sh" "${ROOT}/cipi"; do
    if bash -n "$f" 2>/dev/null; then
        pass "syntax $(basename "$f")"
    else
        fail "syntax $(basename "$f")"
        bash -n "$f" || true
    fi
done

echo "-- dispatch and help"
[[ -f "$SEARCH" ]] && pass "lib/search.sh exists" || fail "lib/search.sh missing"
grep -qE '^[[:space:]]+search\)' "${ROOT}/cipi" \
    && pass "cipi dispatches search" || fail "cipi does not dispatch search"
grep -q 'search_command' "$SEARCH" \
    && pass "search_command exists" || fail "no search_command"
grep -q 'show_help_topic search' "${ROOT}/cipi" \
    && pass "help all includes the search topic" || fail "help all omits search"
grep -qE '^[[:space:]]+search\|meilisearch\|scout\)' "${ROOT}/cipi" \
    && pass "help topic accepts search|meilisearch|scout" || fail "no search help topic"
grep -q 'cipi search install' "${ROOT}/cipi" \
    && pass "help lists cipi search install" || fail "help omits search install"
if "${ROOT}/cipi" 2>/dev/null | grep -q search; then : ; fi   # cipi needs root; help text is checked statically
grep -q ' search ' <<< "$(sed -n '/_help_topics_list()/,/^EOF/p' "${ROOT}/cipi")" \
    && pass "search is in the help topics list" || fail "search missing from the topics list"

for sub in install status enable disable list upgrade remove; do
    grep -qE "^[[:space:]]+${sub}[|)]" "$SEARCH" \
        && pass "search_command handles ${sub}" || fail "search_command has no ${sub}"
done
grep -q 'key|keys)' "$SEARCH" \
    && pass "search_command handles key" || fail "search_command has no key"

echo "-- completion"
grep -q 'health db search ssl' "${LIB}/completion.sh" \
    && pass "completion advertises the search verb" || fail "completion omits search"
if sed -n '/^        search)/,/^            esac ;;/p' "${LIB}/completion.sh" | grep -q '_cipi_apps'; then
    pass "cipi search enable completes app names"
else
    fail "cipi search does not complete app names"
fi
if sed -n '/^        search)/,/^            esac ;;/p' "${LIB}/completion.sh" | grep -q -- '--master'; then
    pass "completion offers key rotate --master"
else
    fail "completion omits --master"
fi
# Drift guard, same rule as 5.2.0: an advertised verb must dispatch.
adv=$(sed -n 's/.*local commands="\([^"]*\)".*/\1/p' "${LIB}/completion.sh")
grep -qw search <<< "$adv" \
    && pass "search is in the completion verb list" || fail "search missing from the verb list"

echo "-- service integration"
grep -q 'systemd_unit_exists meilisearch' "${LIB}/service.sh" \
    && pass "service list includes meilisearch when present" || fail "service list omits meilisearch"
grep -q 'search|meili)' "${LIB}/service.sh" \
    && pass "cipi service accepts the 'search' alias" || fail "no search alias in service.sh"
grep -q 'systemd_unit_exists meilisearch' "${ROOT}/cipi" \
    && pass "cipi status lists meilisearch when present" || fail "cipi status omits meilisearch"

echo "-- notifications"
for t in search_install search_enable search_disable search_key_rotate search_upgrade search_remove; do
    grep -q "^${t}|Search|" "${LIB}/notifications.sh" \
        && pass "trigger ${t}" || fail "missing trigger ${t}"
done
for t in search_install search_enable search_disable search_key_rotate search_upgrade search_remove; do
    grep -q "$t" "$SEARCH" || fail "search.sh never fires ${t}"
done
pass "every Search trigger is fired from search.sh"

echo "-- isolation model"
grep -q 'SCOUT_PREFIX=' "$SEARCH" \
    && pass "SCOUT_PREFIX is written by Cipi" || fail "SCOUT_PREFIX is not written"
if grep -q 'ARG_prefix' "$SEARCH"; then
    fail "the index prefix is operator-settable (it must not be)"
else
    pass "the index prefix is not an operator choice"
fi
# The key must not be able to mint other keys, or the pattern means nothing.
actions=$(sed -n 's/.*SEARCH_KEY_ACTIONS=.\(\[.*\]\).*/\1/p' "$SEARCH")
[[ -n "$actions" ]] && pass "SEARCH_KEY_ACTIONS is defined" || fail "no SEARCH_KEY_ACTIONS"
grep -q 'keys\.' <<< "$actions" \
    && fail "the app key may manage keys: ${actions}" || pass "the app key cannot manage keys"
grep -q '"search"' <<< "$actions" \
    && pass "the app key can search" || fail "the app key cannot search"
grep -q '"documents\.\*"' <<< "$actions" \
    && pass "the app key can write documents" || fail "the app key cannot write documents"
grep -q 'indexes:\[\$i\]' "$SEARCH" \
    && pass "the key is scoped to one index pattern" || fail "the key is not index-scoped"
grep -q 'overlaps app' "$SEARCH" \
    && pass "enable refuses an overlapping prefix" || fail "no prefix overlap guard"

echo "-- prefix arithmetic (the isolation boundary)"
eval "$(sed -n '/^_search_prefix_for()/,/^}/p' "$SEARCH")"
[[ "$(_search_prefix_for blog)" == "blog-" ]] \
    && pass "_search_prefix_for blog → blog-" || fail "_search_prefix_for is wrong"
# A Cipi username is ^[a-z][a-z0-9]{2,31}$ — no hyphens — so no prefix can
# contain another. If validate_username ever gains '-', this stops being true.
if grep -q 'a-z\]\[a-z0-9\]{2,31}' "${LIB}/common.sh"; then
    pass "usernames still exclude '-' (prefixes cannot overlap)"
else
    fail "validate_username changed — re-check the prefix isolation argument"
fi
p1=$(_search_prefix_for blog); p2=$(_search_prefix_for blogs)
if [[ "$p2" == "$p1"* || "$p1" == "$p2"* ]]; then
    fail "blog-/blogs- overlap"
else
    pass "blog- and blogs- do not overlap"
fi

echo "-- the master key never leaks"
if sed -n '/^_search_write_unit()/,/^}/p' "$SEARCH" | grep -q -- '--master-key'; then
    fail "the unit passes --master-key on the command line (visible in ps)"
else
    pass "the unit does not put the master key in ExecStart"
fi
sed -n '/^_search_write_unit()/,/^}/p' "$SEARCH" | grep -q 'EnvironmentFile=' \
    && pass "the unit reads the key from an EnvironmentFile" || fail "no EnvironmentFile in the unit"
sed -n '/^_search_write_env_file()/,/^}/p' "$SEARCH" | grep -q 'chmod 600' \
    && pass "the EnvironmentFile is 0600" || fail "the EnvironmentFile is not 0600"
if sed -n '/^_search_write_toml()/,/^}/p' "$SEARCH" | grep -qiE '^[[:space:]]*(master_key|MEILI_MASTER_KEY)'; then
    fail "the master key is written into meilisearch.toml"
else
    pass "meilisearch.toml holds no secret"
fi
if sed -n '/^_search_api()/,/^}/p' "$SEARCH" | grep -q '\-H "Authorization'; then
    fail "curl receives the master key as an argument"
else
    pass "curl reads the auth header from stdin (-K -)"
fi
sed -n '/^_search_api()/,/^}/p' "$SEARCH" | grep -q -- '-K -' \
    && pass "_search_api uses a curl stdin config" || fail "_search_api does not use -K -"

echo "-- loopback only"
grep -q 'SEARCH_HOST="127.0.0.1"' "$SEARCH" \
    && pass "the listener is pinned to 127.0.0.1" || fail "the listener is not pinned to loopback"
if grep -q 'ARG_host' "$SEARCH"; then
    fail "--host is settable (a public Meilisearch is a data leak)"
else
    pass "there is no --host flag"
fi
# Code, not comments: a loopback listener needs no rule anywhere.
if grep -vE '^[[:space:]]*#' "$SEARCH" | grep -qE '(^|[^[:alnum:]_])(ufw|iptables|nft)[[:space:]]'; then
    fail "search.sh touches the firewall (it binds loopback — it should not need to)"
else
    pass "search.sh opens no firewall port"
fi

echo "-- upgrade path"
grep -q -- '--upgrade-db' "$SEARCH" \
    && pass "upgrade knows --upgrade-db" || fail "upgrade does not know --upgrade-db"
grep -q -- '--experimental-dumpless-upgrade' "$SEARCH" \
    && pass "upgrade knows the older experimental flag" || fail "no fallback for older builds"
if sed -n '/^_search_upgrade_env_var()/,/^}/p' "$SEARCH" | grep -q -- '--help'; then
    pass "the flag is read from the binary, not guessed from a version"
else
    fail "the upgrade flag is guessed"
fi
grep -q 'cipi-bak' "$SEARCH" \
    && pass "the old binary is kept for rollback" || fail "no binary backup"
if sed -n '/^_search_upgrade()/,/^}/p' "$SEARCH" | grep -q 'Rolling back'; then
    pass "a refused store rolls the binary back"
else
    fail "no rollback when the store is refused"
fi
if sed -n '/^_search_upgrade()/,/^}/p' "$SEARCH" | grep -q '_search_clear_upgrade_dropin'; then
    pass "the one-shot upgrade drop-in is removed again"
else
    fail "the upgrade drop-in is left behind"
fi
if sed -n '/^_search_upgrade()/,/^}/p' "$SEARCH" | grep -q '_search_create_key'; then
    pass "a wiped store reissues every app key"
else
    fail "a data reset would leave every app with a dead key"
fi

echo "-- master key rotation rewrites every app"
if sed -n '/^_search_master_rotate()/,/^}/p' "$SEARCH" | grep -q 'MEILISEARCH_KEY'; then
    pass "master rotation rewrites MEILISEARCH_KEY in each .env"
else
    fail "master rotation does not rewrite the app .env files"
fi
if sed -n '/^_search_master_rotate()/,/^}/p' "$SEARCH" | grep -q 'keys/'; then
    pass "master rotation re-reads each key by uid"
else
    fail "master rotation does not re-read the regenerated keys"
fi

echo "-- app lifecycle hooks"
grep -q 'search_cleanup_app' "$SEARCH" \
    && pass "search_cleanup_app exists" || fail "no search_cleanup_app"
grep -q 'search_cleanup_app' "${LIB}/app.sh" \
    && pass "app delete revokes the app key" || fail "app delete leaves a live key behind"
grep -q 'MEILISEARCH_\*|SCOUT_PREFIX) continue' "${LIB}/app.sh" \
    && pass "app clone does not inherit the source key" || fail "a clone would reindex into production"
if sed -n '/^app_clone()/,/^}/p' "${LIB}/app.sh" | grep -q '_search_enable'; then
    pass "a clone of a search app gets its own key"
else
    fail "a clone keeps SCOUT_DRIVER=meilisearch with no key"
fi
grep -q 'backup_profiles, search' "${LIB}/common.sh" \
    && pass "apps-public.json exposes the search flag" || fail "search is not projected to apps-public.json"

echo "-- backups deliberately exclude the index"
if grep -qi 'meilisearch\|data\.ms' "${LIB}/backup.sh"; then
    fail "backup.sh references Meilisearch (indexes are derived data)"
else
    pass "backup.sh ignores Meilisearch (scout:import rebuilds)"
fi

echo "-- panel sudoers"
grep -q 'cipi search status' "${LIB}/cipi-api-sudoers.sh" \
    && pass "panel may read search status" || fail "sudoers omits search status"
grep -q 'cipi search enable' "${LIB}/cipi-api-sudoers.sh" \
    && pass "panel may enable search for an app" || fail "sudoers omits search enable"
for forbidden in "search install" "search remove" "search upgrade" "search key"; do
    if grep -q "cipi ${forbidden}" "${LIB}/cipi-api-sudoers.sh"; then
        fail "sudoers grants '${forbidden}' to www-data"
    else
        pass "sudoers withholds '${forbidden}'"
    fi
done

echo "-- opt-in: nothing installs itself"
if grep -qi 'meilisearch\|search install' "${ROOT}/setup.sh"; then
    fail "setup.sh installs Meilisearch"
else
    pass "setup.sh does not install Meilisearch"
fi
if grep -qiE 'meilisearch|_search_install' "${LIB}/self-update.sh"; then
    fail "self-update installs or starts Meilisearch"
else
    pass "self-update does not install Meilisearch"
fi
grep -q 'SEARCH_MIN_RAM_KB' "$SEARCH" \
    && pass "install has a RAM guard" || fail "no RAM guard"

echo "-- README"
grep -q 'cipi search install' "${ROOT}/README.md" \
    && pass "README documents cipi search install" || fail "README omits cipi search install"
grep -q 'Meilisearch' "${ROOT}/README.md" \
    && pass "README mentions Meilisearch" || fail "README omits Meilisearch"

echo ""
echo "=== ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]

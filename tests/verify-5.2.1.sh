#!/bin/bash
# Local regression checks for 5.2.1 — git refresh, app fix-permissions, self-update notify.
# Run from repo root: bash tests/verify-5.2.1.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/lib"
PASS=0
FAIL=0

pass() { echo "  OK: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

echo "=== Cipi 5.2.1 regression checks ==="

[[ "$(tr -d '[:space:]' < "${ROOT}/version.md")" == "5.2.1" ]] \
    && pass "version.md is 5.2.1" || fail "version.md is not 5.2.1"
grep -q '^## \[5.2.1\]' "${ROOT}/CHANGELOG.md" \
    && pass "CHANGELOG has a 5.2.1 entry" || fail "CHANGELOG has no 5.2.1 entry"
[[ ! -f "${LIB}/migrations/5.2.1.sh" ]] \
    && pass "no 5.2.1 migration (code-only)" || fail "stray 5.2.1 migration"
[[ ! -f "${LIB}/migrations/5.2.2.sh" ]] \
    && pass "no stray 5.2.2 migration" || fail "stray 5.2.2 migration"

echo "-- syntax"
for f in "${LIB}/git.sh" "${LIB}/completion.sh" "${LIB}/common.sh" "${LIB}/app.sh" "${LIB}/self-update.sh" "${ROOT}/cipi"; do
    if bash -n "$f" 2>/dev/null; then
        pass "syntax $(basename "$f")"
    else
        fail "syntax $(basename "$f")"
        bash -n "$f" || true
    fi
done

echo "-- dispatch and help"
grep -q 'refresh)' "${LIB}/git.sh" \
    && pass "git_command dispatches refresh" || fail "git_command has no refresh"
grep -q '_git_refresh' "${LIB}/git.sh" \
    && pass "_git_refresh exists" || fail "no _git_refresh"
grep -q 'git_refresh_app' "${LIB}/git.sh" \
    && pass "git_refresh_app exists" || fail "no git_refresh_app"
grep -q '_git_rotate_local_key' "${LIB}/git.sh" \
    && pass "_git_rotate_local_key exists" || fail "no local key rotation"
grep -q 'cipi git refresh' "${ROOT}/cipi" \
    && pass "help lists cipi git refresh" || fail "help omits git refresh"
grep -q -- '--rotate-keys' "${ROOT}/cipi" \
    && pass "help mentions --rotate-keys" || fail "help omits --rotate-keys"
grep -q -- '--rotate-secret' "${LIB}/git.sh" \
    && pass "refresh accepts --rotate-secret" || fail "no --rotate-secret"

echo "-- completion"
grep -q 'refresh' "${LIB}/completion.sh" \
    && pass "completion lists refresh" || fail "completion omits refresh"
if grep -A20 'git)' "${LIB}/completion.sh" | grep -q '_cipi_apps'; then
    pass "cipi git refresh completes app names"
else
    fail "cipi git refresh does not complete app names"
fi

echo "-- helpers"
eval "$(grep -E '^_git_http_code\(\)|^_git_http_body\(\)|^_git_key_blob\(\)' "${LIB}/git.sh")"
sample=$'[{"id":1}]\n201'
[[ "$(_git_http_code "$sample")" == "201" ]] \
    && pass "_git_http_code reads the trailer" || fail "_git_http_code is wrong"
[[ "$(_git_http_body "$sample")" == '[{"id":1}]' ]] \
    && pass "_git_http_body drops the trailer" || fail "_git_http_body is wrong"
[[ "$(_git_key_blob 'ssh-ed25519 AAAAC3Nza comment here')" == "ssh-ed25519 AAAAC3Nza" ]] \
    && pass "_git_key_blob strips the comment" || fail "_git_key_blob does not strip the comment"

echo "-- idempotent re-add"
grep -q '422' "${LIB}/git.sh" \
    && pass "GitHub add recovers a 422 (key already on the repo)" || fail "no GitHub 422 recovery"
if awk '/^_gitlab_add_deploy_key\(\)/,/^_gitlab_remove_deploy_key\(\)/' "${LIB}/git.sh" | grep -q '400'; then
    pass "GitLab add recovers a duplicate key"
else
    fail "GitLab add does not recover a duplicate key"
fi
grep -q '_github_find_webhook_ids' "${LIB}/git.sh" \
    && pass "refresh finds webhooks by URL (not only stored id)" || fail "no webhook lookup by URL"
grep -q '_github_remove_deploy_keys_by_title' "${LIB}/git.sh" \
    && pass "stale cipi:<app> deploy keys are removed" || fail "no title-based key cleanup"
grep -q 'already used on another repo' "${LIB}/git.sh" \
    && pass "a pubkey used on another GitHub repo triggers a new key" || fail "no cross-repo key collision handling"

echo "-- authorized_keys is updated on rotate"
if awk '/^_git_rotate_local_key\(\)/,/^git_refresh_app\(\)/' "${LIB}/git.sh" | grep -q 'authorized_keys'; then
    pass "key rotation rewrites authorized_keys"
else
    fail "key rotation does not touch authorized_keys (Deployer localhost SSH would break)"
fi
if awk '/^_git_rotate_local_key\(\)/,/^git_refresh_app\(\)/' "${LIB}/git.sh" | grep -q 'ssh-keygen'; then
    pass "key rotation calls ssh-keygen"
else
    fail "key rotation does not generate a key"
fi

echo "-- custom apps skip webhook"
if awk '/^git_refresh_app\(\)/,/^_git_refresh\(\)/' "${LIB}/git.sh" | grep -q 'skip_webhook'; then
    pass "custom apps can skip the webhook"
else
    fail "refresh always creates a webhook"
fi

echo "-- app fix-permissions"
grep -q 'ensure_app_permissions()' "${LIB}/common.sh" \
    && pass "ensure_app_permissions exists" || fail "no ensure_app_permissions"
grep -q 'app_fix_permissions' "${LIB}/app.sh" \
    && pass "app_fix_permissions exists" || fail "no app_fix_permissions"
grep -q 'fix-permissions|fixperms' "${LIB}/app.sh" \
    && pass "app_command dispatches fix-permissions" || fail "no fix-permissions dispatch"
grep -q 'cipi app fix-permissions' "${ROOT}/cipi" \
    && pass "help lists cipi app fix-permissions" || fail "help omits app fix-permissions"
grep -q 'fix-permissions' "${LIB}/completion.sh" \
    && pass "completion lists fix-permissions" || fail "completion omits fix-permissions"
if awk '/^ensure_app_permissions\(\)/,/^_create_supervisor_worker\(\)/' "${LIB}/common.sh" | grep -q 'chmod 750'; then
    pass "home is restored to 750 (www-data in the app group)"
else
    fail "home is not chmod 750"
fi
if awk '/^ensure_app_permissions\(\)/,/^_create_supervisor_worker\(\)/' "${LIB}/common.sh" | grep -q 'chmod 700'; then
    pass ".ssh is restored to 700"
else
    fail ".ssh is not chmod 700"
fi
if awk '/^ensure_app_permissions\(\)/,/^_create_supervisor_worker\(\)/' "${LIB}/common.sh" | grep -q 'logs'; then
    pass "logs/ is handled separately from the app:app tree"
else
    fail "logs/ is not special-cased"
fi
if awk '/^ensure_app_permissions\(\)/,/^_create_supervisor_worker\(\)/' "${LIB}/common.sh" | grep -q 'chown -h'; then
    pass "chown does not follow the current symlink"
else
    fail "chown would follow current → a release twice"
fi
if awk '/^ensure_app_permissions\(\)/,/^_create_supervisor_worker\(\)/' "${LIB}/common.sh" | grep -q 'ensure_app_logs_permissions'; then
    pass "log ACLs are reapplied"
else
    fail "log ACL helper is not called"
fi
grep -q 'cipi app fix-permissions' "${LIB}/cipi-api-sudoers.sh" \
    && pass "panel sudoers allows app fix-permissions" || fail "sudoers omits app fix-permissions"

echo "-- self-update notify"
if awk '/local nv;/,/info "Updating/' "${LIB}/self-update.sh" | grep -q 'version_changed'; then
    pass "version_changed is decided before files are copied"
else
    fail "version_changed is not decided up front"
fi
notify_guard=$(awk '
    /^[[:space:]]*if / { last_if=$0 }
    /cipi_notify/ { print last_if }
' "${LIB}/self-update.sh")
if [[ "$notify_guard" == *version_changed* ]]; then
    pass "cipi_notify is behind version_changed"
else
    fail "cipi_notify is not behind version_changed (${notify_guard})"
fi
grep -q 'old_ver' "${LIB}/self-update.sh" \
    && pass "notify body uses the snapshot, not the rewritten version file" \
    || fail "notify body does not use old_ver"

echo "-- README"
grep -q 'cipi git refresh' "${ROOT}/README.md" \
    && pass "README mentions cipi git refresh" || fail "README omits git refresh"
grep -q 'cipi app fix-permissions' "${ROOT}/README.md" \
    && pass "README mentions cipi app fix-permissions" || fail "README omits app fix-permissions"

echo ""
echo "=== ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]

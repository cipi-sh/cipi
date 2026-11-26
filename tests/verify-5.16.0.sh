#!/bin/bash
# 5.16.0: Cloudflare Tunnel as the way a server is reached.
#  - Access on paths and for people (--path, --allow, --allow=none), the API
#    on the tunnel (--api), service tokens with their Service Auth policy;
#  - TCP services behind Access, SSH with short-lived certificates;
#  - lockdown, previews of a branch, replicas (export/join/leave), purge of
#    Cloudflare's cache (now and after a deploy);
#  - the `tunnel` monitor check and `cipi zt status --json`.
# curl answers as the Cloudflare API does (a stub that logs every call);
# systemctl, sshd and the cipi binary are stubs; the vault is real.
# Run from repo root: bash tests/verify-5.16.0.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/lib"
PASS=0; FAIL=0
pass() { echo "  OK: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
TMP=$(mktemp -d) && [[ -n "$TMP" && -d "$TMP" ]] || exit 1
trap 'rm -rf "${TMP:?}"' EXIT
echo "=== Cipi 5.16.0 regression checks ==="

v=$(tr -d "[:space:]" < "${ROOT}/version.md"); [[ "$(printf "%s\n%s\n" 5.16.0 "$v" | sort -V | head -1)" == 5.16.0 ]] && pass "version.md >= 5.16.0" || fail "version.md"
grep -q '^## \[5.16.0\]' "${ROOT}/CHANGELOG.md" && pass "CHANGELOG 5.16.0" || fail "CHANGELOG"
for f in "${ROOT}/cipi" "${LIB}/zt.sh" "${LIB}/monitor.sh" "${LIB}/notifications.sh" "${LIB}/deploy.sh" \
         "${LIB}/cipi-app-notify.sh" "${LIB}/completion.sh"; do
    bash -n "$f" && pass "$(basename "$f") parses" || fail "$(basename "$f") parse"
done
command -v jq >/dev/null 2>&1 || { echo "  (jq not installed)"; exit 1; }

BIN="${TMP}/bin"; STATE="${TMP}/state"; CFG="${TMP}/etc/cipi"; CF="${TMP}/cloudflared"; SSHD="${TMP}/ssh"
mkdir -p "$BIN" "$STATE" "$CFG" "${TMP}/log" "$CF" "$SSHD/sshd_config.d"
head -c 32 /dev/urandom | base64 > "${CFG}/.vault_key"
echo 0 > "${STATE}/n"

# The Cloudflare API as far as Cipi uses it. Every call: "METHOD path body".
cat > "${BIN}/curl" <<'EOF'
#!/bin/bash
method=GET url="" body=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -X) method="$2"; shift ;;
        -d) body="$2"; shift ;;
        http*) url="$1" ;;
    esac
    shift
done
case "$url" in
    *checkip*) echo "203.0.113.5"; exit 0 ;;
esac
path="${url#https://api.cloudflare.com/client/v4}"
[[ -n "$body" ]] && body=$(printf '%s' "$body" | jq -c . 2>/dev/null || printf '%s' "$body")
printf '%s %s %s\n' "$method" "$path" "$body" >> "$STATE/cf.log"
n=$(( $(cat "$STATE/n") + 1 )); echo "$n" > "$STATE/n"
ok() { printf '{"success":true,"errors":[],"result":%s}' "$1"; }
case "$method $path" in
    "GET /zones?name=example.com") ok '[{"id":"zone1"}]' ;;
    "GET /zones?name="*)           ok '[]' ;;
    "GET /zones/zone1/dns_records"*) ok '[]' ;;
    "POST /zones/zone1/dns_records") ok "{\"id\":\"rec${n}\"}" ;;
    "POST /zones/zone1/purge_cache")
        [[ -f "$STATE/purge.fail" ]] && { echo '{"success":false,"errors":[{"message":"Authentication error"}]}'; exit 0; }
        ok '{"id":"zone1"}' ;;
    "POST /accounts/acc1/access/apps") ok "{\"id\":\"app${n}\"}" ;;
    "POST /accounts/acc1/access/apps/"*"/policies") ok "{\"id\":\"pol${n}\"}" ;;
    "GET /accounts/acc1/access/apps/"*"/ca")
        [[ -f "$STATE/ca.exists" ]] && { ok '{"id":"ca1","public_key":"ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTY= open-ssh-ca@cloudflareaccess.org"}'; exit 0; }
        echo '{"success":false,"errors":[{"code":12130,"message":"access.api.error.not_found"}]}' ;;
    "POST /accounts/acc1/access/apps/"*"/ca") touch "$STATE/ca.exists"; ok '{"id":"ca1","public_key":"ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTY= open-ssh-ca@cloudflareaccess.org"}' ;;
    "POST /accounts/acc1/access/service_tokens") ok "{\"id\":\"tok${n}\",\"client_id\":\"cid${n}.access\",\"client_secret\":\"secret${n}\"}" ;;
    "GET /accounts/acc1/cfd_tunnel/"*)
        if [[ -f "$STATE/tunnel.json" ]]; then ok "$(cat "$STATE/tunnel.json")"; else echo '{"success":false,"errors":[{"message":"down"}]}'; fi ;;
    "DELETE "*) ok '{}' ;;
    *) echo '{"success":false,"errors":[{"message":"stub: unknown call"}]}' ;;
esac
EOF
cat > "${BIN}/systemctl" <<'EOF'
#!/bin/bash
echo "systemctl $*" >> "$STATE/systemctl.log"
case "$*" in
    *is-active*cloudflared*) [[ ! -f "$STATE/cloudflared.down" ]] ;;
    *) exit 0 ;;
esac
EOF
cat > "${BIN}/sshd" <<'EOF'
#!/bin/bash
[[ "$1" == "-t" && -f "$STATE/sshd.fail" ]] && exit 1
exit 0
EOF
# The cipi binary, for the commands previews run: logged, and app create
# writes the app (the real one would do much more).
cat > "${BIN}/cipi" <<'EOF'
#!/bin/bash
echo "cipi $*" >> "$STATE/cipi.log"
[[ -f "$STATE/cipi.fail" && "$*" == *"$(cat "$STATE/cipi.fail")"* ]] && exit 1
exit 0
EOF
cat > "${BIN}/id" <<'EOF'
#!/bin/bash
[[ "$1" == "cipi" ]] && exit 0
exec /usr/bin/id "$@"
EOF
chmod +x "${BIN}"/*

ENVV=(PATH="${BIN}:${PATH}" STATE="$STATE" CIPI_LIB="$LIB" CIPI_CONFIG="$CFG" CIPI_LOG="${TMP}/log"
      ZT_TOKEN_FILE="${CFG}/zt.token" ZT_CF_DIR="$CF" ZT_CF_CONF="${CF}/config.yml" ZT_IPS_DIR="${TMP}/ips"
      ZT_REALIP="${TMP}/realip.conf" ZT_F2B="${TMP}/f2b.conf" ZT_CRON="${TMP}/zt.cron" ZT_CS_WL="${TMP}/cs.yaml"
      ZT_SSH_CA="${SSHD}/cipi-cloudflare-ca.pub" ZT_SSH_PRINCIPALS="${SSHD}/cipi-principals"
      ZT_SSHD_DROPIN="${SSHD}/sshd_config.d/10-cipi-cloudflare-ca.conf" CIPI_BIN="${BIN}/cipi"
      MONITOR_STATE_DIR="${TMP}/mon")
Z() {
    env "${ENVV[@]}" bash -c 'set -euo pipefail
        RED=""; GREEN=""; YELLOW=""; CYAN=""; DIM=""; NC=""; BOLD=""
        source "$CIPI_LIB/common.sh"
        log_action() { :; }; log_event() { :; }; cipi_notify() { echo "notify $3" >> "$STATE/notify.log"; }
        reload_nginx() { :; }
        source "$CIPI_LIB/zt.sh"
        '"$1" < /dev/null
}
cf() { cat "${STATE}/cf.log" 2>/dev/null; }
cfreset() { : > "${STATE}/cf.log"; }
st() { Z '_zt_state'; }

# A server with Zero Trust on, two apps (one with a deploy webhook), the panel and the API.
printf 'tok\n' > "${CFG}/zt.token"
Z 'jq -n "{shop: {domain: \"shop.example.com\", php: \"8.4\", repository: \"git@github.com:acme/shop.git\", webhook_token: \"w1\", aliases: [\"www.shop.example.com\"]},
           blog: {domain: \"blog.example.com\", php: \"8.4\", repository: \"git@github.com:acme/blog.git\"}}" | vault_write apps.json
   echo "{\"domain\":\"panel.example.com\"}" | vault_write gui.json
   echo "{\"domain\":\"api.example.com\"}" | vault_write api.json
   jq -n "{enabled: true, account_id: \"acc1\", tunnel_id: \"0d3f0d3f-1111-2222-3333-444455556666\", tunnel_name: \"cipi-test\", hostnames: {}}" | vault_write zt.json' >/dev/null
echo '{"AccountTag":"acc1","TunnelSecret":"c2VjcmV0","TunnelID":"0d3f0d3f-1111-2222-3333-444455556666"}' > "${CF}/0d3f0d3f-1111-2222-3333-444455556666.json"

# ── hostnames: an app, the API ───────────────────────────────
out=$(Z '_zt_hostname_add shop' 2>&1); rc=$?
[[ $rc -eq 0 && "$(st | jq -r '.hostnames.shop.domains | length')" == 2 ]] && pass "hostname add shop: its domain and its alias" || fail "hostname add: ${out}"
out=$(Z '_zt_hostname_add --api' 2>&1); rc=$?
[[ $rc -eq 0 && "$(st | jq -r .api.domain)" == "api.example.com" ]] && grep -q 'hostname: "api.example.com"' "${CF}/config.yml" \
    && pass "hostname add --api: the API's domain, in the ingress" || fail "--api: ${out}"
tail -1 "${CF}/config.yml" | grep -q 'service: http_status:404' && pass "the catch-all 404 stays last" || fail "ingress order"

# ── Access on paths, for people ──────────────────────────────
cfreset
out=$(Z '_zt_access_enable shop --path=/admin,/horizon/ --allow=me@Example.com,@acme.io' 2>&1); rc=$?
apps=$(cf | grep '^POST /accounts/acc1/access/apps ' | head -1 | cut -d' ' -f3-)
[[ $rc -eq 0 ]] && jq -e '.destinations == [{"type":"public","uri":"shop.example.com/admin"},{"type":"public","uri":"shop.example.com/horizon"}] and .domain == "shop.example.com/admin"' <<< "$apps" >/dev/null \
    && pass "--path: one destination per path (trailing / dropped), the first as domain" || fail "paths: ${out} ${apps}"
pol=$(cf | grep '/policies ' | head -1 | cut -d' ' -f3-)
jq -e '.decision == "allow" and .include == [{"email":{"email":"me@example.com"}},{"email_domain":{"domain":"acme.io"}}]' <<< "$pol" >/dev/null \
    && pass "--allow: an email and an @domain, lower-cased" || fail "allow: ${pol}"
! cf | grep -q 'cipi:shop:webhook' && pass "no /cipi/webhook bypass when Access covers other paths only" || fail "bypass created needlessly"
[[ "$(st | jq -r '.hostnames.shop | "\(.access_paths)|\(.access_allow)"')" == "/admin,/horizon|me@example.com,@acme.io" ]] && pass "paths and allow kept in the state" || fail "state: $(st | jq -c .hostnames.shop)"
grep -q "The rest of the site is public" <<< "$out" && pass "…and the output says the rest is public" || fail "msg: ${out}"

cfreset
out=$(Z '_zt_access_enable shop --path=' 2>&1); rc=$?
[[ $rc -eq 0 ]] && cf | grep -q '^DELETE /accounts/acc1/access/apps/' && cf | grep -q 'cipi:shop:webhook' \
    && pass "access enable again: the old application replaced; the whole site now, so the webhook bypass" || fail "re-enable: ${out} $(cf)"
[[ "$(st | jq -r '.hostnames.shop.access_allow')" == "me@example.com,@acme.io" ]] && pass "…keeping --allow when not given" || fail "allow lost"
out=$(Z '_zt_access_enable shop --allow=bob' 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"Not an email or an @domain: bob"* ]] && pass "--allow refuses what is neither an email nor a domain" || fail "bad allow: ${out}"
out=$(Z '_zt_access_enable shop --path=admin' 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"Not a path"* ]] && pass "--path refuses a path not from /" || fail "bad path: ${out}"
out=$(Z '_zt_access_enable blog' 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"not on the tunnel"* ]] && pass "Access needs the app on the tunnel" || fail "blog: ${out}"

cfreset
out=$(Z '_zt_access_enable --api --allow=none' 2>&1); rc=$?
[[ $rc -eq 0 ]] && ! cf | grep -q '/policies ' && [[ "$(st | jq -r .api.access_allow)" == "none" ]] \
    && pass "--allow=none: an application with no allow policy (service tokens only)" || fail "none: ${out} $(cf)"

# ── service tokens ───────────────────────────────────────────
cfreset
out=$(Z '_zt_service_token_create panel --for=api --json' 2>&1); rc=$?
[[ $rc -eq 0 ]] && jq -e '.client_id | endswith(".access")' <<< "$out" >/dev/null && jq -e '.client_secret | startswith("secret")' <<< "$out" >/dev/null \
    && pass "service-token create --json: client id and secret, once" || fail "token: ${out}"
pol=$(cf | grep '/policies ' | cut -d' ' -f3-)
tid=$(st | jq -r '.service_tokens.panel.id')
jq -e --arg t "$tid" '.decision == "non_identity" and .include == [{"service_token":{"token_id":$t}}]' <<< "$pol" >/dev/null \
    && pass "…and a Service Auth policy for it on the API's application" || fail "policy: ${pol}"
! st | grep -q 'secret' && pass "the secret is never kept in the state" || fail "secret in state"
out=$(Z '_zt_service_token_create panel --for=api' 2>&1); [[ $? -ne 0 && "$out" == *"exists"* ]] && pass "a second token with the same name is refused" || fail "dup: ${out}"
out=$(Z '_zt_service_token_create ci --for=blog' 2>&1); [[ $? -ne 0 && "$out" == *"No Access application"* ]] && pass "a token for a target without Access is refused, with the command" || fail "no access: ${out}"
cfreset
Z '_zt_access_enable --api' >/dev/null 2>&1
cf | grep -q "cipi-service-panel" && [[ -n "$(st | jq -r '.service_tokens.panel.policy_id')" ]] \
    && pass "re-creating the API's application re-attaches its tokens" || fail "reattach: $(cf)"
[[ "$(st | jq -r .api.access_allow)" == "none" ]] && pass "…and keeps --allow=none" || fail "allow none lost"
cfreset
out=$(Z '_zt_service_token_revoke panel' 2>&1); rc=$?
[[ $rc -eq 0 ]] && cf | grep -q '^DELETE /accounts/acc1/access/service_tokens/' && cf | grep -q '/policies/' && [[ "$(st | jq -r '.service_tokens.panel // "gone"')" == "gone" ]] \
    && pass "service-token revoke: policy and token deleted, gone from the state" || fail "revoke: ${out} $(cf)"

# ── TCP ──────────────────────────────────────────────────────
cfreset
out=$(Z '_zt_tcp_add mysql --hostname=db.example.com --allow=me@example.com' 2>&1); rc=$?
[[ $rc -eq 0 ]] && grep -q 'service: tcp://127.0.0.1:3306' "${CF}/config.yml" && [[ "$(st | jq -r '.tcp["db.example.com"].port')" == 3306 ]] \
    && pass "tcp add mysql: 127.0.0.1:3306 on its hostname" || fail "tcp: ${out}"
grep -q 'cloudflared access tcp --hostname db.example.com --url 127.0.0.1:13306' <<< "$out" && pass "…and the command for the laptop" || fail "tcp hint: ${out}"
grep -n 'db.example.com' "${CF}/config.yml" | head -1 | cut -d: -f1 | { read -r l; [[ $l -lt $(grep -n 'http_status:404' "${CF}/config.yml" | cut -d: -f1) ]]; } && pass "…before the catch-all" || fail "tcp order"
echo 'GET /zones?name=example.com' > /dev/null
: > "${STATE}/cf.log"; mv "${BIN}/curl" "${BIN}/curl.ok"
cat > "${BIN}/curl" <<EOF
#!/bin/bash
case "\$*" in *access/apps*) echo '{"success":false,"errors":[{"message":"forbidden"}]}'; exit 0 ;; esac
exec "${BIN}/curl.ok" "\$@"
EOF
chmod +x "${BIN}/curl"
out=$(Z '_zt_tcp_add redis --hostname=cache.example.com' 2>&1); rc=$?
[[ $rc -ne 0 && "$(st | jq -r '.tcp["cache.example.com"] // "none"')" == none ]] && cf | grep -q '^DELETE /zones/zone1/dns_records/' \
    && pass "no Access → nothing published, the DNS record taken back" || fail "tcp no access: ${out}"
mv "${BIN}/curl.ok" "${BIN}/curl"
for bad in "ssh --hostname=x.example.com" "22 --hostname=x.example.com" "443 --hostname=x.example.com" "mongo --hostname=x.example.com"; do
    out=$(Z "_zt_tcp_add ${bad}" 2>&1); [[ $? -ne 0 ]] || { fail "tcp ${bad} accepted"; continue; }
done && pass "tcp refuses ssh, 22, 443 and unknown services"
out=$(Z '_zt_tcp_remove db.example.com' 2>&1); [[ $? -eq 0 ]] && ! grep -q 'db.example.com' "${CF}/config.yml" && pass "tcp remove: out of the ingress" || fail "tcp remove: ${out}"

# ── SSH certificates ─────────────────────────────────────────
out=$(Z '_zt_ssh_cert_enable --principals=andrea' 2>&1); [[ $? -ne 0 && "$out" == *"not on the tunnel"* ]] && pass "ssh cert needs SSH on the tunnel behind Access" || fail "cert pre: ${out}"
cfreset
out=$(Z '_zt_ssh_enable --hostname=ssh.example.com --allow=@acme.io' 2>&1); rc=$?
[[ $rc -eq 0 && -n "$(st | jq -r .ssh.access_id)" ]] && cf | grep '/policies ' | grep -q 'acme.io' && pass "ssh enable --allow: the SSH application allows @acme.io" || fail "ssh enable: ${out}"
cfreset
out=$(Z '_zt_ssh_cert_enable --principals=Andrea@Acme.io,mario,andrea' 2>&1); rc=$?
[[ $rc -eq 0 ]] && cf | grep -q '^GET .*/ca' && cf | grep -q '^POST .*/ca' && pass "ssh cert enable: the CA asked, created when missing" || fail "cert: ${out} $(cf)"
[[ "$(cat "${SSHD}/cipi-principals/cipi")" == $'andrea\nmario' ]] && pass "principals: email prefixes, lower case, once each" || fail "principals: $(cat "${SSHD}/cipi-principals/cipi")"
grep -q "^TrustedUserCAKeys ${SSHD}/cipi-cloudflare-ca.pub$" "${SSHD}/sshd_config.d/10-cipi-cloudflare-ca.conf" && grep -q 'AuthorizedPrincipalsFile .*/%u$' "${SSHD}/sshd_config.d/10-cipi-cloudflare-ca.conf" \
    && grep -q '^ecdsa-sha2-nistp256 ' "${SSHD}/cipi-cloudflare-ca.pub" && pass "sshd drop-in: the CA and a principals file per user" || fail "dropin"
grep -q 'cloudflared access ssh-config --hostname ssh.example.com --short-lived-cert' <<< "$out" && pass "…and the laptop's one-time command" || fail "cert hint"
touch "${STATE}/sshd.fail"; rm -f "${SSHD}/sshd_config.d/10-cipi-cloudflare-ca.conf"
out=$(Z '_zt_ssh_cert_enable --principals=andrea' 2>&1); rc=$?
[[ $rc -ne 0 && ! -f "${SSHD}/sshd_config.d/10-cipi-cloudflare-ca.conf" ]] && pass "sshd -t refuses → the drop-in is taken back" || fail "sshd fail: ${out}"
rm -f "${STATE}/sshd.fail"
Z '_zt_ssh_cert_enable --principals=andrea' >/dev/null 2>&1
out=$(Z '_zt_ssh_cert_disable' 2>&1); [[ $? -eq 0 && ! -e "${SSHD}/sshd_config.d/10-cipi-cloudflare-ca.conf" && ! -e "${SSHD}/cipi-principals" ]] && pass "ssh cert disable: drop-in, CA and principals removed" || fail "cert disable: ${out}"

# ── purge ────────────────────────────────────────────────────
cfreset
out=$(Z '_zt_purge shop' 2>&1); rc=$?
body=$(cf | grep '^POST /zones/zone1/purge_cache' | cut -d' ' -f3-)
[[ $rc -eq 0 ]] && jq -e '.hosts == ["shop.example.com","www.shop.example.com"]' <<< "$body" >/dev/null && pass "purge: the app's hostnames, one call per zone" || fail "purge: ${out} ${body}"
cfreset; Z '_zt_purge shop --everything' >/dev/null 2>&1
cf | grep -q 'purge_everything' && pass "purge --everything: the whole zone" || fail "everything"
Z '_zt_purge shop --on-deploy=on' >/dev/null 2>&1
[[ "$(Z 'app_get shop cf_purge')" == "true" ]] && pass "purge --on-deploy=on: set on the app" || fail "on-deploy"
cfreset; out=$(Z 'zt_purge_after_deploy shop' 2>&1)
[[ "$out" == "Cloudflare purge: done" ]] && cf | grep -q purge_cache && pass "after a deploy: purged, one line for the log" || fail "after deploy: ${out}"
touch "${STATE}/purge.fail"; out=$(Z 'zt_purge_after_deploy shop; echo rc=$?' 2>&1)
[[ "$out" == *"Cloudflare purge: failed"*"rc=0"* ]] && pass "…a failed purge never fails the deploy" || fail "purge fail: ${out}"
rm -f "${STATE}/purge.fail"
out=$(Z 'zt_purge_after_deploy blog' 2>&1); [[ -z "$out" ]] && pass "…an app without --on-deploy: nothing" || fail "blog purge: ${out}"
grep -q 'zt_purge_after_deploy "\$app"' "${LIB}/deploy.sh" && grep -q 'zt_purge_after_deploy "\$APP"' "${LIB}/cipi-app-notify.sh" \
    && pass "cipi deploy and the webhook deploy both purge" || fail "hooks"
! grep -q 'PURGE_LINE.*>> "\$LOG_FILE"' "${LIB}/cipi-app-notify.sh" && pass "the root helper never writes into the app's log" || fail "root writes app log"

# ── previews ─────────────────────────────────────────────────
: > "${STATE}/cipi.log"
out=$(Z '_zt_preview_create shop --branch=Feature/Login_Page --allow=@acme.io' 2>&1); rc=$?
[[ $rc -eq 0 ]] && grep -q -- 'app create --user=shopfeatureloginpage --domain=feature-login-page-shop.example.com --repository=git@github.com:acme/shop.git --branch=Feature/Login_Page --env=preview --php=8.4' "${STATE}/cipi.log" \
    && pass "preview create: an app of its own, one level below the zone" || fail "preview: ${out} $(cat "${STATE}/cipi.log")"
grep -q 'zt hostname add shopfeatureloginpage' "${STATE}/cipi.log" && grep -q 'zt access enable shopfeatureloginpage --allow=@acme.io' "${STATE}/cipi.log" && grep -q 'deploy shopfeatureloginpage' "${STATE}/cipi.log" \
    && pass "…on the tunnel, behind Access, deployed once" || fail "preview steps: $(cat "${STATE}/cipi.log")"
[[ "$(st | jq -r '.previews.shopfeatureloginpage.parent')" == "shop" ]] && pass "…recorded with its parent and branch" || fail "preview state"
out=$(Z '_zt_preview_create shop --branch=Feature/Login_Page' 2>&1); [[ $? -ne 0 && "$out" == *"already has a preview"* ]] && pass "one preview per branch" || fail "dup preview: ${out}"
[[ "$(Z '_zt_preview_host example.com feat')" == "feat.example.com" && "$(Z '_zt_preview_host a.b.example.com feat')" == "feat-a.b.example.com" ]] && pass "preview host: an apex, a deep name" || fail "preview host"
: > "${STATE}/cipi.log"; echo "app create" > "${STATE}/cipi.fail"
out=$(Z '_zt_preview_create shop --branch=other' 2>&1); rc=$?
[[ $rc -ne 0 && "$(st | jq -r '.previews | length')" == 1 ]] && pass "a failed app create leaves no preview behind" || fail "preview fail: ${out}"
rm -f "${STATE}/cipi.fail"
Z 'v=$(vault_read apps.json | jq ".shopfeatureloginpage = {domain: \"feature-login-page-shop.example.com\"}"); echo "$v" | vault_write apps.json
   st=$(_zt_state | jq ".hostnames.shopfeatureloginpage = {domains: []}"); _zt_state_write "$st"' >/dev/null
: > "${STATE}/cipi.log"
out=$(Z '_zt_preview_remove shop --branch=Feature/Login_Page --yes' 2>&1); rc=$?
[[ $rc -eq 0 ]] && grep -q 'zt hostname remove shopfeatureloginpage' "${STATE}/cipi.log" && grep -q 'app delete shopfeatureloginpage --force' "${STATE}/cipi.log" && [[ "$(st | jq -r '.previews | length')" == 0 ]] \
    && pass "preview remove <app> --branch: hostname, app and record gone" || fail "preview remove: ${out} $(cat "${STATE}/cipi.log")"
# What the real `cipi zt hostname remove` / `cipi app delete` would have done.
Z 'st=$(_zt_state | jq "del(.hostnames.shopfeatureloginpage)"); _zt_state_write "$st"; v=$(vault_read apps.json | jq "del(.shopfeatureloginpage)"); echo "$v" | vault_write apps.json' >/dev/null

# ── replicas ─────────────────────────────────────────────────
bundle=$(Z '_zt_replica_export --json' 2>/dev/null | jq -r .bundle)
[[ "$bundle" == cipi-zt1:* ]] && pass "replica export: a cipi-zt1 bundle" || fail "export: ${bundle:0:80}"
dec=$(printf '%s' "${bundle#cipi-zt1:}" | base64 -d | gunzip -c)
jq -e '.credentials.TunnelSecret == "c2VjcmV0" and (.hostnames | has("shop")) and .api.domain == "api.example.com" and (.service_tokens == null)' <<< "$dec" >/dev/null \
    && pass "…credentials and routes, not the Access ids or tokens" || fail "bundle: ${dec}"
# A second server: its own config dir, the shop app only.
CFG2="${TMP}/etc2/cipi"; CF2="${TMP}/cloudflared2"; mkdir -p "$CFG2" "$CF2"; cp "${CFG}/.vault_key" "${CFG2}/.vault_key"
Z2() { local save=("${ENVV[@]}"); ENVV=("${ENVV[@]/#CIPI_CONFIG=*/CIPI_CONFIG=${CFG2}}"); ENVV=("${ENVV[@]/#ZT_CF_DIR=*/ZT_CF_DIR=${CF2}}"); ENVV=("${ENVV[@]/#ZT_CF_CONF=*/ZT_CF_CONF=${CF2}/config.yml}"); ENVV=("${ENVV[@]/#ZT_TOKEN_FILE=*/ZT_TOKEN_FILE=${CFG2}/zt.token}"); Z "$1"; local rc=$?; ENVV=("${save[@]}"); return $rc; }
Z2 'jq -n "{blog: {domain: \"blog.example.com\"}}" | vault_write apps.json' >/dev/null
out=$(Z2 "_zt_install_cloudflared() { :; }; _zt_fetch_ips() { mkdir -p \"\$ZT_IPS_DIR\"; echo 173.245.48.0/20 > \"\$ZT_IPS_DIR/v4\"; }; _zt_replica_join ${bundle}" 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"not on this server: shop"* && ! -f "${CF2}/config.yml" ]] && pass "replica join refuses while an app of the tunnel is missing here" || fail "join missing: ${out}"
Z2 'jq -n "{shop: {domain: \"shop.example.com\"}, blog: {domain: \"blog.example.com\"}}" | vault_write apps.json' >/dev/null
out=$(Z2 "_zt_install_cloudflared() { :; }; _zt_fetch_ips() { mkdir -p \"\$ZT_IPS_DIR\"; echo 173.245.48.0/20 > \"\$ZT_IPS_DIR/v4\"; }; _zt_replica_join ${bundle}" 2>&1); rc=$?
[[ $rc -eq 0 && -f "${CF2}/0d3f0d3f-1111-2222-3333-444455556666.json" ]] && grep -q 'hostname: "shop.example.com"' "${CF2}/config.yml" \
    && [[ "$(Z2 '_zt_state | jq -r .replica')" == "true" ]] && pass "replica join: credentials, the same ingress, marked a replica" || fail "join: ${out}"
out=$(Z2 '_zt_disable --yes' 2>&1); [[ $? -ne 0 && "$out" == *"replica leave"* ]] && pass "disable on a replica is refused: it would delete the tunnel for everyone" || fail "replica disable: ${out}"
echo '{"status":"healthy","connections":[{"client_id":"c1","origin_ip":"203.0.113.5","colo_name":"MXP"},{"client_id":"c1","origin_ip":"203.0.113.5","colo_name":"FRA"},{"client_id":"c2","origin_ip":"198.51.100.9","colo_name":"MXP"}]}' > "${STATE}/tunnel.json"
[[ "$(Z '_zt_replica_connectors_elsewhere')" == 1 ]] && pass "connectors elsewhere: the one whose address is not this server's" || fail "elsewhere: $(Z '_zt_replica_connectors_elsewhere')"
out=$(Z '_zt_disable --yes' 2>&1); [[ $? -ne 0 && "$out" == *"other server(s) run this tunnel"* ]] && pass "disable refuses while another server runs the tunnel" || fail "disable others: ${out}"
out=$(Z2 '_zt_replica_leave --yes' 2>&1); rc=$?
[[ $rc -eq 0 && ! -d "$CF2" && "$(Z2 '_zt_state | jq -r .enabled')" == "false" ]] && ! grep -q '^DELETE /accounts/acc1/cfd_tunnel' "${STATE}/cf.log" \
    && pass "replica leave: the connector stops here, the tunnel is not deleted" || fail "leave: ${out}"

# ── status --json ────────────────────────────────────────────
j=$(Z '_zt_status --json' 2>/dev/null)
jq -e '.enabled == true and .tunnel.status == "healthy" and (.tunnel.connectors | map(.this_server)) == [true, false]' <<< "$j" >/dev/null \
    && pass "status --json: Cloudflare's status, each connector, which one is this server" || fail "status tunnel: ${j:0:400}"
jq -e '.hostnames[] | select(.app == "shop") | .access.enabled == true and .purge_on_deploy == true and (.domains | length) == 2' <<< "$j" >/dev/null \
    && pass "…an app with its Access and purge setting" || fail "status app: $(jq -c '.hostnames' <<< "$j")"
jq -e '.api.on_tunnel == true and .api.access.allow == ["none"] and .gui.on_tunnel == false and (.missing | index("blog") != null and index("gui") != null)' <<< "$j" >/dev/null \
    && pass "…the API (tokens only), the panel not on the tunnel, what is missing" || fail "status api/gui: $(jq -c '{api,gui,missing}' <<< "$j")"
jq -e '.ssh.hostname == "ssh.example.com" and .ssh.certificates.enabled == false and .lock.http == false' <<< "$j" >/dev/null && pass "…SSH and the locks" || fail "status ssh"

# ── monitor: the tunnel check ────────────────────────────────
M() { env "${ENVV[@]}" bash -c 'set -euo pipefail; RED=""; GREEN=""; YELLOW=""; CYAN=""; DIM=""; NC=""; BOLD=""
      source "$CIPI_LIB/common.sh"; source "$CIPI_LIB/monitor.sh"; '"$1" < /dev/null; }
[[ "$(M '_mon_check_tunnel' | jq -r .status)" == ok ]] && pass "monitor tunnel: healthy → ok" || fail "mon ok: $(M '_mon_check_tunnel')"
echo '{"status":"degraded","connections":[{"client_id":"c1","origin_ip":"203.0.113.5"}]}' > "${STATE}/tunnel.json"
[[ "$(M '_mon_check_tunnel' | jq -r .status)" == warn ]] && pass "…degraded → warn" || fail "mon degraded"
echo '{"status":"down","connections":[]}' > "${STATE}/tunnel.json"
[[ "$(M '_mon_check_tunnel' | jq -r .status)" == crit ]] && pass "…down at Cloudflare → crit" || fail "mon down"
touch "${STATE}/cloudflared.down"
r=$(M '_mon_check_tunnel'); [[ "$(jq -r .status <<< "$r")" == crit && "$(jq -r .summary <<< "$r")" == "cloudflared is not running" ]] && pass "…cloudflared stopped → crit" || fail "mon stopped: ${r}"
rm -f "${STATE}/cloudflared.down" "${STATE}/tunnel.json"
[[ "$(M '_mon_check_tunnel' | jq -r .status)" == ok ]] && pass "…Cloudflare not answering: the local service decides" || fail "mon noapi"
M '_mon_catalog' | grep -qx 'tunnel|Cloudflare Tunnel' && pass "tunnel in the monitor catalog" || fail "catalog"
grep -q '^monitor_tunnel|Monitor|' "${LIB}/notifications.sh" && grep -q 'monitor_http_5xx monitor_tunnel' "${LIB}/notifications.sh" && pass "monitor_tunnel: a trigger, and urgent" || fail "trigger"
CFG3="${TMP}/etc3"; mkdir -p "$CFG3"
r=$(env "${ENVV[@]/#CIPI_CONFIG=*/CIPI_CONFIG=${CFG3}}" bash -c 'set -euo pipefail; source "$CIPI_LIB/common.sh"; source "$CIPI_LIB/monitor.sh"; _mon_check_tunnel' 2>/dev/null)
[[ "$(jq -r .summary <<< "$r")" == "Zero Trust not enabled" ]] && pass "…ok while Zero Trust is off" || fail "mon off: ${r}"

# ── help and completion ──────────────────────────────────────
for c in 'zt service-token create' 'zt tcp add mysql' 'zt ssh cert enable' 'zt lockdown' 'zt preview create' 'zt replica export' 'zt purge <app>' 'zt status --json'; do
    grep -q "cipi ${c}" "${ROOT}/cipi" || { fail "help: ${c}"; continue; }
done && pass "help lists the new zt commands"
grep -q 'service-token tcp ssh lock unlock lockdown preview replica purge' "${LIB}/completion.sh" && pass "completion knows them" || fail "completion"

echo ""
echo "  ${PASS} passed, ${FAIL} failed"
[[ $FAIL -eq 0 ]]

#!/bin/bash
# 5.18.0: the private side of Zero Trust — Tailscale and NetBird.
#  - cipi zt tailscale|netbird enable: the client from its vendor's apt
#    repository, the join key in a file, the mesh interface through UFW,
#    nothing closed; one mesh per server; a client that was there is adopted;
#  - lock ssh: only from a session that came over the mesh, only while the
#    mesh is connected and (Tailscale) the node key cannot expire;
#  - lock http, and the locks next to Cloudflare's: neither side reopens what
#    the other keeps closed; cipi firewall refuses to;
#  - Tailscale SSH on and off; NetBird's own SSH server is never turned on;
#  - disable: what the locks closed comes back first, then the client goes;
#  - the `mesh` monitor check and `mesh` in cipi zt status --json;
#  - from the panel (sudo by www-data): --force ignored, lock ssh on a login
#    sshd accepted over the mesh, lock http and disable never on the panel's
#    own way in, and the sudoers that allow exactly these commands;
#  - UFW rules numbered below ten are removed too ("[ 1]" is not awk's $1).
#  - a custom app with no repository gets a Coming soon page in its docroot;
#  - the build step of a deploy has a time limit of its own, not Deployer's
#    300 seconds: the recipes, the deploy.php written before (hook, migration).
# tailscale, netbird, ufw, ip, systemctl, apt-get, curl and sshd are stubs
# that keep a state; the vault is real.
# Deployer is a stub of a few lines (its config and its tasks); where the real
# one is installed (/usr/local/bin/dep, or CIPI_TEST_DEP) it is asked too.
# Run from repo root: bash tests/verify-5.18.0.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/lib"
PASS=0; FAIL=0
pass() { echo "  OK: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
TMP=$(mktemp -d) && [[ -n "$TMP" && -d "$TMP" ]] || exit 1
trap 'rm -rf "${TMP:?}"' EXIT
echo "=== Cipi 5.18.0 regression checks ==="

v=$(tr -d "[:space:]" < "${ROOT}/version.md"); [[ "$(printf "%s\n%s\n" 5.18.0 "$v" | sort -V | head -1)" == 5.18.0 ]] && pass "version.md >= 5.18.0" || fail "version.md"
grep -q '^## \[5.18.0\]' "${ROOT}/CHANGELOG.md" && pass "CHANGELOG 5.18.0" || fail "CHANGELOG"
for f in "${ROOT}/cipi" "${LIB}/zt.sh" "${LIB}/zt-mesh.sh" "${LIB}/firewall.sh" "${LIB}/monitor.sh" \
         "${LIB}/notifications.sh" "${LIB}/completion.sh"; do
    bash -n "$f" && pass "$(basename "$f") parses" || fail "$(basename "$f") parse"
done
command -v jq >/dev/null 2>&1 || { echo "  (jq not installed)"; exit 1; }

BIN="${TMP}/bin"; PKG="${TMP}/pkg"; STATE="${TMP}/state"; CFG="${TMP}/etc/cipi"; APT="${TMP}/apt"; LE="${TMP}/le"
mkdir -p "$BIN" "$PKG" "$STATE" "$CFG" "${TMP}/log" "$APT/keyrings" "$APT/lists" "$LE"
head -c 32 /dev/urandom | base64 > "${CFG}/.vault_key"
printf 'VERSION_CODENAME=noble\nID=ubuntu\n' > "${TMP}/os-release"

# ── stubs ────────────────────────────────────────────────────
# ufw: the rules in a file, numbered as ufw numbers them ("[ 1]" … "[10]").
cat > "${BIN}/ufw" <<'EOF'
#!/bin/bash
R="$STATE/ufw.rules"; touch "$R"
echo "ufw $*" >> "$STATE/ufw.log"
add() { grep -qxF "$1" "$R" || echo "$1" >> "$R"; }
comment=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
    [[ "${args[$i]}" == "comment" ]] && { comment="${args[$((i + 1))]}"; args=("${args[@]:0:$i}"); break; }
done
set -- "${args[@]}"
case "$1" in
    status)
        [[ -f "$STATE/ufw.inactive" ]] && { echo "Status: inactive"; exit 0; }
        echo "Status: active"; echo ""
        echo "     To                         Action      From"
        echo "     --                         ------      ----"
        n=0
        while IFS='|' read -r to action from c; do
            n=$((n + 1))
            printf '[%2d] %-26s %-11s %s%s\n' "$n" "$to" "$action" "$from" "${c:+   # $c}"
        done < "$R" ;;
    allow)
        shift
        if [[ "$1" == "in" && "$2" == "on" ]]; then add "Anywhere on $3|ALLOW IN|Anywhere|${comment}"
        elif [[ "$1" == "from" ]]; then add "$6/${8:-tcp}|ALLOW IN|$2|${comment}"
        else add "$1|ALLOW IN|Anywhere|${comment}"; fi ;;
    delete)
        shift
        if [[ "$1" =~ ^[0-9]+$ ]]; then sed -i "${1}d" "$R"
        elif [[ "$1" == "allow" || "$1" == "limit" ]]; then
            tmp=$(mktemp); awk -F'|' -v t="$2" '!(done == 0 && $1 == t && $3 == "Anywhere") { print; next } { done = 1 }' "$R" > "$tmp"; cat "$tmp" > "$R"; rm -f "$tmp"
        fi ;;
esac
exit 0
EOF
# ip: the address of an interface that "exists", and the way back to an address.
cat > "${BIN}/ip" <<'EOF'
#!/bin/bash
if [[ "$*" == "-4 -o addr show dev "* ]]; then
    f="$STATE/if.${6}"
    [[ -f "$f" ]] || { echo "Device \"${6}\" does not exist." >&2; exit 1; }
    echo "7: ${6}    inet $(cat "$f") brd 0.0.0.0 scope global ${6}"
    exit 0
fi
if [[ "$1" == "route" && "$2" == "get" ]]; then
    if [[ "$3" == 127.* || "$3" == "203.0.113.5" ]]; then echo "local $3 dev lo table local src $3 uid 0"; exit 0; fi
    for f in "$STATE"/if.*; do
        [[ -f "$f" ]] || continue
        if [[ "$3" == 100.* ]]; then echo "$3 dev ${f##*/if.} table 52 src $(cut -d/ -f1 < "$f") uid 0"; exit 0; fi
    done
    echo "$3 via 203.0.113.1 dev eth0 src 203.0.113.5 uid 0"
    exit 0
fi
exit 0
EOF
cat > "${BIN}/systemctl" <<'EOF'
#!/bin/bash
echo "systemctl $*" >> "$STATE/systemctl.log"
case "$1" in
    is-active) [[ -f "$STATE/unit.${!#}" ]] ;;
    enable)    [[ "$2" == "--now" ]] && touch "$STATE/unit.$3"; exit 0 ;;
    disable)   [[ "$2" == "--now" ]] && rm -f "$STATE/unit.$3"; exit 0 ;;
    *) exit 0 ;;
esac
EOF
# apt-get: install puts the client's stub on the PATH, purge takes it away.
cat > "${BIN}/apt-get" <<'EOF'
#!/bin/bash
echo "apt-get $*" >> "$STATE/apt.log"
[[ -f "$STATE/apt.fail" && "$1" == "update" ]] && exit 100
pkg="${!#}"
case "$1" in
    install) [[ -f "$PKG/$pkg" ]] && cp "$PKG/$pkg" "$BIN/$pkg" && chmod +x "$BIN/$pkg"
             [[ "$pkg" == "netbird" ]] && touch "$STATE/unit.netbird"; exit 0 ;;
    purge)   rm -f "$BIN/$pkg"; exit 0 ;;
esac
exit 0
EOF
cat > "${BIN}/curl" <<'EOF'
#!/bin/bash
out="" url=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) out="$2"; shift ;;
        http*) url="$1" ;;
    esac
    shift
done
echo "curl ${url}" >> "$STATE/curl.log"
[[ -f "$STATE/curl.fail" ]] && exit 22
[[ -n "$out" ]] || exit 0
case "$url" in
    *netbird*) printf -- '-----BEGIN PGP PUBLIC KEY BLOCK-----\nabc\n-----END PGP PUBLIC KEY BLOCK-----\n' > "$out" ;;
    *)         printf 'binarykey' > "$out" ;;
esac
EOF
cat > "${BIN}/sshd" <<'EOF'
#!/bin/bash
[[ "$1" == "-T" ]] || exit 0
echo "port 22"
if [[ -f "$STATE/sshd.listen" ]]; then cat "$STATE/sshd.listen"; else echo "listenaddress 0.0.0.0:22"; echo "listenaddress [::]:22"; fi
EOF
cat > "${BIN}/id" <<'EOF'
#!/bin/bash
[[ "$1" == "cipi" ]] && exit 0
exec /usr/bin/id "$@"
EOF
cat > "${BIN}/who" <<'EOF'
#!/bin/bash
exit 0
EOF
# tailscale: a backend state, a node key that may expire, Tailscale SSH.
cat > "${PKG}/tailscale" <<'EOF'
#!/bin/bash
echo "tailscale $*" >> "$STATE/ts.log"
state=$(cat "$STATE/ts.state" 2>/dev/null || echo NeedsLogin)
case "$1" in
    up)
        [[ -f "$STATE/ts.fail" ]] && { echo "backend error: invalid key: API key does not exist" >&2; exit 1; }
        for a in "$@"; do
            [[ "$a" == --auth-key=file:* ]] && { echo "key=$(cat "${a#--auth-key=file:}")" >> "$STATE/ts.log"; echo "${a#--auth-key=file:}" > "$STATE/ts.keyfile"; }
            [[ "$a" == "--ssh" ]] && echo true > "$STATE/ts.ssh"
            [[ "$a" == --hostname=* ]] && echo "${a#--hostname=}" > "$STATE/ts.host"
        done
        echo Running > "$STATE/ts.state"; echo "100.101.102.103/32" > "$STATE/if.tailscale0"; touch "$STATE/unit.tailscaled" ;;
    status)
        if [[ "$state" == "Running" ]]; then ips='["100.101.102.103","fd7a:115c:a1e0::1"]'; else ips='[]'; fi
        exp=$(cat "$STATE/ts.expiry" 2>/dev/null || true)
        online=true; [[ -f "$STATE/ts.offline" ]] && online=false
        jq -n --arg s "$state" --argjson ips "$ips" --arg exp "$exp" --arg host "$(cat "$STATE/ts.host" 2>/dev/null || echo web1)" --argjson online "$online" '
            {Version: "1.80.2-t0abc-g1def", BackendState: $s, TailscaleIPs: $ips,
             Self: ({HostName: $host, DNSName: ($host + ".tail1234.ts.net."), TailscaleIPs: $ips, Online: $online, Tags: ["tag:cipi"]}
                    + (if $exp == "" then {} else {KeyExpiry: $exp} end)),
             CurrentTailnet: {Name: "example.com"}, Health: [],
             Peer: {a: {Online: true}, b: {Online: true}, c: {Online: false}}}' ;;
    debug) jq -n --argjson ssh "$(cat "$STATE/ts.ssh" 2>/dev/null || echo false)" --argjson dns "$(cat "$STATE/ts.dns" 2>/dev/null || echo false)" \
               '{RunSSH: $ssh, ControlURL: "https://controlplane.tailscale.com", CorpDNS: $dns, RouteAll: false}' ;;
    set)
        for a in "$@"; do
            [[ "$a" == "--ssh" ]] && echo true > "$STATE/ts.ssh"
            [[ "$a" == "--ssh=false" ]] && echo false > "$STATE/ts.ssh"
            [[ "$a" == --hostname=* ]] && echo "${a#--hostname=}" > "$STATE/ts.host"
        done ;;
    logout) echo NeedsLogin > "$STATE/ts.state"; rm -f "$STATE/if.tailscale0" ;;
esac
exit 0
EOF
# netbird: the text status its documentation shows.
cat > "${PKG}/netbird" <<'EOF'
#!/bin/bash
echo "netbird $*" >> "$STATE/nb.log"
state=$(cat "$STATE/nb.state" 2>/dev/null || echo NeedsLogin)
case "$1" in
    up)
        [[ -f "$STATE/nb.fail" ]] && { echo "Error: login failed" >&2; exit 1; }
        prev=""
        for a in "$@"; do
            [[ "$prev" == "--setup-key-file" ]] && { echo "key=$(cat "$a")" >> "$STATE/nb.log"; }
            prev="$a"
        done
        echo Connected > "$STATE/nb.state"; echo "100.92.14.7/16" > "$STATE/if.wt0" ;;
    status)
        if [[ "$state" == "Connected" ]]; then
            cat <<OUT
OS: linux/amd64
Daemon version: 0.76.3
CLI version: 0.76.3
Profile: default
Management: Connected to $(cat "$STATE/nb.url" 2>/dev/null || echo https://api.netbird.io:443)
Signal: Connected to https://signal.netbird.io:443
Relays: 2/2 Available
Nameservers: 0/0 Available
FQDN: web1.netbird.cloud
NetBird IP: 100.92.14.7/16
Interface type: Kernel
Quantum resistance: false
Routes: -
Peers count: 3/4 Connected
OUT
        else
            echo "Daemon status: ${state}"
            echo ""
            echo "Run UP command to log in with SSO (interactive login):"
        fi ;;
    down) echo Idle > "$STATE/nb.state" ;;
    deregister) echo NeedsLogin > "$STATE/nb.state"; rm -f "$STATE/if.wt0" ;;
esac
exit 0
EOF
chmod +x "${BIN}"/* "${PKG}"/*

ENVV=(PATH="${BIN}:${PATH}" STATE="$STATE" PKG="$PKG" BIN="$BIN" CIPI_LIB="$LIB" CIPI_CONFIG="$CFG" CIPI_LOG="${TMP}/log"
      MESH_TS_KEYRING="${APT}/keyrings/tailscale.gpg" MESH_TS_LIST="${APT}/lists/tailscale.list"
      MESH_NB_KEYRING="${APT}/keyrings/netbird.asc" MESH_NB_LIST="${APT}/lists/netbird.list"
      MESH_OS_RELEASE="${TMP}/os-release" MESH_LE_LIVE="$LE" MESH_WAIT=2 MESH_JOIN_TIMEOUT=5 MESH_AUTH_LOG="${TMP}/auth.log"
      ZT_TOKEN_FILE="${CFG}/zt.token" ZT_CF_DIR="${TMP}/cf" ZT_CF_CONF="${TMP}/cf/config.yml" ZT_IPS_DIR="${TMP}/ips"
      ZT_REALIP="${TMP}/realip.conf" ZT_F2B="${TMP}/f2b.conf" ZT_CRON="${TMP}/zt.cron" ZT_CS_WL="${TMP}/cs.yaml"
      MONITOR_STATE_DIR="${TMP}/mon")
# SESSION: the address the SSH session came from ("" = no session).
SESSION=""
Z() {
    env "${ENVV[@]}" ${SESSION:+SSH_CLIENT="${SESSION} 50000 22"} bash -c 'set -euo pipefail
        RED=""; GREEN=""; YELLOW=""; CYAN=""; DIM=""; NC=""; BOLD=""
        source "$CIPI_LIB/common.sh"
        log_action() { :; }; log_event() { :; }; cipi_notify() { echo "notify $3" >> "$STATE/notify.log"; }
        reload_nginx() { :; }
        source "$CIPI_LIB/zt.sh"
        '"$1" < /dev/null
}
# The mesh's library is loaded by zt.sh when a mesh command runs — here by hand.
mst() { Z '_zt_mesh_load; _mesh_state'; }
rules() { cat "${STATE}/ufw.rules" 2>/dev/null; }
has_rule() { rules | grep -q "^$1|"; }
reset_fw() { printf '22/tcp|ALLOW IN|Anywhere|\n80/tcp|ALLOW IN|Anywhere|\n443/tcp|ALLOW IN|Anywhere|\n' > "${STATE}/ufw.rules"; }
reset_fw
Z 'jq -n "{shop: {domain: \"shop.example.com\", php: \"8.4\"}}" | vault_write apps.json' >/dev/null

# ── nothing on yet ───────────────────────────────────────────
[[ "$(Z 'zt_command tailscale status --json' | jq -c .)" == '{"enabled":false,"provider":"tailscale","active":null}' ]] && pass "no mesh: tailscale status --json says off" || fail "off json: $(Z 'zt_command tailscale status --json')"
[[ "$(Z '_zt_status_json' | jq -c .mesh)" == '{"enabled":false,"provider":null,"active":null}' ]] && pass "cipi zt status --json: mesh off" || fail "zt json mesh: $(Z '_zt_status_json' | jq -c .mesh)"
out=$(Z 'zt_command status' 2>&1)
grep -q 'Mesh network' <<< "$out" && grep -q 'cipi zt tailscale enable --auth-key=KEY' <<< "$out" && [[ "$(grep -c 'not enabled' <<< "$out")" == 1 ]] \
    && pass "cipi zt status: the mesh under Cloudflare's, and \"not enabled\" said once (Cloudflare's)" || fail "status text: ${out}"
out=$(Z 'zt_command bogus' 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q 'cipi zt tailscale|netbird' <<< "$out" && pass "unknown zt command: the usage names the mesh" || fail "usage: ${out}"
out=$(Z 'zt_command tailscale' 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q 'enable --auth-key=KEY' <<< "$out" && pass "cipi zt tailscale alone: its usage" || fail "mesh usage: ${out}"

# ── tailscale enable ─────────────────────────────────────────
out=$(Z 'zt_command tailscale enable' 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q 'A key is needed' <<< "$out" && [[ ! -f "${STATE}/apt.log" ]] && pass "enable without a key: refused, nothing installed" || fail "no key: ${out}"
for bad in '--hostname=-web' '--tags=1bad' '--login-server=ftp://x' '--management-url=https://nb.example.com'; do
    out=$(Z "zt_command tailscale enable --auth-key=tskey-auth-k1 ${bad}" 2>&1); rc=$?
    [[ $rc -ne 0 && ! -f "${STATE}/apt.log" ]] && pass "enable ${bad}: refused before anything is installed" || fail "bad ${bad}: ${out}"
done
out=$(Z 'zt_command tailscale enable --auth-key="has space"' 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q 'does not look like a key' <<< "$out" && pass "a key with a space is not a key" || fail "key check: ${out}"

out=$(Z 'zt_command tailscale enable --auth-key=tskey-auth-k1 --hostname=web1 --tags=cipi,tag:web' 2>&1); rc=$?
[[ $rc -eq 0 ]] && pass "tailscale enable" || fail "enable: ${out}"
grep -q 'curl https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg' "${STATE}/curl.log" && [[ -s "${APT}/keyrings/tailscale.gpg" ]] \
    && pass "the signing key of this Ubuntu's codename" || fail "key: $(cat "${STATE}/curl.log" 2>/dev/null)"
[[ "$(cat "${APT}/lists/tailscale.list")" == "deb [signed-by=${APT}/keyrings/tailscale.gpg] https://pkgs.tailscale.com/stable/ubuntu noble main" ]] \
    && pass "the apt source, signed by that key alone" || fail "list: $(cat "${APT}/lists/tailscale.list")"
grep -q 'apt-get install -y -qq tailscale' "${STATE}/apt.log" && pass "tailscale installed from it" || fail "apt: $(cat "${STATE}/apt.log")"
up=$(grep '^tailscale up' "${STATE}/ts.log" | head -1)
[[ "$up" == *"--reset"* && "$up" == *"--timeout=5s"* && "$up" == *"--hostname=web1"* && "$up" == *"--advertise-tags=tag:cipi,tag:web"* \
   && "$up" == *"--accept-dns=false"* && "$up" == *"--accept-routes=false"* && "$up" != *"--ssh"* && "$up" != *"--force-reauth"* ]] \
    && pass "tailscale up: hostname, tags, DNS and routes of the tailnet not accepted" || fail "up: ${up}"
[[ "$up" != *"tskey-auth-k1"* ]] && grep -qx 'key=tskey-auth-k1' "${STATE}/ts.log" && pass "the auth key goes in a file, not on the command line" || fail "key on argv: ${up}"
[[ ! -e "$(cat "${STATE}/ts.keyfile")" ]] && pass "…and the file is removed" || fail "key file left: $(cat "${STATE}/ts.keyfile")"
has_rule "Anywhere on tailscale0" && rules | grep -q 'Anywhere on tailscale0|ALLOW IN|Anywhere|cipi-zt-mesh$' && pass "UFW lets the mesh interface in (cipi-zt-mesh)" || fail "ufw: $(rules)"
has_rule "22/tcp" && has_rule "80/tcp" && has_rule "443/tcp" && pass "enable closes nothing: 22, 80, 443 still open" || fail "ports: $(rules)"
! rules | grep -q '41641' && pass "the WireGuard port is not opened unless --direct" || fail "direct: $(rules)"
[[ "$(mst | jq -c '[.provider, .enabled, .installed_by_cipi, .lock_ssh, .lock_http, .interface, .tags]')" == '["tailscale",true,true,false,false,"tailscale0","tag:cipi,tag:web"]' ]] \
    && pass "state: tailscale, Cipi's client, no lock" || fail "state: $(mst)"
grep -qx 'notify zt_enable' "${STATE}/notify.log" && pass "notification zt_enable" || fail "notify"
grep -q 'ssh cipi@100.101.102.103' <<< "$out" && grep -q 'cipi zt tailscale lock ssh' <<< "$out" && pass "enable says how to come in, and what to run from there" || fail "next steps: ${out}"

# ── status ───────────────────────────────────────────────────
j=$(Z 'zt_command tailscale status --json')
jq -e '.enabled and .provider == "tailscale" and .label == "Tailscale" and .connected and .running and .ip == "100.101.102.103" and .ip6 == "fd7a:115c:a1e0::1"
       and .fqdn == "web1.tail1234.ts.net" and .network == "example.com" and .version == "1.80.2" and .tags == ["tag:cipi"]
       and .key_expiry == null and .key_expires_in_days == null and .peers == {"total":3,"online":2}
       and .ssh == {"provider_ssh":false,"ports":[22],"command":"ssh cipi@100.101.102.103","seen":null}
       and .firewall_active and .http01_apps == [] and .panel == null
       and .lock == {"ssh":false,"http":false} and .direct == {"port":41641,"open":false} and .control_url == null and .warnings == []' <<< "$j" >/dev/null \
    && pass "status --json: address, name, tailnet, peers, node key, locks" || fail "status json: ${j}"
[[ "$(Z '_zt_status_json' | jq -c '[.enabled, .mesh.provider, .mesh.ip]')" == '[false,"tailscale","100.101.102.103"]' ]] \
    && pass "cipi zt status --json: mesh next to Cloudflare's (off)" || fail "zt json: $(Z '_zt_status_json' | jq -c .mesh)"
out=$(Z 'zt_command status' 2>&1)
grep -q 'Provider *Tailscale' <<< "$out" && grep -q '100.101.102.103' <<< "$out" && grep -q 'does not expire' <<< "$out" && pass "cipi zt status: the mesh's lines" || fail "status text: ${out}"
[[ "$(Z 'zt_command netbird status --json' | jq -c .)" == '{"enabled":false,"provider":"netbird","active":"tailscale"}' ]] && pass "the other provider's status names the one that is on" || fail "other status"

# ── one mesh per server ──────────────────────────────────────
out=$(Z 'zt_command netbird enable --setup-key=NBKEY' 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q 'one at a time' <<< "$out" && grep -q '100.64.0.0/10' <<< "$out" && grep -q 'cipi zt tailscale disable' <<< "$out" \
    && [[ ! -x "${BIN}/netbird" ]] && pass "a second mesh is refused, and says why" || fail "second mesh: ${out}"

# ── lock ssh: only from a session that came over the mesh ────
SESSION=""; out=$(Z 'zt_command tailscale lock ssh --yes' 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q 'No SSH session to check' <<< "$out" && has_rule "22/tcp" && pass "lock ssh with no session: refused" || fail "no session: ${out}"
SESSION="198.51.100.7"; out=$(Z 'zt_command tailscale lock ssh --yes' 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q 'did not come through Tailscale' <<< "$out" && grep -q 'ssh cipi@100.101.102.103' <<< "$out" && has_rule "22/tcp" \
    && pass "lock ssh from the public address: refused, and told how to come in" || fail "public session: ${out}"
SESSION="100.99.1.2"
date -u -d '+40 days' '+%Y-%m-%dT%H:%M:%SZ' > "${STATE}/ts.expiry"
out=$(Z 'zt_command tailscale lock ssh --yes' 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q 'node key of this machine expires' <<< "$out" && grep -q -- '--tags=tag:cipi --reauth' <<< "$out" && has_rule "22/tcp" \
    && pass "lock ssh while the node key can expire: refused (the day it expires nobody gets in)" || fail "expiry: ${out}"
jq -e '.key_expires_in_days >= 39 and (.warnings | length) == 1' <<< "$(Z 'zt_command tailscale status --json')" >/dev/null && pass "status: the expiry, in days, and a warning" || fail "expiry json"
rm -f "${STATE}/ts.expiry"
echo "listenaddress 203.0.113.5:22" > "${STATE}/sshd.listen"
out=$(Z 'zt_command tailscale lock ssh --yes' 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q 'sshd does not listen on the mesh address' <<< "$out" && has_rule "22/tcp" && pass "lock ssh while sshd listens on the public address only: refused" || fail "listen: ${out}"
rm -f "${STATE}/sshd.listen"
echo NeedsLogin > "${STATE}/ts.state"
out=$(Z 'zt_command tailscale lock ssh --yes' 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q 'is not connected (NeedsLogin)' <<< "$out" && has_rule "22/tcp" && pass "lock ssh while off the network: refused" || fail "disconnected: ${out}"
echo Running > "${STATE}/ts.state"
touch "${STATE}/ufw.inactive"
out=$(Z 'zt_command tailscale lock ssh --yes' 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q 'UFW is not active' <<< "$out" && [[ "$(mst | jq -r .lock_ssh)" == false ]] && pass "lock ssh with UFW off: refused — a lock that closes nothing is not recorded" || fail "ufw off: ${out}"
out=$(Z 'zt_command tailscale lock http --yes' 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q 'UFW is not active' <<< "$out" && [[ "$(mst | jq -r .lock_http)" == false ]] && pass "…and lock http too" || fail "ufw off http: ${out}"
rm -f "${STATE}/ufw.inactive"
out=$(Z 'zt_command tailscale lock ssh' 2>&1); rc=$?
has_rule "22/tcp" && grep -q 'Aborted' <<< "$out" && pass "lock ssh without --yes asks, and no answer is no" || fail "confirm: ${out}"
: > "${STATE}/notify.log"
out=$(Z 'zt_command tailscale lock ssh --yes' 2>&1); rc=$?
[[ $rc -eq 0 ]] && ! has_rule "22/tcp" && has_rule "Anywhere on tailscale0" && has_rule "80/tcp" && [[ "$(mst | jq -r .lock_ssh)" == true ]] \
    && grep -qx 'notify zt_lock_ssh' "${STATE}/notify.log" && pass "lock ssh over the mesh: port 22 closed to the world, the mesh rule stays" || fail "lock ssh: ${out} / $(rules)"

# The firewall does not reopen it, nor does Cloudflare's side.
F() {
    env "${ENVV[@]}" bash -c 'set -euo pipefail
        RED=""; GREEN=""; YELLOW=""; CYAN=""; DIM=""; NC=""; BOLD=""
        source "$CIPI_LIB/common.sh"; source "$CIPI_LIB/firewall.sh"
        '"$1" < /dev/null
}
out=$(F '_firewall_zt_guard 22' 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q 'cipi zt tailscale lock ssh' <<< "$out" && grep -q 'Reopen it with: cipi zt tailscale unlock ssh' <<< "$out" && pass "cipi firewall allow 22: refused under the mesh's lock" || fail "guard ssh: ${out}"
out=$(F '_firewall_zt_guard 8080' 2>&1); rc=$?
[[ $rc -eq 0 ]] && pass "…another port is not its business" || fail "guard 8080: ${out}"
[[ "$(F '_firewall_zt_lock ssh')" == true && "$(F '_firewall_zt_lock http')" == false && "$(F '_firewall_mesh_lock ssh')" == tailscale ]] && pass "firewall: the lock, and who holds it" || fail "fw lock"
out=$(Z '_zt_unlock_ssh' 2>&1)
! has_rule "22/tcp" && grep -q "the mesh's lock does" <<< "$out" && grep -q 'cipi zt tailscale unlock ssh' <<< "$out" && pass "cipi zt ssh unlock (Cloudflare's) leaves port 22 to the mesh's lock" || fail "cf unlock: ${out} / $(rules)"

# Unlock: back to the world — unless Cloudflare's lock holds it.
Z 'echo "{\"enabled\":true,\"lock_ssh\":true}" | vault_write zt.json' >/dev/null
out=$(Z 'zt_command tailscale unlock ssh' 2>&1)
! has_rule "22/tcp" && [[ "$(mst | jq -r .lock_ssh)" == false ]] && grep -q "Cloudflare's lock does" <<< "$out" && pass "unlock ssh: the mesh lets go, Cloudflare's lock keeps port 22" || fail "unlock under cf: ${out}"
Z 'echo "{}" | vault_write zt.json' >/dev/null
Z 'zt_command tailscale lock ssh --yes' >/dev/null 2>&1
out=$(Z 'zt_command tailscale ssh unlock' 2>&1); rc=$?
[[ $rc -eq 0 ]] && has_rule "22/tcp" && [[ "$(mst | jq -r .lock_ssh)" == false ]] && pass "ssh unlock: port 22 open to the world again" || fail "unlock: ${out} / $(rules)"

# ── lock http ────────────────────────────────────────────────
mkdir -p "${LE}/shop.example.com"
out=$(Z 'zt_command tailscale lock http --yes' 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q 'renew SSL over HTTP-01' <<< "$out" && grep -q ' shop' <<< "$out" && has_rule "80/tcp" && pass "lock http with a certificate on HTTP-01: refused, the app named" || fail "http01: ${out}"
rmdir "${LE}/shop.example.com"
out=$(Z 'zt_command tailscale lock http --yes' 2>&1); rc=$?
[[ $rc -eq 0 ]] && ! has_rule "80/tcp" && ! has_rule "443/tcp" && has_rule "22/tcp" && has_rule "Anywhere on tailscale0" && [[ "$(mst | jq -r .lock_http)" == true ]] \
    && grep -qx 'notify zt_lock_http' "${STATE}/notify.log" && pass "lock http: 80/443 closed to the world, open on the mesh" || fail "lock http: ${out} / $(rules)"
out=$(F '_firewall_zt_guard 443' 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q 'Zero Trust keeps 80/443 to the mesh network (cipi zt tailscale lock http)' <<< "$out" && pass "cipi firewall allow 443: refused under the mesh's lock" || fail "guard http: ${out}"
Z '_zt_unlock_http_apply' >/dev/null 2>&1
! has_rule "80/tcp" && pass "Cloudflare's unlock/disable leaves 80/443 to the mesh's lock" || fail "cf unlock http: $(rules)"
out=$(Z 'zt_command tailscale unlock http' 2>&1); rc=$?
[[ $rc -eq 0 ]] && has_rule "80/tcp" && has_rule "443/tcp" && [[ "$(mst | jq -r .lock_http)" == false ]] && pass "unlock http: 80/443 open to the world again" || fail "unlock http: ${out}"

# ── Tailscale SSH ────────────────────────────────────────────
SESSION="100.99.1.2"; out=$(Z 'zt_command tailscale ssh enable' 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q 'this session may end' <<< "$out" && ! grep -q '^tailscale set' "${STATE}/ts.log" && pass "Tailscale SSH from a session over the tailnet: refused without --force" || fail "ssh over mesh: ${out}"
SESSION="198.51.100.7"; out=$(Z 'zt_command tailscale ssh enable' 2>&1); rc=$?
[[ $rc -eq 0 ]] && grep -qx 'tailscale set --ssh' "${STATE}/ts.log" && [[ "$(mst | jq -r .provider_ssh)" == true ]] \
    && [[ "$(Z 'zt_command tailscale status --json' | jq -r .ssh.provider_ssh)" == true ]] && pass "ssh enable: tailscale set --ssh, in the state and the status" || fail "ssh enable: ${out}"
out=$(Z 'zt_command tailscale ssh disable' 2>&1); rc=$?
[[ $rc -eq 0 ]] && grep -qx 'tailscale set --ssh=false' "${STATE}/ts.log" && [[ "$(mst | jq -r .provider_ssh)" == false ]] && pass "ssh disable: back to OpenSSH" || fail "ssh disable: ${out}"

# ── disable: what the locks closed comes back, the client goes ─
SESSION="100.99.1.2"
Z 'zt_command tailscale lock ssh --yes' >/dev/null 2>&1; Z 'zt_command tailscale lock http --yes' >/dev/null 2>&1
[[ "$(rules | wc -l)" == 1 ]] || fail "before disable: $(rules)"
: > "${STATE}/notify.log"
out=$(Z 'zt_command tailscale disable --yes' 2>&1); rc=$?
[[ $rc -eq 0 ]] && has_rule "22/tcp" && has_rule "80/tcp" && has_rule "443/tcp" && pass "disable: 22, 80 and 443 open again" || fail "disable ports: ${out} / $(rules)"
! rules | grep -q 'cipi-zt-mesh' && pass "…the mesh rule gone — it was rule [ 1], below ten" || fail "mesh rule left: $(rules)"
grep -q 'trap .. HUP' "${LIB}/zt-mesh.sh" && [[ "$(grep -n '_mesh_uninstall "\$p" >/dev/null' "${LIB}/zt-mesh.sh" | cut -d: -f1)" -gt "$(grep -n 'ZT MESH DISABLE' "${LIB}/zt-mesh.sh" | cut -d: -f1)" ]] \
    && pass "…the client goes last, with the hangup ignored: a session over the mesh ends there, nothing is left half done" || fail "disable order"
grep -qx 'tailscale logout' "${STATE}/ts.log" && grep -q 'apt-get purge -y -qq tailscale' "${STATE}/apt.log" && [[ ! -x "${BIN}/tailscale" ]] \
    && [[ ! -e "${APT}/lists/tailscale.list" && ! -e "${APT}/keyrings/tailscale.gpg" ]] && pass "…the server off the tailnet, the client, its source and its key removed" || fail "uninstall: $(cat "${STATE}/apt.log")"
[[ "$(mst | jq -c '[.enabled, .provider, .lock_ssh, .lock_http]')" == '[false,"",false,false]' ]] && grep -qx 'notify zt_disable' "${STATE}/notify.log" && pass "…state cleared, notification zt_disable" || fail "state after disable: $(mst)"
out=$(Z 'zt_command tailscale disable --yes' 2>&1); rc=$?
[[ $rc -eq 0 ]] && grep -q 'is off on this server' <<< "$out" && pass "disable twice: nothing to do" || fail "disable twice: ${out}"

# ── signing a machine in again ───────────────────────────────
rm -f "${STATE}"/ts.* "${STATE}/unit.tailscaled" "${STATE}/if.tailscale0" "${STATE}/apt.log"; reset_fw; SESSION="198.51.100.7"
Z 'zt_command tailscale enable --auth-key=tskey-auth-k1' >/dev/null 2>&1
: > "${STATE}/ts.log"
out=$(Z 'zt_command tailscale enable --auth-key=tskey-auth-k9 --tags=cipi --reauth' 2>&1); rc=$?
up=$(grep '^tailscale up' "${STATE}/ts.log" | head -1)
[[ $rc -eq 0 && "$up" == *"--force-reauth"* && "$up" == *"--advertise-tags=tag:cipi"* ]] && grep -qx 'key=tskey-auth-k9' "${STATE}/ts.log" \
    && pass "tailscale enable --reauth on a connected machine: signed in again with the new key and its tags" || fail "reauth: ${out} / ${up}"
echo '0001-01-01T00:00:00Z' > "${STATE}/ts.expiry"
[[ "$(Z 'zt_command tailscale status --json' | jq -c '[.key_expiry, .warnings]')" == '[null,[]]' ]] && pass "a zero time is no expiry" || fail "zero expiry"
rm -f "${STATE}/ts.expiry"
Z 'zt_command tailscale disable --yes' >/dev/null 2>&1

# ── a join that fails ────────────────────────────────────────
rm -f "${STATE}"/ts.* "${STATE}/unit.tailscaled" "${STATE}/if.tailscale0"; touch "${STATE}/ts.fail"; reset_fw
out=$(Z 'zt_command tailscale enable --auth-key=tskey-auth-bad' 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q 'did not join the network' <<< "$out" && [[ "$(mst | jq -c '[.enabled, .provider, .installed_by_cipi]')" == '[false,"tailscale",true]' ]] \
    && ! rules | grep -q 'cipi-zt-mesh' && pass "a key that does not work: not enabled, no rule, the client remembered as Cipi's" || fail "failed join: ${out} / $(mst)"
[[ -z "$(Z '_zt_mesh_load; _mesh_provider')" ]] && pass "…no mesh is on" || fail "provider after failed join"
rm -f "${STATE}/ts.fail"
out=$(Z 'zt_command tailscale disable --yes' 2>&1); rc=$?
[[ $rc -eq 0 && ! -x "${BIN}/tailscale" ]] && pass "…and disable removes it" || fail "disable after failed join: ${out}"

# ── a client that was there before Cipi ──────────────────────
rm -f "${STATE}"/ts.* "${STATE}"/apt.log; reset_fw
cp "${PKG}/tailscale" "${BIN}/tailscale"; echo Running > "${STATE}/ts.state"; echo "100.101.102.103/32" > "${STATE}/if.tailscale0"; touch "${STATE}/unit.tailscaled"
SESSION="198.51.100.7"; out=$(Z 'zt_command tailscale enable' 2>&1); rc=$?
[[ $rc -eq 0 ]] && grep -q 'connected already' <<< "$out" && ! grep -q '^tailscale up' "${STATE}/ts.log" && [[ ! -f "${STATE}/apt.log" ]] \
    && [[ "$(mst | jq -c '[.enabled, .installed_by_cipi]')" == '[true,false]' ]] && has_rule "Anywhere on tailscale0" \
    && pass "a tailnet the server is on already: adopted without a key, its settings untouched" || fail "adopt: ${out}"
echo true > "${STATE}/ts.dns"
[[ "$(Z 'zt_command tailscale status --json' | jq -r .accept_dns)" == true ]] && pass "…a setting the client has on is read from the client" || fail "live dns on"
echo false > "${STATE}/ts.dns"
Z '_zt_mesh_load; _mesh_state_write "$(_mesh_state | jq -c ".accept_dns = true")"' >/dev/null
[[ "$(Z 'zt_command tailscale status --json' | jq -r .accept_dns)" == false ]] && pass "…and one it has off stays off, whatever the state remembered (false is not \"unknown\")" || fail "live dns off"
out=$(Z 'zt_command tailscale enable --accept-dns --tags=cipi' 2>&1); rc=$?
[[ $rc -eq 0 ]] && grep -q 'are given when joining' <<< "$out" && ! grep -q '^tailscale up' "${STATE}/ts.log" && [[ "$(mst | jq -c '[.accept_dns, .tags]')" == '[false,""]' ]] \
    && pass "…what is only applied when joining is said, and not written as done" || fail "adopt options: ${out} / $(mst)"
out=$(Z 'zt_command tailscale disable --yes' 2>&1); rc=$?
[[ $rc -eq 0 && -x "${BIN}/tailscale" ]] && ! grep -q 'logout' "${STATE}/ts.log" && [[ ! -f "${STATE}/apt.log" ]] && ! rules | grep -q 'cipi-zt-mesh' \
    && pass "…and disable leaves it installed and connected" || fail "adopt disable: ${out}"
# NetBird next to a Tailscale that is not Cipi's: refused too.
out=$(Z 'zt_command netbird enable --setup-key=NBKEY' 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q 'Tailscale is installed on this server' <<< "$out" && [[ ! -x "${BIN}/netbird" ]] && pass "NetBird next to a Tailscale that is installed: refused (--force to insist)" || fail "foreign: ${out}"
rm -f "${BIN}/tailscale" "${STATE}"/ts.* "${STATE}/if.tailscale0" "${STATE}/unit.tailscaled"

# ── netbird ──────────────────────────────────────────────────
reset_fw; : > "${STATE}/curl.log"; rm -f "${STATE}/apt.log"
out=$(Z 'zt_command netbird enable --setup-key=NBKEY --ssh' 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q "NetBird's own SSH server is not something Cipi turns on" <<< "$out" && [[ ! -f "${STATE}/apt.log" ]] && pass "netbird enable --ssh: refused — OpenSSH stays the SSH server" || fail "nb --ssh: ${out}"
out=$(Z 'zt_command netbird enable --setup-key=NBKEY --reauth' 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q "is Tailscale's" <<< "$out" && [[ ! -f "${STATE}/apt.log" ]] && pass "netbird enable --reauth: refused, with what to do instead" || fail "nb --reauth: ${out}"
out=$(Z 'zt_command netbird enable --setup-key=NBKEY --tags=x' 2>&1); rc=$?
[[ $rc -ne 0 ]] && pass "netbird enable --tags: Tailscale's option, refused" || fail "nb --tags: ${out}"
echo "https://nb.example.com:443" > "${STATE}/nb.url"
out=$(Z 'zt_command netbird enable --setup-key=NBKEY --management-url=https://nb.example.com:443 --direct' 2>&1); rc=$?
[[ $rc -eq 0 ]] && pass "netbird enable" || fail "nb enable: ${out}"
grep -q 'curl https://pkgs.netbird.io/debian/public.key' "${STATE}/curl.log" && grep -q 'BEGIN PGP PUBLIC KEY BLOCK' "${APT}/keyrings/netbird.asc" \
    && [[ "$(cat "${APT}/lists/netbird.list")" == "deb [signed-by=${APT}/keyrings/netbird.asc] https://pkgs.netbird.io/debian stable main" ]] \
    && pass "NetBird's key (armored, as apt reads it) and source" || fail "nb apt: $(cat "${APT}/lists/netbird.list" 2>/dev/null)"
up=$(grep '^netbird up' "${STATE}/nb.log" | head -1)
[[ "$up" == *"--setup-key-file "* && "$up" != *"NBKEY"* && "$up" == *"--management-url https://nb.example.com:443"* && "$up" == *"--disable-dns=true"* && "$up" == *"--disable-client-routes=true"* && "$up" != *"--allow-server-ssh"* ]] \
    && grep -qx 'key=NBKEY' "${STATE}/nb.log" && pass "netbird up: the key in a file, the self-hosted URL, no DNS, no routes, no SSH server" || fail "nb up: ${up}"
has_rule "Anywhere on wt0" && has_rule "51820/udp" && pass "UFW: wt0, and 51820/udp with --direct" || fail "nb ufw: $(rules)"
j=$(Z 'zt_command netbird status --json')
jq -e '.provider == "netbird" and .connected and .ip == "100.92.14.7" and .fqdn == "web1.netbird.cloud" and .name == "web1" and .network == "netbird.cloud"
       and .version == "0.76.3" and .peers == {"total":4,"online":3} and .control_url == "https://nb.example.com:443" and .interface == "wt0"
       and .key_expiry == null and .direct == {"port":51820,"open":true} and .ssh.command == "ssh cipi@100.92.14.7"' <<< "$j" >/dev/null \
    && pass "netbird status --json, read from its text status" || fail "nb json: ${j}"
out=$(Z 'zt_command netbird ssh enable' 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q 'plain OpenSSH' <<< "$out" && pass "netbird ssh enable: refused, and told what SSH over NetBird is" || fail "nb ssh: ${out}"
SESSION="100.92.1.9"; out=$(Z 'zt_command netbird lock ssh --yes' 2>&1); rc=$?
[[ $rc -eq 0 ]] && ! has_rule "22/tcp" && has_rule "Anywhere on wt0" && pass "netbird lock ssh from a session over wt0" || fail "nb lock: ${out}"
echo Idle > "${STATE}/nb.state"
j=$(Z 'zt_command netbird status --json')
jq -e '(.connected | not) and .state == "Idle" and (.warnings | map(select(test("locked to the mesh"))) | length) == 1' <<< "$j" >/dev/null && pass "netbird down with SSH locked: said in the status" || fail "nb down json: ${j}"
echo Connected > "${STATE}/nb.state"
out=$(Z 'zt_command netbird disable --yes' 2>&1); rc=$?
[[ $rc -eq 0 ]] && has_rule "22/tcp" && ! rules | grep -q 'cipi-zt-mesh' && grep -qx 'netbird deregister' "${STATE}/nb.log" && [[ ! -x "${BIN}/netbird" && ! -e "${APT}/lists/netbird.list" ]] \
    && pass "netbird disable: port 22 back, both rules gone, the peer deregistered, the client removed" || fail "nb disable: ${out} / $(rules)"

# ── from the panel (sudo by www-data) ────────────────────────
# P: the command as the API runs it — no SSH session, SUDO_USER=www-data.
P() {
    env "${ENVV[@]}" SUDO_USER=www-data bash -c 'set -euo pipefail
        RED=""; GREEN=""; YELLOW=""; CYAN=""; DIM=""; NC=""; BOLD=""
        source "$CIPI_LIB/common.sh"
        log_action() { :; }; log_event() { :; }; cipi_notify() { echo "notify $3" >> "$STATE/notify.log"; }
        source "$CIPI_LIB/zt.sh"
        '"$1" < /dev/null
}
rm -f "${STATE}"/ts.* "${STATE}/apt.log"; reset_fw; SESSION=""
out=$(P 'zt_command tailscale enable --auth-key=tskey-auth-p1 --hostname=web1' 2>&1); rc=$?
[[ $rc -eq 0 ]] && grep -qx 'key=tskey-auth-p1' "${STATE}/ts.log" && has_rule "Anywhere on tailscale0" && has_rule "22/tcp" && pass "panel: enable joins the network, and closes nothing" || fail "panel enable: ${out}"
out=$(P 'zt_command tailscale lock ssh --yes' 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q 'Nobody has signed in over SSH through Tailscale yet' <<< "$out" && grep -q 'ssh cipi@100.101.102.103' <<< "$out" && has_rule "22/tcp" \
    && pass "panel: lock ssh with no login over the mesh in sshd's log: refused, and told what to do" || fail "panel lock ssh, no proof: ${out}"
out=$(P 'zt_command tailscale lock ssh --yes --force' 2>&1); rc=$?
[[ $rc -ne 0 ]] && has_rule "22/tcp" && pass "panel: --force changes nothing" || fail "panel force: ${out}"
printf '%s\n' 'Nov 27 11:58:01 web1 sshd[811]: Accepted publickey for cipi from 198.51.100.7 port 50211 ssh2: ED25519 SHA256:abc' \
               'Nov 27 11:59:30 web1 sshd[812]: Failed password for root from 100.99.1.2 port 50212 ssh2' > "${TMP}/auth.log"
out=$(P 'zt_command tailscale lock ssh --yes' 2>&1); rc=$?
[[ $rc -ne 0 ]] && has_rule "22/tcp" && pass "panel: a login from the public address, or a failed one from the mesh, is no proof" || fail "panel lock ssh, wrong proof: ${out}"
printf '%s\n' '2026-11-27T12:00:01.123456+00:00 web1 sshd[900]: Accepted publickey for cipi from 100.99.1.2 port 50213 ssh2: ED25519 SHA256:abc' >> "${TMP}/auth.log"
j=$(P 'zt_command status --json --via=198.51.100.7' | jq -c .mesh)
jq -e '.ssh.seen == {"at":"2026-11-27T12:00:01","from":"100.99.1.2"} and .panel.via == "public" and .panel.from == "198.51.100.7"
       and .panel.blocked.lock_ssh == null and (.panel.blocked.lock_http | test("public address")) and .panel.blocked.disable == null' <<< "$j" >/dev/null \
    && pass "panel: the status says who came in over the mesh, how the panel reaches the server, and what it may not do" || fail "panel status: ${j}"
date -u -d '+40 days' '+%Y-%m-%dT%H:%M:%SZ' > "${STATE}/ts.expiry"
out=$(P 'zt_command tailscale lock ssh --yes --force' 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q 'node key of this machine expires' <<< "$out" && has_rule "22/tcp" && pass "panel: a node key that can expire stops lock ssh, --force or not" || fail "panel expiry: ${out}"
rm -f "${STATE}/ts.expiry"
echo true > "${STATE}/ts.ssh"
out=$(P 'zt_command tailscale lock ssh --yes' 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q "not in sshd's log" <<< "$out" && has_rule "22/tcp" && pass "panel: with Tailscale SSH on, sshd's log proves nothing — locked at the shell" || fail "panel tailscale ssh: ${out}"
echo false > "${STATE}/ts.ssh"
out=$(P 'zt_command tailscale lock ssh --yes' 2>&1); rc=$?
[[ $rc -eq 0 ]] && ! has_rule "22/tcp" && [[ "$(mst | jq -r .lock_ssh)" == true ]] && pass "panel: lock ssh once sshd has accepted a login over the mesh" || fail "panel lock ssh: ${out}"
out=$(P 'zt_command tailscale unlock ssh' 2>&1); rc=$?
[[ $rc -eq 0 ]] && has_rule "22/tcp" && pass "panel: unlock ssh" || fail "panel unlock ssh: ${out}"
# lock http: never the panel's own way in
for via in '' '--via=198.51.100.7' '--via=nonsense'; do
    out=$(P "zt_command tailscale lock http --yes ${via}" 2>&1); rc=$?
    [[ $rc -ne 0 ]] && grep -q "reaches this server's API on its public address" <<< "$out" && has_rule "443/tcp" && pass "panel: lock http ${via:-with no address} — refused, it would cut the panel off" || fail "panel lock http ${via}: ${out}"
done
for via in 100.99.1.2 127.0.0.1 203.0.113.5; do
    out=$(P "zt_command tailscale lock http --yes --via=${via}" 2>&1); rc=$?
    [[ $rc -eq 0 ]] && ! has_rule "443/tcp" && pass "panel: lock http from ${via} (over the mesh, or on this server)" || fail "panel lock http via ${via}: ${out}"
    P 'zt_command tailscale unlock http' >/dev/null 2>&1; has_rule "443/tcp" || fail "panel unlock http"
done
# The panel on this very server: its API is safe, the page of whoever looks at it on the public address is not.
out=$(P 'zt_command tailscale lock http --yes --via=127.0.0.1 --client=198.51.100.7' 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q "using this panel on the server's public address (from 198.51.100.7)" <<< "$out" && grep -q '100.101.102.103' <<< "$out" && has_rule "443/tcp" \
    && pass "panel on this server: lock http from a browser on the public address — refused, the page would close itself" || fail "panel local, browser public: ${out}"
out=$(P 'zt_command tailscale lock http --yes --force --via=203.0.113.5 --client=nonsense' 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q "using this panel on the server's public address" <<< "$out" && has_rule "443/tcp" && pass "panel on this server: an address that is not one is no proof either, --force or not" || fail "panel local, browser nonsense: ${out}"
j=$(P 'zt_command status --json --via=127.0.0.1 --client=198.51.100.7' | jq -c .mesh.panel)
jq -e '.via == "local" and .client == {"via":"public","from":"198.51.100.7"} and (.blocked.lock_http | test("public address")) and .blocked.disable == null' <<< "$j" >/dev/null \
    && pass "panel on this server: the status says where the browser comes from, and why 80/443 stay open" || fail "panel client status: ${j}"
[[ "$(P 'zt_command status --json --via=127.0.0.1' | jq -c '.mesh.panel | [.client, .blocked.lock_http]')" == '[null,null]' ]] && pass "panel on this server: no browser address given (a script on the server) — nothing more is asked" || fail "panel client none"
for client in 100.99.1.2 127.0.0.1; do
    out=$(P "zt_command tailscale lock http --yes --via=127.0.0.1 --client=${client}" 2>&1); rc=$?
    [[ $rc -eq 0 ]] && ! has_rule "443/tcp" && pass "panel on this server: lock http from a browser at ${client} (over the mesh, or on the server)" || fail "panel local, browser ${client}: ${out}"
    P 'zt_command tailscale unlock http' >/dev/null 2>&1; has_rule "443/tcp" || fail "panel unlock http (client)"
done
out=$(P 'zt_command tailscale lock http --yes --via=100.99.1.2 --client=198.51.100.7' 2>&1); rc=$?
[[ $rc -eq 0 ]] && ! has_rule "443/tcp" && pass "a panel on another server, over the mesh: where its user sits does not matter" || fail "panel remote, browser public: ${out}"
P 'zt_command tailscale unlock http' >/dev/null 2>&1
Z 'echo "{\"enabled\":true,\"gui\":{\"domain\":\"panel.example.com\"}}" | vault_write zt.json' >/dev/null
out=$(P 'zt_command tailscale lock http --yes --via=127.0.0.1 --client=198.51.100.7' 2>&1); rc=$?
[[ $rc -eq 0 ]] && ! has_rule "443/tcp" && [[ "$(P 'zt_command status --json --via=127.0.0.1 --client=198.51.100.7' | jq -r .mesh.panel.client.via)" == tunnel ]] \
    && pass "panel on this server, its hostname on the Cloudflare tunnel: the page comes through the tunnel, lock http goes" || fail "panel local, gui on tunnel: ${out}"
P 'zt_command tailscale unlock http' >/dev/null 2>&1
Z 'echo "{}" | vault_write zt.json' >/dev/null
Z 'echo "{\"enabled\":true,\"api\":{\"domain\":\"api.example.com\"}}" | vault_write zt.json' >/dev/null
out=$(P 'zt_command tailscale lock http --yes --via=198.51.100.7' 2>&1); rc=$?
[[ $rc -eq 0 ]] && ! has_rule "443/tcp" && pass "panel: lock http when the API's hostname is on the Cloudflare tunnel" || fail "panel lock http tunnel: ${out}"
P 'zt_command tailscale unlock http' >/dev/null 2>&1
Z 'echo "{}" | vault_write zt.json' >/dev/null
mkdir -p "${LE}/shop.example.com"
out=$(P 'zt_command tailscale lock http --yes --force --via=100.99.1.2' 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q 'HTTP-01' <<< "$out" && has_rule "443/tcp" && pass "panel: an app on HTTP-01 stops lock http, --force or not" || fail "panel http01: ${out}"
[[ "$(P 'zt_command tailscale status --json --via=100.99.1.2' | jq -c '[.http01_apps, .panel.via]')" == '[["shop"],"mesh"]' ]] && pass "panel: the status names the apps on HTTP-01" || fail "panel http01 json"
rmdir "${LE}/shop.example.com"
# Tailscale SSH and leaving the network
out=$(P 'zt_command tailscale ssh enable' 2>&1); rc=$?
[[ $rc -eq 0 ]] && [[ "$(cat "${STATE}/ts.ssh")" == true ]] && pass "panel: Tailscale SSH on" || fail "panel ssh enable: ${out}"
out=$(P 'zt_command tailscale ssh disable' 2>&1); rc=$?
[[ $rc -eq 0 ]] && [[ "$(cat "${STATE}/ts.ssh")" == false ]] && pass "panel: Tailscale SSH off" || fail "panel ssh disable: ${out}"
out=$(P 'zt_command tailscale disable --yes --via=100.99.1.2' 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q 'leaving the network would cut it off' <<< "$out" && [[ -x "${BIN}/tailscale" ]] && pass "panel: disable over the mesh — refused, the panel would lose the server" || fail "panel disable via mesh: ${out}"
out=$(P 'zt_command tailscale disable --yes --via=198.51.100.7' 2>&1); rc=$?
[[ $rc -eq 0 && ! -x "${BIN}/tailscale" ]] && [[ "$(mst | jq -r .enabled)" == false ]] && pass "panel: disable from the public address" || fail "panel disable: ${out}"
out=$(P 'zt_command netbird enable --adopt' 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q 'Nothing to adopt: NetBird is not connected' <<< "$out" && [[ ! -x "${BIN}/netbird" ]] && pass "panel: enable --adopt with no client connected — refused, nothing installed" || fail "panel adopt, nothing there: ${out}"
out=$(P 'zt_command netbird enable --setup-key=NBP1' 2>&1); rc=$?
[[ $rc -eq 0 ]] && has_rule "Anywhere on wt0" && pass "panel: netbird enable" || fail "panel nb enable: ${out}"
out=$(P 'zt_command netbird enable --adopt' 2>&1); rc=$?
[[ $rc -eq 0 ]] && grep -q 'connected already' <<< "$out" && [[ "$(mst | jq -r .provider)" == netbird ]] && pass "panel: enable --adopt on a connected client — taken as it is" || fail "panel adopt: ${out}"
out=$(P 'zt_command netbird disable --yes' 2>&1); rc=$?
[[ $rc -eq 0 && ! -x "${BIN}/netbird" ]] && pass "panel: netbird disable with no address given (the panel is not over the mesh)" || fail "panel nb disable: ${out}"
rm -f "${TMP}/auth.log"
# The sudoers: each command spelled out, '*' only last (sudo-rs), nothing of Cloudflare's side.
S="${LIB}/cipi-api-sudoers.sh"
for c in 'zt tailscale enable \*' 'zt tailscale disable --yes' 'zt tailscale lock ssh --yes' 'zt tailscale lock http --yes \*' 'zt tailscale unlock ssh' 'zt tailscale unlock http' \
         'zt tailscale ssh enable' 'zt tailscale ssh disable' 'zt netbird enable \*' 'zt netbird disable --yes \*' 'zt netbird lock ssh --yes' 'zt netbird lock http --yes' 'zt netbird unlock http'; do
    grep -qE "^ +/usr/local/bin/cipi ${c}, \\\\$" "$S" || fail "sudoers: no '${c}'"
done
pass "the panel's sudoers: join, leave, the locks and their unlocks, Tailscale SSH — each spelled out"
! grep -E '^ +/usr/local/bin/cipi zt ' "$S" | grep -vE 'zt (status|tailscale|netbird)' | grep -q . && ! grep -qE 'cipi zt (tailscale|netbird) \*' "$S" && ! grep -q 'zt netbird ssh' "$S" \
    && pass "…nothing of Cloudflare's side but its status, no catch-all, no NetBird SSH" || fail "sudoers: too wide"
! grep -E '^ +/usr/local/bin/cipi zt ' "$S" | grep -qE '\* [^,]|\*[^,]' && pass "…'*' only as the last token (sudo-rs)" || fail "sudoers: a star in the middle"

# ── monitor ──────────────────────────────────────────────────
M() { env "${ENVV[@]}" bash -c 'set -euo pipefail; RED=""; GREEN=""; YELLOW=""; CYAN=""; DIM=""; NC=""; BOLD=""
      source "$CIPI_LIB/common.sh"; source "$CIPI_LIB/monitor.sh"; '"$1" < /dev/null; }
[[ "$(M '_mon_check_mesh' | jq -r .summary)" == "no mesh network" ]] && pass "monitor mesh: ok while no mesh is on" || fail "mon off: $(M '_mon_check_mesh')"
rm -f "${STATE}"/ts.*; reset_fw; SESSION="100.99.1.2"
Z 'zt_command tailscale enable --auth-key=tskey-auth-k2' >/dev/null 2>&1
r=$(M '_mon_check_mesh'); [[ "$(jq -r .status <<< "$r")" == ok && "$(jq -r .summary <<< "$r")" == "Tailscale connected (100.101.102.103, 2/3 peers online)" ]] && pass "…connected → ok" || fail "mon ok: ${r}"
date -u -d '+5 days' '+%Y-%m-%dT%H:%M:%SZ' > "${STATE}/ts.expiry"
r=$(M '_mon_check_mesh'); [[ "$(jq -r .status <<< "$r")" == warn ]] && grep -q 'expires in [45] day' <<< "$(jq -r .summary <<< "$r")" && pass "…node key expiring within 14 days → warn" || fail "mon expiry: ${r}"
date -u -d '-1 day' '+%Y-%m-%dT%H:%M:%SZ' > "${STATE}/ts.expiry"
[[ "$(M '_mon_check_mesh' | jq -r .status)" == crit ]] && pass "…node key expired → crit" || fail "mon expired"
rm -f "${STATE}/ts.expiry"; touch "${STATE}/ts.offline"
[[ "$(M '_mon_check_mesh' | jq -r .status)" == warn ]] && pass "…coordination server not reachable → warn" || fail "mon offline"
rm -f "${STATE}/ts.offline"
Z 'zt_command tailscale lock ssh --yes' >/dev/null 2>&1
echo NeedsLogin > "${STATE}/ts.state"
r=$(M '_mon_check_mesh'); [[ "$(jq -r .status <<< "$r")" == crit ]] && grep -q "off the network (NeedsLogin) — with port 22 closed" <<< "$(jq -r .summary <<< "$r")" && pass "…off the network with SSH locked → crit, and it says what that means" || fail "mon needslogin: ${r}"
echo Running > "${STATE}/ts.state"; rm -f "${STATE}/unit.tailscaled"
r=$(M '_mon_check_mesh'); [[ "$(jq -r .status <<< "$r")" == crit ]] && grep -q 'tailscaled is not running' <<< "$(jq -r .summary <<< "$r")" && pass "…tailscaled stopped → crit" || fail "mon stopped: ${r}"
touch "${STATE}/unit.tailscaled"
M '_mon_catalog' | grep -qx 'mesh|Mesh network' && M '_mon_catalog' | grep -qx 'tunnel|Cloudflare Tunnel' && pass "mesh in the monitor catalog, after tunnel" || fail "catalog"
[[ "$(M '_mon_settable_keys mesh')" == "days" && "$(M '_mon_default_config' | jq -c .checks.mesh)" == '{"enabled":true,"days":14}' ]] && pass "its threshold: days (14)" || fail "mon keys"
grep -q '^monitor_mesh|Monitor|' "${LIB}/notifications.sh" && grep -q 'monitor_tunnel monitor_mesh' "${LIB}/notifications.sh" && pass "monitor_mesh: a trigger, and urgent" || fail "trigger"

# ── Cloudflare's rules numbered below ten ────────────────────
printf '22/tcp|ALLOW IN|Anywhere|\n80/tcp|ALLOW IN|173.245.48.0/20|cipi-zt-http\n443/tcp|ALLOW IN|173.245.48.0/20|cipi-zt-http\n80/tcp|ALLOW IN|103.21.244.0/22|cipi-zt-http\n' > "${STATE}/ufw.rules"
Z '_zt_ufw_delete_comment cipi-zt-http' >/dev/null 2>&1
[[ "$(rules)" == '22/tcp|ALLOW IN|Anywhere|' ]] && pass "_zt_ufw_delete_comment removes rules [ 2] to [ 4] (they stayed: the number is padded)" || fail "single digit: $(rules)"

# ── the panel stays read-only; help; completion ──────────────
grep -q '/usr/local/bin/cipi zt status \*' "${LIB}/cipi-api-sudoers.sh" && pass "the panel's sudoers still read the whole status" || fail "sudoers status"
grep -q '_help_cmd "cipi zt tailscale enable --auth-key="' "${ROOT}/cipi" && grep -q '_help_cmd "cipi zt netbird lock ssh \[--yes\]"' "${ROOT}/cipi" \
    && grep -q 'tailscale|netbird|mesh|zt|zerotrust|zero-trust|cloudflare|tunnel)' "${ROOT}/cipi" && pass "cipi help zt (and tailscale, netbird, mesh): the commands" || fail "help"
grep -q 'origin-cert tailscale netbird"' "${LIB}/completion.sh" && grep -q 'tailscale|netbird) sub="enable disable status ssh lock unlock"' "${LIB}/completion.sh" && pass "completion: the two providers and their commands" || fail "completion"
grep -q 'zt_lock_ssh|Security|SSH port closed (Cloudflare Tunnel or the mesh)' "${LIB}/notifications.sh" && pass "the zt_* notifications are both sides'" || fail "labels"

# ── a custom app with no repository: the Coming soon page ─────
# In the folder nginx serves (it was written to htdocs/ whatever --docroot, so
# an app on htdocs/www answered 404), one file with nothing fetched from
# anywhere, under a name that gives way to the site once it is uploaded.
A="${LIB}/app.sh"
bash -n "$A" && pass "app.sh parses" || fail "app.sh parse"
CS() { CIPI_LIB="$LIB" bash -c 'source "$1" 2>/dev/null; shift; "$@"' _ "$A" "$@"; }
page=$(CS _app_coming_soon_page shop.example.com)
[[ "$(head -1 <<< "$page")" == '<!doctype html>' && "$(tail -1 <<< "$page")" == '</html>' ]] && pass "coming soon: a whole HTML document" || fail "coming soon: not a document"
grep -q '<title>shop.example.com — Coming soon</title>' <<< "$page" && grep -q '<strong id="host">shop.example.com</strong>' <<< "$page" && ! grep -q '__DOMAIN__' <<< "$page" \
    && pass "coming soon: the domain in the title and in the page, no token left" || fail "coming soon: domain"
grep -q '<h1 id="title">Coming soon</h1>' <<< "$page" && grep -q 'name="robots" content="noindex, nofollow"' <<< "$page" && grep -q 'name="viewport"' <<< "$page" \
    && pass "coming soon: says so, is not indexed, fits a phone" || fail "coming soon: basics"
# Nothing leaves the page: no stylesheet, script, image, font or frame of another origin.
ext=$(grep -oE '(https?:)?//[A-Za-z0-9.-]+' <<< "$page" | sort -u | tr '\n' ' ')
[[ "$ext" == "http://www.w3.org " ]] && pass "coming soon: the only URL in it is the SVG namespace of its inline favicon (a name, never fetched)" || fail "coming soon: URLs in the page: ${ext}"
! grep -qiE '<link[^>]+rel="?stylesheet|@import|@font-face|url\(|<img|<iframe|<script[^>]+src=|<source|<video|<audio|<object|<embed|fetch\(|XMLHttpRequest|import\(' <<< "$page" \
    && pass "coming soon: no stylesheet, font, image, frame or script from outside" || fail "coming soon: an external resource"
[[ "$(grep -c '<link ' <<< "$page")" == 1 ]] && grep -q '<link rel="icon" href="data:image/svg+xml,' <<< "$page" && pass "coming soon: its one <link> is the favicon, inline" || fail "coming soon: link"
grep -q 'font: 400 1rem/1.5 ui-sans-serif, system-ui' <<< "$page" && pass "coming soon: the visitor's system font" || fail "coming soon: font"
grep -q 'prefers-color-scheme: dark' <<< "$page" && grep -q 'prefers-reduced-motion: reduce' <<< "$page" && pass "coming soon: light and dark, still for who asks for less motion" || fail "coming soon: media"
! grep -qi 'cipi' <<< "$page" && pass "coming soon: it carries no name but the site's" || fail "coming soon: names Cipi"
grep -q '<html lang="en">' <<< "$page" && ! grep -qE 'navigator\.language|In arrivo|documentElement\.lang' <<< "$page" && pass "coming soon: in English, whatever the visitor's language" || fail "coming soon: it changes language"
[[ $(printf '%s' "$page" | wc -c) -lt 8192 ]] && pass "coming soon: under 8 KB" || fail "coming soon: $(printf '%s' "$page" | wc -c) bytes"
if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$page" | python3 -c '
import sys
from html.parser import HTMLParser
VOID = {"meta", "link", "br", "hr", "img", "input", "circle", "ellipse", "path", "rect"}
class P(HTMLParser):
    def __init__(self): super().__init__(); self.stack = []; self.bad = []
    def handle_starttag(self, tag, attrs):
        if tag not in VOID: self.stack.append(tag)
    def handle_startendtag(self, tag, attrs): pass
    def handle_endtag(self, tag):
        if not self.stack or self.stack.pop() != tag: self.bad.append(tag)
p = P(); p.feed(sys.stdin.read())
sys.exit(1 if p.bad or p.stack else 0)' && pass "coming soon: every tag is closed" || fail "coming soon: unbalanced tags"
fi
[[ "$(CS _app_coming_soon_page '*.tenants.example.com' | grep -c 'id="host">\*.tenants.example.com<')" == 1 ]] && pass "coming soon: a wildcard domain is written as it is (the page then shows the host it was asked for)" || fail "coming soon: wildcard"
# The docroot: a folder inside htdocs, nothing else.
for pair in '/|' '.|' '|' 'www|www' '/www/|www' 'web//public/|web/public' 'public_html|public_html' 'a.b/c-d|a.b/c-d'; do
    in="${pair%%|*}"; want="${pair#*|}"
    got=$(CS _app_docroot_clean "$in") && [[ "$got" == "$want" ]] && pass "docroot '${in}' → '${want}'" || fail "docroot '${in}': '${got}'"
done
for bad in '..' '../x' 'www/../..' '.git' 'a b' 'a;b' 'x/.ssh' '$(id)'; do
    CS _app_docroot_clean "$bad" >/dev/null && fail "docroot '${bad}' accepted" || pass "docroot '${bad}' refused"
done
grep -q 'docroot=$(_app_docroot_clean "$docroot") || {' "$A" && pass "app create checks the docroot before anything is created" || fail "create: docroot not checked"
H="${TMP}/home/testwp"; mkdir -p "$H"
CS _app_coming_soon_install "$H" "www" "testwp.example.dev" && [[ -f "${H}/htdocs/www/coming-soon.html" && ! -e "${H}/htdocs/index.html" && ! -e "${H}/htdocs/coming-soon.html" ]] \
    && [[ "$(stat -c %a "${H}/htdocs/www/coming-soon.html")" == 644 ]] && grep -q 'testwp.example.dev' "${H}/htdocs/www/coming-soon.html" \
    && pass "docroot www: the page is in htdocs/www, where nginx serves from — and nowhere else" || fail "install, docroot www: $(find "$H" -type f | tr '\n' ' ')"
H2="${TMP}/home/plain"; mkdir -p "$H2"
CS _app_coming_soon_install "$H2" "" "plain.example.dev" && [[ -f "${H2}/htdocs/coming-soon.html" ]] && [[ "$(find "$H2" -type f | wc -l)" == 1 ]] && pass "docroot /: the page is in htdocs" || fail "install, docroot /"
CS _app_coming_soon_install "$H2" "web/public" "plain.example.dev" && [[ -f "${H2}/htdocs/web/public/coming-soon.html" ]] && pass "a docroot two folders deep is created whole" || fail "install, nested docroot"
grep -q '_app_coming_soon_install "$home" "$docroot" "$domain"' "$A" && ! grep -q 'htdocs/index.html' "$A" && ! grep -q 'is currently being deployed' "$A" \
    && pass "app create installs it for an app with no repository; the page that was written to htdocs/ is gone" || fail "create: where the page goes"
grep -q 'index index.html index.php ${APP_COMING_SOON_FILE};' "$A" && [[ "$(CIPI_LIB="$LIB" bash -c 'source "$1" 2>/dev/null; echo "$APP_COMING_SOON_FILE"' _ "$A")" == "coming-soon.html" ]] \
    && pass "nginx: the page is the last choice of the index — an index.html or index.php uploaded takes its place" || fail "nginx: index"
[[ "$(grep -c 'index index.html index.php' "$A")" == 1 ]] && pass "only the custom vhost changed" || fail "another vhost has that index line"
CIPI_LIB="$LIB" bash -c 'source "$1" 2>/dev/null; source "$1" 2>/dev/null; echo ok' _ "$A" | grep -q ok && pass "app.sh loaded twice: the page's name is not declared twice" || fail "app.sh loaded twice"
grep -q 'Coming soon page' "${ROOT}/CHANGELOG.md" && pass "CHANGELOG says it" || fail "CHANGELOG: coming soon"

# ── the build step of a deploy: a time limit of its own ───────
echo "--- deploy: build timeout"
DPL="${LIB}/deployer"
for f in "${LIB}/common.sh" "${LIB}/sync.sh" "${LIB}/migrations/5.18.0.sh"; do
    bash -n "$f" && pass "$(basename "$f") parses" || fail "$(basename "$f") parse"
done
bt_block() {   # <recipe> [seconds]: the block, with the number an app is given (1800 unless it says otherwise)
    sed -n '/^\/\/ cipi:build-timeout /,/^\/\/ cipi:build-timeout end$/p' "$1" | sed "s|__CIPI_BUILD_TIMEOUT__|${2:-1800}|g"
}
bt_helper() { sed -n "/^set('cipi_build_timeout'/,/^}\$/p" "$1"; }
ok=1
for t in laravel laravel-octane node; do
    [[ "$(grep -c '^// cipi:build-timeout ' "${DPL}/${t}.php")" == 2 && "$(bt_block "${DPL}/${t}.php" | tail -n 1)" == "// cipi:build-timeout end" ]] || { ok=0; fail "${t}.php: no build-timeout block"; }
    [[ "$(bt_helper "${DPL}/${t}.php")" == "$(bt_helper "${DPL}/laravel.php")" && -n "$(bt_helper "${DPL}/${t}.php")" ]] || { ok=0; fail "${t}.php: its cipi_build_run is not the one of laravel.php"; }
done
[[ $ok == 1 ]] && pass "the three release recipes have the block, with one and the same cipi_build_run" || true
[[ "$(bt_block "${DPL}/laravel.php")" == "$(bt_block "${DPL}/laravel-octane.php")" ]] && pass "Laravel and Octane: the same block" || fail "the Octane block differs"
grep -q "^set('cipi_build_timeout', __CIPI_BUILD_TIMEOUT__);" "${DPL}/laravel.php" && grep -q "^set('default_timeout', __CIPI_STEP_TIMEOUT__);" "${DPL}/laravel.php" \
    && [[ "$(CIPI_LIB="$LIB" bash -c 'source "$CIPI_LIB/common.sh" 2>/dev/null; deploy_timeout_bounds build; deploy_timeout_bounds step')" == $'1800 60 3600\n300 60 1800' ]] \
    && pass "the build gets 30 minutes and every other command 5, unless the app says otherwise (60-3600, 60-1800 seconds)" || fail "the two clocks and their bounds"
! grep -hE "^[[:space:]]+run\(.*(node-build\.sh|npm (ci|install)|pnpm install|yarn install|bun install)" "${DPL}/laravel.php" "${DPL}/laravel-octane.php" "${DPL}/node.php" | grep -q . \
    && [[ "$(grep -c '^[[:space:]]*cipi_build_run(' "${DPL}/node.php")" == 6 && "$(grep -c '^[[:space:]]*cipi_build_run(' "${DPL}/laravel.php")" == 1 ]] \
    && pass "no install and no build is left on Deployer's 300 seconds (Laravel: node_build; Node: the five installs and the build)" || fail "a build command still runs through run()"
# PHP 7.4 parses deploy.php on a server that kept Deployer 7: no named argument.
! { bt_block "${DPL}/laravel.php"; bt_block "${DPL}/laravel-octane.php"; bt_block "${DPL}/node.php"; } | grep -qE '\b(timeout|idleTimeout|idle_timeout): ' \
    && pass "no named argument (timeout: …): a deploy.php read by PHP 7.4 under Deployer 7 still parses" || fail "named argument in the block"
! grep -q 'cipi_build_run\|cipi:build-timeout' "${DPL}/custom.php" && pass "the classic recipe builds nothing: untouched" || fail "custom.php"

bt_recipe() {   # <app> <template>: deploy.php as Cipi writes it today
    sed -e "s|__CIPI_APP_USER__|$1|g" -e "s|__CIPI_DEPLOY_PATH__|/home/$1|g" -e "s|__CIPI_PHP_VERSION__|8.5|g" \
        -e "s|__CIPI_REPOSITORY__|git@github.com:acme/$1.git|g" -e "s|__CIPI_BRANCH__|main|g" -e "s|__CIPI_KEEP_RELEASES__|5|g" \
        -e "s|__CIPI_SHARED_FILES__|['.env']|g" -e "s|__CIPI_HOOK_STORAGE_LINK__|after('deploy:vendors', 'artisan:storage:link');|g" \
        -e "s|__CIPI_HOOK_MIGRATE__|after('deploy:vendors', 'artisan:migrate');|g" -e "s|__CIPI_HOOK_OPTIMIZE__|after('deploy:vendors', 'artisan:optimize');|g" \
        -e "s|__CIPI_HOOK_HORIZON_TERMINATE__|before('deploy:symlink', 'horizon:terminate');|g" \
        -e "s|__CIPI_HOOK_QUEUE_RESTART__|after('deploy:symlink', 'artisan:queue:restart');|g" \
        -e "s|__CIPI_HOOK_EXTRA_ARTISAN__|// no extra artisan (deploy-config)|g" -e "/__CIPI_EXTRA_ARTISAN_TASK__/d" \
        -e "s|__CIPI_NODE_VERSION__|22|g" -e "s|__CIPI_NODE_MODE__|spa|g" -e "s|__CIPI_NODE_OUTPUT__|dist|g" \
        -e "s|__CIPI_BUILD_TIMEOUT__|1800|g" -e "s|__CIPI_STEP_TIMEOUT__|300|g" "${DPL}/$2.php"
}
bt_before() {   # <app> <template>: the same recipe as it was written before 5.18.0
    bt_recipe "$1" "$2" | sed -e '/^\/\/ cipi:build-timeout end$/d' -e '/^\/\/ cipi:build-timeout /,/^}$/d' -e 's/cipi_build_run(/run(/' \
        -e '/^\/\/ Seconds a command of the deploy may run/,/^set(.default_timeout., /d' | cat -s
}
BT="${TMP}/bt"; mkdir -p "$BT/cfg"
for a in shop blog front static hand twice early closed fresh handnode; do mkdir -p "$BT/home/$a/.deployer"; done
printf '%s\n' '{"shop":{"php":"8.5"},"blog":{"php":"8.5","octane":"frankenphp"},"front":{"php":"8.5","custom":true,"runtime":"node","node_build":"npm run build"},
  "static":{"php":"8.5","custom":true},"hand":{"php":"8.5"},"twice":{"php":"8.5"},"early":{"php":"8.5"},"closed":{"php":"8.5"},"fresh":{"php":"8.5"},
  "handnode":{"php":"8.5","custom":true,"runtime":"node","node_build":"npm run build"}}' > "$BT/cfg/apps.json"
OLD_BUILD="    run('test ! -x {{deploy_path}}/.deployer/node-build.sh || {{deploy_path}}/.deployer/node-build.sh {{release_path}}');"
bt_before shop laravel > "$BT/home/shop/.deployer/deploy.php"
bt_before blog laravel-octane > "$BT/home/blog/.deployer/deploy.php"
bt_before front node > "$BT/home/front/.deployer/deploy.php"
cp "${DPL}/custom.php" "$BT/home/static/.deployer/deploy.php"
bt_before hand laravel | sed "s#^    run('test ! -x .*#    run('cd {{release_path}} \&\& npm ci \&\& npm run build', ['timeout' => 900]);#" > "$BT/home/hand/.deployer/deploy.php"
{ bt_before twice laravel; printf "task('cipi:node_build', function () {\n    run('cd {{release_path}} && make assets');\n});\n"; } > "$BT/home/twice/.deployer/deploy.php"
bt_before early laravel | sed -e "/^\/\/ Optional frontend build/,/^});\$/d" -e "/'cipi:node_build'/d" > "$BT/home/early/.deployer/deploy.php"
{ bt_before closed laravel; echo '?>'; } > "$BT/home/closed/.deployer/deploy.php"
bt_recipe fresh laravel > "$BT/home/fresh/.deployer/deploy.php"
bt_before handnode node | sed "s#'npm ci --no-audit --no-fund'#'npm ci --no-audit --no-fund --legacy-peer-deps'#" > "$BT/home/handnode/.deployer/deploy.php"
# The recipes "before" are the ones on the servers: the command of the report, word for word.
grep -qxF -- "$OLD_BUILD" "$BT/home/shop/.deployer/deploy.php" && ! grep -q 'cipi_build_run\|cipi:build-timeout' "$BT/home/shop/.deployer/deploy.php" \
    && pass "a recipe from before: the build is a plain run(), on Deployer's 300 seconds" || fail "the recipe 'before' is not the one on the servers"
grep -qxF -- "        run(\$cd . 'npm ci --no-audit --no-fund');" "$BT/home/front/.deployer/deploy.php" \
    && grep -qxF -- "    run('{{cipi_node_env}} NODE_ENV=production && {{deploy_path}}/.deployer/node-build.sh {{release_path}}');" "$BT/home/front/.deployer/deploy.php" \
    && pass "…and so are the install and the build of a Node app" || fail "the Node recipe 'before'"
for a in shop blog front static hand twice early closed fresh handnode; do md5sum < "$BT/home/$a/.deployer/deploy.php" > "$BT/$a.sum"; done
same() { [[ "$(md5sum < "$BT/home/$1/.deployer/deploy.php")" == "$(cat "$BT/$1.sum")" ]]; }
BTH() {
    CIPI_LIB="$LIB" CIPI_CONFIG="$BT/cfg" CIPI_LOG="$BT/log" D1="$BT" bash -c 'set -uo pipefail
        RED=; GREEN=; YELLOW=; CYAN=; DIM=; NC=; BOLD=
        source "$CIPI_LIB/common.sh" 2>/dev/null
        vault_read() { cat "$D1/cfg/apps.json"; }
        app_read() { cat -- "${2/#\/home\//$D1/home/}" 2>/dev/null; }
        app_append() { cat >> "${2/#\/home\//$D1/home/}"; }
        eval "$(declare -f deployer_build_timeout_ensure_hook | sed "s|\[\[ -f \"\$df\" \]\]|[[ -f \"\${df/#\\\\/home\\\\//\$D1/home/}\" ]]|")"
        deployer_build_timeout_ensure_hook "$1"; echo "rc=$?"' _ "$1"
}
out=$(BTH shop)
[[ "$out" == "rc=0" ]] && [[ "$(grep -c '^// cipi:build-timeout ' "$BT/home/shop/.deployer/deploy.php")" == 2 ]] \
    && [[ "$(tail -n 4 "$BT/home/shop/.deployer/deploy.php" | head -n 1)" == "task('cipi:node_build', function () {" && "$(tail -n 1 "$BT/home/shop/.deployer/deploy.php")" == "// cipi:build-timeout end" ]] \
    && pass "a Laravel recipe from before gets the block: the build task again, last, with the limit" || fail "shop: ${out}"
[[ "$(sed -n '/^\/\/ cipi:build-timeout /,$p' "$BT/home/shop/.deployer/deploy.php")" == "$(bt_block "${DPL}/laravel.php")" ]] && grep -qxF -- "$OLD_BUILD" "$BT/home/shop/.deployer/deploy.php" \
    && pass "…word for word the block of today's recipe, appended: nothing that was there is rewritten" || fail "shop: what was appended"
out=$(BTH shop); [[ "$out" == "rc=0" && "$(grep -c '^// cipi:build-timeout ' "$BT/home/shop/.deployer/deploy.php")" == 2 ]] && pass "a second run adds nothing" || fail "shop twice: ${out}"
out=$(BTH blog); [[ "$out" == "rc=0" ]] && grep -q "^    cipi_build_run('test ! -x" "$BT/home/blog/.deployer/deploy.php" && pass "an Octane recipe too" || fail "blog: ${out}"
out=$(BTH front)
[[ "$out" == "rc=0" ]] && [[ "$(grep -c "^task('node:install'," "$BT/home/front/.deployer/deploy.php")" == 2 && "$(grep -c "^task('node:build'," "$BT/home/front/.deployer/deploy.php")" == 2 ]] \
    && [[ "$(grep -c '^[[:space:]]*cipi_build_run(' "$BT/home/front/.deployer/deploy.php")" == 6 ]] \
    && pass "a Node app (custom, with a runtime): its install and its build again, with the limit" || fail "front: ${out}"
out=$(BTH static); [[ "$out" == "rc=0" ]] && same static && pass "a classic app builds nothing: left alone (0)" || fail "static: ${out}"
out=$(BTH hand); [[ "$out" == "rc=2" ]] && same hand && pass "a build task edited by hand is left as it is (2): defining it again would undo the edit" || fail "hand: ${out}"
out=$(BTH twice); [[ "$out" == "rc=2" ]] && same twice && pass "a build task the file defines again is left as it is (2)" || fail "twice: ${out}"
out=$(BTH handnode); [[ "$out" == "rc=2" ]] && same handnode && pass "a Node install edited by hand: left as it is (2)" || fail "handnode: ${out}"
out=$(BTH early); [[ "$out" == "rc=0" ]] && same early && pass "a recipe from before the build task has nothing to give more time to (0)" || fail "early: ${out}"
out=$(BTH closed); [[ "$out" == "rc=1" ]] && same closed && pass "a deploy.php closed with ?> is not appended to (1)" || fail "closed: ${out}"
out=$(BTH fresh); [[ "$out" == "rc=0" ]] && same fresh && pass "a recipe written today has the block: nothing to add" || fail "fresh: ${out}"
grep -q 'deployer_build_timeout_ensure_hook "$app"' "${LIB}/sync.sh" && grep -q 'deployer_build_timeout_ensure_hook "$u"' "${LIB}/migrations/5.18.0.sh" \
    && pass "the hook runs for an app restored by cipi sync, and in the migration" || fail "hook call sites"

# What a deploy does with it. A Deployer of a few lines: the config of the host
# and the tasks by name — the last definition of a name is the one that runs.
if command -v php >/dev/null 2>&1; then
    for a in shop blog front fresh; do php -l "$BT/home/$a/.deployer/deploy.php" >/dev/null 2>&1 || fail "php -l: $a"; done
    pass "the recipes with the block are valid PHP"
    cat > "$BT/dep-stub.php" <<'PHPSTUB'
<?php
namespace Deployer;

final class Stub
{
    public static array $cfg = ['default_timeout' => 300];
    public static array $tasks = [];
    public static array $seen = [];
    public static string $lock = 'package-lock.json';
    public static ?string $fail = null;
}
final class Chain { public function __call($name, $args) { return $this; } }
function set($k, $v) { Stub::$cfg[$k] = $v; }
function get($k, $d = null) { return array_key_exists($k, Stub::$cfg) ? Stub::$cfg[$k] : $d; }
function add($k, $v) {}
function host(...$a) { return new Chain(); }
function after(...$a) {}
function before(...$a) {}
function desc(...$a) {}
function task($name, $body = null) { if (is_callable($body)) { Stub::$tasks[$name] = $body; } return new Chain(); }
function test($command) { return strpos($command, Stub::$lock) !== false; }
function writeln($line) {}
function run($command)
{
    Stub::$seen[] = var_export(get('default_timeout', 300), true);
    if (Stub::$fail !== null && strpos($command, Stub::$fail) !== false) {
        throw new \RuntimeException('exceeded the timeout');
    }
    return '';
}
function probe(string $label, array $tasks): void
{
    Stub::$seen = [];
    $threw = 'no';
    try {
        foreach ($tasks as $t) { (Stub::$tasks[$t])(); }
    } catch (\RuntimeException $e) {
        $threw = 'yes';
    }
    $build = implode(',', array_unique(Stub::$seen));
    $runs = count(Stub::$seen);
    // The step that comes after the build, whatever became of it.
    [$fail, Stub::$fail, Stub::$seen] = [Stub::$fail, null, []];
    run('php artisan migrate --force');
    Stub::$fail = $fail;
    printf("%s build=%s runs=%d threw=%s next=%s\n", $label, $build, $runs, $threw, Stub::$seen[0]);
}

[$file, $tasks] = [$argv[1], explode(',', $argv[2])];
require $file;
probe('default', $tasks);
Stub::$cfg['default_timeout'] = 0;    probe('zero', $tasks);
Stub::$cfg['default_timeout'] = null; probe('null', $tasks);
Stub::$cfg['default_timeout'] = 3600; probe('longer', $tasks);
Stub::$cfg['default_timeout'] = 300;  Stub::$cfg['cipi_build_timeout'] = 900; probe('own', $tasks);
Stub::$cfg['cipi_build_timeout'] = 1800; Stub::$fail = 'node-build.sh'; probe('failed', $tasks);
PHPSTUB
    dep_stub() {   # <app> <tasks>
        grep -v "^require 'recipe/" "$BT/home/$1/.deployer/deploy.php" > "$BT/$1.php"
        php "$BT/dep-stub.php" "$BT/$1.php" "$2" 2>&1
    }
    for a in shop blog fresh; do
        out=$(dep_stub "$a" cipi:node_build)
        grep -qx 'default build=1800 runs=1 threw=no next=300' <<< "$out" \
            && pass "${a}: the build runs with 1800 seconds, and the step after it with Deployer's 300 again" || fail "${a}: $(head -n 3 <<< "$out")"
    done
    out=$(dep_stub shop cipi:node_build)
    grep -qx 'zero build=0 runs=1 threw=no next=0' <<< "$out" && grep -qx 'null build=NULL runs=1 threw=no next=NULL' <<< "$out" \
        && pass "a default_timeout turned off (0, null) stays off: the build gets no limit it did not have" || fail "no limit: ${out}"
    grep -qx 'longer build=3600 runs=1 threw=no next=3600' <<< "$out" && pass "a default_timeout that is longer already is not shortened" || fail "longer: ${out}"
    grep -qx 'own build=900 runs=1 threw=no next=300' <<< "$out" && pass "cipi_build_timeout is the one number to change" || fail "own: ${out}"
    grep -qx 'failed build=1800 runs=1 threw=yes next=300' <<< "$out" \
        && pass "a build that fails (or does time out) leaves the 300 seconds in place for what runs after it" || fail "failed: ${out}"
    out=$(dep_stub front node:install,node:build)
    grep -qx 'default build=1800 runs=2 threw=no next=300' <<< "$out" && grep -qx 'failed build=1800 runs=2 threw=yes next=300' <<< "$out" \
        && pass "a Node app: npm ci and the build with 1800 seconds each, then 300 again" || fail "front: ${out}"
    # The function is declared once, however many times the block is there.
    { cat "$BT/shop.php"; bt_block "${DPL}/laravel.php"; } > "$BT/shop2.php"
    php "$BT/dep-stub.php" "$BT/shop2.php" cipi:node_build 2>&1 | grep -qx 'default build=1800 runs=1 threw=no next=300' \
        && pass "the block twice in one file is not a fatal error (cipi_build_run is declared once)" || fail "block twice"
else
    echo "  (php not installed: the block is not run)"
fi

# With the real Deployer, when it is on this machine: a command that outlasts
# default_timeout is stopped by run() and finishes through cipi_build_run().
DEP=""; for c in /usr/local/bin/dep "${CIPI_TEST_DEP:-}"; do [[ -n "$c" && -f "$c" ]] && DEP="$c" && break; done
if [[ -n "$DEP" ]] && command -v php >/dev/null 2>&1 && php "$DEP" --version >/dev/null 2>&1; then
    {
        printf '<?php\nnamespace Deployer;\nlocalhost();\nset("default_timeout", 2);\n'
        bt_helper "${DPL}/laravel.php" | sed "s/__CIPI_BUILD_TIMEOUT__/30/"
        printf '%s\n' "task('probe:build', function () { cipi_build_run('sleep 4'); writeln('after=' . get('default_timeout')); });" \
                      "task('probe:plain', function () { run('sleep 4'); writeln('not stopped'); });"
    } > "$BT/probe.php"
    out=$(cd "$BT" && php "$DEP" probe:build -f "$BT/probe.php" 2>&1); rc=$?
    [[ $rc -eq 0 ]] && grep -q 'after=2' <<< "$out" && pass "real Deployer: a build of 4 seconds under a default_timeout of 2 finishes, and the 2 seconds are back" || fail "real Deployer, build: rc=${rc} ${out}"
    out=$(cd "$BT" && php "$DEP" probe:plain -f "$BT/probe.php" 2>&1); rc=$?
    [[ $rc -ne 0 ]] && ! grep -q 'not stopped' <<< "$out" && pass "real Deployer: the same command through run() is stopped at the default" || fail "real Deployer, plain: rc=${rc} ${out}"
else
    echo "  (no Deployer on this machine: the limit is checked against the stub only)"
fi

# cipi deploy, when Deployer stops a step on its clock: said in plain words.
bash -n "${LIB}/deploy.sh" && pass "deploy.sh parses" || fail "deploy.sh parse"
DTN() {   # <app> <log>: what cipi deploy adds under "Deploy failed"
    CIPI_LIB="$LIB" CIPI_CONFIG="$BT/cfg" CIPI_LOG="$BT/log" D1="$BT" bash -c 'set -uo pipefail
        source "$CIPI_LIB/common.sh" 2>/dev/null
        RED=; GREEN=; YELLOW=; CYAN=; DIM=; NC=; BOLD=
        vault_read() { cat "$D1/cfg/apps.json"; }
        app_read() { cat -- "${2/#\/home\//$D1/home/}" 2>/dev/null; }
        eval "$(sed -n "/^_deploy_timeout_note() {/,/^}/p" "$CIPI_LIB/deploy.sh")"
        _deploy_timeout_note "$1" "$2"; echo "rc=$?"' _ "$1" "$2"
}
dlog() {   # <file> <step> <seconds> <command>: one failed run, as the deploy log has it
    {
        printf '[2026-11-27 14:05:02] ===== deploy start  app=x trigger=cli branch=main from-release=70 =====\n'
        printf '[2026-11-27 14:05:40] task deploy:vendors\n[2026-11-27 14:08:19] task %s\n' "$2"
        printf '[2026-11-27 14:13:19] [localhost] Deployer\\Exception\\TimeoutException in deploy.php on line 52:\n[2026-11-27 14:13:19] \n'
        printf '[2026-11-27 14:13:19]   The command "%s" exceeded the timeout of %s seconds.\n[2026-11-27 14:13:19] \n' "$4" "$3"
        printf '[2026-11-27 14:13:20] task deploy:failed\n[2026-11-27 14:13:20] task deploy:unlock\n'
    } >> "$1"
}
# The report: an app whose deploy.php is still the one from before (twice: defined again by hand, left alone by the hook).
dlog "$BT/twice.log" cipi:node_build 300 "test ! -x /home/twice/.deployer/node-build.sh || /home/twice/.deployer/node-build.sh /home/twice/releases/71"
out=$(DTN twice "$BT/twice.log")
grep -q '^\[WARN\] The build (cipi:node_build) was stopped at the 300 seconds Deployer gives any command' <<< "$out" && grep -q 'cipi app deploy-config twice --keep-releases=5' <<< "$out" && grep -qx 'rc=0' <<< "$out" \
    && pass "a build stopped at 300 seconds in a deploy.php without the limit: said, with the command that writes the recipe again" || fail "timeout note, old recipe: ${out}"
dlog "$BT/handnode.log" node:install 300 "export PATH=/opt/cipi/node/22/bin && cd /home/handnode/releases/3 && npm ci --no-audit --no-fund --legacy-peer-deps"
out=$(DTN handnode "$BT/handnode.log"); grep -q 'The build (node:install) was stopped at the 300 seconds' <<< "$out" && grep -q 'cipi app edit handnode --build="npm run build"' <<< "$out" \
    && pass "…for a Node app that command is cipi app edit --build" || fail "timeout note, node: ${out}"
dlog "$BT/shop.log" cipi:node_build 1800 "test ! -x /home/shop/.deployer/node-build.sh || /home/shop/.deployer/node-build.sh /home/shop/releases/9"
out=$(DTN shop "$BT/shop.log"); grep -q 'The build (cipi:node_build) was stopped after 30 minutes, the most it is given (cipi_build_timeout in deploy.php)' <<< "$out" && grep -q 'cipi deploy shop --log' <<< "$out" && ! grep -q 'deploy-config' <<< "$out" \
    && pass "a build that used its 30 minutes: said as that, with where to look" || fail "timeout note, 30 minutes: ${out}"
dlog "$BT/blog.log" artisan:migrate 300 "/usr/bin/php8.5 /home/blog/releases/4/artisan migrate --force"
out=$(DTN blog "$BT/blog.log"); grep -q 'The step artisan:migrate was stopped after 300 seconds, the most Deployer gives a command' <<< "$out" && ! grep -q 'The build (' <<< "$out" \
    && pass "another step (a migration) stopped at 300 seconds is named as what it is" || fail "timeout note, migrate: ${out}"
# The same log, then a run that failed for another reason: nothing to add to that one.
printf '%s\n' '[2026-11-27 15:00:00] ===== deploy start  app=x trigger=cli branch=main from-release=70 =====' '[2026-11-27 15:00:03] task deploy:update_code' \
    '[2026-11-27 15:00:04] fatal: Could not read from remote repository.' >> "$BT/blog.log"
out=$(DTN blog "$BT/blog.log"); [[ "$out" == "rc=0" ]] && pass "a run that failed for another reason gets no such line — an earlier run's timeout is not this one's" || fail "timeout note, another failure: ${out}"
out=$(DTN shop "$BT/none.log"); [[ "$out" == "rc=0" ]] && pass "no log, no line" || fail "timeout note, no log: ${out}"
grep -q '_deploy_timeout_note "$app" "$lf"' "${LIB}/deploy.sh" && pass "cipi deploy says it right under \"Deploy failed\"" || fail "deploy.sh does not call the note"

echo "--- migration 5.18.0"
MG="${TMP}/mig"; mkdir -p "$MG/cfg" "$MG/lib/migrations" "$MG/bin" "$MG/log"
for a in shop blog front static hand handnode; do mkdir -p "$MG/home/$a/.deployer"; done
printf '%s\n' '{"shop":{"php":"8.5","keep_releases":"3"},"blog":{"php":"8.5","octane":"frankenphp"},"front":{"php":"8.5","custom":true,"runtime":"node","node_build":"npm run build"},
  "static":{"php":"8.5","custom":true},"hand":{"php":"8.5"},"handnode":{"php":"8.5","custom":true,"runtime":"node","node_build":"pnpm build"}}' > "$MG/cfg/apps.json"
bt_before shop laravel > "$MG/home/shop/.deployer/deploy.php"
bt_before blog laravel-octane > "$MG/home/blog/.deployer/deploy.php"
bt_before front node > "$MG/home/front/.deployer/deploy.php"
cp "${DPL}/custom.php" "$MG/home/static/.deployer/deploy.php"
cp "$BT/home/hand/.deployer/deploy.php" "$MG/home/hand/.deployer/deploy.php"
cp "$BT/home/handnode/.deployer/deploy.php" "$MG/home/handnode/.deployer/deploy.php"
for f in "${LIB}"/*.sh; do sed -e "s#/home/#${MG}/home/#g" "$f" > "$MG/lib/$(basename "$f")"; done
cp -r "${LIB}/deployer" "$MG/lib/"
sed -e "s#/home/#${MG}/home/#g" "${LIB}/migrations/5.18.0.sh" > "$MG/lib/migrations/5.18.0.sh"
cat > "$MG/bin/sudo" <<'EOF'
#!/bin/bash
while [ $# -gt 0 ] && [ "$1" != "--" ] && [ "${1#-}" != "$1" ]; do [ "$1" = "-u" ] && shift; shift; done
[ "$1" = "--" ] && shift
exec "$@"
EOF
cat > "$MG/bin/id" <<'EOF'
#!/bin/bash
case "$1" in -u) echo 0 ;; -un|-gn|-nG) echo root ;; *) exit 0 ;; esac
EOF
cat > "$MG/bin/install" <<'EOF'
#!/bin/bash
a=(); skip=
for x in "$@"; do case "$x" in -o|-g) skip=1 ;; *) if [ -n "$skip" ]; then skip=; else a+=("$x"); fi ;; esac; done
exec /usr/bin/install "${a[@]}"
EOF
chmod +x "$MG/bin/sudo" "$MG/bin/id" "$MG/bin/install"
head -c 32 /dev/urandom | base64 > "$MG/cfg/.vault_key"
mig518() { PATH="$MG/bin:$PATH" CIPI_LIB="$MG/lib" CIPI_CONFIG="$MG/cfg" CIPI_LOG="$MG/log" bash "$MG/lib/migrations/5.18.0.sh" 2>&1; }
out=$(mig518); rc=$?
[[ $rc -eq 0 ]] && grep -q 'Migration 5.18.0 complete' <<< "$out" && pass "the migration runs" || fail "migration: rc=${rc} ${out}"
grep -q 'cipi:build-timeout' "$MG/home/shop/.deployer/deploy.php" && grep -q 'cipi:build-timeout' "$MG/home/blog/.deployer/deploy.php" && grep -q 'cipi:build-timeout' "$MG/home/front/.deployer/deploy.php" \
    && grep -q '3 app(s) give the build step 30 minutes instead of 300 seconds' <<< "$out" && pass "…Laravel, Octane and Node recipes get the block, and it is said" || fail "migration block: ${out}"
! grep -q 'cipi:build-timeout' "$MG/home/static/.deployer/deploy.php" && ! grep -q 'static' <<< "$out" && pass "…a classic app is not touched and not named" || fail "migration static: ${out}"
grep -q 'hand: deploy.php was edited by hand' <<< "$out" && ! grep -q 'cipi:build-timeout' "$MG/home/hand/.deployer/deploy.php" && grep -q 'cipi app deploy-config hand --keep-releases=5' <<< "$out" \
    && pass "…a build task edited by hand is left as it is, with the command that writes the recipe again" || fail "migration hand: ${out}"
grep -q 'handnode: deploy.php was edited by hand' <<< "$out" && grep -q 'cipi app edit handnode --build="pnpm build"' <<< "$out" \
    && pass "…for a Node app that command is cipi app edit --build (deploy-config is not for it)" || fail "migration handnode: ${out}"
out2=$(mig518); grep -q 'deploy.php: nothing to change' <<< "$out2" && ! grep -q 'app(s) give' <<< "$out2" && grep -q 'hand: deploy.php was edited by hand' <<< "$out2" \
    && pass "a second run changes nothing (and names the ones edited by hand again)" || fail "migration twice: ${out2}"
grep -q 'exceeded the timeout' "${ROOT}/CHANGELOG.md" && grep -q 'cipi_build_timeout\|30 minutes' "${ROOT}/CHANGELOG.md" && pass "CHANGELOG says it" || fail "CHANGELOG: build timeout"

# ── the two clocks, per app: cipi app deploy-config, cipi.yml ──
echo "--- deploy-config: --build-timeout, --step-timeout"
DCD="${TMP}/dc"; mkdir -p "$DCD/cfg" "$DCD/lib" "$DCD/log"
for a in shop front static early; do mkdir -p "$DCD/home/$a/.deployer"; done
printf '%s\n' '{"shop":{"php":"8.5","repository":"git@github.com:acme/shop.git","branch":"main"},
  "front":{"php":"8.5","custom":true,"runtime":"node","node_build":"npm run build","node_mode":"spa","node_version":"22","node_output":"dist","repository":"git@github.com:acme/front.git","branch":"main"},
  "static":{"php":"8.5","custom":true},"early":{"php":"8.5","deploy_build_timeout":"2400"}}' > "$DCD/cfg/apps.json"
for f in "${LIB}"/*.sh; do sed -e "s#/home/#${DCD}/home/#g" "$f" > "$DCD/lib/$(basename "$f")"; done
cp -r "${LIB}/deployer" "$DCD/lib/"
head -c 32 /dev/urandom | base64 > "$DCD/cfg/.vault_key"
DC() {   # a function of app.sh / common.sh / yml.sh, as cipi would call it
    PATH="$MG/bin:$PATH" CIPI_LIB="$DCD/lib" CIPI_CONFIG="$DCD/cfg" CIPI_LOG="$DCD/log" bash -c 'set -uo pipefail
        source "$CIPI_LIB/common.sh"; source "$CIPI_LIB/app.sh"; source "$CIPI_LIB/yml.sh"
        RED=; GREEN=; YELLOW=; CYAN=; DIM=; NC=; BOLD=
        cipi_notify() { :; }
        yml_act() { _YML_APP="$1"; _yml_apply_action "$2"; }
        ( "$@" ); echo "rc=$?"' _ "$@" 2>&1
}
dcjson() { sed -n '/^{/,/^}/p' <<< "$1"; }
recipe() { cat "$DCD/home/$1/.deployer/deploy.php" 2>/dev/null; }
stored() { DC vault_read apps.json | sed '$d' | jq -c --arg a "$1" '.[$a] | {deploy_build_timeout, deploy_step_timeout}'; }
out=$(DC app_deploy_config shop --json)
[[ "$(dcjson "$out" | jq -c '[.build_timeout, .step_timeout]')" == "[1800,300]" ]] && pass "an app that says nothing: 1800 seconds for the build, 300 for every other command" || fail "defaults: ${out}"
out=$(DC app_deploy_config shop --build-timeout=2700 --step-timeout=600 --json)
[[ "$(dcjson "$out" | jq -c '[.build_timeout, .step_timeout]')" == "[2700,600]" ]] && grep -qx "rc=0" <<< "$out" \
    && recipe shop | grep -qx "set('cipi_build_timeout', 2700);" && recipe shop | grep -qx "set('default_timeout', 600);" \
    && pass "--build-timeout=2700 --step-timeout=600: kept, shown, and in the recipe that is written again" || fail "set: ${out}"
[[ "$(stored shop)" == '{"deploy_build_timeout":"2700","deploy_step_timeout":"600"}' ]] && pass "…stored with the app" || fail "stored: $(stored shop)"
if command -v php >/dev/null 2>&1; then
    grep -v "^require 'recipe/" "$DCD/home/shop/.deployer/deploy.php" | sed '/^task(.deploy., array_values/,$d' > "$BT/shop-dc.php"
    php "$BT/dep-stub.php" "$BT/shop-dc.php" cipi:node_build 2>&1 | grep -qx 'default build=2700 runs=1 threw=no next=600' \
        && pass "…and a deploy runs the build with 2700 seconds and the step after it with 600" || fail "the recipe with its own clocks: $(php "$BT/dep-stub.php" "$BT/shop-dc.php" cipi:node_build 2>&1 | head -n 2)"
fi
for bad in 30 3601 abc "" 12.5 -5 "1800; id"; do
    out=$(DC app_deploy_config shop "--build-timeout=${bad}")
    grep -q '\[ERROR\] --build-timeout is a number of seconds from 60 to 3600 (1800 unless set)' <<< "$out" && grep -qx "rc=1" <<< "$out" || fail "--build-timeout='${bad}' not refused: ${out}"
done
pass "--build-timeout: 30, 3601, a word, nothing, a fraction, a negative, a command — each refused with the bounds"
out=$(DC app_deploy_config shop --keep-releases=9 --step-timeout=5000)
grep -q -- '--step-timeout is a number of seconds from 60 to 1800 (300 unless set)' <<< "$out" && [[ "$(stored shop)" == '{"deploy_build_timeout":"2700","deploy_step_timeout":"600"}' ]] \
    && [[ "$(DC app_get shop keep_releases | sed '$d')" == "" ]] \
    && pass "a number out of bounds is refused before anything is written (the --keep-releases next to it too)" || fail "refused value: ${out} / $(stored shop)"
out=$(DC app_deploy_config shop --build-timeout=1800 --step-timeout=300 --json)
[[ "$(stored shop)" == '{"deploy_build_timeout":null,"deploy_step_timeout":null}' ]] && recipe shop | grep -qx "set('cipi_build_timeout', 1800);" && recipe shop | grep -qx "set('default_timeout', 300);" \
    && pass "the default, asked for by its number, is stored as nothing" || fail "back to the default: $(stored shop)"
out=$(DC app_deploy_config front --build-timeout=900 --json)
[[ "$(dcjson "$out" | jq -c '.')" == '{"app":"front","runtime":"node","keep_releases":5,"predeploy_snapshot":false,"build_timeout":900,"step_timeout":300}' ]] \
    && recipe front | grep -qx "set('cipi_build_timeout', 900);" && [[ "$(recipe front | grep -c '^[[:space:]]*cipi_build_run(')" == 6 ]] \
    && pass "a Node app takes them too: its install and its build get the 900 seconds" || fail "node: ${out}"
out=$(DC app_deploy_config front --no-migrate)
grep -q "is a Node app: its recipe has no artisan hooks" <<< "$out" && grep -qx "rc=1" <<< "$out" && pass "…and is told what it does not take (the artisan hooks)" || fail "node, artisan flag: ${out}"
out=$(DC app_deploy_config static --build-timeout=900)
grep -q "Custom apps have no zero-downtime deploy.php recipe" <<< "$out" && pass "a classic app has no recipe to give a clock to" || fail "static: ${out}"
# An app with a number of its own whose deploy.php is from before: the hook writes that number.
bt_before early laravel > "$DCD/home/early/.deployer/deploy.php"
out=$(DC deployer_build_timeout_ensure_hook early)
grep -qx "rc=0" <<< "$out" && recipe early | grep -qx "set('cipi_build_timeout', 2400);" && ! recipe early | grep -q '__CIPI_' \
    && [[ "$(recipe early | sed -n '/^\/\/ cipi:build-timeout /,$p')" == "$(bt_block "${DPL}/laravel.php" 2400)" ]] \
    && pass "the hook gives a deploy.php from before the number of its app" || fail "hook, own number: ${out}"

echo "--- cipi.yml: deploy.build_timeout, deploy.step_timeout"
sed -n "/<<'CIPIYAMLPY'$/,/^CIPIYAMLPY$/p" "${LIB}/yml.sh" | sed '1d;$d' > "${TMP}/yamlval.py"
yv() { printf 'version: 1\ndeploy:\n%s\n' "$1" > "${TMP}/t.yml"; python3 "${TMP}/yamlval.py" "${TMP}/t.yml" shop; }
r=$(yv $'  build_timeout: 2400\n  step_timeout: 900')
[[ "$(jq -c '[.ok, .data.deploy.build_timeout, .data.deploy.step_timeout]' <<< "$r")" == "[true,2400,900]" ]] && pass "the validator takes both, as whole seconds" || fail "yml valid: ${r}"
r=$(yv $'  keep_releases: 5'); [[ "$(jq -c '.data.deploy | has("build_timeout") or has("step_timeout")' <<< "$r")" == "false" ]] && pass "…and a file that does not name them does not carry them (nothing to reconcile)" || fail "yml absent: ${r}"
for case in "build_timeout: 59|deploy.build_timeout" "build_timeout: 3601|deploy.build_timeout" 'build_timeout: "1800"|deploy.build_timeout' "step_timeout: 1801|deploy.step_timeout" "step_timeout: 2.5|deploy.step_timeout" "step_timeout: true|deploy.step_timeout"; do
    r=$(yv "  ${case%%|*}"); [[ "$(jq -r .ok <<< "$r")" == "false" ]] && jq -r '.errors[]' <<< "$r" | grep -qF "${case##*|}" || fail "yml accepts '${case%%|*}': ${r}"
done
pass "out of bounds, a string, a fraction, a boolean: refused by name (60-3600 and 60-1800)"
out=$(DC yml_act shop "deploy-cfg|build_timeout=2400;step_timeout=900|deploy config")
grep -qx "rc=0" <<< "$out" && [[ "$(stored shop)" == '{"deploy_build_timeout":"2400","deploy_step_timeout":"900"}' ]] && recipe shop | grep -qx "set('cipi_build_timeout', 2400);" && recipe shop | grep -qx "set('default_timeout', 900);" \
    && pass "apply: the app takes the numbers of the file and its recipe is written again" || fail "yml apply: ${out} $(stored shop)"
out=$(DC yml_act front "deploy-cfg|keep_releases=3;build_timeout=1200|deploy config")
grep -qx "rc=0" <<< "$out" && recipe front | grep -qx "set('cipi_build_timeout', 1200);" && recipe front | grep -qx "set('keep_releases', 3);" && pass "apply, a Node app: the same" || fail "yml apply node: ${out}"
grep -q 'for dc_f in build step; do' "${LIB}/yml.sh" && grep -q 'dc_cur=$(_yml_deploy_timeout "$app" "$dc_f")' "${LIB}/yml.sh" \
    && grep -q 'only deploy.keep_releases, deploy.build_timeout, deploy.step_timeout and deploy.predeploy_snapshot apply' "${LIB}/yml.sh" \
    && pass "plan: each is a change only when the file's number is not the app's; a Node app may declare them" || fail "yml plan"
grep -q 'echo "  build_timeout: $(_yml_deploy_timeout "$app" build)"' "${LIB}/yml.sh" && grep -q '# build_timeout: 1800' "${LIB}/yml.sh" && pass "cipi yml init writes them; the commented example names them" || fail "yml export"
grep -q -- '--build-timeout=S' "${ROOT}/cipi" && pass "cipi help app names the flags" || fail "help"

# ── cipi app create --db=NAME: a database made with a custom or a Node app ──
echo "--- app create: --db"
DBC() {   # INSTALLED="mariadb pgsql" EXISTING="names on the server" ARG_engine=… DBC <function> <args…>
    PATH="$MG/bin:$PATH" CIPI_LIB="$DCD/lib" CIPI_CONFIG="$DCD/cfg" CIPI_LOG="$DCD/log" INSTALLED="${INSTALLED:-mariadb}" EXISTING="${EXISTING:-}" WANT_ENGINE="${WANT_ENGINE-}" \
    bash -c 'set -uo pipefail
        source "$CIPI_LIB/common.sh"; source "$CIPI_LIB/db.sh"; source "$CIPI_LIB/app.sh"
        RED=; GREEN=; YELLOW=; CYAN=; DIM=; NC=; BOLD=
        cipi_notify() { :; }
        db_ensure_engine_state() { :; }
        db_engine_is_installed() { [[ " $INSTALLED " == *" $1 "* ]]; }
        db_get_default_engine() { echo mariadb; }
        db_require_engine() { db_engine_is_installed "$1" && { echo "$1"; return 0; }; error "$(db_engine_label "$1") is not installed"; return 1; }
        db_database_exists() { [[ " $EXISTING " == *" $2 "* ]]; }
        db_create_database() { echo "CREATE engine=$1 name=$2 user=$3 pass_chars=${#4}"; }
        [[ -n "$WANT_ENGINE" ]] && ARG_engine="$WANT_ENGINE"
        ( "$@"; rc=$?; pw="${APP_CREATE_DB_PASS:-}"; echo "engine=${APP_CREATE_DB_ENGINE:-} pass_chars=${#pw}"; exit $rc ) 2>&1; echo "rc=$?"' _ "$@"
}
vjson() { DBC vault_read "$1" | sed '/^engine=/,$d'; }   # a vault file, as JSON
out=$(DBC _app_create_db_check custom blog wpblog)
grep -qx 'engine=mariadb pass_chars=0' <<< "$out" && grep -qx 'rc=0' <<< "$out" && pass "a custom app and a name: the server's default engine" || fail "--db: ${out}"
out=$(DBC _app_create_db_check node front frontdb); grep -qx 'rc=0' <<< "$out" && pass "a Node app takes one too" || fail "--db node: ${out}"
out=$(INSTALLED="mariadb pgsql" WANT_ENGINE=pgsql DBC _app_create_db_check custom blog wpblog); grep -qx 'engine=pgsql pass_chars=0' <<< "$out" && pass "--engine=pgsql: there" || fail "--db --engine: ${out}"
out=$(WANT_ENGINE=pgsql DBC _app_create_db_check custom blog wpblog); grep -qx 'rc=1' <<< "$out" && grep -q 'not installed' <<< "$out" && pass "…refused where that engine is not installed" || fail "--db, engine missing: ${out}"
out=$(WANT_ENGINE=oracle DBC _app_create_db_check custom blog wpblog); grep -qx 'rc=1' <<< "$out" && grep -q 'Invalid engine' <<< "$out" && pass "…and for an engine Cipi does not know" || fail "--db, engine unknown: ${out}"
out=$(DBC _app_create_db_check laravel shop extra)
grep -qx 'rc=1' <<< "$out" && grep -q "a Laravel app is created with its own database, named 'shop'" <<< "$out" && grep -q 'cipi db create --name=extra --app=shop' <<< "$out" \
    && pass "a Laravel app has its own database: --db is refused, with the command for one more" || fail "--db laravel: ${out}"
ok=1; for bad in WP 1abc a bad-name 'x; id' "$(printf 'a%.0s' $(seq 65))"; do
    out=$(DBC _app_create_db_check custom blog "$bad"); grep -qx 'rc=1' <<< "$out" && grep -q 'Invalid database name' <<< "$out" || { ok=0; fail "--db='${bad}' accepted: ${out}"; }
done; [[ $ok == 1 ]] && pass "a name that is not a database name is refused (upper case, a digit first, one letter, a dash, a command, 65 letters)"
out=$(EXISTING="wpblog" DBC _app_create_db_check custom blog wpblog)
grep -qx 'rc=1' <<< "$out" && grep -q "Database 'wpblog' already exists" <<< "$out" && grep -q 'cipi db link wpblog blog' <<< "$out" \
    && pass "a database that is on the server already is not taken over: refused, with how to link it" || fail "--db existing: ${out}"
out=$(DBC _app_create_db_make wpblog mariadb)
grep -qx 'CREATE engine=mariadb name=wpblog user=wpblog pass_chars=40' <<< "$out" && grep -qx 'engine= pass_chars=40' <<< "$out" && grep -qx 'rc=0' <<< "$out" \
    && [[ "$(vjson databases.json | jq -c '.mariadb.wpblog.user')" == '"wpblog"' ]] \
    && pass "the database is made with a user of its name and a 40-character password, and recorded like one of cipi db create" || fail "make: ${out}"
out=$(DBC _app_create_db_check custom blog wpblog); grep -qx 'rc=1' <<< "$out" && grep -q 'already exists' <<< "$out" && pass "…so a second app cannot ask for the same name" || fail "--db recorded: ${out}"
DBC _db_link_set static mariadb wpblog >/dev/null
[[ "$(vjson apps.json | jq -c '.static.databases')" == '[{"name":"wpblog","engine":"mariadb"}]' ]] \
    && pass "linked: one line in the app's entry (cipi db list, cipi app show and the panel read it)" || fail "link"
A="${LIB}/app.sh"
# The whole function: its heredocs hold a "}" in the first column, so it ends at the next function.
body=$(awk '/^app_create\(\) \{/ { on = 1; print; next } on && /^[a-z_]+\(\) \{/ { exit } on { print }' "$A")
chk=$(grep -n '_app_create_db_check "$app_type" "$app_user" "$db_new" || exit 1' <<< "$body" | cut -d: -f1)
mk=$(grep -n '_app_create_db_make "$db_new" "$db_new_engine"' <<< "$body" | cut -d: -f1)
usr=$(grep -n 'useradd' <<< "$body" | head -n 1 | cut -d: -f1)
lnk=$(grep -n '_db_link_set "$app_user" "$db_new_engine" "$db_new"' <<< "$body" | cut -d: -f1)
sav=$(grep -n 'app_save "$app_user"' <<< "$body" | tail -n 1 | cut -d: -f1)
[[ -n "$chk" && -n "$mk" && -n "$usr" && -n "$lnk" && -n "$sav" ]] && (( chk < usr && usr < mk && sav < lnk )) \
    && pass "app create: checked before the user is created, made with the app, linked once the app is saved" || fail "app create order: check=${chk} user=${usr} make=${mk} save=${sav} link=${lnk}"
grep -q '\[\[ "$db_new" == "true" \]\] && db_new="$app_user"' <<< "$body" && grep -q 'elif \[\[ "$app_type" != "laravel" && -t 0 \]\]; then' <<< "$body" && grep -q '"${ARG_no_db:-}" != "true"' <<< "$body" \
    && pass "--db alone: the app's name; no flag: asked at a terminal only, and never of a Laravel app; --no-db: not asked" || fail "app create: flag and question"
line=$(grep -F 'echo -e "  ${BOLD}Database${NC}    ${CYAN}${db_new}${NC} / ${CYAN}${db_new_pass}${NC}' <<< "$body")
[[ -n "$line" ]] && [[ "$(printf '  Database    wpblog / s3cr3tPASS  (MariaDB)\n' | grep -cE 'Database[[:space:]]+[^[:space:]]+[[:space:]]*/[[:space:]]*[^[:space:]]+')" == 1 ]] \
    && pass "the summary says name and password on the line the API reads for an app's database" || fail "summary line"
grep -q -- '--db=NAME (custom and Node apps)' "${ROOT}/cipi" && grep -q -- '--db=NAME' "${ROOT}/CHANGELOG.md" && pass "help and CHANGELOG say it" || fail "help / CHANGELOG: --db"

# ── cipi sync for the panel: check, trust/untrust, push without a terminal ──
echo "--- sync: check, untrust, push --auto-passphrase"
bash -n "${LIB}/sync.sh" && pass "sync.sh parses" || fail "sync.sh parse"
SYD="${TMP}/sy"; mkdir -p "$SYD/bin" "$SYD/remote" "$DCD/home/cipi/.ssh"
# Three ed25519 public keys, written as OpenSSH writes them (the type, then 32 bytes): no ssh-keygen needed to make them.
mkpub() { printf 'ssh-ed25519 %s %s\n' "$( { printf '\0\0\0\013ssh-ed25519\0\0\0\040'; head -c 32 /dev/urandom; } | base64 -w 0)" "$1"; }
: > "$DCD/home/cipi/.ssh/id_ed25519"
mkpub "cipi@source" > "$DCD/home/cipi/.ssh/id_ed25519.pub"; mkpub "cipi@other" > "$SYD/other.pub"; mkpub "ops@laptop" > "$SYD/ops.pub"
# Where OpenSSH is not installed (a build machine), an ssh-keygen that reads a public key the same way.
if ! command -v ssh-keygen >/dev/null 2>&1; then
    cat > "$SYD/bin/ssh-keygen" <<'EOF'
#!/bin/bash
read -r t b _ || exit 255
[[ "$t" == ssh-ed25519 ]] || exit 255
[[ "$(printf '%s' "$b" | base64 -d 2>/dev/null | head -c 15 | tail -c 11)" == "ssh-ed25519" && "$(printf '%s' "$b" | base64 -d 2>/dev/null | wc -c)" == 51 ]] || exit 255
echo "256 SHA256:test (ED25519)"
EOF
    chmod +x "$SYD/bin/ssh-keygen"
fi
# ssh: the target, as far as push and check ask. REMOTE_STATE: ok | denied | down | nocipi; REMOTE_VER.
cat > "$SYD/bin/ssh" <<'EOF'
#!/bin/bash
echo "ssh $*" >> "$SYD/ssh.log"
cmd="${@: -1}"
case "${REMOTE_STATE:-ok}" in
    denied) echo "cipi@203.0.113.9: Permission denied (publickey,password)." >&2; exit 255 ;;
    down)   echo "ssh: connect to host 203.0.113.9 port 22: Connection timed out" >&2; exit 255 ;;
esac
case "$cmd" in
    "echo ok") echo ok ;;
    "sudo cipi version"*) [[ "${REMOTE_STATE:-ok}" == nocipi ]] && exit 127; echo "Cipi v${REMOTE_VER:-5.18.0}" ;;
    "sudo cipi sync import "*)
        printf '%s\n' "$cmd" > "$SYD/import.cmd"
        if [[ "$cmd" == *"--passphrase-stdin"* ]]; then IFS= read -r pw; printf '%s' "$pw" > "$SYD/import.stdin"; fi
        exit "${REMOTE_IMPORT_RC:-0}" ;;
    "rm -f "*) echo "$cmd" > "$SYD/remote.rm" ;;
esac
exit 0
EOF
cat > "$SYD/bin/rsync" <<'EOF'
#!/bin/bash
src="${@: -2:1}"; cp -- "$src" "$SYD/remote/$(basename "$src")"
EOF
chmod +x "$SYD/bin/ssh" "$SYD/bin/rsync"
SY() {   # a function of sync.sh, with nobody at the terminal
    PATH="$SYD/bin:$MG/bin:$PATH" SYD="$SYD" CIPI_LIB="$DCD/lib" CIPI_CONFIG="$DCD/cfg" CIPI_LOG="$DCD/log" REMOTE_STATE="${REMOTE_STATE:-ok}" REMOTE_VER="${REMOTE_VER:-5.18.0}" \
    REMOTE_IMPORT_RC="${REMOTE_IMPORT_RC:-0}" SUDO_USER="${AS:-}" bash -c 'set -uo pipefail
        source "$CIPI_LIB/common.sh"; source "$CIPI_LIB/sync.sh"
        RED=; GREEN=; YELLOW=; CYAN=; DIM=; NC=; BOLD=
        cipi_notify() { :; }
        chown() { :; }
        # The export: an archive encrypted with the passphrase it was given, as the real one makes it.
        _sync_export() {
            local a pw=""; for a in "$@"; do [[ "$a" == --passphrase=* ]] && pw="${a#--passphrase=}"; done
            printf "%s\n" "$*" | sed "s/--passphrase=.*/--passphrase=<given>/" > "$SYD/export.args"
            _SYNC_LAST_ARCHIVE="$SYD/cipi-sync-test.tar.gz.enc"
            echo "apps of the source" | CIPI_SYNC_PASSPHRASE="$pw" openssl enc -aes-256-cbc -salt -pbkdf2 -pass env:CIPI_SYNC_PASSPHRASE -out "$_SYNC_LAST_ARCHIVE"
        }
        ( "$@" ) 2>&1 < /dev/null; echo "rc=$?"' _ "$@"
}
out=$(SY _sync_valid_target 203.0.113.9 22 cipi; SY _sync_valid_target fra1.example.com 2222 cipi; SY _sync_valid_target 2001:db8::1 22 cipi)
[[ "$(grep -c '^rc=0$' <<< "$out")" == 3 ]] && pass "a target: an IPv4 or IPv6 address or a hostname, a port, a user" || fail "valid target: ${out}"
ok=1; for bad in "host;id 22 cipi" "-oProxyCommand=x 22 cipi" "a b 22 cipi" "h.example 0 cipi" "h.example 70000 cipi" "h.example 22 root;id" "h.example 22 -l"; do
    # shellcheck disable=SC2086
    out=$(SY _sync_valid_target $bad); grep -qx 'rc=1' <<< "$out" || { ok=0; fail "target accepted: ${bad}"; }
done; [[ $ok == 1 ]] && pass "…and nothing that would be an option or a second command on ssh's line"
if true; then
    KEY_SRC=$(cat "$DCD/home/cipi/.ssh/id_ed25519.pub"); KEY_OTHER=$(cat "$SYD/other.pub"); KEY_OPS=$(cat "$SYD/ops.pub")
    out=$(SY sync_command pubkey --raw); [[ "$(sed '$d' <<< "$out")" == "$KEY_SRC" ]] && pass "pubkey --raw: the key and nothing else" || fail "pubkey --raw: ${out}"
    out=$(SY sync_command check --host=203.0.113.9 --json)
    [[ "$(sed '$d' <<< "$out" | jq -c '[.ok, .cipi, .auto_passphrase, .reason]')" == '[true,"5.18.0",true,null]' ]] && grep -qx 'rc=0' <<< "$out" && pass "check: the key is accepted and Cipi answers — its version, and that it takes a passphrase on standard input" || fail "check ok: ${out}"
    out=$(REMOTE_VER=5.17.0 SY sync_command check --host=203.0.113.9 --json); [[ "$(sed '$d' <<< "$out" | jq -c '[.ok, .cipi, .auto_passphrase]')" == '[true,"5.17.0",false]' ]] && pass "check: an older target is reachable, without the one-time passphrase" || fail "check old: ${out}"
    out=$(REMOTE_STATE=denied SY sync_command check --host=203.0.113.9 --json); [[ "$(sed '$d' <<< "$out" | jq -r '.reason')" == "not-trusted" ]] && grep -qx 'rc=1' <<< "$out" && grep -q 'cipi sync trust' <<< "$out" && pass "check: a target that does not trust the key says so, with what to do there" || fail "check denied: ${out}"
    out=$(REMOTE_STATE=down SY sync_command check --host=203.0.113.9 --json); [[ "$(sed '$d' <<< "$out" | jq -r '.reason')" == "unreachable" ]] && pass "check: a target that does not answer" || fail "check down: ${out}"
    out=$(REMOTE_STATE=nocipi SY sync_command check --host=203.0.113.9 --json); [[ "$(sed '$d' <<< "$out" | jq -r '.reason')" == "no-cipi" ]] && pass "check: a server without Cipi" || fail "check nocipi: ${out}"
    grep -q -- '-o BatchMode=yes' "$SYD/ssh.log" && ! grep -q -- ' -t ' "$SYD/ssh.log" && pass "check never asks for a password and never needs a terminal" || fail "check: ssh options"
    # trust and untrust
    AK="$DCD/home/cipi/.ssh/authorized_keys"; printf '%s\n' "$KEY_OPS" > "$AK"
    out=$(SY sync_command trust "--key=${KEY_OTHER}"); grep -qxF -- "$KEY_OTHER" "$AK" && grep -qxF -- "$KEY_OPS" "$AK" && pass "trust --key=: the key is added, without a question" || fail "trust: ${out}"
    out=$(SY sync_command trust "--key=${KEY_OTHER}"); [[ "$(grep -cF -- "$KEY_OTHER" "$AK")" == 1 ]] && pass "…once" || fail "trust twice: ${out}"
    out=$(SY sync_command trust "--key=ssh-ed25519 AAAAnotakey x"); grep -qx 'rc=1' <<< "$out" && [[ "$(wc -l < "$AK")" == 2 ]] && pass "…and what ssh-keygen cannot read is not a key" || fail "trust garbage: ${out}"
    out=$(SY sync_command trust "--key=${KEY_OTHER}"$'\n''command="id" ssh-ed25519 AAAA x'); grep -qx 'rc=1' <<< "$out" && ! grep -q 'command=' "$AK" && pass "…nor is a key with a second line behind it" || fail "trust two lines: ${out}"
    out=$(SY sync_command untrust "--key=$(awk '{print $1, $2}' <<< "$KEY_OTHER") another-comment")
    grep -qx 'rc=0' <<< "$out" && ! grep -qF -- "$(awk '{print $2}' <<< "$KEY_OTHER")" "$AK" && grep -qxF -- "$KEY_OPS" "$AK" && [[ "$(wc -l < "$AK")" == 1 ]] \
        && pass "untrust --key=: that key is gone (whatever its comment), the others stay" || fail "untrust: ${out} / $(cat "$AK")"
    out=$(SY sync_command untrust "--key=${KEY_OTHER}"); grep -qx 'rc=0' <<< "$out" && grep -q 'nothing to remove' <<< "$out" && pass "…and a key that is not there is nothing to remove" || fail "untrust twice: ${out}"
    # push, with nobody to ask
    out=$(AS=www-data SY sync_command push shop --import --auto-passphrase); grep -qx 'rc=1' <<< "$out" && grep -q -- 'Target server required: --host=' <<< "$out" && pass "push without a terminal asks nothing: no --host, said" || fail "push no host: ${out}"
    out=$(AS=www-data SY sync_command push shop --host=203.0.113.9 --import); grep -qx 'rc=1' <<< "$out" && grep -q -- 'A passphrase is needed' <<< "$out" && pass "…no passphrase, said" || fail "push no passphrase: ${out}"
    out=$(AS=www-data SY sync_command push shop --host=203.0.113.9 --auto-passphrase); grep -qx 'rc=1' <<< "$out" && grep -q -- '--auto-passphrase goes with --import' <<< "$out" && pass "--auto-passphrase without --import is refused: nobody would know the passphrase" || fail "push auto no import: ${out}"
    out=$(AS=www-data SY sync_command push nosuchapp --host=203.0.113.9 --import --auto-passphrase); grep -qx 'rc=1' <<< "$out" && grep -q "App 'nosuchapp' not found" <<< "$out" && pass "an app that is not there is refused before anything is sent" || fail "push unknown app: ${out}"
    out=$(AS=www-data REMOTE_STATE=denied SY sync_command push shop --host=203.0.113.9 --import --auto-passphrase); grep -qx 'rc=1' <<< "$out" && grep -q 'cipi sync trust' <<< "$out" && ! grep -q 'Trying with password' <<< "$out" && pass "a target that does not trust the key: no password is tried, the command ends" || fail "push denied: ${out}"
    out=$(AS=www-data REMOTE_VER=5.17.0 SY sync_command push shop --host=203.0.113.9 --import --auto-passphrase); grep -qx 'rc=1' <<< "$out" && grep -q -- '--auto-passphrase needs Cipi 5.18.0+ on the target' <<< "$out" && [[ ! -f "$SYD/remote/cipi-sync-test.tar.gz.enc" ]] \
        && pass "an older target is refused before the export: its import would take the passphrase as a flag" || fail "push old target: ${out}"
    rm -f "$SYD/import.cmd" "$SYD/import.stdin" "$SYD/ssh.log"
    out=$(AS=www-data SY sync_command push shop --host=203.0.113.9 --port=2222 --import --auto-passphrase --with-db --with-storage)
    pw=$(cat "$SYD/import.stdin" 2>/dev/null || true)
    grep -qx 'rc=0' <<< "$out" && [[ ${#pw} == 48 ]] && grep -qx 'sudo cipi sync import /tmp/cipi-sync-test.tar.gz.enc --yes --update shop --passphrase-stdin' "$SYD/import.cmd" \
        && pass "push --import --auto-passphrase: exported, sent, imported on the target — the passphrase on the import's standard input" || fail "push: ${out} / $(cat "$SYD/import.cmd" 2>/dev/null)"
    [[ "$(CIPI_SYNC_PASSPHRASE="$pw" openssl enc -d -aes-256-cbc -pbkdf2 -pass env:CIPI_SYNC_PASSPHRASE -in "$SYD/remote/cipi-sync-test.tar.gz.enc" 2>/dev/null)" == "apps of the source" ]] \
        && pass "…and it is the one the archive that arrived was encrypted with" || fail "the passphrase does not open the archive"
    ! grep -qF -- "$pw" <<< "$out" && ! grep -qF -- "$pw" "$SYD/ssh.log" "$SYD/import.cmd" "$SYD/export.args" "$DCD/log/"* 2>/dev/null && pass "it is in no output, no command line and no log" || fail "the passphrase leaked"
    grep -q -- '--with-db --with-storage' "$SYD/export.args" && grep -q -- '-p 2222' "$SYD/ssh.log" && ! grep -q -- ' -t ' "$SYD/ssh.log" && [[ ! -f "$SYD/cipi-sync-test.tar.gz.enc" ]] \
        && pass "the options reach the export, the port reaches ssh, no terminal is asked for, and the archive is gone from the source" || fail "push details"
    out=$(AS=www-data REMOTE_IMPORT_RC=1 SY sync_command push shop --host=203.0.113.9 --import --auto-passphrase)
    grep -qx 'rc=1' <<< "$out" && grep -q 'Remote import failed' <<< "$out" && grep -q "rm -f '/tmp/cipi-sync-test.tar.gz.enc'" "$SYD/remote.rm" \
        && pass "an import that fails on the target fails the push, and the archive nobody can open is removed from the target" || fail "push, import failed: ${out}"
fi
# import: the passphrase on standard input
printf 'not an archive' > "$SYD/x.tar.gz.enc"
out=$(PATH="$MG/bin:$PATH" CIPI_LIB="$DCD/lib" CIPI_CONFIG="$DCD/cfg" CIPI_LOG="$DCD/log" bash -c 'source "$CIPI_LIB/common.sh"; source "$CIPI_LIB/sync.sh"; RED=; GREEN=; YELLOW=; CYAN=; DIM=; NC=; BOLD=
    ( sync_command import "$1" --yes --passphrase-stdin ) < /dev/null 2>&1; echo "rc=$?"; ( printf "%s\n" "some-passphrase" | sync_command import "$1" --yes --passphrase-stdin ) 2>&1; echo "rc=$?"' _ "$SYD/x.tar.gz.enc")
grep -q -- '--passphrase-stdin: no passphrase on standard input' <<< "$out" && grep -q 'Decryption failed or invalid archive' <<< "$out" && [[ "$(grep -c '^rc=1$' <<< "$out")" == 2 ]] \
    && pass "import --passphrase-stdin: one line of standard input is the passphrase; none is an error, not a prompt" || fail "import stdin: ${out}"
SUD="${LIB}/cipi-api-sudoers.sh"
for line in 'cipi sync pubkey --raw,' 'cipi sync check \*,' 'cipi sync trust \*,' 'cipi sync untrust \*,' 'cipi sync push \*,'; do
    grep -q "/usr/local/bin/${line}" "$SUD" || fail "sudoers: ${line}"
done
! grep -qE 'cipi sync (export|import|list)' "$SUD" && pass "the panel may ask for the key, check, trust, untrust and push — not export, import or list an archive at a path it names" || fail "sudoers: sync"
grep -q 'cipi sync untrust --key=KEY' "${ROOT}/cipi" && grep -q -- '--auto-passphrase' "${ROOT}/cipi" && grep -q -- '--auto-passphrase' "${ROOT}/CHANGELOG.md" && pass "help and CHANGELOG say it" || fail "help / CHANGELOG: sync"

echo "--- pre-deploy snapshot of a Node app: the databases linked to it"
PS="${TMP}/snap"; mkdir -p "$PS/lib" "$PS/log"
cat > "$PS/lib/db.sh" <<'STUB'
_db_links() { printf '%b' "${LINKS:-}"; }
db_engine_is_installed() { [[ "$1" != "${MISSING_ENGINE:-}" ]]; }
db_normalize_engine() { echo "$1"; }
db_dump_database() { [[ "$2" == "${FAIL_DB:-}" ]] && return 1; echo "dump of $2" | gzip > "$3"; echo "$1 $2" >> "$CIPI_LOG/dumped"; }
STUB
SNAP() {   # <app>: env RUNTIME CUSTOM WANT REQ LINKS FAIL_DB MISSING_ENGINE
    rm -rf "$PS/log"; mkdir -p "$PS/log"
    CIPI_LIB="$PS/lib" CIPI_LOG="$PS/log" REAL_LIB="$LIB" bash -c 'set -uo pipefail
        error() { echo "[ERROR] $*"; }; warn() { echo "[WARN] $*"; }; step() { :; }; success() { echo "[OK] $*"; }
        cipi_notify() { echo "[NOTIFY] $1 :: $2 :: $3"; }; notify_now() { echo now; }
        app_get() { case "$2" in runtime) echo "${RUNTIME:-}" ;; custom) echo "${CUSTOM:-}" ;; predeploy_snapshot) echo "${WANT:-}" ;; engine) echo mariadb ;; esac; }
        eval "$(sed -n "/^_deploy_predeploy_snapshot() {/,/^}/p; /^_deploy_predeploy_snapshot_linked() {/,/^}/p" "$REAL_LIB/deploy.sh")"
        ARG_snapshot=""; ARG_snapshot_required="${REQ:-}"; CIPI_PREDEPLOY_SNAPSHOT=""; CIPI_PREDEPLOY_SNAPSHOT_DB=""
        _deploy_predeploy_snapshot "$1"; echo "rc=$? path=$(basename "${CIPI_PREDEPLOY_SNAPSHOT:-none}") db=${CIPI_PREDEPLOY_SNAPSHOT_DB:-}"' _ "$1" 2>&1
}
TWO='shop\tmariadb\tshop\nshop\tpgsql\tshop_reports\nother\tmariadb\tother_db\n'
out=$(RUNTIME=node CUSTOM=true WANT=true LINKS="$TWO" SNAP shop)
[[ "$(sort "$PS/log/dumped" | tr '\n' ',')" == "mariadb shop,pgsql shop_reports," ]] && grep -Eq '^rc=0 path=mariadb_shop_predeploy_[0-9]{8}_[0-9]{6}\.sql\.gz db=shop$' <<< "$out" \
    && [[ "$(ls "$PS/log/backups" | wc -l)" == 2 ]] && [[ "$(zcat "$PS/log/backups"/pgsql_shop_reports_predeploy_*.sql.gz)" == "dump of shop_reports" ]] \
    && pass "a Node app with the snapshot on: each database linked to it is dumped — not another app's — and the first is the one a failed deploy names" || fail "node snapshot: ${out} / $(cat "$PS/log/dumped" 2>/dev/null)"
out=$(RUNTIME=node CUSTOM=true WANT=true LINKS='other\tmariadb\tother_db\n' SNAP shop)
grep -q "Pre-deploy snapshot skipped — no database is linked to 'shop'" <<< "$out" && grep -q 'cipi db link <database> shop' <<< "$out" && grep -qx 'rc=0 path=none db=' <<< "$out" && [[ ! -e "$PS/log/dumped" ]] \
    && pass "…with no database linked: said, with how to link one, and the deploy goes on" || fail "node snapshot, no links: ${out}"
out=$(RUNTIME=node CUSTOM=true REQ=true LINKS='' SNAP shop)
grep -q 'Snapshot required but the app has no database' <<< "$out" && grep -q '^rc=1 ' <<< "$out" && pass "…a snapshot that is required (--snapshot-required) stops the deploy then" || fail "node snapshot, required, none: ${out}"
out=$(RUNTIME=node CUSTOM=true WANT=true LINKS="$TWO" FAIL_DB=shop_reports SNAP shop)
grep -q '^\[NOTIFY\] Cipi pre-deploy snapshot failed: shop on .*Databases: shop_reports.* :: deploy_snapshot_fail$' <<< "$out" && grep -q 'Pre-deploy snapshot failed for: shop_reports — continuing deploy' <<< "$out" \
    && grep -q '^rc=0 path=mariadb_shop_predeploy_.* db=shop$' <<< "$out" && pass "a dump that fails is reported, by name, and the deploy goes on with the ones that were made" || fail "node snapshot, one fails: ${out}"
out=$(RUNTIME=node CUSTOM=true WANT=true REQ=true LINKS="$TWO" MISSING_ENGINE=pgsql SNAP shop)
grep -q 'Pre-deploy snapshot of shop_reports skipped — engine pgsql not installed' <<< "$out" && grep -q 'Pre-deploy snapshot failed (required): shop_reports' <<< "$out" && grep -q '^rc=1 ' <<< "$out" \
    && pass "…and stops it when the snapshot is required" || fail "node snapshot, required, engine missing: ${out}"
out=$(RUNTIME=node CUSTOM=true LINKS="$TWO" SNAP shop)
grep -qx 'rc=0 path=none db=' <<< "$out" && [[ ! -e "$PS/log/dumped" ]] && pass "a Node app without the option: nothing is dumped" || fail "node snapshot, off: ${out}"
out=$(WANT=true LINKS="$TWO" SNAP blog)
[[ "$(cat "$PS/log/dumped")" == "mariadb blog" ]] && grep -Eq '^rc=0 path=mariadb_blog_predeploy_[0-9_]+\.sql\.gz db=$' <<< "$out" && pass "a Laravel app is as before: its own database, named like the app" || fail "laravel snapshot: ${out}"
out=$(CUSTOM=true WANT=true LINKS='wp\tmariadb\twp\n' SNAP wp)
grep -qx 'rc=0 path=none db=' <<< "$out" && [[ ! -e "$PS/log/dumped" ]] && pass "a custom app (no release recipe) is as before: no snapshot" || fail "custom snapshot: ${out}"
grep -q 'local snapshot_db="${CIPI_PREDEPLOY_SNAPSHOT_DB:-$app}"' "${LIB}/deploy.sh" && grep -q 'warn "Restore: cipi db restore ${snapshot_db} ${snapshot_path}"' "${LIB}/deploy.sh" \
    && pass "a failed deploy names the database the snapshot is of in its restore command" || fail "restore command"

echo "--- page cache: purge some pages, not all"
PC="${TMP}/purge"; mkdir -p "$PC/root" "$PC/cfg" "$PC/log" "$PC/sudoers"
cat > "$PC/apps.json" <<'JSON'
{"blog": {"domain": "blog.test", "aliases": ["www.blog.test", "Blog.Example.COM", "*.tenants.test"], "cache": {"enabled": true}},
 "shop": {"domain": "shop.test", "aliases": [], "cache": {"enabled": false}}}
JSON
echo "user $(id -un);" > "$PC/nginx.conf"   # the files are nginx's: here, the user running the suite
PCH="export CIPI_LIB='${LIB}' CIPI_CONFIG='$PC/cfg' CIPI_LOG='$PC/log' CACHE_ROOT='$PC/root' CACHE_SUDOERS_DIR='$PC/sudoers' CACHE_NGINX_CONF='$PC/nginx.conf'
RED=; GREEN=; YELLOW=; CYAN=; DIM=; NC=; BOLD=
source '${LIB}/common.sh' 2>/dev/null
vault_read() { cat '$PC/apps.json'; }
app_get() { jq -r --arg a \"\$1\" --arg k \"\$2\" '.[\$a][\$k] // empty' '$PC/apps.json'; }
app_exists() { jq -e --arg a \"\$1\" 'has(\$a)' '$PC/apps.json' >/dev/null; }
log_action() { echo \"\$*\" >> '$PC/actions.log'; }
source '${LIB}/cache.sh'
_cache_setting() { jq -r --arg a \"\$1\" --arg k \"\$2\" '.[\$a].cache[\$k] // empty' '$PC/apps.json'; }
"
page() {   # <key> : a file as nginx writes one — a binary header, the KEY line, the response
    local md5; md5=$(printf '%s' "$1" | md5sum | awk '{ print $1 }')
    local d="$PC/root/blog/${md5: -1}/${md5: -3:2}"; mkdir -p "$d"
    { printf '\x05\x00\x00\x00\x00\x00\x00\x00\x9a\x02\x00\x00'; printf '\nKEY: %s\n' "$1"; printf 'HTTP/1.1 200 OK\r\n\r\n<html>KEY: httpsGETblog.test/decoy/</html>\n'; } > "$d/$md5"
}
seed() {
    rm -rf "$PC/root/blog"; mkdir -p "$PC/root/blog"
    for k in 'httpsGETblog.test/' 'httpsHEADblog.test/' 'httpsGETblog.test/?utm_source=nl' 'httpGETblog.test/' \
             'httpsGETblog.test/hello-world/' 'httpsGETwww.blog.test/hello-world/' 'httpsGETblog.test/hello-world/?utm_campaign=x' \
             'httpsGETblog.test/hello-world-2/' 'httpsGETblog.test/category/news/' 'httpsGETblog.test/category/news/page/2/' \
             'httpsGETblog.test/feed/' 'httpsGETblog.example.com/hello-world/' 'httpsGETblog.test/decoy/'; do page "$k"; done
}
left() { grep -rahE -m1 '^KEY: ' "$PC/root/blog" | sed 's/^KEY: //' | sort | paste -sd' ' -; }
PURGE() { bash -c "$PCH"' cache_command "$@"' _ "$@" 2>&1; }
seed
out=$(PURGE blog purge /hello-world/)
[[ "$(left)" == "httpGETblog.test/ httpsGETblog.test/ httpsGETblog.test/?utm_source=nl httpsGETblog.test/category/news/ httpsGETblog.test/category/news/page/2/ httpsGETblog.test/decoy/ httpsGETblog.test/feed/ httpsGETblog.test/hello-world-2/ httpsHEADblog.test/" ]] \
    && grep -q 'Purged 4 cached file' <<< "$out" \
    && pass "purge /hello-world/: that page on every domain and alias of the app (case aside), with its ?utm variants — not /hello-world-2/, not a page whose body names it" || fail "purge one: ${out} / $(left)"
seed; out=$(PURGE blog purge /category/news/* /)
[[ "$(left)" == "httpsGETblog.example.com/hello-world/ httpsGETblog.test/decoy/ httpsGETblog.test/feed/ httpsGETblog.test/hello-world-2/ httpsGETblog.test/hello-world/ httpsGETblog.test/hello-world/?utm_campaign=x httpsGETwww.blog.test/hello-world/" ]] \
    && pass "purge /category/news/* /: a prefix and the home page — http and https, GET and HEAD" || fail "purge prefix: ${out} / $(left)"
seed; out=$(PURGE blog purge https://www.blog.test/hello-world/ --json)
[[ "$(jq -r '[.app, .enabled, .purged, (.targets | length)] | @tsv' <<< "$out")" == $'blog\ttrue\t1\t1' ]] && ! grep -q 'www.blog.test/hello-world/' <<< "$(left)" && grep -q 'httpsGETblog.test/hello-world/ ' <<< "$(left) " \
    && pass "a URL purges that page on that host only, and --json says how many files went" || fail "purge url: ${out} / $(left)"
seed; page 'httpsGETacme.tenants.test/hello-world/'; page 'httpsGETacme.tenants.test/other/'
out=$(PURGE blog purge /hello-world/); ! grep -q 'tenants.test/hello-world/' <<< "$(left)" && grep -q 'acme.tenants.test/other/' <<< "$(left)" \
    && out=$(PURGE blog purge https://acme.tenants.test/other/) && ! grep -q 'tenants.test' <<< "$(left)" \
    && pass "a wildcard alias (*.tenants.test): its subdomains are the app's — by path, and by URL" || fail "wildcard alias: ${out} / $(left)"
seed
for bad in 'https://evil.test/x' 'hello' '/a b' "/x'" '/a*b' '/$(id)' '/a?b=1' '--force' 'https://evil@blog.test/x' $'https://a\n.tenants.test/x' 'https://(.*)|x.tenants.test/'; do
    out=$(PURGE blog purge "$bad"); [[ "$out" == *"Not a page of 'blog'"* || "$out" == *"Unknown option"* ]] || fail "purge took ${bad}: ${out}"
done
[[ "$(left | wc -w)" == 13 ]] && pass "a host that is not the app's (or not a host name: user@, a newline, a pattern), a path without /, a space, a quote, a * inside, a query, an option: refused, nothing deleted" || fail "refusals deleted something: $(left)"
out=$(PURGE shop purge /x); grep -q "page cache of 'shop' is off" <<< "$out" && pass "an app with the cache off: nothing to purge, said" || fail "purge off: ${out}"
out=$(PURGE blog purge); [[ -z "$(left)" ]] && grep -q "emptied — 13 page" <<< "$out" && pass "purge with no page: every page, as clear" || fail "purge all: ${out}"
seed; mapfile -t many < <(seq 1 501 | sed 's|^|/p|'); out=$(PURGE blog purge "${many[@]}"); grep -q 'At most 500 pages' <<< "$out" && [[ "$(left | wc -w)" == 13 ]] && pass "at most 500 pages at once" || fail "purge max: ${out}"
# the helper the app's own user runs through sudo
H="${LIB}/cipi-cache-clear.sh"; bash -n "$H" && pass "cipi-cache-clear parses" || fail "cipi-cache-clear parse"
grep -q 'TARGETS=("$@")' "$H" && grep -q 'n=$(cache_purge "$APP" "${TARGETS\[@\]}")' "$H" && grep -q '_cache_purge_target "$APP" "$t" >/dev/null ||' "$H" \
    && pass "cipi-cache-clear <app> <path>…: each target checked before anything is deleted" || fail "helper purge"
printf 'blog ALL=(root) NOPASSWD: /usr/local/bin/cipi-worker restart blog\nblog ALL=(root) NOPASSWD: /usr/local/bin/cipi-cache-clear blog\n' > "$PC/sudoers/cipi-blog"
bash -c "$PCH visudo() { return 0; }; _cache_sudoers_ensure blog; _cache_sudoers_ensure blog"
[[ "$(grep -c 'cipi-cache-clear blog$' "$PC/sudoers/cipi-blog")" == 1 && "$(grep -cxF 'blog ALL=(root) NOPASSWD: /usr/local/bin/cipi-cache-clear blog *' "$PC/sudoers/cipi-blog")" == 1 ]] \
    && pass "sudoers: the rule for some pages is added once, next to the one for all" || fail "sudoers: $(cat "$PC/sudoers/cipi-blog")"
grep -qF '${app_user} ALL=(root) NOPASSWD: /usr/local/bin/cipi-cache-clear ${app_user} *' "${LIB}/app.sh" && pass "a new app has both rules" || fail "app.sh sudoers"
grep -q '_cache_sudoers_ensure' "${LIB}/migrations/5.18.0.sh" && pass "the migration gives existing apps the rule" || fail "migration sudoers"

echo "--- backups to SFTP: a VPS, a Storage Box"
BS="${TMP}/bsftp"; mkdir -p "$BS/bin" "$BS/cfg" "$BS/log" "$BS/remote" "$BS/run/apps/shop" "$BS/run/databases/mariadb"
# sftp as a stand-in: the batch runs against $BS/remote, the user's home there.
cat > "$BS/bin/sftp" <<'STUB'
#!/bin/bash
batch=""; args=("$@")
for ((i=0; i<${#args[@]}; i++)); do [[ "${args[$i]}" == -b ]] && batch="${args[$((i+1))]}"; done
echo "$*" >> "$SFTP_LOG"
[[ -n "${SFTP_REFUSE:-}" ]] && { echo "${SFTP_REFUSE}" >&2; exit 255; }
abs() { [[ "$1" == /* ]] && echo "${SFTP_ROOT}$1" || echo "${SFTP_ROOT}/$1"; }
while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    soft=false; [[ "$line" == -* ]] && { soft=true; line="${line#-}"; }
    eval "set -- $line"; cmd="$1"; shift; ok=true
    case "$cmd" in
        ls) [[ "$1" == -ln ]] || { echo "ls without -ln: ${line}" >&2; exit 1; }; shift; d=$(abs "$1")
            if [[ -d "$d" ]]; then
                for e in "$d"/*; do [[ -e "$e" ]] || continue; n=$(basename "$e")
                    if [[ -d "$e" ]]; then printf 'drwxr-xr-x    ? 1000  1000   4096 Nov 28 10:00 %s/%s\n' "$1" "$n"
                    else printf -- '-rw-r--r--    ? 1000  1000 %6d Nov 28 10:00 %s/%s\n' "$(stat -c %s "$e")" "$1" "$n"; fi
                done
            else echo "Can't ls: \"$1\" not found" >&2; ok=false; fi ;;
        mkdir) mkdir "$(abs "$1")" 2>/dev/null || ok=false ;;
        put) cp "$1" "$(abs "$2")" 2>/dev/null || { echo "dest open \"$2\": No such file or directory" >&2; ok=false; } ;;
        get) cp "$(abs "$1")" "$2" 2>/dev/null || { echo "File \"$1\" not found." >&2; ok=false; } ;;
        rm) rm "$(abs "$1")" 2>/dev/null || ok=false ;;
        rmdir) rmdir "$(abs "$1")" 2>/dev/null || ok=false ;;
        *) ok=false ;;
    esac
    [[ "$ok" == true || "$soft" == true ]] || exit 1
done < "$batch"
STUB
cat > "$BS/bin/ssh-keygen" <<'STUB'
#!/bin/bash
f=""; c=x; while [[ $# -gt 0 ]]; do case "$1" in -f) f="$2"; shift ;; -C) c="$2"; shift ;; esac; shift; done
echo "PRIVATE" > "$f"; echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKey ${c}" > "${f}.pub"
STUB
chmod +x "$BS/bin/sftp" "$BS/bin/ssh-keygen"
echo '{"local_dir": "/var/backups/cipi", "profiles": {}}' > "$BS/cfg/backup.json"
echo 'files of shop' > "$BS/run/apps/shop/files.tar.gz"; echo '{"app":"shop"}' > "$BS/run/apps/shop/meta.json"
echo 'dump' > "$BS/run/databases/mariadb/shop.sql.gz"; echo '{"v":1}' > "$BS/run/manifest.json"
BK() {   # <function and args> — the backup library with a vault of files
    PATH="$BS/bin:$PATH" SFTP_ROOT="$BS/remote" SFTP_LOG="$BS/sftp.log" CIPI_LIB="$LIB" CIPI_CONFIG="$BS/cfg" CIPI_LOG="$BS/log" BACKUP_SFTP_KEY_DIR="$BS/keys" \
    bash -c 'source "$CIPI_LIB/common.sh" 2>/dev/null; RED=; GREEN=; YELLOW=; CYAN=; DIM=; NC=; BOLD=
        vault_read() { cat "$CIPI_CONFIG/$1" 2>/dev/null; }; vault_write() { cat > "$CIPI_CONFIG/$1"; }
        log_action() { echo "$*" >> "$CIPI_LOG/actions.log"; }; hostname() { echo web1; }
        source "$CIPI_LIB/backup.sh"; "$@"' _ "$@" 2>&1
}
out=$(BK _bk_destination_command add box --type=sftp --host=u1234.your-storagebox.de --port=23 --user=u1234 --path=backups/cipi < /dev/null)
grep -q "Backup destination 'box' added: sftp://u1234@u1234.your-storagebox.de:23/backups/cipi" <<< "$out" && grep -q 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKey cipi-backup-box@web1' <<< "$out" \
    && grep -q 'ssh-copy-id -p 23 -s -i' <<< "$out" && [[ "$(stat -c %a "$BS/keys/box")" == 600 && "$(stat -c %a "$BS/keys")" == 700 ]] \
    && [[ "$(jq -c '.sftp_destinations.box | del(.created_at)' "$BS/cfg/backup.json")" == '{"host":"u1234.your-storagebox.de","port":23,"user":"u1234","path":"backups/cipi"}' ]] \
    && ! grep -qi 'password' "$BS/cfg/backup.json" \
    && pass "destination add --type=sftp: host, port, user, folder kept; a key of its own (600 in a 700 folder); its public half and how to install it printed; no password anywhere" || fail "sftp add: ${out} / $(cat "$BS/cfg/backup.json")"
for bad in "--host='a;b' --user=u" "--host=h --user='a b'" "--host=h --user=u --path=../etc" "--host=h --user=u --port=70000" "--host=-oProxy=x --user=u"; do
    out=$(eval BK _bk_destination_command add bad --type=sftp $bad < /dev/null); grep -q '^\[ERROR\]\|✗\|Invalid' <<< "$out" || fail "sftp add took: ${bad} — ${out}"
done
! jq -e '.sftp_destinations.bad' "$BS/cfg/backup.json" >/dev/null && pass "a host with ; or a leading dash, a user with a space, a folder with .., a port past 65535: refused, nothing saved" || fail "sftp add saved a bad one"
out=$(BK _bk_destination_command key box --raw); [[ "$out" == 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKey cipi-backup-box@web1' ]] && pass "destination key box --raw: the public key and nothing else" || fail "key: ${out}"
out=$(BK _bk_destination_command list); grep -q 'sftp://u1234@u1234.your-storagebox.de:23/backups/cipi' <<< "$out" && grep -q 'Add SFTP: cipi backup destination add' <<< "$out" && pass "destination list shows it" || fail "list: ${out}"
out=$(BK _bk_status_json); [[ "$(jq -c '.destinations[] | select(.name == "box") | [.type, .host, .port, .user, .path]' <<< "$out")" == '["sftp","u1234.your-storagebox.de",23,"u1234","backups/cipi"]' ]] && ! grep -q 'PRIVATE' <<< "$out" \
    && pass "backup status --json: the destination, type sftp, without its key" || fail "status json: $(jq -c '.destinations' <<< "$out" 2>/dev/null || echo "$out")"

out=$(SFTP_REFUSE='u1234@u1234.your-storagebox.de: Permission denied (publickey).' BK _bk_destination_command test box)
grep -q 'Permission denied (publickey)' <<< "$out" && grep -q 'The remote must accept this key: ssh-ed25519' <<< "$out" && pass "destination test before the key is installed: the remote's refusal, and the key to install" || fail "test refused: ${out}"
: > "$BS/sftp.log"
out=$(BK _bk_destination_command test box); grep -q 'reachable — a file written and removed in backups/cipi/cipi' <<< "$out" && [[ -d "$BS/remote/backups/cipi/cipi" && -z "$(ls -A "$BS/remote/backups/cipi/cipi")" ]] \
    && grep -q -- '-P 23 -i '"$BS"'/keys/box -o BatchMode=yes -o IdentitiesOnly=yes' "$BS/sftp.log" && grep -q "UserKnownHostsFile=$BS/keys/known_hosts" "$BS/sftp.log" && grep -q -- '-- u1234@u1234.your-storagebox.de$' "$BS/sftp.log" \
    && pass "destination test: a file written and removed; the key only, no prompt, the host key pinned in its own known_hosts" || fail "test: ${out} / $(cat "$BS/sftp.log")"

# A run, as the rest of the backup code moves it: up, listed, found, down, pruned.
BK _bk_aws box cp "$BS/run/" "sftp://box/cipi/nightly/20261128-030000/" --recursive >/dev/null
mkdir -p "$BS/remote/elsewhere"
[[ "$(cd "$BS/remote/backups/cipi/cipi/nightly/20261128-030000" && find . -type f | sort | paste -sd' ' -)" == "./apps/shop/files.tar.gz ./apps/shop/meta.json ./databases/mariadb/shop.sql.gz ./manifest.json" ]] \
    && pass "a run uploaded: <folder>/cipi/<profile>/<timestamp>/, the same layout as a bucket" || fail "upload: $(find "$BS/remote" -type f)"
BK _bk_aws box cp "$BS/run/" "sftp://box/cipi/nightly/20261129-030000/" --recursive >/dev/null
out=$(BK _bk_s3_ls_dirs box "sftp://box/cipi/nightly/"); [[ "$(paste -sd' ' - <<< "$out")" == "20261128-030000 20261129-030000" ]] && pass "its runs listed as the S3 code reads them (PRE <run>/)" || fail "ls dirs: ${out}"
out=$(BK _bk_aws box ls "sftp://box/cipi/nightly/20261128-030000/" --recursive)
[[ "$(awk '{print $4}' <<< "$out" | sort | paste -sd' ' -)" == "cipi/nightly/20261128-030000/apps/shop/files.tar.gz cipi/nightly/20261128-030000/apps/shop/meta.json cipi/nightly/20261128-030000/databases/mariadb/shop.sql.gz cipi/nightly/20261128-030000/manifest.json" ]] \
    && [[ "$(awk '$4 ~ /manifest/ {print $3}' <<< "$out")" == 8 ]] && pass "a recursive listing: every file, its size, its key — what verify checks for empty files" || fail "ls recursive: ${out}"
out=$(BK _bk_s3_find_run nightly 20261128-030000); [[ "$out" == box ]] && pass "fetch and verify find a run on it" || fail "find run: ${out}"
out=$(BK _bk_s3_find_run nightly 20250101-000000); [[ -z "$out" ]] && pass "…and not one that is not there" || fail "find missing: ${out}"
mkdir -p "$BS/down"; BK _bk_aws box cp "sftp://box/cipi/nightly/20261128-030000/" "$BS/down/" --recursive >/dev/null
diff -r "$BS/run" "$BS/down" >/dev/null && pass "a run downloaded is the run that went up" || fail "download: $(diff -r "$BS/run" "$BS/down")"
BK _bk_aws box rm "sftp://box/cipi/nightly/20261128-030000/" --recursive >/dev/null
[[ ! -e "$BS/remote/backups/cipi/cipi/nightly/20261128-030000" && -d "$BS/remote/backups/cipi/cipi/nightly/20261129-030000" ]] && pass "a run pruned: its files and folders gone, the next run left" || fail "rm: $(find "$BS/remote")"
out=$(BK _bk_aws box rm "sftp://box/cipi/nightly/19990101-000000/" --recursive); rc=$?
[[ $rc -eq 0 ]] && pass "pruning a run that is not there is not an error" || fail "rm missing: rc=${rc} ${out}"
out=$(BK _bk_aws box ls "sftp://box/cipi/nope/"); rc=$?; [[ $rc -eq 1 && -z "$out" ]] && pass "listing a folder that is not there: nothing, status 1 — as aws s3 ls" || fail "ls missing: rc=${rc} ${out}"
grep -q '_bk_is_sftp "$dest" || _ensure_awscli' "${LIB}/backup.sh" && pass "an SFTP copy needs no AWS CLI" || fail "upload installs aws"

out=$(BK _bk_destination_command edit box --port=22 < /dev/null); [[ "$(jq -r '.sftp_destinations.box.port' "$BS/cfg/backup.json")" == 22 && "$(jq -r '.sftp_destinations.box.host' "$BS/cfg/backup.json")" == u1234.your-storagebox.de ]] \
    && pass "destination edit: what is given changes, the rest stays, the key too" || fail "edit: ${out}"
out=$(BK _bk_destination_command add pj --type=sftp --host=10.0.0.5 --user=backup --json < /dev/null)
[[ "$(jq -r '[.name, .type, .host, .port, .user, (.public_key | startswith("ssh-ed25519 "))] | @tsv' <<< "$out")" == $'pj\tsftp\t10.0.0.5\t22\tbackup\ttrue' ]] && pass "add --json: what the panel shows — the destination and the key to install" || fail "add json: ${out}"
out=$(SUDO_USER=www-data BK _bk_destination_command add s3x --bucket=b --key=k --secret=s < /dev/null); grep -q 'An S3 destination is added at the server' <<< "$out" && ! jq -e '.s3_destinations.s3x' "$BS/cfg/backup.json" >/dev/null \
    && pass "from the panel an S3 destination is refused: its secret would be kept there" || fail "www-data s3: ${out}"
out=$(BK _bk_destination_command remove pj < /dev/null); [[ ! -e "$BS/keys/pj" && ! -e "$BS/keys/pj.pub" ]] && ! jq -e '.sftp_destinations.pj' "$BS/cfg/backup.json" >/dev/null && grep -q 'authorized_keys' <<< "$out" \
    && pass "destination remove: its key deleted here, and a word about the remote's authorized_keys" || fail "remove: ${out}"
grep -q '/usr/local/bin/cipi backup sftp \*,' "${LIB}/cipi-api-sudoers.sh" && ! grep -qE 'cipi backup destination (add|edit|remove)' "${LIB}/cipi-api-sudoers.sh" \
    && pass "the panel runs backup sftp — SFTP destinations only; destination add|edit|remove (S3 secrets) stay out" || fail "sudoers sftp"
out=$(BK backup_command sftp add vps --host=10.0.0.9 --user=backup --json < /dev/null); [[ "$(jq -r '.type' <<< "$out")" == sftp ]] && pass "backup sftp add: the same destination, SFTP always" || fail "sftp add: ${out}"
echo '{"s3x": 1}' > /dev/null; jq '.s3_destinations = {"bucket1": {"bucket": "b"}}' "$BS/cfg/backup.json" > "$BS/x" && mv "$BS/x" "$BS/cfg/backup.json"
out=$(BK backup_command sftp remove bucket1 < /dev/null); grep -q "'bucket1' is not an SFTP destination" <<< "$out" && jq -e '.s3_destinations.bucket1' "$BS/cfg/backup.json" >/dev/null \
    && pass "backup sftp remove leaves an S3 destination alone" || fail "sftp remove s3: ${out}"
out=$(BK backup_command sftp remove vps < /dev/null); ! jq -e '.sftp_destinations.vps' "$BS/cfg/backup.json" >/dev/null && pass "backup sftp remove: an SFTP one goes" || fail "sftp remove: ${out}"

echo "--- self-update: a signed release, a delay — both off unless asked"
SU="${TMP}/su"; mkdir -p "$SU/bin" "$SU/cfg" "$SU/log" "$SU/tree" "$SU/opt"
# git as a stand-in: the downloaded tree's HEAD, its tag, what verify-tag says.
cat > "$SU/bin/git" <<'STUB'
#!/bin/bash
args="$*"
case "$args" in
    *" fetch "*) [[ "${NO_TAG:-}" == 1 ]] && { echo "fatal: couldn't find remote ref refs/tags/v5.19.0" >&2; exit 128; }; exit 0 ;;
    *"rev-parse HEAD"*) echo "${HEAD_SHA:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}" ;;
    *"rev-parse v"*"^{commit}"*) echo "${TAG_SHA:-${HEAD_SHA:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}}" ;;
    *"cat-file -t"*) echo "${TAG_TYPE:-tag}" ;;
    *"verify-tag"*)
        grep -q 'allowedSignersFile=' <<< "$args" || exit 1
        [[ "${BAD_SIG:-}" == 1 ]] && { echo 'Could not verify signature.' >&2; exit 1; }
        echo 'Good "git" signature for andrea@cipi.sh with ED25519 key SHA256:abcDEF123' >&2 ;;
esac
STUB
cat > "$SU/bin/ssh-keygen" <<'STUB'
#!/bin/bash
k=$(cat); case "$k" in *AAAAkeyOne*) echo "256 SHA256:keyONEfp no comment (ED25519)" ;; *) echo "256 SHA256:otherfp no comment (ED25519)" ;; esac
STUB
chmod +x "$SU/bin/git" "$SU/bin/ssh-keygen"
printf '# comment\nandrea@cipi.sh namespaces="git" ssh-ed25519 AAAAkeyOne\n' > "$SU/opt/release-signers"
SUH() {
    PATH="$SU/bin:$PATH" CIPI_LIB="$LIB" CIPI_CONFIG="$SU/cfg" CIPI_LOG="$SU/log" CIPI_SHIPPED_SIGNERS="$SU/opt/release-signers" CIPI_SELFUPDATE_DELAY_CRON="$SU/cron" CIPI_VERSION=5.18.0 \
    bash -c 'source "$CIPI_LIB/common.sh" 2>/dev/null; RED=; GREEN=; YELLOW=; CYAN=; DIM=; NC=; BOLD=
        vault_read() { cat "$CIPI_CONFIG/$1" 2>/dev/null; }; vault_write() { cat > "$CIPI_CONFIG/$1"; }
        log_action() { echo "$*" >> "$CIPI_LOG/actions.log"; }; cipi_notify() { echo "NOTIFY $1" >> "$CIPI_LOG/notify.log"; }
        _cipi_run_timed() { shift; "$@"; }
        source "$CIPI_LIB/self-update.sh"; "$@"' _ "$@" 2>&1
}
out=$(SUH selfupdate_policy --json); [[ "$(jq -c '[.verify, .delay_hours, .delay_default_hours, .signers_ready, (.shipped_signers | length)]' <<< "$out")" == '[false,0,12,false,1]' ]] \
    && pass "by default nothing changes: no signature check, no delay — the shipped signers are offered, not trusted" || fail "policy default: ${out}"
out=$(SUH selfupdate_policy --verify=on < /dev/null); grep -q 'Say which key you checked: --fingerprint=SHA256' <<< "$out" && grep -q 'SHA256:keyONEfp' <<< "$out" && [[ ! -e "$SU/cfg/release-signers" ]] \
    && pass "--verify=on without a terminal: the fingerprint compared with cipi.sh has to be given" || fail "verify on blind: ${out}"
out=$(SUH selfupdate_policy --verify=on --fingerprint=SHA256:forged < /dev/null); grep -q 'is not the fingerprint of the signers shipped' <<< "$out" && [[ ! -e "$SU/cfg/release-signers" ]] \
    && pass "…a fingerprint that is not the shipped key's: refused" || fail "verify wrong fp: ${out}"
out=$(SUH selfupdate_policy --verify=on --fingerprint=SHA256:keyONEfp --json < /dev/null)
[[ "$(jq -c '[.verify, .signers_ready, .signers[0].fingerprint, .signers[0].principal]' <<< "$out")" == '[true,true,"SHA256:keyONEfp","andrea@cipi.sh"]' ]] && cmp -s "$SU/opt/release-signers" "$SU/cfg/release-signers" \
    && pass "…the right one: those signers are trusted, the check is on" || fail "verify on: ${out}"
out=$(SUH selfupdate_policy --delay=12h --json); [[ "$(jq -r '.delay_hours' <<< "$out")" == 12 ]] && grep -q '^17 \* \* \* \* root /usr/local/bin/cipi self-update --if-due' "$SU/cron" \
    && pass "--delay=12h: kept, and an hourly check installs a held release once it is due" || fail "delay on: ${out} / $(cat "$SU/cron" 2>/dev/null)"
for bad in 169 x -1 9d; do out=$(SUH selfupdate_policy --delay=$bad); grep -q 'a week at most' <<< "$out" || fail "delay took ${bad}: ${out}"; done
[[ "$(jq -r '.delay_hours' "$SU/cfg/selfupdate.json")" == 12 ]] && pass "a delay that is not hours or days, or past a week: refused, nothing changed" || fail "bad delay changed it"
out=$(SUH selfupdate_policy --delay=2d --json); [[ "$(jq -r '.delay_hours' <<< "$out")" == 48 ]] && pass "--delay=2d is 48 hours" || fail "2d: ${out}"
# A value from the command line never reaches an arithmetic expansion: bash
# runs the command substitution of an array subscript there (www-data may
# call `cipi self-update policy *`).
rm -f "$SU/pwned"
for bad in 'x[$(touch '"$SU"'/pwned)]d' 'x[$(touch '"$SU"'/pwned)]h' 'x[$(touch '"$SU"'/pwned)]' 'abcd' '1000h' '08d'; do
    out=$(SUH selfupdate_policy --delay="$bad" 2>&1); grep -q 'a week at most' <<< "$out" || fail "delay took ${bad}: ${out}"
done
[[ ! -e "$SU/pwned" ]] && pass "--delay: text that is not a number is refused, never evaluated" || fail "--delay ran a command substitution"
out=$(SUH selfupdate_policy --delay=012h --json); [[ "$(jq -r '.delay_hours' <<< "$out")" == 12 ]] && pass "--delay=012h is 12 hours (base 10)" || fail "012h: ${out}"
SUH selfupdate_policy --delay=12h >/dev/null

# The signature: the tag of the version, on the commit downloaded, signed by a trusted key.
out=$(SUH _su_verify_release "$SU/tree" 5.19.0); [[ $? -eq 0 ]] && grep -q 'Good "git" signature for andrea@cipi.sh with ED25519 key SHA256:abcDEF123' <<< "$out" && pass "a release whose tag is signed by a trusted key, at the commit downloaded: verified" || fail "verify ok: ${out}"
out=$(NO_TAG=1 SUH _su_verify_release "$SU/tree" 5.19.0); grep -q 'has no tag v5.19.0 — it was not signed' <<< "$out" && pass "no tag: refused" || fail "no tag: ${out}"
out=$(TAG_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb SUH _su_verify_release "$SU/tree" 5.19.0); grep -q 'not at the signed tag v5.19.0' <<< "$out" && pass "a branch moved past its signed tag (a commit pushed after it): refused" || fail "moved: ${out}"
out=$(TAG_TYPE=commit SUH _su_verify_release "$SU/tree" 5.19.0); grep -q 'lightweight tag' <<< "$out" && pass "a lightweight tag carries no signature: refused" || fail "lightweight: ${out}"
out=$(BAD_SIG=1 SUH _su_verify_release "$SU/tree" 5.19.0); grep -q 'not one of a trusted key' <<< "$out" && pass "a signature by any other key: refused" || fail "bad sig: ${out}"
mv "$SU/cfg/release-signers" "$SU/cfg/rs.bak"; out=$(SUH _su_verify_release "$SU/tree" 5.19.0); grep -q 'no signer is trusted on this server' <<< "$out" && pass "no trusted signer: nothing can be verified, nothing installed" || fail "no signers: ${out}"
mv "$SU/cfg/rs.bak" "$SU/cfg/release-signers"
grep -q 'Update refused: ${why}' "${LIB}/self-update.sh" && grep -q '_su_held "refused: ${why}"' "${LIB}/self-update.sh" && grep -q 'Cipi update refused on $(hostname)' "${LIB}/self-update.sh" \
    && pass "a refused update installs nothing, is noted and notified" || fail "refusal path"

# With the check on, no older release over this one (CIPI_VERSION=5.18.0 here).
SUH _su_downgrade 5.17.9 | grep -q 'older than the v5.18.0' && ! SUH _su_downgrade 5.18.0 >/dev/null && ! SUH _su_downgrade 5.18.1 >/dev/null && ! SUH _su_downgrade 5.20.0 >/dev/null \
    && SUH _su_downgrade 5.9.9 >/dev/null && grep -q 'if why=$(_su_downgrade "$nv") || ! why=$(_su_verify_release "$tmp" "$nv"); then' "${LIB}/self-update.sh" \
    && pass "a signed but older release is refused (the branch pointed back at a release with a known flaw); the same or a newer one goes on" || fail "downgrade"

# The delay: this server's clock, per commit.
SHA1=1111111111111111111111111111111111111111; SHA2=2222222222222222222222222222222222222222
out=$(SUH _su_delay_gate "$SHA1" 5.19.0); [[ $? -eq 1 ]] && grep -q 'v5.19.0 (111111111111) first seen .*; installed from .* (delay 12h)' <<< "$out" && [[ "$(jq -r '.pending.sha' "$SU/cfg/selfupdate-state.json")" == "$SHA1" ]] \
    && pass "a new commit: held, and when it was first seen is recorded" || fail "gate new: ${out}"
first=$(jq -r '.pending.first_seen' "$SU/cfg/selfupdate-state.json"); sleep 1
SUH _su_delay_gate "$SHA1" 5.19.0 >/dev/null; [[ "$(jq -r '.pending.first_seen' "$SU/cfg/selfupdate-state.json")" == "$first" ]] && pass "seen again: the clock is not reset" || fail "gate reset the clock"
SUH _su_delay_gate "$SHA2" 5.19.0 >/dev/null; [[ "$(jq -r '.pending.sha' "$SU/cfg/selfupdate-state.json")" == "$SHA2" ]] && pass "the branch moved (a fix, a revert): the new commit starts its own wait" || fail "gate moved"
jq '.pending.first_seen -= 43201' "$SU/cfg/selfupdate-state.json" > "$SU/st" && mv "$SU/st" "$SU/cfg/selfupdate-state.json"
SUH _su_delay_gate "$SHA2" 5.19.0 >/dev/null && pass "12 hours later: it goes in" || fail "gate due"
jq --arg s "$SHA2" '.installed_sha = $s | del(.pending)' "$SU/cfg/selfupdate-state.json" > "$SU/st" && mv "$SU/st" "$SU/cfg/selfupdate-state.json"
SUH _su_delay_gate "$SHA2" 5.19.0 >/dev/null && pass "what is installed already is never held" || fail "gate installed"
SHA3=3333333333333333333333333333333333333333
echo '{}' > "$SU/cfg/selfupdate-state.json"
SUH _su_delay_gate "$SHA3" 5.18.0 >/dev/null && [[ "$(jq -r '.installed_sha' "$SU/cfg/selfupdate-state.json")" == "$SHA3" ]] \
    && pass "nothing recorded yet: the version running now is taken as installed, not held as a new release" || fail "gate running version: $(cat "$SU/cfg/selfupdate-state.json")"
SUH _su_delay_gate "$SHA1" 5.19.0 >/dev/null; [[ $? -eq 1 ]] && pass "…and a new release after it is held as before" || fail "gate after running version"
SUH selfupdate_policy --delay=off >/dev/null; SUH _su_delay_gate "$SHA1" 5.20.0 >/dev/null && [[ ! -e "$SU/cron" ]] && pass "--delay=off: nothing held, the hourly check removed" || fail "delay off"
grep -q 'if \[\[ -n "$new_sha" && "${ARG_now:-}" != "true" \]\]; then' "${LIB}/self-update.sh" && grep -q "_su_state_write \"\$(_su_state | jq -c --arg s \"\$new_sha\" '.installed_sha = \$s" "${LIB}/self-update.sh" \
    && pass "--now installs at once (the signature is still checked); an install records what it installed" || fail "now / installed"
[[ -f "${ROOT}/release-signers" && -x "${ROOT}/scripts/sign-release.sh" ]] && grep -q 'install -m 644 cipi-install/release-signers /opt/cipi/release-signers' "${ROOT}/setup.sh" \
    && pass "the release ships its signers and the script that signs it" || fail "signers file / script"
grep -q '/usr/local/bin/cipi self-update policy \*,' "${LIB}/cipi-api-sudoers.sh" && ! grep -qE 'cipi self-update( --now)?, ' "${LIB}/cipi-api-sudoers.sh" \
    && pass "the panel may read and set the policy — not start an update" || fail "sudoers self-update"

echo ""
echo "=== ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]

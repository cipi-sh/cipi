#!/bin/bash
#############################################
# Cipi — Zero Trust, the private side: Tailscale and NetBird (opt-in)
#
# Cloudflare (lib/zt.sh) publishes: a site reaches the world through its
# tunnel. A mesh network is the other half — the way the people who run the
# server reach it. SSH, the panel, the API and the sites answer on a private
# address that only the devices of the network can route to.
#
#   cipi zt tailscale enable --auth-key=…
#   cipi zt netbird   enable --setup-key=…
#
# enable installs the client from its vendor's apt repository, joins the
# network and lets the mesh interface through UFW. It closes nothing:
# lock ssh / lock http are later, explicit steps, and lock ssh refuses until
# the command itself arrives over the mesh — that it does is the proof.
#
# One mesh per server: both hand out addresses in 100.64.0.0/10, and
# Tailscale drops what comes from that range outside its own interface.
# Cloudflare Zero Trust and a mesh work side by side (public sites through
# the tunnel, the people who run them through the mesh).
#
# A client that was on the server before Cipi is adopted as it is: its
# settings are not touched, and disable leaves it installed and connected.
# setup.sh / self-update never call enable.
#############################################

# The time of a notification is common.sh's (and follows `cipi notification
# timezone`); loaded on its own, this file still has a clock.
declare -f notify_now >/dev/null 2>&1 || notify_now() { date "$@" '+%Y-%m-%d %H:%M:%S %Z'; }

[[ -z "${MESH_STATE:-}" ]]        && readonly MESH_STATE="zt-mesh.json"
[[ -z "${MESH_TS_KEYRING:-}" ]]   && readonly MESH_TS_KEYRING="/usr/share/keyrings/tailscale-archive-keyring.gpg"
[[ -z "${MESH_TS_LIST:-}" ]]      && readonly MESH_TS_LIST="/etc/apt/sources.list.d/tailscale.list"
# .asc: apt reads an armored key as it is — no gpg --dearmor, no gnupg needed.
[[ -z "${MESH_NB_KEYRING:-}" ]]   && readonly MESH_NB_KEYRING="/usr/share/keyrings/netbird-archive-keyring.asc"
[[ -z "${MESH_NB_LIST:-}" ]]      && readonly MESH_NB_LIST="/etc/apt/sources.list.d/netbird.list"
[[ -z "${MESH_OS_RELEASE:-}" ]]   && readonly MESH_OS_RELEASE="/etc/os-release"
[[ -z "${MESH_LE_LIVE:-}" ]]      && readonly MESH_LE_LIVE="/etc/letsencrypt/live"
# Calls a status or the monitor make: short, so a client that hangs never holds them up.
[[ -z "${MESH_TIMEOUT:-}" ]]      && MESH_TIMEOUT=15
[[ -z "${MESH_JOIN_TIMEOUT:-}" ]] && MESH_JOIN_TIMEOUT=90
# Seconds enable waits for the client to say it is connected.
[[ -z "${MESH_WAIT:-}" ]]         && MESH_WAIT=20

mesh_command() {
    local p="${1:-}"; shift || true
    _mesh_valid "$p" || { error "Usage: cipi zt tailscale|netbird enable|disable|status|ssh|lock|unlock [args]"; exit 1; }
    local sub="${1:-}"; shift || true
    case "$sub" in
        enable|join)   _mesh_enable "$p" "$@" ;;
        disable|leave) _mesh_disable "$p" "$@" ;;
        status)        _mesh_status "$p" "$@" ;;
        ssh)           _mesh_ssh "$p" "$@" ;;
        lock)          _mesh_lock "$p" "$@" ;;
        unlock)        _mesh_unlock "$p" "$@" ;;
        *) _mesh_usage "$p"; exit 1 ;;
    esac
}

_mesh_usage() {
    local p="$1" key
    key=$(_mesh_key_flag "$p")
    error "Usage: cipi zt ${p} enable|disable|status|ssh|lock|unlock [args]"
    echo "  cipi zt ${p} enable --${key}=KEY [--hostname=] [--direct] [--accept-dns] [--accept-routes]"
    if [[ "$p" == "tailscale" ]]; then
        echo "                         [--tags=tag:cipi] [--login-server=URL (Headscale)] [--ssh] [--reauth]"
    else
        echo "                       [--management-url=URL (self-hosted NetBird)]"
    fi
    echo "  cipi zt ${p} status [--json]"
    echo "  cipi zt ${p} lock ssh|http [--yes]      cipi zt ${p} unlock ssh|http"
    [[ "$p" == "tailscale" ]] && echo "  cipi zt ${p} ssh enable|disable          Tailscale SSH (sign-in by the tailnet's policy)"
    echo "  cipi zt ${p} disable [--yes]"
}

# ── the two providers ────────────────────────────────────────

_mesh_valid()    { [[ "${1:-}" == "tailscale" || "${1:-}" == "netbird" ]]; }
_mesh_label()    { case "${1:-}" in tailscale) echo "Tailscale" ;; netbird) echo "NetBird" ;; *) echo "mesh" ;; esac; }
_mesh_other()    { case "${1:-}" in tailscale) echo "netbird" ;; netbird) echo "tailscale" ;; esac; }
_mesh_bin()      { echo "${1:-}"; }
_mesh_unit()     { case "${1:-}" in tailscale) echo "tailscaled" ;; netbird) echo "netbird" ;; esac; }
_mesh_pkg()      { echo "${1:-}"; }
# The WireGuard port a peer reaches this server on directly (--direct opens it).
_mesh_udp_port() { case "${1:-}" in tailscale) echo 41641 ;; netbird) echo 51820 ;; esac; }
_mesh_key_flag() { case "${1:-}" in tailscale) echo "auth-key" ;; netbird) echo "setup-key" ;; esac; }
_mesh_iface_default() { case "${1:-}" in tailscale) echo "tailscale0" ;; netbird) echo "wt0" ;; esac; }

# ── state ────────────────────────────────────────────────────

_mesh_state() {
    vault_read "$MESH_STATE" 2>/dev/null || echo '{}'
}

_mesh_state_write() {
    echo "$1" | vault_write "$MESH_STATE"
}

_mesh_enabled() {
    [[ "$(_mesh_state | jq -r '.enabled // false' 2>/dev/null)" == "true" ]]
}

# The mesh this server is on: tailscale, netbird, or nothing.
_mesh_provider() {
    local st
    st=$(_mesh_state)
    [[ "$(jq -r '.enabled // false' <<< "$st" 2>/dev/null)" == "true" ]] || return 0
    jq -r '.provider // empty' <<< "$st" 2>/dev/null || true
}

_mesh_get() {   # <key> → the value in the state, or nothing
    _mesh_state | jq -r --arg k "$1" '.[$k] // empty' 2>/dev/null || true
}

# true while a lock of the mesh holds: lock_ssh, lock_http. Read by zt.sh and
# firewall.sh too, so that neither reopens what this side keeps closed.
_mesh_lock_on() {   # ssh|http
    [[ "$(_mesh_state | jq -r --arg k "lock_$1" '.[$k] // false' 2>/dev/null)" == "true" ]]
}

# Cloudflare's own lock (cipi zt lock http|ssh) — the other holder of a port.
_mesh_cf_lock_on() {   # ssh|http
    [[ "$(vault_read zt.json 2>/dev/null | jq -r --arg k "lock_$1" '.[$k] // false' 2>/dev/null)" == "true" ]]
}

_mesh_iface() {   # <provider> → its interface on this server
    local p="$1" i=""
    [[ "$(_mesh_get provider)" == "$p" ]] && i=$(_mesh_get interface)
    [[ -n "$i" ]] || i=$(_mesh_iface_default "$p")
    printf '%s' "$i"
}

_mesh_require() {   # <provider> — this provider is the server's mesh
    local p="$1" cur
    cur=$(_mesh_provider)
    if [[ "$cur" == "$p" ]]; then return 0; fi
    if [[ -n "$cur" ]]; then
        error "$(_mesh_label "$p") is not this server's mesh network: $(_mesh_label "$cur") is (cipi zt ${cur} status)"
    else
        error "$(_mesh_label "$p") is off on this server. Run: cipi zt ${p} enable --$(_mesh_key_flag "$p")=KEY"
    fi
    return 1
}

# ── what the client says ─────────────────────────────────────

_mesh_iface_ip() {   # <interface> → its IPv4 address, or nothing
    local out
    out=$(ip -4 -o addr show dev "$1" 2>/dev/null | awk '{ print $4 }' | head -n 1) || out=""
    printf '%s' "${out%%/*}"
}

_mesh_live_tailscale() {
    local raw prefs
    raw=$(_cipi_run_timed "$MESH_TIMEOUT" tailscale status --json 2>/dev/null) || raw=""
    if ! jq -e 'type == "object"' <<< "$raw" >/dev/null 2>&1; then
        echo '{"state":"not answering","connected":false}'
        return 0
    fi
    prefs=$(_cipi_run_timed "$MESH_TIMEOUT" tailscale debug prefs 2>/dev/null) || prefs=""
    jq -e 'type == "object"' <<< "$prefs" >/dev/null 2>&1 || prefs='{}'
    jq -n -c --argjson s "$raw" --argjson p "$prefs" '
        ($s.Self.TailscaleIPs // $s.TailscaleIPs // []) as $ips
        | ([$ips[] | select(test(":") | not)] | .[0]) as $v4
        | {
            state: ($s.BackendState // "unknown"),
            connected: (($s.BackendState // "") == "Running" and $v4 != null),
            online: ($s.Self.Online // false),
            ip: $v4,
            ip6: ([$ips[] | select(test(":"))] | .[0]),
            name: ($s.Self.HostName // null),
            fqdn: (($s.Self.DNSName // "") | sub("\\.$"; "") | if . == "" then null else . end),
            network: ($s.CurrentTailnet.Name // null),
            version: (($s.Version // "") | split("-")[0] // "" | if . == "" then null else . end),
            # No expiry is no field; a zero time, should one come, is no expiry either.
            key_expiry: (($s.Self.KeyExpiry // null) | if . != null and test("^000[01]-") then null else . end),
            tags: ($s.Self.Tags // []),
            peers: (($s.Peer // {}) | length),
            peers_online: ([($s.Peer // {})[] | select(.Online == true)] | length),
            provider_ssh: ($p.RunSSH // false),
            control_url: (($p.ControlURL // "") | if . == "" or . == "https://controlplane.tailscale.com" then null else . end),
            accept_dns: (if ($p | has("CorpDNS")) then $p.CorpDNS else null end),
            accept_routes: (if ($p | has("RouteAll")) then $p.RouteAll else null end),
            health: ($s.Health // [])
        }'
}

# One line of `netbird status`: "Label: value", not indented (the peers of
# --detail are, and are not this server).
_mesh_nb_field() {   # <output> <label>
    awk -v k="$2" 'index($0, k ": ") == 1 { print substr($0, length(k) + 3); exit }' <<< "$1"
}

# NetBird's text status, the one its documentation shows:
#   Management: Connected to https://api.netbird.io:443
#   FQDN: web1.netbird.cloud
#   NetBird IP: 100.92.14.7/16
#   Peers count: 3/4 Connected
# and "Daemon status: NeedsLogin" when it is not up.
_mesh_live_netbird() {
    local raw
    raw=$(_cipi_run_timed "$MESH_TIMEOUT" netbird status 2>/dev/null) || raw=""
    if [[ -z "$raw" ]]; then
        echo '{"state":"not answering","connected":false}'
        return 0
    fi
    local mgmt daemon ip fqdn ver peers ssh url="" state connected=false online=false
    mgmt=$(_mesh_nb_field "$raw" "Management")
    daemon=$(_mesh_nb_field "$raw" "Daemon status")
    ip=$(_mesh_nb_field "$raw" "NetBird IP")
    fqdn=$(_mesh_nb_field "$raw" "FQDN")
    ver=$(_mesh_nb_field "$raw" "Daemon version")
    peers=$(_mesh_nb_field "$raw" "Peers count")
    ssh=$(_mesh_nb_field "$raw" "SSH Server")
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]] || ip=""
    if [[ "$mgmt" == Connected* ]]; then
        online=true
        url=$(sed -n 's/^Connected to[[:space:]]*//p' <<< "$mgmt")
        [[ -n "$ip" ]] && connected=true
    fi
    if [[ -n "$daemon" && "$daemon" != "Connected" ]]; then
        state="$daemon"
    elif [[ "$online" == "true" ]]; then
        state="Connected"
    else
        state="Disconnected"
    fi
    local total=0 up=0
    if [[ "$peers" =~ ^([0-9]+)/([0-9]+) ]]; then up="${BASH_REMATCH[1]}"; total="${BASH_REMATCH[2]}"; fi
    jq -n -c --arg state "$state" --arg connected "$connected" --arg online "$online" --arg ip "${ip%%/*}" \
        --arg cidr "$ip" --arg fqdn "$fqdn" --arg ver "$ver" --arg url "$url" --arg ssh "$ssh" \
        --argjson total "$total" --argjson up "$up" '
        def n: if . == "" or . == "N/A" or . == "-" then null else . end;
        {
            state: $state, connected: ($connected == "true"), online: ($online == "true"),
            ip: ($ip | n), ip6: null, cidr: ($cidr | n),
            name: (($fqdn | n) as $f | if $f == null then null else ($f | split(".")[0]) end),
            fqdn: ($fqdn | n),
            network: (($fqdn | n) as $f | if $f == null then null else ($f | split(".")[1:] | join(".") | n) end),
            version: ($ver | n),
            key_expiry: null, tags: [],
            peers: $total, peers_online: $up,
            provider_ssh: ($ssh | test("^Enabled"; "i")),
            control_url: (($url | n) as $u | if $u == "https://api.netbird.io:443" then null else $u end),
            accept_dns: null, accept_routes: null, health: []
        }'
}

# What the client says, in one shape for both providers. It never fails: a
# client that is not installed or does not answer is installed/connected false.
_mesh_live() {   # <provider>
    local p="$1" bin unit iface installed=false running=false body="{}" ifip=""
    bin=$(_mesh_bin "$p"); unit=$(_mesh_unit "$p"); iface=$(_mesh_iface "$p")
    command -v "$bin" >/dev/null 2>&1 && installed=true
    systemctl is-active --quiet "$unit" 2>/dev/null && running=true
    if [[ "$installed" == "true" ]]; then
        body=$("_mesh_live_${p}" 2>/dev/null) || body="{}"
        jq -e 'type == "object"' <<< "$body" >/dev/null 2>&1 || body="{}"
    fi
    ifip=$(_mesh_iface_ip "$iface")
    jq -n -c --argjson b "$body" --arg installed "$installed" --arg running "$running" \
        --arg iface "$iface" --arg ifip "$ifip" '
        {
            installed: ($installed == "true"), running: ($running == "true"),
            state: ($b.state // (if $installed == "true" then "unknown" else "not installed" end)),
            connected: ($b.connected // false), online: ($b.online // false),
            interface: $iface, interface_up: ($ifip != ""),
            ip: ($b.ip // (if $ifip == "" then null else $ifip end)),
            ip6: ($b.ip6 // null), name: ($b.name // null), fqdn: ($b.fqdn // null),
            network: ($b.network // null), version: ($b.version // null),
            key_expiry: ($b.key_expiry // null), tags: ($b.tags // []),
            peers: {total: ($b.peers // 0), online: ($b.peers_online // 0)},
            provider_ssh: ($b.provider_ssh // false), control_url: ($b.control_url // null),
            accept_dns: (if ($b | has("accept_dns")) then $b.accept_dns else null end),
            accept_routes: (if ($b | has("accept_routes")) then $b.accept_routes else null end),
            health: ($b.health // [])
        }'
}

# Days until an RFC 3339 time; nothing when it is not one.
_mesh_days_until() {
    local ts now
    [[ -n "${1:-}" ]] || return 0
    ts=$(date -d "$1" +%s 2>/dev/null) || return 0
    now=$(date +%s)
    echo $(( (ts - now) / 86400 ))
}

# ── the SSH session that gives the command ───────────────────

_mesh_ssh_ports() {
    local ports=""
    if command -v sshd >/dev/null 2>&1; then
        ports=$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2 }' | sort -un | paste -sd' ' -) || ports=""
    fi
    echo "${ports:-22}"
}

_mesh_ssh_user() {
    id cipi >/dev/null 2>&1 && { echo "cipi"; return 0; }
    echo "root"
}

# sshd answers on the mesh address: it listens everywhere, or there.
_mesh_sshd_listens() {   # <mesh ip>
    local addrs a
    command -v sshd >/dev/null 2>&1 || return 0
    addrs=$(sshd -T 2>/dev/null | awk '$1 == "listenaddress" { print $2 }') || addrs=""
    [[ -n "$addrs" ]] || return 0
    while IFS= read -r a; do
        case "$a" in
            0.0.0.0:*|"[::]":*|"${1}":*) return 0 ;;
        esac
    done <<< "$addrs"
    return 1
}

# The address the session that runs this came from, when there is one.
_mesh_session_ip() {
    local ip=""
    ip=$(_get_client_ip 2>/dev/null) || ip=""
    [[ "$ip" == "local" ]] && ip=""
    if [[ -z "$ip" ]]; then
        ip=$(who am i 2>/dev/null | sed -n 's/.*(\([^)]*\)).*/\1/p') || ip=""
        ip="${ip%%$'\n'*}"
    fi
    [[ "$ip" =~ ^[0-9a-fA-F:.]+$ ]] || ip=""
    printf '%s' "$ip"
}

# yes: the way back to the session's address is the mesh interface — the
# command came through the mesh. no: it came some other way. unknown: there
# is no SSH session to read (a console, cron, the panel).
_mesh_session_via() {   # <interface>
    local ip
    ip=$(_mesh_session_ip)
    [[ -n "$ip" ]] || { echo "unknown"; return 0; }
    local route
    route=$(ip route get "$ip" 2>/dev/null) || route=""
    if grep -qE "(^| )dev ${1}( |\$)" <<< "$route"; then
        echo "yes"
    else
        echo "no"
    fi
    return 0
}

# ── UFW ──────────────────────────────────────────────────────

_mesh_ufw_delete_comment() {
    local comment="$1" nums n
    command -v ufw >/dev/null 2>&1 || return 0
    # "[ 1] 22/tcp …": below ten the number is padded, and is not awk's $1.
    nums=$(ufw status numbered 2>/dev/null | awk -v c="$comment" '
        index($0, c) && match($0, /^\[ *[0-9]+\]/) {
            n = substr($0, RSTART, RLENGTH); gsub(/[^0-9]/, "", n); print n
        }' | sort -nr) || nums=""
    for n in $nums; do
        yes | ufw delete "$n" >/dev/null 2>&1 || true
    done
    return 0
}

# The mesh interface through the firewall. Who reaches what on it is the
# network's own policy (the tailnet's ACL, NetBird's access policies).
_mesh_ufw_open() {   # <provider> <interface> <direct: true|false>
    command -v ufw >/dev/null 2>&1 || return 0
    _mesh_ufw_delete_comment "cipi-zt-mesh"
    ufw allow in on "$2" comment 'cipi-zt-mesh' >/dev/null 2>&1 || true
    if [[ "$3" == "true" ]]; then
        ufw allow "$(_mesh_udp_port "$1")/udp" comment 'cipi-zt-mesh-direct' >/dev/null 2>&1 || true
    fi
    return 0
}

# A lock closes a port in UFW: with UFW off there is nothing to close it with,
# and the state would say "locked" of a port that is open.
_mesh_ufw_active() {
    command -v ufw >/dev/null 2>&1 || return 1
    # Read whole, then searched: grep -q on a pipe closes it at the first
    # match, and under pipefail ufw's write error would read as "not active".
    local out
    out=$(ufw status 2>/dev/null) || out=""
    grep -qi '^Status: active' <<< "$out"
}

_mesh_require_ufw() {
    _mesh_ufw_active && return 0
    error "UFW is not active on this server: there is nothing to close the port with."
    echo "  cipi firewall status   (ufw enable, then lock)"
    return 1
}

_mesh_ufw_close_ssh() {
    command -v ufw >/dev/null 2>&1 || return 0
    local q
    for q in $(_mesh_ssh_ports); do
        yes | ufw delete allow "${q}/tcp" >/dev/null 2>&1 || true
        yes | ufw delete allow "${q}" >/dev/null 2>&1 || true
        yes | ufw delete limit "${q}/tcp" >/dev/null 2>&1 || true
    done
    return 0
}

_mesh_ufw_open_ssh() {
    command -v ufw >/dev/null 2>&1 || return 0
    local q
    for q in $(_mesh_ssh_ports); do
        ufw allow "${q}/tcp" >/dev/null 2>&1 || true
    done
    return 0
}

_mesh_ufw_close_http() {
    command -v ufw >/dev/null 2>&1 || return 0
    yes | ufw delete allow 80/tcp >/dev/null 2>&1 || true
    yes | ufw delete allow 443/tcp >/dev/null 2>&1 || true
    yes | ufw delete allow 80 >/dev/null 2>&1 || true
    yes | ufw delete allow 443 >/dev/null 2>&1 || true
    return 0
}

_mesh_ufw_open_http() {
    command -v ufw >/dev/null 2>&1 || return 0
    ufw allow 80/tcp >/dev/null 2>&1 || true
    ufw allow 443/tcp >/dev/null 2>&1 || true
    return 0
}

# ── install ──────────────────────────────────────────────────

_mesh_os_codename() {
    local c=""
    [[ -r "$MESH_OS_RELEASE" ]] && c=$(. "$MESH_OS_RELEASE" 2>/dev/null; echo "${VERSION_CODENAME:-}")
    [[ "$c" =~ ^[a-z]+$ ]] || return 1
    echo "$c"
}

_mesh_apt_install() {   # <package> <list file>
    export DEBIAN_FRONTEND=noninteractive
    if ! apt-get update -qq; then
        rm -f "$2"
        apt-get update -qq >/dev/null 2>&1 || true
        error "The apt repository of $1 failed (apt-get update)"
        return 1
    fi
    apt-get install -y -qq "$1" >/dev/null || {
        error "apt-get install $1 failed"
        return 1
    }
}

_mesh_install_tailscale() {
    command -v tailscale >/dev/null 2>&1 && return 0
    step "Installing Tailscale..."
    local code tmp
    code=$(_mesh_os_codename) || { error "Could not read this Ubuntu's codename (${MESH_OS_RELEASE})"; return 1; }
    mkdir -p "$(dirname "$MESH_TS_KEYRING")" "$(dirname "$MESH_TS_LIST")"
    # Downloaded next to the keyring and moved over it: a download that fails
    # never leaves a half-written key apt would then refuse.
    tmp=$(mktemp)
    if ! _cipi_run_timed 30 curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${code}.noarmor.gpg" -o "$tmp" 2>/dev/null \
        || [[ ! -s "$tmp" ]]; then
        rm -f "$tmp"
        error "Could not fetch Tailscale's package signing key (pkgs.tailscale.com, Ubuntu ${code})"
        return 1
    fi
    install -m 644 "$tmp" "$MESH_TS_KEYRING"
    rm -f "$tmp"
    echo "deb [signed-by=${MESH_TS_KEYRING}] https://pkgs.tailscale.com/stable/ubuntu ${code} main" > "$MESH_TS_LIST"
    _mesh_apt_install tailscale "$MESH_TS_LIST" || return 1
    systemctl enable --now tailscaled >/dev/null 2>&1 || true
    command -v tailscale >/dev/null 2>&1
}

_mesh_install_netbird() {
    command -v netbird >/dev/null 2>&1 && return 0
    step "Installing NetBird..."
    local tmp
    mkdir -p "$(dirname "$MESH_NB_KEYRING")" "$(dirname "$MESH_NB_LIST")"
    tmp=$(mktemp)
    if ! _cipi_run_timed 30 curl -fsSL "https://pkgs.netbird.io/debian/public.key" -o "$tmp" 2>/dev/null \
        || ! grep -q 'BEGIN PGP PUBLIC KEY BLOCK' "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        error "Could not fetch NetBird's package signing key (pkgs.netbird.io)"
        return 1
    fi
    install -m 644 "$tmp" "$MESH_NB_KEYRING"
    rm -f "$tmp"
    echo "deb [signed-by=${MESH_NB_KEYRING}] https://pkgs.netbird.io/debian stable main" > "$MESH_NB_LIST"
    _mesh_apt_install netbird "$MESH_NB_LIST" || return 1
    # The package starts its service; a binary that came another way does not.
    if ! systemctl is-active --quiet netbird 2>/dev/null; then
        netbird service install >/dev/null 2>&1 || true
        netbird service start >/dev/null 2>&1 || true
    fi
    command -v netbird >/dev/null 2>&1
}

_mesh_uninstall() {   # <provider>
    local p="$1"
    export DEBIAN_FRONTEND=noninteractive
    case "$p" in
        tailscale)
            _cipi_run_timed 30 tailscale logout >/dev/null 2>&1 || true
            systemctl disable --now tailscaled >/dev/null 2>&1 || true
            apt-get purge -y -qq tailscale >/dev/null 2>&1 || true
            rm -f "$MESH_TS_LIST" "$MESH_TS_KEYRING"
            ;;
        netbird)
            # deregister removes the peer from the network; an older client
            # only knows down.
            _cipi_run_timed 30 netbird deregister >/dev/null 2>&1 \
                || _cipi_run_timed 30 netbird down >/dev/null 2>&1 || true
            netbird service stop >/dev/null 2>&1 || true
            netbird service uninstall >/dev/null 2>&1 || true
            apt-get purge -y -qq netbird >/dev/null 2>&1 || true
            rm -f "$MESH_NB_LIST" "$MESH_NB_KEYRING"
            ;;
    esac
    apt-get update -qq >/dev/null 2>&1 || true
    return 0
}

# ── join ─────────────────────────────────────────────────────

# The join key is handed over in a file only root reads, never on a command
# line `ps` shows.
_mesh_key_file() {   # <key> → path
    local f
    f=$(mktemp) || return 1
    chmod 600 "$f"
    printf '%s\n' "$1" > "$f"
    printf '%s' "$f"
}

_mesh_join_tailscale() {   # <key file|""> <hostname> <tags> <url> <dns> <routes> <ssh> <reauth>
    local -a a=(up --reset "--timeout=${MESH_JOIN_TIMEOUT}s")
    [[ -n "$1" ]] && a+=("--auth-key=file:${1}")
    [[ -n "$2" ]] && a+=("--hostname=${2}")
    [[ -n "$3" ]] && a+=("--advertise-tags=${3}")
    [[ -n "$4" ]] && a+=("--login-server=${4}")
    a+=("--accept-dns=${5}" "--accept-routes=${6}")
    [[ "$7" == "true" ]] && a+=(--ssh)
    [[ "$8" == "true" ]] && a+=(--force-reauth)
    _cipi_run_timed "$((MESH_JOIN_TIMEOUT + 15))" tailscale "${a[@]}"
}

_mesh_join_netbird() {   # <key file|""> <hostname> <url> <dns> <routes>
    local -a a=(up)
    [[ -n "$1" ]] && a+=(--setup-key-file "$1")
    [[ -n "$2" ]] && a+=(--hostname "$2")
    [[ -n "$3" ]] && a+=(--management-url "$3")
    # Said either way: the client keeps the last value it was given.
    if [[ "$4" == "true" ]]; then a+=(--disable-dns=false); else a+=(--disable-dns=true); fi
    if [[ "$5" == "true" ]]; then a+=(--disable-client-routes=false); else a+=(--disable-client-routes=true); fi
    _cipi_run_timed "$((MESH_JOIN_TIMEOUT + 15))" netbird "${a[@]}"
}

# tag:web,db → tag:web,tag:db — or nothing and 1 when one is not a tag name.
_mesh_tags_norm() {
    local tags="${1:-}" t out=""
    [[ -z "$tags" ]] && return 0
    local -a list
    IFS=',' read -ra list <<< "$tags"
    for t in "${list[@]}"; do
        t="${t// /}"
        [[ -z "$t" ]] && continue
        t="${t#tag:}"
        [[ "$t" =~ ^[a-zA-Z][a-zA-Z0-9-]*$ ]] || { error "Not a tag: ${t} (letters, digits and -, e.g. --tags=tag:cipi)"; return 1; }
        out+="${out:+,}tag:${t}"
    done
    printf '%s' "$out"
}

# ── enable ───────────────────────────────────────────────────

_mesh_enable() {
    local p="$1"; shift
    parse_args "$@"
    local label other cur flag key
    label=$(_mesh_label "$p"); other=$(_mesh_other "$p"); flag=$(_mesh_key_flag "$p")

    cur=$(_mesh_provider)
    if [[ -n "$cur" && "$cur" != "$p" ]]; then
        error "$(_mesh_label "$cur") is this server's mesh network already — one at a time."
        echo "  Tailscale and NetBird both hand out addresses in 100.64.0.0/10, and Tailscale drops"
        echo "  what comes from that range outside its own interface: the two break each other."
        echo "  Leave the other first: cipi zt ${cur} disable"
        exit 1
    fi
    if [[ "${ARG_force:-}" != "true" ]] && { command -v "$(_mesh_bin "$other")" >/dev/null 2>&1 \
        || [[ -n "$(_mesh_iface_ip "$(_mesh_iface_default "$other")")" ]]; }; then
        error "$(_mesh_label "$other") is installed on this server — one mesh at a time."
        echo "  Both use 100.64.0.0/10, and Tailscale drops that range outside its own interface."
        if [[ "$(_mesh_get provider)" == "$other" ]]; then
            echo "  Remove it first: cipi zt ${other} disable"
        else
            echo "  Remove it first (it was not installed through Cipi), or pass --force if the two do not overlap here."
        fi
        exit 1
    fi

    # What was asked, checked before anything is installed.
    local host="${ARG_hostname:-}" url="" tags="" dns=false routes=false direct=false ssh=false
    if [[ -n "$host" && ! "$host" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
        error "Not a hostname: ${host} (letters, digits and -, up to 63)"; exit 1
    fi
    [[ "${ARG_accept_dns:-}" == "true" ]] && dns=true
    [[ "${ARG_accept_routes:-}" == "true" ]] && routes=true
    [[ "${ARG_direct:-}" == "true" ]] && direct=true
    if [[ "$p" == "tailscale" ]]; then
        url="${ARG_login_server:-}"
        tags=$(_mesh_tags_norm "${ARG_tags:-}") || exit 1
        [[ "${ARG_ssh:-}" == "true" ]] && ssh=true
        [[ -z "${ARG_management_url:-}" ]] || { error "--management-url is NetBird's; Tailscale's (Headscale) is --login-server="; exit 1; }
    else
        url="${ARG_management_url:-}"
        if [[ "${ARG_reauth:-}" == "true" ]]; then
            error "--reauth is Tailscale's: a NetBird peer that is registered is not signed in again."
            echo "  With a new setup key: cipi zt netbird disable, then cipi zt netbird enable --setup-key=KEY"
            exit 1
        fi
        [[ -z "${ARG_login_server:-}" && -z "${ARG_tags:-}" ]] || { error "--login-server and --tags are Tailscale's; NetBird's are --management-url= and the groups of its setup key"; exit 1; }
        if [[ "${ARG_ssh:-}" == "true" ]]; then
            error "NetBird's own SSH server is not something Cipi turns on: it takes port 22 of the mesh address"
            echo "  away from OpenSSH and signs people in its own way. SSH over NetBird is plain OpenSSH"
            echo "  (ssh $(_mesh_ssh_user)@<mesh address>) with the keys of cipi ssh, where a NetBird policy allows TCP 22."
            exit 1
        fi
    fi
    if [[ -n "$url" && ! "$url" =~ ^https?://[A-Za-z0-9._-]+(:[0-9]+)?(/[A-Za-z0-9._~/-]*)?$ ]]; then
        error "Not a URL: ${url} (https://host[:port])"; exit 1
    fi

    key="${ARG_key:-}"
    [[ -n "$key" ]] || { [[ "$p" == "tailscale" ]] && key="${ARG_auth_key:-}" || key="${ARG_setup_key:-}"; }
    if [[ -z "$key" && -n "${ARG_key_file:-}" ]]; then
        [[ -r "${ARG_key_file}" ]] || { error "Cannot read ${ARG_key_file}"; exit 1; }
        key=$(tr -d '[:space:]' < "${ARG_key_file}")
    fi
    if [[ -n "$key" && ! "$key" =~ ^[A-Za-z0-9._~:?\&=%+/-]+$ ]]; then
        error "That does not look like a key (no spaces, no quotes)"; exit 1
    fi

    local had_client=false live connected
    command -v "$(_mesh_bin "$p")" >/dev/null 2>&1 && had_client=true
    live=$(_mesh_live "$p")
    connected=$(jq -r '.connected' <<< "$live")

    local prev by_cipi
    prev=$(_mesh_state)
    # Whose client it is: once Cipi installed it, it stays Cipi's.
    by_cipi=$(jq -r '.installed_by_cipi // false' <<< "$prev")
    [[ "$had_client" == "true" ]] || by_cipi=true

    local joined=false
    if [[ "$connected" == "true" && "${ARG_reauth:-}" != "true" ]]; then
        # Already on the network: taken as it is. Its settings are the
        # operator's (or a previous enable's); only what was asked changes.
        info "${label} is connected already ($(jq -r '.ip // "?"' <<< "$live")) — kept as it is"
        if [[ "$dns" == "true" || "$routes" == "true" || -n "$tags" || -n "$url" ]]; then
            if [[ "$p" == "tailscale" ]]; then
                warn "--accept-dns, --accept-routes, --tags and --login-server are given when joining: add --reauth (and a key) to apply them"
            else
                warn "--accept-dns, --accept-routes and --management-url are given when joining: disable, then enable again to apply them"
            fi
        fi
        # What the client really has, where it says so; what was there before otherwise.
        # (jq's // would take a false for "unknown": asked by name.)
        dns=$(jq -r --argjson prev "$prev" '(if .accept_dns != null then .accept_dns else ($prev.accept_dns // false) end) == true' <<< "$live")
        routes=$(jq -r --argjson prev "$prev" '(if .accept_routes != null then .accept_routes else ($prev.accept_routes // false) end) == true' <<< "$live")
        tags=""; url=""
        if [[ "$p" == "tailscale" ]]; then
            [[ -z "$host" ]] || tailscale set "--hostname=${host}" >/dev/null 2>&1 || warn "Could not set the hostname"
            if [[ "$ssh" == "true" && "$(jq -r '.provider_ssh' <<< "$live")" != "true" ]]; then
                tailscale set --ssh >/dev/null 2>&1 || warn "Could not turn Tailscale SSH on: cipi zt tailscale ssh enable"
            fi
        fi
        [[ "$(jq -r '.provider_ssh' <<< "$live")" == "true" ]] && ssh=true
    else
        if [[ -z "$key" && -t 0 ]]; then
            read_input "${label} ${flag//-/ }" "" key
        fi
        if [[ -z "$key" ]]; then
            error "A key is needed to join the network: cipi zt ${p} enable --${flag}=KEY"
            if [[ "$p" == "tailscale" ]]; then
                echo "  Admin console → Settings → Keys → Generate auth key. For a server: with a tag"
                echo "  (the node key of a tagged machine does not expire) and pre-approved."
            else
                echo "  Dashboard → Setup Keys → Create Setup Key (its groups decide what reaches the server)."
            fi
            exit 1
        fi
        "_mesh_install_${p}" || exit 1
        local kf rc=0
        kf=$(_mesh_key_file "$key") || { error "Could not write the key to a temporary file"; exit 1; }
        step "Joining the ${label} network..."
        if [[ "$p" == "tailscale" ]]; then
            _mesh_join_tailscale "$kf" "$host" "$tags" "$url" "$dns" "$routes" "$ssh" "${ARG_reauth:-false}" || rc=$?
        else
            _mesh_join_netbird "$kf" "$host" "$url" "$dns" "$routes" || rc=$?
        fi
        rm -f "$kf"
        if [[ $rc -ne 0 ]]; then
            error "${label} did not join the network (exit ${rc}): the key is wrong, expired or used up, or the network cannot be reached."
            [[ "$by_cipi" == "true" && "$had_client" != "true" ]] && echo "  The client stays installed; run enable again with a valid key, or: cipi zt ${p} disable"
            # Kept, so that disable knows the client is Cipi's and removes it.
            _mesh_state_write "$(jq -c --arg p "$p" --argjson by "$by_cipi" \
                '. + {provider: $p, installed_by_cipi: $by, enabled: (.enabled // false)}' <<< "$prev")"
            exit 1
        fi
        joined=true
        local i
        for i in $(seq 1 "$MESH_WAIT"); do
            live=$(_mesh_live "$p")
            [[ "$(jq -r '.connected' <<< "$live")" == "true" ]] && break
            sleep 1
        done
    fi

    local iface ip
    iface="${ARG_interface:-}"
    [[ "$iface" =~ ^[a-zA-Z0-9_.-]{1,15}$ ]] || iface=$(_mesh_iface "$p")
    ip=$(jq -r '.ip // empty' <<< "$live")
    _mesh_ufw_open "$p" "$iface" "$direct"

    local now st
    now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    st=$(jq -c --arg p "$p" --arg t "$now" --arg iface "$iface" --arg host "$host" --arg url "$url" \
        --arg tags "$tags" --argjson by "$by_cipi" --argjson dns "$dns" --argjson routes "$routes" \
        --argjson direct "$direct" --argjson ssh "$ssh" '
        . + {
            provider: $p, enabled: true, enabled_at: (if (.enabled // false) then (.enabled_at // $t) else $t end),
            interface: $iface, installed_by_cipi: $by,
            hostname: (if $host != "" then $host else (.hostname // "") end),
            control_url: (if $url != "" then $url else (.control_url // "") end),
            tags: (if $tags != "" then $tags else (.tags // "") end),
            accept_dns: $dns, accept_routes: $routes, direct: $direct, provider_ssh: $ssh,
            lock_ssh: (.lock_ssh // false), lock_http: (.lock_http // false)
        }' <<< "$prev")
    _mesh_state_write "$st"

    log_action "ZT MESH ENABLE provider=${p} ip=${ip:-?} joined=${joined}"
    if [[ "$(jq -r '.connected' <<< "$live")" != "true" ]]; then
        warn "${label} joined, but does not say it is connected yet ($(jq -r '.state' <<< "$live")). Check: cipi zt ${p} status"
    fi
    if [[ -z "$(_mesh_iface_ip "$iface")" ]]; then
        warn "No address on ${iface} yet: lock ssh waits for it (userspace networking has no interface at all)."
    fi
    cipi_notify \
        "Cipi Zero Trust: ${label} enabled on $(hostname)" \
        "This server is on the ${label} network${ip:+ as ${ip}}. The mesh interface (${iface}) is allowed through UFW; ports 22/80/443 are still open to the world.\n\nNext:\n  ssh $(_mesh_ssh_user)@${ip:-<mesh address>}        # from a device of the network\n  cipi zt ${p} lock ssh           # from that session: close port 22 to the world\n  cipi zt ${p} lock http          # a private server: 80/443 over the mesh only\n\nTime: $(notify_now)" \
        zt_enable
    success "${label} enabled${ip:+ — this server is ${ip}}. Ports are still open."
    echo ""
    echo -e "  ${DIM}SSH over the mesh:${NC}   ${CYAN}ssh $(_mesh_ssh_user)@${ip:-<mesh address>}${NC}"
    echo -e "  ${DIM}Then, from there:${NC}    ${CYAN}cipi zt ${p} lock ssh${NC}"
    echo -e "  ${DIM}A private server:${NC}    ${CYAN}cipi zt ${p} lock http${NC}"
    if [[ "$p" == "tailscale" ]]; then
        echo -e "  ${DIM}Who reaches what is the tailnet's access policy: let the people who run the server reach tcp 22, 80, 443 of it.${NC}"
        local exp
        exp=$(jq -r '.key_expiry // empty' <<< "$live")
        if [[ -n "$exp" ]]; then
            warn "The node key of this machine expires on ${exp%%T*}: after that it is off the tailnet until someone signs it in again."
            echo "  Admin console → Machines → this server → Disable key expiry — or join with a tagged key (--tags=, --reauth)."
        fi
    else
        echo -e "  ${DIM}Who reaches what is a NetBird access policy: let the people who run the server reach TCP 22, 80, 443 of it.${NC}"
    fi
    echo ""
}

# ── disable ──────────────────────────────────────────────────

_mesh_disable() {
    local p="$1"; shift
    parse_args "$@"
    local label st by_cipi iface
    label=$(_mesh_label "$p")
    st=$(_mesh_state)
    if [[ "$(jq -r '.provider // empty' <<< "$st")" != "$p" ]]; then
        local cur; cur=$(_mesh_provider)
        if [[ -n "$cur" ]]; then
            error "${label} is not this server's mesh network: $(_mesh_label "$cur") is (cipi zt ${cur} disable)"
            exit 1
        fi
        info "${label} is off on this server"
        return 0
    fi
    by_cipi=$(jq -r '.installed_by_cipi // false' <<< "$st")
    iface=$(_mesh_iface "$p")
    if [[ "${ARG_force:-}" != "true" && "${ARG_yes:-}" != "true" ]]; then
        if [[ "$(_mesh_session_via "$iface")" == "yes" ]]; then
            warn "You are connected through ${label}: this session ends when it stops. Port 22 is reopened first."
        fi
        if [[ "$by_cipi" == "true" ]]; then
            confirm "Leave the ${label} network, remove its client and reopen what its locks closed?" \
                || { info "Aborted"; return 0; }
        else
            confirm "Take ${label} out of Cipi and reopen what its locks closed? The client was here before Cipi: it stays installed and connected." \
                || { info "Aborted"; return 0; }
        fi
    fi

    # What the locks closed comes back first: nobody is left outside.
    if [[ "$(jq -r '.lock_ssh // false' <<< "$st")" == "true" ]]; then
        if _mesh_cf_lock_on ssh; then
            warn "Port 22 stays closed: Cloudflare's lock holds it (cipi zt ssh unlock)"
        else
            step "Reopening the SSH port..."
            _mesh_ufw_open_ssh
        fi
    fi
    if [[ "$(jq -r '.lock_http // false' <<< "$st")" == "true" ]]; then
        if _mesh_cf_lock_on http; then
            warn "Ports 80/443 stay as Cloudflare's lock keeps them (cipi zt unlock http)"
        else
            step "Reopening ports 80/443..."
            _mesh_ufw_open_http
        fi
    fi
    _mesh_ufw_delete_comment "cipi-zt-mesh"

    _mesh_state_write '{"enabled":false,"provider":"","lock_ssh":false,"lock_http":false}'
    log_action "ZT MESH DISABLE provider=${p}"
    cipi_notify \
        "Cipi Zero Trust: ${label} disabled on $(hostname)" \
        "The server left the ${label} mesh as far as Cipi goes: its firewall rule is gone and what its locks closed is open again.\nTime: $(notify_now)" \
        zt_disable

    if [[ "$by_cipi" == "true" ]]; then
        step "Leaving the network and removing ${label}..."
        # The client goes last, with the hangup ignored and nothing written to
        # the terminal: a session that came over the mesh ends here, and the
        # removal still runs to its end.
        trap '' HUP
        _mesh_uninstall "$p" >/dev/null 2>&1 || true
    else
        info "${label} was on this server before Cipi: left installed and connected (its own firewall rules included)"
    fi
    success "${label} disabled" 2>/dev/null || true
}

# ── status ───────────────────────────────────────────────────

# The mesh of this server, for `cipi zt <provider> status --json` and as the
# `mesh` of `cipi zt status --json`. Without a provider: the one that is on.
_mesh_status_json() {
    local p="${1:-}" st cur
    st=$(_mesh_state)
    cur=$(_mesh_provider)
    if [[ -z "$p" ]]; then p="$cur"; fi
    if [[ -z "$p" || "$p" != "$cur" ]]; then
        jq -n -c --arg p "$p" --arg cur "$cur" \
            '{enabled: false, provider: (if $p == "" then null else $p end), active: (if $cur == "" then null else $cur end)}'
        return 0
    fi
    local live days="" ports
    live=$(_mesh_live "$p")
    days=$(_mesh_days_until "$(jq -r '.key_expiry // empty' <<< "$live")")
    ports=$(_mesh_ssh_ports | tr ' ' '\n' | jq -R 'tonumber?' | jq -sc .) || ports='[22]'
    jq -n -c --argjson st "$st" --argjson live "$live" --arg p "$p" --arg label "$(_mesh_label "$p")" \
        --arg days "$days" --argjson ports "$ports" --arg user "$(_mesh_ssh_user)" \
        --argjson udp "$(_mesh_udp_port "$p")" '
        ($days | if . == "" then null else tonumber end) as $d
        | {
            enabled: true, provider: $p, label: $label,
            installed: $live.installed, installed_by_cipi: ($st.installed_by_cipi // false),
            running: $live.running, connected: $live.connected, state: $live.state, online: $live.online,
            interface: $live.interface, interface_up: $live.interface_up,
            ip: $live.ip, ip6: $live.ip6, name: $live.name, fqdn: $live.fqdn, network: $live.network,
            control_url: ($live.control_url // (($st.control_url // "") | if . == "" then null else . end)),
            version: $live.version, tags: $live.tags,
            key_expiry: $live.key_expiry, key_expires_in_days: $d,
            peers: $live.peers,
            ssh: {
                provider_ssh: $live.provider_ssh, ports: $ports,
                command: (if $live.ip != null then "ssh \($user)@\($live.ip)" else null end)
            },
            lock: {ssh: ($st.lock_ssh // false), http: ($st.lock_http // false)},
            direct: {port: $udp, open: ($st.direct // false)},
            accept_dns: (if $live.accept_dns != null then $live.accept_dns else ($st.accept_dns // false) end),
            accept_routes: (if $live.accept_routes != null then $live.accept_routes else ($st.accept_routes // false) end),
            enabled_at: ($st.enabled_at // null),
            warnings: ([
                (if ($live.installed | not) then "The \($label) client is not installed any more" else empty end),
                (if $live.installed and ($live.connected | not) then "\($label) is not connected (\($live.state))" else empty end),
                (if $live.connected and ($live.online | not) then "The coordination server cannot be reached: the connections that are open keep working, new devices cannot find this server" else empty end),
                (if $d != null and $d <= 0 then "The node key has expired"
                 elif $d != null then "The node key expires in \($d) days: disable key expiry for this machine, or join with a tagged key" else empty end),
                (if $p == "netbird" and $live.provider_ssh then "NetBird\u0027s own SSH server is on: it answers port 22 of the mesh address in place of OpenSSH" else empty end),
                (if ($st.lock_ssh // false) and ($live.connected | not) then "SSH is locked to the mesh and the mesh is down: the provider\u0027s console is the way in" else empty end)
            ])
        }'
}

_mesh_row() { printf "  %-16s ${CYAN}%s${NC}\n" "$1" "$2"; }

# The lines `cipi zt status` adds under Cloudflare's, and the body of
# `cipi zt <provider> status`.
_mesh_status_lines() {   # <status json>
    local j="$1" p label
    p=$(jq -r '.provider' <<< "$j"); label=$(jq -r '.label' <<< "$j")
    _mesh_row "$(_mesh_unit "$p")" "$(jq -r 'if .running then "running" else "stopped" end' <<< "$j")"
    _mesh_row "State" "$(jq -r 'if .connected then "connected" else "disconnected" end + " (" + (.state // "?") + ")"' <<< "$j")"
    _mesh_row "Address" "$(jq -r '[.ip // "none", .fqdn // empty] | join("   ")' <<< "$j")"
    _mesh_row "Network" "$(jq -r '[.network // "?", (.control_url // empty | "via " + .)] | join("  ")' <<< "$j")"
    _mesh_row "Interface" "$(jq -r '.interface + (if .interface_up then "" else " (down)" end)' <<< "$j")"
    _mesh_row "Peers" "$(jq -r '"\(.peers.online)/\(.peers.total) online"' <<< "$j")"
    if [[ "$p" == "tailscale" ]]; then
        _mesh_row "Node key" "$(jq -r 'if .key_expiry == null then "does not expire" else "expires \(.key_expiry | split("T")[0]) (\(.key_expires_in_days) days)" end' <<< "$j")"
        _mesh_row "Tags" "$(jq -r 'if (.tags | length) > 0 then (.tags | join(", ")) else "none" end' <<< "$j")"
        _mesh_row "Tailscale SSH" "$(jq -r 'if .ssh.provider_ssh then "on (the tailnet policy signs people in)" else "off (OpenSSH, your keys)" end' <<< "$j")"
    fi
    _mesh_row "lock ssh" "$(jq -r '.lock.ssh' <<< "$j")"
    _mesh_row "lock http" "$(jq -r '.lock.http' <<< "$j")"
    _mesh_row "Direct port" "$(jq -r '"\(.direct.port)/udp " + (if .direct.open then "open" else "closed (peers reach it through relays or hole punching)" end)' <<< "$j")"
    local w
    while IFS= read -r w; do
        [[ -n "$w" ]] && echo -e "  ${YELLOW}! ${w}${NC}"
    done < <(jq -r '.warnings[]?' <<< "$j")
    local cmd
    cmd=$(jq -r '.ssh.command // empty' <<< "$j")
    [[ -n "$cmd" ]] && echo -e "\n  ${DIM}SSH over the mesh:${NC} ${CYAN}${cmd}${NC}"
    return 0
}

_mesh_status() {
    local p="$1"; shift
    parse_args "$@"
    local j
    j=$(_mesh_status_json "$p")
    if [[ "${ARG_json:-}" == "true" ]]; then
        echo "$j"
        return 0
    fi
    local label; label=$(_mesh_label "$p")
    echo ""
    echo -e "  ${BOLD}${label}${NC} ${DIM}— mesh network${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [[ "$(jq -r '.enabled' <<< "$j")" != "true" ]]; then
        local cur; cur=$(jq -r '.active // empty' <<< "$j")
        if [[ -n "$cur" ]]; then
            echo -e "  ${DIM}off — this server's mesh is $(_mesh_label "$cur")${NC}  —  ${CYAN}cipi zt ${cur} status${NC}"
        else
            echo -e "  ${DIM}off${NC}  —  ${CYAN}cipi zt ${p} enable --$(_mesh_key_flag "$p")=KEY${NC}"
        fi
        echo ""
        return 0
    fi
    _mesh_status_lines "$j"
    echo ""
}

# ── SSH ──────────────────────────────────────────────────────

_mesh_ssh() {
    local p="$1"; shift
    local action="${1:-}"; shift || true
    case "$action" in
        enable|on)   _mesh_ssh_provider "$p" true "$@" ;;
        disable|off) _mesh_ssh_provider "$p" false "$@" ;;
        unlock)      _mesh_unlock_ssh "$p" "$@" ;;
        status|"")   _mesh_ssh_status "$p" ;;
        *) error "Usage: cipi zt ${p} ssh enable|disable|status|unlock"; exit 1 ;;
    esac
}

_mesh_ssh_status() {
    local p="$1" j
    _mesh_require "$p" || exit 1
    j=$(_mesh_status_json "$p")
    echo ""
    if [[ "$(jq -r '.ssh.provider_ssh' <<< "$j")" == "true" ]]; then
        echo -e "  ${BOLD}$(_mesh_label "$p") SSH${NC} answers port 22 of the mesh address: the network's policy signs people in."
    else
        echo -e "  ${BOLD}OpenSSH${NC} answers on the mesh address, with the keys of ${CYAN}cipi ssh${NC}."
    fi
    echo -e "  $(jq -r '.ssh.command // "no mesh address yet"' <<< "$j")"
    echo -e "  ${DIM}Port 22 to the world: $(jq -r 'if .lock.ssh then "closed (cipi zt '"$p"' unlock ssh)" else "open (cipi zt '"$p"' lock ssh)" end' <<< "$j")${NC}"
    echo ""
}

# Tailscale SSH: tailscaled answers port 22 of the tailnet address itself and
# signs people in by the tailnet's SSH policy — no keys on the server.
_mesh_ssh_provider() {
    local p="$1" on="$2"; shift 2
    parse_args "$@"
    _mesh_require "$p" || exit 1
    if [[ "$p" != "tailscale" ]]; then
        error "NetBird's own SSH server is not something Cipi turns on: it takes port 22 of the mesh address"
        echo "  away from OpenSSH and signs people in its own way. SSH over NetBird is plain OpenSSH"
        echo "  (ssh $(_mesh_ssh_user)@<mesh address>) with the keys of cipi ssh, where a NetBird policy allows TCP 22."
        exit 1
    fi
    local iface; iface=$(_mesh_iface "$p")
    local -a a=(set)
    if [[ "$on" == "true" ]]; then a+=(--ssh); else a+=(--ssh=false); fi
    if [[ "$(_mesh_session_via "$iface")" == "yes" ]]; then
        if [[ "${ARG_force:-}" != "true" ]]; then
            error "You are connected over the tailnet: port 22 of that address changes hands and this session may end."
            echo "  Run it from a session on the public address, or pass --force."
            exit 1
        fi
        a+=(--accept-risk=lose-ssh)
    fi
    local out
    out=$(_cipi_run_timed 30 tailscale "${a[@]}" 2>&1) || {
        error "tailscale ${a[*]} failed"
        [[ -n "$out" ]] && echo "$out" | sed 's/^/  /'
        exit 1
    }
    _mesh_state_write "$(jq -c --argjson on "$on" '.provider_ssh = $on' <<< "$(_mesh_state)")"
    log_action "ZT MESH SSH provider=${p} tailscale_ssh=${on}"
    if [[ "$on" == "true" ]]; then
        success "Tailscale SSH is on: port 22 of the tailnet address is Tailscale's"
        echo -e "  ${DIM}Who signs in as whom is the \"ssh\" section of the tailnet policy — e.g. the people who run the"
        echo -e "  server as $(_mesh_ssh_user). OpenSSH and its keys keep answering on every other address.${NC}"
    else
        success "Tailscale SSH is off: OpenSSH answers on the tailnet address, with the keys of cipi ssh"
    fi
}

# ── locks ────────────────────────────────────────────────────

_mesh_lock() {
    local p="$1"; shift
    local what="${1:-}"; shift || true
    case "$what" in
        ssh)  _mesh_lock_ssh "$p" "$@" ;;
        http) _mesh_lock_http "$p" "$@" ;;
        *) error "Usage: cipi zt ${p} lock ssh|http [--yes]"; exit 1 ;;
    esac
}

_mesh_unlock() {
    local p="$1"; shift
    local what="${1:-}"; shift || true
    case "$what" in
        ssh)  _mesh_unlock_ssh "$p" "$@" ;;
        http) _mesh_unlock_http "$p" "$@" ;;
        *) error "Usage: cipi zt ${p} unlock ssh|http"; exit 1 ;;
    esac
}

_mesh_lock_ssh() {
    local p="$1"; shift
    parse_args "$@"
    _mesh_require "$p" || exit 1
    local label live ip iface user
    label=$(_mesh_label "$p"); iface=$(_mesh_iface "$p"); user=$(_mesh_ssh_user)
    live=$(_mesh_live "$p")
    ip=$(jq -r '.ip // empty' <<< "$live")
    if [[ "$(jq -r '.connected' <<< "$live")" != "true" || -z "$ip" ]]; then
        error "${label} is not connected ($(jq -r '.state' <<< "$live")) — refusing to close the SSH port (you would lock yourself out)."
        echo "  Check: cipi zt ${p} status   systemctl status $(_mesh_unit "$p")"
        exit 1
    fi
    if [[ "$(jq -r '.provider_ssh' <<< "$live")" != "true" ]] && ! _mesh_sshd_listens "$ip"; then
        error "sshd does not listen on the mesh address ${ip} (ListenAddress): nothing would answer there."
        echo "  Let it listen everywhere (the firewall decides who reaches it), then lock."
        exit 1
    fi
    # A node key that expires takes the server off the network on that day:
    # with port 22 closed, there is no way in then but the provider's console.
    local exp days
    exp=$(jq -r '.key_expiry // empty' <<< "$live")
    if [[ -n "$exp" && "${ARG_force:-}" != "true" ]]; then
        days=$(_mesh_days_until "$exp")
        error "The node key of this machine expires on ${exp%%T*}${days:+ (${days} days)}: on that day the server leaves the tailnet,"
        echo "  and with port 22 closed the only way in is the provider's console."
        echo "  Admin console → Machines → this server → Disable key expiry — or join again with a tagged"
        echo "  key, whose node key does not expire: cipi zt tailscale enable --auth-key=KEY --tags=tag:cipi --reauth"
        echo "  --force locks all the same (the monitor warns before the key expires)."
        exit 1
    fi
    # The proof that SSH over the mesh works is this very session.
    local via
    via=$(_mesh_session_via "$iface")
    if [[ "$via" != "yes" && "${ARG_force:-}" != "true" ]]; then
        if [[ "$via" == "no" ]]; then
            error "This session did not come through ${label} — refusing to close the door you came in by."
        else
            error "No SSH session to check — closing the SSH port is done from a session that came through ${label}."
        fi
        echo "  From a device of the network:  ssh ${user}@${ip}"
        echo "  and from there:                cipi zt ${p} lock ssh"
        echo "  That the command arrives that way is the proof that it works. --force skips the check."
        exit 1
    fi
    _mesh_require_ufw || exit 1
    local ports; ports=$(_mesh_ssh_ports)
    if [[ "${ARG_yes:-}" != "true" ]]; then
        echo ""
        echo -e "  This closes ${BOLD}port ${ports// /, }${NC} to the internet. SSH will only work from the ${label} network:"
        echo -e "    ${CYAN}ssh ${user}@${ip}${NC}"
        echo -e "  If ${label} stops, the way in is the provider's console (then: cipi zt ${p} unlock ssh)."
        echo -e "  Rules of your own for single addresses (cipi firewall allow 22 --from=) stay. Deployer uses localhost."
        echo ""
        confirm "Close the SSH port to the world?" || { info "Aborted"; return 0; }
    fi
    _mesh_ufw_close_ssh
    _mesh_state_write "$(jq -c '.lock_ssh = true' <<< "$(_mesh_state)")"
    log_action "ZT MESH LOCK SSH provider=${p}"
    log_event "SSH port closed to the world (${label}) on $(hostname)"
    cipi_notify \
        "Cipi locked SSH on $(hostname) (${label})" \
        "Port ${ports// /, } is closed to the world. SSH is only over the ${label} network: ssh ${user}@${ip}. Unlock with: cipi zt ${p} unlock ssh\nTime: $(notify_now)" \
        zt_lock_ssh
    success "SSH port closed to the world. SSH is ${label}-only (${ip}). Unlock: cipi zt ${p} unlock ssh"
}

_mesh_unlock_ssh() {
    local p="$1"; shift
    parse_args "$@"
    _mesh_require "$p" || exit 1
    _mesh_state_write "$(jq -c '.lock_ssh = false' <<< "$(_mesh_state)")"
    log_action "ZT MESH UNLOCK SSH provider=${p}"
    if _mesh_cf_lock_on ssh; then
        warn "The mesh no longer holds port 22, but Cloudflare's lock does: it stays closed (cipi zt ssh unlock)"
        return 0
    fi
    _mesh_ufw_open_ssh
    success "SSH port reopened to the world"
}

# The apps whose certificate renews over HTTP-01: port 80 closed to the world,
# Let's Encrypt cannot reach them any more.
_mesh_http01_apps() {
    local a d cert out=""
    while IFS= read -r a; do
        [[ -z "$a" ]] && continue
        [[ "$(app_get "$a" ssl_origin_ca 2>/dev/null || true)" == "true" ]] && continue
        [[ -n "$(app_get "$a" ssl_dns_provider 2>/dev/null || true)" ]] && continue
        d=$(app_get "$a" domain 2>/dev/null || true)
        [[ -z "$d" ]] && continue
        cert="$d"
        declare -f domain_cert_name >/dev/null 2>&1 && cert=$(domain_cert_name "$d")
        [[ -d "${MESH_LE_LIVE}/${cert}" ]] && out+=" ${a}"
    done < <(vault_read apps.json 2>/dev/null | jq -r 'keys[]?' 2>/dev/null)
    printf '%s' "$out"
}

_mesh_lock_http() {
    local p="$1"; shift
    parse_args "$@"
    _mesh_require "$p" || exit 1
    local label live ip
    label=$(_mesh_label "$p")
    live=$(_mesh_live "$p")
    ip=$(jq -r '.ip // empty' <<< "$live")
    if [[ "$(jq -r '.connected' <<< "$live")" != "true" || -z "$ip" ]]; then
        error "${label} is not connected ($(jq -r '.state' <<< "$live")) — with 80/443 closed nothing would reach the sites."
        exit 1
    fi
    local bad
    bad=$(_mesh_http01_apps)
    if [[ -n "$bad" ]]; then
        if [[ "${ARG_force:-}" != "true" ]]; then
            error "These apps renew SSL over HTTP-01, which needs port 80 open to the world:${bad}"
            echo "  Switch each one to DNS-01 first: cipi ssl install <app> --dns=cloudflare"
            echo "  Or pass --force if you accept that those certificates will not renew."
            exit 1
        fi
        warn "HTTP-01 apps will not renew — --force noted:${bad}"
    fi
    _mesh_require_ufw || exit 1
    if [[ "${ARG_yes:-}" != "true" ]]; then
        echo ""
        echo -e "  This closes ${BOLD}ports 80 and 443${NC} to the internet. Every site, the panel and the API answer"
        echo -e "  only to the devices of the ${label} network, on ${CYAN}${ip}${NC}: point their DNS records there"
        echo -e "  (an A record to a 100.x address is fine: only the network routes to it)."
        if vault_read zt.json 2>/dev/null | jq -e '.enabled == true' >/dev/null 2>&1; then
            echo -e "  The hostnames on the Cloudflare tunnel keep working: the tunnel reaches nginx on localhost."
        fi
        echo ""
        confirm "Close 80/443 to the world?" || { info "Aborted"; return 0; }
    fi
    _mesh_ufw_close_http
    _mesh_state_write "$(jq -c '.lock_http = true' <<< "$(_mesh_state)")"
    log_action "ZT MESH LOCK HTTP provider=${p}"
    cipi_notify \
        "Cipi locked HTTP on $(hostname) (${label})" \
        "Ports 80/443 are closed to the world: the sites, the panel and the API answer on the ${label} network only (${ip}). Let's Encrypt HTTP-01 cannot renew — DNS-01 can. Unlock with: cipi zt ${p} unlock http\nTime: $(notify_now)" \
        zt_lock_http
    success "HTTP locked: 80/443 answer on the ${label} network only (${ip}). Unlock: cipi zt ${p} unlock http"
}

_mesh_unlock_http() {
    local p="$1"; shift
    parse_args "$@"
    _mesh_require "$p" || exit 1
    _mesh_state_write "$(jq -c '.lock_http = false' <<< "$(_mesh_state)")"
    log_action "ZT MESH UNLOCK HTTP provider=${p}"
    if _mesh_cf_lock_on http; then
        warn "The mesh no longer holds 80/443, but Cloudflare's lock does: they stay as it keeps them (cipi zt unlock http)"
        return 0
    fi
    _mesh_ufw_open_http
    success "Ports 80/443 world-open again"
}

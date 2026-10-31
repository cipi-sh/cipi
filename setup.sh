#!/bin/bash

#############################################
# Cipi Installer
# Version: see version.md
# Author: Andrea Pollastri
# License: MIT
#############################################

set -e
set -o pipefail

REPO="cipi-sh/cipi"
BRANCH="${1:-latest}"
BUILD=""  # resolved from version.md after git clone in install_cipi()

CIPI_LIB="/opt/cipi/lib"
CIPI_CONFIG="/etc/cipi"
CIPI_LOG="/var/log/cipi"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
DIM='\033[2m'
NC='\033[0m'
BOLD='\033[1m'

export DEBIAN_FRONTEND=noninteractive

APT_OPTS='-o DPkg::Lock::Timeout=300'

_cipi_apt_notice_if_locked() {
    if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
        echo -e "${YELLOW}System updates in progress, waiting for apt to be available...${NC}"
    fi
}

_cipi_apt_configure_lock_timeout() {
    cat > /etc/apt/apt.conf.d/00cipi-lock-timeout <<'EOF'
DPkg::Lock::Timeout "300";
EOF
}

_cipi_apt_update() {
    _cipi_apt_notice_if_locked
    apt-get $APT_OPTS update "$@"
}

_cipi_apt_install() {
    _cipi_apt_notice_if_locked
    apt-get $APT_OPTS install "$@"
}

show_logo() {
    clear
    echo -e "${GREEN}${BOLD}"
    echo " ██████ ██ ██████  ██"
    echo "██      ██ ██   ██ ██"
    echo "██      ██ ██████  ██"
    echo "██      ██ ██      ██"
    echo " ██████ ██ ██      ██"
    echo ""
    echo " v${BUILD} — Installation"
    echo -e "${NC}"
    sleep 2
}

step_msg() {
    clear
    echo -e "\n${GREEN}${BOLD}$1${NC}\n"
    sleep 1
}

# ── CHECKS ────────────────────────────────────────────────────

# Prints the kind of shared-kernel environment this is (docker, lxc, openvz,
# wsl, …) and nothing on bare metal or a full VM (KVM, VMware, Hyper-V, Xen).
# systemd-detect-virt knows best, but a container image often ships without
# systemd: the files and kernel names below cover those.
detect_container() {
    local v=""
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        v=$(systemd-detect-virt --container 2>/dev/null || true)
        if [ "$v" = "none" ]; then v=""; fi
    fi
    if [ -z "$v" ]; then
        if [ -f /.dockerenv ]; then
            v="docker"
        elif [ -f /run/.containerenv ]; then
            v="podman"
        elif grep -qi 'microsoft' /proc/sys/kernel/osrelease 2>/dev/null; then
            v="wsl"
        elif grep -qi 'orbstack' /proc/sys/kernel/osrelease 2>/dev/null; then
            v="orbstack"
        elif [ -d /proc/vz ] && [ ! -d /proc/bc ]; then
            v="openvz"
        elif [ -r /proc/1/environ ]; then
            v=$(tr '\0' '\n' < /proc/1/environ 2>/dev/null | sed -n 's/^container=//p' | head -1 || true)
        fi
    fi
    echo "$v"
}

check_requirements() {
    step_msg "Checking requirements..."

    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}Error: run as root (sudo)${NC}"
        exit 1
    fi

    # Before the OS check: no Ubuntu release makes a container a server.
    local virt virt_name
    virt=$(detect_container)
    if [ -n "$virt" ]; then
        case "$virt" in
            openvz)             virt_name="an OpenVZ / Virtuozzo container" ;;
            lxc|lxc-libvirt)    virt_name="an LXC container (LXD, Incus, Proxmox CT)" ;;
            docker)             virt_name="a Docker container" ;;
            podman)             virt_name="a Podman container" ;;
            wsl)                virt_name="WSL (Windows Subsystem for Linux)" ;;
            orbstack)           virt_name="an OrbStack machine" ;;
            systemd-nspawn)     virt_name="a systemd-nspawn container" ;;
            *)                  virt_name="a container (${virt})" ;;
        esac
        echo -e "${RED}Error: Cipi cannot be installed here: this is ${virt_name}, not a full server.${NC}"
        echo ""
        echo "Cipi needs a kernel of its own. It sets up the firewall (UFW), fail2ban, swap,"
        echo "kernel parameters and systemd services, and an environment that shares the"
        echo "host's kernel does not allow that."
        echo ""
        echo "Not supported: shared-kernel virtualization (OpenVZ, LXC) and container"
        echo "runtimes, including the desktop ones that emulate a Linux machine (Docker"
        echo "Desktop, Podman, OrbStack, WSL)."
        echo ""
        echo -e "Use a VPS or VM with full virtualization (${BOLD}KVM, VMware, Hyper-V, Xen HVM${NC})"
        echo "or a bare-metal server, with Ubuntu 24.04 LTS or 26.04 LTS."
        exit 1
    fi

    if [ ! -f /etc/os-release ]; then
        echo -e "${RED}Error: cannot detect OS${NC}"
        exit 1
    fi

    . /etc/os-release

    if [ "$ID" != "ubuntu" ]; then
        echo -e "${RED}Error: Cipi requires Ubuntu (found: $ID)${NC}"
        exit 1
    fi

    # sort -V, not bc: bc is installed later by this script, and on an image
    # without it every release failed this check, 24.04 included.
    if [ "$(printf '%s\n' "24.04" "${VERSION_ID:-0}" | sort -V | head -1)" != "24.04" ]; then
        echo -e "${RED}Error: requires Ubuntu 24.04+ (found: ${VERSION_ID:-unknown})${NC}"
        exit 1
    fi

    echo -e "${GREEN}✓ Ubuntu $VERSION_ID — root${NC}"
}

# ── APT HELPERS (bootstrap lib/php-apt.sh before /opt/cipi exists) ──

_cipi_source_apt_helpers() {
    if [[ -f "${CIPI_LIB}/php-apt.sh" ]]; then
        # shellcheck source=/dev/null
        source "${CIPI_LIB}/php-apt.sh"
        return 0
    fi
    local dest="/tmp/cipi-php-apt-$$.sh"
    local url="https://raw.githubusercontent.com/${REPO}/refs/heads/${BRANCH}/lib/php-apt.sh"
    if curl -fsSL "$url" -o "$dest" 2>/dev/null; then
        # shellcheck source=/dev/null
        source "$dest"
        rm -f "$dest"
        return 0
    fi
    rm -f "$dest"
    return 1
}

_cipi_sanitize_known_broken_apt_sources() {
    local cn
    cn="$(lsb_release -cs 2>/dev/null || true)"
    case "$cn" in
        resolute|questing)
            rm -f /etc/apt/sources.list.d/mariadb.list
            rm -f /etc/apt/sources.list.d/ondrej-ubuntu-php*.list \
                  /etc/apt/sources.list.d/ondrej-ubuntu-php*.sources 2>/dev/null || true
            ;;
    esac
}

# ── BASE PACKAGES ─────────────────────────────────────────────

install_basics() {
    step_msg "Installing base packages..."

    _cipi_sanitize_known_broken_apt_sources
    _cipi_apt_configure_lock_timeout
    _cipi_apt_update -qq
    _cipi_apt_install -y -qq \
        software-properties-common curl wget nano vim git \
        zip unzip openssl expect apt-transport-https \
        ca-certificates gnupg lsb-release jq bc acl \
        logrotate cron htop ncdu bash-completion \
        unattended-upgrades apt-listchanges

    echo -e "${GREEN}✓ Base packages${NC}"
}

# ── SWAP ──────────────────────────────────────────────────────

setup_swap() {
    step_msg "Configuring swap..."

    if [ -f /var/swap.1 ]; then
        echo -e "${GREEN}✓ Swap already configured${NC}"
        return
    fi

    local ram_mb
    ram_mb=$(free -m | awk '/^Mem:/{print $2}')
    local swap_mb=$((ram_mb * 2))
    [ "$swap_mb" -gt 4096 ] && swap_mb=4096
    [ "$swap_mb" -lt 1024 ] && swap_mb=1024

    dd if=/dev/zero of=/var/swap.1 bs=1M count=$swap_mb status=none
    chmod 600 /var/swap.1
    mkswap /var/swap.1 &>/dev/null
    swapon /var/swap.1
    echo '/var/swap.1 none swap sw 0 0' >> /etc/fstab

    echo 'vm.swappiness=10' >> /etc/sysctl.conf
    sysctl vm.swappiness=10 &>/dev/null

    echo -e "${GREEN}✓ Swap ${swap_mb}MB${NC}"
}

# ── SYSTEM ────────────────────────────────────────────────────

setup_system() {
    step_msg "Configuring system..."

    # Default editor
    cat > /etc/profile.d/cipi-env.sh <<'EOF'
export EDITOR=nano
export VISUAL=nano
EOF
    chmod +x /etc/profile.d/cipi-env.sh

    # MOTD
    cat > /etc/motd <<'EOF'

 ██████ ██ ██████  ██
██      ██ ██   ██ ██
██      ██ ██████  ██
██      ██ ██      ██
 ██████ ██ ██      ██

Easy Laravel Deployments

EOF

    echo -e "${GREEN}✓ System configured${NC}"
}

# ── SSH: COLLECT KEY (interactive, before long installs) ─────

# The keys that will open the cipi user. One is required; more can follow
# (a second machine, a colleague), each checked and shown with its
# fingerprint. SSH_PUBKEY (non-interactive) may hold several, one per line.
SSH_PUBKEYS=()
SERVER_IP=""

# A terminal to ask on: this script's own stdin is the pipe from wget.
_has_tty() { [[ -r /dev/tty && -w /dev/tty ]] && (true < /dev/tty) 2>/dev/null; }

_ask_yn() {
    local a
    echo -en "  ${BOLD}$1${NC} [y/N] "
    read -r a < /dev/tty
    [[ "$a" =~ ^[Yy]$ ]]
}

_ssh_key_clean() { printf '%s' "$1" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }
_ssh_key_valid() { printf '%s\n' "$1" | grep -qE '^(ssh-(rsa|ed25519)|ecdsa-sha2-\S+) '; }

# "ssh-ed25519 · SHA256:… · comment"
_ssh_key_describe() {
    local fp comment
    fp=$(printf '%s\n' "$1" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}') || fp=""
    comment=$(printf '%s\n' "$1" | awk '{$1=$2=""; print}' | xargs)
    printf '%s · %s%s' "$(printf '%s\n' "$1" | awk '{print $1}')" "${fp:-?}" "${comment:+ · ${comment}}"
}

# Adds a key to SSH_PUBKEYS: 0 added, 1 empty or not a public key, 2 already there.
_ssh_key_add() {
    local k e
    k=$(_ssh_key_clean "$1")
    [[ -n "$k" ]] && _ssh_key_valid "$k" || return 1
    for e in ${SSH_PUBKEYS[@]+"${SSH_PUBKEYS[@]}"}; do
        [[ "$e" == "$k" ]] && return 2
    done
    SSH_PUBKEYS+=("$k")
    return 0
}

collect_ssh_keys() {
    echo ""
    echo -e "${BOLD}SSH Security Setup${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo -e "  Cipi disables root SSH login and password authentication."
    echo -e "  A ${BOLD}cipi${NC} user will be created as the only SSH entry point."
    echo -e "  You will need an SSH public key to access the server — one at least;"
    echo -e "  you can add more (another machine, a colleague) before the install starts."
    echo ""
    echo -e "  ${BOLD}If you already have one${NC}, paste it below."
    echo -e "  Accepted formats: ${CYAN}ssh-rsa${NC}, ${CYAN}ssh-ed25519${NC}, ${CYAN}ecdsa-sha2-*${NC}"
    echo ""
    echo -e "  ${BOLD}If you need to generate one${NC} (on your local machine):"
    echo -e "  ${DIM}ssh-keygen -t ed25519${NC}"
    echo -e "  ${DIM}cat ~/.ssh/id_ed25519.pub${NC}"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    local key rc
    if [[ -n "${SSH_PUBKEY:-}" ]]; then
        while IFS= read -r key; do
            [[ -n "$(_ssh_key_clean "$key")" ]] || continue
            _ssh_key_add "$key" && rc=0 || rc=$?
            case $rc in
                0) echo -e "  ${GREEN}✓${NC} $(_ssh_key_describe "${SSH_PUBKEYS[${#SSH_PUBKEYS[@]}-1]}")" ;;
                1) echo -e "  ${RED}Invalid SSH_PUBKEY line. Each key must start with ssh-rsa, ssh-ed25519, or ecdsa-sha2-*${NC}"; exit 1 ;;
                2) echo -e "  ${DIM}duplicate key skipped${NC}" ;;
            esac
        done <<< "$SSH_PUBKEY"
        if [[ ${#SSH_PUBKEYS[@]} -eq 0 ]]; then
            echo -e "  ${RED}SSH_PUBKEY holds no key${NC}"
            exit 1
        fi
        echo -e "  ${GREEN}✓ ${#SSH_PUBKEYS[@]} SSH key(s) provided via environment${NC}"
    else
        if ! _has_tty; then
            echo -e "  ${RED}No terminal to ask for the key. Pass it in the environment:${NC}"
            echo -e "  ${DIM}SSH_PUBKEY=\"ssh-ed25519 AAAA…\" wget -O - https://cipi.sh/setup.sh | bash${NC}"
            exit 1
        fi
        while true; do
            if [[ ${#SSH_PUBKEYS[@]} -gt 0 ]]; then
                if ! _ask_yn "Add another SSH public key?"; then
                    break
                fi
                echo -en "  ${BOLD}Paste the SSH public key:${NC} "
            else
                echo -en "  ${BOLD}Paste your SSH public key:${NC} "
            fi
            read -r key < /dev/tty
            _ssh_key_add "$key" && rc=0 || rc=$?
            case $rc in
                0) echo -e "  ${GREEN}✓ Key ${#SSH_PUBKEYS[@]}:${NC} $(_ssh_key_describe "${SSH_PUBKEYS[${#SSH_PUBKEYS[@]}-1]}")" ;;
                1)
                    if [[ -z "$(_ssh_key_clean "$key")" ]]; then
                        [[ ${#SSH_PUBKEYS[@]} -eq 0 ]] \
                            && echo -e "  ${RED}An SSH public key is required.${NC}" \
                            || echo -e "  ${YELLOW}Nothing pasted.${NC}"
                    else
                        echo -e "  ${RED}Invalid key format. Must start with ssh-rsa, ssh-ed25519, or ecdsa-sha2-*${NC}"
                    fi ;;
                2) echo -e "  ${YELLOW}That key is already in the list.${NC}" ;;
            esac
        done
    fi

    echo ""
    echo -e "${GREEN}✓ ${#SSH_PUBKEYS[@]} SSH key(s) accepted${NC}"
}

# ── PLAN ──────────────────────────────────────────────────────

# What the installer is about to do, before it touches the machine, and the
# chance to stop. The passwords do not exist yet: they are generated during
# the install and shown once at the end, where the installer waits until
# they are saved.
confirm_plan() {
    SERVER_IP=$(curl -s --connect-timeout 3 --max-time 5 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]') || SERVER_IP=""
    [[ "$SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    local os k
    os=$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-Ubuntu}")

    clear
    echo ""
    echo -e "${BOLD}What will be set up${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo -e "  ${BOLD}Server${NC}"
    echo -e "  IP:             ${CYAN}${SERVER_IP:-unknown}${NC}"
    echo -e "  Hostname:       ${CYAN}$(hostname)${NC}"
    echo -e "  OS:             ${CYAN}${os}${NC}"
    echo ""
    echo -e "  ${BOLD}SSH access${NC}"
    echo -e "  User:           ${CYAN}cipi${NC} — key only, sudo for every cipi command"
    for k in "${SSH_PUBKEYS[@]}"; do
        echo -e "  Key:            ${CYAN}$(_ssh_key_describe "$k")${NC}"
    done
    echo -e "  Root:           ${RED}no SSH login${NC} — ssh cipi@${SERVER_IP:-<ip>}, then su root"
    echo -e "  Passwords:      ${RED}off${NC} for SSH (app users excepted)"
    echo ""
    echo -e "  ${BOLD}Stack${NC}"
    echo -e "  Nginx · MariaDB 11.4 · PHP 8.5 (FPM) · Composer · Deployer · Node.js 22 · Supervisor"
    echo -e "  Valkey · Certbot · UFW (22, 80, 443) + fail2ban · swap · unattended security updates"
    echo ""
    echo -e "  ${BOLD}Generated during the install, shown once at the end${NC}"
    echo -e "  root password · MariaDB root password · Valkey password"
    echo -e "  ${YELLOW}Have a password manager ready: the installer waits until you confirm they are saved.${NC}"
    echo ""
    echo -e "  ${DIM}Optional, offered at the end or later: panel API (cipi api), web GUI (cipi gui).${NC}"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    if ! _has_tty; then
        echo -e "  ${DIM}No terminal — proceeding.${NC}"
        return 0
    fi
    local a
    echo -en "  ${BOLD}Proceed with the installation?${NC} [Y/n] "
    read -r a < /dev/tty
    if [[ "$a" =~ ^[Nn] ]]; then
        echo ""
        echo -e "  ${YELLOW}Installation cancelled. Nothing was changed.${NC}"
        echo ""
        exit 0
    fi
}

# ── SSH HARDENING (applied after base packages are installed) ─

setup_ssh() {
    step_msg "SSH Hardening..."

    # 1. Set root password (32 chars, random)
    local ROOT_PASS
    ROOT_PASS=$(openssl rand -base64 64 | tr -dc 'a-zA-Z0-9' | head -c 40)
    echo "root:${ROOT_PASS}" | chpasswd

    # Save root password in server.json (create if missing)
    mkdir -p /etc/cipi
    [ -f /etc/cipi/server.json ] || echo '{}' > /etc/cipi/server.json
    local tmp
    tmp=$(mktemp)
    jq --arg p "$ROOT_PASS" '. + {root_password: $p}' /etc/cipi/server.json > "$tmp"
    mv "$tmp" /etc/cipi/server.json
    chmod 600 /etc/cipi/server.json

    # 2. Create cipi user
    local CIPI_PASS
    CIPI_PASS=$(openssl rand -base64 64 | tr -dc 'a-zA-Z0-9' | head -c 40)
    useradd -m -s /bin/bash cipi 2>/dev/null || true
    echo "cipi:${CIPI_PASS}" | chpasswd
    usermod -aG sudo cipi

    # SSH access groups
    groupadd -f cipi-ssh
    groupadd -f cipi-apps
    usermod -aG cipi-ssh cipi

    # 2. The owner's keys (interactive login): every key accepted at the start
    mkdir -p /home/cipi/.ssh
    printf '%s\n' "${SSH_PUBKEYS[@]}" > /home/cipi/.ssh/authorized_keys
    chmod 700 /home/cipi/.ssh
    chmod 600 /home/cipi/.ssh/authorized_keys

    # 3. Generate server-to-server keypair (used by cipi sync push)
    if [ ! -f /home/cipi/.ssh/id_ed25519 ]; then
        ssh-keygen -t ed25519 -C "cipi@$(hostname)" -f /home/cipi/.ssh/id_ed25519 -N "" -q
    fi
    chmod 600 /home/cipi/.ssh/id_ed25519
    chmod 644 /home/cipi/.ssh/id_ed25519.pub

    chown -R cipi:cipi /home/cipi/.ssh

    # 4. Allow cipi to run cipi CLI as root without password
    # SSH_CLIENT/SSH_CONNECTION survive sudo so `cipi crowdsec enable` can
    # allowlist the session it is typed from. Without them PermitRootLogin=no
    # plus `sudo cipi` means the operator's own IP is never allowlisted.
    cat > /etc/sudoers.d/cipi-sudo <<'SUDOEOF'
Defaults:cipi env_keep += "SSH_USER_AUTH SSH_CLIENT SSH_CONNECTION"
cipi ALL=(root) NOPASSWD: /usr/local/bin/cipi *
SUDOEOF
    chmod 440 /etc/sudoers.d/cipi-sudo

    # 5. Harden sshd_config
    local SSHD="/etc/ssh/sshd_config"
    cp "$SSHD" "${SSHD}.bak.$(date +%s)"

    # Apply settings (replace if exists, append if not)
    local -A ssh_settings=(
        [PermitRootLogin]="no"
        [PasswordAuthentication]="no"
        [PubkeyAuthentication]="yes"
        [PermitEmptyPasswords]="no"
        [MaxAuthTries]="3"
        [LoginGraceTime]="20"
        [X11Forwarding]="no"
        [AllowGroups]="cipi-ssh cipi-apps"
        [ExposeAuthInfo]="yes"
    )

    for key in "${!ssh_settings[@]}"; do
        local val="${ssh_settings[$key]}"
        if grep -qE "^#?\s*${key}\b" "$SSHD"; then
            sed -i "s/^#*\s*${key}\b.*/${key} ${val}/" "$SSHD"
        else
            echo "${key} ${val}" >> "$SSHD"
        fi
    done

    # Remove legacy AllowUsers if present (replaced by AllowGroups)
    sed -i '/^AllowUsers/d' "$SSHD"

    # Allow password auth for app users only (cipi stays key-only)
    if ! grep -q 'Match Group cipi-apps' "$SSHD"; then
        cat >> "$SSHD" <<'MATCHEOF'

Match Group cipi-apps
    PasswordAuthentication yes
MATCHEOF
    fi

    # 6. Restart SSH
    systemctl restart ssh || systemctl restart sshd

    echo -e "${GREEN}✓ SSH hardened (key-only for cipi, password for app users)${NC}"
}

# ── NGINX ─────────────────────────────────────────────────────

install_nginx() {
    step_msg "Installing Nginx..."

    _cipi_apt_install -y -qq nginx libnginx-mod-http-headers-more-filter

    local CPU_CORES
    CPU_CORES=$(nproc)

    cat > /etc/nginx/nginx.conf <<NGINXEOF
user www-data;
worker_processes ${CPU_CORES};
# Headroom for long-lived connections: a WebSocket holds two nginx connections
# (browser side and upstream side) and a descriptor each for as long as it is
# open, and the stock 1024 soft limit caps a Reverb app at a few hundred
# clients. See _ensure_nginx_ws_limits in lib/common.sh, which applies the same
# two values to servers installed before this was the default.
worker_rlimit_nofile 65535;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 8192;
    multi_accept on;
}

http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    server_names_hash_bucket_size 64;
    server_tokens off;
    more_clear_headers 'Server' 'X-Powered-By';

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;

    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml text/javascript
               application/json application/javascript application/xml+rss
               application/rss+xml font/truetype font/opentype
               application/vnd.ms-fontobject image/svg+xml;

    client_max_body_size 256M;
    fastcgi_read_timeout 300;

    limit_req_zone \$binary_remote_addr zone=global:10m rate=30r/s;

    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
NGINXEOF

    cat > /etc/nginx/sites-available/default <<'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    root /var/www/html;
    index index.html;
    server_name _;
    server_tokens off;

    # All requests serve the Server Up page (no 404 leaks)
    location / {
        rewrite ^ /index.html break;
    }
}
EOF

    cat > /var/www/html/index.html <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>SERVER UP</title>
    <meta name="robots" content="noindex, nofollow">
    <link rel="icon" type="image/svg+xml"
        href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'%3E%3Ccircle cx='50' cy='50' r='45' fill='%2322c55e'/%3E%3C/svg%3E">
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, sans-serif;
            background: #ffffff;
            min-height: 100vh;
            display: flex;
            justify-content: center;
            align-items: center;
            color: #1a1a1a;
        }
        .container { text-align: center; animation: fadeIn 1s ease-in; }
        .server-container { position: relative; margin-bottom: 0.3rem; }
        .server-svg { width: 250px; height: 100px; }
        .led {
            fill: #22c55e;
            filter: drop-shadow(0 0 4px rgba(34, 197, 94, 0.9));
            animation: pulseFixed 2s ease-in-out infinite;
        }
        circle.led:nth-of-type(1) { animation-delay: 0s; animation-duration: 2s; }
        circle.led:nth-of-type(2) { animation-delay: 0.6s; animation-duration: 2.3s; }
        @keyframes pulseFixed {
            0%, 100% { opacity: 0.3; filter: drop-shadow(0 0 2px rgba(34, 197, 94, 0.3)); }
            50%       { opacity: 1;   filter: drop-shadow(0 0 6px rgba(34, 197, 94, 1)); }
        }
        .status-text {
            font-size: 1.5rem;
            font-weight: 300;
            letter-spacing: 4px;
            text-transform: uppercase;
            color: #666;
            margin-top: -0.5rem;
            animation: fadeInUp 1s ease-out 0.3s both;
        }
        .host-text {
            font-size: 0.75rem;
            font-weight: 400;
            color: #999;
            margin-top: 0.5rem;
            animation: fadeInUp 1s ease-out 0.5s both;
        }
        @keyframes fadeIn { from { opacity: 0; } to { opacity: 1; } }
        @keyframes fadeInUp {
            from { opacity: 0; transform: translateY(20px); }
            to   { opacity: 1; transform: translateY(0); }
        }
        @media (max-width: 600px) {
            .server-svg { width: 200px; height: 80px; }
            .status-text { font-size: 1.2rem; letter-spacing: 3px; }
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="server-container">
            <svg class="server-svg" viewBox="0 0 250 100" xmlns="http://www.w3.org/2000/svg">
                <rect x="25" y="27.5" width="200" height="45" rx="4" fill="none" stroke="#1a1a1a" stroke-width="2.5" />
                <rect x="35" y="35.5" width="180" height="29" rx="2" fill="none" stroke="#1a1a1a" stroke-width="1.5" />
                <circle cx="50" cy="50" r="6" fill="none" stroke="#999" stroke-width="1.5" />
                <path d="M 50 46 L 50 50" stroke="#999" stroke-width="1.5" stroke-linecap="round" />
                <circle class="led" cx="185" cy="50" r="3.5" />
                <circle class="led" cx="200" cy="50" r="3.5" />
            </svg>
        </div>
        <div class="status-text">Server Up</div>
        <div class="host-text" id="host-label"></div>
    </div>
    <script>
        var h = window.location.hostname;
        var isIP = /^(\d{1,3}\.){3}\d{1,3}$/.test(h) || /^[0-9a-fA-F:]+$/.test(h);
        document.getElementById('host-label').textContent = isIP ? h : h + ' is not configured';
    </script>
</body>
</html>
EOF

    ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
    rm -f /etc/nginx/sites-enabled/default.bak

    # Catch-all for HTTPS. The "default" site above claims :80, but :443 had no
    # default server: an HTTPS request carrying a Host that matches no app fell
    # through to whichever vhost nginx loaded first. With a wildcard
    # multi-tenant app that means its tenant resolver receives a hostname it
    # cannot parse. Close those connections instead (cipi nginx default-server).
    cat > /etc/nginx/sites-available/000-cipi-default <<'EOF'
# Managed by Cipi — catch-all for requests matching no app.
# Disable with: cipi nginx default-server off

server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    server_name _;
    ssl_reject_handshake on;
    access_log off;
    return 444;
}
EOF
    ln -sf /etc/nginx/sites-available/000-cipi-default /etc/nginx/sites-enabled/000-cipi-default
    if ! nginx -t >/dev/null 2>&1; then
        rm -f /etc/nginx/sites-enabled/000-cipi-default /etc/nginx/sites-available/000-cipi-default
    fi

    systemctl restart nginx
    systemctl enable nginx

    echo -e "${GREEN}✓ Nginx${NC}"
}

# ── FIREWALL & FAIL2BAN ──────────────────────────────────────

install_firewall() {
    step_msg "Installing firewall & fail2ban..."

    _cipi_apt_install -y -qq fail2ban ufw

    cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime = 86400
findtime = 3600
maxretry = 3
banaction = iptables-multiport
bantime.increment = true
bantime.factor = 2
bantime.maxtime = 604800

[sshd]
enabled = true
port = ssh
logpath = /var/log/auth.log
maxretry = 3

[recidive]
enabled = true
logpath = /var/log/fail2ban.log
bantime = 604800
findtime = 86400
maxretry = 3
EOF

    systemctl restart fail2ban
    systemctl enable fail2ban

    ufw default deny incoming &>/dev/null
    ufw default allow outgoing &>/dev/null
    ufw allow 22/tcp &>/dev/null
    ufw allow 80/tcp &>/dev/null
    ufw allow 443/tcp &>/dev/null
    ufw --force enable &>/dev/null

    echo -e "${GREEN}✓ Firewall & fail2ban${NC}"
}

# ── MARIADB ───────────────────────────────────────────────────

install_mariadb() {
    step_msg "Installing MariaDB..."

    local mariadb_label="Ubuntu archive"
    _cipi_source_apt_helpers && cipi_sanitize_broken_apt_sources 2>/dev/null || _cipi_sanitize_known_broken_apt_sources
    if _cipi_source_apt_helpers && mariadb_setup_apt_repo; then
        mariadb_label="MariaDB.org 11.4"
    else
        rm -f /etc/apt/sources.list.d/mariadb.list
    fi

    _cipi_apt_update -qq
    _cipi_apt_install -y -qq mariadb-server mariadb-client

    # Generate root password
    local DB_ROOT_PASS
    DB_ROOT_PASS=$(openssl rand -base64 64 | tr -dc 'a-zA-Z0-9' | head -c 40)

    # Secure installation
    mysql <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASS}';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
SQL

    # Tune based on available RAM
    local RAM_MB
    RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
    local BUFFER_POOL="256M"
    [ "$RAM_MB" -ge 2048 ] && BUFFER_POOL="512M"
    [ "$RAM_MB" -ge 4096 ] && BUFFER_POOL="1G"
    [ "$RAM_MB" -ge 8192 ] && BUFFER_POOL="2G"
    [ "$RAM_MB" -ge 16384 ] && BUFFER_POOL="4G"

    cat > /etc/mysql/mariadb.conf.d/99-cipi.cnf <<CNFEOF
[mysqld]
bind-address = 127.0.0.1
innodb_buffer_pool_size = ${BUFFER_POOL}
innodb_log_file_size = 256M
innodb_flush_log_at_trx_commit = 2
innodb_flush_method = O_DIRECT
max_connections = 100
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
skip-name-resolve
CNFEOF

    systemctl restart mariadb
    systemctl enable mariadb

    # Save config (merge with existing server.json to preserve root_password)
    mkdir -p /etc/cipi
    chmod 700 /etc/cipi
    [ -f /etc/cipi/server.json ] || echo '{}' > /etc/cipi/server.json
    local tmp
    tmp=$(mktemp)
    jq --arg p "$DB_ROOT_PASS" '
        . + {
            db_root_password: $p,
            db_default_engine: "mariadb",
            db_engines: ((.db_engines // {}) + {mariadb: {installed: true, port: 3306}})
        }
    ' /etc/cipi/server.json > "$tmp"
    mv "$tmp" /etc/cipi/server.json
    chmod 600 /etc/cipi/server.json

    echo -e "${GREEN}✓ MariaDB (${mariadb_label}, buffer_pool: ${BUFFER_POOL})${NC}"
}

# ── VALKEY ──────────────────────────────────────────────────
# Valkey is a Redis-compatible (RESP, same config directives, port 6379) fork
# shipped in Ubuntu 24.04 Universe (`valkey` + `valkey-tools`). Apps keep using
# the phpredis extension and REDIS_* .env settings unchanged.

install_valkey() {
    step_msg "Installing Valkey..."

    _cipi_apt_install -y -qq valkey-server valkey-tools

    # Generate password
    local VALKEY_PASS
    VALKEY_PASS=$(openssl rand -base64 64 | tr -dc 'a-zA-Z0-9' | head -c 40)

    # Configure requirepass and bind to localhost
    if grep -q "^# *requirepass" /etc/valkey/valkey.conf; then
        sed -i "s/^# *requirepass.*/requirepass ${VALKEY_PASS}/" /etc/valkey/valkey.conf
    elif grep -q "^requirepass" /etc/valkey/valkey.conf; then
        sed -i "s/^requirepass.*/requirepass ${VALKEY_PASS}/" /etc/valkey/valkey.conf
    else
        echo "requirepass ${VALKEY_PASS}" >> /etc/valkey/valkey.conf
    fi

    # Ensure bind to localhost only
    if grep -q "^bind " /etc/valkey/valkey.conf; then
        sed -i "s/^bind .*/bind 127.0.0.1 -::1/" /etc/valkey/valkey.conf
    elif ! grep -q "^bind " /etc/valkey/valkey.conf; then
        echo "bind 127.0.0.1 -::1" >> /etc/valkey/valkey.conf
    fi

    systemctl restart valkey-server
    systemctl enable valkey-server

    # Save Valkey credentials in server.json (merge with existing)
    local tmp
    tmp=$(mktemp)
    jq --arg u "default" --arg p "$VALKEY_PASS" '. + {valkey_user: $u, valkey_password: $p}' /etc/cipi/server.json > "$tmp"
    mv "$tmp" /etc/cipi/server.json
    chmod 600 /etc/cipi/server.json

    echo -e "${GREEN}✓ Valkey $(valkey-server --version 2>/dev/null | awk '{print $3}' || echo "")${NC}"
}

# ── PHP (multi-version) ──────────────────────────────────────

install_php() {
    step_msg "Installing PHP 8.5..."

    _cipi_source_apt_helpers && cipi_sanitize_broken_apt_sources 2>/dev/null || _cipi_sanitize_known_broken_apt_sources
    if _cipi_source_apt_helpers; then
        if ! php_setup_apt_sources; then
            echo -e "${YELLOW}→ No multi-PHP repo for this Ubuntu release — using archive packages${NC}"
        fi
    else
        add-apt-repository -y ppa:ondrej/php &>/dev/null
    fi
    _cipi_apt_update -qq

    local EXTENSIONS="fpm common cli curl bcmath mbstring mysql sqlite3 pgsql memcached redis zip xml soap gd imagick intl"

    for VER in 8.5; do
        echo -e "${CYAN}→ PHP ${VER}...${NC}"

        local PACKAGES=""
        for EXT in $EXTENSIONS; do
            PACKAGES+=" php${VER}-${EXT}"
        done
        _cipi_apt_install -y -qq $PACKAGES

        # Cipi defaults. The last two lines are the PHP advisory mitigations of
        # 2026-10-21 (CVE-2026-109618/109619), the same lines every Cipi pool
        # carries (lib/common.sh php_fpm_ini_hardening): here they also cover
        # the stock `www` pool. PHP ignores fatal_error_backtraces before 8.5.
        cat > "/etc/php/${VER}/fpm/conf.d/99-cipi.ini" <<INIEOF
memory_limit = 256M
upload_max_filesize = 256M
post_max_size = 256M
max_execution_time = 300
max_input_time = 300
expose_php = Off
session.upload_progress.enabled = 0
fatal_error_backtraces = 0
INIEOF

        # Replace default www pool with a minimal placeholder so FPM can start.
        # No vhost points at it; it runs as www-data without open_basedir, so
        # its socket is 0600 — reachable by www-data alone, never by an app.
        cat > "/etc/php/${VER}/fpm/pool.d/www.conf" <<POOLEOF
[www]
user = www-data
group = www-data
listen = /run/php/php${VER}-fpm.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0600
pm = ondemand
pm.max_children = 2
pm.process_idle_timeout = 10s
POOLEOF

        systemctl restart "php${VER}-fpm"
        systemctl enable "php${VER}-fpm"
    done

    # Set 8.5 as default CLI
    update-alternatives --set php /usr/bin/php8.5 2>/dev/null || true

    echo -e "${GREEN}✓ PHP 8.5${NC}"
}

# ── COMPOSER ──────────────────────────────────────────────────

readonly COMPOSER_MIN="2.10.1"

install_composer() {
    step_msg "Installing Composer..."

    curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer --quiet

    # The installer ships the current stable build, but guard the floor so
    # fresh installs never end up below the supported Composer release.
    local cv
    cv="$(composer --version --no-ansi 2>/dev/null | sed -n 's/.*Composer version \([0-9][0-9.]*\).*/\1/p' | head -1)"
    if [[ -z "$cv" ]] || [[ "$(printf '%s\n' "$COMPOSER_MIN" "$cv" | sort -V | head -1)" != "$COMPOSER_MIN" ]]; then
        composer self-update --2 --no-interaction 2>/dev/null || true
        cv="$(composer --version --no-ansi 2>/dev/null | sed -n 's/.*Composer version \([0-9][0-9.]*\).*/\1/p' | head -1)"
        if [[ -n "$cv" ]] && [[ "$(printf '%s\n' "$COMPOSER_MIN" "$cv" | sort -V | head -1)" != "$COMPOSER_MIN" ]]; then
            composer self-update "$COMPOSER_MIN" --no-interaction 2>/dev/null || true
        fi
    fi

    echo -e "${GREEN}✓ Composer$(composer --version 2>/dev/null | awk '{print " "$3}')${NC}"
}

# ── DEPLOYER ──────────────────────────────────────────────────

install_deployer() {
    step_msg "Installing Deployer..."

    curl -fsSL https://deployer.org/deployer.phar -o /usr/local/bin/dep
    chmod 755 /usr/local/bin/dep

    echo -e "${GREEN}✓ Deployer$(dep --version 2>/dev/null | awk '{print " "$2}')${NC}"
}

# ── NODE.JS ───────────────────────────────────────────────────

install_nodejs() {
    step_msg "Installing Node.js..."

    # Node 22 LTS (20 reached end of life in April 2026). Per-app and server-wide
    # majors from nodejs.org are managed later with `cipi node`.
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - &>/dev/null
    _cipi_apt_install -y -qq nodejs

    echo -e "${GREEN}✓ Node.js $(node -v 2>/dev/null)${NC}"
}

# ── SUPERVISOR ────────────────────────────────────────────────

install_supervisor() {
    step_msg "Installing Supervisor..."

    _cipi_apt_install -y -qq supervisor

    # Every program Supervisor runs inherits its file-descriptor limit, and a
    # WebSocket server spends one descriptor per connected client — systemd's
    # default of 1024 would stop Reverb at around a thousand. A drop-in rather
    # than supervisord's own `minfds`, which makes supervisord refuse to start
    # when the limit cannot be reached and would take every queue worker on the
    # box down with it. Written before the first start, so it applies at once.
    mkdir -p /etc/systemd/system/supervisor.service.d
    cat > /etc/systemd/system/supervisor.service.d/cipi-nofile.conf <<'SUPEOF'
# Managed by Cipi — file-descriptor headroom for long-lived connections.
# One descriptor per open WebSocket; supervisord's children inherit this.
[Service]
LimitNOFILE=65535
SUPEOF
    systemctl daemon-reload

    systemctl enable supervisor
    systemctl start supervisor

    echo -e "${GREEN}✓ Supervisor${NC}"
}

# ── LET'S ENCRYPT ─────────────────────────────────────────────

install_certbot() {
    step_msg "Installing Certbot..."

    _cipi_apt_install -y -qq certbot python3-certbot-nginx

    # certbot only issues and renews; Cipi writes the HTTPS vhost itself. A
    # renewed certificate is served once nginx reloads, and certbot runs this
    # hook after every renewal — certbot.timer and the weekly cron alike.
    mkdir -p /etc/letsencrypt/renewal-hooks/deploy
    cat > /etc/letsencrypt/renewal-hooks/deploy/cipi-reload-nginx <<'HOOKEOF'
#!/bin/sh
# Managed by Cipi — certbot runs this after every renewed certificate, so that
# nginx serves it. A failing config test is reported by certbot, not hidden.
nginx -t -q && exec systemctl reload nginx
HOOKEOF
    chmod 755 /etc/letsencrypt/renewal-hooks/deploy/cipi-reload-nginx

    echo -e "${GREEN}✓ Certbot${NC}"
}

# ── CIPI CLI ──────────────────────────────────────────────────

install_cipi() {
    step_msg "Installing Cipi CLI..."

    mkdir -p /opt/cipi/{lib,templates}
    mkdir -p /etc/cipi
    mkdir -p /var/log/cipi
    chmod 700 /etc/cipi

    cd /tmp
    rm -rf cipi-install
    GIT_TERMINAL_PROMPT=0 git clone -b "$BRANCH" --depth 1 "https://github.com/${REPO}.git" cipi-install 2>/dev/null

    BUILD="$(tr -d '[:space:]' < /tmp/cipi-install/version.md 2>/dev/null)"
    [[ -z "$BUILD" ]] && { echo "Cannot read version.md from repo"; exit 1; }

    # Main CLI
    cp cipi-install/cipi /usr/local/bin/cipi
    chmod 700 /usr/local/bin/cipi

    # Lib scripts
    cp cipi-install/lib/*.sh /opt/cipi/lib/
    chmod 755 /opt/cipi /opt/cipi/lib
    chmod 700 /opt/cipi/lib/*.sh
    # cipi-app-post-deploy runs as the app user and sources yml.sh for the
    # deploy.post steps of cipi.yml: it has to be readable by every app user.
    chmod 644 /opt/cipi/lib/yml.sh
    cp cipi-install/lib/gui-reset-admin.php /opt/cipi/lib/ 2>/dev/null || true
    cp cipi-install/lib/cipi-webhook.php /opt/cipi/lib/ 2>/dev/null || true
    chmod 644 /opt/cipi/lib/gui-reset-admin.php 2>/dev/null || true

    # Deployer templates (per app type: laravel, custom)
    if [ -d "cipi-install/lib/deployer" ]; then
        cp -r cipi-install/lib/deployer /opt/cipi/lib/
    fi

    # Cipi API package (for cipi api)
    if [ -d "cipi-install/cipi-api" ]; then
        rm -rf /opt/cipi/cipi-api 2>/dev/null
        cp -a cipi-install/cipi-api /opt/cipi/cipi-api
    fi

    # Cipi GUI is installed via Composer from https://github.com/cipi-sh/gui (cipi gui)

    # Worker helper
    cp cipi-install/lib/cipi-worker.sh /usr/local/bin/cipi-worker
    chmod 700 /usr/local/bin/cipi-worker

    # Cron notification wrapper
    cp cipi-install/lib/cipi-cron-notify.sh /usr/local/bin/cipi-cron-notify
    chmod 700 /usr/local/bin/cipi-cron-notify

    # PAM auth notification script
    cp cipi-install/lib/cipi-auth-notify.sh /usr/local/bin/cipi-auth-notify
    chmod 700 /usr/local/bin/cipi-auth-notify

    # App-level failure notification (called by app users via sudo)
    cp cipi-install/lib/cipi-app-notify.sh /usr/local/bin/cipi-app-notify
    chmod 700 /usr/local/bin/cipi-app-notify

    # Automatic (webhook) deploy wrapper — runs as the app user from its crontab
    cp cipi-install/lib/cipi-app-deploy.sh /usr/local/bin/cipi-app-deploy
    chmod 755 /usr/local/bin/cipi-app-deploy
    cp cipi-install/lib/cipi-app-post-deploy.sh /usr/local/bin/cipi-app-post-deploy
    chmod 755 /usr/local/bin/cipi-app-post-deploy
    # Deploy audit ledger writer — called (root, via per-app sudoers) by every
    # app's Deployer recipe, whatever started the deploy
    cp cipi-install/lib/cipi-deploy-audit.sh /usr/local/bin/cipi-deploy-audit
    chmod 700 /usr/local/bin/cipi-deploy-audit
    # Node frontend apps: blue/green switch (root), process launcher (app user),
    # webhook receiver for apps without cipi/agent
    cp cipi-install/lib/cipi-node-switch.sh /usr/local/bin/cipi-node-switch
    chmod 700 /usr/local/bin/cipi-node-switch
    cp cipi-install/lib/cipi-node-run.sh /usr/local/bin/cipi-node-run
    chmod 755 /usr/local/bin/cipi-node-run
    install -d -m 755 /usr/local/share/cipi
    install -m 644 cipi-install/lib/cipi-webhook.php /usr/local/share/cipi/webhook.php

    cp cipi-install/lib/cipi-read-app-logs.sh /usr/local/bin/cipi-read-app-logs
    chmod 755 /usr/local/bin/cipi-read-app-logs

    # HTTP healthcheck cron helper
    cp cipi-install/lib/cipi-health-check.sh /usr/local/bin/cipi-health-check
    chmod 700 /usr/local/bin/cipi-health-check
    cp cipi-install/lib/cipi-scan-manifest.sh /usr/local/bin/cipi-scan-manifest
    chmod 755 /usr/local/bin/cipi-scan-manifest
    # Integrity baselines live outside /home/<app>, root-only: the app user must
    # not be able to rewrite the manifest it is checked against.
    install -d -m 700 -o root -g root /var/lib/cipi/manifests
    # Deploy audit ledger starts now: `cipi compliance` expects every release
    # published after this moment to have a ledger record.
    date -u '+%Y-%m-%dT%H:%M:%SZ' > /var/lib/cipi/deploy-audit-since
    chmod 600 /var/lib/cipi/deploy-audit-since
    cp cipi-install/lib/cipi-crowdsec-rescue.py /usr/local/bin/cipi-crowdsec-rescue
    chmod 700 /usr/local/bin/cipi-crowdsec-rescue
    cp cipi-install/lib/cipi-crowdsec-rescue-hole.sh /usr/local/bin/cipi-crowdsec-rescue-hole
    chmod 700 /usr/local/bin/cipi-crowdsec-rescue-hole
    mkdir -p /var/log/cipi/health
    if [ ! -f /etc/cron.d/cipi-health ]; then
        cat > /etc/cron.d/cipi-health <<'EOF'
# Cipi app HTTP healthchecks (every 5 minutes)
*/5 * * * * root /usr/local/bin/cipi-health-check >/dev/null 2>&1
EOF
        chmod 644 /etc/cron.d/cipi-health
    fi

    # System monitor (disk, SSL expiry, services, workers, 5xx, fs, load).
    # On by default like the healthchecks; `cipi monitor disable <check>` opts out.
    cp cipi-install/lib/cipi-monitor.sh /usr/local/bin/cipi-monitor
    chmod 755 /usr/local/bin/cipi-monitor
    mkdir -p /var/log/cipi/monitor
    if [ ! -f /etc/cron.d/cipi-monitor ]; then
        cat > /etc/cron.d/cipi-monitor <<'EOF'
# Cipi system monitor (every 5 minutes)
*/5 * * * * root /usr/local/bin/cipi-monitor >/dev/null 2>&1
EOF
        chmod 644 /etc/cron.d/cipi-monitor
    fi

    # Templates (if any)
    cp cipi-install/templates/* /opt/cipi/templates/ 2>/dev/null || true

    chown -R root:root /usr/local/bin/cipi /usr/local/bin/cipi-worker /usr/local/bin/cipi-cron-notify /usr/local/bin/cipi-auth-notify /usr/local/bin/cipi-app-notify /usr/local/bin/cipi-app-deploy /usr/local/bin/cipi-app-post-deploy /usr/local/bin/cipi-deploy-audit /usr/local/bin/cipi-node-switch /usr/local/bin/cipi-node-run /usr/local/bin/cipi-read-app-logs /usr/local/bin/cipi-health-check /usr/local/bin/cipi-monitor /usr/local/bin/cipi-scan-manifest /usr/local/bin/cipi-crowdsec-rescue /usr/local/bin/cipi-crowdsec-rescue-hole /opt/cipi

    # Shell tab-completion — installed for every shell, no activation needed:
    # /etc/bash_completion.d/cipi, the zsh vendor file, and an /etc/profile.d
    # loader that works even without the bash-completion package.
    if [ -f /opt/cipi/lib/completion.sh ]; then
        # shellcheck source=/dev/null
        . /opt/cipi/lib/completion.sh
        _completion_install_system || true
    fi

    # Generate vault key for config encryption
    if [ ! -f /etc/cipi/.vault_key ]; then
        openssl rand -base64 32 > /etc/cipi/.vault_key
        chmod 400 /etc/cipi/.vault_key
    fi

    # Source vault functions now that lib is installed
    source "${CIPI_LIB}/vault.sh"

    # Init config files (encrypted)
    for f in apps.json databases.json; do
        if [ ! -f "/etc/cipi/$f" ]; then
            echo "{}" | vault_write "$f"
        fi
    done

    # Seal any config files written in plaintext earlier in setup
    for f in server.json; do
        [ -f "/etc/cipi/$f" ] && vault_seal "$f"
    done

    # Version
    echo "$BUILD" > /etc/cipi/version

    # Sudoers for the panel (www-data runs cipi via sudo — restricted to API
    # commands only). Written only when the API or the GUI is installed, so a
    # fresh server has no www-data → root path at all; `cipi api <domain>` and
    # `cipi gui <domain>` write it when they install (5.8.6).
    # shellcheck source=/dev/null
    source "${CIPI_LIB}/cipi-api-sudoers.sh"
    ensure_cipi_api_sudoers

    rm -rf /tmp/cipi-install

    echo -e "${GREEN}✓ Cipi CLI v${BUILD}${NC}"
}

# ── PAM AUTH NOTIFICATIONS ────────────────────────────────────

setup_pam() {
    # Restrict su to sudo group members only (blocks app users from su to root/cipi)
    if ! grep -q '^auth\s\+required\s\+pam_wheel\.so' /etc/pam.d/su 2>/dev/null; then
        sed -i '/^#.*pam_wheel\.so/c\auth       required   pam_wheel.so group=sudo' /etc/pam.d/su \
            || echo 'auth       required   pam_wheel.so group=sudo' >> /etc/pam.d/su
    fi
    echo -e "${GREEN}✓ su restricted to sudo group${NC}"

    if [[ -x /usr/local/bin/cipi-auth-notify ]]; then
        if ! grep -q 'cipi-auth-notify' /etc/pam.d/sudo 2>/dev/null; then
            echo 'session optional pam_exec.so seteuid /usr/local/bin/cipi-auth-notify' >> /etc/pam.d/sudo
        fi
        if ! grep -q 'cipi-auth-notify' /etc/pam.d/sshd 2>/dev/null; then
            echo 'session optional pam_exec.so seteuid /usr/local/bin/cipi-auth-notify' >> /etc/pam.d/sshd
        fi
        if ! grep -q 'cipi-auth-notify' /etc/pam.d/su 2>/dev/null; then
            echo 'session optional pam_exec.so seteuid /usr/local/bin/cipi-auth-notify' >> /etc/pam.d/su
        fi
        echo -e "${GREEN}✓ PAM auth notifications${NC}"
    fi
}

# ── CRON JOBS ─────────────────────────────────────────────────

setup_cron() {
    step_msg "Setting up cron jobs..."

    mkdir -p /var/log/cipi

    # Configure unattended-upgrades: security patches only.
    # nginx / mariadb / postgresql / valkey / php stay off the automatic path
    # (a database restart is not a 4am surprise). PHP has a daily cron
    # (`cipi php upgrade`); the others wait for `cipi nginx upgrade`,
    # `cipi db upgrade`, `cipi service upgrade valkey`.
    cat > /etc/apt/apt.conf.d/50cipi-unattended-upgrades <<'UUEOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::Package-Blacklist {
    "nginx";
    "nginx-core";
    "nginx-full";
    "nginx-extras";
    "mariadb-server";
    "mariadb-client";
    "mariadb-common";
    "postgresql";
    "postgresql-.*";
    "postgresql-common";
    "postgresql-client.*";
    "valkey";
    "valkey-server";
    "php.*";
    "libphp.*";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
Dpkg::Options {
    "--force-confdef";
    "--force-confold";
};
UUEOF

    # Enable periodic security updates
    cat > /etc/apt/apt.conf.d/20cipi-auto-upgrades <<'AUEOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
AUEOF

    (crontab -l 2>/dev/null | grep -v "CIPI" || true; cat <<'CRONEOF'
# === CIPI CRON JOBS ===
# Cipi self-update (daily 3:50 AM)
50 3 * * * /usr/local/bin/cipi-cron-notify self-update /usr/local/bin/cipi self-update >> /var/log/cipi/cipi.log 2>&1
# PHP security patch check (daily 3:30 AM)
30 3 * * * /usr/local/bin/cipi-cron-notify php-upgrade /usr/local/bin/cipi php upgrade >> /var/log/cipi/php-upgrade.log 2>&1
# SSL renewal (Sunday 4 AM) — no --nginx: each certificate renews the way it
# was issued (HTTP-01 via nginx, DNS-01 via Cloudflare for wildcards)
10 4 * * 0 /usr/local/bin/cipi-cron-notify ssl-renew certbot renew --non-interactive --post-hook "systemctl reload nginx" >> /var/log/cipi/certbot.log 2>&1
# Security updates — unattended-upgrades handles this daily via APT::Periodic
# Stack patches (nginx / MariaDB / PostgreSQL / Valkey): no cron — run
#   cipi nginx upgrade / cipi db upgrade / cipi service upgrade valkey
# Weekly apt cache cleanup (Sunday 5 AM)
0 5 * * 0 apt-get clean && apt-get autoclean >> /var/log/cipi/updates.log 2>&1
# Clear RAM cache (daily 5:50 AM)
50 5 * * * echo 3 > /proc/sys/vm/drop_caches && swapoff -a && swapon -a 2>/dev/null
CRONEOF
    ) | crontab -

    # ── GDPR-compliant log rotation ──

    # Application logs (Laravel, PHP-FPM, workers, deploy) — 12 months
    # *[!0-9].log leaves out files that end in a date (laravel-2026-01-31.log):
    # those belong to Laravel's `daily` channel, which names and prunes them
    # itself. Rotating them too left a .log.1 per day that never expired.
    cat > /etc/logrotate.d/cipi-app-logs <<'EOF'
/home/*/shared/storage/logs/*[!0-9].log
/home/*/logs/php-fpm-*.log
/home/*/logs/worker-*.log
/home/*/logs/deploy.log
/var/log/cipi/*.log
/var/log/cipi-queue.log {
    daily
    missingok
    rotate 365
    compress
    delaycompress
    notifempty
    copytruncate
}
EOF

    # HTTP / Navigation logs (nginx access & error) — 90 days
    cat > /etc/logrotate.d/cipi-http-logs <<'EOF'
/home/*/logs/nginx-access.log
/home/*/logs/nginx-error.log
/var/log/nginx/*.log {
    daily
    missingok
    rotate 90
    compress
    delaycompress
    notifempty
    sharedscripts
    copytruncate
    postrotate
        [ -f /var/run/nginx.pid ] && kill -USR1 $(cat /var/run/nginx.pid) 2>/dev/null || true
    endscript
}
EOF

    # Security logs (firewall, fail2ban, auth) — 12 months
    cat > /etc/logrotate.d/cipi-security-logs <<'EOF'
/var/log/fail2ban.log {
    daily
    missingok
    rotate 365
    compress
    delaycompress
    notifempty
    create 0640 root adm
    postrotate
        fail2ban-client flushlogs >/dev/null 2>&1 || true
    endscript
}
/var/log/ufw.log {
    daily
    missingok
    rotate 365
    compress
    delaycompress
    notifempty
    create 0640 syslog adm
    postrotate
        /usr/lib/rsyslog/rsyslog-rotate 2>/dev/null || invoke-rc.d rsyslog rotate >/dev/null 2>&1 || true
    endscript
}
/var/log/auth.log {
    daily
    missingok
    rotate 365
    compress
    delaycompress
    notifempty
    create 0640 syslog adm
    postrotate
        /usr/lib/rsyslog/rsyslog-rotate 2>/dev/null || invoke-rc.d rsyslog rotate >/dev/null 2>&1 || true
    endscript
}
EOF

    # Remove conflicting system logrotate configs
    rm -f /etc/logrotate.d/cipi-apps
    rm -f /etc/logrotate.d/nginx
    rm -f /etc/logrotate.d/fail2ban

    echo -e "${GREEN}✓ Cron jobs & GDPR log rotation${NC}"
}

# ── FINAL ─────────────────────────────────────────────────────

# The credentials once, in one layout (a title, then User: and Password:
# under it), and nothing else on the screen until they are saved — a field
# user lost the "save these" line under a page of optional commands. The
# optional layers come after, as questions.
final_summary() {
    clear

    [[ -n "$SERVER_IP" ]] || SERVER_IP=$(curl -s --max-time 5 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]') || SERVER_IP=""
    [[ -n "$SERVER_IP" ]] || SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    source "${CIPI_LIB}/vault.sh"
    source "${CIPI_LIB}/credentials.sh"
    CRED_SERVER_IP="$SERVER_IP"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "  ${GREEN}${BOLD}CIPI v${BUILD} INSTALLED SUCCESSFULLY${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo -e "  ${YELLOW}${BOLD}⚠ SAVE THESE CREDENTIALS NOW${NC}"
    echo -e "  ${DIM}Shown once here. Again later, logged in as cipi: sudo cipi credentials${NC}"
    echo -e "  ${DIM}As CSV for your password manager: sudo cipi credentials export${NC}"
    echo ""
    credentials_card
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    _confirm_credentials_saved
    echo ""
    echo -e "  ${BOLD}Getting started${NC}"
    echo -e "  Log in:         ${CYAN}ssh cipi@${SERVER_IP}${NC}"
    echo -e "  Server status:  ${CYAN}cipi status${NC}"
    echo -e "  Create an app:  ${CYAN}cipi app create${NC}"
    echo -e "  All commands:   ${CYAN}cipi help${NC}"
    echo -e "  ${DIM}Server sync key (cipi sync push): /home/cipi/.ssh/id_ed25519.pub${NC}"
    echo ""
    _setup_optional_wizard
}

# Nothing goes on until the credentials are saved: y, or the question again.
_confirm_credentials_saved() {
    if ! _has_tty; then
        echo -e "  ${DIM}No terminal — not asking. They are in /etc/cipi (encrypted): sudo cipi credentials${NC}"
        return 0
    fi
    local a
    while true; do
        echo -en "  ${BOLD}Have you saved these credentials in a password manager?${NC} [y/N] "
        read -r a < /dev/tty
        [[ "$a" =~ ^[Yy]$ ]] && break
        echo -e "  ${YELLOW}Please save them first — copy them into your password manager, then type y.${NC}"
    done
    echo -e "  ${GREEN}✓ Credentials saved${NC}"
}

# The optional layers, one yes/no each, instead of a page of commands under
# the credentials. Each runs the normal command with stdin on the terminal:
# this script's own stdin is the pipe from wget.
_setup_optional_wizard() {
    echo -e "  ${BOLD}Optional — a browser instead of SSH${NC}"
    echo -e "  ${DIM}Two layers, each a yes/no now or one command later. Both need a DNS A record of their own → ${SERVER_IP}.${NC}"
    echo ""
    if _has_tty; then
        echo -e "  ${BOLD}Panel API${NC} ${DIM}— REST + MCP for the web GUI, cipi-cli, CI and AI agents (~2 min)${NC}"
        if _ask_yn "Install the panel API now?"; then
            _setup_run_panel api
        fi
        echo ""
        echo -e "  ${BOLD}Web GUI${NC} ${DIM}— the control panel; it manages this server (and others) through their API${NC}"
        if _ask_yn "Install the web GUI on this server now?"; then
            _setup_run_panel gui
        fi
        echo ""
    fi
    echo -e "  ${BOLD}Later, whenever you want${NC}"
    echo -e "  ${CYAN}cipi api api.yourdomain.com${NC}      panel API — DNS check, install, HTTPS and a token in one go"
    echo -e "  ${CYAN}cipi gui panel.yourdomain.com${NC}    web GUI — DNS check, install and HTTPS in one go"
    echo -e "  ${CYAN}cipi db install pgsql${NC}            PostgreSQL next to MariaDB"
    echo -e "  ${CYAN}cipi search install${NC}              Meilisearch for Laravel Scout"
    echo -e "  ${DIM}Docs: https://cipi.sh/docs · GUI: https://github.com/cipi-sh/gui${NC}"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

# Ask the domain, run `cipi api|gui <domain>` (it checks the DNS first and
# stops when the name does not point here), offer another go on failure.
_setup_run_panel() {
    local what="$1" domain
    while true; do
        echo -en "  ${BOLD}Domain for the ${what}${NC} ${DIM}(A record → ${SERVER_IP}; empty = skip)${NC}: "
        read -r domain < /dev/tty
        domain=$(printf '%s' "$domain" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
        if [[ -z "$domain" ]]; then
            echo -e "  ${DIM}Skipped. Later: cipi ${what} <domain>${NC}"
            return 0
        fi
        [[ "$domain" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]] && break
        echo -e "  ${RED}Not a valid domain${NC}"
    done
    echo ""
    if /usr/local/bin/cipi "$what" "$domain" < /dev/tty; then
        return 0
    fi
    echo ""
    echo -e "  ${YELLOW}The ${what} setup did not complete — see above.${NC} Later: ${CYAN}cipi ${what} ${domain}${NC}"
    if _ask_yn "Try again?"; then
        _setup_run_panel "$what"
    fi
    return 0
}

# ── MAIN ──────────────────────────────────────────────────────

main() {
    # Fetch version early for logo display
    BUILD=$(curl -fsSL "https://raw.githubusercontent.com/${REPO}/refs/heads/${BRANCH}/version.md" 2>/dev/null | tr -d '[:space:]')
    [[ -z "$BUILD" ]] && BUILD="?"

    show_logo
    check_requirements
    collect_ssh_keys
    confirm_plan
    install_basics
    setup_swap
    setup_system
    setup_ssh
    install_nginx
    install_firewall
    install_mariadb
    install_php
    install_composer
    install_deployer
    install_nodejs
    install_supervisor
    install_valkey
    install_certbot
    install_cipi
    setup_pam || echo -e "${YELLOW}⚠ setup_pam failed, continuing...${NC}"
    setup_cron || echo -e "${YELLOW}⚠ setup_cron failed, continuing...${NC}"
    final_summary
}

main

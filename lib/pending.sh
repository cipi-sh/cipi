#!/bin/bash
#############################################
# Cipi — What is waiting for someone
#
# A server can be fully "up to date" and still run last month's kernel,
# because nothing restarts it; hold a patch for a component whose automatic
# update was switched off; or carry something Cipi no longer looks after.
# None of that showed anywhere. This collects it in one list:
#
#   - a reboot that installed updates are waiting for (kernel, libc, …)
#   - PHP below the security floor, or a branch that is end of life
#   - a newer package of nginx / MariaDB / PostgreSQL / Valkey where the
#     automatic update is off, or where its last run failed
#   - Composer and Node.js below their security floors
#   - PHP extensions that were installed with PECL (deprecated by the PHP
#     project in favour of PIE; nothing updates them)
#   - apps that still share one Valkey instance and one password
#   - Ubuntu's security updates not automatic; logrotate refusing a Cipi rule
#
#   cipi pending [--json]     the list
#   cipi pending --cron       daily: mails the list when it changed, and
#                             again every 7 days for as long as it lasts
#
#   cipi reboot                         is one needed, and since when
#   cipi reboot now [--yes]             restart the server (in one minute)
#   cipi reboot auto on [--at=HH:MM]    restart at night when one is needed
#   cipi reboot auto off
#############################################

[[ -z "${PENDING_STATE:-}" ]] && readonly PENDING_STATE="/var/lib/cipi/pending.state"
[[ -z "${PENDING_CRON:-}" ]]  && readonly PENDING_CRON="/etc/cron.d/cipi-pending"
[[ -z "${REBOOT_CRON:-}" ]]   && readonly REBOOT_CRON="/etc/cron.d/cipi-auto-reboot"
[[ -z "${REBOOT_FLAG:-}" ]]   && readonly REBOOT_FLAG="/var/run/reboot-required"
[[ -z "${PENDING_CACHE:-}" ]] && readonly PENDING_CACHE="/var/lib/cipi/pending.cache"
[[ -z "${PENDING_REMAIL_DAYS:-}" ]] && readonly PENDING_REMAIL_DAYS=7

# One item per line: severity (critical|warning|note) <TAB> id <TAB> what
# <TAB> what to run. The id is stable from day to day for the same problem.
PENDING_ITEMS=()
_pending_add() { PENDING_ITEMS+=("$1"$'\t'"$2"$'\t'"$3"$'\t'"${4:-}"); }

_pending_load_libs() {
    declare -f _stack_upgrade_present >/dev/null || source "${CIPI_LIB}/stack-upgrade.sh"
    declare -f node_full_version >/dev/null      || source "${CIPI_LIB}/node.sh"
    declare -f autoupdate_enabled >/dev/null     || source "${CIPI_LIB}/autoupdate.sh"
    if [[ -f "${CIPI_LIB}/valkey.sh" ]]; then
        declare -f valkey_shared_apps >/dev/null || source "${CIPI_LIB}/valkey.sh"
    fi
}

# ── reboot ───────────────────────────────────────────────────
# Ubuntu's own flag (written by the kernel and libc packages), and — where
# the flag is gone or was never written — the newest kernel in /boot against
# the one that is running. Prints "<since YYYY-MM-DD or ->|<running>|<newest>",
# returns 1 when no reboot is needed.
reboot_needed() {
    local since="-" running newest=""
    running=$(uname -r 2>/dev/null || true)
    if compgen -G "/boot/vmlinuz-*" >/dev/null; then
        newest=$(ls /boot/vmlinuz-* 2>/dev/null | sed 's|^/boot/vmlinuz-||' | sort -V | tail -n 1 || true)
    fi
    if [[ -f "$REBOOT_FLAG" ]]; then
        since=$(date -r "$REBOOT_FLAG" '+%Y-%m-%d' 2>/dev/null || echo "-")
    elif [[ -z "$newest" || "$newest" == "$running" || ! -e "/boot/vmlinuz-${running}" ]]; then
        # No flag, and either no newer kernel or a kernel that is not from
        # /boot at all (a container, a provider's own kernel): nothing to say.
        return 1
    fi
    printf '%s|%s|%s\n' "$since" "$running" "${newest:-$running}"
}

reboot_auto_enabled() { [[ -f "$REBOOT_CRON" ]]; }

_pending_reboot() {
    local r since running newest what fix
    r=$(reboot_needed) || return 0
    IFS='|' read -r since running newest <<< "$r"
    what="Reboot required"
    [[ "$since" != "-" ]] && what="${what} since ${since}"
    if [[ -n "$newest" && "$newest" != "$running" ]]; then
        what="${what}: kernel ${newest} is installed, ${running} is running — its security fixes are not active until the server restarts"
    else
        what="${what}: installed updates (kernel or core libraries) are not active until the server restarts"
    fi
    if reboot_auto_enabled; then
        fix="automatic reboot is on (next night) — or now: cipi reboot now"
    else
        fix="cipi reboot now   (or every time one is needed: cipi reboot auto on)"
    fi
    _pending_add critical reboot "$what" "$fix"
}

# ── PHP ──────────────────────────────────────────────────────
_pending_php() {
    local v state full floor
    for v in 7.4 8.0 8.1 8.2 8.3 8.4 8.5; do
        php_is_installed "$v" || continue
        read -r state full <<< "$(php_security_state "$v")"
        floor=$(php_security_floor "$v")
        case "$state" in
            vulnerable)
                _pending_add critical "php-${v}" "PHP ${full} is below ${floor}, the release with the latest security fixes" "cipi php upgrade"
                ;;
            eol)
                _pending_add warning "php-${v}-eol" "PHP ${v} (${full}) is end of life — the PHP project no longer patches it" "move its apps: cipi app edit <app> --php=8.5"
                ;;
        esac
    done
}

# ── packages held back from unattended-upgrades ──────────────
# "<package> <installed>→<candidate>" for each package whose candidate is
# not what is installed. Reads the apt index as it is (unattended-upgrades
# refreshes it every day).
_pending_apt_waiting() {
    [[ $# -gt 0 ]] || return 0
    LC_ALL=C apt-cache policy "$@" 2>/dev/null | awk '
        /^[^ ]/           { pkg = $1; sub(/:$/, "", pkg) }
        /^  Installed:/   { inst = $2 }
        /^  Candidate:/   { if (inst != "(none)" && $2 != "(none)" && inst != $2) print pkg, inst "→" $2 }' || true
}

_pending_stack() {
    local kind label waiting first n state st ts note
    local -a pkgs
    for kind in nginx mariadb pgsql valkey; do
        _stack_upgrade_present "$kind" || continue
        label=$(_stack_upgrade_label "$kind")
        if autoupdate_enabled "$kind"; then
            state=$(autoupdate_state_get "$kind")
            read -r st ts note <<< "${state:-- 0}"
            if [[ "$st" == "failed" ]]; then
                _pending_add warning "autoupdate-${kind}" \
                    "The automatic update of ${label} failed on $(date -d "@${ts}" '+%Y-%m-%d' 2>/dev/null || echo '?')" \
                    "cipi autoupdate run ${kind}   (log: /var/log/cipi/autoupdate.log)"
            fi
            continue
        fi
        pkgs=()
        while IFS= read -r first; do [[ -n "$first" ]] && pkgs+=("$first"); done < <(_stack_upgrade_list_pkgs "$kind" || true)
        [[ ${#pkgs[@]} -gt 0 ]] || continue
        waiting=$(_pending_apt_waiting "${pkgs[@]}")
        [[ -n "$waiting" ]] || continue
        n=$(wc -l <<< "$waiting")
        first=$(head -n 1 <<< "$waiting")
        _pending_add warning "stack-${kind}" \
            "${label}: ${n} package update(s) waiting (${first}) — its automatic update is off" \
            "cipi autoupdate run ${kind}   (every night: cipi autoupdate on ${kind})"
    done
}

# ── Composer, Node.js ────────────────────────────────────────
_pending_composer() {
    [[ -x /usr/local/bin/composer ]] || return 0
    local cv floor
    floor=$(composer_security_floor)
    cv=$(COMPOSER_ALLOW_SUPERUSER=1 /usr/local/bin/composer --version --no-ansi 2>/dev/null \
            | sed -n 's/.*Composer version \([0-9][0-9.]*\).*/\1/p' | head -n 1 || true)
    [[ -n "$cv" ]] || return 0
    version_at_least "$cv" "$floor" && return 0
    _pending_add warning composer "Composer ${cv} is below ${floor}, the release with the latest security fixes" "cipi autoupdate run composer"
}

_pending_node_one() {   # <label> <full version>
    local label="$1" full="$2" major floor
    [[ "$full" =~ ^([0-9]+)\.[0-9]+\.[0-9]+ ]] || return 0
    major="${BASH_REMATCH[1]}"
    floor=$(node_security_floor "$major")
    if [[ -z "$floor" ]]; then
        # Odd majors and lines past their end of life get no fixes at all.
        if (( major < 22 )); then
            _pending_add warning "node-${label}-eol" "Node.js ${full} (${label}) is end of life — it no longer gets security fixes" "cipi node install 24, then move what uses it (cipi node help)"
        fi
        return 0
    fi
    version_at_least "$full" "$floor" && return 0
    _pending_add warning "node-${label}" "Node.js ${full} (${label}) is below ${floor}, the release with the latest security fixes" "cipi autoupdate run node"
}

_pending_node() {
    local l m
    for l in "${NODE_ROOT}"/[0-9]*; do
        [[ -L "$l" ]] || continue
        m=$(basename "$l")
        node_is_installed "$m" || continue
        _pending_node_one "$m" "$(node_full_version "$m" || true)"
    done
    if [[ -x /usr/bin/node ]]; then
        _pending_node_one system "$(/usr/bin/node --version 2>/dev/null | tr -d v || true)"
    fi
}

# ── PECL ─────────────────────────────────────────────────────
# Cipi installs PHP extensions from apt only, and `cipi php upgrade` patches
# those. An extension someone built with `pecl install` is a file no package
# owns: nothing updates it, it is compiled for one PHP version, and PECL
# itself is deprecated by the PHP project (PIE replaces it). Two signs, both
# read-only: PECL's own registry, and .so files in PHP's extension
# directories that dpkg does not know.
pecl_extensions() {
    local reg f name so out=""
    for reg in /usr/share/php/.registry/.channel.pecl.php.net /usr/share/pear/.registry/.channel.pecl.php.net; do
        [[ -d "$reg" ]] || continue
        for f in "$reg"/*.reg; do
            [[ -f "$f" ]] || continue
            name="${f##*/}"; name="${name%.reg}"
            out="${out}${name}"$'\n'
        done
    done
    if compgen -G "/usr/lib/php/2*/*.so" >/dev/null; then
        while IFS= read -r so; do
            [[ -n "$so" ]] || continue
            name="${so##*/}"; name="${name%.so}"
            out="${out}${name}"$'\n'
        done < <(LC_ALL=C dpkg-query -S /usr/lib/php/2*/*.so 2>&1 >/dev/null \
                    | sed -n 's/^dpkg-query: no path found matching pattern \(.*\)$/\1/p' || true)
    fi
    [[ -n "$out" ]] || return 0
    printf '%s' "$out" | sort -u
}

_pending_pecl() {
    local list n
    list=$(pecl_extensions || true)
    [[ -n "$list" ]] || return 0
    n=$(wc -l <<< "$list")
    _pending_add warning pecl \
        "${n} PHP extension(s) not installed from apt (PECL or built by hand): $(paste -sd' ' - <<< "$list" | cut -c1-200) — Cipi does not update them, and PECL is deprecated by the PHP project" \
        "use the apt package where there is one (apt install php8.5-<name>), otherwise PIE: https://github.com/php/pie"
}

# ── Valkey ───────────────────────────────────────────────────
_pending_valkey() {
    declare -f valkey_shared_apps >/dev/null || return 0
    local list n
    list=$(valkey_shared_apps || true)
    [[ -n "$list" ]] || return 0
    n=$(wc -l <<< "$list")
    (( n > 1 )) || return 0
    _pending_add warning valkey-shared \
        "${n} apps share one Valkey instance and one password — each can read the others' cache, sessions and queues: $(paste -sd' ' - <<< "$list" | cut -c1-200)" \
        "cipi valkey isolate <app>   (or all of them: cipi valkey isolate --all)"
}

# ── Horizon installed, nothing running it ────────────────────
# Deploys started by a Git push run as the app's user and cannot start a
# supervisor program: the case `cipi deploy` settles by itself is reported
# here for the apps that are only ever deployed that way.
_pending_horizon() {
    [[ -f "${CIPI_CONFIG}/apps.json" ]] || return 0
    declare -f deploy_horizon_state >/dev/null || source "${CIPI_LIB}/deploy.sh"
    local app list=""
    while IFS= read -r app; do
        [[ -n "$app" ]] || continue
        [[ "$(deploy_horizon_state "$app" || true)" == "enable" ]] && list="${list} ${app}"
    done < <(vault_read apps.json 2>/dev/null | jq -r 'to_entries[] | select((.value.custom // false) != true and (.value.custom // "") != "true" and (.value.horizon // "") != "true") | .key' 2>/dev/null || true)
    [[ -n "$list" ]] || return 0
    _pending_add warning horizon \
        "laravel/horizon is installed, the queues are on Redis and no worker is configured — nothing processes the jobs of:${list}" \
        "cipi worker horizon enable <app>   (the next cipi deploy <app> does it by itself)"
}

# ── the rest ─────────────────────────────────────────────────
_pending_unattended() {
    command -v apt-config >/dev/null 2>&1 || return 0
    local v
    v=$(apt-config dump APT::Periodic::Unattended-Upgrade 2>/dev/null | sed -n 's/.*"\(.*\)";.*/\1/p' | head -n 1 || true)
    [[ "$v" == "1" || "$v" == "always" ]] && return 0
    _pending_add warning unattended "Ubuntu's security updates are not installed automatically (APT::Periodic::Unattended-Upgrade is \"${v:-unset}\")" \
        "restore /etc/apt/apt.conf.d/20cipi-auto-upgrades, or: dpkg-reconfigure -plow unattended-upgrades"
}

_pending_logrotate() {
    local out
    out=$(logrotate_cipi_check) && return 0
    _pending_add warning logrotate "logrotate reports a problem with a Cipi rule: $(head -n 1 <<< "$out" | cut -c1-200)" \
        "logrotate -d /etc/logrotate.d/cipi-*   then: cipi app fix-permissions"
}

# Fills PENDING_ITEMS, and keeps the list for `cipi status` (the panel asks
# for the status every few seconds: it reads the list, it does not rebuild it).
pending_collect() {
    PENDING_ITEMS=()
    _pending_load_libs
    _pending_reboot
    _pending_php
    _pending_stack
    _pending_composer
    _pending_node
    _pending_pecl
    _pending_valkey
    _pending_horizon
    _pending_unattended
    _pending_logrotate
    _pending_cache_write
    return 0
}

_pending_cache_write() {
    local tmp line
    mkdir -p "$(dirname "$PENDING_CACHE")" 2>/dev/null || return 0
    tmp=$(mktemp "${PENDING_CACHE}.XXXXXX" 2>/dev/null) || return 0
    for line in "${PENDING_ITEMS[@]+"${PENDING_ITEMS[@]}"}"; do printf '%s\n' "$line"; done > "$tmp"
    chmod 600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$PENDING_CACHE" 2>/dev/null || rm -f "$tmp"
    return 0
}

_pending_print() {
    local line sev id what fix col
    if [[ ${#PENDING_ITEMS[@]} -eq 0 ]]; then
        echo -e "  ${GREEN}✓${NC} Nothing is waiting"
        return 0
    fi
    for line in "${PENDING_ITEMS[@]}"; do
        IFS=$'\t' read -r sev id what fix <<< "$line"
        case "$sev" in
            critical) col="$RED" ;;
            warning)  col="$YELLOW" ;;
            *)        col="$DIM" ;;
        esac
        echo -e "  ${col}●${NC} ${what}"
        [[ -n "$fix" ]] && echo -e "    ${DIM}→${NC} ${CYAN}${fix}${NC}"
    done
    return 0
}

_pending_json() {
    local line sev id what fix
    {
        for line in "${PENDING_ITEMS[@]+"${PENDING_ITEMS[@]}"}"; do
            IFS=$'\t' read -r sev id what fix <<< "$line"
            jq -n --arg s "$sev" --arg i "$id" --arg w "$what" --arg f "$fix" \
                '{severity: $s, id: $i, message: $w, fix: $f}'
        done
    } | jq -s '{count: length, items: .}'
}

_pending_plain() {
    local line sev id what fix
    for line in "${PENDING_ITEMS[@]+"${PENDING_ITEMS[@]}"}"; do
        IFS=$'\t' read -r sev id what fix <<< "$line"
        printf -- '- [%s] %s\n' "$sev" "$what"
        [[ -n "$fix" ]] && printf '    %s\n' "$fix"
    done
    return 0
}

# Daily. The mail goes out when the list is not the one already mailed, and
# again after PENDING_REMAIL_DAYS for as long as something is on it — never
# every day for the same thing. An empty list clears the memory, so the same
# problem coming back is news again.
_pending_cron() {
    pending_collect
    local n=${#PENDING_ITEMS[@]} hash prev_hash="" prev_ts=0 now body line
    now=$(date +%s)
    mkdir -p "$(dirname "$PENDING_STATE")" 2>/dev/null || true
    if [[ "$n" -eq 0 ]]; then
        rm -f "$PENDING_STATE"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] nothing waiting"
        return 0
    fi
    hash=$(for line in "${PENDING_ITEMS[@]}"; do cut -f2,3 <<< "$line"; done | sort | sha256sum | cut -d' ' -f1)
    if [[ -f "$PENDING_STATE" ]]; then
        { read -r prev_hash; read -r prev_ts; } < "$PENDING_STATE" || true
        [[ "$prev_ts" =~ ^[0-9]+$ ]] || prev_ts=0
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${n} item(s) waiting"
    _pending_plain
    if [[ "$hash" == "$prev_hash" ]] && (( now - prev_ts < PENDING_REMAIL_DAYS * 86400 )); then
        return 0
    fi
    body="$(_pending_plain)"
    cipi_notify \
        "Cipi: ${n} thing(s) need attention on $(hostname)" \
        "Server: $(hostname)\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')\n\n${body}\n\nThe same list, any time: cipi pending" \
        pending_report
    printf '%s\n%s\n' "$hash" "$now" > "$PENDING_STATE" 2>/dev/null || true
    return 0
}

pending_cron_write() {
    [[ -d /etc/cron.d ]] || return 0
    cat > "$PENDING_CRON" <<'EOF'
# Cipi — daily look at what is waiting: a reboot, a patch, a warning
# (cipi pending). Mails the list when it changes; off: cipi notifications.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
30 7 * * * root /usr/local/bin/cipi pending --cron >> /var/log/cipi/pending.log 2>&1
EOF
    chmod 644 "$PENDING_CRON"
}

pending_command() {
    parse_args "$@"
    if [[ "${ARG_cron:-}" == "true" ]]; then
        _pending_cron
        return 0
    fi
    pending_collect
    if [[ "${ARG_json:-}" == "true" ]]; then
        _pending_json
        return 0
    fi
    echo -e "\n${BOLD}Waiting for you${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    _pending_print
    echo ""
    if [[ ! -f "$PENDING_CRON" ]]; then
        echo -e "  ${DIM}The daily check is not installed (${PENDING_CRON}) — cipi self-update restores it${NC}\n"
    fi
}

# For `cipi status`: the list, or nothing at all when it is empty. The reboot
# is looked at now (two stats); the rest is the list of this morning's check,
# or of the last `cipi pending`.
pending_status_section() {
    local line
    PENDING_ITEMS=()
    _pending_reboot
    if [[ -f "$PENDING_CACHE" && -z "$(find "$PENDING_CACHE" -mtime +2 2>/dev/null)" ]]; then
        while IFS= read -r line; do
            [[ -n "$line" && "$(cut -f2 <<< "$line")" != "reboot" ]] && PENDING_ITEMS+=("$line")
        done < "$PENDING_CACHE"
    fi
    [[ ${#PENDING_ITEMS[@]} -gt 0 ]] || return 0
    echo -e "${BOLD}Waiting for you${NC} ${DIM}(cipi pending)${NC}"
    _pending_print
    echo ""
}

# ── reboot ───────────────────────────────────────────────────

# What a restart would cut in half. Prints the reason, returns 0 when busy.
_reboot_busy() {
    if pgrep -x 'apt-get|apt|dpkg|unattended-upgr' >/dev/null 2>&1; then
        echo "a package installation is running"; return 0
    fi
    if pgrep -x 'mariadb-dump|mysqldump|mariabackup|mariadb-backup|pg_dump|pg_dumpall|pg_basebackup|pg_restore' >/dev/null 2>&1; then
        echo "a database dump is running"; return 0
    fi
    if pgrep -f '/usr/local/bin/dep (deploy|rollback) ' >/dev/null 2>&1; then
        echo "a deploy is running"; return 0
    fi
    # Another cipi command at work: a backup, a scan, an update, a sync.
    local other
    other=$(pgrep -af '/usr/local/bin/cipi [a-z]' 2>/dev/null | grep -vE '/usr/local/bin/cipi (reboot|pending|status|help|version)' | head -n 1 || true)
    if [[ -n "$other" ]]; then
        echo "another cipi command is running (${other#* })"; return 0
    fi
    return 1
}

_reboot_status() {
    local r since running newest
    echo -e "\n${BOLD}Reboot${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if r=$(reboot_needed); then
        IFS='|' read -r since running newest <<< "$r"
        echo -e "  ${RED}●${NC} Required$([[ "$since" != "-" ]] && echo " since ${since}")"
        printf "  %-16s %s\n" "Running kernel" "$running"
        [[ "$newest" != "$running" ]] && printf "  %-16s %s\n" "Installed kernel" "$newest"
        if [[ -s "${REBOOT_FLAG}.pkgs" ]]; then
            printf "  %-16s %s\n" "Asked by" "$(sort -u "${REBOOT_FLAG}.pkgs" 2>/dev/null | paste -sd' ' - | cut -c1-160)"
        fi
    else
        echo -e "  ${GREEN}●${NC} Not required  ${DIM}(kernel $(uname -r))${NC}"
    fi
    printf "  %-16s %s\n" "Uptime" "$(uptime -p 2>/dev/null || true)"
    if reboot_auto_enabled; then
        local at
        at=$(awk '$6 == "root" && /cipi reboot --if-required/ { printf "%02d:%02d", $2, $1; exit }' "$REBOOT_CRON" 2>/dev/null || true)
        echo -e "  Automatic        ${GREEN}on${NC} — at ${at:-night}, only when one is required"
    else
        echo -e "  Automatic        ${YELLOW}off${NC} — a required reboot waits for: cipi reboot now"
    fi
    echo ""
    echo -e "  ${CYAN}cipi reboot now [--yes]${NC}"
    echo -e "  ${CYAN}cipi reboot auto on [--at=HH:MM] | off${NC}"
    echo ""
}

_reboot_now() {
    parse_args "$@"
    if [[ "${ARG_yes:-}" != "true" && "${ARG_force:-}" != "true" ]]; then
        local why
        if why=$(_reboot_busy); then
            warn "${why}"
        fi
        confirm "Restart this server in one minute? Every site on it goes down until it is back." || { info "Aborted"; return 0; }
    fi
    log_action "REBOOT: requested"
    cipi_notify \
        "Cipi: $(hostname) is restarting" \
        "A reboot was requested.\n\nServer: $(hostname)\nKernel now: $(uname -r)\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        reboot
    shutdown -r +1 "Cipi: reboot requested" || { error "shutdown failed"; return 1; }
    success "The server restarts in one minute (cancel: shutdown -c)"
}

# What the nightly job runs. Silent when no reboot is needed; leaves it for
# the next night when something would be cut in half.
_reboot_if_required() {
    local r since running newest why
    r=$(reboot_needed) || return 0
    IFS='|' read -r since running newest <<< "$r"
    if why=$(_reboot_busy); then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] reboot required, but ${why} — left for the next run"
        return 0
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] reboot required (running ${running}, installed ${newest}) — restarting in 2 minutes"
    log_action "REBOOT: automatic (running ${running}, installed ${newest})"
    cipi_notify \
        "Cipi: $(hostname) is restarting (automatic)" \
        "Installed updates need a reboot, and automatic reboot is on.\n\nServer: $(hostname)\nKernel now: ${running}\nKernel after: ${newest}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')\n\nSwitch it off: cipi reboot auto off" \
        reboot
    shutdown -r +2 "Cipi: automatic reboot (installed updates need it)"
}

_reboot_auto() {
    local to="${1:-}"; shift || true
    parse_args "$@"
    case "$to" in
        on|enable)
            local at="${ARG_at:-04:45}" hh mm
            [[ "$at" =~ ^([01][0-9]|2[0-3]):([0-5][0-9])$ ]] || { error "--at=HH:MM (24 hours), for example --at=04:45"; return 1; }
            hh=$((10#${BASH_REMATCH[1]})); mm=$((10#${BASH_REMATCH[2]}))
            [[ -d /etc/cron.d ]] || { error "/etc/cron.d not found"; return 1; }
            cat > "$REBOOT_CRON" <<EOF
# Cipi — restart the server at night when installed updates need it
# (cipi reboot auto). Does nothing on the nights no reboot is required.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
${mm} ${hh} * * * root /usr/local/bin/cipi reboot --if-required >> /var/log/cipi/reboot.log 2>&1
EOF
            chmod 644 "$REBOOT_CRON"
            log_action "REBOOT AUTO: on (${at})"
            success "Automatic reboot on: at ${at}, only on the nights one is required"
            info "Skipped while a deploy, a dump, a package installation or another cipi command is running"
            ;;
        off|disable)
            rm -f "$REBOOT_CRON"
            log_action "REBOOT AUTO: off"
            success "Automatic reboot off — a required reboot is reported by: cipi pending"
            ;;
        *) error "Use: cipi reboot auto on [--at=HH:MM] | off"; return 1 ;;
    esac
}

reboot_command() {
    local sub="${1:-status}"
    case "$sub" in
        status|"")     _reboot_status ;;
        now)           shift; _reboot_now "$@" ;;
        auto)          shift; _reboot_auto "$@" ;;
        --if-required) _reboot_if_required ;;
        *) error "Use: cipi reboot [status] | now [--yes] | auto on [--at=HH:MM] | auto off"; return 1 ;;
    esac
}

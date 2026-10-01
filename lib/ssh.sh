#!/bin/bash
#############################################
# Cipi — SSH Key Management, and remote SSH access of app users
#############################################

AUTHORIZED_KEYS="/home/cipi/.ssh/authorized_keys"

ssh_command() {
    local sub="${1:-}"; shift||true
    case "$sub" in
        list)   _ssh_list "$@" ;;
        add)    _ssh_add "$@" ;;
        remove) _ssh_remove "$@" ;;
        rename) _ssh_rename "$@" ;;
        apps)   _ssh_apps "$@" ;;
        *)      error "Use: list add remove rename apps"; exit 1 ;;
    esac
}

# ── HELPERS ──────────────────────────────────────────────────

# Get the fingerprint of the SSH key used for the current session.
# Requires ExposeAuthInfo=yes in sshd_config and SSH_USER_AUTH env preserved via sudoers.
# SSH_USER_AUTH format: publickey <key_type> <raw_key_data> — field 3 is raw key, not fingerprint
_get_session_fingerprint() {
    local auth_file="${SSH_USER_AUTH:-}"
    [[ -z "$auth_file" || ! -f "$auth_file" ]] && return

    local key_type key_data fp
    key_type=$(awk '/^publickey / {print $2; exit}' "$auth_file" 2>/dev/null)
    key_data=$(awk '/^publickey / {print $3; exit}' "$auth_file" 2>/dev/null)
    if [[ -n "$key_type" && -n "$key_data" ]]; then
        fp=$(echo "$key_type $key_data" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}')
        [[ -n "$fp" ]] && echo "$fp"
    fi
}

# ── LIST ─────────────────────────────────────────────────────

_ssh_list() {
    parse_args "$@"
    local session_fp
    session_fp=$(_get_session_fingerprint)

    if [[ "${ARG_json:-}" == "true" ]]; then
        local items="[]"
        local i=0
        if [[ -f "$AUTHORIZED_KEYS" ]] && [[ -s "$AUTHORIZED_KEYS" ]]; then
            while IFS= read -r line; do
                [[ -z "$line" || "$line" == \#* ]] && continue
                (( i++ )) || true
                local key_type comment fingerprint current=false
                key_type=$(echo "$line" | awk '{print $1}')
                comment=$(echo "$line" | awk '{$1=$2=""; print}' | xargs)
                [[ -z "$comment" ]] && comment="(no comment)"
                fingerprint=$(echo "$line" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}') || fingerprint="?"
                [[ -n "$session_fp" && "$fingerprint" == "$session_fp" ]] && current=true
                items=$(echo "$items" | jq -c --argjson id "$i" --arg t "$key_type" --arg c "$comment" --arg f "$fingerprint" --argjson cur "$current" \
                    '. + [{id:$id, type:$t, comment:$c, fingerprint:$f, current_session:$cur}]')
            done < "$AUTHORIZED_KEYS"
        fi
        jq -n --argjson keys "$items" '{keys: $keys}'
        return 0
    fi

    if [[ ! -f "$AUTHORIZED_KEYS" ]] || [[ ! -s "$AUTHORIZED_KEYS" ]]; then
        warn "No SSH keys configured for cipi user"
        exit 0
    fi

    echo ""
    echo -e "  ${BOLD}SSH Keys (cipi user)${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    local i=0
    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        (( i++ )) || true

        # Extract key type, fingerprint and comment
        local key_type comment fingerprint
        key_type=$(echo "$line" | awk '{print $1}')
        comment=$(echo "$line" | awk '{$1=$2=""; print}' | xargs)
        [[ -z "$comment" ]] && comment="(no comment)"

        fingerprint=$(echo "$line" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}') || fingerprint="?"

        local active_marker=""
        if [[ -n "$session_fp" && "$fingerprint" == "$session_fp" ]]; then
            active_marker=" ${GREEN}<< current session${NC}"
        fi

        echo -e "  ${CYAN}${i}${NC}  ${BOLD}${comment}${NC}${active_marker}"
        echo -e "     ${DIM}${key_type} · ${fingerprint}${NC}"
        echo ""
    done < "$AUTHORIZED_KEYS"

    if [[ $i -eq 0 ]]; then
        warn "No SSH keys configured for cipi user"
    else
        echo -e "  ${DIM}Total: ${i} key(s)${NC}"
    fi
    echo ""
}

# ── ADD ──────────────────────────────────────────────────────

_ssh_add() {
    local key="${*}"

    if [[ -z "$key" ]]; then
        echo ""
        echo -e "  ${BOLD}Add SSH Key${NC}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo -e "  ${DIM}Generate a key on your machine:${NC}"
        echo -e "  ${CYAN}ssh-keygen -t ed25519 -C \"your@email.com\"${NC}"
        echo -e "  ${CYAN}cat ~/.ssh/id_ed25519.pub${NC}"
        echo ""
        echo -en "  ${BOLD}Paste the public key:${NC} "
        read -r key
    fi

    if [[ -z "$key" ]]; then
        error "No key provided"
        exit 1
    fi

    # Validate format
    if ! echo "$key" | grep -qE '^(ssh-(rsa|ed25519)|ecdsa-sha2-\S+) '; then
        error "Invalid key format. Must start with ssh-rsa, ssh-ed25519, or ecdsa-sha2-*"
        exit 1
    fi

    # Check for duplicates
    if grep -qF "$key" "$AUTHORIZED_KEYS" 2>/dev/null; then
        warn "Key already exists"
        exit 0
    fi

    # Append
    echo "$key" >> "$AUTHORIZED_KEYS"
    chown cipi:cipi "$AUTHORIZED_KEYS"
    chmod 600 "$AUTHORIZED_KEYS"

    local comment
    comment=$(echo "$key" | awk '{$1=$2=""; print}' | xargs)
    [[ -z "$comment" ]] && comment="(no comment)"

    local fingerprint
    fingerprint=$(echo "$key" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}') || fingerprint="?"

    success "Key added: ${comment}"
    log_action "SSH KEY ADD: ${comment}"

    # Email notification
    local server_ip; server_ip=$(curl -s --max-time 3 https://checkip.amazonaws.com 2>/dev/null || hostname)
    cipi_notify \
        "Cipi SSH key added on $(hostname)" \
        "An SSH key was added to the cipi user.\n\nServer: $(hostname) (${server_ip})\nComment: ${comment}\nFingerprint: ${fingerprint}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        ssh_key_add
}

# ── RENAME ──────────────────────────────────────────────────

_ssh_rename() {
    local target="${1:-}"
    local new_name="${2:-}"

    if [[ ! -f "$AUTHORIZED_KEYS" ]] || [[ ! -s "$AUTHORIZED_KEYS" ]]; then
        warn "No SSH keys to rename"
        exit 0
    fi

    local -a keys=()
    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        keys+=("$line")
    done < "$AUTHORIZED_KEYS"

    if [[ ${#keys[@]} -eq 0 ]]; then
        warn "No SSH keys to rename"
        exit 0
    fi

    if [[ -z "$target" ]]; then
        echo ""
        echo -e "  ${BOLD}Rename SSH Key${NC}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""

        local i=0
        for k in "${keys[@]}"; do
            (( i++ )) || true
            local comment
            comment=$(echo "$k" | awk '{$1=$2=""; print}' | xargs)
            [[ -z "$comment" ]] && comment="(no comment)"
            local fingerprint
            fingerprint=$(echo "$k" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}') || fingerprint="?"
            echo -e "  ${CYAN}${i}${NC}  ${BOLD}${comment}${NC}"
            echo -e "     ${DIM}${fingerprint}${NC}"
            echo ""
        done

        echo -en "  ${BOLD}Key number to rename (or 'q' to cancel):${NC} "
        read -r target
    fi

    [[ "$target" == "q" || -z "$target" ]] && { echo "  Cancelled"; exit 0; }

    if ! [[ "$target" =~ ^[0-9]+$ ]] || [[ "$target" -lt 1 ]] || [[ "$target" -gt ${#keys[@]} ]]; then
        error "Invalid selection: ${target} (must be 1-${#keys[@]})"
        exit 1
    fi

    if [[ -z "$new_name" ]]; then
        echo -en "  ${BOLD}New name:${NC} "
        read -r new_name
    fi

    if [[ -z "$new_name" ]]; then
        error "Name cannot be empty"
        exit 1
    fi

    local selected_key="${keys[$((target-1))]}"
    local key_type key_data
    key_type=$(echo "$selected_key" | awk '{print $1}')
    key_data=$(echo "$selected_key" | awk '{print $2}')
    local updated_key="${key_type} ${key_data} ${new_name}"

    local tmp
    tmp=$(mktemp)
    local idx=0
    while IFS= read -r line; do
        if [[ -z "$line" || "$line" == \#* ]]; then
            echo "$line" >> "$tmp"
            continue
        fi
        (( idx++ )) || true
        if [[ $idx -eq $target ]]; then
            echo "$updated_key" >> "$tmp"
        else
            echo "$line" >> "$tmp"
        fi
    done < "$AUTHORIZED_KEYS"

    mv "$tmp" "$AUTHORIZED_KEYS"
    chown cipi:cipi "$AUTHORIZED_KEYS"
    chmod 600 "$AUTHORIZED_KEYS"

    local old_comment
    old_comment=$(echo "$selected_key" | awk '{$1=$2=""; print}' | xargs)
    [[ -z "$old_comment" ]] && old_comment="(no comment)"

    local fingerprint
    fingerprint=$(echo "$selected_key" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}') || fingerprint="?"

    success "Key ${target} renamed to: ${new_name}"
    log_action "SSH KEY RENAME: ${old_comment} -> ${new_name}"

    # Email notification
    local server_ip; server_ip=$(curl -s --max-time 3 https://checkip.amazonaws.com 2>/dev/null || hostname)
    cipi_notify \
        "Cipi SSH key renamed on $(hostname)" \
        "An SSH key was renamed on the cipi user.\n\nServer: $(hostname) (${server_ip})\nOld name: ${old_comment}\nNew name: ${new_name}\nFingerprint: ${fingerprint}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        ssh_key_rename
}

# ── REMOVE ───────────────────────────────────────────────────

_ssh_remove() {
    local target="${1:-}"

    if [[ ! -f "$AUTHORIZED_KEYS" ]] || [[ ! -s "$AUTHORIZED_KEYS" ]]; then
        warn "No SSH keys to remove"
        exit 0
    fi

    # Detect current session key fingerprint
    local session_fp
    session_fp=$(_get_session_fingerprint)

    # Build indexed list of keys (skip empty lines and comments)
    local -a keys=()
    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        keys+=("$line")
    done < "$AUTHORIZED_KEYS"

    if [[ ${#keys[@]} -eq 0 ]]; then
        warn "No SSH keys to remove"
        exit 0
    fi

    # If no argument, show list and ask
    if [[ -z "$target" ]]; then
        echo ""
        echo -e "  ${BOLD}Remove SSH Key${NC}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""

        local i=0
        for k in "${keys[@]}"; do
            (( i++ )) || true
            local comment
            comment=$(echo "$k" | awk '{$1=$2=""; print}' | xargs)
            [[ -z "$comment" ]] && comment="(no comment)"
            local fingerprint
            fingerprint=$(echo "$k" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}') || fingerprint="?"

            local active_marker=""
            if [[ -n "$session_fp" && "$fingerprint" == "$session_fp" ]]; then
                active_marker="  ${GREEN}<< current session${NC}"
            fi

            echo -e "  ${CYAN}${i}${NC}  ${comment}  ${DIM}${fingerprint}${NC}${active_marker}"
        done

        echo ""
        echo -en "  ${BOLD}Key number to remove (or 'q' to cancel):${NC} "
        read -r target
    fi

    [[ "$target" == "q" || -z "$target" ]] && { echo "  Cancelled"; exit 0; }

    # Validate number
    if ! [[ "$target" =~ ^[0-9]+$ ]] || [[ "$target" -lt 1 ]] || [[ "$target" -gt ${#keys[@]} ]]; then
        error "Invalid selection: ${target} (must be 1-${#keys[@]})"
        exit 1
    fi

    # Safety: prevent removing the last key
    if [[ ${#keys[@]} -eq 1 ]]; then
        error "Cannot remove the last SSH key — you would be locked out"
        echo -e "  ${DIM}Add another key first: cipi ssh add${NC}"
        exit 1
    fi

    local removed_key="${keys[$((target-1))]}"

    # Safety: prevent removing the key used for the current SSH session
    if [[ -n "$session_fp" ]]; then
        local removed_fp
        removed_fp=$(echo "$removed_key" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}') || removed_fp=""
        if [[ -n "$removed_fp" && "$removed_fp" == "$session_fp" ]]; then
            error "Cannot remove the key you are currently logged in with"
            echo -e "  ${DIM}Log in with a different key first, then remove this one${NC}"
            exit 1
        fi
    fi

    local removed_comment
    removed_comment=$(echo "$removed_key" | awk '{$1=$2=""; print}' | xargs)
    [[ -z "$removed_comment" ]] && removed_comment="(no comment)"

    # Remove the key
    local tmp
    tmp=$(mktemp)
    local idx=0
    while IFS= read -r line; do
        if [[ -z "$line" || "$line" == \#* ]]; then
            echo "$line" >> "$tmp"
            continue
        fi
        (( idx++ )) || true
        [[ $idx -ne $target ]] && echo "$line" >> "$tmp"
    done < "$AUTHORIZED_KEYS"

    mv "$tmp" "$AUTHORIZED_KEYS"
    chown cipi:cipi "$AUTHORIZED_KEYS"
    chmod 600 "$AUTHORIZED_KEYS"

    local removed_fp
    removed_fp=$(echo "$removed_key" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}') || removed_fp="?"

    success "Key removed: ${removed_comment}"
    log_action "SSH KEY REMOVE: ${removed_comment}"

    # Email notification
    local server_ip; server_ip=$(curl -s --max-time 3 https://checkip.amazonaws.com 2>/dev/null || hostname)
    cipi_notify \
        "Cipi SSH key removed on $(hostname)" \
        "An SSH key was removed from the cipi user.\n\nServer: $(hostname) (${server_ip})\nComment: ${removed_comment}\nFingerprint: ${removed_fp}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')\nRemaining keys: $((${#keys[@]} - 1))" \
        ssh_key_remove
}

# ── APP USERS: SSH / SFTP ACCESS FROM OUTSIDE ────────────────
#
#   cipi ssh apps [--json]               app users and their access
#   cipi ssh apps enable|disable <app>   one app user
#   cipi ssh apps enable|disable --all   every app user, and apps created later
#
# "Disabled" means no SSH or SFTP login from another machine. Logins from the
# server itself stay allowed, because Deployer reaches the app user over
# `ssh localhost`: deploys keep working. The cipi user is never touched.
#
# The state is membership of the group cipi-nossh. One static Match block in
# sshd_config denies that group from every non-local address; toggling a user
# is a group change, which sshd reads at login, so nothing is rewritten or
# reloaded per user.

[[ -z "${SSH_APPS_SSHD_CONFIG:-}" ]] && readonly SSH_APPS_SSHD_CONFIG="/etc/ssh/sshd_config"
[[ -z "${SSH_APPS_GROUP:-}" ]]       && readonly SSH_APPS_GROUP="cipi-nossh"

_ssh_apps_sshd() {
    if command -v sshd >/dev/null 2>&1; then sshd "$@"; else /usr/sbin/sshd "$@"; fi
}

_ssh_apps_block_present() {
    grep -q "^Match Group ${SSH_APPS_GROUP} " "$SSH_APPS_SSHD_CONFIG" 2>/dev/null
}

# App users: the apps Cipi knows that exist as system users.
_ssh_apps_users() {
    local a
    while IFS= read -r a; do
        [[ -n "$a" && "$a" != "cipi" && "$a" != "root" ]] || continue
        id "$a" &>/dev/null && echo "$a"
    done <<< "$(vault_read apps.json 2>/dev/null | jq -r 'keys[]' 2>/dev/null || true)"
    return 0
}

_ssh_apps_in_group() {
    id -nG "$1" 2>/dev/null | tr ' ' '\n' | grep -qx "$SSH_APPS_GROUP"
}

# What new apps get: follows the last enable|disable --all.
_ssh_apps_default() {
    local d
    d=$(vault_read server.json 2>/dev/null | jq -r '.app_ssh_default // "enabled"' 2>/dev/null || true)
    [[ "$d" == "disabled" ]] && echo "disabled" || echo "enabled"
}

# server.json holds the server's passwords: it is read whole, checked, and only
# then written back — never piped straight from a read that may have failed.
_ssh_apps_set_default() {
    local sj
    sj=$(vault_read server.json 2>/dev/null) || { warn "Could not read server.json — new apps keep the previous default"; return 0; }
    sj=$(jq --arg v "$1" '.app_ssh_default = $v' <<< "$sj" 2>/dev/null) || sj=""
    if [[ -z "$sj" ]] || ! jq -e 'type == "object" and length > 1' <<< "$sj" >/dev/null 2>&1; then
        warn "Could not update server.json — new apps keep the previous default"
        return 0
    fi
    printf '%s\n' "$sj" | vault_write server.json
}

# The group and the sshd rule, once. The new sshd_config is a copy that sshd
# validates before it replaces the live one; a rejected copy changes nothing.
_ssh_apps_ensure_block() {
    if ! getent group "$SSH_APPS_GROUP" >/dev/null 2>&1; then
        groupadd "$SSH_APPS_GROUP" 2>/dev/null || { error "Could not create the group ${SSH_APPS_GROUP}"; return 1; }
    fi
    _ssh_apps_block_present && return 0
    [[ -f "$SSH_APPS_SSHD_CONFIG" ]] || { error "${SSH_APPS_SSHD_CONFIG} not found"; return 1; }

    local new
    new=$(mktemp "${SSH_APPS_SSHD_CONFIG}.XXXXXX" 2>/dev/null) || new=""
    [[ -n "$new" ]] || { error "Could not create a working copy of ${SSH_APPS_SSHD_CONFIG}"; return 1; }
    if ! cp -p "$SSH_APPS_SSHD_CONFIG" "$new" 2>/dev/null; then
        rm -f "$new"
        error "Could not copy ${SSH_APPS_SSHD_CONFIG}"
        return 1
    fi
    cat >> "$new" <<EOF

# cipi ssh apps — no SSH/SFTP from outside for members of ${SSH_APPS_GROUP}.
# Logins from the server itself stay allowed: deploys run over ssh localhost.
Match Group ${SSH_APPS_GROUP} Address *,!127.0.0.1,!::1
    DenyUsers *
EOF
    if ! _ssh_apps_sshd -t -f "$new" >/dev/null 2>&1; then
        rm -f "$new"
        error "sshd rejected the new configuration — nothing changed (check: sshd -t)"
        return 1
    fi
    if ! mv -f "$new" "$SSH_APPS_SSHD_CONFIG" 2>/dev/null; then
        rm -f "$new"
        error "Could not replace ${SSH_APPS_SSHD_CONFIG} — nothing changed"
        return 1
    fi
    # reload, not restart: sessions that are open stay open
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null \
        || warn "Could not reload sshd — run: systemctl reload ssh"
    return 0
}

# Does sshd really refuse this user from outside and accept it from localhost?
_ssh_apps_enforced() {
    local user="$1"
    _ssh_apps_sshd -T -C "user=${user},host=cipi-check,addr=203.0.113.1" 2>/dev/null | grep -qi '^denyusers \*' || return 1
    ! _ssh_apps_sshd -T -C "user=${user},host=localhost,addr=127.0.0.1" 2>/dev/null | grep -qi '^denyusers'
}

# _ssh_apps_set <user> enabled|disabled
# 0: the state changed · 1: it was already there · 2: the group could not be changed
_ssh_apps_set() {
    local user="$1" want="$2"
    if [[ "$want" == "disabled" ]]; then
        _ssh_apps_in_group "$user" && return 1
        gpasswd -a "$user" "$SSH_APPS_GROUP" >/dev/null 2>&1 \
            || usermod -aG "$SSH_APPS_GROUP" "$user" >/dev/null 2>&1 || true
        _ssh_apps_in_group "$user" || return 2
    else
        _ssh_apps_in_group "$user" || return 1
        gpasswd -d "$user" "$SSH_APPS_GROUP" >/dev/null 2>&1 || true
        _ssh_apps_in_group "$user" && return 2
    fi
    return 0
}

_ssh_apps_list() {
    local json="$1" users u st block=true stale=""
    users=$(_ssh_apps_users)
    _ssh_apps_block_present || block=false

    if [[ "$json" == true ]]; then
        local items="[]"
        while IFS= read -r u; do
            [[ -n "$u" ]] || continue
            st="enabled"
            [[ "$block" == true ]] && _ssh_apps_in_group "$u" && st="disabled"
            items=$(jq -c --arg a "$u" --arg s "$st" '. + [{app: $a, ssh_access: $s}]' <<< "$items")
        done <<< "$users"
        jq -n --arg d "$(_ssh_apps_default)" --argjson apps "$items" '{new_apps: $d, apps: $apps}'
        return 0
    fi

    echo ""
    echo -e "  ${BOLD}App users — SSH / SFTP access from outside${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [[ -z "$users" ]]; then
        echo -e "  ${DIM}No apps yet${NC}"
    else
        printf "  ${BOLD}%-24s %s${NC}\n" "APP" "ACCESS"
        while IFS= read -r u; do
            [[ -n "$u" ]] || continue
            if _ssh_apps_in_group "$u"; then
                if [[ "$block" == true ]]; then
                    printf "  %-24s ${RED}○ disabled${NC}\n" "$u"
                else
                    printf "  %-24s ${GREEN}● enabled${NC}\n" "$u"
                    stale="${stale} ${u}"
                fi
            else
                printf "  %-24s ${GREEN}● enabled${NC}\n" "$u"
            fi
        done <<< "$users"
    fi
    echo ""
    echo -e "  New apps: ${CYAN}$(_ssh_apps_default)${NC}"
    if [[ -n "$stale" ]]; then
        echo -e "  ${YELLOW}Marked as disabled but the sshd rule is missing:${stale} — run: cipi ssh apps disable <app>${NC}"
    fi
    echo -e "  ${DIM}Disabled: no SSH or SFTP login from another machine. Deploys are not affected${NC}"
    echo -e "  ${DIM}(they run over ssh localhost). The cipi user is managed with: cipi ssh list${NC}"
    echo -e "  ${DIM}Change: cipi ssh apps enable|disable <app> | --all${NC}"
    echo ""
}

_ssh_apps() {
    local action="" target="" all=false json=false a
    for a in "$@"; do
        case "$a" in
            --all)  all=true ;;
            --json) json=true ;;
            -*)     error "Usage: cipi ssh apps [--json] | cipi ssh apps enable|disable <app>|--all"; exit 1 ;;
            *)      if [[ -z "$action" ]]; then action="$a"; else target="$a"; fi ;;
        esac
    done
    case "${action:-list}" in
        list)            _ssh_apps_list "$json" ;;
        enable|disable)  _ssh_apps_change "$action" "$target" "$all" ;;
        *)               error "Usage: cipi ssh apps [--json] | cipi ssh apps enable|disable <app>|--all"; exit 1 ;;
    esac
}

_ssh_apps_change() {
    local action="$1" target="$2" all="$3"
    local want="enabled"; [[ "$action" == "disable" ]] && want="disabled"

    if [[ "$all" == true && -n "$target" ]] || [[ "$all" == false && -z "$target" ]]; then
        error "Usage: cipi ssh apps ${action} <app>   or   cipi ssh apps ${action} --all"
        exit 1
    fi

    local users
    if [[ "$all" == true ]]; then
        users=$(_ssh_apps_users)
    else
        [[ "$target" == "cipi" || "$target" == "root" ]] && { error "'${target}' is not an app user — its keys are managed with: cipi ssh list"; exit 1; }
        app_exists "$target" || { error "App '${target}' not found"; exit 1; }
        id "$target" &>/dev/null || { error "App '${target}' has no system user"; exit 1; }
        users="$target"
    fi

    if [[ "$want" == "disabled" ]]; then
        _ssh_apps_ensure_block || exit 1
    fi

    local u changed="" failed="" n=0 rc
    while IFS= read -r u; do
        [[ -n "$u" ]] || continue
        rc=0
        _ssh_apps_set "$u" "$want" || rc=$?
        case "$rc" in
            0) changed="${changed} ${u}"; n=$((n + 1)) ;;
            2) failed="${failed} ${u}" ;;
        esac
    done <<< "$users"
    if [[ -n "$failed" ]]; then
        error "Could not change the group ${SSH_APPS_GROUP} for:${failed} — their access is unchanged"
        [[ "$all" == true ]] || exit 1
    fi

    if [[ "$all" == true ]]; then
        _ssh_apps_set_default "$want"
        success "SSH/SFTP access from outside ${want} for every app user (${n} changed); new apps: ${want}"
    elif [[ "$n" -eq 0 ]]; then
        info "SSH/SFTP access of '${target}' is already ${want}"
    else
        success "SSH/SFTP access from outside ${want} for '${target}'"
    fi

    if [[ "$want" == "disabled" ]]; then
        # Ask sshd itself, for one of the users, whether the rule bites.
        local probe="${users%%$'\n'*}"
        if [[ -n "$probe" ]] && ! _ssh_apps_enforced "$probe"; then
            warn "sshd does not apply the rule to '${probe}' — check the Match block at the end of ${SSH_APPS_SSHD_CONFIG} (sshd -T -C user=${probe},addr=203.0.113.1)"
        fi
        echo -e "  ${DIM}Deploys keep working (ssh localhost). Sessions already open stay open until they close.${NC}"
    fi

    if [[ "$n" -gt 0 || "$all" == true ]]; then
        local who="${changed# }"
        [[ "$all" == true ]] && who="all app users (${n} changed)"
        log_action "SSH APPS ${action}: ${who}"
        cipi_notify \
            "Cipi app SSH access ${want}: ${who} on $(hostname)" \
            "SSH/SFTP access from outside was ${want}.\n\nServer: $(hostname)\nApp users: ${who}\nNew apps: $(_ssh_apps_default)\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
            app_ssh_access
    fi
}

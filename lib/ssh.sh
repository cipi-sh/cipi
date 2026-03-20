#!/bin/bash
#############################################
# Cipi — SSH Key Management
#############################################

AUTHORIZED_KEYS="/home/cipi/.ssh/authorized_keys"

ssh_command() {
    local sub="${1:-}"; shift||true
    case "$sub" in
        list)        _ssh_list ;;
        add)         _ssh_add "$@" ;;
        remove)      _ssh_remove "$@" ;;
        rename)      _ssh_rename "$@" ;;
        enable-root)  _ssh_enable_root "$@" ;;
        disable-root) _ssh_disable_root "$@" ;;
        *)            error "Use: list add remove rename enable-root disable-root"; exit 1 ;;
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

# ── ENABLE ROOT SSH ─────────────────────────────────────────
# Cipi hardening sets PermitRootLogin no and AllowGroups without the root
# group, so root cannot SSH. This reverses that (key-only by default).

_ssh_enable_root() {
    local with_password=false
    for arg in "$@"; do
        case "$arg" in
            --password) with_password=true ;;
            *)
                error "Unknown option: $arg"
                echo "Use: cipi ssh enable-root [--password]"
                exit 1
                ;;
        esac
    done

    local SSHD="/etc/ssh/sshd_config"
    if [[ ! -f "$SSHD" ]]; then
        error "Missing ${SSHD}"
        exit 1
    fi

    local bak="${SSHD}.bak.cipi-enable-root.$(date +%s)"
    cp -a "$SSHD" "$bak"

    # Root's primary group is "root"; it must appear in AllowGroups when set.
    if grep -qE '^[[:space:]]*AllowGroups[[:space:]]' "$SSHD"; then
        if ! grep -qE '^[[:space:]]*AllowGroups[[:space:]].*[[:space:]]root([[:space:]]|$)' "$SSHD"; then
            sed -i 's/^\([[:space:]]*AllowGroups[[:space:]]\+\)/\1root /' "$SSHD"
        fi
    fi

    if grep -q 'BEGIN cipi-ssh-root-access' "$SSHD"; then
        sed -i '/# BEGIN cipi-ssh-root-access/,/# END cipi-ssh-root-access/d' "$SSHD"
    fi

    if [[ "$with_password" == true ]]; then
        cat >> "$SSHD" <<'EOF'

# BEGIN cipi-ssh-root-access (cipi ssh enable-root)
Match User root
    PermitRootLogin yes
    PasswordAuthentication yes
# END cipi-ssh-root-access
EOF
    else
        cat >> "$SSHD" <<'EOF'

# BEGIN cipi-ssh-root-access (cipi ssh enable-root)
Match User root
    PermitRootLogin prohibit-password
# END cipi-ssh-root-access
EOF
    fi

    if ! sshd -t 2>/dev/null; then
        cp -a "$bak" "$SSHD"
        error "sshd -t failed — config restored from backup"
        echo "  ${DIM}Backup kept at: ${bak}${NC}" >&2
        exit 1
    fi

    systemctl restart ssh 2>/dev/null || systemctl restart sshd

    local mode_msg="public key only (prohibit-password)"
    [[ "$with_password" == true ]] && mode_msg="password and public key"

    success "SSH login as root enabled (${mode_msg})"
    echo -e "  ${DIM}Ensure /root/.ssh/authorized_keys has your key, or use: cipi reset root-password${NC}"
    echo -e "  ${YELLOW}When finished:${NC} ${DIM}cipi ssh disable-root${NC}"

    log_action "SSH ENABLE-ROOT: mode=${with_password}"

    local server_ip; server_ip=$(curl -s --max-time 3 https://checkip.amazonaws.com 2>/dev/null || hostname)
    cipi_notify \
        "Cipi: root SSH enabled on $(hostname)" \
        "Root SSH login was enabled via cipi ssh enable-root.\n\nServer: $(hostname) (${server_ip})\nMode: ${mode_msg}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')\n\nRun cipi ssh disable-root when no longer needed."
}

# ── DISABLE ROOT SSH ────────────────────────────────────────
# Undoes cipi ssh enable-root: removes the marked Match block and drops the
# root group from AllowGroups when present.

_ssh_disable_root() {
    if [[ $# -gt 0 ]]; then
        error "Unknown option: $*"
        echo "Use: cipi ssh disable-root"
        exit 1
    fi

    local SSHD="/etc/ssh/sshd_config"
    if [[ ! -f "$SSHD" ]]; then
        error "Missing ${SSHD}"
        exit 1
    fi

    local bak="${SSHD}.bak.cipi-disable-root.$(date +%s)"
    cp -a "$SSHD" "$bak"

    local changed=false

    if grep -q 'BEGIN cipi-ssh-root-access' "$SSHD"; then
        sed -i '/# BEGIN cipi-ssh-root-access/,/# END cipi-ssh-root-access/d' "$SSHD"
        changed=true
    fi

    if grep -qE '^[[:space:]]*AllowGroups[[:space:]].*[[:space:]]root([[:space:]]|$)' "$SSHD"; then
        local tmp
        tmp=$(mktemp)
        awk '
        /^[[:space:]]*AllowGroups[[:space:]]/ {
            rest = $0
            sub(/^[[:space:]]*AllowGroups[[:space:]]+/, "", rest)
            n = split(rest, a, /[[:space:]]+/)
            out = ""
            for (i = 1; i <= n; i++) {
                if (a[i] != "" && a[i] != "root") {
                    out = (out == "" ? a[i] : out " " a[i])
                }
            }
            print "AllowGroups " out
            next
        }
        { print }
        ' "$SSHD" > "$tmp" && mv "$tmp" "$SSHD"
        changed=true
    fi

    if [[ "$changed" != true ]]; then
        rm -f "$bak"
        info "Nothing to do — no cipi root-access block and AllowGroups has no root"
        exit 0
    fi

    if ! sshd -t 2>/dev/null; then
        cp -a "$bak" "$SSHD"
        error "sshd -t failed — config restored from backup"
        echo "  ${DIM}Backup kept at: ${bak}${NC}" >&2
        exit 1
    fi

    systemctl restart ssh 2>/dev/null || systemctl restart sshd

    success "SSH login as root disabled (Cipi-style)"
    log_action "SSH DISABLE-ROOT"

    local server_ip; server_ip=$(curl -s --max-time 3 https://checkip.amazonaws.com 2>/dev/null || hostname)
    cipi_notify \
        "Cipi: root SSH disabled on $(hostname)" \
        "Root SSH was restricted via cipi ssh disable-root.\n\nServer: $(hostname) (${server_ip})\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')"
}

# ── LIST ─────────────────────────────────────────────────────

_ssh_list() {
    if [[ ! -f "$AUTHORIZED_KEYS" ]] || [[ ! -s "$AUTHORIZED_KEYS" ]]; then
        warn "No SSH keys configured for cipi user"
        exit 0
    fi

    local session_fp
    session_fp=$(_get_session_fingerprint)

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
        "An SSH key was added to the cipi user.\n\nServer: $(hostname) (${server_ip})\nComment: ${comment}\nFingerprint: ${fingerprint}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')"
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
        "An SSH key was renamed on the cipi user.\n\nServer: $(hostname) (${server_ip})\nOld name: ${old_comment}\nNew name: ${new_name}\nFingerprint: ${fingerprint}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')"
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
        "An SSH key was removed from the cipi user.\n\nServer: $(hostname) (${server_ip})\nComment: ${removed_comment}\nFingerprint: ${removed_fp}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')\nRemaining keys: $((${#keys[@]} - 1))"
}

#!/bin/bash
#############################################
# Cipi — Vault (AES-256-CBC config encryption at rest)
#############################################

[[ -z "${VAULT_KEY:-}" ]]    && readonly VAULT_KEY="${CIPI_CONFIG}/.vault_key"
[[ -z "${VAULT_CIPHER:-}" ]] && readonly VAULT_CIPHER="aes-256-cbc"

# True when a directory accepts writes (false on remount-ro even if mode bits look writable).
_cipi_path_writable() {
    local dir="$1" probe
    [[ -n "$dir" ]] || return 1
    [[ -d "$dir" ]] || mkdir -p "$dir" 2>/dev/null || return 1
    probe="${dir}/.cipi-writable-$$"
    touch "$probe" 2>/dev/null || return 1
    rm -f "$probe" 2>/dev/null || true
    return 0
}

# True when /etc/cipi accepts writes.
_cipi_config_writable() {
    _cipi_path_writable "${CIPI_CONFIG}"
}

# Remount the filesystem backing $path as read-write.
# Uses mount -n so util-linux does not need to rewrite /etc/mtab while still RO.
# Prefers findmnt SOURCE+TARGET — bare `remount /` can fail on broken fstab UUIDs.
# Sets _CIPI_REMOUNT_ERR on failure (best-effort message for callers).
_cipi_remount_rw() {
    local path="${1:-/}" target="/" source="" err
    _CIPI_REMOUNT_ERR=""
    err="/tmp/cipi-remount-err.$$"

    if command -v findmnt >/dev/null 2>&1; then
        target=$(findmnt -n -o TARGET --target "$path" 2>/dev/null || echo "/")
        source=$(findmnt -n -o SOURCE --target "$path" 2>/dev/null || true)
    fi
    [[ -z "$target" ]] && target="/"

    if mount -n -o remount,rw "$target" >"$err" 2>&1; then
        rm -f "$err" 2>/dev/null || true
        return 0
    fi
    if [[ -n "$source" ]] && mount -n -o remount,rw "$source" "$target" >"$err" 2>&1; then
        rm -f "$err" 2>/dev/null || true
        return 0
    fi
    if mount -n -o remount,rw / >"$err" 2>&1; then
        rm -f "$err" 2>/dev/null || true
        return 0
    fi
    if mount -o remount,rw / >"$err" 2>&1; then
        rm -f "$err" 2>/dev/null || true
        return 0
    fi

    _CIPI_REMOUNT_ERR=$(tr '\n' ' ' <"$err" 2>/dev/null | sed 's/[[:space:]]*$//')
    rm -f "$err" 2>/dev/null || true
    [[ -z "${_CIPI_REMOUNT_ERR:-}" ]] && _CIPI_REMOUNT_ERR="mount -n -o remount,rw ${target} failed"
    return 1
}

# For *mutating* ops only: if /etc/cipi is not writable, try remounting rw.
# Read paths must keep using _cipi_config_writable alone — never call this
# from vault_init / source init.
_cipi_ensure_config_writable() {
    mkdir -p "${CIPI_CONFIG}" 2>/dev/null || true
    _cipi_config_writable && return 0
    _cipi_remount_rw "${CIPI_CONFIG}" || _cipi_remount_rw / || true
    mkdir -p "${CIPI_CONFIG}" 2>/dev/null || true
    _cipi_config_writable
}

# Best-effort chmod: no-op when /etc/cipi is read-only (never abort the caller).
_cipi_safe_chmod() {
    _cipi_config_writable || return 0
    chmod "$@" 2>/dev/null || true
}

vault_init() {
    [[ -f "$VAULT_KEY" ]] && return 0
    _cipi_config_writable || return 0
    openssl rand -base64 32 > "$VAULT_KEY" 2>/dev/null || return 0
    chmod 400 "$VAULT_KEY" 2>/dev/null || true
}

# Decrypt a config file and write JSON to stdout.
# Transparently handles both plaintext (legacy) and encrypted files.
vault_read() {
    local file="${CIPI_CONFIG}/$1"
    [[ ! -f "$file" ]] && { echo "{}"; return 0; }

    if jq empty "$file" 2>/dev/null; then
        cat "$file"
    else
        openssl enc -d -"${VAULT_CIPHER}" -pbkdf2 -pass "file:${VAULT_KEY}" -in "$file" 2>/dev/null \
            || { echo "vault: failed to decrypt $1" >&2; return 1; }
    fi
}

# Read JSON from stdin, encrypt, and write to a config file.
# Optional second arg overrides chmod (default 600).
vault_write() {
    local file="${CIPI_CONFIG}/$1"
    local perms="${2:-600}"
    if ! _cipi_ensure_config_writable; then
        echo "vault: cannot write $1 (read-only ${CIPI_CONFIG})" >&2
        return 1
    fi
    # Written next to the file and renamed over it: atomic, and never across
    # filesystems. A temp under /tmp (tmpfs on recent Ubuntu and Debian, or a
    # service's private /tmp) made mv remove the live file and copy — no
    # apps.json at all until the copy ended. A failed encryption leaves nothing.
    local tmp
    tmp=$(mktemp "$(dirname "$file")/.$(basename "$file").XXXXXX") \
        || { echo "vault: cannot create a temporary file in ${CIPI_CONFIG}" >&2; return 1; }
    if ! openssl enc -"${VAULT_CIPHER}" -salt -pbkdf2 -pass "file:${VAULT_KEY}" -out "$tmp"; then
        rm -f "$tmp"
        echo "vault: encryption of $1 failed" >&2
        return 1
    fi
    mv -f "$tmp" "$file" || { rm -f "$tmp"; return 1; }
    _cipi_safe_chmod "$perms" "$file"
}

# Encrypt an existing plaintext config file in-place.
# No-op if the file is already encrypted or missing.
vault_seal() {
    local file="${CIPI_CONFIG}/$1"
    [[ ! -f "$file" ]] && return 0
    jq empty "$file" 2>/dev/null || return 0

    local tmp
    tmp=$(mktemp "$(dirname "$file")/.$(basename "$file").XXXXXX") \
        || { echo "vault: cannot create a temporary file in ${CIPI_CONFIG}" >&2; return 1; }
    if ! openssl enc -"${VAULT_CIPHER}" -salt -pbkdf2 -pass "file:${VAULT_KEY}" -in "$file" -out "$tmp"; then
        rm -f "$tmp"
        echo "vault: sealing $1 failed" >&2
        return 1
    fi
    mv -f "$tmp" "$file" || { rm -f "$tmp"; return 1; }
    _cipi_safe_chmod 600 "$file"
}

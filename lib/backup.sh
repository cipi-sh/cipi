#!/bin/bash
#############################################
# Cipi — Backup (profiles, S3 / S3-compatible / SFTP / local)
#
# A backup run is driven by a *profile*: what to take (files, databases, or
# both), which apps and databases it covers, how often it runs, where it goes
# and how long it is kept. Several profiles coexist — e.g. a full nightly copy
# to S3 next to a 30-minute database-only copy kept locally — which is what a
# multi-tenant SaaS needs and what a single hardcoded nightly job could not do.
#
# Layout inside a run (local dir or S3 prefix):
#
#   <root>/<profile>/<timestamp>/manifest.json
#   <root>/<profile>/<timestamp>/apps/<app>/files.tar.gz
#   <root>/<profile>/<timestamp>/apps/<app>/meta.json
#   <root>/<profile>/<timestamp>/databases/<engine>/<db>.sql.gz
#
# Application files and databases are separated, so a database-only profile
# costs nothing in disk or transfer, and a database can be restored without
# unpacking the app.
#############################################

# The time of a notification is common.sh's (and follows `cipi notification
# timezone`); loaded on its own, this file still has a clock.
declare -f notify_now >/dev/null 2>&1 || notify_now() { date "$@" '+%Y-%m-%d %H:%M:%S %Z'; }

[[ -z "${BACKUP_KEY_FILE:-}" ]] && readonly BACKUP_KEY_FILE="${CIPI_CONFIG}/.backup_key"

# The AWS CLI installs into /usr/local/bin, which root's crontab PATH
# (/usr/bin:/bin) does not include — and every scheduled run comes from cron.
case ":${PATH}:" in *:/usr/local/bin:*) ;; *) export PATH="/usr/local/bin:${PATH}" ;; esac
[[ -z "${BACKUP_DEFAULT_LOCAL:-}" ]] && readonly BACKUP_DEFAULT_LOCAL="/var/backups/cipi"

backup_command() {
    local sub="${1:-}"; shift||true
    case "$sub" in
        configure) _bk_configure "$@" ;;
        status)    _bk_status "$@" ;;
        profile|profiles) _bk_profile_command "$@" ;;
        destination|destinations|dest) _bk_destination_command "$@" ;;
        sftp)      _bk_sftp_command "$@" ;;
        run)       _bk_run "$@" ;;
        list)      _bk_list "$@" ;;
        prune)     _bk_prune "$@" ;;
        verify)    _bk_verify "$@" ;;
        check)     _bk_check_stale "$@" ;;
        fetch)     _bk_fetch "$@" ;;
        key)       _bk_key_command "$@" ;;
        *) error "Use: configure status destination sftp profile run list prune verify fetch key"; exit 1 ;;
    esac
}

# ── Config helpers ───────────────────────────────────────────

_bk_cfg()       { vault_read backup.json 2>/dev/null || echo '{}'; }
_bk_cfg_write() { vault_write backup.json; }
_bk_configured() { [[ -f "${CIPI_CONFIG}/backup.json" ]]; }

# Local-only backup.json, for `cipi yml apply` when the file declares profiles
# and backup was never configured. No prompt and no `default` profile: the
# file is about to create its own, and a server-wide profile would copy every
# app. Same shape as `cipi backup configure` with an empty bucket.
_bk_init_local() {
    _bk_configured && return 0
    local cl="${BACKUP_DEFAULT_LOCAL}"
    mkdir -p "$cl" || return 1
    chmod 700 "$cl" 2>/dev/null || true
    jq -n --arg l "$cl" \
        '{aws_key:"",aws_secret:"",bucket:"",region:"eu-central-1",endpoint_url:"",tmpdir:"/var/tmp",local_dir:$l,s3_destinations:{},profiles:{}}' \
        | _bk_cfg_write
}

_bk_require_config() {
    _bk_configured || { error "Backup not configured. Run: cipi backup configure"; exit 1; }
}

_bk_local_root() {
    local d; d=$(_bk_cfg | jq -r '.local_dir // ""')
    echo "${d:-$BACKUP_DEFAULT_LOCAL}"
}

# ── S3 destinations ──────────────────────────────────────────
#
# Backups start on this server ("local"). S3 buckets and SFTP servers are
# destinations on a par, each with a name and its own credentials, added with
# `cipi backup destination add <name>`; a profile lists any of them next to
# local. The bucket named "s3" lives in the top-level keys of backup.json
# (bucket, region, endpoint_url, aws_key, aws_secret) — where `cipi backup
# configure` kept its bucket before 5.19.1 — so a server configured then
# carries on unchanged; every other S3 bucket is under `s3_destinations`.

_bk_s3_bucket() { _bk_s3_json "${1:-s3}" | jq -r '.bucket // .host // ""'; }
_bk_has_s3()    { [[ -n "$(_bk_s3_bucket "${1:-s3}")" ]]; }

# Every destination a copy can land on besides local: "s3" first when it is
# set, then the other S3 buckets, then the SFTP servers.
_bk_s3_names() {
    local cfg; cfg=$(_bk_cfg)
    [[ -n "$(echo "$cfg" | jq -r '.bucket // ""')" ]] && echo s3
    echo "$cfg" | jq -r '(.s3_destinations // {}) | keys[]' 2>/dev/null || true
    # SFTP destinations go where the S3 ones go: every copy, prune and listing.
    echo "$cfg" | jq -r '(.sftp_destinations // {}) | keys[]' 2>/dev/null || true
}

# {bucket, region, endpoint_url, aws_key, aws_secret} of one destination;
# nothing when it does not exist.
_bk_s3_json() {
    local name="${1:-s3}"
    if [[ "$name" == "s3" ]]; then
        _bk_cfg | jq '{bucket: (.bucket // ""), region: (.region // "eu-central-1"), endpoint_url: (.endpoint_url // ""), aws_key: (.aws_key // ""), aws_secret: (.aws_secret // "")}'
    else
        _bk_cfg | jq --arg n "$name" '(.s3_destinations // {})[$n] // ((.sftp_destinations // {})[$n] | if . then . + {type: "sftp"} else empty end)'
    fi
}

_bk_s3_exists() {
    local name="${1:-}"
    [[ -z "$name" ]] && return 1
    [[ "$name" == "s3" ]] && { _bk_has_s3; return; }
    [[ -n "$(_bk_s3_json "$name")" ]]
}

# Same charset as profile names; local is this server. "s3" is an S3 bucket's
# name only (see above).
_bk_valid_dest_name() {
    [[ "$1" =~ ^[a-z][a-z0-9-]{1,31}$ && "$1" != "local" ]]
}

# The parts of an S3 destination. A key and a secret are printable characters
# with no space and no line break: before 5.19.1 the bucket "s3"'s were written to
# /root/.aws/credentials, where a line break would add a setting of its own.
_bk_valid_bucket()   { [[ "$1" =~ ^[a-z0-9][a-z0-9._-]{1,62}$ ]]; }
_bk_valid_region()   { [[ "$1" =~ ^[A-Za-z0-9-]{1,64}$ ]]; }
_bk_valid_endpoint() { [[ -z "$1" || "$1" =~ ^https?://[A-Za-z0-9.:/_-]{1,255}$ ]]; }
_bk_valid_s3_cred()  { [[ "$1" =~ ^[[:graph:]]{1,256}$ && "$1" != *[\"\'\\]* ]]; }

# The secret key of an S3 destination: --secret-stdin reads it from the first
# line of standard input — the panel's way: never on a command line (ps, the
# shell's history, a log). From the panel it is the only way.
# Prints it; nothing when none was given. Fails with the reason.
_bk_secret_given() {
    local sec=""
    if [[ "${ARG_secret_stdin:-}" == "true" ]]; then
        IFS= read -r sec || [[ -n "$sec" ]] || { echo "--secret-stdin: nothing on standard input" >&2; return 1; }
        sec="${sec%$'\r'}"
        [[ -n "$sec" ]] || { echo "--secret-stdin: an empty secret" >&2; return 1; }
    elif [[ -n "${ARG_secret+x}" ]]; then
        if [[ "${SUDO_USER:-}" == "www-data" ]]; then
            echo "From the panel a secret key comes on standard input (--secret-stdin), never on the command line" >&2
            return 1
        fi
        sec="${ARG_secret}"
    fi
    if [[ -n "$sec" ]] && ! _bk_valid_s3_cred "$sec"; then
        echo "Invalid secret key: printable characters, no space, no quote" >&2
        return 1
    fi
    printf '%s' "$sec"
}

# Profiles that write to a destination, one per line.
_bk_dest_profiles() {
    _bk_profiles_json | jq -r --arg d "$1" 'to_entries[] | select((.value.destinations // []) | index($d) != null) | .key' 2>/dev/null || true
}

# s3://<bucket>/cipi/[<profile>/[<timestamp>/]] on one destination; status 1
# when the destination has no bucket.
_bk_s3_uri() {
    local name="$1" p="${2:-}" ts="${3:-}"
    local b; b=$(_bk_s3_bucket "$name")
    [[ -n "$b" ]] || return 1
    local uri="s3://${b}/cipi/"
    _bk_is_sftp "$name" && uri="sftp://${name}/cipi/"
    [[ -n "$p" ]]  && uri="${uri}${p}/"
    [[ -n "$ts" ]] && uri="${uri}${ts}/"
    printf '%s' "$uri"
}

# The first S3 destination that holds a run (a non-empty listing): fetch and
# verify use it when there is no local copy.
_bk_s3_find_run() {
    local p="$1" ts="$2" dn
    while IFS= read -r dn; do
        [[ -n "$dn" ]] || continue
        _bk_is_sftp "$dn" || command -v aws &>/dev/null || continue
        [[ -n "$(_bk_aws "$dn" ls "$(_bk_s3_uri "$dn" "$p" "$ts")" 2>/dev/null)" ]] && { echo "$dn"; return 0; }
    done < <(_bk_s3_names)
    return 1
}

_ensure_awscli() {
    if ! command -v aws &>/dev/null; then
        step "Installing AWS CLI v2..."
        local tmp; tmp=$(mktemp -d)
        curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "${tmp}/awscliv2.zip"
        unzip -q "${tmp}/awscliv2.zip" -d "${tmp}"
        "${tmp}/aws/install" --update -i /usr/local/aws-cli -b /usr/local/bin &>/dev/null
        rm -rf "${tmp}"
        command -v aws &>/dev/null || { error "AWS CLI install failed"; exit 1; }
        success "AWS CLI $(aws --version 2>&1 | awk '{print $1}')"
    fi
}

# The AWS CLI when an S3 destination is configured; nothing for SFTP alone.
_bk_ensure_remote_tools() {
    local dn
    while IFS= read -r dn; do
        [[ -n "$dn" ]] || continue
        _bk_is_sftp "$dn" || { _ensure_awscli; return 0; }
    done < <(_bk_s3_names)
}

# Disk-backed temp dir for archives (default /var/tmp). /tmp is often tmpfs and too small for large apps.
# Override: CIPI_BACKUP_TMPDIR env, or backup.json "tmpdir".
_bk_tmp_base() {
    local dir=""
    if [[ -n "${CIPI_BACKUP_TMPDIR:-}" ]]; then
        dir="$CIPI_BACKUP_TMPDIR"
    elif [[ -f "${CIPI_CONFIG}/backup.json" ]]; then
        dir=$(_bk_cfg | jq -r '.tmpdir // ""')
    fi
    dir="${dir:-/var/tmp}"
    if [[ ! -d "$dir" ]] || [[ ! -w "$dir" ]]; then
        error "Backup temp directory not writable: ${dir}"
        exit 1
    fi
    echo "$dir"
}

# Wrapper: adds --endpoint-url and --region when a custom endpoint is configured.
# S3-compatible APIs can fail with "NoneType is not iterable" if region is empty.
_aws_s3() {
    # The bucket "s3", with its own keys like any other (the default credential
    # chain — an instance role, /root/.aws — when it has none).
    if [[ -f "${CIPI_CONFIG}/backup.json" ]]; then
        _bk_aws_json "$(_bk_s3_json s3)" "$@"
    else
        aws s3 "$@"
    fi
}

# aws s3 <args> with the credentials of one destination JSON (see _bk_s3_json):
# keys in the environment of this one call, region and endpoint always given.
# Without keys the default credential chain applies (instance role).
_bk_aws_json() {
    local d="$1"; shift
    local k s ep region
    k=$(echo "$d" | jq -r '.aws_key // ""'); s=$(echo "$d" | jq -r '.aws_secret // ""')
    ep=$(echo "$d" | jq -r '.endpoint_url // ""'); region=$(echo "$d" | jq -r '.region // ""')
    local -a opts=(--region "${region:-eu-central-1}")
    [[ -n "$ep" ]] && opts+=(--endpoint-url "$ep")
    if [[ -n "$k" ]]; then
        env -u AWS_PROFILE -u AWS_SESSION_TOKEN AWS_ACCESS_KEY_ID="$k" AWS_SECRET_ACCESS_KEY="$s" aws s3 "${opts[@]}" "$@"
    else
        aws s3 "${opts[@]}" "$@"
    fi
}

# aws s3 <args> against a destination by name.
_bk_aws() {
    local name="$1"; shift
    _bk_is_sftp "$name" && { _bk_sftp_s3 "$name" "$@"; return; }
    local d; d=$(_bk_s3_json "$name")
    [[ -n "$d" ]] || { echo "unknown backup destination: ${name}" >&2; return 1; }
    _bk_aws_json "$d" "$@"
}

# ── SFTP destinations ────────────────────────────────────────
#
# A server you can reach over SSH and nothing else: a VPS with a user of its
# own for backups, a Hetzner Storage Box (port 23), a NAS. Named like the S3
# ones and kept under `sftp_destinations` in backup.json:
#
#   {host, port, user, path, created_at}
#
# Cipi signs in with a key of its own for each destination — made by
# `cipi backup destination add <name> --type=sftp`, kept in
# /etc/cipi/backup-keys/<name> (root only), the public half to install on the
# remote. No password is ever stored. The remote host key is pinned on first
# use in /etc/cipi/backup-keys/known_hosts.
#
# Only SFTP is asked of the remote — no shell, no rsync — so a chrooted
# `internal-sftp` account works. A run lands in <path>/cipi/<profile>/<ts>/,
# the same layout as a bucket. The operations the rest of this file asks of
# a destination (`aws s3 cp|ls|rm` by URI) are translated by _bk_sftp_s3.

[[ -z "${BACKUP_SFTP_KEY_DIR:-}" ]] && BACKUP_SFTP_KEY_DIR="${CIPI_CONFIG}/backup-keys"

_bk_is_sftp() { [[ -n "${1:-}" && "$1" != "s3" && "$1" != "local" ]] && _bk_cfg 2>/dev/null | jq -e --arg n "$1" '(.sftp_destinations // {}) | has($n)' &>/dev/null; }
_bk_sftp_key() { echo "${BACKUP_SFTP_KEY_DIR}/${1}"; }

_bk_sftp_valid_host() { [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.:-]{0,252}[A-Za-z0-9])?$ ]]; }
_bk_sftp_valid_user() { [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]{0,63}$ ]]; }
# A folder on the remote, relative to the login's home or absolute: no ..,
# nothing a batch file could read as two words.
_bk_sftp_valid_path() { [[ "$1" =~ ^/?[A-Za-z0-9._/-]{0,255}$ && "$1" != *..* ]]; }

# The remote path of a URI sftp://<name>/<rest> on that destination.
_bk_sftp_path() {   # <name> <uri>
    local name="$1" uri="$2" base rest
    base=$(_bk_s3_json "$name" | jq -r '.path // ""')
    rest="${uri#sftp://${name}}"; rest="${rest#/}"; rest="${rest%/}"
    base="${base%/}"
    if [[ -z "$base" || "$base" == "." ]]; then
        printf '%s' "${rest:-.}"
    else
        printf '%s' "${base}${rest:+/${rest}}"
    fi
}

# sftp -b <batch> with the destination's key, its pinned host key, no prompt.
_bk_sftp_batch() {   # <name> <batch file>
    local name="$1" batch="$2" dj host port user key
    dj=$(_bk_s3_json "$name")
    host=$(jq -r '.host' <<< "$dj"); port=$(jq -r '.port // 22' <<< "$dj"); user=$(jq -r '.user' <<< "$dj")
    key=$(_bk_sftp_key "$name")
    [[ -f "$key" ]] || { echo "no key for ${name}: ${key} is missing (cipi backup destination edit ${name} --type=sftp --new-key)" >&2; return 1; }
    command -v sftp &>/dev/null || { echo "sftp not found (apt-get install openssh-client)" >&2; return 1; }
    mkdir -p "$BACKUP_SFTP_KEY_DIR" && chmod 700 "$BACKUP_SFTP_KEY_DIR"
    sftp -q -b "$batch" -P "$port" -i "$key" \
        -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=20 -o ServerAliveInterval=15 \
        -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=${BACKUP_SFTP_KEY_DIR}/known_hosts" \
        -- "${user}@${host}"
}

# The entries of one remote folder: "d <name>" or "f <size> <name>", one per
# line. Status 2 when the folder does not exist.
_bk_sftp_entries() {   # <name> <remote dir>
    local name="$1" dir="$2" batch out rc=0
    batch=$(mktemp)
    # -n: the client writes the long listing itself from the attributes
    # (numeric owner), whatever text the server would give (a Storage Box,
    # a NAS) — one format to read.
    printf 'ls -ln "%s"\n' "$dir" > "$batch"
    out=$(_bk_sftp_batch "$name" "$batch" 2>&1) || rc=$?
    rm -f "$batch"
    if (( rc != 0 )); then
        grep -qiE 'not found|no such file|can.t ls' <<< "$out" && return 2
        grep -vE '^sftp>' <<< "$out" | grep -v '^[[:space:]]*$' | tail -1 >&2
        return 1
    fi
    # ls -ln prints the full path when given one: the last field, basename.
    awk '$1 ~ /^[dl-][rwxsStT-]{9}/ {
            n = $NF; sub(/.*\//, "", n); if (n == "." || n == "..") next
            if (substr($1, 1, 1) == "d") print "d " n; else print "f " $5 " " n
         }' <<< "$out"
}

# Every file under a remote folder: "<size> <path relative to it>".
_bk_sftp_walk() {   # <name> <remote dir> [<prefix>]
    local name="$1" dir="$2" pre="${3:-}" kind a b rc=0 list
    list=$(_bk_sftp_entries "$name" "$dir") || return $?
    while read -r kind a b; do
        [[ -n "$kind" ]] || continue
        if [[ "$kind" == d ]]; then
            _bk_sftp_walk "$name" "${dir}/${a}" "${pre}${a}/" || rc=$?
        else
            echo "${a} ${pre}${b}"
        fi
    done <<< "$list"
    return $rc
}

# The folders under a remote folder, deepest first.
_bk_sftp_dirs() {   # <name> <remote dir>
    local name="$1" dir="$2" kind a b list
    list=$(_bk_sftp_entries "$name" "$dir") || return 0
    while read -r kind a b; do
        [[ "$kind" == d ]] || continue
        _bk_sftp_dirs "$name" "${dir}/${a}"
        echo "${dir}/${a}"
    done <<< "$list"
}

# What `aws s3 <op>` would do, on an SFTP destination:
#   cp <local dir>/ sftp://… --recursive    upload a run
#   cp sftp://… <local dir>/ --recursive    download one
#   ls sftp://… [--recursive]               PRE <dir>/ lines, or "<date> <time> <size> <key>"
#   rm sftp://… --recursive                 delete a run
_bk_sftp_s3() {   # <name> <op> <args…>
    local name="$1" op="${2:-}"; shift 2 || true
    local a src="" dst="" recursive=false
    for a in "$@"; do
        case "$a" in
            --recursive) recursive=true ;;
            --*) ;;
            *) if [[ -z "$src" ]]; then src="$a"; else dst="$a"; fi ;;
        esac
    done
    local batch rc=0 remote size rel
    case "$op" in
        ls)
            remote=$(_bk_sftp_path "$name" "$src")
            if [[ "$recursive" == true ]]; then
                local files; files=$(_bk_sftp_walk "$name" "$remote") || rc=$?
                (( rc == 2 )) && return 1
                local key="${src#sftp://${name}/}"; key="${key%/}"
                while read -r size rel; do
                    [[ -n "$rel" ]] && echo "1970-01-01 00:00:00 ${size} ${key}/${rel}"
                done <<< "$files"
                return $(( rc == 0 ? 0 : 1 ))
            fi
            local entries kind x y
            entries=$(_bk_sftp_entries "$name" "$remote") || { rc=$?; (( rc == 2 )) && return 1; return $rc; }
            while read -r kind x y; do
                [[ "$kind" == d ]] && echo "                           PRE ${x}/"
                [[ "$kind" == f ]] && echo "1970-01-01 00:00:00 ${x} ${y}"
            done <<< "$entries"
            return 0
            ;;
        cp)
            if [[ "$src" == sftp://* ]]; then
                remote=$(_bk_sftp_path "$name" "$src"); dst="${dst%/}"
                local files; files=$(_bk_sftp_walk "$name" "$remote") || return 1
                [[ -n "$files" ]] || return 0
                batch=$(mktemp)
                while read -r size rel; do
                    [[ -n "$rel" ]] || continue
                    mkdir -p "${dst}/$(dirname "$rel")"
                    printf 'get "%s/%s" "%s/%s"\n' "$remote" "$rel" "$dst" "$rel" >> "$batch"
                done <<< "$files"
                _bk_sftp_batch "$name" "$batch" >/dev/null || rc=$?
                rm -f "$batch"
                return $rc
            fi
            remote=$(_bk_sftp_path "$name" "$dst"); src="${src%/}"
            batch=$(mktemp)
            # Every folder of the way, then the run's own folders, then its files.
            _bk_sftp_mkdirs "$remote" >> "$batch"
            while IFS= read -r rel; do
                printf -- '-mkdir "%s/%s"\n' "$remote" "$rel" >> "$batch"
            done < <(cd "$src" && find . -mindepth 1 -type d | sed 's#^\./##' | sort)
            while IFS= read -r rel; do
                printf 'put "%s/%s" "%s/%s"\n' "$src" "$rel" "$remote" "$rel" >> "$batch"
            done < <(cd "$src" && find . -type f | sed 's#^\./##' | sort)
            _bk_sftp_batch "$name" "$batch" >/dev/null || rc=$?
            rm -f "$batch"
            return $rc
            ;;
        rm)
            remote=$(_bk_sftp_path "$name" "$src")
            local files; files=$(_bk_sftp_walk "$name" "$remote") || { rc=$?; (( rc == 2 )) && return 0; return 1; }
            batch=$(mktemp)
            while read -r size rel; do
                [[ -n "$rel" ]] && printf 'rm "%s/%s"\n' "$remote" "$rel" >> "$batch"
            done <<< "$files"
            while IFS= read -r d; do
                [[ -n "$d" ]] && printf 'rmdir "%s"\n' "$d" >> "$batch"
            done < <(_bk_sftp_dirs "$name" "$remote")
            printf 'rmdir "%s"\n' "$remote" >> "$batch"
            _bk_sftp_batch "$name" "$batch" >/dev/null || rc=$?
            rm -f "$batch"
            return $rc
            ;;
    esac
    echo "sftp destination ${name}: unsupported operation ${op}" >&2
    return 1
}

# "-mkdir" lines for every folder of a remote path, the first one first: a
# folder that is there already is not an error.
_bk_sftp_mkdirs() {   # <remote path>
    local part acc="" parts
    [[ "$1" == /* ]] && acc="/"
    IFS='/' read -ra parts <<< "$1"
    for part in "${parts[@]}"; do
        [[ -n "$part" && "$part" != "." ]] || continue
        if [[ "$acc" == "/" ]]; then acc="/${part}"; else acc="${acc:+${acc}/}${part}"; fi
        printf -- '-mkdir "%s"\n' "$acc"
    done
}

# The remote is there and takes files: a folder made, a file written, both
# removed. What `destination test` and `destination add --test` run.
_bk_sftp_probe() {   # <name>
    local name="$1" base probe batch tmp rc=0
    base=$(_bk_sftp_path "$name" "sftp://${name}/cipi")
    probe="${base}/.cipi-probe-$$"
    tmp=$(mktemp); echo "cipi" > "$tmp"
    batch=$(mktemp)
    { _bk_sftp_mkdirs "$base"; printf 'put "%s" "%s"\nrm "%s"\n' "$tmp" "$probe" "$probe"; } > "$batch"
    _bk_sftp_batch "$name" "$batch" 2>&1 >/dev/null | grep -v '^[[:space:]]*$' | tail -1 >&2
    rc=${PIPESTATUS[0]}
    rm -f "$tmp" "$batch"
    return "$rc"
}

# The public half of a destination's key: what the remote has to accept.
_bk_sftp_pubkey() { cat "$(_bk_sftp_key "$1").pub" 2>/dev/null; }


# ── Encryption ───────────────────────────────────────────────
#
# Archives are encrypted client-side with AES-256-CBC before they leave the
# server, so the bucket operator never holds readable data. The key lives only
# on this server: losing it makes every encrypted archive unrecoverable, which
# is why `cipi backup key show` exists and the setup shouts about it.

_bk_key_ensure() {
    [[ -f "$BACKUP_KEY_FILE" ]] && return 0
    _cipi_ensure_config_writable || { error "Cannot write ${CIPI_CONFIG}"; return 1; }
    openssl rand -base64 48 | tr -d '\n' > "$BACKUP_KEY_FILE" || return 1
    chmod 400 "$BACKUP_KEY_FILE" 2>/dev/null || true
    return 0
}

_bk_encrypt_file() {
    local in="$1" out="$2"
    _bk_key_ensure || return 1
    openssl enc -aes-256-cbc -salt -pbkdf2 -pass "file:${BACKUP_KEY_FILE}" -in "$in" -out "$out"
}

_bk_decrypt_file() {
    local in="$1" out="$2" keyfile="${3:-$BACKUP_KEY_FILE}"
    [[ -f "$keyfile" ]] || { error "Backup key not found: ${keyfile}"; return 1; }
    openssl enc -d -aes-256-cbc -pbkdf2 -pass "file:${keyfile}" -in "$in" -out "$out"
}

# Where archives go, or the key they are encrypted with, changed: the owner hears
# of it, with who did it. A panel token with backups-manage can point backups at
# a bucket or a server of its choosing — this is how that never goes unnoticed.
_bk_notify_change() {
    local by="${SUDO_USER:-root}"; [[ "$by" == "www-data" ]] && by="the panel"
    cipi_notify "Backup settings changed on $(hostname)" \
        "${1} (by ${by}).\n\nServer: $(hostname)\nTime: $(notify_now)" \
        backup_config 2>/dev/null || true
}

_bk_key_command() {
    local sub="${1:-show}"; shift||true
    case "$sub" in
        show)
            _bk_key_ensure || exit 1
            local by="${SUDO_USER:-root}"; [[ "$by" == "www-data" ]] && by="the panel"
            log_action "BACKUP KEY SHOWN (${by})"
            cipi_notify "Backup encryption key shown on $(hostname)" \
                "The backup encryption key was shown (cipi backup key show, by ${by}).\n\nServer: $(hostname)\nTime: $(notify_now)" \
                credentials_show 2>/dev/null || true
            # --raw: the key and nothing else — what the panel shows, once.
            if [[ "${1:-}" == "--raw" ]]; then cat "$BACKUP_KEY_FILE"; echo; return 0; fi
            echo -e "\n${BOLD}Backup encryption key${NC}"
            echo -e "  ${DIM}File:${NC} ${BACKUP_KEY_FILE}"
            echo -e "  ${CYAN}$(cat "$BACKUP_KEY_FILE")${NC}"
            echo ""
            echo -e "  ${YELLOW}Store this off the server.${NC} Encrypted archives cannot be read without it —"
            echo -e "  ${DIM}not by Cipi, not by the bucket operator, not by you.${NC}"
            echo ""
            ;;
        rotate)
            echo -e "${YELLOW}Rotating the key does NOT re-encrypt existing archives.${NC}"
            echo -e "${YELLOW}Keep the old key or those backups become unreadable.${NC}"
            if [[ -t 0 ]]; then confirm "Rotate the backup encryption key?" || { info "Cancelled"; return 0; }; fi
            if [[ -f "$BACKUP_KEY_FILE" ]]; then
                local bak="${BACKUP_KEY_FILE}.$(date +%Y%m%d%H%M%S)"
                cp "$BACKUP_KEY_FILE" "$bak" && chmod 400 "$bak"
                warn "Previous key kept at ${bak} — needed to read older archives"
            fi
            _cipi_ensure_config_writable || { error "Cannot write ${CIPI_CONFIG}"; exit 1; }
            rm -f "$BACKUP_KEY_FILE"
            _bk_key_ensure || exit 1
            success "Backup encryption key rotated"
            log_action "BACKUP KEY ROTATED"
            _bk_notify_change "The backup encryption key was rotated: the runs to come use a new key, the old one is kept on the server"
            ;;
        *) error "Use: cipi backup key show [--raw] | rotate"; exit 1 ;;
    esac
}

# ── Profiles ─────────────────────────────────────────────────

_bk_profiles_json() { _bk_cfg | jq '.profiles // {}'; }
_bk_profile_names() { _bk_profiles_json | jq -r 'keys[]' 2>/dev/null || true; }
# jq's `//` treats `false` as absent, so `.[$p][$k] // empty` returned an empty
# string for every boolean that is false — which made `enabled: false` read as
# "not set", and a disabled profile kept running and stayed in the crontab.
_bk_profile_get()   { _bk_profiles_json | jq -r --arg p "$1" --arg k "$2" '.[$p][$k] | if . == null then empty else tostring end'; }
_bk_profile_json()  { _bk_profiles_json | jq --arg p "$1" '.[$p] // empty'; }
_bk_profile_exists() { _bk_profiles_json | jq -e --arg p "$1" 'has($p)' &>/dev/null; }

_bk_profile_list_field() {
    # Print a JSON array field one element per line.
    _bk_profiles_json | jq -r --arg p "$1" --arg k "$2" '(.[$p][$k] // []) | .[]' 2>/dev/null || true
}

_bk_valid_profile_name() {
    [[ "$1" =~ ^[a-z][a-z0-9-]{1,31}$ ]]
}

# Glob list membership: _bk_glob_match <name> <newline-separated globs>
# An empty list means "no match"; a list containing "*" matches everything.
_bk_glob_match() {
    local name="$1" globs="$2" g
    [[ -z "$globs" ]] && return 1
    while IFS= read -r g; do
        [[ -n "$g" ]] || continue
        # shellcheck disable=SC2053
        [[ "$name" == $g ]] && return 0
    done <<< "$globs"
    return 1
}

# Cron expression: exactly 5 space-separated fields of a safe charset.
# Written straight into root's crontab, so nothing else may pass. Only a plain
# space between fields: [[:space:]] would also accept a newline or a tab, and a
# newline splits the crontab line in two (the whole block is then refused).
_bk_valid_cron() {
    local expr="$1" re='^[0-9*/, -]+$'
    [[ "$expr" =~ $re ]] || return 1
    local -a fields; read -ra fields <<< "$expr"
    [[ ${#fields[@]} -eq 5 ]]
}

# --every=30m|6h|1d → "<interval-seconds><TAB><cron expression>".
#
# Both values are printed rather than one of them assigned to a global: callers
# use command substitution, and a global set inside that subshell never reaches
# them.
_bk_every_to_cron() {
    local every="$1" num unit
    [[ "$every" =~ ^([0-9]+)([mhd])$ ]] || return 1
    num="${BASH_REMATCH[1]}"; unit="${BASH_REMATCH[2]}"
    [[ "$num" -gt 0 ]] || return 1
    case "$unit" in
        m)
            [[ "$num" -le 59 ]] || return 1
            [[ $(( 60 % num )) -eq 0 ]] || return 1
            printf '%s\t%s\n' "$(( num * 60 ))" "*/${num} * * * *"
            ;;
        h)
            [[ "$num" -le 23 ]] || return 1
            [[ $(( 24 % num )) -eq 0 ]] || return 1
            printf '%s\t%s\n' "$(( num * 3600 ))" "0 */${num} * * *"
            ;;
        d)
            [[ "$num" -le 28 ]] || return 1
            if [[ "$num" -eq 1 ]]; then
                printf '%s\t%s\n' "86400" "0 2 * * *"
            else
                printf '%s\t%s\n' "$(( num * 86400 ))" "0 2 */${num} * *"
            fi
            ;;
    esac
}

# Best-effort expected interval for a raw cron expression, used only to decide
# when a profile counts as overdue.
_bk_cron_interval_seconds() {
    local expr="$1"
    local min hour dom mon dow
    read -r min hour dom mon dow <<< "$expr"
    if [[ "$min" =~ ^\*/([0-9]+)$ ]]; then echo $(( BASH_REMATCH[1] * 60 )); return; fi
    if [[ "$min" == "*" ]]; then echo 60; return; fi
    if [[ "$hour" =~ ^\*/([0-9]+)$ ]]; then echo $(( BASH_REMATCH[1] * 3600 )); return; fi
    if [[ "$hour" == "*" ]]; then echo 3600; return; fi
    if [[ "$dow" != "*" ]]; then echo 604800; return; fi
    if [[ "$dom" =~ ^\*/([0-9]+)$ ]]; then echo $(( BASH_REMATCH[1] * 86400 )); return; fi
    if [[ "$dom" != "*" ]]; then echo 2592000; return; fi
    echo 86400
}

_bk_default_profile_json() {
    # Mirrors the pre-5.1 behaviour: one nightly full backup, kept four weeks.
    jq -n '{
        scope: "all",
        apps: ["*"],
        databases: ["*"],
        exclude_databases: [],
        exclude_tables: [],
        exclude_paths: [],
        cron: "0 2 * * *",
        interval_seconds: 86400,
        destinations: ["local"],
        retention: { keep: 0, days: 28, weeks: 0 },
        encrypt: false,
        enabled: true,
        created_at: (now | floor)
    }'
}

_bk_profile_save() {
    local name="$1" json="$2"
    _bk_cfg | jq --arg p "$name" --argjson d "$json" '
        .profiles = ((.profiles // {}) | .[$p] = ($d | .created_at = (.created_at // (now | floor))))
    ' | _bk_cfg_write
    _bk_write_cron
}

# The nightly profile of a first setup: every app and every database, on this
# server — plus the destinations given (those added at the same time).
_bk_ensure_default_profile() {   # [destination...]
    _bk_configured || return 1
    local n; n=$(_bk_profiles_json | jq 'length')
    [[ "$n" -gt 0 ]] && return 1
    local d; d=$(_bk_default_profile_json)
    [[ $# -gt 0 ]] && d=$(echo "$d" | jq --args '.destinations = (["local"] + $ARGS.positional)' "$@")
    _bk_profile_save default "$d"
    info "Created backup profile 'default' (nightly 02:00, kept 28 days, on this server)"
    return 0
}

# Send these profiles to a destination too: --use=<profile>[,<profile>].
_bk_use_dest() {   # <destination> <profile,...>
    local dn="$1" csv="$2" p
    [[ -n "$csv" ]] || return 0
    for p in ${csv//,/ }; do
        _bk_valid_profile_name "$p" && _bk_profile_exists "$p" || { warn "No profile '${p}' — not sent to ${dn}" >&2; continue; }
        _bk_cfg | jq --arg p "$p" --arg d "$dn" '.profiles[$p].destinations |= ((. // []) | if any(.[]; . == $d) then . else . + [$d] end)' | _bk_cfg_write
        [[ "${ARG_json:-}" == "true" ]] || info "Profile '${p}' sends its runs to ${dn} too"
    done
}

# ── Profile CLI ──────────────────────────────────────────────

_bk_profile_command() {
    local sub="${1:-list}"; shift||true
    case "$sub" in
        list|ls)  _bk_profile_list ;;
        show)     _bk_profile_show "$@" ;;
        add|edit) _bk_profile_add "$sub" "$@" ;;
        remove|rm|delete) _bk_profile_remove "$@" ;;
        enable)   _bk_profile_toggle "${1:-}" true ;;
        disable)  _bk_profile_toggle "${1:-}" false ;;
        *) error "Use: cipi backup profile list|show|add|edit|remove [--purge]|enable|disable"; exit 1 ;;
    esac
}

_bk_profile_list() {
    _bk_require_config
    _bk_ensure_default_profile
    local names; names=$(_bk_profile_names)
    [[ -z "$names" ]] && { info "No backup profiles. Create one: cipi backup profile add <name> ..."; return 0; }

    local state; state=$(_bk_state)

    echo -e "\n${BOLD}Backup profiles${NC}"
    tbl_start
    tbl_head "PROFILE" "SCOPE" "SCHEDULE" "DEST" "RETENTION" "LAST RUN"
    local p scope cron dest ret enc last status col flag
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        scope=$(_bk_profile_get "$p" scope)
        cron=$(_bk_profile_get "$p" cron)
        dest=$(_bk_profile_list_field "$p" destinations | paste -sd, -)
        ret=$(_bk_retention_label "$p")
        enc=$(_bk_profile_get "$p" encrypt)
        last=$(echo "$state" | jq -r --arg p "$p" '.[$p].last_end // "never"')
        status=$(echo "$state" | jq -r --arg p "$p" '.[$p].status // ""')
        flag=""
        [[ "$(_bk_profile_get "$p" enabled)" == "false" ]] && flag=" ${DIM}(disabled)${NC}"
        [[ "$enc" == "true" ]] && dest="${dest}+enc"
        col="$NC"
        [[ "$status" == "error" ]] && col="$RED"
        [[ "$status" == "ok" ]] && col="$GREEN"
        tbl_row "${CYAN}${p}${NC}" "$scope" "$cron" "$dest" "$ret" "${col}${last}${NC}${flag}"
    done <<< "$names"
    tbl_print
    echo ""
    echo -e "  ${DIM}Details: cipi backup profile show <name>${NC}"
    echo ""
}

_bk_retention_label() {
    local p="$1" keep days weeks out=""
    keep=$(_bk_profiles_json | jq -r --arg p "$p" '.[$p].retention.keep // 0')
    days=$(_bk_profiles_json | jq -r --arg p "$p" '.[$p].retention.days // 0')
    weeks=$(_bk_profiles_json | jq -r --arg p "$p" '.[$p].retention.weeks // 0')
    [[ "$keep"  -gt 0 ]] && out="${out}${out:+,}${keep} runs"
    [[ "$days"  -gt 0 ]] && out="${out}${out:+,}${days}d"
    [[ "$weeks" -gt 0 ]] && out="${out}${out:+,}${weeks}w"
    echo "${out:-—}"
}

_bk_profile_created_label() {
    local ts
    ts=$(_bk_profiles_json | jq -r --arg p "$1" '.[$p].created_at // empty')
    [[ "$ts" =~ ^[0-9]+$ ]] || { echo "—"; return 0; }
    date -d "@${ts}" '+%Y-%m-%d %H:%M' 2>/dev/null || date -r "$ts" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "—"
}

_bk_profile_show() {
    local p="${1:-}"
    [[ -z "$p" ]] && { error "Usage: cipi backup profile show <name>"; exit 1; }
    _bk_require_config
    _bk_profile_exists "$p" || { error "No such profile: ${p}"; exit 1; }

    local state; state=$(_bk_state)
    echo -e "\n${BOLD}Backup profile '${p}'${NC}"
    printf "  %-20s %s\n" "Scope"        "$(_bk_profile_get "$p" scope)"
    printf "  %-20s %s\n" "Enabled"      "$(_bk_profile_get "$p" enabled)"
    printf "  %-20s %s\n" "Schedule"     "$(_bk_profile_get "$p" cron)"
    printf "  %-20s %s\n" "Apps"         "$(_bk_profile_list_field "$p" apps | paste -sd, -)"
    printf "  %-20s %s\n" "Databases"    "$(_bk_profile_list_field "$p" databases | paste -sd, -)"
    local exdb extbl
    exdb=$(_bk_profile_list_field "$p" exclude_databases | paste -sd, -)
    extbl=$(_bk_profile_list_field "$p" exclude_tables | paste -sd, -)
    printf "  %-20s %s\n" "Exclude DBs"    "${exdb:-—}"
    printf "  %-20s %s\n" "Exclude tables" "${extbl:-—}"
    local expth; expth=$(_bk_profile_list_field "$p" exclude_paths | paste -sd, -)
    printf "  %-20s %s\n" "Exclude paths"  "${expth:-—}"
    printf "  %-20s %s\n" "Destinations" "$(_bk_profile_list_field "$p" destinations | paste -sd, -)"
    printf "  %-20s %s\n" "Encrypted"    "$(_bk_profile_get "$p" encrypt)"
    printf "  %-20s %s\n" "Created"      "$(_bk_profile_created_label "$p")"
    printf "  %-20s %s\n" "Retention"    "$(_bk_retention_label "$p")"
    echo ""
    echo -e "  ${BOLD}Last run${NC}"
    printf "  %-20s %s\n" "Started"  "$(echo "$state" | jq -r --arg p "$p" '.[$p].last_start // "never"')"
    printf "  %-20s %s\n" "Finished" "$(echo "$state" | jq -r --arg p "$p" '.[$p].last_end // "never"')"
    printf "  %-20s %s\n" "Status"   "$(echo "$state" | jq -r --arg p "$p" '.[$p].status // "—"')"
    printf "  %-20s %s\n" "Detail"   "$(echo "$state" | jq -r --arg p "$p" '.[$p].detail // "—"')"
    echo ""
    echo -e "  ${DIM}Preview what it would take: cipi backup run --profile=${p} --dry-run${NC}"
    echo ""
}

_bk_profile_toggle() {
    local p="$1" on="$2"
    [[ -z "$p" ]] && { error "Usage: cipi backup profile enable|disable <name>"; exit 1; }
    _bk_require_config
    _bk_profile_exists "$p" || { error "No such profile: ${p}"; exit 1; }
    _bk_cfg | jq --arg p "$p" --argjson v "$on" '.profiles[$p].enabled = $v' | _bk_cfg_write
    _bk_write_cron
    success "Profile '${p}' $([[ "$on" == "true" ]] && echo enabled || echo disabled)"
    log_action "BACKUP PROFILE $([[ "$on" == "true" ]] && echo ENABLE || echo DISABLE): $p"
}

# Drop a profile from backup.json and from root's crontab. Archives stay:
# `cipi backup prune` ages them out with the remaining profiles. Idempotent
# when the profile is already gone, so `cipi yml apply` can call it without
# the interactive confirm of `cipi backup profile remove`.
_bk_profile_delete() {
    local p="$1"
    [[ -n "$p" ]] || return 1
    _bk_configured || return 1
    if _bk_profile_exists "$p"; then
        _bk_cfg | jq --arg p "$p" 'del(.profiles[$p])' | _bk_cfg_write || return 1
        _bk_state_write "$(_bk_state | jq --arg p "$p" 'del(.[$p])')" || return 1
        _bk_write_cron || return 1
    fi
    return 0
}

# cipi backup profile remove <name> [--purge]
# The archives a profile wrote outlive it: `cipi backup prune` ages them out
# with the longest retention a remaining profile sets, and with none they
# stayed for good. --purge deletes every run of the profile now, on every
# destination; on a terminal the question is asked. --purge also works for
# a profile that is already gone, to clear what it left behind.
_bk_profile_remove() {
    local p="${1:-}"; shift || true
    [[ -z "$p" ]] && { error "Usage: cipi backup profile remove <name> [--purge]"; exit 1; }
    _bk_valid_profile_name "$p" || { error "Invalid profile name: ${p}"; exit 1; }
    parse_args "$@"
    local purge="${ARG_purge:-false}" exists=true
    _bk_require_config
    _bk_profile_exists "$p" || exists=false

    local runs="" n=0
    runs=$(_bk_list_runs "$p" 2>/dev/null | grep -E '^[0-9]{4}-' | sort -u || true)
    [[ -n "$runs" ]] && n=$(wc -l <<< "$runs" | tr -d ' ')

    if [[ "$exists" == false ]]; then
        if [[ "$purge" == "true" && "$n" -gt 0 ]]; then
            info "No profile '${p}' — deleting the ${n} archive run(s) it left behind"
        elif [[ "$purge" == "true" ]]; then
            info "No profile '${p}' and no archives of it"; return 0
        else
            error "No such profile: ${p}"; exit 1
        fi
    else
        if [[ -t 0 ]]; then
            confirm "Remove backup profile '${p}'?" || { info "Cancelled"; return 0; }
            if [[ "$purge" != "true" && "$n" -gt 0 ]]; then
                echo -e "  ${DIM}It wrote ${n} archive run(s), kept on every destination: $(_bk_orphan_note "$p").${NC}"
                confirm "Delete those archives now too?" && purge=true
            fi
        fi
        _bk_profile_delete "$p" || return 1
        success "Profile '${p}' removed"
        log_action "BACKUP PROFILE REMOVE: $p"
    fi

    if [[ "$purge" != "true" ]]; then
        [[ "$n" -gt 0 ]] && info "${n} archive run(s) kept — $(_bk_orphan_note "$p"). Delete them: cipi backup profile remove ${p} --purge"
        return 0
    fi
    [[ "$n" -gt 0 ]] || { info "No archives to delete"; return 0; }
    step "Deleting ${n} archive run(s) of '${p}' on every destination..."
    _BK_PRUNE_ERRORS=""
    local ts
    while IFS= read -r ts; do
        [[ -n "$ts" ]] || continue
        _bk_delete_run "$p" "$ts"
    done <<< "$runs"
    rmdir "$(_bk_local_root)/${p}" 2>/dev/null || true
    if [[ -n "$_BK_PRUNE_ERRORS" ]]; then
        error "Some archives could not be deleted: ${_BK_PRUNE_ERRORS}"
        return 1
    fi
    success "Archives of '${p}' deleted (${n} run(s))"
    log_action "BACKUP PROFILE PURGE: $p runs=${n}"
}

# Comma-separated CLI value → JSON array (empty string → []).
_bk_csv_to_json() {
    local csv="${1:-}"
    [[ -z "$csv" ]] && { echo '[]'; return 0; }
    printf '%s' "$csv" | jq -R -s 'split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(length > 0))'
}

_bk_profile_add() {
    local mode="$1"; shift||true
    local name="${1:-}"; shift||true
    [[ -z "$name" ]] && { error "Usage: cipi backup profile ${mode} <name> [flags]  (cipi help backup)"; exit 1; }
    _bk_valid_profile_name "$name" || { error "Invalid profile name '${name}' (lowercase letters, digits and dashes, 2-32 chars)"; exit 1; }
    _bk_require_config
    parse_args "$@"

    local existing="{}" is_new=true
    if _bk_profile_exists "$name"; then
        is_new=false
        existing=$(_bk_profile_json "$name")
        [[ "$mode" == "add" ]] && { error "Profile '${name}' already exists — use: cipi backup profile edit ${name} ..."; exit 1; }
    else
        [[ "$mode" == "edit" ]] && { error "No such profile: ${name}"; exit 1; }
        existing=$(_bk_default_profile_json)
    fi

    local json="$existing"

    # ── scope
    if [[ -n "${ARG_scope:-}" ]]; then
        case "${ARG_scope}" in
            all|files|db) json=$(echo "$json" | jq --arg v "${ARG_scope}" '.scope = $v') ;;
            *) error "--scope must be one of: all files db"; exit 1 ;;
        esac
    fi

    # ── selectors
    [[ -n "${ARG_apps:-}" ]] \
        && json=$(echo "$json" | jq --argjson v "$(_bk_csv_to_json "${ARG_apps}")" '.apps = $v')
    [[ -n "${ARG_databases:-}" ]] \
        && json=$(echo "$json" | jq --argjson v "$(_bk_csv_to_json "${ARG_databases}")" '.databases = $v')
    # The two exclusion lists can be emptied again: --exclude-databases= (the
    # flag with nothing after the equals sign). The panel edits a profile by
    # sending every field, an emptied list included.
    [[ -n "${ARG_exclude_databases+x}" ]] \
        && json=$(echo "$json" | jq --argjson v "$(_bk_csv_to_json "${ARG_exclude_databases}")" '.exclude_databases = $v')
    [[ -n "${ARG_exclude_tables+x}" ]] \
        && json=$(echo "$json" | jq --argjson v "$(_bk_csv_to_json "${ARG_exclude_tables}")" '.exclude_tables = $v')
    # Folders and files left out of the app archives (an uploads folder of a
    # terabyte, kept elsewhere with rsync). Emptied again with --exclude-paths=.
    if [[ -n "${ARG_exclude_paths+x}" ]]; then
        local xp bad=""
        xp=$(_bk_csv_to_json "${ARG_exclude_paths}")
        while IFS= read -r pat; do
            [[ -n "$pat" ]] || continue
            _bk_valid_exclude_path "$pat" || bad="${bad}${bad:+, }${pat}"
        done < <(echo "$xp" | jq -r '.[]')
        if [[ -n "$bad" ]]; then
            error "Invalid --exclude-paths entry: ${bad}"
            info "A path relative to the app (storage/app/uploads, wp-content/uploads, *.mp4),"
            info "optionally for some apps only: shop:storage/app/uploads  (apps by name or glob)"
            exit 1
        fi
        json=$(echo "$json" | jq --argjson v "$xp" '.exclude_paths = $v')
    fi

    # ── schedule
    if [[ -n "${ARG_every:-}" && -n "${ARG_cron:-}" ]]; then
        error "Use either --every=<30m|6h|1d> or --cron='<expr>', not both"; exit 1
    fi
    if [[ -n "${ARG_every:-}" ]]; then
        local spec expr secs
        if ! spec=$(_bk_every_to_cron "${ARG_every}"); then
            error "Invalid --every='${ARG_every}'. Use Nm (a divisor of 60), Nh (a divisor of 24) or Nd (1-28)."
            exit 1
        fi
        secs="${spec%%$'\t'*}"; expr="${spec#*$'\t'}"
        json=$(echo "$json" | jq --arg c "$expr" --argjson i "$secs" '.cron = $c | .interval_seconds = $i')
    elif [[ -n "${ARG_cron:-}" ]]; then
        _bk_valid_cron "${ARG_cron}" || { error "Invalid --cron expression (5 fields, digits and * / , - only)"; exit 1; }
        local secs; secs=$(_bk_cron_interval_seconds "${ARG_cron}")
        json=$(echo "$json" | jq --arg c "${ARG_cron}" --argjson i "$secs" '.cron = $c | .interval_seconds = $i')
    fi

    # ── destinations
    if [[ -n "${ARG_dest:-}" ]]; then
        local d dests="[]"
        dests=$(_bk_csv_to_json "${ARG_dest}")
        while IFS= read -r d; do
            [[ -n "$d" ]] || continue
            case "$d" in
                local) ;;
                *) _bk_s3_exists "$d" || {
                       error "Unknown destination '${d}' — use local or the name of an S3 bucket or an SFTP server"
                       info "Configured destinations: cipi backup destination list"
                       exit 1
                   } ;;
            esac
        done < <(echo "$dests" | jq -r '.[]')
        [[ "$(echo "$dests" | jq 'length')" -eq 0 ]] && { error "--dest cannot be empty"; exit 1; }
        json=$(echo "$json" | jq --argjson v "$dests" '.destinations = $v')
    fi

    # ── retention
    local touched_ret=false
    for k in keep keep_days keep_weeks; do
        local var="ARG_${k}"
        [[ -n "${!var:-}" ]] && touched_ret=true
    done
    if [[ "$touched_ret" == true ]]; then
        local keep="${ARG_keep:-0}" days="${ARG_keep_days:-0}" weeks="${ARG_keep_weeks:-0}"
        for v in "$keep" "$days" "$weeks"; do
            [[ "$v" =~ ^[0-9]+$ ]] || { error "Retention values must be non-negative integers"; exit 1; }
        done
        if [[ "$keep" -eq 0 && "$days" -eq 0 && "$weeks" -eq 0 ]]; then
            error "At least one of --keep, --keep-days, --keep-weeks must be greater than 0"
            error "A profile with no retention would grow without bound."
            exit 1
        fi
        json=$(echo "$json" | jq \
            --argjson k "$keep" --argjson d "$days" --argjson w "$weeks" \
            '.retention = {keep: $k, days: $d, weeks: $w}')
    fi

    # ── encryption
    if [[ "${ARG_encrypt:-}" == "true" ]]; then
        _bk_key_ensure || { error "Could not create the backup encryption key"; exit 1; }
        json=$(echo "$json" | jq '.encrypt = true')
    elif [[ "${ARG_no_encrypt:-}" == "true" ]]; then
        json=$(echo "$json" | jq '.encrypt = false')
    fi

    # ── coherence checks
    local scope; scope=$(echo "$json" | jq -r '.scope')
    if [[ "$scope" == "files" ]] && [[ "$(echo "$json" | jq '.apps | length')" -eq 0 ]]; then
        error "--scope=files with an empty --apps list would back up nothing"; exit 1
    fi
    if [[ "$scope" == "db" ]] && [[ "$(echo "$json" | jq '.databases | length')" -eq 0 ]]; then
        error "--scope=db with an empty --databases list would back up nothing"; exit 1
    fi
    if [[ "$(echo "$json" | jq '.destinations | length')" -eq 0 ]]; then
        error "Profile has no destination — set --dest=local, --dest=s3 or a named destination (cipi backup destination list)"; exit 1
    fi

    _bk_profile_save "$name" "$json"
    if [[ "$is_new" == true ]]; then
        success "Backup profile '${name}' created"
        log_action "BACKUP PROFILE ADD: $name"
    else
        success "Backup profile '${name}' updated"
        log_action "BACKUP PROFILE EDIT: $name"
    fi
    if [[ "$(echo "$json" | jq -r '.encrypt')" == "true" ]]; then
        warn "Archives are encrypted — save the key now: cipi backup key show"
    fi
    _bk_profile_show "$name"
}

# ── Crontab (single managed block) ───────────────────────────
#
# The schedule is derived from the profiles and rewritten wholesale between
# markers, so editing a profile is enough — nobody has to hand-edit crontab,
# and Cipi never touches lines outside its own block.

_BK_CRON_START="# === CIPI BACKUP START (managed by 'cipi backup profile' — do not edit by hand) ==="
_BK_CRON_END="# === CIPI BACKUP END ==="

_bk_write_cron() {
    [[ $EUID -ne 0 ]] && return 0
    local current block=""
    current=$(crontab -l 2>/dev/null || true)

    # Drop the managed block and any pre-5.1 unmanaged backup lines.
    current=$(printf '%s\n' "$current" | awk -v s="$_BK_CRON_START" -v e="$_BK_CRON_END" '
        $0 == s { skip = 1; next }
        $0 == e { skip = 0; next }
        skip { next }
        /^# === CIPI BACKUP \(all apps\) ===$/ { next }
        /cipi backup run/ { next }
        /cipi backup prune/ { next }
        /cipi backup check/ { next }
        { print }
    ')

    local p cron enabled
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        enabled=$(_bk_profile_get "$p" enabled)
        [[ "$enabled" == "false" ]] && continue
        cron=$(_bk_profile_get "$p" cron)
        _bk_valid_cron "$cron" || continue
        block="${block}${cron} /usr/local/bin/cipi backup run --profile=${p} >> ${CIPI_LOG}/backup.log 2>&1"$'\n'
    done < <(_bk_profile_names)

    # Overdue-backup watchdog: a backup that silently stops running is worse
    # than no backup, because it still looks configured.
    if [[ -n "$block" ]]; then
        block="${block}17 * * * * /usr/local/bin/cipi backup check --quiet >> ${CIPI_LOG}/backup.log 2>&1"$'\n'
    fi

    {
        [[ -n "$current" ]] && printf '%s\n' "$current"
        if [[ -n "$block" ]]; then
            printf '%s\n' "$_BK_CRON_START"
            printf '%s' "$block"
            printf '%s\n' "$_BK_CRON_END"
        fi
    } | crontab -
}

# ── Run state (last result per profile) ──────────────────────

_bk_state()       { vault_read backup-state.json 2>/dev/null || echo '{}'; }
_bk_state_write() { printf '%s' "$1" | vault_write backup-state.json; }

_bk_state_set() {
    local profile="$1" status="$2" detail="$3" started="$4"
    local st; st=$(_bk_state)
    _bk_state_write "$(echo "$st" | jq \
        --arg p "$profile" --arg s "$status" --arg d "$detail" \
        --arg b "$started" --arg e "$(date '+%Y-%m-%d %H:%M:%S')" \
        --argjson ts "$(date +%s)" '
        .[$p] = ((.[$p] // {}) + {
            last_start: $b, last_end: $e, status: $s, detail: $d, last_epoch: $ts
        })
        | if $s == "ok" then .[$p].last_success_epoch = $ts else . end
    ')"
}

# ── Selection ────────────────────────────────────────────────

# Apps a profile covers (registered in apps.json, matching its globs).
_bk_select_apps() {
    local p="$1" globs a
    globs=$(_bk_profile_list_field "$p" apps)
    while IFS= read -r a; do
        [[ -n "$a" ]] || continue
        _bk_glob_match "$a" "$globs" && echo "$a"
    done < <(vault_read apps.json 2>/dev/null | jq -r 'keys[]' 2>/dev/null || true)
}

# Databases a profile covers, as "<engine>\t<name>" lines.
#
# The list comes from the *engine*, not from databases.json: tenant databases
# a multi-tenant app creates at runtime appear in no registry, and a backup
# that only consulted the registry skipped every one of them.
_bk_select_databases() {
    local p="$1" inc exc eng db
    inc=$(_bk_profile_list_field "$p" databases)
    exc=$(_bk_profile_list_field "$p" exclude_databases)

    for eng in mariadb pgsql; do
        db_engine_is_installed "$eng" 2>/dev/null || continue
        while IFS= read -r db; do
            [[ -n "$db" ]] || continue
            _bk_glob_match "$db" "$inc" || continue
            _bk_glob_match "$db" "$exc" && continue
            printf '%s\t%s\n' "$eng" "$db"
        done < <(db_list_databases "$eng" 2>/dev/null || true)
    done
}

# Paths to archive for an app, relative to /home/<app>.
#
# Laravel apps keep everything durable in shared/ (the .env and storage/); the
# code itself comes back from git. A --custom app has no shared/ at all — its
# files live in htdocs/, and archiving shared/ there failed on every run,
# marking the whole backup as errored while quietly saving nothing.
_bk_app_home() { echo "/home/${1:-}"; }

_bk_app_paths() {
    local app="$1"
    local home
    home=$(_bk_app_home "$app")
    if [[ "$(app_get "$app" runtime)" == "node" ]]; then
        # Code comes back from git; shared/ holds .env.
        [[ -d "${home}/shared" ]] && echo "shared"
    elif [[ "$(app_get "$app" custom)" == "true" ]]; then
        [[ -d "${home}/htdocs" ]] && echo "htdocs"
    else
        [[ -d "${home}/shared" ]] && echo "shared"
    fi
    # "nothing to archive" is a normal answer, not a failure: without this the
    # empty result made the assignment fail and `set -e` aborted the whole
    # backup run before it reached the "skipped" warning.
    return 0
}

# ── Paths left out of the app archives ───────────────────────
#
# A profile's exclude_paths are tar exclusion patterns, matched against the
# names inside the archive, which are relative to the app's home (shared/…,
# htdocs/…). As tar does for exclusions, a pattern matches after any "/" and
# its wildcards cross "/": "storage/app/uploads" leaves out
# shared/storage/app/uploads, "*.mp4" every video. "<apps>:<pattern>" applies
# to the apps of that name or glob only ("shop:storage/app/uploads").
_bk_valid_exclude_path() {
    local p="$1" pat
    [[ -n "$p" && "$p" != *$'\n'* && ${#p} -le 255 ]] || return 1
    pat="$p"
    if [[ "$p" =~ ^([a-z0-9*?-]+):(.+)$ ]]; then pat="${BASH_REMATCH[2]}"; fi
    # Absolute paths never match a name inside the archive: refused rather
    # than silently excluding nothing.
    local re='^[][A-Za-z0-9._*?/@+ -]+$'
    [[ "$pat" != /* && "$pat" =~ $re ]] || return 1
    # Nothing that would leave the whole app out.
    [[ "$pat" != "*" && "$pat" != "*/" && "$pat" != "shared" && "$pat" != "htdocs" ]]
}

# The patterns of <profile> that apply to <app>, one per line.
_bk_app_excludes() {   # <profile> <app>
    local p="$1" app="$2" e
    while IFS= read -r e; do
        [[ -n "$e" ]] || continue
        if [[ "$e" =~ ^([a-z0-9*?-]+):(.+)$ ]]; then
            # shellcheck disable=SC2053
            [[ "$app" == ${BASH_REMATCH[1]} ]] && echo "${BASH_REMATCH[2]}"
        else
            echo "$e"
        fi
    done < <(_bk_profile_list_field "$p" exclude_paths)
    return 0
}

# Is this gzip stream complete and readable? Catches the failure mode that
# matters most here — an archive truncated by a full disk, which is non-empty
# and therefore passes every size check, but restores to nothing.
_bk_check_archive() {
    local f="$1"
    [[ -s "$f" ]] || return 1
    gzip -t "$f" 2>/dev/null
}

# ── Run ──────────────────────────────────────────────────────

# cipi backup run … --detach: the same run, started on its own and left to
# finish — its output goes to backup.log, like the scheduled ones, and
# `cipi backup status` says when it is done. For whoever cannot wait for it:
# the panel's queue worker gives a command ten minutes and takes its children
# with it when it is recycled, and a backup of a real server needs longer.
# Under systemd the run gets a unit of its own (nothing to do with the
# caller's); without it, a session of its own.
_bk_run_detached() {   # [args of cipi backup run, without --detach]
    local log="${CIPI_LOG}/backup.log" bin="${CIPI_BIN:-/usr/local/bin/cipi}" started=false
    mkdir -p "${CIPI_LOG}" 2>/dev/null || true
    if [[ -d /run/systemd/system ]] && command -v systemd-run >/dev/null 2>&1; then
        if systemd-run --quiet --collect --no-block \
            --unit="cipi-backup-run-$(date +%s)-$$" \
            --description="Cipi backup run (detached)" \
            --setenv=HOME=/root \
            --setenv=CIPI_BACKUP_LOG="$log" \
            /bin/bash -c 'exec "$0" backup run "$@" >> "$CIPI_BACKUP_LOG" 2>&1' "$bin" "$@" 2>/dev/null; then
            started=true
        fi
    fi
    if [[ "$started" == false ]]; then
        setsid nohup "$bin" backup run "$@" >> "$log" 2>&1 < /dev/null &
        disown 2>/dev/null || true
    fi
    success "Backup started in the background"
    echo -e "  ${DIM}Follow it: tail -f ${log}  ·  when it is done: cipi backup status${NC}"
    return 0
}

_bk_run() {
    local profile="" target="" dry=false detach=false
    local arg
    local -a pass=()
    for arg in "$@"; do
        case "$arg" in
            --profile=*) profile="${arg#--profile=}"; pass+=("$arg") ;;
            --dry-run)   dry=true ;;
            --detach)    detach=true ;;
            --*)         error "Unknown flag: ${arg}"; exit 1 ;;
            *)           target="$arg"; pass+=("$arg") ;;
        esac
    done

    _bk_require_config
    _bk_ensure_default_profile

    if [[ "$detach" == true ]]; then
        [[ "$dry" == false ]] || { error "--detach and --dry-run do not go together"; exit 1; }
        if [[ -n "$profile" ]]; then
            _bk_valid_profile_name "$profile" || { error "Invalid profile name: ${profile}"; exit 1; }
            _bk_profile_exists "$profile" || { error "No such profile: ${profile}"; exit 1; }
        fi
        if [[ -n "$target" ]]; then
            app_exists "$target" || { error "App '${target}' not found"; exit 1; }
        fi
        _bk_run_detached "${pass[@]}"
        return 0
    fi

    # `cipi backup run` / `cipi backup run <app>` keep their old meaning: run
    # every enabled profile (optionally narrowed to one app).
    if [[ -z "$profile" ]]; then
        local any=false p rc=0
        while IFS= read -r p; do
            [[ -n "$p" ]] || continue
            [[ "$(_bk_profile_get "$p" enabled)" == "false" ]] && continue
            any=true
            # One failing profile must not stop the others, and must not let
            # `set -e` kill the whole run — but the exit code still reports it.
            _bk_run_profile "$p" "$target" "$dry" || rc=1
        done < <(_bk_profile_names)
        [[ "$any" == false ]] && { warn "No enabled backup profiles"; return 0; }
        return "$rc"
    fi

    _bk_profile_exists "$profile" || { error "No such profile: ${profile}"; exit 1; }
    _bk_run_profile "$profile" "$target" "$dry"
}

_bk_run_profile() {
    local p="$1" only_app="${2:-}" dry="${3:-false}"

    # Guarded: _bk_run loops over every profile, and re-sourcing on each pass
    # is pure waste.
    # shellcheck source=/dev/null
    declare -f db_dump_database_ex >/dev/null 2>&1 || source "${CIPI_LIB}/db.sh"

    local scope encrypt dests ts started
    scope=$(_bk_profile_get "$p" scope)
    encrypt=$(_bk_profile_get "$p" encrypt)
    dests=$(_bk_profile_list_field "$p" destinations)
    ts=$(date +%Y-%m-%d_%H%M%S)
    started=$(date '+%Y-%m-%d %H:%M:%S')

    echo -e "\n${BOLD}Backup profile '${p}'${NC} ${DIM}(${scope}, ${ts})${NC}"

    local -a apps=() dbs=()
    if [[ "$scope" == "all" || "$scope" == "files" ]]; then
        while IFS= read -r a; do
            [[ -n "$a" ]] || continue
            [[ -n "$only_app" && "$a" != "$only_app" ]] && continue
            apps+=("$a")
        done < <(_bk_select_apps "$p")
    fi
    if [[ "$scope" == "all" || "$scope" == "db" ]]; then
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            dbs+=("$line")
        done < <(_bk_select_databases "$p")
    fi

    if [[ "$dry" == true ]]; then
        echo -e "  ${BOLD}Would archive files for ${#apps[@]} app(s):${NC}"
        local a
        for a in "${apps[@]:-}"; do
            [[ -n "$a" ]] || continue
            local xs; xs=$(_bk_app_excludes "$p" "$a" | paste -sd, -)
            echo -e "    ${CYAN}${a}${NC} ${DIM}($(_bk_app_paths "$a" | paste -sd, - || echo 'nothing to archive')${xs:+; leaving out ${xs}})${NC}"
        done
        echo -e "  ${BOLD}Would dump ${#dbs[@]} database(s):${NC}"
        local l
        for l in "${dbs[@]:-}"; do
            [[ -n "$l" ]] || continue
            echo -e "    ${CYAN}$(echo "$l" | cut -f2)${NC} ${DIM}($(echo "$l" | cut -f1))${NC}"
        done
        echo -e "  ${BOLD}Destinations:${NC} $(echo "$dests" | paste -sd, -)$([[ "$encrypt" == "true" ]] && echo " (encrypted)")"
        echo ""
        return 0
    fi

    if [[ ${#apps[@]} -eq 0 && ${#dbs[@]} -eq 0 ]]; then
        warn "Profile '${p}' matched nothing — check its apps/databases patterns"
        _bk_state_set "$p" "warn" "matched nothing" "$started"
        return 0
    fi

    local tmp; tmp="$(_bk_tmp_base)/cipi-bk-${p}-${ts}"
    mkdir -p "${tmp}/apps" "${tmp}/databases"
    local errors=""

    # ── application files
    local a paths tar_err
    for a in "${apps[@]:-}"; do
        [[ -n "$a" ]] || continue
        paths=$(_bk_app_paths "$a")
        if [[ -z "$paths" ]]; then
            warn "  ${a}: nothing to archive (no shared/ or htdocs/) — skipped"
            continue
        fi
        local -a tar_excl=()
        local xpat xlist=""
        while IFS= read -r xpat; do
            [[ -n "$xpat" ]] || continue
            tar_excl+=( "--exclude=${xpat}" )
            xlist="${xlist}${xlist:+, }${xpat}"
        done < <(_bk_app_excludes "$p" "$a")
        step "  Files: ${a} (${paths//$'\n'/, }${xlist:+; leaving out ${xlist}})"
        mkdir -p "${tmp}/apps/${a}"
        # tar exits 1 for *warnings* — most commonly "file changed as we read
        # it", which happens constantly on a live app writing its logs. Only
        # exit 2 and above means the archive is unusable; treating 1 as failure
        # would flag a perfectly good backup as broken on every busy site.
        local tar_rc=0
        # shellcheck disable=SC2086
        tar_err=$(tar -czf "${tmp}/apps/${a}/files.tar.gz" -C "$(_bk_app_home "$a")" "${tar_excl[@]}" $paths 2>&1) || tar_rc=$?
        if [[ $tar_rc -ge 2 ]]; then
            error "    archive failed: ${tar_err}"
            errors="${errors}${errors:+, }files:${a}"
            rm -f "${tmp}/apps/${a}/files.tar.gz"
            continue
        elif [[ $tar_rc -eq 1 ]]; then
            warn "    files changed while being archived (normal on a live app)"
        fi
        if ! _bk_check_archive "${tmp}/apps/${a}/files.tar.gz"; then
            error "    archive is unreadable — discarding it rather than storing a corrupt backup"
            errors="${errors}${errors:+, }files:${a}"
            rm -f "${tmp}/apps/${a}/files.tar.gz"
            continue
        fi
        # What the archive leaves out travels with it: a restore says which
        # folders have to come back from wherever they are kept.
        vault_read apps.json | jq --arg a "$a" --argjson x "$(_bk_app_excludes "$p" "$a" | jq -R -s 'split("\n") | map(select(length > 0))')" '.[$a] | {
            domain, aliases, php, branch, repository, custom, docroot, engine,
            octane, reverb, horizon, schedule
        } + {excluded_paths: $x}' > "${tmp}/apps/${a}/meta.json" 2>/dev/null || echo '{}' > "${tmp}/apps/${a}/meta.json"
    done

    # ── databases
    local excl_tables line eng db
    excl_tables=$(_bk_profile_list_field "$p" exclude_tables | paste -sd, -)
    for line in "${dbs[@]:-}"; do
        [[ -n "$line" ]] || continue
        eng=$(echo "$line" | cut -f1); db=$(echo "$line" | cut -f2)
        step "  Database: ${db} (${eng})"
        mkdir -p "${tmp}/databases/${eng}"
        if ! db_dump_database_ex "$eng" "$db" "${tmp}/databases/${eng}/${db}.sql.gz" "$excl_tables" 2>/dev/null; then
            error "    dump failed: ${db} (${eng})"
            errors="${errors}${errors:+, }db:${db}"
            rm -f "${tmp}/databases/${eng}/${db}.sql.gz"
        elif ! _bk_check_archive "${tmp}/databases/${eng}/${db}.sql.gz"; then
            # A dump truncated by a full disk is still a non-empty file, so the
            # size check inside db_dump_database_ex cannot catch it. Storing it
            # would be worse than failing: it looks like a backup and is not.
            error "    dump is truncated or corrupt (disk full?) — discarding it"
            errors="${errors}${errors:+, }db:${db}"
            rm -f "${tmp}/databases/${eng}/${db}.sql.gz"
        fi
    done

    # ── manifest
    jq -n \
        --arg p "$p" --arg ts "$ts" --arg scope "$scope" \
        --arg host "$(hostname)" --arg ver "${CIPI_VERSION:-unknown}" \
        --argjson enc "$([[ "$encrypt" == "true" ]] && echo true || echo false)" \
        --argjson apps "$(printf '%s\n' "${apps[@]:-}" | jq -R -s 'split("\n")|map(select(length>0))')" \
        --argjson dbs "$(printf '%s\n' "${dbs[@]:-}" | jq -R -s 'split("\n")|map(select(length>0))|map(split("\t")|{engine:.[0],name:.[1]})')" \
        '{profile:$p, timestamp:$ts, scope:$scope, host:$host, cipi:$ver, encrypted:$enc, apps:$apps, databases:$dbs}' \
        > "${tmp}/manifest.json"

    # ── encrypt in place (manifest stays readable so a run can be identified)
    if [[ "$encrypt" == "true" ]]; then
        step "  Encrypting archives..."
        local f
        while IFS= read -r f; do
            [[ -n "$f" ]] || continue
            if _bk_encrypt_file "$f" "${f}.enc"; then
                rm -f "$f"
            else
                error "    encryption failed: $(basename "$f")"
                errors="${errors}${errors:+, }encrypt:$(basename "$f")"
            fi
        done < <(find "$tmp" -type f \( -name '*.tar.gz' -o -name '*.sql.gz' \) 2>/dev/null)
    fi

    # ── ship
    local dest
    while IFS= read -r dest; do
        [[ -n "$dest" ]] || continue
        case "$dest" in
            local)
                local ldir; ldir="$(_bk_local_root)/${p}/${ts}"
                mkdir -p "$ldir"
                if cp -a "${tmp}/." "$ldir/" 2>/dev/null; then
                    chmod -R go-rwx "$(_bk_local_root)" 2>/dev/null || true
                    success "  → ${ldir}"
                else
                    error "  local copy failed: ${ldir}"
                    errors="${errors}${errors:+, }dest:local"
                fi
                ;;
            *)
                # An S3 bucket or an SFTP server, by name.
                local uri
                if ! uri=$(_bk_s3_uri "$dest" "$p" "$ts"); then
                    error "  unknown destination '${dest}' — cipi backup destination list"
                    errors="${errors}${errors:+, }dest:${dest}"
                    continue
                fi
                _bk_is_sftp "$dest" || _ensure_awscli
                local s3_err
                if ! s3_err=$(_bk_aws "$dest" cp "${tmp}/" "$uri" --recursive 2>&1); then
                    error "  upload to ${dest} failed:"
                    echo "$s3_err" | sed 's/^/    /'
                    errors="${errors}${errors:+, }dest:${dest}"
                else
                    success "  → ${uri} (${dest})"
                fi
                ;;
        esac
    done <<< "$dests"

    rm -rf "$tmp"

    if [[ -n "$errors" ]]; then
        _bk_state_set "$p" "error" "$errors" "$started"
        error "Backup '${p}' completed with errors: ${errors}"
        cipi_notify \
            "Cipi backup failed: profile ${p} on $(hostname)" \
            "Backup profile '${p}' finished with errors.\n\nServer: $(hostname)\nProfile: ${p}\nRun: ${ts}\nFailed: ${errors}\nTime: $(notify_now)\n\nLog: ${CIPI_LOG}/backup.log" \
            backup_fail
        log_action "BACKUP ERROR: profile=${p} run=${ts} ${errors}"
        _bk_retention_after_run "$p"
        return 1
    fi

    _bk_state_set "$p" "ok" "${#apps[@]} app(s), ${#dbs[@]} database(s)" "$started"
    success "Backup '${p}' complete — ${#apps[@]} app(s), ${#dbs[@]} database(s)"
    log_action "BACKUP OK: profile=${p} run=${ts} apps=${#apps[@]} dbs=${#dbs[@]}"
    _bk_retention_after_run "$p"
    return 0
}

# ── Prune ────────────────────────────────────────────────────

_bk_prune() {
    _bk_require_config
    local profile="" weeks="" target="" dry=false arg
    for arg in "$@"; do
        case "$arg" in
            --profile=*) profile="${arg#--profile=}" ;;
            --weeks=*)   weeks="${arg#--weeks=}" ;;
            --dry-run)   dry=true ;;
            --*)         error "Unknown flag: ${arg}"; exit 1 ;;
            *)           target="$arg" ;;
        esac
    done

    # Legacy form: `cipi backup prune [app] --weeks=N` over the pre-5.1 layout.
    if [[ -n "$weeks" ]]; then
        _bk_prune_legacy "$target" "$weeks"
        return $?
    fi

    _BK_PRUNE_ERRORS=""
    if [[ -n "$profile" ]]; then
        _bk_profile_exists "$profile" || { error "No such profile: ${profile}"; exit 1; }
        _bk_prune_profile "$profile" "$dry"
    else
        local p
        while IFS= read -r p; do
            [[ -n "$p" ]] || continue
            _bk_prune_profile "$p" "$dry"
        done < <(_bk_profile_names)
    fi
    _bk_prune_orphans "$dry"
    if [[ -n "$_BK_PRUNE_ERRORS" ]]; then
        error "Retention incomplete: ${_BK_PRUNE_ERRORS}"
        return 1
    fi
    return 0
}

# Decide which run timestamps of a profile must go, then delete them from
# every destination. Retention is per profile: a 30-minute database profile
# keeping 48 runs coexists with a weekly full profile keeping 8 weeks.
_bk_prune_profile() {
    local p="$1" dry="${2:-false}"
    local keep days weeks
    keep=$(_bk_profiles_json  | jq -r --arg p "$p" '.[$p].retention.keep  // 0')
    days=$(_bk_profiles_json  | jq -r --arg p "$p" '.[$p].retention.days  // 0')
    weeks=$(_bk_profiles_json | jq -r --arg p "$p" '.[$p].retention.weeks // 0')
    [[ "$keep" -eq 0 && "$days" -eq 0 && "$weeks" -eq 0 ]] && return 0

    local cutoff=0 total_days=0
    [[ "$days"  -gt 0 ]] && total_days=$days
    [[ "$weeks" -gt 0 ]] && total_days=$(( total_days + weeks * 7 ))
    if [[ "$total_days" -gt 0 ]]; then
        cutoff=$(date -d "${total_days} days ago" +%s 2>/dev/null || date -v "-${total_days}d" +%s)
    fi

    # Union of run timestamps across destinations, newest first. A destination
    # that cannot be listed would make this prune nothing, silently, forever:
    # say so (the caller turns it into an alert).
    local errf runs
    errf=$(mktemp)
    runs=$(_bk_list_runs "$p" 2>"$errf" | sort -r | awk '!seen[$0]++')
    if [[ -s "$errf" ]]; then
        _BK_PRUNE_ERRORS="${_BK_PRUNE_ERRORS:-}${_BK_PRUNE_ERRORS:+; }${p}: $(paste -sd' ' "$errf")"
        warn "  Retention for '${p}' is incomplete — $(paste -sd' ' "$errf")"
    fi
    rm -f "$errf"
    [[ -z "$runs" ]] && return 0

    local idx=0 ts run_epoch drop
    while IFS= read -r ts; do
        [[ -n "$ts" ]] || continue
        ((idx++)) || true
        drop=false

        # Age rule
        if [[ "$cutoff" -gt 0 ]]; then
            local date_part="${ts%%_*}"
            run_epoch=$(date -d "$date_part" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "$date_part" +%s 2>/dev/null || echo 0)
            [[ "$run_epoch" -gt 0 && "$run_epoch" -lt "$cutoff" ]] && drop=true
        fi
        # Count rule — never drops a run that the count rule still wants.
        if [[ "$keep" -gt 0 ]]; then
            if [[ "$idx" -le "$keep" ]]; then drop=false
            elif [[ "$cutoff" -eq 0 ]]; then drop=true
            fi
        fi

        [[ "$drop" == true ]] || continue
        if [[ "$dry" == true ]]; then
            echo -e "  ${DIM}would delete${NC} ${p}/${ts}"
            continue
        fi
        _bk_delete_run "$p" "$ts"
    done <<< "$runs"
}

# Run timestamps that exist for a profile, on any destination.
_bk_list_runs() {
    local p="$1"
    local ldir; ldir="$(_bk_local_root)/${p}"
    [[ -d "$ldir" ]] && ls -1 "$ldir" 2>/dev/null | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}$' || true
    local name
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        _bk_s3_ls_dirs "$name" "$(_bk_s3_uri "$name" "$p")" \
            | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}$' || true
    done < <(_bk_s3_names)
}

# Sub-"directories" of an S3 prefix, one per line. An empty or missing prefix
# is not an error (aws exits 1 with nothing on stderr); anything else — no CLI,
# denied ListBucket, a wrong endpoint — is reported on stderr.
# Usage: _bk_s3_ls_dirs <destination> <uri>
_bk_s3_ls_dirs() {
    local name="$1" uri="$2" out errf rc=0
    if ! _bk_is_sftp "$name" && ! command -v aws &>/dev/null; then
        echo "AWS CLI not found — S3 archives cannot be listed" >&2
        return 1
    fi
    errf=$(mktemp)
    out=$(_bk_aws "$name" ls "$uri" 2>"$errf") || rc=$?
    if [[ $rc -ne 0 && -s "$errf" ]]; then
        echo "cannot list ${uri} (${name}): $(grep -v '^[[:space:]]*$' "$errf" | tail -1)" >&2
        rm -f "$errf"
        return 1
    fi
    rm -f "$errf"
    printf '%s\n' "$out" | awk '$1 == "PRE" {print $2}' | sed 's#/$##'
}

_bk_delete_run() {
    local p="$1" ts="$2"
    local ldir="$(_bk_local_root)/${p}/${ts}"
    if [[ -d "$ldir" ]]; then
        rm -rf "$ldir"
        step "  Deleted local: ${p}/${ts}"
    fi
    command -v aws &>/dev/null || return 0
    local name uri
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        uri=$(_bk_s3_uri "$name" "$p" "$ts") || continue
        if _bk_aws "$name" ls "$uri" &>/dev/null; then
            local rm_err
            if rm_err=$(_bk_aws "$name" rm "$uri" --recursive 2>&1 >/dev/null); then
                step "  Deleted S3:    ${p}/${ts}$([[ "$name" != "s3" ]] && echo " (${name})")"
            else
                error "  S3 delete failed (${name}): ${p}/${ts} — $(tail -1 <<< "$rm_err")"
                _BK_PRUNE_ERRORS="${_BK_PRUNE_ERRORS:-}${_BK_PRUNE_ERRORS:+; }${p}/${ts} (${name}): delete failed"
            fi
        fi
    done < <(_bk_s3_names)
}

# ── Orphaned archives ────────────────────────────────────────
#
# Archives no profile prunes any more, which used to pile up forever:
#   * the pre-5.1 layout, s3://<bucket>/cipi/<app>/<date…>/ — 5.1.0 turned the
#     nightly job into the `default` profile and dropped the old
#     `cipi backup prune --weeks=N` line that was their only cleanup;
#   * <local_dir>/<name>/ and s3://<bucket>/cipi/<name>/ of a profile that was
#     removed (removing a profile keeps its archives);
#   * database dumps in /var/log/cipi/backups/ — pre-deploy snapshots
#     (cipi deploy --snapshot) still land there.
# They are kept as long as the longest age-based retention of any profile, so
# nothing goes sooner than a current profile would keep it. With only count
# retention (keep: N) there is no age to go by, and they are left alone.

_bk_orphan_retention_days() {
    _bk_profiles_json | jq -r '[.[] | ((.retention.days // 0) + (.retention.weeks // 0) * 7)] | max // 0' 2>/dev/null || echo 0
}

# One clause for a cipi.yml plan line. $1 is the profile about to be removed,
# so its own retention is not counted: after the apply it is gone, and prune
# uses whatever remains. Count-only retention (keep: N) never ages archives out.
_bk_orphan_note() {
    local except="${1:-}" days
    days=$(_bk_profiles_json | jq -r --arg x "$except" \
        '[to_entries[] | select(.key != $x) | ((.value.retention.days // 0) + ((.value.retention.weeks // 0) * 7))] | max // 0' \
        2>/dev/null || echo 0)
    [[ "$days" =~ ^[0-9]+$ ]] || days=0
    if [[ "$days" -gt 0 ]]; then
        printf 'archives kept, pruned after %s days\n' "$days"
    else
        printf 'archives kept until a remaining profile sets keep_days or keep_weeks\n'
    fi
    return 0
}

_bk_date_epoch() {
    date -d "$1" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "$1" +%s 2>/dev/null || echo 0
}

# $1 = dry (true|false)
_bk_prune_orphans() {
    local dry="${1:-false}" days cutoff profiles name ts dp ep f
    days=$(_bk_orphan_retention_days)
    [[ "$days" =~ ^[0-9]+$ && "$days" -gt 0 ]] || return 0
    cutoff=$(date -d "${days} days ago" +%s 2>/dev/null || date -v "-${days}d" +%s)
    profiles=$(_bk_profile_names)

    _orphan_old() { # $1 = folder name → 0 when it is a dated run older than the cutoff
        [[ "$1" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}) ]] || return 1
        ep=$(_bk_date_epoch "${BASH_REMATCH[1]}")
        [[ "$ep" -gt 0 && "$ep" -lt "$cutoff" ]]
    }

    # local: removed profiles
    local lroot; lroot=$(_bk_local_root)
    if [[ -d "$lroot" ]]; then
        for dp in "$lroot"/*/; do
            [[ -d "$dp" ]] || continue
            name=$(basename "$dp")
            grep -Fxq "$name" <<< "$profiles" && continue
            for f in "$dp"*/; do
                [[ -d "$f" ]] || continue
                ts=$(basename "$f")
                _orphan_old "$ts" || continue
                if [[ "$dry" == true ]]; then echo -e "  ${DIM}would delete${NC} local ${name}/${ts} (orphaned)"; continue; fi
                rm -rf "$f" && step "  Deleted local: ${name}/${ts} (orphaned)"
            done
            [[ "$dry" == true ]] || rmdir "$dp" 2>/dev/null || true
        done
    fi

    # local: loose dumps (pre-5.1 layout, pre-deploy snapshots)
    for f in "${CIPI_LOG}/backups/"*.sql.gz; do
        [[ -f "$f" ]] || continue
        # <engine>_<app>_predeploy_YYYYMMDD_HHMMSS.sql.gz — the date is the
        # suffix; an app name may contain digits of its own.
        [[ "$(basename "$f")" =~ ([0-9]{4})([0-9]{2})([0-9]{2})_[0-9]{6}\.sql\.gz$ ]] \
            || [[ "$(basename "$f")" =~ ([0-9]{4})([0-9]{2})([0-9]{2}) ]] || continue
        _orphan_old "${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]}" || continue
        if [[ "$dry" == true ]]; then echo -e "  ${DIM}would delete${NC} $(basename "$f")"; continue; fi
        rm -f "$f" && step "  Deleted local: $(basename "$f")"
    done

    # S3: prefixes under cipi/ that are not a profile, on every destination
    local dn errf names runs
    errf=$(mktemp)
    while IFS= read -r dn; do
        [[ -n "$dn" ]] || continue
        : > "$errf"
        names=$(_bk_s3_ls_dirs "$dn" "$(_bk_s3_uri "$dn")" 2>"$errf") || true
        if [[ -s "$errf" ]]; then
            _BK_PRUNE_ERRORS="${_BK_PRUNE_ERRORS:-}${_BK_PRUNE_ERRORS:+; }orphans (${dn}): $(paste -sd' ' "$errf")"
            warn "  Old archives on ${dn} could not be checked — $(paste -sd' ' "$errf")"
            continue
        fi
        while IFS= read -r name; do
            [[ -n "$name" ]] || continue
            grep -Fxq "$name" <<< "$profiles" && continue
            runs=$(_bk_s3_ls_dirs "$dn" "$(_bk_s3_uri "$dn" "$name")" 2>"$errf") || true
            if [[ -s "$errf" ]]; then
                _BK_PRUNE_ERRORS="${_BK_PRUNE_ERRORS:-}${_BK_PRUNE_ERRORS:+; }cipi/${name} (${dn}): $(paste -sd' ' "$errf")"
                : > "$errf"; continue
            fi
            while IFS= read -r ts; do
                [[ -n "$ts" ]] || continue
                _orphan_old "$ts" || continue
                if [[ "$dry" == true ]]; then echo -e "  ${DIM}would delete${NC} ${dn} cipi/${name}/${ts} (orphaned)"; continue; fi
                local rm_err
                if rm_err=$(_bk_aws "$dn" rm "$(_bk_s3_uri "$dn" "$name" "$ts")" --recursive 2>&1 >/dev/null); then
                    step "  Deleted S3:    cipi/${name}/${ts} (orphaned, ${dn})"
                else
                    _BK_PRUNE_ERRORS="${_BK_PRUNE_ERRORS:-}${_BK_PRUNE_ERRORS:+; }cipi/${name}/${ts} (${dn}): delete failed"
                    error "  S3 delete failed (${dn}): cipi/${name}/${ts} — $(tail -1 <<< "$rm_err")"
                fi
            done <<< "$runs"
        done <<< "$names"
    done < <(_bk_s3_names)
    rm -f "$errf"
    unset -f _orphan_old
    return 0
}

# After a scheduled run: retention for the profile, orphans, and one alert when
# either could not do its job — a bucket that is never pruned only shows up on
# the invoice.
_bk_retention_after_run() {
    local p="$1"
    _BK_PRUNE_ERRORS=""
    _bk_prune_profile "$p" false || true
    _bk_prune_orphans false || true
    [[ -z "$_BK_PRUNE_ERRORS" ]] && return 0
    log_action "BACKUP PRUNE ERROR: profile=${p} ${_BK_PRUNE_ERRORS}"
    cipi_notify \
        "Cipi backup retention failed: profile ${p} on $(hostname)" \
        "Old backups could not be deleted, so they keep accumulating.\n\nServer: $(hostname)\nProfile: ${p}\nProblem: ${_BK_PRUNE_ERRORS}\nTime: $(notify_now)\n\nPreview what should go: cipi backup prune --dry-run" \
        backup_fail
}

# Pre-5.1 layout: s3://<bucket>/cipi/<app>/<ts>/ plus predeploy dumps in
# /var/log/cipi/backups. Kept so existing crontabs and archives still prune.
_bk_prune_legacy() {
    local target="$1" weeks="$2"
    [[ ! "$weeks" =~ ^[0-9]+$ ]] && { error "--weeks must be a positive integer"; exit 1; }
    [[ "$weeks" -eq 0 ]] && { error "--weeks must be greater than 0"; exit 1; }
    local cutoff; cutoff=$(date -d "${weeks} weeks ago" +%s 2>/dev/null || date -v "-${weeks}w" +%s)

    _prune_local() {
        local app="$1" found=0 f fname date_str file_ts
        for f in "${CIPI_LOG}/backups/${app}_"*.sql.gz "${CIPI_LOG}/backups/"*"_${app}_"*.sql.gz; do
            [[ -f "$f" ]] || continue
            fname=$(basename "$f")
            date_str=$(echo "$fname" | grep -oE '[0-9]{8}' | head -1)
            [[ -z "$date_str" ]] && continue
            file_ts=$(date -d "${date_str}" +%s 2>/dev/null || date -j -f "%Y%m%d" "${date_str}" +%s 2>/dev/null) || continue
            if [[ "$file_ts" -lt "$cutoff" ]]; then
                rm -f "$f"; step "  Deleted local: ${fname}"; found=1
            fi
        done
        [[ $found -eq 0 ]] && info "  No local dumps older than ${weeks} week(s) for '${app}'"
        return 0
    }

    _prune_s3_legacy() {
        local app="$1" found=0 folder date_str folder_ts
        _bk_has_s3 || { warn "S3 not configured — skipping S3 prune for '${app}'"; return; }
        _ensure_awscli
        local bucket; bucket=$(_bk_s3_bucket)
        while IFS= read -r folder; do
            folder=$(echo "$folder" | sed 's#/$##')
            [[ -z "$folder" ]] && continue
            date_str=$(echo "$folder" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}')
            [[ -z "$date_str" ]] && continue
            folder_ts=$(date -d "${date_str}" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "${date_str}" +%s 2>/dev/null) || continue
            if [[ "$folder_ts" -lt "$cutoff" ]]; then
                if _aws_s3 rm "s3://${bucket}/cipi/${app}/${folder}" --recursive &>/dev/null; then
                    step "  Deleted S3:   cipi/${app}/${folder}"; found=1
                else
                    error "  S3 delete failed for ${folder}"
                fi
            fi
        done < <(_aws_s3 ls "s3://${bucket}/cipi/${app}/" 2>/dev/null | awk '{print $NF}')
        [[ $found -eq 0 ]] && info "  No S3 backups older than ${weeks} week(s) for '${app}'"
        return 0
    }

    _prune_app_legacy() {
        local app="$1"
        echo -e "\n${BOLD}Pruning '${app}'${NC} ${DIM}(legacy layout, older than ${weeks} week(s))${NC}"
        _prune_local "$app"
        _prune_s3_legacy "$app"
    }

    if [[ -n "$target" ]]; then
        app_exists "$target" || { error "App not found: ${target}"; exit 1; }
        _prune_app_legacy "$target"
    else
        local apps a
        apps=$(vault_read apps.json | jq -r 'keys[]' 2>/dev/null) || true
        [[ -z "$apps" ]] && { warn "No apps found"; return 0; }
        while IFS= read -r a; do _prune_app_legacy "$a"; done <<< "$apps"
    fi
    echo ""
    success "Prune complete"
    log_action "backup prune (legacy)${target:+ $target} --weeks=${weeks}"
}

# ── List ─────────────────────────────────────────────────────

_bk_list() {
    _bk_require_config
    local profile="" arg json=false
    for arg in "$@"; do
        case "$arg" in
            --profile=*) profile="${arg#--profile=}" ;;
            --json) json=true ;;
            --*) error "Unknown flag: ${arg}"; exit 1 ;;
            *)   profile="$arg" ;;
        esac
    done

    local names
    if [[ -n "$profile" ]]; then
        _bk_profile_exists "$profile" || { error "No such profile: ${profile}"; exit 1; }
        names="$profile"
    else
        names=$(_bk_profile_names)
    fi
    if [[ "$json" == true ]]; then
        _bk_list_json "$profile"
        return 0
    fi

    local p ts n
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        echo -e "\n${BOLD}Backups — profile '${p}'${NC}"
        n=0
        while IFS= read -r ts; do
            [[ -n "$ts" ]] || continue
            ((n++)) || true
            local where=""
            [[ -d "$(_bk_local_root)/${p}/${ts}" ]] && where="local"
            if command -v aws &>/dev/null; then
                local dn
                while IFS= read -r dn; do
                    [[ -n "$dn" ]] || continue
                    _bk_aws "$dn" ls "$(_bk_s3_uri "$dn" "$p" "$ts")" &>/dev/null && where="${where}${where:+,}${dn}"
                done < <(_bk_s3_names)
            fi
            printf "  ${CYAN}%-22s${NC} %s\n" "$ts" "${where:-—}"
        done < <(_bk_list_runs "$p" | sort -r | awk '!seen[$0]++')
        [[ $n -eq 0 ]] && echo -e "  ${DIM}no runs yet${NC}"
    done <<< "$names"
    echo ""
    echo -e "  ${DIM}Download one: cipi backup fetch <profile> <timestamp>${NC}"
    echo ""
}

# ── Status / staleness ───────────────────────────────────────

# Profiles a `cipi backup run` is working on right now, one per line; "*" for
# a run of every profile. From the process table, like `cipi deploy --status`.
_bk_running() {
    local pid args
    ps axww -o pid=,args= 2>/dev/null | while read -r pid args; do
        [[ "$pid" == "$$" || "$pid" == "${BASHPID:-}" ]] && continue
        case "$args" in
            *"/cipi backup run"*)
                case " ${args#*/cipi backup run} " in *" --dry-run "*|*" --detach "*) continue ;; esac
                if [[ "$args" =~ --profile=([a-z][a-z0-9-]{1,31}) ]]; then echo "${BASH_REMATCH[1]}"; else echo "*"; fi ;;
        esac
    done | sort -u
    return 0
}

# cipi backup status --json — what a backup page is drawn from: the
# destinations (never their keys), every profile with what it covers right
# now, its last run, whether it is overdue or running, and the apps and
# databases no enabled profile takes. It only reads: no default profile is
# created and no "overdue" mail is sent, whatever asks and however often.
_bk_status_json() {
    if ! _bk_configured; then
        jq -n '{configured: false, local_dir: null, encryption_key: false, destinations: [], profiles: [],
                apps: [], databases: [], uncovered: {apps: [], databases: []}}'
        return 0
    fi
    # shellcheck source=/dev/null
    declare -f db_list_databases >/dev/null 2>&1 || source "${CIPI_LIB}/db.sh"
    local cfg state now
    cfg=$(_bk_cfg); state=$(_bk_state); now=$(date +%s)

    local all_apps all_dbs="" eng db
    all_apps=$(vault_read apps.json 2>/dev/null | jq -r 'keys[]' 2>/dev/null || true)
    for eng in mariadb pgsql; do
        db_engine_is_installed "$eng" 2>/dev/null || continue
        while IFS= read -r db; do
            [[ -n "$db" ]] && all_dbs+="${eng}"$'\t'"${db}"$'\n'
        done < <(db_list_databases "$eng" 2>/dev/null || true)
    done
    local running; running=$(_bk_running)

    local -a pj=()
    local p prof scope enabled inc_apps inc_dbs exc_dbs a cov_apps cov_dbs interval last created overdue is_running
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        prof=$(jq -c --arg p "$p" '.profiles[$p]' <<< "$cfg")
        scope=$(jq -r '.scope // "all"' <<< "$prof")
        enabled=$(jq -r 'if .enabled == false then "false" else "true" end' <<< "$prof")
        inc_apps=$(jq -r '(.apps // [])[]' <<< "$prof")
        inc_dbs=$(jq -r '(.databases // [])[]' <<< "$prof")
        exc_dbs=$(jq -r '(.exclude_databases // [])[]' <<< "$prof")
        cov_apps=""; cov_dbs=""
        if [[ "$scope" == "all" || "$scope" == "files" ]]; then
            while IFS= read -r a; do
                [[ -n "$a" ]] || continue
                _bk_glob_match "$a" "$inc_apps" && cov_apps+="${a}"$'\n'
            done <<< "$all_apps"
        fi
        if [[ "$scope" == "all" || "$scope" == "db" ]]; then
            while IFS=$'\t' read -r eng db; do
                [[ -n "$db" ]] || continue
                _bk_glob_match "$db" "$inc_dbs" || continue
                _bk_glob_match "$db" "$exc_dbs" && continue
                cov_dbs+="${eng}"$'\t'"${db}"$'\n'
            done <<< "$all_dbs"
        fi
        # Overdue by the rule of `cipi backup check`: no success within twice
        # the profile's interval, and a new profile gets that long to start.
        overdue=false
        if [[ "$enabled" == "true" ]]; then
            interval=$(jq -r '.interval_seconds // 86400' <<< "$prof"); [[ "$interval" =~ ^[0-9]+$ ]] || interval=86400
            last=$(jq -r --arg p "$p" '.[$p].last_success_epoch // 0' <<< "$state"); [[ "$last" =~ ^[0-9]+$ ]] || last=0
            created=$(jq -r '.created_at // 0' <<< "$prof"); [[ "$created" =~ ^[0-9]+$ ]] || created=0
            if [[ "$last" -eq 0 ]]; then
                [[ "$created" -gt 0 && $(( now - created )) -lt $(( interval * 2 )) ]] || overdue=true
            elif [[ $(( now - last )) -gt $(( interval * 2 )) ]]; then
                overdue=true
            fi
        fi
        is_running=false
        grep -qxF -e "$p" <<< "$running" && is_running=true
        [[ "$enabled" == "true" ]] && grep -qxF -e '*' <<< "$running" && is_running=true
        pj+=("$(jq -cn --arg name "$p" --argjson prof "$prof" --arg apps "$cov_apps" --arg dbs "$cov_dbs" \
            --argjson st "$(jq -c --arg p "$p" '.[$p] // null' <<< "$state")" \
            --argjson overdue "$overdue" --argjson running "$is_running" '
            {name: $name, scope: ($prof.scope // "all"), enabled: ($prof.enabled != false),
             cron: ($prof.cron // null), interval_seconds: ($prof.interval_seconds // null),
             apps: ($prof.apps // []), databases: ($prof.databases // []),
             exclude_databases: ($prof.exclude_databases // []), exclude_tables: ($prof.exclude_tables // []),
             destinations: ($prof.destinations // []),
             retention: {keep: ($prof.retention.keep // 0), days: ($prof.retention.days // 0), weeks: ($prof.retention.weeks // 0)},
             encrypt: ($prof.encrypt == true), created_at: ($prof.created_at // null),
             covers: {apps: ($apps | split("\n") | map(select(. != ""))),
                      databases: ($dbs | split("\n") | map(select(. != "") | split("\t") | {engine: .[0], name: .[1]}))},
             last: (if $st == null then null else
                 {status: ($st.status // null), detail: ($st.detail // null),
                  started_at: ($st.last_start // null), finished_at: ($st.last_end // null),
                  epoch: ($st.last_epoch // null), last_success_epoch: ($st.last_success_epoch // null)} end),
             overdue: $overdue, running: $running}')")
    done < <(jq -r '(.profiles // {}) | keys[]' <<< "$cfg")

    local profiles_json="[]" key=false
    [[ ${#pj[@]} -gt 0 ]] && profiles_json=$(printf '%s\n' "${pj[@]}" | jq -cs .)
    [[ -f "$BACKUP_KEY_FILE" ]] && key=true
    jq -n --argjson cfg "$cfg" --argjson profiles "$profiles_json" --argjson key "$key" \
        --arg local "$(_bk_local_root)" --arg apps "$all_apps" --arg dbs "$all_dbs" '
        def nz: if . == null or . == "" then null else . end;
        ($apps | split("\n") | map(select(. != ""))) as $A
        | ($dbs | split("\n") | map(select(. != "") | split("\t") | {engine: .[0], name: .[1]})) as $D
        | ($profiles | map(select(.enabled))) as $on
        | {configured: true, local_dir: $local, encryption_key: $key,
           destinations: (
               [{name: "local", type: "local", path: $local, default: false}]
               + (if ($cfg.bucket // "") != "" then
                    [{name: "s3", type: "s3", bucket: $cfg.bucket, region: ($cfg.region // "eu-central-1"),
                      endpoint: ($cfg.endpoint_url | nz), default: false}] else [] end)
               + (($cfg.s3_destinations // {}) | to_entries | map(
                    {name: .key, type: "s3", bucket: (.value.bucket // null), region: (.value.region | nz),
                     endpoint: (.value.endpoint_url | nz), default: false}))
               + (($cfg.sftp_destinations // {}) | to_entries | map(
                    {name: .key, type: "sftp", host: (.value.host // null), port: (.value.port // 22),
                     user: (.value.user // null), path: (.value.path | nz), default: false}))
               | map(. as $d | . + {profiles: [$profiles[] | select(.destinations | index($d.name) != null) | .name]})),
           profiles: $profiles, apps: $A, databases: $D,
           uncovered: {
               apps: ($A - ([$on[].covers.apps[]] | unique)),
               databases: ($D - ([$on[].covers.databases[]] | unique))}}'
    return 0
}

# cipi backup list --json [--profile=NAME] — the runs each destination holds,
# newest first. One listing per profile and bucket, not one per run.
_bk_list_json() {   # [profile]
    local only="${1:-}" names p ts dn errs="" errf out
    if [[ -n "$only" ]]; then names="$only"; else names=$(_bk_profile_names); fi
    errf=$(mktemp) || return 1
    local -a pj=()
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        local -A where=()
        local ldir; ldir="$(_bk_local_root)/${p}"
        if [[ -d "$ldir" ]]; then
            while IFS= read -r ts; do
                [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}$ ]] && where["$ts"]="local"
            done < <(ls -1 "$ldir" 2>/dev/null || true)
        fi
        while IFS= read -r dn; do
            [[ -n "$dn" ]] || continue
            : > "$errf"
            out=$(_bk_s3_ls_dirs "$dn" "$(_bk_s3_uri "$dn" "$p")" 2>"$errf" || true)
            [[ -s "$errf" ]] && errs+="$(tail -1 "$errf")"$'\n'
            while IFS= read -r ts; do
                [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}$ ]] || continue
                where["$ts"]="${where["$ts"]:-}${where["$ts"]:+,}${dn}"
            done <<< "$out"
        done < <(_bk_s3_names)
        local rows=""
        for ts in "${!where[@]}"; do rows+="${ts}"$'\t'"${where["$ts"]}"$'\n'; done
        pj+=("$(jq -cn --arg p "$p" --arg rows "$rows" '
            {key: $p, value: ($rows | split("\n") | map(select(. != "") | split("\t")
                | {run: .[0], destinations: (.[1] | split(","))}) | sort_by(.run) | reverse)}')")
        unset where
    done <<< "$names"
    rm -f "$errf"
    local body="[]"
    [[ ${#pj[@]} -gt 0 ]] && body=$(printf '%s\n' "${pj[@]}" | jq -cs .)
    jq -n --argjson e "$body" --arg errs "$errs" \
        '{profiles: ($e | from_entries), errors: ($errs | split("\n") | map(select(. != "")) | unique)}'
    return 0
}

_bk_status() {
    local _a
    for _a in "$@"; do
        [[ "$_a" == "--json" ]] && { _bk_status_json; return; }
    done
    _bk_configured || {
        echo -e "\n${BOLD}Backup${NC}"
        echo -e "  ${YELLOW}Not configured${NC} — run: ${CYAN}cipi backup configure${NC}\n"
        return 0
    }
    local cfg; cfg=$(_bk_cfg)
    echo -e "\n${BOLD}Backup destinations${NC}"
    local bucket ep
    bucket=$(echo "$cfg" | jq -r '.bucket // ""')
    ep=$(echo "$cfg" | jq -r '.endpoint_url // ""')
    tbl_start
    if [[ -n "$bucket" ]]; then
        tbl_row "S3 (s3)" "${GREEN}configured${NC}" "s3://${bucket}${ep:+  (${ep})}"
    else
        tbl_row "S3 (s3)" "${DIM}not configured${NC}"
    fi
    # Named destinations (cipi backup destination add)
    local dn dj
    while IFS= read -r dn; do
        [[ -n "$dn" && "$dn" != "s3" ]] || continue
        dj=$(_bk_s3_json "$dn")
        ep=$(echo "$dj" | jq -r '.endpoint_url // ""')
        tbl_row "$dn" "${GREEN}configured${NC}" "s3://$(echo "$dj" | jq -r '.bucket // ""')${ep:+  (${ep})}"
    done < <(_bk_s3_names)
    tbl_row "Local" "$(_bk_local_root)"
    if [[ -f "$BACKUP_KEY_FILE" ]]; then
        tbl_row "Encryption key" "${GREEN}present${NC}" "$BACKUP_KEY_FILE"
    else
        tbl_row "Encryption key" "${DIM}not created${NC}"
    fi
    tbl_print
    _bk_profile_list
    _bk_check_stale --report
}

# A profile that has not succeeded within twice its own interval is overdue.
# Run hourly from cron with --quiet: it only speaks up when something is wrong.
_bk_check_stale() {
    local quiet=false report=false arg
    for arg in "$@"; do
        case "$arg" in
            --quiet)  quiet=true ;;
            --report) report=true ;;
        esac
    done
    _bk_configured || return 0

    local state now p interval last grace overdue_list=""
    state=$(_bk_state); now=$(date +%s)

    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        [[ "$(_bk_profile_get "$p" enabled)" == "false" ]] && continue
        interval=$(_bk_profiles_json | jq -r --arg p "$p" '.[$p].interval_seconds // 86400')
        [[ "$interval" =~ ^[0-9]+$ ]] || interval=86400
        grace=$(( interval * 2 ))
        last=$(echo "$state" | jq -r --arg p "$p" '.[$p].last_success_epoch // 0')
        [[ "$last" =~ ^[0-9]+$ ]] || last=0

        if [[ "$last" -eq 0 ]]; then
            # A profile created five minutes ago has not yet "failed" to run a
            # nightly backup. Only complain once its first scheduled run should
            # plausibly have happened.
            local created
            created=$(_bk_profiles_json | jq -r --arg p "$p" '.[$p].created_at // 0')
            [[ "$created" =~ ^[0-9]+$ ]] || created=0
            if [[ "$created" -gt 0 && $(( now - created )) -lt "$grace" ]]; then
                continue
            fi
            overdue_list="${overdue_list}${overdue_list:+, }${p} (never succeeded)"
        elif [[ $(( now - last )) -gt "$grace" ]]; then
            overdue_list="${overdue_list}${overdue_list:+, }${p} (last success $(( (now - last) / 3600 ))h ago)"
        fi
    done < <(_bk_profile_names)

    if [[ -z "$overdue_list" ]]; then
        [[ "$quiet" == true ]] && return 0
        [[ "$report" == true ]] && echo -e "  ${GREEN}All profiles have run within their expected window.${NC}\n"
        [[ "$report" == false ]] && success "All backup profiles are up to date"
        return 0
    fi

    if [[ "$report" == true ]]; then
        echo -e "  ${YELLOW}Overdue:${NC} ${overdue_list}\n"
    else
        warn "Overdue backup profiles: ${overdue_list}"
    fi
    cipi_notify \
        "Cipi backup overdue on $(hostname)" \
        "One or more backup profiles have not completed successfully within their expected window.\n\nServer: $(hostname)\nOverdue: ${overdue_list}\nTime: $(notify_now)\n\nCheck: cipi backup status" \
        backup_stale
    return 0
}

# ── Verify ───────────────────────────────────────────────────
#
# An archive that cannot be opened is not a backup. Verify reads the newest run
# of each profile back and checks every member decompresses.

_bk_verify() {
    _bk_require_config
    local profile="" deep=false arg
    for arg in "$@"; do
        case "$arg" in
            --profile=*) profile="${arg#--profile=}" ;;
            --deep)      deep=true ;;
            --*) error "Unknown flag: ${arg}"; exit 1 ;;
            *)   profile="$arg" ;;
        esac
    done

    local names
    if [[ -n "$profile" ]]; then
        _bk_profile_exists "$profile" || { error "No such profile: ${profile}"; exit 1; }
        names="$profile"
    else
        names=$(_bk_profile_names)
    fi

    local failed=0 checked=0 p ts
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        ts=$(_bk_list_runs "$p" | sort -r | head -1)
        if [[ -z "$ts" ]]; then
            warn "Profile '${p}': no runs to verify yet"
            continue
        fi
        ((checked++)) || true
        echo -e "\n${BOLD}Verifying ${p}/${ts}${NC}"
        _bk_verify_run "$p" "$ts" "$deep" || failed=1
    done <<< "$names"
    echo ""
    if [[ $failed -ne 0 ]]; then
        error "Verification failed — see above"
        return 1
    fi
    if [[ $checked -eq 0 ]]; then
        # Saying "passed" after checking nothing is a false reassurance.
        warn "Nothing was verified — no profile has produced a backup yet."
        info "Take one now: cipi backup run"
        return 0
    fi
    success "Verification passed (${checked} profile(s))"
}

_bk_verify_run() {
    local p="$1" ts="$2" deep="$3"
    local dir="$(_bk_local_root)/${p}/${ts}" cleanup=""

    if [[ ! -d "$dir" ]]; then
        [[ -n "$(_bk_s3_names)" ]] || { error "  no local copy and no remote destination configured"; return 1; }
        _bk_ensure_remote_tools
        local dn uri
        dn=$(_bk_s3_find_run "$p" "$ts") || { error "  run not found on any remote destination"; return 1; }
        uri=$(_bk_s3_uri "$dn" "$p" "$ts")
        if [[ "$deep" != true ]]; then
            # No local copy: check the remote objects exist and are non-empty
            # without paying to download them.
            local listing
            listing=$(_bk_aws "$dn" ls "$uri" --recursive 2>/dev/null || true)
            [[ -z "$listing" ]] && { error "  run not found on ${dn}"; return 1; }
            local empty
            empty=$(echo "$listing" | awk '$3 == 0 {print $4}')
            if [[ -n "$empty" ]]; then
                error "  zero-byte objects:"; echo "$empty" | sed 's/^/    /'; return 1
            fi
            success "  $(echo "$listing" | wc -l) object(s) present on ${dn}, none empty"
            info  "  Use --deep to download and decompress them"
            return 0
        fi
        dir="$(_bk_tmp_base)/cipi-verify-${p}-${ts}"
        cleanup="$dir"
        mkdir -p "$dir"
        step "  Downloading from ${dn}..."
        _bk_aws "$dn" cp "$uri" "$dir/" --recursive &>/dev/null \
            || { error "  download failed"; rm -rf "$cleanup"; return 1; }
    fi

    local rc=0 f name tmpf
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        name="${f#"${dir}/"}"
        tmpf=""
        if [[ "$f" == *.enc ]]; then
            tmpf=$(mktemp)
            if ! _bk_decrypt_file "$f" "$tmpf" 2>/dev/null; then
                error "  decrypt failed: ${name}"; rm -f "$tmpf"; rc=1; continue
            fi
            f="$tmpf"
        fi
        if [[ "$name" == *.tar.gz* ]]; then
            tar -tzf "$f" &>/dev/null && success "  ok: ${name}" || { error "  corrupt archive: ${name}"; rc=1; }
        elif [[ "$name" == *.sql.gz* ]]; then
            gzip -t "$f" &>/dev/null && success "  ok: ${name}" || { error "  corrupt dump: ${name}"; rc=1; }
        fi
        [[ -n "$tmpf" ]] && rm -f "$tmpf"
    done < <(find "$dir" -type f \( -name '*.tar.gz*' -o -name '*.sql.gz*' \) 2>/dev/null)

    [[ -n "$cleanup" ]] && rm -rf "$cleanup"
    return $rc
}

# ── Fetch ────────────────────────────────────────────────────
#
# Download (and decrypt) one run so it can be inspected or restored by hand.
# Restoring is deliberately manual: `cipi db restore` takes it from here.

_bk_fetch() {
    _bk_require_config
    local p="${1:-}" ts="${2:-}"; shift 2 2>/dev/null || true
    [[ -z "$p" || -z "$ts" ]] && { error "Usage: cipi backup fetch <profile> <timestamp> [--dest=<dir>]"; exit 1; }
    _bk_profile_exists "$p" || { error "No such profile: ${p}"; exit 1; }
    parse_args "$@"

    local dest="${ARG_dest:-$(_bk_tmp_base)/cipi-restore-${p}-${ts}}"
    mkdir -p "$dest" || { error "Cannot create ${dest}"; exit 1; }

    local src="$(_bk_local_root)/${p}/${ts}"
    if [[ -d "$src" ]]; then
        step "Copying local run ${p}/${ts}..."
        cp -a "${src}/." "${dest}/" || { error "Copy failed"; exit 1; }
    else
        [[ -n "$(_bk_s3_names)" ]] || { error "Run not found locally and no remote destination configured"; exit 1; }
        _bk_ensure_remote_tools
        local dn uri
        dn=$(_bk_s3_find_run "$p" "$ts") || {
            rmdir "$dest" 2>/dev/null || true
            error "No backup found at ${p}/${ts} on any destination — nothing was downloaded."
            info "List what exists:  cipi backup list ${p}"
            exit 1
        }
        uri=$(_bk_s3_uri "$dn" "$p" "$ts")
        step "Downloading ${uri} (${dn})..."
        _bk_aws "$dn" cp "$uri" "${dest}/" --recursive &>/dev/null \
            || { error "Download failed — check the profile and timestamp (cipi backup list ${p})"; exit 1; }
    fi

    # `aws s3 cp --recursive` exits 0 when the prefix holds no objects, so a
    # wrong timestamp would otherwise be reported as a successful restore of an
    # empty directory. Never claim a backup is available without seeing it.
    if [[ -z "$(find "$dest" -type f -print -quit 2>/dev/null)" ]]; then
        rmdir "$dest" 2>/dev/null || true
        error "No backup found at ${p}/${ts} — nothing was downloaded."
        info "List what exists:  cipi backup list ${p}"
        exit 1
    fi
    if [[ ! -f "${dest}/manifest.json" ]]; then
        warn "This run has no manifest.json — it may be incomplete or from an older Cipi."
    fi

    local n=0 f
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        if _bk_decrypt_file "$f" "${f%.enc}" 2>/dev/null; then
            rm -f "$f"; ((n++)) || true
        else
            error "Could not decrypt $(basename "$f") — is ${BACKUP_KEY_FILE} the key it was written with?"
            exit 1
        fi
    done < <(find "$dest" -type f -name '*.enc' 2>/dev/null)
    [[ $n -gt 0 ]] && success "Decrypted ${n} file(s)"

    echo ""
    success "Backup available at: ${dest}"
    echo ""
    echo -e "  ${BOLD}Restore a database${NC}"
    echo -e "    ${CYAN}cipi db restore <name> ${dest}/databases/<engine>/<name>.sql.gz${NC}"
    echo -e "  ${BOLD}Inspect application files${NC}"
    echo -e "    ${CYAN}tar -tzf ${dest}/apps/<app>/files.tar.gz${NC}"
    echo ""
    warn "This directory holds decrypted data — delete it when you are done."
    echo ""
}

# ── Configure ────────────────────────────────────────────────

# cipi backup configure: backups on this server — the local folder, the temp
# folder, and a nightly profile `default` (every app and database, kept here).
# Sending them elsewhere too — S3 buckets and SFTP servers, on a par — is
# `cipi backup destination add <name>`; at a terminal this offers it right
# away, and sends the nightly profile there as well. Without a terminal it
# sets up the defaults and asks nothing (the panel).
#   --local-dir= --tmpdir=     the folders (at the server's shell only)
#   --local-only               5.19.0's: the same, nothing else is set up
#   --bucket= --key= --secret=|--secret-stdin [--region=] [--endpoint=]
#                              before 5.19.1 configure's own bucket: the same as
#                              `destination add|edit s3 …`, and the nightly
#                              profile of a first setup is sent there too
#   --json                     {configured, local_dir, profile_created}
_bk_configure() {
    parse_args "$@"
    local was_configured=false; _bk_configured && was_configured=true
    local ct="/var/tmp" cl=""
    if [[ "$was_configured" == true ]]; then
        local _bkj; _bkj=$(_bk_cfg)
        ct=$(echo "$_bkj" | jq -r '.tmpdir // "/var/tmp"')
        cl=$(echo "$_bkj" | jq -r '.local_dir // ""')
    fi
    # --json: the answer alone on standard output, everything said on stderr.
    local json=false; [[ "${ARG_json:-}" == "true" ]] && { json=true; exec 3>&1 1>&2; }

    local from_panel=false; [[ "${SUDO_USER:-}" == "www-data" ]] && from_panel=true
    if [[ "$from_panel" == true ]]; then
        # Folders are the server's to choose: root creates the local one and
        # makes it 0700 — a path from the panel could be any directory.
        [[ -z "${ARG_local_dir+x}" && -z "${ARG_tmpdir+x}" ]] || { error "The local and temp directories are set at the server's shell: cipi backup configure"; exit 1; }
    fi
    local flagged=false bucket_flags=false f
    for f in bucket key secret secret_stdin region endpoint; do
        [[ -n "$(eval "echo \${ARG_${f}+x}")" ]] && bucket_flags=true
    done
    for f in local_dir tmpdir local_only json; do
        [[ -n "$(eval "echo \${ARG_${f}+x}")" ]] && flagged=true
    done
    [[ "$bucket_flags" == true ]] && flagged=true
    local interactive=false
    [[ "$flagged" == false && -t 0 && "$from_panel" == false ]] && interactive=true

    [[ -n "${ARG_local_dir+x}" ]] && cl="${ARG_local_dir}"
    [[ -n "${ARG_tmpdir+x}" ]] && ct="${ARG_tmpdir}"
    if [[ "$interactive" == true ]]; then
        echo -e "\n${BOLD}Backups on this server${NC} ${DIM}— S3 buckets and SFTP servers can be added next${NC}\n"
        echo -e "  ${DIM}Where local copies are kept.${NC}"
        read_input "Local backup directory" "${cl:-$BACKUP_DEFAULT_LOCAL}" cl
        echo -e "  ${DIM}Temp directory for backup archives (must have enough disk space; /tmp is often RAM-backed).${NC}"
        read_input "Temp directory" "$ct" ct
    fi
    ct="${ct:-/var/tmp}"
    cl="${cl:-$BACKUP_DEFAULT_LOCAL}"
    [[ "$cl" == /* && "$cl" != *..* && "$cl" =~ ^[A-Za-z0-9._/-]+$ ]] || { error "Invalid local directory '${cl}' (an absolute path)"; exit 1; }
    [[ "$ct" == /* && "$ct" != *..* && "$ct" =~ ^[A-Za-z0-9._/-]+$ ]] || { error "Invalid temp directory '${ct}' (an absolute path)"; exit 1; }

    # The folders change; destinations and profiles stay as they are.
    _bk_cfg | jq --arg t "$ct" --arg l "$cl" '
        {aws_key: "", aws_secret: "", bucket: "", region: "eu-central-1", endpoint_url: "",
         s3_destinations: {}, sftp_destinations: {}, profiles: {}} + . + {tmpdir: $t, local_dir: $l}' | _bk_cfg_write
    mkdir -p "$cl" && chmod 700 "$cl" 2>/dev/null || true

    # Before 5.19.1 configure took the bucket: it is the S3 destination "s3".
    local -a added=()
    if [[ "$bucket_flags" == true ]]; then
        local smode=add; _bk_has_s3 && smode=edit
        ( _BK_IN_CONFIGURE=1 _bk_destination_add "$smode" s3 "$@" ) || exit 1
        added+=(s3)
    fi

    local created=false
    _bk_ensure_default_profile "${added[@]}" && created=true
    _bk_write_cron
    log_action "BACKUP CONFIGURED: local ${cl}"
    [[ "$was_configured" == true ]] || _bk_notify_change "Backups were set up on this server (${cl})"
    success "Backups set up on this server: ${cl}"

    # At a terminal: S3 buckets and SFTP servers, as many as wanted.
    if [[ "$interactive" == true ]]; then
        local more dn
        while true; do
            echo ""
            echo -e "  ${DIM}A copy only on this server is lost with the server.${NC}"
            read_choice "Send the backups somewhere else too?" "none" more \
                "none|No — only on this server, for now" \
                "s3|An S3 bucket — AWS, Hetzner, Cloudflare R2, DigitalOcean, Backblaze, Scaleway, MinIO…" \
                "sftp|An SFTP server — a VPS with a backup user, a Hetzner Storage Box, a NAS"
            [[ "$more" == "s3" || "$more" == "sftp" ]] || break
            dn=$(_bk_suggest_dest_name "$more")
            read_input "Its name in profiles" "$dn" dn
            if [[ "$more" == "sftp" ]]; then
                ( _BK_IN_CONFIGURE=1 _bk_destination_add add "$dn" --type=sftp ) || { warn "Not added"; continue; }
            else
                ( _BK_IN_CONFIGURE=1 _bk_destination_add add "$dn" ) || { warn "Not added"; continue; }
            fi
            if _bk_profile_exists default && confirm_yes "Send the profile 'default' there too?"; then
                _bk_use_dest "$dn" default
            fi
            if [[ "$more" == "sftp" ]] && confirm "The key installed on the remote? Test the connection now"; then
                local err
                if err=$(_bk_sftp_probe "$dn" 2>&1); then success "SFTP connection OK"; else warn "Not reachable yet: ${err}"; info "Test it later: cipi backup destination test ${dn}"; fi
            fi
        done
    fi

    echo ""
    echo -e "  ${DIM}The schedule is managed for you — no crontab editing needed.${NC}"
    echo -e "  ${DIM}Review it:            ${CYAN}cipi backup status${NC}"
    echo -e "  ${DIM}Add an S3 bucket:     ${CYAN}cipi backup destination add <name> --bucket=<b> --key=<id> --secret-stdin [--endpoint=<url>] --use=default${NC}"
    echo -e "  ${DIM}Or an SFTP server:    ${CYAN}cipi backup destination add <name> --type=sftp --host=<host> --user=<user> [--port=23] --use=default${NC}"
    echo -e "  ${DIM}Another strategy:     ${CYAN}cipi backup profile add hourly-db --scope=db --every=30m --keep=48 --dest=local${NC}"
    echo ""

    if [[ "$json" == true ]]; then
        jq -n --arg l "$cl" --argjson c "$created" '{configured: true, local_dir: $l, profile_created: $c}' >&3
    fi
}

# A free name for a new destination: s3, offsite… / sftp, box…
_bk_suggest_dest_name() {   # <s3|sftp>
    local c
    for c in $([[ "$1" == "sftp" ]] && echo "sftp box backup-box sftp2 sftp3" || echo "s3 offsite bucket s3-2 s3-3"); do
        [[ "$c" == "s3" && "$1" == "sftp" ]] && continue
        _bk_s3_exists "$c" || { echo "$c"; return; }
    done
    echo ""
}

# A secret asked at a terminal: not shown as it is typed; Enter keeps the current one.
_bk_read_secret() {   # <prompt> <var>
    local prompt="$1" var="$2" cur="${!2:-}" input=""
    if [[ -n "$cur" ]]; then echo -e -n "${CYAN}${prompt}${NC} [keep the current one]: "
    else echo -e -n "${CYAN}${prompt}${NC}: "; fi
    read -rs input || input=""
    echo ""
    printf -v "$var" '%s' "${input:-$cur}"
}

# ── Named S3 destinations CLI ────────────────────────────────

# cipi backup sftp add|edit|key|test|remove <name> …: SFTP destinations only —
# what the panel may run (an S3 destination takes a secret, at the shell).
_bk_sftp_command() {
    local sub="${1:-}"; shift || true
    local name="${1:-}"
    case "$sub" in
        add|edit)
            ARG_type=sftp
            _bk_destination_add "$sub" "$@" --type=sftp ;;
        key)    _bk_destination_key "$@" ;;
        test)   _bk_is_sftp "$name" || { error "'${name}' is not an SFTP destination"; exit 1; }; _bk_destination_test "$name" ;;
        remove|rm|delete)
            _bk_is_sftp "$name" || { error "'${name}' is not an SFTP destination"; exit 1; }
            _bk_destination_remove "$name" ;;
        *) error "Use: cipi backup sftp add|edit <name> --host=H --user=U [--port=22] [--path=DIR] [--test] [--json] | key|test|remove <name>"; exit 1 ;;
    esac
}

_bk_destination_command() {
    local sub="${1:-list}"; shift||true
    case "$sub" in
        list|ls)   _bk_destination_list ;;
        show)      _bk_destination_show "$@" ;;
        add|edit)  _bk_destination_add "$sub" "$@" ;;
        remove|rm|delete) _bk_destination_remove "$@" ;;
        test)      _bk_destination_test "$@" ;;
        key)       _bk_destination_key "$@" ;;
        *) error "Use: cipi backup destination list|show|add|edit|remove|test|key"; exit 1 ;;
    esac
}

_bk_destination_list() {
    _bk_require_config
    local names; names=$(_bk_s3_names)
    echo -e "\n${BOLD}Backup destinations${NC}"
    tbl_start
    tbl_row "${CYAN}local${NC}" "$(_bk_local_root)"
    local dn dj b ep used
    while IFS= read -r dn; do
        [[ -n "$dn" ]] || continue
        dj=$(_bk_s3_json "$dn")
        used=$(_bk_dest_profiles "$dn" | paste -sd, -)
        if [[ "$(jq -r '.type // ""' <<< "$dj")" == sftp ]]; then
            tbl_row "${CYAN}${dn}${NC}" "sftp://$(jq -r '.user' <<< "$dj")@$(jq -r '.host' <<< "$dj"):$(jq -r '.port // 22' <<< "$dj")/$(jq -r '.path // ""' <<< "$dj")${used:+  ${DIM}← ${used}${NC}}"
            continue
        fi
        b=$(echo "$dj" | jq -r '.bucket // ""'); ep=$(echo "$dj" | jq -r '.endpoint_url // ""')
        tbl_row "${CYAN}${dn}${NC}" "s3://${b}${ep:+  (${ep})}${used:+  ${DIM}← ${used}${NC}}"
    done <<< "$names"
    tbl_print
    echo ""
    if [[ -z "$names" ]]; then
        echo -e "  ${DIM}Only on this server: a copy here is lost with it. Add an S3 bucket or an SFTP server:${NC}"
    else
        echo -e "  ${DIM}A profile names any of these: --dest=local,<name>[,<name>]${NC}"
    fi
    echo -e "  ${DIM}Add S3:   cipi backup destination add <name> --bucket=<b> --key=<id> --secret-stdin [--region=] [--endpoint=] [--use=<profile>]${NC}"
    echo -e "  ${DIM}Add SFTP: cipi backup destination add <name> --type=sftp --host=<h> --user=<u> [--port=22] [--path=<dir>] [--use=<profile>]${NC}"
    echo ""
}

_bk_destination_show() {
    local n="${1:-}"
    [[ -z "$n" ]] && { error "Usage: cipi backup destination show <name>"; exit 1; }
    _bk_require_config
    _bk_s3_exists "$n" || { error "No such destination: ${n}"; exit 1; }
    local dj k ep used
    dj=$(_bk_s3_json "$n")
    if _bk_is_sftp "$n"; then
        used=$(_bk_dest_profiles "$n" | paste -sd, -)
        echo -e "\n${BOLD}Backup destination '${n}'${NC} ${DIM}(SFTP)${NC}"
        printf "  %-14s %s\n" "Host"    "$(jq -r '.host' <<< "$dj")"
        printf "  %-14s %s\n" "Port"    "$(jq -r '.port // 22' <<< "$dj")"
        printf "  %-14s %s\n" "User"    "$(jq -r '.user' <<< "$dj")"
        printf "  %-14s %s\n" "Folder"  "$(jq -r '.path // "" | if . == "" then "(the login'"'"'s home)" else . end' <<< "$dj")"
        printf "  %-14s %s\n" "Key"     "$(_bk_sftp_key "$n")"
        printf "  %-14s %s\n" "Used by" "${used:-—}"
        echo -e "\n  ${DIM}Public key to accept on the remote:${NC}\n  $(_bk_sftp_pubkey "$n")\n"
        return 0
    fi
    k=$(echo "$dj" | jq -r '.aws_key // ""')
    ep=$(echo "$dj" | jq -r '.endpoint_url // ""')
    used=$(_bk_dest_profiles "$n" | paste -sd, -)
    echo -e "\n${BOLD}Backup destination '${n}'${NC} ${DIM}(S3)${NC}"
    printf "  %-14s %s\n" "Bucket"     "$(echo "$dj" | jq -r '.bucket // ""')"
    printf "  %-14s %s\n" "Region"     "$(echo "$dj" | jq -r '.region // "eu-central-1"')"
    printf "  %-14s %s\n" "Endpoint"   "${ep:-AWS S3}"
    if [[ -n "$k" ]]; then
        printf "  %-14s %s\n" "Access key" "${k:0:4}…${k: -4}"
    else
        printf "  %-14s %s\n" "Access key" "— (default credential chain)"
    fi
    printf "  %-14s %s\n" "Used by"    "${used:-—}"
    echo ""
}

# add: every value may come as a flag, the rest is asked on a terminal. The
# bucket is listed before anything is saved: a destination that cannot be
# reached would fail every run of every profile that names it.
_bk_destination_add() {
    local mode="$1"; shift||true
    local name="${1:-}"; shift||true
    [[ -z "$name" ]] && { error "Usage: cipi backup destination ${mode} <name> [--bucket=B] [--key=K] [--secret-stdin] [--region=R] [--endpoint=URL] | --type=sftp --host=H --user=U [--port=22] [--path=DIR]  [--use=<profile>]"; exit 1; }
    _bk_require_config
    _bk_valid_dest_name "$name" || { error "Invalid destination name '${name}' (lowercase letters, digits and dashes, 2-32 chars; 'local' is this server)"; exit 1; }
    parse_args "$@"
    if [[ "${ARG_type:-}" == "sftp" ]] || { [[ "$mode" == "edit" ]] && _bk_is_sftp "$name"; }; then
        [[ "$name" == "s3" ]] && { error "'s3' is kept for an S3 bucket — give the SFTP server another name"; exit 1; }
        _bk_destination_add_sftp "$mode" "$name"
        return $?
    fi
    [[ -z "${ARG_type:-}" || "${ARG_type}" == "s3" ]] || { error "--type is s3 (when not given) or sftp"; exit 1; }
    # The secret first: --secret-stdin is the first thing read from stdin.
    local s_given errf
    errf=$(mktemp) || exit 1
    s_given=$(_bk_secret_given 2>"$errf") || { error "$(cat "$errf" 2>/dev/null)"; rm -f "$errf"; exit 1; }
    rm -f "$errf"

    local cur="{}"
    if _bk_s3_exists "$name"; then
        [[ "$mode" == "add" ]] && { error "Destination '${name}' already exists — use: cipi backup destination edit ${name} ..."; exit 1; }
        cur=$(_bk_s3_json "$name")
    else
        [[ "$mode" == "edit" ]] && { error "No such destination: ${name}"; exit 1; }
    fi
    local b k s r e
    b="${ARG_bucket:-$(echo "$cur" | jq -r '.bucket // ""')}"
    k="${ARG_key:-$(echo "$cur" | jq -r '.aws_key // ""')}"
    s="${s_given:-$(echo "$cur" | jq -r '.aws_secret // ""')}"
    r="${ARG_region:-$(echo "$cur" | jq -r '.region // ""')}"
    e="${ARG_endpoint:-$(echo "$cur" | jq -r '.endpoint_url // ""')}"
    [[ "${ARG_endpoint:-}" == "none" ]] && e=""

    if [[ -t 0 && "${ARG_secret_stdin:-}" != "true" && "${ARG_json:-}" != "true" && "${SUDO_USER:-}" != "www-data" ]]; then
        echo -e "\n${BOLD}S3 bucket '${name}'${NC} ${DIM}— reached with these keys before anything is saved${NC}"
        [[ -z "${ARG_bucket+x}" ]] && read_input "Bucket name" "$b" b
        [[ -z "${ARG_key+x}" ]]    && read_input "Access Key ID" "$k" k
        [[ -z "${ARG_secret+x}" ]] && _bk_read_secret "Secret Access Key" s
        [[ -z "${ARG_region+x}" ]] && read_input "Region" "${r:-eu-central-1}" r
        if [[ -z "${ARG_endpoint+x}" ]]; then
            echo -e "  ${DIM}Leave empty for AWS S3. Any other S3-compatible provider needs its endpoint URL:${NC}"
            echo -e "  ${DIM}  Hetzner:        https://<location>.your-objectstorage.com${NC}"
            echo -e "  ${DIM}  Cloudflare R2:  https://<account-id>.r2.cloudflarestorage.com   (region: auto)${NC}"
            echo -e "  ${DIM}  DO Spaces:      https://<region>.digitaloceanspaces.com${NC}"
            echo -e "  ${DIM}  Backblaze B2:   https://s3.<region>.backblazeb2.com${NC}"
            echo -e "  ${DIM}  Scaleway:       https://s3.<region>.scw.cloud${NC}"
            echo -e "  ${DIM}  MinIO, others:  https://your-host${NC}"
            read_input "Endpoint URL (optional)" "$e" e
        fi
    fi
    [[ -z "$b" ]] && { error "A bucket is required (--bucket=<name>)"; exit 1; }
    r="${r:-eu-central-1}"
    _bk_valid_bucket "$b" || { error "Invalid bucket name '${b}'"; exit 1; }
    _bk_valid_region "$r" || { error "Invalid region '${r}'"; exit 1; }
    _bk_valid_endpoint "$e" || { error "Invalid endpoint URL '${e}'"; exit 1; }
    [[ -n "$k" && -n "$s" ]] || { error "An access key and a secret key are required (--key=… and --secret-stdin)"; exit 1; }
    # Checked when they change (what was saved before 5.19 stays as it is).
    [[ "$k" == "$(echo "$cur" | jq -r '.aws_key // ""')" ]] || _bk_valid_s3_cred "$k" || { error "Invalid access key: printable characters, no space, no quote"; exit 1; }
    [[ "$s" == "$(echo "$cur" | jq -r '.aws_secret // ""')" ]] || _bk_valid_s3_cred "$s" || { error "Invalid secret key: printable characters, no space, no quote"; exit 1; }

    local dj
    dj=$(jq -n --arg b "$b" --arg k "$k" --arg s "$s" --arg r "$r" --arg e "$e" \
        --argjson c "$(echo "$cur" | jq '.created_at // (now | floor)')" \
        '{bucket:$b, aws_key:$k, aws_secret:$s, region:$r, endpoint_url:$e, created_at:$c}')

    _ensure_awscli
    [[ "${ARG_json:-}" == "true" ]] || step "Testing ${name} (s3://${b})..."
    local test_err
    if ! test_err=$(_bk_aws_json "$dj" ls "s3://${b}" 2>&1); then
        error "S3 connection failed — nothing saved:"
        echo "$test_err" | sed 's/^/  /'
        exit 1
    fi
    [[ "${ARG_json:-}" == "true" ]] || success "S3 connection OK"

    if [[ "$name" == "s3" ]]; then
        # The top-level keys: where "s3" has always been (see _bk_s3_json).
        _bk_cfg | jq --argjson d "$dj" '.bucket = $d.bucket | .aws_key = $d.aws_key | .aws_secret = $d.aws_secret | .region = $d.region | .endpoint_url = $d.endpoint_url' | _bk_cfg_write
    else
        _bk_cfg | jq --arg n "$name" --argjson d "$dj" \
            '.s3_destinations = ((.s3_destinations // {}) | .[$n] = $d)' | _bk_cfg_write
    fi
    _bk_notify_change "The backup destination ${name} was $( [[ "$mode" == add ]] && echo added || echo changed ): s3://${b}${e:+ at ${e}}"
    _bk_use_dest "$name" "${ARG_use:-}"
    if [[ "${ARG_json:-}" == "true" ]]; then
        log_action "BACKUP DESTINATION $( [[ "$mode" == add ]] && echo ADD || echo EDIT ): ${name} s3://${b}"
        # Never the secret, nor the access key: what the panel shows of it.
        jq -n --arg n "$name" --arg b "$b" --arg r "$r" --arg e "$e" '{name: $n, type: "s3", bucket: $b, region: $r, endpoint: $e}'
        return 0
    fi
    if [[ "$mode" == "add" ]]; then
        success "Backup destination '${name}' added"
        log_action "BACKUP DESTINATION ADD: ${name} s3://${b}"
        if [[ -z "${ARG_use:-}" && -z "${_BK_IN_CONFIGURE:-}" ]]; then
            echo ""
            echo -e "  ${DIM}Use it in a profile: ${CYAN}cipi backup profile edit <profile> --dest=local,${name}${NC}"
            echo -e "  ${DIM}or in cipi.yml:      ${CYAN}destinations: [local, ${name}]${NC}"
        fi
        echo ""
    else
        success "Backup destination '${name}' updated"
        log_action "BACKUP DESTINATION EDIT: ${name} s3://${b}"
    fi
}

# add|edit --type=sftp: the remote's address and folder, a key of Cipi's own.
# Nothing is asked of the remote here — it cannot accept a key it has not
# been given yet: the public key is printed with how to install it, and
# `cipi backup destination test <name>` (or --test) checks the way.
_bk_destination_add_sftp() {   # <add|edit> <name>
    local mode="$1" name="$2" cur="{}"
    if _bk_s3_exists "$name"; then
        [[ "$mode" == "add" ]] && { error "Destination '${name}' already exists — use: cipi backup destination edit ${name} ..."; exit 1; }
        _bk_is_sftp "$name" || { error "'${name}' is an S3 destination"; exit 1; }
        cur=$(_bk_s3_json "$name")
    else
        [[ "$mode" == "edit" ]] && { error "No such destination: ${name}"; exit 1; }
    fi
    local host port user path
    host="${ARG_host:-$(jq -r '.host // ""' <<< "$cur")}"
    port="${ARG_port:-$(jq -r '.port // 22' <<< "$cur")}"
    user="${ARG_user:-$(jq -r '.user // ""' <<< "$cur")}"
    path="${ARG_path-$(jq -r '.path // ""' <<< "$cur")}"
    if [[ -t 0 && "${SUDO_USER:-}" != "www-data" ]]; then
        echo -e "\n${BOLD}SFTP destination '${name}'${NC}"
        echo -e "  ${DIM}A server reached over SSH: a VPS with a backup user, a Hetzner Storage Box (port 23), a NAS.${NC}"
        [[ -z "${ARG_host+x}" ]] && read_input "Host" "$host" host
        [[ -z "${ARG_port+x}" ]] && read_input "Port" "$port" port
        [[ -z "${ARG_user+x}" ]] && read_input "User" "$user" user
        [[ -z "${ARG_path+x}" ]] && read_input "Folder on the remote (empty: the login's home)" "$path" path
    fi
    path="${path%/}"
    _bk_sftp_valid_host "$host" || { error "Invalid host '${host}' (an IP address or a hostname)"; exit 1; }
    [[ "$port" =~ ^[0-9]{1,5}$ ]] && (( port >= 1 && port <= 65535 )) || { error "Invalid port '${port}' (1-65535)"; exit 1; }
    _bk_sftp_valid_user "$user" || { error "Invalid user '${user}'"; exit 1; }
    _bk_sftp_valid_path "$path" || { error "Invalid folder '${path}' (letters, digits, . _ - /; no ..)"; exit 1; }

    local key; key=$(_bk_sftp_key "$name")
    mkdir -p "$BACKUP_SFTP_KEY_DIR" && chmod 700 "$BACKUP_SFTP_KEY_DIR"
    if [[ ! -f "$key" || "${ARG_new_key:-}" == "true" ]]; then
        command -v ssh-keygen &>/dev/null || { error "ssh-keygen not found (apt-get install openssh-client)"; exit 1; }
        rm -f "$key" "${key}.pub"
        ssh-keygen -q -t ed25519 -N "" -C "cipi-backup-${name}@$(hostname -s 2>/dev/null || echo server)" -f "$key" </dev/null >/dev/null \
            || { error "Could not make a key for '${name}'"; exit 1; }
        chmod 600 "$key"; chmod 644 "${key}.pub"
    fi
    local dj
    dj=$(jq -n --arg h "$host" --argjson p "$port" --arg u "$user" --arg d "$path" \
        --argjson c "$(jq '.created_at // (now | floor)' <<< "$cur")" '{host:$h, port:$p, user:$u, path:$d, created_at:$c}')
    _bk_cfg | jq --arg n "$name" --argjson d "$dj" '.sftp_destinations = ((.sftp_destinations // {}) | .[$n] = $d)' | _bk_cfg_write
    log_action "BACKUP DESTINATION $( [[ "$mode" == add ]] && echo ADD || echo EDIT ): ${name} sftp://${user}@${host}:${port}/${path}"
    _bk_notify_change "The backup destination ${name} was $( [[ "$mode" == add ]] && echo added || echo changed ): sftp://${user}@${host}:${port}/${path}"
    _bk_use_dest "$name" "${ARG_use:-}"

    if [[ "${ARG_json:-}" == "true" ]]; then
        jq -n --arg n "$name" --argjson d "$dj" --arg k "$(_bk_sftp_pubkey "$name")" '{name: $n, type: "sftp"} + $d + {public_key: $k}'
        [[ "${ARG_test:-}" == "true" ]] && { _bk_sftp_probe "$name" >/dev/null 2>&1 || return 3; }
        return 0
    fi
    success "Backup destination '${name}' $( [[ "$mode" == add ]] && echo added || echo updated ): sftp://${user}@${host}:${port}/${path}"
    echo ""
    echo -e "  ${BOLD}The remote has to accept this key${NC} — Cipi signs in with it, never with a password:"
    echo -e "  ${CYAN}$(_bk_sftp_pubkey "$name")${NC}"
    echo ""
    echo -e "  ${DIM}A server of yours:      append it to ~${user}/.ssh/authorized_keys there${NC}"
    echo -e "  ${DIM}A Hetzner Storage Box:  ssh-copy-id -p ${port} -s -i ${key}.pub ${user}@${host}   (asks the box's password once)${NC}"
    echo -e "  ${DIM}Then check it:          ${CYAN}cipi backup destination test ${name}${NC}"
    [[ -n "${_BK_IN_CONFIGURE:-}${ARG_use:-}" ]] || echo -e "  ${DIM}And use it:             ${CYAN}cipi backup profile edit <profile> --dest=local,${name}${NC}"
    echo ""
    if [[ "${ARG_test:-}" == "true" ]]; then
        step "Testing ${name}..."
        local err
        if err=$(_bk_sftp_probe "$name" 2>&1); then success "SFTP connection OK"; else error "Not reachable yet: ${err}"; return 3; fi
    fi
}

# cipi backup destination key <name> [--raw]: the public key an SFTP remote accepts.
_bk_destination_key() {
    local n="${1:-}"; shift || true
    [[ -z "$n" ]] && { error "Usage: cipi backup destination key <name> [--raw]"; exit 1; }
    _bk_require_config
    _bk_is_sftp "$n" || { error "'${n}' is not an SFTP destination"; exit 1; }
    local k; k=$(_bk_sftp_pubkey "$n")
    [[ -n "$k" ]] || { error "No key for '${n}' — make one: cipi backup destination edit ${n} --new-key"; exit 1; }
    parse_args "$@"
    if [[ "${ARG_raw:-}" == "true" ]]; then echo "$k"; return 0; fi
    echo -e "\n${BOLD}Key of '${n}'${NC} — add it to the remote's authorized_keys:\n  ${k}\n"
}

_bk_destination_remove() {
    local n="${1:-}"
    [[ -z "$n" ]] && { error "Usage: cipi backup destination remove <name>"; exit 1; }
    _bk_require_config
    _bk_s3_exists "$n" || { error "No such destination: ${n}"; exit 1; }
    local used; used=$(_bk_dest_profiles "$n" | paste -sd, -)
    if [[ -n "$used" ]]; then
        error "Destination '${n}' is still used by: ${used}"
        info "Point them elsewhere first: cipi backup profile edit <profile> --dest=..."
        exit 1
    fi
    if [[ -t 0 ]]; then
        warn "Removing the destination does not delete the archives on it — and Cipi stops pruning them."
        confirm "Remove backup destination '${n}'?" || { info "Cancelled"; return 0; }
    fi
    local was_sftp=false; _bk_is_sftp "$n" && was_sftp=true
    if [[ "$n" == "s3" ]]; then
        _bk_cfg | jq '.bucket = "" | .aws_key = "" | .aws_secret = "" | .endpoint_url = ""' | _bk_cfg_write
    else
        _bk_cfg | jq --arg n "$n" 'del(.s3_destinations[$n]) | del(.sftp_destinations[$n])' | _bk_cfg_write
    fi
    if [[ "$was_sftp" == true ]]; then
        rm -f "$(_bk_sftp_key "$n")" "$(_bk_sftp_key "$n").pub"
        info "Its key is deleted here; remove the public key from the remote's authorized_keys too"
    fi
    success "Backup destination '${n}' removed"
    log_action "BACKUP DESTINATION REMOVE: ${n}"
    _bk_notify_change "The backup destination ${n} was removed"
}

# List each bucket (or one) with its own credentials.
_bk_destination_test() {
    local n="${1:-}" names
    _bk_require_config
    if [[ -n "$n" ]]; then
        _bk_s3_exists "$n" || { error "No such destination: ${n}"; exit 1; }
        names="$n"
    else
        names=$(_bk_s3_names)
    fi
    [[ -z "$names" ]] && { warn "No remote destination configured"; return 0; }
    _bk_ensure_remote_tools
    local dn rc=0 err
    while IFS= read -r dn; do
        [[ -n "$dn" ]] || continue
        if _bk_is_sftp "$dn"; then
            local dj; dj=$(_bk_s3_json "$dn")
            step "${dn}: sftp://$(jq -r '.user' <<< "$dj")@$(jq -r '.host' <<< "$dj"):$(jq -r '.port // 22' <<< "$dj")"
            if err=$(_bk_sftp_probe "$dn" 2>&1); then
                success "  reachable — a file written and removed in $(_bk_sftp_path "$dn" "sftp://${dn}/cipi")"
            else
                error "  ${err:-the remote refused the key or the folder}"
                info "  The remote must accept this key: $(_bk_sftp_pubkey "$dn")"
                rc=1
            fi
            continue
        fi
        step "${dn}: s3://$(_bk_s3_bucket "$dn")"
        if err=$(_bk_aws "$dn" ls "s3://$(_bk_s3_bucket "$dn")" 2>&1); then
            success "  reachable"
        else
            error "  $(grep -v '^[[:space:]]*$' <<< "$err" | tail -1)"; rc=1
        fi
    done <<< "$names"
    return $rc
}

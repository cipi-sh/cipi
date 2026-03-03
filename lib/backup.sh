#!/bin/bash
#############################################
# Cipi — Backup (S3)
#############################################

backup_command() {
    local sub="${1:-}"; shift||true
    case "$sub" in
        configure) _bk_configure ;;
        run)       _bk_run "$@" ;;
        list)      _bk_list "$@" ;;
        *) error "Use: configure run list"; exit 1 ;;
    esac
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

_bk_configure() {
    _ensure_awscli
    local cf="${CIPI_CONFIG}/backup.json"
    local ck="" cs="" cb="" cr=""
    [[ -f "$cf" ]] && { ck=$(jq -r '.aws_key//"" ' "$cf"); cs=$(jq -r '.aws_secret//""' "$cf"); cb=$(jq -r '.bucket//""' "$cf"); cr=$(jq -r '.region//""' "$cf"); }
    read_input "AWS Access Key ID" "$ck" ck
    read_input "AWS Secret Access Key" "$cs" cs
    read_input "S3 Bucket" "$cb" cb
    read_input "S3 Region" "${cr:-eu-central-1}" cr
    cat > "$cf" <<EOF
{"aws_key":"${ck}","aws_secret":"${cs}","bucket":"${cb}","region":"${cr}"}
EOF
    chmod 600 "$cf"
    mkdir -p /root/.aws
    cat > /root/.aws/credentials <<AWSCREDS
[default]
aws_access_key_id = ${ck}
aws_secret_access_key = ${cs}
AWSCREDS
    cat > /root/.aws/config <<AWSCFG
[default]
region = ${cr}
output = json
AWSCFG
    chmod 600 /root/.aws/credentials /root/.aws/config

    step "Testing S3 connectivity..."
    local test_err
    test_err=$(aws s3 ls "s3://${cb}" 2>&1)
    if [[ $? -ne 0 ]]; then
        error "S3 connection failed:"
        echo "$test_err" | sed 's/^/  /'
        exit 1
    fi
    success "Backup configured (S3 connection OK)"
}

_bk_run() {
    _ensure_awscli
    local target="${1:-}" cf="${CIPI_CONFIG}/backup.json"
    [[ ! -f "$cf" ]] && { error "Run: cipi backup configure"; exit 1; }
    local bucket; bucket=$(jq -r '.bucket' "$cf")
    local dbr; dbr=$(get_db_root_password)
    local ts; ts=$(date +%Y-%m-%d_%H%M%S)
    local tmp="/tmp/cipi-bk-${ts}"; mkdir -p "$tmp"

    _do_backup() {
        local app="$1"; local d="${tmp}/${app}"; mkdir -p "$d"
        local ok=true
        step "Backup '${app}'..."

        mariadb-dump -u root -p"$dbr" --single-transaction "$app" 2>"${d}/db.err" | gzip >"${d}/db.sql.gz"
        local dump_rc=${PIPESTATUS[0]}
        if [[ $dump_rc -ne 0 ]]; then
            error "  DB dump failed:"; sed 's/^/    /' "${d}/db.err"; ok=false
        fi
        rm -f "${d}/db.err"

        local tar_err
        tar_err=$(tar -czf "${d}/shared.tar.gz" -C "/home/${app}" shared/ 2>&1) || {
            error "  Files archive failed: ${tar_err}"; ok=false
        }

        local s3_err
        s3_err=$(aws s3 cp "${d}/" "s3://${bucket}/cipi/${app}/${ts}/" --recursive 2>&1)
        if [[ $? -ne 0 ]]; then
            error "  S3 upload failed:"
            echo "$s3_err" | sed 's/^/    /'
            ok=false
        else
            success "  → s3://${bucket}/cipi/${app}/${ts}/"
        fi

        [[ "$ok" == false ]] && warn "  Backup '${app}' completed with errors"
    }

    if [[ -n "$target" ]]; then
        app_exists "$target" || { error "Not found"; exit 1; }
        _do_backup "$target"
    else
        jq -r 'keys[]' "${CIPI_CONFIG}/apps.json" 2>/dev/null | while read -r a; do _do_backup "$a"; done
    fi
    rm -rf "$tmp"
    success "Backup complete"
}

_bk_list() {
    _ensure_awscli
    local target="${1:-}" cf="${CIPI_CONFIG}/backup.json"
    [[ ! -f "$cf" ]] && { error "Run: cipi backup configure"; exit 1; }
    local bucket; bucket=$(jq -r '.bucket' "$cf")
    echo -e "\n${BOLD}Backups${NC}"
    local ls_err
    if [[ -n "$target" ]]; then
        ls_err=$(aws s3 ls "s3://${bucket}/cipi/${target}/" 2>&1) || { error "$ls_err"; exit 1; }
        echo "$ls_err" | sed 's/^/  /'
    else
        ls_err=$(aws s3 ls "s3://${bucket}/cipi/" 2>&1) || { error "$ls_err"; exit 1; }
        echo "$ls_err" | sed 's/^/  /'
    fi
    echo ""
}

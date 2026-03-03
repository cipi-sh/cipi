#!/bin/bash
#############################################
# Cipi — Self-Update
#############################################

readonly _CIPI_REPO="andreapollastri/cipi"

selfupdate_command() {
    parse_args "$@"
    local branch="${ARG_branch:-latest}"
    if [[ "${ARG_check:-}" == "true" ]]; then
        local rv; rv=$(curl -fsSL "https://raw.githubusercontent.com/${_CIPI_REPO}/refs/heads/${branch}/version.md" 2>/dev/null | tr -d '[:space:]')
        [[ -z "$rv" ]] && { error "Cannot check updates"; exit 1; }
        [[ "$rv" == "$CIPI_VERSION" ]] && success "Up to date (v${CIPI_VERSION})" || info "Update: v${CIPI_VERSION} → v${rv}"
        return
    fi

    step "Downloading from '${branch}'..."
    local tmp="/tmp/cipi-update-$$"; rm -rf "$tmp"
    git clone -b "$branch" --depth 1 "https://github.com/${_CIPI_REPO}.git" "$tmp" 2>/dev/null || { error "Download failed"; exit 1; }
    local nv; nv=$(tr -d '[:space:]' < "${tmp}/version.md" 2>/dev/null)
    [[ -z "$nv" ]] && { error "Invalid package (version.md missing)"; rm -rf "$tmp"; exit 1; }
    info "Updating v${CIPI_VERSION} → v${nv}"
    cp -r /opt/cipi "/opt/cipi.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null||true
    cp "${tmp}/cipi" /usr/local/bin/cipi; chmod 700 /usr/local/bin/cipi
    cp "${tmp}"/lib/*.sh /opt/cipi/lib/; chmod 700 /opt/cipi/lib/*.sh
    [[ -f "${tmp}/lib/cipi-worker" ]] && cp "${tmp}/lib/cipi-worker" /usr/local/bin/cipi-worker && chmod 700 /usr/local/bin/cipi-worker
    chown -R root:root /usr/local/bin/cipi /opt/cipi

    # Run migrations
    if [[ -d "${tmp}/lib/migrations" ]]; then
        for m in $(ls "${tmp}/lib/migrations/"*.sh 2>/dev/null|sort -V); do
            local mv; mv=$(basename "$m" .sh)
            if [[ "$(printf '%s\n' "$CIPI_VERSION" "$mv"|sort -V|head -1)" == "$CIPI_VERSION" && "$mv" != "$CIPI_VERSION" ]]; then
                step "Migration ${mv}..."; bash "$m" 2>&1
            fi
        done
    fi

    echo "$nv" > "${CIPI_CONFIG}/version"
    rm -rf "$tmp"
    log_action "SELF-UPDATE: v${CIPI_VERSION} → v${nv}"
    success "Updated to v${nv}"
}

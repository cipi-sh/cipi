#!/bin/bash
#############################################
# Cipi — Optional app packages (allowlisted)
#
# Tools a Laravel project may need on the host — image optimisers, ffmpeg,
# pdftotext — installed from Ubuntu's own repositories, on request.
#
# The allowlist is the whole point. `cipi package install <anything>` would be
# a root apt shell with extra steps; the catalog below is a closed set that
# every entry has to earn:
#
#   * a stateless binary — no daemon, no port, no credentials, no state that
#     outlives the process,
#   * from an Ubuntu repository, so Ubuntu ships the security updates,
#   * with a real Laravel package behind it, not "might be handy".
#
# Anything that fails one of those is not a package, it is a service: that is
# `cipi search`, `cipi db install`, or the container branch. Chromium is the
# instructive rejection — on Ubuntu 24.04 `chromium` does not exist and
# `chromium-browser` is a 48kB transitional package that depends on snapd,
# so "apt install chromium" quietly installs a daemon.
#
# Nothing here is installed by setup.sh or self-update.
#############################################

[[ -z "${PKG_MIN_DISK_KB:-}" ]] && readonly PKG_MIN_DISK_KB=1048576

# id|apt packages|binaries to verify|description
#
# The id may be a group ("image-optimizers"); any single apt package inside a
# group is accepted as a name of its own, so `cipi package install webp` works.
_pkg_catalog() {
    cat <<'EOF'
image-optimizers|jpegoptim optipng pngquant gifsicle webp|jpegoptim optipng pngquant gifsicle cwebp|Image optimisers for spatie/laravel-image-optimizer
ffmpeg|ffmpeg|ffmpeg ffprobe|Audio/video transcoding for pbmedia/laravel-ffmpeg
imagemagick|imagemagick|convert|ImageMagick CLI (the PHP extension is already installed; this is convert/magick)
poppler-utils|poppler-utils|pdftotext pdftoppm|PDF text extraction for spatie/pdf-to-text
EOF
}

_pkg_ids()       { _pkg_catalog | cut -d'|' -f1; }
_pkg_apt_for()   { _pkg_catalog | awk -F'|' -v i="$1" '$1 == i { print $2; exit }'; }
_pkg_bins_for()  { _pkg_catalog | awk -F'|' -v i="$1" '$1 == i { print $3; exit }'; }
_pkg_desc_for()  { _pkg_catalog | awk -F'|' -v i="$1" '$1 == i { print $4; exit }'; }

package_command() {
    local sub="${1:-list}"; shift || true
    case "$sub" in
        list|status)    _pkg_list "$@" ;;
        install|add)    _pkg_install "$@" ;;
        remove|uninstall|delete) _pkg_remove "$@" ;;
        help|--help|-h) show_help package ;;
        *)
            error "Unknown package subcommand: ${sub}"
            echo -e "  Usage: ${CYAN}cipi package <list|install|remove> [name]${NC}"
            exit 1
            ;;
    esac
}

_pkg_apt() {
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 "$@"
}

_pkg_dpkg_installed() {
    [[ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null || true)" == "installed" ]]
}

# Resolve a user-typed name to a catalog id. Accepts a group id, or any single
# apt package inside a group — `webp` and `image-optimizers` both work.
_pkg_resolve() {
    local want="$1" id p
    for id in $(_pkg_ids); do
        [[ "$want" == "$id" ]] && { printf '%s' "$id"; return 0; }
    done
    for id in $(_pkg_ids); do
        for p in $(_pkg_apt_for "$id"); do
            if [[ "$want" == "$p" ]]; then
                printf '%s' "$id"
                return 0
            fi
        done
    done
    return 1
}

_pkg_refuse() {
    local want="$1"
    error "'${want}' is not in the Cipi package allowlist"
    echo ""
    echo -e "  Allowed: ${CYAN}$(_pkg_ids | tr '\n' ' ')${NC}"
    echo ""
    echo -e "  ${DIM}The list is closed on purpose: these are stateless binaries from Ubuntu's${NC}"
    echo -e "  ${DIM}own repositories. Anything with a daemon, a port or its own state is a${NC}"
    echo -e "  ${DIM}service — see 'cipi search', 'cipi db install'.${NC}"
    if [[ "$want" == chromium* || "$want" == "google-chrome"* ]]; then
        echo ""
        warn "Chromium is not installable this way on Ubuntu."
        echo "  'chromium' does not exist as a deb; 'chromium-browser' is a transitional"
        echo "  package that depends on snapd, so apt would install a daemon and a snap"
        echo "  that updates itself outside apt. For spatie/browsershot use Puppeteer's"
        echo "  own Chromium (Node is already installed) or Google's apt repository."
    fi
    return 1
}

# How many of a catalog entry's apt packages are present.
_pkg_state() {
    local id="$1" p have=0 total=0
    for p in $(_pkg_apt_for "$id"); do
        total=$((total + 1))
        _pkg_dpkg_installed "$p" && have=$((have + 1))
    done
    printf '%s/%s' "$have" "$total"
}

_pkg_list() {
    parse_args "$@"

    if [[ "${ARG_json:-}" == "true" ]]; then
        local items="[]" id state
        for id in $(_pkg_ids); do
            state=$(_pkg_state "$id")
            items=$(echo "$items" | jq -c \
                --arg i "$id" --arg a "$(_pkg_apt_for "$id")" --arg d "$(_pkg_desc_for "$id")" \
                --arg have "${state%/*}" --arg total "${state#*/}" \
                '. + [{id:$i, packages:($a | split(" ")), description:$d,
                       installed:(($have|tonumber) == ($total|tonumber)),
                       partial:(($have|tonumber) > 0 and ($have|tonumber) < ($total|tonumber))}]')
        done
        jq -n --argjson packages "$items" '{packages: $packages}'
        return 0
    fi

    echo -e "\n${BOLD}Optional packages${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    local id state have total
    for id in $(_pkg_ids); do
        state=$(_pkg_state "$id"); have="${state%/*}"; total="${state#*/}"
        if [[ "$have" == "$total" ]]; then
            printf "  ${GREEN}●${NC} %-18s ${DIM}%s${NC}\n" "$id" "$(_pkg_desc_for "$id")"
        elif [[ "$have" != "0" ]]; then
            printf "  ${YELLOW}◐${NC} %-18s ${DIM}%s${NC}\n" "$id" "partially installed (${have}/${total})"
        else
            printf "  ${DIM}○${NC} %-18s ${DIM}%s${NC}\n" "$id" "$(_pkg_desc_for "$id")"
        fi
        printf "    ${DIM}%s${NC}\n" "$(_pkg_apt_for "$id")"
    done
    echo ""
    echo -e "  ${CYAN}cipi package install <name>${NC}   ${DIM}/  remove <name>${NC}"
    echo ""
    echo -e "  ${DIM}Already in the base stack: the Imagick PHP extension, Ghostscript and${NC}"
    echo -e "  ${DIM}fonts-dejavu-core (pulled in as Recommends of php-imagick), Node 20.${NC}"
    echo ""
}

_pkg_check_disk() {
    local free; free=$(df -Pk /var 2>/dev/null | awk 'NR==2 {print $4}')
    [[ "${free:-0}" -ge "$PKG_MIN_DISK_KB" ]] && return 0
    if [[ "${ARG_force:-}" == "true" ]]; then
        warn "Only $(( ${free:-0} / 1024 ))MB free on /var — continuing because --force"
        return 0
    fi
    error "Less than $((PKG_MIN_DISK_KB / 1024))MB free on /var (have $(( ${free:-0} / 1024 ))MB)"
    echo "  Codec and imaging dependency trees are large. Free some space, or pass --force."
    return 1
}

# What apt actually intends to do, from apt, on this machine — rather than a
# size this file would have to guess and keep up to date.
_pkg_preview() {
    local sim
    sim=$(_pkg_apt install -s "$@" 2>/dev/null) || return 1
    local newly space
    newly=$(grep -cE '^Inst ' <<< "$sim" || true)
    space=$(grep -E 'additional disk space|freed' <<< "$sim" | head -1 | sed 's/^[[:space:]]*//')
    echo ""
    echo -e "  ${BOLD}apt would install ${newly} package(s)${NC}"
    [[ -n "$space" ]] && echo -e "  ${DIM}${space}${NC}"
    echo ""
    return 0
}

_pkg_install() {
    local want="${1:-}"; shift || true
    [[ -z "$want" ]] && { error "Usage: cipi package install <name>"; _pkg_list; exit 1; }
    parse_args "$@"

    local id; id=$(_pkg_resolve "$want") || { _pkg_refuse "$want"; exit 1; }
    local apt_pkgs; apt_pkgs=$(_pkg_apt_for "$id")

    local state; state=$(_pkg_state "$id")
    if [[ "${state%/*}" == "${state#*/}" ]]; then
        success "${id} is already installed (${apt_pkgs})"
        return 0
    fi

    _pkg_check_disk || exit 1

    step "Refreshing the package index..."
    _pkg_apt update -qq || warn "apt-get update reported a problem — continuing"

    # shellcheck disable=SC2086
    _pkg_preview $apt_pkgs || { error "apt cannot resolve: ${apt_pkgs}"; exit 1; }

    if [[ "${ARG_yes:-}" != "true" && "${ARG_force:-}" != "true" ]]; then
        confirm "Install ${id} (${apt_pkgs})?" || { info "Aborted"; return 0; }
    fi

    step "Installing ${apt_pkgs}..."
    # shellcheck disable=SC2086
    if ! _pkg_apt install -y -qq $apt_pkgs; then
        error "apt-get install failed for: ${apt_pkgs}"
        exit 1
    fi

    # A package that installed but whose binary is not on PATH is not a
    # success — say which one, rather than letting the app find out.
    local b missing=""
    for b in $(_pkg_bins_for "$id"); do
        command -v "$b" >/dev/null 2>&1 || missing="${missing} ${b}"
    done

    log_action "PACKAGE: installed ${id} (${apt_pkgs})"
    cipi_notify \
        "Cipi: package installed on $(hostname)" \
        "An optional package was installed.\n\nServer: $(hostname)\nEntry: ${id}\nPackages: ${apt_pkgs}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        package_install

    echo ""
    if [[ -n "$missing" ]]; then
        warn "Installed, but these binaries are not on PATH:${missing}"
    else
        success "${id} installed — $(_pkg_bins_for "$id" | tr ' ' ',') available"
    fi
    echo ""
    echo -e "  ${DIM}PHP-FPM and queue workers pick a new binary up on their next process.${NC}"
    if [[ "$id" == "ffmpeg" ]]; then
        echo -e "  ${YELLOW}Run transcoding from a queue worker, never from a web request:${NC}"
        echo -e "  ${DIM}the FPM pool has request_terminate_timeout = 300, and one ffmpeg will${NC}"
        echo -e "  ${DIM}take every core on a box shared with MariaDB and the other apps.${NC}"
    fi
    if [[ "$id" == "imagemagick" || "$id" == "poppler-utils" ]]; then
        echo -e "  ${DIM}PDF via ImageMagick is blocked by default in /etc/ImageMagick-6/policy.xml${NC}"
        echo -e "  ${DIM}(the Ghostscript CVEs). pdftotext is not affected by that policy.${NC}"
    fi
    echo ""
}

_pkg_remove() {
    local want="${1:-}"; shift || true
    [[ -z "$want" ]] && { error "Usage: cipi package remove <name>"; _pkg_list; exit 1; }
    parse_args "$@"

    local id; id=$(_pkg_resolve "$want") || { _pkg_refuse "$want"; exit 1; }
    local apt_pkgs; apt_pkgs=$(_pkg_apt_for "$id")

    # Purge only what is actually there: naming an absent package makes
    # apt-get exit non-zero and turns a no-op into a failure.
    local p present=""
    for p in $apt_pkgs; do
        _pkg_dpkg_installed "$p" && present="${present} ${p}"
    done
    present="${present# }"
    if [[ -z "$present" ]]; then
        info "${id} is not installed"
        return 0
    fi

    if [[ "${ARG_force:-}" != "true" && "${ARG_yes:-}" != "true" ]]; then
        confirm "Purge ${present}?" || { info "Aborted"; return 0; }
    fi

    step "Purging ${present}..."
    # shellcheck disable=SC2086
    if ! _pkg_apt purge -y -qq $present; then
        error "apt-get purge failed for: ${present}"
        exit 1
    fi

    # Orphaned dependencies are most of the disk an imaging or codec tree took,
    # but autoremove is server-wide: show what it would take and ask, rather
    # than running it silently on a box that also runs MariaDB and PHP.
    local orphans
    orphans=$(_pkg_apt autoremove -s 2>/dev/null | awk '/^Remv /{print $2}' | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    if [[ -n "$orphans" ]]; then
        echo ""
        echo -e "  ${BOLD}Orphaned dependencies apt would also remove:${NC}"
        echo -e "  ${DIM}${orphans}${NC}"
        echo ""
        if [[ "${ARG_autoremove:-}" == "true" ]] || confirm "Remove them too?"; then
            _pkg_apt autoremove -y -qq || warn "autoremove reported a problem"
        else
            info "Left in place — 'apt-get autoremove' when you want them gone"
        fi
    fi

    log_action "PACKAGE: removed ${id} (${present})"
    cipi_notify \
        "Cipi: package removed from $(hostname)" \
        "An optional package was removed.\n\nServer: $(hostname)\nEntry: ${id}\nPackages: ${present}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        package_remove

    echo ""
    success "${id} removed"
    echo -e "  ${DIM}Any app still shelling out to it will now fail — check before deploying.${NC}"
    echo ""
}

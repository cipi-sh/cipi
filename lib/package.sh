#!/bin/bash
#############################################
# Cipi — Optional app packages (allowlisted)
#
# Tools a Laravel project may need on the host — image optimisers, ffmpeg,
# pdftotext, OCR, office conversion — and the libraries some need to run
# (the Chrome Puppeteer downloads for Browsershot), installed from Ubuntu's
# own repositories, on request.
#
# The allowlist is the whole point. `cipi package install <anything>` would be
# a root apt shell with extra steps; the catalog below is a closed set that
# every entry has to earn:
#
#   * stateless: binaries or shared libraries and fonts — no daemon, no port,
#     no credentials, no state that outlives the process,
#   * from an Ubuntu repository, so Ubuntu ships the security updates,
#   * with a real Laravel or PHP package behind it, not "might be handy".
#
# Anything that fails one of those is not a package, it is a service: that is
# `cipi search`, `cipi db install`, or the container branch. Chromium is the
# instructive rejection — on Ubuntu 24.04 `chromium` does not exist and
# `chromium-browser` is a 48kB transitional package that depends on snapd,
# so "apt install chromium" quietly installs a daemon. Browsershot gets the
# libraries instead (`browsershot`), and Chrome comes with Puppeteer, per app.
# wkhtmltopdf is the other one: archived upstream, its Qt WebKit unpatched.
#
# Because the set is closed, the panel may install and remove entries
# (5.14.0): it passes --yes, and its --force and --autoremove are ignored.
#
# Nothing here is installed by setup.sh or self-update.
#############################################

[[ -z "${PKG_MIN_DISK_KB:-}" ]] && readonly PKG_MIN_DISK_KB=1048576

# id|apt packages|binaries to verify|description
#
# The id may be a group ("image-optimizers"); any single apt package inside a
# group is accepted as a name of its own, so `cipi package install webp` works.
#
# An apt item may list alternatives, "a/b": the first one apt has a candidate
# for is installed, and either one installed counts. The 64-bit time_t
# transition renamed shared libraries in 24.04 (libasound2 → libasound2t64),
# and later releases may drop the suffix again: the names stay real package
# names on both 24.04 and 26.04, never virtual ones dpkg cannot see.
#
# No binaries means the entry is libraries or fonts ("libraries"): nothing to
# find on PATH, and removing it takes only what no other package still needs.
_pkg_catalog() {
    cat <<'EOF'
image-optimizers|jpegoptim optipng pngquant gifsicle webp|jpegoptim optipng pngquant gifsicle cwebp|Image optimisers for spatie/laravel-image-optimizer
avif|libavif-bin|avifenc|AVIF encoder (avifenc) for spatie/laravel-image-optimizer
ffmpeg|ffmpeg|ffmpeg ffprobe|Audio/video transcoding for pbmedia/laravel-ffmpeg
imagemagick|imagemagick|convert|ImageMagick CLI (the PHP extension is already installed; this is convert/magick)
poppler-utils|poppler-utils|pdftotext pdftoppm|PDF text extraction for spatie/pdf-to-text
browsershot|libnss3 libnspr4 libatk1.0-0t64/libatk1.0-0 libatk-bridge2.0-0t64/libatk-bridge2.0-0 libcups2t64/libcups2 libdrm2 libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libgbm1 libpango-1.0-0 libcairo2 libasound2t64/libasound2 fonts-liberation fonts-noto-color-emoji||Libraries and fonts for the Chrome Puppeteer downloads: spatie/browsershot, spatie/laravel-pdf
fonts-cjk|fonts-noto-cjk||Chinese, Japanese and Korean fonts for PDFs and images (Browsershot, ImageMagick)
pdftk|pdftk-java|pdftk|Fill forms, merge and split PDFs for mikehaertl/php-pdftk (pulls a headless Java runtime)
libreoffice|libreoffice-writer-nogui libreoffice-calc-nogui|soffice|Headless LibreOffice: DOCX, XLSX and ODT to PDF (soffice --convert-to)
pandoc|pandoc|pandoc|Document conversion (Markdown, HTML, DOCX, ODT, EPUB) for ueberdosis/pandoc
tesseract|tesseract-ocr tesseract-ocr-eng tesseract-ocr-ita tesseract-ocr-deu tesseract-ocr-fra tesseract-ocr-spa|tesseract|OCR for thiagoalessio/tesseract_ocr (English, Italian, German, French, Spanish)
EOF
}

_pkg_ids()       { _pkg_catalog | cut -d'|' -f1; }
_pkg_apt_for()   { _pkg_catalog | awk -F'|' -v i="$1" '$1 == i { print $2; exit }'; }
_pkg_bins_for()  { _pkg_catalog | awk -F'|' -v i="$1" '$1 == i { print $3; exit }'; }
_pkg_desc_for()  { _pkg_catalog | awk -F'|' -v i="$1" '$1 == i { print $4; exit }'; }
_pkg_kind_for()  { [[ -n "$(_pkg_bins_for "$1")" ]] && echo tools || echo libraries; }

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

# The panel runs these through sudo as www-data. It passes --yes; what it
# passes besides does not get past a guard (the disk check) or reach beyond
# the entry (a server-wide autoremove).
_pkg_from_panel() { [[ "${SUDO_USER:-}" == "www-data" ]]; }
_pkg_forced()     { [[ "${ARG_force:-}" == "true" ]] && ! _pkg_from_panel; }

_pkg_dpkg_installed() {
    [[ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null || true)" == "installed" ]]
}

# An item ("a" or "a/b"): the alternative that is installed, if one is.
_pkg_item_installed() {
    local alt
    for alt in ${1//\// }; do
        _pkg_dpkg_installed "$alt" && { printf '%s' "$alt"; return 0; }
    done
    return 1
}

# apt's candidate for a package, or nothing. apt-cache's output is read whole:
# reading it through `awk … exit` kills apt-cache with SIGPIPE, and under
# pipefail that ends cipi (5.13.1).
_pkg_candidate() {
    local out cand
    out=$(apt-cache policy "$1" 2>/dev/null) || true
    cand=$(awk '/Candidate:/ { print $2 }' <<< "$out" | head -1)
    [[ -n "$cand" && "$cand" != "(none)" ]] && printf '%s' "$cand"
}

# An item to install: the first alternative apt has a candidate for.
_pkg_item_pick() {
    local alt
    for alt in ${1//\// }; do
        [[ -n "$(_pkg_candidate "$alt")" ]] && { printf '%s' "$alt"; return 0; }
    done
    return 1
}

# The name to show for an item: the installed alternative, else the first.
_pkg_item_name() { _pkg_item_installed "$1" || printf '%s' "${1%%/*}"; }

# Resolve a user-typed name to a catalog id. Accepts a group id, or any single
# apt package inside a group (either alternative) — `webp` and
# `image-optimizers` both work.
_pkg_resolve() {
    local want="$1" id p alt
    for id in $(_pkg_ids); do
        [[ "$want" == "$id" ]] && { printf '%s' "$id"; return 0; }
    done
    for id in $(_pkg_ids); do
        for p in $(_pkg_apt_for "$id"); do
            for alt in ${p//\// }; do
                if [[ "$want" == "$alt" ]]; then
                    printf '%s' "$id"
                    return 0
                fi
            done
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
    echo -e "  ${DIM}The list is closed on purpose: stateless binaries, libraries and fonts from${NC}"
    echo -e "  ${DIM}Ubuntu's own repositories. Anything with a daemon, a port or its own state is${NC}"
    echo -e "  ${DIM}a service — see 'cipi search', 'cipi db install'.${NC}"
    if [[ "$want" == chromium* || "$want" == "google-chrome"* || "$want" == puppeteer* ]]; then
        echo ""
        warn "Chromium is not installable this way on Ubuntu."
        echo "  'chromium' does not exist as a deb; 'chromium-browser' is a transitional"
        echo "  package that depends on snapd, so apt would install a daemon and a snap"
        echo "  that updates itself outside apt. For spatie/browsershot install the"
        echo "  libraries Chrome needs — cipi package install browsershot — and let"
        echo "  Puppeteer download Chrome into the app (npm install puppeteer)."
    fi
    if [[ "$want" == wkhtmltopdf* || "$want" == wkhtmltox* ]]; then
        echo ""
        warn "wkhtmltopdf is not in the catalog."
        echo "  The project is archived upstream and its Qt WebKit engine no longer gets"
        echo "  security fixes. For HTML to PDF use Chrome: cipi package install browsershot"
        echo "  (spatie/browsershot, spatie/laravel-pdf)."
    fi
    return 1
}

# How many of a catalog entry's apt items are present.
_pkg_state() {
    local id="$1" p have=0 total=0
    for p in $(_pkg_apt_for "$id"); do
        total=$((total + 1))
        _pkg_item_installed "$p" >/dev/null && have=$((have + 1))
    done
    printf '%s/%s' "$have" "$total"
}

# Partly installed, as far as it matters: some items but not all — for a
# library entry, only when one of them was installed on purpose (manual);
# libraries other packages pulled in do not make it half-installed.
_pkg_partial() {
    local id="$1" state="$2" p name present=""
    [[ "${state%/*}" != "0" && "${state%/*}" != "${state#*/}" ]] || return 1
    [[ "$(_pkg_kind_for "$id")" == "tools" ]] && return 0
    for p in $(_pkg_apt_for "$id"); do
        name=$(_pkg_item_installed "$p") && present="${present} ${name}"
    done
    # shellcheck disable=SC2086
    [[ -n "$(apt-mark showmanual $present 2>/dev/null)" ]]
}

_pkg_list() {
    parse_args "$@"

    if [[ "${ARG_json:-}" == "true" ]]; then
        local items="[]" id state p names missing partial
        for id in $(_pkg_ids); do
            state=$(_pkg_state "$id")
            partial=false; _pkg_partial "$id" "$state" && partial=true
            names=""; missing=""
            for p in $(_pkg_apt_for "$id"); do
                names="${names} $(_pkg_item_name "$p")"
                _pkg_item_installed "$p" >/dev/null || missing="${missing} ${p%%/*}"
            done
            items=$(echo "$items" | jq -c \
                --arg i "$id" --arg a "${names# }" --arg d "$(_pkg_desc_for "$id")" \
                --arg b "$(_pkg_bins_for "$id")" --arg k "$(_pkg_kind_for "$id")" --arg m "${missing# }" \
                --arg have "${state%/*}" --arg total "${state#*/}" --argjson partial "$partial" \
                '. + [{id:$i, packages:($a | split(" ")), description:$d, kind:$k,
                       binaries:($b | split(" ") | map(select(. != ""))),
                       missing:($m | split(" ") | map(select(. != ""))),
                       installed:(($have|tonumber) == ($total|tonumber)),
                       partial:$partial}]')
        done
        jq -n --argjson packages "$items" '{packages: $packages}'
        return 0
    fi

    echo -e "\n${BOLD}Optional packages${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    local id state have total p names
    for id in $(_pkg_ids); do
        state=$(_pkg_state "$id"); have="${state%/*}"; total="${state#*/}"
        if [[ "$have" == "$total" ]]; then
            printf "  ${GREEN}●${NC} %-18s ${DIM}%s${NC}\n" "$id" "$(_pkg_desc_for "$id")"
        elif _pkg_partial "$id" "$state"; then
            printf "  ${YELLOW}◐${NC} %-18s ${DIM}%s${NC}\n" "$id" "partially installed (${have}/${total})"
        else
            printf "  ${DIM}○${NC} %-18s ${DIM}%s${NC}\n" "$id" "$(_pkg_desc_for "$id")"
        fi
        names=""
        for p in $(_pkg_apt_for "$id"); do names="${names} $(_pkg_item_name "$p")"; done
        printf "    ${DIM}%s${NC}\n" "${names# }" | fold -s -w 76 | sed '2,$s/^/    /'
    done
    echo ""
    echo -e "  ${CYAN}cipi package install <name>${NC}   ${DIM}/  remove <name>${NC}"
    echo ""
    echo -e "  ${DIM}Already in the base stack: the Imagick PHP extension, Ghostscript and${NC}"
    echo -e "  ${DIM}fonts-dejavu-core (pulled in as Recommends of php-imagick), Node 22 (cipi node).${NC}"
    echo ""
}

_pkg_check_disk() {
    local free; free=$(df -Pk /var 2>/dev/null | awk 'NR==2 {print $4}')
    [[ "${free:-0}" -ge "$PKG_MIN_DISK_KB" ]] && return 0
    if _pkg_forced; then
        warn "Only $(( ${free:-0} / 1024 ))MB free on /var — continuing because --force"
        return 0
    fi
    error "Less than $((PKG_MIN_DISK_KB / 1024))MB free on /var (have $(( ${free:-0} / 1024 ))MB)"
    echo "  Codec, office and imaging dependency trees are large. Free some space, or"
    echo "  pass --force at the server."
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

# Packages apt's simulation would take away: "Purg x [...]" / "Remv x [...]".
_pkg_sim_removed() { awk '/^(Purg|Remv) /{print $2}' <<< "$1" | sort -u; }

# What `apt-get autoremove` would take right now.
_pkg_orphans() {
    local sim; sim=$(_pkg_apt autoremove -s 2>/dev/null) || true
    _pkg_sim_removed "$sim"
}

# Lines of $1 that are not in $2 (both newline lists).
_pkg_minus() { comm -23 <(printf '%s\n' "$1" | sed '/^$/d' | sort -u) <(printf '%s\n' "$2" | sed '/^$/d' | sort -u); }

# What to tell an app's developer after an install.
_pkg_notes() {
    case "$1" in
        ffmpeg)
            echo -e "  ${YELLOW}Run transcoding from a queue worker, never from a web request:${NC}"
            echo -e "  ${DIM}the FPM pool has request_terminate_timeout = 300, and one ffmpeg will${NC}"
            echo -e "  ${DIM}take every core on a box shared with MariaDB and the other apps.${NC}"
            ;;
        imagemagick|poppler-utils)
            echo -e "  ${DIM}PDF via ImageMagick is blocked by default in /etc/ImageMagick-6/policy.xml${NC}"
            echo -e "  ${DIM}(the Ghostscript CVEs). pdftotext is not affected by that policy.${NC}"
            ;;
        browsershot)
            echo -e "  ${BOLD}Chrome itself comes with Puppeteer, per app:${NC} add it to the app"
            echo -e "  ${DIM}(npm install puppeteer) and its install downloads Chrome into the app${NC}"
            echo -e "  ${DIM}user's ~/.cache/puppeteer, kept between releases. Browsershot finds node${NC}"
            echo -e "  ${DIM}and npm in /usr/bin.${NC}"
            echo -e "  ${YELLOW}Ubuntu 24.04+ restricts the user namespaces Chrome's sandbox uses:${NC}"
            echo -e "  ${DIM}if Chrome reports \"No usable sandbox\", ->noSandbox() — for HTML you trust.${NC}"
            echo -e "  ${DIM}Chinese, Japanese or Korean text: cipi package install fonts-cjk.${NC}"
            ;;
        libreoffice)
            echo -e "  ${YELLOW}Convert from a queue worker, never from a web request.${NC}"
            echo -e "  ${DIM}soffice --headless --convert-to pdf --outdir <dir> <file>; two conversions at${NC}"
            echo -e "  ${DIM}once need two profiles: -env:UserInstallation=file:///tmp/lo-<job id>.${NC}"
            ;;
        pdftk)
            echo -e "  ${DIM}pdftk is pdftk-java: it starts a Java runtime on every call (about a second).${NC}"
            ;;
        tesseract)
            echo -e "  ${DIM}Languages: eng, ita, deu, fra, spa — tesseract --list-langs.${NC}"
            echo -e "  ${DIM}OCR is CPU-bound: run it from a queue worker.${NC}"
            ;;
        avif)
            echo -e "  ${DIM}spatie/image-optimizer picks avifenc up for .avif files.${NC}"
            ;;
    esac
}

_pkg_install() {
    local want="${1:-}"; shift || true
    [[ -z "$want" ]] && { error "Usage: cipi package install <name>"; _pkg_list; exit 1; }
    parse_args "$@"

    local id; id=$(_pkg_resolve "$want") || { _pkg_refuse "$want"; exit 1; }
    local items; items=$(_pkg_apt_for "$id")

    local state; state=$(_pkg_state "$id")
    if [[ "${state%/*}" == "${state#*/}" ]]; then
        success "${id} is already installed"
        return 0
    fi

    _pkg_check_disk || exit 1

    step "Refreshing the package index..."
    _pkg_apt update -qq || warn "apt-get update reported a problem — continuing"

    # The apt names to install: what is missing, each item by the first
    # alternative this release has.
    local p pick apt_pkgs="" unknown=""
    for p in $items; do
        _pkg_item_installed "$p" >/dev/null && continue
        if pick=$(_pkg_item_pick "$p"); then
            apt_pkgs="${apt_pkgs} ${pick}"
        else
            unknown="${unknown} ${p}"
        fi
    done
    apt_pkgs="${apt_pkgs# }"
    if [[ -n "$unknown" ]]; then
        error "apt has no candidate for:${unknown//\// or } — nothing installed"
        echo "  Check the server's apt sources (universe enabled?): apt-cache policy ${unknown%%/*}"
        exit 1
    fi

    # shellcheck disable=SC2086
    _pkg_preview $apt_pkgs || { error "apt cannot resolve: ${apt_pkgs}"; exit 1; }

    if [[ "${ARG_yes:-}" != "true" ]] && ! _pkg_forced; then
        if [[ ! -t 0 ]]; then
            error "Installing packages is never implicit: pass --yes"
            exit 1
        fi
        confirm "Install ${id} (${apt_pkgs})?" || { info "Aborted"; return 0; }
    fi

    step "Installing ${apt_pkgs}..."
    # shellcheck disable=SC2086
    if ! _pkg_apt install -y -qq $apt_pkgs; then
        error "apt-get install failed for: ${apt_pkgs}"
        exit 1
    fi

    # A package that installed but whose binary is not on PATH is not a
    # success — say which one, rather than letting the app find out. A
    # library entry has nothing on PATH: every item must be installed.
    local b missing=""
    for b in $(_pkg_bins_for "$id"); do
        command -v "$b" >/dev/null 2>&1 || missing="${missing} ${b}"
    done
    for p in $items; do
        _pkg_item_installed "$p" >/dev/null || missing="${missing} ${p%%/*}"
    done

    log_action "PACKAGE: installed ${id} (${apt_pkgs})"
    cipi_notify \
        "Cipi: package installed on $(hostname)" \
        "An optional package was installed.\n\nServer: $(hostname)\nEntry: ${id}\nPackages: ${apt_pkgs}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        package_install

    echo ""
    if [[ -n "$missing" ]]; then
        warn "Installed, but these are missing:${missing}"
    elif [[ "$(_pkg_kind_for "$id")" == "tools" ]]; then
        success "${id} installed — $(_pkg_bins_for "$id" | tr ' ' ',') available"
    else
        success "${id} installed"
    fi
    echo ""
    [[ "$(_pkg_kind_for "$id")" == "tools" ]] && echo -e "  ${DIM}PHP-FPM and queue workers pick a new binary up on their next process.${NC}"
    _pkg_notes "$id"
    echo ""
}

# Remove an entry, and nothing that does not belong to it. What goes is
# computed before anything changes:
#   * tools — the entry's packages, plus the dependencies only they needed. A
#     purge that would take another package with it (one that depends on the
#     entry) is refused.
#   * libraries — marked as automatically installed, then only those no other
#     package needs, and their own orphaned dependencies. A library another
#     package uses stays, as a dependency.
# Orphans that were there before are left alone (--autoremove at the server
# takes them too).
_pkg_remove() {
    local want="${1:-}"; shift || true
    [[ -z "$want" ]] && { error "Usage: cipi package remove <name>"; _pkg_list; exit 1; }
    parse_args "$@"

    local id; id=$(_pkg_resolve "$want") || { _pkg_refuse "$want"; exit 1; }
    local kind; kind=$(_pkg_kind_for "$id")

    # Only what is actually there: naming an absent package makes apt-get
    # exit non-zero and turns a no-op into a failure.
    local p name present=""
    for p in $(_pkg_apt_for "$id"); do
        name=$(_pkg_item_installed "$p") && present="${present} ${name}"
    done
    present="${present# }"
    if [[ -z "$present" ]]; then
        info "${id} is not installed"
        return 0
    fi

    local before plan sim removed extra manual=""
    before=$(_pkg_orphans)

    if [[ "$kind" == "tools" ]]; then
        # shellcheck disable=SC2086
        sim=$(_pkg_apt purge -s $present 2>/dev/null) || { error "apt cannot plan the removal of: ${present}"; exit 1; }
        removed=$(_pkg_sim_removed "$sim")
        extra=$(_pkg_minus "$removed" "$(tr ' ' '\n' <<< "$present")")
        if [[ -n "$extra" ]] && ! _pkg_forced; then
            error "Removing ${id} would also remove: $(tr '\n' ' ' <<< "$extra" | sed 's/ $//')"
            echo "  They depend on it. Nothing was changed."
            exit 1
        fi
        # shellcheck disable=SC2086
        sim=$(_pkg_apt purge -s --autoremove $present 2>/dev/null) || sim=""
        plan=$(_pkg_minus "$(_pkg_sim_removed "$sim"; tr ' ' '\n' <<< "$present")" "$before")
    else
        # The libraries installed on purpose (manual): what other packages
        # pulled in as dependencies was never this entry's to remove. They are
        # also what goes back to manual on abort.
        for p in $present; do
            [[ -n "$(apt-mark showmanual "$p" 2>/dev/null)" ]] && manual="${manual} ${p}"
        done
        manual="${manual# }"
        if [[ -z "$manual" ]]; then
            info "${id} is not installed"
            echo -e "  ${DIM}The libraries of it that are here were installed by other packages.${NC}"
            return 0
        fi
        # shellcheck disable=SC2086
        apt-mark auto $manual >/dev/null 2>&1 || { error "apt-mark auto failed for: ${manual}"; exit 1; }
        plan=$(_pkg_minus "$(_pkg_orphans)" "$before")
        if [[ -z "$plan" ]]; then
            info "${id}: other packages still use these libraries — nothing to remove"
            echo -e "  ${DIM}They stay as dependencies, and go when nothing needs them any more.${NC}"
            log_action "PACKAGE: released ${id} (${present}) — still needed by other packages"
            return 0
        fi
    fi

    local plan_line; plan_line=$(tr '\n' ' ' <<< "$plan" | sed 's/ $//')
    echo ""
    echo -e "  ${BOLD}apt would remove $(wc -w <<< "$plan_line") package(s):${NC}"
    echo -e "  ${DIM}${plan_line}${NC}" | fold -s -w 78
    echo ""

    if [[ "${ARG_yes:-}" != "true" ]] && ! _pkg_forced; then
        if [[ ! -t 0 ]] || ! confirm "Purge them?"; then
            # shellcheck disable=SC2086
            [[ -n "$manual" ]] && apt-mark manual $manual >/dev/null 2>&1
            if [[ ! -t 0 ]]; then error "Removing packages is never implicit: pass --yes"; exit 1; fi
            info "Aborted"
            return 0
        fi
    fi

    step "Purging ${plan_line}..."
    # shellcheck disable=SC2086
    if ! _pkg_apt purge -y -qq $plan_line; then
        error "apt-get purge failed for: ${plan_line}"
        exit 1
    fi

    if [[ "${ARG_autoremove:-}" == "true" ]] && ! _pkg_from_panel && [[ -n "$before" ]]; then
        step "Removing the orphans that were already there..."
        _pkg_apt autoremove -y -qq || warn "autoremove reported a problem"
    fi

    log_action "PACKAGE: removed ${id} (${plan_line})"
    cipi_notify \
        "Cipi: package removed from $(hostname)" \
        "An optional package was removed.\n\nServer: $(hostname)\nEntry: ${id}\nPackages: ${plan_line}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        package_remove

    echo ""
    success "${id} removed"
    echo -e "  ${DIM}Any app still using it will now fail — check before deploying.${NC}"
    echo ""
}

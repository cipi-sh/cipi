#!/bin/bash
#############################################
# Cipi — Optional app packages (allowlisted)
#
# Tools a Laravel project may need on the host — image optimisers, ffmpeg,
# pdftotext, OCR, office conversion, security scanners — and the libraries
# some need to run (the Chrome Puppeteer downloads for Browsershot), on
# request: from Ubuntu's own repositories, or as pinned upstream releases.
#
# The allowlist is the whole point. `cipi package install <anything>` would be
# a root apt shell with extra steps; the catalog below is a closed set that
# every entry has to earn:
#
#   * stateless: binaries or shared libraries and fonts — no daemon, no port,
#     no credentials, no state that outlives the process,
#   * from an Ubuntu repository, so Ubuntu ships the security updates — or,
#     when Ubuntu does not ship it or ships it too old (the scanners Hackly
#     runs), an upstream release pinned in this file by version and SHA-256
#     (a git tag by its commit), so the server never resolves "latest" and a
#     download that does not match is refused; a newer version is a newer
#     Cipi release (5.14.0, see _pkg_upstream),
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
sec-recon|nmap bind9-dnsutils whois|nmap dig whois|Port scanning, DNS and WHOIS for security scanners (Hackly target scans)
sec-gitleaks|gitleaks|gitleaks|Secrets in source code (Gitleaks) for security scanners (Hackly repository scans)
EOF
}

# ── Upstream entries (5.14.0) ─────────────────────────────────
# What Ubuntu does not ship, or ships too old for the package that needs it:
# the scanners of Hackly (github.com/andreapollastri/hackly). Ubuntu has no
# nuclei, ZAP, WPScan, Trivy, Semgrep or Checkov, and its Nikto is 2.1.5
# (2014), which writes no JSON.
#
# Each one is pinned here to one version, and the bytes of that version to
# what _pkg_pins says: the SHA-256 of the download, or for a git tag the
# commit it must point to. Python and Ruby tools are pinned by version and
# installed into a directory of their own (their dependencies come from PyPI
# and RubyGems as pip and gem resolve them). scripts/package-pins.sh
# refreshes the pins from upstream for a release.
#
# Everything an entry installs lives in /opt/cipi/packages/<id>/<version>,
# `current` points at the live version, and its commands are linked into
# /usr/local/bin — a command that is already there and is not Cipi's is left
# alone. A .deb is installed by apt. The apt packages an entry needs (a Java
# runtime, Ruby, Perl modules) come and go with it; build tools are there
# for the build only. ZAP needs Java 17 or later: 21, 17, or whatever the
# release calls its default once those are gone.
#
# id|method|version|apt dependencies|apt build-only|commands (name=path)|description
_pkg_upstream() {
    cat <<'EOF'
sec-nuclei|zip|3.11.1|||nuclei=nuclei|Template-based vulnerability scanner (nuclei) for Hackly DAST, path discovery and pentests
sec-zap|tar|2.17.0|openjdk-21-jre-headless/openjdk-17-jre-headless/default-jre-headless||zap.sh=zap.sh|OWASP ZAP, headless, with a Java runtime, for Hackly baseline and pentest scans
sec-nikto|git|2.6.1|perl libnet-ssleay-perl libio-socket-ssl-perl libxml-writer-perl||nikto=cipi-bin/nikto|Nikto web server scanner, 2.6 with JSON reports (Ubuntu ships 2.1.5), for Hackly pentests
sec-wpscan|gem|3.8.28|ruby libcurl4t64/libcurl4|ruby-dev build-essential zlib1g-dev|wpscan=cipi-bin/wpscan|WPScan WordPress scanner for Hackly pentests of WordPress targets
sec-trivy|deb|0.76.2|||trivy=/usr/bin/trivy|Trivy dependency and misconfiguration scanner for Hackly repository scans (SCA)
sec-semgrep|venv|1.185.0|python3-venv||semgrep=cipi-bin/semgrep|Semgrep static analysis for Hackly repository scans (SAST)
sec-checkov|venv|3.3.26|python3-venv||checkov=cipi-bin/checkov|Checkov infrastructure-as-code scanner for Hackly repository scans
EOF
}

# id|arch (amd64, arm64, or all)|URL|SHA-256 of the download (git: commit of the tag)
#
# Where they come from (scripts/package-pins.sh fetches and compares them):
# sec-nuclei and sec-trivy the release's <name>_<v>_checksums.txt; sec-zap
# ZapVersions.xml of zaproxy/zap-admin; sec-nikto refs/tags/2.6.1^{}. The
# 5.14.0 pins were also checked against the downloaded files. Every download
# is a GitHub release asset, which stays where it is: Aqua's apt repository
# has the same Trivy .deb (same SHA-256) but keeps only the latest few. An entry without a
# hash cannot be installed, and tests/verify-5.14.0.sh fails until it has one.
_pkg_pins() {
    cat <<'EOF'
sec-nuclei|amd64|https://github.com/projectdiscovery/nuclei/releases/download/v3.11.1/nuclei_3.11.1_linux_amd64.zip|ea63d4ae232808cd7c6bc00d0142428e231fab59dae01042246097d195835ab6
sec-nuclei|arm64|https://github.com/projectdiscovery/nuclei/releases/download/v3.11.1/nuclei_3.11.1_linux_arm64.zip|8044e3d9768ba0a744b2872c1a87e813006f013da97ca9f50f7661a4203bec07
sec-zap|all|https://github.com/zaproxy/zaproxy/releases/download/v2.17.0/ZAP_2.17.0_Linux.tar.gz|efe799aaa3627db683b43f00c9c210aea0b75c00cc8f0a0f0434d12bb3ddde5a
sec-nikto|all|https://github.com/sullo/nikto.git|d201dac320fc5187eac75e723dd07a716196ec5a
sec-trivy|amd64|https://github.com/aquasecurity/trivy/releases/download/v0.76.2/trivy_0.76.2_Linux-64bit.deb|7edaf64c8a2a0ae02137f776c6e56adf285fc36ec76b045274afdc462f20f092
sec-trivy|arm64|https://github.com/aquasecurity/trivy/releases/download/v0.76.2/trivy_0.76.2_Linux-ARM64.deb|0c576cd78352a2084435d393ea31565a3637cc129dd052c422f1e72fd678ee76
EOF
}

_pkg_ids()       { _pkg_catalog | cut -d'|' -f1; _pkg_upstream | cut -d'|' -f1; }
_pkg_apt_for()   { _pkg_catalog | awk -F'|' -v i="$1" '$1 == i { print $2; exit }'; }
_pkg_bins_for() {
    if _pkg_is_up "$1"; then _pkg_up_cmds "$1" | paste -sd' ' -; return 0; fi
    _pkg_catalog | awk -F'|' -v i="$1" '$1 == i { print $3; exit }'
}
_pkg_desc_for() {
    _pkg_catalog | awk -F'|' -v i="$1" '$1 == i { print $4; exit }'
    _pkg_up_field "$1" 7
}
_pkg_kind_for()  { [[ -n "$(_pkg_bins_for "$1")" ]] && echo tools || echo libraries; }

_pkg_is_up()     { [[ -n "$1" ]] && _pkg_upstream | awk -F'|' -v i="$1" '$1 == i { f = 1 } END { exit !f }'; }
_pkg_up_field()  { _pkg_upstream | awk -F'|' -v i="$1" -v f="$2" '$1 == i { print $f; exit }'; }
_pkg_up_cmds()   { local c; for c in $(_pkg_up_field "$1" 6); do printf '%s\n' "${c%%=*}"; done; }
_pkg_up_path()   { local c; for c in $(_pkg_up_field "$1" 6); do [[ "${c%%=*}" == "$2" ]] && { printf '%s' "${c#*=}"; return 0; }; done; return 1; }
# Fixed paths, not read from the environment (tests redefine the functions).
_pkg_up_root()   { printf '%s' /opt/cipi/packages; }
_pkg_up_bindir() { printf '%s' /usr/local/bin; }
_pkg_python()    { printf '%s' python3; }
_pkg_lock_file() { printf '%s' /run/lock/cipi-package.lock; }
_pkg_up_dir()    { printf '%s/%s' "$(_pkg_up_root)" "$1"; }
_pkg_arch()      { dpkg --print-architecture 2>/dev/null || echo amd64; }
# URL|hash for this machine, or nothing.
_pkg_up_pin()    { _pkg_pins | awk -F'|' -v i="$1" -v a="$2" '$1 == i && ($2 == a || $2 == "all") { print $3 "|" $4; exit }'; }
# The version `current` points at, or nothing.
_pkg_up_current() {
    local l; l=$(readlink "$(_pkg_up_dir "$1")/current" 2>/dev/null) || return 1
    [[ -n "$l" ]] && printf '%s' "${l##*/}"
}

package_command() {
    local sub="${1:-list}"; shift || true
    case "$sub" in
        list|status)    _pkg_list "$@" ;;
        install|add)    _pkg_lock; _pkg_install "$@" ;;
        remove|uninstall|delete) _pkg_lock; _pkg_remove "$@" ;;
        help|--help|-h) show_help package ;;
        *)
            error "Unknown package subcommand: ${sub}"
            echo -e "  Usage: ${CYAN}cipi package <list|install|remove> [name]${NC}"
            exit 1
            ;;
    esac
}

# fd 9 is the lock of _pkg_lock: not handed to apt, whose maintainer scripts
# may start something that outlives this command. No pty for dpkg: its
# "(Reading database ... 5%" progress would fill the panel's job output.
_pkg_apt() {
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 -o Dpkg::Use-Pty=0 "$@" 9>&-
}

# One install or remove at a time: the panel's queue and a shell can meet, and
# an upstream entry is built in place under /opt/cipi/packages.
_pkg_lock() {
    { exec 9>"$(_pkg_lock_file)"; } 2>/dev/null || return 0
    flock -w 300 9 && return 0
    error "Another cipi package install or remove is still running — try again when it ends"
    exit 1
}

# The panel runs these through sudo as www-data. It passes --yes; what it
# passes besides does not get past a guard (the disk check) or reach beyond
# the entry (a server-wide autoremove).
_pkg_from_panel() { [[ "${SUDO_USER:-}" == "www-data" ]]; }
_pkg_forced()     { [[ "${ARG_force:-}" == "true" ]] && ! _pkg_from_panel; }

# One line per architecture of a package: installed when one of them is.
# `cipi package list` asks about some 60 packages several times each: it
# primes _PKG_DPKG with one dpkg-query instead (each one reads the whole
# dpkg database — seconds on a server, with the panel waiting).
declare -gA _PKG_DPKG=()
_PKG_DPKG_PRIMED=""
_pkg_dpkg_installed() {
    if [[ -n "$_PKG_DPKG_PRIMED" ]]; then
        [[ "${_PKG_DPKG[$1]:-}" == installed ]]
        return
    fi
    local st; st=$(dpkg-query -W -f='${db:Status-Status}\n' "$1" 2>/dev/null || true)
    grep -qx installed <<< "$st"
}
_pkg_dpkg_prime() {
    local names name status out
    names=$( { _pkg_catalog | cut -d'|' -f2; _pkg_upstream | cut -d'|' -f4,5 | tr '|' ' '
               _pkg_pins | awk -F'|' '$3 ~ /\.deb$/ { n = $3; sub(/.*\//, "", n); sub(/_.*/, "", n); print n }'
             } | tr ' /' '\n\n' | sed '/^$/d' | sort -u)
    # shellcheck disable=SC2086
    out=$(dpkg-query -W -f='${Package} ${db:Status-Status}\n' $names 2>/dev/null || true)
    _PKG_DPKG=()
    while read -r name status; do
        [[ -n "$name" ]] || continue
        [[ "$status" == installed || -z "${_PKG_DPKG[$name]:-}" ]] && _PKG_DPKG[$name]="$status"
    done <<< "$out"
    _PKG_DPKG_PRIMED=1
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
# `image-optimizers` both work — a sec- entry without its prefix (`zap`), or
# a command of an upstream entry: `nuclei` and `zap.sh` are sec-nuclei, sec-zap.
_pkg_resolve() {
    local want="$1" id p alt
    for id in $(_pkg_ids); do
        [[ "$want" == "$id" || "sec-${want}" == "$id" ]] && { printf '%s' "$id"; return 0; }
    done
    local cmds
    for id in $(_pkg_upstream | cut -d'|' -f1); do
        cmds=$(_pkg_up_cmds "$id")
        if grep -qxF -- "$want" <<< "$cmds"; then
            printf '%s' "$id"
            return 0
        fi
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
    echo -e "  ${DIM}Ubuntu's own repositories, or upstream releases pinned by version and checksum.${NC}"
    echo -e "  ${DIM}Anything with a daemon, a port or its own state is a service — see${NC}"
    echo -e "  ${DIM}'cipi search', 'cipi db install'.${NC}"
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

# Partly installed, as far as it matters: some items but not all, and one of
# them installed on purpose (manual). What other packages pulled in does not
# make an entry half-installed: libraries, or dig on a server whose image has
# it (sec-recon would read as partial before anyone asked for it).
_pkg_partial() {
    local id="$1" state="$2" p name present=""
    [[ "${state%/*}" != "0" && "${state%/*}" != "${state#*/}" ]] || return 1
    for p in $(_pkg_apt_for "$id"); do
        name=$(_pkg_item_installed "$p") && present="${present} ${name}"
    done
    # shellcheck disable=SC2086
    [[ -n "$(apt-mark showmanual $present 2>/dev/null)" ]]
}

_pkg_list() {
    parse_args "$@"
    _pkg_dpkg_prime

    # One row per entry — id, source, kind, apt names, binaries, missing,
    # state (installed | partial | outdated | absent), pinned version,
    # installed version, have/total, description — separated by the unit
    # separator: `read` drops empty fields between tabs.
    local S=$'\x1f'
    local rows="" id apt bins desc p names missing state st kind
    while IFS='|' read -r id apt bins desc; do
        [[ -n "$id" ]] || continue
        names=""; missing=""
        for p in $apt; do
            names="${names} $(_pkg_item_name "$p")"
            _pkg_item_installed "$p" >/dev/null || missing="${missing} ${p%%/*}"
        done
        state=$(_pkg_state "$id")
        if [[ "${state%/*}" == "${state#*/}" ]]; then st=installed
        elif _pkg_partial "$id" "$state"; then st=partial
        else st=absent; fi
        kind=tools; [[ -z "$bins" ]] && kind=libraries
        rows+="${id}${S}ubuntu${S}${kind}${S}${names# }${S}${bins}${S}${missing# }${S}${st}${S}${S}${S}${state}${S}${desc}"$'\n'
    done <<< "$(_pkg_catalog)"
    local method version deps build cmds c cur
    while IFS='|' read -r id method version deps build cmds desc; do
        [[ -n "$id" ]] || continue
        names=""; bins=""
        for p in $deps; do names="${names} $(_pkg_item_name "$p")"; done
        for c in $cmds; do bins="${bins} ${c%%=*}"; done
        st=$(_pkg_up_state "$id"); cur=$(_pkg_up_current "$id") || cur=""
        missing=$(_pkg_up_missing "$id" "$st" | paste -sd' ' -)
        rows+="${id}${S}upstream${S}tools${S}${names# }${S}${bins# }${S}${missing}${S}${st}${S}${version}${S}${cur}${S}${S}${desc}"$'\n'
    done <<< "$(_pkg_upstream)"

    if [[ "${ARG_json:-}" == "true" ]]; then
        jq -R -s '
            def words: split(" ") | map(select(. != ""));
            def orNull: if . == "" then null else . end;
            {packages: [split("\n")[] | select(length > 0) | split("\u001f") | {
                id: .[0], packages: (.[3] | words), description: .[10], kind: .[2],
                binaries: (.[4] | words), missing: (.[5] | words),
                installed: (.[6] == "installed"), partial: (.[6] == "partial"),
                source: .[1], version: (.[7] | orNull), installed_version: (.[8] | orNull),
                outdated: (.[6] == "outdated")}]}' <<< "$rows"
        return 0
    fi

    echo -e "\n${BOLD}Optional packages${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    local source _kind have
    while IFS="$S" read -r id source _kind names bins missing st version cur have desc; do
        [[ -n "$id" ]] || continue
        case "$st" in
            installed) printf "  ${GREEN}●${NC} %-18s ${DIM}%s${NC}\n" "$id" "$desc" ;;
            outdated)  printf "  ${YELLOW}◐${NC} %-18s ${YELLOW}%s${NC}\n" "$id" "${cur} installed, ${version} available — cipi package install ${id}" ;;
            partial)
                if [[ "$source" == upstream ]]; then
                    printf "  ${YELLOW}◐${NC} %-18s ${DIM}%s${NC}\n" "$id" "missing: ${missing} — cipi package install ${id}"
                else
                    printf "  ${YELLOW}◐${NC} %-18s ${DIM}%s${NC}\n" "$id" "partially installed (${have})"
                fi ;;
            *)         printf "  ${DIM}○${NC} %-18s ${DIM}%s${NC}\n" "$id" "$desc" ;;
        esac
        [[ "$source" == upstream ]] && names="upstream ${version}${names:+ · ${names}}"
        printf "    ${DIM}%s${NC}\n" "$names" | fold -s -w 76 | sed '2,$s/^/    /'
    done <<< "$rows"
    echo ""
    echo -e "  ${CYAN}cipi package install <name>${NC}   ${DIM}/  remove <name>${NC}"
    echo ""
    echo -e "  ${DIM}Already in the base stack: the Imagick PHP extension, Ghostscript and${NC}"
    echo -e "  ${DIM}fonts-dejavu-core (pulled in as Recommends of php-imagick), Node 22 (cipi node).${NC}"
    echo ""
}

# $1: KB needed (1 GB), $2: where (/var, where apt works).
_pkg_check_disk() {
    local need="${1:-$PKG_MIN_DISK_KB}" where="${2:-/var}"
    local free; free=$(df -Pk "$where" 2>/dev/null | awk 'NR==2 {print $4}')
    [[ "${free:-0}" -ge "$need" ]] && return 0
    if _pkg_forced; then
        warn "Only $(( ${free:-0} / 1024 ))MB free on ${where} — continuing because --force"
        return 0
    fi
    error "Less than $((need / 1024))MB free on ${where} (have $(( ${free:-0} / 1024 ))MB)"
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
        sec-nuclei)
            echo -e "  ${DIM}Templates are per user: Hackly keeps them in storage/app/nuclei-home and${NC}"
            echo -e "  ${DIM}updates them itself (nuclei -update-templates as the app user otherwise).${NC}"
            ;;
        sec-zap)
            echo -e "  ${YELLOW}ZAP takes about 1 GB of RAM while it scans:${NC} ${DIM}keep it off small servers${NC}"
            echo -e "  ${DIM}that also serve production apps. Hackly starts it per scan; no service runs.${NC}"
            ;;
        sec-wpscan)
            echo -e "  ${DIM}WordPress vulnerability data needs a WPScan API token (HACKLY_WPSCAN_API_TOKEN).${NC}"
            ;;
        sec-trivy)
            echo -e "  ${DIM}Trivy downloads its vulnerability database on the first scan, into the cache${NC}"
            echo -e "  ${DIM}of the user that runs it.${NC}"
            ;;
    esac
    [[ "$1" == sec-* ]] && echo -e "  ${DIM}Hackly finds it on PATH: php artisan hackly:check-binaries${NC}"
    return 0
}

# ── Upstream entries: state, install, remove ──────────────────

[[ -z "${PKG_UP_MIN_DISK_KB:-}" ]] && readonly PKG_UP_MIN_DISK_KB=2097152

# The project name of a pip or gem entry: sec-semgrep → semgrep.
_pkg_up_name()    { printf '%s' "${1#sec-}"; }
# The package name of a .deb entry: its pinned file's, up to "_".
_pkg_up_debname() {
    local u; u=$(_pkg_pins | awk -F'|' -v i="$1" '$1 == i { print $3; exit }')
    u="${u##*/}"; printf '%s' "${u%%_*}"
}

# A command of an entry works: its link resolves into the entry's current
# version — or, for a .deb, apt has the package and the command is on PATH.
_pkg_up_cmd_ok() {
    local id="$1" c="$2" path link
    path=$(_pkg_up_path "$id" "$c") || return 1
    if [[ "$path" == /* ]]; then
        _pkg_dpkg_installed "$(_pkg_up_debname "$id")" && command -v "$c" >/dev/null 2>&1
        return
    fi
    link="$(_pkg_up_bindir)/${c}"
    [[ -x "$link" ]] || return 1
    [[ "$(readlink -f "$link")" == "$(readlink -f "$(_pkg_up_dir "$id")/current/${path}")" ]]
}

# installed | outdated (an older pinned version) | partial | absent
_pkg_up_state() {
    local id="$1" cur c
    cur=$(_pkg_up_current "$id") || cur=""
    [[ -z "$cur" ]] && { echo absent; return 0; }
    [[ "$cur" != "$(_pkg_up_field "$id" 3)" ]] && { echo outdated; return 0; }
    for c in $(_pkg_up_cmds "$id"); do
        _pkg_up_cmd_ok "$id" "$c" || { echo partial; return 0; }
    done
    echo installed
}

# The commands that do not work: all of them when absent. $2: the state, when
# the caller has it already.
_pkg_up_missing() {
    local id="$1" c st="${2:-}"
    [[ -n "$st" ]] || st=$(_pkg_up_state "$id")
    [[ "$st" == installed || "$st" == outdated ]] && return 0
    for c in $(_pkg_up_cmds "$id"); do
        [[ "$st" == partial ]] && _pkg_up_cmd_ok "$id" "$c" && continue
        printf '%s\n' "$c"
    done
}

# Commands already on the server that are not Cipi's: installed by hand or by
# another script — Hackly's own installers put nuclei and zap.sh in
# /usr/local/bin. A .deb apt has without a Cipi record of it counts too.
_pkg_up_foreign() {
    local id="$1" c path link out=""
    for c in $(_pkg_up_cmds "$id"); do
        path=$(_pkg_up_path "$id" "$c")
        if [[ "$path" == /* ]]; then
            if _pkg_dpkg_installed "$(_pkg_up_debname "$id")" && [[ -z "$(_pkg_up_current "$id")" ]]; then
                out="${out} $(_pkg_up_debname "$id") (apt)"
            fi
            continue
        fi
        link="$(_pkg_up_bindir)/${c}"
        [[ -e "$link" || -L "$link" ]] || continue
        [[ -L "$link" && "$(readlink "$link")" == "$(_pkg_up_dir "$id")/"* ]] && continue
        out="${out} ${link}"
    done
    printf '%s' "${out# }"
}

# Download a pinned file and check it against its SHA-256. A mismatch is
# refused and deleted: never "close enough", never retried from elsewhere.
_pkg_up_download() {
    local url="$1" out="$2" want="$3" got
    step "Downloading ${url##*/}..."
    # https only, redirects included; a transfer that stalls is given up
    # (under 1 kB/s for a minute) rather than left hanging in the panel's job.
    if ! curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 --retry 3 --retry-delay 2 \
            --connect-timeout 20 --speed-limit 1024 --speed-time 60 -o "$out" "$url"; then
        error "Download failed: ${url}"
        return 1
    fi
    got=$(sha256sum "$out" | awk '{print $1}')
    if [[ "$got" != "$want" ]]; then
        rm -f "$out"
        error "Checksum mismatch for ${url##*/} — refused"
        echo "  pinned   ${want}"
        echo "  received ${got}"
        return 1
    fi
    info "SHA-256 matches the pin"
}

# The wrappers an entry needs in cipi-bin/: an interpreter, an environment.
_pkg_up_wrappers() {
    local id="$1" dest="$2" out="$3"
    mkdir -p "${out}/cipi-bin"
    case "$id" in
        sec-nikto)
            printf '#!/bin/sh\n# Cipi: Nikto %s (cipi package)\nexec /usr/bin/perl %s/src/program/nikto.pl "$@"\n' \
                "${dest##*/}" "$dest" > "${out}/cipi-bin/nikto" ;;
        sec-wpscan)
            printf '#!/bin/sh\n# Cipi: WPScan %s (cipi package)\nexport GEM_HOME=%s GEM_PATH=%s\nexec %s/bin/wpscan "$@"\n' \
                "${dest##*/}" "$dest" "$dest" "$dest" > "${out}/cipi-bin/wpscan" ;;
        sec-semgrep|sec-checkov)
            # The virtualenv first on PATH, as when it is activated: semgrep
            # starts its own helpers (pysemgrep, semgrep-core) by name, and
            # must find its own — not what a pipx install left in /usr/local/bin.
            printf '#!/bin/sh\n# Cipi: %s %s (cipi package)\nPATH="%s/bin:$PATH" exec %s/bin/%s "$@"\n' \
                "$(_pkg_up_name "$id")" "${dest##*/}" "$dest" "$dest" "$(_pkg_up_name "$id")" > "${out}/cipi-bin/$(_pkg_up_name "$id")" ;;
    esac
    chmod 755 "${out}/cipi-bin/"* 2>/dev/null || true
}

# apt packages an entry no longer answers for ($1: build tools after the
# build, dependencies of an install that failed): back to dependencies, and
# whatever that leaves unneeded goes — not orphans that were there before
# ($2), nor what another package needs. $3: what to call them.
_pkg_up_release() {
    local pkgs before="$2" what="${3:-the build tools}" plan
    pkgs=$(tr ' ' '\n' <<< "$1" | sed '/^$/d' | sort -u | paste -sd' ' -)
    [[ -z "$pkgs" ]] && return 0
    # shellcheck disable=SC2086
    apt-mark auto $pkgs >/dev/null 2>&1 || true
    plan=$(_pkg_minus "$(_pkg_orphans)" "$before")
    [[ -z "$plan" ]] && return 0
    step "Removing ${what}..."
    # shellcheck disable=SC2086
    _pkg_apt purge -y -qq $(tr '\n' ' ' <<< "$plan") || warn "apt-get purge reported a problem"
}

_pkg_up_install() {
    local id="$1"
    local method version deps build dir arch cur st pin="" url="" hash=""
    method=$(_pkg_up_field "$id" 2); version=$(_pkg_up_field "$id" 3)
    deps=$(_pkg_up_field "$id" 4); build=$(_pkg_up_field "$id" 5)
    dir=$(_pkg_up_dir "$id"); arch=$(_pkg_arch)
    cur=$(_pkg_up_current "$id") || cur=""
    st=$(_pkg_up_state "$id")

    if [[ "$st" == installed ]]; then
        success "${id} ${version} is already installed"
        return 0
    fi

    case "$method" in
        zip|tar|deb|git)
            pin=$(_pkg_up_pin "$id" "$arch"); url="${pin%%|*}"; hash="${pin#*|}"
            if [[ -z "$pin" || -z "$hash" ]]; then
                error "This Cipi release has no verified checksum for ${id} ${version} (${arch}) — nothing installed"
                echo "  Every download is checked against a hash pinned in Cipi; without one it is not made."
                echo "  A later release pins it: cipi self-update"
                exit 1
            fi
            ;;
    esac

    local foreign; foreign=$(_pkg_up_foreign "$id")
    if [[ -n "$foreign" ]] && ! _pkg_forced; then
        error "Already on this server, and not installed by Cipi: ${foreign}"
        echo "  Installed by hand or by another script (Hackly's own installers, say)."
        echo "  Remove it, or replace it with --force at the server's shell."
        exit 1
    fi

    # Room where it is unpacked (the nearest directory that exists) and
    # where apt works.
    local where; where=$(_pkg_up_root)
    while [[ ! -d "$where" && "$where" == */* && -n "${where%/*}" ]]; do where="${where%/*}"; done
    _pkg_check_disk "$PKG_UP_MIN_DISK_KB" "$where" || exit 1
    _pkg_check_disk || exit 1

    # What apt has to install, and what is there already only as a dependency
    # of something else (Java, for pdftk): that is kept for this entry too,
    # or removing the other package would take it away under this one.
    local p pick name need_deps="" need_build="" unknown="" hold=""
    if [[ -n "${deps}${build}" ]]; then
        step "Refreshing the package index..."
        _pkg_apt update -qq || warn "apt-get update reported a problem — continuing"
    fi
    for p in $deps; do
        if name=$(_pkg_item_installed "$p"); then
            [[ -n "$(apt-mark showauto "$name" 2>/dev/null)" ]] && hold="${hold} ${name}"
            continue
        fi
        if pick=$(_pkg_item_pick "$p"); then need_deps="${need_deps} ${pick}"; else unknown="${unknown} ${p}"; fi
    done
    hold="${hold# }"
    for p in $build; do
        _pkg_item_installed "$p" >/dev/null && continue
        if pick=$(_pkg_item_pick "$p"); then need_build="${need_build} ${pick}"; else unknown="${unknown} ${p}"; fi
    done
    need_deps="${need_deps# }"; need_build="${need_build# }"
    if [[ -n "$unknown" ]]; then
        error "apt has no candidate for:${unknown//\// or } — nothing installed"
        exit 1
    fi

    echo ""
    echo -e "  ${BOLD}${id} ${version}${NC} ${DIM}— upstream, into ${dir}/${version}${NC}"
    case "$method" in
        zip|tar|deb) echo -e "  ${DIM}download  ${url}${NC}"; echo -e "  ${DIM}sha-256   ${hash}${NC}" ;;
        git)         echo -e "  ${DIM}git       ${url} @ ${version} (commit ${hash})${NC}" ;;
        venv)        echo -e "  ${DIM}pip       $(_pkg_up_name "$id")==${version}, in a virtualenv of its own${NC}" ;;
        gem)         echo -e "  ${DIM}gem       $(_pkg_up_name "$id") ${version}, in a gem home of its own${NC}" ;;
    esac
    [[ -n "$need_deps" ]] && echo -e "  ${DIM}apt       ${need_deps}${NC}"
    [[ -n "$need_build" ]] && echo -e "  ${DIM}apt, for the build only: ${need_build}${NC}"
    if [[ -n "$cur" && "$cur" != "$version" ]]; then
        echo -e "  ${DIM}replaces  ${cur}${NC}"
    elif [[ -n "$cur" ]]; then
        echo -e "  ${DIM}repairs   ${cur}, which is incomplete${NC}"
    fi
    echo ""

    if [[ "${ARG_yes:-}" != "true" ]] && ! _pkg_forced; then
        if [[ ! -t 0 ]]; then
            error "Installing packages is never implicit: pass --yes"
            exit 1
        fi
        confirm "Install ${id} ${version}?" || { info "Aborted"; return 0; }
    fi

    # What apt installed for the version this replaces (or completes): read
    # before anything of it is removed.
    local prev=""
    [[ -n "$cur" && -f "${dir}/${cur}/.cipi-package" ]] && prev=$(sed -n 's/^apt=//p' "${dir}/${cur}/.cipi-package" 2>/dev/null || true)

    local before=""; before=$(_pkg_orphans)
    if [[ -n "${need_deps}${need_build}" ]]; then
        step "Installing ${need_deps}${need_build:+ ${need_build}}..."
        # shellcheck disable=SC2086
        if ! _pkg_apt install -y -qq $need_deps $need_build; then
            error "apt-get install failed — nothing else was done"
            exit 1
        fi
    fi
    if [[ -n "$hold" ]]; then
        # shellcheck disable=SC2086
        apt-mark manual $hold >/dev/null 2>&1 || warn "apt-mark manual failed for: ${hold}"
    fi

    # Leftovers of an install that was killed (the lock says none is running).
    local dest="${dir}/${version}" work="${dir}/.work-${version}-$$" got
    mkdir -p "$dir"; chmod 755 "$(_pkg_up_root)" "$dir"
    rm -rf "$dir"/.work-* "$dir"/.current-* "$dest"; mkdir -p "$work"
    # What apt installed for the entry, kept with it: remove takes it away.
    _pkg_up_record() {
        local added
        added=$(printf '%s %s %s' "$prev" "$need_deps" "$hold" | tr ' ' '\n' | sed '/^$/d' | sort -u | paste -sd' ' -)
        {
            echo "id=${id}"; echo "version=${version}"; echo "method=${method}"
            echo "pin=${hash:-${version}}"; echo "apt=${added}"; echo "installed=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        } > "${1}/.cipi-package"
    }
    _pkg_up_fail() {
        rm -rf "$work" "$dest"
        if [[ "$cur" == "$version" ]]; then
            # A repair that failed: the entry stays, incomplete, with the record
            # of what apt installed for it — install again, or remove.
            mkdir -p "$dest"; _pkg_up_record "$dest"; chmod -R a+rX "$dest"
            _pkg_up_release "$need_build" "$before"
        else
            # Nothing of this version is left (an older one keeps working):
            # what apt installed for it goes back with the build tools.
            _pkg_up_release "${need_build} ${need_deps} ${hold}" "$before" "what apt installed for it"
        fi
        error "${id} ${version} was not installed"
        exit 1
    }

    case "$method" in
        zip)
            _pkg_up_download "$url" "${work}/dl.zip" "$hash" || _pkg_up_fail
            unzip -q -o "${work}/dl.zip" -d "${work}/out" || _pkg_up_fail
            ;;
        tar)
            _pkg_up_download "$url" "${work}/dl.tar.gz" "$hash" || _pkg_up_fail
            mkdir -p "${work}/out"
            tar -xzf "${work}/dl.tar.gz" -C "${work}/out" --strip-components=1 --no-same-owner || _pkg_up_fail
            ;;
        git)
            step "Cloning ${url} at ${version}..."
            git -c advice.detachedHead=false clone -q --depth 1 --branch "$version" "$url" "${work}/out/src" || _pkg_up_fail
            got=$(git -C "${work}/out/src" rev-parse HEAD 2>/dev/null)
            if [[ "$got" != "$hash" ]]; then
                error "${version} of ${url} is commit ${got:-?}, not the pinned ${hash} — refused"
                _pkg_up_fail
            fi
            rm -rf "${work}/out/src/.git"
            _pkg_up_wrappers "$id" "$dest" "${work}/out"
            ;;
        deb)
            _pkg_up_download "$url" "${work}/${url##*/}" "$hash" || _pkg_up_fail
            step "Installing ${url##*/}..."
            _pkg_apt install -y -qq --allow-downgrades "${work}/${url##*/}" || _pkg_up_fail
            mkdir -p "${work}/out"
            ;;
        venv)
            # A virtualenv is not relocatable: it is built where it stays.
            step "Installing $(_pkg_up_name "$id") ${version} from PyPI..."
            "$(_pkg_python)" -m venv "$dest" || _pkg_up_fail
            "${dest}/bin/pip" install -q --no-cache-dir --disable-pip-version-check "$(_pkg_up_name "$id")==${version}" || _pkg_up_fail
            [[ -x "${dest}/bin/$(_pkg_up_name "$id")" ]] || { error "pip installed $(_pkg_up_name "$id") ${version} without its command"; _pkg_up_fail; }
            _pkg_up_wrappers "$id" "$dest" "$dest"
            ;;
        gem)
            step "Installing $(_pkg_up_name "$id") ${version} from RubyGems..."
            mkdir -p "$dest"
            gem install --no-document --install-dir "$dest" --bindir "${dest}/bin" "$(_pkg_up_name "$id")" -v "$version" || _pkg_up_fail
            _pkg_up_wrappers "$id" "$dest" "$dest"
            ;;
    esac
    [[ -d "${work}/out" ]] && { mv -T "${work}/out" "$dest" || _pkg_up_fail; }
    rm -rf "$work"

    # The dependencies of the version it replaces carry over.
    _pkg_up_record "$dest"
    chmod -R a+rX "$dest"

    ln -sfn "$version" "${dir}/.current-$$" && mv -Tf "${dir}/.current-$$" "${dir}/current"
    local c path
    for c in $(_pkg_up_cmds "$id"); do
        path=$(_pkg_up_path "$id" "$c")
        [[ "$path" == /* ]] && continue
        mkdir -p "$(_pkg_up_bindir)"
        ln -sfn "${dir}/current/${path}" "$(_pkg_up_bindir)/${c}"
    done
    local d
    for d in "$dir"/*; do
        [[ -L "$d" || "${d##*/}" == "$version" ]] && continue
        rm -rf "$d"
    done

    _pkg_up_release "$need_build" "$before"

    local missing=""
    for c in $(_pkg_up_cmds "$id"); do
        _pkg_up_cmd_ok "$id" "$c" || missing="${missing} ${c}"
    done

    log_action "PACKAGE: installed ${id} ${version} (upstream ${method}${hash:+, ${hash}})"
    cipi_notify \
        "Cipi: package installed on $(hostname)" \
        "An optional package was installed.\n\nServer: $(hostname)\nEntry: ${id} ${version} (upstream)\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        package_install

    echo ""
    if [[ -n "$missing" ]]; then
        warn "Installed, but these are missing:${missing}"
    else
        success "${id} ${version} installed — $(_pkg_bins_for "$id" | tr ' ' ',') available"
    fi
    echo ""
    _pkg_notes "$id"
    echo ""
}

_pkg_up_remove() {
    local id="$1" dir cur method added="" deb="" before plan c link
    dir=$(_pkg_up_dir "$id"); method=$(_pkg_up_field "$id" 2)
    cur=$(_pkg_up_current "$id") || cur=""
    if [[ -z "$cur" && ! -d "$dir" ]]; then
        info "${id} is not installed"
        if [[ -n "$(_pkg_up_foreign "$id")" ]]; then
            echo -e "  ${DIM}What is here was not installed by Cipi: $(_pkg_up_foreign "$id")${NC}"
        fi
        return 0
    fi
    [[ -n "$cur" ]] && added=$(sed -n 's/^apt=//p' "${dir}/${cur}/.cipi-package" 2>/dev/null || true)
    if [[ "$method" == deb ]] && _pkg_dpkg_installed "$(_pkg_up_debname "$id")"; then
        deb=$(_pkg_up_debname "$id")
    fi

    echo ""
    echo -e "  ${BOLD}Removes ${id}${cur:+ ${cur}}:${NC} ${DIM}${dir}, $(_pkg_bins_for "$id")${deb:+, the ${deb} package}${NC}"
    [[ -n "$added" ]] && echo -e "  ${DIM}and what apt installed for it (${added}) unless something else needs it${NC}"
    echo ""
    if [[ "${ARG_yes:-}" != "true" ]] && ! _pkg_forced; then
        if [[ ! -t 0 ]]; then error "Removing packages is never implicit: pass --yes"; exit 1; fi
        confirm "Remove ${id}?" || { info "Aborted"; return 0; }
    fi

    before=$(_pkg_orphans)
    for c in $(_pkg_up_cmds "$id"); do
        link="$(_pkg_up_bindir)/${c}"
        [[ -L "$link" && "$(readlink "$link")" == "${dir}/"* ]] && rm -f "$link"
    done
    if [[ -n "$deb" ]]; then
        step "Purging ${deb}..."
        _pkg_apt purge -y -qq "$deb" || { error "apt-get purge failed for ${deb}"; exit 1; }
    fi
    rm -rf "$dir"

    local p still=""
    for p in $added; do _pkg_dpkg_installed "$p" && still="${still} ${p}"; done
    if [[ -n "$still" ]]; then
        # shellcheck disable=SC2086
        apt-mark auto $still >/dev/null 2>&1 || true
        plan=$(_pkg_minus "$(_pkg_orphans)" "$before")
        if [[ -n "$plan" ]]; then
            step "Purging what only ${id} needed: $(tr '\n' ' ' <<< "$plan" | sed 's/ $//')..."
            # shellcheck disable=SC2086
            _pkg_apt purge -y -qq $(tr '\n' ' ' <<< "$plan") || warn "apt-get purge reported a problem"
        fi
    fi

    log_action "PACKAGE: removed ${id}${cur:+ ${cur}} (upstream)"
    cipi_notify \
        "Cipi: package removed from $(hostname)" \
        "An optional package was removed.\n\nServer: $(hostname)\nEntry: ${id}${cur:+ ${cur}} (upstream)\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        package_remove

    echo ""
    success "${id} removed"
    echo -e "  ${DIM}Any app still using it will now fail — check before deploying.${NC}"
    echo ""
}

_pkg_install() {
    local want="${1:-}"; shift || true
    [[ -z "$want" ]] && { error "Usage: cipi package install <name>"; _pkg_list; exit 1; }
    parse_args "$@"

    local id; id=$(_pkg_resolve "$want") || { _pkg_refuse "$want"; exit 1; }
    if _pkg_is_up "$id"; then _pkg_up_install "$id"; return; fi
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
    if _pkg_is_up "$id"; then _pkg_up_remove "$id"; return; fi
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
        # A tool another package pulled in (dig, with ubuntu-standard) is that
        # package's: only what was installed on purpose goes (5.14.0).
        local own=""
        for p in $present; do
            [[ -n "$(apt-mark showmanual "$p" 2>/dev/null)" ]] && own="${own} ${p}"
        done
        present="${own# }"
        if [[ -z "$present" ]]; then
            info "${id} is not installed"
            echo -e "  ${DIM}The packages of it that are here were installed by other packages.${NC}"
            return 0
        fi
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

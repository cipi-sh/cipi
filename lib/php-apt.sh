#!/bin/bash
#############################################
# Cipi — PHP APT source helpers (ondrej / sury / Ubuntu archive)
#############################################

_cipi_apt_lock_timeout_opts='-o DPkg::Lock::Timeout=300'

# Direct dpkg does not honour DPkg::Lock::Timeout — wait before dpkg -i.
cipi_wait_for_dpkg_lock() {
    local timeout="${1:-300}"
    local waited=0
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
       || fuser /var/lib/dpkg/lock >/dev/null 2>&1; do
        if (( waited == 0 )); then
            echo "System updates in progress, waiting for dpkg to be available..." >&2
        fi
        sleep 2
        waited=$((waited + 2))
        if (( waited >= timeout )); then
            echo "Timed out waiting for dpkg lock after ${timeout}s" >&2
            return 1
        fi
    done
}

ubuntu_codename() {
    local cn
    cn="$(lsb_release -cs 2>/dev/null)"
    if [[ -z "$cn" ]]; then
        # shellcheck source=/dev/null
        . /etc/os-release 2>/dev/null || true
        cn="${VERSION_CODENAME:-noble}"
    fi
    echo "$cn"
}

_mariadb_repo_release_available() {
    local codename="$1"
    [[ -n "$codename" ]] || return 1
    case "$codename" in
        resolute|questing) return 1 ;;
    esac
    command -v curl >/dev/null 2>&1 || return 0
    curl -fsI --max-time 15 \
        "https://dlm.mariadb.com/repo/mariadb-server/11.4/repo/ubuntu/dists/${codename}/Release" \
        2>/dev/null | head -1 | grep -qE '^HTTP/[0-9.]+ 200'
}

# MariaDB.org 11.4 when the suite exists (noble, jammy, …); Ubuntu archive otherwise.
# Returns 0 when the third-party repo was configured, 1 when using Ubuntu main only.
mariadb_setup_apt_repo() {
    local codename
    codename="$(ubuntu_codename)"

    if [[ -f /etc/apt/sources.list.d/mariadb.list ]] \
       && ! _mariadb_repo_release_available "$codename"; then
        rm -f /etc/apt/sources.list.d/mariadb.list
    fi

    if _mariadb_repo_release_available "$codename"; then
        curl -fsSL https://mariadb.org/mariadb_release_signing_key.pgp \
            | gpg --dearmor -o /usr/share/keyrings/mariadb-keyring.gpg 2>/dev/null
        echo "deb [signed-by=/usr/share/keyrings/mariadb-keyring.gpg] https://dlm.mariadb.com/repo/mariadb-server/11.4/repo/ubuntu ${codename} main" \
            > /etc/apt/sources.list.d/mariadb.list
        return 0
    fi

    rm -f /etc/apt/sources.list.d/mariadb.list
    return 1
}

mariadb_apt_source_label() {
    local codename
    codename="$(ubuntu_codename)"
    if [[ -f /etc/apt/sources.list.d/mariadb.list ]] \
       && _mariadb_repo_release_available "$codename"; then
        echo "MariaDB.org 11.4"
    else
        echo "Ubuntu archive"
    fi
}

# Launchpad ppa:ondrej/php — used on LTS releases with a published suite (e.g. noble).
php_ondrej_ppa_available() {
    local codename="${1:-$(ubuntu_codename)}"
    [[ -n "$codename" ]] || return 1

    case "$codename" in
        resolute|questing) return 1 ;;
    esac

    command -v curl >/dev/null 2>&1 || return 0

    curl -fsI --max-time 15 \
        "https://ppa.launchpadcontent.net/ondrej/php/ubuntu/dists/${codename}/Release" \
        2>/dev/null | head -1 | grep -qE '^HTTP/[0-9.]+ 200'
}

# packages.sury.org — same maintainer/packages as ondrej; often ahead of Launchpad on new
# Ubuntu releases (e.g. resolute / 26.04). Required for co-installable php8.3/8.4/8.5/8.6.
php_sury_repo_available() {
    local codename="${1:-$(ubuntu_codename)}"
    [[ -n "$codename" ]] || return 1
    command -v curl >/dev/null 2>&1 || return 1
    curl -fsI --max-time 15 \
        "https://packages.sury.org/php/dists/${codename}/Release" \
        2>/dev/null | head -1 | grep -qE '^HTTP/[0-9.]+ 200'
}

php_remove_ondrej_ppa_sources() {
    add-apt-repository -y --remove ppa:ondrej/php &>/dev/null || true
    rm -f /etc/apt/sources.list.d/ondrej-ubuntu-php*.list \
          /etc/apt/sources.list.d/ondrej-ubuntu-php*.sources 2>/dev/null || true
}

php_remove_sury_repo() {
    rm -f /etc/apt/sources.list.d/php-sury.list /etc/apt/sources.list.d/php.list 2>/dev/null || true
}

# Returns 1, leaving no source behind, when the keyring cannot be installed.
php_setup_sury_repo() {
    local codename tmpdeb
    codename="$(ubuntu_codename)"

    apt-get $_cipi_apt_lock_timeout_opts install -y -qq ca-certificates curl

    tmpdeb=$(mktemp /tmp/debsuryorg-archive-keyring.XXXXXX) || return 1
    if ! curl -fsSL -o "$tmpdeb" https://packages.sury.org/debsuryorg-archive-keyring.deb; then
        rm -f "$tmpdeb"
        return 1
    fi
    cipi_wait_for_dpkg_lock
    dpkg -i "$tmpdeb" >/dev/null || { rm -f "$tmpdeb"; return 1; }
    rm -f "$tmpdeb"
    [[ -s /usr/share/keyrings/debsuryorg-archive-keyring.gpg ]] || return 1

    echo "deb [signed-by=/usr/share/keyrings/debsuryorg-archive-keyring.gpg] https://packages.sury.org/php/ ${codename} main" \
        > /etc/apt/sources.list.d/php-sury.list
}

# Configure PHP APT sources for co-installable versions (8.3 / 8.4 / 8.5 / 8.6).
# Priority: packages.sury.org → Launchpad ondrej PPA → Ubuntu archive only.
# Same maintainer and packages either way, but sury.org publishes first: on
# the 2026-10-21 security release it had the fixed builds for noble while
# the PPA was still building them. The PPA is removed only once sury.org is
# in place, so a failed keyring download leaves the PPA working.
# Returns 0 when a multi-version repo was configured, 1 when Ubuntu archive only.
php_setup_apt_sources() {
    local codename
    codename="$(ubuntu_codename)"

    if php_sury_repo_available "$codename" && php_setup_sury_repo; then
        php_remove_ondrej_ppa_sources
        return 0
    fi

    php_remove_sury_repo

    if php_ondrej_ppa_available "$codename"; then
        add-apt-repository -y ppa:ondrej/php &>/dev/null
        return 0
    fi

    php_remove_ondrej_ppa_sources
    return 1
}

# True when the PHP packages come from packages.sury.org.
php_sury_repo_configured() {
    [[ -f /etc/apt/sources.list.d/php-sury.list || -f /etc/apt/sources.list.d/php.list ]]
}

# The source this server is configured with, not the one it would pick.
php_apt_source_label() {
    if php_sury_repo_configured; then
        echo "packages.sury.org"
    elif compgen -G "/etc/apt/sources.list.d/ondrej-ubuntu-php*" >/dev/null; then
        echo "ondrej/php PPA"
    else
        echo "Ubuntu archive"
    fi
}

# Remove broken third-party APT entries left by a partial install (safe before apt-get update).
cipi_sanitize_broken_apt_sources() {
    local codename
    codename="$(ubuntu_codename)"
    [[ -n "$codename" ]] || return 0

    if [[ -f /etc/apt/sources.list.d/mariadb.list ]] \
       && ! _mariadb_repo_release_available "$codename"; then
        rm -f /etc/apt/sources.list.d/mariadb.list
    fi

    if ! php_ondrej_ppa_available "$codename"; then
        php_remove_ondrej_ppa_sources
    fi
}

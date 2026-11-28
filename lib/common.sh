#!/bin/bash
#############################################
# Cipi — Common Functions
#############################################

# When sourced outside the main cipi binary (e.g. migrations), CIPI_* may be unset.
# The main cipi script sets them readonly — only assign when unset (never touch readonly).
if [[ -z "${CIPI_LIB:-}" ]]; then
    CIPI_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
if [[ -z "${CIPI_CONFIG:-}" ]]; then
    CIPI_CONFIG="/etc/cipi"
fi
if [[ -z "${CIPI_LOG:-}" ]]; then
    CIPI_LOG="/var/log/cipi"
fi

source "${CIPI_LIB}/vault.sh"

info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { _CIPI_ERROR_SHOWN=1; echo -e "${RED}[ERROR]${NC} $*" >&2; }
success() { echo -e "${GREEN}✓${NC} $*"; }
step()    { echo -e "${CYAN}→${NC} $*"; }

log_action() {
    mkdir -p "${CIPI_LOG}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "${CIPI_LOG}/cipi.log"
}

log_event() {
    mkdir -p "${CIPI_LOG}"
    local ip; ip=$(_get_client_ip 2>/dev/null || echo "local")
    local key; key=$(_get_session_key_name 2>/dev/null || echo "n/a")
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${ip}] [key:${key}] $*" >> "${CIPI_LOG}/events.log"
}

_get_client_ip() {
    if [[ -n "${SSH_CLIENT:-}" ]]; then
        echo "${SSH_CLIENT%% *}"
    elif [[ -n "${SSH_CONNECTION:-}" ]]; then
        echo "${SSH_CONNECTION%% *}"
    else
        echo "local"
    fi
}

_get_session_key_name() {
    local fp=""

    # Method 1: SSH_USER_AUTH (requires ExposeAuthInfo=yes + env_keep in sudoers)
    # Format: publickey <key_type> <raw_key_data> — field 3 is raw key, not fingerprint
    local auth_file="${SSH_USER_AUTH:-}"
    if [[ -n "$auth_file" && -f "$auth_file" ]]; then
        local key_type key_data
        key_type=$(awk '/^publickey / {print $2; exit}' "$auth_file" 2>/dev/null)
        key_data=$(awk '/^publickey / {print $3; exit}' "$auth_file" 2>/dev/null)
        if [[ -n "$key_type" && -n "$key_data" ]]; then
            fp=$(echo "$key_type $key_data" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}')
        fi
    fi

    # Method 2: auth.log fallback
    if [[ -z "$fp" && -f /var/log/auth.log ]]; then
        local client_ip; client_ip=$(_get_client_ip)
        local login_user="${SUDO_USER:-cipi}"
        local log_line
        log_line=$(grep "Accepted publickey for ${login_user} from ${client_ip}" /var/log/auth.log 2>/dev/null | tail -1)
        [[ -n "$log_line" ]] && fp=$(echo "$log_line" | grep -o 'SHA256:[^ ]*')
    fi

    [[ -z "$fp" ]] && { echo "n/a"; return; }

    local ak="/home/cipi/.ssh/authorized_keys"
    [[ -f "$ak" ]] || { echo "$fp"; return; }

    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        local line_fp
        line_fp=$(echo "$line" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}')
        if [[ "$line_fp" == "$fp" ]]; then
            local comment
            comment=$(echo "$line" | awk '{$1=$2=""; print}' | xargs)
            [[ -n "$comment" ]] && { echo "$comment"; return; }
        fi
    done < "$ak"
    echo "$fp"
}

generate_password() { openssl rand -base64 64 | tr -dc 'a-zA-Z0-9' | head -c "${1:-40}"; }
generate_token()    { openssl rand -hex 32; }
generate_app_key()  { echo "base64:$(openssl rand -base64 32)"; }

validate_username() {
    local n="$1"
    [[ ! "$n" =~ ^[a-z][a-z0-9]{2,31}$ ]] && return 1
    local bad=("root" "admin" "www" "nginx" "mysql" "mariadb" "postgres" "pgsql" "redis" "valkey" "git" "deploy" "cipi" "ubuntu" "debian" "supervisor" "nobody" "postfix" "sshd" "clamav" "daemon" "bin" "sys")
    for b in "${bad[@]}"; do [[ "$n" == "$b" ]] && return 1; done
    return 0
}

validate_domain() {
    [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*\.[a-zA-Z]{2,}$ ]]
}

# Same, but also accepts a leading "*." wildcard. nginx matches wildcard
# server_names natively, and a multi-tenant app fronted by one certificate
# needs "*.example.com" as an alias rather than one entry per tenant.
# Never use this for the primary domain — only for aliases.
validate_domain_or_wildcard() {
    local d="$1"
    [[ "$d" == \*.* ]] && d="${d#\*.}"
    validate_domain "$d"
}

# True when the domain is a wildcard ("*.example.com").
domain_is_wildcard() { [[ "$1" == \*.* ]]; }

# Certificate lineage name for a domain. Certbot names a wildcard lineage after
# the bare domain — "*" is not a directory name and certbot rejects it as a
# --cert-name — so every `--cert-name` and every /etc/letsencrypt/live/<name>
# lookup has to go through this, or SSL silently misses the app.
domain_cert_name() { local d="$1"; printf '%s' "${d#\*.}"; }

# A concrete host to build a URL with. A wildcard server_name matches
# subdomains only, so "https://*.example.com" reaches nothing and a Git
# provider refuses it as a webhook URL: "www" stands in for the tenant.
domain_url_host() { local d="$1"; [[ "$d" == \*.* ]] && d="www.${d#\*.}"; printf '%s' "$d"; }

# Names a certificate needs so that it covers every name in the list, one per
# line. Let's Encrypt refuses an order where a name is already covered by a
# wildcard of the same order ("www.example.com is redundant with a wildcard
# domain in the same request"), so a name one label below a wildcard of the
# list is dropped. Deeper names stay: "*.example.com" does not cover
# "a.b.example.com" in a certificate (it does in nginx, which is why the
# list can hold both). Order is kept, duplicates go.
cert_names_for() {
    local -a names=() wild=()
    local n w covered
    for n in "$@"; do
        [[ -n "$n" ]] || continue
        domain_is_wildcard "$n" && wild+=("${n#\*.}")
    done
    for n in "$@"; do
        [[ -n "$n" ]] || continue
        if ! domain_is_wildcard "$n"; then
            covered=false
            for w in ${wild[@]+"${wild[@]}"}; do
                # one label, then the wildcard's base: "www" + ".example.com"
                if [[ "$n" == *".${w}" ]]; then
                    local label="${n%".${w}"}"
                    [[ "$label" != *.* ]] && { covered=true; break; }
                fi
            done
            [[ "$covered" == true ]] && continue
        fi
        local seen=false x
        for x in ${names[@]+"${names[@]}"}; do [[ "$x" == "$n" ]] && { seen=true; break; }; done
        [[ "$seen" == true ]] || names+=("$n")
    done
    [[ ${#names[@]} -gt 0 ]] && printf '%s\n' "${names[@]}"
    return 0
}

# ── App HTTPS (written by Cipi, not by certbot) ──────────────
#
# certbot issues and renews certificates; it never edits an app vhost. Its
# nginx installer cannot be driven non-interactively for a wildcard name
# (it always asks "Which server blocks would you like to modify?"), it knows
# nothing of a Cloudflare Origin CA certificate, and its HTTP → HTTPS block
# answers 404 to every host it was not told about — every tenant of a
# wildcard app. So _create_nginx_vhost writes the plain-HTTP vhost and then
# turns it into its HTTPS form here, from whatever certificate the app has.

[[ -z "${CIPI_LE_LIVE:-}" ]]           && readonly CIPI_LE_LIVE="/etc/letsencrypt/live"
[[ -z "${CIPI_ORIGIN_CERT_DIR:-}" ]]   && readonly CIPI_ORIGIN_CERT_DIR="/etc/ssl/cipi-origin"
[[ -z "${CIPI_NGINX_SSL_SNIPPET:-}" ]] && readonly CIPI_NGINX_SSL_SNIPPET="/etc/nginx/snippets/cipi-ssl.conf"
[[ -z "${CIPI_CERTBOT_RELOAD_HOOK:-}" ]] && readonly CIPI_CERTBOT_RELOAD_HOOK="/etc/letsencrypt/renewal-hooks/deploy/cipi-reload-nginx"

# Certificate and key an app is served with, as "cert<TAB>key"; status 1 when it
# has none. A Cloudflare Origin CA certificate (cipi zt origin-cert) is used
# while the app is flagged for it, otherwise the Let's Encrypt lineage named
# after the primary domain (the bare name for a wildcard primary).
app_tls_files() {
    local app="$1" d live
    if [[ "$(app_get "$app" ssl_origin_ca)" == "true" \
          && -s "${CIPI_ORIGIN_CERT_DIR}/${app}/cert.pem" && -s "${CIPI_ORIGIN_CERT_DIR}/${app}/key.pem" ]]; then
        printf '%s\t%s\n' "${CIPI_ORIGIN_CERT_DIR}/${app}/cert.pem" "${CIPI_ORIGIN_CERT_DIR}/${app}/key.pem"
        return 0
    fi
    d=$(app_get "$app" domain)
    [[ -n "$d" ]] || return 1
    live="${CIPI_LE_LIVE}/$(domain_cert_name "$d")"
    if [[ -e "${live}/fullchain.pem" && -e "${live}/privkey.pem" ]]; then
        printf '%s\t%s\n' "${live}/fullchain.pem" "${live}/privkey.pem"
        return 0
    fi
    return 1
}

app_has_tls() { app_tls_files "$1" >/dev/null; }

# The app is published through the Cloudflare tunnel (cipi zt hostname add):
# cloudflared talks plain HTTP to :80, so :80 must keep serving the app.
app_on_cf_tunnel() {
    vault_read zt.json 2>/dev/null | jq -e --arg a "$1" '.hostnames[$a] != null' >/dev/null 2>&1
}

# Names a certificate holds (DNS SANs), one per line.
cert_file_names() {
    openssl x509 -in "$1" -noout -text 2>/dev/null \
        | grep -o 'DNS:[^,[:space:]]*' | sed 's/^DNS://' || true
}

# True when one of the certificate names (stdin, one per line) is valid for
# <name>: the same name, or a wildcard one label above it.
cert_names_cover() {
    local name="$1" c
    while IFS= read -r c; do
        [[ -n "$c" ]] || continue
        [[ "$c" == "$name" ]] && return 0
        if domain_is_wildcard "$c" && ! domain_is_wildcard "$name" && [[ "$name" == *".${c#\*.}" ]]; then
            local label="${name%".${c#\*.}"}"
            [[ "$label" != *.* ]] && return 0
        fi
    done
    return 1
}

# TLS settings shared by every app vhost (Mozilla "intermediate", ECDHE only so
# no dhparam file is needed). Rewritten only when its content changes.
nginx_ensure_ssl_snippet() {
    local want
    want='# Managed by Cipi — TLS settings of every app vhost. Rewritten on update.
ssl_session_cache shared:cipi_ssl:10m;
ssl_session_timeout 1d;
ssl_session_tickets off;
ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers off;
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;'
    [[ -f "$CIPI_NGINX_SSL_SNIPPET" && "$(cat "$CIPI_NGINX_SSL_SNIPPET" 2>/dev/null)" == "$want" ]] && return 0
    mkdir -p "$(dirname "$CIPI_NGINX_SSL_SNIPPET")" 2>/dev/null || return 1
    printf '%s\n' "$want" > "${CIPI_NGINX_SSL_SNIPPET}.tmp" 2>/dev/null \
        && chmod 644 "${CIPI_NGINX_SSL_SNIPPET}.tmp" \
        && mv -f "${CIPI_NGINX_SSL_SNIPPET}.tmp" "$CIPI_NGINX_SSL_SNIPPET"
}

# certbot.timer (twice a day) and the weekly cron both renew certificates, and
# neither touches an app vhost — the live/ paths stay the same. A renewed
# certificate is served only once nginx reloads; certbot runs every file in
# renewal-hooks/deploy after each successful renewal, however it was started.
certbot_ensure_reload_hook() {
    local want
    want='#!/bin/sh
# Managed by Cipi — certbot runs this after every renewed certificate, so that
# nginx serves it. A failing config test is reported by certbot, not hidden.
nginx -t -q && exec systemctl reload nginx'
    [[ -f "$CIPI_CERTBOT_RELOAD_HOOK" && "$(cat "$CIPI_CERTBOT_RELOAD_HOOK" 2>/dev/null)" == "$want" ]] && return 0
    mkdir -p "$(dirname "$CIPI_CERTBOT_RELOAD_HOOK")" 2>/dev/null || return 1
    printf '%s\n' "$want" > "${CIPI_CERTBOT_RELOAD_HOOK}.tmp" 2>/dev/null \
        && chmod 755 "${CIPI_CERTBOT_RELOAD_HOOK}.tmp" \
        && mv -f "${CIPI_CERTBOT_RELOAD_HOOK}.tmp" "$CIPI_CERTBOT_RELOAD_HOOK"
}

# Turn the plain-HTTP vhost written by _create_nginx_vhost into its HTTPS form.
#   redirect  every server block moves to :443, and one :80 block answers every
#             name of the file — tenants of a wildcard included — with a 301 to
#             https://$host. ACME challenges stay reachable on :80.
#   plain     every server block listens on :80 and :443 (Cloudflare tunnel).
# Each server block Cipi writes opens with "    listen 80;" + "    listen [::]:80;".
# A file that does not look like that (edited by hand, already HTTPS) is left
# alone: status 1.
nginx_vhost_apply_tls() {   # <vhost> <cert> <key> <redirect|plain> [log dir]
    local f="$1" cert="$2" key="$3" mode="$4" logdir="${5:-}" blocks
    [[ -f "$f" && -n "$cert" && -n "$key" ]] || return 1
    [[ "$mode" == "redirect" || "$mode" == "plain" ]] || return 1
    blocks=$(grep -c '^server {$' "$f" 2>/dev/null || true)
    [[ "${blocks:-0}" -ge 1 ]] || return 1
    [[ "$(grep -c '^    listen 80;$' "$f")" == "$blocks" \
       && "$(grep -c '^    listen \[::\]:80;$' "$f")" == "$blocks" ]] || return 1
    grep -qE '^[[:space:]]*(listen[[:space:]]+(\[::\]:)?443|ssl_certificate)' "$f" && return 1

    local tmp="${f}.cipi-tls"
    awk -v cert="$cert" -v key="$key" -v mode="$mode" -v snip="$CIPI_NGINX_SSL_SNIPPET" -v logdir="$logdir" '
        /^    listen 80;$/ { if (mode == "plain") print; next }
        /^    listen \[::\]:80;$/ {
            if (mode == "plain") print
            print "    listen 443 ssl;"
            print "    listen [::]:443 ssl;"
            print "    ssl_certificate " cert ";"
            print "    ssl_certificate_key " key ";"
            print "    include " snip ";"
            next
        }
        /^    server_name / {
            line = $0
            sub(/^    server_name[ ]+/, "", line); sub(/;[ ]*$/, "", line)
            n = split(line, parts, /[ ]+/)
            for (i = 1; i <= n; i++) if (parts[i] != "" && !(parts[i] in seen)) {
                seen[parts[i]] = 1
                names = names (names == "" ? "" : " ") parts[i]
            }
        }
        { print }
        END {
            if (mode != "redirect") exit
            print ""
            print "# Written by Cipi with the certificate: HTTP → HTTPS for every name above."
            print "server {"
            print "    listen 80;"
            print "    listen [::]:80;"
            print "    server_name " names ";"
            if (logdir != "") {
                print "    access_log " logdir "/nginx-access.log;"
                print "    error_log " logdir "/nginx-error.log;"
            }
            print "    location ^~ /.well-known/acme-challenge/ {"
            print "        default_type \"text/plain\";"
            print "        root /var/www/html;"
            print "        try_files $uri =404;"
            print "    }"
            print "    location / {"
            print "        return 301 https://$host$request_uri;"
            print "    }"
            print "}"
        }' "$f" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    [[ -s "$tmp" ]] || { rm -f "$tmp"; return 1; }
    chmod 644 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$f"
}

# Git branch name. Restricted to a safe charset so it can never break out of
# the single-quoted PHP string literal it's substituted into when generating
# deploy.php (lib/app.sh _create_deployer_config_from_template / app_edit).
validate_git_branch() {
    local b="$1"
    [[ "$b" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,190}$ ]] || return 1
    [[ "$b" == *".."* ]] && return 1
    return 0
}

# Git remote — SSH shorthand (git@host:path), ssh://, https://, or http://.
# Same rationale as validate_git_branch: restricted charset so it can never
# break out of the PHP string literal (or a downstream Deployer run() call).
validate_git_repository() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._@:/-]{0,254}$ ]]
}

# Database/user identifier used in raw SQL text (mariadb -e "..."). Must never
# contain quotes, backticks, or shell/SQL metacharacters.
validate_db_name() {
    [[ "$1" =~ ^[a-z][a-z0-9_]{1,63}$ ]]
}

# Installable / usable PHP versions. Restricted to 8.3+ because the bundled
# Deployer (v8) requires PHP >= 8.3 and `dep` is invoked with the app's PHP
# version — running it under an older interpreter would break every deploy.
validate_php_version() {
    case "$1" in 8.3|8.4|8.5|8.6) return 0 ;; *) return 1 ;; esac
}

# Any PHP version Cipi has ever managed. Used where we must still operate on a
# legacy install (e.g. `cipi php remove 8.0` to clean up a pre-4.5.4 server).
validate_php_version_known() {
    case "$1" in 7.4|8.0|8.1|8.2|8.3|8.4|8.5|8.6) return 0 ;; *) return 1 ;; esac
}

php_is_installed() { dpkg -l "php${1}-fpm" &>/dev/null 2>&1; }

# Extensions `cipi php install` asked for and the repository did not have:
# one "<version> <extension>" per line. A new PHP branch is published with
# its core packages first; redis, memcached and imagick are separate
# projects and follow days or weeks later. `cipi php upgrade` installs what
# is listed here as soon as apt has it (lib/php.sh), `cipi pending` shows it.
[[ -z "${PHP_EXT_PENDING:-}" ]] && readonly PHP_EXT_PENDING="/var/lib/cipi/php-ext-pending"

# The extensions still missing for PHP <version>, one per line; with no
# argument, every "<version> <extension>" line.
php_ext_pending() {
    [[ -f "$PHP_EXT_PENDING" ]] || return 0
    awk -v v="${1:-}" 'NF == 2 && $1 ~ /^[0-9]+\.[0-9]+$/ && $2 ~ /^[a-z0-9]+$/ {
        if (v == "") print $1, $2; else if ($1 == v) print $2 }' "$PHP_EXT_PENDING" 2>/dev/null || true
}

# Stops an app from being put on a PHP version that is still waiting for
# extensions: the app would be live on a PHP without, say, the redis
# extension, and a Laravel app that keeps cache, sessions or queues in Redis
# answers 500 there. `cipi app create`, `cipi app edit --php` and the plan
# of `cipi yml apply` ask here first; --force goes on anyway (an app that
# uses none of them). Returns 1 after saying why, 0 when there is nothing
# pending or --force was given.
#   $1  PHP version    $2  the last line of the refusal: how to go on
php_ext_pending_refuse() {
    local v="$1" hint="${2:-}" ext
    ext=$(php_ext_pending "$v" | paste -sd' ' - || true)
    [[ -z "$ext" ]] && return 0
    if [[ "${ARG_force:-}" == "true" ]]; then
        warn "PHP ${v} is installed without: ${ext} — going on because of --force; an app that needs one of them does not work until cipi php upgrade installs it"
        return 0
    fi
    error "PHP ${v} is installed without: ${ext} — the repository has no package of them for ${v} yet"
    echo "  An app that needs one does not work on ${v}: Laravel's default Redis client is the redis extension." >&2
    echo "  cipi php upgrade (daily, 03:30) installs them when the repository has them; cipi pending lists them until then." >&2
    [[ -n "$hint" ]] && echo "  ${hint}" >&2
    return 1
}

# True when version $1 is $2 or newer (dotted numbers: 8.5, 8.5.12).
version_at_least() {
    [[ -n "${1:-}" && -n "${2:-}" ]] || return 1
    [[ "$(printf '%s\n' "$2" "$1" | sort -V | head -1)" == "$2" ]]
}

# Oldest release of each PHP branch that carries every security fix Cipi
# knows about. Raised with each PHP security release; the last one was
# 2026-11-19: 8.2.36, 8.3.37, 8.4.28 and 8.5.13, with among others
#   CVE-2026-129289  PHP-FPM request smuggling through an unread request
#                    body (needs fastcgi_keep_conn on, which Cipi never writes)
#   CVE-2026-129291  PHP-FPM epoll use-after-free, worker to master (root)
#   CVE-2026-126714, CVE-2026-115560  session files / serializer, RCE
#   CVE-2026-129496  timezone cache use-after-free, RCE
#   CVE-2026-129474  use-after-free in backtraces, RCE (8.5 and later)
# Empty for branches the PHP project no longer patches (8.1 and older).
# 8.6.0 came out the same day with all of these fixed, so 8.6 starts at its
# first release; a release candidate is reported as such
# (php_security_state), not measured against this.
php_security_floor() {
    case "$1" in
        8.2) echo "8.2.36" ;;
        8.3) echo "8.3.37" ;;
        8.4) echo "8.4.28" ;;
        8.5) echo "8.5.13" ;;
        8.6) echo "8.6.0" ;;
    esac
}

# Oldest nginx that carries every security fix Cipi knows about. 1.31.9
# (2026-11-18) fixes, among others, CVE-2026-123007 and CVE-2026-123633
# (memory corruption and use-after-free in HTTP/2), CVE-2026-118899 (endless
# loop reading a request body over TLS) and CVE-2026-125283 (try_files with
# alias). Mainline numbers: Cipi installs nginx from nginx.org mainline.
nginx_security_floor() { echo "1.31.9"; }

# Oldest Composer that carries every security fix Cipi knows about: 2.10.2
# and 2.10.3 (2026-08-27) are security releases.
composer_security_floor() { echo "2.10.3"; }

# The same for each Node.js line still patched — the security releases of
# 2026-10-21. Empty for a major that is not (or no longer) an LTS line.
node_security_floor() {
    case "$1" in
        22) echo "22.23.4" ;;
        24) echo "24.22.1" ;;
        26) echo "26.12.1" ;;
    esac
}

# Security state of an installed PHP branch, printed as "<state> <version>":
#   patched     at or past php_security_floor
#   vulnerable  older than the floor (ondrej / sury ship upstream versions,
#               so the number is the whole story)
#   distro      older than the floor, from the Ubuntu archive: Ubuntu
#               backports fixes without raising the upstream version, so
#               only the package changelog can tell
#   eol         a branch the PHP project no longer patches
#   prerelease  an alpha, beta or release candidate (8.6.0RC5): what the
#               repositories carry for a branch until its first release.
#               Not a version to measure against a floor — it gets no
#               security releases of its own; the version printed is the
#               whole string, suffix included
#   unknown     the CLI binary for that branch is missing
php_security_state() {
    local v="$1" full floor pkg extra
    full=$("php${v}" -r 'echo PHP_MAJOR_VERSION, ".", PHP_MINOR_VERSION, ".", PHP_RELEASE_VERSION;' 2>/dev/null || true)
    [[ -n "$full" ]] || { echo "unknown -"; return 0; }
    # PHP_EXTRA_VERSION is empty on a release and "RC5", "beta2", "-dev" before
    # one. Only those shapes count: a build that carries some other suffix of
    # its packager's is a release.
    extra=$("php${v}" -r 'echo PHP_EXTRA_VERSION;' 2>/dev/null || true)
    if [[ "$extra" =~ ^-?(alpha|beta|RC|rc|dev) ]]; then
        echo "prerelease ${full}${extra}"
        return 0
    fi
    floor=$(php_security_floor "$v")
    [[ -n "$floor" ]] || { echo "eol ${full}"; return 0; }
    if version_at_least "$full" "$floor"; then
        echo "patched ${full}"
        return 0
    fi
    # Archive builds carry "-0ubuntu0.24.04.5"; ondrej and sury builds carry
    # "+ubuntu24.04", and sury.org's do not say "sury" anywhere.
    pkg=$(dpkg-query -W -f='${Version}' "php${v}-fpm" 2>/dev/null || true)
    if [[ "$pkg" =~ -[0-9]+ubuntu[0-9] ]]; then
        echo "distro ${full}"
    else
        echo "vulnerable ${full}"
    fi
}

# Lines every PHP-FPM pool written by Cipi carries, whatever else it sets.
# They follow the PHP security advisory of 2026-10-21: only the patch release
# fixes CVE-2026-109619 (request state that outlives its memory), but these
# close its two confirmed paths on a server that has not taken it yet.
#   session.upload_progress.enabled  the session path
#   fatal_error_backtraces           the fatal-error backtrace path; the key
#                                    exists from 8.5 on, so it is written only
#                                    where PHP knows it
# Set at pool level as php_admin_flag: applied before the request is parsed,
# and out of reach of .user.ini and ini_set(), which the advisory rules out.
fpm_pool_hardening() {
    echo "php_admin_flag[session.upload_progress.enabled] = off"
    if version_at_least "$1" 8.5; then
        echo "php_admin_flag[fatal_error_backtraces] = off"
    fi
}

# The same two settings as php.ini lines. Written to every PHP-FPM
# /etc/php/X.Y/fpm/conf.d/99-cipi.ini (cipi php install, setup.sh,
# migration 5.7.2) so that the stock `www` pool and any pool written by hand
# carry them too, and to the Octane ini below. PHP ignores a key it does not
# know, so fatal_error_backtraces is written whatever the version.
php_fpm_ini_hardening() {
    echo "session.upload_progress.enabled = 0"
    echo "fatal_error_backtraces = 0"
}

# The same settings for Octane apps. FrankenPHP runs the PHP built into its
# own binary, so pool lines never reach it: each Octane program sets
# PHP_INI_SCAN_DIR=:${OCTANE_INI_DIR} (_create_supervisor_octane). The leading
# ':' keeps the compiled-in scan directory, so the php-cli that starts Octane
# still loads its conf.d; the binary started by Octane inherits the variable.
# Both keys are written whatever the binary's PHP: PHP ignores a key it does
# not know. Loaded at startup, so ini_set() cannot turn upload progress back
# on (PHP_INI_PERDIR). The 2026-10-23 advisory (CVE-2026-115560) asked for
# the same session.upload_progress.enabled=0; the fix came with the releases
# of 2026-11-19, and the setting stays: it is also what the advisory for
# CVE-2026-126714 asks of a server that has not taken them yet.
OCTANE_INI_DIR="/etc/php/cipi-octane.d"
octane_php_ini_ensure() {
    local f="${OCTANE_INI_DIR}/99-cipi-hardening.ini" tmp
    mkdir -p "$OCTANE_INI_DIR" && chmod 755 "$OCTANE_INI_DIR" || return 1
    tmp=$(mktemp "${OCTANE_INI_DIR}/.hardening.XXXXXX") || return 1
    {
        echo "; Written by Cipi; rewritten on update. Loaded by every Octane (FrankenPHP)"
        echo "; app through PHP_INI_SCAN_DIR in its Supervisor program."
        php_fpm_ini_hardening
    } > "$tmp"
    chmod 644 "$tmp" && mv -f "$tmp" "$f" || { rm -f "$tmp"; return 1; }
}

# ── JIT, per app (cipi app jit) ──────────────────────────────
#
# apps.json .jit = {"mode": "tracing"|"function", "buffer": "128M"}; absent = off.
#
# PHP-FPM: one FPM per PHP version serves every pool of that version, and the
# JIT buffer is shared memory the FPM master maps when it starts — a pool can
# not size it (opcache.jit_buffer_size is PHP_INI_SYSTEM). What a pool can do
# is turn JIT on, provided it was *startable*: buffer > 0 and opcache.jit not
# "disable" (PHP 8.4's default, which cannot be changed later; "off" can). So
# while an app on version X has JIT, X's FPM gets jit_fpm_global_file (JIT
# startable, off) and the app's pool php_admin_value[opcache.jit]. Every other
# pool keeps JIT off. The file goes when the last app on X turns JIT off.
#
# Octane: FrankenPHP is one process per app, so its own ini directory
# (PHP_INI_SCAN_DIR, _create_supervisor_octane) carries both settings.
OCTANE_APP_INI_ROOT="/etc/php/cipi-octane-apps"
JIT_DEFAULT_BUFFER="128M"

app_jit_mode()   { vault_read apps.json 2>/dev/null | jq -r --arg a "$1" '.[$a].jit.mode // empty' 2>/dev/null || true; }
app_jit_buffer() { vault_read apps.json 2>/dev/null | jq -r --arg a "$1" '.[$a].jit.buffer // empty' 2>/dev/null || true; }

# "128M" → bytes; nothing for what is not a size.
jit_size_bytes() {
    [[ "${1:-}" =~ ^([0-9]+)([KkMmGg]?)$ ]] || return 1
    local n="${BASH_REMATCH[1]}"
    case "${BASH_REMATCH[2]}" in
        K|k) echo $(( n * 1024 )) ;;
        M|m) echo $(( n * 1024 * 1024 )) ;;
        G|g) echo $(( n * 1024 * 1024 * 1024 )) ;;
        *)   echo "$n" ;;
    esac
}

# The pool line of an app with JIT (nothing otherwise). PHP 8.0 has JIT.
fpm_pool_jit_line() {   # <app> <php version>
    local m; m=$(app_jit_mode "$1")
    if [[ -n "$m" ]] && version_at_least "$2" 8.0; then
        echo "php_admin_value[opcache.jit] = ${m}"
    fi
    return 0
}

# Loaded after 99-cipi.ini (conf.d is read in name order), so it wins over a
# default, never over a choice: an opcache.jit set with `cipi ini set` stays
# (JIT on for every pool is already startable; "disable" means no JIT, and
# cipi app jit refuses then), and the buffer is never made smaller than the
# one set there.
jit_fpm_global_file() { echo "/etc/php/${1}/fpm/conf.d/99-zz-cipi-jit.ini"; }

# Writes or removes the file for PHP <v>, from apps.json. <with> counts an app
# whose "php" is about to become <v> (cipi app edit --php), <without> leaves
# one out (cipi app delete). Prints "changed" when the file changed: that
# FPM has to restart, which the callers do anyway after a pool change.
jit_fpm_global_sync() {   # <php version> [with app] [without app]
    local v="$1" with="${2:-}" without="${3:-}" f a b max=0 bytes g_jit g_buf tmp before=""
    f=$(jit_fpm_global_file "$v")
    [[ -d "/etc/php/${v}/fpm/conf.d" ]] || return 0
    version_at_least "$v" 8.0 || { rm -f "$f"; return 0; }
    [[ -f "$f" ]] && before=$(cat "$f")
    local any=false
    while IFS=$'\t' read -r a b; do
        [[ -n "$a" ]] || continue
        [[ -n "$without" && "$a" == "$without" ]] && continue
        any=true
        bytes=$(jit_size_bytes "${b:-$JIT_DEFAULT_BUFFER}" 2>/dev/null || jit_size_bytes "$JIT_DEFAULT_BUFFER")
        (( bytes > max )) && max=$bytes
    done < <(vault_read apps.json 2>/dev/null | jq -r --arg v "$v" --arg w "$with" '
        to_entries[]
        | select((.value.php == $v or .key == $w) and ((.value.octane // "") == "")
                 and ((.value.runtime // "") != "node") and ((.value.jit.mode // "") != ""))
        | "\(.key)\t\(.value.jit.buffer // "")"' 2>/dev/null || true)
    if [[ "$any" != true ]]; then
        rm -f "$f"
        [[ -n "$before" ]] && echo changed
        return 0
    fi
    g_jit=$(sed -n 's/^[[:space:]]*opcache\.jit[[:space:]]*=[[:space:]]*//p' "/etc/php/${v}/fpm/conf.d/99-cipi.ini" 2>/dev/null | tail -n 1 | tr -d '[:space:]' || true)
    g_buf=$(sed -n 's/^[[:space:]]*opcache\.jit_buffer_size[[:space:]]*=[[:space:]]*//p' "/etc/php/${v}/fpm/conf.d/99-cipi.ini" 2>/dev/null | tail -n 1 | tr -d '[:space:]' || true)
    if [[ -n "$g_buf" ]] && bytes=$(jit_size_bytes "$g_buf" 2>/dev/null) && (( bytes > max )); then max=$bytes; fi
    tmp=$(mktemp "/etc/php/${v}/fpm/conf.d/.cipi-jit.XXXXXX") || return 1
    {
        echo "; Written by Cipi (cipi app jit); rewritten when an app on PHP ${v} turns JIT on"
        echo "; or off, removed when none has it. It only makes JIT startable: opcache.jit"
        echo "; stays off in every pool but those of the apps that turn it on"
        echo "; (php_admin_value[opcache.jit]). The buffer is shared by every pool of"
        echo "; this PHP-FPM and taken from memory only as JIT code is written into it."
        [[ -z "$g_jit" ]] && echo "opcache.jit = off"
        echo "opcache.jit_buffer_size = $(( max / 1024 / 1024 ))M"
    } > "$tmp"
    chmod 644 "$tmp"
    mv -f "$tmp" "$f" || { rm -f "$tmp"; return 1; }
    [[ "$(cat "$f")" != "$before" ]] && echo changed
    return 0
}

# The server-wide opcache.jit set with `cipi ini set`, when it is "disable".
jit_fpm_global_disabled() {   # <php version>
    local g
    g=$(sed -n 's/^[[:space:]]*opcache\.jit[[:space:]]*=[[:space:]]*//p' "/etc/php/${1}/fpm/conf.d/99-cipi.ini" 2>/dev/null | tail -n 1 | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]' || true)
    [[ "$g" == disable ]]
}

# The app's own Octane ini directory, with its JIT file or without it.
jit_octane_ini_sync() {   # <app>
    local app="$1" d m b f tmp
    d="${OCTANE_APP_INI_ROOT}/${app}"
    mkdir -p "$d" && chmod 755 "$OCTANE_APP_INI_ROOT" "$d" || return 1
    f="${d}/50-cipi-jit.ini"
    m=$(app_jit_mode "$app")
    if [[ -z "$m" ]]; then
        rm -f "$f"
        return 0
    fi
    b=$(app_jit_buffer "$app"); b="${b:-$JIT_DEFAULT_BUFFER}"
    tmp=$(mktemp "${d}/.jit.XXXXXX") || return 1
    {
        echo "; Written by Cipi (cipi app jit ${app}); rewritten on every change."
        echo "opcache.jit = ${m}"
        echo "opcache.jit_buffer_size = ${b}"
    } > "$tmp"
    chmod 644 "$tmp" && mv -f "$tmp" "$f" || { rm -f "$tmp"; return 1; }
}

# CIPI_DEPLOY_BRANCH in a Laravel app's shared/.env. The webhook of cipi/agent
# deploys a push to that branch and answers "skipped" to every other one;
# without the key every push deployed. Written at create, kept in step by
# `cipi app edit --branch` and `cipi sync import`. With $3 = add, a key that
# is already there is left alone (migration 5.7.2 fills the gap on existing
# apps without touching a value someone set by hand).
app_env_set_deploy_branch() {
    local app="${1:-}" branch="${2:-}" mode="${3:-set}" env="/home/${1:-}/shared/.env" safe
    [[ -n "$app" && -n "$branch" && -f "$env" ]] || return 0
    # Read and written as the app user (see app_as).
    local cur; cur=$(app_read "$app" "$env") || cur=""
    if grep -q '^CIPI_DEPLOY_BRANCH=' <<< "$cur"; then
        [[ "$mode" == "add" ]] && return 0
        safe=$(printf '%s' "$branch" | sed 's/[&|\\]/\\&/g')
        app_sed "$app" "$env" "s|^CIPI_DEPLOY_BRANCH=.*|CIPI_DEPLOY_BRANCH=${safe}|"
    else
        printf 'CIPI_DEPLOY_BRANCH=%s\n' "$branch" | app_append "$app" "$env"
    fi
}

# Environment label of an app (cipi app create --env): production, staging,
# …. A plain lowercase word, because it becomes part of a file name in the
# repository (cipi-<env>.yml) and a value in the app's .env (APP_ENV).
validate_env_label() { [[ "${1:-}" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]]; }
# shellcheck disable=SC2034  # read by app.sh (create, edit, clone)
ENV_LABEL_HELP="Use lowercase letters, digits, '-' and '_' (max 32 chars), such as production or staging"

# The label of an app. Apps created before 5.8.0 carry no key: production.
app_env_label() {
    local e; e=$(app_get "${1:-}" env 2>/dev/null)
    validate_env_label "$e" && echo "$e" || echo production
}

# The label in a Laravel or Node app's shared/.env. CIPI_ENV is what the
# post-deploy runner — the app user, who cannot read apps.json — uses to pick
# cipi-<env>.yml; APP_ENV is Laravel's own switch and follows only when it is
# already there. Written at create, kept in step by `cipi app edit --env`,
# `cipi app clone` and `cipi sync import|update`. With $3 = add, a CIPI_ENV
# already there is left alone and APP_ENV is not touched (migration 5.8.0
# fills the gap on existing apps without changing a value someone chose).
app_env_set_environment() {
    local app="${1:-}" label="${2:-}" mode="${3:-set}" env="/home/${1:-}/shared/.env"
    [[ -n "$app" && -f "$env" ]] || return 0
    validate_env_label "$label" || return 1
    # Read and written as the app user (see app_as).
    local cur; cur=$(app_read "$app" "$env") || cur=""
    if grep -q '^CIPI_ENV=' <<< "$cur"; then
        [[ "$mode" == "add" ]] && return 0
        app_sed "$app" "$env" "s|^CIPI_ENV=.*|CIPI_ENV=${label}|"
    else
        printf 'CIPI_ENV=%s\n' "$label" | app_append "$app" "$env"
    fi
    [[ "$mode" == "add" ]] && return 0
    if grep -q '^APP_ENV=' <<< "$cur"; then
        app_sed "$app" "$env" "s|^APP_ENV=.*|APP_ENV=${label}|"
    fi
    return 0
}

# True if a systemd unit file exists.
# Note: `systemctl list-unit-files --quiet UNIT` exits 0 even when zero units
# match, so it must not be used as an existence check.
systemd_unit_exists() {
    local unit="${1%.service}"
    [[ -n "$unit" ]] || return 1
    systemctl cat "${unit}.service" &>/dev/null
}

# ── The server on port 3306: MariaDB or MySQL ────────────────
# MariaDB unless `cipi db switch mysql` replaced it (server.json
# db_engines.mariadb.server). The engine keeps its id "mariadb" either way —
# in apps.json, databases.json, the backup layout, cipi.yml and the panel's
# API — so nothing that stores or exchanges it changes shape; these say which
# server answers on it, under which name.
db_mysql_flavor() {
    if [[ -z "${_CIPI_MYSQL_FLAVOR:-}" ]]; then
        _CIPI_MYSQL_FLAVOR=$(vault_read server.json 2>/dev/null | jq -r '.db_engines.mariadb.server // "mariadb"' 2>/dev/null || true)
        [[ "$_CIPI_MYSQL_FLAVOR" == "mysql" ]] || _CIPI_MYSQL_FLAVOR="mariadb"
    fi
    echo "$_CIPI_MYSQL_FLAVOR"
}
# The command-line client. MySQL has no `mariadb`; MariaDB still ships `mysql`.
db_mysql_client() {
    if [[ "$(db_mysql_flavor)" == "mysql" ]] || ! command -v mariadb >/dev/null 2>&1; then
        echo mysql
    else
        echo mariadb
    fi
}
db_mysql_unit()  { [[ "$(db_mysql_flavor)" == "mysql" ]] && echo mysql || echo mariadb; }
db_mysql_label() { [[ "$(db_mysql_flavor)" == "mysql" ]] && echo MySQL || echo MariaDB; }

# A MySQL/MariaDB client program (mysql, mariadb, mysqldump) run as the root
# user of the server on port 3306, its password in an option file the program
# reads from a pipe — never on its command line. On the command line (-p…)
# it sat in the process list, which every user of the server reads (each
# app's too), until the client overwrote it; and MySQL's clients (after
# `cipi db switch mysql`) say so on stderr at every call — "mysql: [Warning]
# Using a password on the command line interface can be insecure." — a line
# `cipi db list` then read as the name of a database. `-u root` stays on the
# command line, where an option file cannot change it.
db_mysql_as_root() {   # <root password> <program> [options…]
    local pw="$1" prog="$2"; shift 2
    "$prog" --defaults-extra-file=<(printf '[client]\npassword="%s"\n' "${pw//\\/\\\\}") -u root "$@"
}

# Major version of the installed Deployer binary (e.g. "8"). Empty if `dep` is
# missing/unreadable. Used to gate the PHP >= 8.3 requirement: only Deployer 8+
# rejects older PHP — under Deployer 7 those apps still deploy fine.
deployer_major_version() {
    local v
    v=$(/usr/local/bin/dep --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -n1)
    [[ -z "$v" ]] && return 1
    echo "${v%%.*}"
}

# Append the deploy-audit hooks (lib/deployer/audit-*.php) to an app's
# deploy.php unless they are already there. Returns 0 when present or added.
# $1=app $2=custom (true|false; default: read from apps.json)
deployer_audit_ensure_hook() {
    local app="$1" custom="${2:-}" df tpl
    df="/home/${app}/.deployer/deploy.php"
    [[ -f "$df" ]] || return 1
    # deploy.php is read and appended to as the app user (see app_as): root
    # appended to it and then chowned it — on every `cipi deploy`, to
    # whatever a symlink of that name pointed at.
    local cur; cur=$(app_read "$app" "$df") || return 1
    grep -q 'cipi:deploy-audit' <<< "$cur" && return 0
    [[ -n "$custom" ]] || custom=$(app_get "$app" custom 2>/dev/null || echo false)
    tpl="${CIPI_LIB}/deployer/audit-releases.php"
    [[ "$custom" == "true" ]] && tpl="${CIPI_LIB}/deployer/audit-custom.php"
    [[ -f "$tpl" ]] || return 1
    # A deploy.php closed with "?>" would print the hook instead of running it.
    grep -qE '^[[:space:]]*\?>[[:space:]]*$' <<< "$cur" && return 1
    sed "s|__CIPI_APP_USER__|${app}|g" "$tpl" | app_append "$app" "$df" || return 1
    return 0
}

# A failed deploy left .dep/deploy.lock behind, and every deploy after it
# stopped at "Deploy locked" until someone ran `cipi deploy <app> --unlock`.
# The recipes now release the lock when a deploy fails (deploy:failed →
# deploy:unlock); this adds the same line to a deploy.php written before
# 5.9.0. Laravel apps only: the custom recipe has no lock, the Node one
# always had the line. Appended as the app user, like the audit hook.
deployer_unlock_ensure_hook() {
    local app="$1" df cur
    df="/home/${app}/.deployer/deploy.php"
    [[ -f "$df" ]] || return 1
    [[ "$(app_get "$app" custom 2>/dev/null || true)" == "true" ]] && return 0
    cur=$(app_read "$app" "$df") || return 1
    grep -q "deploy:unlock" <<< "$cur" && return 0
    grep -q "recipe/laravel.php" <<< "$cur" || return 0
    grep -qE '^[[:space:]]*\?>[[:space:]]*$' <<< "$cur" && return 1
    printf '\n%s\n%s\n' \
        "// Cipi: a deploy that fails releases its own lock (5.9.0)." \
        "after('deploy:failed', 'deploy:unlock');" | app_append "$app" "$df" || return 1
    return 0
}

# Deployer 7 and 8 number a release from .dep/latest_release; Deployer 6 kept
# its own list (.dep/releases) and never wrote that file. The servers that went
# from Deployer 6 to 8 with 5.10.0 started again at release 1 next to the old
# releases, and a later deploy stopped at "Release name "N" already exists".
# This appends lib/deployer/release-name.php, whose release_name is never at or
# below a release already in releases/. Release-based recipes only (Laravel,
# Octane, Node): the custom recipe has none. Appended as the app user, like the
# audit hook.
deployer_release_name_ensure_hook() {
    local app="$1" df cur tpl
    df="/home/${app}/.deployer/deploy.php"
    [[ -f "$df" ]] || return 1
    [[ "$(app_get "$app" custom 2>/dev/null || true)" == "true" ]] && return 0
    cur=$(app_read "$app" "$df") || return 1
    grep -q 'cipi:release-name' <<< "$cur" && return 0
    grep -qE "recipe/(laravel|common)\.php" <<< "$cur" || return 0
    grep -qE '^[[:space:]]*\?>[[:space:]]*$' <<< "$cur" && return 1
    tpl="${CIPI_LIB}/deployer/release-name.php"
    [[ -f "$tpl" ]] || return 1
    app_append "$app" "$df" < "$tpl" || return 1
    return 0
}

# recipe/laravel.php's own `deploy` task runs artisan:storage:link,
# artisan:optimize and artisan:migrate after the vendors; Cipi's hooks run the
# same three right before it. Every deploy did each of them twice (5.17.0),
# and a step turned off in the app's deploy-config still ran once. This appends
# lib/deployer/flow.php, which makes the list of the `deploy` task Cipi's own,
# so only the hooks run. Laravel and Octane recipes only.
#
# Returns 0 when the flow is there or was added, 2 when the file was left as
# it is on purpose: it defines its own `deploy` task, or the three hooks are
# not where Cipi writes them (a deploy.php edited by hand — taking the recipe's
# steps away from it could leave it without a migration at all).
deployer_flow_ensure_hook() {
    local app="$1" df cur tpl step
    df="/home/${app}/.deployer/deploy.php"
    [[ -f "$df" ]] || return 1
    [[ "$(app_get "$app" custom 2>/dev/null || true)" == "true" ]] && return 0
    [[ "$(app_get "$app" runtime 2>/dev/null || true)" == "node" ]] && return 0
    cur=$(app_read "$app" "$df") || return 1
    grep -q 'cipi:deploy-flow' <<< "$cur" && return 0
    grep -q "recipe/laravel.php" <<< "$cur" || return 0
    grep -qE '^[[:space:]]*\?>[[:space:]]*$' <<< "$cur" && return 1
    grep -qE "^[[:space:]]*task\([[:space:]]*['\"]deploy['\"][[:space:]]*," <<< "$cur" && return 2
    for step in storage:link migrate optimize; do
        grep -qE "^[[:space:]]*after\('deploy:vendors', 'artisan:${step}'\);|^// artisan:${step} disabled \(deploy-config\)" <<< "$cur" || return 2
    done
    tpl="${CIPI_LIB}/deployer/flow.php"
    [[ -f "$tpl" ]] || return 1
    app_append "$app" "$df" < "$tpl" || return 1
    return 0
}

# The two clocks of a deploy, in seconds, per app (cipi app deploy-config
# --build-timeout / --step-timeout, deploy.build_timeout / deploy.step_timeout
# in cipi.yml):
#   build — the frontend build: the node_build of a Laravel app, the install
#           and the build of a Node app. 1800 unless the app says otherwise.
#   step  — every other command of the deploy (Deployer's default_timeout):
#           the clone, Composer, the migrations. 300 unless the app says so.
# apps.json keeps a value only when it is not the default (deploy_build_timeout,
# deploy_step_timeout).
deploy_timeout_bounds() {   # build|step → "<default> <min> <max>"
    case "${1:-}" in
        build) echo "1800 60 3600" ;;
        step)  echo "300 60 1800" ;;
        *)     return 1 ;;
    esac
}
deploy_timeout_valid() {   # build|step <seconds>
    local def min max
    read -r def min max <<< "$(deploy_timeout_bounds "${1:-}")" || return 1
    [[ "${2:-}" =~ ^[0-9]{1,5}$ ]] && (( 10#$2 >= min && 10#$2 <= max ))
}
deploy_timeout_get() {   # <app> build|step → seconds (the default when unset or not valid)
    local def min max v
    read -r def min max <<< "$(deploy_timeout_bounds "${2:-}")" || return 1
    v=$(app_get "$1" "deploy_${2}_timeout" 2>/dev/null || true)
    deploy_timeout_valid "$2" "$v" && echo "$((10#$v))" || echo "$def"
}
deploy_timeout_set() {   # <app> build|step <seconds> — the default is stored as nothing
    local def min max
    read -r def min max <<< "$(deploy_timeout_bounds "${2:-}")" || return 1
    deploy_timeout_valid "$2" "${3:-}" || return 1
    if (( 10#$3 == def )); then app_unset "$1" "deploy_${2}_timeout"
    else app_set "$1" "deploy_${2}_timeout" "$((10#$3))"; fi
}

# The command that makes Cipi write an app's deploy.php again from today's
# recipe (edits made to the file by hand are lost): what a message says when
# it leaves a hand-edited deploy.php as it is. deploy-config is not for Node
# apps, which are custom apps with a runtime.
deployer_recipe_again_cmd() {   # <app>
    local app="$1" kr
    if [[ "$(app_get "$app" runtime 2>/dev/null || true)" == "node" ]]; then
        printf 'cipi app edit %s --build="%s"\n' "$app" "$(app_get "$app" node_build 2>/dev/null || true)"
    else
        kr=$(app_get "$app" keep_releases 2>/dev/null || true); [[ "$kr" =~ ^[0-9]+$ ]] || kr=5
        printf 'cipi app deploy-config %s --keep-releases=%s\n' "$app" "$kr"
    fi
}

# Deployer stops a command after default_timeout — 300 seconds — and the
# frontend build is the step of a deploy that takes longer than that on a small
# or busy server: the deploy ended at "exceeded the timeout of 300 seconds",
# some days and not others. The recipes now run the build (the node_build of a
# Laravel app; the install and the build of a Node app) through
# cipi_build_run(), with a limit of its own (5.18.0). This appends the same
# lines — the block between the two "cipi:build-timeout" comments of the recipe
# the app would be given today — to a deploy.php written before: the build
# tasks are defined again, with the limit.
#
# Returns 0 when the block is there, was added, or there is nothing to give
# more time to (custom apps; a Laravel recipe from before the build task); 2
# when the file was left as it is on purpose: a build task is defined more than
# once, or does not run the commands Cipi wrote (a deploy.php edited by hand —
# defining the task again would undo the edit).
deployer_build_timeout_ensure_hook() {
    local app="$1" df cur tpl block name line
    df="/home/${app}/.deployer/deploy.php"
    [[ -f "$df" ]] || return 1
    # A Node app is a custom app with a runtime: asked first.
    if [[ "$(app_get "$app" runtime 2>/dev/null || true)" == "node" ]]; then
        tpl="${CIPI_LIB}/deployer/node.php"
    elif [[ "$(app_get "$app" custom 2>/dev/null || true)" == "true" ]]; then
        return 0
    elif [[ -n "$(app_get "$app" octane 2>/dev/null || true)" ]]; then
        tpl="${CIPI_LIB}/deployer/laravel-octane.php"
    else
        tpl="${CIPI_LIB}/deployer/laravel.php"
    fi
    cur=$(app_read "$app" "$df") || return 1
    grep -q 'cipi:build-timeout' <<< "$cur" && return 0
    if [[ "$tpl" != */node.php ]]; then
        grep -q "recipe/laravel.php" <<< "$cur" || return 0
        grep -qE "task\([[:space:]]*['\"]cipi:node_build['\"]" <<< "$cur" || return 0
    fi
    [[ -f "$tpl" ]] || return 1
    grep -qE '^[[:space:]]*\?>[[:space:]]*$' <<< "$cur" && return 1
    block=$(sed -n '/^\/\/ cipi:build-timeout /,/^\/\/ cipi:build-timeout end$/p' "$tpl" \
        | sed "s|__CIPI_BUILD_TIMEOUT__|$(deploy_timeout_get "$app" build)|g")
    [[ "$(tail -n 1 <<< "$block")" == "// cipi:build-timeout end" ]] || return 1
    # Each task of the block is in the file once…
    while IFS= read -r name; do
        [[ "$(grep -cE "task\([[:space:]]*['\"]${name}['\"]" <<< "$cur")" == 1 ]] || return 2
    done < <(grep -oE "^task\('[^']+'" <<< "$block" | cut -d"'" -f2)
    # …and runs the commands of the block, as Cipi wrote them before the limit.
    while IFS= read -r line; do
        grep -qxF -- "${line/cipi_build_run(/run(}" <<< "$cur" || return 2
    done < <(grep -E '^[[:space:]]+cipi_build_run\(' <<< "$block")
    printf '\n%s\n' "$block" | app_append "$app" "$df" || return 1
    return 0
}

# What the move from Deployer 6 to 8 left behind in an app that had released
# on Deployer 6, repaired as the app user (idempotent, prints one line per
# change and nothing when there was nothing to do):
#  - .dep/latest_release is raised to the highest release in releases/ when it
#    is lower, so the next release follows it;
#  - the releases Deployer 6 made, which are not in .dep/releases_log, go in
#    it before the ones Deployer 8 made — in Deployer 6's order, with the date
#    of its own .dep/releases (or of the directory) — so that deploy:cleanup
#    removes them past keep_releases and `dep rollback` can go back to them.
#    Only where Deployer 6's list is there; each line is marked "imported".
# Skipped while a deploy holds the lock: Deployer appends to releases_log.
deployer_release_state_repair() {   # <app>
    local app="${1:-}"
    [[ "$app" =~ ^[a-z][a-z0-9]{2,31}$ ]] || return 1
    [[ "$(app_get "$app" custom 2>/dev/null || true)" == "true" ]] && return 0
    app_sh "$app" '
        cd -- "$1" 2>/dev/null || exit 0
        [ -d releases ] && [ -d .dep ] && [ ! -L .dep ] || exit 0
        if [ -e .dep/deploy.lock ]; then
            echo "skipped: a deploy holds the lock (.dep/deploy.lock) — when it is over: bash /opt/cipi/lib/migrations/5.12.1.sh"
            exit 0
        fi
        names=$(ls -1 releases 2>/dev/null | grep -x "[0-9][0-9]*" | sort -n)
        [ -n "$names" ] || exit 0
        highest=$(printf "%s\n" "$names" | tail -n 1)
        latest=$(cat .dep/latest_release 2>/dev/null || true)
        case "$latest" in ""|*[!0-9]*) latest=0 ;; esac
        if [ "$highest" -gt "$latest" ]; then
            [ ! -L .dep/latest_release ] || exit 1
            printf "%s\n" "$highest" > .dep/latest_release || exit 1
            echo "release counter ${latest} → ${highest} (next release: $((highest + 1)))"
        fi
        [ -f .dep/releases ] && [ ! -L .dep/releases ] && [ ! -L .dep/releases_log ] || exit 0
        known=""
        [ -f .dep/releases_log ] && known=$(jq -R -r "fromjson? | .release_name // empty | tostring" .dep/releases_log 2>/dev/null)
        rows=$(mktemp .dep/.cipi-import.XXXXXX) || exit 1
        trap "rm -f \"\$rows\" \"\$rows.log\"" EXIT
        for n in $names; do
            printf "%s\n" "$known" | grep -qx "$n" && continue
            d=$(grep -E "^[0-9]{14},${n}\$" .dep/releases | tail -n 1 | cut -d, -f1)
            ts=""
            [ -n "$d" ] && ts=$(date -d "${d:0:4}-${d:4:2}-${d:6:2} ${d:8:2}:${d:10:2}:${d:12:2}" +%s 2>/dev/null)
            [ -n "$ts" ] || ts=$(stat -c %Y "releases/$n")
            printf "%s %s\n" "$ts" "$n" >> "$rows"
        done
        [ -s "$rows" ] || exit 0
        sort -k1,1n -k2,2n "$rows" | while read -r ts n; do
            jq -cn --arg c "$(date -u -d "@$ts" +%Y-%m-%dT%H:%M:%S+0000)" --arg n "$n" \
                "{created_at: \$c, release_name: \$n, user: \"deployer6\", target: \"\", imported: \"deployer6\"}"
        done > "$rows.log" || exit 1
        [ -f .dep/releases_log ] && cat .dep/releases_log >> "$rows.log"
        cat "$rows.log" > .dep/releases_log || exit 1
        imported=$(sort -k1,1n -k2,2n "$rows" | cut -d" " -f2 | paste -sd" " -)
        echo "releases_log: Deployer 6 releases ${imported} imported — cleanup and rollback see them again"
    ' "/home/${app}"
}

app_exists() {
    [[ -f "${CIPI_CONFIG}/apps.json" ]] && vault_read apps.json | jq -e --arg a "$1" '.[$a]' &>/dev/null
}

# Check if domain is used by another app (domain or alias). Exclude app name when editing.
# Returns 0 if in use, 1 if free. If in use, sets DOMAIN_USED_BY_APP for error message.
domain_is_used_by_other_app() {
    local dom="$1" exclude_app="${2:-}"
    DOMAIN_USED_BY_APP=""
    [[ ! -f "${CIPI_CONFIG}/apps.json" ]] && return 1
    DOMAIN_USED_BY_APP=$(vault_read apps.json | jq -r --arg d "$dom" --arg e "$exclude_app" '
        to_entries[] | select(.key != $e) |
        select(.value.domain == $d or ((.value.aliases // []) | index($d) != null)) |
        .key
    ' 2>/dev/null | head -1)
    [[ -n "$DOMAIN_USED_BY_APP" ]]
}

# Domain of the panel API (api) or GUI (gui). Returns 1 when not configured.
panel_domain() {
    local d
    [[ -f "${CIPI_CONFIG}/$1.json" ]] || return 1
    d=$(vault_read "$1.json" 2>/dev/null | jq -r '.domain // empty' 2>/dev/null) || return 1
    [[ -n "$d" && "$d" != "null" ]] || return 1
    printf '%s' "$d"
}

# The API and the GUI each need a hostname of their own: their Nginx vhost and
# certificate are separate from every app's, and two vhosts with the same
# server_name means nginx serves only one of them. Returns 0 when the domain
# belongs to a panel (skipping $2 = api|gui, the panel being moved) and sets
# DOMAIN_USED_BY_PANEL for the error message.
domain_is_used_by_panel() {
    local dom skip="${2:-}" p d
    dom=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    DOMAIN_USED_BY_PANEL=""
    for p in api gui; do
        [[ "$p" == "$skip" ]] && continue
        d=$(panel_domain "$p") || continue
        [[ "$(printf '%s' "$d" | tr '[:upper:]' '[:lower:]')" == "$dom" ]] || continue
        [[ "$p" == api ]] && DOMAIN_USED_BY_PANEL="the panel API (cipi api)" \
            || DOMAIN_USED_BY_PANEL="the GUI panel (cipi gui)"
        return 0
    done
    return 1
}

# Refuse a panel domain ($2 = api|gui) that an app or the other panel already serves.
panel_domain_check() {
    local dom="$1" self="$2"
    if domain_is_used_by_other_app "$dom"; then
        error "Domain '${dom}' is used by app '${DOMAIN_USED_BY_APP}'"
        echo -e "  ${DIM}The panel needs a domain or subdomain of its own, e.g. ${self}.$(printf '%s' "$dom" | sed 's/^www\.//')${NC}"
        return 1
    fi
    if domain_is_used_by_panel "$dom" "$self"; then
        error "Domain '${dom}' is used by ${DOMAIN_USED_BY_PANEL}"
        echo -e "  ${DIM}The API and the GUI need a domain or subdomain each.${NC}"
        return 1
    fi
    return 0
}

# ── Where a panel domain points ──────────────────────────────

# This server's public IPv4 as the outside sees it, cached for the run; empty
# when it cannot be found (no egress, an answer that is not an address).
server_public_ip() {
    if [[ -z "${_CIPI_PUBLIC_IP+x}" ]]; then
        _CIPI_PUBLIC_IP=$(curl -s --connect-timeout 3 --max-time 5 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]') || _CIPI_PUBLIC_IP=""
        [[ "$_CIPI_PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || _CIPI_PUBLIC_IP=""
    fi
    printf '%s' "$_CIPI_PUBLIC_IP"
}

# The addresses on this machine's interfaces, one per line (a server with a
# public address of its own, IPv6 included).
server_local_ips() { hostname -I 2>/dev/null | tr ' ' '\n' | grep . || true; }

# The addresses a name resolves to, one per line: A and AAAA, after CNAMEs,
# through the resolver this server uses.
# getent exits 2 on a name with no record: with pipefail that is the
# pipeline's status, and in a $(…) assignment under set -e it ended the
# command with no message — hence the || true.
dns_resolve_ips() { getent ahosts "$1" 2>/dev/null | awk '{print $1}' | sort -u || true; }

# Cloudflare's proxy ranges (www.cloudflare.com/ips). A name on the orange
# cloud resolves to these and never to the origin; the DNS check accepts
# them, since Let's Encrypt's HTTP-01 is answered through the proxy.
ip_is_cloudflare() {
    local ip="$1" a b c d n base bits cidr
    case "$ip" in
        *:*)
            case "$(printf '%s' "$ip" | tr '[:upper:]' '[:lower:]')" in
                2400:cb00:*|2606:4700:*|2803:f800:*|2405:b500:*|2405:8100:*|2c0f:f248:*|2a06:98c[0-7]:*) return 0 ;;
            esac
            return 1 ;;
    esac
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS=. read -r a b c d <<< "$ip"
    n=$(( (a<<24) | (b<<16) | (c<<8) | d ))
    for cidr in 173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18 \
                108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 197.234.240.0/22 198.41.128.0/17 \
                162.158.0.0/15 104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 131.0.72.0/22; do
        IFS=. read -r a b c d <<< "${cidr%/*}"
        base=$(( (a<<24) | (b<<16) | (c<<8) | d ))
        bits=${cidr#*/}
        (( (n >> (32 - bits)) == (base >> (32 - bits)) )) && return 0
    done
    return 1
}

# The API and the GUI end their setup with a certificate request, and a name
# that does not point here fails it — the install done, the panel on http://,
# and nothing said about why until certbot's error. So the check comes first:
# $1 resolves to this server (or to the Cloudflare proxy) → 0; nothing, or
# another address → 1 with the record to create. --skip-dns-check (or $2 =
# true) turns it into a note, for a NAT or a proxy Cipi cannot see through.
panel_dns_check() {
    local dom="$1" skip="${2:-${ARG_skip_dns_check:-}}"
    if [[ "$skip" == "true" ]]; then
        info "DNS check skipped (--skip-dns-check): the certificate request fails if ${dom} does not reach this server"
        return 0
    fi
    local pub resolved mine ip ok=false cf=false
    pub=$(server_public_ip)
    resolved=$(dns_resolve_ips "$dom")
    mine=$(printf '%s\n%s\n' "$pub" "$(server_local_ips)" | grep . | sort -u || true)
    local shown; shown=$(paste -sd, - <<< "$resolved")
    if [[ -z "$resolved" ]]; then
        error "DNS: ${dom} does not resolve yet"
        echo -e "  ${DIM}Create an A record for ${dom} → ${pub:-the public IP of this server}, wait for it to propagate${NC}"
        echo -e "  ${DIM}(check: getent ahosts ${dom}), then run the command again.${NC}"
        echo -e "  ${DIM}Behind a proxy or NAT Cipi cannot see through: add --skip-dns-check${NC}"
        return 1
    fi
    while IFS= read -r ip; do
        [[ -n "$ip" ]] || continue
        grep -Fxq "$ip" <<< "$mine" && ok=true
        ip_is_cloudflare "$ip" && cf=true
    done <<< "$resolved"
    if [[ "$ok" == true ]]; then
        success "DNS: ${dom} → ${shown}"
        return 0
    fi
    if [[ "$cf" == true ]]; then
        success "DNS: ${dom} → Cloudflare proxy${pub:+ (origin ${pub})}"
        return 0
    fi
    if [[ -z "$mine" ]]; then
        warn "DNS: ${dom} → ${shown} — this server's own address is unknown, not verified"
        return 0
    fi
    local me="${pub:-$(head -1 <<< "$mine")}"
    error "DNS: ${dom} points to ${shown}, this server is ${me}"
    echo -e "  ${DIM}Change the A record of ${dom} to ${me}, wait for it to propagate (check: getent ahosts ${dom}),${NC}"
    echo -e "  ${DIM}then run the command again. Behind a proxy or NAT Cipi cannot see through: add --skip-dns-check${NC}"
    return 1
}

# Let's Encrypt lineages issued for a panel domain: <domain>, plus the
# <domain>-NNNN copies certbot makes when that name is already taken.
panel_cert_names() {
    local f
    for f in "/etc/letsencrypt/renewal/${1}.conf" "/etc/letsencrypt/renewal/${1}"-[0-9][0-9][0-9][0-9].conf; do
        [[ -f "$f" ]] && basename "$f" .conf
    done
    return 0
}

# Delete the certificate of a panel domain ($1) that the panel ($2 = api|gui)
# no longer serves. Kept when an app or the other panel still uses the domain:
# before 5.7.0 nothing stopped a panel from sharing one.
panel_cert_delete() {
    local dom="$1" self="$2" n
    [[ -n "$dom" ]] || return 0
    if domain_is_used_by_other_app "$dom"; then
        warn "Certificate for ${dom} kept: app '${DOMAIN_USED_BY_APP}' uses the domain"
        return 0
    fi
    if domain_is_used_by_panel "$dom" "$self"; then
        warn "Certificate for ${dom} kept: ${DOMAIN_USED_BY_PANEL} uses the domain"
        return 0
    fi
    while IFS= read -r n; do
        [[ -n "$n" ]] || continue
        if certbot delete --cert-name "$n" --non-interactive >/dev/null 2>&1; then
            success "Certificate ${n} deleted"
        else
            warn "Could not delete certificate ${n} — run: certbot delete --cert-name ${n}"
        fi
    done < <(panel_cert_names "$dom")
    return 0
}

app_get() { vault_read apps.json | jq -r --arg a "$1" --arg k "$2" '.[$a][$k] // empty'; }

# Generate apps-public.json: a plaintext projection of apps.json containing
# only non-sensitive fields. Secrets (webhook tokens, git IDs, DNS tokens) stay encrypted.
_update_apps_public() {
    [[ -f "${CIPI_CONFIG}/apps.json" ]] || return 0
    _cipi_config_writable || return 0
    local json
    json=$(vault_read apps.json) || return 0
    echo "$json" | jq '
        with_entries(.value |= {
            domain, aliases, php, branch, env: (.env // "production"), repository, user, created_at, suspended,
            basic_auth, www_redirect, redirect, redirects, proxies, force_https, custom, docroot, engine,
            octane, octane_port, reverb, reverb_port, horizon, schedule, node_build,
            cloned_from, predeploy_snapshot, limits, ini, health_url, health_expect,
            ssl_dns_provider, backup_profiles, search, databases, page_cache,
            runtime, node_mode, node_version, node_framework, node_output, node_start, node_health, node_ports
        })
    ' > "${CIPI_CONFIG}/apps-public.json" 2>/dev/null || return 0
    _cipi_safe_chmod 640 "${CIPI_CONFIG}/apps-public.json"
    chgrp cipi-api "${CIPI_CONFIG}/apps-public.json" 2>/dev/null || true
}

# When Cipi API is configured, ensure www-data can read apps-public.json via
# the cipi-api group. The encrypted apps.json stays root-only (600).
ensure_apps_json_api_access() {
    [[ -f "${CIPI_CONFIG}/api.json" ]] || return 0
    [[ -f "${CIPI_CONFIG}/apps.json" ]] || return 0
    _cipi_config_writable || return 0
    if ! getent group cipi-api &>/dev/null; then
        groupadd cipi-api 2>/dev/null || true
    fi
    if ! id -nG www-data 2>/dev/null | grep -qw cipi-api; then
        usermod -aG cipi-api www-data 2>/dev/null || true
    fi
    chgrp cipi-api "${CIPI_CONFIG}" 2>/dev/null || true
    _cipi_safe_chmod 750 "${CIPI_CONFIG}"
    _update_apps_public
}

# /etc/sudoers.d/cipi-api — the commands www-data (panel API, GUI) may run as
# root. Present only while a panel is installed (lib/cipi-api-sudoers.sh);
# `cipi api`, `cipi gui` and their `remove` call this after writing or
# deleting their config. Best-effort, never fails the caller.
_panel_sudoers_ensure() {
    if ! declare -f ensure_cipi_api_sudoers >/dev/null 2>&1; then
        [[ -f "${CIPI_LIB}/cipi-api-sudoers.sh" ]] || return 0
        # shellcheck source=/dev/null
        source "${CIPI_LIB}/cipi-api-sudoers.sh"
    fi
    ensure_cipi_api_sudoers || true
}

# Panel API (/opt/cipi/api): SQLite, Laravel logs, and bootstrap cache must be
# writable by www-data (PHP-FPM, queue worker, artisan via sudo -u www-data).
# Call after root-run composer or manual edits under /opt/cipi/api.
ensure_cipi_api_permissions() {
    local root="${CIPI_API_ROOT:-/opt/cipi/api}"
    [[ -f "${root}/artisan" ]] || return 0
    # The whole tree is www-data's (the panel updates its own package in
    # it); a name inside it is whatever www-data made it, so root changes
    # owners without following links (-h) and leaves mkdir and chmod to
    # www-data itself.
    chown -h -R www-data:www-data "$root" 2>/dev/null || true
    panel_sh 'mkdir -p "$1/storage/logs" "$1/database" "$1/bootstrap/cache"
              [[ -f "$1/.env" && ! -L "$1/.env" ]] && chmod 640 "$1/.env"
              exit 0' "$root" 2>/dev/null < /dev/null || true
}

# Wall-clock limit when GNU timeout exists (composer/git/ssh-keyscan/systemctl).
_cipi_run_timed() {
    local secs="$1"
    shift
    if command -v timeout >/dev/null 2>&1; then
        # --foreground: keep Ctrl+C working when run interactively
        timeout --foreground "$secs" "$@"
    else
        "$@"
    fi
}

# Wrap `composer` in this shell so even older in-memory self-update bodies
# cannot hang forever on VCS/git (first upgrade pass sources new common.sh,
# then still runs the pre-update function text that calls bare `composer`).
_cipi_composer_guard() {
    [[ -n "${_CIPI_COMPOSER_GUARD:-}" ]] && return 0
    local bin
    bin="$(command -v composer 2>/dev/null || true)"
    [[ -n "$bin" && -x "$bin" ]] || return 0
    _CIPI_COMPOSER_BIN="$bin"
    _CIPI_COMPOSER_GUARD=1
    composer() {
        local bin="${_CIPI_COMPOSER_BIN:-/usr/local/bin/composer}"
        local secs="${CIPI_COMPOSER_TIMEOUT:-600}"
        export GIT_TERMINAL_PROMPT=0
        export COMPOSER_PROCESS_TIMEOUT="${COMPOSER_PROCESS_TIMEOUT:-300}"
        export COMPOSER_DISABLE_XDEBUG=1
        export COMPOSER_ALLOW_SUPERUSER=1
        # Close stdin so Composer never blocks on an accidental prompt (TTY Enter).
        if command -v timeout >/dev/null 2>&1; then
            timeout --foreground "$secs" "$bin" "$@" </dev/null
        else
            "$bin" "$@" </dev/null
        fi
    }
}

# Seed known_hosts for github.com without hanging. Bare `ssh-keyscan` has no
# useful default timeout and blocks forever on filtered egress — that left
# self-update stuck on "Updating cipi-api in Laravel app...".
_cipi_github_known_hosts() {
    local ssh_dir="/root/.ssh"
    local kh="${ssh_dir}/known_hosts"
    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"
    if grep -qE '(^|[,[:space:]])github\.com[,[:space:]]' "$kh" 2>/dev/null; then
        chmod 600 "$kh" 2>/dev/null || true
        return 0
    fi
    _cipi_run_timed 10 ssh-keyscan -T 5 -H github.com >> "$kh" 2>/dev/null || true
    if ! grep -qE '(^|[,[:space:]])github\.com[,[:space:]]' "$kh" 2>/dev/null; then
        # Official GitHub host keys (docs.github.com — SSH key fingerprints)
        cat >> "$kh" <<'EOF'
github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
github.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=
github.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk=
EOF
    fi
    chmod 600 "$kh" 2>/dev/null || true
}

# Composer panel updates (self-update, api/gui update) run as root. Package metadata
# may use git@github.com source URLs; without github.com in /root/.ssh/known_hosts
# git blocks on "Are you sure you want to continue connecting (yes/no)?".
_cipi_composer_prepare_github() {
    local dir="${1:-}"
    [[ -n "$dir" && -d "$dir" ]] || return 0
    _cipi_github_known_hosts
    _cipi_composer_guard
    export GIT_TERMINAL_PROMPT=0
    export COMPOSER_PROCESS_TIMEOUT="${COMPOSER_PROCESS_TIMEOUT:-300}"
    export COMPOSER_ALLOW_SUPERUSER=1
    # As the tree's own user where that is www-data (panel_composer).
    panel_composer "$dir" config --json github-protocols '["https"]' 2>/dev/null || true
    panel_composer "$dir" config preferred-install dist 2>/dev/null || true
}

# ── Root and the panel's trees ───────────────────────────────
# /opt/cipi/api and /opt/cipi/gui belong to www-data, the user every request
# to the panel runs as. Composer takes composer.json, its plugins and its
# scripts from the tree it runs in, and artisan boots the code it finds
# there: run by root, either one is root running what www-data wrote. A
# .env edited by root with sed, `>>` and chown is root writing wherever that
# name leads. So in a tree of www-data's root asks www-data to do it — the
# rule root follows in an app's home (app_as), and the same helpers.
#
# A tree that is still root's (the build directory of `cipi api` /
# `cipi gui`, before it is moved into place) is worked on by root as before.
[[ -z "${PANEL_COMPOSER_HOME:-}" ]] && readonly PANEL_COMPOSER_HOME="/var/lib/cipi-panel/composer"

# By where it is, not by who owns it at this moment: `cipi self-update`
# chowns all of /opt/cipi to root before it updates the panel, and what is
# in the tree is still what www-data wrote.
_panel_tree_is_www() {   # <dir or file>
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || return 1
    local d="${1%/}" r
    for r in "${CIPI_API_ROOT:-/opt/cipi/api}" "${CIPI_GUI_ROOT:-/opt/cipi/gui}"; do
        [[ "$d" == "$r" || "$d" == "$r"/* ]] && return 0
    done
    return 1
}
# The tree back to www-data when root has it (after that chown, after an
# older version's root-run composer): www-data is about to work in it.
# -h -R changes a link, never what it points at, and walks by descriptor.
_panel_tree_hand_back() {   # <dir or file in a panel tree>
    local d="${1%/}" r
    for r in "${CIPI_API_ROOT:-/opt/cipi/api}" "${CIPI_GUI_ROOT:-/opt/cipi/gui}"; do
        [[ "$d" == "$r" || "$d" == "$r"/* ]] || continue
        [[ -d "$r" && ! -L "$r" ]] || return 1
        if [[ "$(stat -c '%U' -- "$r" 2>/dev/null || true)" != "www-data" ]]; then
            chown -h -R www-data:www-data "$r" 2>/dev/null || true
        fi
        return 0
    done
    return 1
}

# composer in <dir>. Composer's own home (cache, keys, config) is a
# directory of www-data's outside any web root: /var/www is not it.
panel_composer() {   # <dir> <composer args…>
    local dir="$1"; shift
    # The binary, not the `composer` function _cipi_composer_guard defines;
    # the same wall-clock limit and closed stdin as that function.
    local bin="${_CIPI_COMPOSER_BIN:-$(type -P composer 2>/dev/null || true)}"
    [[ -n "$bin" ]] || { echo "composer not found" >&2; return 127; }
    local -a run=("$bin")
    if command -v timeout >/dev/null 2>&1; then
        run=(timeout --foreground "${CIPI_COMPOSER_TIMEOUT:-600}" "$bin")
    fi
    if _panel_tree_is_www "$dir"; then
        _panel_tree_hand_back "$dir" || return 1
        # Its parent is root's and open to traverse; the home itself is
        # www-data's alone (/var/lib/cipi may be closed to other users).
        [[ -d "$(dirname "$PANEL_COMPOSER_HOME")" ]] || install -d -m 755 -o root -g root "$(dirname "$PANEL_COMPOSER_HOME")" 2>/dev/null || true
        install -d -m 700 -o www-data -g www-data "$PANEL_COMPOSER_HOME" 2>/dev/null || true
        ( cd / && sudo -u www-data -- env \
            HOME="$PANEL_COMPOSER_HOME" COMPOSER_HOME="$PANEL_COMPOSER_HOME" \
            COMPOSER_PROCESS_TIMEOUT="${COMPOSER_PROCESS_TIMEOUT:-300}" GIT_TERMINAL_PROMPT=0 \
            COMPOSER_NO_INTERACTION=1 COMPOSER_DISABLE_XDEBUG=1 \
            /bin/bash -c 'cd "$1" || exit 1; shift; exec "$@"' _ "$dir" "${run[@]}" "$@" < /dev/null )
        return
    fi
    ( cd "$dir" && GIT_TERMINAL_PROMPT=0 COMPOSER_PROCESS_TIMEOUT="${COMPOSER_PROCESS_TIMEOUT:-300}" \
        COMPOSER_DISABLE_XDEBUG=1 COMPOSER_ALLOW_SUPERUSER=1 "${run[@]}" "$@" < /dev/null )
}

# KEY=VALUE pairs into a .env: a key that is there is replaced, one that is
# not is appended; the file ends up 640. The value is data — never part of
# the sed script.
_panel_env_set_do() {   # <file> <KEY> <VALUE> [<KEY> <VALUE>…]
    local f="$1" k v esc; shift
    [[ -f "$f" && ! -L "$f" ]] || return 1
    while [[ $# -ge 2 ]]; do
        k="$1"; v="$2"; shift 2
        [[ "$k" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        if grep -q "^${k}=" "$f" 2>/dev/null; then
            esc=$(printf '%s' "$v" | sed 's/[\\&|]/\\&/g')
            sed -i "s|^${k}=.*|${k}=${esc}|" "$f" || return 1
        else
            printf '%s=%s\n' "$k" "$v" >> "$f" || return 1
        fi
    done
    chmod 640 "$f" 2>/dev/null || true
    return 0
}
panel_env_set() {   # <file> <KEY> <VALUE> [<KEY> <VALUE>…]
    local f="${1:-}"
    [[ -n "$f" ]] || return 1
    if _panel_tree_is_www "$f"; then
        _panel_tree_hand_back "$f" || return 1
        app_call www-data "_panel_env_set_do" _panel_env_set_do "$@" < /dev/null
        return
    fi
    _panel_env_set_do "$@" || return 1
    # A tree of root's that www-data will be given: the file with it.
    if [[ "${EUID:-$(id -u)}" -eq 0 && ! -L "$f" ]]; then chown -h www-data:www-data "$f" 2>/dev/null || true; fi
    return 0
}
# A .env of the panel, read as its owner.
panel_env_read() {   # <file>
    if _panel_tree_is_www "${1:-}"; then
        _panel_tree_hand_back "$1" || return 1
        app_as www-data cat -- "$1" 2>/dev/null < /dev/null
        return
    fi
    cat -- "$1" 2>/dev/null
}
# Anything else in a panel tree, as its owner: a bash script, "$1"… its args.
panel_sh() {   # <script> [args…]
    app_sh www-data "$@"
}
# A file of a panel tree copied out of it (into a backup directory of
# root's): read by www-data, written by root. Nothing when it is not there
# or www-data cannot read it.
panel_backup_file() {   # <file in the tree> <destination>
    local src="$1" dst="$2"
    [[ -f "$src" ]] || return 0
    if _panel_tree_is_www "$src"; then
        app_as www-data cat -- "$src" 2>/dev/null < /dev/null > "$dst" || { rm -f "$dst"; return 0; }
        return 0
    fi
    cp "$src" "$dst"
}

app_set() {
    vault_read apps.json | jq --arg a "$1" --arg k "$2" --arg v "$3" '.[$a][$k] = $v' | vault_write apps.json
    ensure_apps_json_api_access
}

# Delete a key from an app entry (e.g. clear octane after convert to FPM).
app_unset() {
    vault_read apps.json | jq --arg a "$1" --arg k "$2" 'del(.[$a][$k])' | vault_write apps.json
    ensure_apps_json_api_access
}

# Set a JSON value (object/array/bool/number) on an app entry.
app_set_json() {
    vault_read apps.json | jq --arg a "$1" --arg k "$2" --argjson v "$3" '.[$a][$k] = $v' | vault_write apps.json
    ensure_apps_json_api_access
}

# Read a numeric/string limit from apps.json .limits.<key>, with default + hard cap.
# Usage: _app_limit <app> <key> <default> [max]
_app_limit() {
    local app="$1" key="$2" default="$3" max="${4:-}"
    local val
    val=$(vault_read apps.json | jq -r --arg a "$app" --arg k "$key" \
        '.[$a].limits[$k] // empty' 2>/dev/null || true)
    [[ -z "$val" || "$val" == "null" ]] && val="$default"
    if [[ -n "$max" && "$val" =~ ^[0-9]+$ && "$max" =~ ^[0-9]+$ ]]; then
        (( val > max )) && val="$max"
    fi
    echo "$val"
}

# Remove a [program:…] block from an app's supervisor conf.
_supervisor_remove_program() {
    local app="$1" prog="$2"
    local conf="/etc/supervisor/conf.d/${app}.conf"
    [[ -f "$conf" ]] || return 0
    local tmp; tmp=$(mktemp)
    awk -v p="[program:${prog}]" '$0==p{s=1;next}/^\[program:/{s=0}!s' "$conf" >"$tmp"
    mv "$tmp" "$conf"
    # Drop the file only when nothing is left in it. This used to be the last
    # statement, so the function returned 1 in the ordinary case (other
    # programs still present) and aborted its caller under `set -e` — which is
    # how `cipi worker horizon enable` stopped halfway with no message.
    [[ ! -s "$conf" ]] && rm -f "$conf"
    return 0
}

# Validate node build command (fail-closed). Allows npm/npx/yarn/pnpm/bun/node only.
_validate_node_build_cmd() {
    local cmd="$1"
    [[ -z "$cmd" ]] && return 0
    [[ ${#cmd} -gt 200 ]] && return 1
    # Reject shell metacharacters that enable injection
    [[ "$cmd" == *'|'* || "$cmd" == *'<'* || "$cmd" == *'>'* ]] && return 1
    [[ "$cmd" == *'`'* || "$cmd" == *'$('* ]] && return 1
    # Allow alnum, spaces, &&, ;, quotes, and common npm path chars
    if ! printf '%s' "$cmd" | grep -Eq '^[a-zA-Z0-9_./= :&;'\''"-]+$'; then
        return 1
    fi
    case "$cmd" in
        npm|npm\ *|npx|npx\ *|yarn|yarn\ *|pnpm|pnpm\ *|bun|bun\ *|node|node\ *) return 0 ;;
        *) return 1 ;;
    esac
}

# Write /home/<app>/.deployer/node-build.sh from apps.json node_build (or remove it).
_sync_node_build_script() {
    local app="$1"
    local cmd home
    cmd=$(app_get "$app" node_build)
    home="/home/${app}"
    # Made, written and removed as the app user (see app_as). Root wrote the
    # script and chowned it: with node-build.sh a symlink, the file it pointed
    # at was overwritten and handed to the app — and an app with `cipi yml
    # auto on` reaches this on its own, through sudo (5.9.0).
    app_mkdir "$app" "${home}/.deployer"
    if [[ -z "$cmd" ]]; then
        app_rm "$app" "${home}/.deployer/node-build.sh"
        return 0
    fi
    # An app with its own Node major (Node apps, Laravel apps pinned with
    # --node-version) builds with it; otherwise /usr/local/bin — where
    # `cipi node default` links the server default — comes before /usr/bin.
    local node_ver path_line='export PATH="/usr/local/bin:$PATH"'
    node_ver=$(app_get "$app" node_version)
    [[ "$node_ver" =~ ^[0-9]{2}$ ]] && path_line="export PATH=\"/opt/cipi/node/${node_ver}/bin:/usr/local/bin:\$PATH\""
    app_write "$app" "${home}/.deployer/node-build.sh" 750 <<EOF
#!/bin/bash
set -euo pipefail
${path_line}
cd "\${1:-\$(pwd)}"
${cmd}
EOF
}

app_save() {
    local json
    json=$(vault_read apps.json) || json="{}"
    local result
    if ! result=$(echo "$json" | jq --arg a "$1" --argjson d "$2" '.[$a] = $d' 2>/dev/null); then
        error "Failed to save app config (invalid JSON?)"; return 1
    fi
    echo "$result" | vault_write apps.json
    ensure_apps_json_api_access
}

app_remove() {
    vault_read apps.json | jq --arg a "$1" 'del(.[$a])' | vault_write apps.json
    ensure_apps_json_api_access
}

# Remove Linux user, primary group, and home (including ~/.ssh deploy keys).
# userdel -r often fails when processes still hold the UID (cron, leftover
# php-fpm, open SSH); without a fallback the home/keys become orphans.
remove_app_linux_user() {
    local app="${1:-}"
    [[ -z "$app" || "$app" == "cipi" ]] && return 0
    validate_username "$app" || return 1

    gpasswd -d www-data "$app" 2>/dev/null || true
    crontab -u "$app" -r 2>/dev/null || true

    if id "$app" &>/dev/null; then
        pkill -KILL -u "$app" 2>/dev/null || true
        local i=0
        while (( i < 10 )) && pgrep -u "$app" &>/dev/null; do
            sleep 0.2
            ((i++)) || true
        done
        if ! userdel -r "$app" 2>/dev/null; then
            userdel "$app" 2>/dev/null || true
        fi
    fi
    groupdel "$app" 2>/dev/null || true
    # Absolute cleanup — home + SSH keys must not linger after a partial userdel
    [[ -e "/home/${app}" ]] && rm -rf "/home/${app}"
    # The logs root wrote for it (nginx, supervisor, deploy.log — 5.9.0).
    [[ -d "/var/log/cipi-apps/${app}" ]] && rm -rf "/var/log/cipi-apps/${app}"
    return 0
}

# Drop Linux users / homes that look like Cipi apps but are no longer in apps.json
# (incomplete delete, failed create, or old userdel -r failure). Requires a Cipi
# footprint so unrelated local accounts are never touched.
purge_orphan_app_users() {
    local registered="" u home footprint purged=0
    [[ -f "${CIPI_CONFIG}/apps.json" ]] || return 0
    registered=$(vault_read apps.json 2>/dev/null | jq -r 'keys[]' 2>/dev/null || true)

    for home in /home/*/; do
        [[ -d "$home" ]] || continue
        u=$(basename "$home")
        validate_username "$u" || continue
        [[ "$u" == "cipi" ]] && continue
        if printf '%s\n' "$registered" | grep -Fxq "$u"; then
            continue
        fi

        footprint=false
        if id "$u" &>/dev/null && id -nG "$u" 2>/dev/null | grep -qw cipi-apps; then
            footprint=true
        fi
        [[ -d "${home}.deployer" ]] && footprint=true
        [[ -f "${home}.ssh/id_ed25519" ]] && footprint=true
        [[ -f "/etc/nginx/sites-available/${u}" ]] && footprint=true
        [[ "$footprint" == "true" ]] || continue

        info "Purging orphan app user '${u}'..."
        rm -f "/etc/nginx/sites-enabled/${u}" "/etc/nginx/sites-available/${u}"
        rm -f /etc/php/*/fpm/pool.d/"${u}.conf"
        rm -f "/etc/supervisor/conf.d/${u}.conf"
        rm -f "/etc/sudoers.d/cipi-${u}" "/etc/sudoers.d/cipi-${u}-yml"
        rm -f "/etc/nginx/cipi-basicauth/${u}.htpasswd"
        supervisorctl stop "${u}-worker-"* 2>/dev/null || true
        remove_app_linux_user "$u"
        ((purged++)) || true
    done

    if (( purged > 0 )); then
        nginx -t &>/dev/null && systemctl reload nginx 2>/dev/null || true
        supervisorctl reread &>/dev/null || true
        supervisorctl update &>/dev/null || true
    fi
    return 0
}

get_db_root_password() { vault_read server.json | jq -r '.db_root_password'; }

confirm() {
    echo -e -n "${YELLOW}${1:-Are you sure?} [y/N]: ${NC}"; read -r r; [[ "$r" =~ ^[Yy]$ ]]
}

# The same question with yes as the default: Enter goes on, n stops.
confirm_yes() {
    echo -e -n "${YELLOW}${1:-Continue?} [Y/n]: ${NC}"; read -r r; [[ ! "$r" =~ ^[Nn] ]]
}

read_input() {
    local prompt="$1" default="${2:-}" var="$3"
    if [[ -n "$default" ]]; then echo -e -n "${CYAN}${prompt}${NC} [${default}]: "
    else echo -e -n "${CYAN}${prompt}${NC}: "; fi
    read -r input; printf -v "$var" '%s' "${input:-$default}"
}

# Tables with columns sized from the data (tbl_start, tbl_row, tbl_print …).
# Loaded from next to this file, so it is there whatever CIPI_LIB says.
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/table.sh"

# Numbered menu with the default marked. Accepts the number or the value
# itself; anything else asks again, an empty answer takes the default. Without
# a terminal (panel API, a script) the default is taken without printing.
# Usage: read_choice "<prompt>" "<default>" <var> "value|label" ["value|label" ...]
read_choice() {
    local prompt="$1" default="$2" var="$3"; shift 3
    local -a values=() labels=()
    local opt i n answer def_idx=1
    for opt in "$@"; do
        values+=("${opt%%|*}"); labels+=("${opt#*|}")
    done
    n=${#values[@]}
    [[ -t 0 ]] || { printf -v "$var" '%s' "$default"; return 0; }
    echo -e "  ${BOLD}${prompt}${NC}"
    for ((i = 0; i < n; i++)); do
        local mark=""
        [[ "${values[$i]}" == "$default" ]] && { mark=" ${DIM}(default)${NC}"; def_idx=$((i + 1)); }
        printf "    ${CYAN}%d${NC}) %-10s %s%b\n" "$((i + 1))" "${values[$i]}" "${labels[$i]}" "$mark"
    done
    while true; do
        echo -e -n "  ${CYAN}Choice${NC} [${def_idx}]: "
        read -r answer || answer=""
        answer="${answer#"${answer%%[![:space:]]*}"}"; answer="${answer%"${answer##*[![:space:]]}"}"
        [[ -z "$answer" ]] && { printf -v "$var" '%s' "$default"; return 0; }
        if [[ "$answer" =~ ^[0-9]+$ ]] && (( answer >= 1 && answer <= n )); then
            printf -v "$var" '%s' "${values[$((answer - 1))]}"; return 0
        fi
        for ((i = 0; i < n; i++)); do
            [[ "${values[$i]}" == "$answer" ]] && { printf -v "$var" '%s' "$answer"; return 0; }
        done
        echo -e "  ${YELLOW}Choose 1-${n}${NC}"
    done
}

# --key=value → ARG_key=value, --flag → ARG_flag=true.
#
# An option name is letters, digits, "-" and "_" and nothing else; anything
# else is not an option and is ignored. The name ends up in `printf -v`, and
# bash evaluates an array subscript in the name it is given there, command
# substitutions included: `--x[$(cmd)]` ran cmd. Every `cipi` command parses
# its arguments here, as root — so that was root for whoever may pass
# arguments to a root `cipi` through sudo: an app user with the rule
# `cipi yml node-sync <app> *` (written by `cipi yml auto <app> on`). Same
# family as the cipi-app-notify exit code (5.9.0). Values are never
# evaluated: they are stored with printf '%s'.
parse_args() {
    for arg in "$@"; do
        case "$arg" in
            --*=*) local k="${arg%%=*}" v="${arg#*=}"; k="${k#--}"
                [[ "$k" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || continue
                # Panel API builds --key='value' via escapeshellarg(); keep the value, drop wrapping quotes.
                if [[ "$v" == \'*\' && ${#v} -ge 2 ]]; then v="${v:1:${#v}-2}"; fi
                if [[ "$v" == \"*\" && ${#v} -ge 2 ]]; then v="${v:1:${#v}-2}"; fi
                printf -v "ARG_${k//-/_}" '%s' "$v" ;;
            --*)   local k="${arg#--}"
                [[ "$k" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || continue
                printf -v "ARG_${k//-/_}" '%s' "true" ;;
        esac
    done
}

reload_nginx() {
    if ! nginx -t 2>&1; then
        error "nginx config test failed. Fix config and run: nginx -t"
        return 1
    fi
    systemctl reload nginx || { error "systemctl reload nginx failed"; return 1; }
}

reload_php_fpm() {
    systemctl restart "php${1}-fpm" || { error "Failed to restart php${1}-fpm"; return 1; }
}

# The PHP the `php` command is (cipi php switch) — the one whose FPM hosts
# the panel's pools (cipi-api, cipi-gui): what setup.sh installed, 8.6 from
# Cipi 5.9.1 and 8.5 before. 8.5 when the CLI does not answer.
php_system_version() {
    php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "8.5"
}

# The PHP a new app gets when none is asked for: the server's own. So a
# server installed with 8.6 creates apps on 8.6, and one installed before
# keeps creating them on what it has — `cipi php install 8.6` adds a
# version there, it does not make it the default (`cipi php switch` does).
# When the server's PHP cannot host an app (the CLI does not answer, or it
# is older than 8.3): the first one installed, 8.6 last, since on a server
# that did not choose it it may still be a release candidate.
php_app_default() {
    local v
    v=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)
    if validate_php_version "$v" && php_is_installed "$v"; then
        echo "$v"
        return 0
    fi
    for v in 8.5 8.4 8.3 8.6; do
        if php_is_installed "$v"; then
            echo "$v"
            return 0
        fi
    done
    echo "8.5"
}

reload_supervisor() {
    supervisorctl reread 2>&1 || { error "supervisorctl reread failed"; return 1; }
    supervisorctl update 2>&1 || warn "Supervisor update had issues (worker may start after first deploy)"
}

# ── Logs that root writes: /var/log/cipi-apps/<app> ──────────
#
# /home/<app>/logs belongs to the app user, and three things wrote there as
# root: nginx (the master opens every access_log / error_log while it loads its
# configuration), supervisord (it opens a program's stdout_logfile each time
# it starts the program) and `cipi deploy` (it appended to deploy.log and then
# chowned it to the app). None of them looks at what it opens: a symlink put
# there in place of a log was followed. `cipi deploy` handed the file it
# pointed at to the app user — /etc/passwd, say; supervisord appended a
# worker's output to it, on `sudo cipi-worker restart`, which every app user
# may run. Any app user to root (5.9.0).
#
# Those logs now live in /var/log/cipi-apps/<app>: root's directory, which the
# app user reads (it is the directory's group) and cannot add to, rename in or
# remove from. ~/logs stays the app's own, for what the app itself writes
# (php-fpm-error.log, cron.log, anything of its own), and holds one symlink
# per moved log, so every path people and tools know still reads. Root never
# creates, renames or follows anything inside ~/logs: what has to happen
# there is done as the app user (_app_as), and root reads an app's logs as
# the app user too.
app_log_dir() { echo "/var/log/cipi-apps/${1:-}"; }

# Run a bash script as the app user, from / (root's working directory may be
# one the app user cannot enter). Never fails the caller.
_app_as() {   # <app> <script> [args…]
    local app="$1" script="$2"; shift 2
    (cd / && sudo -u "$app" /bin/bash -c "$script" _ "$@") 2>/dev/null < /dev/null || true
}

# ── Root and an app's home ───────────────────────────────────
# Everything under /home/<app> is the app user's to rename, replace and link:
# a name root opens there is whatever the app made of it a moment ago. So
# root does not open, create, delete, chown or chmod a path inside an app's
# home, and does not run a program on a tree it finds there (git reads the
# repository's own configuration). It asks the app user to: the kernel then
# checks every step with that user's rights, and a symlink to /etc/shadow is
# a "permission denied", not a file handed over. What root still does itself
# is on names it controls — /home/<app> itself — or without following
# anything (`chown -h -R`, which walks by descriptor; `rm -rf`; a test with
# [[ -f ]]).
#
# The exception is an app being created (cipi app create, cipi sync import):
# nobody can be that user before the command that makes it has finished.
#
#   app_as <app> <command> [args…]        the command's own status and output
#   app_sh <app> <script> [args…]         a bash script, "$1"… are its args
#   app_call <app> "<fn> …" <fn> [args…]  shell functions defined here
#   app_read <app> <file>                 its content (nothing when unreadable)
#   app_write <app> <file> [mode]         stdin → the file
#   app_append <app> <file>               stdin → its end
#   app_sed <app> <file> <sed args…>      sed -i
#   app_rm <app> <path>…                  rm -f
#   app_mkdir <app> <dir> [mode]          mkdir -p
#   app_of_path <path>                    whose home a path is in (for root)
#
# Root drops with sudo -u. Anyone else — the app user itself, in
# cipi-app-post-deploy — has no more rights than that already and runs the
# command as it is.
app_as() {   # <app> <command> [args…]
    local app="$1"; shift
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        ( cd / 2>/dev/null; "$@" )
        return
    fi
    ( cd / && sudo -u "$app" -- "$@" )
}
app_sh() {   # <app> <script> [args…]
    local app="$1" script="$2"; shift 2
    app_as "$app" /bin/bash -c "$script" _ "$@"
}
# The functions travel as text (declare -f): what they call must be named too.
app_call() {   # <app> "<function> …" <function> [args…]
    local app="$1" fns="$2"; shift 2
    # shellcheck disable=SC2086
    app_as "$app" /bin/bash -c "$(declare -f app_of_path $fns)"$'\n''"$@"' _ "$@"
}
# The app whose home a path is in — for root only: 1 for anyone else, and for
# a path that is in no app's home. A function that works on a path starts with
#     local _o; if _o=$(app_of_path "$1"); then _app_own_check "$_o" "$1"; app_call "$_o" "<itself> …" <itself> "$@"; return; fi
# and is then the same function for an admin's own file, for the app user,
# and — run as the app user — for root on a file in an app's home.
app_of_path() {   # <path>
    [[ "${EUID:-$(id -u)}" -eq 0 && "${1:-}" =~ ^/home/([a-z][a-z0-9]{2,31})/ ]] || return 1
    id "${BASH_REMATCH[1]}" &>/dev/null || return 1
    printf '%s' "${BASH_REMATCH[1]}"
}

# What is left of a time when root wrote here: a file or a directory of
# root's inside the home, which the app user cannot replace or enter. The one
# thing root does about it is hand the whole top-level entry back —
# /home/<app>/<name>, whose parent is root's, so the name is the one meant;
# -h -R changes a link and never what it points at, and walks by descriptor.
_app_reown() {   # <app> <path under the home>
    local app="$1" path="$2" rel top
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || return 1
    [[ "$app" =~ ^[a-z][a-z0-9]{2,31}$ && "$path" == "/home/${app}/"?* ]] || return 1
    rel="${path#"/home/${app}/"}"; top="${rel%%/*}"
    [[ -n "$top" && "$top" != "." && "$top" != ".." ]] || return 1
    chown -h -R "${app}:${app}" "/home/${app}/${top}" 2>/dev/null
}
# A command of root's inside a directory of an app's home, on "." — and only
# when that directory really is where its name says: with a symlink anywhere
# on the way the physical path differs, and nothing runs. Once inside, the
# directory cannot be swapped under the command.
_app_dir_do() {   # <app> <directory, relative to the home> <command> [args…]
    local app="$1" rel="$2"; shift 2
    (
        cd "/home/${app}" 2>/dev/null || exit 1
        want="$(pwd -P)/${rel}"
        cd "$rel" 2>/dev/null || exit 1
        [[ "$(pwd -P)" == "$want" ]] || exit 1
        "$@"
    )
}
# Before the app user is asked to work on a path: is it, or the directory it
# is in, somebody else's? Then _app_reown. Looked at, never opened: stat on
# the name itself.
_app_own_check() {   # <app> <path>
    local app="$1" path="$2" uid o t
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || return 0
    uid=$(id -u "$app" 2>/dev/null) || return 0
    for t in "$path" "$(dirname -- "$path")"; do
        o=$(stat -c '%u' -- "$t" 2>/dev/null || true)
        if [[ -n "$o" && "$o" != "$uid" ]]; then
            _app_reown "$app" "$path" || true
            return 0
        fi
    done
    return 0
}
# A file operation as the app user. The script gets the path as "$1", then
# the arguments; stdin is the caller's.
_app_file_op() {   # <app> <path> <script> [args…]
    local app="$1" path="$2" script="$3"; shift 3
    _app_own_check "$app" "$path"
    app_sh "$app" "$script" "$path" "$@"
}
app_read() {   # <app> <file>
    _app_own_check "$1" "$2"
    app_as "$1" cat -- "$2" 2>/dev/null < /dev/null
}
# In place, like the `cat > file` root ran before: a file that exists keeps
# its inode and, without a mode, its mode. A new file is 644, or private from
# its first byte when a mode is given. All of stdin is taken before the file
# is opened, so a pipeline may read the file it writes.
app_write() {   # <app> <file> [mode]
    local buf rc=0
    # root's own file, 600: it is handed over as an open descriptor.
    buf=$(mktemp) || return 1
    cat > "$buf" || { rm -f "$buf"; return 1; }
    _app_file_op "$1" "$2" '
        f="$1"; m="$2"; umask 022
        if [[ -n "$m" && ! -e "$f" ]]; then ( umask 077; : > "$f" ) || exit 1; fi
        cat > "$f" || exit 1
        if [[ -n "$m" ]]; then chmod "$m" "$f" || exit 1; fi
        exit 0' "${3:-}" < "$buf" || rc=$?
    rm -f "$buf"
    return $rc
}
app_append() {   # <app> <file>
    _app_file_op "$1" "$2" 'umask 022; cat >> "$1"'
}
app_sed() {   # <app> <file> <sed args…>
    local app="$1" path="$2"; shift 2
    _app_file_op "$app" "$path" 'f="$1"; shift; sed -i "$@" "$f"' "$@" < /dev/null
}
app_rm() {   # <app> <path>…
    local app="$1"; shift
    app_as "$app" rm -f -- "$@" 2>/dev/null < /dev/null
}
app_mkdir() {   # <app> <dir> [mode]
    _app_file_op "$1" "$2" 'umask 022; mkdir -p "$1" || exit 1; if [[ -n "$2" ]]; then chmod "$2" "$1" || exit 1; fi; exit 0' "${3:-}" < /dev/null
}

# The directory, and deploy.log in it — the one log both root (`cipi deploy`)
# and the app user (the webhook deploy) append to: the app user owns the file
# and cannot replace it. The first time, it starts from the last lines of the
# old ~/logs/deploy.log, read as the app user, so the panel still shows the
# deploys from before the move. Idempotent; returns 1 when the directory
# could not be made (callers then leave the old path alone).
app_log_dir_ensure() {
    local app="${1:-}" dir grp
    [[ "$app" =~ ^[a-z][a-z0-9]{2,31}$ ]] || return 1
    id "$app" &>/dev/null || return 1
    dir="/var/log/cipi-apps/${app}"
    grp=$(id -gn "$app" 2>/dev/null) || return 1
    [[ -d /var/log/cipi-apps ]] || install -d -m 755 -o root -g root /var/log/cipi-apps 2>/dev/null || return 1
    if [[ ! -d "$dir" || -L "$dir" || "$(stat -c '%U:%G:%a' "$dir" 2>/dev/null)" != "root:${grp}:750" ]]; then
        [[ -L "$dir" ]] && rm -f "$dir"
        install -d -m 750 -o root -g "$grp" "$dir" 2>/dev/null || return 1
        if command -v setfacl &>/dev/null && id cipi &>/dev/null; then
            setfacl -m u:cipi:rx "$dir" 2>/dev/null || true
        fi
    fi
    if [[ ! -f "${dir}/deploy.log" || -L "${dir}/deploy.log" ]]; then
        rm -f "${dir}/deploy.log" 2>/dev/null || true
        ( umask 077; : > "${dir}/deploy.log" ) 2>/dev/null || return 1
        # Quoted in the script, read as the app user: a symlink there gives
        # the app nothing it could not read already.
        (cd / && sudo -u "$app" /bin/bash -c '[[ -f "$1" && ! -L "$1" ]] && tail -n 20000 "$1"' _ "/home/${app}/logs/deploy.log") \
            >> "${dir}/deploy.log" 2>/dev/null || true
        chown "${app}:www-data" "${dir}/deploy.log" 2>/dev/null || chown "${app}:${grp}" "${dir}/deploy.log" 2>/dev/null || true
        chmod 664 "${dir}/deploy.log" 2>/dev/null || true
    fi
    return 0
}

# ~/logs/<name> → /var/log/cipi-apps/<app>/<name>, for each name given. Made
# by the app user itself. A regular file already there — the log from before
# the move — is kept as <name>.old; a symlink that points elsewhere is
# replaced. Names are plain file names: anything else is skipped.
app_log_links() {   # <app> <name>…
    local app="${1:-}"; shift || true
    [[ "$app" =~ ^[a-z][a-z0-9]{2,31}$ && $# -gt 0 ]] || return 0
    id "$app" &>/dev/null || return 0
    _app_as "$app" '
        dir="$1"; logs="$2"; shift 2
        [[ -d "$logs" ]] || mkdir -p "$logs" || exit 0
        for n in "$@"; do
            [[ "$n" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || continue
            l="${logs}/${n}"
            [[ -L "$l" && "$(readlink "$l")" == "${dir}/${n}" ]] && continue
            if [[ -L "$l" ]]; then rm -f "$l"
            elif [[ -e "$l" ]]; then mv -f "$l" "${l}.old" || continue
            fi
            ln -s "${dir}/${n}" "$l"
        done' "/var/log/cipi-apps/${app}" "/home/${app}/logs" "$@"
}

# The symlinks every app has: the two nginx logs and the deploy log.
app_log_links_default() { app_log_links "${1:-}" nginx-access.log nginx-error.log deploy.log; }

# App home is 750 (app:app): user cipi cannot traverse /home/<app>/ without ACLs.
#
# Do NOT apply setfacl -R or default ACLs on shared/storage/logs — Deployer chmod on Laravel log
# files fails with "Operation not permitted" when per-file ACLs exist. Strip any file ACLs left
# from older Cipi versions, then re-apply directory ACLs only.
#
# Everything under the home is the app user's to rename: as root, nothing here
# dereferences a name found there. ~/logs is created by the app user when it
# is missing and otherwise left as it is (before 5.9.0 root ran mkdir, chown
# app:www-data and chmod 2775 on it — on whatever a symlink called "logs"
# pointed at); chown is -h; a path that is a symlink is skipped; chmod on the
# app's own files is done as the app user.
ensure_app_logs_permissions() {
    local app="${1:-}"
    [[ -z "$app" || "$app" == "cipi" ]] && return 0
    local home="/home/${app}"
    [[ -d "$home" ]] || return 0
    id "$app" &>/dev/null || return 0

    app_log_dir_ensure "$app" || true

    if [[ ! -e "${home}/logs" && ! -L "${home}/logs" ]]; then
        _app_as "$app" 'mkdir -p "$1"' "${home}/logs"
    fi

    # Reclaim root-owned log files left by old logrotate "create" rules — and,
    # since 5.9.0, the logs nginx and supervisor wrote here before the move.
    # From inside each directory, once it is known to be where its name says
    # (_app_dir_do): `shared` or `storage` as a symlink would otherwise aim
    # this at a `logs` directory anywhere. chown -R walks by descriptor and,
    # with -h, never changes what a link points at.
    local own_grp
    own_grp=$(id -gn "$app" 2>/dev/null) || own_grp="$app"
    _app_dir_do "$app" logs chown -h -R --from=root "${app}:${own_grp}" . 2>/dev/null || true
    _app_dir_do "$app" shared/storage/logs chown -h -R --from=root "${app}:${app}" . 2>/dev/null || true

    # The rest is the app user's own doing, on its own files: old ACLs off,
    # Laravel's logs group-writable, the `cipi` user allowed to read.
    local cipi_user=""
    id cipi &>/dev/null && cipi_user="cipi"
    _app_as "$app" '
        h="$1"; cu="$2"
        # Its own logs in its own group: logrotate rotates them as this user
        # (app_logrotate_rule) and gives each copy the owner and group of the
        # log — a group this user is not in (www-data, from before 5.9.0) is
        # one it cannot give, and the rotation of that file would fail.
        g=$(id -gn 2>/dev/null) || g=""
        if [[ -n "$g" ]]; then
            for d in "$h/logs" "$h/shared/storage/logs"; do
                [[ -d "$d" && ! -L "$d" ]] || continue
                find "$d" -maxdepth 1 -type f -name "*.log*" ! -group "$g" -exec chgrp "$g" {} +
            done
        fi
        acl=false; command -v setfacl >/dev/null 2>&1 && acl=true
        if [[ "$acl" == true ]]; then
            if [[ -d "$h/logs" && ! -L "$h/logs" ]]; then
                find "$h/logs" -type f -exec setfacl -b {} \; ; setfacl -k "$h/logs"
            fi
            if [[ -d "$h/shared/storage/logs" && ! -L "$h/shared/storage/logs" ]]; then
                find "$h/shared/storage/logs" -type f -name "*.log" -exec setfacl -b {} \; ; setfacl -k "$h/shared/storage/logs"
            fi
        fi
        if [[ -d "$h/shared/storage/logs" && ! -L "$h/shared/storage/logs" ]]; then
            chmod 664 "$h/shared/storage/logs"/*.log
        fi
        if [[ "$acl" == true && -n "$cu" ]]; then
            for d in logs shared shared/storage shared/storage/logs; do
                [[ -d "$h/$d" && ! -L "$h/$d" ]] || continue
                setfacl -m "u:$cu:rx" "$h/$d"
            done
            if [[ -d "$h/shared/storage/logs" && ! -L "$h/shared/storage/logs" ]]; then
                find "$h/shared/storage/logs" -type f -name "*.log" -exec setfacl -m "u:$cu:r" {} \;
            fi
        fi
        exit 0' "$home" "$cipi_user"
    if [[ -n "$cipi_user" ]] && command -v setfacl &>/dev/null; then
        setfacl -m u:cipi:rx "${home}" 2>/dev/null || true
    fi

    app_log_links_default "$app"
    app_logrotate_rule "$app" || true
}

# ── logrotate for what an app writes in its own home ─────────
# Laravel's logs and the PHP-FPM error log are the app's own files, in the
# app's own directories. One rule on /home/*/… had root rotate them: copy,
# truncate and compress, by path, in a directory the app user can rearrange.
# Each app has its own rule instead, with `su <app> <group>`: logrotate does
# that work with the app user's rights, so the most an app can do to it is
# leave its own logs unrotated. No script in the rule: logrotate runs those as
# root even with `su`.
#
# The file is cipi-home-<app>, not cipi-app-<app>: "logs" is a valid app name
# and cipi-app-logs is the shared rule.
#
# *[!0-9].log leaves out files that end in a date (laravel-2026-01-31.log):
# those belong to Laravel's `daily` channel, which names and prunes them
# itself. Rotating them too left a .log.1 per day that never expired.

# True when the shared rule no longer names the apps' homes. Until then a rule
# per app would name the same files a second time, and logrotate drops the
# whole file in which it meets a duplicate.
_app_logrotate_shared_clean() {
    local f="${CIPI_LOGROTATE_D:-/etc/logrotate.d}/cipi-app-logs"
    [[ -f "$f" ]] || return 0
    ! grep -qE '^[^#]*/home/\*/(shared/storage/logs/|logs/php-fpm-)' "$f" 2>/dev/null
}

# Writes (or refreshes) the rule of one app. Nothing to do without logrotate,
# for a name that is not an app user, or while the shared rule still covers
# the homes (a server that has not run migration 5.9.0 yet). Idempotent.
app_logrotate_rule() {
    local app="${1:-}" d="${CIPI_LOGROTATE_D:-/etc/logrotate.d}" grp f tmp
    [[ "$app" =~ ^[a-z][a-z0-9]{2,31}$ ]] || return 0
    [[ -d "$d" ]] || return 0
    id "$app" &>/dev/null || return 0
    _app_logrotate_shared_clean || return 0
    grp=$(id -gn "$app" 2>/dev/null) || return 0
    [[ "$grp" =~ ^[a-z_][a-z0-9_-]*$ ]] || return 0
    f="${d}/cipi-home-${app}"
    tmp=$(mktemp) || return 1
    cat > "$tmp" <<EOF
# cipi-home-${app} — managed by Cipi, rewritten on deploy and on update.
# The app's own logs, rotated as the app user (su): root does not copy,
# truncate or compress anything inside /home/${app}.
/home/${app}/shared/storage/logs/*[!0-9].log
/home/${app}/logs/php-fpm-*.log {
    su ${app} ${grp}
    daily
    missingok
    rotate 365
    compress
    delaycompress
    notifempty
    copytruncate
}
EOF
    if [[ -f "$f" && ! -L "$f" ]] && cmp -s "$tmp" "$f"; then
        rm -f "$tmp"; return 0
    fi
    [[ -L "$f" ]] && rm -f "$f"
    # root:root 0644 — logrotate ignores a rule file with any other owner or
    # a mode that lets someone else write it.
    if ! install -m 644 -o root -g root "$tmp" "$f" 2>/dev/null; then
        rm -f "$tmp"; return 1
    fi
    rm -f "$tmp"
    return 0
}

app_logrotate_remove() {
    local app="${1:-}"
    [[ "$app" =~ ^[a-z][a-z0-9]{2,31}$ ]] || return 0
    rm -f "${CIPI_LOGROTATE_D:-/etc/logrotate.d}/cipi-home-${app}"
}

# Rules left behind by users that no longer exist: logrotate stops at the
# `su` line of such a rule and reports an error at every run.
app_logrotate_sweep() {
    local d="${CIPI_LOGROTATE_D:-/etc/logrotate.d}" f u
    [[ -d "$d" ]] || return 0
    for f in "$d"/cipi-home-*; do
        [[ -f "$f" || -L "$f" ]] || continue
        u="${f##*/cipi-home-}"
        [[ "$u" =~ ^[a-z][a-z0-9]{2,31}$ ]] || continue
        id "$u" &>/dev/null || rm -f "$f"
    done
    return 0
}

# Takes the homes out of the shared rule — only the lines Cipi wrote, whole —
# and returns 0 when it no longer names them. A rule someone has rearranged
# is left as it is (return 1): the caller then keeps the old behaviour.
_app_logrotate_shared_strip() {
    local f="${CIPI_LOGROTATE_D:-/etc/logrotate.d}/cipi-app-logs" tmp
    _app_logrotate_shared_clean && return 0
    [[ -f "$f" && ! -L "$f" ]] || return 1
    tmp=$(mktemp) || return 1
    grep -vxF -e '/home/*/shared/storage/logs/*[!0-9].log' \
              -e '/home/*/shared/storage/logs/*.log' \
              -e '/home/*/logs/php-fpm-*.log' "$f" > "$tmp" 2>/dev/null || true
    # Still a rule: a path left, and the block it opens.
    if [[ -s "$tmp" ]] && grep -q '{' "$tmp" && grep -qE '^[[:space:]]*/[^[:space:]]' "$tmp" \
        && ! grep -qE '^[^#]*/home/\*/(shared/storage/logs/|logs/php-fpm-)' "$tmp"; then
        cat "$tmp" > "$f" 2>/dev/null || { rm -f "$tmp"; return 1; }
        rm -f "$tmp"; return 0
    fi
    rm -f "$tmp"; return 1
}

# Every app, at once (migration 5.9.0, `cipi app fix-permissions`): the shared
# rule first — the other order would name each log twice for a moment — then
# each app's logs into its own group and its rule. Prints what it did.
# Returns 1 when the shared rule could not be changed (nothing else is then).
app_logrotate_all() {   # <app>…
    local d="${CIPI_LOGROTATE_D:-/etc/logrotate.d}" app n=0 failed=""
    [[ -d "$d" ]] || return 0
    if ! _app_logrotate_shared_strip; then
        echo "  WARNING: ${d}/cipi-app-logs is not the rule Cipi wrote — left as it is: the apps' own logs are still rotated by root"
        echo "           (remove its /home/*/… lines, then: cipi app fix-permissions)"
        return 1
    fi
    app_logrotate_sweep
    for app in "$@"; do
        [[ "$app" =~ ^[a-z][a-z0-9]{2,31}$ ]] || continue
        id "$app" &>/dev/null || continue
        _app_as "$app" '
            g=$(id -gn 2>/dev/null) || exit 0
            for d in "$1/logs" "$1/shared/storage/logs"; do
                [[ -d "$d" && ! -L "$d" ]] || continue
                find "$d" -maxdepth 1 -type f -name "*.log*" ! -group "$g" -exec chgrp "$g" {} +
            done
            exit 0' "/home/${app}"
        if app_logrotate_rule "$app" && [[ -f "${d}/cipi-home-${app}" ]]; then
            n=$((n + 1))
        else
            failed="${failed} ${app}"
        fi
    done
    # The shared rule named every home, an app's or not. A home with the
    # shape of an app (an account left by a failed delete, a site set up by
    # hand) keeps being rotated, by its own rule; any other is named, since
    # nothing rotates it from now on.
    local h u other=""
    for h in /home/*/; do
        u="${h%/}"; u="${u##*/}"
        [[ "$u" == "cipi" || -f "${d}/cipi-home-${u}" ]] && continue
        compgen -G "/home/${u}/shared/storage/logs/*.log" >/dev/null \
            || compgen -G "/home/${u}/logs/php-fpm-*.log" >/dev/null || continue
        if [[ "$u" =~ ^[a-z][a-z0-9]{2,31}$ ]] && id "$u" &>/dev/null \
            && app_logrotate_rule "$u" && [[ -f "${d}/cipi-home-${u}" ]]; then
            n=$((n + 1))
        else
            other="${other} /home/${u}"
        fi
    done
    echo "  logrotate: ${n} app(s) rotate their own logs as the app user (${d}/cipi-home-<app>)"
    if [[ -n "$failed" ]]; then
        echo "  WARNING: no logrotate rule written for:${failed} — their Laravel and PHP-FPM logs are not rotated; retry with: cipi app fix-permissions"
    fi
    if [[ -n "$other" ]]; then
        echo "  NOTE: not an app's home, so no longer rotated by Cipi:${other} — add a logrotate rule of your own if those logs matter"
    fi
    return 0
}

# What logrotate itself makes of Cipi's rules: a dry run (-d changes nothing,
# not even its state file) of the cipi-* files. Prints its "error:" lines and
# returns 1 when there are any; silent and 0 otherwise, or without logrotate.
logrotate_cipi_check() {
    local d="${CIPI_LOGROTATE_D:-/etc/logrotate.d}" out
    command -v logrotate &>/dev/null || return 0
    compgen -G "${d}/cipi-*" >/dev/null || return 0
    out=$(logrotate -d "${d}"/cipi-* 2>&1 || true)
    out=$(grep -E '^error: ' <<< "$out" | sort -u | head -n 10 || true)
    [[ -z "$out" ]] && return 0
    printf '%s\n' "$out"
    return 1
}

# Ubuntu's /var/log is root:syslog 0775 wherever rsyslog is installed, and
# logrotate (as root) refuses a log whose directory a group other than root
# can write unless the rule says who to rotate as: "su". /etc/logrotate.conf
# says it for every rule it includes (su root adm), so the nightly run
# rotated Cipi's logs in /var/log all along — but a rule read on its own has
# no such line, and `logrotate -d /etc/logrotate.d/cipi-*`, which is what
# logrotate_cipi_check and `cipi pending` run, called every one of them
# skipped: auth.log, fail2ban.log, ufw.log, the panel's logs (5.17.0).
#
# Cipi's shared rules say it themselves from now on. This adds
# "su root adm" — what Ubuntu's own configuration gives them — to every block
# of a cipi-* rule file that names a log directly in /var/log and has no su
# line of its own; a server whose logrotate.conf lost its su line gets those
# logs rotated for real. The per-app rules (cipi-home-<app>) already rotate
# as the app user and are not read. Prints the files it changed, one per
# line; a file it cannot write is left as it is.
logrotate_cipi_su() {
    local d="${CIPI_LOGROTATE_D:-/etc/logrotate.d}" grp=adm f tmp
    [[ -d "$d" ]] || return 0
    getent group adm >/dev/null 2>&1 || grp=root
    for f in "$d"/cipi-*; do
        [[ -f "$f" && ! -L "$f" ]] || continue
        [[ "${f##*/}" == cipi-home-* ]] && continue
        tmp=$(mktemp) || return 1
        if ! awk -v grp="$grp" '
            function flush(   i) {
                for (i = 1; i <= n; i++) {
                    print buf[i]
                    if (direct && !has_su && i == open_at) print "    su root " grp
                }
                n = 0; direct = 0; has_su = 0; open_at = 0; inblock = 0; inscript = 0
            }
            {
                buf[++n] = $0
                line = $0; sub(/^[ \t]+/, "", line); sub(/[ \t\r]+$/, "", line)
                if (!inblock) {
                    if (line == "" || line ~ /^#/) next
                    brace = (line ~ /\{$/)
                    if (brace) sub(/[ \t]*\{$/, "", line)
                    m = split(line, part, /[ \t]+/)
                    for (j = 1; j <= m; j++) {
                        p = part[j]; gsub(/["\047]/, "", p)
                        if (p ~ /^\/var\/log\/[^\/]+$/) direct = 1
                    }
                    if (brace) { inblock = 1; open_at = n }
                    next
                }
                if (inscript) { if (line == "endscript") inscript = 0; next }
                if (line ~ /^(prerotate|postrotate|firstaction|lastaction|preremove)([ \t]|$)/) { inscript = 1; next }
                if (line ~ /^su([ \t]|$)/) has_su = 1
                if (line == "}") flush()
            }
            END { flush() }' "$f" > "$tmp" 2>/dev/null; then
            rm -f "$tmp"; continue
        fi
        if [[ ! -s "$tmp" ]] || cmp -s "$tmp" "$f"; then
            rm -f "$tmp"; continue
        fi
        # root:root 0644 — logrotate ignores a rule file with any other owner
        # or a mode that lets someone else write it.
        if install -m 644 -o root -g root "$tmp" "$f" 2>/dev/null; then
            echo "${f##*/}"
        fi
        rm -f "$tmp"
    done
    return 0
}

# Laravel apps log to one file, storage/logs/laravel.log, which logrotate
# (cipi-app-logs) rotates, compresses and expires. With the `daily` channel
# Laravel named a file per day and logrotate then rotated each of those once:
# laravel-<date>.log.1 kept the content for good, uncompressed, next to an empty
# laravel-<date>.log — the file `cipi app logs` and the panel then showed.
#
# Points an .env at `single`: LOG_CHANNEL=daily, and the `daily` member of
# LOG_STACK. Any other channel is left as it is. Returns 0 when it was changed,
# 1 when it was not.
#
# The .env is never truncated in place: a write that fails half-way (a full
# disk) would leave the app without its keys. The new content goes into a copy
# next to it (same owner and mode), which then replaces it in one rename; if
# anything fails the .env is left exactly as it was.
#
# On an app's .env call laravel_app_env_single_log, which runs this as the app
# user.
laravel_env_single_log() {
    local envf="${1:-}"
    [[ -f "$envf" ]] || return 1
    # A linked .env stays a link: the file it points at is the one replaced.
    if [[ -L "$envf" ]]; then
        envf=$(readlink -f "$envf" 2>/dev/null) || return 1
        [[ -f "$envf" ]] || return 1
    fi
    local tmp new line val p out changed=1
    local -a parts
    tmp=$(mktemp) || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            LOG_CHANNEL=*|LOG_STACK=*)
                val="${line#*=}"; val="${val%%#*}"
                val=$(printf '%s' "$val" | tr -d "\"'[:space:]")
                case ",${val}," in
                    *,daily,*)
                        out=""
                        IFS=',' read -ra parts <<< "$val"
                        for p in "${parts[@]}"; do
                            [[ "$p" == "daily" ]] && p="single"
                            case ",${out}," in *",${p},"*) continue ;; esac
                            out="${out:+${out},}${p}"
                        done
                        line="${line%%=*}=${out}"
                        changed=0
                        ;;
                esac
                ;;
        esac
        printf '%s\n' "$line" >> "$tmp"
    done < "$envf"
    if [[ $changed -eq 0 ]]; then
        if new=$(mktemp "${envf}.XXXXXX" 2>/dev/null) && [[ -n "$new" ]]; then
            if cp -p "$envf" "$new" 2>/dev/null && cat "$tmp" > "$new" 2>/dev/null \
               && mv -f "$new" "$envf" 2>/dev/null; then
                :
            else
                rm -f "$new"
                changed=1
            fi
        else
            changed=1
        fi
    fi
    rm -f "$tmp"
    return $changed
}

# laravel_app_env_single_log <app> — the same on an app's shared/.env, as the
# app user. Root does not write in a directory an app controls: a link planted
# there would aim the write at any file on the server.
laravel_app_env_single_log() {
    local app="${1:-}"
    [[ -z "$app" || "$app" == "cipi" ]] && return 1
    local envf="/home/${app}/shared/.env"
    [[ -f "$envf" ]] || return 1
    id "$app" &>/dev/null || return 1
    (cd / && sudo -u "$app" bash -c "$(declare -f laravel_env_single_log); laravel_env_single_log \"\$1\"" _ "$envf")
}

# Folds what the `daily` channel and logrotate left in a Laravel logs directory
# into laravel.log, oldest first: laravel-<date>.log, its rotations (.log.N,
# .log.N.gz) and the empty stubs. A piece is removed only once its content is in
# laravel.log; one that cannot be read stays where it is, and so do the file
# names given after the directory (files a process still has open). Prints how
# many files were folded in. Called through laravel_logs_unify, as the app user.
_laravel_logs_unify_dir() {
    local dir="${1:-}"
    [[ -n "$dir" && -d "$dir" ]] || { echo 0; return 0; }
    shift
    local target="${dir}/laravel.log" tmp="${dir}/.laravel-unify.$$"
    local re='^laravel-([0-9]{4}-[0-9]{2}-[0-9]{2})\.log(\.([0-9]+))?(\.gz)?$'
    local f name n list="" merged="" count=0 keep=" $* "
    for f in "$dir"/laravel-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].log*; do
        [[ -f "$f" ]] || continue
        name="${f##*/}"
        [[ "$name" =~ $re ]] || continue
        [[ "$keep" == *" ${name} "* ]] && continue
        # Higher rotation numbers are older: they sort first within their day.
        n="${BASH_REMATCH[3]:-0}"
        list+="${BASH_REMATCH[1]} $(printf '%09d' $((999999999 - 10#$n))) ${name}"$'\n'
    done
    [[ -n "$list" ]] || { echo 0; return 0; }

    : > "$tmp" || return 1
    while read -r _ _ name; do
        [[ -n "$name" ]] || continue
        f="${dir}/${name}"
        if [[ -s "$f" ]]; then
            if [[ "$name" == *.gz ]]; then
                gzip -t "$f" 2>/dev/null || continue
                gzip -dc "$f" >> "$tmp" || { rm -f "$tmp"; return 1; }
            else
                [[ -r "$f" ]] || continue
                cat "$f" >> "$tmp" || { rm -f "$tmp"; return 1; }
            fi
            # The next piece starts on a line of its own.
            if [[ -s "$tmp" && -n "$(tail -c1 "$tmp")" ]]; then echo >> "$tmp"; fi
        fi
        merged+="${name}"$'\n'
    done <<< "$(printf '%s' "$list" | sort)"

    if [[ -s "$tmp" ]]; then
        # ln refuses an existing target, so laravel.log either appears whole or,
        # when the app already writes one, gets the history appended.
        if ! ln "$tmp" "$target" 2>/dev/null; then
            cat "$tmp" >> "$target" || { rm -f "$tmp"; return 1; }
        fi
        chmod 664 "$target" 2>/dev/null || true
    fi
    rm -f "$tmp"
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        rm -f "${dir}/${name}" && count=$((count + 1))
    done <<< "$merged"
    echo "$count"
}

# laravel_logs_unify <app> [file-name-to-leave…]
# Runs as the app user, never as root: the app can write in that directory, and
# root must not follow a link planted there.
laravel_logs_unify() {
    local app="${1:-}"
    [[ -z "$app" || "$app" == "cipi" ]] && return 0
    shift
    local dir="/home/${app}/shared/storage/logs"
    [[ -d "$dir" ]] || return 0
    id "$app" &>/dev/null || return 0
    # cd /: root's working directory may be one the app user cannot read.
    (cd / && sudo -u "$app" bash -c "$(declare -f _laravel_logs_unify_dir); _laravel_logs_unify_dir \"\$@\"" _ "$dir" "$@")
}

# A new app user follows the last `cipi ssh apps enable|disable --all`: after a
# disable --all it starts without SSH/SFTP access from outside (group cipi-nossh).
app_ssh_apply_default() {
    local user="${1:-}"
    [[ -n "$user" ]] || return 0
    local d
    d=$(vault_read server.json 2>/dev/null | jq -r '.app_ssh_default // "enabled"' 2>/dev/null || true)
    [[ "$d" == "disabled" ]] || return 0
    getent group cipi-nossh >/dev/null 2>&1 || return 0
    usermod -aG cipi-nossh "$user" 2>/dev/null || true
}

# Restore the permission model `cipi app create` left behind. Do NOT chown -R
# the whole home as app:app with a plain chown: a 700 home would lock www-data
# out of the docroot (www-data is in the app group so 750 is enough).
#
# Root, in a directory the app user owns: every chown is -h (the name, never
# what a symlink of that name points at) and every chmod is done as the app
# user, who owns what the chowns just gave back. Before 5.9.0 these were
# plain chown and chmod as root, which follow a symlink: `x.pub ->
# /etc/shadow` in ~/.ssh made shadow 644, `shared/storage -> /etc` gave /etc
# to the app (chown -R alone is harmless there: it changes the link).
ensure_app_permissions() {
    local app="${1:-}"
    [[ -z "$app" || "$app" == "cipi" ]] && return 0
    local home="/home/${app}"
    [[ -d "$home" ]] || return 0
    id "$app" &>/dev/null || return 0

    chown "${app}:${app}" "$home" 2>/dev/null || true
    chmod 750 "$home"

    # Own everything, logs/ included. -h: do not follow `current` → a release,
    # nor any other symlink. chown -R walks the tree through directory
    # descriptors, so a directory swapped for a symlink while it runs is not
    # followed either (find … -exec chown passed whole paths, which are
    # resolved again at each call).
    chown -h -R "${app}:${app}" "$home" 2>/dev/null || true

    _app_as "$app" '
        home="$1"
        if [[ -d "${home}/.ssh" && ! -L "${home}/.ssh" ]]; then
            chmod 700 "${home}/.ssh"
            for f in authorized_keys id_ed25519 id_rsa known_hosts config; do
                [[ -f "${home}/.ssh/${f}" && ! -L "${home}/.ssh/${f}" ]] && chmod 600 "${home}/.ssh/${f}"
            done
            for f in "${home}/.ssh/"*.pub; do
                [[ -f "$f" && ! -L "$f" ]] && chmod 644 "$f"
            done
        fi
        [[ -f "${home}/shared/.env" && ! -L "${home}/shared/.env" ]] && chmod 640 "${home}/shared/.env"
        [[ -f "${home}/shared/auth.json" && ! -L "${home}/shared/auth.json" ]] && chmod 640 "${home}/shared/auth.json"
        [[ -f "${home}/shared/cipi-databases.env" && ! -L "${home}/shared/cipi-databases.env" ]] && chmod 600 "${home}/shared/cipi-databases.env"
        for d in \
            shared/storage \
            shared/storage/app \
            shared/storage/app/public \
            shared/storage/framework \
            shared/storage/framework/cache \
            shared/storage/framework/cache/data \
            shared/storage/framework/sessions \
            shared/storage/framework/views \
            shared/storage/logs
        do
            [[ -d "${home}/${d}" && ! -L "${home}/${d}" ]] && chmod 775 "${home}/${d}"
        done
        if [[ -d "${home}/releases" && ! -L "${home}/releases" ]]; then
            find "${home}/releases" -type d -path "*/bootstrap/cache" -exec chmod 775 {} \;
        fi
        if [[ -d "${home}/.deployer" && ! -L "${home}/.deployer" ]]; then
            find "${home}/.deployer" -maxdepth 1 -type f -name "*.sh" -exec chmod 755 {} \;
        fi
        exit 0' "$home"

    ensure_app_logs_permissions "$app"
}

# A supervisor program logs to /var/log/cipi-apps/<app>/<name> (supervisord
# opens the file as root: see app_log_dir). The directory must exist before
# supervisord reads the program, and ~/logs/<name> points at the log.
_supervisor_log_ready() {   # <app> <log file name>
    app_log_dir_ensure "$1" || warn "Could not create $(app_log_dir "$1") — '${1}' programs will not start until it exists (cipi app fix-permissions ${1})"
    app_log_links "$1" "$2"
}

_create_supervisor_worker() {
    local app="$1" v="$2" queue="${3:-default}" procs="${4:-}" tries="${5:-3}" timeout="${6:-3600}"
    [[ -z "$procs" ]] && procs=$(_app_limit "$app" worker_procs 1 20)
    _supervisor_log_ready "$app" "worker-${queue}.log"
    cat >> "/etc/supervisor/conf.d/${app}.conf" <<EOF
[program:${app}-worker-${queue}]
process_name=%(program_name)s_%(process_num)02d
command=/usr/bin/php${v} /home/${app}/current/artisan queue:work database --sleep=3 --tries=${tries} --max-time=${timeout} --queue=${queue}
autostart=true
autorestart=true
startretries=5
startsecs=3
stopasgroup=true
killasgroup=true
user=${app}
numprocs=${procs}
redirect_stderr=true
stdout_logfile=/var/log/cipi-apps/${app}/worker-${queue}.log
stdout_logfile_maxbytes=10MB
stopwaitsecs=${timeout}
EOF
}

# Normalize --octane / --octane=frankenphp → "frankenphp" or "".
# Returns 0 and prints value; returns 1 on unsupported server.
_normalize_octane_arg() {
    local v="${1:-}"
    case "$v" in
        ""|false|0|no|off) echo ""; return 0 ;;
        true|1|yes|on|frankenphp) echo "frankenphp"; return 0 ;;
        *) return 1 ;;
    esac
}

# Allocate a free localhost port in [lo, hi], skipping ports listed by jq_expr on apps.json.
_allocate_localhost_port() {
    local lo="$1" hi="$2" jq_expr="$3"
    local used p
    used=$(vault_read apps.json 2>/dev/null | jq -r "$jq_expr" 2>/dev/null || true)
    for p in $(seq "$lo" "$hi"); do
        if echo "$used" | grep -qx "$p"; then
            continue
        fi
        if command -v ss &>/dev/null; then
            if ss -ltn 2>/dev/null | grep -qE ":${p}\\s"; then
                continue
            fi
        elif command -v lsof &>/dev/null; then
            if lsof -iTCP:"$p" -sTCP:LISTEN &>/dev/null; then
                continue
            fi
        fi
        echo "$p"
        return 0
    done
    return 1
}

# Allocate a free localhost port for Octane (8100–8999).
_octane_allocate_port() {
    _allocate_localhost_port 8100 8999 '.[].octane_port // empty'
}

# Allocate a free localhost port for Reverb (9000–9099).
_reverb_allocate_port() {
    _allocate_localhost_port 9000 9099 '.[].reverb_port // empty'
}

# Supervisor program for Laravel Octane (FrankenPHP). Same conf file as queue workers
# so cipi-worker restart covers Octane on deploy.
#
# PHP_INI_SCAN_DIR: the compiled-in directory (leading ':'), the hardening
# every Octane app loads, then the app's own directory (cipi app jit).
# PATH starts with the live release: Octane looks for `frankenphp` on PATH
# before it looks in the project, so a frankenphp installed on the system
# would otherwise win over the build Cipi pinned (lib/frankenphp.sh).
_create_supervisor_octane() {
    local app="$1" v="$2" port="$3"
    local workers
    workers=$(_app_limit "$app" octane_workers 2 16)
    octane_php_ini_ensure || warn "Could not write ${OCTANE_INI_DIR} — '${app}' runs Octane without the PHP hardening"
    jit_octane_ini_sync "$app" || warn "Could not write ${OCTANE_APP_INI_ROOT}/${app} — '${app}' runs Octane without its JIT setting"
    _supervisor_log_ready "$app" octane.log
    cat >> "/etc/supervisor/conf.d/${app}.conf" <<EOF
[program:${app}-octane]
process_name=%(program_name)s
command=/usr/bin/php${v} /home/${app}/current/artisan octane:start --server=frankenphp --host=127.0.0.1 --port=${port} --workers=${workers} --max-requests=500
environment=PHP_INI_SCAN_DIR=":${OCTANE_INI_DIR}:${OCTANE_APP_INI_ROOT}/${app}",PATH="/home/${app}/current:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
autostart=true
autorestart=true
startretries=10
startsecs=3
stopasgroup=true
killasgroup=true
user=${app}
numprocs=1
redirect_stderr=true
stdout_logfile=/var/log/cipi-apps/${app}/octane.log
stdout_logfile_maxbytes=10MB
stopwaitsecs=3600
EOF
}

# Supervisor program for Laravel Reverb (WebSockets).
_create_supervisor_reverb() {
    local app="$1" v="$2" port="$3"
    _supervisor_log_ready "$app" reverb.log
    cat >> "/etc/supervisor/conf.d/${app}.conf" <<EOF
[program:${app}-reverb]
process_name=%(program_name)s
command=/usr/bin/php${v} /home/${app}/current/artisan reverb:start --host=127.0.0.1 --port=${port}
autostart=true
autorestart=true
startretries=10
startsecs=3
stopasgroup=true
killasgroup=true
user=${app}
numprocs=1
redirect_stderr=true
stdout_logfile=/var/log/cipi-apps/${app}/reverb.log
stdout_logfile_maxbytes=10MB
stopwaitsecs=3600
EOF
}

# Supervisor program for Laravel Horizon (mutually exclusive with queue:work workers).
_create_supervisor_horizon() {
    local app="$1" v="$2"
    _supervisor_log_ready "$app" horizon.log
    cat >> "/etc/supervisor/conf.d/${app}.conf" <<EOF
[program:${app}-horizon]
process_name=%(program_name)s
command=/usr/bin/php${v} /home/${app}/current/artisan horizon
autostart=true
autorestart=true
startretries=10
startsecs=3
stopasgroup=true
killasgroup=true
user=${app}
numprocs=1
redirect_stderr=true
stdout_logfile=/var/log/cipi-apps/${app}/horizon.log
stdout_logfile_maxbytes=10MB
stopwaitsecs=3600
EOF
}

# Ensure map $http_upgrade $connection_upgrade exists (needed for Octane proxy).
# Prefer conf.d snippet on existing servers so we never patch nginx.conf with sed.
_ensure_nginx_octane_map() {
    local snippet="/etc/nginx/conf.d/cipi-octane-map.conf"
    if grep -qE 'map\s+\$http_upgrade\s+\$connection_upgrade' /etc/nginx/nginx.conf 2>/dev/null; then
        # Avoid duplicate map when the main template already defines it
        rm -f "$snippet" 2>/dev/null || true
        return 0
    fi
    if [[ -f "$snippet" ]] && grep -qE 'map\s+\$http_upgrade\s+\$connection_upgrade' "$snippet" 2>/dev/null; then
        return 0
    fi
    mkdir -p /etc/nginx/conf.d 2>/dev/null || true
    cat > "$snippet" <<'EOF'
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
EOF
}

# ── WEBSOCKET CAPACITY ────────────────────────────────────────
# A WebSocket is not a request: it stays open. Every connected client costs one
# file descriptor inside Reverb and two connections inside nginx (browser side
# and upstream side). The stock limits are sized for short HTTP requests, so a
# Reverb app hits a wall long before it runs out of CPU or RAM:
#
#   supervisor  children inherit supervisord's RLIMIT_NOFILE, and systemd's
#               default soft limit is 1024 — Reverb starts refusing clients at
#               roughly a thousand, with nothing in the logs to explain it.
#   nginx       workers inherit the same 1024 unless worker_rlimit_nofile
#               raises it, and worker_connections caps the pairs on top.
#
# Both helpers are idempotent and are called when Reverb is enabled, from the
# installer, and from the migration — never on every command.
CIPI_WS_NOFILE=65535
CIPI_WS_WORKER_CONNECTIONS=8192

# Is the *running* supervisord already using the raised limit? A drop-in only
# applies to the next start, so this is what decides whether the admin still
# has to restart supervisor.
_supervisor_fd_limit_active() {
    local pid soft
    pid=$(systemctl show supervisor.service -p MainPID --value 2>/dev/null || true)
    # Not running: whatever starts it next reads the drop-in.
    [[ -n "$pid" && "$pid" != "0" && -r "/proc/${pid}/limits" ]] || return 0
    soft=$(awk '/^Max open files/{print $4}' "/proc/${pid}/limits" 2>/dev/null || true)
    [[ "$soft" == "unlimited" ]] && return 0
    [[ "$soft" =~ ^[0-9]+$ ]] || return 0
    (( soft >= CIPI_WS_NOFILE ))
}

# Raise RLIMIT_NOFILE for supervisord, and therefore for every program it runs.
# A systemd drop-in rather than supervisord's own `minfds`: minfds makes
# supervisord *refuse to start* when the limit cannot be reached, and a
# supervisor that will not come up takes every queue worker on the box with it.
#
# Returns 0 when the running supervisord already has the headroom, 1 when the
# drop-in is in place but supervisor still has to be restarted for it to apply.
_ensure_supervisor_fd_limit() {
    systemctl cat supervisor.service &>/dev/null || return 0
    local dir="/etc/systemd/system/supervisor.service.d"
    local drop="${dir}/cipi-nofile.conf"
    if ! grep -q "^LimitNOFILE=${CIPI_WS_NOFILE}$" "$drop" 2>/dev/null; then
        mkdir -p "$dir" 2>/dev/null || return 0
        cat > "$drop" <<EOF
# Managed by Cipi — file-descriptor headroom for long-lived connections.
# One descriptor per open WebSocket; supervisord's children inherit this.
[Service]
LimitNOFILE=${CIPI_WS_NOFILE}
EOF
        systemctl daemon-reload 2>/dev/null || true
    fi
    _supervisor_fd_limit_active
}

# Give nginx workers the same headroom. `worker_rlimit_nofile` is a main-context
# directive, so unlike the octane map it cannot live in a conf.d snippet — that
# include sits inside `http`. nginx.conf itself has to be edited, so the file is
# rewritten through a temp copy, tested, and rolled back if `nginx -t` fails.
#
# Exit status: 0 nothing needed doing, 2 the file was changed and passes
# `nginx -t`, 1 the change was attempted and rolled back. 2 rather than 0 so a
# caller knows to reload — new limits only reach the workers a reload spawns.
_ensure_nginx_ws_limits() {
    local conf="/etc/nginx/nginx.conf"
    [[ -f "$conf" ]] || return 0
    command -v nginx &>/dev/null || return 0

    local has_rlimit=false cur_conns=0
    grep -qE '^[[:space:]]*worker_rlimit_nofile[[:space:]]' "$conf" && has_rlimit=true
    cur_conns=$(grep -oE '^[[:space:]]*worker_connections[[:space:]]+[0-9]+' "$conf" 2>/dev/null \
        | grep -oE '[0-9]+' | head -1)
    [[ "$cur_conns" =~ ^[0-9]+$ ]] || cur_conns=0

    local need_conns=false
    (( cur_conns < CIPI_WS_WORKER_CONNECTIONS )) && need_conns=true
    [[ "$has_rlimit" == false || "$need_conns" == true ]] || return 0

    local tmp; tmp=$(mktemp) || return 0
    awk -v nofile="$CIPI_WS_NOFILE" \
        -v conns="$CIPI_WS_WORKER_CONNECTIONS" \
        -v add_rlimit="$([[ "$has_rlimit" == false ]] && echo 1 || echo 0)" \
        -v add_conns="$([[ "$need_conns" == true ]] && echo 1 || echo 0)" '
        add_rlimit && !placed && /^[[:space:]]*worker_processes[[:space:]]/ {
            print; print "worker_rlimit_nofile " nofile ";"; placed = 1; next
        }
        add_conns && /^[[:space:]]*worker_connections[[:space:]]+[0-9]+[[:space:]]*;/ {
            match($0, /^[[:space:]]*/)
            print substr($0, 1, RLENGTH) "worker_connections " conns ";"; next
        }
        { print }
    ' "$conf" > "$tmp" 2>/dev/null

    # A truncated or unreadable rewrite must never reach nginx.conf.
    if [[ ! -s "$tmp" ]] || ! grep -q 'worker_processes' "$tmp"; then
        rm -f "$tmp"; return 1
    fi

    local backup; backup=$(mktemp)
    cp "$conf" "$backup" 2>/dev/null || { rm -f "$tmp" "$backup"; return 1; }
    cat "$tmp" > "$conf" 2>/dev/null || { cat "$backup" > "$conf"; rm -f "$tmp" "$backup"; return 1; }
    rm -f "$tmp"
    if nginx -t &>/dev/null; then
        rm -f "$backup"
        return 2
    fi
    cat "$backup" > "$conf"
    rm -f "$backup"
    return 1
}

# Init config on source — do not chmod /etc/cipi here: setup.sh sets permissions once.
# chmod on every `cipi` source breaks read-only / (db list, deploy status, …).
mkdir -p "${CIPI_CONFIG}" "${CIPI_LOG}" 2>/dev/null || true
vault_init
if _cipi_config_writable 2>/dev/null; then
    for f in apps.json databases.json; do
        if [[ ! -f "${CIPI_CONFIG}/$f" ]]; then
            echo "{}" | vault_write "$f" 2>/dev/null || true
        fi
    done
    ensure_apps_json_api_access
fi

# The time of a notification. lib/notifications.sh, when it is there, defines
# the one that follows `cipi notification timezone`.
notify_now() { date "$@" '+%Y-%m-%d %H:%M:%S %Z'; }

# Email notifications (optional) — cipi_notify "Subject" "Body" [trigger_id]
[[ -f "${CIPI_LIB}/notifications.sh" ]] && source "${CIPI_LIB}/notifications.sh"
[[ -f "${CIPI_LIB}/alerts.sh" ]] && source "${CIPI_LIB}/alerts.sh"
[[ -f "${CIPI_LIB}/smtp.sh" ]] && source "${CIPI_LIB}/smtp.sh"

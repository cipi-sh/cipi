#!/bin/bash
#############################################
# Cipi — link the app's pinned FrankenPHP build into a new release
#
# Run by Deployer (task cipi:frankenphp of the Octane recipe), as the app
# user, after the vendors are installed and before the release goes live:
#
#   <release>/frankenphp → /opt/cipi-frankenphp/apps/<app>/frankenphp
#
# Octane then finds a binary and does not download one. The pin is Cipi's
# (cipi frankenphp use|upgrade); this only follows it. Without a pin nothing
# is linked and Octane downloads the latest release when it starts, as it did
# before Cipi 5.10.0 — Cipi pins that binary after the deploy.
#
# The deploy stops here, with the live release untouched, when the release's
# laravel/octane asks for a newer FrankenPHP than the pinned one: Octane would
# otherwise replace the binary with the latest download when it starts,
# whatever PHP that carries.
#
# Usage: cipi-frankenphp-link <release path>
#############################################
set -euo pipefail

ROOT="${FRANKENPHP_ROOT:-/opt/cipi-frankenphp}"
REL="${1:-}"
APP=$(id -un)

[[ "$APP" =~ ^[a-z][a-z0-9]{2,31}$ ]] || { echo "cipi-frankenphp-link: run as the app user" >&2; exit 2; }
[[ -n "$REL" && -d "$REL" ]] || { echo "cipi-frankenphp-link: no release directory" >&2; exit 2; }
case "$(cd "$REL" && pwd -P)" in
    "$(cd "/home/${APP}" 2>/dev/null && pwd -P)/releases/"*) ;;
    *) echo "cipi-frankenphp-link: ${REL} is not a release of ${APP}" >&2; exit 2 ;;
esac

PIN="${ROOT}/apps/${APP}"
if [[ ! -x "${PIN}/frankenphp" ]]; then
    echo "FrankenPHP: no build pinned for ${APP} — Octane downloads the latest release when it starts; Cipi pins it after the deploy (or now: cipi frankenphp upgrade ${APP})"
    exit 0
fi

HAVE=$(sed -n 's/^frankenphp=//p' "${PIN}/meta" 2>/dev/null | head -n 1 || true)
PHPV=$(sed -n 's/^php=//p' "${PIN}/meta" 2>/dev/null | head -n 1 || true)

REQ=""
DEP="${REL}/vendor/laravel/octane/src/Commands/Concerns/InstallsFrankenPhpDependencies.php"
if [[ -f "$DEP" ]]; then
    REQ=$(grep -oE "requiredFrankenPhpVersion[[:space:]]*=[[:space:]]*'[0-9]+\.[0-9]+\.[0-9]+'" "$DEP" \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true)
fi
if [[ -n "$REQ" && "$HAVE" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
   && [[ "$(printf '%s\n%s\n' "$REQ" "$HAVE" | sort -V | head -n 1)" != "$REQ" ]]; then
    echo "FrankenPHP: this release's laravel/octane needs FrankenPHP ${REQ} or newer, and ${APP} is pinned to ${HAVE} (PHP ${PHPV})." >&2
    echo "Octane would replace it at start with the latest download, whatever PHP that carries. The live release stays." >&2
    echo "Run: cipi frankenphp upgrade ${APP}   (or: cipi frankenphp use ${APP} <build>), then deploy again." >&2
    exit 1
fi

ln -sfn "${PIN}/frankenphp" "${REL}/frankenphp"
echo "FrankenPHP ${HAVE} (PHP ${PHPV}) linked into the release"

#!/bin/bash
#############################################
# Cipi — Node SSR process launcher (app user, from Supervisor)
#
# Supervisor starts one of these per slot (blue/green) with the release as its
# working directory and PORT, HOST, NODE_ENV, PATH and CIPI_NODE_START in the
# environment (written by cipi-node-switch, root).
#
# .env is read as data, never sourced: KEY=VALUE lines only, surrounding quotes
# stripped, no expansion, and nothing may override PORT/HOST — the slot's port
# is what nginx proxies to. The start command runs as an argv array, not
# through a shell.
#
# Usage: cipi-node-run <app>
#############################################
set -uo pipefail

APP="${1:-}"
[[ "$APP" =~ ^[a-z][a-z0-9]{2,31}$ ]] || { echo "cipi-node-run: invalid app name" >&2; exit 2; }
if [[ "$(id -un)" != "$APP" ]]; then
    echo "cipi-node-run: must run as '${APP}'" >&2
    exit 2
fi
[[ -n "${PORT:-}" && -n "${CIPI_NODE_START:-}" ]] || { echo "cipi-node-run: PORT and CIPI_NODE_START are required" >&2; exit 2; }
case "$PWD" in
    "/home/${APP}/releases/"*) ;;
    *) echo "cipi-node-run: working directory ${PWD} is not a release of ${APP}" >&2; exit 2 ;;
esac

if [[ -f .env ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$ ]] || continue
        key="${BASH_REMATCH[2]}"; val="${BASH_REMATCH[3]}"
        case "$key" in PORT|HOST|HOSTNAME|NITRO_PORT|NITRO_HOST|CIPI_NODE_START|PATH) continue ;; esac
        val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
        if [[ "$val" =~ ^\"(.*)\"$ ]]; then
            val="${BASH_REMATCH[1]}"; val="${val//\\n/$'\n'}"; val="${val//\\\"/\"}"
        elif [[ "$val" =~ ^\'(.*)\'$ ]]; then
            val="${BASH_REMATCH[1]}"
        else
            val="${val%%[[:space:]]#*}"
        fi
        export "${key}=${val}"
    done < .env
fi

# Frameworks disagree on the variable name; all of them get the slot's address.
export HOST=127.0.0.1 HOSTNAME=127.0.0.1 NITRO_HOST=127.0.0.1 NITRO_PORT="$PORT"
export NODE_ENV="${NODE_ENV:-production}"

read -r -a argv <<< "$CIPI_NODE_START"
exec "${argv[@]}"

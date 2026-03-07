#!/bin/bash
#############################################
# Cipi Migration 4.1.2
# - Supervisor: autorestart=unexpected, startretries, startsecs
# - Sudoers: allow cipi-worker stop
# - Deployer: workers:stop before deploy:symlink
#############################################

set -e

CIPI_CONFIG="${CIPI_CONFIG:-/etc/cipi}"
CIPI_LIB="${CIPI_LIB:-/opt/cipi/lib}"

# ── 1. Patch Supervisor configs ──────────────────────────────

echo "Updating Supervisor worker configs..."

for conf in /etc/supervisor/conf.d/*.conf; do
    [[ ! -f "$conf" ]] && continue
    changed=false

    if grep -q 'autorestart=true' "$conf" 2>/dev/null; then
        sed -i 's/autorestart=true/autorestart=unexpected/' "$conf"
        changed=true
    fi

    if ! grep -q 'startretries=' "$conf" 2>/dev/null; then
        sed -i '/^autorestart=/a startretries=5' "$conf"
        changed=true
    fi

    if ! grep -q 'startsecs=' "$conf" 2>/dev/null; then
        sed -i '/^startretries=/a startsecs=3' "$conf"
        changed=true
    fi

    if $changed; then
        echo "  Patched: $(basename "$conf")"
    fi
done

supervisorctl reread 2>/dev/null || true
supervisorctl update 2>/dev/null || true
echo "Supervisor configs updated"

# ── 2. Patch sudoers ─────────────────────────────────────────

echo "Updating sudoers for cipi-worker stop..."

for sf in /etc/sudoers.d/cipi-*; do
    [[ ! -f "$sf" ]] && continue
    [[ "$(basename "$sf")" == "cipi-api" ]] && continue

    if grep -q 'cipi-worker restart' "$sf" && ! grep -q 'cipi-worker stop' "$sf"; then
        app=$(grep -oP '(?<=cipi-worker restart )\S+' "$sf" | head -1)
        [[ -z "$app" ]] && continue
        sed -i "/cipi-worker restart ${app}/a ${app} ALL=(root) NOPASSWD: /usr/local/bin/cipi-worker stop ${app}" "$sf"
        echo "  Patched: $(basename "$sf") (added stop for ${app})"
    fi
done

echo "Sudoers updated"

# ── 3. Patch existing deploy.php files ───────────────────────

echo "Updating Deployer configs (workers:stop before symlink)..."

for dp in /home/*/.deployer/deploy.php; do
    [[ ! -f "$dp" ]] && continue
    app=$(basename "$(dirname "$(dirname "$dp")")")

    if grep -q "workers:restart" "$dp" && ! grep -q "workers:stop" "$dp"; then
        sed -i "/before('deploy:symlink', 'workers:stop');/d" "$dp"

        sed -i "s|before('deploy:symlink', 'artisan:queue:restart');|before('deploy:symlink', 'workers:stop');\nbefore('deploy:symlink', 'artisan:queue:restart');|" "$dp" 2>/dev/null

        if ! grep -q "workers:stop" "$dp"; then
            sed -i "s|after('deploy:symlink', 'artisan:queue:restart');|before('deploy:symlink', 'workers:stop');\nafter('deploy:symlink', 'artisan:queue:restart');|" "$dp"
        fi

        if ! grep -q "task('workers:stop'" "$dp"; then
            sed -i "/task('workers:restart'/i\\
task('workers:stop', function () {\\
    run('sudo /usr/local/bin/cipi-worker stop ${app}');\\
});\\
" "$dp"
        fi

        chown "${app}:${app}" "$dp"
        echo "  Patched: ${app}/deploy.php"
    else
        echo "  Already up to date: ${app}/deploy.php"
    fi
done

echo "Deployer configs updated"
echo "Migration 4.1.2 complete"

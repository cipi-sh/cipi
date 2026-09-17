<?php
namespace Deployer;
require 'recipe/common.php';

// Node frontend app (cipi app create --node=spa|static|ssr): releases, shared .env,
// dependency install from the lockfile, build, then
//   spa/static — nginx serves the build output from `current`;
//   ssr        — cipi-node-switch starts the release on the idle blue/green slot
//                and moves nginx to it before `current` changes.

set('application', '__CIPI_APP_USER__');
set('repository', '__CIPI_REPOSITORY__');
set('branch', '__CIPI_BRANCH__');
set('deploy_path', '__CIPI_DEPLOY_PATH__');
set('keep_releases', __CIPI_KEEP_RELEASES__);
set('git_ssh_command', 'ssh -i __CIPI_DEPLOY_PATH__/.ssh/id_ed25519 -o StrictHostKeyChecking=accept-new');
set('bin/php', '/usr/bin/php__CIPI_PHP_VERSION__');
set('shared_files', ['.env']);
set('shared_dirs', []);
set('writable_dirs', []);

// Values as of when this recipe was written; node:config replaces them with
// ~/.deployer/node.json, which a cipi.yml `node:` section in the release being
// deployed may just have changed.
set('cipi_node_mode', '__CIPI_NODE_MODE__');
set('cipi_node_output', '__CIPI_NODE_OUTPUT__');
set('cipi_node_version', '__CIPI_NODE_VERSION__');
// Node from /opt/cipi/node/<major> first, so npm/npx/pnpm/yarn (corepack) match it.
set('cipi_node_env', function () {
    return 'export PATH=/opt/cipi/node/' . get('cipi_node_version') . '/bin:/usr/local/bin:/usr/bin:/bin'
        . ' CI=true COREPACK_ENABLE_DOWNLOAD_PROMPT=0 NEXT_TELEMETRY_DISABLED=1 NUXT_TELEMETRY_DISABLED=1'
        . ' ASTRO_TELEMETRY_DISABLED=1 GATSBY_TELEMETRY_DISABLED=1';
});

host('localhost')
    ->set('remote_user', '__CIPI_APP_USER__')
    ->set('deploy_path', '__CIPI_DEPLOY_PATH__')
    ->set('ssh_arguments', ['-o StrictHostKeyChecking=accept-new', '-i __CIPI_DEPLOY_PATH__/.ssh/id_ed25519']);

// cipi.yml `node:` in this release (only with `cipi yml auto <app> on`, which is
// also what grants the sudo rule): root validates it and updates the app before
// anything is installed or built, so this commit builds with its own settings.
task('node:config', function () {
    if (test('sudo -n -l /usr/local/bin/cipi yml node-sync __CIPI_APP_USER__ {{release_path}} >/dev/null 2>&1')) {
        run('sudo -n /usr/local/bin/cipi yml node-sync __CIPI_APP_USER__ {{release_path}}');
    }
    if (test('[ -f {{deploy_path}}/.deployer/node.json ]')) {
        $cfg = json_decode(run('cat {{deploy_path}}/.deployer/node.json'), true);
        if (is_array($cfg)) {
            if (in_array($cfg['mode'] ?? '', ['spa', 'static', 'ssr'], true)) {
                set('cipi_node_mode', $cfg['mode']);
            }
            if (preg_match('/^[0-9]{2}$/', (string) ($cfg['version'] ?? ''))) {
                set('cipi_node_version', (string) $cfg['version']);
            }
            if (preg_match('#^[A-Za-z0-9_.][A-Za-z0-9._/-]{0,120}$#', (string) ($cfg['output'] ?? ''))) {
                set('cipi_node_output', $cfg['output']);
            }
        }
    }
});

// After `current` moved: nginx follows a mode or output change from cipi.yml.
task('node:finalize', function () {
    if (test('sudo -n -l /usr/local/bin/cipi yml node-sync __CIPI_APP_USER__ {{release_path}} --finalize >/dev/null 2>&1')) {
        run('sudo -n /usr/local/bin/cipi yml node-sync __CIPI_APP_USER__ {{release_path}} --finalize');
    }
});

// Dependencies exactly as locked. devDependencies are installed: the build needs them.
task('node:install', function () {
    $cd = '{{cipi_node_env}} && cd {{release_path}} && ';
    if (test('[ -f {{release_path}}/pnpm-lock.yaml ]')) {
        run($cd . 'pnpm install --frozen-lockfile');
    } elseif (test('[ -f {{release_path}}/yarn.lock ]')) {
        run($cd . 'if [ -f .yarnrc.yml ]; then yarn install --immutable; else yarn install --frozen-lockfile; fi');
    } elseif (test('[ -f {{release_path}}/bun.lock ] || [ -f {{release_path}}/bun.lockb ]')) {
        run($cd . 'command -v bun >/dev/null || { echo "bun lockfile found but bun is not installed" >&2; exit 1; }; bun install --frozen-lockfile');
    } elseif (test('[ -f {{release_path}}/package-lock.json ]')) {
        run($cd . 'npm ci --no-audit --no-fund');
    } elseif (test('[ -f {{release_path}}/package.json ]')) {
        writeln('<comment>No lockfile — npm install (commit a lockfile for reproducible builds)</comment>');
        run($cd . 'npm install --no-audit --no-fund');
    } else {
        throw new \RuntimeException('package.json not found in the repository root');
    }
});

// Build command from apps.json (cipi app edit <app> --build=…), written by Cipi.
task('node:build', function () {
    run('{{cipi_node_env}} NODE_ENV=production && {{deploy_path}}/.deployer/node-build.sh {{release_path}}');
});

task('node:verify', function () {
    if (get('cipi_node_mode') === 'ssr') {
        return;
    }
    if (!test('[ -f {{release_path}}/{{cipi_node_output}}/index.html ]')) {
        throw new \RuntimeException('Build output {{cipi_node_output}}/index.html not found — set it with: cipi app edit __CIPI_APP_USER__ --output=<dir>');
    }
});

// Blue/green: start this release on the idle slot, wait for it, move nginx.
task('node:switch', function () {
    if (get('cipi_node_mode') === 'ssr') {
        run('sudo -n /usr/local/bin/cipi-node-switch __CIPI_APP_USER__ {{release_path}}');
    }
});

task('node:switch-current', function () {
    if (get('cipi_node_mode') === 'ssr') {
        run('sudo -n /usr/local/bin/cipi-node-switch __CIPI_APP_USER__ current');
    }
});

desc('Deploy a Node frontend app');
task('deploy', [
    'deploy:prepare',
    'node:config',
    'node:install',
    'node:build',
    'node:verify',
    'node:switch',
    'deploy:publish',
]);

after('deploy:symlink', 'node:finalize');
after('rollback', 'node:switch-current');
after('deploy:failed', 'deploy:unlock');

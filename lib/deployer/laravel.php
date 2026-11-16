<?php
namespace Deployer;
require 'recipe/laravel.php';

set('application', '__CIPI_APP_USER__');
set('repository', '__CIPI_REPOSITORY__');
set('branch', '__CIPI_BRANCH__');
set('deploy_path', '__CIPI_DEPLOY_PATH__');
set('keep_releases', __CIPI_KEEP_RELEASES__);
set('git_ssh_command', 'ssh -i __CIPI_DEPLOY_PATH__/.ssh/id_ed25519 -o StrictHostKeyChecking=accept-new');
set('bin/php', '/usr/bin/php__CIPI_PHP_VERSION__');
set('bin/composer', '/usr/bin/php__CIPI_PHP_VERSION__ /usr/local/bin/composer');
set('writable_mode', 'chmod');

add('shared_files', __CIPI_SHARED_FILES__);
add('shared_dirs', ['storage']);
// Override recipe/laravel.php writable_dirs: do NOT include "storage" or "storage/logs" — chmod -R
// would touch laravel-*.log and fail (EPERM). The logs directory is chmod'd by cipi:chmod_storage_logs_dir.
set('writable_dirs', [
    'bootstrap/cache',
    'storage/app', 'storage/app/public',
    'storage/framework', 'storage/framework/cache', 'storage/framework/cache/data',
    'storage/framework/sessions', 'storage/framework/views',
]);

host('localhost')
    ->set('remote_user', '__CIPI_APP_USER__')
    ->set('deploy_path', '__CIPI_DEPLOY_PATH__')
    ->set('ssh_arguments', ['-o StrictHostKeyChecking=accept-new', '-i __CIPI_DEPLOY_PATH__/.ssh/id_ed25519']);

after('deploy:vendors', 'cipi:node_build');
__CIPI_HOOK_STORAGE_LINK__
__CIPI_HOOK_MIGRATE__
__CIPI_HOOK_OPTIMIZE__
__CIPI_HOOK_EXTRA_ARTISAN__
after('deploy:writable', 'cipi:chmod_storage_logs_dir');
before('deploy:symlink', 'workers:stop');
__CIPI_HOOK_HORIZON_TERMINATE__
__CIPI_HOOK_QUEUE_RESTART__
after('deploy:symlink', 'workers:restart');
// A deploy that fails releases its own lock: the next one starts without
// `cipi deploy <app> --unlock`. A deploy refused because another one is
// running is not a failure for Deployer, and releases nothing.
after('deploy:failed', 'deploy:unlock');

task('cipi:chmod_storage_logs_dir', function () {
    run('chmod 775 {{release_path}}/storage/logs 2>/dev/null || true');
});

// Optional frontend build (script written by cipi when node_build is set).
task('cipi:node_build', function () {
    run('test ! -x {{deploy_path}}/.deployer/node-build.sh || {{deploy_path}}/.deployer/node-build.sh {{release_path}}');
});

task('workers:stop', function () {
    run('sudo /usr/local/bin/cipi-worker stop __CIPI_APP_USER__');
});

task('workers:restart', function () {
    run('sudo /usr/local/bin/cipi-worker restart __CIPI_APP_USER__');
});

// Skip when no current symlink yet, or laravel/horizon is not in the current release.
// Do not call artisan unless the package exists — otherwise Symfony throws NamespaceNotFoundException
// (deploy still succeeds via || true, but app exception trackers report it).
// Use deploy_path/current — {{current_path}} runs readlink and aborts when the symlink is missing.
task('horizon:terminate', function () {
    run('[ ! -L {{deploy_path}}/current ] || [ ! -f {{deploy_path}}/current/vendor/laravel/horizon/composer.json ] || {{bin/php}} {{deploy_path}}/current/artisan horizon:terminate 2>/dev/null || true');
});

__CIPI_EXTRA_ARTISAN_TASK__

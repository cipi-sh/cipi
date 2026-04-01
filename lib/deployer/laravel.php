<?php
namespace Deployer;
require 'recipe/laravel.php';

set('application', '__CIPI_APP_USER__');
set('repository', '__CIPI_REPOSITORY__');
set('branch', '__CIPI_BRANCH__');
set('deploy_path', '__CIPI_DEPLOY_PATH__');
set('keep_releases', 5);
set('git_ssh_command', 'ssh -i __CIPI_DEPLOY_PATH__/.ssh/id_ed25519 -o StrictHostKeyChecking=accept-new');
set('bin/php', '/usr/bin/php__CIPI_PHP_VERSION__');
set('bin/composer', '/usr/bin/php__CIPI_PHP_VERSION__ /usr/local/bin/composer');
set('writable_mode', 'chmod');

add('shared_files', ['.env']);
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

after('deploy:vendors', 'artisan:storage:link');
after('deploy:vendors', 'artisan:migrate');
after('deploy:vendors', 'artisan:optimize');
after('deploy:writable', 'cipi:chmod_storage_logs_dir');
before('deploy:symlink', 'workers:stop');
after('deploy:symlink', 'artisan:queue:restart');
after('deploy:symlink', 'workers:restart');

task('cipi:chmod_storage_logs_dir', function () {
    run('chmod 775 {{release_path}}/storage/logs 2>/dev/null || true');
});

task('workers:stop', function () {
    run('sudo /usr/local/bin/cipi-worker stop __CIPI_APP_USER__');
});

task('workers:restart', function () {
    run('sudo /usr/local/bin/cipi-worker restart __CIPI_APP_USER__');
});

# Changelog

All notable changes to Cipi are documented in this file.

---

## [4.2.3] — 2026-03-09

### Fixed

- **SSH login notification showing "SSH Key: unknown"** — PAM auth notification script could not resolve the SSH key name on login because `SSH_USER_AUTH` is not yet available in the sshd PAM session context; added fallback that parses `/var/log/auth.log` for the `Accepted publickey` fingerprint and matches it against `authorized_keys` to resolve the key comment/name
- **Email notifications literal `\n`** — all notifications sent via `cipi_notify()` showed literal `\n` instead of line breaks; fixed `_smtp_send` to use `printf %b` for the body so escape sequences are interpreted correctly

### Added

- **SSH key rename notification** — email alert via SMTP when an SSH key is renamed; includes old name, new name, fingerprint, server hostname, and timestamp
- **Client identity in all notifications** — every email notification now includes a footer with the client IP (`SSH_CLIENT`) and the SSH key name used to authenticate; key name is resolved via `SSH_USER_AUTH` with `auth.log` fallback
- **`su` elevation notification** — PAM auth notification now covers `su` in addition to `sudo` and `sshd`; alerts include who ran `su`, the target user, SSH key, and client IP
- **Security event log** — all notification events (SSH key changes, app lifecycle, password resets, sudo/su/SSH login, cron failures) are always logged to `/var/log/cipi/events.log` in a compact one-line format, regardless of whether SMTP is configured; rotated daily with 1-year retention via existing logrotate config

---

## [4.2.2] — 2026-03-08

### Fixed

- **Nginx default host 404** — requests to unconfigured domains (e.g. server IP with random paths) now always serve the "Server Up" page instead of the default nginx 404 error; uses `rewrite` instead of `try_files` for reliable catch-all behavior
- **`cipi ssh list` / `cipi ssh remove` silent exit** — both commands printed the header but no keys; caused by `((i++))` returning exit code 1 when `i=0` (post-increment evaluates to 0 = falsy) under `set -euo pipefail`; fixed with `|| true` guard on all arithmetic increments
- **SSH key comment stripped on setup** — `collect_ssh_key()` used `awk '{print $1, $2}'` to sanitize input, discarding the comment field (third+ column); keys added during install were always stored without their original comment

### Changed

- **PAM auth notifications** — now include SSH key fingerprint/comment for both sudo and SSH login alerts; key is resolved via `ExposeAuthInfo` + `SSH_USER_AUTH`
- **SSH access model** — replaced `AllowUsers cipi` with group-based access (`AllowGroups cipi-ssh cipi-apps`); `cipi` user remains key-only; app users can now SSH directly with username and password via `Match Group cipi-apps` block that enables `PasswordAuthentication` selectively

### Added

- **App lifecycle notifications** — email alerts on app create, edit, and delete; includes server hostname, app name, domain, PHP version, and change details; sensitive data (passwords, tokens, keys) is never included
- **`cipi app reset-password <app>`** — regenerate the SSH password for an app's Linux user; displays new password once and sends email notification
- **`cipi app reset-db-password <app>`** — regenerate the MariaDB password for an app user; automatically updates `DB_PASSWORD` in the app's `.env` file
- **`cipi reset root-password`** — regenerate the root SSH password and update `server.json` in the vault
- **`cipi reset db-password`** — regenerate the MariaDB root password and update `server.json` in the vault
- **`cipi reset redis-password`** — regenerate the Redis password, restart Redis, and update `server.json` in the vault; warns about updating app `.env` files
- **`cipi ssh rename [number] [name]`** — set or change the display name of an SSH key; updates the comment field in `authorized_keys`; interactive selection if called without arguments

### Security

- **Sudoers hardening** — `www-data` sudo access restricted from wildcard (`cipi *`) to an explicit whitelist of API commands only (`app create/edit/delete`, `deploy`, `alias add/remove`, `ssl install`, `cat apps.json`); prevents privilege escalation from a compromised PHP process
- **Command injection fix** — replaced unsafe `eval` with `printf -v` in `read_input()` and `parse_args()` (`common.sh`); user input is no longer interpreted by the shell
- **Sed injection fix** — `branch` and `repository` values are now escaped before interpolation in `sed` commands (`app.sh`); prevents injection via special characters (`|`, `&`, `\`)
- **API command whitelist** — `CipiCliService` now validates commands against an `ALLOWED_COMMANDS` whitelist before executing `sudo cipi`; provides defence-in-depth alongside sudoers

---

## [4.2.1] — 2026-03-08

### Added

- **Non-interactive SSH key input** — `setup.sh` now accepts `SSH_PUBKEY` environment variable for non-interactive installs (e.g. `SSH_PUBKEY="ssh-rsa ..." bash setup.sh`)
- **Random root password** — installer generates a 32-character random root password, saves it in server.json, and displays it in the final summary
- **SSH key setup instructions** — clearer installer prompt: shows accepted key formats (ssh-rsa, ssh-ed25519, ecdsa) for existing keys, and RSA 4096 generation command for new keys

### Security

- **`su` restricted to sudo group** — application users can no longer use `su` to elevate to root or cipi (via `pam_wheel.so group=sudo`)

### Fixed

- **SSH key paste in `curl | bash`** — `read` now reads from `/dev/tty` so interactive input works when setup is piped via curl
- **SSH key sanitization** — automatically strips comments, carriage returns, and extra whitespace from pasted keys before validation
- **SSH service restart on Ubuntu 24.04** — use `ssh` service name with `sshd` fallback for compatibility across distributions
- **server.json missing during SSH hardening** — installer now creates `/etc/cipi/server.json` before writing to it, and MariaDB setup merges instead of overwriting

---

## [4.2.0] — 2026-03-08

### Added

- **SSH hardening at install** — `setup.sh` now asks for an SSH public key during installation (before any package install begins); creates a dedicated `cipi` user as the only SSH entry point; disables root login and password authentication
  - `PermitRootLogin no`, `PasswordAuthentication no`, `PubkeyAuthentication yes`, `AllowUsers cipi`, `MaxAuthTries 3`, `LoginGraceTime 20`, `X11Forwarding no`, `ExposeAuthInfo yes`
  - `cipi` user has passwordless sudo for `/usr/local/bin/cipi *` only
  - Server-to-server ed25519 keypair auto-generated for sync operations
- **`cipi ssh list`** — list all authorized SSH keys for the cipi user with fingerprint, comment, and current-session marker (`<< current session`)
- **`cipi ssh add [key]`** — add an SSH public key (interactive prompt if no argument); validates format, rejects duplicates; sends email notification via SMTP if configured
- **`cipi ssh remove [n]`** — remove an SSH key by number (interactive list if no argument); sends email notification via SMTP if configured
  - **Session safety** — detects the key used for the current SSH session (via `ExposeAuthInfo` + `SSH_USER_AUTH`) and blocks its removal
  - **Last-key safety** — prevents removing the last remaining key to avoid lockout
- **`cipi sync pubkey`** — display this server's sync public key (for server-to-server trust)
- **`cipi sync trust`** — add a remote server's public key to cipi's authorized_keys, enabling passwordless `cipi sync push` between servers
- **SSH key change notifications** — email alerts (via existing SMTP) on every key add/remove, including server hostname, IP, key fingerprint, comment, timestamp, and remaining key count

### Changed

- **Sync default user** — `cipi sync push` now connects as `cipi` (was `root`); remote commands use `sudo cipi` for privilege escalation
- **Sync troubleshooting** — updated help messages to reference `cipi sync trust` and `cipi sync pubkey` instead of `PermitRootLogin yes`
- **Installation summary** — now shows SSH access info (login command, root-login disabled, password-auth disabled) and the server sync public key
- **Sudoers** — `SSH_USER_AUTH` env variable preserved through sudo (`env_keep`) for session key detection
- **Nginx default vhost** — all requests to the server IP now serve the "Server Up" page instead of returning nginx default 404; custom `error_page` directive catches all error codes (400–504) and serves `/index.html`, preventing nginx version leaks in error pages

---

## [4.1.2] — 2026-03-07

### Fixed

- **Worker restart loop during deploy** — Supervisor no longer floods logs with `Could not open input file: /home/<app>/current/artisan` during deployments. Root cause: the worker process exited when the `current` symlink was briefly unavailable during `deploy:symlink`, triggering immediate Supervisor restarts before the new release was in place. Fix: Deployer now stops workers (`workers:stop`) **before** the symlink swap and restarts them **after** (`workers:restart`), ensuring zero restart attempts against a broken symlink
- **`cipi worker stop <app>`** — new CLI subcommand to cleanly stop all Supervisor workers for an app without removing their configuration
- **`cipi-worker stop`** — extended the sudoers-restricted helper to support `stop` action, enabling Deployer tasks to stop workers during deploy without elevated privileges
- **Supervisor `autorestart=unexpected`** — new worker configs now only auto-restart on unexpected exits with `startretries=5` and `startsecs=3`, reducing noise from transient failures
- **Sudoers** — `cipi-worker stop <app>` added to the sudoers whitelist in both `app create` and `cipi sync`

---

## [4.1.1] — 2026-03-06

### Added

- **Security auth notifications** — email alerts on sudo elevation and privileged SSH logins (requires SMTP configured):
  - **Sudo**: notifies when any user successfully elevates to root via `sudo`, including who ran it and from which TTY
  - **SSH login**: notifies when `root` or any sudoer logs in via SSH, including source IP
  - Integrated via PAM (`pam_exec.so`); runs asynchronously to avoid login delays; fails silently if SMTP is not configured
- **Auth notifications: suppress internal sudo events** — sudo notifications triggered by Cipi internal operations (API calls via PHP-FPM, queue workers, cron jobs, systemd services) are now silently skipped; only interactive sudo elevations from real SSH sessions generate alerts
  - Detection via kernel `loginuid` (primary) with process-tree inspection fallback (php-fpm, artisan queue, supervisord, cipi-queue)
- **Auth notifications: resolve "User: unknown"** — the `SUDO_USER` field in sudo alerts now correctly resolves the calling user via `loginuid` when the PAM environment does not propagate `$SUDO_USER`

### Fixed

- **Vault readonly guard** — `vault.sh` could crash with `readonly variable` error when sourced multiple times in the same shell (e.g. during PAM hooks or nested cipi calls)

---

## [4.1.0] — 2026-03-06

### Added

- **Sync: export/import/list** — transfer apps between CIPI servers
- **`cipi sync export [app ...] [--with-db] [--with-storage]`** — export all apps or specific ones to a portable `.tar.gz` archive including configs, SSH keys, deployer config, supervisor workers, and optionally database dumps and shared storage
- **`cipi sync import <file> [app ...] [--deploy] [--yes]`** — import apps from an archive into the current server; recreates users, databases (with new credentials), nginx vhosts, PHP-FPM pools, supervisor workers, crontabs, and deployer configs; selectively import specific apps from a multi-app archive
- **`cipi sync push [app ...] [--host=IP] [--port=22] [--with-db] [--with-storage] [--import]`** — export, transfer via rsync/scp to a remote server, and optionally run import on the remote; interactive prompts for SSH host/port with connectivity test and remote Cipi version check
- **`cipi sync list <file>`** — inspect archive contents without importing (apps, PHP versions, DB/storage inclusion)
- **`--update` mode for import** — when an app already exists on the target, incrementally syncs .env (preserving local DB credentials), database dump (drop + reimport), shared storage, supervisor workers, deployer config, nginx vhost (alias changes), and PHP version changes; new apps are created as before; `push --import` uses `--update` automatically
- Pre-flight checks on import: warns about missing PHP versions, blocks import of apps that already exist (unless `--update`); **domain conflict check** — blocks import if domain or alias is already used by another app on target or by another app in the same import batch
- `.env` DB credentials automatically updated on import with the new server's values
- SSH deploy keys preserved from source (same key works with git provider)
- **Email notifications (optional)** — receive alerts when backup or deploy fails
- **`cipi smtp configure`** — interactive SMTP setup (host, port, user, password, from/to, TLS); supports Gmail, SendGrid, Mailgun, etc.; installs `msmtp` on first use
- **`cipi smtp status`** — show if notifications are enabled and recipient
- **`cipi smtp test`** — send a test email
- **`cipi smtp disable`** / **`cipi smtp enable`** — toggle notifications without losing config
- **`cipi smtp delete`** — remove SMTP config
- Notifications sent automatically on: backup errors (per-app or full run), deploy failures, system cron failures (self-update, SSL renewal)
- `cipi-cron-notify` wrapper — runs system cron jobs and sends email alert on failure
- Config stored in `/etc/cipi/smtp.json`; `smtp.json` included in sync export for migration
- **Vault: config encryption at rest** — all JSON config files (`server.json`, `apps.json`, `databases.json`, `backup.json`, `smtp.json`, `api.json`) are encrypted on disk with AES-256-CBC using a per-server master key (`/etc/cipi/.vault_key`); transparent read/write with backward compatibility for existing plaintext configs; existing servers are automatically migrated on update
- **apps-public.json** — plaintext projection of `apps.json` containing only non-sensitive fields (domain, aliases, php, branch, repository, user, created_at); automatically regenerated on every app change; the `cipi-api` group reads this file instead of the encrypted `apps.json`, so the vault key stays root-only with no privilege escalation
- **Encrypted sync export** — `cipi sync export` now encrypts the archive with a user-provided passphrase (AES-256-CBC); `cipi sync import` and `cipi sync list` transparently detect and decrypt encrypted archives; protects SSH keys, `.env` files, database dumps, and credentials during transfer; all sync commands accept `--passphrase=<secret>` for non-interactive/automated usage (cron, scripts)
- **GDPR-compliant log rotation** — automatic retention policies via logrotate:
  - **Application logs** (Laravel, PHP-FPM, workers, deploy, Cipi system) — **12 months**
  - **Security logs** (fail2ban, UFW firewall, auth) — **12 months**
  - **HTTP / Navigation logs** (nginx access & error) — **90 days**

---

## [4.0.8] — 2026-03-06

### Security

- **apps.json isolation**: app users could read other apps' webhook tokens via shared `www-data` group membership. Introduced dedicated `cipi-api` group — only `www-data` (PHP-FPM) belongs to it, so app SSH users can no longer access `/etc/cipi/apps.json`

### Changed

- `ensure_apps_json_api_access()` now creates and uses a `cipi-api` group instead of relying on the `www-data` group directly
- Migration `4.0.8.sh` fixes permissions on existing servers and restarts PHP-FPM to pick up the new group
- API `.env` now defaults to `APP_ENV=production` and `APP_DEBUG=false` on fresh install and upgrade
- MOTD updated to "Easy Laravel Deployments"

---

## [4.0.7] — 2026-03-06

### Added

- **Git provider integration**: `cipi git` — automatic deploy key and webhook configuration for GitHub and GitLab repositories
- **`cipi git github-token <token>`** — save GitHub Personal Access Token for auto-setup
- **`cipi git gitlab-token <token>`** — save GitLab Personal Access Token for auto-setup
- **`cipi git gitlab-url <url>`** — configure self-hosted GitLab instance URL
- **`cipi git remove-github`** — remove stored GitHub token
- **`cipi git remove-gitlab`** — remove stored GitLab token and URL
- **`cipi git status`** — show configured providers, tokens (masked) and per-app integration status
- **Auto-setup on `cipi app create`**: when a GitHub/GitLab token is configured, Cipi automatically adds the deploy key and creates the webhook on the repository — zero manual configuration needed
- **Auto-migrate on `cipi app edit --repository=...`**: when changing repository, Cipi removes deploy key + webhook from the old repo and creates them on the new one
- **Auto-cleanup on `cipi app delete`**: Cipi removes deploy key + webhook from the repository before deleting the app
- New `lib/git.sh` module with GitHub REST API v3 and GitLab REST API v4 integration (deploy keys + webhooks CRUD)
- `apps.json` extended with optional `git_provider`, `git_deploy_key_id`, `git_webhook_id` fields per app
- `server.json` extended on-demand with `github_token`, `gitlab_token`, `gitlab_url` fields

### Changed

- `cipi app show` now displays git provider integration status (provider, deploy key ID, webhook ID)
- `cipi deploy <app> --key` shows "auto-configured" status when deploy key was added via API
- `cipi deploy <app> --webhook` shows "auto-configured" status when webhook was added via API
- `cipi app create` summary adapts: shows "auto-configured" badge when git integration succeeded, or manual instructions with a setup tip when no token is configured
- Graceful fallback: if no token is configured or the API call fails, Cipi falls back to manual setup (existing behavior) without interrupting the flow

---

## [4.0.6] — 2026-03-05

### Added

- **Global API**: `cipi api <domain>` — configure API at root (e.g. api.miohosting.it), no aliases
- **API SSL**: `cipi api ssl` — install Let's Encrypt certificate for API domain
- **API tokens**: `cipi api token list|create|revoke` — manage Sanctum tokens (abilities: apps-view, apps-create, apps-edit, apps-delete, ssl-manage, aliases-view, aliases-create, aliases-delete, mcp-access)
- **REST API** (Bearer token): `GET/POST/PUT/DELETE /api/apps`, `GET/POST/DELETE /api/apps/{name}/aliases`, `POST /api/ssl/{name}`, `GET /api/jobs/{id}`
- **Async job system**: all write operations (create, edit, delete, SSL, alias add/remove) dispatch background jobs via Laravel queue, returning `202 Accepted` with a `job_id` for polling; GET operations remain synchronous
- **Sync validation**: domain uniqueness, app existence, PHP version, username format and domain format validated synchronously before job dispatch (409/404/422 returned immediately)
- **Swagger/OpenAPI docs** at `/docs` — interactive API documentation via Swagger UI (spec v2.0.0)
- **MCP server** at `/mcp` — requires `mcp-access` ability, tools for app/alias/SSL management (async dispatch with job_id)
- **Dedicated PHP-FPM pool** `cipi-api` for the API (isolated from app pools, up to 10 workers)
- **Queue worker** `cipi-queue` systemd service for processing background jobs (auto-restart, 600s timeout)
- **`andreapollastri/cipi-api` Composer package**: all API logic (controllers, services, models, MCP tools, migrations, views, routes) is now a standalone Laravel package, publishable on Packagist — install via `cipi api <domain>` or `composer require andreapollastri/cipi-api`
- **Welcome page** `welcome.blade.php` — dark/light theme landing page served at `/`
- **`cipi api update`** — soft update: `composer update` on all packages (Laravel minor/patch + cipi-api), re-publishes assets and runs migrations
- **`cipi api upgrade`** — full rebuild: fresh `composer create-project laravel/laravel` + `composer require cipi-api`, preserves `.env`, database, SSL certificates and tokens; keeps old version at `/opt/cipi/api.old` for rollback
- **`cipi api status`** — shows current Laravel version, cipi-api version, queue worker status and pending jobs

### Changed

- `cipi app delete <app> --force` — skip confirmation for non-interactive use
- API read endpoints (GET /apps, GET /apps/{name}, GET /aliases) now read directly from `apps.json` instead of invoking CLI
- API install uses `composer create-project laravel/laravel` + `composer require andreapollastri/cipi-api` instead of overlay copy — easier upgrades to future Laravel versions
- **apps.json API access**: when `cipi api <domain>` is run, Cipi automatically configures `/etc/cipi` and `apps.json` so that www-data (PHP-FPM) can read them — no manual `chmod 644` or sudoers rules needed

---

## [4.0.5] — 2026-03-05

### Fixed

- Nginx "conflicting server name" warnings when domains or aliases were duplicated
- `_create_nginx_vhost` now deduplicates domain + aliases before writing `server_name`
- Primary domain excluded from aliases when reading (handles legacy data where primary was added as alias)
- `cipi app create` rejects creation if the domain is already used by another app
- `cipi alias add` rejects adding an alias that equals the primary domain or is already used by another app
- `cipi ssl install` excludes primary domain from aliases when building Certbot `-d` flags

---

## [4.0.4] — 2026-03-05

### Added

- Redis in the default stack — installed with password, bind to localhost only
- `cipi service` now includes `redis-server` (list, restart, start, stop)
- Redis credentials (user, password) saved in `/etc/cipi/server.json` and shown at end of installation
- Migration 4.0.4 for existing servers: installs Redis and adds `redis-server` to unattended-upgrades blacklist

### Changed

- Redis added to unattended-upgrades package blacklist (managed by Cipi, no auto-upgrade)

---

## [4.0.3] — 2026-03-05

### Fixed

- `cipi app logs` now includes Laravel daily logs (`laravel-YYYY-MM-DD.log`) from `shared/storage/logs/`
- Added `--type=laravel` option to tail only Laravel application logs

---

## [4.0.2] — 2026-03-04

### Added

- `cipi deploy <app> --trust-host=<host[:port]>` — trust a custom Git server by scanning and persisting its SSH host key
- Custom Git server support in the deploy workflow (non-GitHub/GitLab repositories)
- `cipi backup prune [app] --weeks=N` — delete S3 backups older than N weeks, per-app or globally

### Fixed

- Installer (`setup.sh`) fix for edge cases during provisioning

### Changed

- Documentation updated to reflect new deploy and backup commands

---

## [4.0.1] — 2026-03-03

### Changed

- Self-update mechanism revised: version check and install script updated
- Installer link updated to new canonical URL (`cipi.sh/setup.sh`)
- README refreshed (condensed, up-to-date command reference)

---

## [4.0.0] — 2026-03-03

Complete rewrite of the Cipi CLI from the ground up.

### Added

- New modular shell architecture: each domain split into its own library (`lib/app.sh`, `lib/deploy.sh`, `lib/db.sh`, `lib/backup.sh`, `lib/ssl.sh`, `lib/php.sh`, `lib/firewall.sh`, `lib/service.sh`, `lib/worker.sh`, `lib/self-update.sh`, `lib/common.sh`)
- `lib/common.sh` — shared helpers: `parse_args`, `validate_*`, `generate_password`, `read_input`, `confirm`, `log_action`, and app registry helpers (`app_exists`, `app_get`, `app_set`, `app_save`, `app_remove`)
- `cipi service list|restart|start|stop` — full service management for nginx, mariadb, supervisor, fail2ban, php-fpm
- `cipi deploy <app> --unlock` — unlock a stuck Deployer process
- `cipi deploy <app> --webhook` — display webhook URL and token
- `cipi deploy <app> --key` — display the SSH deploy public key
- `cipi deploy <app> --releases` — list available releases
- `cipi deploy <app> --rollback` — roll back to the previous release
- `cipi backup configure` — interactive S3 configuration wizard
- `cipi backup run [app]` — run backup for a specific app or all apps
- `cipi backup list [app]` — list S3 backups per-app or globally (supports multiple S3 providers)
- `cipi self-update [--check]` — update Cipi in place; `--check` shows available version without installing
- `cipi app artisan <app> <cmd>` — run arbitrary Artisan commands
- `cipi app tinker <app>` — open Laravel Tinker for an app
- `cipi app logs <app> [--type=nginx|php|worker|deploy|laravel|all]` — tail app logs by type
- PHP 8.4 and 8.5 support
- `lib/cipi-worker` — standalone helper script for queue worker management via sudoers
- Nginx security headers (`X-Frame-Options`, `X-Content-Type-Options`, `Referrer-Policy`) in generated vhosts
- App registry stored as JSON (`/etc/cipi/apps.json`) with full CRUD via `app_save`/`app_remove`
- Structured action logging to `/var/log/cipi`

### Changed

- `cipi app create` now provisions: Linux user, directories, SSH deploy key, MariaDB database, `.env`, PHP-FPM pool, Nginx vhost, Supervisor worker, crontab (scheduler + deploy trigger), Deployer config, sudoers entry
- Deployer recipe uses `recipe/laravel.php` with automatic `artisan:migrate`, `artisan:optimize`, `artisan:storage:link`, `artisan:queue:restart`, and `workers:restart` hooks
- `cipi app edit` supports `--php`, `--branch`, `--repository` flags and updates all affected config files atomically
- `cipi app delete` performs full cleanup: workers, nginx, php-fpm, database, crontab, sudoers, SSL certificate, home directory
- `cipi alias add/remove` regenerates the Nginx vhost and reloads nginx
- `cipi db` commands (`create`, `list`, `delete`, `backup`, `restore`) rewritten with MariaDB-native tooling
- `cipi ssl install` uses Certbot with all aliases included in the certificate SAN
- `cipi php install` manages PHP-FPM installs per version
- `cipi firewall allow/list` wraps `ufw`
- Removed legacy `lib/commands.sh`, `lib/domain.sh`, `lib/nginx.sh`, `lib/database.sh`
- Removed Redis dependency from the default stack

### Fixed

- SSL Certbot integration with multi-domain vhosts
- Worker restart via supervisor with app-scoped naming
- PHP-FPM pool `open_basedir` set correctly per app
- Deploy key `authorized_keys` and `known_hosts` permissions hardened

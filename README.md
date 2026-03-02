<p align="center">
  <img src="https://raw.githubusercontent.com/andreapollastri/cipi/latest/logo.png" width="120" alt="Cipi">
</p>

<h1 align="center">Cipi</h1>

<p align="center">
  <strong>Install and manage your server like a pro.</strong><br>
  The open-source control panel built exclusively for Laravel.
</p>

<p align="center">
  <a href="#install">Install</a> •
  <a href="#quick-start">Quick Start</a> •
  <a href="#features">Features</a> •
  <a href="#commands">Commands</a> •
  <a href="#cipi-agent">Cipi Agent</a> •
  <a href="#documentation">Docs</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/version-4.0.0-blue" alt="Version">
  <img src="https://img.shields.io/badge/ubuntu-24.04+-orange" alt="Ubuntu">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="License">
  <img src="https://img.shields.io/github/stars/andreapollastri/cipi?style=social" alt="Stars">
</p>

---

One command installs a complete production stack. One command creates an isolated Laravel app with its own database, Redis, queue workers, SSL, and zero-downtime deploys. No web panel, no bloat — just SSH and `cipi`.

```bash
wget -O - https://raw.githubusercontent.com/andreapollastri/cipi/refs/heads/latest/install.sh | bash
```

---

## What you get

A single VPS becomes a multi-app Laravel hosting platform:

- **Nginx** reverse proxy with per-app virtual hosts
- **MariaDB 11.4** auto-tuned to your server's RAM
- **PHP 8.1 / 8.2 / 8.3 / 8.4** — all installed, selectable per app
- **Redis** for cache, sessions, and queues
- **Supervisor** managing queue workers per app
- **Deployer 7** for zero-downtime deployments
- **Let's Encrypt** automatic SSL via Certbot
- **Fail2ban + UFW** firewall out of the box
- **S3 backups** for databases and storage
- **Auto-update** — Cipi keeps itself current

Every app runs under its own Linux user. Isolated filesystem, isolated PHP-FPM pool, isolated database. One compromised app cannot touch the others.

---

## Install

**Requirements:** Ubuntu 24.04 LTS (or higher), root access, ports 22/80/443 open.

```bash
# Standard install
wget -O - https://raw.githubusercontent.com/andreapollastri/cipi/refs/heads/latest/install.sh | bash

# AWS (where root login is disabled by default)
ssh ubuntu@your-server-ip
sudo -s
wget -O - https://raw.githubusercontent.com/andreapollastri/cipi/refs/heads/latest/install.sh | bash
```

Installation takes about 10–15 minutes. At the end you'll see:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  CIPI v4.0.0 INSTALLED SUCCESSFULLY
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  MariaDB Root
  User:           root
  Password:       ********************************

  ⚠ SAVE THIS PASSWORD!

  Getting Started
  Server status:  cipi status
  All commands:   cipi help
  Create app:     cipi app create
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

> **Save the MariaDB root password.** It's shown only once and stored encrypted in `/etc/cipi/server.json`.

Cipi works on DigitalOcean, AWS EC2, Vultr, Linode, Hetzner, Google Cloud, OVH, and any Ubuntu VPS.

---

## Quick Start

### 1. Create your first app

```bash
cipi app create
```

Cipi asks a few questions:

```
App username: myapp
Primary domain: myapp.com
Git repository URL (SSH): git@github.com:you/myapp.git
Branch [main]: main
PHP version [8.4]: 8.4
```

Or skip the interactive mode:

```bash
cipi app create \
  --user=myapp \
  --domain=myapp.com \
  --repository=git@github.com:you/myapp.git \
  --branch=main \
  --php=8.4
```

At the end Cipi shows everything you need — **save it, it's shown only once:**

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  APP CREATED: myapp
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Domain:     myapp.com
  PHP:        8.4
  Home:       /home/myapp

  SSH         myapp / ************************
  Database    myapp / ********************************

  Deploy Key  (add to your Git provider)
  ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... myapp@cipi

  Webhook     https://myapp.com/cipi/webhook
  Token       ****************************************

  Next: composer require andreapollastri/cipi-agent
        cipi deploy myapp
        cipi ssl install myapp

  ⚠ SAVE THESE CREDENTIALS — shown only once
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### 2. Add the deploy key to your Git repository

Copy the SSH key and add it as a **Deploy Key**:

- **GitHub:** Repository → Settings → Deploy keys → Add deploy key
- **GitLab:** Repository → Settings → Repository → Deploy keys
- **Bitbucket:** Repository → Settings → Access keys
- **Gitea:** Repository → Settings → Deploy Keys

This works with **any Git provider** that supports SSH keys. No OAuth, no SSO — just standard SSH authentication.

### 3. Deploy

```bash
cipi deploy myapp
```

Deployer clones your repo, runs `composer install`, links storage, runs migrations, and swaps the `current` symlink — zero downtime.

### 4. Install SSL

```bash
cipi ssl install myapp
```

Certbot provisions a Let's Encrypt certificate, configures Nginx for HTTPS, and updates `APP_URL` in your `.env`.

**That's it.** Your Laravel app is live on `https://myapp.com`.

---

## What Cipi creates for each app

When you run `cipi app create`, this is what happens behind the scenes:

```
/home/myapp/                         ← isolated Linux user (chmod 750)
├── .ssh/
│   ├── id_ed25519                   ← deploy key (private)
│   └── id_ed25519.pub               ← deploy key (public)
├── .deployer/
│   └── deploy.php                   ← Deployer config (auto-generated)
├── current -> releases/3/           ← symlink to active release
├── releases/
│   ├── 1/
│   ├── 2/
│   └── 3/                           ← latest release
├── shared/
│   ├── .env                         ← auto-compiled by Cipi
│   └── storage/                     ← persistent storage
└── logs/
    ├── nginx-access.log
    ├── nginx-error.log
    ├── php-fpm-error.log
    ├── worker-default.log
    └── deploy.log

PHP-FPM pool:    /etc/php/8.4/fpm/pool.d/myapp.conf  (user=myapp)
Nginx vhost:     /etc/nginx/sites-available/myapp
Supervisor:      /etc/supervisor/conf.d/myapp.conf
Crontab:         * * * * * php artisan schedule:run
MariaDB:         database 'myapp', user 'myapp'@'localhost'
Redis:           database number 1 (isolated per app)
```

The `.env` is **auto-compiled** with all credentials — database, Redis, webhook token, app key. You don't have to configure anything manually.

---

## Features

### Multi-PHP

All four PHP versions (8.1, 8.2, 8.3, 8.4) are installed during setup. You choose the version per app:

```bash
# Create an app on PHP 8.2 (for an older Laravel project)
cipi app create --user=legacy --domain=legacy.com --php=8.2

# Switch an app to a different PHP version (hot swap, no downtime)
cipi app edit myapp --php=8.3
```

Switching PHP updates everything: FPM pool, Nginx socket, Supervisor workers, crontab, Deployer config, and the `.env`.

#### Installing future PHP versions

When PHP 8.5 or later versions are released, Cipi will support them through updates. You can also install new versions manually:

```bash
cipi php install 8.5    # when available in the ondrej/php PPA
cipi php list            # see all installed versions and their status
cipi php remove 8.1      # remove a version (only if no apps use it)
```

Cipi uses the [ondrej/php PPA](https://launchpad.net/~ondrej/+archive/ubuntu/php) which is the de-facto standard for PHP on Ubuntu. New PHP releases typically land there within days of their official release.

---

### Zero-downtime deploys with Deployer

Cipi uses [Deployer](https://deployer.org) for deployments. Every deploy:

1. Clones your repo into a new `releases/N/` directory
2. Runs `composer install --no-dev`
3. Links shared files (`.env`, `storage/`)
4. Runs `artisan migrate --force`
5. Runs `artisan optimize`
6. Creates `storage:link`
7. Swaps the `current` symlink atomically
8. Restarts queue workers
9. Keeps the last 5 releases for instant rollback

```bash
cipi deploy myapp              # deploy latest
cipi deploy myapp --rollback   # instant rollback to previous release
cipi deploy myapp --releases   # list all releases with dates
cipi deploy myapp --key        # show the SSH deploy key
```

---

### Automatic deploys via webhook

For automatic deploys on `git push`, install the [Cipi Agent](#cipi-agent) Laravel package in your app and configure a webhook in your Git provider.

The flow is simple and secure:

```
git push → GitHub sends POST to /cipi/webhook
         → cipi/agent verifies HMAC signature
         → writes /home/myapp/.deploy-trigger (a small JSON flag file)

cron (every minute, runs as 'myapp' user)
         → sees .deploy-trigger
         → deletes it
         → runs: dep deploy
         → logs everything to ~/logs/deploy.log
```

No sudo. No privilege escalation. PHP-FPM and the cron both run as the app user. Deployer runs as the app user. The flag file mechanism means the webhook returns instantly (no long HTTP timeout) and the deploy runs cleanly in the background.

---

### Queue workers

Every app gets a default Supervisor worker for the `default` queue. Add more as needed:

```bash
# Add a worker for the 'emails' queue with 3 processes
cipi worker add myapp --queue=emails --processes=3

# Add a worker for heavy jobs with a long timeout
cipi worker add myapp --queue=exports --processes=1 --timeout=7200

# List all workers
cipi worker list myapp

# Output:
# PROGRAM                      QUEUE      PROCS  STATUS
# myapp-worker-default         default    1      RUNNING
# myapp-worker-emails          emails     3      RUNNING
# myapp-worker-exports         exports    1      RUNNING

# Scale up a worker
cipi worker edit myapp --queue=default --processes=3

# Restart all workers (e.g. after code changes)
cipi worker restart myapp

# Remove a worker
cipi worker remove myapp emails
```

Workers are automatically restarted after each deploy.

---

### Domain aliases

Add multiple domains or subdomains to any app:

```bash
cipi alias add myapp www.myapp.com
cipi alias add myapp staging.myapp.com
cipi alias add myapp myapp.it
cipi alias list myapp
cipi alias remove myapp staging.myapp.com
```

After adding aliases, update SSL to include the new domains:

```bash
cipi ssl install myapp
```

Certbot will provision a single certificate with SAN (Subject Alternative Names) for all domains.

---

### SSL certificates

```bash
cipi ssl install myapp    # provision Let's Encrypt certificate
cipi ssl status            # show all certs with expiry dates
cipi ssl renew             # force renewal of all certificates
```

Certificates auto-renew via a weekly cron. `cipi ssl status` shows expiry dates with color-coded warnings (green > 30 days, yellow 14–30, red < 14).

---

### Database management

Cipi creates a dedicated MariaDB database for each app automatically. You can also manage databases separately:

```bash
cipi db create                     # interactive
cipi db create --name=analytics    # non-interactive
cipi db list                       # all databases with sizes
cipi db backup myapp               # dump → /var/log/cipi/backups/
cipi db restore myapp backup.sql.gz
cipi db password myapp             # regenerate password
cipi db delete analytics
```

---

### S3 backups

Backup databases and storage to Amazon S3 (or any S3-compatible provider):

```bash
# One-time setup
cipi backup configure
# → asks for AWS Access Key, Secret, Bucket, Region

# Backup everything
cipi backup run

# Backup a single app
cipi backup run myapp

# List backups
cipi backup list
cipi backup list myapp
```

Each backup uploads to `s3://your-bucket/cipi/appname/2025-01-15_143022/` and contains:

- `db.sql.gz` — compressed database dump
- `shared.tar.gz` — the entire `shared/` directory (`.env`, `storage/`)

You can schedule automatic backups by adding a cron:

```bash
# Daily backup at 2 AM (add to root crontab)
crontab -e
0 2 * * * /usr/local/bin/cipi backup run >> /var/log/cipi/backup.log 2>&1
```

---

### Firewall

Cipi installs UFW with ports 22, 80, and 443 open by default. Manage additional rules:

```bash
cipi firewall allow 3306 --from=10.0.0.5    # MySQL access from specific IP
cipi firewall allow 6379 --from=10.0.0.0/24  # Redis from subnet
cipi firewall deny 8080                       # block a port
cipi firewall list                            # show all rules
```

---

### Artisan & Tinker

Run Artisan commands and Tinker as the app user (correct permissions, correct PHP version):

```bash
cipi app artisan myapp migrate:status
cipi app artisan myapp queue:retry all
cipi app artisan myapp db:seed --class=ProductionSeeder
cipi app tinker myapp
```

---

### Logs

Tail application logs in real-time:

```bash
cipi app logs myapp                  # all logs
cipi app logs myapp --type=nginx     # Nginx access + error
cipi app logs myapp --type=php       # PHP-FPM errors
cipi app logs myapp --type=worker    # queue worker output
cipi app logs myapp --type=deploy    # deploy history
```

Logs are automatically rotated daily and kept for 14 days.

---

## Cipi Agent

**[andreapollastri/cipi-agent](https://github.com/andreapollastri/cipi-agent)** is a lightweight Laravel package that connects your app to Cipi.

### Install

```bash
composer require andreapollastri/cipi-agent
```

The service provider auto-discovers. No configuration needed — Cipi already set the required `.env` variables during app creation.

### What it provides

**Webhook endpoint** at `/cipi/webhook` — receives push events from GitHub, GitLab, Bitbucket, and Gitea. Verifies HMAC signatures (GitHub/Gitea) or token comparison (GitLab). Writes a `.deploy-trigger` flag file that Cipi's cron picks up to run Deployer.

**Health check** at `/cipi/health` — returns JSON with app, database, Redis, cache, and queue status. Useful for monitoring services like UptimeRobot.

**Artisan commands:**

```bash
php artisan cipi:status       # show Cipi config and connectivity
php artisan cipi:deploy-key   # show the SSH deploy key
```

### Webhook setup

After installing the agent, configure a webhook in your Git provider:

| Provider  | URL                                   | Secret/Token          |
| --------- | ------------------------------------- | --------------------- |
| GitHub    | `https://yourdomain.com/cipi/webhook` | Set as "Secret"       |
| GitLab    | `https://yourdomain.com/cipi/webhook` | Set as "Secret token" |
| Bitbucket | `https://yourdomain.com/cipi/webhook` | —                     |
| Gitea     | `https://yourdomain.com/cipi/webhook` | Set as "Secret"       |

The token is in your `.env` as `CIPI_WEBHOOK_TOKEN` (also visible via `cipi deploy myapp --webhook`).

### Branch filtering

To only deploy when pushing to a specific branch:

```env
CIPI_DEPLOY_BRANCH=main
```

Pushes to other branches get a `skipped` response.

### Health check

```bash
curl -H "Authorization: Bearer YOUR_TOKEN" https://yourdomain.com/cipi/health
```

```json
{
  "status": "healthy",
  "app_user": "myapp",
  "php": "8.4",
  "laravel": "12.0.0",
  "checks": {
    "database": { "ok": true },
    "redis": { "ok": true },
    "cache": { "ok": true },
    "queue": { "ok": true, "pending_jobs": 0 }
  }
}
```

---

## Self-Update

Cipi can update itself from GitHub:

```bash
# Check if an update is available
cipi self-update --check

# Update to the latest version
cipi self-update

# Update from a specific branch (for testing)
cipi self-update --branch=develop
```

The update process:

1. Downloads the latest version from GitHub
2. Backs up the current installation to `/opt/cipi.bak.YYYYMMDDHHMMSS/`
3. Replaces CLI and lib scripts
4. Runs **migration scripts** if the new version requires system changes (e.g., new Nginx config directives, new packages)
5. Updates the version file

Migration scripts live in `lib/migrations/` and are named by version (e.g., `4.1.0.sh`). When updating from v4.0.0 to v4.2.0, Cipi automatically runs `4.1.0.sh` and `4.2.0.sh` in order. This means Cipi can evolve the server configuration over time without requiring a full reinstall.

**Your apps, databases, and configurations are never touched by updates.** Only Cipi's own scripts are replaced.

You can also reinstall Cipi at any time without affecting existing apps:

```bash
wget -O - https://raw.githubusercontent.com/andreapollastri/cipi/refs/heads/latest/install.sh | bash
```

The installer detects existing configurations and preserves them.

---

## Security

Cipi takes security seriously:

- **User isolation** — each app runs under its own Linux user with `chmod 750` on the home directory. Apps cannot read each other's files.
- **PHP-FPM isolation** — each app has its own FPM pool running as the app user with its own socket. `open_basedir` restricts PHP to the app's home directory.
- **Database isolation** — each app has its own MariaDB user with `GRANT ALL` only on its own database.
- **Redis isolation** — each app uses a separate Redis database number (0–15).
- **SSH keys per app** — each app gets its own ed25519 deploy key. A compromised key only affects one repository.
- **Fail2ban** — brute-force protection on SSH with automatic IP banning.
- **UFW firewall** — only ports 22, 80, and 443 are open by default.
- **No web panel** — no attack surface from a web interface. Management is SSH-only.
- **Automatic updates** — system packages update weekly via cron.
- **SSL enforcement** — Certbot configures HTTPS with automatic redirect from HTTP.

Credentials (database passwords, webhook tokens) are generated using `openssl rand` and shown only once during creation. They are not stored in plain text in any config file accessible to other users.

---

## Commands Reference

### Server

| Command                    | Description                                         |
| -------------------------- | --------------------------------------------------- |
| `cipi status`              | Server status (CPU, RAM, disk, services, PHP, apps) |
| `cipi version`             | Show Cipi version                                   |
| `cipi self-update`         | Update Cipi                                         |
| `cipi self-update --check` | Check for updates without installing                |

### Applications

| Command                                                      | Description                      |
| ------------------------------------------------------------ | -------------------------------- |
| `cipi app create`                                            | Create app (interactive)         |
| `cipi app create --user=U --domain=D --repository=R --php=V` | Create app (flags)               |
| `cipi app list`                                              | List all apps                    |
| `cipi app show <app>`                                        | App details, deploy key, workers |
| `cipi app edit <app> --php=8.3`                              | Change PHP version               |
| `cipi app edit <app> --branch=develop`                       | Change deploy branch             |
| `cipi app delete <app>`                                      | Delete app (with confirmation)   |
| `cipi app env <app>`                                         | Edit `.env` in nano              |
| `cipi app logs <app>`                                        | Tail all logs                    |
| `cipi app logs <app> --type=deploy`                          | Tail specific log type           |
| `cipi app tinker <app>`                                      | Open Tinker                      |
| `cipi app artisan <app> migrate`                             | Run Artisan command              |

### Domains

| Command                            | Description      |
| ---------------------------------- | ---------------- |
| `cipi alias add <app> <domain>`    | Add domain alias |
| `cipi alias remove <app> <domain>` | Remove alias     |
| `cipi alias list <app>`            | List aliases     |

### Deploy

| Command                        | Description                  |
| ------------------------------ | ---------------------------- |
| `cipi deploy <app>`            | Deploy via Deployer          |
| `cipi deploy <app> --rollback` | Rollback to previous release |
| `cipi deploy <app> --releases` | List releases                |
| `cipi deploy <app> --key`      | Show SSH deploy key          |
| `cipi deploy <app> --webhook`  | Show webhook URL and token   |

### Workers

| Command                                          | Description         |
| ------------------------------------------------ | ------------------- |
| `cipi worker add <app> --queue=Q --processes=N`  | Add worker          |
| `cipi worker list <app>`                         | List workers        |
| `cipi worker edit <app> --queue=Q --processes=N` | Edit worker         |
| `cipi worker remove <app> <queue>`               | Remove worker       |
| `cipi worker restart <app>`                      | Restart all workers |

### Database

| Command                      | Description               |
| ---------------------------- | ------------------------- |
| `cipi db create`             | Create database           |
| `cipi db list`               | List databases with sizes |
| `cipi db delete <n>`         | Delete database           |
| `cipi db backup <n>`         | Backup to local file      |
| `cipi db restore <n> <file>` | Restore from file         |
| `cipi db password <n>`       | Regenerate password       |

### SSL / PHP / Firewall / Backup

| Command                                | Description                  |
| -------------------------------------- | ---------------------------- |
| `cipi ssl install <app>`               | Install Let's Encrypt SSL    |
| `cipi ssl renew`                       | Renew all certificates       |
| `cipi ssl status`                      | Show certificates and expiry |
| `cipi php install <ver>`               | Install PHP version          |
| `cipi php remove <ver>`                | Remove PHP version           |
| `cipi php list`                        | List installed PHP versions  |
| `cipi firewall allow <port>`           | Allow port                   |
| `cipi firewall allow <port> --from=IP` | Allow port from IP           |
| `cipi firewall deny <port>`            | Deny port                    |
| `cipi firewall list`                   | Show rules                   |
| `cipi backup configure`                | Configure S3 credentials     |
| `cipi backup run [app]`                | Backup all or single app     |
| `cipi backup list [app]`               | List backups                 |

---

## Why MariaDB?

Cipi v4 uses MariaDB instead of MySQL:

- **Drop-in replacement** — Laravel doesn't notice the difference. Same PDO driver, same SQL syntax.
- **Better performance** — more advanced query optimizer, native thread pool in the community edition.
- **Clean licensing** — pure GPL, no Oracle involvement.
- **Native on Ubuntu** — installs without external PPAs.
- **Auto-tuned** — Cipi configures `innodb_buffer_pool_size` based on your server's RAM (256M for 1GB, up to 4GB for 16GB+ servers).

---

## Differences from Cipi v3

|             | v3                      | v4                                                    |
| ----------- | ----------------------- | ----------------------------------------------------- |
| Interface   | Web UI (Laravel app)    | CLI only (SSH)                                        |
| Target      | Generic PHP + WordPress | Laravel exclusively                                   |
| Database    | MySQL                   | MariaDB 11.4                                          |
| Deploy      | `git pull`              | Deployer (zero-downtime)                              |
| Workers     | Basic Supervisor        | CLI-managed with add/edit/remove                      |
| Cache/Queue | Redis optional          | Redis required (cache + session + queue)              |
| Deploy keys | Shared                  | Per-app (ed25519)                                     |
| Webhooks    | Not available           | GitHub/GitLab/Bitbucket/Gitea via cipi/agent          |
| Auto-update | Reinstall               | `cipi self-update` with migrations                    |
| Scheduler   | Manual setup            | Automatic for every app                               |
| PHP         | Multi-version           | Multi-version (confirmed)                             |
| Isolation   | Separate users          | Users + FPM pools + open_basedir + separate Redis DBs |
| SSL         | Let's Encrypt           | Let's Encrypt with SAN for aliases                    |
| Backup      | Not available           | S3 automated                                          |

---

## Supported providers

Cipi works on any Ubuntu 24.04+ VPS:

- DigitalOcean
- AWS EC2
- Vultr
- Linode / Akamai
- Hetzner
- Google Cloud
- OVH
- Scaleway
- Any KVM/bare-metal with Ubuntu

---

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

---

## License

Cipi is open-source software licensed under the [MIT license](LICENSE).

---

<p align="center">
  Made with ❤️ for Laravel developers by <a href="https://web.ap.it">Andrea Pollastri</a>
</p>

<div align="center">

<img src="https://cipi.sh/favicon-light-192.png" width="64" height="64" alt="Cipi logo" />

# Cipi

**Easy Laravel Deployments**  
One command installs a complete production stack. One command deploys your app.<br>
No panel, no bloat — so you can focus on what you love: building your application.

[![MIT License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![GitHub Stars](https://img.shields.io/github/stars/cipi-sh/cipi?style=flat&color=yellow)](https://github.com/cipi-sh/cipi/stargazers)
[![Version](https://img.shields.io/badge/version-4.4.12-green.svg)](https://github.com/cipi-sh/cipi/releases)
[![Ubuntu](https://img.shields.io/badge/Ubuntu-24.04%2B-orange.svg)](https://ubuntu.com)

[Website](https://cipi.sh) · [Docs](https://cipi.sh/docs) · [Report a bug](https://github.com/cipi-sh/cipi/issues)

</div>

---

## What is Cipi?

Cipi turns any Ubuntu VPS into a **multi-app PHP hosting platform** — Laravel by default, with full isolation, zero-downtime deploys, SSL, queue workers, and S3 backups — all managed from a single CLI. Use **`--custom`** for simple sites: classic deploy (no releases/shared), configurable docroot and Nginx (try_files, entry point), no DB or cron.

No web panel. No bloat. No sleepless nights fighting Nginx configs or PHP-FPM pools.  
Just SSH and the `cipi` command.

```bash
$ wget -O - https://cipi.sh/setup.sh | bash
```

> Works on DigitalOcean, AWS EC2, Hetzner, Vultr, Linode, OVH, Google Cloud, Scaleway, and more.

---

## From zero to production in 3 steps

**1. Install Cipi** on a fresh Ubuntu 24.04+ VPS (~10 minutes):

```bash
wget -O - https://cipi.sh/setup.sh | bash
```

**2. Create your app** (Laravel by default, or `cipi app create --custom` for a simple deploy):

```bash
cipi app create
# username, domain, git repo, branch, PHP version
# → Laravel: user, DB, Nginx, workers, cron, webhook
# → Custom: user, Nginx, PHP-FPM; Git optional (empty = SFTP-only to ~/htdocs)
```

**3. Deploy and go live:**

```bash
cipi deploy myapp
cipi ssl install myapp
```

That's it. Your Laravel app is live.

---

## Stack

Every app gets a fully isolated environment. **Laravel** (default): zero-downtime deploy, DB, workers, cron, webhook. **`--custom`**: classic deploy into `htdocs`, configurable docroot only; Nginx uses `index index.html index.php`, `try_files $uri $uri/ /index.php?$args`, `error_page 404 /404.html`. No DB, no .env, no cron, no workers.

| Component          | Details                                                                             |
| ------------------ | ----------------------------------------------------------------------------------- |
| **Web server**     | Nginx reverse proxy with per-app virtual hosts, optimized for Laravel               |
| **PHP & Composer** | Selectable per app — PHP 7.4 to 8.5, hot-swappable                                  |
| **Database**       | MariaDB, auto-tuned to RAM, dedicated DB and user per Laravel app                   |
| **Queue workers**  | Supervisor with per-app pools (Laravel) — add, scale, monitor                       |
| **Deployments**    | Deployer — Laravel: atomic symlink, 5 releases, rollback; Custom: clone into htdocs |
| **SSL**            | Let's Encrypt via Certbot with SAN support and auto-renewal                         |
| **Security**       | Fail2ban + UFW, per-app Linux user + PHP-FPM pool + SSH key                         |
| **Backups**        | Automated DB and storage dumps to S3 or any compatible provider                     |

---

## Features

### 🔒 Security & Isolation by Design

Each app runs under its own Linux user with an isolated filesystem, PHP-FPM pool, and database. A compromise in one app cannot touch the others. Configs are encrypted at rest with AES-256 (Vault). GDPR-compliant log rotation included.

### ⚡ Zero-Downtime Deploys

Deployer clones your repo, runs `composer install`, links storage, runs migrations, and swaps the symlink atomically. Roll back to any of the last 5 releases instantly.

### 🔗 Webhook Auto-Deploy

Native GitHub and GitLab integration — deploy keys and webhooks configured automatically. HMAC signature verification. Or plug in any custom Git provider.

### 📦 App Types

**Laravel** (default) — zero-downtime deploy with releases, shared storage, workers, scheduler, webhook. **`--custom`** — for simple sites (e.g. WordPress, static+PHP): classic deploy into `htdocs` (no current/shared), choose docroot only (e.g. `/`, `www`, `dist`). Nginx: `index index.html index.php`, `try_files $uri $uri/ /index.php?$args`, `error_page 404 /404.html`. No DB, no .env, no cron, no workers, no webhook — just Nginx, PHP-FPM, and deploy key.

### 🌐 Aliases & SSL

Add multiple domains or subdomains to any app. A single SAN certificate covers all of them. Auto-renew handles the rest.

### 🤖 AI Agent Ready (MCP)

Cipi ships with a built-in MCP server. Laravel first: install the `cipi-agent` Laravel package, point your AI client at the endpoint, and deploy, rollback, query logs, and run Artisan commands via natural language — no SSH required.

Works with Claude, Cursor, VS Code, OpenAI, Gemini, and more.

```bash
composer require cipi/agent
```

MCP tools exposed: `health`, `app_info`, `deploy`, `logs`, `db_query`, `artisan`.

### 🔌 REST API (optional)

When you need to manage apps programmatically or integrate with external pipelines, enable the optional API layer with a single command. Bearer tokens, granular permissions, OpenAPI spec available, interactive Swagger docs.

### 🔁 Sync Between Servers

Move entire stacks or single apps between Cipi servers — for migration, failover, or disaster recovery. Archives are encrypted in transit.

---

## Who uses Cipi?

- **Solo developers** — ship Laravel first, without the DevOps overhead
- **Agencies** — one VPS, many isolated client projects (Laravel first), onboard a new client in minutes
- **Startups & SaaS** — atomic deploys, instant rollbacks, grow without changing your workflow
- **Datacenters & automation pipelines** — every Cipi command is a plain shell call, wire it into Ansible or any provisioning script

---

## Requirements

- Ubuntu **24.04 LTS** or higher
- Root access
- Ports **22**, **80**, **443** open

---

## Documentation

Full docs at: **[cipi.sh/docs](https://cipi.sh/docs)**

---

## Contributing

Cipi is open source and MIT licensed. Issues, PRs, and feedback are welcome on [GitHub](https://github.com/cipi-sh/cipi).

---

<div align="center">

Made with ❤️ by [Andrea Pollastri](https://web.ap.it)

</div>

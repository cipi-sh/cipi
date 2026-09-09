<div align="center">

<img src="https://cipi.sh/favicon-light-192.png" width="64" height="64" alt="Cipi logo" />

# Cipi

**Easy Laravel Deployments**  
One command installs a complete production stack. One command deploys your app.<br>
No panel, no bloat — so you can focus on what you love: building your application.

[Website](https://cipi.sh) · [Docs](https://cipi.sh/docs) · [Report a bug](https://github.com/cipi-sh/cipi/issues)

</div>

---

## What is Cipi?

Cipi turns any Ubuntu VPS into a **multi-app PHP hosting platform** — Laravel by default (PHP-FPM or optional **Octane/FrankenPHP**), with full isolation, zero-downtime deploys, SSL, queue workers, and S3 backups — all managed from a single CLI. Use **`--custom`** for simple sites: classic deploy (no releases/shared), configurable docroot and Nginx (try_files, entry point), no DB or cron.

No web panel. No bloat. No sleepless nights fighting Nginx configs or PHP-FPM pools.  
Just SSH and the `cipi` command.

```bash
wget -O - https://cipi.sh/setup.sh | bash
```

> Run this **on the server**, over SSH — not on your own machine — as a user with `sudo`.

> Works on DigitalOcean, AWS EC2, Hetzner, Vultr, Linode, OVH, Google Cloud, Scaleway, and more.

---

## From zero to production in 3 steps

**1. Install Cipi** on a fresh Ubuntu 24.04 or 26.04 VPS (~10 minutes).
SSH into the server first and run it there, as a user with `sudo`:

```bash
wget -O - https://cipi.sh/setup.sh | bash
```

The installer asks for the **public** half of an SSH key (`~/.ssh/id_ed25519.pub`
on your own machine; `ssh-keygen -t ed25519` creates one if you have none — on
Windows, from PowerShell or WSL). It ends by printing a root password: keep it
in a password manager. Root is reachable only by logging in as the `cipi` user
with that key and then running `su root`.

**2. Create your app** (Laravel by default, or `cipi app create --custom` for a simple deploy):

```bash
cipi app create
# username, domain, git repo, branch, PHP version
# → Laravel: user, DB, Nginx, workers, cron, webhook
# → Laravel Octane: cipi app create --octane
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

Every app gets a fully isolated environment. **Laravel** (default): zero-downtime deploy, DB, workers, cron, webhook — optionally **Octane (FrankenPHP)** instead of PHP-FPM. **`--custom`**: classic deploy into `htdocs`, configurable docroot only; Nginx uses `index index.html index.php`, `try_files $uri $uri/ /index.php?$args`, `error_page 404 /404.html`. No DB, no .env, no cron, no workers.

| Component          | Details                                                                                                      |
| ------------------ | ------------------------------------------------------------------------------------------------------------ |
| **Web server**     | Nginx reverse proxy with per-app virtual hosts — PHP-FPM or Octane (`proxy_pass`), optimized for Laravel     |
| **PHP & Composer** | Selectable per app — PHP 7.4 to 8.5, hot-swappable                                                           |
| **Runtime**        | PHP-FPM pools by default; optional **Laravel Octane (FrankenPHP)** per app (`--octane`)                      |
| **Database**       | MariaDB (default) + optional PostgreSQL; dedicated DB and user per Laravel app                               |
| **Queue workers**  | Supervisor with per-app pools — `queue:work` or **Horizon**; optional **Reverb** for WebSockets (wss:// + credentials + fd limits) |
| **Deployments**    | Deployer — Laravel: atomic symlink, 5 releases, rollback, optional Node build; Custom: clone into htdocs     |
| **SSL**            | Let's Encrypt via Certbot — HTTP-01 by default; optional **DNS-01 (Cloudflare)** + wildcards                 |
| **Security**       | Fail2ban + UFW, optional CrowdSec (firewall bouncer) and nightly integrity/upload scan, per-app Linux user + PHP-FPM/Octane + SSH key |
| **Healthchecks**   | HTTP probes every 5 minutes, plus a post-deploy check with optional automatic rollback of a broken release    |
| **Backups**        | Backup profiles: what, how often, where, how long — S3/S3-compatible/local, client-side encryption           |
| **Configuration**  | `cipi ini` for php.ini; optional per-project `cipi.yml` for aliases, databases, workers, Reverb and backups  |

---

## Features

### 🔒 Security & Isolation by Design

Each app runs under its own Linux user with an isolated filesystem, PHP-FPM pool (or Octane process), and database. A compromise in one app cannot touch the others. Configs are encrypted at rest with AES-256 (Vault). GDPR-compliant log rotation included. Per-app **resource limits** (`cipi app limits`) cap FPM children, memory, Octane workers, and queue processes. `cipi app fix-permissions` restores that layout if a deploy or a zip-as-root left the home unreadable.

Optional, off until you turn them on — `setup.sh` / `self-update` never install them:

```bash
cipi crowdsec enable    # IP reputation → firewall bouncer (not a WAF)
                        # includes a TLS rescue URL: one GET allowlists your IP
cipi scan enable        # nightly: release integrity + ClamAV on uploads
```

### ⚡ Zero-Downtime Deploys

Deployer clones your repo, runs `composer install`, links storage, runs migrations, and swaps the symlink atomically. Optional **Node build** on deploy (`cipi app edit --node-build=…`). Roll back to any of the last 5 releases instantly. Opt-in **pre-deploy DB snapshot** (`cipi deploy --snapshot`).

### 💾 Backups That Match How You Actually Work

Backups are driven by **profiles**: each one decides what it takes (application
files, databases, or both), which apps and databases it covers, how often it
runs, where it lands and how long it is kept. A 30-minute database-only copy
kept on disk sits happily next to a nightly full copy encrypted to S3.

```bash
cipi backup profile add hourly-db --scope=db \
    --databases='shop,tenant_*' --exclude-tables='*.jobs,*.telescope_*' \
    --every=30m --keep=48 --dest=local

cipi backup profile add nightly --scope=all \
    --cron='0 2 * * *' --keep-days=14 --dest=s3 --encrypt
```

Databases are discovered from the engine, so tenant databases an app creates at
runtime are backed up too. The schedule is written to root's crontab for you.
`cipi backup verify` checks the newest run actually opens, and an overdue
profile raises an alert — a backup that quietly stopped running is worse than
none, because it still looks configured.

### 📄 cipi.yml — Configuration That Travels With the Code

An app can carry a `cipi.yml` in its repository describing the state it expects:
domain aliases, PHP version and settings, its extra databases, its queue workers,
its healthcheck and its backup strategy. `cipi yml plan` shows exactly what would change and
`cipi yml apply` applies it.

Deploys **ignore the file** until you opt in with `cipi yml auto <app> on`. From
then on every successful deploy reconciles — whether it came from `cipi deploy`
or from the Git webhook — and a release without the file is simply a no-op.

You do not have to write it by hand: `cipi yml generate <app>` prints the app's
current configuration on that server as a ready-to-commit `cipi.yml`.

```bash
cipi yml generate myapp > cipi.yml   # then commit it
cipi yml plan myapp                  # reports nothing to do
```

It can only *configure* an app that already exists, its databases must be named
`<app>` or `<app>_*`, its backup profiles `<app>` or `<app>-*`, its healthcheck
URL one of the app's own domains, and nothing in the schema carries a shell command — so a commit can never reach beyond its
own app. Run `cipi yml example` for a blank commented template.

### 🚀 Laravel Octane (FrankenPHP)

Serve Laravel via Octane instead of PHP-FPM — same server, side by side with classic apps:

```bash
cipi app create --octane
cipi app convert myapp --to=octane   # or --to=fpm
```

Nginx proxies to a localhost Octane port; Supervisor runs `${app}-octane`. Requires `laravel/octane` in the app repo (starts after the first successful deploy).

### 📡 Reverb, Horizon & Scheduler

First-class Laravel extras, all CLI-managed:

```bash
cipi app reverb enable myapp
cipi worker horizon enable myapp
cipi schedule on myapp
```

Enabling Reverb allocates a localhost port, writes a Supervisor program, and proxies the two paths the Pusher protocol uses — `/app/{key}` for the WebSocket and `/apps/{id}/…` for the broadcast API — through Nginx on the app's own domain. It also generates `REVERB_APP_ID/KEY/SECRET` and the `VITE_REVERB_*` copies the frontend build reads, picks `ws://` or `wss://` from whether the app has a certificate (and moves to `wss://` by itself when one is installed later), and raises the file-descriptor limits that otherwise cap a WebSocket server at about a thousand concurrent clients.

An app with its own `/app` or `/apps` route cannot use Reverb behind the same domain — those paths belong to the protocol. Reverb can also be declared in `cipi.yml` as `workers.reverb: true`.

Horizon is mutually exclusive with `queue:work` workers. Scheduler toggles the crontab `schedule:run` entry.

### 🔗 Webhook Auto-Deploy

Native GitHub and GitLab integration — deploy keys and webhooks configured automatically. HMAC signature verification. Or plug in any custom Git provider. If a token expires and keys/webhooks drift, `cipi git refresh` re-registers them on every app (`--rotate-keys` / `--rotate-secret` to mint new material).

### 📦 App Types

**Laravel** (default) — zero-downtime deploy with releases, shared storage, workers, scheduler, webhook; add **`--octane`** for FrankenPHP. **`--custom`** — for simple sites (e.g. WordPress, static+PHP): classic deploy into `htdocs` (no current/shared), choose docroot only (e.g. `/`, `www`, `dist`). Nginx: `index index.html index.php`, `try_files $uri $uri/ /index.php?$args`, `error_page 404 /404.html`. No DB, no .env, no cron, no workers, no webhook — just Nginx, PHP-FPM, and deploy key.

Clone an app for staging with **`cipi app clone <src> --domain=…`**.

### 🌐 Aliases, www & SSL

Add multiple domains or subdomains to any app. A domain can be a **wildcard** (`*.example.com`), as the app's primary domain or as an alias — multi-tenant apps get one vhost for every tenant. Manage www/apex aliases and canonical redirects with **`cipi www`**. A single SAN certificate covers all of them — HTTP-01 by default, or **DNS-01 via Cloudflare** for wildcards (`cipi ssl install --dns=cloudflare --wildcard`). Auto-renew handles the rest.

### ❤️ HTTP Healthchecks

Point Cipi at an HTTP endpoint; it probes every 5 minutes and alerts after consecutive failures:

```bash
cipi health set myapp --url=https://example.com/up --expect=200
```

### 🤖 AI Agent Ready (MCP)

Cipi ships with a built-in MCP server. Laravel first: install the `cipi-agent` Laravel package, point your AI client at the endpoint, and deploy, rollback, query logs, and run Artisan commands via natural language — no SSH required.

Works with Claude, Cursor, VS Code, OpenAI, Gemini, and more.

```bash
composer require cipi/agent
```

MCP tools exposed: `health`, `app_info`, `deploy`, `logs`, `db_query`, `artisan`.

### 🔌 REST API (optional)

When you need to manage apps programmatically or integrate with external pipelines, enable the optional API layer with a single command. Bearer tokens, granular permissions, OpenAPI spec available, interactive Swagger docs.

### 🖥️ Web GUI (optional)

Multi-server control panel for operators who prefer a browser over SSH. Register N Cipi servers with API tokens, switch between them from any page, and manage apps, databases, deploys, SSL, aliases, and logs with Livewire UI and async job overlays. Install with **`cipi gui <domain>`** — requires **`cipi api`** on each managed server. Session login with optional Google Authenticator 2FA.

[GitHub](https://github.com/cipi-sh/gui)

### 🔁 Sync Between Servers

Move entire stacks or single apps between Cipi servers — for migration, failover, or disaster recovery. Archives are encrypted in transit.

### 🖥️ CLI Client

A standalone Go binary that talks to the Cipi REST API from your local machine — no SSH required. Manage apps, databases, SSL, aliases, and deployments from any terminal. Pre-built binaries for Linux and macOS (amd64/arm64).

[Docs](https://cipi.sh/docs/cli-client) · [GitHub](https://github.com/cipi-sh/cli)

### 🛒 WHMCS Module

An official provisioning module that bridges the WHMCS lifecycle to the Cipi REST API — automate app creation, deletion, SSL certificates, deployments, and package changes for your hosting customers. Self-contained drop-in, no Composer dependencies.

[Docs](https://cipi.sh/docs/advanced#whmcs) · [GitHub](https://github.com/cipi-sh/whmcs)

---

## Who uses Cipi?

- **Solo developers** — ship Laravel first, without the DevOps overhead
- **Agencies** — one VPS, many isolated client projects (Laravel first), onboard a new client in minutes
- **Startups & SaaS** — atomic deploys, instant rollbacks, grow without changing your workflow
- **Datacenters & automation pipelines** — every Cipi command is a plain shell call, wire it into Ansible or any provisioning script

---

## Requirements

- Ubuntu **24.04 LTS** or **26.04 LTS** (no other releases)
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

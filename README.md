<div align="center">

<a href="https://cipi.sh">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://cipi.sh/brand/cipi-logo-dark.svg">
    <img src="https://cipi.sh/brand/cipi-logo.svg" alt="Cipi" height="56">
  </picture>
</a>

## Deploy Laravel to servers you own.

One command turns a fresh Ubuntu VPS into a production host for all your Laravel and PHP apps.<br>
Isolated, patched, zero-downtime. No panel needed, no SaaS behind it, no monthly fee.

[![Version](https://img.shields.io/github/v/release/cipi-sh/cipi?label=version&color=111827)](https://github.com/cipi-sh/cipi/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-111827)](LICENSE)
[![Ubuntu 24.04 · 26.04](https://img.shields.io/badge/ubuntu-24.04%20%7C%2026.04-111827)](https://cipi.sh/docs/installation)

<br>

<a href="https://cipi.sh">
  <img alt="A Laravel app going from git push to live with HTTPS on a Cipi server" src="https://cipi.sh/img/blog/hero-live.png" width="860">
</a>

</div>

<br>

## Try it in ten minutes

On a fresh Ubuntu 24.04 or 26.04 server, over SSH:

```bash
wget -O - https://cipi.sh/setup.sh | bash
```

Then ship your app:

```bash
cipi app create          # pick Laravel, a domain and your Git repo
cipi deploy myapp        # atomic release, instant rollback
cipi ssl install myapp   # HTTPS with Let's Encrypt
```

That's it: your app is live. **[Follow the 15-minute guide →](https://cipi.sh/guides/deploy-laravel-ubuntu-vps)**

<br>

## Why people switch to Cipi

|                                   |                                                                                                    |
| --------------------------------- | -------------------------------------------------------------------------------------------------- |
| **Every app in its own box**      | Its own Linux user, PHP-FPM pool, database and Valkey. One hacked site can't read the others.      |
| **Secure from the first boot**    | Key-only SSH, UFW, Fail2ban, optional CrowdSec and Cloudflare Zero Trust. PHP CVEs patched overnight. |
| **Deploys that don't break**      | Releases with a symlink swap, health checks, automatic rollback, deploy on `git push`.             |
| **Settings live in your repo**    | One [`cipi.yml`](https://cipi.sh/cipi-yml) for workers, cron, domains, redirects and backups.      |
| **The whole Laravel stack**       | PHP 8.3 to 8.6, Octane, Horizon, Reverb, Scout with Meilisearch, MariaDB or PostgreSQL, Node frontends. |
| **Backups and alerts built in**   | Encrypted backups to any S3 bucket; alerts on Slack, Telegram, email, Discord and more.             |
| **AI agent ready**                | An [MCP server](https://cipi.sh/mcp) lets Claude or Cursor read logs and deploy, with limits you set. |
| **Yours, end to end**             | MIT licensed, no telemetry, no account. An optional [web GUI](https://cipi.sh/docs/gui) and [REST API](https://cipi.sh/api) if you want them. |

<br>

## Coming from somewhere else?

Honest comparisons with real migration steps: [Laravel Forge](https://cipi.sh/alternative-to-laravel-forge) · [Ploi](https://cipi.sh/alternative-to-ploi) · [Laravel Cloud](https://cipi.sh/alternative-to-laravel-cloud) · [Coolify](https://cipi.sh/alternative-to-coolify) · [cPanel](https://cipi.sh/alternative-to-cpanel) · [all comparisons](https://cipi.sh/alternatives)

<br>

## Requirements

- Ubuntu **24.04 LTS** or **26.04 LTS**, freshly installed
- A KVM/VMware/Hyper-V/Xen VM or bare metal (not OpenVZ, LXC or Docker)
- A user with `sudo`, and ports **22**, **80**, **443** open

Works on Hetzner, DigitalOcean, AWS, Vultr, Linode, OVHcloud, Scaleway, Google Cloud and any other provider that gives you a real VM.

<br>

<div align="center">

### [Read the docs](https://cipi.sh/docs) · [Browse the guides](https://cipi.sh/guides) · [Report a bug](https://github.com/cipi-sh/cipi/issues)

Open source since 2019, MIT licensed. Made in Italy by [Andrea Pollastri](https://web.ap.it).<br>
If Cipi saves you time, a ⭐ helps other people find it.

</div>

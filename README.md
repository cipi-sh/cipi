## Cipi

**Easy Laravel Deployments**  
The open-source server control panel exclusively for Laravel.

<p align="center">
  <img src="https://img.shields.io/badge/dynamic/yaml?url=https%3A%2F%2Fraw.githubusercontent.com%2Fandreapollastri%2Fcipi%2Flatest%2Fversion.md&query=%24&label=version&color=blue" alt="Version">
  <img src="https://img.shields.io/badge/ubuntu-24.04+-orange" alt="Ubuntu">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="License">
  <img src="https://img.shields.io/github/stars/andreapollastri/cipi?style=social" alt="Stars">
</p>

---

**Documentation, guides and full reference at [cipi.sh](https://cipi.sh)**

---

## Install

```bash
wget -O - https://cipi.sh/setup.sh | bash
```

## Quick start

```bash
cipi app create
cipi deploy <app>
cipi ssl install <app>
```

## Git providers

Cipi works with any Git provider that supports SSH deploy keys — no vendor lock-in.

| Provider | Support |
|---|---|
| GitHub | ✓ |
| GitLab | ✓ |
| Gitea | ✓ |
| Forgejo | ✓ |
| Bitbucket | ✓ |
| Any self-hosted / custom Git server | ✓ |

```bash
# show the deploy key and add it to your Git provider
cipi deploy <app> --key

# trust a custom Git server fingerprint (standard port)
cipi deploy <app> --trust-host=git.mycompany.com

# trust a custom Git server on a non-standard port
# (also writes ~/.ssh/config automatically)
cipi deploy <app> --trust-host=git.mycompany.com:2222
```

## Backup

```bash
cipi backup configure              # configure S3 credentials
cipi backup run [app]              # backup DB + shared/ to S3
cipi backup list [app]             # list S3 backups
cipi backup prune [app] --weeks=N  # delete backups older than N weeks
```

## License

MIT — made with ❤️ for Laravel developers by [Andrea Pollastri](https://web.ap.it)

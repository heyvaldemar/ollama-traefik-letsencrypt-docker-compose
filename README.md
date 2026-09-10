# Ollama + Open WebUI + Traefik + Let's Encrypt on Docker Compose

[![Deployment Verification](https://github.com/heyvaldemar/ollama-traefik-letsencrypt-docker-compose/actions/workflows/deployment-verification.yml/badge.svg?branch=main)](https://github.com/heyvaldemar/ollama-traefik-letsencrypt-docker-compose/actions/workflows/deployment-verification.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## Contents

- [Why this stack?](#why-this-stack)
- [Prerequisites](#prerequisites)
- [Getting started](#getting-started)
- [Features](#features)
  - [Typical use cases](#typical-use-cases)
- [GPU support](#gpu-support)
- [Supply chain trust](#supply-chain-trust)
- [Production checklist](#production-checklist)
- [Testing](#testing)
- [Security Notes](#security-notes)
- [About the maintainer](#about-the-maintainer)

This repository deploys Ollama (local LLM runtime) with Open WebUI (chat interface) behind Traefik with automatic Let's Encrypt TLS. One `docker compose up` away from a self-hosted ChatGPT-style service at `https://your-domain`, with the raw Ollama API exposed on port 11434 for programmatic use.

📙 Full narrative installation guide on the blog: [heyvaldemar.com/install-ollama-using-docker-compose/](https://www.heyvaldemar.com/install-ollama-using-docker-compose/).

## Why this stack?

| Need | This stack | Manual install | Kubernetes | Other compose examples |
|------|-----------|----------------|------------|------------------------|
| Ready to deploy in <10 min | ✅ | ❌ hours of setup | ✅ if K8s is already running | Often |
| TLS via Let's Encrypt, auto-renewed | ✅ Traefik ACME built-in | Manual certbot | Via cert-manager | Rare |
| Web chat UI + raw API on one host | ✅ | Separate installs | Varies | Varies |
| Models auto-installed on first start | ✅ configurable list | Manual `ollama pull` | Init containers | Rare |
| Upstream images pinned by `sha256` digest | ✅ | N/A | Depends | Rare |
| Weekly pin-freshness check in CI | ✅ | N/A | Depends | Rare |
| CI-verified deployment on every push | ✅ | N/A | Varies | Rare |
| Credentials via env (never committed) | ✅ | N/A | K8s Secrets | Often committed plaintext |

Three moving parts (Traefik + Ollama + Open WebUI). No Kubernetes prerequisites, no manual certificate management.

## Prerequisites

Before you start, you need:

- **A Linux server** with a public IP. Tested on Ubuntu 22.04 LTS+ and Debian 12+. Local Mac/Windows works for dev; production is Linux.
- **Docker Engine 24+ and Docker Compose 2.20+.** Quick check: `docker version` and `docker compose version`.
- **A domain you control,** with two `A` records pointing at your server's public IP: one for Open WebUI (e.g. `ollama.example.com`), one for the Traefik dashboard (e.g. `traefik.ollama.example.com`). DNS must propagate before deploy or the Let's Encrypt TLS-ALPN challenge will fail.
- **Ports 80, 443, and 11434 open** on the server's firewall. 11434 serves the raw Ollama API through Traefik's TCP entrypoint. Close it if you only need the web UI.
- **Disk for models.** The default `OLLAMA_INSTALL_MODELS=llama3,codegemma,mistral` downloads roughly 12 GB on first start. Set the variable to an empty value in `.env` to skip automatic model installation, or list only the models you need.
- **RAM/CPU sized to your models.** 8 GB RAM runs 7-8B quantized models on CPU; a GPU changes everything (see [GPU support](#gpu-support)).

## Getting started

```bash
# 1. Clone
git clone https://github.com/heyvaldemar/ollama-traefik-letsencrypt-docker-compose
cd ollama-traefik-letsencrypt-docker-compose

# 2. Create the two Docker networks the stack expects
docker network create traefik-network
docker network create ollama-network

# 3. Copy the environment template and fill in required values
cp .env.example .env
$EDITOR .env
# ^ Required: OLLAMA_HOSTNAME, TRAEFIK_HOSTNAME, TRAEFIK_ACME_EMAIL,
#   TRAEFIK_BASIC_AUTH. See .env.example for generation commands.

# 4. Deploy
docker compose -f ollama-traefik-letsencrypt-docker-compose.yml -p ollama up -d
```

Within a minute or two `https://${OLLAMA_HOSTNAME}` serves Open WebUI with a fresh Let's Encrypt certificate; the first account you register becomes the admin. Model downloads continue in the background if `OLLAMA_INSTALL_MODELS` is set.

### What success looks like

```bash
# All three services should report as healthy / up:
docker compose -f ollama-traefik-letsencrypt-docker-compose.yml -p ollama ps

# The Ollama API answers through the Traefik TCP entrypoint:
curl -fsS http://localhost:11434/api/version
# Expected: {"version":"0.34.0"}

# Model installation progress:
docker compose -p ollama logs ollama | grep -i pull

# Traefik issued a certificate:
docker compose -p ollama logs traefik | grep -i "adding certificate"
```

### Common first-deploy issues

- **Cert issuance fails.** DNS hasn't propagated or port 80 isn't reachable from the internet. Confirm with `dig +short ${OLLAMA_HOSTNAME}` and `curl -I http://${OLLAMA_HOSTNAME}` from outside the server.
- **`docker compose up` fails with `set in .env`.** A required variable is empty; the error names it. Generate values per the comments in `.env.example`.
- **`network ollama-network not found`.** Step 2 was skipped.
- **First responses are slow.** The model loads into RAM on first inference after each idle unload. This is Ollama behavior, not a stack problem.

### Apply `.env` or compose-file changes

```bash
docker compose -f ollama-traefik-letsencrypt-docker-compose.yml -p ollama up -d --force-recreate
```

## Features

- **Ollama** latest stable (0.34.0) with automatic model installation from a configurable list.
- **Open WebUI** (0.11 line): multi-user chat interface with per-user history; first registered account becomes admin.
- **Traefik v3** reverse proxy with automatic HTTP→HTTPS redirect and Let's Encrypt TLS-ALPN certificate issuance.
- **Raw Ollama API** published through a dedicated Traefik TCP entrypoint on port 11434 for OpenAI-compatible programmatic access.
- **Basic-auth protected Traefik dashboard** on a separate hostname.
- **Healthchecks** on every service with start-order dependencies.
- **Credentials required at deploy time**: compose fails fast if `.env` is incomplete.

### Typical use cases

- **Private ChatGPT alternative**: chat with local models; prompts and history never leave your server.
- **LLM API backend for development**: point OpenAI-compatible SDKs at `http://your-server:11434` without cloud API costs.
- **Team inference server**: one GPU box, many users through Open WebUI accounts.
- **Model evaluation sandbox**: pull and compare models with `docker exec -it <ollama-container> ollama pull <model>`.

## GPU support

The compose file ships with a commented NVIDIA GPU block on the `ollama` service. To enable it: install the [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html) on the host, uncomment the `deploy.resources.reservations.devices` block, and set `OLLAMA_GPU_COUNT` in `.env` (default `all`). Recreate the stack afterwards. Without a GPU the stack runs fully on CPU, slower, but functional for small quantized models.

## Supply chain trust

This repository is a deployment template, not a custom Docker image. It orchestrates three upstream images:

- [`traefik`](https://hub.docker.com/_/traefik): reverse proxy, Docker Hub official image
- [`ollama/ollama`](https://hub.docker.com/r/ollama/ollama): Ollama upstream
- [`ghcr.io/open-webui/open-webui`](https://github.com/open-webui/open-webui/pkgs/container/open-webui): Open WebUI upstream

All three are pinned to `tag@sha256:<digest>` as interpolation defaults in the compose file's `x-images` block. Compose pulls by digest, not by tag, and `git pull` alone delivers the version combination this repository has tested, because the pins live in the tracked compose file rather than in your `.env`. Setting `TRAEFIK_IMAGE_TAG`, `OLLAMA_IMAGE_TAG`, or `WEBUI_IMAGE_TAG` in `.env` overrides the default when you deliberately want a different version.

Two override levels exist per image. `<PREFIX>_IMAGE_VERSION` in `.env` swaps only the version of that image (Compose then pulls the tag, without a digest) and leaves every other pin as tested; `<PREFIX>_IMAGE_TAG` replaces the whole reference, digest included. The variable names are listed in `.env.example`. Nested defaults need Docker Compose v2.5 or newer (2022); v2.0 to v2.4 leave the inner `${...}` unexpanded and `docker compose up` fails with an invalid reference instead of deploying something unexpected.

The daily `check-pin-freshness` CI job re-resolves each pinned tag against its registry and compares the pinned Ollama, Open WebUI, and Traefik versions against the latest upstream releases: any drift fails the run and notifies the maintainer. CI's Deployment Verification workflow runs on every push, pull request, and every day at 06:00 UTC. GitHub Actions are pinned by commit SHA; Dependabot's `github-actions` ecosystem keeps those fresh.

## Production checklist

Before exposing this to real users, check every box:

- [ ] **Register the admin account first.** Open WebUI grants admin to the first registered user. Do it before sharing the URL, then disable open sign-ups in Open WebUI's admin settings if the instance is not meant to be public.
- [ ] **Decide about port 11434.** The raw Ollama API has no authentication of its own. If you only need the web UI, close 11434 on your firewall; if you need the API, restrict source IPs.
- [ ] **Strong Traefik dashboard hash.** Regenerate `TRAEFIK_BASIC_AUTH` per deployment (command in `.env.example`).
- [ ] **Size your models to your RAM/VRAM.** A model that does not fit forces heavy swapping or OOM kills.
- [ ] **Verify Let's Encrypt cert issuance** in the Traefik logs on first start.
- [ ] **Plan model storage.** Models live in the `ollama-data` volume; back it up or accept re-downloading models after host loss.

## Unattended updates

Releases are the update channel: a tag is cut only after CI has built the pinned images, booted the full stack, and passed the smoke tests. `update.sh` moves a deployment to the newest tag and nothing else:

```bash
./update.sh --dry-run   # show what would be applied
./update.sh             # update within the current major and redeploy
```

Put it on a timer for hands-off minor/patch updates:

```bash
# crontab -e
17 5 * * *  /opt/ollama-traefik-letsencrypt-docker-compose/update.sh >> /var/log/ollama-update.log 2>&1
```

The script refuses to cross a MAJOR template version on its own: majors are breaking by definition and their release notes exist to be read. After reading them, `./update.sh --allow-major` performs the jump. It also refuses to touch a checkout with local modifications: your customization belongs in `.env`, which updates never overwrite.

This is deliberately a host-side script and not a container in the stack: an in-stack updater needs the Docker socket (root on the host) and turns "someone pushed to a repo" into "someone deployed to your machine" with no operator in the loop. A cron job under your own user updates only to tagged, CI-verified states and leaves the trust boundary where it was.

## Backups

The `backups` container runs on a loop: an initial delay (`OPEN_WEBUI_BACKUP_INIT_SLEEP`, default 30m), then every `OPEN_WEBUI_BACKUP_INTERVAL` (default 24h) it takes a consistent copy of each SQLite database (`webui.db`) through Python's `sqlite3` backup API - no application stop - and a `tar.gz` of the rest of the data directory (live database files excluded), into the `open-webui-backups` volume; files older than `OPEN_WEBUI_BACKUP_PRUNE_DAYS` (default 7) are pruned. Each artefact logs `... backup OK: <file> (<bytes> bytes)` or `FAILED` (kept as `<file>.failed`). Grep the log for `FAILED` from your monitoring.

**Verify backups are running:**

```bash
docker compose -p open-webui logs backups | tail -5
docker compose -p open-webui exec backups ls -la /srv/open-webui/backups/
```

**Restore** a backup set with the interactive script (`chmod +x open-webui-restore-data.sh` once): it stops open-webui, unpacks the data archive over the data directory, restores each database from its consistent copy, and starts open-webui again.

```bash
./open-webui-restore-data.sh
```

**Off-host replication.** Backups live in a named volume on the same host. Bind-mount `OPEN_WEBUI_BACKUPS_PATH` to a directory covered by your off-host backup solution (restic, rclone, Borg, S3 sync).

## Container hardening

Every service runs with `security_opt: no-new-privileges:true`, so a process cannot gain privileges through setuid binaries even if it escapes its initial capability set. Infrastructure containers (the reverse proxy, databases, caches, backups) run with `cap_drop: [ALL]` and add back only what their entrypoints need: `NET_BIND_SERVICE` for Traefik to bind :80/:443, `CHOWN`/`SETUID`/`SETGID` (and friends) for database images to own their data directory and drop to their service user. Application containers keep the default capability set on purpose: upstream images assume it, and a wrong guess there is a boot loop in production rather than a hardening win. CI boots the stack under exactly these settings on every push, so what ships is what was tested.

## Testing

The [Deployment Verification](https://github.com/heyvaldemar/ollama-traefik-letsencrypt-docker-compose/actions/workflows/deployment-verification.yml?query=branch%3Amain) workflow runs on every push, pull request, and every day at 06:00 UTC:

1. **Lint**: shellcheck on `entrypoint.sh`, actionlint on the workflow.
2. **Trivy scans** of all three pinned images (CRITICAL/HIGH, SARIF to the Security tab).
3. **Pin freshness** (daily/manual): digest drift against registries plus release-lag checks for Ollama, Open WebUI, and Traefik.
4. **Deploy-and-test**: boots the full stack with ephemeral credentials (model download skipped in CI), then requires the Ollama API (`/api/version`) to answer through the Traefik TCP entrypoint and the Open WebUI front page to answer 200 through HTTPS before the run may pass.

A green run is the authoritative proof that the shipped configuration produces a working instance, not just started containers.

### Backup and restore, proven

`tests/e2e-backup-restore.sh` runs against the live stack and is what CI executes after the smoke test. The scenario that matters most is the restore roundtrip: the application is stopped, the baseline database copy is put back, and a row inserted after the baseline is gone. The tests stop the application briefly and write into its data directory. Run them on a staging copy with short intervals in `.env` (`OPEN_WEBUI_BACKUP_INIT_SLEEP=15s`, `OPEN_WEBUI_BACKUP_INTERVAL=60s`), never on production.

```bash
chmod +x tests/e2e-backup-restore.sh
./tests/e2e-backup-restore.sh
```

## Security notes

- Credentials are read from `.env` at deploy time; `.env` is gitignored and the compose file fails fast on missing required variables.
- The raw Ollama API on 11434 is unauthenticated by design (upstream behavior). Treat network access to that port as full access to your models.
- Upstream image digests are pinned; the daily freshness job flags drift loudly.
- CI runs on every push and every day to catch upstream drift.

---

## About the maintainer

<div align="center">

**Maintained by [Vladimir Mikhalev](https://github.com/heyvaldemar)** · Docker Captain · IBM Champion · AWS Community Builder

[YouTube](https://www.youtube.com/channel/UCf85kQ0u1sYTTTyKVpxrlyQ?sub_confirmation=1) · [Blog](https://heyvaldemar.com) · [LinkedIn](https://www.linkedin.com/in/heyvaldemar/)

</div>

# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_(no unreleased changes yet)_

## [1.2.0] - 2026-09-02

### Added

- **A `backups` service** for Open WebUI's users, chats and settings (models in ollama-data are re-downloadable and are not backed up): on a loop it takes a consistent copy of each SQLite database (`webui.db`) through Python's `sqlite3` backup API - no application stop - and a `tar.gz` of the rest of the data directory (live database files excluded), logs `OK` or `FAILED` per artefact (a failed archive is kept as `.failed`), and prunes only its own files. Schedule knobs (`OPEN_WEBUI_BACKUP_INIT_SLEEP`, `OPEN_WEBUI_BACKUP_INTERVAL`, `OPEN_WEBUI_BACKUP_PRUNE_DAYS`, path and names) have defaults listed in `.env.example`.
- **`open-webui-restore-data.sh`** — interactive restore of a backup set: stops open-webui, unpacks the data archive, restores each database copy, starts open-webui.
- CI waits for the first backup cycle and proves the archives are readable and the database copy passes `PRAGMA integrity_check`.

## [1.1.0] - 2026-09-02

### Added

- **`update.sh`** — unattended updates to the newest tagged release,
  and nothing else: a tag is cut only after CI has booted the pinned
  images and passed the smoke tests, so "update to the latest tag" means
  "update to a combination a machine has already run". It refuses to
  cross a major version on its own (`--allow-major` after reading the
  notes), refuses a checkout with local modifications, and supports
  `--dry-run`. Put it on a cron timer for hands-off minor/patch updates.

## [1.0.0] - 2026-08-31

First semver release. Brings this template to the fleet standard established
in [keycloak-traefik-letsencrypt-docker-compose](https://github.com/heyvaldemar/keycloak-traefik-letsencrypt-docker-compose)
v1.2.0.

### Security

- **Ollama bumped 0.16.1 → 0.33.2**, **Open WebUI v0.8.3 → 0.11 line**,
  **Traefik 3.2 → 3.7** — Traefik 3.2's Docker client cannot talk to
  Docker Engine 29 (provider retry loop, silent 404s). This repo carried a
  `DOCKER_API_VERSION=1.47` workaround for exactly that problem; the real
  fix is the version bump, so the workaround is removed.
- **All three images pinned by `tag@sha256:digest`.**
- `.env` untracked and gitignored; `.env.example` documents every value.

### Changed

- **Image pins live in the compose file as interpolation defaults**
  (`x-images` block): `git pull` alone delivers the tested version
  combination; `.env` carries only hostnames, credentials, and deliberate
  overrides.

### Added

- **Deployment Verification workflow**: shellcheck + actionlint; Trivy
  scans of all three pinned images; weekly `check-pin-freshness` (digest
  drift + Ollama/Open WebUI/Traefik release lag); deploy-and-test that
  requires the Ollama API (`/api/version`) through the Traefik TCP
  entrypoint and the Open WebUI front page through HTTPS.

### Fixed

- Quoting in `entrypoint.sh` model-pull loop.

[Unreleased]: https://github.com/heyvaldemar/ollama-traefik-letsencrypt-docker-compose/compare/v1.2.0...HEAD
[1.2.0]: https://github.com/heyvaldemar/ollama-traefik-letsencrypt-docker-compose/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/heyvaldemar/ollama-traefik-letsencrypt-docker-compose/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/heyvaldemar/ollama-traefik-letsencrypt-docker-compose/releases/tag/v1.0.0

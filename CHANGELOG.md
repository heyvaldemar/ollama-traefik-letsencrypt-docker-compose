# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_(no unreleased changes yet)_

## [1.5.0] - 2026-09-04

### Fixed

- **A backup interrupted halfway no longer looks like a good one.** The loop
  already renamed a failed dump to `.failed` so nothing would restore from it,
  but that rename only runs if the shell lives long enough to reach it. Stop
  the container mid-dump and it does not: the truncated file keeps the name a
  finished backup would have, and it is the newest one, which is exactly what
  the restore script and the end-to-end test pick. Every backup is now written
  to `<name>.partial` and renamed only after the dump succeeds, so the real
  name never exists unless the file behind it is complete. Verified by killing
  a dump in flight: before, the restore path selected a file that failed
  `gzip -t`; after, it finds nothing to select.

## [1.4.1] - 2026-09-04

### Changed

- `ollama/ollama` 0.33.2 to 0.33.3. Found by the daily freshness check.

## [1.4.0] - 2026-09-03

### Added

- **Per-image version overrides.** Every pin in the `x-images` block is
  now `${<PREFIX>_IMAGE_TAG:-repo:${<PREFIX>_IMAGE_VERSION:-tag@sha256:digest}}`.
  Set `<PREFIX>_IMAGE_VERSION` in `.env` to run a different version of one
  image while every other pin stays as tested (Compose pulls that tag
  without a digest), or `<PREFIX>_IMAGE_TAG` to replace the whole
  reference as before. A deployment that sets neither is unchanged. The
  freshness job, the Trivy matrix and the fleet digest automation resolve
  the nested default before reading a pin. Needs Docker Compose v2.5 or
  newer (2022): v2.0 to v2.4 leave the inner `${...}` unexpanded and
  `docker compose up` fails with an invalid reference instead of
  deploying something unexpected.

## [1.3.0] - 2026-09-02

### Security

- **Container hardening.** Every service runs with
  `security_opt: no-new-privileges:true` (no privilege escalation via
  setuid binaries even if a process escapes its initial capability
  set). Infrastructure containers (the reverse proxy, databases,
  caches, backups) drop every Linux capability and add back only what
  their entrypoints need (bind :80/:443, chown a data directory, drop to
  the service user). Application containers keep the default capability
  set: upstream images assume it, and a wrong guess there is a boot loop
  in production, not a hardening win. CI boots the stack under these
  settings on every push.

### Added

- **`tests/e2e-backup-restore.sh`**: scenarios against the live stack,
  run by CI on every push: the required-variable guard fires, a backup
  set is produced, the archive is readable, the database copy passes `PRAGMA integrity_check`, a cycle that cannot
 write its archive is reported as `FAILED`, **restore 
  replaces the data** (the application is stopped, the baseline database copy is put back, and a row inserted after the baseline is gone), and pruning removes only old files.

## [1.2.0] - 2026-09-02

### Added

- **A `backups` service** for Open WebUI's users, chats and settings (models in ollama-data are re-downloadable and are not backed up): on a loop it takes a consistent copy of each SQLite database (`webui.db`) through Python's `sqlite3` backup API - no application stop - and a `tar.gz` of the rest of the data directory (live database files excluded), logs `OK` or `FAILED` per artefact (a failed archive is kept as `.failed`), and prunes only its own files. Schedule knobs (`OPEN_WEBUI_BACKUP_INIT_SLEEP`, `OPEN_WEBUI_BACKUP_INTERVAL`, `OPEN_WEBUI_BACKUP_PRUNE_DAYS`, path and names) have defaults listed in `.env.example`.
- **`open-webui-restore-data.sh`**: interactive restore of a backup set: stops open-webui, unpacks the data archive, restores each database copy, starts open-webui.
- CI waits for the first backup cycle and proves the archives are readable and the database copy passes `PRAGMA integrity_check`.

## [1.1.0] - 2026-09-02

### Added

- **`update.sh`**: unattended updates to the newest tagged release,
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

- **Ollama bumped 0.16.1 → 0.33.2**, Open WebUI v0.8.3 → 0.11 line,
  **Traefik 3.2 → 3.7**: Traefik 3.2's Docker client cannot talk to
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

[Unreleased]: https://github.com/heyvaldemar/ollama-traefik-letsencrypt-docker-compose/compare/v1.5.0...HEAD
[1.5.0]: https://github.com/heyvaldemar/ollama-traefik-letsencrypt-docker-compose/compare/v1.4.1...v1.5.0
[1.4.1]: https://github.com/heyvaldemar/ollama-traefik-letsencrypt-docker-compose/compare/v1.4.0...v1.4.1
[1.4.0]: https://github.com/heyvaldemar/ollama-traefik-letsencrypt-docker-compose/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/heyvaldemar/ollama-traefik-letsencrypt-docker-compose/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/heyvaldemar/ollama-traefik-letsencrypt-docker-compose/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/heyvaldemar/ollama-traefik-letsencrypt-docker-compose/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/heyvaldemar/ollama-traefik-letsencrypt-docker-compose/releases/tag/v1.0.0

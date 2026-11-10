# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/) and this project adheres to
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.1.2] - 2026-11-10

### Fixed

- The builder stage no longer does a fresh pip resolve against a moving
  `main`. Upstream is now pinned to commit `80c97785bf552ee50f82e5d5088bed5bdccb7704`
  (RT #1564); its committed `uv.lock` is exported for the `sqlite` extra with
  `uv export --frozen --no-dev --no-emit-project --extra sqlite` and installed
  with `--no-deps`, then the project itself is installed `--no-deps` on top of
  that locked set. Torch isn't in the `sqlite` extra's lock closure (upstream
  keeps it under the separate `[ml]` extra), so it is still installed
  explicitly from PyTorch's CPU index, but now pinned to `torch==2.14.1` --
  the exact version named in upstream's lock for `[ml]` -- with `--no-deps`.

## [1.1.1] - 2026-10-28

### Fixed

- `/app/backups` is no longer a volume, and `MCP_BACKUP_ENABLED=false` turns
  off the in-app backup scheduler. The scheduler only starts in `--http` mode,
  so with `--rm` and `--streamable-http` podman created an empty anonymous
  volume on every start and threw it away on stop. Host backups (pbs,
  `sqlite3 .backup`) are the only backup path (RT #1537).

## [1.1.0] - 2026-10-22

### Changed

- Rebuilt on upstream mcp-memory-service v12.2.1 (was v11.8.5). The upgrade
  brings upstream's security fixes (GHSA-9x7v-2vjj-xghg, certifi
  GHSA-6q48-6c7w-9gw2) and schema migrations 016–019, which run on first start.
- Added the per-repo constitution as a v1.18.0 manifest (Forked MCP Server):
  upstream, deployment, patches and deviations only.
- Constitution validation pinned to v1.18.0 via `constitution.yml`.
- Dependabot auto-merges GitHub Actions minor and patch updates.
- Added `LICENSE` (Apache-2.0, upstream's license).

### Fixed

- The hybrid health check no longer reports `syncing` while every Cloudflare
  call fails: it now reports `sync_failing` and exposes `cloudflare_available`
  and `consecutive_failures` (#3).

## [1.0.0] - 2026-09-20

First tagged release. This image has been running in production since before
it had version control; this release marks the current state as the baseline
going forward.

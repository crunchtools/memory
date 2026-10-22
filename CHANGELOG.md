# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/) and this project adheres to
[Semantic Versioning](https://semver.org/).

## [Unreleased]

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

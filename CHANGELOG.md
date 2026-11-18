# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/) and this project adheres to
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed

- `MCP_MEMORY_BASE_DIR` is now set explicitly to `/app/state`, a directory
  created in the builder stage under the runtime user. Unset, upstream's
  `config/base.py` derives the base directory from `$HOME`, which is `/tmp`
  in this image, giving `/tmp/.local/share/mcp-memory` — inside the
  root-owned `/tmp/.local` that holds the pip `--user` install. That only
  ever worked because a dependency's install left a 65532-owned
  `/tmp/.local/share` behind as a side effect. The v12.11.0 dependency set
  does not, and `config/base.py` calls `sys.exit(1)` when it cannot create
  the directory, so the server exited at import with "Fatal error
  initializing paths" the moment anything imported config. Caught locally on
  the 12.11.0 build before it shipped (RT #1655).

### Changed

- Rebuilt on upstream mcp-memory-service v12.11.0 (was v12.2.1). The upgrade
  brings upstream's HLC-based peer sync — `storage/sync/` and
  `storage/remote_http.py` as a peer adapter, with a `/sync/{force,status,
  pause,resume,capabilities}` control plane — which is what RT #1655 needs to
  split work memory from personal memory at the storage layer. Sync is
  scheduled in-process and opt-in: `MCP_SYNC_SCHEDULE=15m` runs pull + push
  against each peer in `MCP_SYNC_PEERS` (ADR-0028), which supersedes the
  manual-invocation-only state of ADR-0026, so no external timer is needed.
  Both the control plane and that scheduler live in the FastAPI app, and the
  CLI only starts that app under `--http` — under `--sse`,
  `--streamable-http` or stdio the server runs the bare MCP path, where
  `/api/sync/*` 404s and the scheduler never starts.
- A syncing instance runs `--http` with `MCP_HTTP_HOST` and `MCP_HTTP_PORT`
  set, and is **not** the fleet's MCP endpoint. `--http` binds those two
  variables (defaults `127.0.0.1:8000`) and ignores `--sse-host` and
  `--sse-port`, so leaving them unset silently yields a loopback-only server
  on the wrong port. The MCP router it mounts is a JSON-only shim pinned to
  protocol `2024-11-05`, not the Streamable HTTP transport the gateway
  speaks, so fleet clients stay on `--streamable-http` as the deployed units
  already pass. Sync and fleet traffic are separate instances, not one
  process serving both.
- The build takes **upstream direct** instead of going through the
  [fatherlinux](https://github.com/fatherlinux/mcp-memory-service) fork. That
  fork existed to carry one patch — the hybrid health check reporting
  `sync_failing` (#3) — and upstream now carries it verbatim, comments
  included. `UPSTREAM_COMMIT` is doobidoo's v12.11.0 tag,
  `112d881c03268fe791d3a7f3d5e277cbe56174b2`.
- `torch` bumped 2.14.1 → 2.15.0 to track the version named in upstream's lock
  for `[ml]`, still taken from PyTorch's CPU index with `--no-deps`. The
  `sqlite` extra's lock now resolves `onnxruntime==1.31.1` (was 1.24.3); the
  two independent guards against the HUM-6564 telemetry segfault (a populated
  `/etc/machine-id` and `ORT_DISABLE_TELEMETRY`) are unchanged and still
  required.
- Constitution manifest to 1.1.0: upstream is pinned and fork-free, the
  Patches section is empty, and the Cloudflare credentials and "Cloudflare is
  a backup, not a peer" topology note are gone — D1 and Vectorize were deleted
  and the token revoked in RT #1653.

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

# memory Constitution

> **Version:** 1.1.0
> **Ratified:** 2026-10-02
> **Status:** Active
> **Inherits:** [crunchtools/constitution](https://github.com/crunchtools/constitution) v1.46.0
> **Profile:** Forked MCP Server

This file holds what is specific to the memory image. The fleet rules and the
Forked MCP Server profile apply at the inherited version and are checked
against this repo's files by `constitution.yml`. They are not restated here.

## Upstream

- **Source:** https://github.com/doobidoo/mcp-memory-service, built direct from
  upstream — no fork in the build path
- **License:** Apache-2.0
- **Pinned at:** upstream v12.11.0
  (`112d881c03268fe791d3a7f3d5e277cbe56174b2`), named by `UPSTREAM_COMMIT` in
  the Containerfile. The [fatherlinux](https://github.com/fatherlinux/mcp-memory-service)
  fork was retired from the build in RT #1655 once upstream carried its only
  patch; it remains as history, not as a source

This is a packaging repo: the source is fetched at build time, so the repo
holds only the Containerfile, the workflows and this file.

## Deployment

- **Port:** 8765 (same inside and outside the container, bound to 127.0.0.1)
- **Env file:** `mcp-memory.env`, delivered from the secret store to
  `/run/srv-secrets/<service>/` for the Streamable HTTP deployment, or
  `~/.config/mcp-env/` for a local SSE instance
- **Credentials:** MCP_API_KEY (Streamable HTTP gate), and
  MCP_SYNC_PEER_API_KEY where peer sync is configured; backend chosen by
  MCP_MEMORY_STORAGE_BACKEND, which is `sqlite_vec` everywhere this image is
  deployed

The SQLite database lives in the `/app/sqlite_db` volume, bind-mounted from
the host. Backups are the host's job (pbs stages it with `sqlite3 .backup`),
so the in-app scheduler is off (`MCP_BACKUP_ENABLED=false`) and
`/app/backups` is not a volume. The image holds the
whole memory corpus at runtime, so telemetry is off
(`HF_HUB_DISABLE_TELEMETRY`, `ORT_DISABLE_TELEMETRY`, `DO_NOT_TRACK`). The
Cloudflare backends are no longer used anywhere: D1 and Vectorize were deleted
and the token revoked in RT #1653.

## Patches

None. The one patch this image used to carry — the hybrid health check
reporting `cloudflare_sync: sync_failing` when the sync loop runs but
Cloudflare is unreachable (crunchtools/memory#3,
fatherlinux/mcp-memory-service#1) — is in upstream verbatim as of v12.11.0,
which is why the build no longer goes through the fork.

The Containerfile carries two packaging workarounds. A populated
`/etc/machine-id` is baked into the runtime image because onnxruntime's
telemetry falls back to `popen("blkid")` and segfaults on a shell-less image
(onnxruntime#32173); an absent or empty file still crashes, so keep it
populated. And `MCP_MEMORY_BASE_DIR` is set explicitly to `/app/state`,
created in the builder stage under the runtime user, because upstream derives
that directory from `$HOME` — `/tmp` here — and `config/base.py` exits 1 when
it cannot create it. Neither may be dropped without re-testing a real boot.

## Deviations

- **Image name and registries.** The image is `quay.io/crunchtools/memory`,
  not `mcp-memory`; the name predates the profile and renaming would break
  running deployments. Quay.io is the only registry.
- **Base image.** The Hummingbird Python image is pulled from
  `registry.access.redhat.com/hi/python:3.14` (builder and runtime), pinned
  to Python 3.14, rather than `quay.io/hummingbird/python:latest`. The builder
  stage installs `libgomp` and `libstdc++`, which onnxruntime and numpy load,
  and the runtime copies them in.
- **Peer sync needs `--http`.** Upstream's HLC-based peer sync
  (`storage/sync/`, `storage/remote_http.py` as the peer adapter) arrives with
  v12.11.0 and is what RT #1655 builds the work/personal split on. Its
  `/api/sync/*` control plane and its opt-in scheduler
  (`MCP_SYNC_SCHEDULE`, ADR-0028) both live in the FastAPI app, and
  `cli/main.py` starts that app only under `--http`; every other transport
  runs the bare MCP server, where the endpoints 404 and the scheduler never
  starts. `--http` also mounts the MCP-over-HTTP router, so a syncing
  deployment serves MCP and REST from the one process. The image's default
  CMD is still SSE, which does not sync.

## History

| Version | Date | Changes |
|---------|------|---------|
| 1.0.0 | 2026-10-02 | Initial manifest under constitution v1.18.0 |
| 1.0.1 | 2026-10-28 | Backups owned by the host; `/app/backups` volume dropped (RT #1537) |
| 1.1.0 | 2026-11-18 | Built direct from upstream v12.11.0, fork retired, patches empty; Cloudflare credentials and topology claims removed (RT #1653, #1655) |

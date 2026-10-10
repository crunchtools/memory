# memory Constitution

> **Version:** 1.0.0
> **Ratified:** 2026-10-02
> **Status:** Active
> **Inherits:** [crunchtools/constitution](https://github.com/crunchtools/constitution) v1.22.0
> **Profile:** Forked MCP Server

This file holds what is specific to the memory image. The fleet rules and the
Forked MCP Server profile apply at the inherited version and are checked
against this repo's files by `constitution.yml`. They are not restated here.

## Upstream

- **Source:** https://github.com/doobidoo/mcp-memory-service, built from the
  `main` branch of the [fatherlinux/mcp-memory-service](https://github.com/fatherlinux/mcp-memory-service)
  fork
- **License:** Apache-2.0
- **Forked at:** fork reset to upstream v11.8.2+ on 2026-08-30; the
  Containerfile downloads the fork's `main` tarball, and `SOURCE_VERSION` is
  bumped to force a rebuild when it moves

This is a packaging repo: the source is fetched at build time, so the repo
holds only the Containerfile, the workflows and this file.

## Deployment

- **Port:** 8765 (same inside and outside the container, bound to 127.0.0.1)
- **Env file:** `mcp-memory.env`, under `/srv/<service>/config/` for the
  Streamable HTTP deployment or `~/.config/mcp-env/` for a local SSE instance
- **Credentials:** CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID,
  CLOUDFLARE_D1_DATABASE_ID, CLOUDFLARE_VECTORIZE_INDEX (hybrid or cloudflare
  backend), MCP_MEMORY_API_KEY (Streamable HTTP gate); backend chosen by
  MCP_MEMORY_STORAGE_BACKEND

The SQLite database and backups live in the `/app/sqlite_db` and
`/app/backups` volumes, bind-mounted from the host. The image holds the
whole memory corpus at runtime, so telemetry is off
(`HF_HUB_DISABLE_TELEMETRY`, `ORT_DISABLE_TELEMETRY`, `DO_NOT_TRACK`). One
authoritative instance; Cloudflare is a backup, not a peer.

## Patches

None to upstream code since 2026-08-30. The Containerfile carries one
packaging workaround: a populated `/etc/machine-id` is baked into the
runtime image because onnxruntime's telemetry falls back to `popen("blkid")`
and segfaults on a shell-less image (onnxruntime#32173). An absent or empty
file still crashes; keep it populated.

## Deviations

- **Image name and registries.** The image is `quay.io/crunchtools/memory`,
  not `mcp-memory`, and `container.yml` also pushes `ghcr.io/crunchtools/memory`.
  Both predate the profile; renaming would break running deployments.
- **Base image.** The Hummingbird Python image is pulled from
  `registry.access.redhat.com/hi/python:3.12` (builder and runtime), pinned
  to Python 3.12, rather than `quay.io/hummingbird/python:latest`. The builder
  stage installs `libgomp` and `libstdc++`, which onnxruntime and numpy load,
  and the runtime copies them in.
- **Unpinned source.** The build takes the fork's `main` rather than a tag,
  so a rebuild can pick up upstream changes.

## History

| Version | Date | Changes |
|---------|------|---------|
| 1.0.0 | 2026-10-02 | Initial manifest under constitution v1.18.0 |

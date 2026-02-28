# MCP Memory Service Container

Container image for [mcp-memory-service](https://github.com/doobidoo/mcp-memory-service) with Streamable HTTP + OAuth support, built from the [fatherlinux fork](https://github.com/fatherlinux/mcp-memory-service/tree/feature/streamable-http-oauth).

**Image:** `quay.io/crunchtools/memory`

## Quick Start

### Local Claude Code (SSE transport)

```bash
podman run -d --name mcp-memory \
  -p 127.0.0.1:8765:8765 \
  --env-file ~/.config/mcp-env/mcp-memory.env \
  -v ~/.local/share/mcp-memory:/app/sqlite_db:Z \
  quay.io/crunchtools/memory \
  --sse --sse-host 0.0.0.0 --sse-port 8765
```

Claude Code config:
```json
{
  "memory": {
    "type": "sse",
    "url": "http://127.0.0.1:8765/sse"
  }
}
```

### Remote Claude.ai (Streamable HTTP + OAuth)

```bash
podman run -d --name mcp-memory \
  -p 127.0.0.1:8765:8765 \
  --env-file /srv/memory.crunchtools.com/config/mcp-memory.env \
  -v /srv/memory.crunchtools.com/data:/app/sqlite_db:Z \
  quay.io/crunchtools/memory \
  --streamable-http --streamable-http-host 0.0.0.0 --streamable-http-port 8765
```

Requires Apache/nginx reverse proxy with SSL and Cloudflare CDN in front.

## Environment Variables

| Variable | Description |
|---|---|
| `MCP_MEMORY_STORAGE_BACKEND` | `sqlite_vec`, `hybrid`, or `cloudflare` |
| `CLOUDFLARE_API_TOKEN` | Cloudflare API token (for hybrid/cloudflare backend) |
| `CLOUDFLARE_ACCOUNT_ID` | Cloudflare account ID |
| `CLOUDFLARE_D1_DATABASE_ID` | Cloudflare D1 database ID |
| `CLOUDFLARE_VECTORIZE_INDEX` | Cloudflare Vectorize index name |
| `MCP_MEMORY_API_KEY` | API key for OAuth gate (Streamable HTTP mode) |
| `MCP_STREAMABLE_HTTP_MODE` | Set to `1` for Streamable HTTP mode |

## Building Locally

```bash
podman build -t quay.io/crunchtools/memory .
```

## License

Apache-2.0 (upstream license)

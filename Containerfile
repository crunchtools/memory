# MCP Memory Service Container
# Wraps fatherlinux/mcp-memory-service (upstream sync, no custom patches)
# on Hummingbird Python base image.
#
# Build:
#   podman build -t quay.io/crunchtools/memory .
#
# Run (Streamable HTTP — production on lotor):
#   podman run -d --name mcp-memory -p 127.0.0.1:8765:8765 \
#     --env-file /srv/mcp-memory.crunchtools.com/config/mcp-memory.env \
#     -v /srv/mcp-memory.crunchtools.com/data:/app/sqlite_db:Z \
#     quay.io/crunchtools/memory \
#     --streamable-http --sse-host 0.0.0.0 --sse-port 8765

# Stage 1: grab libstdc++ from Fedora (Hummingbird is distroless)
FROM registry.fedoraproject.org/fedora-minimal:44 AS libs
RUN microdnf install -y libstdc++ && microdnf clean all

# Stage 2: build on Hummingbird Python (distroless — no shell, all exec-form)
FROM quay.io/hummingbird/python:latest

LABEL name="mcp-memory" \
      version="0.3.0" \
      summary="MCP Memory Service with persistent semantic memory" \
      description="Persistent memory for AI agents — semantic search, knowledge graph, Cloudflare sync" \
      maintainer="crunchtools.com" \
      url="https://github.com/crunchtools/memory" \
      io.k8s.display-name="MCP Memory (CrunchTools)"

# Copy libstdc++ from Fedora stage (needed by numpy, torch, sentence-transformers)
COPY --from=libs /usr/lib64/libstdc++.so* /usr/lib64/

WORKDIR /app

# Cache-bust when fork changes (update this to force rebuild)
ARG SOURCE_VERSION=2026-08-30c

# Download and extract fork source
RUN ["python", "-c", "\nimport urllib.request, tarfile, io, os\nurl = 'https://github.com/fatherlinux/mcp-memory-service/archive/refs/heads/main.tar.gz'\ndata = urllib.request.urlopen(url).read()\ntf = tarfile.open(fileobj=io.BytesIO(data))\nmembers = tf.getmembers()\nprefix = members[0].name\nfor m in members[1:]:\n    m.name = os.path.relpath(m.name, prefix)\n    tf.extract(m, '/app')\ntf.close()\nprint(f'Extracted {len(members)} files')\n"]

# Install CPU-only PyTorch first (saves ~1.5GB vs full CUDA build)
RUN ["pip", "install", "--no-cache-dir", "torch", "--index-url", "https://download.pytorch.org/whl/cpu"]

# Install the package and all dependencies
RUN ["pip", "install", "--no-cache-dir", "-e", "."]

# Create data directories
RUN ["python", "-c", "import os; os.makedirs('/app/sqlite_db', exist_ok=True); os.makedirs('/app/backups', exist_ok=True)"]

ENV PYTHONUNBUFFERED=1 \
    PYTHONPATH=/app/src \
    PATH="/tmp/.local/bin:${PATH}" \
    MCP_MEMORY_SQLITE_PATH=/app/sqlite_db/memory.db \
    MCP_MEMORY_BACKUPS_PATH=/app/backups \
    MCP_SSE_HOST=0.0.0.0 \
    MCP_SSE_PORT=8765 \
    HF_HUB_DISABLE_TELEMETRY=1

VOLUME ["/app/sqlite_db", "/app/backups"]

EXPOSE 8765

ENTRYPOINT ["python", "-m", "mcp_memory_service.cli.main", "server"]
CMD ["--sse", "--sse-host", "0.0.0.0", "--sse-port", "8765"]

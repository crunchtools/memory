# MCP Memory Service Container
# Wraps fatherlinux/mcp-memory-service fork (Streamable HTTP + OAuth)
# on Hummingbird Python base image.
#
# Build:
#   podman build -t quay.io/crunchtools/memory .
#
# Run (SSE - local Claude Code):
#   podman run -d --name mcp-memory -p 127.0.0.1:8765:8765 \
#     --env-file ~/.config/mcp-env/mcp-memory.env \
#     -v ~/.local/share/mcp-memory:/app/sqlite_db:Z \
#     quay.io/crunchtools/memory \
#     --sse --sse-host 0.0.0.0 --sse-port 8765
#
# Run (Streamable HTTP + OAuth - remote Claude.ai):
#   podman run -d --name mcp-memory -p 127.0.0.1:8765:8765 \
#     --env-file /srv/memory.crunchtools.com/config/mcp-memory.env \
#     -v /srv/memory.crunchtools.com/data:/app/sqlite_db:Z \
#     quay.io/crunchtools/memory \
#     --streamable-http --streamable-http-host 0.0.0.0 --streamable-http-port 8765

# Stage 1: grab libstdc++ from Fedora (Hummingbird is too minimal)
FROM registry.fedoraproject.org/fedora-minimal:44 AS libs
RUN microdnf install -y libstdc++ && microdnf clean all

# Stage 2: build on Hummingbird Python
FROM quay.io/hummingbird/python:latest

LABEL name="mcp-memory" \
      version="0.2.0" \
      summary="MCP Memory Service with persistent semantic memory" \
      description="Persistent memory for AI agents — semantic search, knowledge graph, Cloudflare sync" \
      maintainer="crunchtools.com" \
      url="https://github.com/crunchtools/memory" \
      io.k8s.display-name="MCP Memory (CrunchTools)"

# Copy libstdc++ from Fedora stage (needed by numpy, torch, sentence-transformers)
COPY --from=libs /usr/lib64/libstdc++.so* /usr/lib64/

WORKDIR /app

# Cache-bust when fork changes (update this to force rebuild)
ARG SOURCE_VERSION=2026-02-28

# Download and extract fork source (minimal image has no git/tar, use Python)
RUN python -c "exec('''\nimport urllib.request, tarfile, io, os\nurl = \"https://github.com/fatherlinux/mcp-memory-service/archive/refs/heads/main.tar.gz\"\ndata = urllib.request.urlopen(url).read()\ntf = tarfile.open(fileobj=io.BytesIO(data))\nmembers = tf.getmembers()\nprefix = members[0].name\nfor m in members[1:]:\n    m.name = os.path.relpath(m.name, prefix)\n    tf.extract(m, \"/app\")\ntf.close()\n''')"

# Install CPU-only PyTorch first (saves ~1.5GB vs full CUDA build)
RUN pip install --no-cache-dir torch --index-url https://download.pytorch.org/whl/cpu

# Install the package and all dependencies
RUN pip install --no-cache-dir -e .

# Create data directories
RUN mkdir -p /app/sqlite_db /app/backups

# Ensure pip user-install binaries are on PATH
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

# Default: SSE transport on port 8765
# Override at runtime with --streamable-http for OAuth mode
ENTRYPOINT ["python", "-m", "mcp_memory_service.cli.main", "server"]
CMD ["--sse", "--sse-host", "0.0.0.0", "--sse-port", "8765"]

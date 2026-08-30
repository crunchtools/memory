# MCP Memory Service Container
# Built on Hummingbird Python using proper multi-stage builder pattern.
#
# Run (Streamable HTTP — production on lotor):
#   podman run -d --name mcp-memory -p 127.0.0.1:8765:8765 \
#     --env-file /srv/mcp-memory.crunchtools.com/config/mcp-memory.env \
#     -v /srv/mcp-memory.crunchtools.com/data:/app/sqlite_db:Z \
#     quay.io/crunchtools/memory \
#     --streamable-http --sse-host 0.0.0.0 --sse-port 8765

# Stage 1: builder — has dnf, bash, shadow-utils for installing native deps
FROM registry.access.redhat.com/hi/python:3.12-builder AS builder

WORKDIR /app

# Cache-bust when upstream changes
ARG SOURCE_VERSION=2026-08-30f

# Install native libs needed by onnxruntime (libgomp) and numpy (libstdc++)
RUN dnf install -y --setopt=install_weak_deps=False libgomp libstdc++ tar gzip && dnf clean all

# Download and extract upstream source
RUN curl -sL https://github.com/fatherlinux/mcp-memory-service/archive/refs/heads/main.tar.gz \
    | tar xz --strip-components=1 -C /app

# Install CPU-only PyTorch then the package with ONNX embedding support
RUN pip3.12 install --no-cache-dir torch --index-url https://download.pytorch.org/whl/cpu && \
    pip3.12 install --no-cache-dir -e ".[sqlite]"

RUN mkdir -p /app/sqlite_db /app/backups

# Stage 2: distroless production image
FROM registry.access.redhat.com/hi/python:3.12

LABEL name="mcp-memory" \
      version="0.3.0" \
      summary="MCP Memory Service with persistent semantic memory" \
      description="Persistent memory for AI agents — semantic search, knowledge graph, Cloudflare sync" \
      maintainer="crunchtools.com" \
      url="https://github.com/crunchtools/memory" \
      io.k8s.display-name="MCP Memory (CrunchTools)"

WORKDIR /app

# Copy native libs from builder
COPY --from=builder /usr/lib64/libgomp.so* /usr/lib64/
COPY --from=builder /usr/lib64/libstdc++.so* /usr/lib64/

# Copy installed Python packages and app source
COPY --from=builder /tmp/.local /tmp/.local
COPY --from=builder /app /app

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

ENTRYPOINT ["python3.12", "-m", "mcp_memory_service.cli.main", "server"]
CMD ["--sse", "--sse-host", "0.0.0.0", "--sse-port", "8765"]

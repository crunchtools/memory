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
FROM registry.access.redhat.com/hi/python:3.14-builder AS builder

WORKDIR /app

# Cache-bust when upstream changes
ARG SOURCE_VERSION=2026-08-30h

# Install native libs needed by onnxruntime (libgomp) and numpy (libstdc++)
USER 0
RUN dnf install -y --setopt=install_weak_deps=False libgomp libstdc++ tar gzip && dnf clean all

# onnxruntime vendors cpp_client_telemetry, which reads /etc/machine-id for a
# device ID. When the value is unusable it falls back to popen("blkid"), and
# popen() returns NULL with no /bin/sh. The SDK does not check that, so the
# following pclose(NULL) segfaults the interpreter on `import onnxruntime`.
# That is HUM-6564 / onnxruntime#32173.
#
# The file must be POPULATED — measured against 1.29.0 with telemetry on:
#   absent -> SIGSEGV(139) | empty -> SIGSEGV(139) | populated -> clean
# The empty "first boot" state is NOT enough. Needs root, so it lives here.
RUN tr -d - < /proc/sys/kernel/random/uuid > /etc/machine-id.seed

USER 65532

# Download and extract upstream source
RUN curl -sL https://github.com/fatherlinux/mcp-memory-service/archive/refs/heads/main.tar.gz \
    | tar xz --strip-components=1 -C /app

# Install CPU-only PyTorch then the package with ONNX embedding support.
# onnxruntime is no longer pinned: the <1.20 pin was a workaround for the
# distroless segfault, and it held the embedding runtime nine minor versions
# back. The populated /etc/machine-id above and ORT_DISABLE_TELEMETRY below
# each independently prevent that crash, verified against 1.29.0.
RUN pip3.12 install --no-cache-dir torch --index-url https://download.pytorch.org/whl/cpu && \
    pip3.12 install --no-cache-dir -e ".[sqlite]"

RUN mkdir -p /app/sqlite_db /app/backups

# Stage 2: distroless production image
FROM registry.access.redhat.com/hi/python:3.14

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

# Keeps onnxruntime's telemetry off its shell-based fallback — see stage 1
COPY --from=builder /etc/machine-id.seed /etc/machine-id

ENV PYTHONUNBUFFERED=1 \
    PYTHONPATH=/app/src \
    PATH="/tmp/.local/bin:${PATH}" \
    MCP_MEMORY_SQLITE_PATH=/app/sqlite_db/memory.db \
    MCP_MEMORY_BACKUPS_PATH=/app/backups \
    MCP_SSE_HOST=0.0.0.0 \
    MCP_SSE_PORT=8765

# Second, independent guard against the HUM-6564 crash, and appropriate on its
# own merits: left enabled, onnxruntime's init reads /etc/machine-id and
# /etc/os-release, writes /tmp/mat-debug-1.log and creates a session file at
# /tmp/.ses — not wanted in the image holding the whole memory corpus.
ENV HF_HUB_DISABLE_TELEMETRY=1 \
    ORT_DISABLE_TELEMETRY=1 \
    DO_NOT_TRACK=1

VOLUME ["/app/sqlite_db", "/app/backups"]

EXPOSE 8765

ENTRYPOINT ["python3.12", "-m", "mcp_memory_service.cli.main", "server"]
CMD ["--sse", "--sse-host", "0.0.0.0", "--sse-port", "8765"]

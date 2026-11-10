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

# Pin upstream to a specific commit (RT#1564) -- `main` is drift. Bump this
# deliberately when upstream needs to move; pair it with re-exporting
# requirements-sqlite.txt and re-checking the torch pin below.
# https://github.com/fatherlinux/mcp-memory-service/commit/80c97785bf552ee50f82e5d5088bed5bdccb7704
ARG UPSTREAM_COMMIT=80c97785bf552ee50f82e5d5088bed5bdccb7704

# Install native libs needed by onnxruntime (libgomp) and numpy (libstdc++),
# and uv to export upstream's lock. Both run as root so `uv` lands in
# /usr/local/bin, already on PATH, rather than the non-root user's --user
# site that only stage 2's PATH knows about.
USER 0
RUN dnf install -y --setopt=install_weak_deps=False libgomp libstdc++ tar gzip && dnf clean all
RUN pip3.14 install --no-cache-dir uv==0.13.7

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

# Belt-and-suspenders: WORKDIR created /app under the image's default UID
# (65532) before the USER 0 switch above, but observed locally under
# concurrent podman builds sharing this host's container storage, /app can
# come out of the USER 0 steps owned by root. Make the ownership explicit
# rather than relying on it surviving the USER 0 block.
RUN chown -R 65532:0 /app

USER 65532

# Download and extract upstream source at the pinned commit
RUN curl -sL https://github.com/fatherlinux/mcp-memory-service/archive/${UPSTREAM_COMMIT}.tar.gz \
    | tar xz --strip-components=1 -C /app

# Export upstream's committed uv.lock for the sqlite extra and install that
# exact, hash-locked set with --no-deps -- no fresh resolve, no drift.
# onnxruntime is no longer pinned in upstream's own pyproject: the <1.20 pin
# was a workaround for the distroless segfault, and it held the embedding
# runtime nine minor versions back. The populated /etc/machine-id above and
# ORT_DISABLE_TELEMETRY below each independently prevent that crash, verified
# against 1.29.0; the lock at this commit resolves onnxruntime==1.24.3 for
# Python 3.14.
RUN uv export --frozen --no-dev --no-emit-project --extra sqlite \
      --format requirements-txt -o /tmp/requirements.txt && \
    pip3.14 install --no-cache-dir --no-deps -r /tmp/requirements.txt

# torch is NOT in the sqlite extra's dependency closure (upstream keeps it in
# the separate [ml] extra), so `uv export --extra sqlite` never names it --
# there is nothing to lock it against. It is still installed here because the
# image needs the CPU wheel from PyTorch's own index rather than the
# CUDA-pulling PyPI build upstream's uv.lock resolves for [ml] (torch==2.14.1,
# with cuda-bindings/cuda-toolkit/nvidia-* deps). Pin to that same version so
# it tracks upstream's lock, take it from the CPU index, and use --no-deps:
# the CPU wheel's own runtime deps (filelock, fsspec, sympy, typing-extensions)
# are already satisfied by the sqlite extra install above via huggingface_hub;
# jinja2/networkx/setuptools (torch's own extras, pulled only for its fx/jit
# features) are not required at import time for the ONNX embedding path this
# image actually uses -- verified against this build. Bump this together with
# the UPSTREAM_COMMIT pin above.
RUN pip3.14 install --no-cache-dir --no-deps torch==2.14.1 \
      --index-url https://download.pytorch.org/whl/cpu

# Install the project itself last, --no-deps: its dependency closure was
# already installed, locked, above.
RUN pip3.14 install --no-cache-dir --no-deps -e ".[sqlite]"

RUN mkdir -p /app/sqlite_db /app/backups

# Stage 2: distroless production image
FROM registry.access.redhat.com/hi/python:3.14

LABEL name="mcp-memory" \
      version="1.1.2" \
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

# pbs on the host backs up sqlite_vec.db with sqlite3 .backup. The in-app
# scheduler only runs in --http mode and would write to the ephemeral layer.
ENV MCP_BACKUP_ENABLED=false

# Second, independent guard against the HUM-6564 crash, and appropriate on its
# own merits: left enabled, onnxruntime's init reads /etc/machine-id and
# /etc/os-release, writes /tmp/mat-debug-1.log and creates a session file at
# /tmp/.ses — not wanted in the image holding the whole memory corpus.
ENV HF_HUB_DISABLE_TELEMETRY=1 \
    ORT_DISABLE_TELEMETRY=1 \
    DO_NOT_TRACK=1

VOLUME ["/app/sqlite_db"]

EXPOSE 8765

ENTRYPOINT ["python3.14", "-m", "mcp_memory_service.cli.main", "server"]
CMD ["--sse", "--sse-host", "0.0.0.0", "--sse-port", "8765"]

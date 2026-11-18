# MCP Memory Service Container
# Built on Hummingbird Python using proper multi-stage builder pattern.
#
# Run (Streamable HTTP — production on gloval):
#   podman run -d --name mcp-memory -p 127.0.0.1:8765:8765 \
#     --env-file /run/srv-secrets/mcp-memory.crunchtools.com/mcp-memory.env \
#     -v /srv/mcp-memory.crunchtools.com/data:/app/sqlite_db:Z \
#     quay.io/crunchtools/memory \
#     --streamable-http --sse-host 0.0.0.0 --sse-port 8765

# Stage 1: builder — has dnf, bash, shadow-utils for installing native deps
FROM registry.access.redhat.com/hi/python:3.14-builder AS builder

WORKDIR /app

# Pin upstream to a specific commit (RT#1564) -- `main` is drift. Bump this
# deliberately when upstream needs to move; pair it with re-checking the torch
# pin below. This is doobidoo's v12.11.0 tag: the fatherlinux fork's only
# patch is now carried upstream verbatim, so the build takes upstream direct
# (RT#1655).
# https://github.com/doobidoo/mcp-memory-service/releases/tag/v12.11.0
ARG UPSTREAM_COMMIT=112d881c03268fe791d3a7f3d5e277cbe56174b2

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

# The Python packages install into /opt/memory, not pip's default user base.
# The builder runs as 65532 with HOME=/tmp, so `pip install` falls back to a
# --user install under $HOME/.local -- i.e. /tmp/.local, ~1.07 GB of it. The
# runtime stage then carried that into /tmp, and the house
# `Tmpfs=/tmp:rw,nosuid,size=256m` mounts over it: the container died at
# create with "No space left on device" (#43). PYTHONUSERBASE moves the user
# base out of /tmp in both stages; site.py honours it at runtime, so nothing
# else changes. Needs root to create, so it lives here.
RUN mkdir -p /opt/memory && chown 65532:0 /opt/memory
ENV PYTHONUSERBASE=/opt/memory

USER 65532

# Download and extract upstream source at the pinned commit
RUN curl -sL https://github.com/doobidoo/mcp-memory-service/archive/${UPSTREAM_COMMIT}.tar.gz \
    | tar xz --strip-components=1 -C /app

# Export upstream's committed uv.lock for the sqlite extra and install that
# exact, hash-locked set with --no-deps -- no fresh resolve, no drift.
# onnxruntime is no longer pinned in upstream's own pyproject: the <1.20 pin
# was a workaround for the distroless segfault, and it held the embedding
# runtime nine minor versions back. The populated /etc/machine-id above and
# ORT_DISABLE_TELEMETRY below each independently prevent that crash, verified
# against 1.29.0; the lock at this commit resolves onnxruntime==1.31.1 for
# Python 3.14.
RUN uv export --frozen --no-dev --no-emit-project --extra sqlite \
      --format requirements-txt -o /tmp/requirements.txt && \
    pip3.14 install --no-cache-dir --no-deps -r /tmp/requirements.txt

# torch is NOT in the sqlite extra's dependency closure (upstream keeps it in
# the separate [ml] extra), so `uv export --extra sqlite` never names it --
# there is nothing to lock it against. It is still installed here because the
# image needs the CPU wheel from PyTorch's own index rather than the
# CUDA-pulling PyPI build upstream's uv.lock resolves for [ml] (torch==2.15.0,
# with cuda-bindings/cuda-toolkit/nvidia-* deps). Pin to that same version so
# it tracks upstream's lock, take it from the CPU index, and use --no-deps:
# the CPU wheel's own runtime deps (filelock, fsspec, sympy, typing-extensions)
# are already satisfied by the sqlite extra install above via huggingface_hub;
# jinja2/networkx/setuptools (torch's own extras, pulled only for its fx/jit
# features) are not required at import time for the ONNX embedding path this
# image actually uses -- verified against this build. Bump this together with
# the UPSTREAM_COMMIT pin above.
RUN pip3.14 install --no-cache-dir --no-deps torch==2.15.0 \
      --index-url https://download.pytorch.org/whl/cpu

# Install the project itself last, --no-deps: its dependency closure was
# already installed, locked, above.
RUN pip3.14 install --no-cache-dir --no-deps -e ".[sqlite]"

# /app/state backs MCP_MEMORY_BASE_DIR (set in stage 2). Created here, under
# the /app that is chowned to 65532 above, because stage 2 is distroless and
# cannot RUN mkdir; `COPY --from=builder /app /app` carries it and its
# ownership across.
RUN mkdir -p /app/sqlite_db /app/backups /app/state

# Stage 2: distroless production image
FROM registry.access.redhat.com/hi/python:3.14

LABEL name="mcp-memory" \
      version="1.2.1" \
      summary="MCP Memory Service with persistent semantic memory" \
      description="Persistent memory for AI agents — semantic search, knowledge graph, HLC peer sync" \
      maintainer="crunchtools.com" \
      url="https://github.com/crunchtools/memory" \
      io.k8s.display-name="MCP Memory (CrunchTools)"

WORKDIR /app

# Copy native libs from builder
COPY --from=builder /usr/lib64/libgomp.so* /usr/lib64/
COPY --from=builder /usr/lib64/libstdc++.so* /usr/lib64/

# Copy installed Python packages and app source
COPY --from=builder /opt/memory /opt/memory
COPY --from=builder /app /app

# Keeps onnxruntime's telemetry off its shell-based fallback — see stage 1
COPY --from=builder /etc/machine-id.seed /etc/machine-id

# MCP_MEMORY_BASE_DIR is set EXPLICITLY. Unset, config/base.py falls back to
# $HOME/.local/share/mcp-memory, and HOME is /tmp here, so the base dir landed
# inside /tmp/.local -- which the image once created for the pip --user install
# (it now lives in /opt/memory, see stage 1) and which belonged to root, mode
# 0755. That only ever worked because some dependency's install happened to
# leave a 65532-owned /tmp/.local/share behind; the 12.11.0 dependency set does
# not, and config/base.py calls
# sys.exit(1) when it cannot create the directory, so the server died at import
# with "Fatal error initializing paths" (RT#1655). /app/state is owned by the
# runtime user by construction and does not depend on HOME or on pip's layout.
# It is deliberately NOT a volume: BASE_DIR holds the ONNX model cache and the
# consolidation archive, which were ephemeral before this change and stay so.
ENV PYTHONUNBUFFERED=1 \
    PYTHONPATH=/app/src \
    PYTHONUSERBASE=/opt/memory \
    PATH="/opt/memory/bin:${PATH}" \
    MCP_MEMORY_BASE_DIR=/app/state \
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

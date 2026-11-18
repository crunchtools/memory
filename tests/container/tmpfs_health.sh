#!/usr/bin/env bash
# Boot the image the way the house quadlets run it -- /tmp as a small tmpfs --
# and require the HTTP API to answer /api/health (#43).
#
# The image once carried its ~1.07 GB of Python packages in /tmp/.local, so a
# `--tmpfs /tmp:size=256m` hid them (or failed the create outright with "No
# space left on device"). The data volume mirrors gloval's
# `-v data:/app/sqlite_db`. CI's contract-test runs this with $IMAGE set.
set -euo pipefail

: "${IMAGE:?set IMAGE to the image under test}"
TIMEOUT="${TIMEOUT:-240}"
PORT="${PORT:-18000}"
name="memory-tmpfs-$$"
vol="memory-tmpfs-data-$$"

cleanup() {
  podman logs "$name" 2>&1 | tail -40 || true
  podman rm -f "$name" >/dev/null 2>&1 || true
  podman volume rm -f "$vol" >/dev/null 2>&1 || true
}
trap cleanup EXIT

podman volume create "$vol" >/dev/null
podman run -d --name "$name" \
  --tmpfs /tmp:rw,nosuid,size=256m \
  -v "$vol:/app/sqlite_db" \
  -e MCP_API_KEY=contract-test-dummy-key \
  -p "127.0.0.1:$PORT:8000" \
  "$IMAGE" \
  --http --http-host 0.0.0.0 --http-port 8000 --storage-backend sqlite_vec >/dev/null

deadline=$((SECONDS + TIMEOUT))
while (( SECONDS < deadline )); do
  if [ "$(podman inspect -f '{{.State.Running}}' "$name")" != true ]; then
    echo "container exited before answering /api/health" >&2
    exit 1
  fi
  if body=$(curl -fsS "http://127.0.0.1:$PORT/api/health" 2>/dev/null); then
    echo "/api/health: $body"
    grep -q '"healthy"' <<<"$body"
    exit 0
  fi
  sleep 3
done
echo "/api/health did not answer within ${TIMEOUT}s" >&2
exit 1

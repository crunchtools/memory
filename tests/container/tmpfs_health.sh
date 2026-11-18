#!/usr/bin/env bash
# Boot the image the way the house quadlets run it -- /tmp as a small tmpfs --
# and require the HTTP API to answer /api/health, then store a memory and find
# it again by semantic search, so the embedding model really loads (#43).
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
KEY=contract-test-dummy-key
base="http://127.0.0.1:$PORT/api"

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
  -e MCP_API_KEY="$KEY" \
  -p "127.0.0.1:$PORT:8000" \
  "$IMAGE" \
  --http --http-host 0.0.0.0 --http-port 8000 --storage-backend sqlite_vec >/dev/null

deadline=$((SECONDS + TIMEOUT))
until body=$(curl -fsS "$base/health" 2>/dev/null); do
  if [ "$(podman inspect -f '{{.State.Running}}' "$name")" != true ]; then
    echo "container exited before answering /api/health" >&2
    exit 1
  fi
  if (( SECONDS >= deadline )); then
    echo "/api/health did not answer within ${TIMEOUT}s" >&2
    exit 1
  fi
  sleep 3
done
echo "/api/health: $body"
grep -q '"healthy"' <<<"$body"

# /api/health is a constant. A store and a semantic search need the embedding
# model, which is where the cache under $HOME comes in.
token="tmpfs-contract-$$-$RANDOM"
api() {
  curl -fsS --max-time "$TIMEOUT" -H "X-API-Key: $KEY" \
    -H 'Content-Type: application/json' "$@"
}
stored=$(api -X POST "$base/memories" \
  -d "{\"content\": \"Contract test memory $token: tmpfs on /tmp must not hide the model.\", \"tags\": [\"contract-test\"]}")
echo "store: $stored"
grep -q '"success": *true' <<<"$stored"
found=$(api -X POST "$base/search" \
  -d '{"query": "contract test memory about tmpfs hiding the model", "n_results": 5}')
grep -q "$token" <<<"$found" || { echo "search did not return the stored memory: $found" >&2; exit 1; }
echo "search: found $token"

# The model cache must have landed under HOME=/app/state, and /tmp stayed small.
podman exec "$name" python3.14 -I -c '
import os, pathlib, sys
cache = pathlib.Path.home() / ".cache"
model = sum(f.stat().st_size for f in cache.rglob("*") if f.is_file()) if cache.is_dir() else 0
st = os.statvfs("/tmp")
tmp_used = (st.f_blocks - st.f_bfree) * st.f_frsize
print(f"HOME={pathlib.Path.home()} cache={model >> 20} MiB /tmp used={tmp_used >> 20} MiB")
sys.exit(0 if str(pathlib.Path.home()) == "/app/state" and model > 0 and tmp_used < 32 << 20 else 1)
'

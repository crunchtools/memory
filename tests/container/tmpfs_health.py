"""Run the image's HTTP API the way the house runs it and prove it really works.

Runs inside the built image (distroless: no shell, no curl), as sdlc's
`contract` check in sdlc.toml. /tmp is a fresh tmpfs there, as in the house
quadlets. The image once carried its ~1.07 GB of Python packages in
/tmp/.local, so a tmpfs on /tmp hid them (#43). This starts the server,
requires /api/health to answer, then stores a memory and finds it again by
semantic search, so the embedding model really loads, and checks the model
cache landed under HOME=/app/state while /tmp stayed small.
"""

import json
import os
import pathlib
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

TIMEOUT = int(os.environ.get("TIMEOUT", "240"))
PORT = 8000
KEY = "contract-test-dummy-key"
BASE = f"http://127.0.0.1:{PORT}/api"


def api(path: str, body: dict | None = None) -> str:
    req = urllib.request.Request(
        f"{BASE}/{path}",
        data=None if body is None else json.dumps(body).encode(),
        headers={"X-API-Key": KEY, "Content-Type": "application/json"},
        method="GET" if body is None else "POST",
    )
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
        return resp.read().decode()


def check(log) -> None:
    server = subprocess.Popen(
        [
            *["python3.14", "-m", "mcp_memory_service.cli.main", "server"],
            *["--http", "--http-host", "127.0.0.1", "--http-port", str(PORT)],
            *["--storage-backend", "sqlite_vec"],
        ],
        env={**os.environ, "MCP_API_KEY": KEY},
        stdout=log,
        stderr=subprocess.STDOUT,
    )
    try:
        deadline = time.monotonic() + TIMEOUT
        while True:
            if server.poll() is not None:
                sys.exit("server exited before answering /api/health")
            try:
                body = api("health")
                break
            except (urllib.error.URLError, OSError):
                if time.monotonic() >= deadline:
                    sys.exit(f"/api/health did not answer within {TIMEOUT}s")
                time.sleep(3)
        print(f"/api/health: {body}")
        if '"healthy"' not in body:
            sys.exit("/api/health is not healthy")

        token = f"tmpfs-contract-{os.getpid()}-{time.time_ns()}"
        stored = api(
            "memories",
            {
                "content": f"Contract test memory {token}: tmpfs on /tmp must not hide the model.",
                "tags": ["contract-test"],
            },
        )
        print(f"store: {stored}")
        if json.loads(stored).get("success") is not True:
            sys.exit("store did not succeed")
        found = api(
            "search",
            {"query": "contract test memory about tmpfs hiding the model", "n_results": 5},
        )
        if token not in found:
            sys.exit(f"search did not return the stored memory: {found}")
        print(f"search: found {token}")

        home = pathlib.Path.home()
        cache = home / ".cache"
        model = sum(f.stat().st_size for f in cache.rglob("*") if f.is_file()) if cache.is_dir() else 0
        st = os.statvfs("/tmp")
        tmp_used = (st.f_blocks - st.f_bfree) * st.f_frsize
        print(f"HOME={home} cache={model >> 20} MiB /tmp used={tmp_used >> 20} MiB")
        if str(home) != "/app/state" or model == 0 or tmp_used >= 32 << 20:
            sys.exit("model cache is not under HOME=/app/state, or /tmp grew")
    finally:
        server.terminate()
        try:
            server.wait(timeout=30)
        except subprocess.TimeoutExpired:
            server.kill()


if __name__ == "__main__":
    # The server's log goes under HOME, not /tmp, so it doesn't count against /tmp.
    with tempfile.TemporaryFile(mode="w+", dir=pathlib.Path.home()) as log:
        try:
            check(log)
        except BaseException:
            log.seek(0)
            print("".join(log.readlines()[-40:]), file=sys.stderr)
            raise

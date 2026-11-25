"""Run the image's HTTP API the way the house runs it and prove it really works.

Runs inside the built image (distroless: no shell, no curl), as sdlc's
`contract` check in pyproject.toml. /tmp is a fresh tmpfs there, as in the house
quadlets. The image once carried its ~1.07 GB of Python packages in
/tmp/.local, so a tmpfs on /tmp hid them (#43). This starts the server,
requires /api/health to answer, then stores a memory and finds it again by
semantic search, so the embedding model really loads, and checks the model
cache sits under HOME=/app/state while /tmp stayed small.

The model is baked into the image (#52) and this runs with no network, so
/api/health/model must name the ONNX model rather than upstream's hash
pseudo-embedding fallback: with one memory stored, a search over hash vectors
would still find it.

Before any of that, errors_reported() runs wait_healthy against a stub server,
so a 401 or 500 on /api/health fails at once with its status and body, a 503
is waited out, and a status outside the HTTPStatus enum, like 599, still
reports its number (#59).
"""

import http.client
import json
import os
import pathlib
import socket
import subprocess
import sys
import tempfile
import threading
import time
from collections.abc import Callable
from http import HTTPStatus

TIMEOUT = 240  # seconds; matches boot-timeout in pyproject.toml
SHUTDOWN_TIMEOUT = 30  # seconds
MIB = 1 << 20
TMP_LIMIT = 32 * MIB
PORT = 8000
KEY = "contract-test-dummy-key"
MODEL = "all-MiniLM-L6-v2"
RETRY = 3  # seconds between /api/health attempts
RECV = 4096  # bytes per read of a request to the stub server
NOT_IN_ENUM = 599  # a status HTTPStatus has no member for


class HTTPStatusError(http.client.HTTPException):
    """The API answered with a non-2xx status."""

    def __init__(self, path: str, status: int, body: str) -> None:
        super().__init__(f"/api/{path} answered {status}: {body}")
        self.status = status


def api(path: str, body: dict | None = None, port: int = PORT) -> str:
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=TIMEOUT)
    try:
        conn.request(
            "GET" if body is None else "POST",
            f"/api/{path}",
            body=None if body is None else json.dumps(body),
            headers={"X-API-Key": KEY, "Content-Type": "application/json"},
        )
        resp = conn.getresponse()
        text = resp.read().decode()
        # A range, not HTTPStatus(resp.status): that raises on a code outside
        # the enum, like 599, and hides the answer behind a ValueError.
        if not HTTPStatus.OK <= resp.status < HTTPStatus.MULTIPLE_CHOICES:
            raise HTTPStatusError(path, resp.status, text)
        return text
    finally:
        conn.close()


def wait_healthy(exited: Callable[[], int | None], port: int = PORT) -> str | None:
    """Wait out a server still starting: no connection yet, or a 503.

    Any other non-2xx answer is the server's real reply, so it fails at once.
    """
    deadline = time.monotonic() + TIMEOUT
    while True:
        if exited() is not None:
            return "server exited before answering /api/health"
        try:
            body = api("health", port=port)
            break
        except HTTPStatusError as e:
            if e.status != HTTPStatus.SERVICE_UNAVAILABLE:
                return str(e)
            last = e
        except OSError as e:
            last = e
        if time.monotonic() >= deadline:
            return f"/api/health did not answer within {TIMEOUT}s: {last}"
        time.sleep(RETRY)
    print(f"/api/health: {body}")
    return None if '"healthy"' in body else "/api/health is not healthy"


def stub(*answers: tuple[int, str]) -> tuple[int, threading.Thread]:
    """Serve one canned HTTP answer per connection, in order, on a free port."""
    listener = socket.create_server(("127.0.0.1", 0))
    listener.settimeout(TIMEOUT)

    def serve() -> None:
        with listener:
            for status, body in answers:
                conn, _ = listener.accept()
                with conn:
                    request = b""
                    while b"\r\n\r\n" not in request:
                        chunk = conn.recv(RECV)
                        if not chunk:
                            break
                        request += chunk
                    payload = body.encode()
                    conn.sendall(
                        f"HTTP/1.1 {status} Stub\r\nContent-Length: {len(payload)}\r\n"
                        f"Connection: close\r\n\r\n".encode() + payload
                    )

    thread = threading.Thread(target=serve, daemon=True)
    thread.start()
    return listener.getsockname()[1], thread


def errors_reported() -> str | None:
    """Prove wait_healthy's non-2xx handling against a stub server (#59)."""
    def alive() -> None:
        return None

    cases = [
        # (answers, what wait_healthy must return, longest it may take)
        ([(401, "bad key")], "/api/health answered 401: bad key", 1),
        ([(500, "boom")], "/api/health answered 500: boom", 1),
        ([(NOT_IN_ENUM, "odd")], f"/api/health answered {NOT_IN_ENUM}: odd", 1),
        ([(503, "starting"), (200, '{"status": "healthy"}')], None, RETRY + 1),
    ]
    for answers, want, limit in cases:
        port, thread = stub(*answers)
        start = time.monotonic()
        got = wait_healthy(alive, port)
        took = time.monotonic() - start
        thread.join(TIMEOUT)
        if got != want or took > limit:
            return f"stub {answers}: wait_healthy returned {got!r} in {took:.1f}s, want {want!r}"
    print("stub: /api/health errors are reported, 503 is waited out")
    return None


def store_and_search() -> str | None:
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
        return "store did not succeed"
    found = api(
        "search",
        {"query": "contract test memory about tmpfs hiding the model", "n_results": 5},
    )
    if token not in found:
        return f"search did not return the stored memory: {found}"
    print(f"search: found {token}")
    return None


def model_loaded() -> str | None:
    model_health = api("health/model")
    print(f"/api/health/model: {model_health}")
    if MODEL not in model_health or "__hash_fallback__" in model_health:
        return "the embedding model did not load; the server fell back to hash vectors"
    return None


def cache_placed() -> str | None:
    home = pathlib.Path.home()
    cache = home / ".cache"
    files = cache.rglob("*") if cache.is_dir() else ()
    model = sum(f.stat().st_size for f in files if f.is_file())
    # The image sets no TMPDIR, so this is /tmp: the house tmpfs (#43).
    st = os.statvfs(tempfile.gettempdir())
    tmp_used = (st.f_blocks - st.f_bfree) * st.f_frsize
    print(f"HOME={home} cache={model // MIB} MiB /tmp used={tmp_used // MIB} MiB")
    if str(home) != "/app/state" or model == 0 or tmp_used >= TMP_LIMIT:
        return "model cache is not under HOME=/app/state, or /tmp grew"
    return None


def check(log) -> str | None:
    """Return the first way the image broke the contract, or None."""
    server = subprocess.Popen(
        [
            "/usr/bin/python3.14", "-m", "mcp_memory_service.cli.main", "server",
            "--http", "--http-host", "127.0.0.1",
            "--storage-backend", "sqlite_vec",
        ],
        # The port goes by env rather than --http-port, so PORT is its one source.
        env={**os.environ, "MCP_API_KEY": KEY, "MCP_HTTP_PORT": str(PORT)},
        stdout=log,
        stderr=subprocess.STDOUT,
    )
    try:
        return wait_healthy(server.poll) or store_and_search() or model_loaded() or cache_placed()
    finally:
        server.terminate()
        try:
            server.wait(timeout=SHUTDOWN_TIMEOUT)
        except subprocess.TimeoutExpired:
            server.kill()


def main() -> int:
    # The server's log goes under HOME, not /tmp, so it doesn't count against /tmp.
    with tempfile.TemporaryFile(mode="w+", dir=pathlib.Path.home()) as log:
        try:
            failure = errors_reported() or check(log)
        except BaseException:
            failure = "raised"
            raise
        finally:
            if failure:
                log.seek(0)
                print("".join(log.readlines()[-40:]), file=sys.stderr)
    if failure:
        print(failure, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

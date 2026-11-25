"""The error paths of tmpfs_health against a stub server."""

import http.server
import sys
import threading
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).parent))

import tmpfs_health


class _Server:
    def __init__(self, status: int) -> None:
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self) -> None:
                self.send_response(status)
                self.end_headers()
                self.wfile.write(b"stub body")

            def log_message(self, *args) -> None:
                pass

        self.httpd = http.server.HTTPServer(("127.0.0.1", 0), Handler)

    def __enter__(self) -> int:
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        return self.httpd.server_address[1]

    def __exit__(self, *exc) -> None:
        self.httpd.shutdown()
        self.httpd.server_close()


class _Running:
    def poll(self):
        return None


class TmpfsHealthErrors(unittest.TestCase):
    def test_unknown_status_keeps_raw_number(self) -> None:
        with _Server(599) as port:
            tmpfs_health.PORT = port
            with self.assertRaises(tmpfs_health.HTTPStatusError) as ctx:
                tmpfs_health.api("health")
        self.assertEqual(ctx.exception.status, 599)
        self.assertIn("stub body", str(ctx.exception))

    def test_wait_healthy_fails_fast_on_401(self) -> None:
        with _Server(401) as port:
            tmpfs_health.PORT = port
            msg = tmpfs_health.wait_healthy(_Running())
        self.assertIn("401", msg)
        self.assertIn("stub body", msg)

    def test_wait_healthy_retries_503_then_times_out(self) -> None:
        # monotonic: deadline calc, then one in-time check, then past the deadline.
        clock = iter([0, 1, tmpfs_health.TIMEOUT + 1])
        with _Server(503) as port:
            tmpfs_health.PORT = port
            with (
                mock.patch.object(tmpfs_health.time, "monotonic", lambda: next(clock)),
                mock.patch.object(tmpfs_health.time, "sleep") as sleep,
            ):
                msg = tmpfs_health.wait_healthy(_Running())
        sleep.assert_called_once_with(3)
        self.assertIn(f"did not answer within {tmpfs_health.TIMEOUT}s", msg)
        self.assertIn("503", msg)


if __name__ == "__main__":
    unittest.main()

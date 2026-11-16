from __future__ import annotations

import datetime as _dt
import http.server
import json
import logging
import os
import platform
import socket
import threading
import time
from typing import Any


SERVER_PORT = 3000 if os.environ.get("PORT") == "8080" else int(os.environ.get("PORT", "3000"))
BANNER = "kenV1 | envlogger"
HEALTH_PASS = b"OK"
HEALTH_FAIL = b"FAIL"

_start_time = time.time()
_state_lock = threading.Lock()
_server: http.server.ThreadingHTTPServer | None = None
_server_thread: threading.Thread | None = None
_bot_alive = threading.Event()
_stop_event = threading.Event()

logging.basicConfig(
    level=os.environ.get("LOG_LEVEL", "INFO").upper(),
    format="[KeepAlive] %(asctime)s %(levelname)s %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("keep_alive")


# The supervisor uses these helpers to expose a small, local health endpoint.
def _now_utc() -> str:
    return _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _uptime_seconds() -> int:
    return max(0, int(time.time() - _start_time))


def _memory_mb() -> int:
    try:
        with open("/proc/self/status", encoding="utf-8") as handle:
            for line in handle:
                if line.startswith("VmRSS:"):
                    return int(line.split()[1]) // 1024
    except (OSError, ValueError):
        pass
    return 0


def _status_payload() -> dict[str, Any]:
    with _state_lock:
        alive = _bot_alive.is_set()
    return {
        "status": "ok" if alive else "starting",
        "uptime_s": _uptime_seconds(),
        "pid": os.getpid(),
        "hostname": socket.gethostname(),
        "platform": f"{platform.system()} {platform.release()}",
        "python": platform.python_version(),
        "memory_mb": _memory_mb(),
        "server_time_utc": _now_utc(),
    }


_PAGE_STYLE = """
<style>
body{background:#0d0d0d;color:#e0e0e0;font-family:system-ui,sans-serif;padding:2rem}
h1{color:#ff9900}.ok{color:#44ff88}.starting{color:#ffcc00}
table{border-collapse:collapse;max-width:720px;width:100%}
td,th{border:1px solid #333;padding:.5rem;text-align:left}
th{color:#ff9900;background:#1a1a1a}
</style>
"""


def _status_page() -> bytes:
    data = _status_payload()
    rows = "".join(
        f"<tr><th>{key}</th><td class='{value if key == 'status' else ''}'>{value}</td></tr>"
        for key, value in data.items()
    )
    return (
        "<!doctype html><html><head><meta charset='utf-8'>"
        f"<title>{BANNER}</title>{_PAGE_STYLE}</head><body>"
        f"<h1>{BANNER}</h1><table>{rows}</table>"
        "</body></html>"
    ).encode("utf-8")


class _HealthHandler(http.server.BaseHTTPRequestHandler):
    timeout = 5

    def log_message(self, _format: str, *_args: object) -> None:
        return

    def _send(self, status: int, content_type: str, body: bytes) -> None:
        try:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass

    def do_GET(self) -> None:
        path = self.path.split("?", 1)[0].rstrip("/") or "/"
        if path in {"/ping", "/health", "/heartbeat", "/status"}:
            self._send(200, "text/plain; charset=utf-8", HEALTH_PASS if _bot_alive.is_set() else HEALTH_FAIL)
        elif path in {"/json", "/api", "/api/status"}:
            body = json.dumps(_status_payload(), indent=2).encode("utf-8")
            self._send(200, "application/json; charset=utf-8", body)
        else:
            self._send(200, "text/html; charset=utf-8", _status_page())

    def do_HEAD(self) -> None:
        self._send(200, "text/plain; charset=utf-8", b"")


class _HealthServer(http.server.ThreadingHTTPServer):
    allow_reuse_address = True
    daemon_threads = True


def _serve() -> None:
    global _server
    try:
        _server = _HealthServer(("0.0.0.0", SERVER_PORT), _HealthHandler)
        log.info("Health server listening on :%s", SERVER_PORT)
        _server.serve_forever(poll_interval=0.5)
    except OSError:
        log.exception("Could not bind health server on :%s", SERVER_PORT)
    finally:
        if _server is not None:
            _server.server_close()
            _server = None


def keep_alive() -> None:
    global _server_thread
    if _server_thread and _server_thread.is_alive():
        return
    _stop_event.clear()
    _server_thread = threading.Thread(target=_serve, name="health-server", daemon=True)
    _server_thread.start()
    log.info("Health monitoring enabled")


def set_bot_alive(alive: bool) -> None:
    if alive:
        _bot_alive.set()
    else:
        _bot_alive.clear()


def stop_all() -> None:
    _stop_event.set()
    if _server is not None:
        _server.shutdown()
    if _server_thread and _server_thread.is_alive():
        _server_thread.join(timeout=3)


if __name__ == "__main__":
    def _stop(_signal: int, _frame: object) -> None:
        stop_all()

    import signal
    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)
    keep_alive()
    _bot_alive.set()
    try:
        while not _stop_event.wait(1):
            pass
    finally:
        stop_all()

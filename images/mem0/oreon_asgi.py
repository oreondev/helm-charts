"""ASGI entry point for the Mem0 server on Kubernetes.

Wraps the upstream FastAPI app (main:app) without modifying it:
- /healthz (process up) and /readyz (app database reachable), answered before the upstream request-log
  middleware, which would otherwise write a database row for every probe;
- Prometheus metrics for every route on a separate port (METRICS_PORT, default 9090, 0 disables), so
  they are never reachable through the public API;
- probe requests left out of the access log.
"""

import logging
import os

import anyio
from prometheus_client import start_http_server
from prometheus_fastapi_instrumentator import Instrumentator
from sqlalchemy import text

import main
from db import engine

PROBE_PATHS = {"/healthz", "/readyz"}

Instrumentator(excluded_handlers=list(PROBE_PATHS)).instrument(main.app)

_metrics_port = int(os.environ.get("METRICS_PORT", "9090") or 0)
if _metrics_port:
    start_http_server(_metrics_port)


class _ProbeFilter(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        args = record.args if isinstance(record.args, tuple) else ()
        return not (len(args) >= 3 and args[2] in PROBE_PATHS)


logging.getLogger("uvicorn.access").addFilter(_ProbeFilter())


def _database_ok() -> None:
    with engine.connect() as conn:
        conn.execute(text("SELECT 1"))


async def _respond(send, status: int, body: bytes) -> None:
    await send({"type": "http.response.start", "status": status,
                "headers": [(b"content-type", b"text/plain"), (b"cache-control", b"no-store")]})
    await send({"type": "http.response.body", "body": body})


async def app(scope, receive, send):
    if scope["type"] == "http" and scope["path"] in PROBE_PATHS:
        if scope["path"] == "/readyz":
            try:
                with anyio.fail_after(3):
                    await anyio.to_thread.run_sync(_database_ok)
            except Exception:
                await _respond(send, 503, b"database unavailable\n")
                return
        await _respond(send, 200, b"ok\n")
        return
    await main.app(scope, receive, send)

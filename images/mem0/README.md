# Mem0 images

Upstream Mem0 publishes no maintained server or dashboard images (the last `mem0/mem0-api-server` push predates auth and the dashboard), so the [mem0 chart](../../charts/mem0) uses these, built by [images.yml](../../.github/workflows/images.yml) from the upstream release in `VERSION` for amd64 and arm64:

- `ghcr.io/oreondev/mem0-server:<version>`: `server/` from the release tag, with `mem0ai==<version>`.
- `ghcr.io/oreondev/mem0-dashboard:<version>`: `server/dashboard/` from the release tag.

Compared with building upstream `server/Dockerfile` and `server/dashboard/Dockerfile` (measured on 2.2.1):

| | Upstream Dockerfile | These images |
|---|---|---|
| mem0ai version | whatever `mem0ai>=0.1.48` resolves to on the day of the build | pinned to the release |
| Server process | `uvicorn --reload`: a file-watcher parent plus a multiprocessing child (3 processes, 233 MiB) | one uvicorn process (210 MiB) |
| Starts without the compose volume | no: `/app/history` is missing, the history SQLite fails to open, and the reloader keeps the container "Up" with nothing listening | yes |
| Migrations | not run (only the dev compose file runs alembic) | `alembic upgrade head`, run by the chart's init container |
| Health check | none; `GET /` writes a request-log row per call | `/healthz`, `/readyz` (checks the database), not logged |
| Metrics | none | Prometheus on port 9090, separate from the API |
| User / filesystem | root (server), writable | uid 10001, works with a read-only root filesystem |
| Dashboard config | `sed` over `.next` in place on each start (needs a writable image) | substituted into a copy on an emptyDir |

The upstream code is not modified: `oreon_asgi.py` wraps `main:app`, `oreon_bootstrap.py` adds the database and first-admin setup steps, and `dashboard-entrypoint.sh` replaces the upstream entrypoint.

To move to a new Mem0 release, change `VERSION` and the chart's `appVersion` together. Mem0 is Apache-2.0 licensed.

# Mem0 self-hosted API server, built from a pinned upstream release.
#   docker build -f server.Dockerfile --build-arg UPSTREAM_VERSION=2.2.1 -t mem0-server .
# Differences from upstream server/Dockerfile: mem0ai pinned to the release (upstream installs whatever
# ">=0.1.48" resolves to at build time), no uvicorn --reload (a file watcher in production), non-root,
# probe and metrics endpoints added by oreon_asgi.py without changing the upstream code.
ARG PYTHON_IMAGE=python:3.12-slim-bookworm

FROM ${PYTHON_IMAGE} AS source
ARG UPSTREAM_VERSION=2.2.1
ADD https://github.com/mem0ai/mem0/archive/refs/tags/v${UPSTREAM_VERSION}.tar.gz /tmp/mem0.tar.gz
RUN mkdir /src && tar -xzf /tmp/mem0.tar.gz -C /src --strip-components=1 \
    && rm -rf /src/server/dashboard /src/server/dev.Dockerfile /src/server/docker-compose.yaml

FROM ${PYTHON_IMAGE}
ARG UPSTREAM_VERSION=2.2.1
LABEL org.opencontainers.image.title="mem0-server" \
      org.opencontainers.image.version="${UPSTREAM_VERSION}" \
      org.opencontainers.image.source="https://github.com/oreondev/helm-charts" \
      org.opencontainers.image.description="Mem0 self-hosted API server (upstream release, rebuilt for Kubernetes)" \
      org.opencontainers.image.licenses="Apache-2.0"
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    HISTORY_DB_PATH=/app/history/history.db \
    MEM0_TELEMETRY_STATE_PATH=/app/history/telemetry.json \
    MEM0_DIR=/app/history \
    PYTHONPATH=/app
WORKDIR /app
COPY --from=source /src/server/requirements.txt /tmp/requirements.txt
RUN pip install -r /tmp/requirements.txt "mem0ai==${UPSTREAM_VERSION}" \
        "prometheus-client>=0.21,<1" "prometheus-fastapi-instrumentator>=7.0,<8" \
    && rm /tmp/requirements.txt
COPY --from=source /src/server/ /app/
COPY oreon_asgi.py oreon_bootstrap.py /app/
RUN useradd --uid 10001 --gid 0 --no-create-home --home-dir /app mem0 \
    && mkdir -p /app/history && chown 10001:0 /app/history && chmod 770 /app/history
USER 10001
EXPOSE 8000 9090
CMD ["uvicorn", "oreon_asgi:app", "--host", "0.0.0.0", "--port", "8000", "--proxy-headers", "--timeout-graceful-shutdown", "20"]

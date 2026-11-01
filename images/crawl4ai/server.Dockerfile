# Crawl4AI server, rebuilt from the upstream image onto a clean base.
#   docker build -f server.Dockerfile --build-arg UPSTREAM_VERSION=0.9.5 -t crawl4ai-server .
# The upstream image (unclecode/crawl4ai) keeps its whole build environment: compilers and -dev packages,
# kernel headers, the GStreamer/FFmpeg libraries that Playwright's WebKit and Firefox need (Crawl4AI only
# drives Chromium), and the build project with old lock files in /tmp/project. Scanners report thousands of
# findings for packages it never runs. This image keeps the same Python, packages, app and browsers on a
# slim base with only Chromium's runtime libraries and Redis, and upgrades the Python packages that have
# fixes within Crawl4AI's version ranges. The upstream code is not modified.
ARG UPSTREAM_VERSION=0.9.5
ARG PYTHON_IMAGE=python:3.12-slim-bookworm

FROM unclecode/crawl4ai:${UPSTREAM_VERSION} AS upstream
USER root
# Security fixes available within Crawl4AI's requirements (pip check must still pass).
RUN pip install --no-cache-dir --upgrade \
        "pillow>=13.0.0" "pyjwt>=2.15.0" "pypdf>=6.21.4" "nltk>=3.10.4" "brotli>=1.2.1" \
        "certifi>=2026.10.18" "filelock>=4.2.1" \
    && pip check \
    # litellm ships old copies of its enterprise add-on as wheels; nothing installs them at runtime.
    && rm -rf /usr/local/lib/python3.12/site-packages/litellm/proxy/enterprise/dist \
    && rm -f /usr/local/lib/python3.12/ensurepip/_bundled/*.whl \
    # pip is not used at runtime, and its vendored certifi, urllib3 and msgpack are older than the installed ones.
    && python -m pip uninstall -y pip \
    # Bytecode for everything, so a read-only root filesystem does not mean compiling on every start.
    && python -m compileall -q -j 0 /usr/local/lib/python3.12 /app >/dev/null || true

FROM ${PYTHON_IMAGE}
ARG UPSTREAM_VERSION=0.9.5
LABEL org.opencontainers.image.title="crawl4ai-server" \
      org.opencontainers.image.version="${UPSTREAM_VERSION}" \
      org.opencontainers.image.source="https://github.com/oreondev/helm-charts" \
      org.opencontainers.image.description="Crawl4AI server (upstream release on a slim base: no build tools, Chromium only)" \
      org.opencontainers.image.licenses="Apache-2.0"
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONFAULTHANDLER=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    C4AI_VERSION=${UPSTREAM_VERSION} \
    PYTHON_ENV=production \
    REDIS_HOST=localhost \
    REDIS_PORT=6379 \
    PLAYWRIGHT_BROWSERS_PATH=/home/appuser/.cache/ms-playwright

# Python, its packages and the console scripts exactly as upstream installed them. The base image's own
# Python is removed first, or its older pip would be left behind next to upstream's.
RUN rm -rf /usr/local/lib/python3.12 /usr/local/bin/*
COPY --from=upstream /usr/local/ /usr/local/

# Chromium's runtime libraries (Playwright's own list for chromium, no WebKit or Firefox), Redis for the
# chart's sidecar, then everything apt brought along that is only needed to install.
RUN apt-get update \
    && apt-get upgrade -y --no-install-recommends \
    && python -m playwright install-deps chromium \
    && apt-get install -y --no-install-recommends redis-server \
    && apt-get purge -y --auto-remove \
    && rm -rf /var/lib/apt/lists/* /var/cache/apt/* /var/log/apt /var/log/dpkg.log \
    && groupadd --gid 999 appuser \
    && useradd --uid 999 --gid 999 --create-home --home-dir /home/appuser --shell /usr/sbin/nologin appuser

COPY --from=upstream --chown=appuser:appuser /home/appuser/.cache/ms-playwright /home/appuser/.cache/ms-playwright
COPY --from=upstream --chown=appuser:appuser /app /app
WORKDIR /app
USER 999
EXPOSE 11235
CMD ["gunicorn", "--bind", "0.0.0.0:11235", "--workers", "1", "--worker-class", "uvicorn.workers.UvicornWorker", "--timeout", "1800", "server:app"]

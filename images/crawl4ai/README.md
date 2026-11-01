# Crawl4AI image

`ghcr.io/oreondev/crawl4ai-server:<version>` is the upstream [Crawl4AI](https://github.com/unclecode/crawl4ai) image (`unclecode/crawl4ai:<version>`, version in `VERSION`) rebuilt on a slim base for the [crawl4ai chart](../../charts/crawl4ai). [images.yml](../../.github/workflows/images.yml) builds it for amd64 and arm64, scans it with Trivy, signs it with cosign and rebuilds it every week.

What changes, and what does not:

- **Same:** Python 3.12 and every installed package, the `/app` server code, and the Chromium builds Playwright and Patchright use, copied from the upstream image. The Crawl4AI code is not modified.
- **Removed:** the build toolchain (`build-essential`, gcc, about 20 `-dev` packages, kernel headers), the GStreamer, FFmpeg and OpenEXR libraries that only Playwright's WebKit and Firefox need, the build project and its old lock files in `/tmp/project`, old `litellm_enterprise` wheels bundled inside litellm, and pip (not used at runtime; its vendored certifi and urllib3 are older than the installed ones).
- **Upgraded** within Crawl4AI's version ranges (`pip check` passes): pillow 13, PyJWT 2.15, pypdf 6.21, nltk 3.10.4, brotli 1.2.1, certifi and filelock.
- **Base:** `python:3.12-slim-bookworm` with Chromium's runtime libraries (`playwright install-deps chromium`), Redis for the chart's sidecar, and current Debian security updates.
- **Runs as** uid 999 (`appuser`, as upstream), with bytecode precompiled so a read-only root filesystem does not slow the start.

Measured on 0.9.5 with Trivy 0.75:

| | `unclecode/crawl4ai` | this image |
|---|---|---|
| Findings (critical / high / medium / low / unknown) | 5,929 (68 / 868 / 3,210 / 1,724 / 59) | 481 (4 / 84 / 197 / 186 / 10) |
| Findings with a fixed version available | 1,743 | 0 |
| Size unpacked | 5.7 GB | 2.7 GB |

The remaining findings are in Debian bookworm packages that have no fix yet. Through the chart on a kind cluster, both images start, crawl and stop in the same time (see the chart README).

The image is meant for the chart: gunicorn runs as PID 1 and Redis as a sidecar container. The upstream `entrypoint.sh` and `supervisord.conf` are still in `/app` but supervisord is not installed.

To move to a new Crawl4AI release, change `VERSION` and the chart's `appVersion` together. Crawl4AI is Apache-2.0 licensed.

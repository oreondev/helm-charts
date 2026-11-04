#!/usr/bin/env python3
"""Compare each application chart's appVersion with the newest upstream version (.github/upstream.yaml).

    python3 .github/scripts/check-upstream.py            # report only
    GITHUB_TOKEN=... GITHUB_REPOSITORY=owner/repo python3 .github/scripts/check-upstream.py --issues

With --issues, opens one issue per chart that is behind ("<chart>: upstream <version> available") or updates
the open one when a newer version appears. Prints a Markdown table for the job summary.
"""
import json
import os
import re
import subprocess
import sys
import urllib.parse
import urllib.request

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def get(url, headers=None):
    req = urllib.request.Request(url, headers={"User-Agent": "oreondev-helm-charts", **(headers or {})})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r), r.headers


def vkey(v):
    # "2.11.621", "1.9.4" or SearXNG's dated "2026.10.29-cff884f98": compare the numeric part before any "-".
    return tuple(int(x) for x in v.split("-")[0].split("."))


def newest(tags, pattern):
    rx = re.compile(pattern)
    found = [m.group(1) for t in tags if (m := rx.match(t))]
    return max(found, key=vkey) if found else None


def dockerhub_tags(image):
    tags, url = [], f"https://hub.docker.com/v2/repositories/{image}/tags?page_size=100&ordering=last_updated"
    for _ in range(5):
        data, _ = get(url)
        tags += [t["name"] for t in data.get("results", [])]
        url = data.get("next")
        if not url:
            break
    return tags


def ghcr_token(image):
    data, _ = get(f"https://ghcr.io/token?scope=repository:{image}:pull")
    return data["token"]


def ghcr_tags(image):
    auth = {"Authorization": f"Bearer {ghcr_token(image)}"}
    tags, last = [], ""
    for _ in range(50):
        q = "n=1000" + (f"&last={urllib.parse.quote(last)}" if last else "")
        data, _ = get(f"https://ghcr.io/v2/{image}/tags/list?{q}", auth)
        page = data.get("tags") or []
        if not page:
            break
        tags += page
        last = page[-1]
    return tags


def ghcr_digest(image, tag="latest"):
    req = urllib.request.Request(
        f"https://ghcr.io/v2/{image}/manifests/{tag}", method="HEAD",
        headers={"Authorization": f"Bearer {ghcr_token(image)}", "User-Agent": "oreondev-helm-charts",
                 "Accept": "application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.headers["Docker-Content-Digest"]


def git_tags(repo):
    out = subprocess.run(["git", "ls-remote", "--tags", "--refs", repo], check=True, capture_output=True, text=True).stdout
    return [line.split("refs/tags/", 1)[1] for line in out.splitlines() if "refs/tags/" in line]


def dig(d, path):
    for p in path.split("."):
        d = (d or {}).get(p)
    return d


def check():
    cfg = yaml.safe_load(open(os.path.join(ROOT, ".github", "upstream.yaml")))
    results = []
    for chart, c in cfg.items():
        meta = yaml.safe_load(open(os.path.join(ROOT, "charts", chart, "Chart.yaml")))
        values = yaml.safe_load(open(os.path.join(ROOT, "charts", chart, "values.yaml")))
        current = str(meta["appVersion"])
        src = c["source"]
        tags = {"dockerhub": lambda: dockerhub_tags(c["image"]), "ghcr": lambda: ghcr_tags(c["image"]),
                "git": lambda: git_tags(c["repo"])}[src]()
        latest = newest(tags, c["pattern"])
        notes = []
        for d in c.get("digests", []):
            pinned = dig(values, d["values"])
            live = ghcr_digest(d["image"])
            if pinned != live:
                notes.append(f"`{d['image']}:latest` is now `{live}` (chart pins `{pinned}`, `{d['values']}`)")
        if c.get("imageVersionFile"):
            iv = open(os.path.join(ROOT, c["imageVersionFile"])).read().strip()
            if iv != current:
                notes.append(f"`{c['imageVersionFile']}` is {iv}, appVersion is {current}")
        behind = latest is not None and vkey(latest) > vkey(current)
        results.append({"chart": chart, "current": current, "latest": latest, "behind": behind, "notes": notes,
                        "source": c.get("image") or c.get("repo")})
    return results


def issues(results):
    token, repo = os.environ["GITHUB_TOKEN"], os.environ["GITHUB_REPOSITORY"]
    api = f"https://api.github.com/repos/{repo}"
    auth = {"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json"}

    def call(method, url, body=None):
        req = urllib.request.Request(url, method=method, data=json.dumps(body).encode() if body else None,
                                     headers={**auth, "User-Agent": "oreondev-helm-charts", "Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.load(r)

    open_issues = call("GET", f"{api}/issues?state=open&labels=upstream-release&per_page=100")
    for r in results:
        if not (r["behind"] or r["notes"]):
            continue
        prefix = f"{r['chart']}: upstream "
        title = f"{prefix}{r['latest']} available" if r["behind"] else f"{r['chart']}: pinned images changed upstream"
        body = "\n".join([
            f"`charts/{r['chart']}` deploys **{r['current']}**; the newest upstream version is **{r['latest']}** ({r['source']}).",
            "", *[f"- {n}" for n in r["notes"]], "",
            "Before releasing: read the upstream changelog, update appVersion (and the image VERSION file if there is one),",
            "re-test on the dev stack (install, upgrade from the previous chart version), bump the chart version and",
            "add an artifacthub.io/changes entry and a CHANGELOG.md section.",
        ])
        existing = next((i for i in open_issues if i["title"].startswith(r["chart"] + ":")), None)
        if existing and existing["title"] == title:
            continue
        if existing:
            call("PATCH", f"{api}/issues/{existing['number']}", {"title": title, "body": body})
        else:
            call("POST", f"{api}/issues", {"title": title, "body": body, "labels": ["upstream-release"]})


def main():
    results = check()
    lines = ["| Chart | appVersion | Upstream | Status |", "|---|---|---|---|"]
    for r in results:
        status = "update available" if r["behind"] else "current"
        if r["notes"]:
            status += "; " + "; ".join(r["notes"])
        lines.append(f"| {r['chart']} | {r['current']} | {r['latest']} | {status} |")
    print("\n".join(lines))
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        open(os.environ["GITHUB_STEP_SUMMARY"], "a").write("\n".join(lines) + "\n")
    if "--issues" in sys.argv:
        issues(results)


if __name__ == "__main__":
    main()

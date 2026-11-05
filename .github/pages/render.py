#!/usr/bin/env python3
"""Render the GitHub Pages site from the Helm repository index.

    python3 .github/pages/render.py <gh-pages checkout> [<main checkout>]

Reads index.yaml in that directory and writes:
- index.html: the landing page with the chart table;
- <chart>/index.html: one docs page per released chart, from charts/<chart>/README.md on main;
- sitemap.xml, plus the logo and favicon.
Every page carries a canonical link to https://www.oreonit.com/helm-charts/, where a Cloudflare Worker serves this
site, so search engines treat oreonit.com as the original and the github.io copy as a duplicate.
READMEs come from <main checkout> when given, otherwise from `git show origin/main:...` (the release workflow).
The paths written are listed in .generated (one per line) so the workflow commits only those.
"""
import html
import os
import posixpath
import re
import shutil
import subprocess
import sys

import markdown
import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
SITE = "https://www.oreonit.com/"
BASE = SITE + "helm-charts/"
REPO = "https://github.com/oreondev/helm-charts"
UTM = "?utm_source=helm-charts&utm_medium=referral&utm_campaign=oss"

# Bar linking the Oreon IT open-source docs sites; same markup and colours as the Harbor Operator and
# Harbor MCP sites (oreondev/harbor-resource-operator overrides/partials/products.html). Full URLs, so the
# links also work on oreondev.github.io. A new site goes into all three.
PRODUCT_BAR = """<nav class="oreon-products" aria-label="Oreon IT open source">
  <div class="oreon-products__inner">
    <a class="oreon-products__home" href="https://www.oreonit.com/">Oreon IT</a>
    <span class="oreon-products__sep" aria-hidden="true">/</span>
    <span class="oreon-products__label">Open source</span>
    <ul class="oreon-products__list">
      <li><a href="https://www.oreonit.com/harbor-operator/">Harbor Operator</a></li>
      <li><a href="https://www.oreonit.com/harbor-mcp/">Harbor MCP</a></li>
      <li><a href="https://www.oreonit.com/helm-charts/" class="oreon-products__current" aria-current="page">Helm charts</a></li>
    </ul>
  </div>
</nav>"""

# Which charts each service builds on, so the card reads as "the people who wrote these", not an advert.
SERVICES = [
    ("SRE as a service", "sre-as-a-service/",
     "SLOs, error budgets and on-call that pages for the right things.",
     ["slo-burn-rate-alerts", "blackbox-slo-probes", "alertmanager-routing-baseline"]),
    ("Observability and monitoring", "observability-and-monitoring-consultancy-services/",
     "OpenTelemetry, Prometheus and Grafana set up end to end.",
     ["otel-collector-baseline", "slo-burn-rate-alerts"]),
    ("Kubernetes production readiness", "production-readiness-audit-for-kubernetes/",
     "A 48-point audit of EKS, GKE or AKS, then the fixes.",
     ["kyverno-production-policies", "namespace-baseline", "gateway-api-baseline", "velero-backup-schedules"]),
    ("Cloud cost review", "cloud-cost-optimization-review/",
     "Where the cluster bill goes, and a savings plan with the changes made.",
     ["k8s-cost-waste-alerts"]),
]


def esc(s):
    return html.escape(str(s), quote=True)


# Charts published elsewhere (not in this repository's index), listed so the table covers every Oreon IT chart.
# They link to their own docs site; the version cell says where to install from instead of a version that would go stale.
EXTERNAL = [
    ("harbor-resource-operator", "https://www.oreonit.com/harbor-operator/", "OCI",
     "Kubernetes operator for Harbor: projects, robot accounts, members, replication, webhooks, retention and "
     "garbage collection as custom resources. Installed from oci://ghcr.io/oreondev/charts/harbor-resource-operator."),
]


def main(out, src=None):
    idx = yaml.safe_load(open(os.path.join(out, "index.yaml")))
    rows = []
    for name in sorted(idx["entries"]):
        e = sorted(idx["entries"][name], key=lambda x: x["created"], reverse=True)[0]
        rows.append((name,
            f'<tr><td><a href="{esc(name)}/"><code>{esc(name)}</code></a></td>'
            f'<td>{esc(e["version"])}</td><td>{esc(e.get("description", ""))}</td></tr>'))
    for name, url, version, desc in EXTERNAL:
        rows.append((name,
            f'<tr><td><a href="{esc(url)}"><code>{esc(name)}</code></a></td>'
            f'<td>{esc(version)}</td><td>{esc(desc)}</td></tr>'))
    rows = [r for _, r in sorted(rows)]
    tiles = []
    for title, path, line, charts in SERVICES:
        chips = "".join(f"<span>{esc(c)}</span>" for c in charts)
        tiles.append(f'<a class="tile" href="{SITE}{path}{UTM}"><strong>{esc(title)} →</strong>'
                     f'<em>{esc(line)}</em><div class="chips">{chips}</div></a>')

    page = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Oreon IT Helm charts</title>
<meta name="description" content="Helm charts for Kubernetes reliability: SLO burn-rate alerts, OpenTelemetry collectors, alert routing, probes, policies, guardrails, cost and backups. Maintained by Oreon IT.">
<link rel="canonical" href="{BASE}">
<link rel="icon" href="favicon.svg" type="image/svg+xml">
<style>
:root{{--bg:#fff;--fg:#14213d;--muted:#5b6478;--line:#e3e6ee;--code:#f3f5f9;--accent:#e8590c}}
@media (prefers-color-scheme:dark){{:root{{--bg:#0b1220;--fg:#e8ecf4;--muted:#9aa3b5;--line:#1f2a40;--code:#141d30;--accent:#ff8a3d}}}}
*{{box-sizing:border-box}}
body{{margin:0;background:var(--bg);color:var(--fg);font:16px/1.55 system-ui,-apple-system,"Segoe UI",sans-serif}}
main{{max-width:980px;margin:0 auto;padding:40px 16px 56px}}
h1{{margin:0 0 6px;font-size:30px;letter-spacing:-.01em}}
.badges{{margin:4px 0 12px}} .badges img{{display:block}}
.lead{{color:var(--muted);margin:0 0 20px}}
a{{color:var(--accent)}}
pre{{background:var(--code);border:1px solid var(--line);padding:14px 16px;border-radius:10px;overflow-x:auto;margin:0}}
table{{width:100%;border-collapse:collapse;margin:24px 0 40px}}
td,th{{text-align:left;padding:11px 8px;border-bottom:1px solid var(--line);vertical-align:top}}
th{{font-size:12px;text-transform:uppercase;letter-spacing:.06em;color:var(--muted);font-weight:600}}
td:nth-child(1){{white-space:nowrap}}
td:nth-child(2){{white-space:nowrap;color:var(--muted)}}
td a{{text-decoration:none}} td a:hover{{text-decoration:underline}}
.card{{position:relative;overflow:hidden;border-radius:18px;padding:32px;color:#e8ecf4;
  background:radial-gradient(120% 140% at 100% 0%,rgba(245,130,21,.28) 0,rgba(245,130,21,0) 45%),linear-gradient(135deg,#0f1d3a 0%,#14274d 60%,#0b1430 100%);
  box-shadow:0 20px 50px -25px rgba(10,20,45,.6)}}
.card:before{{content:"";position:absolute;left:0;top:0;bottom:0;width:5px;background:linear-gradient(#fdb813,#e23b26)}}
.brand{{display:flex;align-items:center;gap:18px;flex-wrap:wrap}}
.brand img{{height:52px;width:auto}}
.card h2{{margin:0;font-size:22px;color:#fff}}
.card p{{color:#b9c3d6;margin:10px 0 0;max-width:680px}}
.tiles{{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:12px;margin:24px 0}}
.tile{{display:block;padding:16px 18px;border-radius:12px;background:rgba(255,255,255,.06);border:1px solid rgba(255,255,255,.1);
  color:#fff;text-decoration:none;transition:background .15s,border-color .15s,transform .15s}}
.tile:hover{{background:rgba(255,255,255,.1);border-color:rgba(253,184,19,.55);transform:translateY(-2px)}}
.tile strong{{display:block;font-size:16px}}
.tile em{{display:block;font-style:normal;color:#b9c3d6;font-size:14px;margin:4px 0 10px}}
.chips{{display:flex;flex-wrap:wrap;gap:6px}}
.chips span{{font:12px/1.2 ui-monospace,SFMono-Regular,Menlo,monospace;padding:4px 7px;border-radius:6px;background:rgba(253,184,19,.12);color:#fdd27a}}
.cta{{display:flex;flex-wrap:wrap;gap:12px;align-items:center}}
.btn{{display:inline-block;padding:12px 18px;border-radius:10px;font-weight:600;text-decoration:none}}
.btn.primary{{background:linear-gradient(90deg,#f58215,#e23b26);color:#fff}}
.btn.primary:hover{{filter:brightness(1.08)}}
.btn.ghost{{color:#fff;border:1px solid rgba(255,255,255,.3)}}
.btn.ghost:hover{{border-color:#fff}}
footer{{margin-top:28px;font-size:14px;color:var(--muted);display:flex;flex-wrap:wrap;gap:6px 18px}}
footer a{{color:var(--muted)}}
@media (max-width:700px){{.tiles{{grid-template-columns:1fr}} .card{{padding:24px 20px}} td:nth-child(3),th:nth-child(3){{display:none}} td:nth-child(1){{white-space:normal;overflow-wrap:anywhere}}}}
.oreon-products{{background-color:#0b1323;color:#c9d1e0;font-size:13px;line-height:36px}}
.oreon-products__inner{{display:flex;align-items:center;gap:12px;max-width:1220px;margin:0 auto;padding:0 16px;white-space:nowrap;overflow-x:auto}}
.oreon-products a{{color:inherit;text-decoration:none}}
.oreon-products a:hover,.oreon-products a:focus{{color:#fdb813}}
.oreon-products__home{{font-weight:700;color:#ffffff !important}}
.oreon-products__sep,.oreon-products__label{{opacity:.6}}
.oreon-products__list{{display:flex;gap:24px;margin:0 0 0 auto;padding:0;list-style:none}}
.oreon-products__current{{color:#f58215 !important;font-weight:700;box-shadow:inset 0 -2px 0 #f58215}}
@media screen and (max-width:720px){{.oreon-products__label,.oreon-products__sep{{display:none}} .oreon-products__list{{gap:14px}} .oreon-products__inner{{gap:10px;padding:0 12px}}}}
@media screen and (max-width:380px){{.oreon-products{{font-size:12px}} .oreon-products__list{{gap:12px}}}}
</style></head><body>
{PRODUCT_BAR}
<main>
<h1>Oreon IT Helm charts</h1>
<p class="badges"><a href="https://artifacthub.io/packages/search?repo=oreonit"><img src="https://img.shields.io/endpoint?url=https://artifacthub.io/badge/repository/oreonit" alt="Artifact Hub" height="20"></a></p>
<p class="lead">Production building blocks for Kubernetes reliability, observability and cost. Tested against the real controllers they target. Source, docs and issues on <a href="https://github.com/oreondev/helm-charts">GitHub</a>.</p>
<pre><code>helm repo add oreonit https://oreondev.github.io/helm-charts
helm repo update
helm search repo oreonit/</code></pre>
<table><thead><tr><th>Chart</th><th>Version</th><th>Description</th></tr></thead><tbody>
{chr(10).join(rows)}
</tbody></table>

<section class="card" aria-labelledby="by">
  <div class="brand"><img src="oreon-logo.svg" alt="Oreon IT"><h2 id="by">Built and maintained by Oreon IT</h2></div>
  <p>We are a London cloud, DevOps and SRE consultancy. These are the charts we run on client platforms on Google Cloud, AWS and Azure. If you want them rolled out and tuned to your services, or the whole platform made production-ready, that is what we do.</p>
  <div class="tiles">
{chr(10).join("    " + t for t in tiles)}
  </div>
  <div class="cta">
    <a class="btn primary" href="{SITE}book-a-consultation/{UTM}">Book a free 30-minute call</a>
    <a class="btn ghost" href="{SITE}case-studies/{UTM}">See case studies</a>
  </div>
</section>

<footer>
  <span>MIT licence</span>
  <a href="https://github.com/oreondev/helm-charts">Source</a>
  <a href="https://github.com/oreondev/helm-charts/issues">Report an issue</a>
  <a href="{SITE}{UTM}">oreonit.com</a>
</footer>
</main></body></html>
"""
    open(os.path.join(out, "index.html"), "w").write(page)
    for f in ("oreon-logo.svg", "favicon.svg"):
        shutil.copy(os.path.join(HERE, f), os.path.join(out, f))
    # GitHub Pages runs Jekyll unless .nojekyll exists, and Jekyll fails on the {{ }} in Helm examples.
    open(os.path.join(out, ".nojekyll"), "w").close()
    generated = ["index.html", "oreon-logo.svg", "favicon.svg", "sitemap.xml", ".nojekyll"]

    css = page[page.index("<style>") + 7:page.index("</style>")]
    released = set(idx["entries"])
    urls = [(BASE, max(str(v[0]["created"])[:10] for v in idx["entries"].values()))]
    for name in sorted(released):
        e = sorted(idx["entries"][name], key=lambda x: x["created"], reverse=True)[0]
        readme = read_readme(name, src)
        if readme is None:
            continue
        os.makedirs(os.path.join(out, name), exist_ok=True)
        open(os.path.join(out, name, "index.html"), "w").write(chart_page(name, e, readme, released, css))
        generated.append(f"{name}/index.html")
        urls.append((f"{BASE}{name}/", str(e["created"])[:10]))

    sm = ['<?xml version="1.0" encoding="UTF-8"?>', '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">']
    sm += [f"  <url><loc>{esc(u)}</loc><lastmod>{d}</lastmod></url>" for u, d in urls]
    sm.append("</urlset>")
    open(os.path.join(out, "sitemap.xml"), "w").write("\n".join(sm) + "\n")
    open(os.path.join(out, ".generated"), "w").write("\n".join(generated) + "\n")


def read_readme(name, src):
    path = f"charts/{name}/README.md"
    if src:
        f = os.path.join(src, path)
        return open(f).read() if os.path.exists(f) else None
    r = subprocess.run(["git", "show", f"origin/main:{path}"], capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else None


def fix_link(href, name, released):
    """README links are relative to charts/<name>/ in the repo; point them at the docs site or GitHub."""
    if re.match(r"^[a-z]+:|^#|^//", href):
        return href
    target, _, frag = href.partition("#")
    resolved = posixpath.normpath(posixpath.join("charts", name, target))
    m = re.fullmatch(r"charts/([a-z0-9-]+)/?(README\.md)?", resolved)
    if m and m.group(1) in released:
        url = "./" if m.group(1) == name else f"../{m.group(1)}/"
    elif m:
        return None  # a chart that is not released yet: no page and maybe not on main, so no link
    else:
        kind = "blob" if posixpath.splitext(resolved)[1] else "tree"
        url = f"{REPO}/{kind}/main/{resolved}"
    return url + (f"#{frag}" if frag else "")


def chart_page(name, e, readme, released, css):
    body = markdown.markdown(readme, extensions=["tables", "fenced_code", "toc"], output_format="html5")
    def relink(m):
        url = fix_link(html.unescape(m.group(2)), name, released)
        return m.group(1) + esc(url) + m.group(3) if url else m.group(1) + "#" + m.group(3)
    body = re.sub(r'(<(?:a|img)\b[^>]*?\b(?:href|src)=")([^"]+)(")', relink, body)
    body = re.sub(r'<a href="#">(.*?)</a>', r"\1", body)  # unreleased-chart links become plain text
    body = re.sub(r"^\s*<h1[^>]*>.*?</h1>", "", body, count=1, flags=re.S)  # the page has its own h1
    desc = e.get("description", "")
    title = f"{name} Helm chart"
    app = f' · app {esc(e["appVersion"])}' if e.get("appVersion") else ""
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>{esc(title)} | Oreon IT</title>
<meta name="description" content="{esc(desc)[:155]}">
<link rel="canonical" href="{BASE}{esc(name)}/">
<link rel="icon" href="../favicon.svg" type="image/svg+xml">
<style>{css}
.crumb{{font-size:14px;color:var(--muted);margin:0 0 10px}} .crumb a{{color:var(--muted)}}
.meta{{color:var(--muted);margin:0 0 22px}}
.doc h2{{margin:34px 0 10px;font-size:22px}} .doc h3{{margin:24px 0 8px;font-size:18px}}
.doc table{{margin:16px 0 24px;display:block;overflow-x:auto}} .doc td,.doc th{{white-space:normal}}
.doc code{{background:var(--code);padding:1px 5px;border-radius:5px;font-size:.92em}} .doc pre code{{padding:0;background:none}}
.doc pre{{margin:12px 0 18px}}
.card.small{{padding:24px;margin-top:40px}}
</style></head><body>
{PRODUCT_BAR}
<main>
<p class="crumb"><a href="../">Oreon IT Helm charts</a> / {esc(name)}</p>
<h1>{esc(title)}</h1>
<p class="meta">Version {esc(e["version"])}{app} · MIT · <a href="{REPO}/tree/main/charts/{esc(name)}">source</a> · <a href="https://artifacthub.io/packages/helm/oreonit/{esc(name)}">Artifact Hub</a></p>
<article class="doc">
{body}
</article>
<section class="card small" aria-labelledby="by">
  <div class="brand"><img src="../oreon-logo.svg" alt="Oreon IT"><h2 id="by">Maintained by Oreon IT</h2></div>
  <p>A London cloud, DevOps and SRE consultancy. If you want this chart rolled out and tuned for your platform, we can help.</p>
  <div class="cta" style="margin-top:18px"><a class="btn primary" href="{SITE}book-a-consultation/{UTM}">Book a free 30-minute call</a>
  <a class="btn ghost" href="../">All charts</a></div>
</section>
<footer><span>MIT licence</span><a href="{REPO}">Source</a><a href="{REPO}/issues">Report an issue</a><a href="{SITE}{UTM}">oreonit.com</a></footer>
</main></body></html>
"""


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else ".", sys.argv[2] if len(sys.argv) > 2 else None)

#!/usr/bin/env python3
"""Render the GitHub Pages landing page from the Helm repository index.

    python3 .github/pages/render.py <gh-pages checkout>

Reads index.yaml in that directory, writes index.html and copies the logo and favicon next to it. The release
workflow runs it after chart-releaser, so the chart table always shows the latest version of every chart.
"""
import html
import os
import shutil
import sys

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
SITE = "https://www.oreonit.com/"
UTM = "?utm_source=helm-charts&utm_medium=referral&utm_campaign=oss"

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
PARTNERS = ["Google Cloud Partner", "IBM Silver Partner", "SUSE", "Datadog", "Elastic", "DigitalOcean"]


def esc(s):
    return html.escape(str(s), quote=True)


def main(out):
    idx = yaml.safe_load(open(os.path.join(out, "index.yaml")))
    rows = []
    for name in sorted(idx["entries"]):
        e = sorted(idx["entries"][name], key=lambda x: x["created"], reverse=True)[0]
        rows.append(
            f'<tr><td><a href="https://github.com/oreondev/helm-charts/tree/main/charts/{esc(name)}"><code>{esc(name)}</code></a></td>'
            f'<td>{esc(e["version"])}</td><td>{esc(e.get("description", ""))}</td></tr>')
    tiles = []
    for title, path, line, charts in SERVICES:
        chips = "".join(f"<span>{esc(c)}</span>" for c in charts)
        tiles.append(f'<a class="tile" href="{SITE}{path}{UTM}"><strong>{esc(title)} →</strong>'
                     f'<em>{esc(line)}</em><div class="chips">{chips}</div></a>')
    partners = " · ".join(esc(p) for p in PARTNERS)

    page = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Oreon IT Helm charts</title>
<meta name="description" content="Helm charts for Kubernetes reliability: SLO burn-rate alerts, OpenTelemetry collectors, alert routing, probes, policies, guardrails, cost and backups. Maintained by Oreon IT.">
<link rel="icon" href="favicon.svg" type="image/svg+xml">
<style>
:root{{--bg:#fff;--fg:#14213d;--muted:#5b6478;--line:#e3e6ee;--code:#f3f5f9;--accent:#e8590c}}
@media (prefers-color-scheme:dark){{:root{{--bg:#0b1220;--fg:#e8ecf4;--muted:#9aa3b5;--line:#1f2a40;--code:#141d30;--accent:#ff8a3d}}}}
*{{box-sizing:border-box}}
body{{margin:0;background:var(--bg);color:var(--fg);font:16px/1.55 system-ui,-apple-system,"Segoe UI",sans-serif}}
main{{max-width:980px;margin:0 auto;padding:40px 16px 56px}}
h1{{margin:0 0 6px;font-size:30px;letter-spacing:-.01em}}
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
.partners{{margin-top:22px;font-size:13px;color:#8e9ab2}}
footer{{margin-top:28px;font-size:14px;color:var(--muted);display:flex;flex-wrap:wrap;gap:6px 18px}}
footer a{{color:var(--muted)}}
@media (max-width:700px){{.tiles{{grid-template-columns:1fr}} .card{{padding:24px 20px}} td:nth-child(3),th:nth-child(3){{display:none}}}}
</style></head><body><main>
<h1>Oreon IT Helm charts</h1>
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
  <div class="partners">{partners}</div>
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


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else ".")

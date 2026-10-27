#!/usr/bin/env python3
"""Build the standalone (grafana.com) versions of the chart dashboards into dashboards/.

    python3 dashboards/build.py

The release workflow runs this on every release and commits the result, so the files here always match the charts.
Edit the dashboards in charts/<chart>/dashboards/, never the generated files in this directory.

The charts fill placeholders at install time (__PERIOD__, __JOB__, __CURRENCY_UNIT__). A dashboard imported from
grafana.com has no chart around it, so each placeholder becomes a dashboard variable with the chart's default (the
currency, which Grafana cannot take from a variable, is fixed per file). The result is written to dashboards/<file>,
with __inputs / __requires so the import screen asks for the Prometheus data source. Titles and descriptions for the
grafana.com listing are in dashboards/README.md.
"""
import copy
import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "dashboards")

PERIOD_VAR = {
    "name": "period", "label": "SLO period", "type": "custom", "query": "30d,28d,7d",
    "current": {"text": "30d", "value": "30d"}, "options": [], "hide": 0,
    "description": "Must match sloPeriodDays of the chart that writes the recording rules.",
}
JOB_VAR = {
    "name": "job", "label": "Probe job", "type": "textbox", "query": "blackbox-slo",
    "current": {"text": "blackbox-slo", "value": "blackbox-slo"}, "hide": 0,
    "description": "Job label on the probe metrics (probe.jobName of the blackbox-slo-probes chart).",
}

DASHBOARDS = [
    # (chart, source file, output file, title, placeholder -> replacement, extra variables, uid). The uids differ from
    # the chart dashboards' so an import from grafana.com never collides with one the chart provisioned.
    ("slo-burn-rate-alerts", "slo-overview.json", "slo-burn-rate-error-budget.json",
     "SLO burn rate and error budget (Prometheus, multi-window)",
     {"__PERIOD__": "$period"}, [PERIOD_VAR], "oreon-slo-burn-rate"),
    ("blackbox-slo-probes", "probes.json", "synthetic-probes-slo.json",
     "Synthetic probes with SLOs (blackbox exporter, Prometheus)",
     {"__PERIOD__": "$period", "__JOB__": "$job"}, [PERIOD_VAR, JOB_VAR], "oreon-synthetic-probes-slo"),
    ("otel-collector-baseline", "otel-collector.json", "opentelemetry-collector-agent-gateway.json",
     "OpenTelemetry Collector: agent and gateway health",
     {}, [], "oreon-otel-collector-gcom"),
    ("k8s-cost-waste-alerts", "cost-waste.json", "kubernetes-cost-waste-savings.json",
     "Kubernetes cost, showback, waste and savings (Prometheus, OpenCost)",
     {"__CURRENCY_UNIT__": "currencyUSD"}, [], "oreon-k8s-cost-waste-gcom"),
]


def build(chart, src, out, title, repl, extra_vars, uid):
    text = open(os.path.join(ROOT, "charts", chart, "dashboards", src)).read()
    for k, v in repl.items():
        text = text.replace(k, v)
    d = json.loads(text)
    leftover = [k for k in ("__PERIOD__", "__JOB__", "__CURRENCY_UNIT__") if k in text]
    assert not leftover, (out, leftover)
    d["title"] = title
    d["uid"] = uid
    d.pop("id", None)
    d["version"] = 1
    tl = d.setdefault("templating", {}).setdefault("list", [])
    names = {v["name"] for v in tl}
    # Data source first, then the new variables, then the dashboard's own query variables.
    pos = 1 if tl and tl[0].get("type") == "datasource" else 0
    for v in reversed(extra_vars):
        if v["name"] not in names:
            tl.insert(pos, copy.deepcopy(v))
    panel_types = sorted({p["type"] for p in d["panels"]})
    names_of = {"timeseries": "Time series", "stat": "Stat", "gauge": "Gauge", "table": "Table", "text": "Text",
                "bargauge": "Bar gauge", "state-timeline": "State timeline"}
    d["__inputs"] = []
    d["__requires"] = [
        {"type": "grafana", "id": "grafana", "name": "Grafana", "version": "10.4.0"},
        {"type": "datasource", "id": "prometheus", "name": "Prometheus", "version": "1.0.0"},
    ] + [{"type": "panel", "id": t, "name": names_of.get(t, t), "version": ""} for t in panel_types]
    ordered = {"__inputs": d.pop("__inputs"), "__requires": d.pop("__requires")}
    ordered.update(d)
    with open(os.path.join(OUT, out), "w") as f:
        json.dump(ordered, f, indent=2)
        f.write("\n")
    return out, len(d["panels"])


if __name__ == "__main__":
    for row in DASHBOARDS:
        print("%s: %d panels" % build(*row))

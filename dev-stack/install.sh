#!/usr/bin/env bash
# Installs the operators and monitoring stack the charts in this repo target,
# so the charts can be tested against real controllers and watched in Grafana.
#
#   KUBECONFIG=... ./dev-stack/install.sh [monitoring|policy|all]
#
# Sized for a single-node test cluster (kind or similar). Refuses to run
# against a context unless DEV_STACK_CONTEXT names it, so it never lands on a
# real cluster by accident.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
phase="${1:-monitoring}"

ctx="$(kubectl config current-context)"
if [[ "${DEV_STACK_CONTEXT:-}" != "$ctx" ]]; then
  echo "Current context is '$ctx'. Re-run with DEV_STACK_CONTEXT=$ctx to confirm." >&2
  exit 1
fi

# Pinned versions (bump together, then re-run the chart tests).
KPS_VERSION=92.13.1
CERT_MANAGER_VERSION=v1.21.3
OTEL_OPERATOR_VERSION=0.126.2
BLACKBOX_VERSION=11.20.2
KYVERNO_VERSION=3.9.2

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null
helm repo add jetstack https://charts.jetstack.io >/dev/null
helm repo add kyverno https://kyverno.github.io/kyverno >/dev/null
helm repo update >/dev/null

# Charts that template their own CRDs cannot adopt CRDs applied by hand
# (for example by the CI workflow). Remove those first; this deletes any
# custom resources of that kind, so only do it on a test cluster.
drop_unmanaged_crds() {
  local release="$1"; shift
  for crd in "$@"; do
    if kubectl get crd "$crd" >/dev/null 2>&1 &&
       [[ "$(kubectl get crd "$crd" -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}')" != "$release" ]]; then
      kubectl delete crd "$crd"
    fi
  done
}

monitoring() {
  helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
    --version "$KPS_VERSION" -n monitoring --create-namespace \
    -f "$here/kube-prometheus-stack.yaml" --wait --timeout 10m

  helm upgrade --install cert-manager jetstack/cert-manager \
    --version "$CERT_MANAGER_VERSION" -n cert-manager --create-namespace \
    -f "$here/cert-manager.yaml" --wait --timeout 5m

  drop_unmanaged_crds opentelemetry-operator \
    opentelemetrycollectors.opentelemetry.io instrumentations.opentelemetry.io \
    opampbridges.opentelemetry.io targetallocators.opentelemetry.io
  helm upgrade --install opentelemetry-operator open-telemetry/opentelemetry-operator \
    --version "$OTEL_OPERATOR_VERSION" -n opentelemetry-operator-system --create-namespace \
    -f "$here/opentelemetry-operator.yaml" --wait --timeout 5m

  helm upgrade --install blackbox-exporter prometheus-community/prometheus-blackbox-exporter \
    --version "$BLACKBOX_VERSION" -n monitoring \
    -f "$here/blackbox-exporter.yaml" --wait --timeout 5m
}

policy() {
  drop_unmanaged_crds kyverno $(kubectl get crd -o name | sed -n 's|^customresourcedefinition.apiextensions.k8s.io/\(.*kyverno.io\)$|\1|p')
  helm upgrade --install kyverno kyverno/kyverno \
    --version "$KYVERNO_VERSION" -n kyverno --create-namespace \
    -f "$here/kyverno.yaml" --wait --timeout 10m
}

case "$phase" in
  monitoring) monitoring ;;
  policy) policy ;;
  all) monitoring; policy ;;
  *) echo "unknown phase: $phase" >&2; exit 2 ;;
esac

echo
echo "Grafana: kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80"
echo "Admin password: kubectl -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d"

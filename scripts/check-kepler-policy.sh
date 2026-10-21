#!/usr/bin/env bash
# Enforce Cilium policy completeness for the kepler namespace (ADR-014).
# Shared by CI (ci.yaml validate job) and local `just validate-kepler`.
#
# Why this exists: kepler runs in `podInformer.mode: kubelet`, which still
# talks to the API server. It GETs the Node object at startup to discover the
# kubelet InternalIP/port before polling https://<node>:10250/pods. A missing
# apiserver egress is dropped by the namespace default-deny, the Init() error
# is fatal (`cmd/kepler/main.go` -> os.Exit(1)), and the DaemonSet CrashLoops
# with no energy telemetry. Assertions below pin every flow the pod needs.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "::error::$1"
  else
    echo "❌ $1" >&2
  fi
  exit 1
}

render="$(helm template kepler platform/kepler -n kepler)"

# 1) Egress to the API server — Node object lookup at startup (443/6443).
egress="$(awk '/name: kepler-allow-egress/,/^---$/' <<<"$render")"
grep -q 'kube-apiserver' <<<"$egress" \
  || fail "kepler-allow-egress must allow toEntities: [kube-apiserver] (Node lookup at startup)"
grep -q 'port: "443"' <<<"$egress" \
  || fail "kepler-allow-egress must allow kube-apiserver :443"
grep -q 'port: "6443"' <<<"$egress" \
  || fail "kepler-allow-egress must allow kube-apiserver :6443"

# 2) Egress to the kubelet for pod attribution (kubelet mode).
grep -q 'port: "10250"' <<<"$egress" \
  || fail "kepler-allow-egress must allow the kubelet :10250 (podInformer mode kubelet)"

# 3) Ingress for Prometheus, on the port the chart actually renders.
metrics_port="$(grep -oE 'containerPort: [0-9]+' <<<"$render" | head -1 | awk '{print $2}')"
[ -n "$metrics_port" ] \
  || fail "could not derive the kepler metrics port from the rendered DaemonSet"
ingress="$(awk '/name: kepler-allow-ingress/,0' <<<"$render")"
grep -q 'k8s:io.kubernetes.pod.namespace: monitoring' <<<"$ingress" \
  || fail "kepler-allow-ingress must allow scraping from the monitoring namespace"
grep -q "port: \"$metrics_port\"" <<<"$ingress" \
  || fail "kepler-allow-ingress must allow the rendered metrics port :$metrics_port"

# 4) kubelet probes arrive as the host entity; ADR-014 requires them explicit.
grep -q 'remote-node' <<<"$ingress" \
  || fail "kepler-allow-ingress must allow host/remote-node probes (ADR-014)"

# 5) ADR-014 coverage docs must list the namespace (roadmap is the source of truth).
grep -q 'kepler' docs/roadmap.md \
  || fail "docs/roadmap.md policy coverage must list the kepler chart"

# 6) Metric relabeling must drop the scrape target's own pod/namespace labels.
# Prometheus attaches the target's labels to every series of the scrape, so
# without this every kepler_container_* series claims to belong to
# pod kepler-<hash> in namespace kepler. Any panel or ad-hoc query grouping
# those metrics by namespace then silently ranks the exporter as the consumer.
metrics_render="$(helm template monitoring platform/monitoring -n monitoring \
  --show-only templates/services/kepler-servicemonitor.yaml)"
grep -q 'action: labeldrop' <<<"$metrics_render" \
  || fail "kepler ServiceMonitor must labeldrop the target's pod/namespace labels"
grep -q 'regex: pod|namespace' <<<"$metrics_render" \
  || fail "kepler ServiceMonitor labeldrop regex must be 'pod|namespace'"

echo "✅ Kepler Cilium policy: OK (apiserver 443/6443, kubelet 10250, metrics :$metrics_port, probes, docs)"
echo "✅ Kepler metrics contract: OK (target pod/namespace labels dropped)"

#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"

cluster_name='forgepath-observability'
kind_context="kind-$cluster_name"
workload_namespace='forgepath-observability-test'
monitoring_namespace='monitoring'
release_name='runtime'
service_name='runtime-secure-fastapi-service'
kind_version='v0.32.0'
kubernetes_version='v1.32.11'
kind_node_image='kindest/node:v1.32.11@sha256:5fc52d52a7b9574015299724bd68f183702956aa4a2116ae75a63cb574b35af8'
prometheus_image='prom/prometheus@sha256:63805ebb8d2b3920190daf1cb14a60871b16fd38bed42b857a3182bc621f4996'
artifact_directory="${FORGEPATH_ARTIFACT_DIR:-$repository_root/.forgepath/trusted-artifact}"
metadata="$artifact_directory/metadata.json"

runtime_directory=''
original_context=''
cluster_created=false
prometheus_port_forward_pid=''
application_port_forward_pid=''
failure_pid=''

log() {
  printf '[forgepath-observability-runtime] %s\n' "$*"
}

fail() {
  printf '[forgepath-observability-runtime] ERROR: %s\n' "$*" >&2
  exit 1
}

kube() {
  kubectl --context "$kind_context" "$@"
}

require_target_context() {
  [[ "$(kubectl config current-context 2>/dev/null || true)" == "$kind_context" ]] ||
    fail "refusing mutation because current context is not $kind_context"
}

# ShellCheck cannot infer that this function is reached through the EXIT trap.
# shellcheck disable=SC2317
cleanup() {
  local exit_code=$?
  trap - EXIT
  trap '' INT TERM

  for process_id in "$failure_pid" "$application_port_forward_pid" \
    "$prometheus_port_forward_pid"; do
    if [[ -n "$process_id" ]]; then
      kill "$process_id" 2>/dev/null || true
      wait "$process_id" 2>/dev/null || true
    fi
  done

  if [[ "$cluster_created" == 'true' ]] &&
    kind get clusters 2>/dev/null | grep -Fxq "$cluster_name"; then
    log "deleting only disposable Kind cluster $cluster_name"
    kind delete cluster --name "$cluster_name" >/dev/null || exit_code=1
  fi

  if [[ -n "$original_context" ]]; then
    log "restoring original Kubernetes context $original_context"
    kubectl config use-context "$original_context" >/dev/null || exit_code=1
  fi

  if [[ -n "$runtime_directory" &&
        "$runtime_directory" == /private/tmp/forgepath-observability-runtime.* &&
        -d "$runtime_directory" ]]; then
    rm -rf "$runtime_directory"
  fi

  if [[ $exit_code -eq 0 ]]; then
    log 'cleanup passed: disposable cluster and temporary runtime artifacts removed'
  else
    printf '[forgepath-observability-runtime] cleanup encountered an error\n' >&2
  fi
  exit "$exit_code"
}
trap cleanup EXIT INT TERM

wait_for_http_process() {
  local process_id="$1"
  local url="$2"
  local name="$3"
  local deadline=$((SECONDS + 180))

  while ((SECONDS < deadline)); do
    kill -0 "$process_id" 2>/dev/null || {
      sed -n '1,160p' "$runtime_directory/$name.log" >&2 || true
      fail "$name port-forward exited before becoming available"
    }
    if curl -fsS -o /dev/null "$url"; then
      return 0
    fi
    sleep 2
  done
  fail "$name did not become available at $url"
}

prometheus_query() {
  curl -fsS --get --data-urlencode "query=$1" \
    'http://127.0.0.1:19090/api/v1/query'
}

for tool in curl docker helm jq kind kubectl promtool "$repository_root/scripts/validate-trusted-artifact.sh" yq; do
  command -v "$tool" >/dev/null || fail "required runtime tool not found: $tool"
done

actual_kind_version="$(kind version | awk '{print $2}')"
[[ "$actual_kind_version" == "$kind_version" ]] ||
  fail "Kind $kind_version is required; found $actual_kind_version"
if kind get clusters | grep -Fxq "$cluster_name"; then
  fail "refusing to use pre-existing Kind cluster $cluster_name"
fi

original_context="$(kubectl config current-context 2>/dev/null || true)"
[[ -n "$original_context" ]] ||
  fail 'an original Kubernetes context is required for exact restoration'
log "recorded original Kubernetes context: $original_context"

[[ -s "$metadata" ]] || fail "trusted artifact metadata is missing: $metadata"
"$repository_root/scripts/validate-trusted-artifact.sh" "$artifact_directory" >/dev/null
trusted_repository="$(jq -er '.image.repository' "$metadata")"
trusted_digest="$(jq -er '.image.digest' "$metadata")"
trusted_reference="$trusted_repository@$trusted_digest"
source_revision="$(jq -er '.build.source_revision' "$metadata")"
current_source_revision="$(git log -1 --format=%H -- templates/secure-fastapi-service)"
[[ "$source_revision" == "$current_source_revision" ]] ||
  fail 'trusted artifact does not contain the current observability fixture source'
[[ -z "$(git status --porcelain --untracked-files=all -- templates/secure-fastapi-service)" ]] ||
  fail 'commit and rebuild the trusted artifact before runtime validation'

runtime_directory="$(mktemp -d /private/tmp/forgepath-observability-runtime.XXXXXX)"
rendered="$runtime_directory/rendered.yaml"
runtime_resources="$runtime_directory/runtime-resources.yaml"
rules="$runtime_directory/rules.yaml"
prometheus_config="$runtime_directory/prometheus.yml"
prometheus_resources="$runtime_directory/prometheus-resources.yaml"

helm template "$release_name" services/secure-fastapi-service/chart \
  --namespace "$workload_namespace" \
  --set image.repository="$trusted_repository" \
  --set image.digest="$trusted_digest" \
  --set failureFixture.enabled=true \
  --set monitoring.slo.windowProfile=demo >"$rendered"
yq 'select(.kind != "ServiceMonitor" and .kind != "PrometheusRule")' \
  "$rendered" >"$runtime_resources"
yq -o=yaml 'select(.kind == "PrometheusRule") | {"groups": .spec.groups}' \
  "$rendered" >"$rules"
promtool check rules "$rules" >/dev/null

cat >"$prometheus_config" <<EOF
global:
  scrape_interval: 2s
  evaluation_interval: 2s
rule_files:
  - /etc/prometheus/rules.yaml
scrape_configs:
  - job_name: forgepath-runtime
    metrics_path: /metrics
    static_configs:
      - targets:
          - ${service_name}.${workload_namespace}.svc:80
        labels:
          forgepath_service: ${service_name}
EOF

cat >"$prometheus_resources" <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: forgepath-prometheus
  namespace: ${monitoring_namespace}
automountServiceAccountToken: false
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: forgepath-prometheus
  namespace: ${monitoring_namespace}
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: prometheus
  template:
    metadata:
      labels:
        app.kubernetes.io/name: prometheus
    spec:
      serviceAccountName: forgepath-prometheus
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534
        runAsGroup: 65534
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: prometheus
          image: ${prometheus_image}
          args:
            - --config.file=/etc/prometheus/prometheus.yml
            - --storage.tsdb.path=/prometheus
          ports:
            - name: http
              containerPort: 9090
          livenessProbe:
            httpGet: {path: /-/healthy, port: http}
            periodSeconds: 10
            timeoutSeconds: 2
          readinessProbe:
            httpGet: {path: /-/ready, port: http}
            periodSeconds: 5
            timeoutSeconds: 2
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          resources:
            requests: {cpu: 100m, memory: 128Mi}
            limits: {cpu: 500m, memory: 512Mi}
          volumeMounts:
            - {name: config, mountPath: /etc/prometheus, readOnly: true}
            - {name: data, mountPath: /prometheus}
      volumes:
        - name: config
          configMap:
            name: forgepath-prometheus
        - name: data
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: forgepath-prometheus
  namespace: ${monitoring_namespace}
spec:
  selector:
    app.kubernetes.io/name: prometheus
  ports:
    - {name: http, port: 9090, targetPort: http}
EOF

cluster_created=true
log "creating disposable Kind $kind_version cluster $cluster_name with $kind_node_image"
kind create cluster --name "$cluster_name" --image "$kind_node_image" --wait 180s
require_target_context
observed_server="$(kube version -o json | jq -r '.serverVersion.gitVersion')"
[[ "$observed_server" == "$kubernetes_version" ]] ||
  fail "expected Kubernetes $kubernetes_version, observed $observed_server"

log 'loading the trusted application OCI archive without a remote registry'
kind load image-archive "$artifact_directory/image.oci.tar" --name "$cluster_name"
docker exec "${cluster_name}-control-plane" ctr --namespace k8s.io images tag \
  "docker.io/$trusted_repository:0.1.0-local" \
  "docker.io/$trusted_reference" >/dev/null

require_target_context
kube create namespace "$workload_namespace" >/dev/null
kube create namespace "$monitoring_namespace" >/dev/null
kube label namespace "$workload_namespace" "$monitoring_namespace" \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/warn=restricted --overwrite >/dev/null
kube -n "$workload_namespace" apply -f "$runtime_resources" >/dev/null
kube -n "$workload_namespace" rollout status deployment/"$service_name" \
  --timeout=180s >/dev/null

kube -n "$monitoring_namespace" create configmap forgepath-prometheus \
  --from-file=prometheus.yml="$prometheus_config" \
  --from-file=rules.yaml="$rules" --dry-run=client -o yaml \
  >"$runtime_directory/prometheus-configmap.yaml"
kube apply -f "$runtime_directory/prometheus-configmap.yaml" \
  -f "$prometheus_resources" >/dev/null
kube -n "$monitoring_namespace" rollout status deployment/forgepath-prometheus \
  --timeout=300s >/dev/null

kube -n "$monitoring_namespace" port-forward service/forgepath-prometheus \
  19090:9090 >"$runtime_directory/prometheus-port-forward.log" 2>&1 &
prometheus_port_forward_pid=$!
wait_for_http_process "$prometheus_port_forward_pid" \
  'http://127.0.0.1:19090/-/ready' 'prometheus-port-forward'
kube -n "$workload_namespace" port-forward service/"$service_name" \
  18080:80 >"$runtime_directory/application-port-forward.log" 2>&1 &
application_port_forward_pid=$!
wait_for_http_process "$application_port_forward_pid" \
  'http://127.0.0.1:18080/health/ready' 'application-port-forward'

target_deadline=$((SECONDS + 120))
while ((SECONDS < target_deadline)); do
  target_up="$(prometheus_query 'up{forgepath_service="runtime-secure-fastapi-service"}' |
    jq -r '.data.result[0].value[1] // "0"')"
  [[ "$target_up" == '1' ]] && break
  sleep 2
done
[[ "${target_up:-0}" == '1' ]] ||
  fail 'Prometheus could not scrape /metrics through the restricted NetworkPolicy'
log 'PASS Prometheus scraped /metrics through the namespace-and-pod-selected policy'

for _ in {1..30}; do
  curl -fsS -o /dev/null 'http://127.0.0.1:18080/docs'
done
(
  deadline=$((SECONDS + 600))
  while ((SECONDS < deadline)); do
    status="$(curl -sS -o /dev/null -w '%{http_code}' \
      'http://127.0.0.1:18080/_test/failure')"
    [[ "$status" == '503' ]] || exit 1
    sleep 0.25
  done
) &
failure_pid=$!

alert_deadline=$((SECONDS + 600))
alert_firing=false
while ((SECONDS < alert_deadline)); do
  alert_count="$(
    prometheus_query 'ALERTS{alertname="ForgePathSLOFastBurn",alertstate="firing"}' |
      jq '.data.result | length'
  )"
  if [[ "$alert_count" -gt 0 ]]; then
    alert_firing=true
    break
  fi
  kill -0 "$failure_pid" 2>/dev/null ||
    fail 'controlled failure traffic generator exited unexpectedly'
  sleep 5
done
[[ "$alert_firing" == 'true' ]] ||
  fail 'fast-burn alert did not fire within the accelerated runtime window'

availability="$(
  prometheus_query 'forgepath:sli_availability:ratio_rate5m{forgepath_service="runtime-secure-fastapi-service"}' |
    jq -er '.data.result[0].value[1] | tonumber'
)"
jq -ne --argjson availability "$availability" '$availability < 0.999' >/dev/null ||
  fail "availability did not degrade below the 99.9% SLO: $availability"
log "PASS controlled 503 traffic degraded availability to $availability and fired ForgePathSLOFastBurn"
log "VERSIONS Kind $kind_version; Kubernetes $observed_server; Prometheus v3.5.0"

exit 0

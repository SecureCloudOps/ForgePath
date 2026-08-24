#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"

cluster_name='forgepath-namespace-boundary'
kind_context="kind-$cluster_name"
workload_namespace='forgepath-namespace-test'
monitoring_namespace='monitoring'
allowed_namespace='forgepath-allowed-client'
denied_namespace='forgepath-denied-client'
external_namespace='forgepath-external-service'
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

log() {
  printf '[forgepath-namespace-runtime] %s\n' "$*"
}

fail() {
  printf '[forgepath-namespace-runtime] ERROR: %s\n' "$*" >&2
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

  if [[ -n "$prometheus_port_forward_pid" ]]; then
    kill "$prometheus_port_forward_pid" 2>/dev/null || true
    wait "$prometheus_port_forward_pid" 2>/dev/null || true
  fi

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
        "$runtime_directory" == /private/tmp/forgepath-namespace-runtime.* &&
        -d "$runtime_directory" ]]; then
    rm -rf "$runtime_directory"
  fi

  if [[ $exit_code -eq 0 ]]; then
    log 'cleanup passed: disposable cluster and temporary runtime artifacts removed'
  else
    printf '[forgepath-namespace-runtime] cleanup encountered an error\n' >&2
  fi
  exit "$exit_code"
}
trap cleanup EXIT INT TERM

wait_for_pod() {
  local namespace="$1"
  local pod="$2"
  kube -n "$namespace" wait --for=condition=Ready "pod/$pod" --timeout=180s >/dev/null
}

assert_rejected() {
  local manifest="$1"
  local expected="$2"
  local output
  local status

  set +e
  output="$(kube -n "$workload_namespace" apply --dry-run=server -f "$manifest" 2>&1)"
  status=$?
  set -e
  [[ $status -ne 0 ]] || fail "insecure fixture was admitted: $manifest"
  grep -Fq "$expected" <<<"$output" || {
    printf '%s\n' "$output" >&2
    fail "denial did not contain expected remediation text: $expected"
  }
}

assert_http_succeeds() {
  local namespace="$1"
  local pod="$2"
  local url="$3"
  kube -n "$namespace" exec "$pod" -- python -c \
    'import sys, urllib.request; sys.exit(0 if urllib.request.urlopen(sys.argv[1], timeout=3).status == 200 else 1)' \
    "$url" >/dev/null
}

assert_http_fails() {
  local namespace="$1"
  local pod="$2"
  local url="$3"
  if kube -n "$namespace" exec "$pod" -- python -c \
    'import sys, urllib.request; urllib.request.urlopen(sys.argv[1], timeout=3)' \
    "$url" >/dev/null 2>&1; then
    fail "unauthorized connection unexpectedly succeeded: $namespace/$pod -> $url"
  fi
}

for tool in curl docker helm jq kind kubectl "$repository_root/scripts/validate-trusted-artifact.sh" yq; do
  command -v "$tool" >/dev/null || fail "required runtime tool not found: $tool"
done

actual_kind_version="$(kind version | awk '{print $2}')"
[[ "$actual_kind_version" == "$kind_version" ]] ||
  fail "Kind $kind_version is required; found $actual_kind_version"
if kind get clusters | grep -Fxq "$cluster_name"; then
  fail "refusing to use pre-existing Kind cluster $cluster_name"
fi

original_context="$(kubectl config current-context 2>/dev/null || true)"
[[ -n "$original_context" ]] || fail 'an original Kubernetes context is required for exact restoration'
log "recorded original Kubernetes context: $original_context"

[[ -s "$metadata" ]] || fail "trusted artifact metadata is missing: $metadata"
"$repository_root/scripts/validate-trusted-artifact.sh" "$artifact_directory" >/dev/null
trusted_repository="$(jq -er '.image.repository' "$metadata")"
trusted_digest="$(jq -er '.image.digest' "$metadata")"
trusted_reference="$trusted_repository@$trusted_digest"

runtime_directory="$(mktemp -d /private/tmp/forgepath-namespace-runtime.XXXXXX)"
rendered="$runtime_directory/rendered.yaml"
boundary_resources="$runtime_directory/boundary-resources.yaml"
application_resources="$runtime_directory/application-resources.yaml"
test_workloads="$runtime_directory/test-workloads.yaml"
prometheus_resources="$runtime_directory/prometheus-resources.yaml"

helm template "$release_name" services/secure-fastapi-service/chart \
  --namespace "$workload_namespace" \
  --set image.repository="$trusted_repository" \
  --set image.digest="$trusted_digest" >"$rendered"

cp gitops/platform/namespaces/secure-fastapi-service-local.yaml "$boundary_resources"
yq -i 'select(.kind == "NetworkPolicy" and .metadata.name == "forgepath-platform-allow-prometheus") |
  .spec.ingress += [{"from": [{"namespaceSelector": {"matchLabels":
    {"forgepath.dev/access": "application"}}, "podSelector": {"matchLabels":
    {"forgepath.dev/client": "application"}}}], "ports": [{"protocol": "TCP", "port": 8080}]}]' \
  "$boundary_resources"
yq 'select(.kind == "ServiceAccount" or .kind == "Service")' \
  "$rendered" >"$application_resources"
yq 'select(.kind == "Rollout") |
  .apiVersion = "apps/v1" | .kind = "Deployment" |
  .spec.replicas = 1 | del(.spec.strategy)' \
  "$rendered" >>"$application_resources"

for fixture in restricted-violation limit-violation quota-violation; do
  sed "s|__FORGEPATH_RUNTIME_IMAGE__|$trusted_reference|g" \
    "tests/namespace/runtime/$fixture.yaml.tmpl" \
    >"$runtime_directory/$fixture.yaml"
done

cluster_created=true
log "creating disposable Kind $kind_version cluster $cluster_name with built-in NetworkPolicy enforcement"
kind create cluster --name "$cluster_name" --image "$kind_node_image" --wait 180s
require_target_context
observed_server="$(kube version -o json | jq -r '.serverVersion.gitVersion')"
[[ "$observed_server" == "$kubernetes_version" ]] ||
  fail "expected Kubernetes $kubernetes_version, observed $observed_server"

log 'loading the previously validated immutable application artifact'
kind load image-archive "$artifact_directory/image.oci.tar" --name "$cluster_name"
docker exec "${cluster_name}-control-plane" ctr --namespace k8s.io images tag \
  "$trusted_repository:0.1.0-local" "$trusted_reference" >/dev/null

cat >"$runtime_directory/namespaces.yaml" <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${workload_namespace}
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.32
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: v1.32
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: v1.32
---
apiVersion: v1
kind: Namespace
metadata:
  name: ${monitoring_namespace}
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.32
---
apiVersion: v1
kind: Namespace
metadata:
  name: ${allowed_namespace}
  labels:
    forgepath.dev/access: application
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.32
---
apiVersion: v1
kind: Namespace
metadata:
  name: ${denied_namespace}
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.32
---
apiVersion: v1
kind: Namespace
metadata:
  name: ${external_namespace}
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.32
EOF

require_target_context
kube apply -f "$runtime_directory/namespaces.yaml" >/dev/null
kube apply -f "$boundary_resources" >/dev/null

[[ "$(kube get namespace "$workload_namespace" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}')" == 'restricted' ]] ||
  fail 'workload namespace did not start with restricted Pod Security enforcement'
[[ "$(kube -n "$workload_namespace" get networkpolicy -o name | wc -l | tr -d ' ')" == '3' ]] ||
  fail 'workload namespace must start with exactly three network policies'
kube -n "$workload_namespace" get resourcequota forgepath-namespace-boundary >/dev/null
kube -n "$workload_namespace" get limitrange forgepath-namespace-boundary >/dev/null
log 'PASS compliant namespace started with restricted PSA, quota, limits, and deny-all networking'

kube -n "$workload_namespace" apply -f "$application_resources" >/dev/null
kube -n "$workload_namespace" rollout status deployment/"$service_name" --timeout=180s >/dev/null
application_pod="$(kube -n "$workload_namespace" get pod \
  -l app.kubernetes.io/name=secure-fastapi-service,app.kubernetes.io/instance="$release_name" \
  -o jsonpath='{.items[0].metadata.name}')"

cat >"$test_workloads" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: allowed-client
  namespace: ${allowed_namespace}
  labels:
    forgepath.dev/client: application
spec:
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    seccompProfile: {type: RuntimeDefault}
  containers:
    - name: client
      image: ${trusted_reference}
      imagePullPolicy: IfNotPresent
      command: ["python", "-c", "import time; time.sleep(600)"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: {drop: ["ALL"]}
      resources:
        requests: {cpu: 10m, memory: 32Mi}
        limits: {cpu: 100m, memory: 64Mi}
---
apiVersion: v1
kind: Pod
metadata:
  name: denied-client
  namespace: ${denied_namespace}
spec:
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    seccompProfile: {type: RuntimeDefault}
  containers:
    - name: client
      image: ${trusted_reference}
      imagePullPolicy: IfNotPresent
      command: ["python", "-c", "import time; time.sleep(600)"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: {drop: ["ALL"]}
      resources:
        requests: {cpu: 10m, memory: 32Mi}
        limits: {cpu: 100m, memory: 64Mi}
---
apiVersion: v1
kind: Pod
metadata:
  name: external-service
  namespace: ${external_namespace}
  labels:
    app: external-service
spec:
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    seccompProfile: {type: RuntimeDefault}
  containers:
    - name: application
      image: ${trusted_reference}
      imagePullPolicy: IfNotPresent
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: {drop: ["ALL"]}
      ports:
        - {name: http, containerPort: 8080}
      resources:
        requests: {cpu: 10m, memory: 32Mi}
        limits: {cpu: 100m, memory: 64Mi}
---
apiVersion: v1
kind: Service
metadata:
  name: external-service
  namespace: ${external_namespace}
spec:
  selector: {app: external-service}
  ports:
    - {name: http, port: 80, targetPort: http}
EOF
kube apply -f "$test_workloads" >/dev/null
wait_for_pod "$allowed_namespace" allowed-client
wait_for_pod "$denied_namespace" denied-client
wait_for_pod "$external_namespace" external-service

service_url="http://${service_name}.${workload_namespace}.svc.cluster.local/health/ready"
assert_http_succeeds "$allowed_namespace" allowed-client "$service_url"
log 'PASS normal service traffic from the explicitly authorized namespace and pod worked'

cat >"$runtime_directory/prometheus.yml" <<EOF
global:
  scrape_interval: 2s
scrape_configs:
  - job_name: forgepath-namespace-runtime
    metrics_path: /metrics
    static_configs:
      - targets: ["${service_name}.${workload_namespace}.svc.cluster.local:80"]
EOF
kube -n "$monitoring_namespace" create configmap forgepath-prometheus \
  --from-file=prometheus.yml="$runtime_directory/prometheus.yml" \
  --dry-run=client -o yaml >"$runtime_directory/prometheus-configmap.yaml"
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
    matchLabels: {app.kubernetes.io/name: prometheus}
  template:
    metadata:
      labels: {app.kubernetes.io/name: prometheus}
    spec:
      serviceAccountName: forgepath-prometheus
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534
        runAsGroup: 65534
        seccompProfile: {type: RuntimeDefault}
      containers:
        - name: prometheus
          image: ${prometheus_image}
          args: ["--config.file=/etc/prometheus/prometheus.yml", "--storage.tsdb.path=/prometheus"]
          ports: [{name: http, containerPort: 9090}]
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: {drop: ["ALL"]}
          resources:
            requests: {cpu: 100m, memory: 128Mi}
            limits: {cpu: 500m, memory: 512Mi}
          volumeMounts:
            - {name: config, mountPath: /etc/prometheus, readOnly: true}
            - {name: data, mountPath: /prometheus}
      volumes:
        - name: config
          configMap: {name: forgepath-prometheus}
        - name: data
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: forgepath-prometheus
  namespace: ${monitoring_namespace}
spec:
  selector: {app.kubernetes.io/name: prometheus}
  ports: [{name: http, port: 9090, targetPort: http}]
EOF
kube apply -f "$runtime_directory/prometheus-configmap.yaml" -f "$prometheus_resources" >/dev/null
kube -n "$monitoring_namespace" rollout status deployment/forgepath-prometheus --timeout=180s >/dev/null
kube -n "$monitoring_namespace" port-forward service/forgepath-prometheus 19090:9090 \
  >"$runtime_directory/prometheus-port-forward.log" 2>&1 &
prometheus_port_forward_pid=$!

target_up='0'
for _ in $(seq 1 60); do
  if ! kill -0 "$prometheus_port_forward_pid" 2>/dev/null; then
    sed -n '1,120p' "$runtime_directory/prometheus-port-forward.log" >&2
    fail 'Prometheus port-forward exited unexpectedly'
  fi
  target_up="$(curl -fsS --get --data-urlencode \
    'query=up{job="forgepath-namespace-runtime"}' \
    'http://127.0.0.1:19090/api/v1/query' 2>/dev/null |
    jq -r '.data.result[0].value[1] // "0"' 2>/dev/null || true)"
  [[ "$target_up" == '1' ]] && break
  sleep 2
done
[[ "$target_up" == '1' ]] || fail 'Prometheus could not scrape through the scoped ingress policy'
log 'PASS Prometheus scraped only through the namespace, pod, and TCP-port-selected rule'

kube -n "$workload_namespace" exec "$application_pod" -- python -c \
  'import socket; socket.getaddrinfo("kubernetes.default.svc.cluster.local", 443)' >/dev/null
log 'PASS application DNS resolution worked through the UDP/TCP 53-only egress rule'

sleep 5
assert_http_fails "$denied_namespace" denied-client "$service_url"
log 'PASS ingress from an unauthorized namespace and pod was denied'

external_ip="$(kube -n "$external_namespace" get service external-service -o jsonpath='{.spec.clusterIP}')"
assert_http_fails "$workload_namespace" "$application_pod" "http://${external_ip}/health/ready"
log 'PASS application egress not explicitly required by the service was denied'

assert_rejected "$runtime_directory/limit-violation.yaml" 'maximum cpu usage per Container is 1'
assert_rejected "$runtime_directory/quota-violation.yaml" 'exceeded quota'
log 'PASS LimitRange and aggregate ResourceQuota violations were rejected by admission'

assert_rejected "$runtime_directory/restricted-violation.yaml" 'violates PodSecurity "restricted:v1.32"'
log 'PASS restricted Pod Security violation was rejected by admission'
log "VERSIONS Kind $kind_version; Kubernetes $observed_server; network policy kindnet; PSA restricted:v1.32"

exit 0

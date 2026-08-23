#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"

cluster_name='forgepath-workload-identity'
kind_context="kind-$cluster_name"
workload_namespace='forgepath-identity-test'
release_name='identity'
application_name='identity-secure-fastapi-service'
application_service_account="$application_name"
platform_service_account='forgepath-platform-reconciler'
kind_version='v0.32.0'
kubernetes_version='v1.32.11'
kind_node_image='kindest/node:v1.32.11@sha256:5fc52d52a7b9574015299724bd68f183702956aa4a2116ae75a63cb574b35af8'
artifact_directory="${FORGEPATH_ARTIFACT_DIR:-$repository_root/.forgepath/trusted-artifact}"
metadata="$artifact_directory/metadata.json"

runtime_directory=''
original_context=''
cluster_created=false

log() { printf '[forgepath-workload-identity-runtime] %s\n' "$*"; }
fail() { printf '[forgepath-workload-identity-runtime] ERROR: %s\n' "$*" >&2; exit 1; }
kube() { kubectl --context "$kind_context" "$@"; }

require_context() {
  [[ "$(kubectl config current-context 2>/dev/null || true)" == "$kind_context" ]] ||
    fail "refusing mutation because current context is not $kind_context"
}

cleanup() {
  local exit_code=$?
  trap - EXIT INT TERM
  if [[ "$cluster_created" == true ]] &&
    kind get clusters 2>/dev/null | grep -Fxq "$cluster_name"; then
    log "deleting only disposable Kind cluster $cluster_name"
    kind delete cluster --name "$cluster_name" >/dev/null || exit_code=1
  fi
  if [[ -n "$original_context" ]]; then
    kubectl config use-context "$original_context" >/dev/null || exit_code=1
  fi
  if [[ -n "$runtime_directory" &&
        "$runtime_directory" == /private/tmp/forgepath-workload-identity-runtime.* &&
        -d "$runtime_directory" ]]; then
    rm -rf "$runtime_directory"
  fi
  exit "$exit_code"
}
trap cleanup EXIT INT TERM

assert_can_i() {
  local expected="$1" service_account="$2" verb="$3" resource="$4"
  local namespace="${5:-$workload_namespace}" actual

  actual="$(kube auth can-i "$verb" "$resource" --namespace "$namespace" \
    --as="system:serviceaccount:$workload_namespace:$service_account" \
    --as-group=system:authenticated \
    --as-group=system:serviceaccounts \
    --as-group="system:serviceaccounts:$workload_namespace" || true)"
  [[ "$actual" == "$expected" ]] ||
    fail "expected $service_account can-i $verb $resource in $namespace to be $expected, got $actual"
}

assert_application_denied() {
  local description="$1" output status
  shift

  set +e
  output="$(kube \
    --as="system:serviceaccount:$workload_namespace:$application_service_account" \
    --as-group=system:authenticated \
    --as-group=system:serviceaccounts \
    --as-group="system:serviceaccounts:$workload_namespace" \
    "$@" 2>&1)"
  status=$?
  set -e
  [[ $status -ne 0 ]] || fail "application identity unexpectedly succeeded: $description"
  grep -Eiq 'forbidden|cannot|No such file' <<<"$output" || {
    printf '%s\n' "$output" >&2
    fail "application denial did not contain expected evidence: $description"
  }
}

for tool in docker helm jq kind kubectl yq "$repository_root/scripts/validate-trusted-artifact.sh"; do
  command -v "$tool" >/dev/null || fail "required runtime tool not found: $tool"
done
[[ "$(kind version | awk '{print $2}')" == "$kind_version" ]] || fail "Kind $kind_version is required"
kind get clusters | grep -Fxq "$cluster_name" && fail "refusing pre-existing cluster $cluster_name"
original_context="$(kubectl config current-context 2>/dev/null || true)"
[[ -n "$original_context" ]] || fail 'an original Kubernetes context is required'
"$repository_root/scripts/validate-trusted-artifact.sh" "$artifact_directory" >/dev/null

trusted_repository="$(jq -er '.image.repository' "$metadata")"
trusted_digest="$(jq -er '.image.digest' "$metadata")"
trusted_reference="$trusted_repository@$trusted_digest"
runtime_directory="$(mktemp -d /private/tmp/forgepath-workload-identity-runtime.XXXXXX)"
rendered="$runtime_directory/rendered.yaml"
application_resources="$runtime_directory/application-resources.yaml"

helm template "$release_name" services/secure-fastapi-service/chart \
  --namespace "$workload_namespace" \
  --set image.repository="$trusted_repository" \
  --set image.digest="$trusted_digest" >"$rendered"
yq 'select(.kind == "ServiceAccount" or .kind == "Service")' \
  "$rendered" >"$application_resources"
yq 'select(.kind == "Rollout") |
  .apiVersion = "apps/v1" | .kind = "Deployment" |
  .spec.replicas = 1 | del(.spec.strategy)' \
  "$rendered" >>"$application_resources"

cluster_created=true
kind create cluster --name "$cluster_name" --image "$kind_node_image" --wait 180s
require_context
[[ "$(kube version -o json | jq -r '.serverVersion.gitVersion')" == "$kubernetes_version" ]] ||
  fail "expected Kubernetes $kubernetes_version"
kind load image-archive "$artifact_directory/image.oci.tar" --name "$cluster_name"
docker exec "${cluster_name}-control-plane" ctr --namespace k8s.io images tag \
  "$trusted_repository:0.1.0-local" "$trusted_reference" >/dev/null

kube create namespace "$workload_namespace" >/dev/null
kube label namespace "$workload_namespace" \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=v1.32 --overwrite >/dev/null
kube -n "$workload_namespace" apply -f "$application_resources" >/dev/null
kube -n "$workload_namespace" rollout status deployment/"$application_name" --timeout=180s >/dev/null
application_pod="$(kube -n "$workload_namespace" get pod \
  -l app.kubernetes.io/name=secure-fastapi-service,app.kubernetes.io/instance="$release_name" \
  -o jsonpath='{.items[0].metadata.name}')"
kube -n "$workload_namespace" exec "$application_pod" -- python -c \
  'import urllib.request; assert urllib.request.urlopen("http://127.0.0.1:8080/health/ready", timeout=2).status == 200' >/dev/null
if kube -n "$workload_namespace" exec "$application_pod" -- \
  python -c 'open("/var/run/secrets/kubernetes.io/serviceaccount/token").read()' >/dev/null 2>&1; then
  fail 'normal application unexpectedly received an automounted service-account token'
fi
log 'PASS normal application is ready and has no automounted service-account token'

for resource in secrets deployments.apps rollouts.argoproj.io \
  analysisruns.argoproj.io policies.kyverno.io clusterpolicies.kyverno.io \
  networkpolicies.networking.k8s.io; do
  for verb in get list watch create update patch delete deletecollection; do
    assert_can_i no "$application_service_account" "$verb" "$resource"
  done
done
for denied_access in 'create pods' 'create serviceaccounts/token' \
  'impersonate serviceaccounts' 'impersonate users' 'impersonate groups'; do
  read -r verb resource <<<"$denied_access"
  assert_can_i no "$application_service_account" "$verb" "$resource"
done
log 'PASS negative kubectl auth can-i checks denied workload, policy, identity, and Secret paths'
assert_application_denied 'create a privileged workload' -n "$workload_namespace" \
  create -f tests/kyverno/runtime/privileged-pod.yaml
log 'PASS application identity could not submit a privileged workload'

cat >"$runtime_directory/api-probe.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata: {name: application-api-probe, namespace: $workload_namespace}
spec:
  restartPolicy: Never
  serviceAccountName: $application_service_account
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    seccompProfile: {type: RuntimeDefault}
  containers:
    - name: probe
      image: $trusted_reference
      imagePullPolicy: IfNotPresent
      command: ["python", "-c"]
      args:
        - |
          import ssl, urllib.error, urllib.request
          token = open('/var/run/secrets/tokens/api-token').read()
          context = ssl.create_default_context(cafile='/var/run/secrets/kubernetes.io/serviceaccount/ca.crt')
          request = urllib.request.Request(
              'https://kubernetes.default.svc/api/v1/namespaces/$workload_namespace/secrets',
              headers={'Authorization': 'Bearer ' + token})
          try:
              urllib.request.urlopen(request, context=context, timeout=5)
          except urllib.error.HTTPError as error:
              raise SystemExit(0 if error.code == 403 else 1)
          raise SystemExit(1)
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: {drop: ["ALL"]}
      resources:
        requests: {cpu: 10m, memory: 32Mi}
        limits: {cpu: 100m, memory: 64Mi}
      volumeMounts:
        - {name: api-token, mountPath: /var/run/secrets/tokens, readOnly: true}
        - {name: api-ca, mountPath: /var/run/secrets/kubernetes.io/serviceaccount, readOnly: true}
  volumes:
    - name: api-token
      projected:
        sources:
          - serviceAccountToken: {path: api-token, expirationSeconds: 600}
    - name: api-ca
      configMap: {name: kube-root-ca.crt}
EOF
kube apply -f "$runtime_directory/api-probe.yaml" >/dev/null
kube -n "$workload_namespace" wait --for=jsonpath='{.status.phase}'=Succeeded \
  pod/application-api-probe --timeout=120s >/dev/null
log 'PASS an explicitly projected, short-lived application token received HTTP 403 from the Secrets API'

cat >"$runtime_directory/platform-identity.yaml" <<EOF
apiVersion: v1
kind: ServiceAccount
metadata: {name: $platform_service_account, namespace: $workload_namespace}
automountServiceAccountToken: false
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: forgepath-platform-reconciler, namespace: $workload_namespace}
rules:
  - apiGroups: ["apps"]
    resources: ["deployments"]
    resourceNames: ["$application_name"]
    verbs: ["get", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: forgepath-platform-reconciler, namespace: $workload_namespace}
subjects:
  - {kind: ServiceAccount, name: $platform_service_account, namespace: $workload_namespace}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: forgepath-platform-reconciler}
EOF
kube apply -f "$runtime_directory/platform-identity.yaml" >/dev/null
assert_can_i yes "$platform_service_account" patch "deployments.apps/$application_name"
assert_can_i yes "$platform_service_account" get "deployments.apps/$application_name"
assert_can_i no "$platform_service_account" patch deployments.apps/not-platform-owned
assert_can_i no "$platform_service_account" update "deployments.apps/$application_name"
assert_can_i no "$platform_service_account" create deployments.apps
assert_can_i no "$platform_service_account" list secrets
assert_can_i no "$platform_service_account" patch networkpolicies.networking.k8s.io

assert_application_denied 'patch the platform-owned Deployment' -n "$workload_namespace" \
  patch deployment "$application_name" --type=merge -p '{"spec":{"replicas":2}}'
kube --as="system:serviceaccount:$workload_namespace:$platform_service_account" \
  --as-group=system:authenticated \
  --as-group=system:serviceaccounts \
  --as-group="system:serviceaccounts:$workload_namespace" \
  -n "$workload_namespace" patch deployment "$application_name" \
  --type=merge -p '{"spec":{"replicas":2}}' >/dev/null
kube -n "$workload_namespace" rollout status deployment/"$application_name" --timeout=180s >/dev/null
[[ "$(kube -n "$workload_namespace" get deployment "$application_name" -o jsonpath='{.status.readyReplicas}')" == '2' ]] ||
  fail 'platform reconciler patch did not produce two ready replicas'
log 'PASS isolated platform reconciler patched its named Deployment; application identity could not'

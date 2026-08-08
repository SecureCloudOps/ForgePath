#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"

cluster_name='forgepath-kyverno'
kind_context="kind-$cluster_name"
test_namespace='forgepath-kyverno-test'
kind_version='v0.32.0'
kubernetes_version='v1.32.11'
kind_node_image='kindest/node:v1.32.11@sha256:5fc52d52a7b9574015299724bd68f183702956aa4a2116ae75a63cb574b35af8'
kyverno_version='v1.18.2'
kyverno_manifest_url='https://github.com/kyverno/kyverno/releases/download/v1.18.2/install.yaml'
kyverno_manifest_sha256='3dcd43eaf11f0719084217148cd0c82a8fa49faa9b1a783ea5bea2cf84041bda'
kyverno_image='reg.kyverno.io/kyverno/kyverno@sha256:0a540e2ddf74d0d2d3d45f9ef248d7dbc96576accdbcc6a2dd7eaff9fea56504'
background_image='reg.kyverno.io/kyverno/background-controller@sha256:d62566ce41bd0d4a32bf2cf44b9ebfc02c36374f821f83070890287f62f68671'
cleanup_image='reg.kyverno.io/kyverno/cleanup-controller@sha256:b0395d29ae332276e6910eb40418be9bc127c068d659f90aa1bcddd6be99ccb4'
reports_image='reg.kyverno.io/kyverno/reports-controller@sha256:f09cf305170014e191b94e1c54f5be73163d8824eefad49349675c4efe43159a'
pre_image='reg.kyverno.io/kyverno/kyvernopre@sha256:cd8cb4a31d25b3992734fb8f24a90ef691c90ce49338c89bea96792160eacb98'

runtime_directory=''
original_context=''
cluster_creation_started=false

log() {
  printf '[forgepath-kyverno-runtime] %s\n' "$*"
}

fail() {
  printf '[forgepath-kyverno-runtime] ERROR: %s\n' "$*" >&2
  exit 1
}

sha256_file() {
  if command -v sha256sum >/dev/null; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
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

  if [[ "$cluster_creation_started" == 'true' ]] &&
    kind get clusters 2>/dev/null | grep -Fxq "$cluster_name"; then
    log "deleting only disposable Kind cluster $cluster_name"
    kind delete cluster --name "$cluster_name" >/dev/null || exit_code=1
  fi

  if [[ -n "$original_context" ]]; then
    log "restoring original Kubernetes context $original_context"
    kubectl config use-context "$original_context" >/dev/null || exit_code=1
  fi

  if [[ -n "$runtime_directory" &&
        "$runtime_directory" == /private/tmp/forgepath-kyverno-runtime.* &&
        -d "$runtime_directory" ]]; then
    rm -rf "$runtime_directory"
  fi

  if [[ $exit_code -eq 0 ]]; then
    log 'cleanup passed: disposable cluster and temporary runtime artifacts removed'
  else
    printf '[forgepath-kyverno-runtime] cleanup encountered an error\n' >&2
  fi
  exit "$exit_code"
}
trap cleanup EXIT INT TERM

assert_rejected() {
  local fixture="$1"
  local expected="$2"
  local normalized_report
  local report
  local status

  report="$runtime_directory/$(basename "$fixture").rejection.txt"

  require_target_context
  set +e
  kube -n "$test_namespace" apply --dry-run=server -f "$fixture" >"$report" 2>&1
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "runtime fixture unexpectedly admitted: $fixture"
  normalized_report="$(tr '\n' ' ' <"$report" | tr -s '[:space:]' ' ')"
  grep -Fq "$expected" <<<"$normalized_report" || {
    sed -n '1,160p' "$report" >&2
    fail "runtime rejection did not identify expected policy message: $expected"
  }
}

for tool in curl docker helm kind kubectl rg sed yq; do
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

runtime_directory="$(mktemp -d /private/tmp/forgepath-kyverno-runtime.XXXXXX)"
manifest="$runtime_directory/kyverno-install.yaml"
pinned_manifest="$runtime_directory/kyverno-install-pinned.yaml"
rendered="$runtime_directory/secure-fastapi-service.yaml"

log "downloading reviewed Kyverno $kyverno_version installation manifest"
curl -fsSLo "$manifest" "$kyverno_manifest_url"
[[ "$(sha256_file "$manifest")" == "$kyverno_manifest_sha256" ]] ||
  fail 'Kyverno installation manifest checksum mismatch'

expected_tagged_images="$(printf '%s\n' \
  'reg.kyverno.io/kyverno/background-controller:v1.18.2' \
  'reg.kyverno.io/kyverno/cleanup-controller:v1.18.2' \
  'reg.kyverno.io/kyverno/kyverno:v1.18.2' \
  'reg.kyverno.io/kyverno/kyvernopre:v1.18.2' \
  'reg.kyverno.io/kyverno/reports-controller:v1.18.2')"
observed_tagged_images="$(rg -o 'reg\.kyverno\.io/kyverno/[a-z-]+:v1\.18\.2' "$manifest" | sort -u)"
[[ "$observed_tagged_images" == "$expected_tagged_images" ]] ||
  fail 'unexpected image set in the reviewed Kyverno manifest'

sed \
  -e "s#reg.kyverno.io/kyverno/kyverno:v1.18.2#$kyverno_image#g" \
  -e "s#reg.kyverno.io/kyverno/background-controller:v1.18.2#$background_image#g" \
  -e "s#reg.kyverno.io/kyverno/cleanup-controller:v1.18.2#$cleanup_image#g" \
  -e "s#reg.kyverno.io/kyverno/reports-controller:v1.18.2#$reports_image#g" \
  -e "s#reg.kyverno.io/kyverno/kyvernopre:v1.18.2#$pre_image#g" \
  "$manifest" >"$pinned_manifest"
if rg -n 'reg\.kyverno\.io/kyverno/[a-z-]+:v1\.18\.2' "$pinned_manifest"; then
  fail 'a mutable Kyverno image reference remains after digest pinning'
fi
[[ "$(rg -o 'reg\.kyverno\.io/kyverno/[a-z-]+@sha256:[a-f0-9]{64}' "$pinned_manifest" | sort -u | wc -l | tr -d ' ')" == '5' ]] ||
  fail 'the pinned Kyverno manifest does not contain exactly five immutable images'

cluster_creation_started=true
log "creating disposable Kind $kind_version cluster $cluster_name with $kind_node_image"
kind create cluster --name "$cluster_name" --image "$kind_node_image" --wait 180s
require_target_context

observed_server="$(kube version -o json | yq -p=json -r '.serverVersion.gitVersion')"
[[ "$observed_server" == "$kubernetes_version" ]] ||
  fail "expected Kubernetes $kubernetes_version, observed $observed_server"

log "installing Kyverno $kyverno_version from the checksum-verified, digest-pinned manifest"
require_target_context
kube apply --server-side --force-conflicts -f "$pinned_manifest" >/dev/null
kube -n kyverno wait --for=condition=Available deployment --all --timeout=300s >/dev/null

log 'installing validation-only ForgePath ClusterPolicies'
require_target_context
kube apply -f policies/kyverno/workload-security.yaml \
  -f policies/kyverno/serviceaccount-security.yaml >/dev/null
kube wait --for=condition=Ready clusterpolicy --all --timeout=180s >/dev/null

require_target_context
kube create namespace "$test_namespace" >/dev/null

helm template secure-fastapi-service services/secure-fastapi-service/chart \
  --namespace "$test_namespace" \
  --values gitops/environments/local/secure-fastapi-service/values.yaml \
  >"$rendered"
require_target_context
kube -n "$test_namespace" apply --dry-run=server -f "$rendered" >/dev/null
log 'PASS compliant secure-fastapi-service admitted by the Kubernetes API'

assert_rejected tests/kyverno/runtime/privileged-pod.yaml 'Privileged containers are forbidden.'
assert_rejected tests/kyverno/runtime/root-pod.yaml 'Containers must run as non-root.'
assert_rejected tests/kyverno/runtime/latest-pod.yaml 'Mutable image tags latest, stable, main, and master are forbidden.'
assert_rejected tests/kyverno/runtime/missing-resources-pod.yaml 'Containers must define CPU and memory requests and limits.'
assert_rejected tests/kyverno/runtime/host-network-pod.yaml 'hostNetwork is forbidden.'
assert_rejected tests/kyverno/runtime/host-pid-pod.yaml 'hostPID is forbidden.'
log 'PASS privileged, root, latest, resources, hostNetwork, and hostPID fixtures rejected'

log 'restarting the Kyverno admission controller and waiting for availability'
require_target_context
kube -n kyverno rollout restart deployment/kyverno-admission-controller >/dev/null
kube -n kyverno rollout status deployment/kyverno-admission-controller --timeout=300s >/dev/null
assert_rejected tests/kyverno/runtime/privileged-pod.yaml 'Privileged containers are forbidden.'
log 'PASS admission enforcement remained active after Kyverno restart'
log "VERSIONS Kind $kind_version; Kubernetes $observed_server; Kyverno $kyverno_version"

exit 0

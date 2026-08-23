#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"

cluster_name='forgepath-workload-exceptions'
kind_context="kind-$cluster_name"
workload_namespace='forgepath-exception-test'
exception_namespace='forgepath-policy-exceptions'
application_service_account='forgepath-exception-demo-app'
admin_service_account='forgepath-policy-exception-admin'
exception_name='allow-exempted-pod-host-network'
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
evidence_directory=''
original_context=''
cluster_creation_started=false

log() { printf '[forgepath-workload-exceptions-runtime] %s\n' "$*"; }
fail() { printf '[forgepath-workload-exceptions-runtime] ERROR: %s\n' "$*" >&2; exit 1; }
kube() { kubectl --context "$kind_context" "$@"; }

require_target_context() {
  [[ "$(kubectl config current-context 2>/dev/null || true)" == "$kind_context" ]] ||
    fail "refusing mutation because current context is not $kind_context"
}

sha256_file() {
  if command -v sha256sum >/dev/null; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

timestamp_after_seconds() {
  local epoch
  epoch="$(($(date -u +%s) + $1))"
  if date -u -r "$epoch" '+%Y-%m-%dT%H:%M:%SZ' >/dev/null 2>&1; then
    date -u -r "$epoch" '+%Y-%m-%dT%H:%M:%SZ'
  else
    date -u -d "@$epoch" '+%Y-%m-%dT%H:%M:%SZ'
  fi
}

# ShellCheck cannot infer that this function is reached through the EXIT trap.
# shellcheck disable=SC2317
cleanup() {
  local exit_code=$?
  local context_restored=false
  trap - EXIT INT TERM

  if [[ "$cluster_creation_started" == true ]] &&
    kind get clusters 2>/dev/null | grep -Fxq "$cluster_name"; then
    log "deleting only disposable Kind cluster $cluster_name"
    kind delete cluster --name "$cluster_name" >/dev/null || exit_code=1
  fi
  if [[ -n "$original_context" ]]; then
    if kubectl config use-context "$original_context" >/dev/null &&
      [[ "$(kubectl config current-context 2>/dev/null || true)" == "$original_context" ]]; then
      context_restored=true
    else
      exit_code=1
    fi
  fi
  if [[ -n "$runtime_directory" &&
        "$runtime_directory" == /private/tmp/forgepath-workload-exceptions-runtime.* &&
        -d "$runtime_directory" ]]; then
    rm -rf "$runtime_directory"
  fi
  if [[ -n "$evidence_directory" ]]; then
    if ! kind get clusters 2>/dev/null | grep -Fxq "$cluster_name" &&
      [[ "$context_restored" == true ]]; then
      printf 'PASS: disposable cluster deleted; original context restored to %s\n' \
        "$original_context" >"$evidence_directory/cleanup.txt"
    else
      printf 'FAIL: cluster cleanup or context restoration was not proven\n' \
        >"$evidence_directory/cleanup.txt"
      exit_code=1
    fi
  fi
  exit "$exit_code"
}
trap cleanup EXIT INT TERM

assert_rejected() {
  local fixture="$1" expected="$2" evidence_file="$3"
  local status
  require_target_context
  set +e
  kube -n "$workload_namespace" apply --dry-run=server -f "$fixture" \
    >"$evidence_file" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]] || fail "workload unexpectedly admitted: $(basename "$fixture")"
  grep -Fq "$expected" "$evidence_file" || {
    sed -n '1,160p' "$evidence_file" >&2
    fail "workload denial did not identify expected control: $expected"
  }
}

assert_admitted() {
  local fixture="$1" evidence_file="$2"
  require_target_context
  kube -n "$workload_namespace" apply --dry-run=server -f "$fixture" \
    >"$evidence_file" 2>&1 || {
    sed -n '1,160p' "$evidence_file" >&2
    fail "exact exempted workload was not admitted"
  }
}

auth_can_i() {
  local identity_namespace="$1" identity="$2" expected="$3" verb="$4" resource="$5" target_namespace="$6"
  local actual
  actual="$(kube auth can-i "$verb" "$resource" --namespace "$target_namespace" \
    --as="system:serviceaccount:$identity_namespace:$identity" \
    --as-group=system:authenticated \
    --as-group=system:serviceaccounts \
    --as-group="system:serviceaccounts:$identity_namespace" || true)"
  printf '%s/%s can-i %s %s in %s: %s\n' "$identity_namespace" "$identity" \
    "$verb" "$resource" "$target_namespace" "$actual" \
    >>"$evidence_directory/authorization.txt"
  [[ "$actual" == "$expected" ]] ||
    fail "expected $identity can-i $verb $resource in $target_namespace to be $expected, got $actual"
}

for tool in curl jq kind kubectl rg sed yq; do
  command -v "$tool" >/dev/null || fail "required runtime tool not found: $tool"
done
[[ "$(kind version | awk '{print $2}')" == "$kind_version" ]] ||
  fail "Kind $kind_version is required"
kind get clusters | grep -Fxq "$cluster_name" && fail "refusing pre-existing cluster $cluster_name"
original_context="$(kubectl config current-context 2>/dev/null || true)"
[[ -n "$original_context" ]] || fail 'an original Kubernetes context is required'

runtime_directory="$(mktemp -d /private/tmp/forgepath-workload-exceptions-runtime.XXXXXX)"
evidence_directory="$repository_root/.forgepath/workload-exception-evidence/$(date -u '+%Y%m%dT%H%M%SZ')"
mkdir -p "$evidence_directory"
manifest="$runtime_directory/kyverno-install.yaml"
pinned_manifest="$runtime_directory/kyverno-install-pinned.yaml"
configured_manifest="$runtime_directory/kyverno-install-exceptions.yaml"

log "downloading reviewed Kyverno $kyverno_version installation manifest"
curl -fsSLo "$manifest" "$kyverno_manifest_url"
[[ "$(sha256_file "$manifest")" == "$kyverno_manifest_sha256" ]] ||
  fail 'Kyverno installation manifest checksum mismatch'

sed \
  -e "s#reg.kyverno.io/kyverno/kyverno:v1.18.2#$kyverno_image#g" \
  -e "s#reg.kyverno.io/kyverno/background-controller:v1.18.2#$background_image#g" \
  -e "s#reg.kyverno.io/kyverno/cleanup-controller:v1.18.2#$cleanup_image#g" \
  -e "s#reg.kyverno.io/kyverno/reports-controller:v1.18.2#$reports_image#g" \
  -e "s#reg.kyverno.io/kyverno/kyvernopre:v1.18.2#$pre_image#g" \
  -e 's#--enablePolicyException=false#--enablePolicyException=true#g' \
  "$manifest" >"$pinned_manifest"
if rg -n 'reg\.kyverno\.io/kyverno/[a-z-]+:v1\.18\.2' "$pinned_manifest"; then
  fail 'a mutable Kyverno image reference remains after digest pinning'
fi
[[ "$(rg -o 'reg\.kyverno\.io/kyverno/[a-z-]+@sha256:[a-f0-9]{64}' \
  "$pinned_manifest" | sort -u | wc -l | tr -d ' ')" == '5' ]] ||
  fail 'the pinned Kyverno manifest does not contain exactly five immutable images'

EXCEPTION_NAMESPACE="$exception_namespace" yq '
  (select(.kind == "Deployment" and
    (.metadata.name == "kyverno-admission-controller" or
     .metadata.name == "kyverno-background-controller" or
     .metadata.name == "kyverno-reports-controller")).spec.template.spec.containers[] |
    select(.name == "kyverno" or .name == "controller").args) +=
      ["--exceptionNamespace=" + strenv(EXCEPTION_NAMESPACE)]
' "$pinned_manifest" >"$configured_manifest"
[[ "$(rg -c -- '--exceptionNamespace=forgepath-policy-exceptions' "$configured_manifest")" == '3' ]] ||
  fail 'exception namespace was not pinned on all three Kyverno evaluation controllers'

cluster_creation_started=true
log "creating disposable Kind cluster $cluster_name"
kind create cluster --name "$cluster_name" --image "$kind_node_image" --wait 180s
require_target_context
observed_server="$(kube version -o json | yq -p=json -r '.serverVersion.gitVersion')"
[[ "$observed_server" == "$kubernetes_version" ]] ||
  fail "expected Kubernetes $kubernetes_version, observed $observed_server"

require_target_context
kube apply --server-side --force-conflicts -f "$configured_manifest" >/dev/null
kube -n kyverno wait --for=condition=Available deployment --all --timeout=300s >/dev/null

require_target_context
kube apply -f policies/kyverno/workload-security.yaml \
  -f policies/exceptions/exception-boundary.yaml >/dev/null
kube wait --for=condition=Ready clusterpolicy --all --timeout=180s >/dev/null
kube apply -f policies/exceptions/exception-admin-rbac.yaml >/dev/null
kube create namespace "$workload_namespace" >/dev/null
kube -n "$workload_namespace" create serviceaccount "$application_service_account" >/dev/null
kube -n "$workload_namespace" patch serviceaccount "$application_service_account" \
  --type=merge -p '{"automountServiceAccountToken":false}' >/dev/null

TARGET_NAME='exempted-pod' TARGET_NAMESPACE="$workload_namespace" yq '
  .metadata.name = strenv(TARGET_NAME) |
  .metadata.namespace = strenv(TARGET_NAMESPACE)
' tests/kyverno/runtime/host-network-pod.yaml >"$runtime_directory/exempted-pod.yaml"
TARGET_NAME='neighboring-pod' yq '.metadata.name = strenv(TARGET_NAME)' \
  "$runtime_directory/exempted-pod.yaml" >"$runtime_directory/neighboring-pod.yaml"
yq '.spec.hostPID = true' "$runtime_directory/exempted-pod.yaml" \
  >"$runtime_directory/unrelated-control-pod.yaml"

assert_rejected "$runtime_directory/exempted-pod.yaml" 'hostNetwork is forbidden.' \
  "$evidence_directory/01-baseline-denial.txt"
log 'PASS workload denied normally before an exception existed'

approved_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
expires_at="$(timestamp_after_seconds 30)"
APPROVED_AT="$approved_at" EXPIRES_AT="$expires_at" yq '
  .metadata.annotations."forgepath.dev/exception-approved-at" = strenv(APPROVED_AT) |
  .metadata.annotations."forgepath.dev/exception-expires-at" = strenv(EXPIRES_AT) |
  .spec.conditions.all[0].key =
    "{{ time_before(time_now_utc(), '\''" + strenv(EXPIRES_AT) + "'\'') }}"
' tests/exceptions/valid-narrow-exception.yaml >"$runtime_directory/exception.yaml"

: >"$evidence_directory/authorization.txt"
for verb in get list watch create update patch delete; do
  auth_can_i "$workload_namespace" "$application_service_account" no "$verb" \
    policyexceptions.kyverno.io "$exception_namespace"
done
auth_can_i "$exception_namespace" "$admin_service_account" yes create \
  policyexceptions.kyverno.io "$exception_namespace"
auth_can_i "$exception_namespace" "$admin_service_account" yes delete \
  policyexceptions.kyverno.io "$exception_namespace"
auth_can_i "$exception_namespace" "$admin_service_account" no create \
  policyexceptions.kyverno.io "$workload_namespace"
auth_can_i "$exception_namespace" "$admin_service_account" no create \
  clusterpolicies.kyverno.io "$exception_namespace"
auth_can_i "$exception_namespace" "$admin_service_account" no create pods "$workload_namespace"

require_target_context
kube --as="system:serviceaccount:$exception_namespace:$admin_service_account" \
  --as-group=system:authenticated \
  --as-group=system:serviceaccounts \
  --as-group="system:serviceaccounts:$exception_namespace" \
  apply -f "$runtime_directory/exception.yaml" >/dev/null
kube -n "$exception_namespace" get policyexception "$exception_name" -o json \
  >"$evidence_directory/02-applied-exception.json"
jq -e --arg expiry "$expires_at" '
  .metadata.annotations."forgepath.dev/exception-owner" == "platform-security" and
  (.metadata.annotations."forgepath.dev/exception-justification" | length) > 0 and
  .metadata.annotations."forgepath.dev/exception-expires-at" == $expiry and
  (.metadata.annotations."forgepath.dev/exception-approved-by" | length) > 0 and
  (.metadata.annotations."forgepath.dev/exception-approval-reference" | length) > 0 and
  .spec.exceptions == [{"policyName":"forgepath-workload-security",
    "ruleNames":["forbid-host-network"]}] and
  .spec.match.any[0].resources.names == ["exempted-pod"] and
  .spec.match.any[0].resources.namespaces == ["forgepath-exception-test"]
' "$evidence_directory/02-applied-exception.json" >/dev/null ||
  fail 'persisted exception evidence did not retain the exact approved contract'
log "PASS valid narrow exception applied with expiry $expires_at"

assert_admitted "$runtime_directory/exempted-pod.yaml" \
  "$evidence_directory/03-exact-workload-allowed.txt"
assert_rejected "$runtime_directory/neighboring-pod.yaml" 'hostNetwork is forbidden.' \
  "$evidence_directory/04-neighbor-denied.txt"
assert_rejected "$runtime_directory/unrelated-control-pod.yaml" 'hostPID is forbidden.' \
  "$evidence_directory/05-unrelated-control-denied.txt"
log 'PASS only the exact workload/control was allowed; neighbor and hostPID remained denied'

set +e
kube --as="system:serviceaccount:$workload_namespace:$application_service_account" \
  --as-group=system:authenticated \
  --as-group=system:serviceaccounts \
  --as-group="system:serviceaccounts:$workload_namespace" \
  -n "$exception_namespace" patch policyexception "$exception_name" --type=merge \
  -p '{"metadata":{"annotations":{"forgepath.dev/exception-owner":"application"}}}' \
  >"$evidence_directory/06-application-modification-denied.txt" 2>&1
application_patch_status=$?
set -e
[[ $application_patch_status -ne 0 ]] || fail 'application identity modified the exception'
grep -Fqi 'forbidden' "$evidence_directory/06-application-modification-denied.txt" ||
  fail 'application exception-modification denial lacked forbidden evidence'
log 'PASS application identity could not modify the exception'

expiry_epoch="$(date -u -d "$expires_at" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$expires_at" +%s)"
while (( $(date -u +%s) <= expiry_epoch )); do
  sleep 1
done
printf 'expires_at=%s\nobserved_expired_at=%s\nexception_still_present=true\n' \
  "$expires_at" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  >"$evidence_directory/07-expiry.txt"
kube -n "$exception_namespace" get policyexception "$exception_name" >/dev/null ||
  fail 'exception disappeared before in-place expiry could be proven'
assert_rejected "$runtime_directory/exempted-pod.yaml" 'hostNetwork is forbidden.' \
  "$evidence_directory/08-post-expiry-denial.txt"
log 'PASS exception expired in place and the workload was denied again'

require_target_context
kube --as="system:serviceaccount:$exception_namespace:$admin_service_account" \
  --as-group=system:authenticated \
  --as-group=system:serviceaccounts \
  --as-group="system:serviceaccounts:$exception_namespace" \
  -n "$exception_namespace" delete policyexception "$exception_name" --wait=true >/dev/null
removed_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
printf 'approved_at=%s\nexpires_at=%s\nremoved_at=%s\nremoved_by=system:serviceaccount:%s:%s\n' \
  "$approved_at" "$expires_at" "$removed_at" "$exception_namespace" \
  "$admin_service_account" >"$evidence_directory/09-removal.txt"
log 'PASS expired exception object removed by the platform identity'

cat >"$evidence_directory/summary.txt" <<EOF
PASS baseline workload denied
PASS exact policy/rule and exact namespace/Pod exception admitted
PASS exact Pod allowed only for hostNetwork
PASS neighboring Pod denied
PASS unrelated hostPID control denied
PASS application ServiceAccount denied exception mutation
PASS exception expired while its object still existed
PASS formerly exempted Pod denied after expiry
PASS expired exception object removed by dedicated platform administrator
owner=platform-security
justification=Temporary compatibility test for one named workload.
approved_by=platform-security-reviewer
approval_reference=FORGEPATH-EXC-0001
approved_at=$approved_at
expires_at=$expires_at
removed_at=$removed_at
affected=forgepath-workload-security/forbid-host-network:$workload_namespace/exempted-pod
EOF

log "EVIDENCE $evidence_directory"
log "VERSIONS Kind $kind_version; Kubernetes $observed_server; Kyverno $kyverno_version"

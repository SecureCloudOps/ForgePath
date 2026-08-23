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
registry_image='registry:2.8.3@sha256:a3d8aaa63ed8681a604f1dea0aa03f100d5895b6a58ace528858a7b332415373'
artifact_directory="${FORGEPATH_ARTIFACT_DIR:-$repository_root/.forgepath/trusted-artifact}"
trusted_image_template='policies/templates/trusted-image-verification.yaml.tmpl'

runtime_directory=''
original_context=''
cluster_creation_started=false
port_forward_pid=''

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

  if [[ -n "$port_forward_pid" ]] && kill -0 "$port_forward_pid" 2>/dev/null; then
    kill "$port_forward_pid" 2>/dev/null || true
    wait "$port_forward_pid" 2>/dev/null || true
  fi

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

assert_admitted() {
  local fixture="$1"
  local report

  report="$runtime_directory/$(basename "$fixture").admission.txt"

  require_target_context
  if ! kube -n "$test_namespace" apply --dry-run=server -f "$fixture" >"$report" 2>&1; then
    sed -n '1,180p' "$report" >&2
    fail "compliant runtime fixture was rejected: $fixture"
  fi
}

publish_oci_archive() {
  local archive="$1"
  local digest="$2"
  local layout="$runtime_directory/oci-layout"
  local repository='forgepath/secure-fastapi-service'
  local blob
  local blob_digest
  local location
  local separator
  local upload_path
  local observed_digest

  mkdir -p "$layout"
  tar -xf "$archive" -C "$layout"
  [[ "$(jq -er '.manifests | if length == 1 then .[0].digest else error("expected one OCI manifest") end' "$layout/index.json")" == "$digest" ]] ||
    fail 'OCI archive index does not match trusted artifact digest'

  for blob in "$layout"/blobs/sha256/*; do
    blob_digest="sha256:$(basename "$blob")"
    location="$(curl -fsS -D - -o /dev/null -X POST \
      "http://127.0.0.1:5000/v2/$repository/blobs/uploads/" |
      awk 'BEGIN {IGNORECASE=1} /^Location:/ {sub(/^[^:]+:[[:space:]]*/, ""); sub(/\r$/, ""); print; exit}')"
    [[ -n "$location" ]] || fail 'registry did not return an OCI blob upload location'
    upload_path="$(sed -E 's#^https?://[^/]+##' <<<"$location")"
    separator='?'
    [[ "$upload_path" == *'?'* ]] && separator='&'
    curl -fsS -o /dev/null --upload-file "$blob" \
      "http://127.0.0.1:5000${upload_path}${separator}digest=$blob_digest"
  done

  curl -fsS -o /dev/null --upload-file "$layout/blobs/sha256/${digest#sha256:}" \
    -H 'Content-Type: application/vnd.oci.image.manifest.v1+json' \
    "http://127.0.0.1:5000/v2/$repository/manifests/admission-demo"
  observed_digest="$(curl -fsSI \
    -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
    "http://127.0.0.1:5000/v2/$repository/manifests/admission-demo" |
    awk 'BEGIN {IGNORECASE=1} /^Docker-Content-Digest:/ {sub(/^[^:]+:[[:space:]]*/, ""); sub(/\r$/, ""); print; exit}')"
  [[ "$observed_digest" == "$digest" ]] ||
    fail 'disposable registry digest does not match trusted artifact evidence'
}

for tool in cosign curl docker helm jq kind kubectl rg sed tar yq; do
  command -v "$tool" >/dev/null || fail "required runtime tool not found: $tool"
done


[[ -s "$artifact_directory/metadata.json" ]] ||
  fail "trusted artifact is missing; run make validate-trusted-artifact first"
"$repository_root/scripts/validate-trusted-artifact.sh" "$artifact_directory" >/dev/null
trusted_repository="$(jq -er '.image.repository' "$artifact_directory/metadata.json")"
trusted_digest="$(jq -er '.image.digest' "$artifact_directory/metadata.json")"
[[ "$trusted_repository" == 'ghcr.io/securecloudops/secure-fastapi-service' ]] ||
  fail 'trusted artifact repository is outside the approved production registry'

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
demo_manifest="$runtime_directory/kyverno-install-demo.yaml"
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

REGISTRY_IMAGE="$registry_image" yq eval '
  (select(.kind == "Deployment" and .metadata.name == "kyverno-admission-controller").spec.replicas) = 1 |
  (select(.kind == "Deployment" and .metadata.name == "kyverno-admission-controller").spec.template.spec.containers[] |
    select(.name == "kyverno").args[] | select(. == "--allowInsecureRegistry=false")) = "--allowInsecureRegistry=true" |
  (select(.kind == "Deployment" and .metadata.name == "kyverno-admission-controller").spec.template.spec.containers) += [{
    "name": "forgepath-demo-registry",
    "image": strenv(REGISTRY_IMAGE),
    "imagePullPolicy": "IfNotPresent",
    "ports": [{"name": "registry", "containerPort": 5000, "protocol": "TCP"}],
    "securityContext": {
      "allowPrivilegeEscalation": false,
      "capabilities": {"drop": ["ALL"]},
      "privileged": false,
      "readOnlyRootFilesystem": true,
      "runAsNonRoot": true,
      "runAsUser": 10000,
      "runAsGroup": 10000,
      "seccompProfile": {"type": "RuntimeDefault"}
    },
    "volumeMounts": [{"name": "forgepath-demo-registry", "mountPath": "/var/lib/registry"}],
    "resources": {
      "requests": {"cpu": "10m", "memory": "32Mi"},
      "limits": {"cpu": "200m", "memory": "128Mi"}
    }
  }] |
  (select(.kind == "Deployment" and .metadata.name == "kyverno-admission-controller").spec.template.spec.volumes) += [{
    "name": "forgepath-demo-registry", "emptyDir": {}
  }]
' "$pinned_manifest" >"$demo_manifest"
[[ "$(yq -r 'select(.kind == "Deployment" and .metadata.name == "kyverno-admission-controller") |
  .spec.template.spec.containers[] | select(.name == "forgepath-demo-registry").image' "$demo_manifest")" == "$registry_image" ]] ||
  fail 'disposable registry image was not pinned into the reviewed Kyverno manifest'

cluster_creation_started=true
log "creating disposable Kind $kind_version cluster $cluster_name with $kind_node_image"
kind create cluster --name "$cluster_name" --image "$kind_node_image" --wait 180s
require_target_context

observed_server="$(kube version -o json | yq -p=json -r '.serverVersion.gitVersion')"
[[ "$observed_server" == "$kubernetes_version" ]] ||
  fail "expected Kubernetes $kubernetes_version, observed $observed_server"

log "installing Kyverno $kyverno_version from the checksum-verified, digest-pinned manifest"
require_target_context
kube apply --server-side --force-conflicts -f "$demo_manifest" >/dev/null
kube -n kyverno wait --for=condition=Available deployment --all --timeout=300s >/dev/null

log 'installing validation-only ForgePath ClusterPolicies'
require_target_context
kube apply -f policies/kyverno/workload-security.yaml \
  -f policies/kyverno/serviceaccount-security.yaml \
  -f policies/kyverno/platform-guardrails.yaml >/dev/null
kube wait --for=condition=Ready clusterpolicy --all --timeout=180s >/dev/null

require_target_context
kube create namespace "$test_namespace" >/dev/null

DEMO_REFERENCE="ghcr.io/securecloudops/secure-fastapi-service@$trusted_digest" yq \
  '.spec.containers[0].image = strenv(DEMO_REFERENCE)' \
  tests/kyverno/runtime/trusted-image-pod.yaml.tmpl \
  >"$runtime_directory/metadata-base-pod.yaml"
while IFS='|' read -r label expected; do
  fixture="$runtime_directory/missing-${label##*/}.yaml"
  LABEL="$label" yq 'del(.metadata.labels[strenv(LABEL)])' \
    "$runtime_directory/metadata-base-pod.yaml" >"$fixture"
  assert_rejected "$fixture" "$expected"
done <<'METADATA_FIXTURES'
forgepath.dev/owner|Missing required workload metadata: set a non-empty forgepath.dev/owner label.
forgepath.dev/system|Missing required workload metadata: set a non-empty forgepath.dev/system label.
forgepath.dev/environment|Missing required workload metadata: set a non-empty forgepath.dev/environment label.
forgepath.dev/data-classification|Missing required workload metadata: set a non-empty forgepath.dev/data-classification label.
METADATA_FIXTURES
assert_rejected tests/policy/fixtures/invalid-metadata.yaml \
  'Workload environment must be local, development, staging, or production'
assert_rejected tests/policy/fixtures/tagged-approved-image.yaml \
  'Images must use a sha256 digest'
assert_rejected tests/policy/fixtures/unapproved-registry.yaml \
  'Images must come from ghcr.io/securecloudops'
log 'PASS each required metadata key, tag-only image, and unapproved registry produced actionable denial text'

log 'publishing the trusted OCI artifact to the isolated admission-demo registry'
kube -n kyverno port-forward deployment/kyverno-admission-controller 5000:5000 \
  >"$runtime_directory/registry-port-forward.log" 2>&1 &
port_forward_pid=$!
for _ in $(seq 1 30); do
  if curl -fsS http://localhost:5000/v2/ >/dev/null 2>&1; then
    break
  fi
  kill -0 "$port_forward_pid" 2>/dev/null || {
    sed -n '1,120p' "$runtime_directory/registry-port-forward.log" >&2
    fail 'disposable registry port-forward exited before becoming ready'
  }
  sleep 1
done
curl -fsS http://localhost:5000/v2/ >/dev/null || fail 'disposable registry did not become ready'
demo_reference="127.0.0.1:5000/forgepath/secure-fastapi-service@$trusted_digest"
publish_oci_archive "$artifact_directory/image.oci.tar" "$trusted_digest"

DEMO_REFERENCE="$demo_reference" yq \
  '.spec.containers[0].image = strenv(DEMO_REFERENCE)' \
  tests/kyverno/runtime/trusted-image-pod.yaml.tmpl \
  >"$runtime_directory/trusted-pod.yaml"

key_prefix="$runtime_directory/cosign"
COSIGN_PASSWORD='' cosign generate-key-pair --output-key-prefix "$key_prefix" >/dev/null 2>&1
cp "$trusted_image_template" "$runtime_directory/trusted-image-verification.yaml"
PUBLIC_KEY_FILE="$key_prefix.pub" yq -i '
  .spec.rules[0].verifyImages[0].attestors[0].entries[0].keys.publicKeys = load_str(strenv(PUBLIC_KEY_FILE)) |
  .spec.rules[0].verifyImages[0].attestors[0].entries[0].keys.rekor.ignoreTlog = true |
  .spec.rules[0].verifyImages[0].attestations[0].attestors[0].entries[0].keys.publicKeys = load_str(strenv(PUBLIC_KEY_FILE)) |
  .spec.rules[0].verifyImages[0].attestations[0].attestors[0].entries[0].keys.rekor.ignoreTlog = true |
  .metadata.annotations."forgepath.dev/demo-rekor-mode" = "offline-ignore-tlog"
' "$runtime_directory/trusted-image-verification.yaml"
require_target_context
kube apply -f "$runtime_directory/trusted-image-verification.yaml" >/dev/null
kube wait --for=condition=Ready clusterpolicy/forgepath-trusted-image-verification --timeout=180s >/dev/null

assert_rejected "$runtime_directory/trusted-pod.yaml" 'signature'
log 'PASS valid ownership with an unsigned trusted-registry digest was denied'

COSIGN_PASSWORD='' cosign sign --yes --tlog-upload=false --allow-http-registry \
  --key "$key_prefix.key" "$demo_reference" >/dev/null
assert_rejected "$runtime_directory/trusted-pod.yaml" 'attestation'
log 'PASS a signed digest without required SLSA provenance was denied'

cat >"$runtime_directory/provenance.json" <<EOF
{
  "buildDefinition": {
    "buildType": "https://forgepath.dev/build-types/admission-demo/v1",
    "externalParameters": {},
    "internalParameters": {},
    "resolvedDependencies": []
  },
  "runDetails": {
    "builder": {"id": "https://forgepath.dev/builders/local-runtime-proof/v1"},
    "metadata": {"invocationId": "forgepath-kyverno-runtime"}
  }
}
EOF
COSIGN_PASSWORD='' cosign attest --yes --tlog-upload=false --allow-http-registry \
  --type slsaprovenance1 --predicate "$runtime_directory/provenance.json" \
  --key "$key_prefix.key" "$demo_reference" >/dev/null
rm -f "$key_prefix.key"
assert_admitted "$runtime_directory/trusted-pod.yaml"
log 'PASS signed trusted digest with verified SLSA provenance admitted'

yq '.metadata.name = "prohibited-privilege-demo" |
  .spec.containers[0].securityContext.privileged = true |
  .spec.containers[0].securityContext.allowPrivilegeEscalation = true' \
  "$runtime_directory/trusted-pod.yaml" >"$runtime_directory/privileged-trusted-pod.yaml"
assert_rejected "$runtime_directory/privileged-trusted-pod.yaml" 'Privileged containers are forbidden.'
log 'PASS signed trusted workload requesting prohibited privilege denied'
assert_admitted "$runtime_directory/trusted-pod.yaml"
log 'PASS compliant metadata, trusted image, and workload security admitted'

helm template secure-fastapi-service services/secure-fastapi-service/chart \
  --namespace "$test_namespace" \
  --values gitops/environments/local/secure-fastapi-service/values.yaml \
  --set image.repository=127.0.0.1:5000/forgepath/secure-fastapi-service \
  --set image.digest="$trusted_digest" \
  >"$rendered"
yq 'select(.kind == "Rollout") | {
  "apiVersion": "v1",
  "kind": "Pod",
  "metadata": {
    "name": (.metadata.name + "-rendered-admission"),
    "labels": .spec.template.metadata.labels
  },
  "spec": (.spec.template.spec | .serviceAccountName = "default")
}' "$rendered" >"$runtime_directory/rendered-workload-pod.yaml"
assert_admitted "$runtime_directory/rendered-workload-pod.yaml"
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

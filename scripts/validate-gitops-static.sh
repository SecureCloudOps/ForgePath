#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"

run_negative_tests=false
if [[ "${1:-}" == "--run-negative-tests" ]]; then
  run_negative_tests=true
elif [[ -n "${1:-}" ]]; then
  printf 'unknown GitOps validation option: %s\n' "$1" >&2
  exit 1
fi

python_bin="${PYTHON_BIN:-python3.12}"
for tool in "$python_bin" conftest helm jq kubeconform rg yq; do
  if ! command -v "$tool" >/dev/null; then
    printf 'required GitOps validation tool not found: %s\n' "$tool" >&2
    exit 1
  fi
done

approved_repository='git@github.com:SecureCloudOps/ForgePath.git'
intended_namespace='secure-fastapi-service-local'
cluster_server='https://kubernetes.default.svc'
chart="$repository_root/services/secure-fastapi-service/chart"
values="$repository_root/gitops/environments/local/secure-fastapi-service/values.yaml"
project="$repository_root/gitops/projects/forgepath-local.yaml"
application="$repository_root/gitops/applications/secure-fastapi-service-local.yaml"
platform_namespace="$repository_root/gitops/platform/namespaces/secure-fastapi-service-local.yaml"
metadata="${TRUSTED_ARTIFACT_METADATA:-$repository_root/.forgepath/trusted-artifact/metadata.json}"
schema_directory="$repository_root/gitops/schemas/kubernetes/v1.32.0-standalone-strict"
work_directory="$(mktemp -d)"
cleanup() {
  rm -rf "$work_directory"
}
trap cleanup EXIT

validate_argocd() {
  local candidate_project="$1"
  local candidate_application="$2"

  yq -o=json "$candidate_project" | jq -e \
    --arg repo "$approved_repository" \
    --arg namespace "$intended_namespace" \
    --arg server "$cluster_server" '
      .apiVersion == "argoproj.io/v1alpha1" and
      .kind == "AppProject" and
      .metadata.name == "forgepath-local" and
      .metadata.namespace == "argocd" and
      .spec.sourceRepos == [$repo] and
      .spec.destinations == [{"namespace": $namespace, "server": $server}] and
      (.spec.namespaceResourceWhitelist | length) == 7 and
      ([.spec.namespaceResourceWhitelist[] | [.group, .kind]] | sort) ==
        [["", "ConfigMap"], ["", "Service"], ["", "ServiceAccount"],
         ["argoproj.io", "AnalysisTemplate"], ["argoproj.io", "Rollout"],
         ["monitoring.coreos.com", "PrometheusRule"], ["monitoring.coreos.com", "ServiceMonitor"]] and
      .spec.clusterResourceBlacklist == [{"group": "*", "kind": "*"}] and
      (.spec.clusterResourceWhitelist == null)
    ' >/dev/null || return 1

  yq -o=json "$candidate_application" | jq -e \
    --arg repo "$approved_repository" \
    --arg namespace "$intended_namespace" \
    --arg server "$cluster_server" '
      .apiVersion == "argoproj.io/v1alpha1" and
      .kind == "Application" and
      .metadata.name == "secure-fastapi-service-local" and
      .metadata.namespace == "argocd" and
      .spec.project == "forgepath-local" and
      .spec.source.repoURL == $repo and
      .spec.source.targetRevision == "main" and
      .spec.source.path == "services/secure-fastapi-service/chart" and
      .spec.source.helm.releaseName == "secure-fastapi-service" and
      .spec.source.helm.valueFiles == ["../../../gitops/environments/local/secure-fastapi-service/values.yaml"] and
      .spec.destination == {"server": $server, "namespace": $namespace} and
      .spec.syncPolicy.automated.prune == true and
      .spec.syncPolicy.automated.selfHeal == true and
      (.spec.syncPolicy.managedNamespaceMetadata == null) and
      (.spec.syncPolicy.syncOptions == ["ApplyOutOfSyncOnly=true"]) and
      ((.spec.syncPolicy.syncOptions // []) | index("CreateNamespace=true") == null)
    ' >/dev/null || return 1

  if rg -l '^kind:[[:space:]]*ApplicationSet[[:space:]]*$' gitops >/dev/null; then
    printf 'ApplicationSet is not authorized for the current single-service model\n' >&2
    return 1
  fi
}

validate_platform_namespace() {
  local candidate="$1"
  local documents

  documents="$(yq -o=json -I=0 'select(. != null)' "$candidate")"
  jq -se --arg namespace "$intended_namespace" '
    length == 6 and
    ([.[] | [(.apiVersion | split("/") | if length == 1 then "" else .[0] end), .kind]] | sort) ==
      [["", "LimitRange"], ["", "Namespace"], ["", "ResourceQuota"],
       ["networking.k8s.io", "NetworkPolicy"],
       ["networking.k8s.io", "NetworkPolicy"],
       ["networking.k8s.io", "NetworkPolicy"]] and
    ([.[] | select(.kind == "Namespace")] | length) == 1 and
    all(.[] | select(.kind == "Namespace");
      .metadata.name == $namespace and
      .metadata.labels["forgepath.dev/managed-by"] == "platform" and
      .metadata.labels["pod-security.kubernetes.io/enforce"] == "restricted" and
      .metadata.labels["pod-security.kubernetes.io/enforce-version"] == "v1.32" and
      .metadata.labels["pod-security.kubernetes.io/audit"] == "restricted" and
      .metadata.labels["pod-security.kubernetes.io/warn"] == "restricted") and
    all(.[] | select(.kind != "Namespace");
      .metadata.namespace == $namespace and
      .metadata.labels["forgepath.dev/managed-by"] == "platform")
  ' <<<"$documents" >/dev/null
}

read_trusted_reference() {
  local trusted_marker

  if [[ ! -s "$metadata" ]]; then
    printf 'trusted artifact metadata is missing: %s\n' "$metadata" >&2
    return 1
  fi
  trusted_marker="$(dirname "$metadata")/TRUSTED"
  if [[ ! -s "$trusted_marker" ]]; then
    printf 'trusted artifact marker is missing: %s\n' "$trusted_marker" >&2
    return 1
  fi

  jq -er '
    select(
      .schema_version == 1 and
      (.image.repository | type == "string" and length > 0) and
      (.image.digest | test("^sha256:[a-f0-9]{64}$")) and
      .image.trusted_reference == (.image.repository + "@" + .image.digest) and
      .vulnerability_scan.result == "passed" and
      .signature.verification_result == "passed"
    ) |
    .image.trusted_reference
  ' "$metadata"
}

authorize_rendered() {
  local manifests="$1"
  local trusted_reference="$2"
  local documents

  documents="$(yq -o=json -I=0 'select(. != null)' "$manifests")"
  if [[ -z "$documents" ]]; then
    printf 'Helm rendered no Kubernetes resources\n' >&2
    return 1
  fi

  if jq -se 'any(.[]; .kind == "Namespace")' <<<"$documents" >/dev/null; then
    printf 'application chart must never render Namespace; namespace lifecycle is platform-owned\n' >&2
    return 1
  fi

  if ! jq -se --arg namespace "$intended_namespace" '
    length == 8 and
    all(.[ ]; .apiVersion and .kind and .metadata.name) and
    all(.[ ]; (.metadata.namespace // $namespace) == $namespace) and
    ([.[] | [(.apiVersion | split("/") | if length == 1 then "" else .[0] end), .kind]] | sort) ==
      [["", "ConfigMap"], ["", "Service"], ["", "Service"], ["", "ServiceAccount"],
       ["argoproj.io", "AnalysisTemplate"], ["argoproj.io", "Rollout"],
       ["monitoring.coreos.com", "PrometheusRule"], ["monitoring.coreos.com", "ServiceMonitor"]]
  ' <<<"$documents" >/dev/null; then
    printf 'rendered resources exceed the AppProject namespace/kind allowlist\n' >&2
    return 1
  fi

  if ! jq -se --arg reference "$trusted_reference" '
    [.[] | select(.kind == "Rollout") | .spec.template.spec |
      ((.initContainers // []) + (.containers // []) + (.ephemeralContainers // []))[] |
      .image] as $images |
    ($images | length) > 0 and
    all($images[]; . == $reference and test("^[^@]+@sha256:[a-f0-9]{64}$"))
  ' <<<"$documents" >/dev/null; then
    printf 'rendered image does not exactly match the trusted immutable reference\n' >&2
    return 1
  fi

  if ! jq -se '
    [.[] | select(.kind == "AnalysisTemplate") |
      .spec.metrics[] | select(.name == "availability-burn-rate")] as $metrics |
    ($metrics | length) == 1 and
    all($metrics[];
      .count == 1 and .failureLimit == 0 and .consecutiveErrorLimit == 0)
  ' <<<"$documents" >/dev/null; then
    printf 'availability analysis must fail closed on its first failed or errored measurement\n' >&2
    return 1
  fi
}

render_and_validate() {
  local candidate_values="$1"
  local output="$2"
  local trusted_reference="$3"
  local generated_service="$work_directory/generated-service"
  local combined="$work_directory/combined.yaml"
  local metadata_repository metadata_digest marker_digest values_repository values_digest

  metadata_repository="$(jq -er '.image.repository' "$metadata")"
  metadata_digest="$(jq -er '.image.digest' "$metadata")"
  marker_digest="$(tr -d '\r\n' <"$(dirname "$metadata")/TRUSTED")"
  values_repository="$(yq -er '.image.repository' "$candidate_values")"
  values_digest="$(yq -er '.image.digest' "$candidate_values")"

  if [[ "$marker_digest" != "$metadata_digest" ]] ||
     [[ "$values_repository" != "$metadata_repository" ]] ||
     [[ "$values_digest" != "$metadata_digest" ]]; then
    printf 'GitOps desired state does not match trusted artifact metadata\n' >&2
    return 1
  fi
  if [[ ! "$values_digest" =~ ^sha256:[a-f0-9]{64}$ ]]; then
    printf 'GitOps desired state contains a mutable or invalid image reference\n' >&2
    return 1
  fi

  if [[ ! -d "$generated_service" ]]; then
    "$python_bin" templates/secure-fastapi-service/render.py \
      --output "$generated_service" --service-name secure-fastapi-service || return 1
  fi
  diff -ru "$generated_service/chart" "$chart" >/dev/null || {
    printf 'application chart has drifted from the secure-fastapi-service paved path\n' >&2
    return 1
  }

  helm lint "$chart" --values "$candidate_values" >/dev/null || return 1
  helm template secure-fastapi-service "$chart" \
    --namespace "$intended_namespace" --values "$candidate_values" >"$output"
  kubeconform -exit-on-error -strict -summary \
    -skip AnalysisTemplate,PrometheusRule,Rollout,ServiceMonitor \
    -schema-location "file://$schema_directory/{{.ResourceKind}}{{.KindSuffix}}.json" \
    "$output" >/dev/null || return 1
  validate_platform_namespace "$platform_namespace" || return 1
  cp "$platform_namespace" "$combined"
  printf '\n---\n' >>"$combined"
  cat "$output" >>"$combined"
  conftest test --combine --policy policies "$combined" >/dev/null || return 1
  authorize_rendered "$output" "$trusted_reference"
}

run_policy() {
  conftest test --combine --policy policies "$1" >/dev/null
}

expect_rejection() {
  local description="$1"
  shift
  if "$@" >"$work_directory/negative.stdout" 2>"$work_directory/negative.stderr"; then
    printf 'negative test unexpectedly passed: %s\n' "$description" >&2
    return 1
  fi
  printf 'negative test passed: %s\n' "$description"
}

run_negative_suite() {
  local trusted_reference="$1"
  local rendered="$2"
  local mismatch_values="$work_directory/mismatch-values.yaml"
  local mutable_values="$work_directory/mutable-values.yaml"
  local unauthorized_namespace="$work_directory/unauthorized-namespace.yaml"
  local unauthorized_repository="$work_directory/unauthorized-repository.yaml"
  local missing_psa="$work_directory/missing-psa.yaml"
  local namespace_creation_enabled="$work_directory/namespace-creation-enabled.yaml"
  local namespace_permission="$work_directory/namespace-permission.yaml"
  local namespace_in_chart="$work_directory/namespace-in-chart.yaml"
  local secret_manifests="$work_directory/secret-manifests.yaml"
  local cluster_manifests="$work_directory/cluster-manifests.yaml"
  local policy_violation="$work_directory/policy-violation.yaml"

  yq '.image.digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' \
    "$values" >"$mismatch_values"
  expect_rejection 'mismatched artifact digest' render_and_validate \
    "$mismatch_values" "$work_directory/mismatch-rendered.yaml" "$trusted_reference"

  yq '.image.digest = "latest"' "$values" >"$mutable_values"
  expect_rejection 'mutable image reference' render_and_validate \
    "$mutable_values" "$work_directory/mutable-rendered.yaml" "$trusted_reference"

  yq '.spec.destination.namespace = "unauthorized"' "$application" >"$unauthorized_namespace"
  expect_rejection 'unauthorized namespace' validate_argocd \
    "$project" "$unauthorized_namespace"

  yq '.spec.source.repoURL = "https://example.invalid/unauthorized.git"' \
    "$application" >"$unauthorized_repository"
  expect_rejection 'unauthorized repository' validate_argocd \
    "$project" "$unauthorized_repository"

  yq 'del((select(.kind == "Namespace") | .metadata.labels."pod-security.kubernetes.io/enforce"))' \
    "$platform_namespace" >"$missing_psa"
  expect_rejection 'missing platform-owned restricted Pod Security enforcement' \
    validate_platform_namespace "$missing_psa"

  yq '.spec.syncPolicy.syncOptions += ["CreateNamespace=true"]' \
    "$application" >"$namespace_creation_enabled"
  expect_rejection 'CreateNamespace=true reappeared' validate_argocd \
    "$project" "$namespace_creation_enabled"

  yq '.spec.clusterResourceWhitelist = [{"group": "", "kind": "Namespace"}]' \
    "$project" >"$namespace_permission"
  expect_rejection 'application AppProject namespace creation permission' validate_argocd \
    "$namespace_permission" "$application"

  cp "$rendered" "$namespace_in_chart"
  printf '\n---\napiVersion: v1\nkind: Namespace\nmetadata:\n  name: forbidden\n' \
    >>"$namespace_in_chart"
  expect_rejection 'application chart Namespace manifest' authorize_rendered \
    "$namespace_in_chart" "$trusted_reference"

  cp "$rendered" "$secret_manifests"
  printf '\n---\napiVersion: v1\nkind: Secret\nmetadata:\n  name: forbidden\ntype: Opaque\n' \
    >>"$secret_manifests"
  expect_rejection 'Secret manifest' authorize_rendered \
    "$secret_manifests" "$trusted_reference"

  cp "$rendered" "$cluster_manifests"
  printf '\n---\napiVersion: rbac.authorization.k8s.io/v1\nkind: ClusterRole\nmetadata:\n  name: forbidden\nrules: []\n' \
    >>"$cluster_manifests"
  expect_rejection 'disallowed cluster-scoped resource' authorize_rendered \
    "$cluster_manifests" "$trusted_reference"

  sed 's/allowPrivilegeEscalation: false/allowPrivilegeEscalation: true/' \
    "$rendered" >"$policy_violation"
  expect_rejection 'policy-violating rendered Helm output' run_policy "$policy_violation"
}

validate_argocd "$project" "$application"
validate_platform_namespace "$platform_namespace"
trusted_reference="$(read_trusted_reference)"
rendered="$work_directory/rendered.yaml"
render_and_validate "$values" "$rendered" "$trusted_reference"

if [[ "$run_negative_tests" == "true" ]]; then
  run_negative_suite "$trusted_reference" "$rendered"
fi

printf 'ForgePath static GitOps validation passed for %s\n' "$trusted_reference"

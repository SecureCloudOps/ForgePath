#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"

fail() {
  printf '[forgepath-workload-identity-static] ERROR: %s\n' "$*" >&2
  exit 1
}

for tool in helm jq yq; do
  command -v "$tool" >/dev/null || fail "required tool not found: $tool"
done

temporary_root="${TMPDIR:-/tmp}"
work_directory="$(mktemp -d "${temporary_root%/}/forgepath-workload-identity-static.XXXXXX")"
trap 'rm -rf "$work_directory"' EXIT

validate_chart_identity() {
  local chart="$1"
  local name="$2"
  local rendered="$work_directory/$name.yaml"
  local documents="$work_directory/$name.json"

  helm template identity "$chart" \
    --namespace forgepath-identity-test \
    --set workloadMetadata.owner=platform \
    --set workloadMetadata.system=forgepath \
    --set workloadMetadata.environment=local \
    --set workloadMetadata.dataClassification=internal \
    --set image.repository=ghcr.io/securecloudops/identity-test >"$rendered"
  yq -o=json -I=0 'select(. != null)' "$rendered" | jq -s '.' >"$documents"

  jq -e '
    ([.[] | select(.kind == "ServiceAccount")] | length) == 1 and
    ([.[] | select(.kind == "ServiceAccount") |
      .automountServiceAccountToken == false] | all) and
    (([.[] | select(.kind == "ServiceAccount") | .metadata.name][0]) as $service_account |
      ([.[] | select(.kind == "Rollout") |
        .spec.template.spec.automountServiceAccountToken == false and
        .spec.template.spec.serviceAccountName == $service_account and
        ([.spec.template.spec | .. | objects |
          select(has("serviceAccountToken"))] | length) == 0] | all)) and
    ([.[] | select(.kind == "Role" or .kind == "RoleBinding" or
      .kind == "ClusterRole" or .kind == "ClusterRoleBinding")] | length) == 0
  ' "$documents" >/dev/null ||
    fail "$chart does not preserve the zero-permission, tokenless application identity"
}

validate_chart_identity services/secure-fastapi-service/chart reference
validate_chart_identity templates/secure-fastapi-service/skeleton/chart template

yq -o=json gitops/projects/forgepath-local.yaml | jq -e '
  (.spec.clusterResourceBlacklist |
    any(.group == "*" and .kind == "*")) and
  (.spec.namespaceResourceWhitelist |
    all(.group != "rbac.authorization.k8s.io")) and
  (.spec.namespaceResourceWhitelist |
    all(.kind != "Secret"))
' >/dev/null || fail 'AppProject must deny cluster resources, workload RBAC, and Secrets'

printf '[forgepath-workload-identity-static] PASS application identity has no RBAC grant or token mount\n'
printf '[forgepath-workload-identity-static] PASS AppProject cannot deliver application-owned RBAC or Secrets\n'

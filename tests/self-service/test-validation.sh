#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
renderer="$repository_root/templates/secure-fastapi-service/render.py"
publisher="$repository_root/templates/secure-fastapi-service/publish.py"
python_bin="${PYTHON_BIN:-python3.12}"
work_directory="$(mktemp -d)"
trap 'rm -rf "$work_directory"' EXIT

"$python_bin" -m unittest "$repository_root/tests/self-service/test_publish.py"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_rejected() {
  local name="$1"
  local expected="$2"
  shift 2
  local output
  if output=$("$@" 2>&1); then
    fail "$name was unexpectedly accepted"
  fi
  [[ "$output" == *"$expected"* ]] ||
    fail "$name did not report the expected safe error: $output"
  printf 'PASS safe rejection: %s\n' "$name"
}

valid_render=(
  "$python_bin" "$renderer"
  --service-name payments-api
  --owner group:default/platform
  --system forgepath
  --environment development
  --data-classification confidential
  --image-repository ghcr.io/securecloudops/payments-api
  --kubernetes-namespace payments-api-development
)

assert_rejected invalid-owner 'owner must be a group:default/<dns-label> entity reference' \
  "$python_bin" "$renderer" --output "$work_directory/invalid-owner" \
  --service-name payments-api --owner user:default/alice

assert_rejected missing-classification 'expected one argument' \
  "$python_bin" "$renderer" --output "$work_directory/missing-classification" \
  --service-name payments-api --data-classification

assert_rejected unsupported-image 'image repository must use ghcr.io' \
  "$python_bin" "$renderer" --output "$work_directory/unsupported-image" \
  --service-name payments-api --image-repository docker.io/example/payments-api

assert_rejected privileged-access 'privileged access is not supported' \
  "$python_bin" "$renderer" --output "$work_directory/privileged" \
  --service-name payments-api --privileged

assert_rejected malformed-service-name 'service name must be a 3-63 character DNS label' \
  "$python_bin" "$renderer" --output "$work_directory/malformed" \
  --service-name 'Payments_API'

rendered="$work_directory/generated/payments-api"
"${valid_render[@]}" --output "$rendered"

publish_common=(
  "$python_bin" "$publisher"
  --mode local
  --source "$rendered"
  --generation-root "$work_directory/generated"
  --simulation-root "$work_directory/published"
  --service-name payments-api
  --owner group:default/platform
  --system forgepath
  --environment development
  --data-classification confidential
  --gitops-repository SecureCloudOps/forgepath-gitops
  --backstage-identity user:default/local-developer
  --allowed-owner group:default/platform
  --allowed-system forgepath
  --allowed-repository-owner SecureCloudOps
)

assert_rejected unauthorized-repository-target 'repository target is not allowlisted' \
  "${publish_common[@]}" --repository-owner UntrustedOrg

assert_rejected unauthenticated-remote-publishing \
  'GitHub publication requires an authenticated non-guest Backstage identity' \
  "$python_bin" "$publisher" --mode github \
  --source "$rendered" --generation-root "$work_directory/generated" \
  --simulation-root "$work_directory/published" --service-name payments-api \
  --owner group:default/platform --system forgepath --environment development \
  --data-classification confidential --repository-owner SecureCloudOps \
  --gitops-repository SecureCloudOps/forgepath-gitops \
  --backstage-identity user:development/guest \
  --allowed-owner group:default/platform --allowed-system forgepath \
  --allowed-repository-owner SecureCloudOps

publication_json="$("${publish_common[@]}" --repository-owner SecureCloudOps)"
publication_root="$work_directory/published/payments-api"

jq -e '
  .mode == "local" and
  .remote == false and
  .requestedBy == "user:default/local-developer" and
  .developerExperience.manualSteps == 1 and
  .developerExperience.securityControlsInherited == 9 and
  .developerExperience.kubernetesManifestsDevelopersMustUnderstand == 0 and
  .developerExperience.requestToRepositorySeconds >= 0 and
  .developerExperience.requestToFirstPullRequestSeconds >=
    .developerExperience.requestToRepositorySeconds and
  .developerExperience.requestToPublishedSeconds >= 0 and
  .developerExperience.requestToHealthySeconds == null and
  (.servicePullRequest.requiredChecks | contains([
    "Service pipeline / validate",
    "Service pipeline / trusted-artifact"
  ]))
' <<<"$publication_json" >/dev/null

service_repo="$publication_root/service-repository"
gitops_repo="$publication_root/gitops-repository"
[[ "$(git -C "$service_repo" branch --show-current)" == 'forgepath/enable-delivery' ]] ||
  fail 'service onboarding branch was not created'
[[ "$(git -C "$gitops_repo" branch --show-current)" == \
  'forgepath/onboard-payments-api-development' ]] ||
  fail 'GitOps onboarding branch was not created'

for required in \
  .github/workflows/service.yml \
  .forgepath/onboarding.yaml \
  catalog-info.yaml \
  chart/templates/rollout.yaml \
  chart/templates/servicemonitor.yaml \
  chart/templates/prometheusrule.yaml \
  chart/templates/serviceaccount.yaml; do
  test -s "$service_repo/$required" || fail "generated paved-path file is missing: $required"
done

yq -e '
  .spec.privileged == false and
  (.spec.kubernetesApiPermissions | length) == 0 and
  .spec.delivery.promotion == "git-digest-pull-request" and
  (.spec.controls | length) == 9
' "$service_repo/.forgepath/onboarding.yaml" >/dev/null
yq -o=json '.' "$gitops_repo/applications/payments-api-development.yaml" | jq -e '
  .spec.sources[0].helm.valueFiles[0] ==
    "$values/environments/development/payments-api/values.yaml" and
  .spec.sources[1].ref == "values" and
  .spec.syncPolicy.automated.prune == true and
  .spec.syncPolicy.automated.selfHeal == true and
  .spec.syncPolicy.syncOptions == ["ApplyOutOfSyncOnly=true"] and
  .spec.destination.namespace == "payments-api-development"
' >/dev/null
if rg -n 'CreateNamespace=true|managedNamespaceMetadata' \
  "$gitops_repo/applications/payments-api-development.yaml" >/dev/null; then
  fail 'generated Application attempted to own namespace lifecycle'
fi
yq -o=json '.' \
  "$gitops_repo/projects/forgepath-payments-api-development.yaml" | jq -e '
    (.spec.destinations | length) == 1 and
    .spec.destinations[0].namespace == "payments-api-development" and
    .spec.destinations[0].server == "https://kubernetes.default.svc" and
    (.spec.clusterResourceBlacklist | any(.group == "*" and .kind == "*")) and
    (.spec.namespaceResourceWhitelist |
      all(.group != "rbac.authorization.k8s.io" and
          .kind != "Secret" and .kind != "ResourceQuota" and
          .kind != "LimitRange" and .kind != "NetworkPolicy"))
  ' >/dev/null
if rg -n 'clusterResourceWhitelist|kind:[[:space:]]*Namespace' \
  "$gitops_repo/projects/forgepath-payments-api-development.yaml" >/dev/null; then
  fail 'generated application AppProject can create cluster-scoped resources'
fi

platform_namespace="$gitops_repo/platform/namespaces/payments-api-development.yaml"
yq -o=json -I=0 'select(. != null)' "$platform_namespace" | jq -se '
  length == 6 and
  any(.[]; .kind == "Namespace" and
    .metadata.name == "payments-api-development" and
    .metadata.labels["forgepath.dev/managed-by"] == "platform" and
    .metadata.labels["pod-security.kubernetes.io/enforce"] == "restricted") and
  all(.[] | select(.kind != "Namespace");
    .metadata.namespace == "payments-api-development" and
    .metadata.labels["forgepath.dev/managed-by"] == "platform")
' >/dev/null

rendered_chart="$work_directory/generated-application-manifests.yaml"
helm template payments-api "$service_repo/chart" --namespace payments-api-development \
  >"$rendered_chart"
if yq -e 'select(.kind == "Namespace" or .kind == "ResourceQuota" or
    .kind == "LimitRange" or .kind == "NetworkPolicy")' "$rendered_chart" \
  >/dev/null 2>&1; then
  fail 'application chart rendered a platform-owned namespace boundary resource'
fi

if find "$service_repo/chart" -type f \( -name '*role*.yaml' -o -name '*binding*.yaml' \) | grep -q .; then
  fail 'generated application chart contains Kubernetes RBAC grants'
fi

printf 'PASS developer request -> validation -> repository/PR -> trusted pipeline -> GitOps PR contract\n'

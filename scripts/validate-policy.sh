#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"

python_bin="${PYTHON_BIN:-python3.12}"
for tool in "$python_bin" conftest helm jq; do
  if ! command -v "$tool" >/dev/null; then
    printf 'required policy tool not found: %s\n' "$tool" >&2
    exit 1
  fi
done

work_directory="$(mktemp -d)"
cleanup() {
  rm -rf "$work_directory"
}
trap cleanup EXIT

rendered="$work_directory/rendered"
helm_output="$work_directory/helm-output"

"$python_bin" templates/secure-fastapi-service/render.py \
  --output "$rendered" --service-name example-fastapi
helm lint "$rendered/chart"
helm template validation "$rendered/chart" --output-dir "$helm_output" >/dev/null

if ! find "$helm_output" -type f -name '*.yaml' -print -quit | grep -q .; then
  printf 'Helm rendered no Kubernetes manifests for policy validation\n' >&2
  exit 1
fi

conftest test --combine --policy policies "$helm_output"

assert_policy_rejects() {
  local fixture="$1"
  local expected_message="$2"
  local report
  local status

  report="$work_directory/$(basename "$fixture").json"

  set +e
  conftest test --combine --policy policies --output json "$fixture" \
    >"$report" 2>"$report.stderr"
  status=$?
  set -e

  if [[ "$status" -eq 0 ]]; then
    printf 'policy fixture unexpectedly passed: %s\n' "$fixture" >&2
    exit 1
  fi
  if ! jq -e --arg expected "$expected_message" '
    type == "array" and
    length > 0 and
    all(.[]; ((.exceptions // []) | length) == 0) and
    any(.[]?.failures[]?; .msg | contains($expected))
  ' "$report" >/dev/null; then
    printf 'policy fixture did not produce expected denial: %s\n' \
      "$expected_message" >&2
    if [[ -s "$report.stderr" ]]; then
      sed -n '1,120p' "$report.stderr" >&2
    fi
    exit 1
  fi
}

while IFS='|' read -r fixture expected_message; do
  assert_policy_rejects "tests/policy/fixtures/$fixture" "$expected_message"
done <<'POLICY_FIXTURES'
run-as-non-root.yaml|Deployment/non-root: container application must run as non-root
privilege-escalation.yaml|Deployment/privilege-escalation: container application must set allowPrivilegeEscalation=false
capabilities.yaml|Deployment/capabilities: container application must drop all Linux capabilities
resources.yaml|Deployment/resources: container application must define CPU and memory requests and limits
mutable-image.yaml|Deployment/mutable-image: container application uses mutable image
privileged.yaml|Deployment/privileged: container application must not run privileged
workload-token.yaml|Deployment/workload-token: pod spec must set automountServiceAccountToken=false
serviceaccount-token.yaml|ServiceAccount/serviceaccount-token: must set automountServiceAccountToken=false
host-network.yaml|Deployment/host-network: hostNetwork is forbidden
host-pid.yaml|Deployment/host-pid: hostPID is forbidden
missing-default-deny.yaml|Rendered manifests with workloads must include a namespace-wide default-deny NetworkPolicy
missing-metadata.yaml|Deployment/missing-metadata: workload metadata must set owner, system, environment, and data-classification labels
invalid-metadata.yaml|Pod/invalid-metadata: workload environment, data-classification, or support-tier label is invalid
unapproved-registry.yaml|Pod/unapproved-registry: container application image "docker.io/example/application@sha256:
tagged-approved-image.yaml|Pod/tagged-approved-image: container application image must use a sha256 digest only
weak-namespace-boundary.yaml|Rendered manifests with workloads must include a namespace-wide default-deny NetworkPolicy
weak-namespace-boundary.yaml|Rendered manifests with workloads must include a ResourceQuota
weak-namespace-boundary.yaml|Rendered manifests with workloads must include a Container LimitRange
weak-namespace-boundary.yaml|Rendered manifests with monitored workloads must restrict Prometheus ingress
weak-namespace-boundary.yaml|Rendered manifests with workloads must allow egress only to kube-system DNS pods
POLICY_FIXTURES

printf 'ForgePath Kubernetes policy validation passed.\n'

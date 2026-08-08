#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"

kyverno_version='1.18.2'
policy_directory='policies/kyverno'

fail() {
  printf '[forgepath-kyverno-static] ERROR: %s\n' "$*" >&2
  exit 1
}

for tool in helm kyverno yq; do
  command -v "$tool" >/dev/null || fail "required static validation tool not found: $tool"
done

[[ "$(kyverno version 2>&1)" == *"Version: $kyverno_version"* ]] ||
  fail "Kyverno CLI $kyverno_version is required"

for policy in "$policy_directory"/*.yaml; do
  yq -e '
    .apiVersion == "kyverno.io/v1" and
    .kind == "ClusterPolicy" and
    .spec.admission == true and
    .spec.background == true and
    .spec.failurePolicy == "Fail" and
    .spec.validationFailureAction == "Enforce" and
    ([.spec.rules[] | (has("validate") and
      (has("mutate") | not) and
      (has("generate") | not) and
      (has("verifyImages") | not))] | all)
  ' "$policy" >/dev/null || fail "policy is not validation-only and fail-closed: $policy"
done

work_directory="$(mktemp -d)"
cleanup() {
  rm -rf "$work_directory"
}
trap cleanup EXIT

rendered="$work_directory/secure-fastapi-service.yaml"
helm lint services/secure-fastapi-service/chart \
  --values gitops/environments/local/secure-fastapi-service/values.yaml >/dev/null
helm template secure-fastapi-service services/secure-fastapi-service/chart \
  --namespace forgepath-kyverno-test \
  --values gitops/environments/local/secure-fastapi-service/values.yaml \
  >"$rendered"

positive_report="$work_directory/compliant.txt"
kyverno apply "$policy_directory" --resource "$rendered" >"$positive_report" 2>&1 || {
  sed -n '1,180p' "$positive_report" >&2
  fail 'secure-fastapi-service rendered manifests were rejected'
}
grep -Eq 'pass:[[:space:]]*[1-9][0-9]*' "$positive_report" ||
  fail 'no Kyverno rule passed against the secure rendered manifests'

assert_rejected() {
  local fixture="$1"
  local expected="$2"
  local report
  local status

  report="$work_directory/$(basename "$fixture").txt"

  set +e
  kyverno apply "$policy_directory" --resource "$fixture" >"$report" 2>&1
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "insecure fixture unexpectedly passed: $fixture"
  grep -Fq "$expected" "$report" || {
    sed -n '1,180p' "$report" >&2
    fail "fixture did not produce expected denial '$expected': $fixture"
  }
}

while IFS='|' read -r fixture expected; do
  assert_rejected "tests/policy/fixtures/$fixture" "$expected"
done <<'KYVERNO_FIXTURES'
run-as-non-root.yaml|Containers must run as non-root.
privilege-escalation.yaml|Containers must set allowPrivilegeEscalation=false.
capabilities.yaml|Containers must drop all Linux capabilities
resources.yaml|Containers must define CPU and memory requests and limits.
mutable-image.yaml|Mutable image tags latest, stable, main, and master are forbidden.
privileged.yaml|Privileged containers are forbidden.
workload-token.yaml|Pod specs must set automountServiceAccountToken=false.
serviceaccount-token.yaml|Managed ServiceAccounts must set automountServiceAccountToken=false.
host-network.yaml|hostNetwork is forbidden.
host-pid.yaml|hostPID is forbidden.
KYVERNO_FIXTURES

while IFS='|' read -r fixture expected; do
  assert_rejected "tests/kyverno/runtime/$fixture" "$expected"
done <<'RUNTIME_FIXTURES'
privileged-pod.yaml|Privileged containers are forbidden.
root-pod.yaml|Containers must run as non-root.
latest-pod.yaml|Mutable image tags latest, stable, main, and master are forbidden.
missing-resources-pod.yaml|Containers must define CPU and memory requests and limits.
host-network-pod.yaml|hostNetwork is forbidden.
host-pid-pod.yaml|hostPID is forbidden.
RUNTIME_FIXTURES

printf '[forgepath-kyverno-static] PASS secure paved-path rendered manifests admitted\n'
printf '[forgepath-kyverno-static] PASS 16 synthetic insecure fixtures rejected\n'
printf '[forgepath-kyverno-static] VERSION Kyverno CLI %s\n' "$kyverno_version"

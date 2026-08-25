#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"

boundary_policy='policies/exceptions/exception-boundary.yaml'
admin_rbac='policies/exceptions/exception-admin-rbac.yaml'
valid_exception='tests/exceptions/valid-narrow-exception.yaml'
workload_policy='policies/kyverno/workload-security.yaml'

fail() {
  printf '[forgepath-workload-exceptions-static] ERROR: %s\n' "$*" >&2
  exit 1
}

for tool in jq kyverno yq; do
  command -v "$tool" >/dev/null || fail "required static validation tool not found: $tool"
done

temporary_root="${TMPDIR:-/tmp}"
work_directory="$(mktemp -d "${temporary_root%/}/forgepath-workload-exceptions-static.XXXXXX")"
trap 'rm -rf "$work_directory"' EXIT

yq -e '
  .apiVersion == "kyverno.io/v1" and
  .kind == "ClusterPolicy" and
  .metadata.name == "forgepath-policy-exception-boundary" and
  .spec.admission == true and
  .spec.background == false and
  .spec.failurePolicy == "Fail" and
  .spec.validationFailureAction == "Enforce" and
  (.spec.rules | length) == 4 and
  ([.spec.rules[] | select(
    ((.match.any[0].resources.kinds | length) == 1) and
    (.match.any[0].resources.kinds[0] == "PolicyException") and
    ((.match.any[0].resources.operations | length) == 2) and
    (([.match.any[0].resources.operations[] |
      select(. == "CREATE" or . == "UPDATE")] | length) == 2))] |
    length) == 4 and
  ([.spec.rules[] | select(has("validate"))] | length) == 4 and
  ([.spec.rules[] | select(has("mutate") or has("generate") or
    has("verifyImages"))] | length) == 0
' "$boundary_policy" >/dev/null ||
  fail 'exception boundary must be fail-closed, admission-only, and validation-only'

yq -o=json -I=0 'select(. != null)' "$admin_rbac" | jq -s -e '
  ([.[] | select(.kind == "Namespace" and
    .metadata.name == "forgepath-policy-exceptions")] | length) == 1 and
  ([.[] | select(.kind == "ServiceAccount" and
    .metadata.name == "forgepath-policy-exception-admin" and
    .metadata.namespace == "forgepath-policy-exceptions" and
    .automountServiceAccountToken == false)] | length) == 1 and
  ([.[] | select(.kind == "Role" and
    .metadata.name == "forgepath-policy-exception-admin" and
    .metadata.namespace == "forgepath-policy-exceptions" and
    (.rules | length) == 1 and
    .rules[0].apiGroups == ["kyverno.io"] and
    .rules[0].resources == ["policyexceptions"] and
    ((.rules[0].verbs | sort) ==
      (["create", "delete", "get", "list", "patch", "update", "watch"] | sort)) and
    ([.rules[0].apiGroups[], .rules[0].resources[], .rules[0].verbs[]] |
      all(. != "*")))] | length) == 1 and
  ([.[] | select(.kind == "RoleBinding" and
    .metadata.namespace == "forgepath-policy-exceptions" and
    .roleRef.kind == "Role" and
    .roleRef.name == "forgepath-policy-exception-admin" and
    .subjects == [{"kind":"ServiceAccount", "name":"forgepath-policy-exception-admin",
      "namespace":"forgepath-policy-exceptions"}]) ] | length) == 1
' >/dev/null || fail 'exception administration RBAC is not isolated and least-privileged'

yq -o=json gitops/projects/forgepath-local.yaml | jq -e '
  (.spec.destinations | all(.namespace != "forgepath-policy-exceptions")) and
  (.spec.namespaceResourceWhitelist | all(
    .group != "kyverno.io" and .kind != "PolicyException"))
' >/dev/null || fail 'application GitOps project must not deliver PolicyExceptions'

valid_report="$work_directory/valid-boundary.txt"
kyverno apply "$boundary_policy" --resource "$valid_exception" \
  --detailed-results >"$valid_report" 2>&1 || {
    sed -n '1,180p' "$valid_report" >&2
    fail 'valid narrow exception was rejected by its governance boundary'
  }
grep -Eq 'pass:[[:space:]]*4' "$valid_report" ||
  fail 'valid narrow exception did not pass all four exception boundary rules'

assert_boundary_rejected() {
  local name="$1" mutation="$2" expected="$3"
  local fixture="$work_directory/$name.yaml"
  local report="$work_directory/$name.txt"
  local status

  yq "$mutation" "$valid_exception" >"$fixture"
  set +e
  kyverno apply "$boundary_policy" --resource "$fixture" >"$report" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]] || fail "invalid exception unexpectedly passed: $name"
  grep -Fq "$expected" "$report" || {
    sed -n '1,180p' "$report" >&2
    fail "invalid exception did not produce expected denial: $name"
  }
}

assert_boundary_rejected missing-owner \
  'del(.metadata.annotations."forgepath.dev/exception-owner")' \
  'PolicyExceptions require owner, justification, expiry, and complete approval metadata.'
assert_boundary_rejected missing-justification \
  'del(.metadata.annotations."forgepath.dev/exception-justification")' \
  'PolicyExceptions require owner, justification, expiry, and complete approval metadata.'
assert_boundary_rejected missing-approval \
  'del(.metadata.annotations."forgepath.dev/exception-approved-by")' \
  'PolicyExceptions require owner, justification, expiry, and complete approval metadata.'
assert_boundary_rejected missing-expiry \
  'del(.metadata.annotations."forgepath.dev/exception-expires-at")' \
  'PolicyExceptions must carry a valid future RFC3339 expiry timestamp.'
assert_boundary_rejected already-expired \
  '.metadata.annotations."forgepath.dev/exception-expires-at" = "2000-01-01T00:00:00Z" |
    .spec.conditions.all[0].key = "{{ time_before(time_now_utc(), '\''2000-01-01T00:00:00Z'\'') }}"' \
  'PolicyExceptions must carry a valid future RFC3339 expiry timestamp.'
assert_boundary_rejected missing-expiry-condition \
  'del(.spec.conditions)' \
  'PolicyExceptions must carry a valid future RFC3339 expiry timestamp.'
assert_boundary_rejected mismatched-expiry-condition \
  '.spec.conditions.all[0].key = "{{ time_before(time_now_utc(), '\''2098-12-31T23:59:59Z'\'') }}"' \
  'PolicyExceptions must carry a valid future RFC3339 expiry timestamp.'
assert_boundary_rejected wildcard-policy \
  '.spec.exceptions[0].policyName = "*"' \
  'A PolicyException must name exactly one policy and exactly one rule'
assert_boundary_rejected multiple-controls \
  '.spec.exceptions[0].ruleNames += ["forbid-host-pid"]' \
  'A PolicyException must name exactly one policy and exactly one rule'
assert_boundary_rejected multiple-policies \
  '.spec.exceptions += [{"policyName":"forgepath-platform-guardrails","ruleNames":["require-workload-owner"]}]' \
  'A PolicyException must name exactly one policy and exactly one rule'
assert_boundary_rejected wildcard-workload \
  '.spec.match.any[0].resources.names[0] = "exempted-*" |
    .metadata.annotations."forgepath.dev/exception-workload" = "exempted-*"' \
  'A PolicyException must match one exact Pod name in one exact namespace'
assert_boundary_rejected missing-namespace \
  'del(.spec.match.any[0].resources.namespaces)' \
  'A PolicyException must match one exact Pod name in one exact namespace'
assert_boundary_rejected selector-scope \
  '.spec.match.any[0].resources.selector.matchLabels.app = "exempted"' \
  'A PolicyException must match one exact Pod name in one exact namespace'

TARGET_NAME='exempted-pod' TARGET_NAMESPACE='forgepath-exception-test' yq '
  .metadata.name = strenv(TARGET_NAME) |
  .metadata.namespace = strenv(TARGET_NAMESPACE)
' tests/kyverno/runtime/host-network-pod.yaml >"$work_directory/exempted-pod.yaml"

kyverno apply "$workload_policy" --resource "$work_directory/exempted-pod.yaml" \
  --exception "$valid_exception" >"$work_directory/exact-allow.txt" 2>&1 || {
    sed -n '1,180p' "$work_directory/exact-allow.txt" >&2
    fail 'valid exception did not allow its exact workload and control'
  }
grep -Eq 'skip:[[:space:]]*1' "$work_directory/exact-allow.txt" ||
  fail 'exact exception did not skip exactly one workload-security rule'

TARGET_NAME='neighboring-pod' yq '.metadata.name = strenv(TARGET_NAME)' \
  "$work_directory/exempted-pod.yaml" >"$work_directory/neighboring-pod.yaml"
set +e
kyverno apply "$workload_policy" --resource "$work_directory/neighboring-pod.yaml" \
  --exception "$valid_exception" >"$work_directory/neighboring-denial.txt" 2>&1
neighbor_status=$?
set -e
[[ $neighbor_status -ne 0 ]] || fail 'neighboring workload unexpectedly used the exception'
grep -Fq 'hostNetwork is forbidden.' "$work_directory/neighboring-denial.txt" ||
  fail 'neighboring workload did not retain hostNetwork enforcement'

yq '.spec.hostPID = true' "$work_directory/exempted-pod.yaml" \
  >"$work_directory/unrelated-control-pod.yaml"
set +e
kyverno apply "$workload_policy" --resource "$work_directory/unrelated-control-pod.yaml" \
  --exception "$valid_exception" >"$work_directory/unrelated-control-denial.txt" 2>&1
unrelated_status=$?
set -e
[[ $unrelated_status -ne 0 ]] || fail 'exception unexpectedly disabled an unrelated control'
grep -Fq 'hostPID is forbidden.' "$work_directory/unrelated-control-denial.txt" ||
  fail 'unrelated hostPID policy did not remain enforced'

printf '[forgepath-workload-exceptions-static] PASS narrow exception contract and expiry validation\n'
printf '[forgepath-workload-exceptions-static] PASS wildcard and multi-control exceptions rejected\n'
printf '[forgepath-workload-exceptions-static] PASS exact workload allowed; neighbor and unrelated control denied\n'
printf '[forgepath-workload-exceptions-static] PASS administration identity isolated from application delivery\n'

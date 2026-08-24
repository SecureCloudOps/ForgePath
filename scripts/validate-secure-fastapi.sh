#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"

python_bin="${PYTHON_BIN:-python3.12}"

for tool in "$python_bin" docker gitleaks helm jq kubeconform promtool rg semgrep trivy yq; do
  if ! command -v "$tool" >/dev/null; then
    printf 'required tool not found: %s\n' "$tool" >&2
    exit 1
  fi
done

work_directory="$(mktemp -d)"
cleanup() {
  docker rm -f forgepath-secure-fastapi-validation >/dev/null 2>&1 || true
  rm -rf "$work_directory"
}
trap cleanup EXIT

rendered="$work_directory/rendered"
second_render="$work_directory/rendered-second"
venv="$work_directory/venv"
image="forgepath/secure-fastapi-validation:0.1.0"
trivy_cache="$work_directory/trivy-cache"
schema_directory="$repository_root/gitops/schemas/kubernetes/v1.32.0-standalone-strict"

# Static misconfiguration scans use the checks embedded in the repository-pinned
# Trivy binary. Vulnerability DB acquisition belongs only to the online gate.

expect_exit_one() {
  local description="$1"
  shift
  local status

  set +e
  "$@" >/dev/null 2>&1
  status=$?
  set -e
  if [[ "$status" -ne 1 ]]; then
    printf '%s: expected exit code 1, got %s\n' "$description" "$status" >&2
    exit 1
  fi
}

assert_trivy_rejects() {
  local description="$1"
  local target="$2"
  local report="$3"

  trivy config --cache-dir "$trivy_cache" --exit-code 0 --quiet \
    --skip-check-update --skip-version-check \
    --format json --output "$report" --severity HIGH,CRITICAL "$target"
  if ! jq -e \
    '[.Results[]?.Misconfigurations[]? | select(.Severity == "HIGH" or .Severity == "CRITICAL")] | length > 0' \
    "$report" >/dev/null; then
    printf '%s: Trivy did not report a high or critical misconfiguration\n' \
      "$description" >&2
    exit 1
  fi
  expect_exit_one "$description" trivy config --cache-dir "$trivy_cache" \
    --exit-code 1 --quiet --severity HIGH,CRITICAL \
    --skip-check-update --skip-version-check "$target"
}

"$python_bin" templates/secure-fastapi-service/render.py \
  --output "$rendered" --service-name example-fastapi
"$python_bin" templates/secure-fastapi-service/render.py \
  --output "$second_render" --service-name example-fastapi
diff -ru "$rendered" "$second_render"

if rg -n '__FORGEPATH_[A-Z0-9_]+__' "$rendered"; then
  printf 'unresolved template variable found\n' >&2
  exit 1
fi

"$python_bin" -m venv "$venv"
"$venv/bin/pip" install --disable-pip-version-check \
  -r "$rendered/requirements.txt" -r "$rendered/requirements-dev.txt"
(
  cd "$rendered"
  "$venv/bin/ruff" format --check .
  "$venv/bin/ruff" check .
  "$venv/bin/mypy"
  "$venv/bin/python" -m pytest
  "$venv/bin/pip" check
)

semgrep scan --config .semgrep.yml --disable-version-check --error --no-git-ignore \
  --metrics=off "$rendered/app" "$rendered/tests"

gitleaks git --config .gitleaks.toml --exit-code 1 --no-banner --redact .
gitleaks dir --config .gitleaks.toml --exit-code 1 --no-banner --redact .

mkdir -p "$work_directory/negative-secret"
cp tests/security/fixtures/fake-secret.txt \
  "$work_directory/negative-secret/committed-fake-secret.txt"
expect_exit_one "synthetic committed secret fixture" gitleaks dir \
  --config .gitleaks.toml --exit-code 1 --no-banner --redact \
  "$work_directory/negative-secret"

docker build --tag "$image" "$rendered"
container_user="$(docker image inspect "$image" --format '{{.Config.User}}')"
if [[ "$container_user" != "10001:10001" ]]; then
  printf 'container user must be 10001:10001, got: %s\n' "$container_user" >&2
  exit 1
fi
docker run --detach --name forgepath-secure-fastapi-validation \
  --read-only --tmpfs /tmp:rw,noexec,nosuid,size=16m "$image" >/dev/null
ready=false
for _ in {1..30}; do
  if docker exec forgepath-secure-fastapi-validation \
    python -c 'import urllib.request; urllib.request.urlopen("http://127.0.0.1:8080/health/ready", timeout=1)' \
    >/dev/null 2>&1; then
    ready=true
    break
  fi
  if [[ "$(docker inspect --format '{{.State.Running}}' forgepath-secure-fastapi-validation)" != "true" ]]; then
    break
  fi
  sleep 1
done
if [[ "$ready" != "true" ]]; then
  docker logs forgepath-secure-fastapi-validation >&2
  printf 'container did not become ready\n' >&2
  exit 1
fi
docker exec forgepath-secure-fastapi-validation \
  python -c 'import os; assert os.getuid() == 10001 and os.getgid() == 10001'
docker exec forgepath-secure-fastapi-validation \
  python -c 'import urllib.request; assert urllib.request.urlopen("http://127.0.0.1:8080/metrics", timeout=2).status == 200'
docker stop forgepath-secure-fastapi-validation >/dev/null

helm lint "$rendered/chart"
if helm lint "$rendered/chart" --set image.digest=latest >/dev/null 2>&1; then
  printf 'Helm schema must reject a mutable image reference\n' >&2
  exit 1
fi
helm template validation "$rendered/chart" >"$work_directory/manifests.yaml"

yq -o=yaml 'select(.kind == "PrometheusRule") | {"groups": .spec.groups}' \
  "$work_directory/manifests.yaml" >"$rendered/tests/prometheus-rules.yaml"
promtool check rules "$rendered/tests/prometheus-rules.yaml"
(
  cd "$rendered/tests"
  promtool test rules prometheus-rules.test.yaml
)

kubeconform -exit-on-error -strict -skip AnalysisTemplate,PrometheusRule,Rollout,ServiceMonitor -summary \
  -schema-location "file://$schema_directory/{{.ResourceKind}}{{.KindSuffix}}.json" \
  "$work_directory/manifests.yaml"
expect_exit_one "schema-invalid Kubernetes fixture" kubeconform \
  -exit-on-error -strict \
  -schema-location "file://$schema_directory/{{.ResourceKind}}{{.KindSuffix}}.json" \
  tests/security/fixtures/invalid-manifest.yaml

trivy config --cache-dir "$trivy_cache" --exit-code 1 \
  --severity HIGH,CRITICAL --quiet --skip-check-update --skip-version-check \
  "$rendered/Dockerfile"
trivy config --cache-dir "$trivy_cache" --exit-code 1 \
  --severity HIGH,CRITICAL --quiet --skip-check-update --skip-version-check \
  "$work_directory/manifests.yaml"
assert_trivy_rejects "insecure container fixture" \
  tests/security/fixtures/insecure/Dockerfile \
  "$work_directory/insecure-container.json"
assert_trivy_rejects "insecure Kubernetes fixture" \
  tests/security/fixtures/insecure/deployment.yaml \
  "$work_directory/insecure-kubernetes.json"
assert_trivy_rejects "policy-violating Kubernetes fixture" \
  tests/security/fixtures/policy-violation.yaml \
  "$work_directory/policy-violation.json"

# Validate every rendered document has the Kubernetes envelope, then assert the
# expected resource set. This deliberately stays offline rather than consulting
# whichever cluster happens to be in the caller's kubeconfig.
yq -e 'select(. != null) | .apiVersion and .kind and .metadata.name' \
  "$work_directory/manifests.yaml" >/dev/null
rendered_kinds="$(
  yq -o=json -I=0 'select(. != null)' "$work_directory/manifests.yaml" \
    | jq -r '.kind' | sort
)"
expected_kinds="$(printf '%s\n' AnalysisTemplate ConfigMap PrometheusRule Rollout Service Service ServiceAccount ServiceMonitor | sort)"
if [[ "$rendered_kinds" != "$expected_kinds" ]]; then
  printf 'unexpected rendered Kubernetes resource set:\n%s\n' "$rendered_kinds" >&2
  exit 1
fi

rollout_json="$(yq -o=json 'select(.kind == "Rollout")' "$work_directory/manifests.yaml")"
analysis_template_json="$(yq -o=json 'select(.kind == "AnalysisTemplate")' "$work_directory/manifests.yaml")"
service_monitor_json="$(yq -o=json 'select(.kind == "ServiceMonitor")' "$work_directory/manifests.yaml")"
prometheus_rule_json="$(yq -o=json 'select(.kind == "PrometheusRule")' "$work_directory/manifests.yaml")"
dashboard_json="$(yq -r 'select(.kind == "ConfigMap") | .data."slo-dashboard.json"' "$work_directory/manifests.yaml")"

jq -e '
  .metadata.labels["forgepath.dev/owner"] == "platform" and
  .metadata.labels["forgepath.dev/system"] == "forgepath" and
  .metadata.labels["forgepath.dev/environment"] == "local" and
  .metadata.labels["forgepath.dev/data-classification"] == "internal" and
  .metadata.labels["forgepath.dev/support-tier"] == "2" and
  .spec.template.metadata.labels["forgepath.dev/owner"] == "platform" and
  .spec.template.metadata.labels["forgepath.dev/system"] == "forgepath" and
  (.spec.template.spec.containers[0].image |
    test("^ghcr.io/securecloudops/example-fastapi@sha256:[a-f0-9]{64}$")) and
  .spec.template.spec.securityContext.runAsUser == 10001 and
  .spec.template.spec.securityContext.seccompProfile.type == "RuntimeDefault" and
  .spec.template.spec.containers[0].securityContext.readOnlyRootFilesystem == true and
  .spec.template.spec.containers[0].livenessProbe.httpGet.path == "/health/live" and
  .spec.template.spec.containers[0].readinessProbe.httpGet.path == "/health/ready"
' <<<"$rollout_json" >/dev/null
jq -e '
  .spec.replicas == 20 and
  .spec.strategy.canary.stableService == "validation-example-fastapi" and
  .spec.strategy.canary.canaryService == "validation-example-fastapi-canary" and
  .spec.strategy.canary.abortScaleDownDelaySeconds == 600 and
  [.spec.strategy.canary.steps[] |
    if has("setWeight") then ["weight", .setWeight]
    else ["analysis", .analysis.templates[0].templateName] end] ==
    [["weight", 5], ["analysis", "validation-example-fastapi-slo"],
     ["weight", 25], ["analysis", "validation-example-fastapi-slo"],
     ["weight", 50], ["analysis", "validation-example-fastapi-slo"],
     ["weight", 100]]
' <<<"$rollout_json" >/dev/null
jq -e '
  .spec.metrics[0].provider.prometheus.query as $query |
  .spec.metrics == [{
    "name": "availability-burn-rate",
    "initialDelay": "6m",
    "count": 1,
    "failureLimit": 0,
    "consecutiveErrorLimit": 0,
    "successCondition": "len(result) == 1 && result[0] <= 14.4",
    "provider": {
      "prometheus": {
        "address": "http://prometheus-operated.monitoring.svc.cluster.local:9090",
        "timeout": 10,
        "query": $query
      }
    }
  }] and
  (.spec.metrics[0].provider.prometheus.query |
    contains("forgepath:slo_availability_burn_rate") and contains("window=\"5m\""))
' <<<"$analysis_template_json" >/dev/null

jq -e '
  (.spec.endpoints | length) == 1 and
  .spec.endpoints[0].path == "/metrics" and
  .spec.endpoints[0].port == "http" and
  .spec.endpoints[0].relabelings[0].targetLabel == "forgepath_service" and
  .spec.targetLabels == ["forgepath_delivery_role"]
' <<<"$service_monitor_json" >/dev/null
jq -e '
  [.spec.groups[].rules[] | select(.record != null) | .record] |
    index("forgepath:sli_availability:ratio_rate5m") != null and
    index("forgepath:sli_latency_under_300ms:ratio_rate5m") != null and
    index("forgepath:slo_error_budget_remaining:ratio") != null and
    index("forgepath:slo_availability_burn_rate") != null
' <<<"$prometheus_rule_json" >/dev/null
jq -e '
  .title == "validation-example-fastapi service SLO" and
  [.panels[].title] == [
    "Traffic", "Errors", "Latency", "CPU saturation", "Memory saturation",
    "Availability error budget remaining", "Availability SLI", "Latency SLI"
  ]
' <<<"$dashboard_json" >/dev/null

if helm template validation "$rendered/chart" --set monitoring.enabled=false \
  >/dev/null 2>&1; then
  printf 'Helm schema must reject disabling monitoring required by rollout analysis\n' >&2
  exit 1
fi

helm template validation "$rendered/chart" \
  --set failureFixture.enabled=true \
  --set monitoring.slo.windowProfile=demo \
  --set progressiveDelivery.analysis.burnRateWindow=1m \
  --set progressiveDelivery.analysis.initialDelay=90s \
  >"$work_directory/demo.yaml"
demo_rollout_json="$(
  yq -o=json 'select(.kind == "Rollout")' "$work_directory/demo.yaml"
)"
demo_prometheus_rule_json="$(
  yq -o=json 'select(.kind == "PrometheusRule")' "$work_directory/demo.yaml"
)"
demo_analysis_template_json="$(
  yq -o=json 'select(.kind == "AnalysisTemplate")' "$work_directory/demo.yaml"
)"
jq -e '
  .spec.template.spec.containers[0].env == [
    {"name": "FORGEPATH_FAILURE_FIXTURE_ENABLED", "value": "true"}
  ]
' <<<"$demo_rollout_json" >/dev/null
jq -e '
  ([.spec.groups[].rules[] | select(.record == "forgepath:slo_availability_burn_rate") | .labels.window] | index("1m") != null) and
  ([.spec.groups[].rules[] | select(.record == "forgepath:slo_availability_burn_rate") | .labels.window] | index("10m") != null) and
  ([.spec.groups[].rules[] | select(.record == "forgepath:slo_error_budget_remaining:ratio") | .labels.window] == ["1h"])
' <<<"$demo_prometheus_rule_json" >/dev/null
jq -e '
  .spec.metrics[0].initialDelay == "90s" and
  (.spec.metrics[0].provider.prometheus.query | contains("window=\"1m\""))
' <<<"$demo_analysis_template_json" >/dev/null

jq -e '
  .metadata.name == "example-fastapi" and
  .spec.owner == "group:default/platform" and
  .spec.type == "service" and
  .spec.system == "forgepath" and
  .metadata.annotations["backstage.io/techdocs-ref"] == "dir:." and
  .metadata.annotations["backstage.io/kubernetes-label-selector"] ==
    "app.kubernetes.io/name=example-fastapi" and
  .metadata.annotations["backstage.io/kubernetes-namespace"] ==
    "example-fastapi-local"
' \
  < <(yq -o=json "$rendered/catalog-info.yaml") >/dev/null
yq -e '.site_name and .docs_dir == "docs" and .plugins[] == "techdocs-core"' \
  "$rendered/mkdocs.yml" >/dev/null
jq -e '.type == "object" and .properties.image.properties.digest.pattern == "^sha256:[a-f0-9]{64}$"' \
  "$rendered/chart/values.schema.json" >/dev/null

for document in README.md docs/index.md docs/PROGRESSIVE_DELIVERY.md docs/RUNBOOK.md \
  docs/SECURITY.md docs/SLO.md catalog-info.yaml mkdocs.yml; do
  test -s "$rendered/$document"
done

printf 'secure-fastapi-service static quality and security validation passed.\n'

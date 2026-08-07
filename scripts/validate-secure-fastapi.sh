#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"

python_bin="${PYTHON_BIN:-python3.12}"

for tool in "$python_bin" docker gitleaks helm jq kubeconform semgrep trivy yq; do
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
schema_cache="$work_directory/kubeconform-cache"
mkdir -p "$schema_cache"

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

  trivy config --cache-dir "$trivy_cache" --exit-code 0 \
    --format json --output "$report" --severity HIGH,CRITICAL "$target"
  if ! jq -e \
    '[.Results[]?.Misconfigurations[]? | select(.Severity == "HIGH" or .Severity == "CRITICAL")] | length > 0' \
    "$report" >/dev/null; then
    printf '%s: Trivy did not report a high or critical misconfiguration\n' \
      "$description" >&2
    exit 1
  fi
  expect_exit_one "$description" trivy config --cache-dir "$trivy_cache" \
    --exit-code 1 --quiet --severity HIGH,CRITICAL "$target"
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

trivy fs --cache-dir "$trivy_cache" --exit-code 1 --scanners vuln \
  --severity HIGH,CRITICAL --skip-version-check "$rendered"
mkdir -p "$work_directory/development-dependencies"
cp "$rendered/requirements-dev.txt" \
  "$work_directory/development-dependencies/requirements.txt"
trivy fs --cache-dir "$trivy_cache" --exit-code 1 --scanners vuln \
  --severity HIGH,CRITICAL --skip-version-check \
  "$work_directory/development-dependencies"

docker build --tag "$image" "$rendered"
trivy image --cache-dir "$trivy_cache" --exit-code 1 --scanners vuln \
  --severity HIGH,CRITICAL --skip-version-check "$image"
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
if helm lint "$rendered/chart" --set image.tag=latest >/dev/null 2>&1; then
  printf 'Helm schema must reject a mutable latest image tag\n' >&2
  exit 1
fi
helm template validation "$rendered/chart" >"$work_directory/manifests.yaml"

kubeconform -cache "$schema_cache" -exit-on-error -kubernetes-version 1.32.0 \
  -strict -summary "$work_directory/manifests.yaml"
expect_exit_one "schema-invalid Kubernetes fixture" kubeconform \
  -cache "$schema_cache" -exit-on-error -kubernetes-version 1.32.0 \
  -strict tests/security/fixtures/invalid-manifest.yaml

trivy config --cache-dir "$trivy_cache" --exit-code 1 \
  --severity HIGH,CRITICAL "$rendered/Dockerfile"
trivy config --cache-dir "$trivy_cache" --exit-code 1 \
  --severity HIGH,CRITICAL "$work_directory/manifests.yaml"
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
expected_kinds="$(printf '%s\n' Deployment NetworkPolicy Service ServiceAccount | sort)"
if [[ "$rendered_kinds" != "$expected_kinds" ]]; then
  printf 'unexpected rendered Kubernetes resource set:\n%s\n' "$rendered_kinds" >&2
  exit 1
fi

deployment_json="$(yq -o=json 'select(.kind == "Deployment")' "$work_directory/manifests.yaml")"

jq -e '
  .spec.template.spec.securityContext.runAsUser == 10001 and
  .spec.template.spec.securityContext.seccompProfile.type == "RuntimeDefault" and
  .spec.template.spec.containers[0].securityContext.readOnlyRootFilesystem == true and
  .spec.template.spec.containers[0].livenessProbe.httpGet.path == "/health/live" and
  .spec.template.spec.containers[0].readinessProbe.httpGet.path == "/health/ready"
' <<<"$deployment_json" >/dev/null

jq -e '.metadata.name and .spec.owner and .spec.type == "service" and .metadata.annotations["backstage.io/techdocs-ref"] == "dir:."' \
  < <(yq -o=json "$rendered/catalog-info.yaml") >/dev/null
yq -e '.site_name and .docs_dir == "docs" and .plugins[] == "techdocs-core"' \
  "$rendered/mkdocs.yml" >/dev/null
jq -e '.type == "object" and .properties.image.properties.tag.not.pattern' \
  "$rendered/chart/values.schema.json" >/dev/null

for document in README.md docs/RUNBOOK.md docs/SECURITY.md catalog-info.yaml mkdocs.yml; do
  test -s "$rendered/$document"
done

printf 'secure-fastapi-service quality and security validation passed.\n'

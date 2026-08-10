#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
backstage_root="$repository_root/platform/backstage"
python_bin="${PYTHON_BIN:-python3.12}"

for tool in corepack diff jq mkdocs node rg "$python_bin" yq; do
  if ! command -v "$tool" >/dev/null; then
    printf 'required tool not found: %s\n' "$tool" >&2
    exit 1
  fi
done

if [[ "$(mkdocs --version)" != *'mkdocs, version 1.6.1'* ]]; then
  printf 'MkDocs 1.6.1 is required, got: %s\n' "$(mkdocs --version)" >&2
  exit 1
fi
rg -F '"pipx:mkdocs-techdocs-core" = { version = "1.7.0", pipx_args = "--preinstall mkdocs==1.6.1 --include-deps", depends = ["python"] }' \
  "$repository_root/mise.toml" >/dev/null

work_directory="$(mktemp -d)"
cleanup() {
  rm -rf "$work_directory"
}
trap cleanup EXIT

jq -e '
  .backstageVersion == "1.53.0" and
  .createApp.package == "@backstage/create-app" and
  .createApp.version == "0.9.0" and
  .createApp.tarball == "https://registry.npmjs.org/@backstage/create-app/-/create-app-0.9.0.tgz" and
  .createApp.integrity == "sha512-rCiofh5z27nXG1hMMcw0qc01Ks8A7C6RrJvSiC27ZUghjRKj6+b1R3nOT4T5M42SUzwviRZgZ3TOOyIxEHxVQA==" and
  .nodeVersion == "22.22.2" and
  .packageManager == "yarn@4.13.0"
' "$backstage_root/bootstrap.lock.json" >/dev/null
jq -e '.version == "1.53.0"' "$backstage_root/backstage.json" >/dev/null
jq -e '
  .engines.node == "22.22.2" and
  .packageManager == "yarn@4.13.0"
' "$backstage_root/package.json" >/dev/null
jq -e '
  .dependencies."@backstage/plugin-search" == "1.7.6" and
  .dependencies."@backstage/plugin-search-react" == "1.11.6"
' "$backstage_root/packages/app/package.json" >/dev/null
if [[ "$(node --version)" != "v22.22.2" ]]; then
  printf 'Node.js v22.22.2 is required, got: %s\n' "$(node --version)" >&2
  exit 1
fi
if [[ "$(cd "$backstage_root" && corepack yarn --version)" != "4.13.0" ]]; then
  printf 'Yarn 4.13.0 is required by the pinned bootstrap\n' >&2
  exit 1
fi

for package_file in \
  "$backstage_root/package.json" \
  "$backstage_root/packages/app/package.json" \
  "$backstage_root/packages/backend/package.json"; do
  if ! jq -e '
    [
      (.dependencies // {}),
      (.devDependencies // {}),
      (.resolutions // {})
    ]
    | add
    | to_entries
    | all(.value | test("^(workspace:\\*|[0-9]+\\.[0-9]+\\.[0-9]+)$"))
  ' "$package_file" >/dev/null; then
    printf 'dependency versions must be exact or workspace-local: %s\n' \
      "$package_file" >&2
    exit 1
  fi
done

yq -e '
  .apiVersion == "scaffolder.backstage.io/v1beta3" and
  .kind == "Template" and
  (.spec.steps | length) == 1 and
  .spec.steps[0].action == "forgepath:renderSecureFastapi"
' "$repository_root/templates/secure-fastapi-service/template.yaml" >/dev/null
if yq -e '.spec.steps[].action | test("^(publish:|catalog:register)")' \
  "$repository_root/templates/secure-fastapi-service/template.yaml" \
  >/dev/null 2>&1; then
  printf 'Backstage template must not publish or register output\n' >&2
  exit 1
fi

yq -e '
  .permission.enabled == true and
  (.catalog.rules[0].allow | contains(["Resource"])) and
  .catalog.locations[0].target == "../../catalog/entities.yaml" and
  .catalog.locations[1].target ==
    "../../../../services/secure-fastapi-service/catalog-info.yaml" and
  .catalog.locations[2].target ==
    "../../../../templates/secure-fastapi-service/template.yaml" and
  .app.routes.bindings."scaffolder.registerComponent" == false and
  .kubernetes.frontend.podDelete.enabled == false and
  .kubernetes.clusterLocatorMethods[0].type == "localKubectlProxy" and
  .kubernetes.customResources[0].group == "argoproj.io" and
  .kubernetes.customResources[0].apiVersion == "v1alpha1" and
  .kubernetes.customResources[0].plural == "applications"
' "$backstage_root/app-config.yaml" >/dev/null
yq -o=json -I=0 '.' "$backstage_root/catalog/entities.yaml" | jq -s -e '
  any(.[];
    .kind == "Resource" and
    .metadata.name == "secure-fastapi-service-argocd" and
    .metadata.annotations."backstage.io/kubernetes-label-selector" ==
      "app.kubernetes.io/name=secure-fastapi-service" and
    .metadata.annotations."backstage.io/kubernetes-namespace" == "argocd" and
    .spec.type == "argocd-application" and
    .spec.dependencyOf == ["component:default/secure-fastapi-service"])
' >/dev/null
yq -o=json -I=0 '.' \
  "$repository_root/services/secure-fastapi-service/catalog-info.yaml" | jq -e '
    .kind == "Component" and
    .metadata.name == "secure-fastapi-service" and
    .metadata.annotations."backstage.io/techdocs-ref" == "dir:." and
    .metadata.annotations."backstage.io/kubernetes-namespace" ==
      "secure-fastapi-service-local" and
    .spec.dependsOn == ["resource:default/secure-fastapi-service-argocd"]
  ' >/dev/null
yq -e '
  .site_name == "Secure FastAPI service" and
  .plugins[] == "techdocs-core" and
  .nav[0].Overview == "index.md"
' "$repository_root/services/secure-fastapi-service/mkdocs.yml" >/dev/null
for document in docs/index.md docs/runtime.md; do
  test -s "$repository_root/services/secure-fastapi-service/$document"
done
mkdocs build --strict --clean \
  --config-file "$repository_root/services/secure-fastapi-service/mkdocs.yml" \
  --site-dir "$work_directory/techdocs-site"
test -s "$work_directory/techdocs-site/index.html"
rg -F "request.permission.name === 'kubernetes.proxy'" \
  "$backstage_root/packages/backend/src/modules/forgePathPermissions.ts" >/dev/null
rg -F "AuthorizeResult.DENY" \
  "$backstage_root/packages/backend/src/modules/forgePathPermissions.ts" >/dev/null
rg -F "actionId: 'forgepath:renderSecureFastapi'" \
  "$backstage_root/packages/backend/src/modules/forgePathPermissions.ts" >/dev/null
rg -F "templates/secure-fastapi-service/render.py" \
  "$backstage_root/packages/backend/src/actions/renderSecureFastapi.ts" >/dev/null
rg -F 'execFileAsync(' \
  "$backstage_root/packages/backend/src/actions/renderSecureFastapi.ts" >/dev/null

(
  cd "$backstage_root"
  corepack yarn install --immutable
  corepack yarn backstage-cli config:check --config app-config.yaml
  corepack yarn tsc
  corepack yarn lint
  corepack yarn workspace backend test --runInBand --watchAll=false
  # The frontend asset table contains hundreds of lines and can overwhelm
  # non-interactive CI log buffers; build errors still remain on stderr.
  corepack yarn build >/dev/null
)

rendered="$work_directory/secure-fastapi-service"
"$python_bin" "$repository_root/templates/secure-fastapi-service/render.py" \
  --output "$rendered" \
  --service-name secure-fastapi-service \
  --description "Backstage contract validation service." \
  --owner group:default/platform \
  --kubernetes-namespace secure-fastapi-service-local

diff -ru \
  "$repository_root/services/secure-fastapi-service/chart" \
  "$rendered/chart"

if rg -n '__FORGEPATH_[A-Z0-9_]+__' "$rendered"; then
  printf 'unresolved template variable found\n' >&2
  exit 1
fi

yq -e '
  .apiVersion == "backstage.io/v1alpha1" and
  .kind == "Component" and
  .metadata.name == "secure-fastapi-service" and
  .metadata.description == "Backstage contract validation service." and
  .metadata.annotations."backstage.io/techdocs-ref" == "dir:." and
  .metadata.annotations."backstage.io/kubernetes-label-selector" ==
    "app.kubernetes.io/name=secure-fastapi-service" and
  .metadata.annotations."backstage.io/kubernetes-namespace" ==
    "secure-fastapi-service-local" and
  .spec.owner == "group:default/platform" and
  .spec.type == "service" and
  .spec.system == "forgepath"
' "$rendered/catalog-info.yaml" >/dev/null
yq -e '
  .docs_dir == "docs" and
  .plugins[] == "techdocs-core" and
  .nav[0].Overview == "index.md"
' "$rendered/mkdocs.yml" >/dev/null
for document in \
  catalog-info.yaml \
  mkdocs.yml \
  docs/index.md \
  docs/RUNBOOK.md \
  docs/SECURITY.md; do
  test -s "$rendered/$document"
done

printf 'ForgePath Backstage static validation passed.\n'

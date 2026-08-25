#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"

python_bin="${PYTHON_BIN:-python3.12}"
trivy_cache="${FORGEPATH_TRIVY_CACHE_DIR:-$repository_root/.forgepath/cache/trivy}"
trivy_db_repository="${FORGEPATH_TRIVY_DB_REPOSITORY:-mirror.gcr.io/aquasec/trivy-db:2}"
image="forgepath/secure-fastapi-online-validation:0.1.0"

for tool in "$python_bin" docker jq trivy; do
  if ! command -v "$tool" >/dev/null; then
    printf 'required online vulnerability-gate tool not found: %s\n' "$tool" >&2
    exit 1
  fi
done

work_directory="$(mktemp -d)"
cleanup() {
  docker image rm -f "$image" >/dev/null 2>&1 || true
  rm -rf "$work_directory"
}
trap cleanup EXIT

rendered="$work_directory/rendered"
development_dependencies="$work_directory/development-dependencies"
metadata="$trivy_cache/db/metadata.json"

mkdir -p "$trivy_cache"
printf 'online-required: refreshing the cached Trivy vulnerability DB from %s\n' \
  "$trivy_db_repository"
trivy image --cache-dir "$trivy_cache" \
  --db-repository "$trivy_db_repository" \
  --download-db-only --skip-version-check

if [[ ! -s "$metadata" ]]; then
  printf 'Trivy DB metadata is missing after download: %s\n' "$metadata" >&2
  exit 1
fi
jq -e '.Version == 2 and .UpdatedAt and .NextUpdate and .DownloadedAt' \
  "$metadata" >/dev/null
db_metadata_sha256="$({ sha256sum "$metadata" 2>/dev/null || shasum -a 256 "$metadata"; } | awk '{print $1}')"
printf 'Trivy DB snapshot: version=%s updated=%s metadata_sha256=%s\n' \
  "$(jq -r '.Version' "$metadata")" "$(jq -r '.UpdatedAt' "$metadata")" \
  "$db_metadata_sha256"

"$python_bin" templates/secure-fastapi-service/render.py \
  --output "$rendered" --service-name example-fastapi
mkdir -p "$development_dependencies"
cp "$rendered/requirements-dev.txt" "$development_dependencies/requirements.txt"
docker build --tag "$image" "$rendered"

scan_flags=(
  --cache-dir "$trivy_cache"
  --exit-code 1
  --scanners vuln
  --severity "HIGH,CRITICAL"
  --skip-db-update
  --skip-check-update
  --skip-vex-repo-update
  --skip-version-check
  --offline-scan
)
trivy fs "${scan_flags[@]}" "$rendered"
trivy fs "${scan_flags[@]}" "$development_dependencies"
trivy image "${scan_flags[@]}" "$image"

printf 'online Trivy vulnerability gate passed using one cached DB snapshot.\n'

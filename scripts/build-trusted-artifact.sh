#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"

for tool in cosign docker git jq syft tar trivy; do
  if ! command -v "$tool" >/dev/null; then
    printf 'required trusted-artifact tool not found: %s\n' "$tool" >&2
    exit 1
  fi
done

artifact_parent="$repository_root/.forgepath"
artifact_directory="$artifact_parent/trusted-artifact"
image_repository="forgepath/secure-fastapi-service"
image_tag="$image_repository:0.1.0-local"
build_input="templates/secure-fastapi-service"

mkdir -p "$artifact_parent"
staging_directory="$(mktemp -d "$artifact_parent/trusted-artifact.XXXXXX")"
work_directory="$(mktemp -d)"
cleanup() {
  rm -rf "$staging_directory" "$work_directory"
}
trap cleanup EXIT

rendered="$work_directory/secure-fastapi-service"
build_metadata="$work_directory/build-metadata.json"
oci_archive="$staging_directory/image.oci.tar"
scan_report="$staging_directory/trivy-report.json"
trivy_db_evidence="$staging_directory/trivy-db-metadata.json"
sbom="$staging_directory/sbom.spdx.json"
digest_payload="$staging_directory/image-digest.txt"
signature="$staging_directory/image-digest.sig"
public_key="$staging_directory/cosign.pub"
metadata="$staging_directory/metadata.json"
trusted_marker="$staging_directory/TRUSTED"
trivy_cache="${FORGEPATH_TRIVY_CACHE_DIR:-$repository_root/.forgepath/cache/trivy}"
trivy_db_repository="${FORGEPATH_TRIVY_DB_REPOSITORY:-mirror.gcr.io/aquasec/trivy-db:2}"
oci_layout="$work_directory/oci-layout"

# Bind provenance to the service renderer that supplies the complete image build
# context. Repository-wide HEAD would make unrelated documentation changes alter
# the image digest and create a circular GitOps digest-promotion workflow.
source_revision="$(git log -1 --format=%H -- "$build_input" 2>/dev/null || true)"
source_dirty=false
if [[ -n "$(git status --porcelain --untracked-files=all -- "$build_input")" ]]; then
  source_dirty=true
fi
build_timestamp=""
source_date_epoch=""
if [[ -n "$source_revision" ]]; then
  build_timestamp="$(git show -s --format=%cI "$source_revision" 2>/dev/null || true)"
  source_date_epoch="$(git show -s --format=%ct "$source_revision" 2>/dev/null || true)"
fi

python_bin="${PYTHON_BIN:-python3.12}"
if ! command -v "$python_bin" >/dev/null; then
  printf 'required trusted-artifact tool not found: %s\n' "$python_bin" >&2
  exit 1
fi
"$python_bin" templates/secure-fastapi-service/render.py \
  --output "$rendered" --service-name secure-fastapi-service

build_arguments=(
  buildx build
  --provenance=false
  --sbom=false
  --tag "$image_tag"
  --output "type=oci,dest=$oci_archive"
  --metadata-file "$build_metadata"
)
if [[ -n "$source_date_epoch" ]]; then
  build_arguments+=(--build-arg "SOURCE_DATE_EPOCH=$source_date_epoch")
fi
if [[ -n "$build_timestamp" ]]; then
  build_arguments+=(--label "org.opencontainers.image.created=$build_timestamp")
fi
if [[ -n "$source_revision" ]]; then
  build_arguments+=(--label "org.opencontainers.image.revision=$source_revision")
fi
build_arguments+=("$rendered")
docker "${build_arguments[@]}"

image_digest="$(tar -xOf "$oci_archive" index.json | jq -er '.manifests | if length == 1 then .[0].digest else error("expected one OCI manifest") end')"
if [[ ! "$image_digest" =~ ^sha256:[a-f0-9]{64}$ ]]; then
  printf 'Docker produced an invalid image digest: %s\n' "$image_digest" >&2
  exit 1
fi
build_digest="$(jq -er '."containerimage.digest"' "$build_metadata")"
if [[ "$build_digest" != "$image_digest" ]]; then
  printf 'Docker build metadata digest does not match the OCI archive\n' >&2
  exit 1
fi
printf '%s\n' "$image_digest" >"$digest_payload"

# Refresh one persistent DB snapshot before scanning, then forbid DB updates and
# external dependency lookups for the scan itself. The online fetch is explicit;
# every result in this artifact is evaluated against the same cached snapshot.
mkdir -p "$trivy_cache"
trivy image --cache-dir "$trivy_cache" \
  --db-repository "$trivy_db_repository" \
  --download-db-only --skip-version-check
trivy_db_metadata="$trivy_cache/db/metadata.json"
if [[ ! -s "$trivy_db_metadata" ]]; then
  printf 'Trivy DB metadata is missing after download: %s\n' \
    "$trivy_db_metadata" >&2
  exit 1
fi
jq -e '.Version == 2 and .UpdatedAt and .NextUpdate and .DownloadedAt' \
  "$trivy_db_metadata" >/dev/null
cp "$trivy_db_metadata" "$trivy_db_evidence"
mkdir -p "$oci_layout"
tar -xf "$oci_archive" -C "$oci_layout"
layout_digest="$(jq -er '.manifests | if length == 1 then .[0].digest else error("expected one OCI manifest") end' "$oci_layout/index.json")"
if [[ "$layout_digest" != "$image_digest" ]]; then
  printf 'extracted OCI layout digest does not match the image archive\n' >&2
  exit 1
fi
trivy image --input "$oci_layout" --cache-dir "$trivy_cache" \
  --exit-code 1 --scanners vuln --severity HIGH,CRITICAL \
  --skip-db-update --skip-check-update --skip-vex-repo-update \
  --skip-version-check --offline-scan --format json --output "$scan_report"

syft scan "oci-archive:$oci_archive" --output "spdx-json=$sbom"
sbom_temporary="$work_directory/sbom.spdx.json"
jq --arg digest "$image_digest" \
  '.documentComment = "ForgePath validated image digest: \($digest)"' \
  "$sbom" >"$sbom_temporary"
mv "$sbom_temporary" "$sbom"

key_prefix="$work_directory/cosign"
COSIGN_PASSWORD='' cosign generate-key-pair \
  --output-key-prefix "$key_prefix" >/dev/null 2>&1
cp "$key_prefix.pub" "$public_key"
COSIGN_PASSWORD='' cosign sign-blob --yes --tlog-upload=false \
  --key "$key_prefix.key" --output-signature "$signature" \
  "$digest_payload" >/dev/null
cosign verify-blob --offline --private-infrastructure \
  --key "$public_key" --signature "$signature" \
  "$digest_payload" >/dev/null
rm -f "$key_prefix.key"

sha256_file() {
  if command -v sha256sum >/dev/null; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

sbom_sha256="$(sha256_file "$sbom")"
scan_sha256="$(sha256_file "$scan_report")"
trivy_db_metadata_sha256="$(sha256_file "$trivy_db_evidence")"
signature_sha256="$(sha256_file "$signature")"

jq -n \
  --arg repository "$image_repository" \
  --arg digest "$image_digest" \
  --arg trusted_reference "$image_repository@$image_digest" \
  --arg build_timestamp "$build_timestamp" \
  --arg source_revision "$source_revision" \
  --argjson source_dirty "$source_dirty" \
  --arg sbom_sha256 "$sbom_sha256" \
  --arg scan_sha256 "$scan_sha256" \
  --arg trivy_db_metadata_sha256 "$trivy_db_metadata_sha256" \
  --argjson trivy_db_version "$(jq '.Version' "$trivy_db_evidence")" \
  --arg trivy_db_updated_at "$(jq -r '.UpdatedAt' "$trivy_db_evidence")" \
  --arg signature_sha256 "$signature_sha256" \
  '{
    schema_version: 1,
    image: {
      repository: $repository,
      digest: $digest,
      trusted_reference: $trusted_reference,
      oci_archive_path: "image.oci.tar"
    },
    build: {
      timestamp: (if $build_timestamp == "" then null else $build_timestamp end),
      source_revision: (if $source_revision == "" then null else $source_revision end),
      source_dirty: $source_dirty,
      reproducible_timestamp: ($build_timestamp != "")
    },
    sbom: {
      path: "sbom.spdx.json",
      format: "SPDX-JSON",
      sha256: $sbom_sha256,
      image_digest: $digest
    },
    vulnerability_scan: {
      result: "passed",
      scanner: "Trivy",
      policy_severities: ["HIGH", "CRITICAL"],
      report_path: "trivy-report.json",
      report_sha256: $scan_sha256,
      database: {
        schema_version: $trivy_db_version,
        updated_at: $trivy_db_updated_at,
        metadata_path: "trivy-db-metadata.json",
        metadata_sha256: $trivy_db_metadata_sha256
      },
      image_digest: $digest
    },
    signature: {
      method: "Cosign local detached signature over image-digest.txt",
      payload_path: "image-digest.txt",
      signature_path: "image-digest.sig",
      signature_sha256: $signature_sha256,
      public_key_path: "cosign.pub",
      verification_result: "passed",
      image_digest: $digest
    }
  }' >"$metadata"

"$repository_root/scripts/validate-trusted-artifact.sh" \
  "$staging_directory" --evidence-only
printf '%s\n' "$image_digest" >"$trusted_marker"
"$repository_root/scripts/validate-trusted-artifact.sh" "$staging_directory"

rm -rf "$artifact_directory"
mv "$staging_directory" "$artifact_directory"
printf 'Trusted artifact created: %s@%s\n' "$image_repository" "$image_digest"
printf 'Artifact evidence: %s\n' "$artifact_directory"

#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
artifact_directory="${1:-${FORGEPATH_ARTIFACT_DIR:-$repository_root/.forgepath/trusted-artifact}}"
require_trusted_marker=true
if [[ "${2:-}" == "--evidence-only" ]]; then
  require_trusted_marker=false
elif [[ -n "${2:-}" ]]; then
  printf 'unknown trusted-artifact validation option: %s\n' "$2" >&2
  exit 1
fi

for tool in cosign jq tar; do
  if ! command -v "$tool" >/dev/null; then
    printf 'required trusted-artifact validation tool not found: %s\n' "$tool" >&2
    exit 1
  fi
done

required_files=(
  cosign.pub
  image-digest.sig
  image-digest.txt
  image.oci.tar
  metadata.json
  sbom.spdx.json
  trivy-report.json
)
if [[ "$require_trusted_marker" == "true" ]]; then
  required_files+=(TRUSTED)
fi
for relative_path in "${required_files[@]}"; do
  if [[ ! -s "$artifact_directory/$relative_path" ]]; then
    printf 'trusted artifact file is missing or empty: %s\n' "$relative_path" >&2
    exit 1
  fi
done
if find "$artifact_directory" -type f -name '*.key' -print -quit | grep -q .; then
  printf 'private signing key found in trusted artifact directory\n' >&2
  exit 1
fi

metadata="$artifact_directory/metadata.json"
recorded_digest="$(jq -er '.image.digest' "$metadata")"
archive_digest="$(tar -xOf "$artifact_directory/image.oci.tar" index.json | jq -er '.manifests | if length == 1 then .[0].digest else error("expected one OCI manifest") end')"
payload_digest="$(tr -d '\r\n' <"$artifact_directory/image-digest.txt")"

if [[ ! "$recorded_digest" =~ ^sha256:[a-f0-9]{64}$ ]]; then
  printf 'metadata contains an invalid image digest\n' >&2
  exit 1
fi
if [[ "$recorded_digest" != "$archive_digest" ]]; then
  printf 'trusted artifact digest mismatch\n' >&2
  exit 1
fi
if [[ "$recorded_digest" != "$payload_digest" ]]; then
  printf 'trusted artifact digest mismatch\n' >&2
  exit 1
fi
if [[ "$require_trusted_marker" == "true" ]]; then
  marker_digest="$(tr -d '\r\n' <"$artifact_directory/TRUSTED")"
  if [[ "$recorded_digest" != "$marker_digest" ]]; then
    printf 'trusted artifact digest mismatch\n' >&2
    exit 1
  fi
fi

if ! jq -e --arg digest "$recorded_digest" '
  .schema_version == 1 and
  (.image.repository |
    type == "string" and length > 0 and (contains(":latest") | not)) and
  .image.trusted_reference == (.image.repository + "@" + $digest) and
  .image.oci_archive_path == "image.oci.tar" and
  (.build.source_dirty | type == "boolean") and
  .sbom.path == "sbom.spdx.json" and
  .sbom.format == "SPDX-JSON" and
  .sbom.image_digest == $digest and
  .vulnerability_scan.result == "passed" and
  .vulnerability_scan.scanner == "Trivy" and
  .vulnerability_scan.policy_severities == ["HIGH", "CRITICAL"] and
  .vulnerability_scan.report_path == "trivy-report.json" and
  .vulnerability_scan.image_digest == $digest and
  .signature.payload_path == "image-digest.txt" and
  .signature.signature_path == "image-digest.sig" and
  .signature.public_key_path == "cosign.pub" and
  .signature.verification_result == "passed" and
  .signature.image_digest == $digest
' "$metadata" >/dev/null; then
  printf 'trusted artifact metadata contract is invalid\n' >&2
  exit 1
fi

sha256_file() {
  if command -v sha256sum >/dev/null; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

if [[ "$(sha256_file "$artifact_directory/sbom.spdx.json")" != \
      "$(jq -er '.sbom.sha256' "$metadata")" ]]; then
  printf 'SBOM checksum does not match metadata\n' >&2
  exit 1
fi
if [[ "$(sha256_file "$artifact_directory/trivy-report.json")" != \
      "$(jq -er '.vulnerability_scan.report_sha256' "$metadata")" ]]; then
  printf 'vulnerability report checksum does not match metadata\n' >&2
  exit 1
fi
if [[ "$(sha256_file "$artifact_directory/image-digest.sig")" != \
      "$(jq -er '.signature.signature_sha256' "$metadata")" ]]; then
  printf 'signature checksum does not match metadata\n' >&2
  exit 1
fi

if ! jq -e --arg digest "$recorded_digest" '
  .spdxVersion == "SPDX-2.3" and
  (.packages | type == "array" and length > 0) and
  .documentComment == ("ForgePath validated image digest: " + $digest)
' "$artifact_directory/sbom.spdx.json" >/dev/null; then
  printf 'SBOM is invalid, empty, or not bound to the image digest\n' >&2
  exit 1
fi

if ! jq -e '
  (.SchemaVersion | type == "number") and
  (.Results | type == "array") and
  ([.Results[]?.Vulnerabilities[]? |
    select(.Severity == "HIGH" or .Severity == "CRITICAL")] | length == 0)
' "$artifact_directory/trivy-report.json" >/dev/null; then
  printf 'vulnerability report is invalid or contains denied findings\n' >&2
  exit 1
fi

cosign verify-blob --offline --private-infrastructure \
  --key "$artifact_directory/cosign.pub" \
  --signature "$artifact_directory/image-digest.sig" \
  "$artifact_directory/image-digest.txt" >/dev/null

printf 'Trusted artifact validation passed for %s\n' \
  "$(jq -r '.image.trusted_reference' "$metadata")"

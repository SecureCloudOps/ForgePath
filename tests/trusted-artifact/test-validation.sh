#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
artifact_directory="${FORGEPATH_ARTIFACT_DIR:-$repository_root/.forgepath/trusted-artifact}"
validator="$repository_root/scripts/validate-trusted-artifact.sh"

if [[ ! -s "$artifact_directory/TRUSTED" ]]; then
  printf 'trusted artifact fixture not found; run make build-trusted-artifact first\n' >&2
  exit 1
fi

work_directory="$(mktemp -d)"
cleanup() {
  rm -rf "$work_directory"
}
trap cleanup EXIT

expect_rejection() {
  local description="$1"
  local candidate="$2"
  local status

  set +e
  "$validator" "$candidate" >/dev/null 2>&1
  status=$?
  set -e
  if [[ "$status" -eq 0 ]]; then
    printf 'negative test unexpectedly passed: %s\n' "$description" >&2
    exit 1
  fi
  printf 'Negative test passed: %s\n' "$description"
}

make_candidate() {
  local name="$1"
  local candidate="$work_directory/$name"
  cp -R "$artifact_directory" "$candidate"
  printf '%s\n' "$candidate"
}

candidate="$(make_candidate unsigned)"
rm -f "$candidate/image-digest.sig"
expect_rejection 'unsigned artifact is rejected' "$candidate"

candidate="$(make_candidate mismatched-digest)"
jq '.image.digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' \
  "$candidate/metadata.json" >"$candidate/metadata.tmp"
mv "$candidate/metadata.tmp" "$candidate/metadata.json"
expect_rejection 'metadata with a mismatched digest is rejected' "$candidate"

candidate="$(make_candidate missing-sbom)"
rm -f "$candidate/sbom.spdx.json"
expect_rejection 'missing SBOM is rejected' "$candidate"

candidate="$(make_candidate missing-trivy-db-metadata)"
rm -f "$candidate/trivy-db-metadata.json"
expect_rejection 'missing Trivy DB snapshot evidence is rejected' "$candidate"

candidate="$(make_candidate invalid-signature)"
printf 'invalid-signature\n' >"$candidate/image-digest.sig"
signature_sha256="$(shasum -a 256 "$candidate/image-digest.sig" | awk '{print $1}')"
jq --arg signature_sha256 "$signature_sha256" \
  '.signature.signature_sha256 = $signature_sha256' \
  "$candidate/metadata.json" >"$candidate/metadata.tmp"
mv "$candidate/metadata.tmp" "$candidate/metadata.json"
expect_rejection 'failed signature verification is rejected' "$candidate"

printf 'Trusted artifact negative validation tests passed.\n'

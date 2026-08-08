#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"

required_files=(
  README.md
  .gitignore
  mise.toml
  Makefile
  docs/ARCHITECTURE.md
  docs/DEMO.md
  docs/THREAT_MODEL.md
  docs/ROADMAP.md
  docs/adr/README.md
  scripts/validate-foundation.sh
)

required_directories=(
  platform
  policies
  gitops
  tests
)

for file in "${required_files[@]}"; do
  if [[ ! -s "$file" ]]; then
    printf 'missing or empty required file: %s\n' "$file" >&2
    exit 1
  fi
done

if [[ ! -d templates ]]; then
  printf 'missing required directory: templates\n' >&2
  exit 1
fi

for directory in "${required_directories[@]}"; do
  if [[ ! -d "$directory" ]]; then
    printf 'missing required directory: %s\n' "$directory" >&2
    exit 1
  fi
done

if [[ ! -x scripts/validate-foundation.sh ]]; then
  printf 'validation script must be executable\n' >&2
  exit 1
fi

for document in README.md docs/ARCHITECTURE.md docs/DEMO.md \
  docs/THREAT_MODEL.md docs/ROADMAP.md docs/adr/README.md; do
  if ! grep -Fq 'ForgePath' "$document"; then
    printf 'documentation does not identify ForgePath: %s\n' "$document" >&2
    exit 1
  fi
done

if ! grep -Fq 'make validate-foundation' README.md; then
  printf 'README.md does not document foundation validation\n' >&2
  exit 1
fi

architecture_stages=(
  'Backstage'
  'secure-fastapi-service'
  'Repository-owned renderer'
  'OPA / Conftest policy gate'
  'OCI image + SBOM + scan report'
  'Git desired state'
  'Argo CD Application'
  'Kyverno admission'
  'Kubernetes workload'
  'backstage-runtime-reader'
)

for stage in "${architecture_stages[@]}"; do
  if ! grep -Fq -- "$stage" docs/ARCHITECTURE.md; then
    printf 'architecture flow is missing stage: %s\n' "$stage" >&2
    exit 1
  fi
done

printf 'ForgePath foundation validation passed.\n'

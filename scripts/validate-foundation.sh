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

empty_directories=(
  platform
  gitops
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

for directory in "${empty_directories[@]}"; do
  if find "$directory" -mindepth 1 -print -quit | grep -q .; then
    printf 'foundation directory must be empty: %s\n' "$directory" >&2
    exit 1
  fi
done

if [[ ! -x scripts/validate-foundation.sh ]]; then
  printf 'validation script must be executable\n' >&2
  exit 1
fi

for document in README.md docs/ARCHITECTURE.md docs/THREAT_MODEL.md \
  docs/ROADMAP.md docs/adr/README.md; do
  if ! grep -Fq 'ForgePath' "$document"; then
    printf 'documentation does not identify ForgePath: %s\n' "$document" >&2
    exit 1
  fi
done

if ! grep -Fq 'make validate-foundation' README.md; then
  printf 'README.md does not document foundation validation\n' >&2
  exit 1
fi

expected_flow=(
  'paved path'
  '-> generated service'
  '-> CI validation'
  '-> policy enforcement'
  '-> build / scan / SBOM / sign'
  '-> trusted artifact'
  '-> Git desired state'
  '-> Argo CD'
  '-> Kyverno'
  '-> Kubernetes'
)

previous_line=0
for stage in "${expected_flow[@]}"; do
  line="$(grep -nF -- "$stage" docs/ARCHITECTURE.md | head -n 1 | cut -d: -f1)"
  if [[ -z "$line" || "$line" -le "$previous_line" ]]; then
    printf 'architecture flow is missing or out of order at: %s\n' "$stage" >&2
    exit 1
  fi
  previous_line="$line"
done

printf 'ForgePath foundation validation passed.\n'

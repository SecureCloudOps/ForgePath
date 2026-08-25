# Trusted-artifact provenance corrective-action closure

Corrective action CA-4 from incident `INC-20260824T152814Z` is closed.

On 2026-08-24, ForgePath rebuilt the trusted artifact in a clean local clone of
the current committed source. The build used the repository-pinned toolchain,
the deterministic template renderer and the existing trusted-artifact contract.
No Kubernetes cluster or remote Git repository was contacted or mutated.

## Closure result

| Field | Verified value |
| --- | --- |
| Source revision | `211bd353248f0481c9e7d7b11d8a3596480f4ea6` |
| Source dirty | `false` |
| Reproducible timestamp | `true` |
| Image digest | `sha256:26a1ce3bbe7bae23a594ec2292d666e1173aadb4c20ce310639e0048df3efa40` |
| Metadata SHA-256 | `350fa8cb0447ed4c1aeb1c36a44fe2d4dbd84495948714c30229a2b7fafb478f` |
| SPDX SBOM SHA-256 | `6ce3bc181a96a8ff79db071a0f7a869c67bb41565fadbe02ba2846b642214bc1` |
| Trivy report SHA-256 | `ea47d1b0a3f6d273876183e5415610015cdea05adee3fc3351496a96f3cc58dc` |
| Trivy DB metadata SHA-256 | `5ff07fbd26547b2eab52881ba9de217c65f9fcefdbada7b786e5cae1b765025a` |
| Signature SHA-256 | `8d477496268d6d6e6b45435584ecd16f804e48541aea796890dffb0642a2e516` |
| Signature verification | Passed, offline/private-infrastructure mode |
| HIGH/CRITICAL vulnerability policy | Passed |

The local GitOps value now pins that exact digest. The validated artifact is
retained at `.forgepath/trusted-artifact/`. Its previous dirty-source version
was temporarily backed up during replacement; the original incident bundle
continues to retain the historical dirty-source metadata.

The build workflow now fails closed when any file beneath
`templates/secure-fastapi-service` is dirty. A future full rebuild cannot
silently replace this closure artifact with `source_dirty=true` evidence.

## Independent verification

```sh
./scripts/validate-trusted-artifact.sh
jq -e '.build.source_dirty == false' \
  .forgepath/trusted-artifact/metadata.json
jq -e '.image.digest == "sha256:26a1ce3bbe7bae23a594ec2292d666e1173aadb4c20ce310639e0048df3efa40"' \
  .forgepath/trusted-artifact/metadata.json
```

Run `make validate-trusted-artifact` for a complete rebuild only from a clean
template source state; the gate now refuses a dirty input before building.

The tracked [closure manifest](manifests/ca4-trusted-artifact.json) records the
artifact hashes and GitOps digest binding. The original incident bundle is not
rewritten: its historical `trusted-artifact.json` correctly continues to show
`source_dirty=true`, while this record proves the subsequent corrective action.

## Scope note

The template `.dockerignore` excludes chart, documentation and test material
from the OCI build context. The clean rebuild nevertheless binds provenance to
the complete committed template input and records the source revision label in
the image. The changed digest is therefore promoted explicitly rather than
silently treating the previous digest as equivalent.

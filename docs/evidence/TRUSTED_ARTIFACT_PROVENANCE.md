# Trusted-artifact provenance corrective-action closure

Corrective action CA-4 from incident `INC-20260824T152814Z` is closed.

On 2026-08-24, ForgePath rebuilt the release artifact from the clean final v2
source commit. The build used the repository-pinned toolchain, deterministic
template renderer and existing trusted-artifact contract. No Kubernetes cluster
or remote Git repository was contacted or mutated. This release rebuild
supersedes the earlier corrective-action artifact without rewriting the
historical incident evidence.

## Closure result

| Field | Verified value |
| --- | --- |
| Source revision | `c51aaa8f7db00f316389c1078b6ce3968b794f97` |
| Source dirty | `false` |
| Reproducible timestamp | `true` |
| Image digest | `sha256:148fa9472d55a1e093e1b31242928aa40cbe3681d025d1c8880c0d6e1bc20d4f` |
| Metadata SHA-256 | `b1723e7b50699e926cacafd55ff0862a25745ce9cf48acf93aa64892d901c720` |
| SPDX SBOM SHA-256 | `59d770a71f91441ff800bb6dbd175f36d1f230a277f2152d0c50444382f549e8` |
| Trivy report SHA-256 | `15fa65b213d9655b3d178c1818c08c28457d76d8f27846be451c8bb631288e25` |
| Trivy DB metadata SHA-256 | `5ff07fbd26547b2eab52881ba9de217c65f9fcefdbada7b786e5cae1b765025a` |
| Signature SHA-256 | `711a1cbb9bffe768507209b5807b1258c06fb8a59146bf958646295e3212f094` |
| Signature verification | Passed, offline/private-infrastructure mode |
| HIGH/CRITICAL vulnerability policy | Passed |

The local GitOps value now pins that exact digest. The validated artifact is
retained at `.forgepath/trusted-artifact/`; the original incident bundle
continues to retain the historical dirty-source metadata.

The build workflow now fails closed when any file beneath
`templates/secure-fastapi-service` is dirty. A future full rebuild cannot
silently replace this closure artifact with `source_dirty=true` evidence.

## Independent verification

```sh
./scripts/validate-trusted-artifact.sh
jq -e '.build.source_dirty == false' \
  .forgepath/trusted-artifact/metadata.json
jq -e '.image.digest == "sha256:148fa9472d55a1e093e1b31242928aa40cbe3681d025d1c8880c0d6e1bc20d4f"' \
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

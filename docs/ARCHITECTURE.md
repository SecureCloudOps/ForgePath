# ForgePath Architecture

ForgePath is intended to provide a single, understandable delivery flow:

```text
Backstage or CLI
-> paved-path renderer
-> generated service
-> CI validation
-> policy enforcement
-> build / scan / SBOM / sign
-> trusted artifact
-> Git desired state
-> Argo CD
-> Kyverno
-> Kubernetes
```

Backstage is a local developer-experience consumer at the entrance to this
flow. Its only permitted scaffolder action delegates to the same
repository-owned Python renderer used by the CLI and writes to a confined,
ignored local directory. It does not publish repositories, register remote
entities, build artifacts, or apply Kubernetes resources. The generated
`catalog-info.yaml` and TechDocs are part of the paved-path output contract
rather than a separate portal-specific implementation.

Each stage passes evidence to the next stage. The trusted-artifact stage builds
the generated service as a local OCI archive and binds its manifest digest to a
Trivy report, SPDX JSON SBOM, local Cosign signature, and machine-readable
metadata. A trusted marker is published atomically only after all evidence is
validated. Local signing keys are ephemeral and no artifact is published.

Git holds a static desired-state model for the local environment. Its restricted
AppProject, single Application, environment values, and offline validation prove
the trusted digest handoff. Runtime responsibilities remain intentionally
layered: OPA/Conftest rejects policy violations during pre-deployment CI, Argo CD
reconciles approved desired state, and Kyverno fails closed at Kubernetes
admission if a non-compliant workload bypasses an earlier layer.

The first Kyverno runtime proof is independent of Argo CD. It installs the
reviewed, pinned Kyverno release and ForgePath validation policies directly into
a disposable Kind cluster, then sends compliant and non-compliant requests to
the Kubernetes API. This keeps admission behavior observable without making the
GitOps controller part of the test's critical path.

Optional portal visibility is read-only. Backstage queries the selected
Kubernetes workload resources and the existing Argo CD `Application` custom
resource; it does not hold an Argo API token or expose sync controls. Pod
deletion is disabled and the permission policy denies the Kubernetes proxy
permission. The local kubectl proxy must use a separately constrained
read-only Kubernetes identity, so access remains bounded by Kubernetes RBAC.

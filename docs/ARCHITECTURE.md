# ForgePath Architecture

ForgePath is intended to provide a single, understandable delivery flow:

```text
paved path
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

Each stage passes evidence to the next stage. The trusted-artifact stage builds
the generated service as a local OCI archive and binds its manifest digest to a
Trivy report, SPDX JSON SBOM, local Cosign signature, and machine-readable
metadata. A trusted marker is published atomically only after all evidence is
validated. Local signing keys are ephemeral and no artifact is published.

Git now holds a static desired-state model for the local environment. Its
restricted AppProject, single Application, environment values, and offline
validation prove the trusted digest handoff without installing Argo CD or
contacting Kubernetes. Argo CD reconciliation and Kubernetes runtime state
remain later operational stages; Kyverno is still a roadmap item.

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

Git will hold desired state, and GitOps reconciliation remains the only intended
application delivery path. Those later delivery stages are roadmap items and
are not implemented here.

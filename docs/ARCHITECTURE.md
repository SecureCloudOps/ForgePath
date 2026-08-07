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

Each stage should pass evidence to the next stage. Git holds the desired state,
and GitOps reconciliation is the only intended application delivery path. This
document describes direction only; none of these components are implemented in
the repository foundation.

# ForgePath Threat Model

This initial threat model identifies the major trust boundaries and threats in
the intended ForgePath delivery flow. It does not prescribe controls in detail.

## Trust boundaries

- Developer input entering a paved path and generated service repository.
- Local Backstage input crossing into the repository-owned paved-path renderer.
- Source changes entering CI and policy evaluation.
- The build environment producing artifacts, scan results, SBOMs, and signatures.
- Trusted artifacts and provenance entering the artifact store.
- Git desired state entering the GitOps reconciliation boundary.
- Argo CD and Kyverno interacting with the Kubernetes API.

## Major threats

- A developer or compromised account bypasses an approved paved path or review.
- Malicious source, dependencies, or CI configuration execute in the build
  environment.
- Validation or policy checks are bypassed, weakened, or evaluated against the
  wrong input.
- Build artifacts, SBOMs, signatures, or provenance are forged, replaced, or
  separated from the reviewed source.
- Git desired state references an untrusted or mutable artifact.
- GitOps credentials or controller permissions are abused to change cluster
  state outside the approved scope.
- Admission controls are bypassed or fail open, allowing non-compliant workloads.
- Sensitive data is exposed through source, logs, artifacts, or configuration.
- A local developer portal escapes its output root, publishes unexpectedly, or
  uses overprivileged Kubernetes credentials for status visibility.

The intended posture is least privilege, immutable and verifiable artifacts,
fail-closed enforcement, and GitOps-only application delivery.

The local Backstage proof confines generation to an ignored repository path,
uses argument-safe process execution, delegates to the existing renderer, and
allows only that local renderer action to execute; publish and remote
registration actions are denied. Its workload view excludes
Secrets and ConfigMaps, disables pod deletion, denies direct proxy permission,
and relies on the caller to supply a read-only Kubernetes identity. Guest auth
and the in-memory database make this bootstrap unsuitable for shared hosting.

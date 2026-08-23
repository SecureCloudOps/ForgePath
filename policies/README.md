# ForgePath Kubernetes policy

`kubernetes.rego` is the centralized ForgePath policy for Kubernetes workloads.
It is evaluated with Conftest in combined-input mode so rules can reason across
the complete Helm-rendered resource set, including the requirement for a
namespace-wide default-deny NetworkPolicy, ResourceQuota, LimitRange, a
dual-selector Prometheus scrape exception, and a DNS-only egress exception.

Run the policy gate from the repository root:

```sh
make validate-policy
```

The validation renders the `secure-fastapi-service` Helm chart before testing it.
Source templates are not treated as policy evidence.

## Runtime admission enforcement

Validation-only Kyverno `ClusterPolicy` resources live in `policies/kyverno/`.
They express the same core workload security intent at admission time and are
configured with `validationFailureAction: Enforce` and `failurePolicy: Fail`.
They contain no mutation or generation rules.

Run the offline Kyverno CLI suite with:

```sh
make validate-kyverno-static
```

This is additive defense in depth: OPA/Conftest remains the pre-deployment CI
gate, Argo CD remains the desired-state reconciler, and Kyverno is the runtime
Kubernetes admission layer. Installation version, artifact checksum, and image
digests are documented in `policies/kyverno/INSTALLATION.md`.

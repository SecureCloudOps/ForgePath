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
They contain no mutation or generation rules. `platform-guardrails.yaml`
additionally requires the following Pod labels and restricts images to approved
registries and digest-only references:

- `forgepath.dev/owner`
- `forgepath.dev/system`
- `forgepath.dev/environment`
- `forgepath.dev/data-classification`
- optional `forgepath.dev/support-tier` (`1` through `4`)

The production registry prefix is `ghcr.io/securecloudops/`. A loopback
registry prefix is accepted only in the named `forgepath-kyverno-test`
namespace used by the disposable runtime proof.

Run the offline Kyverno CLI suite with:

```sh
make validate-kyverno-static
```

This is additive defense in depth: OPA/Conftest remains the pre-deployment CI
gate, Argo CD remains the desired-state reconciler, and Kyverno is the runtime
Kubernetes admission layer. Installation version, artifact checksum, and image
digests are documented in `policies/kyverno/INSTALLATION.md`.

## Signature and provenance trust root

`policies/templates/trusted-image-verification.yaml.tmpl` is deliberately not a
directly installable policy. The platform operator must inject a reviewed Cosign
public key before applying it. The resulting fail-closed policy requires both an
OCI image signature and a signed SLSA provenance v1 attestation for approved
images; it never mutates a tag into a digest.

The runtime harness generates a one-run key pair under its temporary directory,
injects only the public key, signs and attests the isolated registry copy, then
deletes the private key before the admission sequence completes. No private key,
registry credential, or Kubernetes Secret is written to Git.
Because this isolated proof has no external Rekor dependency, only its generated
temporary policy sets `rekor.ignoreTlog: true`; the committed trust template
retains transparency-log verification for production trust roots.

# Platform guardrail validation evidence

The first ForgePath platform-guardrail increment was validated on 2026-08-23
with the repository-pinned toolchain. Its scope is frozen at required workload
metadata and trusted-image admission. Namespace protections remain a separate,
subsequent increment.

## Static evidence

```sh
make validate-platform-guardrails-static
```

The gate admitted the secure paved-path render, rejected all 20 deliberately
insecure Kyverno fixtures, and verified that the trusted-image policy requires
both a signature and SLSA provenance. Kyverno CLI v1.18.2 reported success.

## Runtime admission evidence

After explicit approval, the isolated runtime proof ran with Kind v0.32.0,
Kubernetes v1.32.11, and Kyverno v1.18.2:

```sh
make validate-platform-guardrails-runtime
```

The Kubernetes API produced the following results:

- each missing `forgepath.dev/owner`, `forgepath.dev/system`,
  `forgepath.dev/environment`, and `forgepath.dev/data-classification` label was
  denied with a label-specific remediation message;
- a tag-based image and an image from an unapproved registry were denied with
  actionable messages;
- an unsigned digest from the isolated trusted registry was denied;
- a signed digest without the required SLSA provenance was denied;
- the same immutable digest was admitted after signature and SLSA provenance
  verification;
- a signed and attested workload requesting privileged execution was denied;
- the compliant metadata, trusted image, and secure workload were admitted;
- the compliant Helm-rendered application Pod was admitted;
- the existing privileged, root, mutable-image, missing-resource, host-network,
  and host-PID runtime fixtures remained denied; and
- admission enforcement remained active after the Kyverno controller restarted.

## Isolation and cleanup evidence

The harness refused reuse of a pre-existing target, created only the disposable
`forgepath-kyverno` cluster, addressed it through the exact
`kind-forgepath-kyverno` context, and deleted it at exit. It restored the
original context:

```text
arn:aws:eks:us-east-1:767828729088:cluster/cloudsecops-llm-finetuning-dev
```

The registry data, one-run Cosign private key, generated policy, signature,
attestation, and other runtime material lived only in the disposable cluster or
temporary directory. Cleanup reported that the cluster and temporary artifacts
were removed. No existing cluster or unrelated workload was mutated.

For the offline demonstration registry, the generated temporary verification
policy ignores transparency-log lookup while still requiring the one-run public
key, signature, and SLSA attestation. The committed production template remains
fail-closed and does not carry that demonstration-only setting.

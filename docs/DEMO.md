# ForgePath demonstrations

## Platform-guardrails demonstration

The first guardrail increment establishes who owns a workload and which software
may execute. Its single admission story is:

```text
developer submits workload with valid ownership metadata
  -> trusted-registry digest is unsigned
  -> denied
  -> image is signed but has no SLSA provenance
  -> denied
  -> signed digest and signed SLSA provenance supplied
  -> admitted
  -> the same trusted workload requests privileged execution
  -> denied
  -> compliant workload admitted
```

Offline policy, chart, and negative-fixture proof:

```sh
make validate-platform-guardrails-static
```

After explicit approval for the trusted-artifact build and disposable cluster
mutation:

```sh
make validate-platform-guardrails-runtime
```

The harness uses only `forgepath-kyverno`, verifies the exact context, installs
the checksum-reviewed and digest-pinned Kyverno manifest, and adds a digest-pinned
registry sidecar for this proof. The registry is reachable only through a local
port-forward. The one-run Cosign private key remains in a temporary directory,
is never printed, and is deleted immediately after signing and attestation.
Cleanup removes the cluster and all temporary material and restores the caller's
original Kubernetes context.

## Namespace-isolation demonstration

Offline boundary validation:

```sh
make validate-namespace-protections-static
```

After explicit approval for the disposable cluster mutation:

```sh
make validate-namespace-protections-runtime
```

The `forgepath-namespace-boundary` harness creates the workload namespace with
version-pinned `restricted` Pod Security Admission before creating any workload,
then installs its ResourceQuota, LimitRange, and namespace-wide default-deny
policies. It proves authorized service traffic, Prometheus scraping, and DNS;
rejects unauthorized ingress, unauthorized application egress, quota and limit
violations, and a restricted Pod Security violation; then deletes the isolated
cluster and restores the original context.

## Progressive-delivery demonstration

The next approved runtime demonstration is intentionally one failure story:

```text
healthy v1
  -> reconcile defective v2
  -> 5% replica-weighted canary
  -> availability burn rate exceeds 14.4x
  -> AnalysisRun fails
  -> Rollout aborts before 25%
  -> stable Service remains on v1
```

The repository now contains the static desired state and assertions for this
path. The exact prerequisites, demo-only values, 95/5 synthetic request mix,
observations, and Git rollback are in the reference service's
[progressive-delivery runbook](../services/secure-fastapi-service/docs/progressive-delivery.md).
Installing the Argo Rollouts prerequisites and running the cluster mutation are
a separate approval boundary.

## Workload-identity demonstration

The application has no Kubernetes API requirement, so its explicit permission
set is empty and both its ServiceAccount and Pod disable token automount. The
AppProject also refuses application-owned RBAC resources.

```sh
make validate-workload-identity-static
```

After explicit approval for the disposable cluster mutation:

```sh
make validate-workload-identity-runtime
```

The runtime story is `healthy application -> short-lived application identity
calls the Secrets API -> HTTP 403 -> isolated platform reconciler patches only
its named Deployment -> application identity cannot perform the same patch`.
The harness also runs negative `kubectl auth can-i` checks for Secrets,
Deployments, Rollouts, AnalysisRuns, Kyverno policies, NetworkPolicies,
privileged-workload creation, token requests, and identity impersonation.

## ForgePath v1 demo

This demo tells one story with one service:

```text
Backstage -> secure-fastapi-service -> Catalog + TechDocs
          -> Kubernetes workload status -> Argo CD Application status
```

It also shows three controls behaving under pressure: CI policy rejects an
unsafe manifest, Argo CD repairs drift, and Kyverno rejects an unsafe admission
request.

## Prerequisites and approval

Install the pinned tools with `mise install` and start Docker. The runtime
commands create and delete disposable Kind clusters and mutate only those
clusters. Under `AGENTS.md`, obtain explicit approval immediately before running
them. The harnesses refuse pre-existing cluster names, verify the exact context,
restore the original context, and clean up on exit.

## 1. Establish the offline evidence

```sh
make validate-v1-static
```

Show the generated component in Backstage, its TechDocs, the hardened Helm
render, the trusted digest metadata beneath `.forgepath/trusted-artifact/`, and
the static GitOps Application/AppProject.

For the policy-rejection moment, run:

```sh
mise exec -- conftest test --combine --policy policies \
  tests/policy/fixtures/mutable-image.yaml
```

The command must fail. The fixture is synthetic and contains no credential.

## 2. Prove Backstage runtime visibility and Argo CD reconciliation

After explicit approval:

```sh
make validate-backstage-runtime
```

The gate creates `forgepath-gitops`, deploys the trusted reference service only
through Argo CD, and starts Backstage against a loopback kubectl proxy that
always impersonates `backstage-runtime-reader`. It proves:

- Catalog and TechDocs metadata for `secure-fastapi-service`;
- a ready Deployment and Pod returned by the Backstage Kubernetes backend;
- a `Synced` and `Healthy` Argo CD Application returned through Backstage;
- `get`, `list`, and `watch` on only the selected workload types and Application;
- denial of Secrets, Pod deletion, exec, workload mutation, service-account
  token requests, Application mutation/sync, and Backstage's raw Kubernetes
  proxy permission; and
- self-heal after replica drift, a Git revision change, creation, and pruning.

The harness prints one `PASS` line per claim and retains no cluster or token.

## 3. Prove Kyverno admission rejection

After explicit approval:

```sh
make validate-kyverno-runtime
```

The disposable `forgepath-kyverno` cluster runs the metadata and trusted-image
sequence above, admits the compliant Helm rendering, and rejects privileged,
root, mutable-image, missing-resource, host-network, and host-PID Pods. It
repeats a rejection after restarting the admission controller to prove
fail-closed enforcement remains active.

## Screenshot set

Record these five frames during the approved demo run and save them beneath
`docs/screenshots/`:

1. the one-service ForgePath catalog;
2. the `secure-fastapi-service` overview with its TechDocs entry point and
   related Argo CD Resource;
3. the rendered TechDocs overview for the reference service;
4. Kubernetes status showing the ready Deployment and Pod; and
5. the related Argo CD resource showing `Synced` and `Healthy`.

The non-sensitive terminal proof for the policy controls, Argo CD self-heal,
Kyverno admission rejection, cleanup, and final gate is recorded in the
[v1 validation evidence](evidence/V1_VALIDATION.md). It excludes kubeconfigs,
tokens, Secret values, environment dumps, and unrelated desktop content.

## Final validation

After approval for both disposable runtime proofs, the complete release gate is:

```sh
make validate-v1
```

Stop feature work when that command passes and the screenshot set is recorded.

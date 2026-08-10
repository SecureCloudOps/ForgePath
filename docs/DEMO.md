# ForgePath v1 demo

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

The disposable `forgepath-kyverno` cluster admits the compliant Helm rendering
and rejects privileged, root, mutable-image, missing-resource, host-network,
and host-PID Pods. It repeats a rejection after restarting the admission
controller to prove fail-closed enforcement remains active.

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

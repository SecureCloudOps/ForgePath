# ForgePath static GitOps desired state

This directory is the Git-managed desired state for one environment (`local`)
and one service (`secure-fastapi-service`). It is intentionally static: no
command in this model creates a cluster, installs Argo CD, calls a Kubernetes
API, or publishes an artifact.

## Repository structure

```text
gitops/
├── applications/
│   └── secure-fastapi-service-local.yaml
├── environments/
│   └── local/
│       └── secure-fastapi-service/
│           └── values.yaml
├── projects/
│   └── forgepath-local.yaml
└── schemas/
    └── kubernetes/
        └── v1.32.0-standalone-strict/
```

The Application renders the application-owned chart at
`services/secure-fastapi-service/chart` with the local environment values. The
values contain the repository and exact `sha256` digest copied from validated
trusted-artifact metadata. A tag is neither required nor accepted by the chart.

The `forgepath-local` AppProject accepts only the ForgePath repository, the
in-cluster API destination, and the `secure-fastapi-service-local` namespace.
Its namespace allowlist contains only Rollout, AnalysisTemplate, Service,
ServiceAccount, NetworkPolicy, ResourceQuota, LimitRange, and the existing
monitoring/dashboard resources. Every cluster-scoped kind is blacklisted, which
also means this model does not install the Argo Rollouts or Prometheus Operator
CRDs. Secret is absent from the allowlist and rendered Secrets fail validation.
The Application creates only its fixed destination namespace and applies
version-pinned `restricted` Pod Security Admission labels through Argo CD
managed namespace metadata.

Role and RoleBinding are deliberately absent from the namespace allowlist. The
application has no Kubernetes API requirement, receives no RBAC grant, and runs
without an automounted token. Controller permissions remain installation-owned
prerequisites outside the application repository and are bound to separate
controller ServiceAccounts.

PolicyException is also absent from the allowlist and the AppProject destination
does not include the dedicated `forgepath-policy-exceptions` namespace. Exception
administration is a separate platform function with its own namespaced identity;
an application repository cannot create or modify its policy exceptions through
Argo CD.

There is one Application and no ApplicationSet because no current fan-out or
multi-environment requirement exists.

## Trust handoff and validation

The trusted artifact pipeline produces `.forgepath/trusted-artifact/metadata.json`
and publishes `TRUSTED` only after build, scan, SBOM, and signature validation.
That evidence directory is local and Git-ignored. In CI, provide the same
pipeline output and set `TRUSTED_ARTIFACT_METADATA` if it is stored elsewhere.

Run the offline desired-state gate with the pinned `mise` toolchain:

```sh
mise install
make validate-gitops-static
```

The gate:

1. validates the AppProject and Application restrictions;
2. checks the desired repository and digest against trusted metadata and the
   trusted marker;
3. lints and renders the Helm chart using the local GitOps values;
4. validates the rendered native resources with Kubeconform and repository-local
   Kubernetes 1.32 schema snapshots, without schema downloads;
5. evaluates the existing OPA/Rego rules with Conftest;
6. confirms every rendered container uses the exact trusted
   `repository@sha256:digest` reference; and
7. runs negative tests for digest mismatch, mutable references, unauthorized
   namespace and repository, Secret, cluster-scoped resources, and a
   policy-violating Helm render.

## Promotion

Promotion is a reviewed Git change to the environment `values.yaml`. Select an
artifact that the trusted-artifact pipeline has already accepted, then update
both `image.repository` and `image.digest` from that artifact's metadata. Run
`make validate-gitops-static` with that trusted metadata before merging. Argo CD
later observes the merged Git commit and reconciles it; it does not decide what
is trusted or perform promotion.

The Rollout uses the fixed sequence `5% -> analysis -> 25% -> analysis -> 50% ->
analysis -> 100%`. The stable Service retains the original name and stays pinned
to the last healthy ReplicaSet until all gates pass. Analysis consumes the
existing Prometheus availability burn-rate recording rule and fails closed on
missing data or query errors.

## Rollback

Rollback is a Git revert or a new reviewed commit that restores the repository
and digest of a previously trusted artifact. Validate that commit against the
corresponding trusted metadata before merging it. Do not use imperative Argo CD
rollback as the delivery model, because that would make live state diverge from
Git.

## Ownership boundaries

| Boundary | Owns |
| --- | --- |
| Application repository | Source code, tests, Dockerfile, and Helm chart |
| Trusted artifact pipeline | Build, scan, SBOM, signature, and trusted digest metadata |
| GitOps desired state | Environment configuration, approved artifact digest, Application, and AppProject |
| Argo CD | Reconciliation only |
| Argo Rollouts | ReplicaSet proportions, stable/canary Service selectors, and AnalysisRuns |
| Kubernetes | Runtime state only |

The destination namespace, Argo CD installation, Argo Rollouts controller/CRDs,
and Prometheus Operator CRDs are prerequisites owned outside this static model.
This repository does not apply them.

## Disposable runtime validation

After explicit cluster-mutation approval, `make validate-gitops-runtime`
validates this desired state on a disposable Kind cluster. Because runtime Git
revision and pruning tests must remain local and unpublished, the harness copies
the current committed repository into a temporary local Git remote and changes
only the live test copies of `sourceRepos` and `repoURL` to that remote. The
committed production source URL and the chart, values, destination, resource
allowlist, sync policy, and ownership boundaries are unchanged.

The harness pins Kind, the Kubernetes node image digest, Argo CD, the reviewed
installation manifest checksum, and every installation image digest. It applies
the final workload only through Argo CD, proves the trusted image digest at
runtime, then proves Backstage can read workload and Application status through
a namespaced `get`/`list`/`watch` identity. It removes the temporary Git data,
Backstage/proxy processes, and cluster on exit.

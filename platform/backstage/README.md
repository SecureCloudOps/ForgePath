# ForgePath Backstage

This is a local-first Backstage bootstrap for the existing ForgePath paved
path. It provides a catalog, TechDocs, a single software template, and
read-only workload visibility. It does not publish source, register generated
components remotely, deploy workloads, or replace ForgePath's renderer,
security checks, trusted-artifact flow, Git desired state, Argo CD, or Kyverno.

## Pinned bootstrap

The app targets Backstage `1.53.0`, Node.js `22.22.2`, Yarn `4.13.0`, MkDocs
`1.6.1`, and `mkdocs-techdocs-core` `1.7.0`.
[`bootstrap.lock.json`](bootstrap.lock.json) records the reviewed
`@backstage/create-app` `0.9.0` tarball and npm integrity value. Direct package
versions are exact and `yarn.lock` pins the resolved dependency graph.

The upstream generator was reviewed but not executed because its bootstrap
flow obtains an unpinned lockfile seed from a mutable branch. The checked-in
app follows the reviewed generator layout while keeping the complete dependency
graph local and immutable.

## Install and run locally

From the repository root:

```sh
mise install
cd platform/backstage
corepack yarn install --immutable
corepack yarn start
```

Backstage binds to loopback only. Guest authentication and the in-memory
database are suitable for this local proof, not for a shared deployment.

## Generate a service without publishing

Choose **Create**, then **Secure FastAPI service**. The only template action,
`forgepath:renderSecureFastapi`, invokes the repository-owned
`templates/secure-fastapi-service/render.py`. Output is confined to:

```text
.forgepath/generated/<service-name>/
```

The action refuses to overwrite non-empty output through the existing renderer.
The permission policy allows only this action to execute, so Backstage's built-in
publish and catalog-registration actions cannot run. Generated output includes
`catalog-info.yaml`, `mkdocs.yml`, TechDocs content, owner and system metadata,
and the same Helm chart and application source as the command-line paved path.

## Read-only Kubernetes and Argo CD visibility

The service catalog Component selects workloads with
`app.kubernetes.io/name=<service-name>` in the declared namespace. The
Kubernetes plugin is limited to workload resource types, disables pod deletion,
and the permission policy denies `kubernetes.proxy`.

The reference service depends on a related catalog Resource that uses the same
label selector in the `argocd` namespace. This lets Backstage read the matching
Application without granting cluster-wide list access; Backstage's Kubernetes
annotation accepts only one namespace per entity.

For an optional local proof, first select a Kubernetes identity that has only
`get`, `list`, and `watch` access to the intended workload resources and Argo
CD Applications. Then start a loopback-only kubectl proxy separately:

```sh
kubectl proxy --address=127.0.0.1 --port=8001 \
  --accept-hosts='^localhost$,^127\.0\.0\.1$'
```

Backstage can display Argo CD health and sync status by reading the existing
`argoproj.io/v1alpha1` `Application` custom resource through that related
Resource.
There is no Argo CD plugin, sync control, token, or alternate reconciliation
implementation in this bootstrap. Do not use a privileged kubeconfig: the
local proxy acts with the caller's Kubernetes credentials.

Starting the proxy or consulting a live cluster is not part of static
validation and must follow the repository's explicit Kubernetes approval
boundary.

## Validate

```sh
make validate-backstage-static
```

The target validates pins and configuration, installs the locked dependencies
immutably, type-checks, lints, tests, and builds the app, then renders a local
service and compares it with the existing paved-path contract. It does not
contact a Kubernetes API or publish anything.

After explicit approval for disposable cluster creation and Kubernetes API
mutation, the executable runtime proof is:

```sh
make validate-backstage-runtime
```

The harness forces the proxy to impersonate a dedicated service account and
proves Backstage Catalog/TechDocs metadata, ready workload status, a Synced and
Healthy Application, and denial of Secrets, delete, exec, mutation, sync,
credential access, and Backstage's raw Kubernetes proxy permission.

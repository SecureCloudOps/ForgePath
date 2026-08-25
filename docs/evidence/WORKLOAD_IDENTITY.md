# Workload-identity validation evidence

The ForgePath workload-identity increment was runtime-proven on 2026-08-23 and
is frozen. The proof used the source checkpoint `55bcf40`, Kind v0.32.0,
Kubernetes v1.32.11, and the previously validated immutable application digest
`sha256:d971dc0d119a17e9b361906b67eb0fbada2cac6d197ec338620ecfd7e1eeba2c`.

## Static contract

```sh
mise exec -- make validate-workload-identity-static
```

The gate proved that the reference chart and paved-path template each render one
dedicated application ServiceAccount, disable token automount on both the
ServiceAccount and Pod, contain no explicit service-account-token projection,
and render no Role, RoleBinding, ClusterRole, or ClusterRoleBinding. The Argo CD
AppProject continues to deny application-delivered RBAC, Secrets, and every
cluster-scoped resource.

The application has no Kubernetes API requirement, so its required application
permission set remains empty.

## Runtime sequence

After explicit approval, the disposable proof ran with:

```sh
mise exec -- ./scripts/validate-workload-identity-runtime.sh
```

The normal application became ready without an automounted token. A dedicated
test probe then used an explicitly projected, ten-minute token for the same
application ServiceAccount solely to make the denied API call:

```text
EVIDENCE workload API attempt: HTTP 403: list Secrets denied for application ServiceAccount
```

Representative `kubectl auth can-i` results from the complete negative matrix
were:

```text
EVIDENCE auth can-i identity-secure-fastapi-service list secrets in forgepath-identity-test: no
EVIDENCE auth can-i identity-secure-fastapi-service patch deployments.apps in forgepath-identity-test: no
EVIDENCE auth can-i identity-secure-fastapi-service patch rollouts.argoproj.io in forgepath-identity-test: no
EVIDENCE auth can-i identity-secure-fastapi-service patch analysisruns.argoproj.io in forgepath-identity-test: no
EVIDENCE auth can-i identity-secure-fastapi-service patch policies.kyverno.io in forgepath-identity-test: no
EVIDENCE auth can-i identity-secure-fastapi-service patch clusterpolicies.kyverno.io in forgepath-identity-test: no
EVIDENCE auth can-i identity-secure-fastapi-service patch networkpolicies.networking.k8s.io in forgepath-identity-test: no
EVIDENCE auth can-i identity-secure-fastapi-service create pods in forgepath-identity-test: no
EVIDENCE auth can-i identity-secure-fastapi-service create serviceaccounts/token in forgepath-identity-test: no
EVIDENCE auth can-i identity-secure-fastapi-service impersonate serviceaccounts in forgepath-identity-test: no
EVIDENCE auth can-i identity-secure-fastapi-service impersonate users in forgepath-identity-test: no
EVIDENCE auth can-i identity-secure-fastapi-service impersonate groups in forgepath-identity-test: no
```

For Secrets, Deployments, Rollouts, AnalysisRuns, Kyverno Policy and
ClusterPolicy, and NetworkPolicy, the matrix checked `get`, `list`, `watch`,
`create`, `update`, `patch`, `delete`, and `deletecollection`; every answer was
`no`. The minimal proof did not install the Argo Rollouts or Kyverno CRDs.
Kubernetes authorization review still evaluated the fully qualified API
group/resource attributes, while `kubectl` transparently reported that those
resource types were absent from discovery.

An actual privileged-Pod submission under the application identity failed at
RBAC before admission:

```text
Error from server (Forbidden): error when creating "tests/kyverno/runtime/privileged-pod.yaml": pods is forbidden: User "system:serviceaccount:forgepath-identity-test:identity-secure-fastapi-service" cannot create resource "pods" in API group "" in the namespace "forgepath-identity-test"
```

## Controller ownership boundary

The harness created a separate platform reconciler ServiceAccount and a Role
limited to `get` and `patch` on the single named Deployment. Inspection of every
RoleBinding subject in the namespace returned:

```text
EVIDENCE binding isolation: application ServiceAccount RoleBinding subject count = 0
```

Authorization and action evidence was:

```text
EVIDENCE auth can-i forgepath-platform-reconciler patch deployments.apps/identity-secure-fastapi-service in forgepath-identity-test: yes
EVIDENCE auth can-i forgepath-platform-reconciler patch deployments.apps/not-platform-owned in forgepath-identity-test: no
EVIDENCE auth can-i forgepath-platform-reconciler update deployments.apps/identity-secure-fastapi-service in forgepath-identity-test: no
EVIDENCE auth can-i forgepath-platform-reconciler create deployments.apps in forgepath-identity-test: no
EVIDENCE auth can-i identity-secure-fastapi-service patch deployments.apps in forgepath-identity-test: no
EVIDENCE scoped reconciler patch: named Deployment readyReplicas = 2
```

The actual application-side `kubectl patch` was forbidden. The client surfaced
the denial on its prerequisite Deployment read, and the separate authorization
review also explicitly returned `no` for `patch`. The reconciler identity then
patched the named Deployment successfully and Kubernetes reported two ready
replicas. It could not patch another Deployment, update or create Deployments,
read Secrets, or patch NetworkPolicies.

## Isolation and cleanup

The harness refused a pre-existing `forgepath-workload-identity` target, checked
the exact `kind-forgepath-workload-identity` context before every mutation,
loaded only the validated digest, and removed only that disposable cluster.
Its final assertion reported:

```text
PASS cleanup deleted the disposable cluster and restored the original context
```

An independent post-run check confirmed that the target cluster was absent and
the current context exactly matched the value recorded before the run. The
unrelated pre-existing Kind cluster remained present and untouched.

No token value, kubeconfig, Secret value, credential, or environment dump was
printed or retained.

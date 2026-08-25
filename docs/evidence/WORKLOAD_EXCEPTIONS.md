# Workload-exception validation evidence

The controlled policy-exception boundary was runtime-proven on 2026-08-23 with
Kind v0.32.0, Kubernetes v1.32.11, and Kyverno v1.18.2. The proof used only the
disposable `forgepath-workload-exceptions` cluster and restored the caller's
original Kubernetes context after deleting it. The validated source checkpoint
was `e0e97bb7b625bb8dda49e227dd20abeefbbdc153`.

## Boundary contract

The exception admission policy requires:

- non-empty owner and justification annotations;
- one exact ClusterPolicy name and one exact rule name;
- one exact Pod name and one exact namespace, duplicated in binding annotations;
- an RFC3339 expiry later than admission time and a PolicyException time
  condition bound to that exact timestamp; and
- approver, approval timestamp, and approval-reference annotations.

It rejects wildcards, selectors, subjects, missing scope, missing or expired
timestamps, multiple policies, and multiple rules. Limiting each exception to a
single rule prevents one request from combining unrelated control reductions.
The exception boundary is validation-only, enforced, and fail-closed.

The administration manifest creates the dedicated
`forgepath-policy-exceptions` namespace and a tokenless
`forgepath-policy-exception-admin` ServiceAccount. Its Role has no wildcard and
grants namespaced CRUD only for `policyexceptions.kyverno.io`. The application
AppProject cannot target the exception namespace or deliver PolicyException or
RBAC resources.

Static proof:

```sh
mise exec -- make validate-workload-exceptions-static
```

The gate admitted the valid one-Pod/one-rule fixture; rejected missing owner,
justification, approval, expiry, already-expired expiry, wildcard policy,
wildcard workload, selector, missing namespace, multiple controls, and multiple
policies; then proved the exact Pod could skip only `forbid-host-network` while
a neighboring Pod and the unrelated `forbid-host-pid` rule remained denied.

## Runtime sequence

After explicit cluster-mutation approval:

```sh
mise exec -- ./scripts/validate-workload-exceptions-runtime.sh
```

The API-server proof produced this sequence:

```text
PASS workload denied normally before an exception existed
PASS valid narrow exception applied with expiry 2026-08-23T21:06:55Z
PASS only the exact workload/control was allowed; neighbor and hostPID remained denied
PASS application identity could not modify the exception
PASS exception expired in place and the workload was denied again
PASS expired exception object removed by the platform identity
```

The admitted exception affected only:

```text
forgepath-workload-security/forbid-host-network:
  forgepath-exception-test/exempted-pod
```

The `forgepath-exception-demo-app` ServiceAccount returned `no` for `get`,
`list`, `watch`, `create`, `update`, `patch`, and `delete` on PolicyExceptions in
the administration namespace. Its actual patch attempt was forbidden. The
platform administrator could create and delete PolicyExceptions in its own
namespace, but could not create one in the workload namespace, create a
ClusterPolicy, or create a Pod.

The persisted evidence recorded:

```text
owner=platform-security
justification=Temporary compatibility test for one named workload.
approved_by=platform-security-reviewer
approval_reference=FORGEPATH-EXC-0001
approved_at=2026-08-23T21:06:25Z
expires_at=2026-08-23T21:06:55Z
observed_expired_at=2026-08-23T21:06:56Z
exception_still_present=true
removed_at=2026-08-23T21:06:57Z
affected=forgepath-workload-security/forbid-host-network:forgepath-exception-test/exempted-pod
```

The exception remained stored after its scheduled expiry but its bound time
condition stopped matching, and the previously exempted Pod was immediately
denied again. The administrator then deleted the expired object. The harness
retained only non-sensitive results beneath the ignored
`.forgepath/workload-exception-evidence/20260823T210528Z/` directory. It did not
record kubeconfig data, tokens, Secret values, credentials, or environment
dumps.

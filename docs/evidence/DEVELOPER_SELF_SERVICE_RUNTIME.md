# Developer self-service runtime evidence

## Failed proof preserved: ownership conflict

The first approved runtime attempt on 2026-08-24 intentionally remains part of
the ForgePath case study. Argo CD compared Git revision
`87356f5c69f099804df62507ec20300dcd503924` and remained `OutOfSync` with
health `Missing` because its generated namespace task was rejected:

```text
resource :Namespace is not permitted in project forgepath-local
```

The application AppProject denied all cluster-scoped resources, while the
Application enabled `CreateNamespace=true`. The security boundary therefore
prevented unsafe reconciliation. No application workload resource was applied,
the disposable `forgepath-progressive-delivery` cluster was deleted, and the
original Kubernetes context was restored. The retained
`failure-application.json` SHA-256 is
`1a675aeb53a980cbb3169b50071258c7d5ef46832832b772128f705a099d4743`.

ForgePath did not add Namespace to the application AppProject. The ownership
model was redesigned instead:

```text
platform-owned namespace lifecycle and security boundary
  -> application-owned namespaced workload and SLO resources
```

## Regression controls

The remediation adds fail-closed static checks that reject:

- any `Namespace` rendered by an application chart;
- any Argo CD Application containing `CreateNamespace=true`;
- any application AppProject that grants Namespace or another cluster-scoped
  permission;
- a destination outside the one exact pre-provisioned namespace; and
- a platform namespace prerequisite missing restricted PSA ownership metadata.

ResourceQuota, LimitRange, default-deny networking, DNS egress, Prometheus
ingress, and PSA labels now live in the platform-owned namespace prerequisite.
The application chart no longer renders those resources and its AppProject no
longer permits them.

## Approved rerun

Pending. The rerun must prove the governed namespace exists before the single
developer request, Argo CD reconciles only namespaced application resources,
the Rollout becomes Healthy, Prometheus exposes the SLO, and the measured
request-to-healthy duration is recorded without requiring developer `kubectl`.

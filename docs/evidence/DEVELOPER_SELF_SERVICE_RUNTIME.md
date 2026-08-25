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

The first remediation rerun provisioned the governed namespace, generated the
local repositories and PR-ready branches, reconciled the Rollout Healthy in
`94.533s`, and proved Prometheus visibility with 322 canary errors, burn rate
`49.82977406375731`, and the fast-burn alert firing. It then failed safely when
the namespace-scoped Rollouts controller could not query Prometheus through the
platform default-deny policy; the AnalysisRun ended `Error` on a ten-second
timeout. The cluster was deleted and the original context restored.

The follow-up keeps default deny and adds one platform-owned egress exception:
only the Rollouts controller pod label may reach only Prometheus pods in the
`monitoring` namespace on TCP 9090.

The final approved rerun at remediation revision
`211bd353248f0481c9e7d7b11d8a3596480f4ea6` passed:

1. the platform prerequisite provisioned the exact governed namespace, PSA,
   quota, limits, and four network policies before the developer request;
2. one local self-service action created service and GitOps repositories plus
   PR-ready branches;
3. Argo CD reconciled only the eight namespaced application resources and
   reported the initial Rollout Healthy;
4. Prometheus observed the SLO burn and fast-burn alert;
5. the AnalysisRun reached `Failed`, not `Error`, and the defective revision
   was aborted at 5% while stable v1 remained selected; and
6. a Git revert reconciled the Application back to `Synced/Healthy` before the
   disposable cluster was deleted and the original context restored.

### Developer-experience measurements

| Metric | Observed |
| --- | ---: |
| Request to repository | 0.021 seconds |
| Request to first PR-ready branch | 0.099 seconds |
| Request to completed local publication | 0.162 seconds |
| Request to Healthy service | 127.114 seconds |
| Manual developer actions | 1 |
| Automatically inherited controls | 9 |
| Kubernetes manifests the developer must understand | 0 |
| Developer needs `kubectl` | No |
| Developer must understand Argo CD, Kyverno, Rollouts, Prometheus, or NetworkPolicy | No |

The final Application was `Synced/Healthy`; the failed AnalysisRun measured a
burn value of `50.13873609012707`. Evidence is retained locally under
`.forgepath/progressive-delivery-evidence/20260824T143958Z/`. Key SHA-256 values:

- `developer-experience.json`:
  `e78eb45b6f9af5bff32b3323df92b402712ed91d607dc2ff7f4cbc3ae800bb47`
- `final-application.json`:
  `080034868dc0c67850d9eb2f837754f96593f5e9b0c8eeec4b28732624c582b9`
- `failed-analysisrun.json`:
  `a0d8182113253e90c95f4f612f7db5bb663a17372c7bc8958ad9af1a67491b1f`
- `cleanup.txt`:
  `ef19bdf9e4d9ae82a6f6c770c0ecce5eeb8e59cd39271988dfd0ca0d2b8ef0e3`

This proof used local publication simulation and the committed ForgePath
reference GitOps repository in the same timed run; it did not claim a live
GitHub API or remote pull-request latency measurement. The trusted runtime image
was the previously validated digest whose build source was
`2ff10f069979d9c42d3ff5a3e39b8f1be6e90612`.

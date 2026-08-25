# ForgePath v2 architecture

ForgePath implements one secure paved path from developer intent to a measured,
recoverable Kubernetes service. Every solid delivery arrow below is implemented;
every material trust boundary has a static or disposable runtime gate.

## System flow

```mermaid
flowchart LR
  developer["Developer"] --> backstage["Backstage"]
  backstage --> preflight["Authenticated request<br/>allowlisted preflight"]
  preflight --> renderer["Repository-owned renderer"]
  renderer --> repository["Private service repository<br/>PR-ready onboarding branch"]
  repository --> catalog["secure-fastapi-service<br/>Catalog + TechDocs"]

  renderer --> validation["Tests · SAST · secrets · dependencies<br/>container and manifest scans"]
  validation --> policy["OPA / Conftest policy gate"]
  policy --> artifact["OCI image + SBOM + scan report<br/>signature + provenance + digest"]
  artifact --> desired["Git desired state<br/>immutable digest"]
  desired --> application["Argo CD Application"]
  application --> rollout["Argo Rollout<br/>5% → 25% → 50% → 100%"]
  prometheus["Prometheus SLO recordings<br/>and burn-rate alerts"] --> rollout
  rollout --> admission["Kyverno admission"]
  admission --> workload["Kubernetes workload"]

  reader["backstage-runtime-reader<br/>get · list · watch only"] -.-> workload
  reader -.-> application
  backstage -. "loopback proxy<br/>forced impersonation" .-> reader
```

The portal creates intent; it does not become a deployment controller. The
repository-owned renderer is the shared implementation behind portal and CLI
flows, while Git remains the only source of application desired state.

## Trust boundaries and control ownership

```mermaid
flowchart TB
  subgraph dev["Developer boundary"]
    request["Authenticated request"]
    status["Catalog, TechDocs and status"]
  end

  subgraph platform["Platform control plane"]
    preflight["Preflight + renderer"]
    ci["CI validation"]
    supply["Trusted-artifact pipeline"]
    namespace["Platform-owned namespace<br/>PSA · quota · limits · network policy"]
    exceptions["Exception administrator<br/>one Pod · one rule · expiry"]
  end

  subgraph delivery["GitOps delivery boundary"]
    git["Reviewed Git state"]
    argo["Restricted Argo CD AppProject"]
    progressive["Argo Rollouts + Prometheus"]
  end

  subgraph runtime["Kubernetes runtime boundary"]
    kyverno["Fail-closed Kyverno admission"]
    app["Namespaced application resources"]
    readonly["Read-only Backstage identity"]
  end

  request --> preflight --> ci --> supply --> git --> argo --> progressive --> kyverno --> app
  namespace --> app
  exceptions --> kyverno
  app -. "selected status only" .-> readonly -.-> status
```

| Boundary | Allowed responsibility | Explicitly excluded |
| --- | --- | --- |
| Backstage | Identity-aware validation, one constrained create action, Catalog/TechDocs and read-only status | Image builds, cluster mutation, Argo CD credentials or sync controls |
| Publisher | Allowlisted private service/GitOps repositories and PR-ready branches | Arbitrary organizations, public repositories or direct production mutation |
| CI validation | Reject unsafe source, dependencies, images and manifests | Promotion after a failed gate |
| Trusted-artifact pipeline | Bind OCI archive, scan, SPDX SBOM, signature, provenance and digest | Mutable tags or retained private signing keys |
| Git | Hold reviewed desired state and the approved immutable digest | Hidden imperative rollback state |
| Argo CD | Reconcile and self-heal inside one restricted AppProject | Cluster-scoped application ownership |
| Platform namespace owner | Own namespace lifecycle, PSA, quota, limits and network policy | Application-owned namespace creation |
| Argo Rollouts | Scale stable/canary ReplicaSets and fail closed on SLO analysis | Automatic Git recovery |
| Kyverno | Enforce independent admission policy | Silent bypasses or broad exclusions |
| Exception administrator | Time-bounded one-Pod/one-rule PolicyExceptions | Wildcards, multiple controls or application-owned exceptions |
| `backstage-runtime-reader` | `get`, `list`, `watch` on selected workload and Application objects | Secrets, exec, delete, mutation, token requests or sync |

## Progressive delivery and recovery

```mermaid
stateDiagram-v2
  [*] --> Healthy: stable revision
  Healthy --> Canary5: Git promotes candidate digest
  Canary5 --> Canary25: SLO analysis passes
  Canary25 --> Canary50: SLO analysis passes
  Canary50 --> Healthy: final analysis passes
  Canary5 --> Contained: burn-rate analysis fails
  Canary25 --> Contained: burn-rate analysis fails
  Canary50 --> Contained: burn-rate analysis fails
  Contained --> AwaitApproval: stable Service remains selected
  AwaitApproval --> GitRecovery: human approves recovery commit
  GitRecovery --> Reconciled: Argo CD syncs reviewed state
  Reconciled --> Healthy: Rollout and verification pass
```

The basic canary is replica weighted and has no traffic router. On abort, the
controller contains the candidate promptly; the incident harness therefore
captures candidate logs and configuration immediately after alert
acknowledgment, before post-abort scale-down.

Recovery is a reviewed Git change. The runtime exercise does not imperatively
roll back Argo CD and does not create the recovery commit until the human
checkpoint is satisfied.

## Evidence flow

```mermaid
flowchart LR
  checks["Static and runtime gates"] --> raw["Timestamped raw evidence"]
  raw --> hashes["SHA-256 manifest"]
  hashes --> record["Permanent evidence record"]
  record --> index["Evidence index"]
  record --> postmortem["Incident postmortem"]
  postmortem --> actions["Corrective actions"]
  actions --> closure["Independent closure evidence"]
  closure --> index
```

Raw runtime bundles are intentionally ignored by Git because they can be large
and environment-specific. Permanent records retain measurements, exact hashes,
source revisions, cleanup results and raw bundle locations. Failed proofs stay
visible and are not rewritten into successful results.

## Reconciliation and admission details

The application AppProject permits only the reference repository, exact target
namespace and required namespaced kinds. Platform automation provisions the
governed namespace separately. Argo CD proves initial sync, drift repair,
revision reconciliation, create and prune behavior.

Kyverno complements the pre-deployment OPA gate. Runtime proofs admit the
compliant chart and reject privileged, root, mutable-image, missing-resource,
host-network, host-PID, unsigned and unattested requests through the Kubernetes
API. Narrow exceptions never edit the source policy and immediately revert to
denial when removed or expired.

See the [evidence index](evidence/README.md) for claim-to-proof mapping and the
[incident postmortem](evidence/postmortems/INC-20260824T152814Z.md) for the
measured recovery path.

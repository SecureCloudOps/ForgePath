# ForgePath evidence index

This index maps ForgePath v2 claims to permanent, reviewable records. Runtime
bundles under `.forgepath/` are local and Git-ignored; the records below retain
their source revision, measurements, selected hashes and cleanup result so a
reviewer can distinguish static proof, runtime proof and historical failure.

## Portfolio proof map

| Capability | Evidence record | Proof type | Status |
| --- | --- | --- | --- |
| End-to-end v1 paved path | [V1 validation](V1_VALIDATION.md) | Disposable runtime | Passed |
| Prometheus SLO model | [V2 observability validation](V2_VALIDATION.md) | Static + referenced runtime | Passed |
| Progressive delivery | [Phase 2 progressive delivery](PHASE_2_PROGRESSIVE_DELIVERY.md) | Static + disposable runtime | Passed |
| Workload metadata and trusted admission | [Platform guardrails](PLATFORM_GUARDRAILS.md) | Static + disposable runtime | Passed |
| Namespace isolation | [Namespace isolation](NAMESPACE_ISOLATION.md) | Static + disposable runtime | Passed |
| Workload identity | [Workload identity](WORKLOAD_IDENTITY.md) | Static + disposable runtime | Passed |
| Narrow policy exceptions | [Workload exceptions](WORKLOAD_EXCEPTIONS.md) | Static + disposable runtime | Passed |
| Developer golden path | [Developer self-service](DEVELOPER_SELF_SERVICE.md) | Static | Passed |
| Developer journey and DX metrics | [Developer self-service runtime](DEVELOPER_SELF_SERVICE_RUNTIME.md) | Disposable runtime, failed proofs retained | Passed after remediation |
| Operational response | [Incident exercise](INCIDENT_EXERCISE.md) | Disposable runtime, failed proof retained | Passed after harness correction |
| Incident analysis | [INC-20260824T152814Z postmortem](postmortems/INC-20260824T152814Z.md) | Generated + independently hash-checked | Complete |
| Clean-source supply-chain provenance | [Trusted-artifact provenance](TRUSTED_ARTIFACT_PROVENANCE.md) | Clean rebuild + local verification | CA-4 closed |

## Headline measurements

| Measure | Recorded result | Source |
| --- | ---: | --- |
| Manual developer actions | 1 | [Developer self-service runtime](DEVELOPER_SELF_SERVICE_RUNTIME.md) |
| Automatically inherited controls | 9 | [Developer self-service runtime](DEVELOPER_SELF_SERVICE_RUNTIME.md) |
| Request to repository | 0.021s | [Developer self-service runtime](DEVELOPER_SELF_SERVICE_RUNTIME.md) |
| Request to Healthy service | 127.114s | [Developer self-service runtime](DEVELOPER_SELF_SERVICE_RUNTIME.md) |
| Maximum defective-canary exposure | 5% (1/20 replicas) | [Incident exercise](INCIDENT_EXERCISE.md) |
| MTTD / MTTA / MTTR | 270.265s / 8.543s / 374.620s | [Incident exercise](INCIDENT_EXERCISE.md) |
| Failed synthetic requests | 1,606 / 32,120 | [Incident exercise](INCIDENT_EXERCISE.md) |
| Error budget consumed | 100% of the 1-hour demo budget | [Incident exercise](INCIDENT_EXERCISE.md) |
| Rollback control | Human-approved Git recovery | [Incident postmortem](postmortems/INC-20260824T152814Z.md) |

## How to read the evidence

- **Static** means the proof renders, validates or evaluates repository inputs
  without contacting Kubernetes.
- **Disposable runtime** means a named Kind cluster was created only after
  approval, exact context was verified, and cleanup/context restoration was
  recorded.
- **Failed proof retained** means the unexpected result remains part of the
  engineering record; it was not edited away when the workflow was corrected.
- **Local raw evidence** is referenced by path and hashes but is not committed.
  This keeps large environment-specific data out of source control without
  weakening the permanent claim record.

## Raw local bundle map

| Exercise | Local path | Permanent interpretation |
| --- | --- | --- |
| Developer-runtime ownership conflict | `.forgepath/progressive-delivery-evidence/` (failed run described in record) | [Developer runtime evidence](DEVELOPER_SELF_SERVICE_RUNTIME.md) |
| Developer-runtime final proof | `.forgepath/progressive-delivery-evidence/20260824T143958Z/` | [Developer runtime evidence](DEVELOPER_SELF_SERVICE_RUNTIME.md) |
| Incident harness discovery | `.forgepath/progressive-delivery-evidence/20260824T150948Z/` | [Incident exercise](INCIDENT_EXERCISE.md) |
| Completed incident | `.forgepath/progressive-delivery-evidence/20260824T152814Z/` | [Postmortem](postmortems/INC-20260824T152814Z.md) |
| Current trusted artifact | `.forgepath/trusted-artifact/` | [Provenance closure](TRUSTED_ARTIFACT_PROVENANCE.md) |

The raw incident manifest contains 18 diagnostic artifacts. Its hashes were
recomputed after cleanup and matched. The provenance closure has a separate
tracked [corrective-action manifest](manifests/ca4-trusted-artifact.json).

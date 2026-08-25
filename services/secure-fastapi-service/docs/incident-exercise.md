# Incident exercise

This is an operational, evidence-producing exercise—not a tabletop:

```text
healthy service -> defective release -> alert fires -> responder acknowledges
  -> logs + metrics + Rollout + Git evidence -> cause identified
  -> human-approved Git revert -> Argo CD reconciliation -> service restored
  -> measured postmortem
```

The exercise uses the existing controlled 503 fixture, accelerated demo SLO
windows, replica-weighted Argo Rollout, Prometheus analysis, and a temporary
local Git remote. It never patches or imperatively promotes the workload. The
stable Service remains on the healthy ReplicaSet. Candidate pod configuration
and logs are captured after acknowledgment while analysis is still running,
because a basic canary is scaled down promptly after an abort.

## Safety and prerequisites

The runtime target creates and deletes the disposable Kind cluster
`forgepath-progressive-delivery`, installs pinned controllers, commits only to a
temporary local Git remote, and writes non-sensitive evidence beneath
`.forgepath/progressive-delivery-evidence/`. It refuses a pre-existing cluster,
verifies the exact context, restores the original context, and cleans up.

Obtain explicit approval immediately before running the target because it
creates and mutates the disposable cluster. Docker and the pinned `mise`
toolchain must be available, and the trusted artifact workflow must already
have produced the local artifact referenced by GitOps values.

First validate the exercise contract without contacting a cluster:

```sh
make validate-incident-exercise-static
```

Then, after the required approval, run the operational exercise:

```sh
make validate-incident-exercise-runtime
```

The harness pauses twice:

1. When `ForgePathSLOFastBurn` is first observed firing, type
   `ACK <responder>` to record acknowledgment and begin triage.
2. After logs, Prometheus results, Rollout/AnalysisRun state, Kubernetes events,
   Argo CD state, and the Git diff have been gathered, review the printed
   diagnosis and type `APPROVE GIT REVERT <approver>` to authorize recovery.

The second checkpoint makes the recovery explicitly human-approved. The
existing `make validate-progressive-delivery-runtime` target remains an
automated regression proof and records its rollback control as `automatic`.

## Measurement contract

All timestamps use the runtime host's UTC clock. The report derives metrics
from raw artifacts instead of accepting operator-entered values.

| Measure | Exact definition | Authoritative evidence |
| --- | --- | --- |
| MTTD | First observation of the firing alert minus the first synthetic 5xx | `prometheus-alert.json`, `request-events.csv` |
| MTTA | Responder acknowledgment minus first alert observation | acknowledgment timestamp in `incident-context.json` |
| MTTR | Verified restoration minus the first synthetic 5xx | `request-events.csv`, `final-application.json`, `final-rollout.json`, successful verification request |
| Maximum canary exposure | Maximum `updatedReplicas / spec.replicas` in captured Rollout samples | `rollout-samples.jsonl` |
| Failed requests | Exact count of recorded synthetic HTTP 5xx responses | `request-events.csv` |
| Error budget consumed | `1 - forgepath:slo_error_budget_remaining:ratio` for the 1-hour demo window | `prometheus-error-budget.json` |
| Rollback control | `human-approved` for this exercise; `automatic` for the regression harness | approval checkpoint and `incident-context.json` |

This local exercise measures controlled synthetic impact. It does not claim
production customer impact, notification-delivery latency, or multi-region
behavior.

## Evidence-led diagnosis

The responder should establish facts before approving recovery:

1. `prometheus-alert.json` proves the fast-burn alert is firing, while
   `prometheus-burn-rate.json` and `prometheus-canary-errors.json` quantify the
   SLO breach.
2. `canary-logs.txt` correlates `/_test/failure` with HTTP 503 responses, and
   `canary-pods.json` shows the fixture environment on the candidate ReplicaSet.
3. `defective-release.patch` identifies the Git desired-state change that
   enabled the fixture.
4. `failed-analysisrun.json` proves the burn-rate gate failed;
   `aborted-rollout.json` proves the Rollout stopped at the first gate and the
   stable ReplicaSet did not change.
5. `aborted-application.json` links the observed runtime state to the defective
   Git revision. Kubernetes events preserve the controller sequence.

The confirmed cause is therefore the controlled fixture enabled by the
defective Git revision. Resource saturation, readiness failure, network policy,
and unrelated configuration are rejected by the collected evidence rather than
left as unverified explanations.

## Postmortem output

On successful restoration, the harness generates:

- `incident-metrics.json` with MTTD, MTTA, MTTR, exposure, request, budget, and
  rollback-control measurements;
- `evidence-manifest.json` with every diagnostic artifact, observation, and
  SHA-256 hash; and
- `postmortem.md` with executive summary, impact, timeline, detection, root
  cause, contributing factors, recovery, corrective actions, detection gaps,
  and unverified hypotheses.

The report renderer fails closed on missing files, path traversal, inconsistent
timestamps, unresolved incidents, malformed traffic, or absent Rollout samples.

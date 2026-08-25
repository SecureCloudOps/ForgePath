# Operational incident-exercise evidence

ForgePath ran the evidence-producing defective-canary exercise twice on
2026-08-24. The first run exposed an incorrect evidence-retention assumption and
failed closed. The corrected run completed the full operational sequence and
generated incident `INC-20260824T152814Z`.

Both runs used only the disposable Kind cluster
`forgepath-progressive-delivery` and a temporary local Git remote. Neither run
pushed to a remote repository or accessed an existing cluster. Cleanup evidence
for both runs confirms that the disposable cluster was deleted and the exact
original Kubernetes context was restored.

## First run: preserved failed proof

Raw local evidence is retained at
`.forgepath/progressive-delivery-evidence/20260824T150948Z/`. This ignored bundle
has not been rewritten or removed.

The service reached healthy v1 on stable ReplicaSet `5c46bc7978`. The defective
revision then produced 1,627 HTTP 503 responses among 32,580 recorded synthetic
requests. The first recorded failure was at `2026-08-24T15:12:05.843599Z`.
Prometheus returned a firing fast-burn alert at
`2026-08-24T15:16:20.599000Z`, and the AnalysisRun failed at 49.9648x burn.
The Rollout aborted at the first analysis gate and retained the healthy stable
Service.

The harness then attempted to collect candidate logs after abort. Kubernetes
events showed that the controller scaled candidate ReplicaSet `6474858754` from
one replica to zero at `2026-08-24T15:18:01Z`, so the pod selector returned no
resources. The run stopped before Git recovery or postmortem generation. It did
not suppress the missing evidence or manufacture a successful result.

The cause was a false assumption in the chart and runbook:
`abortScaleDownDelaySeconds` is not applicable to a basic replica-weighted
canary without traffic routing. The correction:

1. captures candidate pod configuration, logs, Rollout state, Argo CD state,
   Prometheus results, and the Git diff immediately after acknowledgment while
   analysis is still running;
2. captures the failed AnalysisRun, controller events, and containment state
   after abort;
3. removes the ineffective field from the reference and generated charts; and
4. updates static assertions and both progressive-delivery runbooks so this
   behavior cannot silently regress.

Selected retained evidence hashes:

| Artifact | SHA-256 |
| --- | --- |
| `request-events.csv` | `0ecde5148388091115b2d506ca58f4b1a0f91759d2a5141318d66a2de7378bbb` |
| `failed-analysisrun.json` | `7d6844837258d14794374fd01513e6cdf264403d20a32de7d4808ef62e82de2f` |
| `aborted-rollout.json` | `88bc2bb14ced36e75bc53d151d8cefad7d57d9c279caf7f599d24a9bb8a19bc7` |
| `workload-events.json` | `458244d672d79566b73a269b54069b84fbd4bedec7218244bb66c853f8219b53` |
| `cleanup.txt` | `ef19bdf9e4d9ae82a6f6c770c0ecce5eeb8e59cd39271988dfd0ca0d2b8ef0e3` |

## Corrected run: complete operational proof

Raw local evidence is retained at
`.forgepath/progressive-delivery-evidence/20260824T152814Z/`. The permanent
postmortem is [INC-20260824T152814Z](postmortems/INC-20260824T152814Z.md).

The completed sequence was:

```text
healthy v1 -> defective Git revision -> 5% canary degradation
  -> ForgePathSLOFastBurn firing -> human acknowledgment
  -> live candidate logs/config + Prometheus + Rollout + Argo CD + Git diagnosis
  -> failed AnalysisRun -> Rollout containment
  -> human-approved temporary Git revert -> Argo CD Synced/Healthy
  -> Rollout Healthy -> verification request succeeds
  -> measured postmortem -> verified cleanup
```

### Measured result

| Measure | Result |
| --- | ---: |
| MTTD | 270.265 seconds |
| MTTA | 8.543 seconds |
| MTTR | 374.620 seconds |
| Maximum canary exposure | 5% (1/20 replicas) |
| Failed synthetic requests | 1,606 of 32,120 |
| Observed synthetic availability | 95.000% |
| Error budget consumed | 100.000% of the 1-hour demo budget |
| Rollback control | Human-approved |

Prometheus observed a 49.9635x burn rate before AnalysisRun
`secure-fastapi-service-secure-fastapi-service-6474858754-2-1` failed. The
stable Service remained on ReplicaSet `5c46bc7978`. Recovery revision
`834ba5fef90d394c02de853f28d4c8bd681db4ad` reconciled Argo CD to
`Synced/Healthy`; the final Rollout was `Healthy` with 20/20 ready replicas on
the original stable hash.

The generated `evidence-manifest.json` contains 18 diagnostic artifacts. Every
recorded SHA-256 was independently recomputed after cleanup and matched. The
raw `cleanup.txt` confirms cluster deletion and exact context restoration; a
separate local check found no remaining Kind cluster.

## Known gaps and corrective actions

- The exercise polls Prometheus directly and does not prove Alertmanager paging
  delivery.
- Traffic is synthetic and does not validate client retry or regional behavior.
- CA-4 is closed. The trusted artifact was rebuilt from clean source at revision
  `211bd353248f0481c9e7d7b11d8a3596480f4ea6`; retained metadata now records
  `source_dirty=false`, and GitOps pins the rebuilt digest. See the
  [provenance closure](TRUSTED_ARTIFACT_PROVENANCE.md).
- Establish reviewed targets for MTTD, MTTA, MTTR, maximum exposure, failed
  requests, and error-budget consumption before using these values as a release
  gate.

No unverified root-cause hypotheses remain for the controlled incident. The
first run's harness failure and the successful service incident remain distinct
in the retained evidence.

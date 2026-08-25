# Progressive delivery

This service is delivered by an Argo Rollouts `Rollout` using replica-weighted
canary steps:

```text
5% -> SLO analysis -> 25% -> SLO analysis -> 50% -> SLO analysis -> 100%
```

The stable Service keeps the original release name and selects only the last
healthy ReplicaSet. The `-canary` Service selects only the candidate ReplicaSet.
Without a traffic router, weights are pod proportions rather than request-router
guarantees, so the chart requires replica counts in multiples of 20. Test clients
must send the corresponding request ratio to the two Services.

Every analysis queries the existing availability burn-rate recording rule in
Prometheus. Promotion is fail-closed: missing data, a query error, or a burn rate
above the configured maximum fails the AnalysisRun, aborts the Rollout, and
leaves the stable Service on the previous version.
Because this is a basic replica-weighted canary without a traffic router, the
controller scales the candidate down promptly after abort. Capture candidate
configuration and logs while analysis is still running, then capture the failed
AnalysisRun and containment state.

The Argo Rollouts controller and CRDs, Prometheus Operator CRDs, and the
configured Prometheus endpoint are platform prerequisites. Use production's
5-minute burn window and 6-minute telemetry warm-up for normal delivery. The
1-minute window, 90-second warm-up, and controlled failure fixture are for an
isolated demonstration only.

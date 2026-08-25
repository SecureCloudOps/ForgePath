# Progressive delivery

The workload is an Argo Rollouts `Rollout`, not a Kubernetes `Deployment`. Its
first canary sequence is intentionally fixed:

```text
5% -> SLO analysis -> 25% -> SLO analysis -> 50% -> SLO analysis -> 100%
```

The chart creates two Services. The stable Service retains the original service
name and is pinned by Argo Rollouts to the last healthy ReplicaSet. The
`-canary` Service is pinned to the candidate ReplicaSet. With no ingress or
service mesh in this first version, `setWeight` controls ReplicaSet proportions.
`replicaCount` is therefore constrained to multiples of 20, making 5% exactly
one canary pod per twenty desired pods. A caller or test harness must send the
same request ratio to the two Services; Kubernetes Services do not combine the
two endpoints into weighted request routing.

Each analysis step runs the chart's `AnalysisTemplate`. It queries the existing
`forgepath:slo_availability_burn_rate` Prometheus recording rule. Promotion
succeeds only when exactly one result exists and its value is no greater than
the configured maximum burn rate. An empty result, an over-threshold result, or
a Prometheus query error fails the AnalysisRun. Argo Rollouts then aborts the
update and keeps the stable Service on the previous ReplicaSet.
Because this is a basic replica-weighted canary without a traffic router, the
controller scales the candidate down promptly after abort. The incident harness
therefore captures candidate configuration and logs after alert acknowledgment
while analysis is still running, then captures the failed AnalysisRun and
containment state.

## Defective-v2 abort demonstration

Prerequisites owned outside this chart are the Argo Rollouts controller and CRDs,
the Prometheus Operator CRDs, a Prometheus instance reachable at
`progressiveDelivery.analysis.prometheusAddress`, and a request generator able
to reach both Services. Install or mutate those prerequisites only through their
approved platform workflow.

1. Reconcile healthy v1 with `failureFixture.enabled=false` and wait for the
   Rollout to be Healthy. Confirm the stable Service endpoints use v1.
2. In a reviewed Git change, set all three demo values together:

   ```yaml
   failureFixture:
     enabled: true
   monitoring:
     slo:
       windowProfile: demo
   progressiveDelivery:
     analysis:
       burnRateWindow: 1m
       initialDelay: 90s
   ```

   The pod-template change is the deliberately defective v2 candidate. The
   fixture leaves health probes healthy but makes `/_test/failure` return 503,
   so readiness cannot mask SLO degradation.
3. After Argo CD reconciles the Git revision and the Rollout reaches `setWeight:
   5`, continuously send nineteen eligible successful requests to the stable
   Service for every one `/_test/failure` request to the canary Service.
4. Observe one canary pod, nineteen stable pods, and an AnalysisRun waiting for
   the 90-second telemetry warm-up. The 5% error rate is about a 50x burn rate
   against the 99.9% availability objective, above the 14.4x gate.
5. Observe the AnalysisRun become `Failed`, the Rollout become `Degraded`, and
   the stable Service selector remain on v1. The sequence must not reach 25%.
6. Roll back through Git by restoring the last healthy trusted image/configuration
   and the production SLO/analysis windows. Do not imperatively promote an
   aborted Rollout.

For a healthy candidate, the same analysis repeats after 25% and 50%, then the
Rollout promotes at 100%. Production uses the 5-minute burn-rate recording and a
6-minute warm-up; the accelerated 1-minute/90-second pair is demo-only.

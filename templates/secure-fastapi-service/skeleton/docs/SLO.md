# Service-level objective

## Scope and indicators

The initial availability objective is **99.9%**. An eligible request is any
request except `/metrics`, `/health/live`, or `/health/ready`. The availability
SLI is eligible non-5xx requests divided by all eligible requests. Redirects and
4xx responses therefore count as available; 5xx responses consume the error
budget.

The latency SLI is the proportion of eligible requests completed within 300 ms.
The application histogram has an explicit 300 ms bucket and the same `method`,
`path`, and `status_code` labels as the request counter.

The chart creates a `ServiceMonitor`, recording and alerting rules in one
`PrometheusRule`, and one Grafana dashboard ConfigMap. The dashboard covers
traffic, 5xx errors, p95 latency, CPU and memory saturation, both SLIs, and the
remaining availability error budget. These resources require the Prometheus
Operator CRDs and a Grafana sidecar that discovers the configured dashboard
label. The Prometheus installation must select this chart's resources.

## Production windows

`monitoring.slo.windowProfile=production` is the default. It uses a 30-day error
budget and these paired burn-rate windows:

| Alert | Long window | Short window | Burn rate | Severity |
| --- | ---: | ---: | ---: | --- |
| Fast | 1 hour | 5 minutes | 14.4x | page |
| Medium | 6 hours | 30 minutes | 6x | page |
| Slow | 1 day | 2 hours | 3x | ticket |
| Very slow | 3 days | 6 hours | 1x | ticket |

Both windows must exceed the threshold. Keep this profile for real alerting.

## Accelerated demonstration windows

`monitoring.slo.windowProfile=demo` is only for short demonstrations. It changes
the budget window to 1 hour and uses 5m/1m, 15m/3m, 30m/5m, and 1h/10m window
pairs at the same respective burn thresholds. These windows are intentionally
noisy and are not production alert settings.

The controlled failure route is off by default. In an isolated demo values file,
set `failureFixture.enabled=true`, reconcile that values change through the
normal GitOps path, and repeatedly request `/_test/failure`. It returns 503 and
is included in both SLIs, allowing the dashboard and fast-burn alert to prove
degradation detection. Restore the value to `false` immediately afterward.

The rule unit test supplies synthetic eligible 200 and 503 counters and proves
that availability drops, the error budget reaches zero, and the fast-burn alert
fires. It does not require enabling the runtime fixture.

Prometheus recordings are the application-health contract for any future
progressive-delivery controller. Kubernetes readiness still protects traffic,
but readiness and Argo CD sync health must not be used as substitutes for SLO
compliance. Missing Prometheus data must fail closed and pause promotion.

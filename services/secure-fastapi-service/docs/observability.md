# Observability and SLO

The reference chart scrapes the existing `/metrics` endpoint with a
`ServiceMonitor`. Metrics and health probes are excluded from eligible traffic.
Availability is eligible non-5xx requests divided by all eligible requests; the
initial availability SLO is **99.9%**. Latency is the proportion of eligible
requests completed within 300 ms.

The `PrometheusRule` records eligible traffic, errors, availability, latency,
remaining error budget, and burn rates. Its multi-window alerts require both the
long and short window to breach. The Grafana dashboard ConfigMap contains one
dashboard for traffic, errors, latency, CPU and memory saturation, SLIs, and
error budget. Prometheus Operator CRDs and compatible Prometheus/Grafana
resource discovery must already exist; this scope does not install a monitoring
stack.

## Realistic production windows

The default `production` profile uses a 30-day budget and paired windows of
1h/5m at 14.4x, 6h/30m at 6x, 1d/2h at 3x, and 3d/6h at 1x. The first two page;
the latter two create tickets.

## Accelerated demo windows

The `demo` profile uses a 1-hour budget and 5m/1m, 15m/3m, 30m/5m, and 1h/10m
pairs. It is intentionally too sensitive for production.

For an isolated demonstration, set both
`monitoring.slo.windowProfile=demo` and `failureFixture.enabled=true` in the
GitOps values, then send repeated requests to `/_test/failure`. The endpoint is
otherwise disabled; when enabled it returns an eligible 503. Revert the fixture
to `false` after verifying the SLI, budget, and fast-burn alert.

The NetworkPolicy scrape exception requires both the `monitoring` namespace
label and the Prometheus pod label configured in chart values, and permits only
TCP port 8080. It does not create general workload ingress.

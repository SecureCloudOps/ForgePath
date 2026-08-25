# ForgePath v2 observability validation evidence

The initial ForgePath v2 Prometheus/SLO scope was statically validated on
2026-08-23 with the repository-pinned toolchain, including Prometheus
`promtool` v3.5.0.

Validated implementation commit: `a601481d74ceb4653b03ad77db00d1e81021934d`

## Recorded static result

The deterministic rule fixture contributes 29 eligible HTTP 200 responses and
one eligible HTTP 503 response per interval. The recorded availability is:

```text
29 / (29 + 1) = 0.9666666666666667 = 96.67%
```

At the fixture's 65-minute evaluation point, both production fast-burn windows
exceed 14.4x and the two-minute hold has elapsed. The expected and observed
alert is `ForgePathSLOFastBurn` with `severity=page`.

```text
Checking prometheus-rules.yaml
  SUCCESS: 17 rules found

  SUCCESS
```

The same test asserts `forgepath:slo_error_budget_remaining:ratio == 0` for the
degraded series. This is static synthetic evidence: it proves PromQL evaluation
and alert behavior without claiming a live Prometheus deployment.

## Static resource evidence

The static observability gate validates:

- one `/metrics` ServiceMonitor;
- availability and sub-300 ms latency recordings;
- a 99.9% availability target, remaining-budget calculation, and burn rates;
- four paired multi-window burn alerts;
- one eight-panel Grafana dashboard;
- an unchanged ingress/egress default-deny NetworkPolicy plus a separate scrape
  policy restricted by Prometheus namespace label, pod label, and TCP 8080;
- production and accelerated-demo renders; and
- a disabled-by-default controlled 503 fixture.

The rendered GitOps set contains eight resources. Kubeconform validated the six
native Kubernetes resources, skipped the two Prometheus Operator custom kinds
for dedicated structural and `promtool` validation, and Conftest reported 11/11
policy tests passing. Kyverno static validation admitted the paved-path render
and rejected all 16 synthetic insecure fixtures.

Run this evidence without creating or contacting a Kubernetes cluster:

```sh
make validate-observability-static
```

## Security-gate boundary

Static Trivy configuration checks run with check updates disabled. Vulnerability
data is intentionally outside the static gate:

```sh
make validate-observability-online
```

The online gate refreshes `.forgepath/cache/trivy` once from the explicitly
configured v2 database repository, verifies its metadata, prints the metadata
SHA-256, and performs filesystem and image scans with DB updates and external
dependency lookups disabled. CI caches that directory by pinned Trivy version,
DB schema, operating system, and architecture. A fetch failure is therefore an
explicit online-gate failure, never an ambiguous static-validation result.
Trusted-artifact builds additionally copy the DB metadata into the evidence
bundle and bind its checksum and update timestamp into `metadata.json`.

The recorded online gate used Trivy DB schema v2 with update timestamp
`2026-08-23T06:56:50.570047645Z` and metadata SHA-256:

```text
cf48e2f22068b57a93d47d4bf15a4b66bb25abe331d4af601972da7cd99436de
```

Runtime dependencies, development dependencies, Alpine packages, and packaged
Python dependencies all reported zero HIGH or CRITICAL vulnerabilities. The
complete online gate passed using that one cached snapshot.

## Runtime evidence status

Runtime verification is deliberately separate because it creates and deletes a
Kubernetes cluster:

```sh
make validate-observability-runtime
```

That target refuses a pre-existing `forgepath-observability` cluster, verifies
the exact Kind context, uses pinned Kind/Kubernetes/Prometheus images, loads the
trusted application artifact by digest, proves live `/metrics` scraping through
the restricted NetworkPolicy, enables the controlled fixture, waits for the
accelerated fast-burn alert, restores the original context, and deletes the
cluster. It requires explicit approval immediately before execution. No runtime
result is claimed in this static evidence record.

The subsequent disposable Argo Rollouts and Prometheus Operator proof is
recorded in [Phase 2 progressive-delivery evidence](PHASE_2_PROGRESSIVE_DELIVERY.md).
It proves Prometheus discovery, the fast-burn alert, analysis failure, rollout
abort, stable-version protection, Git recovery, final reconciliation, and
cleanup without claiming a persistent controller installation.

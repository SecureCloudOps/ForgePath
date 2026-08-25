# Changelog

All notable ForgePath changes are recorded here. ForgePath follows semantic
versioning for release tags, while historical checkpoint tags remain immutable.

## 2.0.0 - 2026-08-24

ForgePath v2 transforms the original secure-service paved path into a
production-shaped, reproducible local reference platform. It is a portfolio and
engineering reference, not a claim of production readiness.

### Added

- An authenticated Backstage self-service path backed by the same
  repository-owned renderer as the CLI, with fail-closed publication and
  pre-generation rejection of unsafe inputs.
- Availability and latency SLOs, a 99.9% availability target, error-budget and
  burn-rate recording rules, multi-window alerts, a Grafana dashboard, and a
  narrowly scoped Prometheus scrape path.
- Replica-weighted Argo Rollouts canaries at 5%, 25%, 50%, and 100%, with
  Prometheus analysis gates that fail closed and preserve the stable Service.
- Runtime-proven platform guardrails for ownership metadata, approved
  registries, immutable digests, signature and provenance verification,
  restricted Pod Security Admission, quotas, limits, and default-deny
  networking.
- Workload identity boundaries with negative authorization tests and a
  time-bounded, owner-approved, narrowly scoped exception mechanism.
- A measured incident exercise covering alert acknowledgment, logs, metrics,
  Rollout and Git evidence, human-approved Git recovery, Argo CD
  reconciliation, tamper-evident evidence, and generated postmortem output.
- A trusted-artifact workflow that binds a clean source revision to an OCI
  archive, SPDX SBOM, Trivy results, immutable digest, and detached Cosign
  signature. Builds fail closed when the template source is dirty.

### Measured results

- One developer action produced a repository with nine inherited controls;
  request-to-repository time was 0.021 seconds and the first PR-ready branch was
  available in 0.099 seconds in the disposable local exercise.
- A defective revision was contained at 5% maximum canary exposure. The
  exercise measured MTTD at 270.265 seconds, MTTA at 8.543 seconds, and MTTR at
  374.620 seconds, with 1,606 failed requests among 32,120 synthetic requests.
- Recovery remained human-approved and Git-mediated; Argo CD reconciled the
  recovered desired state and the service returned healthy.

These figures are reproducible local-exercise measurements, not production
benchmarks. Their evidence and limitations are indexed in
[`docs/evidence/README.md`](docs/evidence/README.md).

### Known limitations

- CA-2 remains open: the exercise observes Prometheus directly and does not
  prove an external paging and acknowledgment integration.
- CA-3 remains open: production owners have not established reviewed targets
  for MTTD, MTTA, MTTR, exposure, failed requests, or error-budget consumption.
- The reference proves one template, one service, one local GitOps environment,
  and disposable Kind runtimes; it does not prove multi-cluster, regional, or
  hosted control-plane behavior.

### Release integrity

- `v2.0.0-observability-baseline` remains an earlier checkpoint and is not
  renamed or reused.
- The final v2 artifact digest and clean-source revision are recorded in
  [`docs/evidence/TRUSTED_ARTIFACT_PROVENANCE.md`](docs/evidence/TRUSTED_ARTIFACT_PROVENANCE.md)
  and its tracked corrective-action manifest.

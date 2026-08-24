# ForgePath Roadmap

ForgePath will be built in small, demonstrable increments:

1. Establish the repository foundation and decision record process.
2. Define one minimal paved path and its generated service contract.
3. Add CI validation and policy checks for that path.
4. Build, scan, produce an SBOM, and sign an immutable artifact.
5. Record the trusted artifact in Git desired state.
6. Add Argo CD reconciliation and Kyverno admission enforcement. Complete and
   runtime-proven.
7. Add a pinned local Backstage experience that consumes the existing paved
   path and exposes read-only delivery status. Complete.
8. Demonstrate the complete path on a minimal Kubernetes environment.
   Complete.
9. Harden, document, and collect portfolio evidence from the working flow.
   Complete. See the [v1 validation evidence](evidence/V1_VALIDATION.md) and
   [screenshot set](screenshots/README.md).
10. Define and statically prove the initial Prometheus availability/latency SLO,
    error budget, burn alerts, dashboard, and restricted scrape path. Complete.
    See the [v2 validation evidence](evidence/V2_VALIDATION.md).
11. Run the separately approved disposable observability runtime proof before
    enabling a progressive-delivery controller. Runtime proof complete.
12. Replace the reference Deployment with a replica-weighted Argo Rollout,
    stable/canary Services, and fail-closed Prometheus analysis at 5%, 25%, and
    50%. Static implementation complete.
13. Run the separately approved defective-v2 runtime proof: 5% canary, SLO
    degradation, failed AnalysisRun, aborted Rollout, and stable v1 traffic.
    Complete.
14. Add the first platform-guardrail increment: required workload ownership
    metadata, approved registries, digest-only images, Cosign signature
    verification, SLSA provenance verification, and a negative-first admission
    demonstration. Complete, runtime-proven, and frozen. See the
    [platform-guardrail validation evidence](evidence/PLATFORM_GUARDRAILS.md).
15. Add namespace guardrails: restricted Pod Security Admission, ResourceQuota,
    LimitRange, default-deny networking, DNS-only application egress, and
    narrowly scoped observability. Complete, runtime-proven, and frozen. See the
    [namespace-isolation validation evidence](evidence/NAMESPACE_ISOLATION.md).
16. Add workload RBAC boundaries and explicit negative authorization tests.
    Complete, runtime-proven, and frozen. See the
    [workload-identity validation evidence](evidence/WORKLOAD_IDENTITY.md).
17. Add the time-bounded, owner-approved, narrowly scoped exception mechanism
    with expiry failure tests. Complete and runtime-proven. See the
    [workload-exception validation evidence](evidence/WORKLOAD_EXCEPTIONS.md).
    Source checkpoint: `e0e97bb7b625bb8dda49e227dd20abeefbbdc153`.
    Evidence checkpoint: `b1192319d4fe3746f1d411f0d047b188597c3140`.
18. Make Backstage the developer entry point, add fail-closed repository and
    GitOps publishing with an offline Git simulation, prove common mistakes are
    rejected before generation, and capture developer-experience metrics.
    Complete statically and frozen. See
    [developer self-service evidence](evidence/DEVELOPER_SELF_SERVICE.md).
    Source checkpoint: `8505cf081c444b5fc97623c19e6c4c13315065a1`.
    Evidence checkpoint: `9049c21fd7ddd1bcaae1bc68cc05a29d45f810c3`.
    The Phase 4 static implementation was frozen on 2026-08-24. Runtime proof
    may add evidence only; source changes require a new roadmap increment and
    checkpoint.
19. Redesign namespace ownership after the first approved runtime proof exposed
    an Application/AppProject conflict: platform owns namespace lifecycle, PSA,
    quota, limits, and network policy; applications own only namespaced workload
    and SLO resources. Complete, runtime-proven, and fail-closed regression
    tested. Ownership checkpoint: `3715ab573bcc2dade6ddc6fe629f3862b98ce38e`.
    Scoped analysis-network checkpoint:
    `211bd353248f0481c9e7d7b11d8a3596480f4ea6`.
    Preserve the failed proof and remediation evidence in
    [developer self-service runtime evidence](evidence/DEVELOPER_SELF_SERVICE_RUNTIME.md).

Details will be designed only when each increment begins. The project will favor
one complete, secure path over broad platform scope.

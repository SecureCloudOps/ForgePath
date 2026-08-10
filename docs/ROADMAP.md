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

Details will be designed only when each increment begins. The project will favor
one complete, secure path over broad platform scope.

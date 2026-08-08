# ForgePath Roadmap

ForgePath will be built in small, demonstrable increments:

1. Establish the repository foundation and decision record process.
2. Define one minimal paved path and its generated service contract.
3. Add CI validation and policy checks for that path.
4. Build, scan, produce an SBOM, and sign an immutable artifact.
5. Record the trusted artifact in Git desired state.
6. Add Argo CD reconciliation and Kyverno admission enforcement. (static
   implementation complete; Kyverno runtime proof pending explicit approval)
7. Add a pinned local Backstage experience that consumes the existing paved
   path and exposes read-only delivery status.
8. Demonstrate the complete path on a minimal Kubernetes environment.
9. Harden, document, and collect portfolio evidence from the working flow.

Details will be designed only when each increment begins. The project will favor
one complete, secure path over broad platform scope.

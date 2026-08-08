# Demo screenshots

These non-sensitive frames came from the passing `forgepath-gitops` runtime
proof on 2026-08-08:

- `backstage-catalog.png` — the one-service ForgePath catalog;
- `backstage-service-overview.png` — the service, TechDocs entry point, and
  related Argo CD catalog Resource;
- `backstage-kubernetes-workload.png` — the live Deployment and Pod status; and
- `backstage-argocd-application.png` — the related Application with `Healthy`
  and `Synced` status.

The warning banner in the Kubernetes frames is expected evidence of namespace
containment: the workload entity cannot read Applications outside `argocd`, and
the Argo CD entity cannot read unrelated workloads. The authorized status cards
remain visible. No kubeconfig, credential, token, or Secret value is present.

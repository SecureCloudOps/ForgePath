# Secure FastAPI service

This is ForgePath's single reference service. It demonstrates the complete path
from a Backstage catalog entry and TechDocs through a hardened Helm workload,
policy gates, a trusted image digest, Argo CD reconciliation, SLO-gated Argo
Rollouts delivery, Kyverno admission, and read-only runtime status.

The service is intentionally small. ForgePath v1 proves one secure paved path;
it does not attempt to provide a template catalog or a multi-cloud platform.

## Ownership

- Owner: `group:default/platform`
- System: `forgepath`
- Kubernetes namespace: `secure-fastapi-service-local`
- Argo CD Application: `argocd/secure-fastapi-service-local`

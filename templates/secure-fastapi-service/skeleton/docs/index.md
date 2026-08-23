# __FORGEPATH_SERVICE_NAME__

__FORGEPATH_SERVICE_DESCRIPTION__

This service was generated from ForgePath's `secure-fastapi-service` paved
path. Use the runbook for operational procedures and the security guide for the
controls inherited from the path.

Delivery uses a replica-weighted Argo Rollouts canary with fail-closed
Prometheus SLO analysis. See the progressive-delivery guide for its stable and
canary Service contract.

## Ownership

- Owner: `__FORGEPATH_OWNER__`
- System: `forgepath`
- Kubernetes namespace: `__FORGEPATH_KUBERNETES_NAMESPACE__`

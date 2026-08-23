# Runbook

## Service indicators

- `/health/live` confirms the process event loop can answer HTTP.
- `/health/ready` returns 200 only while the application lifespan is ready.
- `/metrics` exposes request count and latency in Prometheus text format.
- The SLO rules exclude metrics and health probes from eligible traffic.
- JSON logs include `request_id`, route, method, status, and duration.

## Triage

1. Check Deployment availability and recent pod events.
2. Inspect readiness failures and structured logs using the request ID.
3. Check CPU and memory usage against the configured requests and limits.
4. Confirm NetworkPolicies permit only the intended ingress source.
5. Roll back to the previous immutable image version through the owning GitOps
   workflow. Do not patch a live workload or reuse an image tag.

See [SLO.md](SLO.md) for the production burn windows and the isolated failure
fixture procedure.

## Graceful termination

Kubernetes sends SIGTERM and allows 30 seconds by default. Uvicorn stops accepting
new work, completes in-flight requests, and runs the FastAPI lifespan shutdown.

## Escalation

The owning team is `__FORGEPATH_OWNER__`. Escalate sustained readiness failure,
error-rate increase, or saturation according to the team's on-call process.

# Security

## Defaults

- Runtime dependencies and the Python base image are pinned.
- The container runs as UID/GID 10001 and does not need a writable root filesystem.
- The pod uses RuntimeDefault seccomp, drops all capabilities, disallows privilege
  escalation, and does not mount a service account token.
- The namespace-wide NetworkPolicy denies ingress and egress by default.
- DNS egress is limited to kube-system DNS pods on UDP/TCP 53; the generated
  application has no other egress exception.
- Prometheus ingress requires both the monitoring namespace and Prometheus pod
  labels and is restricted to TCP 8080.
- ResourceQuota and LimitRange bound aggregate namespace consumption and each
  container's CPU and memory allocation.
- Resource requests and limits reduce noisy-neighbor and exhaustion risk.

## Reporting

Report vulnerabilities privately to `__FORGEPATH_OWNER__`. Do not include secrets,
customer data, exploit payloads, or credentials in issues or logs.

## Application responsibilities

This template does not add authentication, authorization, secrets, persistence,
or outbound access. Add only controls required by the service threat model. Keep
sensitive values outside Git and allow the minimum necessary network traffic.

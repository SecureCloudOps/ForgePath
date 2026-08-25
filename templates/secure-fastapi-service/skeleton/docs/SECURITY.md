# Security

## Defaults

- Runtime dependencies and the Python base image are pinned.
- The container runs as UID/GID 10001 and does not need a writable root filesystem.
- The pod uses RuntimeDefault seccomp, drops all capabilities, disallows privilege
  escalation, and does not mount a service account token.
- The platform-owned namespace prerequisite supplies restricted PSA labels,
  ResourceQuota, LimitRange, default-deny networking, DNS egress, and narrowly
  selected Prometheus ingress before application reconciliation.
- The application chart cannot create or modify that namespace boundary.
- Resource requests and limits reduce noisy-neighbor and exhaustion risk.
- The application has no Kubernetes API requirement, receives no Role or
  RoleBinding, and keeps controller permissions on separate platform identities.

## Reporting

Report vulnerabilities privately to `__FORGEPATH_OWNER__`. Do not include secrets,
customer data, exploit payloads, or credentials in issues or logs.

## Application responsibilities

This template does not add authentication, authorization, secrets, persistence,
or outbound access. Add only controls required by the service threat model. Keep
sensitive values outside Git and allow the minimum necessary network traffic.

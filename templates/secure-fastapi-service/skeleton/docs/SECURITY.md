# Security

## Defaults

- Runtime dependencies and the Python base image are pinned.
- The container runs as UID/GID 10001 and does not need a writable root filesystem.
- The pod uses RuntimeDefault seccomp, drops all capabilities, disallows privilege
  escalation, and does not mount a service account token.
- The NetworkPolicy denies ingress and egress by default.
- Resource requests and limits reduce noisy-neighbor and exhaustion risk.

## Reporting

Report vulnerabilities privately to `__FORGEPATH_OWNER__`. Do not include secrets,
customer data, exploit payloads, or credentials in issues or logs.

## Application responsibilities

This template does not add authentication, authorization, secrets, persistence,
or outbound access. Add only controls required by the service threat model. Keep
sensitive values outside Git and allow the minimum necessary network traffic.

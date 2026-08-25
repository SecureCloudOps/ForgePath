# Security policy

ForgePath is a production-shaped, reproducible local reference platform. It is
not a hosted service or a claim that the repository is ready for an unreviewed
production deployment.

## Supported versions

| Version | Security updates |
| --- | --- |
| Latest `2.x` release | Supported |
| Historical checkpoints and `1.x` | Not supported |

Historical tags remain available as engineering evidence, but fixes are made on
the current supported line.

## Reporting a vulnerability

Use GitHub's private vulnerability-reporting or draft security-advisory flow for
this repository when it is available. Include:

- the affected path, revision, and configuration;
- the security impact and required preconditions;
- minimal reproduction steps using synthetic, non-sensitive data; and
- any suggested remediation or compensating control.

If private reporting is unavailable, open a minimal issue requesting a private
maintainer contact. Do not publish exploit details, credentials, tokens,
personal data, or live-environment identifiers in a public issue.

Maintainers will acknowledge a complete report, assess severity and scope,
prepare a fix and regression coverage, and coordinate disclosure. No response
time is guaranteed for this portfolio reference.

## Security boundaries

- Never submit real credentials. Examples and tests must use synthetic values.
- Do not test against infrastructure you do not own or have explicit permission
  to use.
- Runtime proofs must use their named disposable local clusters and must restore
  the original Kubernetes context during cleanup.
- Application delivery remains GitOps-mediated. Do not bypass Git promotion,
  admission policy, immutable image references, or human recovery checkpoints.
- Dependency and tool versions must remain pinned or digest-bound where
  practical; exceptions require documented compensating validation.

The repository's threat model is in
[`docs/THREAT_MODEL.md`](docs/THREAT_MODEL.md), and the implemented validation
and runtime evidence is indexed in
[`docs/evidence/README.md`](docs/evidence/README.md).

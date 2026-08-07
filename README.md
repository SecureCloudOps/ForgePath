# ForgePath

ForgePath is a small portfolio project for demonstrating secure paved paths.
Developers choose an approved path; the platform generates secure defaults,
validates every change, and delivers only policy-compliant trusted artifacts
through GitOps.

The first paved path is `secure-fastapi-service`, a small secure-by-default
FastAPI service template with local validation and a hardened Helm chart.

## Documentation

- [Architecture](docs/ARCHITECTURE.md)
- [Threat model](docs/THREAT_MODEL.md)
- [Roadmap](docs/ROADMAP.md)
- [Architecture decision records](docs/adr/README.md)

## Validate the foundation

```sh
make validate-foundation
```

## Validate the secure FastAPI paved path

Install the pinned validation toolchain with `mise install`. The validation also
requires a running Docker engine. It creates only temporary files and a local
container image.

```sh
mise install
make validate-security
```

This single fail-closed entry point runs formatting, linting, type checking,
unit tests, secret scanning, SAST, dependency and container vulnerability
scanning, Dockerfile and Kubernetes misconfiguration scanning, Kubeconform,
and Helm lint/render checks. Synthetic negative fixtures prove that the scanners
reject secrets, insecure container and Kubernetes configurations, schema-invalid
manifests, and overprivileged RBAC.

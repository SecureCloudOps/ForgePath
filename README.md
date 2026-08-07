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

The validation requires Python 3.12, Docker, Helm, jq, and yq. It
creates only temporary files and a local container image.

```sh
make validate-secure-fastapi
```

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

## Validate platform policy

ForgePath's Kubernetes rules are centralized as OPA/Rego in `policies/` and are
evaluated by Conftest against Helm-rendered manifests. The standalone policy gate
also exercises a synthetic negative fixture for every enforced rule:

```sh
make validate-policy
```

`make validate-security` depends on this target, so CI and local security
validation execute the exact same policy checks.

## Build a trusted local artifact

Install the pinned toolchain and start Docker, then run:

```sh
mise install
make build-trusted-artifact
make validate-trusted-artifact
```

The build entry point first reuses `make validate-security`, then renders and
builds `secure-fastapi-service` as a local OCI archive. It scans the exact
archive with Trivy using ForgePath's `HIGH,CRITICAL` demo policy, generates an
SPDX JSON SBOM with Syft, and records the OCI manifest digest. Cosign signs that
digest locally with an ephemeral test key and verifies it before the private key
is deleted. Nothing is uploaded to a registry or transparency service.

Successful evidence is written beneath `.forgepath/trusted-artifact/`, which is
ignored by Git. `metadata.json` binds the archive, digest, SBOM, scan report,
signature, source revision, and reproducible source timestamp. The validator
also exercises rejection of unsigned artifacts, mismatched metadata, missing
SBOMs, and invalid signatures.

## Validate static GitOps desired state

The local desired state promotes only an already trusted
`secure-fastapi-service` image digest. Validation is offline and does not create
a cluster, install Argo CD, or contact a Kubernetes API:

```sh
make validate-gitops-static
```

This renders the application-owned Helm chart with `gitops/` environment
values, validates local Kubernetes schemas and OPA policies, checks the exact
trusted digest, and exercises the GitOps negative suite. See
[`gitops/README.md`](gitops/README.md) for structure, ownership, promotion, and
Git-revert rollback semantics.

## Validate GitOps at runtime

The runtime gate creates and deletes only a disposable Kind cluster named
`forgepath-gitops`. It records and restores the original Kubernetes context,
rebuilds and verifies the trusted image digest, installs a reviewed and pinned
Argo CD manifest, and exercises sync, health, self-heal, Git revision changes,
pruning, and AppProject containment. It uses a temporary local Git remote and
never pushes an image or Git revision.

Cluster creation and mutation require the explicit approval described in
`AGENTS.md`. After that approval, run:

```sh
make validate-gitops-runtime
```

The command refuses to run if a cluster named `forgepath-gitops` already
exists. Cleanup deletes only the cluster created by that invocation and restores
the exact context that was active before creation.

# ForgePath

ForgePath is a local portfolio implementation of one secure paved path. A
developer generates `secure-fastapi-service`; ForgePath validates it, builds and
signs an immutable trusted artifact, promotes its digest through Git, reconciles
it with Argo CD, enforces admission with Kyverno, and exposes read-only status
in Backstage.

```text
Backstage -> secure-fastapi-service -> Catalog + TechDocs
          -> Kubernetes workload status -> Argo CD Application status
```

The v1 scope is deliberately narrow: one template, one service, one local
environment, one failure scenario, one drift scenario, and one admission
rejection. Crossplane, AI, more templates, and multi-cloud support are future
work.

## Quick start

Install the pinned toolchain and start Docker:

```sh
mise install
make validate-v1-static
```

Run the local portal:

```sh
cd platform/backstage
corepack yarn start
```

Choose **Create → Secure FastAPI service**. Output is confined to
`.forgepath/generated/`; Backstage cannot publish it or register it remotely.

## What the gates prove

| Gate | Command | Evidence |
| --- | --- | --- |
| Repository foundation | `make validate-foundation` | Required structure, documentation, architecture stages, and shell safety |
| Paved path and security | `make validate-security` | Tests, scans, schemas, Helm, OPA, and Kyverno CLI negative fixtures |
| Trusted artifact | `make validate-trusted-artifact` | OCI archive, Trivy report, SPDX SBOM, digest, and locally verified ephemeral signature |
| Backstage | `make validate-backstage-static` | Pinned app and MkDocs toolchain, rendered TechDocs, catalog, renderer confinement, and permissions |
| GitOps | `make validate-gitops-static` | Restricted AppProject/Application, trusted digest handoff, render, schema, and policy checks |
| Backstage + Argo runtime | `make validate-backstage-runtime` | Disposable Kind deployment, reconciliation, read-only Backstage workload and Application status, and RBAC denials |
| Kyverno runtime | `make validate-kyverno-runtime` | Compliant admission and unsafe Pod rejection through the Kubernetes API |

Runtime gates create, mutate, and delete only named disposable Kind clusters.
They require explicit approval under `AGENTS.md`, refuse pre-existing target
clusters, verify context before mutation, restore the original context, and
clean up on exit.

## Read-only runtime identity

`backstage-runtime-reader` receives only `get`, `list`, and `watch` for selected
workload resources and the matching Argo CD `Application`. The runtime gate
explicitly proves denial of:

- Secrets and credential/token access;
- Pod deletion and exec;
- workload creation, update, patch, and deletion;
- Argo CD Application update/patch (including sync); and
- Backstage's raw Kubernetes proxy permission.

Backstage holds no Argo CD API token and exposes no sync control.

## Final validation

After approval for the disposable cluster mutations:

```sh
make validate-v1
```

That is the v1 release gate. Stop adding features once it passes and the demo
screenshots are recorded.

## Documentation

- [Architecture](docs/ARCHITECTURE.md)
- [End-to-end demo and screenshot checklist](docs/DEMO.md)
- [Threat model](docs/THREAT_MODEL.md)
- [GitOps design and rollback](gitops/README.md)
- [Backstage boundary](platform/backstage/README.md)
- [Roadmap](docs/ROADMAP.md)
- [ADRs](docs/adr/README.md)

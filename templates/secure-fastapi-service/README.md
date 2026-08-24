# secure-fastapi-service paved path

This ForgePath template generates one production-style FastAPI service with
health endpoints, Prometheus metrics, JSON logs, correlation IDs, tests, a
minimal non-root container, and a hardened Helm chart.

## Render

```sh
python3 templates/secure-fastapi-service/render.py \
  --output /tmp/my-service \
  --service-name my-service \
  --owner group:default/platform \
  --system forgepath \
  --environment development \
  --data-classification internal \
  --kubernetes-namespace my-service-development
```

The output directory must be empty. Rendering is deterministic for the same
arguments and does not require network access or a template engine.

The same renderer is the only generation implementation used by Backstage.
The Backstage action validates identity, ownership, metadata, image constraints,
privilege requests, and repository targets before invoking it. The paired
`publish.py` command creates either offline Git/PR evidence or tightly scoped
GitHub and GitOps onboarding changes.

## Validate

From the ForgePath repository root:

```sh
make validate-security
```

See the generated service README for development and deployment instructions.

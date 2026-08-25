# Developer self-service evidence

ForgePath exposes one Backstage entry point: **Create Secure FastAPI Service**.
The custom action performs server-side validation before creating a directory or
contacting GitHub. It then renders the repository-owned skeleton and invokes the
same narrow publisher in either local simulation or GitHub mode.

## Golden-path contract

```text
developer request
  -> Backstage identity and request preflight
  -> secure service repository and onboarding PR
  -> required validation and trusted-artifact checks
  -> signed digest plus SBOM and provenance
  -> digest-only GitOps promotion PR
  -> Argo CD reconciliation and SLO-gated rollout
  -> healthy workload and visible Prometheus SLOs
```

The local mode creates real Git repositories, commits, branches, and PR
descriptors without network access. GitHub mode is fail-closed unless the
Backstage caller is non-guest, the organization and GitOps repository match
server-side allowlists, and short-lived GitHub App and Backstage catalog tokens
are injected at runtime. The service repository is private, its default branch
requires review, CODEOWNER approval, and both pipeline checks, and the GitOps
change is always a separate PR.

## Safe failure evidence

`make validate-developer-self-service` proves that malformed names, invalid
owners, missing classification, unsupported image repositories, privileged
access, and unauthorized repository targets fail before publication. The test
also confirms that denied requests do not create generated service output.

## Developer-experience measurements

Every publication writes the following machine-readable metrics to
`publication.json`:

| Metric | Local proof | Interpretation |
| --- | ---: | --- |
| Time to create a service | Measured per run | Validation through local repositories and PR descriptors |
| Manual steps | 1 | Submit the Backstage form; review/merge remains an approver responsibility |
| Automatically inherited security controls | 9 | Counted from `.forgepath/onboarding.yaml` |
| Kubernetes manifests developers need to understand | 0 | Platform owns the generated Helm and GitOps contract |
| Request to healthy deployment | Not fabricated in static mode | Recorded only by an approved runtime proof after Argo CD reports Healthy and the SLO target is queryable |

Run `scripts/measure-developer-experience.py <publication.json>` to print a
normalized report. A null healthy duration is intentional in local simulation;
it prevents static tests from being presented as runtime evidence.

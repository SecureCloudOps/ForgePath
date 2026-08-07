# ForgePath Safety and Approval Boundaries

## Scope

This file governs the entire repository. More specific `AGENTS.md` files may add
stricter constraints, but they must not weaken these safety boundaries or broaden
mutation permissions.

If a request conflicts with a hard safety boundary, stop and explain the conflict.
Do not silently reinterpret the request.

## Allowed Local Actions

Agents may perform these repository-scoped actions without additional approval:

- inspect and edit files in the current worktree
- create and update local tests and documentation
- run local validation, formatting, rendering, and static analysis
- build containers locally
- create temporary local resources when cleanup is deterministic and no external
  system is affected
- inspect the Git worktree and local history

Preserve unrelated user changes. Do not stage, commit, discard, overwrite, or
publish them.

## Approval Required

Obtain explicit user approval immediately before:

- staging changes or creating, amending, or rewriting a local Git commit
- creating, deleting, or reconfiguring a Kubernetes cluster
- applying, deleting, or mutating resources through any Kubernetes API
- provisioning, changing, or destroying cloud infrastructure
- pushing to a remote repository or modifying a remote branch or tag
- creating a remote repository or pull request
- publishing container images, packages, releases, attestations, or artifacts
- changing external services, identities, permissions, credentials, or secrets
- changing any live infrastructure

Approval applies only to the specific action and target presented to the user. Do
not infer approval from an earlier action, another environment, or prior work.
Prefer a dry run, render, plan, or diff before requesting approval for a mutation.

## Hard Safety Boundaries

Never:

- expose, print, store, or commit secrets or credentials
- introduce static cloud access keys
- weaken, skip, or delete tests merely to make validation pass
- disable or relax security policy merely to obtain a successful deployment
- mutate a Kubernetes cluster without first verifying the exact context and scope
- use `cluster-admin` unless an accepted ADR explicitly demonstrates that narrower
  RBAC cannot satisfy the requirement
- deploy mutable image references such as `latest`
- bypass GitOps for application delivery
- execute a downloaded script directly from the internet unless its immutable
  source is pinned and its contents have been reviewed before execution
- introduce unpinned infrastructure tooling
- perform a destructive operation against an ambiguous path, context, account,
  project, subscription, environment, or resource

Use least privilege, immutable references, fail-closed validation, reproducible
inputs, and synthetic non-sensitive fixtures by default.

Container images, GitHub Actions, Helm charts, packages, and other executable or
build-time dependencies must use immutable versions or digests where practical.
When immutability is impractical, document the constraint and compensating
validation.

## After Local Changes

- run relevant local checks when available
- review the diff for secrets, unsafe defaults, scope creep, and unrelated changes
- report checks run, results, and anything that could not be validated
- do not claim validation or completion without supporting evidence

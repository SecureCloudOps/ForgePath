#!/usr/bin/env python3
"""Publish a rendered ForgePath service to local Git simulation or allowlisted GitHub repos."""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import shutil
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

DNS_LABEL = re.compile(r"^[a-z][a-z0-9-]{1,61}[a-z0-9]$")
OWNER_REF = re.compile(r"^group:default/[a-z][a-z0-9-]{1,61}[a-z0-9]$")
REPOSITORY_OWNER = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$")
ENVIRONMENTS = {"local", "development", "staging", "production"}
CLASSIFICATIONS = {"public", "internal", "confidential", "restricted"}
REQUIRED_CHECKS = ["Service pipeline / validate", "Service pipeline / trusted-artifact"]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("local", "github"), required=True)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--generation-root", type=Path, required=True)
    parser.add_argument("--simulation-root", type=Path, required=True)
    parser.add_argument("--service-name", required=True)
    parser.add_argument("--owner", required=True)
    parser.add_argument("--system", required=True)
    parser.add_argument("--environment", required=True)
    parser.add_argument("--data-classification", required=True)
    parser.add_argument("--repository-owner", required=True)
    parser.add_argument("--gitops-repository", required=True)
    parser.add_argument("--backstage-identity", required=True)
    parser.add_argument("--allowed-owner", action="append", default=[])
    parser.add_argument("--allowed-system", action="append", default=[])
    parser.add_argument("--allowed-repository-owner", action="append", default=[])
    parser.add_argument("--github-api-url", default="https://api.github.com")
    parser.add_argument("--backstage-catalog-url", default="http://localhost:7007/api/catalog")
    return parser.parse_args()


def fail(message: str) -> None:
    raise SystemExit(message)


def assert_child(parent: Path, child: Path, label: str) -> None:
    try:
        child.resolve().relative_to(parent.resolve())
    except ValueError:
        fail(f"{label} must remain inside {parent.resolve()}")


def validate(args: argparse.Namespace) -> None:
    if not DNS_LABEL.fullmatch(args.service_name):
        fail("service name must be a 3-63 character DNS label")
    if not OWNER_REF.fullmatch(args.owner) or args.owner not in args.allowed_owner:
        fail("owner is not an allowlisted Backstage Group entity")
    if not DNS_LABEL.fullmatch(args.system) or args.system not in args.allowed_system:
        fail("system is not an allowlisted Backstage System entity")
    if args.environment not in ENVIRONMENTS:
        fail("environment is unsupported")
    if args.data_classification not in CLASSIFICATIONS:
        fail("data classification is required and must be approved")
    if not REPOSITORY_OWNER.fullmatch(args.repository_owner):
        fail("repository owner is malformed")
    if args.repository_owner.casefold() not in {
        value.casefold() for value in args.allowed_repository_owner
    }:
        fail("repository target is not allowlisted")
    if args.gitops_repository != f"{args.repository_owner}/forgepath-gitops":
        fail("GitOps repository target must be the configured forgepath-gitops repository")
    if args.source.resolve() != (args.generation_root / args.service_name).resolve():
        fail("source must be the renderer-owned service directory")
    assert_child(args.generation_root, args.source, "source")
    if not (args.source / ".forgepath/onboarding.yaml").is_file():
        fail("rendered service is missing its immutable onboarding contract")
    if args.mode == "github":
        if not args.backstage_identity or re.fullmatch(
            r"user:[^/]+/guest", args.backstage_identity
        ):
            fail("GitHub publication requires an authenticated non-guest Backstage identity")
        if not os.environ.get("FORGEPATH_GITHUB_APP_TOKEN"):
            fail("GitHub publication requires FORGEPATH_GITHUB_APP_TOKEN")
        if not os.environ.get("FORGEPATH_BACKSTAGE_CATALOG_TOKEN"):
            fail("GitHub publication requires FORGEPATH_BACKSTAGE_CATALOG_TOKEN")


def run_git(repository: Path, *arguments: str) -> str:
    completed = subprocess.run(
        ["git", "-C", str(repository), *arguments],
        check=True,
        capture_output=True,
        text=True,
        env={
            **os.environ,
            "GIT_AUTHOR_NAME": "ForgePath Simulator",
            "GIT_AUTHOR_EMAIL": "forgepath-simulator@invalid.example",
            "GIT_COMMITTER_NAME": "ForgePath Simulator",
            "GIT_COMMITTER_EMAIL": "forgepath-simulator@invalid.example",
        },
    )
    return completed.stdout.strip()


def application_yaml(args: argparse.Namespace) -> str:
    namespace = f"{args.service_name}-{args.environment}"
    service_url = f"https://github.com/{args.repository_owner}/{args.service_name}.git"
    gitops_url = f"https://github.com/{args.gitops_repository}.git"
    return f"""apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: {namespace}
  namespace: argocd
  annotations:
    forgepath.dev/namespace-prerequisite: platform/namespaces/{namespace}.yaml
  labels:
    app.kubernetes.io/name: {args.service_name}
    app.kubernetes.io/part-of: {args.system}
spec:
  project: forgepath-{args.service_name}-{args.environment}
  sources:
    - repoURL: {service_url}
      targetRevision: main
      path: chart
      helm:
        releaseName: {args.service_name}
        valueFiles:
          - $values/environments/{args.environment}/{args.service_name}/values.yaml
    - repoURL: {gitops_url}
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: {namespace}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - ApplyOutOfSyncOnly=true
"""


def project_yaml(args: argparse.Namespace) -> str:
    namespace = f"{args.service_name}-{args.environment}"
    service_url = f"https://github.com/{args.repository_owner}/{args.service_name}.git"
    gitops_url = f"https://github.com/{args.gitops_repository}.git"
    return f"""apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: forgepath-{namespace}
  namespace: argocd
spec:
  description: Exact delivery boundary for {args.service_name} in {args.environment}
  sourceRepos:
    - {service_url}
    - {gitops_url}
  destinations:
    - namespace: {namespace}
      server: https://kubernetes.default.svc
  namespaceResourceWhitelist:
    - group: ""
      kind: ConfigMap
    - group: ""
      kind: Service
    - group: ""
      kind: ServiceAccount
    - group: argoproj.io
      kind: AnalysisTemplate
    - group: argoproj.io
      kind: Rollout
    - group: monitoring.coreos.com
      kind: PrometheusRule
    - group: monitoring.coreos.com
      kind: ServiceMonitor
  clusterResourceBlacklist:
    - group: "*"
      kind: "*"
"""


def namespace_prerequisite_yaml(args: argparse.Namespace) -> str:
    namespace = f"{args.service_name}-{args.environment}"
    return f"""apiVersion: v1
kind: Namespace
metadata:
  name: {namespace}
  labels:
    forgepath.dev/managed-by: platform
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.32
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: v1.32
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: v1.32
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: forgepath-namespace-boundary
  namespace: {namespace}
  labels: {{forgepath.dev/managed-by: platform}}
spec:
  hard:
    requests.cpu: "4"
    requests.memory: 4Gi
    limits.cpu: "12"
    limits.memory: 6Gi
    pods: "30"
    services: "10"
    configmaps: "20"
---
apiVersion: v1
kind: LimitRange
metadata:
  name: forgepath-namespace-boundary
  namespace: {namespace}
  labels: {{forgepath.dev/managed-by: platform}}
spec:
  limits:
    - type: Container
      defaultRequest: {{cpu: 100m, memory: 128Mi}}
      default: {{cpu: 500m, memory: 256Mi}}
      min: {{cpu: 10m, memory: 32Mi}}
      max: {{cpu: "1", memory: 512Mi}}
      maxLimitRequestRatio: {{cpu: "5", memory: "2"}}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: forgepath-platform-default-deny
  namespace: {namespace}
  labels: {{forgepath.dev/managed-by: platform}}
spec:
  podSelector: {{}}
  policyTypes: [Ingress, Egress]
  ingress: []
  egress: []
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: forgepath-platform-allow-prometheus
  namespace: {namespace}
  labels: {{forgepath.dev/managed-by: platform}}
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: {args.service_name}
      app.kubernetes.io/instance: {args.service_name}
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels: {{kubernetes.io/metadata.name: monitoring}}
          podSelector:
            matchLabels: {{app.kubernetes.io/name: prometheus}}
      ports:
        - {{protocol: TCP, port: 8080}}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: forgepath-platform-allow-dns
  namespace: {namespace}
  labels: {{forgepath.dev/managed-by: platform}}
spec:
  podSelector: {{}}
  policyTypes: [Egress]
  egress:
    - to:
        - namespaceSelector:
            matchLabels: {{kubernetes.io/metadata.name: kube-system}}
          podSelector:
            matchLabels: {{k8s-app: kube-dns}}
      ports:
        - {{protocol: UDP, port: 53}}
        - {{protocol: TCP, port: 53}}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: forgepath-platform-allow-rollouts-prometheus-egress
  namespace: {namespace}
  labels: {{forgepath.dev/managed-by: platform}}
spec:
  podSelector:
    matchLabels: {{app.kubernetes.io/name: argo-rollouts}}
  policyTypes: [Egress]
  egress:
    - to:
        - namespaceSelector:
            matchLabels: {{kubernetes.io/metadata.name: monitoring}}
          podSelector:
            matchLabels: {{app.kubernetes.io/name: prometheus}}
      ports:
        - {{protocol: TCP, port: 9090}}
"""


def gitops_files(args: argparse.Namespace) -> dict[str, bytes]:
    values = (args.source / "chart/values.yaml").read_bytes()
    base = f"environments/{args.environment}/{args.service_name}"
    return {
        f"applications/{args.service_name}-{args.environment}.yaml": application_yaml(args).encode(),
        f"projects/forgepath-{args.service_name}-{args.environment}.yaml": project_yaml(args).encode(),
        f"platform/namespaces/{args.service_name}-{args.environment}.yaml": namespace_prerequisite_yaml(args).encode(),
        f"{base}/values.yaml": values,
        f"{base}/request.json": json.dumps(
            {
                "requestedBy": args.backstage_identity,
                "owner": args.owner,
                "system": args.system,
                "environment": args.environment,
                "dataClassification": args.data_classification,
                "imagePromotion": "digest-only",
            },
            indent=2,
            sort_keys=True,
        ).encode()
        + b"\n",
    }


def initialize_repository(path: Path) -> None:
    path.mkdir(parents=True)
    run_git(path, "init", "--initial-branch=main")


def write_bytes(root: Path, files: dict[str, bytes]) -> None:
    for relative, content in files.items():
        target = root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content)


def local_publish(args: argparse.Namespace, started: float) -> dict[str, Any]:
    root = (args.simulation_root / args.service_name).resolve()
    assert_child(args.simulation_root, root, "simulation output")
    if root.exists():
        fail(f"simulation output already exists: {root}")
    service_repo = root / "service-repository"
    gitops_repo = root / "gitops-repository"
    initialize_repository(service_repo)
    request_to_repository = round(time.monotonic() - started, 3)
    shutil.copytree(args.source, service_repo, dirs_exist_ok=True)
    run_git(service_repo, "add", ".")
    run_git(service_repo, "commit", "-m", "Create secure FastAPI service")
    run_git(service_repo, "switch", "-c", "forgepath/enable-delivery")
    marker = service_repo / ".forgepath/onboarding.yaml"
    marker.write_text(marker.read_text() + "status: review-required\n", encoding="utf-8")
    run_git(service_repo, "add", ".forgepath/onboarding.yaml")
    run_git(service_repo, "commit", "-m", "Request protected delivery enablement")
    service_commit = run_git(service_repo, "rev-parse", "HEAD")
    request_to_first_pull_request = round(time.monotonic() - started, 3)

    initialize_repository(gitops_repo)
    (gitops_repo / "README.md").write_text(
        "# ForgePath local GitOps publication simulation\n", encoding="utf-8"
    )
    run_git(gitops_repo, "add", "README.md")
    run_git(gitops_repo, "commit", "-m", "Initialize simulated GitOps repository")
    branch = f"forgepath/onboard-{args.service_name}-{args.environment}"
    run_git(gitops_repo, "switch", "-c", branch)
    write_bytes(gitops_repo, gitops_files(args))
    run_git(gitops_repo, "add", ".")
    run_git(gitops_repo, "commit", "-m", f"Onboard {args.service_name} through GitOps")
    gitops_commit = run_git(gitops_repo, "rev-parse", "HEAD")

    result: dict[str, Any] = {
        "mode": "local",
        "remote": False,
        "requestedBy": args.backstage_identity,
        "serviceRepository": str(service_repo),
        "servicePullRequest": {
            "base": "main",
            "head": "forgepath/enable-delivery",
            "commit": service_commit,
            "requiredChecks": REQUIRED_CHECKS,
        },
        "catalogRegistration": str(service_repo / "catalog-info.yaml"),
        "gitopsRepository": str(gitops_repo),
        "gitopsPullRequest": {"base": "main", "head": branch, "commit": gitops_commit},
        "developerExperience": {
            "manualSteps": 1,
            "securityControlsInherited": 9,
            "kubernetesManifestsDevelopersMustUnderstand": 0,
            "requestToRepositorySeconds": request_to_repository,
            "requestToFirstPullRequestSeconds": request_to_first_pull_request,
            "requestToPublishedSeconds": round(time.monotonic() - started, 3),
            "requestToHealthySeconds": None,
        },
    }
    (root / "publication.json").write_text(
        json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    return result


class GitHub:
    def __init__(self, api_url: str, token: str) -> None:
        self.api_url = api_url.rstrip("/")
        self.token = token

    def request(self, method: str, path: str, payload: Any | None = None) -> Any:
        body = None if payload is None else json.dumps(payload).encode()
        request = urllib.request.Request(
            f"{self.api_url}{path}",
            data=body,
            method=method,
            headers={
                "Accept": "application/vnd.github+json",
                "Authorization": f"Bearer {self.token}",
                "Content-Type": "application/json",
                "X-GitHub-Api-Version": "2022-11-28",
                "User-Agent": "ForgePath-Backstage-Publisher",
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                content = response.read()
                return json.loads(content) if content else None
        except urllib.error.HTTPError as error:
            detail = error.read().decode(errors="replace")[:1000]
            fail(f"GitHub API {method} {path} failed with {error.code}: {detail}")

    def create_commit(
        self,
        repository: str,
        branch: str,
        files: dict[str, bytes],
        message: str,
        parent_sha: str | None = None,
        base_tree: str | None = None,
    ) -> str:
        tree: list[dict[str, str]] = []
        for relative, content in sorted(files.items()):
            blob = self.request(
                "POST",
                f"/repos/{repository}/git/blobs",
                {"content": base64.b64encode(content).decode(), "encoding": "base64"},
            )
            tree.append({"path": relative, "mode": "100644", "type": "blob", "sha": blob["sha"]})
        tree_payload: dict[str, Any] = {"tree": tree}
        if base_tree:
            tree_payload["base_tree"] = base_tree
        tree_sha = self.request(
            "POST", f"/repos/{repository}/git/trees", tree_payload
        )["sha"]
        commit_payload: dict[str, Any] = {"message": message, "tree": tree_sha}
        if parent_sha:
            commit_payload["parents"] = [parent_sha]
        commit_sha = self.request(
            "POST", f"/repos/{repository}/git/commits", commit_payload
        )["sha"]
        self.request(
            "POST",
            f"/repos/{repository}/git/refs",
            {"ref": f"refs/heads/{branch}", "sha": commit_sha},
        )
        return commit_sha


def source_files(source: Path) -> dict[str, bytes]:
    files: dict[str, bytes] = {}
    for path in sorted(source.rglob("*")):
        if path.is_symlink():
            fail(f"symbolic links are not publishable: {path}")
        if path.is_file():
            relative = path.relative_to(source).as_posix()
            content = path.read_bytes()
            if len(content) > 2 * 1024 * 1024:
                fail(f"generated file exceeds the 2 MiB publishing limit: {relative}")
            files[relative] = content
    return files


def github_publish(args: argparse.Namespace, started: float) -> dict[str, Any]:
    token = os.environ["FORGEPATH_GITHUB_APP_TOKEN"]
    github = GitHub(args.github_api_url, token)
    repository = f"{args.repository_owner}/{args.service_name}"
    github.request(
        "POST",
        f"/orgs/{urllib.parse.quote(args.repository_owner)}/repos",
        {
            "name": args.service_name,
            "description": f"Secure FastAPI service owned by {args.owner}",
            "private": True,
            "has_issues": True,
            "has_projects": False,
            "has_wiki": False,
            "auto_init": False,
        },
    )
    request_to_repository = round(time.monotonic() - started, 3)
    main_sha = github.create_commit(
        repository, "main", source_files(args.source), "Create secure FastAPI service"
    )
    main = github.request("GET", f"/repos/{repository}/git/commits/{main_sha}")
    onboarding = (args.source / ".forgepath/onboarding.yaml").read_bytes()
    branch = "forgepath/enable-delivery"
    service_branch_sha = github.create_commit(
        repository,
        branch,
        {".forgepath/onboarding.yaml": onboarding + b"status: review-required\n"},
        "Request protected delivery enablement",
        parent_sha=main_sha,
        base_tree=main["tree"]["sha"],
    )
    service_pr = github.request(
        "POST",
        f"/repos/{repository}/pulls",
        {
            "title": "Enable ForgePath protected delivery",
            "head": branch,
            "base": "main",
            "body": "Enables the reviewed trusted-artifact and GitOps delivery contract.",
        },
    )
    request_to_first_pull_request = round(time.monotonic() - started, 3)
    github.request(
        "PUT",
        f"/repos/{repository}/branches/main/protection",
        {
            "required_status_checks": {"strict": True, "contexts": REQUIRED_CHECKS},
            "enforce_admins": True,
            "required_pull_request_reviews": {
                "required_approving_review_count": 1,
                "require_code_owner_reviews": True,
            },
            "restrictions": None,
        },
    )

    gitops_repository = args.gitops_repository
    base = github.request("GET", f"/repos/{gitops_repository}/git/ref/heads/main")["object"]["sha"]
    base_commit = github.request("GET", f"/repos/{gitops_repository}/git/commits/{base}")
    gitops_branch = f"forgepath/onboard-{args.service_name}-{args.environment}"
    gitops_sha = github.create_commit(
        gitops_repository,
        gitops_branch,
        gitops_files(args),
        f"Onboard {args.service_name} through GitOps",
        parent_sha=base,
        base_tree=base_commit["tree"]["sha"],
    )
    gitops_pr = github.request(
        "POST",
        f"/repos/{gitops_repository}/pulls",
        {
            "title": f"Onboard {args.service_name} ({args.environment})",
            "head": gitops_branch,
            "base": "main",
            "body": "Adds this service's exact AppProject boundary, Argo CD Application, and immutable desired-state values.",
        },
    )
    catalog_target = (
        f"https://raw.githubusercontent.com/{repository}/main/catalog-info.yaml"
    )
    catalog_request = urllib.request.Request(
        f"{args.backstage_catalog_url.rstrip('/')}/locations",
        data=json.dumps({"type": "url", "target": catalog_target}).encode(),
        method="POST",
        headers={
            "Authorization": f"Bearer {os.environ['FORGEPATH_BACKSTAGE_CATALOG_TOKEN']}",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(catalog_request, timeout=30) as response:
            catalog_registration = json.loads(response.read())
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")[:1000]
        fail(f"Backstage catalog registration failed with {error.code}: {detail}")
    return {
        "mode": "github",
        "remote": True,
        "requestedBy": args.backstage_identity,
        "serviceRepository": f"https://github.com/{repository}",
        "serviceCommit": service_branch_sha,
        "servicePullRequest": service_pr["html_url"],
        "catalogInfoUrl": catalog_target,
        "catalogRegistration": catalog_registration,
        "gitopsRepository": f"https://github.com/{gitops_repository}",
        "gitopsCommit": gitops_sha,
        "gitopsPullRequest": gitops_pr["html_url"],
        "requiredChecks": REQUIRED_CHECKS,
        "developerExperience": {
            "manualSteps": 1,
            "securityControlsInherited": 9,
            "kubernetesManifestsDevelopersMustUnderstand": 0,
            "requestToRepositorySeconds": request_to_repository,
            "requestToFirstPullRequestSeconds": request_to_first_pull_request,
            "requestToPublishedSeconds": round(time.monotonic() - started, 3),
            "requestToHealthySeconds": None,
        },
    }


def main() -> None:
    started = time.monotonic()
    args = parse_args()
    validate(args)
    result = local_publish(args, started) if args.mode == "local" else github_publish(args, started)
    print(json.dumps(result, separators=(",", ":"), sort_keys=True))


if __name__ == "__main__":
    main()

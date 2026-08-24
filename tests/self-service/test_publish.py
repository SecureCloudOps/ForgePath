from __future__ import annotations

import argparse
import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "forgepath_publish",
    REPOSITORY_ROOT / "templates/secure-fastapi-service/publish.py",
)
assert SPEC and SPEC.loader
publish = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(publish)


class FakeResponse:
    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False

    def read(self) -> bytes:
        return b'{"entities":[{"kind":"Component"}]}'


class FakeGitHub:
    instances: list["FakeGitHub"] = []

    def __init__(self, _api_url: str, _token: str) -> None:
        self.calls: list[tuple[str, str, object | None]] = []
        self.commits: list[tuple[str, str, set[str]]] = []
        self.__class__.instances.append(self)

    def request(self, method: str, path: str, payload=None):
        self.calls.append((method, path, payload))
        if path.endswith("/git/ref/heads/main"):
            return {"object": {"sha": "gitops-main"}}
        if path.endswith("/git/commits/gitops-main"):
            return {"tree": {"sha": "gitops-tree"}}
        if path.endswith("/git/commits/service-main"):
            return {"tree": {"sha": "service-tree"}}
        if path.endswith("/pulls"):
            return {"html_url": f"https://github.test{path}/1"}
        return {}

    def create_commit(
        self,
        repository: str,
        branch: str,
        files: dict[str, bytes],
        _message: str,
        **_kwargs,
    ) -> str:
        self.commits.append((repository, branch, set(files)))
        return "service-main" if branch == "main" else f"sha-{branch}"


class GitHubPublisherContractTest(unittest.TestCase):
    def test_remote_path_is_allowlisted_protected_and_catalog_registered(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "generated/payments-api"
            (source / ".forgepath").mkdir(parents=True)
            (source / "chart").mkdir()
            (source / ".forgepath/onboarding.yaml").write_text("spec: {}\n")
            (source / "chart/values.yaml").write_text(
                'image:\n  digest: "sha256:' + "0" * 64 + '"\n'
            )
            (source / "catalog-info.yaml").write_text("kind: Component\n")
            args = argparse.Namespace(
                mode="github",
                source=source,
                generation_root=root / "generated",
                simulation_root=root / "published",
                service_name="payments-api",
                owner="group:default/platform",
                system="forgepath",
                environment="development",
                data_classification="confidential",
                repository_owner="SecureCloudOps",
                gitops_repository="SecureCloudOps/forgepath-gitops",
                backstage_identity="user:default/alice",
                allowed_owner=["group:default/platform"],
                allowed_system=["forgepath"],
                allowed_repository_owner=["SecureCloudOps"],
                github_api_url="https://github.test/api/v3",
                backstage_catalog_url="https://backstage.test/api/catalog",
            )
            with (
                patch.dict(
                    os.environ,
                    {
                        "FORGEPATH_GITHUB_APP_TOKEN": "synthetic-installation-token",
                        "FORGEPATH_BACKSTAGE_CATALOG_TOKEN": "synthetic-catalog-token",
                    },
                ),
                patch.object(publish, "GitHub", FakeGitHub),
                patch.object(publish.urllib.request, "urlopen", return_value=FakeResponse()) as urlopen,
            ):
                publish.validate(args)
                result = publish.github_publish(args, 0.0)

            github = FakeGitHub.instances[-1]
            protection = next(
                payload
                for method, path, payload in github.calls
                if method == "PUT" and path.endswith("/branches/main/protection")
            )
            self.assertEqual(
                protection["required_status_checks"]["contexts"], publish.REQUIRED_CHECKS
            )
            self.assertTrue(protection["enforce_admins"])
            self.assertTrue(
                protection["required_pull_request_reviews"]["require_code_owner_reviews"]
            )
            self.assertIn(
                (
                    "SecureCloudOps/forgepath-gitops",
                    "forgepath/onboard-payments-api-development",
                    {
                        "applications/payments-api-development.yaml",
                        "projects/forgepath-payments-api-development.yaml",
                        "platform/namespaces/payments-api-development.yaml",
                        "environments/development/payments-api/values.yaml",
                        "environments/development/payments-api/request.json",
                    },
                ),
                github.commits,
            )
            catalog_request = urlopen.call_args.args[0]
            self.assertEqual(catalog_request.method, "POST")
            self.assertEqual(
                json.loads(catalog_request.data)["target"],
                "https://raw.githubusercontent.com/SecureCloudOps/payments-api/main/catalog-info.yaml",
            )
            self.assertTrue(result["remote"])
            self.assertEqual(result["requestedBy"], "user:default/alice")


if __name__ == "__main__":
    unittest.main()

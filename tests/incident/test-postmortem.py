"""Tests for the measured incident postmortem renderer."""

from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "render-incident-postmortem.py"
SPEC = importlib.util.spec_from_file_location("incident_postmortem", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class IncidentPostmortemTest(unittest.TestCase):
    def make_fixture(self, directory: Path) -> Path:
        (directory / "request-events.csv").write_text(
            "epoch_seconds,delivery_role,path,status_code\n"
            "100.000,stable,/docs,200\n"
            "101.000,canary,/_test/failure,503\n"
            "102.000,stable,/docs,200\n"
            "103.000,canary,/_test/failure,503\n",
            encoding="utf-8",
        )
        (directory / "rollout-samples.jsonl").write_text(
            '{"epochSeconds":99,"updatedReplicas":1,"desiredReplicas":20,"stepIndex":1}\n',
            encoding="utf-8",
        )
        for filename in ("canary-logs.jsonl", "analysisrun.json", "git-diff.patch"):
            (directory / filename).write_text(f"synthetic {filename}\n", encoding="utf-8")
        context = {
            "schemaVersion": 1,
            "incidentId": "INC-TEST-001",
            "service": "secure-fastapi-service",
            "status": "resolved",
            "severity": "SEV-2 exercise",
            "responder": "test-responder",
            "objective": {"availabilityTarget": 0.999, "budgetWindow": "1h"},
            "timestamps": {
                "defectiveReleaseStartedAtEpochSeconds": 98,
                "detectedAtEpochSeconds": 111,
                "acknowledgedAtEpochSeconds": 116,
                "recoveryStartedAtEpochSeconds": 120,
                "restoredAtEpochSeconds": 141,
            },
            "errorBudgetRemainingRatio": 0,
            "rollback": {"control": "human-approved", "actor": "test-approver"},
            "revisions": {"healthy": "aaa", "defective": "bbb", "recovery": "ccc"},
            "impact": "A controlled canary returned HTTP 503 to synthetic traffic; stable traffic remained healthy.",
            "detection": "The fast-burn SLO alert fired before rollout analysis completed.",
            "rootCause": "The defective Git revision enabled the controlled failure fixture.",
            "contributingFactors": ["Demo alert windows intentionally accelerate detection."],
            "recovery": "A reviewed Git revert restored the prior desired state through Argo CD.",
            "correctiveActions": [
                {"id": "CA-1", "action": "Retain the exercise as a release gate.", "owner": "platform", "status": "open"}
            ],
            "detectionGaps": ["Notification transport is outside the local exercise."],
            "unverifiedHypotheses": [],
            "evidence": [
                {"id": "synthetic-requests", "path": "request-events.csv", "observation": "Two exact HTTP 503 responses."},
                {"id": "rollout-samples", "path": "rollout-samples.jsonl", "observation": "Exposure remained at one of twenty replicas."},
                {"id": "canary-logs", "path": "canary-logs.jsonl", "observation": "Canary logs correlate the failing route."},
                {"id": "analysisrun", "path": "analysisrun.json", "observation": "The SLO measurement failed."},
                {"id": "git-change", "path": "git-diff.patch", "observation": "The fixture was enabled by the defective revision."},
            ],
        }
        context_path = directory / "incident-context.json"
        context_path.write_text(json.dumps(context), encoding="utf-8")
        return context_path

    def test_renders_exact_metrics_and_required_postmortem_sections(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            context_path = self.make_fixture(directory)
            MODULE.render(context_path, directory)
            metrics = json.loads((directory / "incident-metrics.json").read_text(encoding="utf-8"))
            self.assertEqual(metrics["mttdSeconds"], 10.0)
            self.assertEqual(metrics["mttaSeconds"], 5.0)
            self.assertEqual(metrics["mttrSeconds"], 40.0)
            self.assertEqual(metrics["maximumCanaryExposurePercent"], 5.0)
            self.assertEqual(metrics["failedSyntheticRequests"], 2)
            self.assertEqual(metrics["errorBudgetConsumedRatio"], 1.0)
            self.assertEqual(metrics["rollbackControl"], "human-approved")
            report = (directory / "postmortem.md").read_text(encoding="utf-8")
            for section in (
                "## Impact",
                "## Timeline",
                "## Detection",
                "## Root cause",
                "## Contributing factors",
                "## Recovery",
                "## Corrective actions",
                "## Evidence used to diagnose",
            ):
                self.assertIn(section, report)

    def test_rejects_evidence_that_escapes_the_run_directory(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            context_path = self.make_fixture(directory)
            context = json.loads(context_path.read_text(encoding="utf-8"))
            context["evidence"][0]["path"] = "../outside.csv"
            context_path.write_text(json.dumps(context), encoding="utf-8")
            with self.assertRaises(MODULE.IncidentDataError):
                MODULE.render(context_path, directory)


if __name__ == "__main__":
    unittest.main()

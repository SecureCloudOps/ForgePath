#!/usr/bin/env python3
"""Render measured incident results and a postmortem from runtime evidence."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import sys
from datetime import UTC, datetime
from pathlib import Path
from typing import Any


class IncidentDataError(ValueError):
    """Raised when incident evidence is missing or internally inconsistent."""


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise IncidentDataError(f"cannot read JSON evidence {path}: {error}") from error


def require(mapping: dict[str, Any], key: str, expected_type: type) -> Any:
    value = mapping.get(key)
    if not isinstance(value, expected_type):
        raise IncidentDataError(f"{key} must be {expected_type.__name__}")
    return value


def finite_number(mapping: dict[str, Any], key: str) -> float:
    value = mapping.get(key)
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        raise IncidentDataError(f"{key} must be a number")
    result = float(value)
    if not math.isfinite(result):
        raise IncidentDataError(f"{key} must be finite")
    return result


def relative_evidence_path(base: Path, value: str) -> Path:
    candidate = Path(value)
    if candidate.is_absolute() or ".." in candidate.parts:
        raise IncidentDataError(f"evidence path must remain inside the run directory: {value}")
    resolved = (base / candidate).resolve()
    try:
        resolved.relative_to(base.resolve())
    except ValueError as error:
        raise IncidentDataError(f"evidence path escapes the run directory: {value}") from error
    if not resolved.is_file():
        raise IncidentDataError(f"evidence file does not exist: {value}")
    return resolved


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def iso8601(epoch_seconds: float) -> str:
    return datetime.fromtimestamp(epoch_seconds, UTC).isoformat(timespec="milliseconds").replace(
        "+00:00", "Z"
    )


def duration(later: float, earlier: float, label: str) -> float:
    result = round(later - earlier, 3)
    if result < 0:
        raise IncidentDataError(f"{label} cannot be negative")
    return result


def load_traffic(path: Path) -> tuple[int, int, float]:
    total = 0
    failed = 0
    first_failure: float | None = None
    with path.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        required = {"epoch_seconds", "delivery_role", "path", "status_code"}
        if reader.fieldnames is None or not required.issubset(reader.fieldnames):
            raise IncidentDataError("request-events.csv is missing required columns")
        for row in reader:
            total += 1
            try:
                status = int(row["status_code"])
                observed_at = float(row["epoch_seconds"])
            except (TypeError, ValueError) as error:
                raise IncidentDataError("request-events.csv contains an invalid row") from error
            if status >= 500:
                failed += 1
                if first_failure is None:
                    first_failure = observed_at
    if total == 0 or first_failure is None:
        raise IncidentDataError("traffic evidence must contain at least one request and one 5xx")
    return total, failed, first_failure


def load_max_exposure(path: Path) -> tuple[float, int, int]:
    maximum = -1.0
    maximum_updated = 0
    desired = 0
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        if not line.strip():
            continue
        try:
            sample = json.loads(line)
            sample_updated = int(sample["updatedReplicas"])
            sample_desired = int(sample["desiredReplicas"])
        except (KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
            raise IncidentDataError(f"invalid rollout sample on line {line_number}") from error
        if sample_desired <= 0 or sample_updated < 0:
            raise IncidentDataError(f"invalid replica count on rollout sample line {line_number}")
        exposure = 100.0 * sample_updated / sample_desired
        if exposure > maximum:
            maximum = exposure
            maximum_updated = sample_updated
            desired = sample_desired
    if maximum < 0:
        raise IncidentDataError("rollout evidence contains no samples")
    return round(maximum, 3), maximum_updated, desired


def markdown_list(items: list[str], empty: str = "None recorded.") -> str:
    return "\n".join(f"- {item}" for item in items) if items else empty


def render(context_path: Path, output_directory: Path) -> None:
    context = load_json(context_path)
    if not isinstance(context, dict):
        raise IncidentDataError("incident context must be a JSON object")
    if context.get("schemaVersion") != 1:
        raise IncidentDataError("schemaVersion must be 1")

    incident_id = require(context, "incidentId", str)
    service = require(context, "service", str)
    status = require(context, "status", str)
    if status != "resolved":
        raise IncidentDataError("postmortem can only be rendered for a resolved incident")
    severity = require(context, "severity", str)
    timestamps = require(context, "timestamps", dict)
    detected_at = finite_number(timestamps, "detectedAtEpochSeconds")
    acknowledged_at = finite_number(timestamps, "acknowledgedAtEpochSeconds")
    recovery_started_at = finite_number(timestamps, "recoveryStartedAtEpochSeconds")
    restored_at = finite_number(timestamps, "restoredAtEpochSeconds")
    release_started_at = finite_number(timestamps, "defectiveReleaseStartedAtEpochSeconds")

    evidence = require(context, "evidence", list)
    evidence_by_id: dict[str, dict[str, Any]] = {}
    evidence_manifest: list[dict[str, str]] = []
    for item in evidence:
        if not isinstance(item, dict):
            raise IncidentDataError("each evidence entry must be an object")
        evidence_id = require(item, "id", str)
        if evidence_id in evidence_by_id:
            raise IncidentDataError(f"duplicate evidence id: {evidence_id}")
        evidence_path_value = require(item, "path", str)
        observation = require(item, "observation", str)
        evidence_path = relative_evidence_path(output_directory, evidence_path_value)
        evidence_by_id[evidence_id] = item
        evidence_manifest.append(
            {
                "id": evidence_id,
                "path": evidence_path_value,
                "sha256": sha256(evidence_path),
                "observation": observation,
            }
        )

    traffic_entry = evidence_by_id.get("synthetic-requests")
    rollout_entry = evidence_by_id.get("rollout-samples")
    if traffic_entry is None or rollout_entry is None:
        raise IncidentDataError("synthetic-requests and rollout-samples evidence are required")
    traffic_path = relative_evidence_path(output_directory, traffic_entry["path"])
    rollout_path = relative_evidence_path(output_directory, rollout_entry["path"])
    total_requests, failed_requests, impact_started_at = load_traffic(traffic_path)
    max_exposure, max_updated, desired_replicas = load_max_exposure(rollout_path)

    if not (
        release_started_at <= impact_started_at <= detected_at <= acknowledged_at
        <= recovery_started_at <= restored_at
    ):
        raise IncidentDataError("incident timestamps are not in causal order")

    objective = require(context, "objective", dict)
    availability_target = finite_number(objective, "availabilityTarget")
    if not 0 < availability_target < 1:
        raise IncidentDataError("availabilityTarget must be between zero and one")
    budget_window = require(objective, "budgetWindow", str)
    error_budget_remaining = finite_number(context, "errorBudgetRemainingRatio")
    if not 0 <= error_budget_remaining <= 1:
        raise IncidentDataError("errorBudgetRemainingRatio must be between zero and one")

    rollback = require(context, "rollback", dict)
    rollback_control = require(rollback, "control", str)
    if rollback_control not in {"automatic", "human-approved"}:
        raise IncidentDataError("rollback.control must be automatic or human-approved")
    rollback_actor = require(rollback, "actor", str)
    responder = require(context, "responder", str)

    mttd = duration(detected_at, impact_started_at, "MTTD")
    mtta = duration(acknowledged_at, detected_at, "MTTA")
    mttr = duration(restored_at, impact_started_at, "MTTR")
    error_budget_consumed = round(1.0 - error_budget_remaining, 6)
    availability = round((total_requests - failed_requests) / total_requests, 6)

    metrics = {
        "incidentId": incident_id,
        "mttdSeconds": mttd,
        "mttaSeconds": mtta,
        "mttrSeconds": mttr,
        "maximumCanaryExposurePercent": max_exposure,
        "maximumCanaryReplicas": max_updated,
        "desiredReplicas": desired_replicas,
        "totalSyntheticRequests": total_requests,
        "failedSyntheticRequests": failed_requests,
        "observedAvailabilityRatio": availability,
        "errorBudgetConsumedRatio": error_budget_consumed,
        "errorBudgetWindow": budget_window,
        "rollbackControl": rollback_control,
        "rollbackActor": rollback_actor,
    }

    root_cause = require(context, "rootCause", str)
    impact = require(context, "impact", str)
    detection = require(context, "detection", str)
    recovery = require(context, "recovery", str)
    contributing_factors = require(context, "contributingFactors", list)
    corrective_actions = require(context, "correctiveActions", list)
    detection_gaps = require(context, "detectionGaps", list)
    unverified_hypotheses = require(context, "unverifiedHypotheses", list)
    if not all(isinstance(item, str) for item in contributing_factors + detection_gaps + unverified_hypotheses):
        raise IncidentDataError("factor, gap, and hypothesis entries must be strings")

    revisions = require(context, "revisions", dict)
    defective_revision = require(revisions, "defective", str)
    recovery_revision = require(revisions, "recovery", str)
    healthy_revision = require(revisions, "healthy", str)

    timeline_rows = [
        (release_started_at, "Defective release committed to the temporary Git remote."),
        (impact_started_at, "First synthetic customer request returned HTTP 5xx; incident impact began."),
        (detected_at, "ForgePathSLOFastBurn was first observed firing."),
        (acknowledged_at, f"{responder} acknowledged the alert and began evidence-led triage."),
        (recovery_started_at, f"Git recovery began after {rollback_control} authorization by {rollback_actor}."),
        (restored_at, "Argo CD and the Rollout were Healthy and a verification request succeeded."),
    ]
    timeline = "\n".join(
        f"| {iso8601(at)} | {event} |" for at, event in sorted(timeline_rows, key=lambda row: row[0])
    )

    evidence_rows = "\n".join(
        f"| `{item['id']}` | `{item['path']}` | `{item['sha256']}` | {item['observation']} |"
        for item in evidence_manifest
    )
    action_rows: list[str] = []
    for action in corrective_actions:
        if not isinstance(action, dict):
            raise IncidentDataError("each corrective action must be an object")
        action_rows.append(
            "| {id} | {action} | {owner} | {status} |".format(
                id=require(action, "id", str),
                action=require(action, "action", str),
                owner=require(action, "owner", str),
                status=require(action, "status", str),
            )
        )

    report = f"""# Postmortem: {incident_id} defective canary release

## Executive summary

{impact} The incident was detected in {mttd:.3f}s, acknowledged in {mtta:.3f}s,
and restored in {mttr:.3f}s. The canary never exceeded {max_exposure:g}% exposure.

## Impact

{impact}

- Affected service: {service}
- Availability objective: {availability_target:.3%}
- Failed synthetic requests: {failed_requests} of {total_requests}
- Observed synthetic availability: {availability:.3%}
- Availability error budget consumed: {error_budget_consumed:.3%} of the {budget_window} demo budget
- Maximum canary exposure: {max_exposure:g}% ({max_updated}/{desired_replicas} replicas)
- Severity: {severity}

## Timeline

| Time (UTC) | Event |
| --- | --- |
{timeline}

MTTD is measured from the first 5xx request to the first observation of the firing
alert. MTTA is measured from detection to acknowledgment. MTTR is measured from
the first 5xx request until desired state, Rollout health, and a verification
request all confirm restoration.

## Detection

{detection}

## Root cause

{root_cause}

The healthy Git revision was `{healthy_revision}`. The defective revision was
`{defective_revision}`.

## Contributing factors

{markdown_list(contributing_factors)}

## Recovery

{recovery}

- Recovery revision: `{recovery_revision}`
- Rollback control: `{rollback_control}`
- Recovery actor/approver: `{rollback_actor}`

## Evidence used to diagnose

These are the exact artifacts used for the conclusion above. SHA-256 hashes make
the retained evidence tamper-evident.

| Evidence ID | File | SHA-256 | Diagnostic observation |
| --- | --- | --- | --- |
{evidence_rows}

## Corrective actions

| ID | Action | Owner | Status |
| --- | --- | --- | --- |
{chr(10).join(action_rows)}

## Detection gaps

{markdown_list(detection_gaps)}

## Unverified hypotheses

{markdown_list(unverified_hypotheses)}
"""

    output_directory.mkdir(parents=True, exist_ok=True)
    (output_directory / "incident-metrics.json").write_text(
        json.dumps(metrics, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    (output_directory / "evidence-manifest.json").write_text(
        json.dumps({"incidentId": incident_id, "evidence": evidence_manifest}, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    (output_directory / "postmortem.md").write_text(report, encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--context", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()
    try:
        render(args.context.resolve(), args.output_dir.resolve())
    except IncidentDataError as error:
        print(f"incident postmortem validation failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

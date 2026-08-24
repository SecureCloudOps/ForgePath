#!/usr/bin/env python3
"""Report reproducible ForgePath developer-experience measurements."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("publication", type=Path)
    args = parser.parse_args()
    publication = json.loads(args.publication.read_text(encoding="utf-8"))
    metrics = publication["developerExperience"]
    report = {
        "measurementMode": publication["mode"],
        "timeToCreateServiceSeconds": metrics["requestToPublishedSeconds"],
        "manualSteps": metrics["manualSteps"],
        "securityControlsAutomaticallyInherited": metrics[
            "securityControlsInherited"
        ],
        "kubernetesManifestsDevelopersNeedToUnderstand": metrics[
            "kubernetesManifestsDevelopersMustUnderstand"
        ],
        "timeFromRequestToHealthyDeploymentSeconds": metrics[
            "requestToHealthySeconds"
        ],
        "healthyMeasurementStatus": (
            "measured"
            if metrics["requestToHealthySeconds"] is not None
            else "requires an approved runtime environment"
        ),
    }
    print(json.dumps(report, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()

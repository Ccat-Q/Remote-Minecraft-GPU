#!/usr/bin/env python3
"""Record actual isolated B1.1 binaries; frontend metadata is not GL acceptance."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

from prepare_mobileglues_probe import MOBILEGLUES


def verify_bundle(app):
    data = json.loads((app / "B11Provenance.json").read_text())
    expected = {"MobileGluesProbe": data["candidate_framework_sha256"]}
    for name in ("EGL", "GLESv2"):
        expected[name] = data["angle_artifact"]["framework_sha256"][name]
    frameworks = app / "Frameworks"
    if {path.name for path in frameworks.glob("*.framework")} != {name + ".framework" for name in expected}:
        raise ValueError("Independent app contains unexpected/missing frameworks")
    for name, value in expected.items():
        actual = hashlib.sha256((frameworks / (name + ".framework") / name).read_bytes()).hexdigest()
        if actual != value:
            raise ValueError(f"Bundled unsigned framework hash mismatch: {name}")
    return expected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify-app", type=Path)
    for name in ("angle", "recipe", "candidate", "output"):
        parser.add_argument("--" + name, type=Path)
    args = parser.parse_args()
    if args.verify_app:
        print(json.dumps(verify_bundle(args.verify_app), indent=2, sort_keys=True))
        return
    if not all((args.angle, args.recipe, args.candidate, args.output)):
        parser.error("Provide --angle --recipe --candidate --output, or --verify-app")
    angle = json.loads(args.angle.read_text())
    recipe = json.loads(args.recipe.read_text())
    source = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    if source != os.environ["GITHUB_SHA"] or recipe["mobileglues_sha"] != MOBILEGLUES:
        raise ValueError("Checkout/candidate provenance mismatch")
    subprocess.run(["git", "merge-base", "--is-ancestor", "6dd8b04c049da999b9dbd91e4c341f4a8b6d5e31", source], check=True)
    result = {
        "experiment": "B1.1 isolated frontend/backend provider and context test",
        "source_sha": source, "actions_run": os.environ["GITHUB_RUN_ID"],
        "accepted_a32_sha": "6dd8b04c049da999b9dbd91e4c341f4a8b6d5e31",
        "angle_artifact": angle, "mobileglues_recipe": recipe,
        "candidate_framework_sha256": hashlib.sha256(args.candidate.read_bytes()).hexdigest(),
        "framework_hash_scope": "unsigned before external signing; iOS resigning may change bytes",
        "provider_policy": "RTLD_FIRST explicit handles + per-entry dladdr validation; no RTLD_DEFAULT lookup",
        "capability_status": "UNVERIFIED: no guest/VirGL, GLSL 150 or complete GL 3.2 acceptance",
    }
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(args.output.read_text())


if __name__ == "__main__":
    main()

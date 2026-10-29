#!/usr/bin/env python3
"""Record actual isolated B1.1 binaries; frontend metadata is not GL acceptance."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

from prepare_mobileglues_probe import MOBILEGLUES

ACCEPTED_B11 = "d95d32be3d003f3c2c6c5a84b2f87132e4f6c7b2"
ACCEPTED_B12A = "c6c443facf52929f6caaa760f8bad675e4f4bde5"
ACCEPTED_B12B = "f91d6838b1534a65a8c7e6eecc4830a2e47c572d"
ACCEPTED_B12C = "e989b4d86d70d1fa15fbbde119bcdac9287ac6ba"


def experiment_scope(scope):
    if scope == "b11":
        return {"experiment": "B1.1 isolated frontend/backend provider and context test",
                "capability_status": "UNVERIFIED: no guest/VirGL, GLSL 150 or complete GL 3.2 acceptance"}
    if scope == "b12d":
        return {"experiment": "B1.2d isolated signed/float Texture Buffer and Geometry capability tests; not full B1.2 or guest acceptance",
                "accepted_b11_device_sha": ACCEPTED_B11, "accepted_b12a_device_sha": ACCEPTED_B12A,
                "accepted_b12b_device_sha": ACCEPTED_B12B, "accepted_b12c_device_sha": ACCEPTED_B12C,
                "capability_status": "DEVICE_PENDING: per-feature PASS/BLOCKED required; no full B1.2, cross-context sync, VirGL/guest or Minecraft acceptance"}
    if scope == "b12c":
        return {"experiment": "B1.2c isolated depth/stencil/blending; not full B1.2 or guest acceptance",
                "accepted_b11_device_sha": ACCEPTED_B11, "accepted_b12a_device_sha": ACCEPTED_B12A,
                "accepted_b12b_device_sha": ACCEPTED_B12B,
                "capability_status": "DEVICE_PENDING: representative depth/stencil/blending only; TextureBuffer, Geometry, cross-context sync and guest NOT ACCEPTED"}
    if scope == "b12b":
        return {"experiment": "B1.2b isolated instancing and same-context sync; not full B1.2 or guest acceptance",
                "accepted_b11_device_sha": ACCEPTED_B11, "accepted_b12a_device_sha": ACCEPTED_B12A,
                "capability_status": "DEVICE_PENDING: representative instancing and same-context sync only; cross-context, remaining features and guest NOT ACCEPTED"}
    if scope != "b12a":
        raise ValueError("Unknown isolated probe scope")
    return {"experiment": "B1.2a isolated GLSL150 vertex/fragment dynamic output; not full B1.2 or guest acceptance",
            "accepted_b11_device_sha": ACCEPTED_B11,
            "capability_status": "DEVICE_PENDING: representative shader/dynamic output only; remaining features and guest/VirGL NOT ACCEPTED"}


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
    parser.add_argument("--scope", choices=("b11", "b12a", "b12b", "b12c", "b12d"), default="b11")
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
    if args.scope in ("b12a", "b12b", "b12c", "b12d"):
        subprocess.run(["git", "merge-base", "--is-ancestor", ACCEPTED_B11, source], check=True)
    if args.scope in ("b12b", "b12c", "b12d"):
        subprocess.run(["git", "merge-base", "--is-ancestor", ACCEPTED_B12A, source], check=True)
    if args.scope in ("b12c", "b12d"):
        subprocess.run(["git", "merge-base", "--is-ancestor", ACCEPTED_B12B, source], check=True)
    if args.scope == "b12d":
        subprocess.run(["git", "merge-base", "--is-ancestor", ACCEPTED_B12C, source], check=True)
    result = {
        **experiment_scope(args.scope),
        "source_sha": source, "actions_run": os.environ["GITHUB_RUN_ID"],
        "accepted_a32_sha": "6dd8b04c049da999b9dbd91e4c341f4a8b6d5e31",
        "angle_artifact": angle, "mobileglues_recipe": recipe,
        "candidate_framework_sha256": hashlib.sha256(args.candidate.read_bytes()).hexdigest(),
        "framework_hash_scope": "unsigned before external signing; iOS resigning may change bytes",
        "provider_policy": "RTLD_FIRST explicit handles + per-entry dladdr validation; no RTLD_DEFAULT lookup",
    }
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(args.output.read_text())


if __name__ == "__main__":
    main()

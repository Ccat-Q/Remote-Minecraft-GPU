#!/usr/bin/env python3
"""Embed verified artifact provenance, not guessed dependency version strings."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

A1 = "f7413ff245b06c27aa1fbb9b3dcbd527ba32be42"


def command(*args):
    return subprocess.check_output(args, text=True)


def revision_from_log(log):
    revisions = set(re.findall(r"UTM_REVISION: ([0-9a-f]{40})", log))
    if len(revisions) != 1:
        raise ValueError("Cannot identify exactly one actual UTM revision in renderer build log")
    return revisions.pop()


def pins_from_source(source):
    result = {}
    for variable in ("VIRGLRENDERER", "WEBKIT", "EPOXY"):
        match = re.search(rf'^{variable}_COMMIT="([0-9a-f]{{40}})"$', source, re.M)
        if not match:
            raise ValueError(f"Missing immutable {variable} source pin")
        result[variable.lower()] = match[1]
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--renderer-run-id", required=True)
    parser.add_argument("--sysroot", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    source = command("git", "rev-parse", "HEAD").strip()
    if source != os.environ["GITHUB_SHA"]:
        raise ValueError("App checkout does not match workflow source SHA")
    subprocess.run(["git", "merge-base", "--is-ancestor", A1, source], check=True)
    repository = os.environ["GITHUB_REPOSITORY"]
    run = json.loads(command("gh", "api", f"repos/{repository}/actions/runs/{args.renderer_run_id}"))
    if run["conclusion"] != "success" or run["name"] != "Build iOS renderer sysroot":
        raise ValueError("Unverified renderer run")
    jobs = json.loads(command("gh", "api", f"repos/{repository}/actions/runs/{args.renderer_run_id}/jobs"))["jobs"]
    render_jobs = [job for job in jobs if job["name"] == "UTM ANGLE/virglrenderer iOS arm64 sysroot"]
    if len(render_jobs) != 1 or render_jobs[0]["conclusion"] != "success":
        raise ValueError("Renderer job missing or failed")
    log = command("gh", "api", f"repos/{repository}/actions/jobs/{render_jobs[0]['id']}/logs")
    utm = revision_from_log(log)
    sources = command("gh", "api", "-H", "Accept: application/vnd.github.raw+json",
                      f"repos/utmapp/UTM/contents/patches/sources?ref={utm}")
    recipe = command("gh", "api", "-H", "Accept: application/vnd.github.raw+json",
                     f"repos/{repository}/contents/tools/ci/prepare_utm_renderer.py?ref={run['head_sha']}")
    frameworks = {}
    for name in ("EGL", "GLESv2", "virglrenderer.1", "epoxy.0"):
        binary = args.sysroot / "Frameworks" / f"{name}.framework" / name
        frameworks[name] = hashlib.sha256(binary.read_bytes()).hexdigest()
    data = {
        "app_source_sha": source, "accepted_a1_sha": A1,
        "app_actions_run": os.environ["GITHUB_RUN_ID"],
        "renderer_actions_run": args.renderer_run_id, "sysroot_recipe_source_sha": run["head_sha"],
        "utm_sha": utm, "dependency_source_sha": pins_from_source(sources),
        "compat_recipe_sha256": hashlib.sha256(recipe.encode()).hexdigest(),
        "framework_sha256": frameworks,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
    print(args.output.read_text())


if __name__ == "__main__":
    main()

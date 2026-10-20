#!/usr/bin/env python3

"""Verify one complete SDK run and prepare its exact bytes for publication."""

import hashlib
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path


ARCHES = (
    "aarch64_cortex-a53", "aarch64_cortex-a72", "aarch64_generic",
    "arm_cortex-a7_neon-vfpv4", "arm_cortex-a9", "arm_cortex-a9_neon",
    "i386_pentium4", "x86_64",
)
SDKS = ("24.10", "25.12")
PACKAGES = ("dae", "daed", "luci-app-daede", "vmlinux-btf")


def fail(message):
    raise SystemExit("prepare-release-assets: " + message)


def digest(path):
    sha = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            sha.update(chunk)
    return sha.hexdigest()


def copy_once(source, target):
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        if digest(source) != digest(target):
            fail("conflicting release asset: " + target.name)
    else:
        shutil.copyfile(source, target)


def package_version(sha, package):
    source = subprocess.run(
        ["git", "show", f"{sha}:{package}/Makefile"],
        check=True, capture_output=True, text=True,
    ).stdout
    fields = dict(re.findall(r"^(PKG_VERSION|PKG_RELEASE):=(.+)$", source, re.MULTILINE))
    if set(fields) != {"PKG_VERSION", "PKG_RELEASE"}:
        fail("missing package version or release: " + package)
    return fields["PKG_VERSION"] + "-r" + fields["PKG_RELEASE"]


def collect(root, output, sha, run_id):
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        fail("candidate SHA must be 40 lowercase hex characters")
    if not run_id.isdecimal():
        fail("build run ID must be numeric")
    expected = {f"packages-sdk{sdk}-{arch}" for sdk in SDKS for arch in ARCHES}
    found = {path.name for path in root.iterdir() if path.is_dir()}
    if found != expected:
        fail(f"artifact sets differ: missing={sorted(expected - found)} extra={sorted(found - expected)}")
    if output.exists():
        fail("output directory already exists: " + str(output))
    output.mkdir(parents=True)
    versions = {package: package_version(sha, package) for package in PACKAGES if package != "vmlinux-btf"}

    for sdk in SDKS:
        for arch in ARCHES:
            artifact = root / f"packages-sdk{sdk}-{arch}"
            feed = artifact / "feed"
            release = artifact / "release"
            if not feed.is_dir() or not release.is_dir():
                fail("missing feed or release directory: " + artifact.name)
            package_files = [path for path in feed.iterdir() if path.is_file() and path.suffix in (".apk", ".ipk")]
            suffix = ".ipk" if sdk == "24.10" else ".apk"
            for package in PACKAGES:
                matches = [path for path in package_files if path.name.startswith((package + "_", package + "-"))]
                if len(matches) != 1 or matches[0].suffix != suffix:
                    fail(f"{artifact.name}: expected one {package} {suffix}, found {len(matches)}")
                if package in versions:
                    expected_name = package + ("_" if sdk == "24.10" else "-") + versions[package]
                    if not matches[0].name.startswith(expected_name + ("_" if sdk == "24.10" else ".")):
                        fail(f"{artifact.name}: {package} version differs from the candidate Makefile")
            index_names = ("Packages.gz",) if sdk == "24.10" else ("packages.adb",)
            if any(not (feed / name).is_file() for name in index_names):
                fail("missing feed index: " + artifact.name)
            for source in feed.iterdir():
                if source.is_file():
                    copy_once(source, output / "feed" / sdk / arch / source.name)
            for source in release.iterdir():
                if source.is_file():
                    copy_once(source, output / "release" / source.name)

            # Emit a per-arch manifest-daede.txt in the key=value format that
            # scripts/install.sh expects (package name and sha256 per line).
            manifest_lines = []
            for package in ("dae", "daed", "luci-app-daede"):
                pkg_matches = [p for p in package_files
                               if p.name.startswith((package + "_", package + "-"))]
                if len(pkg_matches) != 1:
                    continue
                name = pkg_matches[0].name
                copied = output / "feed" / sdk / arch / name
                manifest_lines.append(f"{package}={name}")
                manifest_lines.append(f"{package}_sha256={digest(copied)}")
            if manifest_lines:
                (output / "feed" / sdk / arch / "manifest-daede.txt").write_text(
                    "\n".join(manifest_lines) + "\n")

    files = []
    for path in sorted(output.rglob("*")):
        if path.is_file():
            files.append({"path": str(path.relative_to(output)), "size": path.stat().st_size, "sha256": digest(path)})
    manifest = {"candidate_sha": sha, "build_run_id": int(run_id), "files": files}
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"verified {len(expected)} SDK package sets and {len(files)} files")


if __name__ == "__main__":
    if len(sys.argv) != 5:
        fail("usage: prepare-release-assets.py <artifact-dir> <output-dir> <candidate-sha> <build-run-id>")
    collect(Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3], sys.argv[4])

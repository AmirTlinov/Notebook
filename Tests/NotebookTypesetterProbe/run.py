#!/usr/bin/env python3
"""Build/run only the isolated physical-iPad typesetting feasibility probe."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path(__file__).resolve().parent
STAGE = ROOT / ".build/print-layout-spike"
TECTONIC = "66b6654103501b0a4a6926a7c450264be59cf927"
VCPKG = "e6f9e70a29a3e80a1fc510d8503304315447112f"
BUNDLE = "com.amirtlinov.notebook.typeset-probe"


def run(args, *, cwd=ROOT, log=None, env=None):
    print("+", " ".join(map(str, args)), flush=True)
    if log:
        with (STAGE / log).open("w") as output:
            subprocess.run(list(map(str, args)), cwd=cwd, env=env, stdout=output,
                           stderr=subprocess.STDOUT, check=True)
    else:
        subprocess.run(list(map(str, args)), cwd=cwd, env=env, check=True)


def sha(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def checkout(name, url, revision, patch):
    folder = STAGE / name
    if not folder.exists():
        run(["git", "init", folder])
        run(["git", "remote", "add", "origin", url], cwd=folder)
        run(["git", "fetch", "--depth", "1", "origin", revision], cwd=folder)
        run(["git", "checkout", "--detach", revision], cwd=folder)
    actual = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=folder, text=True).strip()
    if actual != revision:
        raise RuntimeError(f"{name}: wrong upstream commit {actual}; refusing to overwrite checkout")
    diff = subprocess.check_output(["git", "diff"], cwd=folder)
    expected = (SOURCE / patch).read_bytes()
    if not diff:
        run(["git", "apply", SOURCE / patch], cwd=folder)
    elif diff != expected:
        raise RuntimeError(f"{name}: unrecognized local patch; refusing to overwrite changes")
    return folder


def source_identity():
    files = [p for p in SOURCE.rglob("*") if p.is_file() and "__pycache__" not in p.parts]
    files += [ROOT / "Sources/NotebookMarkupService/Resources/notebook-markup.js",
              ROOT / "Sources/NotebookMarkupService/TeXResources.lock.json"]
    return {str(p.relative_to(ROOT)): sha(p) for p in sorted(files)}


def assert_native_slot():
    if subprocess.run(["pgrep", "-x", "xcodebuild"], capture_output=True).returncode == 0:
        raise RuntimeError("Another Xcode runner is active; wait for the agreed native slot")


def build(runtime):
    assert_native_slot()
    lock = json.loads((ROOT / "Sources/NotebookMarkupService/TeXResources.lock.json").read_text())
    bundle = runtime / "Resources/NotebookTeX/texlive.zip"
    expected = lock["distribution"]["zip"]
    if not bundle.is_file() or bundle.stat().st_size != expected["bytes"] or sha(bundle) != expected["sha256"]:
        raise RuntimeError("Prepare the pinned Notebook TeX runtime; bundle bytes do not match the lock")
    identity = source_identity()
    tectonic = checkout("tectonic", "https://github.com/tectonic-typesetting/tectonic.git", TECTONIC, "tectonic.patch")
    run(["git", "submodule", "update", "--init", "--depth", "1", "crates/bridge_harfbuzz/harfbuzz"], cwd=tectonic, log="harfbuzz-clone.log")
    vcpkg = checkout("vcpkg", "https://github.com/microsoft/vcpkg.git", VCPKG, "vcpkg.patch")
    if not (vcpkg / "vcpkg").is_file():
        run([vcpkg / "bootstrap-vcpkg.sh", "-disableMetrics"], cwd=vcpkg, log="vcpkg-bootstrap.log")
    env = dict(os.environ, VCPKG_MAX_CONCURRENCY="4")
    run([vcpkg / "vcpkg", "install", "libpng", "freetype", "graphite2", "icu", "--triplet", "arm64-ios", "--clean-after-build"], env=env, log="ios-dependencies.log")
    bridge = STAGE / "bridge"
    shutil.copytree(SOURCE / "bridge", bridge, dirs_exist_ok=True)
    # A previous manually-created diagnostic CLI is not part of this build.
    # Build --lib explicitly; never remove unrelated files from the stage.
    env.update(VCPKG_ROOT=str(vcpkg), VCPKGRS_TRIPLET="arm64-ios", TECTONIC_DEP_BACKEND="vcpkg", CARGO_TARGET_DIR=str(tectonic / "target"))
    run(["cargo", "build", "--manifest-path", bridge / "Cargo.toml", "--lib", "--target", "aarch64-apple-ios", "--release", "--locked", "-j", "2"], env=env, log="bridge-build.log")
    device = STAGE / "device"
    (device / "Resources").mkdir(parents=True, exist_ok=True)
    shutil.copytree(SOURCE / "app", device / "Sources", dirs_exist_ok=True)
    shutil.copyfile(SOURCE / "project.yml", device / "project.yml")
    notices = device / "Resources/Notices"
    notices.mkdir(exist_ok=True)
    shutil.copytree(runtime / "Resources/NotebookTeX/licenses", notices / "tex-bundle", dirs_exist_ok=True)
    for library in (vcpkg / "installed/arm64-ios/share").iterdir():
        copyright = library / "copyright"
        if copyright.is_file():
            shutil.copyfile(copyright, notices / (library.name + ".txt"))
    shutil.copyfile(tectonic / "LICENSE", notices / "Tectonic.txt")
    shutil.copyfile(tectonic / "crates/bridge_harfbuzz/harfbuzz/COPYING", notices / "HarfBuzz.txt")
    destination = device / "Resources/texlive.zip"
    if not destination.exists() or sha(destination) != expected["sha256"]:
        run(["cp", "-c", bundle, destination])
    shutil.copyfile(ROOT / "Sources/NotebookMarkupService/Resources/notebook-markup.js", device / "Resources/notebook-markup.js")
    assert_native_slot()
    run(["xcodegen", "generate", "--spec", device / "project.yml"], log="device-generate.log")
    run(["xcodebuild", "-quiet", "-project", device / "NotebookTypesetProbe.xcodeproj", "-scheme", "NotebookTypesetProbe", "-destination", "generic/platform=iOS", "-derivedDataPath", STAGE / "device-build", "-allowProvisioningUpdates", "build"], log="device-build.log")
    if source_identity() != identity:
        raise RuntimeError("Probe sources changed during build")
    app = STAGE / "device-build/Build/Products/Debug-iphoneos/NotebookTypesetProbe.app"
    receipt = dict(sources=identity, tectonic=TECTONIC, vcpkg=VCPKG, texBundleSHA256=expected["sha256"],
                   executableSHA256=sha(app / "NotebookTypesetProbe"),
                   rustc=subprocess.check_output(["rustc", "--version"], text=True).strip())
    (STAGE / "build-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")


def physical(device):
    assert_native_slot()
    receipt_path = STAGE / "build-receipt.json"
    receipt = json.loads(receipt_path.read_text())
    if receipt["sources"] != source_identity():
        raise RuntimeError("Sources differ from the built probe; build again")
    listing = STAGE / "devices.json"
    run(["xcrun", "devicectl", "list", "devices", "--json-output", listing], log="device-list.log")
    devices = json.loads(listing.read_text())["result"]["devices"]
    match = next((d for d in devices if device in (d.get("identifier"), d.get("properties", {}).get("hardware", {}).get("udid"))), None)
    if not match or match.get("properties", {}).get("hardware", {}).get("reality") != "physical":
        raise RuntimeError("--device must identify a connected physical device")
    app = STAGE / "device-build/Build/Products/Debug-iphoneos/NotebookTypesetProbe.app"
    if sha(app / "NotebookTypesetProbe") != receipt["executableSHA256"]:
        raise RuntimeError("Executable changed since build receipt")
    run(["xcrun", "devicectl", "device", "install", "app", "--device", device, app], log="device-install.log")
    log = STAGE / "device-run.log"
    with log.open("w") as output:
        command = ["xcrun", "devicectl", "device", "process", "launch", "--device", device, "--terminate-existing", "--console", BUNDLE, "--acceptance"]
        process = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 180
            while time.monotonic() < deadline:
                content = log.read_text(errors="replace")
                if "TYPESET_ACCEPTANCE_DONE" in content or "TYPESET_ACCEPTANCE_ERROR" in content:
                    break
                if process.poll() is not None:
                    raise RuntimeError("Probe exited without completion; inspect device-run.log")
                time.sleep(0.2)
            else:
                raise RuntimeError("Probe did not finish in 180 s; investigate, do not retry blindly")
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill(); process.wait()
    destination = STAGE / "device-output"
    destination.mkdir(exist_ok=True)
    run(["xcrun", "devicectl", "device", "copy", "from", "--device", device, "--domain-type", "appDataContainer", "--domain-identifier", BUNDLE, "--source", "Documents", "--destination", destination], log="device-copy.log")
    content = log.read_text(errors="replace")
    if "TYPESET_ACCEPTANCE_DONE 0 failures" not in content:
        raise RuntimeError("Physical probe failed; inspect device-run.log")
    receipt.update(device=device, completedAt=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                   reportSHA256=sha(destination / "report.txt"), scope="isolated typesetter; NOT Notebook editor acceptance")
    (STAGE / "physical-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print("PASS: isolated typesetter only; editor integration remains open")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", action="store_true")
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--tex-runtime", type=Path, default=ROOT / ".build/notebook-tex-runtime")
    parser.add_argument("--device")
    args = parser.parse_args()
    if not args.build and not args.run:
        parser.error("choose --build and/or --run")
    if args.run and not args.device:
        parser.error("--run requires a physical --device")
    STAGE.mkdir(parents=True, exist_ok=True)
    if args.build:
        build(args.tex_runtime.resolve())
    if args.run:
        physical(args.device)

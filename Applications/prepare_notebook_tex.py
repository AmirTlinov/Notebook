#!/usr/bin/env python3
"""Build-time, pinned TeX resources; never reads the user's Tectonic cache.

The runtime receives this immutable distribution in the markup XPC bundle.
Only --prepare downloads. --check is read-only, including in frozen builds.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request
import zipfile
import zlib


ROOT = Path(__file__).resolve().parent.parent
LOCK = ROOT / "Sources/NotebookMarkupService/TeXResources.lock.json"


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def verify(path: Path, expected: dict) -> None:
    if path.is_symlink() or not path.is_file():
        raise RuntimeError(f"Missing regular TeX resource: {path}")
    if path.stat().st_size != expected["bytes"] or digest(path) != expected["sha256"]:
        raise RuntimeError(f"TeX resource does not match its source pin: {path}")


def obtain(artifact: dict, cache: Path) -> Path:
    path = cache / artifact["name"]
    if path.exists():
        verify(path, artifact)
        return path
    partial = path.with_name(path.name + ".downloading")
    print(f"Preparing pinned TeX input: {artifact['name']} ({artifact['bytes']} bytes)", flush=True)
    request = urllib.request.Request(artifact["url"], headers={"User-Agent": "Notebook-TeX-Resource-Builder/1"})
    try:
        with urllib.request.urlopen(request, timeout=60) as source, partial.open("wb") as output:
            shutil.copyfileobj(source, output, 1024 * 1024)
        verify(partial, artifact)
        partial.replace(path)
    finally:
        partial.unlink(missing_ok=True)
    return path


def create_distribution(archive: Path, target: Path, pin: dict) -> dict:
    names: set[str] = set()
    source_bytes = 0
    forbidden = []
    bundle_digest = None
    # Fixed timestamps, mode, order and compression settings make the output
    # repeatable. A zlib change must explicitly update the checked output pin.
    with tarfile.open(archive, "r:") as source, zipfile.ZipFile(target, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6, allowZip64=True) as output:
        for member in source:
            name = member.name
            if not member.isfile() or PurePosixPath(name).name != name or name in (".", "..") or name in names:
                raise RuntimeError(f"Unexpected distribution member: {name}")
            # The official distribution contains package illustrations/PDFs.
            # It contains no user's documents, logs, auxiliaries or formats.
            if Path(name).suffix.lower() in (".fmt", ".aux", ".log"):
                forbidden.append(name)
            names.add(name)
            source_bytes += member.size
            entry = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            entry.create_system = 3
            entry.external_attr = 0o100644 << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            entry._compresslevel = 6
            with source.extractfile(member) as data:
                if name == "SHA256SUM":
                    contents = data.read()
                    bundle_digest = contents.decode("ascii").strip()
                    output.writestr(entry, contents)
                else:
                    with output.open(entry, "w") as destination:
                        shutil.copyfileobj(data, destination, 1024 * 1024)
    if forbidden or bundle_digest != pin["bundleDigest"] or len(names) != pin["fileCount"]:
        raise RuntimeError(f"Unexpected TeX inventory: forbidden={forbidden}, digest={bundle_digest}, count={len(names)}")
    return {"fileCount": len(names), "sourceBytes": source_bytes, "privateFormats": 0,
            "auxiliaries": 0, "logs": 0, "bundleDigest": bundle_digest, "zlib": zlib.ZLIB_VERSION}


def check(stage: Path, lock: dict) -> dict:
    manifest_path = stage / "Resources/NotebookTeX/manifest.json"
    manifest = json.loads(manifest_path.read_text())
    if manifest["sourceLockSHA256"] != digest(LOCK):
        raise RuntimeError("Prepared TeX resources use a different source lock")
    if manifest["schema"] != 1 or any(manifest[key] != lock[key] for key in ("compiler", "distribution", "licenses")):
        raise RuntimeError("Prepared TeX manifest does not match its source lock")
    expected = {"Helpers/tectonic": lock["compiler"]["executable"],
                "Resources/NotebookTeX/texlive.zip": lock["distribution"]["zip"]}
    expected.update({f"Resources/NotebookTeX/licenses/{item['name']}": item for item in lock["licenses"]})
    paths = {str(path.relative_to(stage)) for path in stage.rglob("*") if not path.is_dir()}
    if paths != set(expected) | {"Resources/NotebookTeX/manifest.json"}:
        raise RuntimeError("TeX stage contains missing or untracked resources")
    for relative, artifact in expected.items():
        verify(stage / relative, artifact)
    if manifest["inventory"]["fileCount"] != lock["distribution"]["fileCount"] or any(manifest["inventory"][key] != 0 for key in ("privateFormats", "auxiliaries", "logs")):
        raise RuntimeError("Prepared TeX inventory does not match the full pinned distribution")
    return manifest


def prepare(stage: Path, cache: Path, lock: dict, record_output_pin: bool) -> dict:
    cache.mkdir(parents=True, exist_ok=True)
    if stage.exists() and not record_output_pin:
        return check(stage, lock)
    compiler = obtain(lock["compiler"], cache)
    distribution = obtain(lock["distribution"], cache)
    license_paths = [(item, obtain(item, cache)) for item in lock["licenses"]]
    stage.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix="notebook-tex-stage-", dir=stage.parent))
    try:
        helpers = temporary / "Helpers"
        resources = temporary / "Resources/NotebookTeX"
        helpers.mkdir(); (resources / "licenses").mkdir(parents=True)
        with tarfile.open(compiler, "r:gz") as source:
            members = source.getmembers()
            if len(members) != 1 or members[0].name != "tectonic" or not members[0].isfile():
                raise RuntimeError("The compiler release archive has unexpected members")
            with source.extractfile(members[0]) as data, (helpers / "tectonic").open("wb") as output:
                shutil.copyfileobj(data, output)
        (helpers / "tectonic").chmod(0o755)
        verify(helpers / "tectonic", lock["compiler"]["executable"])
        libraries = subprocess.check_output(["/usr/bin/otool", "-L", str(helpers / "tectonic")], text=True).splitlines()[1:]
        if any(not line.strip().startswith(("/System/Library/", "/usr/lib/")) for line in libraries):
            raise RuntimeError("The pinned compiler unexpectedly depends on a non-system dynamic library")
        inventory = create_distribution(distribution, resources / "texlive.zip", lock["distribution"])
        if record_output_pin:
            lock["distribution"]["zip"] = {"bytes": (resources / "texlive.zip").stat().st_size,
                                             "sha256": digest(resources / "texlive.zip")}
            LOCK.write_text(json.dumps(lock, ensure_ascii=False, indent=2) + "\n")
        verify(resources / "texlive.zip", lock["distribution"]["zip"])
        for item, path in license_paths:
            shutil.copyfile(path, resources / "licenses" / item["name"])
        manifest = {"schema": 1, "sourceLockSHA256": digest(LOCK), "inventory": inventory,
                    "compiler": lock["compiler"], "distribution": lock["distribution"], "licenses": lock["licenses"]}
        (resources / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
        check(temporary, lock)
        if stage.exists():
            raise RuntimeError("Refusing to replace an existing resource stage; prepare a new stage directory")
        temporary.replace(stage)
        return manifest
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group(required=True)
    modes.add_argument("--prepare", action="store_true")
    modes.add_argument("--check", action="store_true")
    parser.add_argument("--stage", type=Path, default=Path(os.environ.get("NOTEBOOK_TEX_RUNTIME", ROOT / ".build/notebook-tex-runtime")))
    parser.add_argument("--cache", type=Path, default=ROOT / ".build/notebook-tex-upstream")
    parser.add_argument("--record-output-pin", action="store_true", help="Maintainer operation after explicitly changing upstream pins; never used by builds")
    args = parser.parse_args()
    if args.record_output_pin and not args.prepare:
        parser.error("--record-output-pin requires --prepare")
    lock = json.loads(LOCK.read_text())
    result = prepare(args.stage.resolve(), args.cache.resolve(), lock, args.record_output_pin) if args.prepare else check(args.stage.resolve(), lock)
    print(json.dumps({"status": "ready", "stage": str(args.stage.resolve()), "sourceLockSHA256": result["sourceLockSHA256"],
                      "distributionFiles": result["inventory"]["fileCount"], "distributionBytes": result["distribution"]["zip"]["bytes"]}))


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Stage the pinned official runtimes; no login/config/daemon side effects."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

CODEX_VERSION = "0.155.0"
NODE_VERSION = "v24.21.0"
ASSETS = {
    "arm64": ("aarch64", "b1411ec00ac410467e05cf8fb5b063cf83632613530201cd4724ef8dd0e9c33f",
              "bed7eea5325e1108f32ce5228ddd6a5f0f08a499ee42aa7442aea583702f6057"),
}


def checked_download(url, destination, expected):
    with urllib.request.urlopen(url, timeout=60) as response, destination.open("wb") as output:
        shutil.copyfileobj(response, output)
    if hashlib.file_digest(destination.open("rb"), "sha256").hexdigest() != expected:
        raise RuntimeError("Runtime archive checksum mismatch")


def signature(path, identifier, team):
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", "-R",
        f'=anchor apple generic and identifier "{identifier}" and certificate leaf[subject.OU] = "{team}"', str(path)], check=True)


def prepare(stage):
    arch = platform.machine()
    if arch not in ASSETS:
        raise RuntimeError("Notebook Codex runtime is currently admitted only for Apple silicon")
    triple, codex_sha, node_sha = ASSETS[arch]
    marker = {"codex": CODEX_VERSION, "node": NODE_VERSION, "architecture": arch}
    manifest = stage / "runtime.json"
    if manifest.exists() and json.loads(manifest.read_text()) == marker:
        signature(stage / "codex/bin/codex", "codex", "2DC432GLL2")
        signature(stage / "node", "node", "HX7739G8FX")
        return
    stage.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="notebook-codex-", dir=stage.parent) as temporary:
        work = Path(temporary)
        archive = work / "codex.tar.gz"
        checked_download(f"https://github.com/openai/codex/releases/download/rust-v{CODEX_VERSION}/codex-package-{triple}-apple-darwin.tar.gz", archive, codex_sha)
        codex = work / "prepared/codex"; codex.mkdir(parents=True)
        with tarfile.open(archive) as source: source.extractall(codex, filter="data")
        archive = work / "node.tar.gz"
        checked_download(f"https://nodejs.org/dist/{NODE_VERSION}/node-{NODE_VERSION}-darwin-{arch}.tar.gz", archive, node_sha)
        with tarfile.open(archive) as source:
            prefix = f"node-{NODE_VERSION}-darwin-{arch}/"
            for name in ("bin/node", "LICENSE"):
                member = source.extractfile(prefix + name)
                if member is None: raise RuntimeError("Missing Node runtime")
                target = work / "prepared" / ("node" if name == "bin/node" else "Node-LICENSE")
                with target.open("wb") as output: shutil.copyfileobj(member, output)
        (work / "prepared/node").chmod(0o755)
        signature(codex / "bin/codex", "codex", "2DC432GLL2")
        signature(work / "prepared/node", "node", "HX7739G8FX")
        version = subprocess.check_output([codex / "bin/codex", "--version"], text=True).strip()
        if version != "codex-cli " + CODEX_VERSION: raise RuntimeError("Unexpected Codex version")
        (work / "prepared/runtime.json").write_text(json.dumps(marker, sort_keys=True) + "\n")
        if stage.exists(): shutil.rmtree(stage)
        (work / "prepared").rename(stage)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--stage", type=Path, required=True)
    parser.add_argument("--bundle", type=Path)
    args = parser.parse_args()
    if args.bundle:
        marker = {"codex": CODEX_VERSION, "node": NODE_VERSION, "architecture": platform.machine()}
        if not (args.stage / "runtime.json").is_file() or json.loads((args.stage / "runtime.json").read_text()) != marker:
            raise RuntimeError("Prepare the pinned Codex runtimes before Xcode build")
        signature(args.stage / "codex/bin/codex", "codex", "2DC432GLL2")
        signature(args.stage / "node", "node", "HX7739G8FX")
        prefix = "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/CodexRuntime"
        expected = {prefix} | {prefix + "/" + str(p.relative_to(args.stage)) for p in args.stage.rglob("*")}
        inventory = set(Path(__file__).with_name("NotebookCodexResources.xcfilelist").read_text().splitlines())
        if expected != inventory: raise RuntimeError("Pinned runtime differs from the admitted sandbox output inventory")
        if args.bundle.name != "CodexRuntime" or args.bundle.is_symlink(): raise RuntimeError("Unsafe bundle output")
        # Replaced runtimes must not retain executables from an older package.
        if args.bundle.exists(): shutil.rmtree(args.bundle)
        shutil.copytree(args.stage, args.bundle)
    else: prepare(args.stage)


if __name__ == "__main__": main()

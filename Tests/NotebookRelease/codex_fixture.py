"""Tiny fabricated archives for build-input contracts; never official binaries."""
import gzip
import hashlib
import io
import json
from pathlib import Path
import shutil
import sys
import tarfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Applications"))
import prepare_notebook_codex as codex


def payload(codex_version="0.155.0", node_version="v24.21.0"):
    def executable(version):
        return ("#!" + sys.executable + "\nprint(" + repr(version) + ")\n").encode()
    return {"codex/bin/codex": (executable("codex-cli " + codex_version), 0o755),
            "codex/codex-package.json": (b'{"fixture":true}\n', 0o644),
            "codex/codex-resources/helper.dat": (b"fixture helper bytes\n", 0o644),
            "node": (executable(node_version), 0o755), "Node-LICENSE": (b"fixture license\n", 0o644)}


def fixture(codex_version="0.155.0", node_version="v24.21.0"):
    files = payload(codex_version, node_version)
    directories = {str(parent) for name in files for parent in Path(name).parents if str(parent) != "."}
    entries = [{"path": name, "type": "directory", "mode": "0755"} for name in directories]
    entries += [{"path": name, "type": "file", "mode": f"{mode:04o}", "bytes": len(data),
                 "sha256": hashlib.sha256(data).hexdigest()} for name, (data, mode) in files.items()]
    archives = {}
    for role in ("codex", "node"):
        raw = io.BytesIO()
        with tarfile.open(fileobj=raw, mode="w") as archive:
            if role == "codex":
                members = [(name.removeprefix("codex/"), None, 0o755) for name in sorted(directories) if name != "codex"]
                members += [(name.removeprefix("codex/"), data, mode) for name, (data, mode) in files.items() if name.startswith("codex/")]
            else:
                prefix = "node-" + node_version + "-darwin-arm64/"
                members = [(prefix + "bin/node", *files["node"]), (prefix + "LICENSE", *files["Node-LICENSE"])]
            for name, data, mode in members:
                member = tarfile.TarInfo(name); member.mode = mode; member.mtime = 0
                if data is None:
                    member.type = tarfile.DIRTYPE; archive.addfile(member)
                else:
                    member.size = len(data); archive.addfile(member, io.BytesIO(data))
        archives[role] = gzip.compress(raw.getvalue(), mtime=0)
    urls = {"codex": f"https://github.com/openai/codex/releases/download/rust-v{codex_version}/codex-package-aarch64-apple-darwin.tar.gz",
            "node": f"https://nodejs.org/dist/{node_version}/node-{node_version}-darwin-arm64.tar.gz"}
    lock = {"format": 1, "codexVersion": codex_version, "nodeVersion": node_version,
            "architectures": {"arm64": {"triple": "aarch64", "archives": {
                name: {"url": urls[name], "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)}
                for name, data in archives.items()}, "entries": sorted(entries, key=lambda item: item["path"])}}}
    return lock, archives, files


def source(root, codex_version="0.155.0", node_version="v24.21.0"):
    root = Path(root); (root / "Applications").mkdir(parents=True, exist_ok=True)
    lock, archives, files = fixture(codex_version, node_version)
    path = root / "Applications/NotebookCodexRuntime.lock.json"
    path.write_text(json.dumps(lock, indent=2) + "\n")
    shutil.copyfile(ROOT / "Applications/prepare_notebook_codex.py", root / "Applications/prepare_notebook_codex.py")
    runtime = codex.admitted_runtime("arm64", path)
    prefix = "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/CodexRuntime"
    outputs = root / "Applications/NotebookCodexResources.xcfilelist"
    outputs.write_text("\n".join(sorted({prefix, prefix + "/runtime.json"} | {prefix + "/" + row["path"] for row in runtime["entries"]})) + "\n")
    return runtime, archives, files


def stage(destination, runtime, files):
    destination = Path(destination); destination.mkdir(parents=True, mode=0o755); destination.chmod(0o755)
    for entry in runtime["entries"]:
        path = destination / entry["path"]
        if entry["type"] == "directory": path.mkdir(mode=0o755)
        else: path.write_bytes(files[entry["path"]][0])
        path.chmod(int(entry["mode"], 8))
    (destination / "runtime.json").write_bytes(codex.canonical(codex.identity(runtime)))
    (destination / "runtime.json").chmod(0o644)
    return destination


def report(stage, runtime):
    # FakeCLI's native-signature runner is fabricated too. Do not weaken the
    # real payload validator: these tiny bytes must still match their source lock.
    return {"status": "ready", "stage": str(Path(stage).resolve()),
            "identity": codex.check_payload(Path(stage), runtime), "versions": codex.expected_versions(runtime)}

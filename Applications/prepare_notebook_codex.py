#!/usr/bin/env python3
"""Admit archive-pinned build inputs; never touch login, live runtime or old caches."""
import argparse
from contextlib import contextmanager, ExitStack
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import selectors
import shutil
import stat
import subprocess
import tarfile
import tempfile
import time
import urllib.request

LOCK = Path(__file__).with_name("NotebookCodexRuntime.lock.json")
OUTPUTS = Path(__file__).with_name("NotebookCodexResources.xcfilelist")
DEFAULT_STAGE_ROOT = Path(__file__).resolve().parents[1] / ".build/notebook-codex-runtimes"
VERSION_LIMIT = 4096
VERSION_TIMEOUT = 10
LEASE_TIMEOUT = 1800


def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def fail(message):
    raise RuntimeError(message)


def admitted_runtime(architecture=None, lock_path=LOCK):
    lock = json.loads(Path(lock_path).read_text())
    architecture = architecture or platform.machine()
    if lock.get("format") != 1 or architecture not in lock.get("architectures", {}):
        fail("Notebook Codex runtime is admitted only for a pinned architecture")
    if not re.fullmatch(r"\d+\.\d+\.\d+", lock.get("codexVersion", "")) or not re.fullmatch(r"v\d+\.\d+\.\d+", lock.get("nodeVersion", "")):
        fail("Invalid runtime version pin")
    value = lock["architectures"][architecture]
    archives = value["archives"]
    urls = {
        "codex": f'https://github.com/openai/codex/releases/download/rust-v{lock["codexVersion"]}/codex-package-{value["triple"]}-apple-darwin.tar.gz',
        "node": f'https://nodejs.org/dist/{lock["nodeVersion"]}/node-{lock["nodeVersion"]}-darwin-{architecture}.tar.gz',
    }
    if set(archives) != set(urls):
        fail("Incomplete runtime archive pins")
    for name, archive in archives.items():
        if archive.get("url") != urls[name] or type(archive.get("bytes")) is not int or archive["bytes"] <= 0 or not re.fullmatch(r"[0-9a-f]{64}", archive.get("sha256", "")):
            fail("Invalid runtime archive pin")
    entries = value["entries"]
    names = []
    for entry in entries:
        name = entry["path"]
        path = PurePosixPath(name)
        if not name or path.is_absolute() or ".." in path.parts or path.as_posix() != name or name == "runtime.json":
            fail("Unsafe runtime manifest path")
        if entry.get("type") not in ("file", "directory") or entry.get("mode") not in ("0644", "0755"):
            fail("Invalid runtime manifest type/mode")
        keys = {"path", "type", "mode"}
        if entry["type"] == "file":
            keys |= {"bytes", "sha256"}
            if type(entry.get("bytes")) is not int or entry["bytes"] < 0 or not re.fullmatch(r"[0-9a-f]{64}", entry.get("sha256", "")):
                fail("Invalid runtime file pin")
        if set(entry) != keys:
            fail("Unexpected runtime manifest fields")
        names.append(name)
    if names != sorted(set(names)):
        fail("Runtime manifest paths must be unique and sorted")
    by_path = {entry["path"]: entry for entry in entries}
    for path in by_path:
        for parent in PurePosixPath(path).parents:
            if str(parent) != "." and by_path.get(str(parent), {}).get("type") != "directory":
                fail("Runtime manifest is missing a parent directory")
    for executable in ("codex/bin/codex", "node"):
        if by_path.get(executable, {}).get("mode") != "0755":
            fail("Runtime manifest is missing an executable")
    return {"format": 1, "architecture": architecture, "codex": lock["codexVersion"],
            "node": lock["nodeVersion"], "archives": archives, "entries": entries}


def identity(runtime):
    return {"format": 2, "architecture": runtime["architecture"], "codex": runtime["codex"], "node": runtime["node"],
            "archiveSHA256": {name: value["sha256"] for name, value in runtime["archives"].items()},
            "manifestSHA256": hashlib.sha256(canonical(runtime)).hexdigest()}


def expected_versions(runtime):
    return {"codex": "codex-cli " + runtime["codex"], "node": runtime["node"]}


def validate_report(report, *, lock_path=LOCK, stage_root=None):
    if not isinstance(report, dict) or not isinstance(report.get("identity"), dict):
        fail("Malformed Codex runtime receipt")
    runtime = admitted_runtime(report["identity"].get("architecture"), lock_path)
    expected = identity(runtime)
    stage = report.get("stage")
    if set(report) != {"status", "stage", "identity", "versions"} or report.get("status") != "ready" or report.get("identity") != expected or report.get("versions") != expected_versions(runtime):
        fail("Codex runtime receipt differs from the source pin")
    if not isinstance(stage, str) or not Path(stage).is_absolute() or str(Path(stage).resolve()) != stage:
        fail("Codex runtime receipt has no exact stage")
    if stage_root is not None and Path(stage) != Path(stage_root).resolve() / expected["manifestSHA256"]:
        fail("Codex runtime receipt does not name its content-addressed stage")
    return expected


def fingerprint(info):
    return (info.st_dev, info.st_ino, info.st_size, info.st_mode, info.st_nlink,
            info.st_mtime_ns, info.st_ctime_ns)


def payload_digest(stream):
    # Xcode's /usr/bin/python3 can predate hashlib.file_digest (Python 3.11).
    digest = hashlib.sha256()
    while block := stream.read(1024 * 1024):
        digest.update(block)
    return digest.hexdigest()


@contextmanager
def regular_file(path, expected, *, dir_fd=None):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dir_fd)
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) != int(expected["mode"], 8) or info.st_size != expected["bytes"]:
            fail("Runtime file type/mode/length/link count differs: " + str(path))
        yield stream
        after = os.fstat(stream.fileno())
        current = os.stat(path, dir_fd=dir_fd, follow_symlinks=False)
        if fingerprint(info) != fingerprint(after) or fingerprint(after) != fingerprint(current):
            fail("Runtime file changed during admission: " + str(path))


@contextmanager
def admitted_payload(stage, runtime):
    """Hold exact parents throughout hashing/use; reject changed tree bindings."""
    stage = Path(stage)
    marker = canonical(identity(runtime))
    expected = {"runtime.json": {"path": "runtime.json", "type": "file", "mode": "0644", "bytes": len(marker),
                                 "sha256": hashlib.sha256(marker).hexdigest()}}
    expected.update({entry["path"]: entry for entry in runtime["entries"]})
    with ExitStack() as handles:
        def open_directory(name, parent=None):
            fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
            handles.callback(os.close, fd)
            return fd
        root = open_directory(stage)
        initial_root = os.fstat(root)
        if stat.S_IMODE(initial_root.st_mode) != 0o755:
            fail("Runtime stage must be a regular normalized directory")
        directories = {"": root}
        snapshots = {}
        def visit(directory, relative=""):
            with os.scandir(directory) as children:
                for child in children:
                    name = relative + child.name
                    entry = expected.get(name)
                    if entry is None:
                        fail("Unexpected runtime entry: " + name)
                    info = os.stat(child.name, dir_fd=directory, follow_symlinks=False)
                    valid = stat.S_ISDIR(info.st_mode) if entry["type"] == "directory" else stat.S_ISREG(info.st_mode)
                    if not valid or stat.S_IMODE(info.st_mode) != int(entry["mode"], 8):
                        fail("Runtime entry type/mode differs: " + name)
                    if entry["type"] == "file" and (info.st_nlink != 1 or info.st_size != entry["bytes"]):
                        fail("Runtime file length or link count differs: " + name)
                    snapshots[name] = (directory, child.name, info)
                    if entry["type"] == "directory":
                        nested = open_directory(child.name, directory)
                        if fingerprint(os.fstat(nested)) != fingerprint(info):
                            fail("Runtime directory changed during admission: " + name)
                        directories[name] = nested
                        visit(nested, name + "/")
        visit(root)
        if set(snapshots) != set(expected):
            fail("Runtime cache is incomplete")
        def open_file(name):
            parent, leaf, _ = snapshots[name]
            return regular_file(leaf, expected[name], dir_fd=parent)
        def unchanged():
            # A held fd alone would accept a detached tree. Check every original
            # parent/name binding as well as the retained directory descriptors.
            if fingerprint(stage.lstat()) != fingerprint(initial_root) or fingerprint(os.fstat(root)) != fingerprint(initial_root):
                fail("Runtime root changed during admission")
            for name, (parent, leaf, before) in snapshots.items():
                if fingerprint(os.stat(leaf, dir_fd=parent, follow_symlinks=False)) != fingerprint(before):
                    fail("Runtime tree changed during admission: " + name)
                if name in directories and fingerprint(os.fstat(directories[name])) != fingerprint(before):
                    fail("Runtime directory changed during admission: " + name)
        # Exactly one payload SHA pass. Metadata retained for the whole operation
        # catches changes to previously hashed files and newly introduced entries.
        for name, entry in expected.items():
            if entry["type"] == "file":
                with open_file(name) as stream:
                    if fingerprint(os.fstat(stream.fileno())) != fingerprint(snapshots[name][2]):
                        fail("Runtime tree changed during admission: " + name)
                    if payload_digest(stream) != entry["sha256"]:
                        fail("Runtime bytes differ from the archive pin: " + name)
        unchanged()
        yield open_file
        unchanged()


def check_payload(stage, runtime):
    with admitted_payload(stage, runtime):
        return identity(runtime)


def signature(path, identifier, team):
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", "-R",
        f'=anchor apple generic and identifier "{identifier}" and certificate leaf[subject.OU] = "{team}"', str(path)], check=True, timeout=30)


def executable_version(path):
    output = bytearray()
    deadline = time.monotonic() + VERSION_TIMEOUT
    with subprocess.Popen([str(path), "--version"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT) as process:
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ)
                while selector.get_map():
                    remaining = deadline - time.monotonic()
                    if remaining <= 0 or not selector.select(remaining):
                        fail("Runtime version probe timed out")
                    block = os.read(process.stdout.fileno(), VERSION_LIMIT + 1 - len(output))
                    if not block:
                        selector.unregister(process.stdout)
                        break
                    output.extend(block)
                    if len(output) > VERSION_LIMIT:
                        fail("Runtime version output exceeds its bound")
            if process.wait(timeout=max(0.001, deadline - time.monotonic())) != 0:
                fail("Runtime version probe failed")
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
    return output.decode("utf-8").strip()


def check_stage(stage, runtime):
    stage = Path(stage)
    with admitted_payload(stage, runtime):
        signature(stage / "codex/bin/codex", "codex", "2DC432GLL2")
        signature(stage / "node", "node", "HX7739G8FX")
        versions = {"codex": executable_version(stage / "codex/bin/codex"), "node": executable_version(stage / "node")}
        if versions != expected_versions(runtime):
            fail("Unexpected pinned Codex/Node executable version")
        return {"status": "ready", "stage": str(stage.resolve()), "identity": identity(runtime), "versions": versions}


def checked_download(archive, destination):
    digest = hashlib.sha256()
    size = 0
    with urllib.request.urlopen(archive["url"], timeout=60) as response, destination.open("xb") as output:
        while block := response.read(1024 * 1024):
            size += len(block)
            if size > archive["bytes"]:
                fail("Runtime archive exceeds its pinned length")
            digest.update(block)
            output.write(block)
    if size != archive["bytes"] or digest.hexdigest() != archive["sha256"]:
        fail("Runtime archive checksum/length mismatch")


def copy_exact(source, output, size):
    remaining = size
    while remaining:
        block = source.read(min(1024 * 1024, remaining))
        if not block:
            fail("Runtime copy was truncated")
        output.write(block)
        remaining -= len(block)
    if source.read(1):
        fail("Runtime copy grew beyond its pinned length")


def prepare_payload(stage, work, runtime):
    expected = {entry["path"]: entry for entry in runtime["entries"]}
    stage.mkdir(mode=0o755)
    stage.chmod(0o755)
    for entry in runtime["entries"]:
        if entry["type"] == "directory":
            target = stage / entry["path"]
            target.mkdir(mode=int(entry["mode"], 8))
            target.chmod(int(entry["mode"], 8))
    seen = {"codex"}
    for name, pinned in runtime["archives"].items():
        archive = work / (name + ".tar.gz")
        checked_download(pinned, archive)
        node_prefix = f'node-{runtime["node"]}-darwin-{runtime["architecture"]}/'
        selected = {node_prefix + "bin/node": "node", node_prefix + "LICENSE": "Node-LICENSE"}
        with tarfile.open(archive, "r|gz") as members:
            for member in members:
                if name == "node" and member.name not in selected:
                    continue
                target = selected[member.name] if name == "node" else "codex/" + member.name
                entry = expected.get(target)
                if entry is None or target in seen:
                    fail("Unexpected or repeated archive member: " + member.name)
                if entry["type"] == "directory":
                    if not member.isdir() or member.mode != int(entry["mode"], 8):
                        fail("Archive directory type differs")
                else:
                    if not member.isfile() or member.size != entry["bytes"] or member.mode != int(entry["mode"], 8):
                        fail("Archive file type/mode/length differs")
                    source = members.extractfile(member)
                    if source is None:
                        fail("Missing archive file body")
                    with source, (stage / target).open("xb") as output:
                        copy_exact(source, output, entry["bytes"])
                    (stage / target).chmod(int(entry["mode"], 8))
                seen.add(target)
    if seen != set(expected):
        fail("Pinned archives do not contain the complete runtime")
    (stage / "runtime.json").write_bytes(canonical(identity(runtime)))
    (stage / "runtime.json").chmod(0o644)


def sync_path(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def prepare(stage_root, runtime):
    stage_root = Path(stage_root)
    if stage_root.is_symlink():
        fail("Runtime cache root must not be a symbolic link")
    stage_root.mkdir(parents=True, exist_ok=True)
    stage_root = stage_root.resolve()
    key = identity(runtime)["manifestSHA256"]
    stage = stage_root / key
    # The OS lease ends on process death. Published stages are never replaced
    # or deleted; consumers can keep using them through another preparation.
    fd = os.open(stage_root / (key + ".lock"), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "a+b") as lease:
        info = os.fstat(lease.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            fail("Runtime preparation lease must be a private regular file")
        deadline = time.monotonic() + LEASE_TIMEOUT
        while True:
            try:
                fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    fail("Runtime preparation lease timed out")
                time.sleep(min(0.05, remaining))
        if stage.exists() or stage.is_symlink():
            return check_stage(stage, runtime)
        with tempfile.TemporaryDirectory(prefix=".prepare-" + key + "-", dir=stage_root) as temporary:
            work = Path(temporary)
            prepared = work / "payload"
            prepare_payload(prepared, work, runtime)
            report = check_stage(prepared, runtime)
            # Persist the checked bytes and directory entries before exposing
            # their immutable name. A failed acknowledgement never deletes it.
            for path in sorted(prepared.rglob("*"), key=lambda path: len(path.parts), reverse=True):
                sync_path(path)
            sync_path(prepared)
            prepared.rename(stage)
            sync_path(stage_root)
            report["stage"] = str(stage)
            return report


def bundle(stage, destination, runtime, outputs=OUTPUTS):
    stage, destination = Path(stage), Path(destination)
    if destination.name != "CodexRuntime" or destination.is_symlink() or stage.resolve() == destination.resolve() or stage.resolve() in destination.resolve().parents or destination.resolve() in stage.resolve().parents:
        fail("Unsafe Codex runtime bundle output")
    prefix = "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/CodexRuntime"
    expected_outputs = {prefix, prefix + "/runtime.json"} | {prefix + "/" + entry["path"] for entry in runtime["entries"]}
    if set(Path(outputs).read_text().splitlines()) != expected_outputs:
        fail("Pinned runtime differs from the admitted sandbox output inventory")
    with admitted_payload(stage, runtime) as source_file:
        # This is an unpublished Xcode build product. C4's signed-package
        # publisher owns eventual release; no second publisher is added.
        if destination.exists():
            shutil.rmtree(destination)
        destination.mkdir(parents=True, mode=0o755)
        destination.chmod(0o755)
        entries = [*runtime["entries"], {"path": "runtime.json", "type": "file", "mode": "0644", "bytes": len(canonical(identity(runtime)))}]
        for entry in entries:
            target = destination / entry["path"]
            if entry["type"] == "directory":
                target.mkdir(mode=int(entry["mode"], 8))
            else:
                with source_file(entry["path"]) as source, target.open("xb") as output:
                    copy_exact(source, output, entry["bytes"])
            target.chmod(int(entry["mode"], 8))
        return check_stage(destination, runtime)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--prepare", action="store_true")
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--stage-root", type=Path, default=DEFAULT_STAGE_ROOT)
    parser.add_argument("--stage", type=Path)
    parser.add_argument("--bundle", type=Path)
    args = parser.parse_args()
    if sum((args.prepare, args.check, args.bundle is not None)) != 1 or (args.prepare and args.stage is not None) or (not args.prepare and args.stage is None):
        parser.error("Choose --prepare [--stage-root], --check --stage, or --stage --bundle")
    if args.stage is not None and not args.stage.is_absolute():
        parser.error("--stage must name the exact absolute prepared path")
    runtime = admitted_runtime()
    if args.prepare:
        report = prepare(args.stage_root, runtime)
    elif args.bundle:
        report = bundle(args.stage, args.bundle, runtime)
    else:
        report = check_stage(args.stage, runtime)
    print(json.dumps(report, sort_keys=True))


if __name__ == "__main__":
    main()

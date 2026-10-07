#!/usr/bin/env python3
"""Build only Core; measure the pure owner in isolated subprocesses."""
import argparse
import hashlib
import json
import pathlib
import platform
import re
import subprocess
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
HARNESS = pathlib.Path(__file__).resolve().parent


def source_manifest():
    paths = [ROOT / "Package.swift", *sorted((ROOT / "Sources/NotebookCore").glob("*.swift")),
             *sorted((ROOT / "Sources/NotebookSurface").glob("*.swift")), *sorted(HARNESS.glob("*.*"))]
    values = [{"path": str(path.relative_to(ROOT)), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
              for path in paths if path.is_file()]
    digest = hashlib.sha256(json.dumps(values, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    return {"digest": digest, "files": values}


def checked(command):
    result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    return result


def measure(probe, operation, size, timeout):
    began = time.monotonic()
    result = subprocess.run(["/usr/bin/time", "-l", str(probe), operation, str(size), str(timeout)],
                            cwd=ROOT, text=True, capture_output=True)
    output = [json.loads(line) for line in result.stdout.splitlines() if line.startswith("{")]
    metrics = {}
    for pattern, name in [(r"([\d.]+) user", "processUserCPUSeconds"),
                          (r"([\d.]+) sys", "processSystemCPUSeconds"),
                          (r"(\d+)\s+maximum resident set size", "processPeakRSSBytes")]:
        match = re.search(pattern, result.stderr)
        if match:
            metrics[name] = float(match.group(1))
    return {"operation": operation, "size": size, "exitCode": result.returncode,
            "status": "complete" if result.returncode == 0 else "timeout" if result.returncode == 124 else "failed",
            "processWallSeconds": time.monotonic() - began, **metrics, "output": output,
            "stderr": result.stderr}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--sizes", type=int, nargs="+", default=[1000, 4097, 100000])
    parser.add_argument("--timeout-seconds", type=int, default=60)
    parser.add_argument("--repetitions", type=int, default=1)
    arguments = parser.parse_args()
    output = arguments.output.resolve(); output.parent.mkdir(parents=True, exist_ok=True)
    scratch = ROOT / ".build/causal-content-probe"
    source_before = source_manifest()
    checked(["swift", "build", "-c", "release", "--target", "NotebookCore", "-Xswiftc", "-enable-testing",
             "--scratch-path", str(scratch)])
    build = pathlib.Path(checked(["swift", "build", "-c", "release", "--show-bin-path",
                                 "--scratch-path", str(scratch)]).stdout.strip())
    probe = scratch / "causal-content-probe"
    checked(["swiftc", "-O", "-swift-version", "6", "-I", str(build),
             "-I", str(ROOT / "Sources/CSQLite"), "-I", str(ROOT / "Sources/CZlib"),
             str(HARNESS / "main.swift"), str(build / "NotebookCore.o"), str(build / "NotebookSurface.o"),
             "-lsqlite3", "-lz", "-o", str(probe)])
    semantic_output = checked([str(probe), "semantics"]).stdout
    semantics = json.loads(semantic_output)
    (output.parent / (output.stem + "-semantics.json")).write_text(semantic_output)
    report = {"scope": "pure optimized Core owner; no storage, native app, helper, or device",
              "gitHead": checked(["git", "rev-parse", "HEAD"]).stdout.strip(), "platform": platform.platform(),
              "toolchain": checked(["swift", "--version"]).stdout.strip(), "sourceBefore": source_before,
              "probeSHA256": hashlib.sha256(probe.read_bytes()).hexdigest(),
              "semantics": {"snapshotCount": len(semantics["snapshots"]),
                            "sha256": hashlib.sha256(semantic_output.encode()).hexdigest()}, "measurements": []}
    for repetition in range(arguments.repetitions):
        for size in arguments.sizes:
            for operation in ["record-sparse", "record-all", "merge-shapes", "merge-fields"]:
                row = measure(probe, operation, size, arguments.timeout_seconds)
                row["repetition"] = repetition + 1
                report["measurements"].append(row)
                print(json.dumps({key: row[key] for key in ["operation", "size", "repetition", "status", "processWallSeconds"]}), flush=True)
                output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
                if row["status"] == "failed":
                    raise RuntimeError(row["stderr"])
    report["sourceAfter"] = source_manifest()
    report["sourceUnchangedDuringRun"] = report["sourceBefore"] == report["sourceAfter"]
    output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    if not report["sourceUnchangedDuringRun"]:
        raise RuntimeError("Core/harness sources changed during measurement")


if __name__ == "__main__":
    main()

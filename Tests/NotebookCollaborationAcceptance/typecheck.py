#!/usr/bin/env python3
"""Compile the real UI scenario's semantics without starting an Xcode runner."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess


def main():
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=root / ".build/collaboration-ui-semantic")
    options = parser.parse_args()
    output = options.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    developer = Path(subprocess.check_output(["xcode-select", "-p"], text=True).strip())
    sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], text=True).strip()
    test_developer = developer / "Platforms/iPhoneSimulator.platform/Developer"
    sources = [root / "Applications/AcceptanceUITests" / name for name in (
        "NotebookSystemTraceHandshake.swift", "NotebookCollaborationAcceptanceUITests.swift")]

    def snapshot():
        return {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sources}

    before = snapshot()
    command = ["xcrun", "swiftc", "-typecheck", "-module-name", "NotebookAcceptanceUITests",
               "-target", "arm64-apple-ios27.0-simulator", "-sdk", sdk,
               "-swift-version", "6", "-strict-concurrency=complete",
               "-F", str(test_developer / "Library/Frameworks"),
               "-I", str(test_developer / "usr/lib"), *map(str, sources)]
    started = datetime.now(timezone.utc).isoformat()
    result = subprocess.run(command, cwd=root, capture_output=True, text=True)
    (output / "typecheck.log").write_text(result.stdout + result.stderr)
    after = snapshot()
    passed = result.returncode == 0 and before == after
    compiler = subprocess.run(["xcrun", "swiftc", "--version"], capture_output=True, text=True, check=True)
    receipt = {"kind": "swift-ui-semantic-check", "startedAt": started,
               "finishedAt": datetime.now(timezone.utc).isoformat(), "command": command,
               "compiler": (compiler.stdout + compiler.stderr).strip(),
               "sourcesBefore": before, "sourcesAfter": after, "exitCode": result.returncode,
               "status": "passed" if passed else "failed", "uiExecuted": False,
               "limitations": "No Xcode/Simulator runner, gestures, agent turn, persistence or presentation was tested."}
    (output / "receipt.json").write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"status": receipt["status"], "receipt": str(output / "receipt.json"),
                      "uiExecuted": False}))
    if not passed:
        print(result.stdout + result.stderr)
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())

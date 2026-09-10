"""Offline, exact-byte check. No downloads, interpreter execution, or archive IO."""
import hashlib
import json
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[2] / "Applications/ComputationResources"
manifest = json.loads((root / "manifest.json").read_text())
expected = {entry["path"] for entry in manifest["files"]}
actual = {str(p.relative_to(root)) for p in root.rglob("*") if p.is_file()} - {"manifest.json", "README.md"}
assert actual == expected, (actual - expected, expected - actual)
for entry in manifest["files"]:
    path = root / entry["path"]
    assert not path.is_symlink() and root in path.resolve().parents
    data = path.read_bytes()
    assert len(data) == entry["bytes"], path
    assert hashlib.sha256(data).hexdigest() == entry["sha256"], path
lock = json.loads((root / "pyodide-lock.json").read_text())
assert lock["info"]["python"] == manifest["python"] == "3.14.2"
assert {k: v["version"] for k, v in lock["packages"].items()} == manifest["packages"] == {
    "numpy": "2.4.6", "scipy": "1.18.0", "sympy": "1.14.0", "mpmath": "1.4.1",
}
for package in lock["packages"].values():
    assert set(package["depends"]) <= lock["packages"].keys()
    assert hashlib.sha256((root / package["file_name"]).read_bytes()).hexdigest() == package["sha256"]
if "--fingerprint" in sys.argv:
    harness = Path(__file__).resolve().parent
    sources = [root / "manifest.json"] + [harness / name for name in [
        "main.swift", "index.html", "worker.mjs", "run.sh", "verify-resources.py",
    ]]
    hashes = [hashlib.sha256(path.read_bytes()).hexdigest() for path in sources]
    print(hashlib.sha256("\n".join(hashes).encode()).hexdigest())
else:
    print(f"Verified Pyodide {manifest['release']}: {len(expected)} immutable files; four scientific libraries")

"""Explicit build-time download. Evaluation itself is offline and verifies hashes."""
import hashlib
import json
from pathlib import Path
import shutil
import urllib.request

harness = Path(__file__).resolve().parent
root = harness.parents[1] / ".build/recognition-model"
lock = json.loads((harness / "model-lock.json").read_text())
for entry in lock["files"]:
    target = root / entry["path"]
    if target.is_file() and hashlib.sha256(target.read_bytes()).hexdigest() == entry["sha256"]:
        continue
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_suffix(target.suffix + ".download")
    url = f"https://huggingface.co/{lock['repository']}/resolve/{lock['revision']}/{entry['path']}"
    try:
        with urllib.request.urlopen(url, timeout=120) as response, temporary.open("wb") as stream:
            shutil.copyfileobj(response, stream)
        assert temporary.stat().st_size == entry["bytes"], target
        assert hashlib.sha256(temporary.read_bytes()).hexdigest() == entry["sha256"], target
        temporary.replace(target)
    finally:
        temporary.unlink(missing_ok=True)
print(f"Pinned open recognition model prepared: {root}")

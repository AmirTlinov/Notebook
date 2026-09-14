"""Keep preserved launch configuration distinct from the installed source build."""
import hashlib
import json
from pathlib import Path
import re

import notebook_release as release


def configuration_provenance(manifest):
    revision = manifest.get("sourceRevision")
    release.require(isinstance(revision, str) and re.fullmatch(r"[0-9a-fA-F]{40}", revision),
                    "В launch configuration нет корректной исходной revision.")
    canonical = json.dumps(manifest, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    return {"sourceRevision": revision, "canonicalSHA256": hashlib.sha256(canonical).hexdigest()}


def verify_launch_configuration(value, launch_manifest, journal_directory_name):
    path, container = Path(launch_manifest), Path(value["simulatorDataContainer"]).resolve()
    release.require(path.is_file() and not path.is_symlink()
                    and path.resolve().is_relative_to(container) and 0 < path.stat().st_size <= 16_384,
                    "Launch manifest не принадлежит выбранному Simulator контейнеру.")
    data = path.read_bytes()
    manifest = json.loads(data)
    release.require(configuration_provenance(manifest) == value.get("launchConfiguration"),
                    "Launch configuration изменился после подготовки observation.")
    release.require(manifest.get("bundleID") == "com.amirtlinov.notebook.acceptance"
                    and manifest.get("role") == "iPad"
                    and manifest.get("runID", "").lower() == value["runID"].lower()
                    and manifest.get("workspaceID") == value["workspaceID"]
                    and Path(manifest["root"]).resolve().parent / journal_directory_name
                        == Path(value["nativeJournalDirectory"]).resolve(),
                    "Launch configuration принадлежит другой observation scope.")
    return {**value["launchConfiguration"], "path": str(path),
            "fileSHA256": hashlib.sha256(data).hexdigest()}

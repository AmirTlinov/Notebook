"""Opt-in geometry/ownership evidence from the actual private Simulator app."""
import json
from pathlib import Path
import uuid

import notebook_release as release
import notebook_observation_provenance as provenance

NATIVE_FILES = (
    "Applications/Shared/NotebookSceneObservation.swift",
    "Applications/Shared/SceneCameraPlane.swift",
    "Applications/Shared/SceneCompositionTiles.swift",
    "Applications/iPad/SpatialWorkspaceView.swift",
)
TARGET = "acceptance-native-title"
MAX_BYTES = 16 * 1024 * 1024 + 65536


def request(args):
    raw = getattr(args, "scene_observation_session", None)
    if raw is None:
        return None
    try:
        session = uuid.UUID(raw)
    except (ValueError, TypeError, AttributeError):
        session = None
    release.require(args.platform == "ipad" and session is not None and session.int != 0,
                    "--scene-observation-session требует непустой UUID и private iPad Simulator.")
    return {"sessionID": str(session), "elementID": TARGET}


def prepare(value, built, manifest, container, requested):
    root, container = Path(manifest["root"]).resolve(), Path(container).resolve()
    run_id = str(uuid.UUID(value["runID"]))
    release.require(manifest["bundleID"] == "com.amirtlinov.notebook.acceptance"
                    and manifest["role"] == "iPad" and str(uuid.UUID(manifest["runID"])) == run_id
                    and manifest["workspaceID"] == value["workspaceID"]
                    and root.is_relative_to(container) and root != container and run_id in root.parts,
                    "Scene observation требует manifest текущего private Simulator контейнера.")
    build = Path(value["build"])
    snapshot = build / "source"
    source = json.loads((build / "source.json").read_text())
    release.require(source["sha256"] == built["sourceSHA256"], "Snapshot не соответствует выбранной native сборке.")
    listed = {entry["path"]: entry["sha256"] for entry in source["files"]}
    owners = {}
    for relative in NATIVE_FILES:
        path = snapshot / relative
        release.require(path.is_file() and not path.is_symlink()
                        and path.resolve().is_relative_to(snapshot.resolve())
                        and release.file_digest(path) == listed.get(relative),
                        "В native snapshot нет неизменного observer owner: " + relative)
        owners[relative] = listed[relative]
    release.require("NotebookSceneObservation" in (snapshot / NATIVE_FILES[1]).read_text()
                    and "NotebookSceneObservation" in (snapshot / NATIVE_FILES[3]).read_text()
                    and "observedTileInstallation" in (snapshot / NATIVE_FILES[2]).read_text(),
                    "UI-only bundle не добавляет отсутствующие native hooks.")
    journal = root.parent / "scene-observations"
    release.require(journal.resolve().is_relative_to(container) and not journal.is_symlink(),
                    "Журнал scene observation вышел из Simulator контейнера.")
    release.require(not list(journal.glob(requested["sessionID"] + "-*.ndjson")),
                    "Session ID уже имеет журнал; повтор требует нового UUID.")
    return {**requested, "runID": value["runID"], "workspaceID": value["workspaceID"],
            "sourceRevision": built["sourceRevision"], "nativeSourceSHA256": built["sourceSHA256"],
            "launchConfiguration": provenance.configuration_provenance(manifest),
            "nativeSources": owners, "simulatorDataContainer": str(container),
            "simulatorUDID": built["simulator"]["udid"], "nativeJournalDirectory": str(journal),
            "displayMeasured": False, "textRecorded": False,
            "environment": {"NOTEBOOK_SCENE_OBSERVATION_SESSION_ID": requested["sessionID"]}}


def collect(value, evidence, *, launch_manifest):
    configuration = provenance.verify_launch_configuration(value, launch_manifest, "scene-observations")
    directory, container = Path(value["nativeJournalDirectory"]), Path(value["simulatorDataContainer"])
    release.require(directory.resolve().is_relative_to(container.resolve()) and not directory.is_symlink(),
                    "Каталог scene observation изменился или вышел из Simulator контейнера.")
    paths = sorted(directory.glob(value["sessionID"] + "-*.ndjson"))
    release.require(len(paths) <= 32, "Сессия scene observation превысила 32 запуска приложения.")
    journals = []
    for path in paths:
        release.require(path.is_file() and not path.is_symlink() and path.stat().st_size <= MAX_BYTES,
                        "Недопустимый или слишком большой scene journal.")
        data = path.read_bytes()
        first = json.loads(data.splitlines()[0]) if data else {}
        release.require(first.get("kind") == "identity" and first.get("format") == 1
                        and first.get("sessionID", "").lower() == value["sessionID"]
                        and first.get("acceptanceRunID", "").lower() == value["runID"].lower()
                        and first.get("workspaceID") == value["workspaceID"]
                        and first.get("sourceRevision") == configuration["sourceRevision"]
                        and first.get("simulatorUDID") == value["simulatorUDID"]
                        and first.get("bundleID") == "com.amirtlinov.notebook.acceptance"
                        and first.get("elementID") == TARGET and first.get("textRecorded") is False
                        and first.get("displayMeasured") is False,
                        "Журнал не принадлежит выбранной native сборке, сессии или Simulator.")
        target = Path(evidence) / path.name
        release.require(not target.exists(), "Scene evidence не перезаписывается.")
        target.write_bytes(data); target.chmod(0o600)
        journals.append({"source": str(path), "copy": str(target), "bytes": len(data),
                         "sha256": release.file_digest(target)})
    receipt = {"sessionID": value["sessionID"], "nativeJournals": journals,
               "launchConfiguration": configuration,
               "nativeBuild": {"sourceRevision": value["sourceRevision"],
                   "sourceSHA256": value["nativeSourceSHA256"], "nativeSources": value["nativeSources"]},
               "status": "observed_unassessed" if journals else "unobserved",
               "displayMeasured": False, "textRecorded": False,
               "reason": "Ownership and UIKit geometry need correlation with independently reviewed actual video frames"}
    path = Path(evidence) / "scene-observation-evidence.json"
    release.require(not path.exists(), "Scene receipt не перезаписывается.")
    release.write_json(path, receipt); path.chmod(0o600)
    return receipt

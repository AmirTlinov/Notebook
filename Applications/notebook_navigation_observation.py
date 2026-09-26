"""Opt-in navigation stage evidence from the actual private Simulator app."""
import json
from pathlib import Path
import uuid

import notebook_release as release
import notebook_observation_provenance as provenance

NATIVE_FILES = (
    "Applications/Shared/NotebookNavigationObservation.swift",
    "Applications/Shared/NotebookAppModel.swift",
    "Applications/Shared/NotebookNavigationView.swift",
    "Applications/iPad/SpatialWorkspaceView.swift",
    "Applications/Shared/DocumentPagePresentationOwner.swift",
    "Applications/iPad/IPadPageTurnController.swift",
    "Applications/Shared/DocumentPagePreparation.swift",
    "Applications/Shared/SceneRenderResources.swift",
    "Applications/Shared/DocumentProgramOwner.swift",
    "Applications/iPad/PencilCanvasView.swift",
    "Applications/Shared/InkCanvasView.swift",
)
TARGET = "navigation"
MAX_BYTES = 4 * 1024 * 1024 + 65536


def request(args):
    raw = getattr(args, "navigation_observation_session", None)
    if raw is None:
        return None
    try:
        session = uuid.UUID(raw)
    except (ValueError, TypeError, AttributeError):
        session = None
    release.require(args.platform == "ipad" and session is not None and session.int != 0,
                    "--navigation-observation-session требует непустой UUID и private iPad Simulator.")
    return {"sessionID": str(session), "observer": TARGET}


def prepare(value, built, manifest, container, requested):
    root, container = Path(manifest["root"]).resolve(), Path(container).resolve()
    run_id = str(uuid.UUID(value["runID"]))
    release.require(manifest["bundleID"] == "com.amirtlinov.notebook.acceptance"
                    and manifest["role"] == "iPad" and str(uuid.UUID(manifest["runID"])) == run_id
                    and manifest["workspaceID"] == value["workspaceID"]
                    and root.is_relative_to(container) and root != container and run_id in root.parts,
                    "Navigation observation требует manifest текущего private Simulator контейнера.")
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
    ink_delivery = (snapshot / NATIVE_FILES[9]).read_text()
    ink_render = (snapshot / NATIVE_FILES[10]).read_text()
    release.require("NotebookNavigationObservation.record" in (snapshot / NATIVE_FILES[1]).read_text()
                    and '"ink_accepted"' in (snapshot / NATIVE_FILES[1]).read_text()
                    and "static func recordInk" in (snapshot / NATIVE_FILES[0]).read_text()
                    and "view_ready_to_resolve" in (snapshot / NATIVE_FILES[3]).read_text()
                    and "search_result_tap" in (snapshot / NATIVE_FILES[2]).read_text()
                    and "document_owner_created" in (snapshot / NATIVE_FILES[4]).read_text()
                    and "page_turn_external_request" in (snapshot / NATIVE_FILES[5]).read_text()
                    and all(stage in ink_delivery for stage in (
                        '"ink_delivery"', '"ink_source_settled"', '"ink_cold_requested"', '"ink_source_applied"'))
                    and all(stage in ink_render for stage in (
                        '"ink_display_update"', '"ink_submitted"', '"ink_gpu_complete"', '"ink_frame_readiness"',
                        '"pageRevision"', '"installedPageRevision"', '"submissionID"', '"completionMach"')),
                    "UI-only bundle не добавляет отсутствующие native hooks.")
    journal = root.parent / "navigation-observations"
    release.require(journal.resolve().is_relative_to(container) and not journal.is_symlink(),
                    "Журнал navigation observation вышел из Simulator контейнера.")
    release.require(not list(journal.glob(requested["sessionID"] + "-*.ndjson")),
                    "Session ID уже имеет журнал; повтор требует нового UUID.")
    return {**requested, "runID": value["runID"], "workspaceID": value["workspaceID"],
            "sourceRevision": built["sourceRevision"], "nativeSourceSHA256": built["sourceSHA256"],
            "launchConfiguration": provenance.configuration_provenance(manifest),
            "nativeSources": owners, "simulatorDataContainer": str(container),
            "simulatorUDID": built["simulator"]["udid"], "nativeJournalDirectory": str(journal),
            "displayMeasured": False, "textRecorded": False,
            "environment": {"NOTEBOOK_NAVIGATION_OBSERVATION_SESSION_ID": requested["sessionID"]}}


def collect(value, evidence, *, launch_manifest):
    configuration = provenance.verify_launch_configuration(value, launch_manifest, "navigation-observations")
    directory, container = Path(value["nativeJournalDirectory"]), Path(value["simulatorDataContainer"])
    release.require(directory.resolve().is_relative_to(container.resolve()) and not directory.is_symlink(),
                    "Каталог navigation observation изменился или вышел из Simulator контейнера.")
    paths = sorted(directory.glob(value["sessionID"] + "-*.ndjson"))
    release.require(len(paths) <= 32, "Сессия navigation observation превысила 32 запуска приложения.")
    journals = []
    for path in paths:
        release.require(path.is_file() and not path.is_symlink() and path.stat().st_size <= MAX_BYTES,
                        "Недопустимый или слишком большой navigation journal.")
        data = path.read_bytes()
        first = json.loads(data.splitlines()[0]) if data else {}
        release.require(first.get("kind") == "identity" and first.get("format") == 1
                        and first.get("sessionID", "").lower() == value["sessionID"]
                        and first.get("acceptanceRunID", "").lower() == value["runID"].lower()
                        and first.get("workspaceID") == value["workspaceID"]
                        and first.get("sourceRevision") == configuration["sourceRevision"]
                        and first.get("simulatorUDID") == value["simulatorUDID"]
                        and first.get("bundleID") == "com.amirtlinov.notebook.acceptance"
                        and first.get("observer") == TARGET and first.get("textRecorded") is False
                        and first.get("displayMeasured") is False,
                        "Журнал не принадлежит выбранной native сборке, сессии или Simulator.")
        target = Path(evidence) / path.name
        release.require(not target.exists(), "Navigation evidence не перезаписывается.")
        target.write_bytes(data); target.chmod(0o600)
        journals.append({"source": str(path), "copy": str(target), "bytes": len(data),
                         "sha256": release.file_digest(target)})
    receipt = {"sessionID": value["sessionID"], "nativeJournals": journals,
               "launchConfiguration": configuration,
               "nativeBuild": {"sourceRevision": value["sourceRevision"],
                   "sourceSHA256": value["nativeSourceSHA256"], "nativeSources": value["nativeSources"]},
               "status": "observed_unassessed" if journals else "unobserved",
               "displayMeasured": False, "textRecorded": False,
               "reason": "Navigation stages identify waits/cancellation; actual installation and displayed pixels require their independent owners"}
    path = Path(evidence) / "navigation-observation-evidence.json"
    release.require(not path.exists(), "Navigation receipt не перезаписывается.")
    release.write_json(path, receipt); path.chmod(0o600)
    return receipt

"""Private Simulator measurement configuration and evidence lifecycle only."""
import json
from pathlib import Path
import uuid

import notebook_release as release

SUITE = "NotebookInteractionAcceptanceUITests/testTenReadyControlTapsWithNativeAndDisplayedFrameEvidence"
NATIVE_FILES = (
    "Applications/Shared/NotebookInteractionDiagnostics.swift",
    "Applications/Shared/NotebookInteractionScript.swift",
    "Applications/Shared/AgentWebElementView.swift",
    "Applications/iPad/WorkspaceGestureLayer.swift",
)


def request(args):
    session = getattr(args, "interaction_session", None)
    directory = getattr(args, "interaction_control_directory", None)
    if args.test != SUITE:
        release.require(session is None and directory is None,
                        "Диагностика касания допускается только в своём явном Simulator-сценарии.")
        return None
    release.require(args.platform == "ipad" and not args.trace and not args.pencil,
                    "Измерение control использует обычное касание iPad Simulator и отдельный оконный capture.")
    try:
        parsed = uuid.UUID(session) if isinstance(session, str) else None
    except ValueError:
        parsed = None
    release.require(parsed is not None and parsed.int != 0 and directory is not None,
                    "Нужны --interaction-session UUID и --interaction-control-directory с новым каталогом.")
    control = Path(directory)
    release.require(control.is_absolute(), "Каталог измерения должен иметь абсолютный путь.")
    run = args.run.resolve()
    release.require(control.resolve().is_relative_to(run) and control.resolve() != run
                    and not control.exists() and not control.is_symlink(),
                    "Новый каталог измерения должен находиться внутри выбранного private run, без старых доказательств.")
    return {"sessionID": str(parsed), "controlDirectory": str(control.resolve())}


def prepare(value, built, manifest, container, request_value):
    """Validate owners and immutable source before creating any control output."""
    root, container = Path(manifest["root"]).resolve(), Path(container).resolve()
    run_id = str(uuid.UUID(value["runID"]))
    release.require(manifest["bundleID"] == "com.amirtlinov.notebook.acceptance"
                    and manifest["role"] == "iPad" and str(uuid.UUID(manifest["runID"])) == run_id
                    and manifest["workspaceID"] == value["workspaceID"]
                    and root.is_relative_to(container) and root != container and run_id in root.parts,
                    "Диагностика не принимает manifest вне текущего private Simulator контейнера/пространства.")
    build = Path(value["build"]); snapshot = build / "source"
    source = json.loads((build / "source.json").read_text())
    release.require(source["sha256"] == built["sourceSHA256"], "Исходный snapshot не соответствует выбранной сборке.")
    listed = {entry["path"]: entry["sha256"] for entry in source["files"]}
    native_sources = {}
    for relative in NATIVE_FILES:
        path = snapshot / relative
        release.require(path.is_file() and not path.is_symlink()
                        and path.resolve().is_relative_to(snapshot.resolve())
                        and release.file_digest(path) == listed.get(relative),
                        "В выбранной неизменной сборке нет проверенного native hook: " + relative)
        native_sources[relative] = listed[relative]
    # A separately rebuilt UI bundle cannot introduce missing native hooks.
    release.require("NotebookInteractionDiagnostics" in (snapshot / NATIVE_FILES[2]).read_text()
                    and "NotebookInteractionDiagnostics" in (snapshot / NATIVE_FILES[3]).read_text(),
                    "UI-only runner не может заменить отсутствующие нативные точки наблюдения.")
    control = Path(request_value["controlDirectory"])
    control.mkdir(mode=0o700)
    result = {**request_value, "nativeJournalDirectory": str(root.parent / "interaction-diagnostics"),
              "nativeSourceSHA256": built["sourceSHA256"], "nativeSources": native_sources,
              "simulatorDataContainer": str(container), "simulatorUDID": built["simulator"]["udid"],
              "workspaceID": value["workspaceID"], "latencyMeasured": False,
              "environment": {"NOTEBOOK_INTERACTION_SESSION_ID": request_value["sessionID"],
                              "NOTEBOOK_INTERACTION_CONTROL_DIRECTORY": str(control)}}
    write(control / "configuration.json", {key: value for key, value in result.items() if key != "environment"})
    return result


def write(path, value):
    release.write_json(path, value); path.chmod(0o600)


def stop_and_collect(value, evidence):
    """Cooperate with only this session's helper; do not kill another process.

    Evidence remains durable on success or failure. Missing end/recordings are
    an explicit unmeasured condition, not a synthetic completion receipt.
    """
    control = Path(value["controlDirectory"])
    if not (control / "ui-ended.json").exists():
        write(control / "cancel.json", {"sessionID": value["sessionID"], "status": "cancelled"})
    source = Path(value["nativeJournalDirectory"])
    container = Path(value["simulatorDataContainer"])
    release.require(source.resolve().is_relative_to(container.resolve()) and not source.is_symlink(),
                    "Каталог native журнала вышел из выбранного Simulator контейнера.")
    records = []
    for path in sorted(source.glob(value["sessionID"] + "-*.ndjson")):
        release.require(path.is_file() and not path.is_symlink() and path.stat().st_size <= 8 * 1_024 * 1_024 + 65_536,
                        "Native журнал недопустим или превысил бюджет.")
        data = path.read_bytes()
        first = json.loads(data.splitlines()[0]) if data else {}
        release.require(first.get("kind") == "identity" and first.get("sessionID", "").lower() == value["sessionID"]
                        and first.get("workspaceID") == value["workspaceID"],
                        "Native журнал относится к другой сессии/пространству.")
        target = Path(evidence) / path.name
        release.require(not target.exists(), "Native доказательства не перезаписываются.")
        target.write_bytes(data); target.chmod(0o600)
        records.append({"source": str(path), "copy": str(target), "sha256": release.file_digest(target), "bytes": len(data)})
    receipt = {"sessionID": value["sessionID"], "controlDirectory": str(control), "nativeJournals": records,
               "status": "captured_unassessed" if records and (control / "ui-ended.json").exists() else "unmeasured",
               "latencyMeasured": False, "reason": "Actual window frames and independent pixel review are required"}
    write(Path(evidence) / "interaction-evidence.json", receipt)
    return receipt

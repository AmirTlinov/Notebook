#!/usr/bin/env python3
"""Build and drive an isolated production Mac/Simulator pair; never install a device build."""
import argparse
from contextlib import ExitStack
import fcntl
import importlib.util
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import shutil
import struct
import subprocess
import tempfile
import time
import uuid

import notebook_release as release
import notebook_verification as verification
import notebook_interaction_acceptance as interaction_acceptance
import notebook_scene_observation as scene_observation
import notebook_navigation_observation as navigation_observation

ROOT = Path(__file__).resolve().parents[1]
IPAD_BUNDLE = "com.amirtlinov.notebook.acceptance"
# LaunchServices and XCTest identify Mac applications by bundle ID, not just
# executable path. Distinct worktrees must not activate each other's stand.
def mac_bundle_for(root):
    scope = hashlib.sha256(str(Path(root).resolve()).encode()).hexdigest()[:12]
    return "com.amirtlinov.notebook.mac.acceptance." + scope


MAC_BUNDLE = mac_bundle_for(ROOT)
MAC_BUNDLE_SUFFIX = MAC_BUNDLE.removeprefix("com.amirtlinov.notebook.mac")
# Sandbox containers are keyed by bundle ID and admit their original signer.
# Scope these stateless workers to the verified build team, never reuse an old
# development team's container or alter its ACL to make a test launch succeed.
SCRIPT_BUNDLE_SUFFIX = ".acceptance-runtime-" + release.TEAM.lower()
UI_TEST_BUNDLE = "com.amirtlinov.notebook.acceptance.diagnostic-uitests"


def run(command, *, cwd=ROOT, output=None, timeout=1800, on_exit=None):
    if output:
        with Path(output).open("wb") as log:
            result = subprocess.run(list(map(str, command)), cwd=cwd, stdout=log, stderr=subprocess.STDOUT, timeout=timeout)
        if on_exit is not None:
            on_exit(result.returncode)
        release.require(result.returncode == 0, "Команда не прошла; журнал: " + str(output))
        return b""
    return subprocess.check_output(list(map(str, command)), cwd=cwd, timeout=timeout)


def write(path, value):
    release.write_json(Path(path), value)
    Path(path).chmod(0o600)


def read(path):
    return json.loads(Path(path).read_text())


def info(app, mac=False):
    return plistlib.loads((app / ("Contents/Info.plist" if mac else "Info.plist")).read_bytes())


def mac_acceptance_signer(display):
    # Local Network privacy identifies a Mac application by its certificate.
    # Ad hoc test hosts cannot exercise a stable, independently granted pair.
    return release.development_signer(display, MAC_BUNDLE)


def validate_simulator_entitlements(entitlements):
    identifier = release.TEAM + "." + IPAD_BUNDLE
    release.require(entitlements.get("application-identifier") == identifier
                    and entitlements.get("keychain-access-groups") == [identifier]
                    and set(entitlements) <= {"application-identifier", "keychain-access-groups",
                                              "get-task-allow", "com.apple.developer.team-identifier"}
                    and entitlements.get("com.apple.developer.team-identifier", release.TEAM) == release.TEAM,
                    "Simulator должен иметь собственную подпись и ровно свою Keychain-группу.")


def verify_simulator_signature(app):
    release.require(info(app)["CFBundleIdentifier"] == IPAD_BUNDLE,
                    "Проверка стенда не принимает production bundle.")
    run(["codesign", "--verify", "--strict", app])
    # Xcode's Simulator linker puts the runtime entitlement plist in Mach-O;
    # the ad-hoc code signature itself intentionally has an empty entitlement
    # dictionary. Inspect the installed executable, not a build .xcent sidecar.
    entitlements = simulator_entitlements((app / info(app)["CFBundleExecutable"]).read_bytes())
    validate_simulator_entitlements(entitlements)
    return entitlements


def simulator_entitlements(data):
    release.require(len(data) >= 32, "Нет заголовка Simulator executable.")
    magic, cpu, _, _, count, commands_size, _, _ = struct.unpack_from("<IiiIIIII", data)
    release.require(magic == 0xFEEDFACF and cpu == 0x0100000C
                    and 0 < count <= 4096 and commands_size <= len(data) - 32,
                    "Нужен обычный arm64 Mach-O Simulator executable.")
    cursor, end, platform, payload = 32, 32 + commands_size, None, None
    for _ in range(count):
        release.require(cursor + 8 <= end, "Обрезана таблица Mach-O commands.")
        command, size = struct.unpack_from("<II", data, cursor)
        release.require(size >= 8 and cursor + size <= end, "Неверный размер Mach-O command.")
        if command == 0x32:  # LC_BUILD_VERSION
            release.require(size >= 24, "Обрезана версия платформы Mach-O.")
            platform = struct.unpack_from("<I", data, cursor + 8)[0]
        if command == 0x19:  # LC_SEGMENT_64
            release.require(size >= 72, "Обрезан сегмент Mach-O.")
            sections = struct.unpack_from("<I", data, cursor + 64)[0]
            release.require(72 + 80 * sections <= size, "Обрезана таблица Mach-O sections.")
            for index in range(sections):
                section = cursor + 72 + 80 * index
                name = data[section:section + 16].rstrip(b"\0")
                segment = data[section + 16:section + 32].rstrip(b"\0")
                if (segment, name) == (b"__TEXT", b"__entitlements"):
                    _, byte_count, offset = struct.unpack_from("<QQI", data, section + 32)
                    release.require(payload is None and 0 < byte_count <= 16384
                                    and offset >= end and offset + byte_count <= len(data),
                                    "Неверная область Simulator entitlements.")
                    payload = data[offset:offset + byte_count]
        cursor += size
    release.require(cursor == end and platform == 7 and payload is not None,
                    "Нет встроенных entitlements платформы iOS Simulator.")
    return plistlib.loads(payload)


class SimulatorRecording:
    def __init__(self, udid, evidence, trace=None, duration=240, *, allow_host_processes=False):
        # Simulator is a host process tree, not a tracing isolation boundary:
        # xctrace --device <simulator> --all-processes also captures the Mac.
        release.require(trace is None or allow_host_processes,
                        "Системная трасса захватывает также процессы Mac; нужно явное --allow-host-processes.")
        self.udid, self.evidence, self.trace, self.duration = udid, evidence, trace, duration
        self.processes = []
        self.logs = []

    @staticmethod
    def wait_for_start(process, log_path, timeout, label):
        deadline = time.monotonic() + timeout
        while process.poll() is None and time.monotonic() < deadline:
            if b"Recording started" in log_path.read_bytes():
                return
            time.sleep(0.05)
        # A spawned simctl process is not an active video recording. Stop the
        # scenario before its workload if the selected device never starts it.
        detail = log_path.read_text(errors="replace")[-2000:]
        raise release.ReleaseError(label + " не подтвердил начало записи: " + detail)

    def start(self):
        log_path = self.evidence / "video.log"
        log = log_path.open("wb"); self.logs.append(log)
        process = subprocess.Popen(["xcrun", "simctl", "io", self.udid, "recordVideo", "--codec=h264",
                                    str(self.evidence / "simulator.mp4")], stdout=log, stderr=subprocess.STDOUT)
        self.processes.append(process)
        self.wait_for_start(process, log_path, 10, "Simulator")
        if self.trace:
            write(self.evidence / "trace-scope.json", {"template": self.trace,
                "simulatorUDID": self.udid, "scope": "system_wide_including_host_mac",
                "explicitHostProcessConsent": True, "assessment": "unassessed"})
            trace_path = self.evidence / "trace.log"
            log = trace_path.open("wb"); self.logs.append(log)
            command = ["xcrun", "xctrace", "record", "--template", self.trace,
                "--device", self.udid, "--all-processes", "--time-limit", str(self.duration) + "s",
                "--output", str(self.evidence / "system.trace")]
            if self.trace == "Time Profiler":
                # xctrace's default Hangs threshold is 250 ms. The accepted
                # workload requires system observation beginning at 100 ms.
                options = self.evidence / "trace-options.json"
                defaults = json.loads(run(["xcrun", "xctrace", "record", "--template", self.trace,
                                          "--show-recording-options"], timeout=20))
                release.require(isinstance(defaults.get("Hangs"), dict)
                                and "hangsThreshold" in defaults["Hangs"],
                                "Установленный Time Profiler не предоставил порог измерения остановок.")
                defaults["Hangs"]["hangsThreshold"] = 100
                # xctrace decodes a complete options document; a partial JSON
                # fails before recording with a misleading missing-data error.
                write(options, defaults)
                command.extend(["--recording-options", str(options)])
            # Reuse the per-launch trace owner's documented notification.
            # RC xctrace no longer prints the old "Recording started" text;
            # its "Starting recording" line is not a readiness acknowledgement.
            with system_trace_module().TraceStartNotification() as notification:
                command.extend(["--notify-tracing-started", notification.name])
                process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
                self.processes.append(process)
                deadline = time.monotonic() + 20
                while True:
                    release.require(process.poll() is None and time.monotonic() < deadline,
                        "Системный инструмент не подтвердил начало записи: " + trace_path.read_text(errors="replace")[-2000:])
                    if notification.wait(0.1):
                        break
                release.require(process.poll() is None, "Системный инструмент завершился при подтверждении начала записи.")
                write(self.evidence / "trace-started.json", {"notification": notification.name,
                    "uptimeSeconds": time.monotonic(), "assessment": "captured_unassessed"})

    def stop(self):
        failures = []
        for process in reversed(self.processes):
            if process.poll() is None:
                process.send_signal(signal.SIGINT)
            try:
                code = process.wait(timeout=45)
                if code not in (0, -signal.SIGINT):
                    failures.append(code)
            except subprocess.TimeoutExpired:
                process.terminate(); process.wait(timeout=10); failures.append("timeout")
        for log in self.logs:
            log.close()
        self.logs = []; self.processes = []
        release.require(not failures, "Запись видео или системной трассы не завершилась: " + str(failures))


def build(args):
    release.require(args.development or not run(["git", "status", "--porcelain"]).strip(),
                    "Окончательная приёмка требует зафиксированный чистый срез; для диагностики есть --development.")
    evidence = args.evidence.resolve()
    release.require(not evidence.exists(), "Нужен новый каталог сборки стенда.")
    evidence.mkdir(parents=True, mode=0o700)
    before = release.source_inputs(ROOT)
    write(evidence / "source.json", before)
    snapshot = evidence / "source"
    release.copy_source(ROOT, snapshot, before)
    revision = run(["git", "rev-parse", "HEAD"]).decode().strip()
    inventory = json.loads(run(["xcrun", "simctl", "list", "devices", "available", "--json"]))
    devices = [d for values in inventory["devices"].values() for d in values if d["udid"] == args.simulator]
    release.require(len(devices) == 1 and ".iPad-" in devices[0].get("deviceTypeIdentifier", ""), "Нужен точный iPad Simulator UDID.")
    run(["npm", "ci", "--ignore-scripts"], cwd=snapshot / "MCP", output=evidence / "dependencies.log")
    runtime = release.prepare_typesetter_runtime(snapshot, release.release_commands(evidence), "iphonesimulator", stage=ROOT / ".build/notebook-typesetter-runtime")
    release.prepare_typesetter_runtime(snapshot, release.release_commands(evidence), "macosx", stage=runtime)
    typescript_runtime = release.prepare_typescript_runtime(snapshot, release.release_commands(evidence))
    release.prepare_codex_runtime(snapshot, release.release_commands(evidence))
    run(["xcodegen", "generate", "--spec", "project.yml"], cwd=snapshot / "Applications", output=evidence / "project.log")
    for platform, scheme, destination in (("ipad", "NotebookAcceptance", "platform=iOS Simulator,id=" + args.simulator),
                                           ("mac", "NotebookMacAcceptance", "platform=macOS,arch=arm64")):
        command = ["xcrun", "xcodebuild", "-quiet", "-project", snapshot / "Applications/Notebook.xcodeproj",
                   "-scheme", scheme, "-configuration", "Release", "-destination", destination,
                   "-derivedDataPath", evidence / "derived" / platform, "-parallel-testing-enabled", "NO",
                   "NOTEBOOK_BUNDLE_SUFFIX=.acceptance", "NOTEBOOK_ACCEPTANCE_ENABLED=YES", "ENABLE_TESTABILITY=YES",
                   "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES"]
        if platform == "ipad":
            command += ["CODE_SIGN_IDENTITY=-", "CODE_SIGN_STYLE=Manual",
                        "CODE_SIGNING_ALLOWED=YES", "DEVELOPMENT_TEAM=" + release.TEAM,
                        "NOTEBOOK_IPAD_ENTITLEMENTS=iPad/Acceptance.entitlements"]
        else:
            command += ["CODE_SIGN_IDENTITY=Apple Development", "CODE_SIGN_STYLE=Automatic",
                        "CODE_SIGNING_ALLOWED=YES", "DEVELOPMENT_TEAM=" + release.TEAM,
                        "NOTEBOOK_SCRIPT_BUNDLE_SUFFIX=" + SCRIPT_BUNDLE_SUFFIX,
                        "NOTEBOOK_MAC_BUNDLE_SUFFIX=" + MAC_BUNDLE_SUFFIX]
        command.append("NOTEBOOK_TYPESETTER_RUNTIME=" + str(runtime))
        if platform == "mac":
            command.append("NOTEBOOK_TYPESCRIPT_RUNTIME=" + str(typescript_runtime))
        run(command + ["build-for-testing"], output=evidence / (platform + "-build.log"))
        if platform == "mac":
            mac_app = evidence / "derived/mac/Build/Products/Release/Notebook.app"
            signing = release.release_commands(evidence)
            display = signing("acceptance-mac-signer", ["/usr/bin/codesign", "--display", "--verbose=4", mac_app], read_output=True)
            signer, _ = mac_acceptance_signer(b"\n".join(display).decode())
            release.restrict_test_script_services(mac_app, snapshot, signing, bundle_identifier=MAC_BUNDLE, signing_identity=signer)
            display = signing("acceptance-mac-signature", ["/usr/bin/codesign", "--display", "--verbose=4", mac_app], read_output=True)
            _, mac_signature = mac_acceptance_signer(b"\n".join(display).decode())
    release.require(before == release.source_inputs(snapshot), "Исходники независимой копии изменились во время сборки.")
    unchanged = release.source_inputs(ROOT) == before
    release.require(args.development or unchanged, "Рабочий срез изменился во время окончательной сборки стенда.")
    ipad = evidence / "derived/ipad/Build/Products/Release-iphonesimulator/Notebook.app"
    mac = evidence / "derived/mac/Build/Products/Release/Notebook.app"
    release.require(info(ipad)["CFBundleIdentifier"] == IPAD_BUNDLE and info(mac, True)["CFBundleIdentifier"] == MAC_BUNDLE,
                    "Стенд обязан использовать отдельные bundle IDs.")
    simulator_entitlements = verify_simulator_signature(ipad)
    services = {"NotebookScriptService": "com.amirtlinov.notebook.script-service" + SCRIPT_BUNDLE_SUFFIX,
                "NotebookMarkupService": "com.amirtlinov.notebook.markup-service" + SCRIPT_BUNDLE_SUFFIX}
    for name, identifier in services.items():
        service = mac / "Contents/XPCServices" / (name + ".xpc")
        release.require(info(mac, True).get(name) == identifier and info(service, True).get("CFBundleIdentifier") == identifier,
                        "Исполнитель стенда должен иметь собственную устойчивую подписанную идентичность.")
    value = {"format": 1, "developmentBuild": args.development, "workingTreeUnchanged": unchanged,
             "sourceRevision": revision, "sourceSHA256": before["sha256"], "simulator": devices[0],
             "ipadApp": str(ipad), "macApp": str(mac), "source": str(snapshot),
             "simulatorEntitlements": simulator_entitlements,
             "macSignature": mac_signature,
             "workerBundleSuffix": SCRIPT_BUNDLE_SUFFIX,
             "xcode": run(["xcodebuild", "-version"]).decode().strip(),
             "macOS": run(["sw_vers", "-productVersion"]).decode().strip(),
             "macOSBuild": run(["sw_vers", "-buildVersion"]).decode().strip()}
    write(evidence / "build.json", value)
    print(json.dumps(value, ensure_ascii=False))


def ui_test_inputs(source):
    root = Path(source) / "Applications/AcceptanceUITests"
    release.require(root.is_dir() and not root.is_symlink(), "Нужны обычные исходники acceptance UI tests.")
    files = []
    for path in sorted(root.rglob("*")):
        release.require(not path.is_symlink(), "UI sources не могут ссылаться за пределы snapshot.")
        if path.is_dir():
            continue
        release.require(path.is_file() and path.suffix == ".swift", "UI-only snapshot принимает только Swift test sources.")
        files.append({"path": str(path.relative_to(source)), "sha256": release.file_digest(path)})
    release.require(bool(files), "Пустой UI test snapshot запрещён.")
    return {"files": files, "sha256": release.digest(json.dumps(files, sort_keys=True).encode())}


def ui_only_project():
    target = "NotebookAcceptanceUITests"
    return {"name": "NotebookAcceptanceUIHarness", "options": {"minimumXcodeGenVersion": "2.46.0",
        "xcodeVersion": "27.0", "deploymentTarget": {"iOS": "27.0"}},
        "settings": {"base": {"SWIFT_VERSION": "6.0", "SWIFT_STRICT_CONCURRENCY": "complete"}},
        "targets": {target: {"type": "bundle.ui-testing", "platform": "iOS",
            "sources": [{"path": "source/Applications/AcceptanceUITests"}],
            "settings": {"base": {"PRODUCT_BUNDLE_IDENTIFIER": UI_TEST_BUNDLE,
                "GENERATE_INFOPLIST_FILE": True, "TARGETED_DEVICE_FAMILY": "2"}}}},
        "schemes": {"NotebookAcceptanceUIHarness": {"build": {"targets": {target: "all"}},
            "test": {"targets": [target], "gatherCoverageData": False}}}}


def ui_targets(spec):
    targets = [target for configuration in spec.get("TestConfigurations", [])
               for target in configuration.get("TestTargets", [])]
    return targets or [target for key, target in spec.items()
                       if key != "__xctestrun_metadata__" and isinstance(target, dict)]


def ui_only_products(products, original):
    runner = products / "Release-iphonesimulator/NotebookAcceptanceUITests-Runner.app"
    bundle = runner / "PlugIns/NotebookAcceptanceUITests.xctest"
    release.require(info(bundle).get("CFBundleIdentifier") == UI_TEST_BUNDLE, "Неверная идентичность diagnostic test bundle.")
    targets = ui_targets(plistlib.loads(original.read_bytes()))
    release.require(len(targets) == 1 and targets[0].get("BlueprintName") == "NotebookAcceptanceUITests",
                    "UI-only project должен содержать ровно один известный test target.")
    target = targets[0]
    def resolve(path):
        return Path(path.replace("__TESTROOT__", str(products)).replace("__TESTHOST__", str(runner))).resolve()
    release.require(not target.get("UITargetAppPath") and resolve(target["TestHostPath"]) == runner.resolve()
                    and resolve(target["TestBundlePath"]) == bundle.resolve(),
                    "Diagnostic test target не должен назначать или подменять приложение.")
    for path in target.get("DependentProductPaths", []):
        release.require(resolve(path).is_relative_to(runner.resolve()), "UI runner содержит постороннюю product dependency.")
    release.require(not list(products.glob("*/Notebook.app")), "UI-only build неожиданно собрал приложение.")
    return runner


def ui_build(args):
    directory, evidence = args.run.resolve(), args.evidence.resolve()
    value = read(directory / "run.json")
    built = read(Path(value["build"]) / "build.json")
    release.require(not evidence.exists(), "Нужен новый каталог diagnostic UI-only build.")
    before = installed_ipad_state(built["simulator"]["udid"])
    release.require(before["bundleSHA256"] == release.app_manifest(Path(built["ipadApp"]))["sha256"],
                    "Установленное приложение отличается от выбранного accepted build.")
    evidence.mkdir(parents=True, mode=0o700)
    source = ui_test_inputs(ROOT)
    snapshot = evidence / "source"
    for entry in source["files"]:
        destination = snapshot / entry["path"]
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / entry["path"], destination)
    release.require(ui_test_inputs(snapshot) == source, "UI test source изменился при копировании.")
    write(evidence / "test-source.json", source)
    write(evidence / "project.json", ui_only_project())
    receipt = {"format": 1, "diagnosticOnly": True, "status": "building", "runID": value["runID"],
               "applicationBuild": value["build"], "applicationSourceSHA256": built["sourceSHA256"],
               "applicationBundleSHA256": before["bundleSHA256"], "simulatorUDID": built["simulator"]["udid"],
               "testSourceSHA256": source["sha256"], "source": str(snapshot), "startedAt": time.time(),
               "driverSHA256": release.file_digest(Path(__file__)), "installedApplicationBefore": before}
    write(evidence / "ui-build.json", receipt)
    try:
        run(["xcodegen", "generate", "--spec", evidence / "project.json"], cwd=evidence, output=evidence / "project.log")
        command = ["xcrun", "xcodebuild", "-quiet", "-project", evidence / "NotebookAcceptanceUIHarness.xcodeproj",
            "-scheme", "NotebookAcceptanceUIHarness", "-configuration", "Release",
            "-destination", "platform=iOS Simulator,id=" + built["simulator"]["udid"],
            "-derivedDataPath", evidence / "derived/ipad", "-parallel-testing-enabled", "NO",
            "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES", "CODE_SIGN_IDENTITY=-", "CODE_SIGN_STYLE=Manual",
            "CODE_SIGNING_ALLOWED=YES", "DEVELOPMENT_TEAM=" + release.TEAM, "build-for-testing"]
        write(evidence / "build-command.json", list(map(str, command)))
        run(command, output=evidence / "build.log")
        products = evidence / "derived/ipad/Build/Products"
        originals = list(products.glob("*.xctestrun"))
        release.require(len(originals) == 1, "Нужен единственный UI-only xctestrun.")
        runner = ui_only_products(products, originals[0])
        release.require(ui_test_inputs(snapshot) == source, "Immutable UI test source изменился во время сборки.")
        after = installed_ipad_state(built["simulator"]["udid"])
        release.require(before == after, "UI-only build изменил установленное приложение или контейнер.")
        receipt.update(status="built", installedApplicationAfter=after, installedApplicationPreserved=True,
            products=str(products), xctestrun=str(originals[0]), xctestrunSHA256=release.file_digest(originals[0]),
            runner=str(runner), runnerSHA256=release.app_manifest(runner)["sha256"])
    except BaseException as error:
        receipt.update(status="failed", error={"type": type(error).__name__, "message": str(error)})
        raise
    finally:
        receipt["endedAt"] = time.time()
        write(evidence / "ui-build.json", receipt)
    print(str(evidence))


def selected_ui_build(path, *, platform, value, built):
    release.require(platform == "ipad", "Diagnostic UI-only build предназначен только для iPad Simulator.")
    path = Path(path).resolve()
    receipt = read(path / "ui-build.json")
    release.require(receipt.get("status") == "built" and receipt.get("diagnosticOnly") is True
        and receipt["runID"] == value["runID"] and receipt["applicationBuild"] == value["build"]
        and receipt["applicationSourceSHA256"] == built["sourceSHA256"]
        and receipt["simulatorUDID"] == built["simulator"]["udid"], "UI-only build не принадлежит выбранной паре и приложению.")
    source = read(path / "test-source.json")
    release.require(source == ui_test_inputs(path / "source") and source["sha256"] == receipt["testSourceSHA256"],
                    "Immutable UI test source не совпадает с квитанцией.")
    products, original = Path(receipt["products"]), Path(receipt["xctestrun"])
    release.require(products.resolve().is_relative_to(path) and original.resolve().is_relative_to(products.resolve())
                    and release.file_digest(original) == receipt["xctestrunSHA256"], "UI-only xctestrun изменился.")
    runner = ui_only_products(products, original)
    release.require(str(runner) == receipt["runner"] and release.app_manifest(runner)["sha256"] == receipt["runnerSHA256"]
                    and release.app_manifest(Path(built["ipadApp"]))["sha256"] == receipt["applicationBundleSHA256"],
                    "UI runner или приложение изменились после diagnostic build.")
    return products, original, {"diagnosticOnly": True, "build": str(path),
        "testSourceSHA256": receipt["testSourceSHA256"], "runnerSHA256": receipt["runnerSHA256"],
        "applicationSourceSHA256": receipt["applicationSourceSHA256"], "applicationBundleSHA256": receipt["applicationBundleSHA256"]}


def prepare(args):
    built = read(args.build / "build.json")
    identifier = str(uuid.UUID(args.run_id)) if args.run_id else str(uuid.uuid4())
    directory = args.build.resolve() / "runs" / identifier
    # The helper owns a new runtime under Application Support. Evidence stays
    # beside the immutable build; starting the app must not request access to
    # the user's Documents merely because the checkout happens to live there.
    runtime = (Path.home() / "Library/Application Support/NotebookAcceptance" / identifier).resolve()
    release.require(not directory.exists() and not runtime.exists(), "Нужен новый каталог данных и квитанции стенда.")
    release.require(info(Path(built["macApp"]), True)["CFBundleIdentifier"] == MAC_BUNDLE,
                    "Mac-стенд должен принадлежать этому checkout; старый run не мигрируется.")
    ipad = Path(built["ipadApp"])
    release.require(info(ipad)["CFBundleIdentifier"] == IPAD_BUNDLE, "Нельзя устанавливать production bundle из маршрута стенда.")
    verify_simulator_signature(ipad)
    run(["xcrun", "simctl", "install", built["simulator"]["udid"], ipad])
    container = run(["xcrun", "simctl", "get_app_container", built["simulator"]["udid"], IPAD_BUNDLE, "data"]).decode().strip()
    run(["swift", "run", "--package-path", built["source"], "notebook-acceptance", "prepare", runtime,
                  built["sourceRevision"], container, MAC_BUNDLE], timeout=600)
    value = read(runtime / "run.json")
    value["build"] = str(args.build.resolve())
    value["runtimeDirectory"] = str(runtime)
    value["preparationDriverSHA256"] = release.file_digest(Path(__file__))
    write(runtime / "run.json", value)
    directory.mkdir(parents=True, mode=0o700)
    write(directory / "run.json", value)
    run(["/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
         "-f", built["macApp"]])
    print(json.dumps({"run": str(directory), "workspaceID": value["workspaceID"]}))


def rebase_simulator_manifest(manifest, old_container, new_container):
    old, new = Path(old_container).resolve(), Path(new_container).resolve()
    root = Path(manifest["root"]).resolve()
    release.require(root.is_relative_to(old) and root != old,
                    "Данные iPad должны принадлежать выбранному private Simulator container.")
    return {**manifest, "root": str(new / root.relative_to(old))}


def data_inventory(root):
    root = Path(root)
    release.require(root.is_dir() and not root.is_symlink(), "Нет обычного каталога данных стенда.")
    files = {}
    for path in sorted(root.rglob("*")):
        release.require(not path.is_symlink(), "Стенд не должен вести за пределы своего каталога данных.")
        if path.is_file():
            files[str(path.relative_to(root))] = release.file_digest(path)
    return files


def installed_ipad_manifest(value, simulator):
    container = Path(run(["xcrun", "simctl", "get_app_container", simulator, IPAD_BUNDLE, "data"]).decode().strip()).resolve()
    original = Path(value["iPadManifest"]).resolve()
    relative = original.relative_to(container.parent)
    release.require(len(relative.parts) >= 3 and relative.parts[1] == "Documents",
                    "Manifest не принадлежит контейнеру iPad этого Simulator.")
    uuid.UUID(relative.parts[0])
    old_container = container.parent / relative.parts[0]
    moved = container.joinpath(*relative.parts[1:])
    manifest = read(moved)
    release.require(manifest["runID"].lower() == value["runID"]
                    and manifest["workspaceID"] == value["workspaceID"] and manifest["bundleID"] == IPAD_BUNDLE,
                    "Идентичность перенесённого manifest изменилась.")
    return container, moved, rebase_simulator_manifest(manifest, old_container, container)


def installed_ipad_state(simulator):
    bundle = Path(run(["xcrun", "simctl", "get_app_container", simulator, IPAD_BUNDLE, "app"]).decode().strip()).resolve()
    release.require(info(bundle).get("CFBundleIdentifier") == IPAD_BUNDLE,
                    "UI runner получил не изолированное приложение.")
    container = Path(run(["xcrun", "simctl", "get_app_container", simulator, IPAD_BUNDLE, "data"]).decode().strip()).resolve()
    return {"bundlePath": str(bundle), "dataContainer": str(container),
            "bundleSHA256": release.app_manifest(bundle)["sha256"]}


def use_installed_ui_application(target):
    # Preserve the runner and frameworks, removing only the application that
    # XCTest would otherwise reinstall before the explicit XCUIApplication.
    target_path = target.pop("UITargetAppPath", None)
    target["UseUITargetAppProvidedByTests"] = True
    target["DependentProductPaths"] = [path for path in target.get("DependentProductPaths", [])
                                      if path != target_path]


def system_trace_module():
    path = ROOT / "Tests/NotebookDocumentAcceptance/system_trace.py"
    specification = importlib.util.spec_from_file_location("notebook_acceptance_system_trace", path)
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


def write_upgrade_manifest(previous_manifest, manifest, source_sha256):
    # A container handoff, not source content, owns this launch manifest. A
    # development and a clean build may have identical sources; the earlier
    # manifest must remain byte-for-byte intact after either installation.
    path = previous_manifest.with_name("ipad-build-" + source_sha256[:16] + "-" + str(uuid.uuid4()) + ".json")
    release.require(not path.exists(), "Manifest этого обновления уже существует.")
    write(path, manifest)
    return path


def upgrade(args):
    """Update only the selected private pair; preserve its data and trust scope."""
    release.require(args.mac_pid > 1, "Нужен конкретный PID private helper.")
    previous_directory, build_directory = args.from_run.resolve(), args.build.resolve()
    previous, built = read(previous_directory / "run.json"), read(build_directory / "build.json")
    old_built = read(Path(previous["build"]) / "build.json")
    identifier = str(uuid.UUID(previous["runID"]))
    release.require(old_built["simulator"]["udid"] == built["simulator"]["udid"],
                    "Обновление стенда не переносит данные на другой Simulator.")
    directory = build_directory / "runs" / identifier
    release.require(not directory.exists(), "Для обновления нужен новый каталог квитанции.")
    release.require(info(Path(built["macApp"]), True)["CFBundleIdentifier"] == MAC_BUNDLE
                    and info(Path(old_built["macApp"]), True)["CFBundleIdentifier"] == MAC_BUNDLE,
                    "Обновление принимает только private Mac bundle.")
    verify_simulator_signature(Path(built["ipadApp"]))
    runtime = (Path.home() / "Library/Application Support/NotebookAcceptance" / identifier).resolve()
    release.require(Path(previous["macManifest"]).resolve().is_relative_to(runtime),
                    "Manifest Mac должен принадлежать private acceptance runtime.")
    simulator = built["simulator"]["udid"]
    old_container, installed_manifest, ipad_manifest = installed_ipad_manifest(previous, simulator)
    manifests = {"macManifest": read(previous["macManifest"]), "iPadManifest": ipad_manifest}
    for key, manifest in manifests.items():
        expected = MAC_BUNDLE if key == "macManifest" else IPAD_BUNDLE
        release.require(manifest["runID"].lower() == identifier
                        and manifest["workspaceID"] == previous["workspaceID"]
                        and manifest["bundleID"] == expected,
                        "Идентичность выбранной пары не совпадает с квитанцией.")
    mac_root = Path(manifests["macManifest"]["root"]).resolve()
    release.require(mac_root.is_relative_to(runtime) and mac_root != runtime,
                    "Хранилище Mac должно оставаться внутри private runtime.")
    expected_executable = str(Path(old_built["macApp"]) / "Contents/MacOS/Notebook")
    actual_executable = run(["ps", "-p", str(args.mac_pid), "-o", "args="]).decode().strip()
    release.require(actual_executable == expected_executable,
                    "PID не принадлежит предыдущему private helper; процесс не остановлен.")
    manifest_relative = installed_manifest.relative_to(old_container)
    rebase_simulator_manifest(manifests["iPadManifest"], old_container, old_container)
    directory.mkdir(parents=True, mode=0o700)
    write(directory / "upgrade-start.json", {"previousRun": str(previous_directory),
          "oldPrivatePID": args.mac_pid, "oldExecutable": actual_executable, "startedAt": time.time()})
    # Stop precisely the validated owners before measuring their stored bytes.
    subprocess.run(["xcrun", "simctl", "terminate", simulator, IPAD_BUNDLE],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20)
    os.kill(args.mac_pid, signal.SIGTERM)
    deadline = time.monotonic() + 10
    while subprocess.run(["ps", "-p", str(args.mac_pid)], stdout=subprocess.DEVNULL).returncode == 0:
        release.require(time.monotonic() < deadline, "Private helper не завершился; второй писатель не запущен.")
        time.sleep(0.05)
    before = {"mac": data_inventory(mac_root), "iPad": data_inventory(manifests["iPadManifest"]["root"])}
    write(directory / "data-before.json", before)
    mac_manifest_bytes = Path(previous["macManifest"]).read_bytes()
    ipad_manifest_bytes = installed_manifest.read_bytes()
    run(["xcrun", "simctl", "install", simulator, built["ipadApp"]])
    new_container = run(["xcrun", "simctl", "get_app_container", simulator, IPAD_BUNDLE, "data"]).decode().strip()
    relocated_old_manifest = Path(new_container) / manifest_relative
    release.require(relocated_old_manifest.read_bytes() == ipad_manifest_bytes
                    and Path(previous["macManifest"]).read_bytes() == mac_manifest_bytes,
                    "Существующие manifests изменились при обновлении.")
    ipad_manifest = rebase_simulator_manifest(manifests["iPadManifest"], old_container, new_container)
    after = {"mac": data_inventory(mac_root), "iPad": data_inventory(ipad_manifest["root"])}
    write(directory / "data-after.json", after)
    release.require(before == after, "Обновление изменило сохранённые данные; пара не запущена.")
    new_manifest = write_upgrade_manifest(relocated_old_manifest, ipad_manifest, built["sourceSHA256"])
    current = {**previous, "build": str(build_directory), "sourceSHA256": built["sourceSHA256"],
               "sourceRevision": built["sourceRevision"], "iPadManifest": str(new_manifest),
               "continuedFrom": str(previous_directory / "run.json"),
               "continuation": {"sameRuntimeAndIdentities": True, "dataBytesPreserved": True,
                   "previousSimulatorContainer": str(old_container), "simulatorContainer": new_container,
                   "preservedPreviousIPadManifest": str(relocated_old_manifest),
                   "driverSHA256": release.file_digest(Path(__file__))}}
    write(directory / "run.json", current)
    command = ["/usr/bin/open", "-n", "-g", "-j", "--env", "NOTEBOOK_ACCEPTANCE_MANIFEST=" + previous["macManifest"],
               "--stdout", str(directory / "mac.stdout.log"), "--stderr", str(directory / "mac.stderr.log"), built["macApp"]]
    run(command)
    write(directory / "launch.json", {"command": command, "sourceSHA256": built["sourceSHA256"],
          "previousPrivatePIDStopped": args.mac_pid, "launchedAt": time.time()})
    print(json.dumps({"run": str(directory), "workspaceID": current["workspaceID"]}))


def document_ui_request(platform, test, document_id, document_title):
    """Validate the public fixture address before loading or touching a stand."""
    suite = "NotebookDocumentAcceptanceUITests/"
    mac_document = test in {
        "NotebookAcceptanceMacUITests/testPublicScientificDocumentRetainsARealControlEditAfterReopening",
        "NotebookAcceptanceMacUITests/testSourceUnavailableUsesTheWholePaneInBesideAndCodeModes",
    }
    if not test.startswith(suite) and not mac_document:
        release.require(document_id is None and document_title is None,
                        "Адрес документа допускается только в документном UI-сценарии.")
        return None
    release.require(platform == ("mac" if mac_document else "ipad"),
                    "Документный сценарий требует свою платформу Mac или iPad Simulator.")
    release.require(isinstance(document_id, str) and re.fullmatch(
        r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}", document_id),
        "Нужен --document-id: UUID из результата публичного create-control.js.")
    identifier = uuid.UUID(document_id)
    release.require(identifier.int != 0, "Пустой UUID не адресует контрольный документ.")
    release.require(isinstance(document_title, str) and document_title.strip()
                    and len(document_title) <= 512 and "\x00" not in document_title,
                    "Нужен --document-title: сохранённое название публичного контрольного документа.")
    cold = suite + "testTenColdOpeningsAndWarmDistantLinksMeetNativeInstallationBudgets"
    return {"documentID": str(identifier), "title": document_title,
            "timeoutSeconds": 660 if test == cold else 300,
            "environment": {"NOTEBOOK_ACCEPTANCE_DOCUMENT_ID": str(identifier),
                            "NOTEBOOK_ACCEPTANCE_DOCUMENT_TITLE": document_title}}


COLLABORATION_UI_TESTS = frozenset({
    "NotebookCollaborationAcceptanceUITests/testCreatedMaterialRetainsHumanEditsThroughAgentUndoAndCancellation",
    "NotebookCollaborationAcceptanceUITests/testConcurrentHumanStateRejectsStaleAgentWriteAndSurvivesItsUndo",
})

COLLABORATION_RECOVERY_UI_TESTS = frozenset({
    "NotebookCollaborationAcceptanceUITests/testUseCreatedDocumentFromTheExistingRealConversation",
    "NotebookCollaborationAcceptanceUITests/testContinueSavedDocumentFromTheExistingRealConversation",
    "NotebookCollaborationAcceptanceUITests/testOfflineOutgoingAndDraftSurviveRelaunchInTheSameConversation",
    "NotebookCollaborationAcceptanceUITests/testReconnectedConversationDeliversOnceAndRetainsUnsentDraft",
})


def supports_attached_ui_trace(platform, test):
    """Only native scenarios with the launch/began/ended handshake may attach."""
    return platform == "ipad" and (test.startswith(
        ("NotebookAcceptanceUITests/", "NotebookDocumentAcceptanceUITests/")) or test in COLLABORATION_UI_TESTS)


def ui_timeout(platform, test, *, document=None, workload_seconds=1800):
    """Keep the host alive through the selected native scenario's own deadline."""
    if test in COLLABORATION_UI_TESTS | COLLABORATION_RECOVERY_UI_TESTS:
        release.require(platform == "ipad", "Совместная UI-приёмка выполняется на iPad Simulator.")
        # XCTest allows 600 seconds, including genuine Codex packet waits.
        # The outer process gets another minute to report its terminal result.
        return 660
    if document:
        return document["timeoutSeconds"]
    if test.endswith("/testThirtyMinutesOfMixedInteraction"):
        release.require(platform == "ipad" and 1800 <= workload_seconds <= 2700,
                        "Смешанная приёмка требует от 30 до 45 минут на iPad Simulator.")
        return workload_seconds + 180
    return 240


def finalize_ui_attempt(*, evidence, scenario, primary_error, trace, trace_finished,
                        recording, installed_before, simulator, interaction=None, scene=None, navigation=None,
                        runner_exit=None, expected_test=None):
    """Attempt every cleanup step without replacing the scenario's failure."""
    errors = []

    def attempt(stage, operation):
        try:
            return operation()
        except BaseException as error:
            errors.append((stage, error))
            return None

    def describe(error):
        return {"type": type(error).__name__, "message": str(error)}

    if interaction:
        attempt("interaction.stop-and-collect", lambda: interaction_acceptance.stop_and_collect(interaction, evidence))
    if scene:
        attempt("scene-observation.collect", lambda: scene_observation.collect(scene, evidence, launch_manifest=scenario["launchManifest"]))
    if navigation:
        attempt("navigation-observation.collect", lambda: navigation_observation.collect(navigation, evidence, launch_manifest=scenario["launchManifest"]))
    if trace and not trace_finished:
        attempt("trace.cancel", trace.cancel)
    if recording:
        attempt("recording.stop", recording.stop)
    installed_after = None
    if installed_before is not None:
        installed_after = attempt("installed-application.snapshot", lambda: installed_ipad_state(simulator))
        if installed_after is not None:
            attempt("installed-application.receipt", lambda: write(evidence / "installed-application-after.json", installed_after))
            attempt("installed-application.identity", lambda: release.require(installed_before == installed_after,
                    "UI runner изменил приложение или его контейнер; результат не относится к выбранной паре."))
    result_exists = attempt("result-bundle.inspect", lambda: (evidence / "result.xcresult").exists())
    if primary_error is None and expected_test is not None:
        attempt("runner-result.completed", lambda: release.require(runner_exit == 0 and result_exists,
                "UI runner не оставил завершённый результат выбранного сценария."))
    if result_exists:
        for kind in ("attachments", "metrics"):
            attempt("export." + kind, lambda kind=kind: run(["xcrun", "xcresulttool", "export", kind,
                    "--path", evidence / "result.xcresult", "--output-path", evidence / kind]))
        # A directory can exist while XCTest is still producing its result.
        # Only a returned subprocess result witnesses runner termination.
        if runner_exit is not None:
            results = {}
            for kind in ("summary", "tests"):
                def export_result(kind=kind):
                    value = json.loads(run(["xcrun", "xcresulttool", "get", "test-results", kind,
                                           "--path", evidence / "result.xcresult", "--compact"]))
                    write(evidence / (kind + ".json"), value)
                    results[kind] = value
                attempt("export." + kind, export_result)
            if primary_error is None and expected_test is not None:
                if "summary" in results:
                    summary = results["summary"]
                    attempt("result-summary.validate", lambda: release.require(
                        runner_exit == 0 and summary.get("failedTests", 0) == 0
                        and summary.get("passedTests", 0) == 1 and summary.get("skippedTests", 0) == 0
                        and summary.get("runtimeWarnings") == [], "UI runner не подтвердил исполненный сценарий."))
                if "tests" in results:
                    attempt("result-tests.validate", lambda: verification.validate_executed_tests(results["tests"], [expected_test]))
    receipt = {**scenario, "endedAt": time.time(),
               "runnerExitCode": runner_exit,
               "status": "failed" if primary_error is not None or errors else "passed",
               "primaryError": describe(primary_error) if primary_error is not None else None,
               "cleanupErrors": [{"stage": stage, **describe(error)} for stage, error in errors],
               "installedApplicationPreserved": installed_before == installed_after
                    if installed_before is not None and installed_after is not None else None,
               "systemTraceLifecycleFinished": trace_finished if trace else None}
    # Write after exports so their failures are also durable. Even a failed
    # snapshot, trace shutdown or export must not prevent this receipt attempt.
    attempt("scenario.receipt", lambda: write(evidence / "scenario.json", receipt))
    if primary_error is not None:
        for stage, error in errors:
            if hasattr(primary_error, "add_note"):
                primary_error.add_note("Cleanup " + stage + ": " + type(error).__name__ + ": " + str(error))
    elif errors:
        raise errors[0][1]


def ui(args):
    driver_sha = release.file_digest(Path(__file__))
    release.require(re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*/test[A-Za-z0-9_]+", args.test),
                    "Нужен точный Suite/testMethod из изолированного UI target.")
    allow_host_processes = getattr(args, "allow_host_processes", False)
    release.require(not allow_host_processes or (args.platform == "ipad" and args.trace),
                    "--allow-host-processes относится только к явно выбранной системной трассе iPad Simulator.")
    release.require(args.trace is None or args.platform == "ipad",
                    "UI-драйвер системной трассы работает только с iPad Simulator.")
    release.require(args.trace in (None, "Time Profiler") or allow_host_processes,
                    "Этот инструмент записывает также процессы Mac; нужно явное --allow-host-processes.")
    document = document_ui_request(args.platform, args.test, args.document_id, args.document_title)
    interaction_request = interaction_acceptance.request(args)
    scene_request = scene_observation.request(args)
    navigation_request = navigation_observation.request(args)
    directory = args.run.resolve()
    workload = args.test.endswith("/testThirtyMinutesOfMixedInteraction")
    timeout = ui_timeout(args.platform, args.test, document=document, workload_seconds=args.workload_seconds)
    value = read(directory / "run.json")
    built = read(Path(value["build"]) / "build.json")
    attempt = str(uuid.uuid4())
    evidence = directory / (args.platform + "-" + args.test.split("/")[-1] + "-" + attempt)
    attached_trace = args.trace == "Time Profiler" and not allow_host_processes
    release.require(not attached_trace or supports_attached_ui_trace(args.platform, args.test),
        "Time Profiler требует iPad сценарий с настоящим per-launch trace handshake.")
    trace_session = str(uuid.uuid4()) if attached_trace else None
    products = Path(value["build"]) / "derived" / args.platform / "Build/Products"
    test_build = getattr(args, "test_build", None)
    test_provenance = None
    if test_build:
        products, original, test_provenance = selected_ui_build(test_build, platform=args.platform, value=value, built=built)
        originals = [original]
    else:
        originals = [p for p in products.glob("*.xctestrun") if not p.name.startswith("acceptance-")]
    release.require(len(originals) == 1, "Нужен единственный исходный xctestrun выбранной платформы.")
    spec = plistlib.loads(originals[0].read_bytes())
    target_name = "NotebookAcceptanceUITests" if args.platform == "ipad" else "NotebookMacAcceptanceUITests"
    ipad_container, stored_ipad_manifest, ipad_manifest = installed_ipad_manifest(value, built["simulator"]["udid"])
    manifest = ipad_manifest if args.platform == "ipad" else read(value["macManifest"])
    interaction = interaction_acceptance.prepare(value, built, manifest, ipad_container, interaction_request) if interaction_request else None
    peer = read(value["macManifest"]) if args.platform == "ipad" else ipad_manifest
    launch_manifest = str(stored_ipad_manifest)
    if args.platform == "ipad":
        ui_manifest = stored_ipad_manifest.with_name("ipad-ui-" + str(uuid.uuid4()) + ".json")
        write(ui_manifest, manifest)
        launch_manifest = str(ui_manifest)
    environment = {"NOTEBOOK_ACCEPTANCE_MANIFEST": launch_manifest if args.platform == "ipad" else value["macManifest"],
                   "NOTEBOOK_ACCEPTANCE_PEER_ID": peer["actorID"], "NOTEBOOK_ACCEPTANCE_WORKSPACE_ID": value["workspaceID"],
                   "NOTEBOOK_ACCEPTANCE_REPLY_MARKER": "ACCEPTANCE_REPLY_" + value["runID"]}
    if args.platform == "mac":
        environment["NOTEBOOK_ACCEPTANCE_MAC_APPLICATION"] = built["macApp"]
    if interaction:
        environment.update(interaction["environment"])
    if document:
        environment.update(document["environment"])
    if attached_trace:
        environment.update({"NOTEBOOK_TRACE_SESSION_ID": trace_session,
                            "NOTEBOOK_TRACE_CONTROL_DIRECTORY": str(evidence / "trace-control")})
    if workload:
        environment["NOTEBOOK_ACCEPTANCE_WORKLOAD_SECONDS"] = str(args.workload_seconds)
    if args.pencil:
        environment["NOTEBOOK_ACCEPTANCE_PENCIL_CONTACTS"] = "1"
    if args.pencil:
        release.require(args.platform == "ipad", "Профиль Pencil доступен только Simulator.")
        manifest["simulatorContact"] = "pencil"
        contact_manifest = stored_ipad_manifest.with_name("ipad-pencil-" + str(uuid.uuid4()) + ".json")
        write(contact_manifest, manifest)
        environment["NOTEBOOK_ACCEPTANCE_MANIFEST"] = str(contact_manifest)
    scene = scene_observation.prepare(value, built, manifest, ipad_container, scene_request) if scene_request else None
    navigation = navigation_observation.prepare(value, built, manifest, ipad_container, navigation_request) if navigation_request else None
    if scene:
        environment.update(scene["environment"])
    if navigation:
        environment.update(navigation["environment"])
    targets = ui_targets(spec)
    chosen = [t for t in targets if t.get("BlueprintName") == target_name or t.get("TestBundlePath", "").endswith(target_name + ".xctest")]
    release.require(len(chosen) == 1, "Не найден ровно один изолированный UI target.")
    if args.platform == "ipad":
        # The stand was installed and its identities verified by prepare/upgrade.
        # XCTest must drive that instance, not reinstall its dependent product
        # and invalidate the selected container before XCUIApplication.launch.
        use_installed_ui_application(chosen[0])
    chosen[0].setdefault("EnvironmentVariables", {}).update(environment)
    chosen[0].setdefault("UITargetAppEnvironmentVariables", {}).update({"NOTEBOOK_ACCEPTANCE_MANIFEST": environment["NOTEBOOK_ACCEPTANCE_MANIFEST"]})
    configured = products / ("acceptance-" + value["runID"] + "-" + attempt + ".xctestrun")
    configured.write_bytes(plistlib.dumps(spec)); configured.chmod(0o600)
    evidence.mkdir(mode=0o700)
    destination = "platform=macOS,arch=arm64" if args.platform == "mac" else "platform=iOS Simulator,id=" + built["simulator"]["udid"]
    command = ["xcrun", "xcodebuild", "-xctestrun", configured, "-destination", destination,
               "-resultBundlePath", evidence / "result.xcresult", "-parallel-testing-enabled", "NO",
               "-collect-test-diagnostics", "never",
               "-only-testing:" + target_name + "/" + args.test, "test-without-building"]
    started = time.time()
    scenario = {"sourceSHA256": built["sourceSHA256"], "sourceRevision": built["sourceRevision"],
                "testBuild": test_provenance,
                "driverSHA256": driver_sha, "simulatorDataContainer": str(ipad_container),
                "launchManifest": environment["NOTEBOOK_ACCEPTANCE_MANIFEST"],
                "runID": value["runID"], "platform": args.platform, "scenario": args.test, "startedAt": started,
                "timeoutSeconds": timeout,
                "requestedWorkloadSeconds": args.workload_seconds if workload else None, "systemTraceTemplate": args.trace,
                "systemTraceScope": ("system_wide_including_host_mac" if allow_host_processes
                    else "launched_private_app" if attached_trace else None),
                "systemTraceSessionID": trace_session,
                "interaction": {key: value for key, value in interaction.items() if key != "environment"} if interaction else None,
                "sceneObservation": {key: value for key, value in scene.items() if key != "environment"} if scene else None,
                "navigationObservation": {key: value for key, value in navigation.items() if key != "environment"} if navigation else None,
                "document": {key: document[key] for key in ("documentID", "title", "timeoutSeconds")} if document else None,
                "inputProfile": "Simulator direct contacts routed to the production Pencil owner" if args.pencil else "native touch",
                "simulator": built["simulator"]}
    installed_before = None
    recording = None
    trace = None
    trace_finished = False
    primary_error = None
    runner_exit = None

    def runner_did_exit(returncode):
        nonlocal runner_exit
        runner_exit = returncode
    try:
        installed_before = installed_ipad_state(built["simulator"]["udid"]) if args.platform == "ipad" else None
        if installed_before:
            write(evidence / "installed-application-before.json", installed_before)
            release.require(installed_before["bundleSHA256"] == release.app_manifest(Path(built["ipadApp"]))["sha256"],
                            "Установленный iPad bundle отличается от выбранной сборки; сценарий не начат.")
        recording = SimulatorRecording(built["simulator"]["udid"], evidence,
            None if attached_trace else args.trace, timeout,
            allow_host_processes=allow_host_processes) if args.platform == "ipad" else None
        if attached_trace:
            module = system_trace_module()
            bundle = Path(installed_before["bundlePath"])
            executable = bundle / info(bundle)["CFBundleExecutable"]
            trace = module.TraceHandshake(session_id=trace_session, control_directory=evidence / "trace-control",
                evidence_directory=evidence / "system-traces", simulator_udid=built["simulator"]["udid"],
                expected_bundle_id=IPAD_BUNDLE, expected_executable_uuid=module.macho_uuid(executable),
                segment_time_limit_seconds=timeout)
        if trace:
            trace.start()
        if recording:
            recording.start()
        run(command, output=evidence / "test.log", timeout=timeout, on_exit=runner_did_exit)
        if trace:
            write(evidence / "system-trace-segments.json", trace.finish())
            trace_finished = True
    except BaseException as error:
        primary_error = error
        raise
    finally:
        finalize_ui_attempt(evidence=evidence, scenario=scenario, primary_error=primary_error,
                            trace=trace, trace_finished=trace_finished, recording=recording,
                            installed_before=installed_before, simulator=built["simulator"]["udid"], interaction=interaction, scene=scene, navigation=navigation,
                            runner_exit=runner_exit, expected_test=target_name + "/" + args.test)
    print(str(evidence))


def lock_names(args):
    # Only mutable device/application owners are exclusive. Immutable builds
    # and distinct Mac/Simulator stands need no machine-wide Xcode queue.
    if args.command in ("build", "ui-build"):
        return ["build-" + MAC_BUNDLE]
    if args.command in ("prepare", "upgrade"):
        built = read(args.build / "build.json")
    else:
        value = read(args.run / "run.json")
        built = read(Path(value["build"]) / "build.json")
    simulator = "simulator-" + str(uuid.UUID(built["simulator"]["udid"]))
    mac = info(Path(built["macApp"]), True)["CFBundleIdentifier"]
    release.require(mac == MAC_BUNDLE, "Стенд другого checkout не может получить этот runner.")
    if args.command == "ui":
        return [mac if args.platform == "mac" else simulator]
    return sorted([mac, simulator])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    command = commands.add_parser("build"); command.add_argument("--evidence", type=Path, required=True); command.add_argument("--simulator", required=True)
    command.add_argument("--development", action="store_true", help="Неизменная копия для диагностики во время разработки; не окончательная приёмка")
    command = commands.add_parser("ui-build"); command.add_argument("--run", type=Path, required=True)
    command.add_argument("--evidence", type=Path, required=True)
    command = commands.add_parser("prepare"); command.add_argument("--build", type=Path, required=True); command.add_argument("--run-id")
    command = commands.add_parser("upgrade"); command.add_argument("--build", type=Path, required=True)
    command.add_argument("--from-run", type=Path, required=True); command.add_argument("--mac-pid", type=int, required=True)
    command = commands.add_parser("ui"); command.add_argument("--run", type=Path, required=True); command.add_argument("--platform", choices=["mac", "ipad"], required=True); command.add_argument("--test", required=True)
    command.add_argument("--test-build", type=Path, help="Отдельный diagnostic UI runner; не финальная приёмка единого среза")
    command.add_argument("--trace", choices=["Animation Hitches", "Time Profiler", "Metal System Trace", "Allocations"])
    command.add_argument("--allow-host-processes", action="store_true",
        help="Явное согласие на системную трассу всех процессов, включая Mac и другие приложения; Simulator не изолирует захват")
    command.add_argument("--pencil", action="store_true", help="Явно направить измеренные касания Simulator владельцу Pencil; не измеряет физический стилус")
    command.add_argument("--workload-seconds", type=int, default=1800,
                         help="Продолжительность testThirtyMinutesOfMixedInteraction; минимум 1800 секунд")
    command.add_argument("--interaction-session", help="UUID отдельного измерения настоящего control в Simulator")
    command.add_argument("--interaction-control-directory", type=Path, help="Новый абсолютный каталог внутри private run для оконного capture handshake")
    command.add_argument("--navigation-observation-session", help="UUID пассивного журнала стадий навигации private Simulator")
    command.add_argument("--scene-observation-session", help="UUID пассивного журнала nativeText/camera/installed ownership в private Simulator")
    command.add_argument("--document-id", help="UUID контрольного документа, созданного через публичный API")
    command.add_argument("--document-title", help="Точное сохранённое название контрольного документа для настоящего поиска")
    args = parser.parse_args()
    with ExitStack() as locks:
        for name in lock_names(args):
            lock = locks.enter_context((Path(tempfile.gettempdir()) / ("notebook-acceptance-" + name + ".lock")).open("w"))
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        {"build": build, "ui-build": ui_build, "prepare": prepare, "upgrade": upgrade, "ui": ui}[args.command](args)


if __name__ == "__main__":
    main()

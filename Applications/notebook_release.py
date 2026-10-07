"""Build input, signature and evidence contracts shared by Notebook release commands."""
import argparse
import contextlib
import ctypes
import datetime
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import socket
import subprocess
import sys
import stat
import tempfile
import time
import prepare_notebook_typesetter as notebook_typesetter
import prepare_notebook_typescript as notebook_typescript
import prepare_notebook_codex as notebook_codex

sys.dont_write_bytecode = True

BUNDLE = "com.amirtlinov.notebook.preview"
CANONICAL = "com.amirtlinov.notebook"
DISPLAY_NAME = "Notebook Lab"
CONFIGURATION = "Release"
SWIFT_OPTIMIZATION = "-O"
TEAM = "M94V58FCVP"
DEVICE = "9CF2C22D-1CC6-573F-B27D-7EB0C81D2DD9"
UDID = "00008103-001E059934D9001E"
PRODUCT_TYPE = "iPad13,4"
CANONICAL_MAC = Path("/Users/amir/Applications/Notebook.app")
APP_ID = TEAM + "." + BUNDLE
GENERATED = {"Applications/iPad/Info.plist", "Applications/Mac/Info.plist"}
MAC_BUNDLE = "com.amirtlinov.notebook.mac"
CLOUD_CONTAINER = "iCloud.com.amirtlinov.notebook"
# Permanent personal content uses Production on both platforms. Native
# acceptance builds have no container entitlement; there is no dev fallback.
CLOUD_ENVIRONMENT = "Production"


def cloud_entitlements(mac=False):
    return {"com.apple.developer.icloud-container-identifiers": [CLOUD_CONTAINER],
            "com.apple.developer.icloud-services": ["CloudKit"],
            "com.apple.developer.icloud-container-environment": CLOUD_ENVIRONMENT,
            "com.apple.developer.aps-environment" if mac else "aps-environment": "development"}


def validate_cloud_rights(entitlements, profile_rights, mac=False):
    for key, value in cloud_entitlements(mac).items():
        require(entitlements.get(key) == value, "Сборка не имеет точных CloudKit/Push прав Notebook: " + key)
        permitted = profile_rights.get(key)
        # Apple's automatic profiles authorize iCloud services with a scalar
        # wildcard. This is a profile allowlist (TN3125), never an app claim;
        # the signed service, container and environments remain pinned above.
        if key == "com.apple.developer.icloud-services" and permitted == "*":
            continue
        if isinstance(value, list):
            require(isinstance(permitted, list) and all(item in permitted for item in value),
                    "Provisioning не разрешает общий CloudKit-контейнер Notebook: " + key)
        else:
            require(permitted == value or isinstance(permitted, list) and value in permitted,
                    "Provisioning не разрешает выбранное CloudKit/Push окружение: " + key)



class ReleaseError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise ReleaseError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def write_json(path, value):
    data = (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode()
    descriptor, temporary = tempfile.mkstemp(prefix="." + path.name + "-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
        descriptor = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def below(path, root):
    return path == root or root in path.parents


def source_inputs(root):
    """Inventory actual inputs, including new files, independently of Git or cwd.

    This same inventory is used before/after verify, snapshot copying and signing.
    Only generated outputs and installed dependencies are excluded; lockfiles,
    release tools, MCP, test fixtures and the verification route are inputs.
    """
    root = Path(root)
    required = ("Package.swift", "verify.sh", "Applications/project.yml")
    require(all((root / path).is_file() for path in required),
            "Исходник должен содержать Package.swift, verify.sh и Applications/project.yml.")
    paths = [root / "Package.swift", root / "verify.sh"]
    if (root / "Package.resolved").exists():
        paths.append(root / "Package.resolved")
    for directory in ("Sources", "Tests", "Applications", "MCP"):
        require((root / directory).is_dir() and not (root / directory).is_symlink(),
                "Нет обычного каталога исходников: " + directory)
        for base, directories, files in os.walk(root / directory, followlinks=False):
            relative = Path(base).relative_to(root)
            directories[:] = sorted(name for name in directories
                if name not in (".git", ".build", "node_modules", "__pycache__", ".notebook-test")
                and not name.endswith(".xcresult")
                and (relative / name).as_posix() not in ("Applications/Notebook.xcodeproj", "MCP/.notebook/program-builds", "MCP/plugin/notebook/runtime")
                and not (relative.as_posix() == "MCP/plugin/notebook" and name.startswith(".runtime-stage-"))
                and not (relative.as_posix() == "Applications" and name.startswith("DerivedData")))
            for name in directories:
                require(not (Path(base) / name).is_symlink(), "Ссылка за пределы исходников не допускается.")
            for name in sorted(files):
                path = Path(base) / name
                if name == ".DS_Store" or (relative / name).as_posix() in GENERATED:
                    continue
                paths.append(path)
    result = []
    for path in sorted(paths):
        require(stat.S_ISREG(path.lstat().st_mode), "Нужен обычный файл исходника: " + str(path))
        result.append({"path": path.relative_to(root).as_posix(), "sha256": digest(path.read_bytes()),
                       "executable": bool(path.stat().st_mode & 0o111)})
    encoded = json.dumps(result, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
    return {"format": 2, "sha256": digest(encoded), "files": result}


def app_manifest(app):
    require(app.is_dir() and not app.is_symlink(), "Нужен обычный каталог подписанного bundle.")
    files = []
    for path in sorted(app.rglob("*")):
        require(not path.is_symlink(), "Ссылки не входят в подписанный bundle: " + str(path))
        require(not (path.is_dir() and path.suffix in (".app", ".appex")), "Вложенные приложения/расширения не входят в preview-контракт.")
        require(path.is_dir() or stat.S_ISREG(path.lstat().st_mode), "Специальный файл не входит в подписанный bundle.")
        if path.is_file():
            files.append({"path": path.relative_to(app).as_posix(), "sha256": digest(path.read_bytes()),
                          "bytes": path.stat().st_size, "executable": bool(path.stat().st_mode & 0o111)})
    return {"sha256": digest(json.dumps(files, sort_keys=True, separators=(",", ":")).encode()), "files": files}


def successful_json(path, command_type):
    require(path.is_file() and path.stat().st_size <= 8 * 1024 * 1024, "CLI не вернул ограниченную JSON-квитанцию.")
    value = json.loads(path.read_text())
    require(value.get("info", {}).get("outcome") == "success"
            and value["info"].get("commandType") == command_type, "CLI не подтвердил успешную команду " + command_type)
    require(isinstance(value.get("result"), dict), "В CLI-квитанции отсутствует result.")
    return value["result"]


def validate_device(result):
    props = result.get("properties", {})
    hardware, connection, state = (props.get(key, {}) for key in ("hardware", "connection", "state"))
    require(result.get("identifier") == DEVICE and hardware.get("udid") == UDID, "Подключён не согласованный iPad.")
    require(hardware.get("reality") == "physical" and hardware.get("platform") == "iOS"
            and hardware.get("deviceType") == "iPad" and hardware.get("productType") == PRODUCT_TYPE,
            "Нужен физический iPad13,4, не Simulator/Mac.")
    require(connection.get("state") == "connected" and connection.get("pairingState") == "paired"
            and state.get("bootState") == "booted" and "enabled" in state.get("developerModeStatus", {}),
            "iPad должен быть подключён, сопряжён, загружен и иметь Developer Mode.")
    os_version = props.get("software", {}).get("osVersionNumber", {}).get("stringValue")
    require(isinstance(os_version, str) and re.fullmatch(r"\d+(\.\d+)*", os_version), "Неизвестная версия iPadOS.")
    os_build = props.get("software", {}).get("osBuildVersions", {}).get("buildVersion", {}).get("name")
    require(isinstance(os_build, str) and os_build, "Неизвестный build iPadOS.")
    return {"identifier": DEVICE, "udid": UDID, "productType": PRODUCT_TYPE, "reality": "physical",
            "osVersion": os_version, "osBuild": os_build}


def app_rows(result, bundle):
    require(result.get("deviceIdentifier") == DEVICE and result.get("matchingBundleIdentifier") == bundle,
            "Список приложений относится к другому устройству или bundle.")
    rows = result.get("apps")
    require(isinstance(rows, list) and all(isinstance(row, dict) and row.get("bundleIdentifier") == bundle for row in rows),
            "Неоднозначный ответ списка приложений.")
    require(len(rows) <= 1, "Несколько установок с одним bundle ID требуют ручного разбора.")
    return rows


def validate_bundle_info(info, device):
    require(info.get("CFBundleIdentifier") == BUNDLE and info.get("CFBundleDisplayName") == DISPLAY_NAME,
            "Bundle обязан называться com.amirtlinov.notebook.preview / Notebook Lab.")
    require(info.get("CFBundlePackageType") == "APPL" and info.get("CFBundleSupportedPlatforms") == ["iPhoneOS"]
            and info.get("DTPlatformName") == "iphoneos" and str(info.get("DTSDKName", "")).startswith("iphoneos")
            and info.get("UIDeviceFamily") == [2], "Нужен bundle физического iPad, не Simulator/Mac/Catalyst.")
    require(info.get("NotebookCloudContainer") == CLOUD_CONTAINER, "Info.plist не называет согласованный CloudKit-контейнер.")
    executable = info.get("CFBundleExecutable")
    require(isinstance(executable, str) and executable and Path(executable).name == executable,
            "Некорректный адрес исполняемого файла.")
    for key in ("CFBundleShortVersionString", "CFBundleVersion", "MinimumOSVersion"):
        require(isinstance(info.get(key), str) and info[key], "В bundle отсутствует " + key)
    require(re.fullmatch(r"\d+(\.\d+)*", info["MinimumOSVersion"]), "Некорректная минимальная iPadOS.")
    version = lambda value: tuple(int(part) for part in value.split(".")) + (0,) * (5 - len(value.split(".")))
    require(version(info["MinimumOSVersion"]) <= version(device["osVersion"]), "iPadOS старше минимальной версии bundle.")
    return executable


def signature_identity(display, bundle):
    def field(name):
        matches = re.findall(r"^" + re.escape(name) + r"=(.*)$", display, re.MULTILINE)
        require(len(matches) == 1, "Подпись не имеет однозначного поля " + name)
        return matches[0]
    require(field("Identifier") == bundle and field("TeamIdentifier") == TEAM, "Подписан чужой bundle или team.")
    require("Authority=Apple Development:" in display and "Signature=adhoc" not in display, "Нужна настоящая Apple Development подпись.")
    require(re.fullmatch(r"[0-9a-fA-F]{40,64}", field("CDHash")), "В подписи отсутствует CDHash.")
    return {"identifier": bundle, "team": TEAM, "cdhash": field("CDHash")}


def development_signer(display, bundle):
    identity = signature_identity(display, bundle)
    authorities = re.findall(r"^Authority=(.+)$", display, re.MULTILINE)
    require(authorities and authorities[0].startswith("Apple Development: "),
            "Нужен Apple Development сертификат выбранного владельца.")
    return authorities[0], identity


def validate_signature(display, entitlements, profile):
    identity = signature_identity(display, BUNDLE)
    allowed = {"application-identifier", "com.apple.developer.team-identifier", "keychain-access-groups", "get-task-allow"} | set(cloud_entitlements())
    require(isinstance(entitlements, dict) and set(entitlements).issubset(allowed),
            "Неизвестные entitlements или контейнеры не входят в контракт Notebook.")
    require(entitlements.get("application-identifier") == APP_ID
            and entitlements.get("com.apple.developer.team-identifier") == TEAM
            and entitlements.get("keychain-access-groups") == [APP_ID]
            and entitlements.get("get-task-allow") is True, "Preview обязан иметь только собственную keychain-группу и development identity.")
    require(profile.get("TeamIdentifier") == [TEAM] and profile.get("ApplicationIdentifierPrefix") == [TEAM]
            and UDID in profile.get("ProvisionedDevices", []) and not profile.get("ProvisionsAllDevices", False),
            "Provisioning не относится к согласованному team и физическому iPad.")
    profile_entitlements = profile.get("Entitlements", {})
    require(profile_entitlements.get("application-identifier") == APP_ID
            and profile_entitlements.get("com.apple.developer.team-identifier") == TEAM
            and profile_entitlements.get("get-task-allow") is True, "Provisioning не разрешает этот development bundle.")
    validate_cloud_rights(entitlements, profile_entitlements)
    expiry = profile.get("ExpirationDate")
    require(isinstance(expiry, datetime.datetime) and expiry.replace(tzinfo=datetime.timezone.utc) > datetime.datetime.now(datetime.timezone.utc),
            "Provisioning истёк или не имеет даты окончания.")
    return {**identity, "profileUUID": profile.get("UUID"),
            "profileExpiration": expiry.isoformat(), "entitlements": entitlements}



def release_commands(evidence, runner=None):
    command_runner = runner or subprocess.run
    log = evidence / "commands.json"
    commands = json.loads(log.read_bytes()) if log.exists() else []
    require(isinstance(commands, list) and all(isinstance(entry, dict) for entry in commands),
            "Журнал команд повреждён.")
    def command(label, arguments, cwd=None, timeout=60, read_output=False, pipe_stdout=False, pass_fds=()):
        require(not any(entry.get("label") == label for entry in commands), "Команда с этой меткой уже записана: " + label)
        entry = {"label": label, "argv": [str(value) for value in arguments], "cwd": str(cwd) if cwd else None}
        if pipe_stdout:
            entry["stdoutMode"] = "pipe"
        commands.append(entry)
        write_json(evidence / "commands.json", commands)
        with (evidence / (label + ".stdout.log")).open("wb") as out, (evidence / (label + ".stderr.log")).open("wb") as err:
            result = command_runner(entry["argv"], cwd=cwd, stdout=subprocess.PIPE if pipe_stdout else out,
                                    stderr=err, timeout=timeout, **({"pass_fds": pass_fds} if pass_fds else {}))
            if pipe_stdout:
                require(isinstance(result.stdout, bytes) and len(result.stdout) <= 64 * 1024 * 1024,
                        "Машинный поток runner отсутствует или превысил бюджет.")
                out.write(result.stdout)
        entry["exitCode"] = result.returncode
        write_json(evidence / "commands.json", commands)
        require(result.returncode == 0, "Команда " + label + " завершилась ошибкой; см. каталог доказательств.")
        if read_output:
            files = [evidence / (label + suffix) for suffix in (".stdout.log", ".stderr.log")]
            require(all(path.stat().st_size <= 4 * 1024 * 1024 for path in files), "Диагностика подписи/бинарника превысила бюджет.")
            return tuple(path.read_bytes() for path in files)

    return command


def copy_source(source, snapshot, before):
    snapshot.mkdir()
    for item in before["files"]:
        origin, target = source / item["path"], snapshot / item["path"]
        target.parent.mkdir(parents=True, exist_ok=True)
        data = origin.read_bytes()
        require(digest(data) == item["sha256"], "Исходники изменились во время подготовки.")
        target.write_bytes(data)
        target.chmod(0o755 if item["executable"] else 0o644)
    require(source_inputs(source) == before and source_inputs(snapshot) == before, "Неполная или изменившаяся копия исходников.")


def build_ipad(snapshot, evidence, command, typesetter_runtime):
    entitlements_file = evidence / "preview.entitlements"
    entitlements_file.write_bytes(plistlib.dumps({"keychain-access-groups": [APP_ID], "get-task-allow": True, **cloud_entitlements()}))
    overrides = ["NOTEBOOK_TYPESETTER_RUNTIME=" + str(typesetter_runtime), "NOTEBOOK_CLOUD_CONTAINER=" + CLOUD_CONTAINER, "PRODUCT_BUNDLE_IDENTIFIER=" + BUNDLE, "NOTEBOOK_DISPLAY_NAME=" + DISPLAY_NAME,
                 "DEVELOPMENT_TEAM=" + TEAM, "CODE_SIGN_STYLE=Automatic", "CODE_SIGNING_ALLOWED=YES",
                 "CODE_SIGNING_REQUIRED=YES", "CODE_SIGN_IDENTITY=Apple Development",
                 "SWIFT_OPTIMIZATION_LEVEL=" + SWIFT_OPTIMIZATION, "CODE_SIGN_ENTITLEMENTS=" + str(entitlements_file)]
    build_command = ["/usr/bin/xcrun", "xcodebuild", "-project", str(snapshot / "Applications/Notebook.xcodeproj"),
                     "-scheme", "Notebook", "-configuration", CONFIGURATION, "-destination", "id=" + UDID, "-sdk", "iphoneos",
                     "-derivedDataPath", str(evidence / "derived-data"), "-allowProvisioningUpdates", *overrides, "build"]
    command("build", build_command, cwd=snapshot, timeout=1800)
    return evidence / ("derived-data/Build/Products/" + CONFIGURATION + "-iphoneos/Notebook.app")


def inspect_ipad(app, device, evidence, command):
    require(app.is_dir() and not app.is_symlink(), "Сборка не создала ожидаемый iphoneos bundle.")
    info = plistlib.loads((app / "Info.plist").read_bytes())
    executable = app / validate_bundle_info(info, device)
    require(executable.is_file() and not executable.is_symlink(), "Отсутствует обычный исполняемый файл iPad.")
    requirement = '=anchor apple generic and identifier "' + BUNDLE + '" and certificate leaf[subject.OU] = "' + TEAM + '"'
    command("signature-verify", ["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", "-R", requirement, app])
    display = command("signature-details", ["/usr/bin/codesign", "--display", "--verbose=4", app], read_output=True)
    entitlement_bytes = command("signature-entitlements", ["/usr/bin/codesign", "--display", "--entitlements", ":-", "--xml", app], read_output=True)[0]
    profile_bytes = command("provisioning-profile", ["/usr/bin/security", "cms", "-D", "-i", app / "embedded.mobileprovision"], read_output=True)[0]
    profile = plistlib.loads(profile_bytes)
    signature = validate_signature(b"\n".join(display).decode(), plistlib.loads(entitlement_bytes), profile)
    certificate_prefix = evidence / "signer-certificate-"
    command("signature-certificates", ["/usr/bin/codesign", "--display", "--extract-certificates=" + str(certificate_prefix), app])
    certificate = evidence / "signer-certificate-0"
    require(certificate.is_file() and certificate.stat().st_size <= 64 * 1024, "Не найден сертификат подписи bundle.")
    require(certificate.read_bytes() in profile.get("DeveloperCertificates", []), "Сертификат bundle не разрешён provisioning profile.")
    signature["certificateSHA256"] = digest(certificate.read_bytes())
    architecture = command("binary-architectures", ["/usr/bin/xcrun", "lipo", "-archs", executable], read_output=True)[0].decode().split()
    require(architecture and set(architecture).issubset({"arm64", "arm64e"}), "Бинарник не предназначен только для физического iPad.")
    build_info = command("binary-platform", ["/usr/bin/xcrun", "vtool", "-show-build", executable], read_output=True)[0].decode()
    platforms = re.findall(r"^\s*platform\s+(\S+)\s*$", build_info, re.MULTILINE)
    require(platforms and all(value.upper() == "IOS" for value in platforms), "Mach-O имеет платформу не iOS device.")
    uuids = command("binary-uuids", ["/usr/bin/xcrun", "dwarfdump", "--uuid", executable], read_output=True)[0].decode()
    require(re.search(r"UUID: [0-9A-Fa-f-]{36} \(arm64e?\)", uuids), "Бинарник не имеет UUID физического iPad.")
    signature["typesetter"] = inspect_typesetter_resources(app / "NotebookTypesetter")
    bundle = app_manifest(app)
    return info, signature, uuids, bundle


from notebook_check_registry import BASE_EVIDENCE


def read_json(path, limit=16 * 1024 * 1024):
    require(path.is_file() and not path.is_symlink() and path.stat().st_size <= limit,
            "Нет ограниченного обычного JSON-файла: " + str(path))
    value = json.loads(path.read_bytes())
    require(isinstance(value, dict), "Ожидался JSON-объект: " + str(path))
    return value


def file_digest(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            result.update(chunk)
    return result.hexdigest()


def verification_artifacts(evidence, *, full=True):
    """Hash the complete evidence, including xcresult payloads, not only counts."""
    require(evidence.is_dir() and not evidence.is_symlink(), "Нет каталога полного verify.sh.")
    require(not full or all((evidence / name).is_file() for name in BASE_EVIDENCE),
            "Полный verify.sh не оставил все обязательные свидетельства.")
    require(not full or all((evidence / (platform + ".xcresult")).is_dir() for platform in ("mac", "ipad")),
            "Нужны оба настоящих xcresult, не только сводки тестов.")
    files = []
    for path in sorted(evidence.rglob("*")):
        require(not path.is_symlink(), "Свидетельство не может ссылаться вне своего каталога.")
        require(path.is_dir() or stat.S_ISREG(path.lstat().st_mode), "Специальный файл не является свидетельством.")
        if path.is_file() and path != evidence / "verification.json":
            files.append({"path": path.relative_to(evidence).as_posix(), "bytes": path.stat().st_size,
                          "sha256": file_digest(path)})
    return files




def read_toolchain(command, prefix="toolchain-"):
    commands = {
        "python": [sys.executable, "--version"],
        "xcode": ["/usr/bin/xcrun", "xcodebuild", "-version"],
        "swift": ["/usr/bin/xcrun", "swift", "--version"],
        "iphoneosSDK": ["/usr/bin/xcrun", "--sdk", "iphoneos", "--show-sdk-build-version"],
        "macosSDK": ["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-build-version"],
    }
    for name in ("xcodegen", "node", "npm"):
        executable = shutil.which(name)
        require(executable is not None, "Не найден инструмент: " + name)
        commands[name] = [executable, "--version"]
    result = {}
    for name, argv in commands.items():
        output = command(prefix + name, argv, read_output=True)
        value = output[0].decode().strip()
        require(value, "Инструмент не назвал свою версию: " + name)
        result[name] = value
    return result


def finish_verification(source, evidence):
    from notebook_verification import validate_selected, prerequisites, prepared_codex
    require(not (evidence / "verification.json").exists(), "Этот проход уже завершён.")
    before = read_json(evidence / "source-before.json")
    after = source_inputs(source)
    write_json(evidence / "source-after.json", after)
    require(before == after, "Исходники изменились во время проверки.")
    require(read_json(evidence / "toolchain.json") == read_json(evidence / "toolchain-after.json"),
            "Инструменты изменились во время проверки.")
    plan = read_json(evidence / "selection.json")
    receipt = {"format": 2, "route": "./verify.sh" if plan.get("selectionMode") == "full-registry" else "./verify.sh:selected",
               "scope": "registry-contracts", "physicalAcceptance": False, "status": "passed",
               "source": before, "artifacts": verification_artifacts(evidence, full=False)}
    if "codex" in prerequisites(plan):
        receipt["codexRuntime"] = prepared_codex(evidence, Path(plan["sourceRoot"]))["identity"]
    validate_selected(source, evidence, receipt)
    write_json(evidence / "verification.json", receipt)
    return receipt


def checked_verification(source, evidence):
    from notebook_verification import validate_selected
    return validate_selected(source, evidence, read_json(evidence / "verification.json"))


def inspect_typesetter_resources(resources):
    try:
        return notebook_typesetter.check_bundle(resources)
    except (OSError, ValueError, KeyError, RuntimeError) as error:
        raise ReleaseError("Typesetter resource contract failed: " + str(error)) from error


def prepare_typesetter_runtime(source, command, platform, stage=None):
    stage = Path(stage or os.environ.get("NOTEBOOK_TYPESETTER_RUNTIME", Path(source) / ".build/notebook-typesetter-runtime")).resolve()
    command("typesetter-resources-"+platform, [sys.executable, "-B", Path(source) / "Applications/prepare_notebook_typesetter.py",
        "--prepare", "--platform", platform, "--stage", stage], cwd=source, timeout=1800)
    return stage


def validate_codex_report(report, source, stage_root=None):
    try:
        return notebook_codex.validate_report(report,
            lock_path=Path(source) / "Applications/NotebookCodexRuntime.lock.json", stage_root=stage_root)
    except (OSError, ValueError, KeyError, TypeError, RuntimeError) as error:
        raise ReleaseError("Codex runtime contract failed: " + str(error)) from error


def prepare_codex_runtime(source, command, stage_root=None):
    root = Path(stage_root or Path(source) / ".build/notebook-codex-runtimes").resolve()
    output = command("codex-resources", [sys.executable, "-B", Path(source) / "Applications/prepare_notebook_codex.py",
        "--prepare", "--stage-root", root], cwd=source, timeout=1800, read_output=True)[0]
    report = json.loads(output)
    validate_codex_report(report, source, root)
    return Path(report["stage"])


def prepare_surface_stage(source, command):
    stage = Path(source).resolve() / ".build/surface"
    command("surface-resources", ["node", Path(source) / "MCP/build-surface.mjs", "--stage", stage],
            cwd=source, timeout=600)
    return stage


def prepare_typescript_runtime(source, command, stage_root=None):
    output = command("typescript-resources", [sys.executable, "-B", Path(source) / "Applications/prepare_notebook_typescript.py",
        "--prepare", "--stage-root", Path(stage_root or Path(source) / ".build/notebook-typescript-runtime").resolve()],
        cwd=source, timeout=120, read_output=True)[0]
    value = json.loads(output)
    require(value.get("status") == "ready" and Path(value.get("stage", "")).is_absolute(), "TypeScript resources are not ready.")
    return Path(value["stage"])


def restrict_test_script_services(app, source, command, *, bundle_identifier, signing_identity="-"):
    """Remove Xcode's test-only sandbox grants before executing real workers.

    Xcode injects a read-all-files exception for its test action separately
    from CODE_SIGN_INJECT_BASE_ENTITLEMENTS. Signing these build products with
    the source entitlements restores the same boundary as an ordinary build.
    The enclosing test host retains its own XCTest instrumentation rights.
    """
    app, source = Path(app).resolve(), Path(source).resolve()
    require(not below(app, CANONICAL_MAC.resolve()), "Нельзя переподписывать установленный рабочий Mac.")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    require(info.get("CFBundleIdentifier") == bundle_identifier,
            "Ожидался созданный этим маршрутом тестовый Mac bundle.")
    root = app / "Contents/XPCServices"
    require(root.is_dir() and {path.name for path in root.iterdir()}
            == {"NotebookScriptService.xpc", "NotebookMarkupService.xpc"},
            "Тестовый Mac должен содержать ровно два исполнителя.")
    targets = [(root / "NotebookMarkupService.xpc/Contents" / notebook_typescript.BINARY,
                source / "Sources/NotebookMarkupService/typescript-child.entitlements.plist", "com.amirtlinov.notebook.typescript-compiler")]
    targets += [(root / (name + ".xpc"), source / "Sources" / name / "entitlements.plist", info.get(name))
                for name in ("NotebookScriptService", "NotebookMarkupService")]
    for index, (target, entitlement_file, identifier) in enumerate(targets):
        require(target.exists() and not target.is_symlink() and isinstance(identifier, str),
                "Нельзя подписать отсутствующего или неидентифицированного исполнителя.")
        command("test-worker-sign-" + str(index), ["/usr/bin/codesign", "--force", "--sign", signing_identity, "--timestamp=none",
            "--identifier", identifier, "--entitlements", entitlement_file, target])
        rights = command("test-worker-rights-" + str(index), ["/usr/bin/codesign", "--display", "--entitlements", ":-", "--xml", target], read_output=True)[0]
        require(plistlib.loads(rights) == plistlib.loads(entitlement_file.read_bytes()),
                "Xcode добавил исполнителю права, отсутствующие в исходном контракте.")
    command("test-host-reseal", ["/usr/bin/codesign", "--force", "--sign", signing_identity, "--timestamp=none",
        "--preserve-metadata=identifier,entitlements,flags,runtime", app])
    command("test-host-seal-verify", ["/usr/bin/codesign", "--verify", "--deep", "--strict", app])


def build_mac(snapshot, evidence, command, typesetter_runtime, codex_stage_root, surface_stage):
    typescript_runtime = prepare_typescript_runtime(snapshot, command)
    codex_runtime = prepare_codex_runtime(snapshot, command, stage_root=codex_stage_root)
    entitlements = evidence / "mac.entitlements"
    entitlements.write_bytes(plistlib.dumps({"com.apple.security.get-task-allow": True, **cloud_entitlements(mac=True)}))
    command("build-mac", ["/usr/bin/xcrun", "xcodebuild", "-project",
        snapshot / "Applications/Notebook.xcodeproj", "-scheme", "NotebookRuntime",
        "-configuration", CONFIGURATION, "-destination", "generic/platform=macOS",
        "-derivedDataPath", evidence / "derived-mac", "-allowProvisioningUpdates",
        "DEVELOPMENT_TEAM=" + TEAM,
        "CODE_SIGN_STYLE=Automatic", "CODE_SIGNING_ALLOWED=YES", "CODE_SIGNING_REQUIRED=YES",
        "CODE_SIGN_IDENTITY=Apple Development", "NOTEBOOK_CLOUD_CONTAINER=" + CLOUD_CONTAINER, "NOTEBOOK_MAC_ENTITLEMENTS=" + str(entitlements),
        "NOTEBOOK_TYPESETTER_RUNTIME=" + str(typesetter_runtime),
        "NOTEBOOK_CODEX_RUNTIME=" + str(codex_runtime),
        "NOTEBOOK_SURFACE_STAGE=" + str(surface_stage),
        "NOTEBOOK_TYPESCRIPT_RUNTIME=" + str(typescript_runtime),
        "SWIFT_OPTIMIZATION_LEVEL=" + SWIFT_OPTIMIZATION, "ARCHS=arm64", "build"],
        cwd=snapshot, timeout=1800)
    return evidence / ("derived-mac/Build/Products/" + CONFIGURATION + "/NotebookRuntime.app")


def inspect_mac(app, command, source):
    bundle = app_manifest(app)
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    require(info.get("CFBundleIdentifier") == MAC_BUNDLE and info.get("LSUIElement") is True
            and info.get("NotebookPluginRuntime") is True
            and info.get("LSBackgroundOnly", False) is False
            and info.get("NotebookCloudContainer") == CLOUD_CONTAINER
            and info.get("CFBundlePackageType") == "APPL" and info.get("DTPlatformName") == "macosx",
            "Нужен подписанный runtime плагина Notebook без самостоятельного интерфейса.")
    require(all(isinstance(info.get(key), str) and info[key]
                for key in ("CFBundleShortVersionString", "CFBundleVersion", "LSMinimumSystemVersion")),
            "Mac bundle не назвал версию или минимальную систему.")
    name = info.get("CFBundleExecutable")
    require(isinstance(name, str) and name and Path(name).name == name, "Некорректный executable Mac.")
    executable = app / "Contents/MacOS" / name
    require(executable.is_file(), "Нет исполняемого файла Mac.")
    sidecar = app / "Contents/Resources/NotebookTools"
    require((sidecar / "dist/index.mjs").is_file() and (sidecar / "package.json").is_file(),
            "В подписанном helper отсутствует установленный MCP.")
    requirement = '=anchor apple generic and identifier "' + MAC_BUNDLE + '" and certificate leaf[subject.OU] = "' + TEAM + '"'
    command("mac-signature-verify", ["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", "-R", requirement, app])
    display = command("mac-signature-details", ["/usr/bin/codesign", "--display", "--verbose=4", app], read_output=True)
    signature = signature_identity(b"\n".join(display).decode(), MAC_BUNDLE)
    output = command("mac-signature-entitlements", ["/usr/bin/codesign", "--display", "--entitlements", ":-", "--xml", app], read_output=True)
    entitlements = plistlib.loads(output[0])
    allowed = {"com.apple.security.get-task-allow": True, "com.apple.application-identifier": TEAM + "." + MAC_BUNDLE,
               "com.apple.developer.team-identifier": TEAM, "keychain-access-groups": [TEAM + "." + MAC_BUNDLE], **cloud_entitlements(mac=True)}
    require(isinstance(entitlements, dict) and entitlements.get("com.apple.security.get-task-allow") is True
            and entitlements.get("com.apple.application-identifier") == TEAM + "." + MAC_BUNDLE
            and entitlements.get("com.apple.developer.team-identifier") == TEAM
            and all(key in allowed and value == allowed[key] for key, value in entitlements.items()),
            "Mac получил неизвестные права или чужую идентичность Keychain.")
    profile_path = app / "Contents/embedded.provisionprofile"
    require(profile_path.is_file() and not profile_path.is_symlink(), "CloudKit helper требует embedded provisioning profile.")
    profile = plistlib.loads(command("mac-provisioning-profile", ["/usr/bin/security", "cms", "-D", "-i", profile_path], read_output=True)[0])
    profile_rights = profile.get("Entitlements", {})
    require(profile.get("TeamIdentifier") == [TEAM] and profile.get("ApplicationIdentifierPrefix") == [TEAM]
            and "OSX" in profile.get("Platform", [])
            and profile_rights.get("com.apple.application-identifier") == TEAM + "." + MAC_BUNDLE
            and profile_rights.get("com.apple.developer.team-identifier") == TEAM,
            "Mac provisioning не разрешает идентичность и development-подпись helper.")
    # Modern macOS registers the Provisioning UDID, not Hardware UUID.
    # get-task-allow is unrestricted on macOS; verify it on the code signature
    # above, not as a required profile claim (Apple TN3125).
    hardware = json.loads(command("mac-provisioning-device", ["/usr/sbin/system_profiler", "-json", "SPHardwareDataType"], read_output=True)[0])
    devices = hardware.get("SPHardwareDataType", [])
    device = devices[0].get("provisioning_UDID") if len(devices) == 1 else None
    require(isinstance(device, str) and device and device in profile.get("ProvisionedDevices", []) and not profile.get("ProvisionsAllDevices", False),
            "Mac provisioning не разрешает этот компьютер.")
    expiry = profile.get("ExpirationDate")
    require(isinstance(expiry, datetime.datetime) and expiry.replace(tzinfo=datetime.timezone.utc) > datetime.datetime.now(datetime.timezone.utc),
            "Mac provisioning истёк.")
    validate_cloud_rights(entitlements, profile_rights, mac=True)
    with tempfile.TemporaryDirectory(prefix="notebook-mac-signer-") as temporary:
        prefix = Path(temporary) / "certificate-"
        command("mac-signature-certificates", ["/usr/bin/codesign", "--display", "--extract-certificates=" + str(prefix), app])
        certificate = Path(str(prefix) + "0")
        require(certificate.is_file() and certificate.stat().st_size <= 64 * 1024
                and certificate.read_bytes() in profile.get("DeveloperCertificates", []),
                "Сертификат Mac не разрешён provisioning profile.")
        signature["certificateSHA256"] = digest(certificate.read_bytes())
    signature["profileUUID"] = profile.get("UUID")
    signature["entitlements"] = entitlements
    signature["services"] = inspect_script_services(app, info, command)
    signature["typesetter"] = inspect_typesetter_resources(app / "Contents/Resources/NotebookTypesetter")
    codex_stage = app / "Contents/Resources/CodexRuntime"
    report = json.loads(command("codex-runtime-check", [sys.executable, "-B",
        Path(source) / "Applications/prepare_notebook_codex.py", "--check", "--stage", codex_stage],
        cwd=source, timeout=120, read_output=True)[0])
    signature["codexRuntime"] = validate_codex_report(report, source)
    require(report["stage"] == str(codex_stage.resolve()), "Codex receipt names another bundle.")
    architectures = command("mac-binary-architectures", ["/usr/bin/xcrun", "lipo", "-archs", executable], read_output=True)[0].decode().split()
    require(architectures == ["arm64"], "Нужен arm64 helper согласованного Mac.")
    output = command("mac-binary-platform", ["/usr/bin/xcrun", "vtool", "-show-build", executable], read_output=True)[0].decode()
    platforms = re.findall(r"^\s*platform\s+(\S+)\s*$", output, re.MULTILINE)
    require(platforms and all(value.upper() == "MACOS" for value in platforms), "Mach-O helper не относится к macOS.")
    uuids = command("mac-binary-uuids", ["/usr/bin/xcrun", "dwarfdump", "--uuid", executable], read_output=True)[0].decode()
    require(re.search(r"UUID: [0-9A-Fa-f-]{36} \(arm64\)", uuids), "Mac binary не имеет UUID arm64.")
    require(app_manifest(app) == bundle, "Mac bundle изменился во время проверки подписи.")
    return info, signature, uuids, bundle


def inspect_script_services(app, app_info, command):
    """Require the two separately signed capability-free interpreters in the bundle."""
    root = app / "Contents/XPCServices"
    expected = {
        "NotebookScriptService": ("NotebookScriptService", "com.amirtlinov.notebook.script-service", "notebook-sdk.js"),
        "NotebookMarkupService": ("NotebookMarkupService", "com.amirtlinov.notebook.markup-service", "notebook-markup.js"),
    }
    require(root.is_dir() and {p.name for p in root.iterdir()} == {name + ".xpc" for name in expected},
            "Mac обязан содержать ровно два изолированных XPC исполнителя.")
    result = {}
    for name, (info_key, bundle_id, resource) in expected.items():
        service = root / (name + ".xpc")
        info = plistlib.loads((service / "Contents/Info.plist").read_bytes())
        require(app_info.get(info_key) == bundle_id and info.get("CFBundleIdentifier") == bundle_id
                and info.get("CFBundlePackageType") == "XPC!"
                and info.get("XPCService", {}).get("ServiceType") == "Application", "Изменилась идентичность XPC исполнителя.")
        executable_name = info.get("CFBundleExecutable")
        require(isinstance(executable_name, str) and executable_name and Path(executable_name).name == executable_name,
                "Некорректный executable XPC.")
        executable = service / "Contents/MacOS" / executable_name
        require(executable.is_file() and (service / "Contents/Resources" / resource).is_file(),
                "В XPC отсутствует исполнитель или закреплённый SDK.")
        label = "xpc-" + name
        requirement = '=anchor apple generic and identifier "' + bundle_id + '" and certificate leaf[subject.OU] = "' + TEAM + '"'
        command(label + "-verify", ["/usr/bin/codesign", "--verify", "--strict", "-R", requirement, service])
        display = command(label + "-details", ["/usr/bin/codesign", "--display", "--verbose=4", service], read_output=True)
        identity = signature_identity(b"\n".join(display).decode(), bundle_id)
        rights = plistlib.loads(command(label + "-entitlements", ["/usr/bin/codesign", "--display", "--entitlements", ":-", "--xml", service], read_output=True)[0])
        allowed = {"com.apple.security.app-sandbox": True, "com.apple.security.get-task-allow": True,
                   "com.apple.application-identifier": TEAM + "." + bundle_id, "com.apple.developer.team-identifier": TEAM}
        require(isinstance(rights, dict) and rights.get("com.apple.security.app-sandbox") is True
                and all(key in allowed and value == allowed[key] for key, value in rights.items()),
                "XPC получил доступ к файлам, сети или чужим возможностям.")
        architecture = command(label + "-architecture", ["/usr/bin/xcrun", "lipo", "-archs", executable], read_output=True)[0].decode().split()
        require(architecture == ["arm64"], "XPC обязан использовать arm64.")
        identity["entitlements"] = rights
        if name == "NotebookMarkupService":
            identity["typescript"] = inspect_typescript_runtime(service, command)
        result[name] = identity
    return result


def inspect_typescript_runtime(service, command):
    try:
        manifest = notebook_typescript.check(service / "Contents", signed=True)
    except (RuntimeError, OSError, ValueError, KeyError) as error:
        raise ReleaseError("TypeScript compiler resource/source contract failed: " + str(error)) from error
    executable = service / "Contents" / notebook_typescript.BINARY
    bundle_id = "com.amirtlinov.notebook.typescript-compiler"
    requirement = '=anchor apple generic and identifier "' + bundle_id + '" and certificate leaf[subject.OU] = "' + TEAM + '"'
    command("typescript-signature-verify", ["/usr/bin/codesign", "--verify", "--strict", "-R", requirement, executable])
    display = command("typescript-signature-details", ["/usr/bin/codesign", "--display", "--verbose=4", executable], read_output=True)
    identity = signature_identity(b"\n".join(display).decode(), bundle_id)
    rights = plistlib.loads(command("typescript-rights", ["/usr/bin/codesign", "--display", "--entitlements", ":-", "--xml", executable], read_output=True)[0])
    require(rights == {"com.apple.security.app-sandbox": True, "com.apple.security.inherit": True},
            "TypeScript child must inherit only the compiler sandbox.")
    return {**manifest, "signature": identity, "entitlements": rights}


def build_verified_pair(source, verification, evidence, runner=None):
    """Build only. This command has no archive, launch, install or deletion verb."""
    source, verification = source.resolve(), verification.resolve()
    raw_evidence = evidence.absolute()
    evidence = raw_evidence.resolve()
    require(not raw_evidence.is_symlink() and not evidence.exists(), "Нужен новый каталог сборки, не повтор прежней попытки.")
    require(not below(evidence, CANONICAL_MAC.resolve()) and not below(source, CANONICAL_MAC.resolve()),
            "Установленный Mac не является назначением сборки.")
    require(evidence != source and not below(evidence, verification) and not below(verification, evidence)
            and (not below(evidence, source) or evidence.relative_to(source).parts[0] == ".build"),
            "Сборка должна быть вне исходников и свидетельств verify.sh.")
    driver = source / "Applications/notebook_release.py"
    require(driver.is_file() and not driver.is_symlink() and file_digest(driver) == file_digest(Path(__file__)),
            "Сборщик должен принадлежать тому же проверяемому набору исходников.")
    proof = checked_verification(source, verification)
    before = proof["source"]
    evidence.mkdir(parents=True, mode=0o700)
    command = release_commands(evidence, runner)
    receipt = {"format": 1, "status": "building", "installationAttempted": False,
               "verificationRoute": proof["route"],
               "verificationSHA256": file_digest(verification / "verification.json"), "sourceSHA256": before["sha256"]}
    write_json(evidence / "build.json", receipt)
    try:
        toolchain = read_toolchain(command)
        verified_tools = read_json(verification / "toolchain.json")
        require(all(toolchain.get(name) == value for name, value in verified_tools.items()),
                "Инструменты сборки отличаются от verify.sh.")
        write_json(evidence / "toolchain.json", toolchain)
        snapshot = evidence / "source"
        copy_source(source, snapshot, before)
        write_json(evidence / "source-before.json", before)
        device_json = evidence / "device.json"
        command("device", ["/usr/bin/xcrun", "devicectl", "device", "info", "details", "--device", DEVICE,
            "--timeout", "30", "--json-output", device_json, "--omit-deprecated-fields-in-json"])
        device = validate_device(successful_json(device_json, "devicectl.device.info.details"))
        command("dependencies", [shutil.which("npm"), "ci", "--ignore-scripts"], cwd=snapshot / "MCP", timeout=600)
        command("generate-project", [shutil.which("xcodegen"), "generate", "--spec", "project.yml"], cwd=snapshot / "Applications")
        runtime_stage = os.environ.get("NOTEBOOK_TYPESETTER_RUNTIME") or source / ".build/notebook-typesetter-runtime"
        runtime = prepare_typesetter_runtime(snapshot, command, "iphoneos", stage=runtime_stage)
        prepare_typesetter_runtime(snapshot, command, "macosx", stage=runtime)
        ipad = build_ipad(snapshot, evidence, command, runtime)
        ipad_info, ipad_signature, ipad_uuids, ipad_manifest = inspect_ipad(ipad, device, evidence, command)
        surface_stage = prepare_surface_stage(source, command)
        mac = build_mac(snapshot, evidence, command, runtime, source / ".build/notebook-codex-runtimes", surface_stage)
        mac_info, mac_signature, mac_uuids, mac_manifest = inspect_mac(mac, command, snapshot)
        require("codexRuntime" not in proof or proof["codexRuntime"] == mac_signature["codexRuntime"],
                "Codex runtime differs from the verified prerequisite.")
        plugin = evidence / "plugin"
        shutil.copytree(snapshot / "MCP/plugin", plugin)
        command("package-plugin", [shutil.which("node"), snapshot / "MCP/package-plugin-runtime.mjs",
            mac, plugin / "notebook"], cwd=snapshot, timeout=600)
        mac = plugin / "notebook/runtime/NotebookRuntime.app"
        require(all(ipad_info[key] == mac_info[key] for key in ("CFBundleVersion", "CFBundleShortVersionString")),
                "Пара собрана с разными версиями приложений.")
        require(source_inputs(source) == before == source_inputs(snapshot), "Исходники изменились при сборке пары.")
        require(checked_verification(source, verification) == proof, "Полная проверка изменилась при сборке.")
        require(app_manifest(ipad) == ipad_manifest and app_manifest(mac) == mac_manifest,
                "Подписанная пара изменилась после проверки.")
        require(read_toolchain(command, prefix="toolchain-after-") == toolchain,
                "Инструменты изменились во время сборки пары.")
        write_json(evidence / "source-after.json", source_inputs(snapshot))
        apps = {}
        for role, app, signature, uuids, manifest in (("iPad", ipad, ipad_signature, ipad_uuids, ipad_manifest),
                                                     ("mac", mac, mac_signature, mac_uuids, mac_manifest)):
            write_json(evidence / (role + "-manifest.json"), manifest)
            apps[role] = {"path": app.relative_to(evidence).as_posix(), "manifestSHA256": manifest["sha256"],
                          "signature": signature, "binaryUUIDs": uuids.strip()}
        receipt.update({"status": "verified-build", "device": device, "apps": apps,
                        "codexRuntime": mac_signature["codexRuntime"],
                        "plugin": {"path": plugin.relative_to(evidence).as_posix(),
                                   "version": json.loads((plugin / "notebook/plugin.json").read_text())["version"]},
                        "version": ipad_info["CFBundleShortVersionString"], "build": ipad_info["CFBundleVersion"]})
        write_json(evidence / "build.json", receipt)
        return receipt
    except Exception as error:
        receipt.update({"status": "refused", "error": str(error)})
        write_json(evidence / "build.json", receipt)
        raise


def plugin_metadata(root):
    """The authored plugin payload, without the separately sealed runtime."""
    files = []
    for base, directories, names in os.walk(root, followlinks=False):
        relative = Path(base).relative_to(root)
        if relative.as_posix() == "notebook":
            directories[:] = [name for name in directories if name != "runtime" and not name.startswith(".runtime-stage-")]
        for name in directories:
            require(not (Path(base) / name).is_symlink(), "Plugin metadata содержит ссылку.")
        for name in names:
            path = Path(base) / name
            require(stat.S_ISREG(path.lstat().st_mode), "Plugin metadata содержит специальный файл или ссылку.")
            files.append({"path": path.relative_to(root).as_posix(), "sha256": file_digest(path),
                          "executable": bool(path.stat().st_mode & 0o111)})
    return sorted(files, key=lambda item: item["path"])


@contextlib.contextmanager
def plugin_publication_lease(root):
    """The release owner and its inherited child FD share one OS-released lease."""
    require(root.is_absolute() and root == root.resolve(), "Нужен прямой адрес каталога публикации.")
    root.mkdir(parents=True, mode=0o700, exist_ok=True)
    info = root.lstat()
    require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.geteuid(), "Каталог публикации должен принадлежать пользователю.")
    path = root / ".publication.owner"
    descriptor = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
        info, current = os.fstat(descriptor), path.lstat()
        require(stat.S_ISREG(info.st_mode) and info.st_uid == os.geteuid() and stat.S_IMODE(info.st_mode) == 0o600
                and info.st_nlink == 1 and (info.st_dev, info.st_ino) == (current.st_dev, current.st_ino),
                "Файл владельца публикации должен принадлежать пользователю с правами 0600.")
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise ReleaseError("Другая публикация Notebook ещё выполняется.") from error
        yield descriptor
    finally:
        os.close(descriptor)


def installed_runtime_identities(command, apps):
    """Admit only the installed bundle paths already resolved by pair preflight."""
    result = {}
    for app in sorted(set(path.resolve() for path in apps)):
        info_path = app / "Contents/Info.plist"
        if not info_path.exists():
            continue
        info = plistlib.loads(info_path.read_bytes())
        if info.get("CFBundleExecutable") != "NotebookRuntime":
            continue
        require(info.get("CFBundleIdentifier") == MAC_BUNDLE and info.get("NotebookPluginRuntime") is True
                and info.get("LSUIElement") is True, "Установленный runtime не имеет идентичности Notebook plugin.")
        label = "installed-runtime-" + str(len(result))
        requirement = '=anchor apple generic and identifier "' + MAC_BUNDLE + '" and certificate leaf[subject.OU] = "' + TEAM + '"'
        command(label + "-verify", ["/usr/bin/codesign", "--verify", "--deep", "--strict", "-R", requirement, app])
        display = command(label + "-identity", ["/usr/bin/codesign", "--display", "--verbose=4", app], read_output=True)
        identity = signature_identity(b"\n".join(display).decode(), MAC_BUNDLE)
        result[str(app / "Contents/MacOS/NotebookRuntime")] = identity["cdhash"]
    return result


class RuntimeAuditToken(ctypes.Structure):
    _fields_ = [("val", ctypes.c_uint32 * 8)]


def runtime_peer(endpoint):
    """The socket supplies the kernel's process identity, including PID version."""
    with socket.socket(socket.AF_UNIX) as probe:
        probe.settimeout(0.5)
        try:
            probe.connect(str(endpoint))
        except OSError as error:
            require(error.errno in (errno.ENOENT, errno.ECONNREFUSED), "Не удалось проверить владельца Notebook IPC.")
            return None
        # sys/un.h: SOL_LOCAL / LOCAL_PEERTOKEN. No domain request or store read.
        token = probe.getsockopt(0, 0x006, ctypes.sizeof(RuntimeAuditToken))
        require(len(token) == ctypes.sizeof(RuntimeAuditToken), "IPC не подтвердил audit identity владельца.")
        return token


def runtime_process_identity(raw_token):
    """Read the running path and CDHash against the same PID-version token."""
    token = RuntimeAuditToken.from_buffer_copy(raw_token)
    bsm = ctypes.CDLL("/usr/lib/libbsm.dylib")
    for name in ("audit_token_to_pid", "audit_token_to_euid"):
        function = getattr(bsm, name)
        function.argtypes = [RuntimeAuditToken]
        function.restype = ctypes.c_uint32
    pid, uid = bsm.audit_token_to_pid(token), bsm.audit_token_to_euid(token)
    require(pid > 0 and uid == os.geteuid(), "IPC принадлежит неизвестному владельцу или другому пользователю.")
    proc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    proc.proc_pidpath_audittoken.argtypes = [ctypes.POINTER(RuntimeAuditToken), ctypes.c_void_p, ctypes.c_uint32]
    proc.proc_pidpath_audittoken.restype = ctypes.c_int
    path = ctypes.create_string_buffer(4096)
    if proc.proc_pidpath_audittoken(ctypes.byref(token), path, len(path)) <= 0:
        if ctypes.get_errno() == errno.ESRCH:
            return None
        raise ReleaseError("Не удалось проверить путь действующего Notebook IPC peer.")
    system = ctypes.CDLL(None, use_errno=True)
    system.csops_audittoken.argtypes = [ctypes.c_int, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_size_t,
                                      ctypes.POINTER(RuntimeAuditToken)]
    system.csops_audittoken.restype = ctypes.c_int
    cdhash = ctypes.create_string_buffer(20)
    if system.csops_audittoken(pid, 5, cdhash, len(cdhash), ctypes.byref(token)) != 0:  # CS_OPS_CDHASH
        if ctypes.get_errno() == errno.ESRCH:
            return None
        raise ReleaseError("Не удалось проверить подпись действующего Notebook IPC peer.")
    return {"pid": pid, "uid": uid, "executable": os.fsdecode(path.value), "cdhash": cdhash.raw.hex()}


def request_runtime_termination(raw_token, approved):
    identity = runtime_process_identity(raw_token)
    if identity is None:
        return None
    require(approved.get(identity["executable"]) == identity["cdhash"],
            "Неизвестный владелец Notebook IPC: путь или подпись не совпали с установленным runtime.")
    token = RuntimeAuditToken.from_buffer_copy(raw_token)
    proc = ctypes.CDLL("/usr/lib/libproc.dylib")
    proc.proc_signal_with_audittoken.argtypes = [ctypes.POINTER(RuntimeAuditToken), ctypes.c_int]
    proc.proc_signal_with_audittoken.restype = ctypes.c_int
    # libproc returns errno directly. The kernel compares PID version when
    # signalling, so an exited peer's reused PID cannot receive this request.
    status = proc.proc_signal_with_audittoken(ctypes.byref(token), signal.SIGTERM)
    require(status in (0, errno.ESRCH), "Не удалось запросить штатное завершение Notebook runtime.")
    return identity if status == 0 else None


@contextlib.contextmanager
def stopped_runtime(command, approved=None, root=None, *, wait_seconds=30):
    """Gracefully retire an admitted owner and hold its existing writer lease."""
    approved = approved or {}
    root = root or Path("/tmp") / ("notebook-" + str(os.geteuid()))
    root.mkdir(mode=0o700, exist_ok=True)
    info = root.lstat()
    require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.geteuid() and stat.S_IMODE(info.st_mode) == 0o700,
            "Каталог runtime должен принадлежать пользователю с правами 0700.")
    endpoint = root / "bridge.sock"
    lease = endpoint.with_suffix(".sock.owner")
    descriptor = os.open(lease, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
        info, current = os.fstat(descriptor), lease.lstat()
        require(stat.S_ISREG(info.st_mode) and info.st_uid == os.geteuid() and stat.S_IMODE(info.st_mode) == 0o600
                and info.st_nlink == 1 and (info.st_dev, info.st_ino) == (current.st_dev, current.st_ino),
                "Файл владельца runtime должен принадлежать пользователю с правами 0600.")
        processes = command("owners-before-install", ["/bin/ps", "-axo", "pid=,comm="], read_output=True)[0].decode()
        legacy = {str(path / "Contents/MacOS/Notebook") for path in (CANONICAL_MAC, Path("/Applications/Notebook.app"))}
        require(not any(line.strip().split(None, 1)[-1] in legacy for line in processes.splitlines() if line.strip()),
                "Настольный Notebook ещё завершает работу; дождитесь выхода процесса.")
        deadline = time.monotonic() + wait_seconds
        requested, shutdown = set(), []
        while True:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                held = False
            else:
                held = True
            peer = runtime_peer(endpoint)
            if held:
                require(peer is None, "Notebook обслуживает рабочее пространство без подтверждённого writer lease.")
                current = lease.lstat()
                require(stat.S_ISREG(current.st_mode) and current.st_uid == os.geteuid()
                        and stat.S_IMODE(current.st_mode) == 0o600 and current.st_nlink == 1
                        and (current.st_dev, current.st_ino) == (info.st_dev, info.st_ino),
                        "Файл writer lease изменился во время завершения runtime; публикация не начата.")
                yield shutdown
                return
            require(peer is not None or bool(requested), "Неизвестный владелец Notebook writer lease; приложение не остановлено.")
            if peer is not None and peer not in requested:
                require(len(requested) < 3, "Notebook runtime повторно запускается; публикация не начата.")
                identity = request_runtime_termination(peer, approved)
                requested.add(peer)
                if identity is not None:
                    shutdown.append(identity)
                # Acquire this same FD immediately after requesting saved quit.
                continue
            require(time.monotonic() < deadline,
                    "Notebook runtime не завершил сохранение; владелец оставлен активным, публикация не начата.")
            time.sleep(0.05)
    finally:
        os.close(descriptor)


def install_verified_pair(source, build, evidence, runner=None):
    """Install one verified pair; compare the small catalog, never copy a store."""
    source, build = source.resolve(), build.resolve()
    raw_evidence = evidence.absolute()
    evidence = raw_evidence.resolve()
    require(not raw_evidence.is_symlink() and not evidence.exists() and not below(evidence, build)
            and not any(part.endswith(".app") for part in evidence.parts)
            and (not below(evidence, source) or evidence.relative_to(source).parts[0] == ".build"),
            "Для установки нужен новый каталог вне release bundle и build inputs.")
    release = read_json(build / "build.json")
    require(release.get("format") == 1 and release.get("status") == "verified-build"
            and set(release.get("apps", {})) == {"iPad", "mac"}, "Установка требует verified-build пары.")
    snapshot = build / "source"
    require(source_inputs(snapshot)["sha256"] == release.get("sourceSHA256"), "Проверенный source snapshot изменился.")
    require(file_digest(snapshot / "Applications/notebook_release.py") == file_digest(Path(__file__)),
            "Установщик должен принадлежать проверенному release snapshot.")
    paths = {"iPad": "derived-data/Build/Products/Release-iphoneos/Notebook.app",
             "mac": "plugin/notebook/runtime/NotebookRuntime.app"}
    for role, path in paths.items():
        require(release["apps"][role].get("path") == path, "Release называет неизвестный адрес bundle.")
        manifest = read_json(build / (role + "-manifest.json"))
        require(app_manifest(build / path) == manifest and manifest["sha256"] == release["apps"][role].get("manifestSHA256"),
                "Подписанная пара изменилась после сборки.")
    plugin = build / "plugin"
    metadata = plugin_metadata(plugin)
    require(metadata == plugin_metadata(snapshot / "MCP/plugin"), "Release plugin metadata изменилось.")
    manifest = read_json(plugin / "notebook/plugin.json")
    require(release.get("plugin") == {"path": "plugin", "version": manifest.get("version")}, "Release plugin version не совпала.")
    evidence.mkdir(mode=0o700)
    command = release_commands(evidence, runner)
    receipt = {"format": 1, "status": "preflight", "buildSHA256": file_digest(build / "build.json"),
               "build": release["build"], "version": release["version"], "pluginVersion": manifest["version"], "installationAttempted": False}
    write_json(evidence / "installation.json", receipt)

    def device_apps(label, bundle):
        target = evidence / (label + ".json")
        command(label, ["/usr/bin/xcrun", "devicectl", "device", "info", "apps", "--device", DEVICE,
            "--bundle-id", bundle, "--include-default-apps", "--include-app-clips", "--include-removable-apps",
            "--include-container-paths", "--include-app-group-identifiers", "--timeout", "30", "--json-output", target])
        return app_rows(successful_json(target, "devicectl.device.info.apps"), bundle)

    def ipad_groups(info):
        groups = info.get("appGroupIdentifiers")
        require(isinstance(groups, list)
                and all(isinstance(group, str) and group for group in groups)
                and len(groups) == len(set(groups)), "CLI не подтвердил appGroupIdentifiers установленного iPad.")
        return sorted(groups)

    def ipad_workspace(label):
        # Resolve every path inside the bundle domain: iPadOS may relocate the
        # data container during an update. The catalog owns logical selection.
        def files(suffix, relative=""):
            target = evidence / (label + "-" + suffix + ".json")
            argv = ["/usr/bin/xcrun", "devicectl", "device", "info", "files", "--device", DEVICE,
                "--domain-type", "appDataContainer", "--domain-identifier", BUNDLE, "--no-recurse"]
            if relative:
                argv += ["--subdirectory", relative]
            command(label + "-" + suffix, argv + ["--timeout", "30", "--json-output", target])
            result = successful_json(target, "devicectl.device.info.files")
            require(result.get("deviceIdentifier") == DEVICE and result.get("domain") == "appDataContainer"
                    and result.get("domainIdentifier") == BUNDLE, "Список файлов относится к другому iPad или приложению.")
            rows = result.get("files")
            require(isinstance(rows, list) and all(isinstance(row, dict) and isinstance(row.get("name"), str)
                    and row["name"] not in ("", ".", "..") and "/" not in row["name"]
                    and row.get("relativePath") == row["name"] for row in rows)
                    and len({row["name"] for row in rows}) == len(rows), "CLI не подтвердил однозначный список файлов iPad.")
            return {row["name"]: row for row in rows}

        def admitted(row, directory):
            resources = row.get("resources", {})
            require(resources.get("isDirectory") is directory and resources.get("isSymbolicLink") is False
                    and resources.get("isReadable") is True, "Файл пространства iPad недоступен или имеет неизвестный тип.")
            size = row.get("metadata", {}).get("size")
            require(type(size) is int and size >= 0, "CLI не подтвердил размер файла пространства iPad.")
            return size

        def directory(parent, name, relative, suffix):
            if name not in parent:
                return {}
            admitted(parent[name], True)
            return files(suffix, relative)

        root = files("root")
        library = directory(root, "Library", "Library", "library")
        support_path = "Library/Application Support"
        support = directory(library, "Application Support", support_path, "support")
        catalog_path = support_path + "/Notebook.spaces.json"
        catalog = support.get("Notebook.spaces.json")
        if catalog is None:
            original = directory(support, "Notebook", support_path + "/Notebook", "original")
            managed = directory(support, "Notebook.spaces", support_path + "/Notebook.spaces", "managed")
            require(not original and not managed,
                    "На iPad есть данные Notebook без подтверждённого каталога пространств; сохранность не подтверждена.")
            return {"identity": {"state": "empty"}}

        size = admitted(catalog, False)
        require(0 < size <= 262_144, "Каталог пространств iPad пуст или превышает допустимый размер.")
        with tempfile.TemporaryDirectory(prefix=label + "-catalog-", dir=evidence) as temporary:
            local = Path(temporary) / "Notebook.spaces.json"
            command(label + "-catalog", ["/usr/bin/xcrun", "devicectl", "device", "copy", "from", "--device", DEVICE,
                "--domain-type", "appDataContainer", "--domain-identifier", BUNDLE, "--source", catalog_path,
                "--destination", local, "--timeout", "30"])
            require(local.is_file() and not local.is_symlink() and local.stat().st_size == size,
                    "CLI не подтвердил чтение неизменного каталога пространств iPad.")
            data = local.read_bytes()
        raw_catalog = evidence / (label + "-catalog.json")
        raw_catalog.write_bytes(data)

        def catalog_object(pairs):
            value = dict(pairs)
            require(len(value) == len(pairs), "Каталог пространств iPad содержит повторяющиеся ключи JSON.")
            return value

        def unsupported_number(_):
            # Format 1 has only integer numbers. Binary float decoding could
            # otherwise merge distinct values before the preservation check.
            raise ReleaseError("Каталог пространств iPad содержит неподдерживаемое число JSON.")

        try:
            value = json.loads(data, object_pairs_hook=catalog_object,
                               parse_float=unsupported_number, parse_constant=unsupported_number)
            canonical = json.dumps(value, ensure_ascii=False, sort_keys=True,
                                   separators=(",", ":"), allow_nan=False).encode()
        except (ValueError, UnicodeError, RecursionError) as error:
            raise ReleaseError("Каталог пространств iPad не содержит корректный JSON.") from error
        uuid = lambda item: isinstance(item, str) and re.fullmatch(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", item)
        require(isinstance(value, dict) and type(value.get("format")) is int and value["format"] == 1 and isinstance(value.get("entries"), list)
                and len(value["entries"]) <= 32 and all(isinstance(entry, dict) and uuid(entry.get("id")) for entry in value["entries"]),
                "Каталог пространств iPad не имеет поддерживаемой идентичности.")
        ids = [entry["id"].lower() for entry in value["entries"]]
        original, selected = value.get("originalID"), value.get("selectedID")
        require(len(ids) == len(set(ids)) and (original is None or uuid(original))
                and (selected is None or uuid(selected) and selected.lower() in ids),
                "Каталог iPad не подтвердил выбранное пространство.")
        active = None
        sqlite_metadata = None
        if selected is not None:
            name = "Notebook" if original is not None and original.lower() == selected.lower() else "Notebook.spaces/" + selected.lower()
            if name == "Notebook":
                listing = directory(support, name, support_path + "/" + name, "active")
            else:
                managed = directory(support, "Notebook.spaces", support_path + "/Notebook.spaces", "managed")
                listing = directory(managed, selected.lower(), support_path + "/" + name, "active")
            require("notebook.sqlite" in listing, "Выбранное пространство iPad потеряло notebook.sqlite.")
            require(admitted(listing["notebook.sqlite"], False) > 0, "SQLite выбранного пространства iPad пуста.")
            active = support_path + "/" + name + "/notebook.sqlite"
            sqlite_metadata = listing["notebook.sqlite"]["metadata"]
        return {"identity": {"state": "catalog", "catalogSemanticSHA256": digest(canonical),
                    "originalID": original.lower() if original else None, "selectedID": selected.lower() if selected else None,
                    "workspaceIDs": sorted(ids), "activeSQLite": active},
                "catalogReadback": {"file": raw_catalog.name, "rawSHA256": digest(data), "rawBytes": size},
                "sqliteMetadata": sqlite_metadata}

    leases = contextlib.ExitStack()
    try:
        node, codex = shutil.which("node"), os.environ.get("CODEX_BIN") or shutil.which("codex")
        require(node and codex, "Для установки нужны node и Codex CLI.")
        installer = snapshot / "MCP/install-plugin.mjs"
        publication_before = json.loads(command("plugin-publication-preflight", [node, installer, "preflight"], read_output=True)[0])
        stable = Path(publication_before["root"])
        require(stable.is_absolute() and not below(stable, source) and not below(stable, build),
                "Опубликованный marketplace должен жить отдельно от исходников и сборки.")
        publication_fd = leases.enter_context(plugin_publication_lease(stable))

        def plugin_command(label, arguments, **options):
            return command(label, [node, installer, *arguments, "--publication-fd", publication_fd],
                           pass_fds=(publication_fd,), **options)

        device_path = evidence / "device.json"
        command("device", ["/usr/bin/xcrun", "devicectl", "device", "info", "details", "--device", DEVICE,
            "--timeout", "30", "--json-output", device_path, "--omit-deprecated-fields-in-json"])
        device = validate_device(successful_json(device_path, "devicectl.device.info.details"))
        require(device == release["device"], "Физический iPad или его система изменились после сборки пары.")
        ipad, mac = (build / paths[role] for role in ("iPad", "mac"))
        ipad_info, ipad_signature, _, _ = inspect_ipad(ipad, device, evidence, command)
        mac_info, mac_signature, _, _ = inspect_mac(mac, command, snapshot)
        require(release.get("codexRuntime") == mac_signature["codexRuntime"], "Codex release identity changed.")
        require(ipad_signature == release["apps"]["iPad"]["signature"] and mac_signature == release["apps"]["mac"]["signature"],
                "Подпись release пары изменилась.")
        require(all(info["CFBundleVersion"] == release["build"] and info["CFBundleShortVersionString"] == release["version"]
                    for info in (ipad_info, mac_info)), "Release версия не совпала с подписанными bundles.")
        before = device_apps("ipad-before", BUNDLE)
        canonical = device_apps("canonical-before", CANONICAL)
        groups_before = ipad_groups(before[0]) if before else None
        workspace_before = ipad_workspace("ipad-storage-before") if before else None
        build_number = release["build"]
        require(isinstance(build_number, str) and build_number.isdecimal(), "Build пары должен быть числом.")
        for info in before:
            current = info.get("bundleVersion")
            require(isinstance(current, str) and current.isdecimal() and int(current) <= int(build_number),
                    "Установленный iPad новее этой пары; downgrade запрещён.")
        current_apps = [CANONICAL_MAC]
        if publication_before["plugin"]:
            current_apps.append(Path(publication_before["plugin"]) / "runtime/NotebookRuntime.app")
        plugins = json.loads(command("plugins-before", [codex, "plugin", "list", "--json"], read_output=True)[0])
        installed = [item for item in plugins.get("installed", []) if item.get("pluginId") == "notebook@notebook-local"]
        require(len(installed) <= 1, "Codex назвал несколько установок плагина Notebook.")
        if installed:
            previous = installed[0].get("version", "")
            require(re.fullmatch(r"\d+\.\d+\.\d+", previous) and re.fullmatch(r"\d+\.\d+\.\d+", manifest["version"])
                    and tuple(map(int, previous.split("."))) <= tuple(map(int, manifest["version"].split("."))),
                    "Установленный плагин новее этой пары; downgrade запрещён.")
            connected_before = json.loads(command("connected-before", [codex, "mcp", "get", "notebook", "--json"], read_output=True)[0])
            previous_node = Path(connected_before.get("transport", {}).get("command", ""))
            if previous_node.is_absolute() and previous_node.parts[-4:] == ("Contents", "Resources", "CodexRuntime", "node"):
                current_apps.append(previous_node.parents[3])
        for current_app in current_apps:
            current_info = current_app / "Contents/Info.plist"
            if current_info.exists():
                current = plistlib.loads(current_info.read_bytes())
                number = current.get("CFBundleVersion")
                require(current.get("CFBundleIdentifier") == MAC_BUNDLE and isinstance(number, str)
                        and number.isdecimal() and int(number) <= int(build_number),
                        "Установленный runtime новее этой пары или имеет другую идентичность; downgrade запрещён.")
        receipt.update({"ipadBefore": before, "ipadWorkspaceBefore": workspace_before,
                        "canonicalBefore": canonical, "marketplace": str(stable)})
        approved = installed_runtime_identities(command, current_apps)
        receipt["step"] = "stop-runtime"; write_json(evidence / "installation.json", receipt)
        with stopped_runtime(command, approved) as shutdown:
            receipt["runtimeShutdown"] = shutdown
            receipt.update({"status": "incomplete", "installationAttempted": True, "step": "publish-plugin"})
            write_json(evidence / "installation.json", receipt)
            publication = json.loads(plugin_command("publish-plugin", ["publish", plugin], read_output=True, timeout=600)[0])
            require(publication["root"] == str(stable) and publication["version"] == manifest["version"],
                    "Публикация назвала другую версию или marketplace.")
            require(app_manifest(Path(publication["plugin"]) / "runtime/NotebookRuntime.app") == read_json(build / "mac-manifest.json"),
                    "Подписанный runtime изменился при переносе в marketplace.")
            receipt["publication"] = publication
            receipt["step"] = "install-plugin"; write_json(evidence / "installation.json", receipt)
            plugin_command("install-plugin", ["install"], cwd=snapshot, timeout=120)
            connected = json.loads(command("installed-plugin", [codex, "mcp", "get", "notebook", "--json"], read_output=True)[0])
            transport = connected.get("transport", {})
            executable = Path(transport.get("command", ""))
            suffix = ("Contents", "Resources", "CodexRuntime", "node")
            require(connected.get("enabled") is True and transport.get("type") == "stdio" and executable.is_absolute()
                    and executable.parts[-4:] == suffix, "Codex не подключил bundled Notebook runtime.")
            cached = executable.parents[3]
            require(transport.get("args") == [str(cached / "Contents/Resources/NotebookTools/dist/launch-runtime.mjs")],
                    "Codex подключил неверные аргументы запуска Notebook runtime.")
            require(app_manifest(cached) == read_json(build / "mac-manifest.json"),
                    "Нарушена целостность подписанного runtime в кеше Codex: состав или содержимое файлов не совпадает с проверенной сборкой.")
        # Only release after Codex's actual cached payload has been admitted.
        preinstall = device_apps("ipad-preinstall", BUNDLE)
        fields = ("bundleIdentifier", "bundleVersion", "version", "url")
        require([{key: info.get(key) for key in fields} for info in preinstall]
                == [{key: info.get(key) for key in fields} for info in before]
                and (not preinstall or ipad_groups(preinstall[0]) == groups_before),
                "Установленный iPad изменился во время подготовки.")
        if workspace_before is not None:
            workspace_preinstall = ipad_workspace("ipad-storage-preinstall")
            receipt["ipadWorkspacePreinstall"] = workspace_preinstall
            require(workspace_preinstall["identity"] == workspace_before["identity"],
                    "Каталог пространств iPad изменился во время подготовки; установка iPad не начата.")
        receipt["step"] = "install-ipad"; write_json(evidence / "installation.json", receipt)
        installed_path = evidence / "install-ipad.json"
        command("install-ipad", ["/usr/bin/xcrun", "devicectl", "device", "install", "app", "--device", DEVICE,
            ipad, "--timeout", "120", "--json-output", installed_path], timeout=150)
        installed = successful_json(installed_path, "devicectl.device.install.app").get("installedApplications")
        require(isinstance(installed, list) and len(installed) == 1 and installed[0].get("bundleID") == BUNDLE,
                "CLI не подтвердил единственную установку iPad; автоматического повтора нет.")
        after = device_apps("ipad-after", BUNDLE)
        receipt["ipadAfter"] = after
        require(len(after) == 1 and after[0].get("name") == DISPLAY_NAME and after[0].get("version") == release["version"]
                and after[0].get("bundleVersion") == build_number and isinstance(after[0].get("url"), str)
                and after[0]["url"] == installed[0].get("installationURL"), "iPad не подтвердил установленные build и bundle URL.")
        groups_after = ipad_groups(after[0])
        require(groups_before is None or groups_after == groups_before, "Идентификаторы app groups iPad изменились при установке.")
        workspace_after = ipad_workspace("ipad-storage-after")
        receipt["ipadWorkspaceAfter"] = workspace_after
        require(workspace_before is None or workspace_after["identity"] == workspace_before["identity"],
                "Каталог или выбранное пространство iPad изменились при установке; требуется readback без повторной установки.")
        require(device_apps("canonical-after", CANONICAL) == canonical, "Историческая установка iPad изменилась.")
        receipt["step"] = "prune-plugin-publications"; write_json(evidence / "installation.json", receipt)
        plugin_command("prune-plugin-publications", ["prune"], cwd=snapshot, timeout=120)
        receipt.update({"status": "installed", "step": "complete", "ipadAfter": after, "runtime": str(cached)})
        write_json(evidence / "installation.json", receipt)
        return receipt
    except Exception as error:
        receipt.update({"status": "incomplete" if receipt["installationAttempted"] else "refused", "error": str(error)})
        write_json(evidence / "installation.json", receipt)
        raise
    finally:
        leases.close()


def migrate_plugin_source(source, evidence, runner=None):
    """Adopt the installed immutable payload without reinstalling either product."""
    source = source.resolve()
    require(evidence.is_absolute() and evidence == evidence.resolve() and not evidence.exists(),
            "Для миграции нужен новый прямой каталог доказательств.")
    evidence.mkdir(parents=True, mode=0o700)
    command = release_commands(evidence, runner)
    node = shutil.which("node")
    require(node is not None, "Для миграции нужен node.")
    installer = source / "MCP/install-plugin.mjs"
    root = Path(json.loads(command("publication-location", [node, installer, "location"], read_output=True)[0])["root"])
    receipt = {"format": 1, "status": "migrating", "publicationRoot": str(root)}
    write_json(evidence / "source-migration.json", receipt)
    try:
        with plugin_publication_lease(root) as descriptor:
            result = json.loads(command("migrate-source", [node, installer, "migrate-source", "--publication-fd", descriptor],
                                        pass_fds=(descriptor,), read_output=True, timeout=600)[0])
        receipt.update({"status": "migrated", "result": result})
        write_json(evidence / "source-migration.json", receipt)
        return receipt
    except Exception as error:
        receipt.update({"status": "incomplete", "error": str(error)})
        write_json(evidence / "source-migration.json", receipt)
        raise


def main():
    parser = argparse.ArgumentParser(description="Проверка, сборка и установка пары Notebook iPad + Codex plugin без переноса содержания.")
    actions = parser.add_subparsers(dest="action", required=True)
    for name in ("fingerprint", "build-pair", "install-pair", "migrate-plugin-source"):
        action = actions.add_parser(name)
        action.add_argument("--source-root", type=Path, required=True)
        action.add_argument("--evidence-dir", type=Path, required=True)
        if name == "build-pair":
            action.add_argument("--verification-dir", type=Path, required=True)
        if name == "install-pair":
            action.add_argument("--build-dir", type=Path, required=True)
    args = parser.parse_args()
    if args.action == "fingerprint":
        write_json(args.evidence_dir, source_inputs(args.source_root))
    elif args.action == "build-pair":
        build_verified_pair(args.source_root, args.verification_dir, args.evidence_dir)
        print("Подписанная пара собрана из проверенного среза. Приложения НЕ установлены, архивы НЕ изменены.")
    elif args.action == "migrate-plugin-source":
        migrate_plugin_source(args.source_root, args.evidence_dir)
        print("Источник Notebook перенесён с сохранением установленного плагина и кеша. Квитанция: " + str(args.evidence_dir / "source-migration.json"))
    else:
        install_verified_pair(args.source_root, args.build_dir, args.evidence_dir)
        print("Плагин Notebook и iPad установлены из проверенной пары. Квитанция: " + str(args.evidence_dir / "installation.json"))


if __name__ == "__main__":
    try:
        main()
    except (ReleaseError, OSError, ValueError, subprocess.SubprocessError) as error:
        print("Notebook release отклонён: " + str(error), file=sys.stderr)
        sys.exit(1)


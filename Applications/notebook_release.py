"""Build input, signature and evidence contracts shared by Notebook release commands."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import stat
import tempfile

sys.dont_write_bytecode = True

BUNDLE = "com.amirtlinov.notebook.preview"
CANONICAL = "com.amirtlinov.notebook"
DISPLAY_NAME = "Notebook Lab"
CONFIGURATION = "Release"
SWIFT_OPTIMIZATION = "-O"
TEAM = "VUNH73AYPY"
DEVICE = "9CF2C22D-1CC6-573F-B27D-7EB0C81D2DD9"
UDID = "00008103-001E059934D9001E"
PRODUCT_TYPE = "iPad13,4"
CANONICAL_MAC = Path("/Users/amir/Applications/Notebook.app")
APP_ID = TEAM + "." + BUNDLE
GENERATED = {"Applications/iPad/Info.plist", "Applications/Mac/Info.plist"}
MAC_BUNDLE = "com.amirtlinov.notebook.mac"


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
                and (relative / name).as_posix() != "Applications/Notebook.xcodeproj"
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
        require(not path.is_symlink(), "Подписанный bundle не может ссылаться на внешние файлы.")
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


def canonical_identity(rows):
    require(len(rows) == 1, "Исходная установка Notebook должна быть явно найдена до preview.")
    row = rows[0]
    keys = ("bundleIdentifier", "bundleVersion", "version", "name", "url")
    require(all(isinstance(row.get(key), str) and row[key] for key in keys), "Неполная идентичность исходной установки.")
    return {key: row[key] for key in keys}


def validate_bundle_info(info, device):
    require(info.get("CFBundleIdentifier") == BUNDLE and info.get("CFBundleDisplayName") == DISPLAY_NAME,
            "Bundle обязан называться com.amirtlinov.notebook.preview / Notebook Lab.")
    require(info.get("CFBundlePackageType") == "APPL" and info.get("CFBundleSupportedPlatforms") == ["iPhoneOS"]
            and info.get("DTPlatformName") == "iphoneos" and str(info.get("DTSDKName", "")).startswith("iphoneos")
            and info.get("UIDeviceFamily") == [2], "Нужен bundle физического iPad, не Simulator/Mac/Catalyst.")
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


def validate_signature(display, entitlements, profile):
    identity = signature_identity(display, BUNDLE)
    allowed = {"application-identifier", "com.apple.developer.team-identifier", "keychain-access-groups", "get-task-allow"}
    require(isinstance(entitlements, dict) and set(entitlements).issubset(allowed),
            "Shared containers и неизвестные entitlements не входят в preview-контракт.")
    require(entitlements.get("application-identifier") == APP_ID
            and entitlements.get("com.apple.developer.team-identifier") == TEAM
            and entitlements.get("keychain-access-groups") == [APP_ID]
            and entitlements.get("get-task-allow") is True, "Preview обязан иметь только собственную keychain-группу и development identity.")
    require(profile.get("TeamIdentifier") == [TEAM] and profile.get("ApplicationIdentifierPrefix") == [TEAM]
            and UDID in profile.get("ProvisionedDevices", []) and not profile.get("ProvisionsAllDevices", False),
            "Provisioning не относится к согласованному team и физическому iPad.")
    profile_entitlements = profile.get("Entitlements", {})
    require(profile_entitlements.get("application-identifier") in (APP_ID, TEAM + ".*")
            and profile_entitlements.get("com.apple.developer.team-identifier") == TEAM
            and profile_entitlements.get("get-task-allow") is True, "Provisioning не разрешает этот development bundle.")
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
    def command(label, arguments, cwd=None, timeout=60, read_output=False):
        require(not any(entry.get("label") == label for entry in commands), "Команда с этой меткой уже записана: " + label)
        entry = {"label": label, "argv": [str(value) for value in arguments], "cwd": str(cwd) if cwd else None}
        commands.append(entry)
        write_json(evidence / "commands.json", commands)
        with (evidence / (label + ".stdout.log")).open("wb") as out, (evidence / (label + ".stderr.log")).open("wb") as err:
            result = command_runner(entry["argv"], cwd=cwd, stdout=out, stderr=err, timeout=timeout)
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


def build_ipad(snapshot, evidence, command):
    entitlements_file = evidence / "preview.entitlements"
    entitlements_file.write_bytes(plistlib.dumps({"keychain-access-groups": [APP_ID], "get-task-allow": True}))
    overrides = ["PRODUCT_BUNDLE_IDENTIFIER=" + BUNDLE, "NOTEBOOK_DISPLAY_NAME=" + DISPLAY_NAME,
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
    bundle = app_manifest(app)
    return info, signature, uuids, bundle


VERIFICATION_FILES = {
    "source-before.json", "source-after.json", "toolchain.json", "toolchain-after.json", "core.log",
    "load-fixture.log", "preview-installer.log", "release-tools.log", "mcp-check.log",
    "mcp-tests.log", "mcp-smoke.log", "computation-queue.json",
    "computation-dependencies.json", "computation-dependencies.log",
    "recognition-preparation.log", "mac-helper-launch.json", "mac-helper-launch.png",
    "ipad-release-build.log", "mac.log", "ipad.log", "mac-summary.json", "ipad-summary.json",
}


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


def verification_artifacts(evidence):
    """Hash the complete evidence, including xcresult payloads, not only counts."""
    require(evidence.is_dir() and not evidence.is_symlink(), "Нет каталога полного verify.sh.")
    require(all((evidence / name).is_file() for name in VERIFICATION_FILES),
            "Полный verify.sh не оставил все обязательные свидетельства.")
    require(all((evidence / (platform + ".xcresult")).is_dir() for platform in ("mac", "ipad")),
            "Нужны оба настоящих xcresult, не только сводки тестов.")
    files = []
    for path in sorted(evidence.rglob("*")):
        require(not path.is_symlink(), "Свидетельство не может ссылаться вне своего каталога.")
        require(path.is_dir() or stat.S_ISREG(path.lstat().st_mode), "Специальный файл не является свидетельством.")
        if path.is_file() and path != evidence / "verification.json":
            files.append({"path": path.relative_to(evidence).as_posix(), "bytes": path.stat().st_size,
                          "sha256": file_digest(path)})
    return files


def validate_test_summaries(evidence):
    for platform in ("mac", "ipad"):
        summary = read_json(evidence / (platform + "-summary.json"))
        require(type(summary.get("passedTests")) is int and summary["passedTests"] > 0
                and summary.get("failedTests") == 0 and summary.get("skippedTests") == 0
                and summary.get("runtimeWarnings") == [],
                "Полный маршрут не допускает ошибок, пропусков или runtime warnings: " + platform)


def read_toolchain(command, prefix="toolchain-"):
    commands = {
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
    require(not (evidence / "verification.json").exists(), "Этот полный проход уже завершён.")
    before = read_json(evidence / "source-before.json")
    after = source_inputs(source)
    write_json(evidence / "source-after.json", after)
    require(before == after, "Исходники изменились во время полного verify.sh.")
    validate_test_summaries(evidence)
    require(read_json(evidence / "toolchain.json") == read_json(evidence / "toolchain-after.json"),
            "Инструменты изменились во время полного verify.sh.")
    receipt = {"format": 1, "route": "./verify.sh", "status": "passed",
               "source": before, "artifacts": verification_artifacts(evidence)}
    write_json(evidence / "verification.json", receipt)


def checked_verification(source, evidence):
    receipt = read_json(evidence / "verification.json")
    require(receipt.get("format") == 1 and receipt.get("route") == "./verify.sh"
            and receipt.get("status") == "passed", "Нет завершённого полного verify.sh.")
    require(receipt.get("source") == source_inputs(source)
            == read_json(evidence / "source-before.json") == read_json(evidence / "source-after.json"),
            "Полный verify.sh проверял другой набор исходников.")
    validate_test_summaries(evidence)
    require(receipt.get("artifacts") == verification_artifacts(evidence),
            "Свидетельства полного verify.sh изменились после завершения.")
    return receipt


def build_mac(snapshot, evidence, command):
    entitlements = evidence / "mac.entitlements"
    entitlements.write_bytes(plistlib.dumps({"com.apple.security.get-task-allow": True}))
    command("build-mac", ["/usr/bin/xcrun", "xcodebuild", "-project",
        snapshot / "Applications/Notebook.xcodeproj", "-scheme", "NotebookMac",
        "-configuration", CONFIGURATION, "-destination", "generic/platform=macOS",
        "-derivedDataPath", evidence / "derived-mac", "-allowProvisioningUpdates",
        "PRODUCT_BUNDLE_IDENTIFIER=" + MAC_BUNDLE, "DEVELOPMENT_TEAM=" + TEAM,
        "CODE_SIGN_STYLE=Automatic", "CODE_SIGNING_ALLOWED=YES", "CODE_SIGNING_REQUIRED=YES",
        "CODE_SIGN_IDENTITY=Apple Development", "CODE_SIGN_ENTITLEMENTS=" + str(entitlements),
        "SWIFT_OPTIMIZATION_LEVEL=" + SWIFT_OPTIMIZATION, "ARCHS=arm64", "build"],
        cwd=snapshot, timeout=1800)
    return evidence / ("derived-mac/Build/Products/" + CONFIGURATION + "/Notebook.app")


def inspect_mac(app, command):
    bundle = app_manifest(app)
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    require(info.get("CFBundleIdentifier") == MAC_BUNDLE and info.get("LSUIElement") is True
            and info.get("CFBundlePackageType") == "APPL" and info.get("DTPlatformName") == "macosx",
            "Нужен безоконный macOS helper с собственной идентичностью.")
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
               "com.apple.developer.team-identifier": TEAM, "keychain-access-groups": [TEAM + "." + MAC_BUNDLE]}
    require(isinstance(entitlements, dict) and entitlements.get("com.apple.security.get-task-allow") is True
            and all(key in allowed and value == allowed[key] for key, value in entitlements.items()),
            "Mac получил неизвестные права или чужую идентичность Keychain.")
    signature["entitlements"] = entitlements
    architectures = command("mac-binary-architectures", ["/usr/bin/xcrun", "lipo", "-archs", executable], read_output=True)[0].decode().split()
    require(architectures == ["arm64"], "Нужен arm64 helper согласованного Mac.")
    output = command("mac-binary-platform", ["/usr/bin/xcrun", "vtool", "-show-build", executable], read_output=True)[0].decode()
    platforms = re.findall(r"^\s*platform\s+(\S+)\s*$", output, re.MULTILINE)
    require(platforms and all(value.upper() == "MACOS" for value in platforms), "Mach-O helper не относится к macOS.")
    uuids = command("mac-binary-uuids", ["/usr/bin/xcrun", "dwarfdump", "--uuid", executable], read_output=True)[0].decode()
    require(re.search(r"UUID: [0-9A-Fa-f-]{36} \(arm64\)", uuids), "Mac binary не имеет UUID arm64.")
    require(app_manifest(app) == bundle, "Mac bundle изменился во время проверки подписи.")
    return info, signature, uuids, bundle


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
               "verificationSHA256": file_digest(verification / "verification.json"), "sourceSHA256": before["sha256"]}
    write_json(evidence / "build.json", receipt)
    try:
        toolchain = read_toolchain(command)
        require(toolchain == read_json(verification / "toolchain.json"), "Инструменты сборки отличаются от полного verify.sh.")
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
        ipad = build_ipad(snapshot, evidence, command)
        ipad_info, ipad_signature, ipad_uuids, ipad_manifest = inspect_ipad(ipad, device, evidence, command)
        mac = build_mac(snapshot, evidence, command)
        mac_info, mac_signature, mac_uuids, mac_manifest = inspect_mac(mac, command)
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
                        "version": ipad_info["CFBundleShortVersionString"], "build": ipad_info["CFBundleVersion"]})
        write_json(evidence / "build.json", receipt)
        return receipt
    except Exception as error:
        receipt.update({"status": "refused", "error": str(error)})
        write_json(evidence / "build.json", receipt)
        raise


def main():
    parser = argparse.ArgumentParser(description="Проверка и сборка Notebook без изменения установленных приложений или архивов.")
    actions = parser.add_subparsers(dest="action", required=True)
    for name in ("fingerprint", "verification-start", "verification-finish", "build-pair"):
        action = actions.add_parser(name)
        action.add_argument("--source-root", type=Path, required=True)
        action.add_argument("--evidence-dir", type=Path, required=True)
        if name == "build-pair":
            action.add_argument("--verification-dir", type=Path, required=True)
    args = parser.parse_args()
    if args.action == "fingerprint":
        write_json(args.evidence_dir, source_inputs(args.source_root))
    elif args.action == "verification-start":
        write_json(args.evidence_dir / "source-before.json", source_inputs(args.source_root))
        write_json(args.evidence_dir / "toolchain.json", read_toolchain(release_commands(args.evidence_dir)))
    elif args.action == "verification-finish":
        write_json(args.evidence_dir / "toolchain-after.json",
                   read_toolchain(release_commands(args.evidence_dir), prefix="toolchain-after-"))
        finish_verification(args.source_root, args.evidence_dir)
    else:
        build_verified_pair(args.source_root, args.verification_dir, args.evidence_dir)
        print("Подписанная пара собрана из проверенного среза. Приложения НЕ установлены, архивы НЕ изменены.")


if __name__ == "__main__":
    try:
        main()
    except (ReleaseError, OSError, ValueError, subprocess.SubprocessError) as error:
        print("Notebook release отклонён: " + str(error), file=sys.stderr)
        sys.exit(1)


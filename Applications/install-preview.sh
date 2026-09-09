#!/bin/bash
set -euo pipefail
ROOT=$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd)
exec python3 - "$ROOT" "$@" <<'PY'
"""First installation of an isolated iPad preview; never an archive updater."""
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


class PreviewError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise PreviewError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def write_json(path, value):
    data = (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode()
    with path.open("wb") as output:
        output.write(data)
        output.flush()
        os.fsync(output.fileno())


def below(path, root):
    return path == root or root in path.parents


def source_inputs(root):
    require((root / "Package.swift").is_file() and (root / "Applications/project.yml").is_file(),
            "Исходник должен содержать Package.swift и Applications/project.yml.")
    paths = [root / "Package.swift"]
    if (root / "Package.resolved").exists():
        paths.append(root / "Package.resolved")
    for directory in ("Sources", "Tests", "Applications"):
        require((root / directory).is_dir(), "Нет каталога исходников: " + directory)
        for base, directories, files in os.walk(root / directory, followlinks=False):
            relative = Path(base).relative_to(root)
            directories[:] = sorted(name for name in directories if name not in (".git", ".build", "node_modules")
                and not name.endswith((".xcodeproj", ".xcresult")) and not name.startswith("DerivedData"))
            for name in directories:
                require(not (Path(base) / name).is_symlink(), "Ссылка за пределы исходников не допускается.")
            for name in sorted(files):
                path = Path(base) / name
                if name == ".DS_Store" or (relative / name).as_posix() in GENERATED:
                    continue
                paths.append(path)
    result = []
    for path in sorted(paths):
        require(path.is_file() and not path.is_symlink(), "Нужен обычный файл исходника: " + str(path))
        result.append({"path": path.relative_to(root).as_posix(), "sha256": digest(path.read_bytes()),
                       "executable": bool(path.stat().st_mode & 0o111)})
    encoded = json.dumps(result, sort_keys=True, separators=(",", ":")).encode()
    return {"sha256": digest(encoded), "files": result}


def app_manifest(app):
    files = []
    for path in sorted(app.rglob("*")):
        require(not path.is_symlink(), "Подписанный bundle не может ссылаться на внешние файлы.")
        require(not (path.is_dir() and path.suffix in (".app", ".appex")), "Вложенные приложения/расширения не входят в preview-контракт.")
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


def validate_signature(display, entitlements, profile):
    def field(name):
        matches = re.findall(r"^" + re.escape(name) + r"=(.*)$", display, re.MULTILINE)
        require(len(matches) == 1, "Подпись не имеет однозначного поля " + name)
        return matches[0]
    require(field("Identifier") == BUNDLE and field("TeamIdentifier") == TEAM, "Подписан чужой bundle или team.")
    require("Authority=Apple Development:" in display and "Signature=adhoc" not in display, "Нужна настоящая Apple Development подпись.")
    require(re.fullmatch(r"[0-9a-fA-F]{40,64}", field("CDHash")), "В подписи отсутствует CDHash.")
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
    return {"identifier": BUNDLE, "team": TEAM, "cdhash": field("CDHash"), "profileUUID": profile.get("UUID"),
            "profileExpiration": expiry.isoformat(), "entitlements": entitlements}


def main(argv, default_source, runner=None):
    parser = argparse.ArgumentParser(description="Только первая отдельная установка Notebook Lab; не замена Notebook и не перенос данных.")
    parser.add_argument("--source-root", type=Path, default=Path(default_source))
    parser.add_argument("--evidence-dir", type=Path)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--dry-run", action="store_true", help="Показать план без Xcode, подписи и обращения к устройству (по умолчанию).")
    modes.add_argument("--build", action="store_true", help="Собрать, подписать и проверить, но не устанавливать.")
    modes.add_argument("--install", action="store_true", help="После всех проверок один раз установить новый preview bundle.")
    args = parser.parse_args(argv)
    source = args.source_root.resolve()
    require(not below(source, CANONICAL_MAC), "Исходная Mac-установка не является рабочим каталогом.")
    require((source / "Applications/project.yml").is_file(), "Не найден Applications/project.yml.")
    spec = (source / "Applications/project.yml").read_text()
    require("CFBundleDisplayName: $(NOTEBOOK_DISPLAY_NAME)" in spec and "NOTEBOOK_DISPLAY_NAME: Notebook" in spec,
            "Нужна конфигурация с отдельным preview display-name override.")
    mode = "install" if args.install else "build" if args.build else "dry-run"
    plan = {"mode": mode, "source": str(source), "bundleIdentifier": BUNDLE, "displayName": DISPLAY_NAME,
            "team": TEAM, "device": DEVICE, "physicalUDID": UDID,
            "configuration": CONFIGURATION, "swiftOptimization": SWIFT_OPTIMIZATION,
            "existingPreview": "refuse", "canonical": "metadata only; never install, launch, copy data, terminate or delete",
            "provenance": "private source snapshot -> signed iphoneos bundle -> one devicectl install -> device metadata",
            "warning": "Notebook Lab имеет отдельные данные. Это не обновление исходного Notebook и не перенос архива."}
    if mode == "dry-run":
        print(json.dumps(plan, ensure_ascii=False, indent=2))
        return 0
    require(args.evidence_dir is not None, "Для сборки нужен явный новый --evidence-dir.")
    raw_evidence = args.evidence_dir.absolute()
    evidence = raw_evidence.resolve()
    require(not raw_evidence.is_symlink() and not below(evidence, CANONICAL_MAC.resolve()), "Каталог доказательств не может быть ссылкой или исходной Mac-установкой.")
    require(evidence != source and (not below(evidence, source) or evidence.relative_to(source).parts[0] == ".build"),
            "Доказательства нельзя создавать внутри build inputs; используйте .build или внешний каталог.")
    require(not evidence.exists() or (evidence.is_dir() and not any(evidence.iterdir())), "Для нового запуска нужен пустой каталог доказательств; прежняя попытка не повторяется автоматически.")
    evidence.mkdir(parents=True, exist_ok=True, mode=0o700)
    evidence.chmod(0o700)
    command_runner = runner or subprocess.run
    commands = []
    receipt = {"format": 1, "plan": plan, "status": "preflight", "installationAttempted": False}
    write_json(evidence / "receipt.json", receipt)

    def command(label, arguments, cwd=None, timeout=60, read_output=False):
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

    def device_info(label):
        target = evidence / (label + ".json")
        command(label, ["/usr/bin/xcrun", "devicectl", "device", "info", "details", "--device", DEVICE,
                        "--timeout", "30", "--json-output", target, "--omit-deprecated-fields-in-json"])
        return validate_device(successful_json(target, "devicectl.device.info.details"))

    def apps(label, bundle):
        target = evidence / (label + ".json")
        command(label, ["/usr/bin/xcrun", "devicectl", "device", "info", "apps", "--device", DEVICE,
                        "--bundle-id", bundle, "--include-default-apps", "--include-app-clips", "--include-removable-apps",
                        "--include-container-paths", "--include-app-group-identifiers", "--timeout", "30", "--json-output", target])
        return app_rows(successful_json(target, "devicectl.device.info.apps"), bundle)

    try:
        device = device_info("device-before")
        canonical = canonical_identity(apps("canonical-before", CANONICAL))
        require(not apps("preview-before", BUNDLE), "Notebook Lab уже установлен. Обновление запрещено без отдельного согласованного checkpoint его данных; живой SQLite не копируется.")
        before = source_inputs(source)
        write_json(evidence / "source-before.json", before)
        snapshot = evidence / "source"
        snapshot.mkdir()
        for item in before["files"]:
            origin, target = source / item["path"], snapshot / item["path"]
            target.parent.mkdir(parents=True, exist_ok=True)
            data = origin.read_bytes()
            require(digest(data) == item["sha256"], "Исходники изменились во время подготовки.")
            target.write_bytes(data)
            target.chmod(0o755 if item["executable"] else 0o644)
        require(source_inputs(source) == before and source_inputs(snapshot) == before, "Неполная или изменившаяся копия исходников.")
        xcodegen = shutil.which("xcodegen")
        require(xcodegen is not None, "Нужен установленный xcodegen.")
        command("xcode-version", ["/usr/bin/xcrun", "xcodebuild", "-version"])
        command("xcodegen-version", [xcodegen, "--version"])
        command("generate-project", [xcodegen, "generate", "--spec", "project.yml"], cwd=snapshot / "Applications")
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
        after = source_inputs(source)
        write_json(evidence / "source-after.json", after)
        snapshot_after = source_inputs(snapshot)
        write_json(evidence / "built-source-after.json", snapshot_after)
        require(before == after == snapshot_after, "Исходники изменились при сборке; такой bundle не устанавливается.")
        app = evidence / ("derived-data/Build/Products/" + CONFIGURATION + "-iphoneos/Notebook.app")
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
        write_json(evidence / "app-manifest.json", bundle)
        require(not apps("preview-preinstall", BUNDLE), "Preview появился после начала проверки; замена запрещена.")
        require(canonical_identity(apps("canonical-preinstall", CANONICAL)) == canonical, "Исходная установка изменилась независимо от preview; установка отменена.")
        require(device_info("device-preinstall") == device, "Устройство или его iPadOS изменились во время сборки.")
        require(app_manifest(app) == bundle and source_inputs(source) == before and source_inputs(snapshot) == before,
                "Подписанный bundle или исходники изменились после проверки.")
        receipt.update({"status": "ready", "sourceSHA256": before["sha256"], "app": str(app), "appManifestSHA256": bundle["sha256"],
                        "signature": signature, "device": device, "canonicalBefore": canonical,
                        "binaryUUIDs": uuids.strip(), "version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"]})
        write_json(evidence / "receipt.json", receipt)
        if not args.install:
            print("Notebook Lab собран и проверен, но НЕ установлен. Доказательства: " + str(evidence))
            return 0
        # There is no retry, replacement, launch, termination or rollback-delete.
        receipt.update({"status": "install-attempted", "installationAttempted": True})
        write_json(evidence / "receipt.json", receipt)
        install_json = evidence / "install.json"
        command("install", ["/usr/bin/xcrun", "devicectl", "device", "install", "app", "--device", DEVICE, app,
                            "--timeout", "120", "--json-output", install_json], timeout=150)
        installed = successful_json(install_json, "devicectl.device.install.app").get("installedApplications")
        require(isinstance(installed, list) and len(installed) == 1 and installed[0].get("bundleID") == BUNDLE,
                "CLI не подтвердил единственный preview bundle; автоматического повтора нет.")
        rows = apps("preview-after", BUNDLE)
        require(len(rows) == 1 and rows[0].get("name") == DISPLAY_NAME
                and rows[0].get("version") == info["CFBundleShortVersionString"] and rows[0].get("bundleVersion") == info["CFBundleVersion"],
                "Устройство не подтвердило имя и версию установленного preview.")
        require(isinstance(rows[0].get("url"), str) and rows[0]["url"] == installed[0].get("installationURL"),
                "Адрес установки не совпал с текущим metadata устройства.")
        canonical_after = canonical_identity(apps("canonical-after", CANONICAL))
        require(canonical_after == canonical and app_manifest(app) == bundle, "После установки изменилась исходная программа или локальный bundle.")
        receipt.update({"status": "installed", "previewAfter": rows[0], "canonicalAfter": canonical_after})
        write_json(evidence / "receipt.json", receipt)
        print("Отдельный Notebook Lab установлен, но не запущен. Исходный Notebook не заменён. Доказательства: " + str(evidence))
        return 0
    except Exception as error:
        receipt.update({"status": "installation-unconfirmed" if receipt["installationAttempted"] else "refused", "error": str(error)})
        write_json(evidence / "receipt.json", receipt)
        if receipt["installationAttempted"]:
            print("Установка могла завершиться: НЕ повторяйте её автоматически. Сначала проверьте receipt.json и устройство.", file=sys.stderr)
        raise


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[2:], sys.argv[1]))
    except (PreviewError, OSError, ValueError, subprocess.SubprocessError) as error:
        print("Preview отклонён: " + str(error), file=sys.stderr)
        sys.exit(1)
PY

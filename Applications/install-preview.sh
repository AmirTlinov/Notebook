#!/bin/bash
set -euo pipefail
ROOT=$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd)
exec env PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$ROOT/Applications" python3 - "$ROOT" "$@" <<'PY'
"""First installation only. An existing Lab is always refused, including --build."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys
sys.dont_write_bytecode = True
from notebook_release import (BUNDLE, CANONICAL, DISPLAY_NAME, CONFIGURATION,
    SWIFT_OPTIMIZATION, TEAM, DEVICE, UDID, CANONICAL_MAC, APP_ID, ReleaseError,
    require, write_json, below, source_inputs, app_manifest,
    successful_json, validate_device, app_rows, canonical_identity,
    release_commands, copy_source, build_ipad, inspect_ipad)


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
    command = release_commands(evidence, runner)
    receipt = {"format": 1, "plan": plan, "status": "preflight", "installationAttempted": False}
    write_json(evidence / "receipt.json", receipt)

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
        copy_source(source, snapshot, before)
        xcodegen = shutil.which("xcodegen")
        require(xcodegen is not None, "Нужен установленный xcodegen.")
        command("xcode-version", ["/usr/bin/xcrun", "xcodebuild", "-version"])
        command("xcodegen-version", [xcodegen, "--version"])
        command("generate-project", [xcodegen, "generate", "--spec", "project.yml"], cwd=snapshot / "Applications")
        app = build_ipad(snapshot, evidence, command)
        after = source_inputs(source)
        write_json(evidence / "source-after.json", after)
        snapshot_after = source_inputs(snapshot)
        write_json(evidence / "built-source-after.json", snapshot_after)
        require(before == after == snapshot_after, "Исходники изменились при сборке; такой bundle не устанавливается.")
        info, signature, uuids, bundle = inspect_ipad(app, device, evidence, command)
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
    except (ReleaseError, OSError, ValueError, subprocess.SubprocessError) as error:
        print("Preview отклонён: " + str(error), file=sys.stderr)
        sys.exit(1)
PY

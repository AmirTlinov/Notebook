#!/usr/bin/env python3
"""Exercise the real installer guards with a fake CLI; never contact Apple/device."""
import contextlib
import datetime
import io
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / "Applications"))
SCRIPT = ROOT / "Applications/install-preview.sh"
MODULE = types.ModuleType("notebook_preview_installer")
CODE = SCRIPT.read_text().split("<<'PY'\n", 1)[1].rsplit("\nPY\n", 1)[0]
exec(compile(CODE, str(SCRIPT), "exec"), MODULE.__dict__)


def device_result():
    return {"identifier": MODULE.DEVICE, "properties": {
        "hardware": {"udid": MODULE.UDID, "reality": "physical", "platform": "iOS", "deviceType": "iPad", "productType": "iPad13,4"},
        "connection": {"state": "connected", "pairingState": "paired"},
        "state": {"bootState": "booted", "developerModeStatus": {"enabled": {"mode": 1}}},
        "software": {"osVersionNumber": {"stringValue": "27.0"}, "osBuildVersions": {"buildVersion": {"name": "24A5430a"}}}}}


def app_info():
    return {"CFBundleIdentifier": MODULE.BUNDLE, "CFBundleDisplayName": MODULE.DISPLAY_NAME,
        "CFBundlePackageType": "APPL", "CFBundleSupportedPlatforms": ["iPhoneOS"], "DTPlatformName": "iphoneos",
        "DTSDKName": "iphoneos27.0", "UIDeviceFamily": [2], "MinimumOSVersion": "27.0", "CFBundleExecutable": "Notebook",
        "CFBundleShortVersionString": "0.3.14", "CFBundleVersion": "17"}


def entitlement_values():
    return {"application-identifier": MODULE.APP_ID, "com.apple.developer.team-identifier": MODULE.TEAM,
            "keychain-access-groups": [MODULE.APP_ID], "get-task-allow": True}


class FakeCLI:
    """Writes the observed CLI JSON shapes and fake signed bundle into one temp root."""
    def __init__(self, source):
        self.source = source
        self.calls = []
        self.installed = False
        self.device = device_result()
        self.info = app_info()
        self.entitlements = entitlement_values()
        self.certificate = b"fixture Apple Development certificate"
        self.profile = {"TeamIdentifier": [MODULE.TEAM], "ApplicationIdentifierPrefix": [MODULE.TEAM],
            "ProvisionedDevices": [MODULE.UDID], "Entitlements": {**entitlement_values(), "application-identifier": MODULE.TEAM + ".*"},
            "ExpirationDate": datetime.datetime.now() + datetime.timedelta(days=10), "UUID": "fixture-profile",
            "DeveloperCertificates": [self.certificate]}
        self.canonical = {"bundleIdentifier": MODULE.CANONICAL, "name": "Notebook", "version": "0.3.14", "bundleVersion": "17",
            "url": "file:///private/var/containers/Bundle/Application/CANONICAL/Notebook.app/"}
        self.preview = {"bundleIdentifier": MODULE.BUNDLE, "name": MODULE.DISPLAY_NAME, "version": "0.3.14", "bundleVersion": "17",
            "url": "file:///private/var/containers/Bundle/Application/PREVIEW/Notebook.app/"}
        self.existing_preview = False
        self.preview_during_build = False
        self.change_source = False
        self.change_snapshot = False
        self.change_bundle = False
        self.change_canonical = False
        self.fail_build = False
        self.fail_signature = False
        self.fail_install = False
        self.bad_install_receipt = False
        self.missing_installation_url = False
        self.wrong_installation_url = False
        self.bad_signature_team = False
        self.platform = "IOS"
        self.architectures = "arm64"
        self.app = None

    def __call__(self, argv, cwd=None, stdout=None, stderr=None, timeout=None):
        self.calls.append(list(argv))
        output = b""
        error = b""
        exit_code = 0
        def after(flag): return argv[argv.index(flag) + 1]
        def emit(command, result):
            target = Path(after("--json-output"))
            target.write_text(json.dumps({"info": {"outcome": "success", "commandType": command}, "result": result}))
        if argv[0] == "/usr/bin/xcrun" and argv[1:5] == ["devicectl", "device", "info", "details"]:
            emit("devicectl.device.info.details", self.device)
        elif argv[0] == "/usr/bin/xcrun" and argv[1:5] == ["devicectl", "device", "info", "apps"]:
            bundle = after("--bundle-id")
            label = Path(after("--json-output")).stem
            if self.change_bundle and label == "preview-preinstall":
                (self.app / "Notebook").write_bytes(b"changed after signature verification")
            if self.change_canonical and label == "canonical-preinstall":
                self.canonical["url"] = "file:///different-canonical/Notebook.app/"
            rows = [self.canonical] if bundle == MODULE.CANONICAL else [self.preview] if (self.installed or self.existing_preview) else []
            emit("devicectl.device.info.apps", {"deviceIdentifier": MODULE.DEVICE, "matchingBundleIdentifier": bundle, "apps": rows})
        elif argv[0] == "/usr/bin/xcrun" and argv[1:5] == ["devicectl", "device", "install", "app"]:
            if self.fail_install:
                exit_code = 1
            else:
                self.installed = True
                application = {"bundleID": MODULE.CANONICAL if self.bad_install_receipt else MODULE.BUNDLE,
                               "installationURL": "file:///different-preview/Notebook.app/" if self.wrong_installation_url else self.preview["url"]}
                if self.missing_installation_url:
                    application.pop("installationURL")
                    application["bundleURL"] = self.preview["url"]
                emit("devicectl.device.install.app", {"installedApplications": [application]})
        elif argv[0] == "/usr/bin/xcrun" and argv[1] == "xcodebuild" and argv[-1] == "build":
            if self.fail_build:
                exit_code = 1
            else:
                self.app = Path(after("-derivedDataPath")) / ("Build/Products/" + after("-configuration") + "-iphoneos/Notebook.app")
                self.app.mkdir(parents=True)
                (self.app / "Info.plist").write_bytes(plistlib.dumps(self.info))
                (self.app / "Notebook").write_bytes(b"fixture arm64 iOS binary")
                (self.app / "Notebook").chmod(0o755)
                (self.app / "embedded.mobileprovision").write_bytes(b"fixture signed profile")
                if self.change_source:
                    (self.source / "Sources/NotebookCore/Test.swift").write_text("let changed = true\n")
                if self.change_snapshot:
                    (Path(cwd) / "Sources/NotebookCore/Test.swift").write_text("let changed = true\n")
                if self.preview_during_build:
                    self.existing_preview = True
        elif argv[0] == "/usr/bin/codesign":
            if "--verify" in argv:
                exit_code = 1 if self.fail_signature else 0
            elif "--entitlements" in argv:
                output = plistlib.dumps(self.entitlements)
            elif any(value.startswith("--extract-certificates=") for value in argv):
                prefix = next(value.split("=", 1)[1] for value in argv if value.startswith("--extract-certificates="))
                Path(prefix + "0").write_bytes(self.certificate)
            else:
                team = "OTHERTEAM" if self.bad_signature_team else MODULE.TEAM
                error = ("Identifier=" + MODULE.BUNDLE + "\nTeamIdentifier=" + team + "\nAuthority=Apple Development: Fixture\nCDHash=" + "a" * 40 + "\n").encode()
        elif argv[0] == "/usr/bin/security":
            output = plistlib.dumps(self.profile)
        elif argv[0] == "/usr/bin/xcrun" and argv[1] == "lipo":
            output = (self.architectures + "\n").encode()
        elif argv[0] == "/usr/bin/xcrun" and argv[1] == "vtool":
            output = ("Load command 1\n platform " + self.platform + "\n minos 27.0\n").encode()
        elif argv[0] == "/usr/bin/xcrun" and argv[1] == "dwarfdump":
            output = b"UUID: 11111111-2222-3333-4444-555555555555 (arm64) fixture\n"
        elif argv[0] == "/fixture/xcodegen" or argv[:3] == ["/usr/bin/xcrun", "xcodebuild", "-version"]:
            output = b"fixture tool version\n"
        else:
            raise AssertionError("Unexpected CLI command: " + repr(argv))
        stdout.write(output)
        stderr.write(error)
        return subprocess.CompletedProcess(argv, exit_code)

    @property
    def install_calls(self):
        return [call for call in self.calls if call[1:5] == ["devicectl", "device", "install", "app"]]


class PreviewInstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="notebook-preview-guards-")
        self.root = Path(self.temp.name).resolve()
        self.source = self.root / "source"
        for directory in ["Sources/NotebookCore", "Tests/NotebookCoreTests", "Applications/Shared", "Applications/iPad", "MCP"]:
            (self.source / directory).mkdir(parents=True, exist_ok=True)
        (self.source / "verify.sh").write_text("#!/bin/bash\n")
        (self.source / "MCP/package.json").write_text('{}\n')
        (self.source / "Package.swift").write_text("// fixture build input\n")
        (self.source / "Sources/NotebookCore/Test.swift").write_text("let accepted = true\n")
        (self.source / "Tests/NotebookCoreTests/Test.swift").write_text("// test fixture input\n")
        (self.source / "Applications/project.yml").write_text((ROOT / "Applications/project.yml").read_text())
        self.cli = FakeCLI(self.source)
        self.evidence = self.root / "evidence"

    def tearDown(self):
        self.temp.cleanup()

    def execute(self, mode="--install", evidence=None):
        with patch.object(MODULE.shutil, "which", return_value="/fixture/xcodegen"), contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            return MODULE.main(["--source-root", str(self.source), "--evidence-dir", str(evidence or self.evidence), mode],
                               default_source=self.source, runner=self.cli)

    def refused(self, expected):
        with self.assertRaises((MODULE.ReleaseError, ValueError)) as caught:
            self.execute()
        self.assertIn(expected, str(caught.exception))
        self.assertEqual(self.cli.install_calls, [])

    def test_default_dry_run_has_no_commands_or_evidence(self):
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(MODULE.main(["--source-root", str(self.source)], self.source, runner=self.cli), 0)
        self.assertEqual(self.cli.calls, [])
        self.assertFalse(self.evidence.exists())

    def test_build_only_retains_proof_and_never_installs(self):
        self.assertEqual(self.execute("--build"), 0)
        self.assertEqual(self.cli.install_calls, [])
        receipt = json.loads((self.evidence / "receipt.json").read_text())
        self.assertEqual(receipt["status"], "ready")
        self.assertFalse(receipt["installationAttempted"])
        self.assertEqual(json.loads((self.evidence / "source-before.json").read_text()), json.loads((self.evidence / "source-after.json").read_text()))

    def test_first_install_is_one_exact_command_with_full_provenance(self):
        self.assertEqual(self.execute(), 0)
        self.assertEqual(len(self.cli.install_calls), 1)
        call = self.cli.install_calls[0]
        self.assertEqual(call[call.index("--device") + 1], MODULE.DEVICE)
        self.assertIn(str(self.cli.app), call)
        receipt = json.loads((self.evidence / "receipt.json").read_text())
        self.assertEqual(receipt["status"], "installed")
        self.assertEqual(receipt["canonicalBefore"], receipt["canonicalAfter"])
        self.assertEqual(receipt["signature"]["entitlements"]["keychain-access-groups"], [MODULE.APP_ID])
        self.assertEqual(receipt["sourceSHA256"], json.loads((self.evidence / "source-before.json").read_text())["sha256"])
        self.assertEqual(receipt["appManifestSHA256"], json.loads((self.evidence / "app-manifest.json").read_text())["sha256"])
        build = next(call for call in self.cli.calls if call[1:2] == ["xcodebuild"] and call[-1] == "build")
        for value in ["PRODUCT_BUNDLE_IDENTIFIER=" + MODULE.BUNDLE, "DEVELOPMENT_TEAM=" + MODULE.TEAM,
                      "NOTEBOOK_DISPLAY_NAME=" + MODULE.DISPLAY_NAME, "id=" + MODULE.UDID, "iphoneos", "-allowProvisioningUpdates"]:
            self.assertIn(value, build)
        for call in self.cli.calls:
            self.assertFalse({"launch", "terminate", "uninstall", "erase", "copy", "--terminate-existing", "--remove-existing-content"}.intersection(call))
            self.assertNotIn(str(MODULE.CANONICAL_MAC), call)

    def test_release_optimization_and_development_signing_are_explicit(self):
        self.assertEqual(self.execute("--build"), 0)
        build = next(call for call in self.cli.calls if call[1:2] == ["xcodebuild"] and call[-1] == "build")
        self.assertEqual(build[build.index("-configuration") + 1], "Release")
        self.assertIn("SWIFT_OPTIMIZATION_LEVEL=-O", build)
        self.assertIn("CODE_SIGN_IDENTITY=Apple Development", build)
        self.assertEqual(self.cli.app, self.evidence / "derived-data/Build/Products/Release-iphoneos/Notebook.app")
        self.assertEqual(plistlib.loads((self.evidence / "preview.entitlements").read_bytes()),
                         {"keychain-access-groups": [MODULE.APP_ID], "get-task-allow": True})
        receipt = json.loads((self.evidence / "receipt.json").read_text())
        self.assertEqual(receipt["plan"]["configuration"], "Release")
        self.assertEqual(receipt["plan"]["swiftOptimization"], "-O")
        self.assertEqual(self.cli.install_calls, [])

    def test_signature_requirement_is_literal_and_keeps_apple_team_and_bundle(self):
        self.assertEqual(self.execute("--build"), 0)
        verification = next(call for call in self.cli.calls if call[0] == "/usr/bin/codesign" and "--verify" in call)
        self.assertEqual(verification[verification.index("-R") + 1],
                         '=anchor apple generic and identifier "com.amirtlinov.notebook.preview" and certificate leaf[subject.OU] = "VUNH73AYPY"')
        self.assertTrue({"--verify", "--deep", "--strict"}.issubset(verification))
        self.assertEqual(self.cli.install_calls, [])

    def test_certificate_extraction_attaches_optional_prefix_to_option(self):
        self.assertEqual(self.execute("--build"), 0)
        extraction = next(call for call in self.cli.calls if any(value.startswith("--extract-certificates=") for value in call))
        self.assertEqual(extraction, ["/usr/bin/codesign", "--display",
                         "--extract-certificates=" + str(self.evidence / "signer-certificate-"), str(self.cli.app)])
        self.assertTrue((self.evidence / "signer-certificate-0").is_file())
        self.assertEqual(self.cli.install_calls, [])

    def test_canonical_bundle_cannot_be_installed(self):
        self.cli.info["CFBundleIdentifier"] = MODULE.CANONICAL
        self.refused('Bundle обязан')

    def test_preview_must_have_an_unambiguous_display_name(self):
        self.cli.info["CFBundleDisplayName"] = "Notebook"
        self.refused('Bundle обязан')

    def test_simulator_bundle_is_rejected(self):
        self.cli.info["CFBundleSupportedPlatforms"] = ["iPhoneSimulator"]
        self.refused('Нужен bundle физического iPad')

    def test_simulator_macho_cannot_hide_behind_ios_plist(self):
        self.cli.platform = "IOSSIMULATOR"
        self.refused('Mach-O')

    def test_mac_cpu_is_rejected(self):
        self.cli.architectures = "x86_64"
        self.refused('Бинарник не предназначен')

    def test_simulated_device_is_rejected_before_build(self):
        self.cli.device["properties"]["hardware"]["reality"] = "simulated"
        self.refused('Нужен физический iPad')
        self.assertEqual(len(self.cli.calls), 1)

    def test_other_device_is_rejected(self):
        self.cli.device["identifier"] = "other-device"
        self.refused('Подключён не согласованный iPad')

    def test_other_physical_udid_is_rejected(self):
        self.cli.device["properties"]["hardware"]["udid"] = "other-udid"
        self.refused('Подключён не согласованный iPad')

    def test_existing_preview_refuses_without_backup_or_replacement(self):
        self.cli.existing_preview = True
        self.refused('Notebook Lab уже установлен')
        self.assertFalse(any(call[1:2] == ["xcodebuild"] for call in self.cli.calls))

    def test_existing_preview_still_refuses_build_only_mode(self):
        self.cli.existing_preview = True
        with self.assertRaisesRegex(MODULE.ReleaseError, 'Notebook Lab уже установлен'):
            self.execute(mode="--build")
        self.assertFalse(any(call[1:2] == ["xcodebuild"] for call in self.cli.calls))
        self.assertFalse(self.cli.install_calls)

    def test_preview_appearing_during_build_is_not_replaced(self):
        self.cli.preview_during_build = True
        self.refused('Preview появился')

    def test_shared_keychain_is_rejected(self):
        self.cli.entitlements["keychain-access-groups"] = [MODULE.TEAM + "." + MODULE.CANONICAL]
        self.refused('собственную keychain-группу')

    def test_unknown_or_shared_container_entitlement_is_rejected(self):
        self.cli.entitlements["com.apple.security.application-groups"] = ["group.notebook"]
        self.refused('Shared containers')

    def test_foreign_signature_team_is_rejected(self):
        self.cli.bad_signature_team = True
        self.refused('чужой bundle или team')

    def test_failed_signature_verification_is_rejected(self):
        self.cli.fail_signature = True
        self.refused('Команда signature-verify')

    def test_profile_for_other_device_is_rejected(self):
        self.cli.profile["ProvisionedDevices"] = ["different"]
        self.refused('Provisioning не относится')

    def test_expired_profile_is_rejected(self):
        self.cli.profile["ExpirationDate"] = datetime.datetime.now() - datetime.timedelta(days=1)
        self.refused('Provisioning истёк')

    def test_profile_certificate_must_match_bundle_signer(self):
        self.cli.profile["DeveloperCertificates"] = [b"different signer"]
        self.refused('Сертификат bundle')

    def test_source_drift_prevents_install(self):
        self.cli.change_source = True
        self.refused('Исходники изменились при сборке')

    def test_private_build_source_drift_prevents_install(self):
        self.cli.change_snapshot = True
        self.refused('Исходники изменились при сборке')

    def test_bundle_drift_after_signature_check_prevents_install(self):
        self.cli.change_bundle = True
        self.refused('Подписанный bundle или исходники')

    def test_canonical_metadata_change_prevents_install(self):
        self.cli.change_canonical = True
        self.refused('Исходная установка изменилась')

    def test_failed_build_never_attempts_install(self):
        self.cli.fail_build = True
        self.refused('Команда build')

    def test_evidence_cannot_overwrite_a_previous_attempt(self):
        self.evidence.mkdir()
        (self.evidence / "accepted-input.txt").write_text("keep")
        self.refused('пустой каталог доказательств')
        self.assertEqual((self.evidence / "accepted-input.txt").read_text(), "keep")
        self.assertEqual(self.cli.calls, [])

    def test_evidence_cannot_be_the_source_root(self):
        with self.assertRaises(MODULE.ReleaseError): self.execute(evidence=self.source)
        self.assertEqual(self.cli.calls, [])

    def test_canonical_mac_path_is_never_a_destination(self):
        with self.assertRaises(MODULE.ReleaseError): self.execute(evidence=MODULE.CANONICAL_MAC / "evidence")
        self.assertEqual(self.cli.calls, [])

    def test_install_failure_is_not_retried_or_rolled_back(self):
        self.cli.fail_install = True
        with self.assertRaises(MODULE.ReleaseError): self.execute()
        self.assertEqual(len(self.cli.install_calls), 1)
        self.assertEqual(json.loads((self.evidence / "receipt.json").read_text())["status"], "installation-unconfirmed")

    def test_unexpected_install_receipt_is_not_a_success_or_retry(self):
        self.cli.bad_install_receipt = True
        with self.assertRaises(MODULE.ReleaseError): self.execute()
        self.assertEqual(len(self.cli.install_calls), 1)
        self.assertEqual(json.loads((self.evidence / "receipt.json").read_text())["status"], "installation-unconfirmed")

    def test_missing_installation_url_has_no_invented_bundle_url_fallback(self):
        self.cli.missing_installation_url = True
        with self.assertRaises(MODULE.ReleaseError) as caught: self.execute()
        self.assertIn("Адрес установки не совпал", str(caught.exception))
        self.assertEqual(len(self.cli.install_calls), 1)
        self.assertEqual(json.loads((self.evidence / "receipt.json").read_text())["status"], "installation-unconfirmed")

    def test_installation_url_must_equal_current_device_metadata(self):
        self.cli.wrong_installation_url = True
        with self.assertRaises(MODULE.ReleaseError) as caught: self.execute()
        self.assertIn("Адрес установки не совпал", str(caught.exception))
        self.assertEqual(len(self.cli.install_calls), 1)
        self.assertEqual(json.loads((self.evidence / "receipt.json").read_text())["status"], "installation-unconfirmed")


    def test_bundle_and_team_cannot_be_overridden_from_cli(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            MODULE.main(["--bundle-id", MODULE.CANONICAL], self.source, runner=self.cli)
        self.assertEqual(self.cli.calls, [])

    def test_existing_preview_remains_refused_on_next_invocation(self):
        self.assertEqual(self.execute(), 0)
        first_count = len(self.cli.install_calls)
        with self.assertRaises(MODULE.ReleaseError) as caught:
            self.execute(evidence=self.root / "second-evidence")
        self.assertIn("Notebook Lab уже установлен", str(caught.exception))
        self.assertEqual(len(self.cli.install_calls), first_count)

    def test_product_default_remains_canonical_and_mac_name_unchanged(self):
        spec = (ROOT / "Applications/project.yml").read_text()
        self.assertEqual(spec.count("CFBundleDisplayName: $(NOTEBOOK_DISPLAY_NAME)"), 1)
        self.assertEqual(spec.count("NOTEBOOK_DISPLAY_NAME: Notebook"), 1)
        self.assertIn("PRODUCT_BUNDLE_IDENTIFIER: com.amirtlinov.notebook\n", spec)
        self.assertIn("CFBundleDisplayName: Notebook\n", spec.split("  NotebookMac:", 1)[1])


if __name__ == "__main__":
    unittest.main(verbosity=2)

#!/usr/bin/env python3
"""Execute release guards against fabricated tools/evidence, never a real device."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Applications"))
import notebook_release as release

spec = importlib.util.spec_from_file_location("preview_fixture", ROOT / "Tests/PreviewInstaller/run.py")
preview = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preview)
TOOLCHAIN = {name: "fixture " + name + " version" for name in
             ("xcode", "swift", "iphoneosSDK", "macosSDK", "xcodegen", "node", "npm")}


class PairCLI(preview.FakeCLI):
    def __init__(self, source, verification):
        super().__init__(source)
        self.verification = verification
        self.mac = None
        self.mac_info = {"CFBundleIdentifier": release.MAC_BUNDLE, "LSUIElement": True,
            "CFBundlePackageType": "APPL", "DTPlatformName": "macosx", "CFBundleExecutable": "Notebook",
            "CFBundleShortVersionString": self.info["CFBundleShortVersionString"],
            "CFBundleVersion": self.info["CFBundleVersion"], "LSMinimumSystemVersion": "27.0"}
        self.mac_entitlements = {"com.apple.security.get-task-allow": True}
        self.mac_signature_team = release.TEAM
        self.mac_platform = "MACOS"
        self.mac_architectures = "arm64"
        self.mac_sidecar = True
        self.mac_adhoc = False
        self.mac_fail = False
        self.mutate_proof = False
        self.mutate_ipad = False
        self.mutate_mac = False
        self.toolchain = dict(TOOLCHAIN)

    def __call__(self, argv, cwd=None, stdout=None, stderr=None, timeout=None):
        label = Path(stdout.name).name.removesuffix(".stdout.log")
        output, error, exit_code = b"", b"", 0
        if label.startswith("toolchain-"):
            output = self.toolchain[label.removeprefix("toolchain-").removeprefix("after-")].encode()
        elif label == "dependencies":
            assert argv[1:] == ["ci", "--ignore-scripts"]
        elif label == "build-mac":
            if self.mac_fail:
                exit_code = 1
            else:
                self.mac = Path(argv[argv.index("-derivedDataPath") + 1]) / "Build/Products/Release/Notebook.app"
                (self.mac / "Contents/MacOS").mkdir(parents=True)
                (self.mac / "Contents/Info.plist").write_bytes(plistlib.dumps(self.mac_info))
                (self.mac / "Contents/MacOS/Notebook").write_bytes(b"fixture Mac executable")
                if self.mac_sidecar:
                    tools = self.mac / "Contents/Resources/NotebookTools"
                    (tools / "dist").mkdir(parents=True)
                    (tools / "dist/index.mjs").write_text("// bundled fixture MCP\n")
                    (tools / "package.json").write_text('{"type":"module"}\n')
                if self.mutate_proof:
                    (self.verification / "core.log").write_text("changed proof\n")
                if self.mutate_ipad:
                    (self.app / "Notebook").write_bytes(b"changed iPad after signature")
        elif label == "mac-signature-verify":
            exit_code = 1 if self.fail_signature else 0
        elif label == "mac-signature-details":
            error = ("Identifier=" + release.MAC_BUNDLE + "\nTeamIdentifier=" + self.mac_signature_team
                + "\nAuthority=Apple Development: Fixture\nCDHash=" + "b" * 40 + "\n"
                + ("Signature=adhoc\n" if self.mac_adhoc else "")).encode()
        elif label == "mac-signature-entitlements":
            output = plistlib.dumps(self.mac_entitlements)
        elif label == "mac-binary-architectures":
            output = self.mac_architectures.encode()
        elif label == "mac-binary-platform":
            output = (" platform " + self.mac_platform + "\n").encode()
        elif label == "mac-binary-uuids":
            output = b"UUID: 11111111-2222-3333-4444-555555555555 (arm64) fixture\n"
            if self.mutate_mac:
                (self.mac / "Contents/MacOS/Notebook").write_bytes(b"changed Mac after signature")
        else:
            return super().__call__(argv, cwd=cwd, stdout=stdout, stderr=stderr, timeout=timeout)
        self.calls.append(list(argv))
        stdout.write(output)
        stderr.write(error)
        return subprocess.CompletedProcess(argv, exit_code)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="notebook-release-contract-")
        self.root = Path(self.temp.name).resolve()
        self.source = self.root / "source"
        for directory in ("Sources/Core", "Tests/CoreTests", "Applications", "MCP"):
            (self.source / directory).mkdir(parents=True)
        for file in ("Package.swift", "verify.sh", "Sources/Core/value.swift", "Tests/CoreTests/test.swift",
                     "MCP/package.json", "MCP/package-lock.json", "MCP/tool.ts"):
            (self.source / file).write_text("// fixture input " + file + "\n")
        (self.source / "Applications/project.yml").write_text((ROOT / "Applications/project.yml").read_text())
        (self.source / "Applications/notebook_release.py").write_bytes((ROOT / "Applications/notebook_release.py").read_bytes())
        self.verification = self.root / "verification"
        self.verification.mkdir()
        for file in release.VERIFICATION_FILES:
            (self.verification / file).write_bytes(b"fabricated unit-test evidence; NOT a verify.sh PASS\n")
        for platform in ("mac", "ipad"):
            (self.verification / (platform + ".xcresult")).mkdir()
            (self.verification / (platform + ".xcresult") / "Data").write_bytes(b"fabricated test result")
            release.write_json(self.verification / (platform + "-summary.json"), {
                "passedTests": 1, "failedTests": 0, "skippedTests": 0, "runtimeWarnings": []})
        self.before = release.source_inputs(self.source)
        release.write_json(self.verification / "source-before.json", self.before)
        release.write_json(self.verification / "toolchain.json", TOOLCHAIN)
        release.write_json(self.verification / "toolchain-after.json", TOOLCHAIN)
        release.finish_verification(self.source, self.verification)
        self.evidence = self.root / "build"
        self.cli = PairCLI(self.source, self.verification)

    def tearDown(self):
        self.temp.cleanup()

    def build(self):
        with patch.object(release.shutil, "which", side_effect=lambda name: "/fixture/" + name):
            return release.build_verified_pair(self.source, self.verification, self.evidence, self.cli)

    def refused(self, message, before_commands=False):
        with self.assertRaises(release.ReleaseError) as caught:
            self.build()
        self.assertIn(message, str(caught.exception))
        self.assertFalse(self.cli.install_calls)
        if before_commands:
            self.assertEqual(self.cli.calls, [])
        elif self.evidence.exists():
            self.assertEqual(release.read_json(self.evidence / "build.json")["status"], "refused")

    def test_builds_both_signed_apps_from_one_snapshot_without_install_or_archive_access(self):
        self.cli.existing_preview = True
        receipt = self.build()
        self.assertEqual(receipt["status"], "verified-build")
        self.assertFalse(receipt["installationAttempted"])
        self.assertEqual(set(receipt["apps"]), {"iPad", "mac"})
        self.assertEqual(release.source_inputs(self.evidence / "source"), self.before)
        self.assertEqual(release.source_inputs(self.source), self.before)
        builds = [call for call in self.cli.calls if "xcodebuild" in call and "build" == call[-1]]
        self.assertEqual(len(builds), 2)
        self.assertIn("PRODUCT_BUNDLE_IDENTIFIER=" + release.BUNDLE, builds[0])
        self.assertIn("PRODUCT_BUNDLE_IDENTIFIER=" + release.MAC_BUNDLE, builds[1])
        for argv in builds:
            self.assertIn("CODE_SIGN_IDENTITY=Apple Development", argv)
            self.assertIn("SWIFT_OPTIMIZATION_LEVEL=-O", argv)
            self.assertIn(str(self.evidence / "source/Applications/Notebook.xcodeproj"), argv)
        device_calls = [call for call in self.cli.calls if "devicectl" in call]
        self.assertEqual(len(device_calls), 1)
        self.assertEqual(device_calls[0][1:5], ["devicectl", "device", "info", "details"])

    def test_previous_directory_is_not_reused(self):
        receipt = self.build()
        calls = list(self.cli.calls)
        with self.assertRaisesRegex(release.ReleaseError, "новый каталог"):
            self.build()
        self.assertEqual(self.cli.calls, calls)
        self.assertEqual(release.read_json(self.evidence / "build.json"), receipt)

    def test_evidence_cannot_be_inside_verification(self):
        self.evidence = self.verification / "build"
        self.refused("вне исходников", before_commands=True)

    def test_evidence_cannot_be_inside_sources(self):
        self.evidence = self.source / "Applications/build"
        self.refused("вне исходников", before_commands=True)

    def test_missing_completion_receipt_cannot_be_inferred_from_old_summaries(self):
        (self.verification / "verification.json").unlink()
        self.refused("JSON-файла", before_commands=True)

    def test_changed_mcp_source_invalidates_verification(self):
        (self.source / "MCP/tool.ts").write_text("changed MCP\n")
        self.refused("другой набор", before_commands=True)

    def test_changed_verification_route_invalidates_verification(self):
        (self.source / "verify.sh").write_text("exit 0\n")
        self.refused("другой набор", before_commands=True)

    def test_running_builder_must_belong_to_the_verified_source(self):
        (self.source / "Applications/notebook_release.py").write_text("different build owner\n")
        self.refused("Сборщик должен принадлежать", before_commands=True)

    def test_added_input_invalidates_verification_even_without_git(self):
        (self.source / "Applications/new.swift").write_text("let new = true\n")
        self.refused("другой набор", before_commands=True)

    def test_deleted_input_invalidates_verification(self):
        (self.source / "MCP/tool.ts").unlink()
        self.refused("другой набор", before_commands=True)

    def test_executable_mode_is_part_of_input_identity(self):
        (self.source / "verify.sh").chmod(0o755)
        self.refused("другой набор", before_commands=True)

    def test_root_dependency_resolution_is_part_of_input_identity(self):
        (self.source / "Package.resolved").write_text("{}\n")
        self.refused("другой набор", before_commands=True)

    def test_snapshot_does_not_depend_on_parent_git_checkout(self):
        subprocess.run(["git", "init", "--quiet", str(self.root)], check=True)
        self.assertEqual(release.source_inputs(self.source), self.before)
        self.build()

    def test_generated_files_and_dependencies_do_not_change_input_identity(self):
        for file in ("Applications/Notebook.xcodeproj/project.pbxproj", "Applications/iPad/Info.plist",
                     "Applications/Mac/Info.plist", "Applications/DerivedDataRelease/output", "MCP/node_modules/lib.js",
                     "Tests/Harness/node_modules/lib.js", "Applications/__pycache__/cache.pyc"):
            path = self.source / file
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("generated output\n")
        self.assertEqual(release.source_inputs(self.source), self.before)
        self.build()

    def test_symlink_source_file_is_rejected(self):
        (self.source / "MCP/link.ts").symlink_to(self.source / "MCP/tool.ts")
        self.refused("обычный файл", before_commands=True)

    def test_symlink_source_directory_is_rejected(self):
        (self.source / "MCP/linked").symlink_to(self.source / "Sources", target_is_directory=True)
        self.refused("Ссылка", before_commands=True)

    def test_special_source_file_is_rejected_without_reading(self):
        os.mkfifo(self.source / "MCP/input.fifo")
        self.refused("обычный файл", before_commands=True)

    def test_changed_result_payload_invalidates_evidence(self):
        (self.verification / "ipad.xcresult/Data").write_bytes(b"different xcresult")
        self.refused("Свидетельства", before_commands=True)

    def test_changed_log_invalidates_evidence(self):
        (self.verification / "core.log").write_text("different log\n")
        self.refused("Свидетельства", before_commands=True)

    def test_missing_required_log_invalidates_evidence(self):
        (self.verification / "mcp-smoke.log").unlink()
        self.refused("обязательные свидетельства", before_commands=True)

    def test_symlink_result_is_rejected(self):
        (self.verification / "external-result").symlink_to(self.source / "Package.swift")
        self.refused("ссылаться", before_commands=True)

    def test_failed_skipped_warning_or_empty_native_run_cannot_finish(self):
        for field, value in (("failedTests", 1), ("skippedTests", 1), ("runtimeWarnings", [{}]), ("passedTests", 0)):
            with self.subTest(field=field):
                path = self.verification / "mac-summary.json"
                summary = {"passedTests": 1, "failedTests": 0, "skippedTests": 0, "runtimeWarnings": []}
                summary[field] = value
                release.write_json(path, summary)
                (self.verification / "verification.json").unlink(missing_ok=True)
                with self.assertRaises(release.ReleaseError):
                    release.finish_verification(self.source, self.verification)
                self.assertFalse((self.verification / "verification.json").exists())

    def test_toolchain_mismatch_is_refused_before_build(self):
        self.cli.toolchain["xcode"] = "other Xcode"
        self.refused("Инструменты сборки")
        self.assertFalse(any(call[-1] == "build" for call in self.cli.calls))

    def test_verification_toolchain_change_cannot_finish(self):
        (self.verification / "verification.json").unlink()
        release.write_json(self.verification / "toolchain-after.json", {**TOOLCHAIN, "xcode": "other version"})
        with self.assertRaisesRegex(release.ReleaseError, "Инструменты изменились"):
            release.finish_verification(self.source, self.verification)
        self.assertFalse((self.verification / "verification.json").exists())

    def test_source_change_cannot_finish_verification(self):
        (self.verification / "verification.json").unlink()
        (self.source / "MCP/tool.ts").write_text("changed during verify\n")
        with self.assertRaisesRegex(release.ReleaseError, "Исходники изменились"):
            release.finish_verification(self.source, self.verification)
        self.assertFalse((self.verification / "verification.json").exists())

    def test_input_change_during_build_is_refused(self):
        # Existing first-install fixture changes this exact file during xcodebuild.
        path = self.source / "Sources/NotebookCore/Test.swift"
        path.parent.mkdir()
        path.write_text("initial input\n")
        (self.verification / "verification.json").unlink()
        release.write_json(self.verification / "source-before.json", release.source_inputs(self.source))
        release.finish_verification(self.source, self.verification)
        self.cli.change_source = True
        self.refused("Исходники изменились")

    def test_proof_change_during_build_is_refused(self):
        self.cli.mutate_proof = True
        self.refused("Свидетельства")

    def test_ipad_change_after_signature_is_refused(self):
        self.cli.mutate_ipad = True
        self.refused("Подписанная пара изменилась")

    def test_mac_change_during_signature_check_is_refused(self):
        self.cli.mutate_mac = True
        self.refused("Mac bundle изменился")

    def test_foreground_mac_is_refused(self):
        self.cli.mac_info["LSUIElement"] = False
        self.refused("безоконный")

    def test_mac_without_bundled_mcp_is_refused(self):
        self.cli.mac_sidecar = False
        self.refused("отсутствует установленный MCP")

    def test_mac_foreign_signer_is_refused(self):
        self.cli.mac_signature_team = "other"
        self.refused("чужой bundle или team")

    def test_mac_adhoc_signature_is_refused(self):
        self.cli.mac_adhoc = True
        self.refused("настоящая Apple Development")

    def test_mac_foreign_keychain_is_refused(self):
        self.cli.mac_entitlements["keychain-access-groups"] = [release.APP_ID]
        self.refused("чужую идентичность Keychain")

    def test_mac_unknown_entitlement_is_refused(self):
        self.cli.mac_entitlements["com.apple.security.application-groups"] = ["group.notebook"]
        self.refused("неизвестные права")

    def test_mac_wrong_macho_is_refused(self):
        self.cli.mac_platform = "IOS"
        self.refused("Mach-O helper")

    def test_mac_wrong_architecture_is_refused(self):
        self.cli.mac_architectures = "x86_64"
        self.refused("arm64 helper")

    def test_pair_version_mismatch_is_refused(self):
        self.cli.mac_info["CFBundleVersion"] = "different"
        self.refused("разными версиями")

    def test_failed_second_build_leaves_refusal_not_partial_release(self):
        self.cli.mac_fail = True
        self.refused("Команда build-mac")
        self.assertTrue(self.cli.app.is_dir())

    def test_no_install_delete_archive_or_force_cli_exists(self):
        for option in ("--install", "--delete", "--archive", "--force", "--skip-verification"):
            with self.subTest(option=option), patch.object(sys, "argv", [str(ROOT / "Applications/notebook_release.py"),
                 "build-pair", "--source-root", str(self.source), "--evidence-dir", str(self.evidence),
                 "--verification-dir", str(self.verification), option]), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit):
                    release.main()
        self.assertEqual(self.cli.calls, [])


if __name__ == "__main__":
    unittest.main(verbosity=2)

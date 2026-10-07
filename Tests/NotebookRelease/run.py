#!/usr/bin/env python3
"""Execute release guards and an isolated AppKit lifecycle, never live content or a device."""
import contextlib
import ctypes
import errno
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
from types import SimpleNamespace

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Applications"))
import notebook_release as release
import notebook_verification as verify
import typesetter_fixture
import typescript_fixture
import codex_fixture
from test_codex import CodexPackagingTests
from cli_fixture import FakeCLI
from test_typesetter import TypesetterPackagingTests
from test_runtime_lifecycle import RuntimeLifecycleTests

TOOLCHAIN = {name: "fixture " + name + " version" for name in
             ("python", "xcode", "swift", "iphoneosSDK", "macosSDK", "xcodegen", "node", "npm")}


class PairCLI(FakeCLI):
    def __init__(self, source, verification):
        super().__init__(source)
        self.verification = verification
        self.codex_runtime = release.notebook_codex.admitted_runtime("arm64", self.source / "Applications/NotebookCodexRuntime.lock.json")
        self.codex_files = codex_fixture.payload()
        self.mac = None
        self.mac_info = {"CFBundleIdentifier": release.MAC_BUNDLE, "LSUIElement": True,
            "NotebookPluginRuntime": True, "CFBundleName": "NotebookRuntime",
            "NotebookScriptService": "com.amirtlinov.notebook.script-service",
            "NotebookMarkupService": "com.amirtlinov.notebook.markup-service",
            "NotebookCloudContainer": release.CLOUD_CONTAINER,
            "CFBundlePackageType": "APPL", "DTPlatformName": "macosx", "CFBundleExecutable": "NotebookRuntime",
            "CFBundleShortVersionString": self.info["CFBundleShortVersionString"],
            "CFBundleVersion": self.info["CFBundleVersion"], "LSMinimumSystemVersion": "27.0"}
        self.mac_entitlements = {"com.apple.security.get-task-allow": True, **release.cloud_entitlements(mac=True),
            "com.apple.application-identifier": release.TEAM + "." + release.MAC_BUNDLE,
            "com.apple.developer.team-identifier": release.TEAM}
        self.mac_profile = {**self.profile, "Platform": ["OSX"], "ProvisionedDevices": ["00006050-0123456789ABCDEF"],
            "Entitlements": {**release.cloud_entitlements(mac=True), "com.apple.application-identifier": release.TEAM + "." + release.MAC_BUNDLE,
                             "com.apple.developer.team-identifier": release.TEAM}}
        self.mac_signature_team = release.TEAM
        self.mac_platform = "MACOS"
        self.mac_architectures = "arm64"
        self.mac_sidecar = True
        self.mac_adhoc = False
        self.mac_fail = False
        self.package_fail = False
        self.mutate_packaged_runtime = False
        self.codex_prepare_fail = False
        self.changed_codex_helper = False
        self.forged_codex_report = False
        self.xpc_rights = {"com.apple.security.app-sandbox": True}
        self.missing_xpc = False
        self.missing_tex = False
        self.changed_tex = False
        self.typescript_rights = {"com.apple.security.app-sandbox": True, "com.apple.security.inherit": True}
        self.missing_typescript = False
        self.changed_typescript = False
        self.linked_typescript_declaration = False
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
        elif label.startswith("typesetter-resources-"):
            assert "--prepare" in argv and "--platform" in argv and "--stage" in argv
        elif label == "codex-resources":
            snapshot = Path(cwd)
            assert argv == [sys.executable, "-B", str(snapshot / "Applications/prepare_notebook_codex.py"),
                            "--prepare", "--stage-root", str(self.source / ".build/notebook-codex-runtimes")]
            exit_code = 1 if self.codex_prepare_fail else 0
            if not exit_code:
                stage = self.source / ".build/notebook-codex-runtimes" / release.notebook_codex.identity(self.codex_runtime)["manifestSHA256"]
                if not stage.exists(): codex_fixture.stage(stage, self.codex_runtime, self.codex_files)
                report = codex_fixture.report(stage, self.codex_runtime)
                if self.forged_codex_report: report["identity"]["manifestSHA256"] = "0" * 64
                output = json.dumps(report).encode()
        elif label == "codex-runtime-check":
            assert argv[:4] == [sys.executable, "-B", str(Path(cwd) / "Applications/prepare_notebook_codex.py"), "--check"]
            try:
                output = json.dumps(codex_fixture.report(Path(argv[-1]), self.codex_runtime)).encode()
            except (OSError, RuntimeError) as failure:
                exit_code, error = 1, str(failure).encode()
        elif label == "typescript-resources":
            assert "--prepare" in argv and "--stage-root" in argv
            output = json.dumps({"status": "ready", "stage": str(self.source / ".build/fixture-typescript-runtime")}).encode()
        elif label == "surface-resources":
            assert Path(cwd) == self.source
            assert argv == ["node", str(self.source / "MCP/build-surface.mjs"), "--stage", str(self.source / ".build/surface")]
        elif label == "build-mac":
            assert "NOTEBOOK_CODEX_RUNTIME=" + str(self.source / ".build/notebook-codex-runtimes" / release.notebook_codex.identity(self.codex_runtime)["manifestSHA256"]) in argv
            assert "NOTEBOOK_SURFACE_STAGE=" + str(self.source / ".build/surface") in argv
            if self.mac_fail:
                exit_code = 1
            else:
                assert argv[argv.index("-scheme") + 1] == "NotebookRuntime"
                self.mac = Path(argv[argv.index("-derivedDataPath") + 1]) / "Build/Products/Release/NotebookRuntime.app"
                (self.mac / "Contents/MacOS").mkdir(parents=True)
                (self.mac / "Contents/Info.plist").write_bytes(plistlib.dumps(self.mac_info))
                (self.mac / "Contents/MacOS/NotebookRuntime").write_bytes(b"fixture Mac executable")
                (self.mac / "Contents/embedded.provisionprofile").write_bytes(b"fixture signed Mac profile")
                if not self.missing_xpc:
                    for name, bundle_id, resource in (
                        ("NotebookScriptService", self.mac_info["NotebookScriptService"], "notebook-sdk.js"),
                        ("NotebookMarkupService", self.mac_info["NotebookMarkupService"], "notebook-markup.js")):
                        xpc = self.mac / "Contents/XPCServices" / (name + ".xpc")
                        (xpc / "Contents/MacOS").mkdir(parents=True)
                        (xpc / "Contents/Resources").mkdir()
                        (xpc / "Contents/Info.plist").write_bytes(plistlib.dumps({
                            "CFBundleIdentifier": bundle_id, "CFBundlePackageType": "XPC!", "CFBundleExecutable": name,
                            "XPCService": {"ServiceType": "Application"}}))
                        (xpc / "Contents/MacOS" / name).write_bytes(b"fabricated service executable")
                        (xpc / "Contents/Resources" / resource).write_text("// fabricated service SDK")
                        if name == "NotebookMarkupService":
                            if not self.missing_typescript:
                                typescript_fixture.stage(xpc / "Contents")
                                if self.changed_typescript:
                                    (xpc / "Contents" / release.notebook_typescript.RESOURCES / "lib.es5.d.ts").write_text("changed declaration")
                            if self.linked_typescript_declaration:
                                link = xpc / "Contents" / release.notebook_typescript.RESOURCES / "lib.d.ts"
                                link.unlink(); link.symlink_to("/tmp/foreign-lib.d.ts")
                tex = typesetter_fixture.stage(self.mac / "Contents/Resources/NotebookTypesetter")
                if self.missing_tex: (tex / "texlive.zip").unlink()
                if self.changed_tex: (tex / "texlive.zip").write_bytes(b"changed distribution")
                if self.mac_sidecar:
                    tools = self.mac / "Contents/Resources/NotebookTools"
                    (tools / "dist").mkdir(parents=True)
                    (tools / "dist/index.mjs").write_text("// bundled fixture MCP\n")
                    (tools / "dist/launch-runtime.mjs").write_text("// bundled fixture launcher\n")
                    (tools / "package.json").write_text('{"type":"module"}\n')
                    codex_fixture.stage(self.mac / "Contents/Resources/CodexRuntime", self.codex_runtime, self.codex_files)
                    if self.changed_codex_helper:
                        helper = self.mac / "Contents/Resources/CodexRuntime/codex/codex-resources/helper.dat"
                        helper.write_bytes(b"x" + helper.read_bytes()[1:])
                if self.mutate_proof:
                    (self.verification / "core.log").write_text("changed proof\n")
                if self.mutate_ipad:
                    (self.app / "Notebook").write_bytes(b"changed iPad after signature")
        elif label == "package-plugin":
            snapshot = Path(cwd)
            plugin = snapshot.parent / "plugin/notebook"
            assert argv == ["/fixture/node", str(snapshot / "MCP/package-plugin-runtime.mjs"),
                            str(self.mac), str(plugin)]
            assert json.loads((plugin / "plugin.json").read_text())["name"] == "notebook"
            if self.package_fail:
                exit_code = 1
            else:
                bundled = plugin / "runtime/NotebookRuntime.app"
                shutil.copytree(self.mac, bundled, symlinks=True)
                if self.mutate_packaged_runtime:
                    (bundled / "Contents/MacOS/NotebookRuntime").write_bytes(b"changed during packaging")
        elif label == "mac-provisioning-profile":
            output = plistlib.dumps(self.mac_profile)
        elif label == "mac-provisioning-device":
            output = json.dumps({"SPHardwareDataType": [{"platform_UUID": "11111111-2222-3333-4444-555555555555",
                "provisioning_UDID": "00006050-0123456789ABCDEF"}]}).encode()
        elif label == "mac-signature-certificates":
            prefix = next(arg.split("=", 1)[1] for arg in argv if str(arg).startswith("--extract-certificates="))
            Path(prefix + "0").write_bytes(self.certificate)
        elif label == "mac-signature-verify":
            exit_code = 1 if self.fail_signature else 0
        elif label.startswith("typescript-"):
            if label.endswith("-details"):
                error = ("Identifier=com.amirtlinov.notebook.typescript-compiler\nTeamIdentifier=" + release.TEAM
                    + "\nAuthority=Apple Development: Fixture\nCDHash=" + "f" * 40 + "\n").encode()
            elif label.endswith("-rights"):
                output = plistlib.dumps(self.typescript_rights)
        elif label.startswith("xpc-"):
            name = label.split("-")[1]
            bundle_id = self.mac_info[name]
            if label.endswith("-details"):
                error = ("Identifier=" + bundle_id + "\nTeamIdentifier=" + release.TEAM
                    + "\nAuthority=Apple Development: Fixture\nCDHash=" + "c" * 40 + "\n").encode()
            elif label.endswith("-entitlements"):
                output = plistlib.dumps(self.xpc_rights)
            elif label.endswith("-architecture"):
                output = b"arm64"
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
                (self.mac / "Contents/MacOS/NotebookRuntime").write_bytes(b"changed Mac after signature")
        else:
            return super().__call__(argv, cwd=cwd, stdout=stdout, stderr=stderr, timeout=timeout)
        self.calls.append(list(argv))
        stdout.write(output)
        stderr.write(error)
        return subprocess.CompletedProcess(argv, exit_code)


class CloudRightsTests(unittest.TestCase):
    def apple_profile(self, mac):
        # Shape observed in Apple's automatic CloudKit provisioning profile.
        return {**release.cloud_entitlements(mac),
                "com.apple.developer.icloud-services": "*",
                "com.apple.developer.icloud-container-environment": ["Production", "Development"]}

    def test_apple_service_wildcard_authorizes_exact_cloudkit_signature(self):
        for mac in (False, True):
            with self.subTest(mac=mac):
                release.validate_cloud_rights(release.cloud_entitlements(mac), self.apple_profile(mac), mac)

    def test_explicit_service_allowlist_authorizes_exact_cloudkit_signature(self):
        for mac in (False, True):
            with self.subTest(mac=mac):
                profile = self.apple_profile(mac)
                profile["com.apple.developer.icloud-services"] = ["CloudKit", "CloudDocuments"]
                release.validate_cloud_rights(release.cloud_entitlements(mac), profile, mac)

    def test_profile_wildcard_never_expands_the_signed_app_rights(self):
        for mac in (False, True):
            claims = {
                "com.apple.developer.icloud-services": ["*", ["*"], ["CloudKit", "CloudDocuments"], []],
                "com.apple.developer.icloud-container-identifiers": [["*"], ["iCloud.foreign"]],
                "com.apple.developer.icloud-container-environment": ["Development", "*"],
                "com.apple.developer.aps-environment" if mac else "aps-environment": ["production", "*"],
            }
            for key, values in claims.items():
                for value in values:
                    with self.subTest(mac=mac, key=key, value=value), self.assertRaises(release.ReleaseError):
                        signed = {**release.cloud_entitlements(mac), key: value}
                        release.validate_cloud_rights(signed, self.apple_profile(mac), mac)

    def test_service_wildcard_still_requires_explicit_container_and_environment_authority(self):
        for mac in (False, True):
            claims = {
                "com.apple.developer.icloud-container-identifiers": ["*", ["*"], ["iCloud.foreign"], []],
                "com.apple.developer.icloud-container-environment": ["Development", ["Development"], "*"],
                "com.apple.developer.aps-environment" if mac else "aps-environment": ["production", "*"],
            }
            for key, values in claims.items():
                for value in values:
                    with self.subTest(mac=mac, key=key, value=value), self.assertRaises(release.ReleaseError):
                        profile = {**self.apple_profile(mac), key: value}
                        release.validate_cloud_rights(release.cloud_entitlements(mac), profile, mac)

    def test_missing_or_wrong_service_authority_is_refused(self):
        for mac in (False, True):
            for value in (None, [], ["CloudDocuments"], "CloudKit", True):
                with self.subTest(mac=mac, value=value), self.assertRaises(release.ReleaseError):
                    profile = self.apple_profile(mac)
                    if value is None:
                        del profile["com.apple.developer.icloud-services"]
                    else:
                        profile["com.apple.developer.icloud-services"] = value
                    release.validate_cloud_rights(release.cloud_entitlements(mac), profile, mac)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="notebook-release-contract-")
        self.root = Path(self.temp.name).resolve()
        self.source = self.root / "source"
        for directory in ("Sources/Core", "Sources/NotebookMarkupService", "Tests/CoreTests", "Applications", "MCP"):
            (self.source / directory).mkdir(parents=True)
        for file in ("Package.swift", "verify.sh", "Sources/Core/value.swift", "Tests/CoreTests/test.swift",
                     "MCP/package.json", "MCP/package-lock.json", "MCP/tool.ts"):
            (self.source / file).write_text("// fixture input " + file + "\n")
        (self.source / "Applications/project.yml").write_text((ROOT / "Applications/project.yml").read_text())
        (self.source / "Applications/notebook_release.py").write_bytes((ROOT / "Applications/notebook_release.py").read_bytes())
        manifest = self.source / "MCP/plugin/notebook/plugin.json"
        manifest.parent.mkdir(parents=True)
        manifest.write_text(json.dumps({"name": "notebook", "version": "0.2.0"}))
        (self.source / "MCP/package-plugin-runtime.mjs").write_text("// fixture runtime packager\n")
        (self.source / "MCP/install-plugin.mjs").write_text("// fixture plugin installer\n")
        def pin(data):
            import hashlib
            return {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
        for name, value in {"LOCK": typesetter_fixture.LOCK, "input_digest": lambda: typesetter_fixture.IDENTITY}.items():
            resource_patch = patch.object(release.notebook_typesetter, name, value)
            resource_patch.start(); self.addCleanup(resource_patch.stop)
        for key, value in typescript_fixture.inputs(self.source).items():
            type_patch = patch.object(release.notebook_typescript, key, value)
            type_patch.start(); self.addCleanup(type_patch.stop)
        codex_fixture.source(self.source)
        self.verification = self.root / "verification"
        self.verification.mkdir()
        # This is a selected, fabricated contract for release guard tests.
        # Router tests separately exercise real discovery and runner parsing.
        script = self.source / "Applications/test-load-fixture.sh"
        script.write_text("#!/bin/sh\nexit 0\n")
        plan = {"format": 2, "sourceRoot": str(self.source), "selectionMode": "explicit-only", "profiles": [],
                "unclassified": [], "manualSelection": True,
                "checks": {"core": [], "mac": [], "ipad": [], "commands": ["load-fixture"]}}
        execution = {"format": 1, "planned": ["load-fixture"], "executed": ["load-fixture"], "skipped": [], "failed": []}
        release.write_json(self.verification / "selection.json", plan)
        release.write_json(self.verification / "completed.json", {"format": 2, "checks": {"load-fixture": execution}})
        release.write_json(self.verification / "load-fixture-inventory.json", {"format": 1, "tests": ["load-fixture"]})
        release.write_json(self.verification / "load-fixture-execution.json", execution)
        release.write_json(self.verification / "commands.json", [{"label": "load-fixture", "argv": [str(script)], "cwd": str(self.source), "exitCode": 0}])
        nested = self.verification / "runner-payload"; nested.mkdir()
        (nested / "Data").write_bytes(b"fabricated nested test result")
        (self.verification / "core.log").write_bytes(b"fabricated unit-test evidence; NOT a verify.sh PASS\n")
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

    def test_missing_typescript_resources_refuse_release(self):
        self.cli.missing_typescript = True
        self.refused("TypeScript compiler resource/source contract failed")

    def test_changed_typescript_declarations_refuse_release(self):
        self.cli.changed_typescript = True
        self.refused("TypeScript resource hash mismatch")

    def test_typescript_declarations_cannot_be_symlinks(self):
        self.cli.linked_typescript_declaration = True
        self.refused("Ссылки не входят в подписанный bundle")

    def test_typescript_child_cannot_gain_network_rights(self):
        self.cli.typescript_rights["com.apple.security.network.client"] = True
        self.refused("TypeScript child must inherit only")

    def test_builds_signed_ipad_and_plugin_runtime_from_one_snapshot_without_install_or_archive_access(self):
        for override in (None, self.root / "private runtime"):
            with self.subTest(runtime=override), patch.dict(os.environ):
                os.environ.pop("NOTEBOOK_TYPESETTER_RUNTIME", None)
                if override is not None:
                    os.environ["NOTEBOOK_TYPESETTER_RUNTIME"] = str(override)
                expected_stage = str(override or self.source / ".build/notebook-typesetter-runtime")
                self.evidence = self.root / ("build-private" if override else "build-default")
                self.cli = PairCLI(self.source, self.verification)
                self.cli.existing_preview = True
                receipt = self.build()
                self.assertEqual(receipt["status"], "verified-build")
                self.assertEqual(receipt["codexRuntime"], release.notebook_codex.identity(self.cli.codex_runtime))
                self.assertEqual(receipt["apps"]["mac"]["signature"]["codexRuntime"], receipt["codexRuntime"])
                self.assertFalse(receipt["installationAttempted"])
                self.assertEqual(set(receipt["apps"]), {"iPad", "mac"})
                self.assertEqual(receipt["plugin"], {"path": "plugin", "version": "0.2.0"})
                self.assertEqual(receipt["apps"]["mac"]["path"], "plugin/notebook/runtime/NotebookRuntime.app")
                self.assertEqual(release.app_manifest(self.evidence / receipt["apps"]["mac"]["path"]),
                                 release.app_manifest(self.cli.mac))
                markup = self.cli.mac / "Contents/XPCServices/NotebookMarkupService.xpc/Contents"
                compiler = markup / release.notebook_typescript.BINARY
                self.assertTrue(compiler.is_file())
                self.assertFalse((compiler.parent / "lib.d.ts").is_symlink())
                self.assertFalse((markup / "Helpers").exists())
                self.assertEqual(release.source_inputs(self.evidence / "source"), self.before)
                self.assertEqual(release.source_inputs(self.source), self.before)
                builds = [call for call in self.cli.calls if "xcodebuild" in call and "build" == call[-1]]
                self.assertEqual(len(builds), 2)
                typesetter = [call for call in self.cli.calls if any(str(arg).endswith("/prepare_notebook_typesetter.py") for arg in call)]
                self.assertEqual([(argv[argv.index("--platform") + 1], argv[argv.index("--stage") + 1]) for argv in typesetter],
                                 [("iphoneos", expected_stage), ("macosx", expected_stage)])
                preparation = [call for call in self.cli.calls if "--prepare" in call and any(str(arg).endswith("/prepare_notebook_codex.py") for arg in call)]
                self.assertEqual(len(preparation), 1)
                self.assertLess(self.cli.calls.index(preparation[0]), self.cli.calls.index(builds[1]))
                packaging = [call for call in self.cli.calls if any(str(arg).endswith("/package-plugin-runtime.mjs") for arg in call)]
                self.assertEqual(len(packaging), 1)
                self.assertLess(self.cli.calls.index(builds[1]), self.cli.calls.index(packaging[0]))
                self.assertIn("PRODUCT_BUNDLE_IDENTIFIER=" + release.BUNDLE, builds[0])
                self.assertFalse(any(arg.startswith("PRODUCT_BUNDLE_IDENTIFIER=") for arg in builds[1]))
                self.assertFalse(any(arg.startswith("CODE_SIGN_ENTITLEMENTS=") for arg in builds[1]))
                self.assertTrue(any(arg.startswith("NOTEBOOK_MAC_ENTITLEMENTS=") for arg in builds[1]))
                for argv in builds:
                    self.assertEqual([arg for arg in argv if arg.startswith("NOTEBOOK_TYPESETTER_RUNTIME=")],
                                     ["NOTEBOOK_TYPESETTER_RUNTIME=" + expected_stage])
                    self.assertIn("CODE_SIGN_IDENTITY=Apple Development", argv)
                    self.assertIn("SWIFT_OPTIMIZATION_LEVEL=-O", argv)
                    self.assertIn(str(self.evidence / "source/Applications/Notebook.xcodeproj"), argv)
                device_calls = [call for call in self.cli.calls if "devicectl" in call]
                self.assertEqual(len(device_calls), 1)
                self.assertEqual(device_calls[0][1:5], ["devicectl", "device", "info", "details"])

    def test_changed_codex_helper_refuses_verified_pair_even_with_valid_fixture_signature(self):
        self.cli.changed_codex_helper = True
        self.refused("codex-runtime-check")

    def test_forged_preparation_receipt_stops_before_mac_build(self):
        self.cli.forged_codex_report = True
        self.refused("Codex runtime contract failed")
        self.assertIsNone(self.cli.mac)

    def test_portable_only_verification_cannot_claim_native_codex_admission(self):
        receipt = release.read_json(self.verification / "verification.json")
        self.assertNotIn("codexRuntime", receipt)
        receipt["codexRuntime"] = release.notebook_codex.identity(self.cli.codex_runtime)
        with self.assertRaisesRegex(release.ReleaseError, "did not admit"):
            verify.validate_selected(self.source, self.verification, receipt)

    def test_failed_codex_preparation_stops_before_mac_build_or_verified_pair(self):
        self.cli.codex_prepare_fail = True
        self.refused("codex-resources")
        self.assertIsNone(self.cli.mac)
        self.assertNotIn("apps", release.read_json(self.evidence / "build.json"))
        self.assertFalse(self.cli.install_calls)

    def test_previous_directory_is_not_reused(self):
        receipt = self.build()
        calls = list(self.cli.calls)
        with self.assertRaisesRegex(release.ReleaseError, "новый каталог"):
            self.build()
        self.assertEqual(self.cli.calls, calls)
        self.assertEqual(release.read_json(self.evidence / "build.json"), receipt)

    def test_missing_isolated_worker_prevents_release(self):
        self.cli.missing_xpc = True
        self.refused("ровно два")

    def test_network_capability_on_worker_prevents_release(self):
        self.cli.xpc_rights["com.apple.security.network.client"] = True
        self.refused("XPC получил доступ")

    def test_worker_without_sandbox_prevents_release(self):
        self.cli.xpc_rights = {}
        self.refused("XPC получил доступ")


    def test_xcode_injected_read_all_files_exception_prevents_release(self):
        self.cli.xpc_rights["com.apple.security.temporary-exception.files.absolute-path.read-only"] = ["/"]
        self.refused("XPC получил доступ")


    def test_missing_tex_distribution_prevents_release(self):
        self.cli.missing_tex = True
        self.refused("Typesetter resource contract failed")

    def test_changed_tex_distribution_prevents_release(self):
        self.cli.changed_tex = True
        self.refused("Typesetter resource contract failed")





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
                     "Tests/Harness/node_modules/lib.js", "Applications/__pycache__/cache.pyc",
                     "MCP/.notebook/program-builds/immutable/main.js",
                     "MCP/plugin/notebook/runtime/NotebookRuntime.app/Contents/MacOS/NotebookRuntime",
                     "MCP/plugin/notebook/.runtime-stage-fixture/retired/Contents/Info.plist"):
            path = self.source / file
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("generated output\n")
        self.assertEqual(release.source_inputs(self.source), self.before)
        self.build()

    def test_authored_notebook_data_is_still_a_source_input(self):
        path = self.source / "MCP/.notebook/authored.json"
        path.parent.mkdir(parents=True)
        path.write_text("{}")
        self.assertNotEqual(release.source_inputs(self.source), self.before)

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
        (self.verification / "runner-payload/Data").write_bytes(b"different xcresult")
        self.refused("Свидетельства", before_commands=True)

    def test_changed_log_invalidates_evidence(self):
        (self.verification / "core.log").write_text("different log\n")
        self.refused("Свидетельства", before_commands=True)

    def test_missing_required_log_invalidates_evidence(self):
        (self.verification / "load-fixture-execution.json").unlink()
        self.refused("JSON-файла", before_commands=True)

    def test_symlink_result_is_rejected(self):
        (self.verification / "external-result").symlink_to(self.source / "Package.swift")
        self.refused("ссылаться", before_commands=True)

    def test_incomplete_failed_or_skipped_execution_cannot_finish(self):
        for field, value in (("failed", ["load-fixture"]), ("skipped", ["load-fixture"]), ("executed", []), ("format", 0)):
            with self.subTest(field=field):
                report = {"format": 1, "planned": ["load-fixture"], "executed": ["load-fixture"], "skipped": [], "failed": []}
                report[field] = value
                release.write_json(self.verification / "load-fixture-execution.json", report)
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
        # The build fixture changes this exact source during xcodebuild.
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

    def test_standalone_mac_app_is_refused(self):
        self.cli.mac_info["LSUIElement"] = False
        self.refused("без самостоятельного интерфейса")

    def test_runtime_without_plugin_entrypoint_is_refused(self):
        del self.cli.mac_info["NotebookPluginRuntime"]
        self.refused("без самостоятельного интерфейса")

    def test_failed_packaging_does_not_publish_a_verified_pair(self):
        self.cli.package_fail = True
        self.refused("Команда package-plugin")
        self.assertNotIn("apps", release.read_json(self.evidence / "build.json"))

    def test_packaging_cannot_change_the_verified_runtime(self):
        self.cli.mutate_packaged_runtime = True
        self.refused("Подписанная пара изменилась")

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

    def test_mac_profile_without_cloud_container_is_refused(self):
        self.cli.mac_profile["Entitlements"]["com.apple.developer.icloud-container-identifiers"] = ["iCloud.foreign"]
        self.refused("Provisioning не разрешает")

    def test_mac_cloud_signature_requires_an_explicit_app_identity(self):
        del self.cli.mac_entitlements["com.apple.application-identifier"]
        self.refused("чужую идентичность Keychain")

    def test_mac_cloud_signature_requires_the_entitled_team(self):
        del self.cli.mac_entitlements["com.apple.developer.team-identifier"]
        self.refused("чужую идентичность Keychain")

    def test_mac_profile_for_another_device_is_refused(self):
        self.cli.mac_profile["ProvisionedDevices"] = ["00000000-0000-0000-0000-000000000000"]
        self.refused("не разрешает этот компьютер")

    def test_mac_hardware_uuid_cannot_replace_the_provisioning_udid(self):
        self.cli.mac_profile["ProvisionedDevices"] = ["11111111-2222-3333-4444-555555555555"]
        self.refused("не разрешает этот компьютер")

    def test_mac_cloud_environment_mismatch_is_refused(self):
        self.cli.mac_entitlements["com.apple.developer.icloud-container-environment"] = "Development"
        self.refused("неизвестные права")

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


class InstallationCLI(PairCLI):
    support = "Library/Application Support"
    catalog_path = support + "/Notebook.spaces.json"
    sqlite_path = support + "/Notebook/notebook.sqlite"
    workspace_id = "54349F3B-9E0A-4DEA-B990-40CAE04EF45E"

    def __init__(self, built, build):
        self.__dict__.update(built.__dict__)
        self.calls = []
        self.mac = build / "plugin/notebook/runtime/NotebookRuntime.app"
        self.publication = build.parent / "published-marketplace"
        self.published_plugin = self.publication / "releases/0.2.0/notebook"
        self.cache = build.parent / "codex-cache/notebook/0.2.0/runtime/NotebookRuntime.app"
        self.preview = {**self.preview, "bundleVersion": "16", "version": "0.3.13"}
        self.existing_preview = True
        self.plugin_fail = False
        self.stale_cache = False
        self.missing_cached_typescript_library = False
        self.wrong_launcher_args = False
        self.literal_plugin_root = False
        self.previous_runtime = None
        self.untrusted_previous_runtime = False
        self.on_plugin_phase = None
        self.on_preinstall = None
        self.on_install = None
        self.storage = {name: self.file(directory=True) for name in
            ("Library", self.support, self.support + "/Notebook", self.support + "/Notebook.spaces")}
        self.storage[self.catalog_path] = self.file(content=json.dumps({"format": 1,
            "originalID": self.workspace_id, "selectedID": self.workspace_id,
            "entries": [{"id": self.workspace_id, "name": "Fixture"}],
            "deleting": [], "pendingCloudDeletion": []}).encode())
        self.storage[self.sqlite_path] = self.file(size=329682944)
        self.storage[self.sqlite_path + "-wal"] = self.file(size=1767512)

    @staticmethod
    def file(directory=False, size=0, content=None):
        return {"resources": {"isDirectory": directory, "isSymbolicLink": False, "isReadable": True},
                "metadata": {"size": len(content) if content is not None else size}, "content": content}

    def __call__(self, argv, cwd=None, stdout=None, stderr=None, timeout=None, pass_fds=()):
        if pass_fds:
            assert argv[-2:] == ["--publication-fd", str(pass_fds[0])]
            assert len(pass_fds) == 1
            os.fstat(pass_fds[0])
            argv = argv[:-2]
        label = Path(stdout.name).name.removesuffix(".stdout.log")
        output, exit_code = b"", 0
        if label in ("publish-plugin", "install-plugin", "installed-plugin") and self.on_plugin_phase:
            self.on_plugin_phase(label)
        if argv[1:5] == ["devicectl", "device", "info", "files"]:
            assert argv[argv.index("--domain-type") + 1] == "appDataContainer"
            assert argv[argv.index("--domain-identifier") + 1] == release.BUNDLE
            relative = argv[argv.index("--subdirectory") + 1] if "--subdirectory" in argv else ""
            rows = []
            for name, entry in self.storage.items():
                parent, _, child = name.rpartition("/")
                if parent == relative:
                    rows.append({"name": child, "relativePath": child,
                        "metadata": entry["metadata"], "resources": entry["resources"]})
            release.write_json(Path(argv[argv.index("--json-output") + 1]), {
                "info": {"outcome": "success", "commandType": "devicectl.device.info.files"},
                "result": {"deviceIdentifier": release.DEVICE, "domain": "appDataContainer",
                    "domainIdentifier": release.BUNDLE, "files": rows}})
        elif argv[1:5] == ["devicectl", "device", "copy", "from"]:
            assert argv[argv.index("--source") + 1] == self.catalog_path, "Installation may only copy the bounded catalog"
            assert argv[argv.index("--domain-identifier") + 1] == release.BUNDLE
            Path(argv[argv.index("--destination") + 1]).write_bytes(self.storage[self.catalog_path]["content"])
        elif label == "ipad-preinstall":
            if self.on_preinstall:
                self.on_preinstall()
            return super().__call__(argv, cwd=cwd, stdout=stdout, stderr=stderr, timeout=timeout)
        elif label == "plugin-publication-preflight":
            assert argv == ["/fixture/node", str(self.mac.parents[3] / "source/MCP/install-plugin.mjs"), "preflight"]
            output = json.dumps({"root": str(self.publication), "plugin": None}).encode()
        elif label == "plugins-before":
            output = json.dumps({"installed": [{"pluginId": "notebook@notebook-local", "version": "0.1.6"}]}).encode()
        elif label == "connected-before":
            previous = str(self.previous_runtime / "Contents/Resources/CodexRuntime/node") if self.previous_runtime else "/bin/sh"
            output = json.dumps({"enabled": True, "transport": {"type": "stdio", "command": previous, "args": []}}).encode()
        elif label == "owners-before-install":
            pass
        elif label.startswith("installed-runtime-"):
            assert Path(argv[-1]) == self.previous_runtime
            if label.endswith("-verify"):
                assert {"--verify", "--deep", "--strict", "-R"}.issubset(argv)
                exit_code = 1 if self.untrusted_previous_runtime else 0
            elif label.endswith("-identity"):
                output = ("Identifier=" + release.MAC_BUNDLE + "\nTeamIdentifier=" + release.TEAM
                    + "\nAuthority=Apple Development: Fixture\nCDHash=" + "b" * 40 + "\n").encode()
        elif label == "publish-plugin":
            assert Path(argv[1]) == self.mac.parents[3] / "source/MCP/install-plugin.mjs"
            assert argv[2:] == ["publish", str(self.mac.parents[2])]
            shutil.copytree(self.mac.parent.parent, self.published_plugin, symlinks=True)
            output = json.dumps({"root": str(self.publication), "plugin": str(self.published_plugin), "version": "0.2.0"}).encode()
        elif label == "install-plugin":
            assert argv == ["/fixture/node", str(self.mac.parents[3] / "source/MCP/install-plugin.mjs"), "install"]
            if self.plugin_fail:
                exit_code = 1
            else:
                shutil.copytree(self.mac, self.cache, symlinks=True)
                if self.stale_cache:
                    (self.cache / "Contents/MacOS/NotebookRuntime").write_bytes(b"old cached runtime")
                if self.missing_cached_typescript_library:
                    (self.cache / "Contents/XPCServices/NotebookMarkupService.xpc/Contents" / release.notebook_typescript.RESOURCES / "lib.d.ts").unlink()
        elif label == "installed-plugin":
            runtime = Path("${PLUGIN_ROOT}/runtime/NotebookRuntime.app") if self.literal_plugin_root else self.cache
            output = json.dumps({"enabled": True, "transport": {"type": "stdio",
                "command": str(runtime / "Contents/Resources/CodexRuntime/node"),
                "args": [str(runtime / "Contents/Resources/NotebookTools/dist" / ("index.mjs" if self.wrong_launcher_args else "launch-runtime.mjs"))]}}).encode()
        elif label == "prune-plugin-publications":
            assert argv == ["/fixture/node", str(self.mac.parents[3] / "source/MCP/install-plugin.mjs"), "prune"]
            assert len(self.install_calls) == 1, "Old publication stays available until the full pair has installed"
        elif label == "install-ipad":
            result = super().__call__(argv, cwd=cwd, stdout=stdout, stderr=stderr, timeout=timeout)
            if self.on_install:
                self.on_install()
            return result
        else:
            return super().__call__(argv, cwd=cwd, stdout=stdout, stderr=stderr, timeout=timeout)
        self.calls.append(list(argv))
        stdout.write(output)
        return subprocess.CompletedProcess(argv, exit_code)


class InstallationTests(unittest.TestCase):
    tearDown = ReleaseTests.tearDown
    build = ReleaseTests.build

    def setUp(self):
        ReleaseTests.setUp(self)
        self.build_receipt = self.build()
        self.build_dir = self.evidence
        self.evidence = self.root / "installation"
        self.cli = InstallationCLI(self.cli, self.build_dir)
        ipc = tempfile.TemporaryDirectory(prefix="nb-install-", dir="/tmp")
        self.addCleanup(ipc.cleanup)
        self.ipc = Path(ipc.name) / "ipc"

    def install(self):
        stopped = release.stopped_runtime
        with patch.object(release.shutil, "which", side_effect=lambda name: "/fixture/" + name), \
             patch.object(release, "CANONICAL_MAC", self.root / "legacy/Notebook.app"), \
             patch.object(release, "stopped_runtime", side_effect=lambda command, approved: stopped(command, approved, self.ipc)):
            return release.install_verified_pair(self.source, self.build_dir, self.evidence, self.cli)

    def test_installs_plugin_and_ipad_in_place_and_reads_exact_cached_runtime(self):
        before = dict(self.cli.preview)
        receipt = self.install()
        self.assertEqual(receipt["status"], "installed")
        self.assertEqual(receipt["runtime"], str(self.cli.cache))
        self.assertEqual(receipt["ipadWorkspaceBefore"]["identity"], receipt["ipadWorkspaceAfter"]["identity"])
        self.assertEqual(receipt["ipadWorkspaceAfter"]["identity"]["selectedID"], self.cli.workspace_id.lower())
        for key in ("dataContainerPath", "appGroupIdentifiers", "groupContainerPaths"):
            self.assertEqual(receipt["ipadAfter"][0][key], before[key])
        self.assertEqual(receipt["ipadAfter"][0]["bundleVersion"], self.build_receipt["build"])
        self.assertEqual(len(self.cli.install_calls), 1)
        self.assertFalse(any({"kill", "terminate", "uninstall", "--remove-existing-content"}.intersection(call) for call in self.cli.calls))

    def test_missing_group_identity_refuses_before_plugin_or_device_mutation(self):
        del self.cli.preview["appGroupIdentifiers"]
        with self.assertRaisesRegex(release.ReleaseError, "CLI не подтвердил appGroupIdentifiers"):
            self.install()
        self.assertEqual(self.cli.install_calls, [])
        self.assertFalse((self.source / "MCP/plugin/notebook/runtime").exists())
        self.assertEqual(release.read_json(self.evidence / "installation.json")["status"], "refused")

    def test_device_preflight_refusal_does_not_request_runtime_shutdown(self):
        self.cli.device["identifier"] = "foreign-device"
        with patch.object(release, "stopped_runtime") as handoff:
            with self.assertRaisesRegex(release.ReleaseError, "не согласованный iPad"):
                self.install()
        handoff.assert_not_called()
        self.assertFalse(self.cli.published_plugin.exists())
        self.assertEqual(self.cli.install_calls, [])

    def test_installed_cli_runtime_has_its_signature_admitted_before_handoff(self):
        self.cli.previous_runtime = self.root / "old-cache/NotebookRuntime.app"
        shutil.copytree(self.cli.mac, self.cli.previous_runtime)
        receipt = self.install()
        checks = [call for call in self.cli.calls if call[:1] == ["/usr/bin/codesign"] and call[-1] == str(self.cli.previous_runtime)]
        self.assertEqual(len(checks), 2)
        self.assertIn("--verify", checks[0])
        self.assertIn("--display", checks[1])
        self.assertEqual(receipt["runtimeShutdown"], [])
        self.assertEqual(receipt["status"], "installed")

    def test_untrusted_installed_cli_runtime_refuses_before_shutdown_or_publication(self):
        self.cli.previous_runtime = self.root / "old-cache/NotebookRuntime.app"
        shutil.copytree(self.cli.mac, self.cli.previous_runtime)
        self.cli.untrusted_previous_runtime = True
        with patch.object(release, "stopped_runtime") as handoff:
            with self.assertRaisesRegex(release.ReleaseError, "installed-runtime-0-verify"):
                self.install()
        handoff.assert_not_called()
        self.assertFalse(self.cli.published_plugin.exists())
        self.assertEqual(self.cli.install_calls, [])

    def test_writer_lease_remains_held_until_codex_installs_and_admits_its_cache(self):
        phases, inodes = [], []
        def check(label):
            lease = self.ipc / "bridge.sock.owner"
            inodes.append(lease.stat().st_ino)
            other = os.open(lease, os.O_RDWR)
            try:
                with self.assertRaises(BlockingIOError):
                    release.fcntl.flock(other, release.fcntl.LOCK_EX | release.fcntl.LOCK_NB)
            finally:
                os.close(other)
            phases.append(label)
        self.cli.on_plugin_phase = check
        self.assertEqual(self.install()["status"], "installed")
        self.assertEqual(phases, ["publish-plugin", "install-plugin", "installed-plugin"])
        self.assertEqual(len(set(inodes)), 1)

    def test_relocated_container_and_checkpointed_wal_preserve_the_workspace(self):
        self.cli.preview.update(appGroupIdentifiers=["group.notebook"],
            groupContainerPaths={"group.notebook": "/private/var/mobile/Containers/Shared/BEFORE"})
        def relocate():
            self.cli.preview["dataContainerPath"] = "/private/var/mobile/Containers/Data/Application/AFTER"
            self.cli.preview["groupContainerPaths"]["group.notebook"] = "/private/var/mobile/Containers/Shared/AFTER"
            self.cli.storage[self.cli.sqlite_path]["metadata"]["size"] += 4096
            del self.cli.storage[self.cli.sqlite_path + "-wal"]
        self.cli.on_install = relocate
        receipt = self.install()
        self.assertEqual(receipt["status"], "installed")
        self.assertNotEqual(receipt["ipadBefore"][0]["dataContainerPath"], receipt["ipadAfter"][0]["dataContainerPath"])
        self.assertEqual(receipt["ipadWorkspaceBefore"]["identity"], receipt["ipadWorkspaceAfter"]["identity"])
        self.assertEqual(len(self.cli.install_calls), 1)

    def test_installed_unopened_app_keeps_an_empty_baseline(self):
        self.cli.storage = {"Library": self.cli.file(directory=True)}
        receipt = self.install()
        self.assertEqual(receipt["ipadWorkspaceBefore"], {"identity": {"state": "empty"}})
        self.assertEqual(receipt["ipadWorkspaceBefore"], receipt["ipadWorkspaceAfter"])
        self.assertFalse(any(call[1:5] == ["devicectl", "device", "copy", "from"] for call in self.cli.calls))

    def test_data_without_catalog_refuses_before_plugin_or_device_mutation(self):
        del self.cli.storage[self.cli.catalog_path]
        with self.assertRaisesRegex(release.ReleaseError, "без подтверждённого каталога"):
            self.install()
        self.assertEqual(self.cli.install_calls, [])
        self.assertFalse((self.source / "MCP/plugin/notebook/runtime").exists())

    def test_unknown_original_contents_without_catalog_are_not_an_empty_baseline(self):
        for name in (self.cli.catalog_path, self.cli.sqlite_path, self.cli.sqlite_path + "-wal"):
            del self.cli.storage[name]
        self.cli.storage[self.cli.support + "/Notebook/workspace.json"] = self.cli.file(size=128)
        with self.assertRaisesRegex(release.ReleaseError, "без подтверждённого каталога"):
            self.install()
        self.assertEqual(self.cli.install_calls, [])
        self.assertFalse(any(call[1:5] == ["devicectl", "device", "copy", "from"] for call in self.cli.calls))

    def test_oversized_catalog_is_not_copied_or_installed(self):
        self.cli.storage[self.cli.catalog_path]["metadata"]["size"] = 262145
        with self.assertRaisesRegex(release.ReleaseError, "превышает допустимый размер"):
            self.install()
        self.assertEqual(self.cli.install_calls, [])
        self.assertFalse(any(call[1:5] == ["devicectl", "device", "copy", "from"] for call in self.cli.calls))

    def assert_catalog_change_refused(self, phase, change):
        def changed():
            catalog = json.loads(self.cli.storage[self.cli.catalog_path]["content"])
            change(catalog)
            self.cli.storage[self.cli.catalog_path] = self.cli.file(content=json.dumps(catalog).encode())
        setattr(self.cli, "on_" + phase, changed)
        message = "изменился во время подготовки" if phase == "preinstall" else "Каталог или выбранное пространство"
        with self.assertRaisesRegex(release.ReleaseError, message):
            self.install()
        self.assertEqual(len(self.cli.install_calls), 0 if phase == "preinstall" else 1)
        receipt = release.read_json(self.evidence / "installation.json")
        self.assertEqual(receipt["status"], "incomplete")
        observation = "ipadWorkspacePreinstall" if phase == "preinstall" else "ipadWorkspaceAfter"
        self.assertNotEqual(receipt["ipadWorkspaceBefore"]["identity"], receipt[observation]["identity"])
        if phase == "install":
            self.assertEqual(receipt["step"], "install-ipad")

    def test_catalog_key_order_and_json_formatting_preserve_the_workspace(self):
        def reordered(value):
            if isinstance(value, dict):
                return {key: reordered(item) for key, item in reversed(value.items())}
            return [reordered(item) for item in value] if isinstance(value, list) else value

        original = json.loads(self.cli.storage[self.cli.catalog_path]["content"])
        original["entries"][0]["name"] = "Тетрадь"
        observations = [json.dumps(original, ensure_ascii=False).encode()]
        self.cli.storage[self.cli.catalog_path] = self.cli.file(content=observations[0])

        def rewrite():
            value = reordered(json.loads(self.cli.storage[self.cli.catalog_path]["content"]))
            data = json.dumps(value, ensure_ascii=len(observations) % 2 == 0, indent=len(observations)).encode()
            observations.append(data)
            self.cli.storage[self.cli.catalog_path] = self.cli.file(content=data)

        self.cli.on_preinstall = self.cli.on_install = rewrite
        receipt = self.install()
        self.assertEqual(receipt["status"], "installed")
        self.assertEqual(len(self.cli.install_calls), 1)
        phases = [receipt[key] for key in ("ipadWorkspaceBefore", "ipadWorkspacePreinstall", "ipadWorkspaceAfter")]
        self.assertTrue(all(phase["identity"] == phases[0]["identity"] for phase in phases))
        self.assertEqual(len({phase["catalogReadback"]["rawSHA256"] for phase in phases}), 3)
        for phase, data in zip(phases, observations, strict=True):
            raw = phase["catalogReadback"]
            self.assertEqual((self.evidence / raw["file"]).read_bytes(), data)
            self.assertEqual((raw["rawSHA256"], raw["rawBytes"]), (release.digest(data), len(data)))

    def test_ambiguous_or_nonfinite_catalog_refuses_before_mutation(self):
        original = self.cli.storage[self.cli.catalog_path]["content"]
        for index, extra in enumerate((b'"format":1,', b'"invalid":NaN,', b'"invalid":1e999,')):
            with self.subTest(extra=extra):
                self.evidence = self.root / ("invalid-catalog-" + str(index))
                self.cli.storage[self.cli.catalog_path] = self.cli.file(content=b"{" + extra + original[1:])
                with self.assertRaisesRegex(release.ReleaseError, "JSON"):
                    self.install()
                self.assertEqual(self.cli.install_calls, [])
                self.assertFalse(self.cli.published_plugin.exists())
                self.assertFalse(self.cli.cache.exists())

    def test_catalog_change_during_plugin_setup_stops_before_ipad_install(self):
        self.assert_catalog_change_refused("preinstall", lambda value: value.update(selectedID=None))

    def test_catalog_fractional_numbers_are_refused_without_rounding(self):
        original = self.cli.storage[self.cli.catalog_path]["content"]
        for index, number in enumerate((b"1e-400", b"0.0", b"9007199254740992.0", b"9007199254740993.0")):
            with self.subTest(number=number):
                self.evidence = self.root / ("fractional-catalog-" + str(index))
                data = b'{"extra":' + number + b"," + original[1:]
                self.cli.storage[self.cli.catalog_path] = self.cli.file(content=data)
                with self.assertRaisesRegex(release.ReleaseError, "неподдерживаемое число JSON"):
                    self.install()
                self.assertEqual(self.cli.install_calls, [])
                self.assertFalse(self.cli.published_plugin.exists())
                self.assertFalse(self.cli.cache.exists())

    def test_changed_selected_workspace_cannot_be_claimed_installed_or_retried(self):
        self.assert_catalog_change_refused("install", lambda value: value.update(selectedID=None))

    def test_catalog_rename_refuses_before_ipad_install(self):
        self.assert_catalog_change_refused("preinstall", lambda value: value["entries"][0].update(name="Renamed"))

    def test_catalog_rename_cannot_be_claimed_installed(self):
        self.assert_catalog_change_refused("install", lambda value: value["entries"][0].update(name="Renamed"))

    def test_catalog_entry_change_refuses_before_ipad_install(self):
        self.assert_catalog_change_refused("preinstall", lambda value: value["entries"].append(
            {"id": "A1111111-1111-4111-8111-111111111111", "name": "Another"}))

    def test_catalog_entry_change_cannot_be_claimed_installed(self):
        self.assert_catalog_change_refused("install", lambda value: value["entries"].append(
            {"id": "A1111111-1111-4111-8111-111111111111", "name": "Another"}))

    def test_catalog_deletion_change_refuses_before_ipad_install(self):
        self.assert_catalog_change_refused("preinstall", lambda value: value["deleting"].append(
            "A1111111-1111-4111-8111-111111111111"))

    def test_catalog_deletion_change_cannot_be_claimed_installed(self):
        self.assert_catalog_change_refused("install", lambda value: value["deleting"].append(
            "A1111111-1111-4111-8111-111111111111"))

    def test_catalog_array_order_is_preserved(self):
        value = json.loads(self.cli.storage[self.cli.catalog_path]["content"])
        value["entries"].append({"id": "A1111111-1111-4111-8111-111111111111", "name": "Another"})
        self.cli.storage[self.cli.catalog_path] = self.cli.file(content=json.dumps(value).encode())
        self.assert_catalog_change_refused("preinstall", lambda value: value["entries"].reverse())

    def test_lost_catalog_cannot_be_claimed_installed_or_retried(self):
        self.cli.on_install = lambda: self.cli.storage.pop(self.cli.catalog_path)
        with self.assertRaisesRegex(release.ReleaseError, "без подтверждённого каталога"):
            self.install()
        self.assertEqual(len(self.cli.install_calls), 1)
        self.assertEqual(release.read_json(self.evidence / "installation.json")["status"], "incomplete")

    def test_lost_active_sqlite_cannot_be_claimed_installed_or_retried(self):
        self.cli.on_install = lambda: self.cli.storage.pop(self.cli.sqlite_path)
        with self.assertRaisesRegex(release.ReleaseError, "потеряло notebook.sqlite"):
            self.install()
        self.assertEqual(len(self.cli.install_calls), 1)
        self.assertEqual(release.read_json(self.evidence / "installation.json")["status"], "incomplete")

    def test_symlinked_active_sqlite_refuses_before_plugin_or_device_mutation(self):
        self.cli.storage[self.cli.sqlite_path]["resources"]["isSymbolicLink"] = True
        with self.assertRaisesRegex(release.ReleaseError, "неизвестный тип"):
            self.install()
        self.assertEqual(self.cli.install_calls, [])
        self.assertFalse((self.source / "MCP/plugin/notebook/runtime").exists())

    def test_managed_workspace_uses_its_catalog_address(self):
        catalog = json.loads(self.cli.storage[self.cli.catalog_path]["content"])
        catalog["originalID"] = None
        self.cli.storage[self.cli.catalog_path] = self.cli.file(content=json.dumps(catalog).encode())
        directory = self.cli.support + "/Notebook.spaces/" + self.cli.workspace_id.lower()
        self.cli.storage[directory] = self.cli.file(directory=True)
        self.cli.storage[directory + "/notebook.sqlite"] = self.cli.file(size=8192)
        receipt = self.install()
        self.assertEqual(receipt["ipadWorkspaceAfter"]["identity"]["activeSQLite"], directory + "/notebook.sqlite")

    def test_changed_app_groups_cannot_be_claimed_installed(self):
        self.cli.on_install = lambda: self.cli.preview.update(appGroupIdentifiers=["group.other"])
        with self.assertRaisesRegex(release.ReleaseError, "app groups"):
            self.install()
        self.assertEqual(len(self.cli.install_calls), 1)
        self.assertEqual(release.read_json(self.evidence / "installation.json")["status"], "incomplete")

    def test_newer_ipad_refuses_before_plugin_or_device_mutation(self):
        self.cli.preview["bundleVersion"] = "999"
        with self.assertRaisesRegex(release.ReleaseError, "downgrade"):
            self.install()
        self.assertEqual(self.cli.install_calls, [])
        self.assertFalse((self.source / "MCP/plugin/notebook/runtime").exists())

    def test_changed_authored_metadata_cannot_replace_the_verified_publication(self):
        (self.source / "MCP/plugin/notebook/plugin.json").write_text('{"name":"notebook","version":"9.0.0"}')
        receipt = self.install()
        self.assertEqual(receipt["status"], "installed")
        self.assertEqual(json.loads((self.cli.published_plugin / "plugin.json").read_text())["version"], "0.2.0")
        self.assertFalse((self.source / "MCP/plugin/notebook/runtime").exists())

    def test_newer_cached_runtime_refuses_before_plugin_or_device_mutation(self):
        self.cli.previous_runtime = self.root / "newer/NotebookRuntime.app"
        info = self.cli.previous_runtime / "Contents/Info.plist"
        info.parent.mkdir(parents=True)
        info.write_bytes(plistlib.dumps({"CFBundleIdentifier": release.MAC_BUNDLE, "CFBundleVersion": "999"}))
        with self.assertRaisesRegex(release.ReleaseError, "downgrade"):
            self.install()
        self.assertEqual(self.cli.install_calls, [])
        self.assertFalse((self.source / "MCP/plugin/notebook/runtime").exists())

    def test_stale_codex_cache_is_incomplete_and_does_not_install_ipad(self):
        self.cli.stale_cache = True
        with self.assertRaisesRegex(release.ReleaseError, "Нарушена целостность подписанного runtime"):
            self.install()
        self.assertEqual(self.cli.install_calls, [])
        receipt = release.read_json(self.evidence / "installation.json")
        self.assertEqual((receipt["status"], receipt["step"]), ("incomplete", "install-plugin"))

    def test_missing_cached_typescript_library_is_reported_as_integrity_failure_before_ipad(self):
        self.cli.missing_cached_typescript_library = True
        with self.assertRaisesRegex(release.ReleaseError, "Нарушена целостность подписанного runtime"):
            self.install()
        self.assertEqual(self.cli.install_calls, [])
        receipt = release.read_json(self.evidence / "installation.json")
        self.assertEqual((receipt["status"], receipt["step"]), ("incomplete", "install-plugin"))

    def test_wrong_launcher_arguments_are_reported_before_ipad(self):
        self.cli.wrong_launcher_args = True
        with self.assertRaisesRegex(release.ReleaseError, "неверные аргументы запуска"):
            self.install()
        self.assertEqual(self.cli.install_calls, [])

    def test_unresolved_plugin_root_does_not_install_ipad(self):
        self.cli.literal_plugin_root = True
        with self.assertRaisesRegex(release.ReleaseError, "Codex не подключил bundled Notebook runtime"):
            self.install()
        self.assertEqual(self.cli.install_calls, [])
        receipt = release.read_json(self.evidence / "installation.json")
        self.assertEqual((receipt["status"], receipt["step"]), ("incomplete", "install-plugin"))

    def test_plugin_install_failure_preserves_staged_runtime_and_does_not_install_ipad(self):
        self.cli.plugin_fail = True
        with self.assertRaisesRegex(release.ReleaseError, "install-plugin"):
            self.install()
        self.assertEqual(self.cli.install_calls, [])
        self.assertEqual(release.read_json(self.evidence / "installation.json")["status"], "incomplete")
        self.assertTrue((self.cli.published_plugin / "runtime/NotebookRuntime.app").is_dir())

    def test_uncertain_ipad_install_is_not_retried_or_claimed_installed(self):
        self.cli.missing_installation_url = True
        with self.assertRaisesRegex(release.ReleaseError, "bundle URL"):
            self.install()
        self.assertEqual(len(self.cli.install_calls), 1)
        receipt = release.read_json(self.evidence / "installation.json")
        self.assertEqual((receipt["status"], receipt["step"]), ("incomplete", "install-ipad"))


class PluginPublicationOwnershipTests(unittest.TestCase):
    def test_migration_uses_the_release_lease_and_records_the_adapter_result(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve()
            source, publication, evidence = base / "source", base / "publication", base / "evidence"
            source.mkdir()

            def runner(argv, cwd=None, stdout=None, stderr=None, timeout=None, pass_fds=()):
                if argv[2] == "location":
                    self.assertEqual(pass_fds, ())
                    stdout.write(json.dumps({"root": str(publication)}).encode())
                else:
                    self.assertEqual(argv[2], "migrate-source")
                    self.assertEqual(argv[-2:], ["--publication-fd", str(pass_fds[0])])
                    os.fstat(pass_fds[0])
                    with self.assertRaisesRegex(release.ReleaseError, "Другая публикация"):
                        with release.plugin_publication_lease(publication):
                            self.fail("Migration must hold the release lease")
                    stdout.write(json.dumps({"root": str(publication), "cachePreserved": True}).encode())
                return subprocess.CompletedProcess(argv, 0)

            result = release.migrate_plugin_source(source, evidence, runner)
            self.assertEqual(result["status"], "migrated")
            self.assertTrue(result["result"]["cachePreserved"])
            self.assertEqual(release.read_json(evidence / "source-migration.json"), result)

    def test_exception_releases_the_same_persistent_lease_file(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve() / "publication"
            with self.assertRaisesRegex(RuntimeError, "interrupted"):
                with release.plugin_publication_lease(root) as descriptor:
                    inode = os.fstat(descriptor).st_ino
                    with self.assertRaisesRegex(release.ReleaseError, "Другая публикация"):
                        with release.plugin_publication_lease(root):
                            self.fail("A second publisher cannot enter")
                    raise RuntimeError("interrupted")
            with release.plugin_publication_lease(root) as descriptor:
                self.assertEqual(os.fstat(descriptor).st_ino, inode)

    def test_inherited_child_retains_lease_after_parent_close_and_kill_releases_it(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve() / "publication"
            child = None
            try:
                with release.plugin_publication_lease(root) as descriptor:
                    child = subprocess.Popen([shutil.which("node"), "--input-type=module", "-e",
                        "import {fstatSync} from 'node:fs'; fstatSync(Number(process.argv[1])); console.log('ready'); process.stdin.resume();",
                        str(descriptor)],
                        pass_fds=(descriptor,), stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                    self.assertEqual(child.stdout.readline().strip(), "ready")
                with self.assertRaisesRegex(release.ReleaseError, "Другая публикация"):
                    with release.plugin_publication_lease(root):
                        self.fail("The surviving publication child still owns the lease")
                child.kill()  # This test-created, data-free child only.
                child.communicate(timeout=5)
                with release.plugin_publication_lease(root):
                    self.assertTrue((root / ".publication.owner").is_file())
            finally:
                if child is not None:
                    if child.poll() is None:
                        child.kill()
                    child.communicate(timeout=5)

    def test_codex_cli_retains_lease_after_the_adapter_exits(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve()
            root, endpoint = base / "publication", base / "ready.sock"
            cli = base / "codex-fixture"
            cli.write_text(f"#!{sys.executable}\n"
                "import json, os, socket\n"
                "lease = os.fstat(3)\n"
                "with socket.socket(socket.AF_UNIX) as peer:\n"
                f"    peer.connect({str(endpoint)!r})\n"
                "    peer.sendall(json.dumps({'pid': os.getpid(), 'inode': lease.st_ino}).encode())\n"
                "    peer.recv(1)\n")
            cli.chmod(0o700)
            adapter, peer = None, None
            with socket.socket(socket.AF_UNIX) as listener:
                listener.bind(str(endpoint)); listener.listen(); listener.settimeout(5)
                try:
                    with release.plugin_publication_lease(root) as descriptor:
                        adapter = subprocess.Popen([shutil.which("node"), ROOT / "MCP/install-plugin.mjs",
                            "preflight", "--publication-fd", str(descriptor)],
                            env={**os.environ, "CODEX_BIN": str(cli)}, pass_fds=(descriptor,),
                            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                        peer, _ = listener.accept(); peer.settimeout(5)
                        ready = json.loads(peer.recv(1024))
                        self.assertEqual(ready["inode"], os.fstat(descriptor).st_ino)
                    adapter.kill()  # Only the adapter spawned by this isolated test.
                    adapter.communicate(timeout=5)
                    with self.assertRaisesRegex(release.ReleaseError, "Другая публикация"):
                        with release.plugin_publication_lease(root):
                            self.fail("The surviving Codex operation still owns the lease")
                    peer.sendall(b"x")  # The data-free CLI fixture now completes normally.
                    self.assertEqual(peer.recv(1), b"")
                    deadline = time.monotonic() + 2
                    while True:
                        try:
                            with release.plugin_publication_lease(root):
                                break
                        except release.ReleaseError:
                            if time.monotonic() >= deadline:
                                raise
                            time.sleep(0.01)
                finally:
                    if peer is not None:
                        peer.close()
                    if adapter is not None:
                        if adapter.poll() is None:
                            adapter.kill()
                        adapter.communicate(timeout=5)


class RuntimeInstallationOwnershipTests(unittest.TestCase):
    command = staticmethod(lambda *args, **kwargs: (b"", b""))

    def test_peer_identity_reads_the_kernel_token_of_an_isolated_python_listener(self):
        with tempfile.TemporaryDirectory(prefix="nb-peer-", dir="/tmp") as directory:
            endpoint = Path(directory) / "bridge.sock"
            with socket.socket(socket.AF_UNIX) as server:
                server.bind(str(endpoint)); server.listen()
                token = release.runtime_peer(endpoint)
                identity = release.runtime_process_identity(token)
                self.assertEqual(identity["pid"], os.getpid())
                self.assertEqual(identity["uid"], os.geteuid())
                # Framework Python may exec Python.app rather than sys.executable.
                expected = subprocess.check_output(["/bin/ps", "-p", str(os.getpid()), "-o", "comm="], text=True).strip()
                self.assertEqual(identity["executable"], expected)
                signature = subprocess.run(["/usr/bin/codesign", "--display", "--verbose=4", expected],
                                           capture_output=True, text=True, check=True)
                self.assertIn("CDHash=" + identity["cdhash"] + "\n", signature.stderr)

    def test_unknown_runtime_lease_refuses_packaging_and_preserves_its_inode(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "ipc"
            with release.stopped_runtime(self.command, root=root):
                inode = (root / "bridge.sock.owner").stat().st_ino
                with self.assertRaisesRegex(release.ReleaseError, "Неизвестный владелец"):
                    with release.stopped_runtime(self.command, root=root):
                        self.fail("Second owner cannot replace its runtime")
            with release.stopped_runtime(self.command, root=root):
                self.assertEqual((root / "bridge.sock.owner").stat().st_ino, inode)

    def test_serving_legacy_socket_refuses_install_without_unlinking_it(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "ipc"
            root.mkdir(mode=0o700)
            endpoint = root / "bridge.sock"
            with socket.socket(socket.AF_UNIX) as server:
                server.bind(str(endpoint)); server.listen()
                with self.assertRaisesRegex(release.ReleaseError, "обслуживает рабочее пространство"):
                    with release.stopped_runtime(self.command, root=root):
                        self.fail("Legacy writer must stop first")
                self.assertTrue(endpoint.is_socket())

    def test_draining_legacy_process_without_socket_still_refuses_install(self):
        with tempfile.TemporaryDirectory() as directory:
            command = lambda *args, **kwargs: (("42 " + str(release.CANONICAL_MAC / "Contents/MacOS/Notebook") + "\n").encode(), b"")
            with self.assertRaisesRegex(release.ReleaseError, "дождитесь выхода процесса"):
                with release.stopped_runtime(command, root=Path(directory) / "ipc"):
                    self.fail("A closed socket is not process exit")

    @contextlib.contextmanager
    def runtime_fixture(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "ipc"
            root.mkdir(mode=0o700)
            lease = root / "bridge.sock.owner"
            descriptor = os.open(lease, os.O_RDWR | os.O_CREAT, 0o600)
            release.fcntl.flock(descriptor, release.fcntl.LOCK_EX | release.fcntl.LOCK_NB)
            token = bytes(release.RuntimeAuditToken((ctypes.c_uint32 * 8)(0, os.geteuid(), 0, os.getuid(), 0, 42, 0, 1)))
            identity = {"pid": 42, "uid": os.geteuid(), "executable": str(Path(directory) / "Installed.app/Contents/MacOS/NotebookRuntime"),
                        "cdhash": "b" * 40}
            state = SimpleNamespace(root=root, lease=lease, descriptor=descriptor, token=token, identity=identity,
                                    approved={identity["executable"]: identity["cdhash"]}, peer=token, signals=[], saved=False)
            def request(pointer, number):
                raw = bytes(pointer._obj)
                self.assertEqual(number, signal.SIGTERM)
                state.signals.append(raw)
                if raw != state.token:
                    return errno.ESRCH
                state.saved = True
                release.fcntl.flock(state.descriptor, release.fcntl.LOCK_UN)
                state.peer = None
                return 0
            library = SimpleNamespace(proc_signal_with_audittoken=request)
            with patch.object(release, "runtime_peer", side_effect=lambda endpoint: state.peer), \
                 patch.object(release, "runtime_process_identity", side_effect=lambda raw: dict(state.identity)), \
                 patch.object(release.ctypes, "CDLL", return_value=library):
                try:
                    yield state
                finally:
                    os.close(descriptor)

    def test_saved_quit_claims_the_same_lease_and_excludes_bootstrap_until_publication(self):
        with self.runtime_fixture() as state:
            inode = state.lease.stat().st_ino
            with release.stopped_runtime(self.command, state.approved, state.root) as shutdown:
                self.assertTrue(state.saved, "Publication starts only after the fixture saves accepted work")
                self.assertEqual(shutdown, [state.identity])
                self.assertEqual(state.signals, [state.token])
                self.assertEqual(state.lease.stat().st_ino, inode)
                with self.assertRaises(BlockingIOError):
                    release.fcntl.flock(state.descriptor, release.fcntl.LOCK_EX | release.fcntl.LOCK_NB)
            release.fcntl.flock(state.descriptor, release.fcntl.LOCK_EX | release.fcntl.LOCK_NB)

    def test_unapproved_running_path_or_cdhash_never_receives_a_signal(self):
        for field in ("executable", "cdhash"):
            with self.subTest(field=field), self.runtime_fixture() as state:
                state.identity[field] += "different"
                with self.assertRaisesRegex(release.ReleaseError, "Неизвестный владелец"):
                    with release.stopped_runtime(self.command, state.approved, state.root):
                        self.fail("Unknown IPC peer must not be retired")
                self.assertEqual(state.signals, [])
                self.assertFalse(state.saved)

    def test_reused_pid_cannot_receive_the_old_audit_token_signal(self):
        with self.runtime_fixture() as state:
            observed = state.token
            state.token = bytes(release.RuntimeAuditToken((ctypes.c_uint32 * 8)(0, os.geteuid(), 0, os.getuid(), 0, 42, 0, 2)))
            self.assertIsNone(release.request_runtime_termination(observed, state.approved))
            self.assertEqual(state.signals, [observed])
            self.assertFalse(state.saved, "The recycled PID's new generation keeps its work and lease")
            other = os.open(state.lease, os.O_RDWR)
            try:
                with self.assertRaises(BlockingIOError):
                    release.fcntl.flock(other, release.fcntl.LOCK_EX | release.fcntl.LOCK_NB)
            finally:
                os.close(other)

    def test_refused_saved_shutdown_keeps_owner_and_never_forces_or_repeats_the_signal(self):
        with self.runtime_fixture() as state:
            def refuse(raw, approved):
                state.signals.append(raw)
                return state.identity
            with patch.object(release, "request_runtime_termination", side_effect=refuse):
                with self.assertRaisesRegex(release.ReleaseError, "не завершил сохранение"):
                    with release.stopped_runtime(self.command, state.approved, state.root, wait_seconds=0):
                        self.fail("Unsaved accepted work must retain its writer")
            self.assertEqual(state.signals, [state.token])
            self.assertFalse(state.saved)
            other = os.open(state.lease, os.O_RDWR)
            try:
                with self.assertRaises(BlockingIOError):
                    release.fcntl.flock(other, release.fcntl.LOCK_EX | release.fcntl.LOCK_NB)
            finally:
                os.close(other)

    def test_verified_auto_relaunch_between_quit_and_flock_is_retired_before_publication(self):
        with self.runtime_fixture() as state:
            original = state.token
            restarted = bytes(release.RuntimeAuditToken((ctypes.c_uint32 * 8)(0, os.geteuid(), 0, os.getuid(), 0, 43, 0, 2)))
            def restart(raw, approved):
                state.signals.append(raw)
                if raw == original:
                    state.peer = state.token = restarted
                    state.identity["pid"] = 43
                else:
                    state.saved = True
                    state.peer = None
                    release.fcntl.flock(state.descriptor, release.fcntl.LOCK_UN)
                return dict(state.identity)
            with patch.object(release, "request_runtime_termination", side_effect=restart):
                with release.stopped_runtime(self.command, state.approved, state.root) as shutdown:
                    self.assertTrue(state.saved)
                    self.assertEqual(state.signals, [original, restarted])
                    self.assertEqual(len(shutdown), 2)

    def test_changed_lease_inode_during_shutdown_cannot_admit_publication(self):
        with self.runtime_fixture() as state:
            def replace(raw, approved):
                state.saved = True
                state.peer = None
                release.fcntl.flock(state.descriptor, release.fcntl.LOCK_UN)
                state.lease.unlink()
                state.lease.touch(mode=0o600)
                return state.identity
            with patch.object(release, "request_runtime_termination", side_effect=replace):
                with self.assertRaisesRegex(release.ReleaseError, "writer lease изменился"):
                    with release.stopped_runtime(self.command, state.approved, state.root):
                        self.fail("A detached lock inode cannot exclude a new bootstrap")

    def test_continuous_auto_relaunch_has_a_bounded_refusal_without_force(self):
        with self.runtime_fixture() as state:
            def restart(raw, approved):
                state.signals.append(raw)
                generation = len(state.signals) + 1
                state.peer = bytes(release.RuntimeAuditToken((ctypes.c_uint32 * 8)(0, os.geteuid(), 0, os.getuid(), 0, 42, 0, generation)))
                return state.identity
            with patch.object(release, "request_runtime_termination", side_effect=restart):
                with self.assertRaisesRegex(release.ReleaseError, "повторно запускается"):
                    with release.stopped_runtime(self.command, state.approved, state.root):
                        self.fail("Unbounded restarts cannot hold a release attempt forever")
            self.assertEqual(len(state.signals), 3)
            self.assertFalse(state.saved)


if __name__ == "__main__":
    unittest.main(verbosity=2)

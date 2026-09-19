#!/usr/bin/env python3
"""Test selection and receipt refusal, without launching an app or a test runner."""
import contextlib
import copy
import io
import json
import plistlib
from pathlib import Path
import subprocess
import struct
import sys
import tempfile
from types import SimpleNamespace
import unittest
import uuid
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Applications"))
import notebook_release as release
import notebook_verification as verify
import notebook_acceptance as acceptance


class FullPrerequisiteTests(unittest.TestCase):
    def test_full_route_prepares_one_pinned_compiler_before_swift_and_reuses_it_for_xcode(self):
        route = (ROOT / "Tests/NotebookVerification/full.sh").read_text()
        install = "npm ci --ignore-scripts\n"
        prepare = 'python3 -B "$ROOT/Applications/prepare_notebook_typescript.py" --prepare'
        export = "export NOTEBOOK_TYPESCRIPT_RUNTIME\n"
        core = 'swift test 2>&1 | tee "$EVIDENCE/core.log"'
        for command in (install, prepare, export, core):
            self.assertEqual(route.count(command), 1, command)
        self.assertLess(route.index(install), route.index(prepare))
        self.assertLess(route.index(prepare), route.index(export))
        self.assertLess(route.index(export), route.index(core),
                        "Real compiler tests must not depend on a previous checkout's SDK stage")
        self.assertLess(route.index(core), route.index("xcodebuild \\\n"))


class SelectionTests(unittest.TestCase):
    def test_document_ui_requires_a_real_address_and_ipad_before_touching_the_stand(self):
        method = "NotebookDocumentAcceptanceUITests/testRealPageControlsLinksAndTouchSourceEditingSurviveColdReopening"
        identifier = "ADB44DE5-5B67-44F8-8371-9D03883E55EC"
        value = acceptance.document_ui_request("ipad", method, identifier, "Контрольный документ")
        self.assertEqual(value["documentID"], identifier.lower())
        self.assertEqual(value["timeoutSeconds"], 300)
        self.assertEqual(value["environment"], {"NOTEBOOK_ACCEPTANCE_DOCUMENT_ID": identifier.lower(),
                                             "NOTEBOOK_ACCEPTANCE_DOCUMENT_TITLE": "Контрольный документ"})
        for platform, document_id, title in (("mac", identifier, "Title"), ("ipad", None, "Title"),
                ("ipad", "not-a-uuid", "Title"), ("ipad", identifier.replace("-", ""), "Title"),
                ("ipad", "00000000-0000-0000-0000-000000000000", "Title"),
                ("ipad", identifier, None), ("ipad", identifier, "   "),
                ("ipad", identifier, "bad\x00title"), ("ipad", identifier, "x" * 513)):
            with self.subTest(platform=platform, document_id=document_id, title=title):
                with self.assertRaises(release.ReleaseError):
                    acceptance.document_ui_request(platform, method, document_id, title)

    def test_only_the_exact_cold_document_scenario_gets_660_seconds(self):
        identifier = "adb44de5-5b67-44f8-8371-9d03883e55ec"
        method = "NotebookDocumentAcceptanceUITests/testTenColdOpeningsAndWarmDistantLinksMeetNativeInstallationBudgets"
        value = acceptance.document_ui_request("ipad", method, identifier, "Control")
        self.assertEqual(value["timeoutSeconds"], 660)
        changed = acceptance.document_ui_request("ipad", method + "Other", identifier, "Control")
        self.assertEqual(changed["timeoutSeconds"], 300)
        ordinary = "NotebookAcceptanceUITests/testRealChatReplyThroughConnectedMac"
        self.assertIsNone(acceptance.document_ui_request("ipad", ordinary, None, None))
        with self.assertRaises(release.ReleaseError):
            acceptance.document_ui_request("ipad", ordinary, identifier, "Control")

    def test_collaborative_host_deadline_exceeds_real_native_agent_waits_only_for_exact_scenarios(self):
        scenarios = [
            "NotebookCollaborationAcceptanceUITests/testCreatedMaterialRetainsHumanEditsThroughAgentUndoAndCancellation",
            "NotebookCollaborationAcceptanceUITests/testConcurrentHumanStateRejectsStaleAgentWriteAndSurvivesItsUndo",
            "NotebookCollaborationAcceptanceUITests/testUseCreatedDocumentFromTheExistingRealConversation",
            "NotebookCollaborationAcceptanceUITests/testContinueSavedDocumentFromTheExistingRealConversation",
            "NotebookCollaborationAcceptanceUITests/testOfflineOutgoingAndDraftSurviveRelaunchInTheSameConversation",
            "NotebookCollaborationAcceptanceUITests/testReconnectedConversationDeliversOnceAndRetainsUnsentDraft",
        ]
        for scenario in scenarios:
            with self.subTest(scenario=scenario):
                self.assertEqual(acceptance.ui_timeout("ipad", scenario), 660)
                self.assertGreater(acceptance.ui_timeout("ipad", scenario), 600)
                self.assertEqual(acceptance.ui_timeout("ipad", scenario + "Other"), 240)
                with self.assertRaises(release.ReleaseError):
                    acceptance.ui_timeout("mac", scenario)

    def test_ui_deadlines_preserve_document_and_bounded_mixed_workload_contracts(self):
        self.assertEqual(acceptance.ui_timeout("ipad", "NotebookAcceptanceUITests/testRealChatReplyThroughConnectedMac"), 240)
        for seconds in (300, 660):
            self.assertEqual(acceptance.ui_timeout("ipad", "NotebookDocumentAcceptanceUITests/testDocument",
                                                  document={"timeoutSeconds": seconds}), seconds)
        workload = "NotebookAcceptanceUITests/testThirtyMinutesOfMixedInteraction"
        for seconds in (1800, 2700):
            self.assertEqual(acceptance.ui_timeout("ipad", workload, workload_seconds=seconds), seconds + 180)
        for platform, seconds in (("mac", 1800), ("ipad", 1799), ("ipad", 2701)):
            with self.subTest(platform=platform, seconds=seconds), self.assertRaises(release.ReleaseError):
                acceptance.ui_timeout(platform, workload, workload_seconds=seconds)

    def test_attached_trace_accepts_only_ipad_scenarios_with_the_launch_handshake(self):
        collaborative = [
            "NotebookCollaborationAcceptanceUITests/testCreatedMaterialRetainsHumanEditsThroughAgentUndoAndCancellation",
            "NotebookCollaborationAcceptanceUITests/testConcurrentHumanStateRejectsStaleAgentWriteAndSurvivesItsUndo",
        ]
        for scenario in collaborative + ["NotebookAcceptanceUITests/testRealChatReplyThroughConnectedMac",
                                        "NotebookDocumentAcceptanceUITests/testRealPageControlsLinksAndTouchSourceEditingSurviveColdReopening"]:
            self.assertTrue(acceptance.supports_attached_ui_trace("ipad", scenario))
            self.assertFalse(acceptance.supports_attached_ui_trace("mac", scenario))
        for scenario in [collaborative[0] + "Other", "NotebookCollaborationAcceptanceUITests/testWithoutHandshake",
                         *acceptance.COLLABORATION_RECOVERY_UI_TESTS,
                         "NotebookChatPanelTests/testNativeWorkShimmersOnceAndDisclosureSurvivesResizeWithoutReplayingItems",
                         "UnknownUITests/testRealGesture"]:
            self.assertFalse(acceptance.supports_attached_ui_trace("ipad", scenario))

    def test_simulator_signature_requires_only_its_private_keychain_group(self):
        identifier = acceptance.release.TEAM + "." + acceptance.IPAD_BUNDLE
        valid = {"application-identifier": identifier, "keychain-access-groups": [identifier]}
        acceptance.validate_simulator_entitlements(valid)
        for invalid in ({}, {**valid, "application-identifier": "production"},
                        {**valid, "keychain-access-groups": []},
                        {**valid, "keychain-access-groups": [identifier, "production"]},
                        {**valid, "com.apple.security.application-groups": ["production"]}):
            with self.assertRaises(release.ReleaseError):
                acceptance.validate_simulator_entitlements(invalid)

    def test_acceptance_mac_has_its_own_stable_apple_identity(self):
        display = ("Identifier=" + acceptance.MAC_BUNDLE + "\nTeamIdentifier=" + release.TEAM
                   + "\nAuthority=Apple Development: Test Developer\nCDHash=" + "a" * 40 + "\n")
        signer, identity = acceptance.mac_acceptance_signer(display)
        self.assertEqual(signer, "Apple Development: Test Developer")
        self.assertEqual(identity["identifier"], acceptance.MAC_BUNDLE)
        self.assertEqual(acceptance.SCRIPT_BUNDLE_SUFFIX, ".acceptance-runtime-" + identity["team"].lower())
        for invalid in (display + "Signature=adhoc\n",
                        display.replace(acceptance.MAC_BUNDLE, release.MAC_BUNDLE),
                        display.replace(release.TEAM, "OTHERTEAM"),
                        display.replace("Apple Development: Test Developer", "Untrusted Developer")):
            with self.assertRaises(release.ReleaseError):
                acceptance.mac_acceptance_signer(invalid)

    def test_ui_drives_the_installed_app_without_removing_runner_dependencies(self):
        app = "/test/products/Notebook.app"
        dependencies = ["/test/products/TestRunner.app", app, "/test/products/Support.framework"]
        target = {"UITargetAppPath": app, "DependentProductPaths": dependencies[:],
                  "TestBundlePath": "/test/products/Tests.xctest"}
        acceptance.use_installed_ui_application(target)
        self.assertNotIn("UITargetAppPath", target)
        self.assertTrue(target["UseUITargetAppProvidedByTests"])
        self.assertEqual(target["DependentProductPaths"], [dependencies[0], dependencies[2]])
        self.assertEqual(target["TestBundlePath"], "/test/products/Tests.xctest")
        before = dict(target)
        acceptance.use_installed_ui_application(target)
        self.assertEqual(target, before)

    def test_native_workers_have_stable_signed_identity_separate_from_the_paired_stand(self):
        settings = dict(value.split("=", 1) for value in verify.native_mac_signing_settings())
        self.assertEqual(settings["CODE_SIGN_IDENTITY"], "Apple Development")
        self.assertEqual(settings["DEVELOPMENT_TEAM"], release.TEAM)
        self.assertEqual(settings["NOTEBOOK_BUNDLE_SUFFIX"], ".acceptance")
        self.assertEqual(settings["NOTEBOOK_ACCEPTANCE_ENABLED"], "YES")
        self.assertEqual(settings["NOTEBOOK_SCRIPT_BUNDLE_SUFFIX"], ".native-test")
        self.assertNotEqual(settings["NOTEBOOK_SCRIPT_BUNDLE_SUFFIX"], settings["NOTEBOOK_BUNDLE_SUFFIX"])

    def test_simulator_entitlements_come_from_the_executable_and_refuse_wrong_platform_or_bounds(self):
        identifier = acceptance.release.TEAM + "." + acceptance.IPAD_BUNDLE
        entitlements = {"application-identifier": identifier, "keychain-access-groups": [identifier]}
        payload = plistlib.dumps(entitlements)
        def executable(platform=7):
            build = struct.pack("<IIIIII", 0x32, 24, platform, 0, 0, 0)
            segment = struct.pack("<II16sQQQQIIII", 0x19, 152, b"__TEXT", 0, 0, 0, 0, 0, 0, 1, 0)
            section = struct.pack("<16s16sQQIIIIIIII", b"__entitlements", b"__TEXT", 0, len(payload),
                                  208, 0, 0, 0, 0, 0, 0, 0)
            header = struct.pack("<IiiIIIII", 0xFEEDFACF, 0x0100000C, 0, 2, 2, 176, 0, 0)
            return header + build + segment + section + payload
        valid = executable()
        self.assertEqual(acceptance.simulator_entitlements(valid), entitlements)
        outside = bytearray(valid)
        struct.pack_into("<I", outside, 176, len(valid) + 1)
        for invalid in (b"", valid[:40], valid[:-1], executable(platform=2), bytes(outside),
                        valid.replace(b"__entitlements", b"__missing-data")):
            with self.assertRaises(release.ReleaseError):
                acceptance.simulator_entitlements(invalid)

    def test_simulator_relocation_preserves_every_identity_and_changes_only_root(self):
        old = self.root / "old-container"
        new = self.root / "new-container"
        manifest = {"root": str(old / "Documents/acceptance/run/workspace"),
                    "actorID": "ipad-actor", "workspaceID": "shared-workspace", "runID": "run",
                    "bundleID": acceptance.IPAD_BUNDLE, "sourceRevision": "original-checkpoint"}
        changed = acceptance.rebase_simulator_manifest(manifest, old, new)
        self.assertEqual(changed, {**manifest, "root": str(new.resolve() / "Documents/acceptance/run/workspace")})
        self.assertEqual(manifest["root"], str(old / "Documents/acceptance/run/workspace"))
        for outside in (self.root / "production", old):
            with self.assertRaises(release.ReleaseError):
                acceptance.rebase_simulator_manifest({**manifest, "root": str(outside)}, old, new)

    def test_equal_source_builds_preserve_previous_manifests_across_two_handoffs(self):
        source = "a" * 64
        previous = self.root / ("ipad-build-" + source[:16] + ".json")
        original = {"runID": str(uuid.uuid4()), "actorID": str(uuid.uuid4()), "root": "/old/store"}
        previous.write_text(json.dumps(original))
        original_bytes = previous.read_bytes()
        first_value = {**original, "root": "/first/store"}
        first = acceptance.write_upgrade_manifest(previous, first_value, source)
        first_bytes = first.read_bytes()
        second_value = {**original, "root": "/second/store"}
        second = acceptance.write_upgrade_manifest(first, second_value, source)
        self.assertEqual(len({previous, first, second}), 3)
        self.assertEqual(previous.read_bytes(), original_bytes)
        self.assertEqual(first.read_bytes(), first_bytes)
        self.assertEqual(json.loads(first_bytes), first_value)
        self.assertEqual(json.loads(second.read_bytes()), second_value)
        self.assertEqual(second.parent, previous.parent)

    def test_installed_manifest_follows_moved_container_without_reading_missing_original(self):
        old, new = (self.root / str(uuid.uuid4()) for _ in range(2))
        run_id, workspace = str(uuid.uuid4()), str(uuid.uuid4())
        relative = Path("Documents/acceptance") / run_id / "ipad.json"
        current = new / relative
        current.parent.mkdir(parents=True)
        manifest = {"runID": run_id, "workspaceID": workspace, "bundleID": acceptance.IPAD_BUNDLE,
                    "actorID": str(uuid.uuid4()), "root": str(old / relative.parent / "store")}
        current.write_text(json.dumps(manifest))
        original_bytes = current.read_bytes()
        value = {"runID": run_id, "workspaceID": workspace, "iPadManifest": str(old / relative)}
        with patch.object(acceptance, "run", return_value=str(new).encode()):
            container, path, relocated = acceptance.installed_ipad_manifest(value, "selected-simulator")
            self.assertEqual(container, new.resolve())
            self.assertEqual(path, current.resolve())
            self.assertEqual(relocated, {**manifest, "root": str((new / relative.parent / "store").resolve())})
            self.assertFalse((old / relative).exists())
            self.assertEqual(current.read_bytes(), original_bytes)
            current.write_text(json.dumps({**manifest, "workspaceID": str(uuid.uuid4())}))
            with self.assertRaises(release.ReleaseError):
                acceptance.installed_ipad_manifest(value, "selected-simulator")

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for path in ("Sources", "Tests", "Applications", "MCP", "docs"):
            (self.root / path).mkdir()
        for path in ("Package.swift", "verify.sh", "Applications/project.yml"):
            (self.root / path).write_text("fixture\n")
        self.git("init", "-q"); self.git("config", "user.name", "test"); self.git("config", "user.email", "test@example.test")
        self.git("add", "."); self.git("commit", "-qm", "initial")

    def git(self, *args):
        return verify.git(self.root, *args)

    def change(self, path, value="changed"):
        destination = self.root / path; destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(value)

    def test_version_only_does_not_hide_build_configuration_change(self):
        original = 'settings:\n  MARKETING_VERSION: "0.3.19"\n  CURRENT_PROJECT_VERSION: 22\n'
        self.change("Applications/project.yml", original)
        self.git("add", "."); self.git("commit", "-qm", "version")
        self.change("Applications/project.yml", original.replace("0.3.19", "0.3.20").replace("22", "23"))
        self.assertFalse(verify.make_plan(self.root)["unclassified"])
        self.change("Applications/project.yml", original + "  SWIFT_VERSION: 7\n")
        self.assertTrue(verify.make_plan(self.root)["unclassified"])

    def test_package_version_only_does_not_hide_dependency_changes(self):
        path = "MCP/package-lock.json"
        old = {"version": "0.3.19", "packages": {"": {"version": "0.3.19"}, "node_modules/x": {"version": "1"}}}
        self.change(path, json.dumps(old)); self.git("add", "."); self.git("commit", "-qm", "package")
        self.change(path, json.dumps(old).replace("0.3.19", "0.3.20"))
        self.assertFalse(any(verify.make_plan(self.root)["checks"].values()))
        old["packages"]["node_modules/x"]["version"] = "2"
        self.change(path, json.dumps(old))
        self.assertIn("mcp", verify.make_plan(self.root)["profiles"])

    def test_scene_owner_does_not_select_the_100k_fixture_or_ui(self):
        self.change("Applications/Shared/SceneCompositionTiles.swift")
        self.change("Applications/Tests/SceneCompositionTests.swift")
        plan = verify.make_plan(self.root)
        self.assertFalse(plan["unclassified"])
        self.assertTrue(plan["checks"]["ipad"])
        self.assertTrue(all(s.count("/") == 2 and "HundredThousand" not in s and "UITests" not in s for s in plan["checks"]["ipad"]))

    def test_a_misspelled_selector_cannot_hide_behind_other_passed_tests(self):
        tree = {"testNodes": [{"name": "NotebookTests", "nodeType": "Unit test bundle", "children": [
            {"nodeType": "Test Case", "nodeIdentifier": "Suite/testCase()", "result": "Passed"}]}]}
        verify.validate_executed_tests(tree, ["NotebookTests/Suite", "NotebookTests/Suite/testCase"])
        with self.assertRaises(release.ReleaseError):
            verify.validate_executed_tests(tree, ["NotebookTests/Suite/testCase", "NotebookTests/Suite/missing"])

    def test_acceptance_selector_uses_actual_bundle_owner_not_the_project_name(self):
        for bundle in ("NotebookAcceptanceUITests", "NotebookMacAcceptanceUITests"):
            case = {"name": "testPair()", "nodeType": "Test Case", "result": "Passed",
                    "nodeIdentifier": bundle + "/testPair()", "durationInSeconds": 2}
            tree = {"testNodes": [{"name": "NotebookAcceptanceUIHarness", "nodeType": "Test Plan", "children": [
                {"name": bundle, "nodeType": "UI test bundle", "children": [
                    {"name": bundle, "nodeType": "Test Suite", "children": [case]}]}]}]}
            selector = bundle + "/" + bundle + "/testPair"
            verify.validate_executed_tests(tree, [selector])
            self.assertEqual(verify.timing_report(tree)["targets"], {bundle: {"tests": 1, "seconds": 2}})
            for wrong in (bundle + "/OtherSuite/testPair", bundle + "/" + bundle + "/testOther",
                          "NotebookAcceptanceUIHarness/" + bundle + "/testPair"):
                with self.assertRaises(release.ReleaseError): verify.validate_executed_tests(tree, [wrong])

    def test_suite_name_cannot_impersonate_the_selected_bundle_or_a_skipped_case(self):
        bundle = {"name": "OtherUITests", "nodeType": "UI test bundle", "children": [
            {"name": "NotebookAcceptanceUITests", "nodeType": "Test Suite", "children": [
                {"nodeType": "Test Case", "nodeIdentifier": "NotebookAcceptanceUITests/testPair()", "result": "Passed"}]}]}
        tree = {"testNodes": [bundle]}
        selector = "NotebookAcceptanceUITests/NotebookAcceptanceUITests/testPair"
        with self.assertRaises(release.ReleaseError): verify.validate_executed_tests(tree, [selector])
        bundle["name"] = "NotebookAcceptanceUITests"
        bundle["children"][0]["children"][0]["result"] = "Skipped"
        with self.assertRaises(release.ReleaseError): verify.validate_executed_tests(tree, [selector])

    def test_live_placement_profile_covers_delivery_and_held_scene_without_full_acceptance(self):
        plan = verify.make_plan(self.root, profiles=["live-placement"], only=True)
        self.assertIn("BoardMergeOwnershipTests", plan["checks"]["core"])
        self.assertIn("NotebookReferenceLiveSceneTests", plan["checks"]["core"])
        self.assertIn("NotebookBoardContentRevisionTests", plan["checks"]["core"])
        self.assertIn("NotebookTests/NotebookBoardRevisionTests", plan["checks"]["ipad"])
        self.assertIn("NotebookTests/NotebookLiveGesturePresentationTests", plan["checks"]["ipad"])
        self.assertEqual(plan["selectionMode"], "explicit-only")
        self.assertFalse(plan["checks"]["commands"])
        self.assertFalse(any("UITests" in value for value in plan["checks"]["ipad"]))

    def test_placement_scale_is_an_explicit_separate_risk_check(self):
        regular = verify.make_plan(self.root, profiles=["live-placement"], only=True)
        scale = verify.make_plan(self.root, profiles=["placement-scale"], only=True)
        selector = "NotebookSQLScaleTests/oneHundredThousandOwnersKeepAnEditAndItsJournalAddressed"
        self.assertNotIn(selector, regular["checks"]["core"])
        self.assertEqual(scale["checks"]["core"], [selector])
        self.assertFalse(scale["checks"]["ipad"])

    def test_ipad_selection_uses_the_physical_device_and_an_isolated_signed_app(self):
        class RunnerReached(Exception): pass
        calls = []
        def command(label, argv, **kwargs):
            calls.append((label, argv))
            if label == "ipad": raise RunnerReached()
            return b"", None
        plan = {"checks": {"core": [], "ipad": ["NotebookTests/NotebookGraphicModelTests"],
                            "mac": [], "commands": []}}
        with patch.object(release, "release_commands", return_value=command), \
             patch.object(release, "source_inputs", return_value={"source": "fixture"}), \
             patch.object(release, "read_toolchain", return_value={"toolchain": "fixture"}), \
             self.assertRaises(RunnerReached):
            verify.run_selected(self.root, plan, self.root / "physical-native")
        args = next(args for label, args in calls if label == "ipad")
        self.assertEqual(args[args.index("-destination") + 1], "platform=iOS,id=" + release.UDID)
        self.assertIn("NOTEBOOK_BUNDLE_SUFFIX=.native-test", args)
        self.assertIn("DEVELOPMENT_TEAM=" + release.TEAM, args)
        self.assertIn("-allowProvisioningUpdates", args)
        self.assertFalse(any("simctl" in args for _, args in calls))

    def test_docs_do_not_start_any_runner(self):
        self.change("docs/contract.md")
        plan = verify.make_plan(self.root)
        self.assertFalse(any(plan["checks"].values())); self.assertFalse(plan["unclassified"])

    def test_chat_control_selects_its_native_contract_and_two_gestures_not_the_whole_ui(self):
        self.change("Applications/iPad/NotebookChatPanel.swift")
        plan = verify.make_plan(self.root)
        self.assertEqual(plan["profiles"], ["chat", "chat-touch"])
        gestures = [s for s in plan["checks"]["ipad"] if s.startswith(verify.UI)]
        self.assertEqual(len(gestures), 2)
        self.assertFalse(any("HundredThousand" in s or "PageAddress" in s for values in plan["checks"].values() for s in values))
        self.assertFalse(plan["unclassified"])

    def test_document_markup_does_not_run_ui_gestures(self):
        self.change("Applications/WebResources/document-shell.html")
        plan = verify.make_plan(self.root)
        self.assertEqual(plan["profiles"], ["document-web"])
        self.assertFalse(any(s.startswith("NotebookUITests") for s in plan["checks"]["ipad"]))

    def test_each_browser_contract_selects_web_boundaries_not_all_documents(self):
        paths = ["Tests/NotebookDocumentAcceptance/test_link_activation.mjs"]
        for path in paths:
            with self.subTest(path=path):
                self.assertEqual(verify.owners(path), ["document-web"])
        plan = verify.make_plan(self.root, profiles=["document-web"], only=True)
        self.assertEqual(plan["checks"]["commands"], ["document-browser"])
        for suite in ("DocumentShellPreparationTests", "DocumentPrintImageTests", "DocumentLinkActivationTests"):
            self.assertIn("NotebookTests/" + suite, plan["checks"]["ipad"])
        self.assertEqual(verify.owners("Tests/NotebookDocumentAcceptance/test_system_trace.py"), ["acceptance-bootstrap"])

    def test_document_shell_selects_four_native_boundaries_and_js_not_storage_or_full_ui(self):
        self.change("Applications/WebResources/document-shell.html")
        plan = verify.make_plan(self.root)
        self.assertEqual(plan["profiles"], ["document-web"])
        self.assertEqual(plan["checks"]["commands"], ["document-browser"])
        self.assertEqual(plan["checks"]["core"], [])
        self.assertEqual(plan["checks"]["mac"], ["NotebookMacTests/DocumentRuntimeTests"])
        self.assertEqual(plan["checks"]["ipad"], ["NotebookTests/DocumentLinkActivationTests",
            "NotebookTests/DocumentPrintImageTests", "NotebookTests/DocumentShellPreparationTests"])
        scenario = verify.UI + "testDocumentLinksOpenTheMeasuredDistantPageAndReturnToContents"
        self.assertIn(scenario, verify.make_plan(self.root, tests=[scenario])["checks"]["ipad"])

    def test_new_native_owner_uses_existing_same_named_tests_without_a_map_entry(self):
        for path in ("Applications/Tests/NewOwnerTests.swift", "Applications/MacTests/NewOwnerTests.swift"):
            self.change(path)
        self.git("add", "."); self.git("commit", "-qm", "existing contracts")
        self.change("Applications/Shared/NewOwner.swift")
        plan = verify.make_plan(self.root)
        self.assertFalse(plan["profiles"])
        self.assertFalse(plan["unclassified"])
        self.assertEqual(plan["checks"]["ipad"], ["NotebookTests/NewOwnerTests"])
        self.assertEqual(plan["checks"]["mac"], ["NotebookMacTests/NewOwnerTests"])
        explicit = verify.make_plan(self.root, tests=["NotebookTests/OtherTests/testRegression"], only=True)
        self.assertEqual(explicit["checks"]["ipad"], ["NotebookTests/OtherTests/testRegression"])
        self.assertFalse(explicit["checks"]["mac"])

    def test_native_lookup_keeps_platform_scope_and_missing_tests_visible(self):
        self.change("Applications/MacTests/NewOwnerTests.swift")
        self.git("add", "."); self.git("commit", "-qm", "mac contract")
        self.change("Applications/iPad/NewOwner.swift")
        plan = verify.make_plan(self.root)
        self.assertEqual(plan["unclassified"], ["Applications/iPad/NewOwner.swift"])
        self.assertFalse(any(plan["checks"].values()))

    def test_document_owner_uses_nearest_native_contract_instead_of_integration_profile(self):
        self.change("Applications/Tests/DocumentBlockRuntimeTests.swift")
        self.git("add", "."); self.git("commit", "-qm", "document contract")
        self.change("Applications/Shared/DocumentBlockRuntime.swift")
        plan = verify.make_plan(self.root)
        self.assertFalse(plan["profiles"])
        self.assertEqual(plan["checks"], {"core": [], "mac": [], "commands": [],
                                         "ipad": ["NotebookTests/DocumentBlockRuntimeTests"]})

    def test_shared_native_test_routes_both_targets_but_scale_stays_explicit(self):
        self.change("Applications/TestSupport/SharedOwnerTests.swift")
        plan = verify.make_plan(self.root)
        self.assertEqual(plan["checks"]["ipad"], ["NotebookTests/SharedOwnerTests"])
        self.assertEqual(plan["checks"]["mac"], ["NotebookMacTests/SharedOwnerTests"])
        self.change("Applications/Tests/NotebookPageAddressTests.swift")
        self.change("Applications/Shared/NotebookPageAddress.swift")
        plan = verify.make_plan(self.root)
        self.assertIn("Applications/Shared/NotebookPageAddress.swift", plan["unclassified"])
        self.assertNotIn("NotebookTests/NotebookPageAddressTests", plan["checks"]["ipad"])

    def test_browser_contract_runner_executes_the_shipped_listener_and_refuses_any_failure(self):
        for path in ("Sources/Fixture.swift", "MCP/fixture.ts", "docs/fixture.md"):
            self.change(path, "source inventory fixture\n")
        paths = ["Tests/NotebookDocumentAcceptance/test_link_activation.mjs"]
        plan = {"unclassified": [], "manualSelection": True,
                "checks": {"core": [], "mac": [], "ipad": [], "commands": ["document-browser"]}}
        for failed in (None, *paths):
            with self.subTest(failed=failed):
                for index, path in enumerate(paths):
                    self.change(path, "import test from 'node:test';import assert from 'node:assert/strict';"
                                + f"test('required-contract-{index}',()=>assert.equal({str(path != failed).lower()},true));")
                evidence = self.root / ".build" / ("browser-" + str(failed is not None) + (Path(failed).stem if failed else "passed"))
                with patch.object(release, "read_toolchain", return_value={"fixture": "command routing only"}):
                    if failed is None:
                        receipt = verify.run_selected(self.root, plan, evidence)
                        self.assertEqual(receipt["status"], "passed")
                        self.assertEqual(json.loads((evidence / "completed.json").read_text()), plan["checks"])
                    else:
                        with self.assertRaises(release.ReleaseError): verify.run_selected(self.root, plan, evidence)
                        self.assertFalse((evidence / "completed.json").exists())
                        self.assertFalse((evidence / "verification.json").exists())
                commands = json.loads((evidence / "commands.json").read_text())
                self.assertEqual(len(commands), 1, "No application, package install, or native runner is part of these CPU contracts")
                self.assertEqual(commands[0]["label"], "document-browser")
                self.assertEqual(commands[0]["argv"], ["node", "--test", *(str(self.root / path) for path in paths)])
                self.assertEqual(commands[0]["exitCode"] == 0, failed is None)
                output = (evidence / "document-browser.stdout.log").read_text()
                for index in range(len(paths)): self.assertIn("required-contract-" + str(index), output)
                if failed is None:
                    verify.validate_selected(self.root, evidence, receipt)
                    relocated = self.root / ".build/identical-source"
                    release.copy_source(self.root, relocated, receipt["source"])
                    verify.validate_selected(relocated, evidence, receipt)
                    # Even a successful process cannot certify an omitted or
                    # substituted script by keeping only the command label.
                    for omitted in paths:
                        narrowed = copy.deepcopy(commands)
                        narrowed[0]["argv"].remove(str(self.root / omitted))
                        release.write_json(evidence / "commands.json", narrowed)
                        changed = {**receipt, "artifacts": release.verification_artifacts(evidence, full=False)}
                        with self.assertRaisesRegex(release.ReleaseError, "другой набор"):
                            verify.validate_selected(self.root, evidence, changed)
                    release.write_json(evidence / "commands.json", commands)
                    substituted = copy.deepcopy(commands)
                    substituted[0]["cwd"] = str(self.root / "different-source")
                    release.write_json(evidence / "commands.json", substituted)
                    changed = {**receipt, "artifacts": release.verification_artifacts(evidence, full=False)}
                    with self.assertRaisesRegex(release.ReleaseError, "другой набор"):
                        verify.validate_selected(self.root, evidence, changed)
                    release.write_json(evidence / "commands.json", commands)

    def test_script_runtime_selects_real_xpc_and_core_admission(self):
        self.change("Sources/NotebookScriptHost/Coordinator.swift")
        self.change("Sources/CQuickJS/notebook-quickjs.c")
        self.change("Sources/NotebookCore/NotebookScriptRun.swift")
        self.change("Sources/NotebookCore/NotebookScriptEffectOutcome.swift")
        self.change("Tests/NotebookScriptHostTests/NotebookScriptEffectRecoveryTests.swift")
        self.change("Tests/NotebookCoreTests/NotebookPublicProtocolTests.swift")
        self.change("Tests/NotebookScriptWorkerTests/NotebookQuickJSCancellationTests.swift")
        plan = verify.make_plan(self.root)
        self.assertFalse(plan["unclassified"])
        self.assertEqual(plan["profiles"], ["script-runtime"])
        self.assertIn("NotebookScriptAdmissionTests", plan["checks"]["core"])
        self.assertTrue({"NotebookScriptCancellationTests", "NotebookScriptEffectOutcomeTests",
                         "NotebookScriptEffectRecoveryTests", "NotebookScriptHelpTests", "NotebookPublicProtocolTests",
                         "NotebookScriptDeadlineTests", "NotebookQuickJSCancellationTests"}.issubset(plan["checks"]["core"]))
        self.assertEqual(plan["checks"]["mac"], ["NotebookMacTests/NotebookScriptServiceTests"])
        self.assertIn("mcp", plan["checks"]["commands"])
        self.assertFalse(plan["checks"]["ipad"])

    def test_acceptance_bootstrap_does_not_silently_claim_real_pairing(self):
        self.change("Applications/Shared/NotebookAcceptanceConfiguration.swift")
        self.change("Sources/NotebookAcceptance/main.swift")
        plan = verify.make_plan(self.root)
        self.assertFalse(plan["unclassified"])
        self.assertEqual(plan["profiles"], ["acceptance-bootstrap"])
        self.assertEqual(plan["checks"]["ipad"], ["NotebookTests/NotebookAcceptanceLaunchTests"])
        self.assertFalse(any("UITests" in check for group in plan["checks"].values() for check in group))

    def test_window_and_context_controls_name_their_live_gestures(self):
        for path in ("Applications/iPad/NotebookRootView.swift", "Applications/iPad/NotebookChatWindow.swift",
                     "Applications/Shared/NotebookCollaborationView.swift"):
            self.change(path)
        plan = verify.make_plan(self.root)
        self.assertFalse(plan["unclassified"])
        self.assertEqual(plan["profiles"], ["chat", "chat-touch", "workspace-controls"])
        self.assertIn(verify.UI + "testChatMovesResizesAndOpensSettingsWithoutMovingPaper", plan["checks"]["ipad"])
        self.assertIn(verify.UI + "testAgentChangesStayQuietAndHistoryKeepsItsActions", plan["checks"]["ipad"])

    def test_page_turn_owner_adds_only_two_page_turn_gestures(self):
        self.change("Applications/iPad/IPadPageTurnController.swift")
        plan = verify.make_plan(self.root)
        self.assertEqual(sum(s.startswith(verify.UI) for s in plan["checks"]["ipad"]), 2)

    def test_explicit_only_does_not_append_suites_and_records_unclassified_files(self):
        self.change("Applications/WebResources/document-shell.html")
        self.change("Applications/MacTests/DocumentSnapshotTests.swift")
        scenario = "NotebookMacTests/DocumentLinkNavigationTests"
        plan = verify.make_plan(self.root, tests=[scenario], only=True)
        self.assertEqual(plan["selectionMode"], "explicit-only")
        self.assertEqual(plan["checks"], {"core": [], "mac": [scenario], "ipad": [], "commands": []})
        self.assertFalse(plan["unclassified"])
        with self.assertRaises(release.ReleaseError):
            verify.make_plan(self.root, only=True)
        self.change("Sources/Unknown.swift")
        self.assertEqual(verify.make_plan(self.root, tests=[scenario], only=True)["unclassified"], ["Sources/Unknown.swift"])

    def test_shared_ui_fixture_requires_a_named_gesture_not_a_broad_profile(self):
        paths = ["Applications/iPad/NotebookDrawingFixture.swift", "Applications/UITests/DrawingResponsivenessTests.swift"]
        for path in paths:
            self.change(path)
        self.assertEqual(verify.make_plan(self.root, profiles=["documents"])["unclassified"], sorted(paths))
        scenario = verify.UI + "testDocumentLinksOpenTheMeasuredDistantPageAndReturnToContents"
        plan = verify.make_plan(self.root, tests=[scenario])
        self.assertFalse(plan["unclassified"])
        self.assertEqual(plan["checks"]["ipad"], [scenario])
        self.change("Sources/Unknown.swift")
        self.assertEqual(verify.make_plan(self.root, tests=[scenario])["unclassified"], ["Sources/Unknown.swift"])

    def test_shared_fixture_accepts_an_explicit_gesture_from_its_own_ui_suite(self):
        path = "Applications/iPad/NotebookDrawingFixture.swift"
        self.change(path)
        scenario = "NotebookUITests/NotebookAgentFeedbackUITests/testHumanDrag"
        plan = verify.make_plan(self.root, tests=[scenario], only=True)
        self.assertFalse(plan["unclassified"])
        self.assertEqual(plan["checks"]["ipad"], [scenario])
        with self.assertRaises(release.ReleaseError):
            verify.make_plan(self.root, tests=["NotebookUITests/NotebookAgentFeedbackUITests"], only=True)
        self.assertIn(path, verify.make_plan(self.root, tests=["NotebookTests/Feedback/testHumanDrag"], only=True)["unclassified"])

    def test_unknown_storage_requires_an_explicit_decision_not_automatic_full(self):
        self.change("Sources/NotebookCore/NotebookSQLite.swift")
        plan = verify.make_plan(self.root)
        self.assertEqual(plan["unclassified"], ["Sources/NotebookCore/NotebookSQLite.swift"])
        self.assertFalse(any(plan["checks"].values()))

    def test_staged_deleted_and_untracked_paths_are_not_lost(self):
        self.change("Applications/iPad/NotebookChatPanel.swift"); self.git("add", ".")
        self.git("rm", "Package.swift")
        self.change("Applications/WebResources/document-shell.html")
        plan = verify.make_plan(self.root)
        self.assertIn("Package.swift", plan["unclassified"])
        self.assertEqual(set(plan["profiles"]), {"chat", "chat-touch", "document-web"})

    def test_committed_change_uses_explicit_base(self):
        self.change("Applications/iPad/NotebookChatPanel.swift"); self.git("add", "."); self.git("commit", "-qm", "edit")
        self.assertFalse(verify.make_plan(self.root)["changedFiles"])
        self.assertIn("chat", verify.make_plan(self.root, "HEAD^")["profiles"])

    def test_exact_ui_method_is_allowed_but_whole_ui_suite_is_not(self):
        selector = verify.UI + "testProseDocumentTurnsToDifferentTextAndBack"
        self.assertEqual(verify.make_plan(self.root, tests=[selector])["checks"]["ipad"], [selector])
        for bad in ["NotebookUITests", "NotebookUITests/DrawingResponsivenessTests", "NotebookTests", "NotebookTests/Foo;echo"]:
            with self.subTest(bad=bad), self.assertRaises(release.ReleaseError):
                verify.make_plan(self.root, tests=[bad])

    def test_large_page_suite_is_never_automatically_selected(self):
        self.change("Applications/Tests/NotebookPageAddressTests.swift")
        self.assertTrue(verify.make_plan(self.root)["unclassified"])

    def test_changed_runtime_test_selects_that_suite(self):
        self.change("Applications/Tests/NotebookChatPanelTests.swift")
        plan = verify.make_plan(self.root)
        self.assertEqual(plan["checks"]["ipad"], ["NotebookTests/NotebookChatPanelTests"])

    def test_plan_does_not_launch_subprocess_runners(self):
        with patch.object(verify, "ROOT", self.root), patch.object(verify, "run_selected") as runner, contextlib.redirect_stdout(io.StringIO()):
            verify.main(["--plan", "--profile", "chat"])
            verify.main(["--plan", "--full"])
        runner.assert_not_called()

    def test_clean_mac_document_selection_prepares_sidecar_build_without_forcing_mcp_tests(self):
        class BuildReached(Exception): pass
        for commands in ([], ["mcp"]):
            with self.subTest(commands=commands):
                calls = []
                def command(label, argv, **kwargs):
                    calls.append((label, argv, kwargs))
                    if label == "mac-build-for-testing": raise BuildReached()
                    return b"", None
                plan = {"checks": {"core": [], "ipad": [], "mac": ["NotebookMacTests/DocumentRenderSessionTests"],
                                    "commands": commands}}
                evidence = self.root / ("with-mcp" if commands else "mac-only")
                self.assertFalse((self.root / "MCP/node_modules").exists())
                with patch.object(release, "release_commands", return_value=command), \
                     patch.object(release, "source_inputs", return_value={"source": "fixture"}), \
                     patch.object(release, "read_toolchain", return_value={"toolchain": "fixture"}), \
                     patch.object(release, "prepare_typesetter_runtime", return_value=self.root / "typesetter"), \
                     patch.object(release, "prepare_typescript_runtime", return_value=self.root / "typescript"), \
                     self.assertRaises(BuildReached):
                    verify.run_selected(self.root, plan, evidence)
                labels = [item[0] for item in calls]
                self.assertEqual(labels.count("mcp-dependencies"), 1)
                self.assertLess(labels.index("mcp-dependencies"), labels.index("mac-build-for-testing"))
                dependency = next(item for item in calls if item[0] == "mcp-dependencies")
                self.assertEqual(dependency[1], ["npm", "ci", "--ignore-scripts"])
                self.assertEqual(dependency[2]["cwd"], self.root / "MCP")
                self.assertEqual("mcp-test" in labels, bool(commands))
                build = next(item[1] for item in calls if item[0] == "mac-build-for-testing")
                self.assertIn("NOTEBOOK_TYPESETTER_RUNTIME=" + str(self.root / "typesetter"), build)
                self.assertIn("NOTEBOOK_TYPESCRIPT_RUNTIME=" + str(self.root / "typescript"), build)

    def test_submitted_pixel_owner_selects_native_display_and_immutable_attention_contracts(self):
        self.change("Applications/Shared/NotebookWorkspacePresentation.swift")
        plan = verify.make_plan(self.root)
        self.assertFalse(plan["unclassified"])
        self.assertIn("NotebookTests/NotebookSubmittedPixelsTests", plan["checks"]["ipad"])
        self.assertIn("NotebookTests/SharedAttentionTests", plan["checks"]["ipad"])
        self.assertFalse(plan["checks"]["mac"])

    def test_simulator_video_requires_actual_started_marker_and_live_recorder(self):
        class Process:
            def __init__(self, code=None): self.code = code
            def poll(self): return self.code
        path = self.root / "trace.log"
        path.write_text("Recording started.\n")
        acceptance.SimulatorRecording.wait_for_start(Process(), path, 20, "fixture")
        with self.assertRaises(release.ReleaseError):
            acceptance.SimulatorRecording.wait_for_start(Process(2), path, 20, "fixture")
        path.write_text("Hitches is not supported on this platform.\n")
        with self.assertRaisesRegex(release.ReleaseError, "Hitches is not supported"):
            acceptance.SimulatorRecording.wait_for_start(Process(2), path, 20, "fixture")
        path.write_text("Preparing recording...\n")
        with patch.object(acceptance.time, "monotonic", side_effect=[0, 21]), \
             self.assertRaisesRegex(release.ReleaseError, "Preparing recording"):
            acceptance.SimulatorRecording.wait_for_start(Process(), path, 20, "fixture")

    def test_all_process_trace_requires_explicit_host_scope_before_starting_any_recorder(self):
        with patch.object(acceptance.subprocess, "Popen") as start:
            for template in ("Time Profiler", "Animation Hitches", "Metal System Trace", "Allocations"):
                with self.subTest(template=template), self.assertRaisesRegex(release.ReleaseError, "процессы Mac"):
                    acceptance.SimulatorRecording("private-simulator", self.root, template)
            start.assert_not_called()

    def test_ui_rejects_unacknowledged_host_scope_before_reading_the_stand(self):
        for platform, template, consent in (("ipad", "Animation Hitches", False),
                ("ipad", "Allocations", False), ("ipad", None, True), ("mac", "Time Profiler", True)):
            args = SimpleNamespace(test="NotebookAcceptanceUITests/testProof", platform=platform,
                                   trace=template, allow_host_processes=consent)
            with self.subTest(platform=platform, template=template, consent=consent), \
                 patch.object(acceptance, "read") as read, patch.object(acceptance.subprocess, "Popen") as start:
                with self.assertRaises(release.ReleaseError):
                    acceptance.ui(args)
                read.assert_not_called(); start.assert_not_called()

    def test_authorized_host_trace_uses_existing_system_start_notification_not_log_prose(self):
        recorder = acceptance.SimulatorRecording("private-simulator", self.root, "Time Profiler", 120,
                                                allow_host_processes=True)
        video, process, notification = Mock(), Mock(), Mock()
        for child in (video, process):
            child.poll.return_value = None; child.wait.return_value = 0
        notification.name = "actual-notification"; notification.wait.return_value = True
        module = Mock(); module.TraceStartNotification.return_value.__enter__ = Mock(return_value=notification)
        module.TraceStartNotification.return_value.__exit__ = Mock(return_value=False)
        with patch.object(acceptance.subprocess, "Popen", side_effect=[video, process]) as start, \
             patch.object(acceptance, "system_trace_module", return_value=module), \
             patch.object(acceptance, "run", return_value=b'{"Hangs":{"hangsThreshold":250},"Time Profiler":{}}'), \
             patch.object(recorder, "wait_for_start") as video_started:
            try:
                recorder.start()
                command = start.call_args.args[0]
                self.assertIn("--all-processes", command)
                self.assertEqual(command[command.index("--time-limit") + 1], "120s")
                self.assertEqual(command[command.index("--notify-tracing-started") + 1], notification.name)
                video_started.assert_called_once()
                notification.wait.assert_called_once_with(0.1)
                scope = json.loads((self.root / "trace-scope.json").read_text())
                self.assertEqual(scope["scope"], "system_wide_including_host_mac")
                self.assertEqual(scope["assessment"], "unassessed")
                self.assertEqual(json.loads((self.root / "trace-started.json").read_text())["assessment"], "captured_unassessed")
                self.assertEqual(json.loads((self.root / "trace-options.json").read_text())["Hangs"]["hangsThreshold"], 100)
                self.assertEqual((self.root / "trace.log").read_bytes(), b"")
            finally:
                recorder.stop()

    def test_trace_log_without_notification_never_admits_the_workload(self):
        recorder = acceptance.SimulatorRecording("private-simulator", self.root, "Animation Hitches",
                                                allow_host_processes=True)
        video, process, notification = Mock(), Mock(), Mock()
        for child in (video, process):
            child.poll.return_value = None; child.wait.return_value = 0
        notification.name = "actual-notification"; notification.wait.return_value = False
        module = Mock(); module.TraceStartNotification.return_value.__enter__ = Mock(return_value=notification)
        module.TraceStartNotification.return_value.__exit__ = Mock(return_value=False)
        def spawn(*args, **kwargs):
            if args[0][1] == "simctl": return video
            kwargs["stdout"].write(b"Starting recording with the template.\n"); kwargs["stdout"].flush()
            return process
        with patch.object(acceptance.subprocess, "Popen", side_effect=spawn), \
             patch.object(acceptance, "system_trace_module", return_value=module), \
             patch.object(recorder, "wait_for_start"), \
             patch.object(acceptance.time, "monotonic", side_effect=[0, 0, 21]):
            try:
                with self.assertRaisesRegex(release.ReleaseError, "не подтвердил начало"):
                    recorder.start()
                self.assertFalse((self.root / "trace-started.json").exists())
            finally:
                recorder.stop()

    def test_timing_report_separates_ui_from_scale_inside_runtime(self):
        def case(name, seconds): return {"nodeType": "Test Case", "nodeIdentifier": name, "durationInSeconds": seconds}
        result = verify.timing_report({"testNodes": [{"name": "NotebookTests", "nodeType": "Unit test bundle", "children": [case("100k", 260)]},
                                                   {"name": "NotebookUITests", "nodeType": "UI test bundle", "children": [case("tap", 25), case("curl", 50)]}]})
        self.assertEqual(result["targets"]["NotebookUITests"], {"tests": 2, "seconds": 75})
        self.assertEqual(result["slowest"][0]["test"], "100k")

    def test_runtime_warnings_failure_skip_and_empty_run_are_not_pass(self):
        good = dict(passedTests=1, failedTests=0, skippedTests=0, runtimeWarnings=[])
        verify.validate_summary(good)
        for key, value in [("passedTests", 0), ("failedTests", 1), ("skippedTests", 1), ("runtimeWarnings", ["warning"]), ("runtimeWarnings", None)]:
            with self.subTest(key=key), self.assertRaises(release.ReleaseError):
                verify.validate_summary(dict(good, **{key: value}))

    def receipt(self):
        self.change("Applications/notebook_verification.py")
        evidence = self.root / ".build/selected"; evidence.mkdir(parents=True)
        plan = verify.make_plan(self.root)
        source = release.source_inputs(self.root)
        for name, value in [("selection.json", plan), ("completed.json", plan["checks"]), ("source-before.json", source),
                            ("source-after.json", source), ("toolchain.json", {"fixture": "not a native proof"})]:
            release.write_json(evidence / name, value)
        (evidence / "commands.json").write_text(json.dumps([{"label": name, "argv": ["python", name], "exitCode": 0} for name in plan["checks"]["commands"]]))
        receipt = {"format": 1, "route": "./verify.sh:selected", "status": "passed", "source": source,
                   "artifacts": release.verification_artifacts(evidence, full=False)}
        release.write_json(evidence / "verification.json", receipt)
        return evidence, receipt

    def test_selected_receipt_is_accepted_as_selected_not_claimed_full(self):
        evidence, receipt = self.receipt()
        self.assertEqual(release.checked_verification(self.root, evidence), receipt)
        self.assertNotEqual(receipt["route"], "./verify.sh")

    def test_changed_source_or_evidence_refuses_selected_release(self):
        evidence, _ = self.receipt()
        self.change("Applications/notebook_verification.py", "late edit")
        with self.assertRaises(release.ReleaseError): release.checked_verification(self.root, evidence)
        self.change("Applications/notebook_verification.py")
        (evidence / "completed.json").write_text("{}")
        with self.assertRaises(release.ReleaseError): release.checked_verification(self.root, evidence)

    def test_manual_scope_admits_unknown_owner_without_claiming_full_acceptance(self):
        evidence, receipt = self.receipt()
        plan = release.read_json(evidence / "selection.json")
        plan["unclassified"] = ["Applications/Shared/NotebookAppModel.swift"]
        plan["manualSelection"] = True
        release.write_json(evidence / "selection.json", plan)
        receipt["artifacts"] = release.verification_artifacts(evidence, full=False)
        self.assertEqual(verify.validate_selected(self.root, evidence, receipt), receipt)
        plan["unclassified"] = ["Applications/iPad/NotebookDrawingFixture.swift"]
        release.write_json(evidence / "selection.json", plan)
        receipt["artifacts"] = release.verification_artifacts(evidence, full=False)
        with self.assertRaises(release.ReleaseError): verify.validate_selected(self.root, evidence, receipt)

    def test_failed_command_or_unclassified_change_refuses_release(self):
        evidence, receipt = self.receipt()
        (evidence / "commands.json").write_text(json.dumps([{"label": "verification", "exitCode": 1}]))
        receipt["artifacts"] = release.verification_artifacts(evidence, full=False)
        with self.assertRaises(release.ReleaseError): verify.validate_selected(self.root, evidence, receipt)
        (evidence / "commands.json").write_text(json.dumps([{"label": "verification", "exitCode": 0}]))
        plan = release.read_json(evidence / "selection.json"); plan["unclassified"] = ["Sources/Unknown.swift"]; plan["manualSelection"] = False
        release.write_json(evidence / "selection.json", plan)
        receipt["artifacts"] = release.verification_artifacts(evidence, full=False)
        with self.assertRaises(release.ReleaseError): verify.validate_selected(self.root, evidence, receipt)


class UIOnlyBuildTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "source"
        self.swift = self.source / "Applications/AcceptanceUITests/Proof.swift"
        self.swift.parent.mkdir(parents=True); self.swift.write_text("import XCTest\n")
        self.products = self.root / "derived/ipad/Build/Products"
        self.runner = self.products / "Release-iphonesimulator/NotebookAcceptanceUITests-Runner.app"
        self.bundle = self.runner / "PlugIns/NotebookAcceptanceUITests.xctest"
        self.bundle.mkdir(parents=True)
        (self.bundle / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": acceptance.UI_TEST_BUNDLE}))
        self.binary = self.runner / "Runner"
        self.binary.write_bytes(b"immutable diagnostic test runner")
        self.target = {"BlueprintName": "NotebookAcceptanceUITests",
            "TestHostPath": "__TESTROOT__/Release-iphonesimulator/NotebookAcceptanceUITests-Runner.app",
            "TestBundlePath": "__TESTHOST__/PlugIns/NotebookAcceptanceUITests.xctest",
            "DependentProductPaths": ["__TESTROOT__/Release-iphonesimulator/NotebookAcceptanceUITests-Runner.app",
                                      "__TESTHOST__/PlugIns/NotebookAcceptanceUITests.xctest"]}
        self.original = self.products / "Diagnostic.xctestrun"
        self.write_spec(self.target)
        self.app = self.root / "accepted/Notebook.app"
        self.app.mkdir(parents=True); (self.app / "Notebook").write_bytes(b"accepted app")
        source = acceptance.ui_test_inputs(self.source)
        acceptance.write(self.root / "test-source.json", source)
        self.value = {"runID": "selected-run", "build": str(self.app.parent)}
        self.built = {"sourceSHA256": "accepted-source", "ipadApp": str(self.app), "simulator": {"udid": "selected-simulator"}}
        receipt = {"status": "built", "diagnosticOnly": True, "runID": self.value["runID"],
            "applicationBuild": self.value["build"], "applicationSourceSHA256": self.built["sourceSHA256"],
            "applicationBundleSHA256": release.app_manifest(self.app)["sha256"],
            "simulatorUDID": "selected-simulator", "testSourceSHA256": source["sha256"],
            "products": str(self.products), "runner": str(self.runner),
            "runnerSHA256": release.app_manifest(self.runner)["sha256"],
            "xctestrun": str(self.original), "xctestrunSHA256": release.file_digest(self.original)}
        acceptance.write(self.root / "ui-build.json", receipt)

    def write_spec(self, target):
        self.original.write_bytes(plistlib.dumps({"NotebookAcceptanceUITests": target}))

    def selected(self, **changes):
        arguments = {"platform": "ipad", "value": self.value, "built": self.built}
        arguments.update(changes)
        return acceptance.selected_ui_build(self.root, **arguments)

    def test_project_has_only_an_independent_ui_bundle_and_no_application_target_or_package(self):
        project = acceptance.ui_only_project()
        self.assertNotIn("packages", project)
        self.assertEqual(list(project["targets"]), ["NotebookAcceptanceUITests"])
        target = project["targets"]["NotebookAcceptanceUITests"]
        self.assertEqual(target["type"], "bundle.ui-testing")
        self.assertNotIn("dependencies", target)
        self.assertNotIn("TEST_TARGET_NAME", target["settings"]["base"])
        self.assertEqual(target["settings"]["base"]["PRODUCT_BUNDLE_IDENTIFIER"], acceptance.UI_TEST_BUNDLE)

    def test_test_sources_are_separate_from_application_sources_and_refuse_symlinks(self):
        before = acceptance.ui_test_inputs(self.source)
        (self.source / "Other.swift").write_text("unrelated application edit")
        self.assertEqual(acceptance.ui_test_inputs(self.source), before)
        self.swift.write_text("import XCTest\n// changed UI observation\n")
        self.assertNotEqual(acceptance.ui_test_inputs(self.source), before)
        self.swift.with_name("Alias.swift").symlink_to(self.swift)
        with self.assertRaises(release.ReleaseError): acceptance.ui_test_inputs(self.source)

    def test_guard_refuses_an_app_target_dependency_or_wrong_test_bundle(self):
        self.assertEqual(acceptance.ui_only_products(self.products, self.original), self.runner)
        for changed in ({**self.target, "UITargetAppPath": "__TESTROOT__/Release-iphonesimulator/Notebook.app"},
                        {**self.target, "DependentProductPaths": self.target["DependentProductPaths"] + [str(self.app)]},
                        {**self.target, "TestHostPath": str(self.app)}):
            with self.subTest(changed=changed):
                self.write_spec(changed)
                with self.assertRaises(release.ReleaseError): acceptance.ui_only_products(self.products, self.original)
        self.write_spec(self.target)
        (self.bundle / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "production.tests"}))
        with self.assertRaises(release.ReleaseError): acceptance.ui_only_products(self.products, self.original)

    def test_selection_keeps_both_provenances_and_rejects_other_run_or_application(self):
        products, original, provenance = self.selected()
        self.assertEqual((products, original), (self.products, self.original))
        self.assertTrue(provenance["diagnosticOnly"])
        self.assertEqual(provenance["applicationSourceSHA256"], "accepted-source")
        self.assertNotEqual(provenance["testSourceSHA256"], provenance["applicationSourceSHA256"])
        for arguments in ({"platform": "mac"}, {"value": {**self.value, "runID": "other-run"}},
                          {"built": {**self.built, "sourceSHA256": "other-source"}},
                          {"built": {**self.built, "simulator": {"udid": "other-simulator"}}}):
            with self.subTest(arguments=arguments), self.assertRaises(release.ReleaseError): self.selected(**arguments)

    def test_selection_rejects_modified_source_runner_spec_and_accepted_application(self):
        for path in (self.swift, self.binary, self.original, self.app / "Notebook"):
            before = path.read_bytes()
            try:
                path.write_bytes(before + b"changed")
                with self.subTest(path=path), self.assertRaises(release.ReleaseError): self.selected()
            finally:
                path.write_bytes(before)
        self.selected()


class UICleanupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.evidence = Path(self.temp.name)
        self.installed = {"bundlePath": "/private/Notebook.app", "dataContainer": "/private/data", "bundleSHA256": "accepted"}

    def finish(self, **changes):
        arguments = dict(evidence=self.evidence, scenario={"runID": "proof"}, primary_error=None,
                         trace=None, trace_finished=False, recording=None,
                         installed_before=self.installed, simulator="private-simulator")
        arguments.update(changes)
        return acceptance.finalize_ui_attempt(**arguments)

    def receipt(self):
        return json.loads((self.evidence / "scenario.json").read_text())

    def test_failed_completed_runner_exports_both_result_documents(self):
        (self.evidence / "result.xcresult").mkdir()
        summary, tree = {"failedTests": 1}, {"testNodes": ["failed-case"]}
        with patch.object(acceptance, "installed_ipad_state", return_value=self.installed), \
             patch.object(acceptance, "run", side_effect=[b"", b"", json.dumps(summary).encode(), json.dumps(tree).encode()]):
            self.finish(primary_error=ValueError("UI failure"), runner_exit=65, expected_test="Suite/testCase")
        self.assertEqual(json.loads((self.evidence / "summary.json").read_text()), summary)
        self.assertEqual(json.loads((self.evidence / "tests.json").read_text()), tree)
        self.assertEqual(self.receipt()["runnerExitCode"], 65)
        self.assertEqual(self.receipt()["primaryError"]["message"], "UI failure")
        self.assertEqual(self.receipt()["cleanupErrors"], [])

    def test_failed_summary_export_does_not_skip_tests_or_replace_primary(self):
        (self.evidence / "result.xcresult").mkdir()
        with patch.object(acceptance, "installed_ipad_state", return_value=self.installed), \
             patch.object(acceptance, "run", side_effect=[b"", b"", RuntimeError("summary unavailable"), b'{"testNodes": []}']):
            self.finish(primary_error=ValueError("UI failure"), runner_exit=65)
        self.assertTrue((self.evidence / "tests.json").exists())
        self.assertEqual(self.receipt()["cleanupErrors"][0]["stage"], "export.summary")
        self.assertEqual(self.receipt()["primaryError"]["message"], "UI failure")

    def test_xcresult_directory_without_exit_witness_is_not_a_completed_result(self):
        (self.evidence / "result.xcresult").mkdir()
        with patch.object(acceptance, "installed_ipad_state", return_value=self.installed), \
             patch.object(acceptance, "run", return_value=b"") as commands:
            self.finish(primary_error=subprocess.TimeoutExpired("runner", 1))
        self.assertEqual(len(commands.call_args_list), 2)
        self.assertFalse((self.evidence / "summary.json").exists())
        self.assertFalse((self.evidence / "tests.json").exists())
        self.assertIsNone(self.receipt()["runnerExitCode"])

    def test_success_requires_completed_result_and_still_validates_exact_test(self):
        with patch.object(acceptance, "installed_ipad_state", return_value=self.installed):
            with self.assertRaises(release.ReleaseError):
                self.finish(runner_exit=0, expected_test="Suite/testCase")
        self.assertEqual(self.receipt()["cleanupErrors"][0]["stage"], "runner-result.completed")
        (self.evidence / "result.xcresult").mkdir()
        summary = {"passedTests": 1, "failedTests": 0, "skippedTests": 0, "runtimeWarnings": []}
        with patch.object(acceptance, "installed_ipad_state", return_value=self.installed), \
             patch.object(acceptance, "run", side_effect=[b"", b"", json.dumps(summary).encode(), b'{"testNodes": []}']), \
             patch.object(acceptance.verification, "validate_executed_tests", side_effect=release.ReleaseError("missing expected test")) as validate:
            with self.assertRaises(release.ReleaseError):
                self.finish(runner_exit=0, expected_test="Suite/testCase")
        validate.assert_called_once_with({"testNodes": []}, ["Suite/testCase"])
        self.assertEqual(self.receipt()["cleanupErrors"][0]["stage"], "result-tests.validate")

    def test_exit_witness_comes_from_completed_child_not_timeout_or_launch_failure(self):
        exits = []
        with self.assertRaises(release.ReleaseError):
            acceptance.run([sys.executable, "-c", "raise SystemExit(65)"],
                           output=self.evidence / "exit.log", on_exit=exits.append)
        self.assertEqual(exits, [65])
        with self.assertRaises(subprocess.TimeoutExpired):
            acceptance.run([sys.executable, "-c", "import time; time.sleep(2)"],
                           output=self.evidence / "timeout.log", timeout=0.05, on_exit=exits.append)
        with self.assertRaises(FileNotFoundError):
            acceptance.run([str(self.evidence / "missing-executable")],
                           output=self.evidence / "missing.log", on_exit=exits.append)
        self.assertEqual(exits, [65])

    def test_actual_ui_keeps_its_failure_and_writes_receipt_when_after_snapshot_fails(self):
        build, directory = self.evidence / "build", self.evidence / "run"
        products = build / "derived/ipad/Build/Products"
        products.mkdir(parents=True); directory.mkdir()
        (products / "original.xctestrun").write_bytes(plistlib.dumps({"TestConfigurations": [{"TestTargets": [{
            "BlueprintName": "NotebookAcceptanceUITests", "UITargetAppPath": "/private/Notebook.app"}]}]}))
        (directory / "run.json").write_text(json.dumps({"runID": "proof", "workspaceID": "workspace",
            "build": str(build), "macManifest": str(self.evidence / "mac.json")}))
        (build / "build.json").write_text(json.dumps({"sourceSHA256": "source", "sourceRevision": "revision",
            "simulator": {"udid": "private-simulator"}, "ipadApp": "/private/Notebook.app"}))
        (self.evidence / "mac.json").write_text(json.dumps({"actorID": "mac-actor"}))
        args = SimpleNamespace(run=directory, platform="ipad", test="NotebookAcceptanceUITests/testProof",
                               document_id=None, document_title=None, workload_seconds=1800, trace=None, pencil=False)
        original, cleanup = ValueError("UI scenario failed"), RuntimeError("Simulator disconnected")
        recording = Mock()
        with patch.object(acceptance, "installed_ipad_manifest", return_value=(self.evidence,
                self.evidence / "ipad.json", {"actorID": "ipad-actor"})), \
             patch.object(acceptance, "installed_ipad_state", side_effect=[self.installed, cleanup]), \
             patch.object(acceptance.release, "app_manifest", return_value={"sha256": "accepted"}), \
             patch.object(acceptance, "SimulatorRecording", return_value=recording), \
             patch.object(acceptance, "run", side_effect=original):
            with self.assertRaises(ValueError) as failure:
                acceptance.ui(args)
        self.assertIs(failure.exception, original)
        recording.stop.assert_called_once_with()
        receipts = list(directory.glob("ipad-*/scenario.json"))
        self.assertEqual(len(receipts), 1)
        receipt = json.loads(receipts[0].read_text())
        self.assertEqual(receipt["status"], "failed")
        self.assertEqual(receipt["primaryError"], {"type": "ValueError", "message": "UI scenario failed"})
        self.assertEqual(receipt["cleanupErrors"], [{"stage": "installed-application.snapshot",
            "type": "RuntimeError", "message": "Simulator disconnected"}])
        self.assertIsNone(receipt["installedApplicationPreserved"])

    def test_trace_and_recording_failures_do_not_skip_snapshot_or_exports(self):
        (self.evidence / "result.xcresult").mkdir()
        trace, recording = Mock(), Mock()
        trace.cancel.side_effect = RuntimeError("cancel failed")
        recording.stop.side_effect = OSError("video stop failed")
        with patch.object(acceptance, "installed_ipad_state", return_value=self.installed), \
             patch.object(acceptance, "run") as commands:
            self.finish(primary_error=ValueError("trace finish failed"), trace=trace, recording=recording)
        self.assertEqual([call.args[0][3] for call in commands.call_args_list], ["attachments", "metrics"])
        receipt = self.receipt()
        self.assertEqual(receipt["primaryError"]["message"], "trace finish failed")
        self.assertEqual([error["stage"] for error in receipt["cleanupErrors"]], ["trace.cancel", "recording.stop"])
        self.assertTrue(receipt["installedApplicationPreserved"])
        self.assertFalse(receipt["systemTraceLifecycleFinished"])
        self.assertTrue((self.evidence / "installed-application-after.json").exists())

    def test_export_failure_keeps_primary_and_still_exports_the_other_artifacts(self):
        (self.evidence / "result.xcresult").mkdir()
        with patch.object(acceptance, "installed_ipad_state", return_value=self.installed), \
             patch.object(acceptance, "run", side_effect=[RuntimeError("attachments failed"), b""]) as commands:
            self.finish(primary_error=ValueError("UI failure"))
        self.assertEqual(commands.call_count, 2)
        self.assertEqual(self.receipt()["cleanupErrors"], [{"stage": "export.attachments",
            "type": "RuntimeError", "message": "attachments failed"}])
        self.assertEqual(self.receipt()["primaryError"]["message"], "UI failure")

    def test_successful_ui_cannot_pass_when_after_snapshot_is_unavailable(self):
        cleanup = RuntimeError("snapshot unavailable")
        with patch.object(acceptance, "installed_ipad_state", side_effect=cleanup):
            with self.assertRaises(RuntimeError) as failure:
                self.finish()
        self.assertIs(failure.exception, cleanup)
        self.assertEqual(self.receipt()["status"], "failed")
        self.assertIsNone(self.receipt()["primaryError"])
        self.assertIsNone(self.receipt()["installedApplicationPreserved"])

    def test_successful_ui_cannot_pass_after_the_bundle_or_container_changes(self):
        for field in ("bundleSHA256", "dataContainer"):
            with self.subTest(field=field), patch.object(acceptance, "installed_ipad_state",
                    return_value={**self.installed, field: "changed"}):
                with self.assertRaises(release.ReleaseError):
                    self.finish()
                self.assertFalse(self.receipt()["installedApplicationPreserved"])
                self.assertEqual(self.receipt()["status"], "failed")
                self.assertEqual(self.receipt()["cleanupErrors"][0]["stage"], "installed-application.identity")

    def test_completed_trace_is_not_cancelled_and_clean_completion_is_recorded(self):
        trace, recording = Mock(), Mock()
        with patch.object(acceptance, "installed_ipad_state", return_value=self.installed):
            self.finish(trace=trace, trace_finished=True, recording=recording)
        trace.cancel.assert_not_called(); recording.stop.assert_called_once_with()
        self.assertEqual(self.receipt()["status"], "passed")
        self.assertEqual(self.receipt()["cleanupErrors"], [])
        self.assertTrue(self.receipt()["systemTraceLifecycleFinished"])

    def test_unwritable_receipt_cannot_replace_primary_or_allow_false_success(self):
        original_write = acceptance.write
        def fail_receipt(path, value):
            if path.name == "scenario.json":
                raise OSError("evidence disk unavailable")
            original_write(path, value)
        original = ValueError("UI failed")
        with patch.object(acceptance, "installed_ipad_state", return_value=self.installed), \
             patch.object(acceptance, "write", side_effect=fail_receipt):
            self.finish(primary_error=original)
            if hasattr(original, "__notes__"):
                self.assertTrue(any("scenario.receipt" in note for note in original.__notes__))
            with self.assertRaisesRegex(OSError, "evidence disk unavailable"):
                self.finish()


if __name__ == "__main__":
    unittest.main(verbosity=2)

#!/usr/bin/env python3
"""Test selection and receipt refusal, without launching an app or a test runner."""
import contextlib
import copy
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Applications"))
import notebook_release as release
import notebook_verification as verify


class SelectionTests(unittest.TestCase):
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
        tree = {"testNodes": [{"name": "NotebookTests", "children": [
            {"nodeType": "Test Case", "nodeIdentifier": "Suite/testCase()", "result": "Passed"}]}]}
        verify.validate_executed_tests(tree, ["NotebookTests/Suite", "NotebookTests/Suite/testCase"])
        with self.assertRaises(release.ReleaseError):
            verify.validate_executed_tests(tree, ["NotebookTests/Suite/testCase", "NotebookTests/Suite/missing"])

    def test_renamed_simulator_is_selected_by_type_and_id_not_display_name(self):
        device = {"name": "Notebook InputUI RC", "udid": "ipad", "state": "Booted", "isAvailable": True,
                  "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPad-Air-11-inch-M4"}
        inventory = {"devices": {"runtime": [device]}}
        self.assertEqual(verify.select_simulator(inventory), device)
        self.assertEqual(verify.select_simulator(inventory, "ipad"), device)
        inventory["devices"]["runtime"].append(dict(device, udid="second"))
        with self.assertRaises(release.ReleaseError): verify.select_simulator(inventory)
        self.assertEqual(verify.select_simulator(inventory, "ipad"), device)

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
        self.change("Applications/WebResources/document-fragments.js")
        plan = verify.make_plan(self.root)
        self.assertEqual(plan["profiles"], ["documents"])
        self.assertFalse(any(s.startswith("NotebookUITests") for s in plan["checks"]["ipad"]))

    def test_window_and_context_controls_name_their_live_gestures(self):
        for path in ("Applications/iPad/NotebookRootView.swift", "Applications/iPad/NotebookChatWindow.swift",
                     "Applications/Shared/NotebookCollaborationView.swift"):
            self.change(path)
        plan = verify.make_plan(self.root)
        self.assertFalse(plan["unclassified"])
        self.assertEqual(plan["profiles"], ["chat", "chat-touch", "workspace-controls"])
        self.assertIn(verify.UI + "testChatMovesResizesAndOpensSettingsWithoutMovingPaper", plan["checks"]["ipad"])
        self.assertIn(verify.UI + "testAgentNoticeExpiresAndHistoryKeepsItsActions", plan["checks"]["ipad"])

    def test_page_turn_owner_adds_only_two_page_turn_gestures(self):
        self.change("Applications/iPad/IPadPageTurnController.swift")
        plan = verify.make_plan(self.root)
        self.assertEqual(sum(s.startswith(verify.UI) for s in plan["checks"]["ipad"]), 2)

    def test_explicit_only_does_not_append_suites_and_still_refuses_unknown_owners(self):
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
        paths = ["Applications/iPad/SimulatorDrawingFixture.swift", "Applications/UITests/DrawingResponsivenessTests.swift"]
        for path in paths:
            self.change(path)
        self.assertEqual(verify.make_plan(self.root, profiles=["documents"])["unclassified"], sorted(paths))
        scenario = verify.UI + "testDocumentLinksOpenTheMeasuredDistantPageAndReturnToContents"
        plan = verify.make_plan(self.root, tests=[scenario])
        self.assertFalse(plan["unclassified"])
        self.assertEqual(plan["checks"]["ipad"], [scenario])
        self.change("Sources/Unknown.swift")
        self.assertEqual(verify.make_plan(self.root, tests=[scenario])["unclassified"], ["Sources/Unknown.swift"])

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
        self.assertEqual(set(plan["profiles"]), {"chat", "chat-touch", "documents"})

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

    def test_timing_report_separates_ui_from_scale_inside_runtime(self):
        def case(name, seconds): return {"nodeType": "Test Case", "nodeIdentifier": name, "durationInSeconds": seconds}
        result = verify.timing_report({"testNodes": [{"name": "NotebookTests", "children": [case("100k", 260)]},
                                                   {"name": "NotebookUITests", "children": [case("tap", 25), case("curl", 50)]}]})
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
        plan["unclassified"] = ["Applications/iPad/SimulatorDrawingFixture.swift"]
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


if __name__ == "__main__":
    unittest.main(verbosity=2)

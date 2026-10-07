"""Exercise the real router/parser with bounded, explicitly fabricated runners."""
import copy
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Applications"))
import notebook_check_reports as reports
import notebook_release as release
import notebook_verification as verify
sys.path.insert(0, str(ROOT / "Tests/NotebookRelease"))
import codex_fixture


class RegistryReportTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        for folder in ("Sources", "Tests", "Applications", "MCP"):
            (self.root / folder).mkdir()
        for path in ("Package.swift", "verify.sh", "Applications/project.yml", "Sources/value.swift", "Tests/Contracts.swift", "Applications/prepare_notebook_typescript.py"):
            (self.root / path).write_text("explicit fabricated runner source\n")
        self.evidence = self.root / ".build/evidence"
        self.plan = {"format": 2, "sourceRoot": str(self.root), "selectionMode": "explicit-only", "profiles": [],
                     "unclassified": [], "manualSelection": True,
                     "checks": {"core": ["WantedSuite"], "mac": [], "ipad": [], "commands": []}}
        self.functions = [self.function("WantedSuite", "first"), self.function("WantedSuite", "second"),
                          self.function("OtherSuite", "unrelated")]
        self.execution_override = None
        self.calls = []
        self.codex_runtime, _, self.codex_files = codex_fixture.source(self.root)
        self.codex_stage = self.root / ".build/notebook-codex-runtimes" / release.notebook_codex.identity(self.codex_runtime)["manifestSHA256"]

    def function(self, suite, name, product="NotebookCoreTests"):
        return {"version": "6.4.0", "kind": "test", "payload": {"kind": "function", "name": name + "()",
                "id": product + "." + suite + "/" + name + "()/Contracts.swift:5:3",
                "sourceLocation": {"fileID": product + "/Contracts.swift", "filePath": str(self.root / "Tests/Contracts.swift"), "line": 5, "column": 3},
                "isParameterized": False}}

    def event(self, kind, identity=None):
        return {"version": "6.4.0", "kind": "event", "payload": {"kind": kind, **({"testID": identity} if identity else {})}}

    def execution(self, functions=None):
        functions = functions if functions is not None else self.functions[:2]
        return [*functions, self.event("runStarted"),
                *(self.event(kind, function["payload"]["id"]) for function in functions for kind in ("testStarted", "testEnded")),
                self.event("runEnded")]

    def fake_runner(self, argv, cwd, stdout, stderr, timeout, env=None):
        self.calls.append(list(argv))
        if argv[0] == str(self.codex_stage / "node") or argv[:2] == ["npm", "ci"]:
            self.assertIsNotNone(env)
            self.assertTrue(env["PATH"].startswith(str(self.codex_stage) + os.pathsep))
        if "--version" in argv:
            value = self.codex_runtime["node"] if Path(argv[0]).name == "node" else "fabricated fixed toolchain version"
            stdout.write((value + "\n").encode())
        elif any(value.endswith("prepare_notebook_codex.py") for value in argv):
            if not self.codex_stage.exists():
                codex_fixture.stage(self.codex_stage, self.codex_runtime, self.codex_files)
            stdout.write(json.dumps(codex_fixture.report(self.codex_stage, self.codex_runtime)).encode())
        elif any(value.endswith("prepare_notebook_typescript.py") for value in argv):
            stdout.write(json.dumps({"status": "ready", "stage": str(self.root / ".build/notebook-typescript-runtime/stages/pinned")}).encode())
        elif "--event-stream-output-path" in argv:
            product = None if "list" in argv else argv[argv.index("--test-product") + 1]
            selected = self.functions if product is None else [function for function in self.functions
                         if function["payload"]["id"].startswith(product + ".")
                         and re.fullmatch(argv[argv.index("--filter") + 1], function["payload"]["id"])]
            values = self.functions if product is None else (self.execution_override if self.execution_override is not None else self.execution(selected))
            stream = "\n".join(json.dumps(value) for value in values) + "\n"
            destination = argv[argv.index("--event-stream-output-path") + 1]
            if "list" in argv:
                self.assertEqual(destination, "/dev/stdout")
                self.assertEqual(stdout, subprocess.PIPE)
                return subprocess.CompletedProcess(argv, 0, stdout=(stream + "Test run with 99 tests passed\n").encode())
            Path(destination).write_text(stream)
            # An aggregate success line must not substitute for those events.
            stdout.write(b"Test run with 99 tests passed\n")
        return subprocess.CompletedProcess(argv, 0)

    def run_route(self):
        recorder = release.release_commands
        # This runner fabricates command results, including tool versions. Its
        # available commands belong to the same fixture, not the host's PATH.
        available = {sys.executable, "swift", "node", "npm", str(self.codex_stage / "node")}
        with patch.object(verify.shutil, "which", side_effect=lambda executable: executable if executable in available else None), \
             patch.object(release, "release_commands", side_effect=lambda evidence, **options: recorder(evidence, self.fake_runner, **options)):
            return verify.run_selected(self.root, self.plan, self.evidence)

    def test_fabricated_runner_discovery_is_independent_of_and_restores_the_host(self):
        original = verify.shutil.which
        with patch.object(verify.shutil, "which", return_value=None) as host:
            receipt = self.run_route()
            self.assertEqual(receipt["status"], "passed")
            host.assert_not_called()
            self.assertIs(verify.shutil.which, host)
        self.assertIs(verify.shutil.which, original)

    def test_production_toolchain_still_refuses_missing_swift_before_invoking_it(self):
        calls = []
        def command(label, argv, **options):
            calls.append((label, argv, options))
            return b"fixture Python version", b""
        with patch.object(verify.shutil, "which", side_effect=lambda executable: executable if executable == sys.executable else None):
            with self.assertRaisesRegex(release.ReleaseError, "Не найден prerequisite: swift"):
                verify.selected_toolchain(command, self.plan)
        self.assertEqual([label for label, _, _ in calls], ["toolchain-python"])
        self.assertFalse(any("swift" in argv for _, argv, _ in calls))

    def test_full_and_selected_toolchain_share_stdout_version_and_keep_diagnostic_stderr(self):
        self.evidence.mkdir(parents=True)
        diagnostic = b"swift-driver version:1.168.6\n"
        def runner(argv, cwd, stdout, stderr, timeout):
            stdout.write(b"fabricated fixed toolchain version\n")
            if "swift" in argv:
                stderr.write(diagnostic)
            return subprocess.CompletedProcess(argv, 0)
        command = release.release_commands(self.evidence, runner)
        with patch.object(verify.shutil, "which", side_effect=lambda executable: executable):
            full = release.read_toolchain(command, prefix="full-")
            selected = verify.selected_toolchain(command, self.plan, prefix="selected-")
        self.assertEqual(full["swift"], "fabricated fixed toolchain version")
        self.assertEqual(selected, {name: full[name] for name in selected})
        for prefix in ("full-", "selected-"):
            self.assertEqual((self.evidence / (prefix + "swift.stderr.log")).read_bytes(), diagnostic)

    def changed_receipt(self, receipt):
        return {**receipt, "artifacts": release.verification_artifacts(self.evidence, full=False)}

    def test_exact_suite_inventory_is_the_completed_execution(self):
        receipt = self.run_route()
        core = release.read_json(self.evidence / "completed.json")["checks"]["core"]
        expected = sorted(function["payload"]["id"] for function in self.functions[:2])
        self.assertEqual(core["planned"], expected)
        self.assertEqual(core["executed"], expected)
        self.assertEqual(verify.validate_selected(self.root, self.evidence, receipt), receipt)
        self.assertFalse(any("xcodebuild" in argv or "xcrun" in argv for argv in self.calls))
        self.assertFalse(any("prepare_notebook_codex.py" in value for argv in self.calls for value in argv))
        self.assertTrue(all("environment" not in entry for entry in verify.read_commands(self.evidence)))

    def test_pinned_node_binds_selected_toolchain_children_and_recorded_environment(self):
        self.plan["profiles"] = ["compiler"]
        original_path = os.environ.get("PATH")
        receipt = self.run_route()
        commands = verify.read_commands(self.evidence)
        expected_path = str(self.codex_stage) + os.pathsep + (original_path or "")
        node = next(entry for entry in commands if entry["label"] == "toolchain-node")
        self.assertEqual(node["argv"], [str(self.codex_stage / "node"), "--version"])
        self.assertEqual(node["environment"], {"PATH": expected_path})
        self.assertEqual(release.read_json(self.evidence / "toolchain.json")["node"], self.codex_runtime["node"])
        self.assertEqual(sum(entry["label"] == "codex-resources" for entry in commands), 1)
        self.assertEqual(receipt["codexRuntime"], release.notebook_codex.identity(self.codex_runtime))
        self.assertEqual(os.environ.get("PATH"), original_path)
        dependency = next(entry for entry in commands if entry["label"] == "mcp-dependencies")
        dependency["environment"]["PATH"] = "/foreign/node:" + (original_path or "")
        release.write_json(self.evidence / "commands.json", commands)
        with self.assertRaisesRegex(release.ReleaseError, "PATH подготовленного Node"):
            verify.validate_selected(self.root, self.evidence, self.changed_receipt(receipt))

    def test_missing_or_renamed_selector_refuses_before_execution(self):
        self.plan["checks"]["core"] = ["MissingSuite", "WantedSuite"]
        with self.assertRaisesRegex(release.ReleaseError, "фактическом инвентаре"):
            self.run_route()
        self.assertFalse(any("--skip-build" in argv for argv in self.calls))
        self.assertFalse((self.evidence / "verification.json").exists())

    def test_multiple_products_keep_full_inventory_and_distinct_execution_reports(self):
        self.functions.append(self.function("WantedSuite", "third", "NotebookCodexTests"))
        self.plan["checks"]["core"] = ["NotebookCodexTests.WantedSuite", "NotebookCoreTests.WantedSuite"]
        receipt = self.run_route()
        core = release.read_json(self.evidence / "completed.json")["checks"]["core"]
        self.assertEqual(len(core["executed"]), 3)
        self.assertEqual(sum(core["executions"].values()), 3)
        commands = verify.read_commands(self.evidence)
        self.assertEqual([entry["label"] for entry in commands if "--test-product" in entry["argv"]],
                         ["core-NotebookCodexTests", "core-NotebookCoreTests"])
        for product in ("NotebookCodexTests", "NotebookCoreTests"):
            self.assertTrue((self.evidence / ("core-" + product + "-events.jsonl")).is_file())
        self.assertEqual(verify.validate_selected(self.root, self.evidence, receipt), receipt)

    def test_truncated_machine_stdout_refuses_even_beside_valid_inventory(self):
        path = self.root / "machine.stdout.log"
        path.write_text("human readable ID\n" + json.dumps(self.functions[0]) + '\n{"kind":')
        with self.assertRaisesRegex(release.ReleaseError, "Malformed report"):
            reports.swift_stdout(path)

    def test_parameterized_execution_requires_balanced_nonempty_case_events(self):
        function = copy.deepcopy(self.functions[0])
        function["payload"]["isParameterized"] = True
        identity = function["payload"]["id"]
        records = self.execution([function])
        with self.assertRaises(release.ReleaseError):
            reports.swift_execution(records, [identity], self.root)
        for kind in ("testCaseStarted", "testCaseStarted", "testCaseEnded", "testCaseEnded"):
            records.insert(-2, self.event(kind, identity))
        self.assertEqual(reports.swift_execution(records, [identity], self.root)["executions"], {identity: 2})
        records.pop(-3)
        with self.assertRaises(release.ReleaseError):
            reports.swift_execution(records, [identity], self.root)

    def test_partial_suite_cannot_hide_behind_a_passed_function_or_summary(self):
        self.execution_override = self.execution(self.functions[:1])
        with self.assertRaises(release.ReleaseError):
            self.run_route()
        self.assertFalse((self.evidence / "verification.json").exists())

    def test_skipped_selected_function_refuses_pass(self):
        self.execution_override = self.execution()
        self.execution_override.insert(-1, self.event("testSkipped", self.functions[0]["payload"]["id"]))
        with self.assertRaises(release.ReleaseError):
            self.run_route()

    def test_unrelated_passed_id_cannot_satisfy_the_selected_plan(self):
        self.execution_override = self.execution([self.functions[2]])
        with self.assertRaises(release.ReleaseError):
            self.run_route()

    def test_missing_run_end_or_malformed_events_refuse_pass(self):
        for events in (self.execution()[:-1], [{"version": "6.4.0", "payload": "broken"}], ["not an event"],
                       [*self.execution(), self.event("unsupported-event")]):
            with self.subTest(events=events):
                with self.assertRaises(release.ReleaseError):
                    reports.swift_execution(events, [function["payload"]["id"] for function in self.functions[:2]], self.root)

    def test_altered_core_argv_or_source_cwd_refuses_even_rehashed_receipt(self):
        receipt = self.run_route()
        original = json.loads((self.evidence / "commands.json").read_bytes())
        for field, value in (("argv", ["swift", "test", "--filter", "OtherSuite"]), ("cwd", str(self.root / "other-source"))):
            with self.subTest(field=field):
                commands = copy.deepcopy(original)
                next(command for command in commands if command["label"] == "core-NotebookCoreTests")[field] = value
                release.write_json(self.evidence / "commands.json", commands)
                with self.assertRaisesRegex(release.ReleaseError, "argv или источник"):
                    verify.validate_selected(self.root, self.evidence, self.changed_receipt(receipt))

    def test_compiled_inventory_from_another_source_refuses(self):
        self.functions[0]["payload"]["sourceLocation"]["filePath"] = "/another-checkout/Tests/Contracts.swift"
        with self.assertRaisesRegex(release.ReleaseError, "another source"):
            self.run_route()

    def test_schema_requires_the_emitted_swift_semantic_version(self):
        for version in (0, "6.4", "6.5.0", None):
            with self.subTest(version=version):
                record = {**self.functions[0], "version": version}
                with self.assertRaisesRegex(release.ReleaseError, "версия Swift"):
                    reports.swift_inventory([record], self.root)

    def test_locked_physical_ipad_refuses_before_preparation_or_native_runner(self):
        self.plan["checks"]["core"] = []
        self.plan["checks"]["ipad"] = ["NotebookTests/Contract"]
        def runner(argv, cwd, stdout, stderr, timeout):
            self.calls.append(list(argv))
            command_type = "devicectl.device.info.details" if "details" in argv else "devicectl.device.info.lockState"
            result = {} if "details" in argv else {"deviceIdentifier": release.DEVICE,
                                                    "passcodeRequired": True, "unlockedSinceBoot": True}
            destination = Path(argv[argv.index("--json-output") + 1])
            release.write_json(destination, {"info": {"commandType": command_type, "outcome": "success"}, "result": result})
            return subprocess.CompletedProcess(argv, 0)
        recorder = release.release_commands
        with patch.object(verify, "selected_toolchain", return_value={"fixture": "bounded lock-state preflight"}), \
             patch.object(release, "validate_device", return_value={}), \
             patch.object(release, "release_commands", side_effect=lambda evidence, **options: recorder(evidence, runner, **options)), \
             self.assertRaisesRegex(release.ReleaseError, "требует ввода кода"):
            verify.run_selected(self.root, self.plan, self.evidence)
        self.assertEqual(len(self.calls), 2)
        self.assertIn("lockState", self.calls[-1])
        self.assertFalse((self.evidence / "verification.json").exists())

    def test_lock_state_requires_the_agreed_device_and_boolean_readiness(self):
        state = {"deviceIdentifier": release.DEVICE, "passcodeRequired": False, "unlockedSinceBoot": True}
        verify.validate_ipad_lock_state(state)
        for patch_state in ({"deviceIdentifier": "other-device"}, {"passcodeRequired": "false"},
                            {"unlockedSinceBoot": None}, {"unlockedSinceBoot": False}):
            with self.subTest(state=patch_state), self.assertRaises(release.ReleaseError):
                verify.validate_ipad_lock_state({**state, **patch_state})

    def test_ipad_autolock_after_build_or_enumeration_refuses_before_the_next_launch(self):
        self.plan["checks"]["core"] = []
        self.plan["checks"]["ipad"] = ["NotebookTests/Contract"]
        recorder = release.release_commands
        for phase in ("inventory", "execution"):
            with self.subTest(phase=phase):
                self.calls = []
                self.evidence = self.root / (".build/locked-" + phase)
                def runner(argv, cwd, stdout, stderr, timeout, env=None):
                    self.calls.append(list(argv))
                    if "lockState" in argv or "details" in argv:
                        destination = Path(argv[argv.index("--json-output") + 1])
                        lock = "lockState" in argv
                        result = {"deviceIdentifier": release.DEVICE, "passcodeRequired": destination.stem.endswith("-" + phase),
                                  "unlockedSinceBoot": True} if lock else {}
                        release.write_json(destination, {"info": {"outcome": "success", "commandType":
                            "devicectl.device.info." + ("lockState" if lock else "details")}, "result": result})
                    elif any(value.endswith("prepare_notebook_codex.py") for value in argv):
                        if not self.codex_stage.exists():
                            codex_fixture.stage(self.codex_stage, self.codex_runtime, self.codex_files)
                        stdout.write(json.dumps(codex_fixture.report(self.codex_stage, self.codex_runtime)).encode())
                    elif "-enumerate-tests" in argv:
                        destination = Path(argv[argv.index("-test-enumeration-output-path") + 1])
                        release.write_json(destination, {"tests": ["NotebookTests/Contract/testAction"]})
                    return subprocess.CompletedProcess(argv, 0)
                with patch.object(verify, "selected_toolchain", return_value={"fixture": "autolock after preparation", "node": self.codex_runtime["node"]}), \
                     patch.object(release, "validate_device", return_value={}), \
                     patch.object(release, "release_commands", side_effect=lambda evidence, **options: recorder(evidence, runner, **options)), \
                     self.assertRaisesRegex(release.ReleaseError, "требует ввода кода"):
                    verify.run_selected(self.root, self.plan, self.evidence)
                self.assertTrue(any("build-for-testing" in argv for argv in self.calls))
                self.assertEqual(any("-enumerate-tests" in argv for argv in self.calls), phase == "execution")
                self.assertFalse(any("test-without-building" in argv and "-enumerate-tests" not in argv for argv in self.calls))
                self.assertFalse((self.evidence / "verification.json").exists())

    def test_compiler_runtime_is_prepared_before_inventory_and_missing_preparation_refuses_receipt(self):
        self.plan["profiles"] = ["compiler"]
        self.plan["checks"]["core"] = ["NotebookCompilerProcessTests"]
        self.functions = [self.function("NotebookCompilerProcessTests", "first"), self.function("NotebookCompilerProcessTests", "second")]
        receipt = self.run_route()
        preparation = next(index for index, argv in enumerate(self.calls) if any(value.endswith("prepare_notebook_typescript.py") for value in argv))
        inventory = next(index for index, argv in enumerate(self.calls) if "list" in argv)
        self.assertLess(preparation, inventory)
        self.assertIn("NOTEBOOK_TYPESCRIPT_RUNTIME=" + str(self.root / ".build/notebook-typescript-runtime/stages/pinned"), self.calls[inventory])
        commands = json.loads((self.evidence / "commands.json").read_bytes())
        release.write_json(self.evidence / "commands.json", [command for command in commands if command["label"] != "typescript-resources"])
        with self.assertRaisesRegex(release.ReleaseError, "typescript-resources"):
            verify.validate_selected(self.root, self.evidence, self.changed_receipt(receipt))

    def test_unknown_route_and_old_receipt_refuse(self):
        self.plan["checks"]["commands"] = ["invented-route"]
        with self.assertRaisesRegex(release.ReleaseError, "Неизвестный маршрут"):
            self.run_route()
        with self.assertRaises(release.ReleaseError):
            verify.validate_selected(self.root, self.evidence, {"format": 1, "status": "passed", "route": "./verify.sh:selected"})

    def test_contract_receipt_cannot_claim_physical_acceptance_or_a_different_scope(self):
        receipt = self.run_route()
        for changed in ({"scope": "physical-acceptance"}, {"physicalAcceptance": True}, {"physicalAcceptance": 0}):
            with self.subTest(receipt=changed), self.assertRaisesRegex(release.ReleaseError, "область приёмки"):
                verify.validate_selected(self.root, self.evidence, {**receipt, **changed})

    def test_independent_core_checkout_can_run_beside_native_but_shared_owners_serialize(self):
        locks = self.root / "locks"
        locks.mkdir()
        other = self.root / "other-checkout"
        other.mkdir()
        native_plan = copy.deepcopy(self.plan)
        native_plan["checks"]["ipad"] = ["NotebookTests/Contract"]
        with patch.object(verify.tempfile, "gettempdir", return_value=str(locks)):
            with verify.verification_slot(self.root, native_plan):
                with verify.verification_slot(other, self.plan):
                    with self.assertRaises(release.ReleaseError):
                        with verify.verification_slot(other, self.plan):
                            self.fail("A shared checkout admitted two routes")
                with self.assertRaises(release.ReleaseError):
                    with verify.verification_slot(other, native_plan):
                        self.fail("Two routes admitted the same native runner")
                with self.assertRaises(release.ReleaseError):
                    with verify.verification_slot(self.root, self.plan):
                        self.fail("A native preparation admitted a shared checkout route")
            with verify.verification_slot(self.root, native_plan):
                pass

    def test_real_python_reporter_preserves_inventory_and_rejects_skip(self):
        script = self.root / "Tests/test_contract.py"
        for skip in (False, True):
            with self.subTest(skip=skip):
                script.write_text("import unittest\nclass Contract(unittest.TestCase):\n"
                                  + (" @unittest.skip('required owner unavailable')\n" if skip else "")
                                  + " def test_action(self): pass\n")
                self.evidence.mkdir(parents=True, exist_ok=True)
                result = subprocess.run([sys.executable, "-B", str(ROOT / "Applications/notebook_python_checks.py"),
                            "--script", str(script), "--evidence", str(self.evidence), "--check", "python"], capture_output=True)
                self.assertEqual(result.returncode, int(skip))
                inventory = release.read_json(self.evidence / "python-inventory.json")
                execution = release.read_json(self.evidence / "python-execution.json")
                if skip:
                    with self.assertRaises(release.ReleaseError):
                        reports.python_execution(inventory, execution, script)
                else:
                    self.assertEqual(reports.python_execution(inventory, execution, script)["planned"], inventory["tests"])


if __name__ == "__main__":
    unittest.main(verbosity=2)

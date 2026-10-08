#!/usr/bin/env python3
"""Select checks by the changed owner; full acceptance is an explicit operation."""
import argparse
from contextlib import contextmanager, ExitStack
import fcntl
import hashlib
import json
import math
import shutil
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import time

import notebook_release as release

ROOT = Path(__file__).resolve().parents[1]
UI = "NotebookUITests/DrawingResponsivenessTests/"
NATIVE_IPAD_BUNDLE = release.CANONICAL + ".native-test"
NATIVE_IPAD_UI_RUNNER = release.CANONICAL + ".uitests.xctrunner"
from notebook_check_registry import CHECKS, COMMANDS, PROFILES, full_checks, native, selected_checks
import notebook_check_reports as reports

DOCUMENT_BROWSER_CONTRACTS = tuple(value for value in COMMANDS["document-browser"].command if value.endswith(".mjs"))



def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args])


def document_browser_arguments(root):
    return portable_arguments(root, Path("/unused"), "document-browser")[0]


def changed_files(root, base):
    commit = git(root, "rev-parse", "--verify", base + "^{commit}").decode().strip()
    paths = set(git(root, "diff", "--name-only", "-z", commit, "--").decode().split("\0"))
    paths.update(git(root, "ls-files", "--others", "--exclude-standard", "-z").decode().split("\0"))
    return commit, sorted(paths - {""})


def owners(path):
    """An unclassified implementation never silently falls back to all tests."""
    if path == "AGENTS.md" or path.startswith("docs/") or path == "README.md":
        return []
    if path in ("verify.sh", "Applications/notebook_verification.py", "Applications/notebook_release.py", "Applications/notebook_check_registry.py", "Applications/notebook_check_reports.py", "Applications/notebook_python_checks.py", "Applications/notebook_node_reporter.mjs", "Applications/prepare_notebook_codex.py", "Applications/NotebookCodexRuntime.lock.json", "Applications/NotebookCodexResources.xcfilelist") or path.startswith(("Tests/NotebookVerification/", "Tests/NotebookRelease/")):
        return ["verification"]
    if path.startswith("MCP/"):
        return ["mcp"]
    if path in DOCUMENT_BROWSER_CONTRACTS or (path.startswith("Applications/WebResources/")
                                             and Path(path).name.startswith("document-")):
        return ["document-web"]
    if path.startswith("Tests/NotebookDocumentAcceptance/"):
        return ["acceptance-bootstrap"]
    name = Path(path).name
    if path.startswith(("Sources/NotebookScript", "Sources/NotebookMarkupService/", "Sources/CQuickJS/", "Tests/NotebookScriptHostTests/", "Tests/NotebookScriptWorkerTests/")) or name.startswith("NotebookScript") or name in ("NotebookActionSubmission.swift", "NotebookPublicProtocolTests.swift"):
        return ["script-runtime"]
    if path.startswith("Sources/NotebookAcceptance/") or name in (
        "NotebookAcceptanceConfiguration.swift", "NotebookAcceptanceLaunchTests.swift", "notebook_acceptance.py",
        "NotebookSystemTraceIdentitySurface.swift", "NotebookSystemTraceHandshake.swift"):
        return ["acceptance-bootstrap"]
    if name.startswith("NotebookPresentation"):
        return ["presentation"]
    if name in ("NotebookComputerStore.swift", "NotebookComputerStoreTests.swift", "NotebookComputerControllerTests.swift"):
        return ["computers"]
    if "Dictation" in name:
        return ["dictation"]
    if "Voice" in name or "Wake" in name or name.startswith("voice-") or path.startswith("Tests/NotebookVoiceHarness/"):
        return ["voice"]
    if name in ("NotebookProjectRun.swift", "NotebookRunStore.swift", "MacNotebookProjectRuns.swift", "NotebookRunController.swift", "NotebookTerminalView.swift", "NotebookRunStoreTests.swift", "NotebookProjectRunsTests.swift", "NotebookRunControllerTests.swift") or name.startswith(("terminal-", "xterm")):
        return ["project-runs"]
    if name in ("NotebookCodeLink.swift", "NotebookCodeImageRenderer.swift", "NotebookCodeDiscussionTests.swift"):
        return ["code-discussion"]
    if name in ("NotebookArchiveEnrollment.swift", "ArchiveComputerPreparation.swift", "ArchiveComputerPreparationTests.swift"):
        return ["computer-enrollment"]
    if name in ("NotebookCodeFragment.swift", "NotebookCodeStore.swift", "NotebookCodeAnnotations.swift",
                "NotebookCodeInkView.swift", "NotebookCodeFragmentTests.swift", "NotebookCodeStoreTests.swift",
                "NotebookCodeAnnotationsTests.swift"):
        return ["code-notes"]
    if path.startswith(("Sources/NotebookCodex/", "Tests/NotebookCodexTests/", "Tests/NotebookCodexBridgeHarness/")):
        return ["codex"]
    if name in ("NotebookProjectFile.swift", "NotebookFileStore.swift", "MacNotebookProjectFiles.swift",
                "NotebookFileController.swift", "NotebookCodeDocumentView.swift", "NotebookProjectFilesView.swift",
                "NotebookProjectFileTests.swift", "NotebookProjectFilesTests.swift", "NotebookFileControllerTests.swift"):
        return ["project-files"]
    if name in ("DocumentPagePreparation.swift", "SpatialInkSurfaceView.swift", "SpatialBoardInkHandoff.swift") or path == "Applications/TestSupport/DocumentLargeSourceTests.swift":
        return ["paper-resources"]
    if path == "Applications/iPad/SpatialWorkspaceView.swift":
        return ["scene-composition", "documents", "navigation-ux"]
    if name in ("NotebookSubmittedPixels.swift", "NotebookWorkspacePresentation.swift", "NotebookPinnedImageRenderer.swift",
                "NotebookAttentionProjection.swift", "NotebookAttentionSelection.swift", "NotebookCoverPresentation.swift",
                "PagePresentation.swift"):
        return ["submitted-pixels"]
    if name in ("NotebookDocumentFileRead.swift", "NotebookDocumentStateCommand.swift", "DocumentFilesTests.swift",
                "PhysicalWebViewport.swift", "NotebookDocumentOpeningTests.swift"):
        return ["documents"]
    if name in ("SceneCompositionTiles.swift", "SceneCompositionSource.swift", "SceneCompositionTests.swift"):
        return ["scene-composition", "navigation-ux"]
    if name in ("AgentWebElementView.swift", "PreparedAgentElementView.swift", "PageRasterPreparation.swift",
                "SceneWebRasterPreparation.swift", "AgentOverlayView.swift", "PageSurface.swift",
                "NotebookPageNavigation.swift", "NotebookNavigationView.swift", "SceneRenderResources.swift"):
        return ["navigation-ux"]
    if name == "NotebookChatPanel.swift":
        return ["chat", "chat-touch"]
    if name in ("NotebookRootView.swift", "NotebookCollaborationView.swift", "NotebookChatWindow.swift"):
        return ["chat", "chat-touch", "workspace-controls"]
    if "Chat" in name or name in ("NotebookCodexSidecar.swift",):
        return ["chat"]
    if name in ("IPadPageTurnController.swift", "IPadSheetCurlController.swift", "SheetCurlRenderer.swift", "PageTurnSurface.swift"):
        return ["documents", "page-turn", "navigation-ux"]
    if (name.startswith("Document") or name.startswith("document-")) and path.startswith("Applications/"):
        return ["documents"]
    return None


def test_selector(path):
    for prefix, target in (("Applications/MacTests/", "NotebookMacTests"), ("Applications/Tests/", "NotebookTests")):
        if path.startswith(prefix) and path.endswith("Tests.swift"):
            # This suite contains a 100k-record fixture. It must be requested by method.
            if Path(path).stem in ("NotebookPageAddressTests", "SceneCompositionTests"):
                return None
            return ("mac" if target == "NotebookMacTests" else "ipad", target + "/" + Path(path).stem)
    return None


def matching_native_tests(root, path):
    """Use adjacent test naming, not an exhaustive implementation-file map.

    This suggests a local contract, not all effects of a shared implementation.
    Cross-owner regressions and UI gestures remain an explicit scope decision.
    """
    file = Path(path)
    platforms = {
        "Applications/Shared": ("Tests", "MacTests"),
        "Applications/iPad": ("Tests",),
        "Applications/Mac": ("MacTests",),
        "Applications/TestSupport": ("Tests", "MacTests"),
    }.get(str(file.parent), ())
    if file.suffix != ".swift":
        return []
    suite = file.stem if file.stem.endswith("Tests") else file.stem + "Tests"
    result = []
    for folder in platforms:
        candidate = "Applications/" + folder + "/" + suite + ".swift"
        if (root / candidate).is_file() or (root / "Applications/TestSupport" / (suite + ".swift")).is_file():
            selector = test_selector(candidate)
            if selector:
                result.append(selector)
    return result


def version_only(root, commit, path):
    if path not in ("Applications/project.yml", "MCP/package.json", "MCP/package-lock.json"):
        return False
    try:
        before = git(root, "show", commit + ":" + path).decode()
        after = (root / path).read_text()
    except (OSError, subprocess.CalledProcessError):
        return False
    if path.startswith("MCP/"):
        try:
            left, right = json.loads(before), json.loads(after)
            for value in (left, right):
                value.pop("version", None)
                if path.endswith("package-lock.json"):
                    value.get("packages", {}).get("", {}).pop("version", None)
            return before != after and left == right
        except (ValueError, AttributeError):
            return False
    pattern = r'(?m)^(\s*(?:MARKETING_VERSION|CURRENT_PROJECT_VERSION):\s*)[^\n]+'
    return before != after and re.sub(pattern, r"\1<version>", before) == re.sub(pattern, r"\1<version>", after)


def make_plan(root, base="HEAD", profiles=(), tests=(), only=False):
    release.require(not only or profiles or tests, "--only требует явный --profile или --test.")
    commit, paths = changed_files(root, base)
    selected = set(profiles)
    unknown = []
    direct = []
    for path in paths:
        if version_only(root, commit, path):
            continue
        # Shared UI fixtures have no production behavior to certify. Their
        # caller must name the real gesture(s); a broad profile cannot silently
        # select all UI cases or pretend that native tests exercised a tap.
        if path in ("Applications/iPad/NotebookDrawingFixture.swift", "Applications/UITests/DrawingResponsivenessTests.swift"):
            if not any(t.startswith("NotebookUITests/") and t.count("/") == 2 for t in tests):
                unknown.append(path)
            continue
        test = test_selector(path)
        found = owners(path)
        # Keep explicit gesture/resource routes; use the closest native suite
        # instead of expanding every document file into the integration profile.
        nearby = matching_native_tests(root, path) if found in (None, ["documents"]) else []
        if test:
            if not only:
                direct.append(test)
        elif nearby:
            if not only:
                direct.extend(nearby)
        elif found is None:
            unknown.append(path)
        elif not only:
            selected.update(found)
    checks = {key: set() for key in ("core", "mac", "ipad", "commands")}
    release.require(not selected - set(PROFILES), "Неизвестный профиль: " + ", ".join(sorted(selected - set(PROFILES))))
    for check in selected_checks(selected):
        checks[check.platform].update((check.id,) if check.platform == "commands" else check.selectors)
    for key, value in direct:
        checks[key].add(value)
    for test in tests:
        target = test.split("/", 1)[0]
        if target in ("NotebookCoreTests", "NotebookCodexTests", "NotebookScriptHostTests", "NotebookScriptWorkerTests", "NotebookArchiveTransferTests"):
            release.require(re.fullmatch(r"[A-Za-z0-9_/]+", test) and "/" in test,
                            "Укажите точный Swift target/suite[/function].")
            checks["core"].add(test.replace("/", ".", 1))
            continue
        if target not in ("NotebookMacTests", "NotebookTests", "NotebookUITests") or not re.fullmatch(r"[A-Za-z0-9_/]+", test) or "/" not in test:
            raise release.ReleaseError("Укажите точный XCTest target/suite[/method], не весь target.")
        if target == "NotebookUITests" and test.count("/") < 2:
            raise release.ReleaseError("UI запускается по сценарию, не всем 44 тестам сразу.")
        checks["mac" if target == "NotebookMacTests" else "ipad"].add(test)
    return {"format": 2, "sourceRoot": str(root.resolve()), "baseCommit": commit, "changedFiles": paths, "profiles": sorted(selected),
            "unclassified": unknown, "manualSelection": bool(profiles or tests),
            "selectionMode": "explicit-only" if only else "changed-owners",
            "checks": {key: sorted(values) for key, values in checks.items()}}


def full_plan(root):
    checks = {key: set() for key in ("core", "mac", "ipad", "commands")}
    for check in full_checks():
        checks[check.platform].update((check.id,) if check.platform == "commands" else check.selectors)
    return {"format": 2, "sourceRoot": str(root.resolve()), "selectionMode": "full-registry",
            "profiles": [], "unclassified": [], "manualSelection": True,
            "checks": {key: sorted(values) for key, values in checks.items()},
            "notice": "Все контракты реестра; физическая и системная приёмка фиксируется отдельно."}


def validate_plan(plan):
    release.require(isinstance(plan, dict) and plan.get("format") == 2
                    and isinstance(plan.get("sourceRoot"), str) and Path(plan["sourceRoot"]).is_absolute(),
                    "Нет текущего плана проверки с владельцем исходников.")
    checks = plan.get("checks")
    release.require(isinstance(checks, dict) and set(checks) == {"core", "mac", "ipad", "commands"}
                    and all(isinstance(values, list) and all(isinstance(value, str) and value for value in values)
                            and values == sorted(set(values)) for values in checks.values()), "Malformed check plan")
    release.require(not set(checks["commands"]) - set(COMMANDS), "Неизвестный маршрут проверки.")
    if plan.get("selectionMode") == "full-registry":
        release.require(checks == full_plan(Path(plan["sourceRoot"]))["checks"], "Полный маршрут не совпадает с реестром.")
    return checks


def prerequisites(plan):
    checks = plan["checks"]
    required = set()
    declared = full_checks() if plan.get("selectionMode") == "full-registry" else selected_checks(plan.get("profiles", []))
    for check in declared:
        required.update(check.prerequisites)
    for name in checks["commands"]:
        required.update(COMMANDS[name].prerequisites)
    for platform in ("mac", "ipad"):
        if checks[platform]:
            required.update(native("explicit/" + platform, "", platform, checks[platform]).prerequisites)
    for check in CHECKS:
        if check.platform != "core" or not check.prerequisites:
            continue
        for selector in checks["core"]:
            components = selector.replace(".", "/").split("/")
            if any(value in components or value == selector for value in check.selectors):
                required.update(check.prerequisites)
    if checks["mac"] or checks["ipad"] or "darwin" in required or required & {"mcp-dependencies", "recognition-dependencies"} or any(
            COMMANDS[name].parser == "node-events" for name in checks["commands"]):
        required.add("codex")
    return required


def selected_toolchain(command, plan, prefix="toolchain-"):
    checks = plan["checks"]
    required = prerequisites(plan)
    codex_stage = prepared_codex_stage(plan) if "codex" in required else None
    if checks["mac"] or checks["ipad"] or "darwin" in required:
        return release.read_toolchain(command, prefix=prefix, codex_stage=codex_stage)
    executables = {"python": [sys.executable, "--version"]}
    if checks["core"] or prerequisites(plan) & {"ipc-host", "typescript"} or any(
            COMMANDS[name].parser in ("exit-contract", "json-contract") for name in checks["commands"]):
        executables["swift"] = ["swift", "--version"]
    if codex_stage:
        executables["node"] = [str(codex_stage / "node"), "--version"]
    if prerequisites(plan) & {"mcp-dependencies", "recognition-dependencies"}:
        executables["npm"] = ["npm", "--version"]
    result = {}
    for name, argv in executables.items():
        release.require(shutil.which(argv[0]) is not None, "Не найден prerequisite: " + argv[0])
        result[name] = release.read_tool_version(command, name, argv, prefix=prefix)
    return result


def portable_arguments(root, evidence, name):
    check = COMMANDS[name]
    if check.parser == "python-unittest":
        return ([sys.executable, "-B", str(root / "Applications/notebook_python_checks.py"),
                 "--script", str(root / check.command[0]), "--evidence", str(evidence), "--check", name], root, [root / check.command[0]])
    if check.parser == "node-events":
        scripts = []
        argv = []
        for value in check.command:
            if "*" in value:
                files = sorted(root.glob(value))
                release.require(files, "Не найден prerequisite: " + value)
                scripts.extend(files)
                argv.extend(str(path) for path in files)
            elif value.endswith((".mjs", ".ts", ".js")):
                scripts.append(root / value)
                argv.append(str(root / value))
            else:
                argv.append(value)
        argv.insert(argv.index("--test") + 1, "--test-reporter=" + str(root / "Applications/notebook_node_reporter.mjs"))
        return argv, root / "MCP" if name == "mcp" else root, scripts
    argv = [str(root / value) if "/" in value else value for value in check.command]
    scripts = [root / value for value in check.command if value.endswith((".sh", ".py", ".mjs", ".ts", ".js"))]
    if check.command[0].endswith(".py"):
        argv = [sys.executable, "-B", *argv]
    return argv, root / "MCP" if name == "mcp-smoke" else root, scripts


def core_arguments(evidence, expected=None, typescript=None, product=None):
    argv = list(next(check.command for check in CHECKS if check.platform == "core"))
    release.require(isinstance(product, str) and re.fullmatch(r"[A-Za-z0-9_]+", product), "Неверный Swift test product.")
    if expected is None:
        argv.extend(("list", "--disable-xctest", "--test-product", product))
        report = str(evidence / ("core-" + product + "-inventory.jsonl"))
    else:
        release.require(expected and all(identity.startswith(product + ".") for identity in expected), "Неверный Swift test product.")
        argv.extend(("--disable-xctest", "--skip-build", "--test-product", product,
                     "--filter", "^(?:" + "|".join(re.escape(identity) for identity in expected) + ")$"))
        report = str(evidence / ("core-" + product + "-events.jsonl"))
    argv.extend(("--event-stream-output-path", report, "--event-stream-version", "6.4"))
    if typescript:
        argv = ["/usr/bin/env", "NOTEBOOK_TYPESCRIPT_RUNTIME=" + str(typescript), *argv]
    return argv


def check_command(commands, label, argv, cwd):
    entry = next((entry for entry in commands if entry.get("label") == label), None)
    release.require(entry is not None and entry.get("argv") == [str(value) for value in argv]
                    and entry.get("cwd") == str(cwd),
                    "Команда " + label + " исполняла другой набор, argv или источник.")
    return entry


def core_inventory_products(selectors, available):
    selected = set()
    for selector in selectors:
        head = selector.split("/", 1)[0]
        if head in available:
            selected.add(head)
        elif "." in head:
            product = head.split(".", 1)[0]
            release.require(product in available, "Selector names an absent Swift test product: " + product)
            selected.add(product)
        else:
            # A bare suite or '*' can live in any actual test target. Resolve
            # against each product's complete machine inventory, never stdout.
            selected.update(available)
    release.require(selected, "Не выбраны Swift test products.")
    return sorted(selected)


def core_inventory(evidence, selectors, origin, command=None, typescript=None):
    package_argv = ["swift", "package", "describe", "--type", "json"]
    if command:
        command("core-package", package_argv, cwd=origin, timeout=600)
    available = reports.swift_test_products(release.read_json(evidence / "core-package.stdout.log"), origin)
    products = core_inventory_products(selectors, available)
    inventory = {}
    for product in products:
        if command:
            command("core-inventory-" + product, core_arguments(evidence, typescript=typescript, product=product),
                    cwd=origin, timeout=600)
        # SwiftPM's stdout/stderr transport converts arbitrary byte chunks to
        # UTF-8 strings and can drop a chunk split inside a scalar. Each product
        # owns a separate regular event file, outside that lossy text transport.
        records = reports.rows(evidence / ("core-" + product + "-inventory.jsonl"))
        release.require(all(record.get("kind") == "test" for record in records), "Swift inventory contains execution events.")
        inventory.update(reports.swift_inventory(records, origin, product))
    return inventory, products


def core_products(expected):
    products = {}
    for identity in expected:
        product = identity.split(".", 1)[0]
        release.require(re.fullmatch(r"[A-Za-z0-9_]+", product), "Malformed Swift product ID.")
        products.setdefault(product, []).append(identity)
    return products


def core_execution(evidence, expected, origin):
    executions = {}
    for product, identities in core_products(expected).items():
        report = reports.swift_execution(reports.rows(evidence / ("core-" + product + "-events.jsonl")), identities, origin, product)
        executions.update(report["executions"])
    return {"format": 1, "planned": sorted(expected), "executed": sorted(executions),
            "executions": executions, "skipped": [], "failed": []}


def read_commands(evidence):
    path = evidence / "commands.json"
    release.require(path.is_file() and not path.is_symlink() and path.stat().st_size <= 4 * 1024 * 1024,
                    "Отсутствует ограниченный журнал команд.")
    commands = json.loads(path.read_bytes())
    release.require(isinstance(commands, list) and commands
                    and all(isinstance(entry, dict) and type(entry.get("exitCode")) is int and entry["exitCode"] == 0
                            and isinstance(entry.get("argv"), list) and all(isinstance(arg, str) for arg in entry["argv"])
                            and isinstance(entry.get("label"), str) for entry in commands)
                    and len({entry["label"] for entry in commands}) == len(commands),
                    "Команда не завершилась успешно или её отчёт повреждён.")
    return commands


def prepared_typescript(evidence, origin):
    output = release.read_json(evidence / "typescript-resources.stdout.log")
    stage = output.get("stage")
    release.require(output.get("status") == "ready" and isinstance(stage, str) and Path(stage).is_absolute()
                    and Path(stage).is_relative_to(origin / ".build/notebook-typescript-runtime"),
                    "Нет exact TypeScript prerequisite текущего источника.")
    return Path(stage)


def prepared_codex(evidence, origin):
    report = release.read_json(evidence / "codex-resources.stdout.log")
    release.validate_codex_report(report, origin, origin / ".build/notebook-codex-runtimes")
    return report


def prepared_codex_stage(plan):
    value = plan.get("codexRuntimeStage")
    release.require(isinstance(value, str) and Path(value).is_absolute()
                    and str(Path(value).resolve()) == value and re.fullmatch(r"[0-9a-f]{64}", Path(value).name),
                    "Нет точного подготовленного Codex runtime в плане проверки.")
    return Path(value)


def native_test_bundle(node, inherited=""):
    if node.get("nodeType") in ("Unit test bundle", "UI test bundle"):
        name = node.get("name", "")
        return name if name in reports.NATIVE_BUNDLES else ""
    return inherited


def timing_report(tree):
    rows = []
    def walk(node, target=""):
        name = node.get("name", "")
        target = native_test_bundle(node, target)
        if node.get("nodeType") == "Test Case":
            rows.append({"target": target, "test": node.get("nodeIdentifier", name), "seconds": node.get("durationInSeconds", 0)})
        for child in node.get("children", []):
            walk(child, target)
    for node in tree.get("testNodes", []):
        walk(node)
    return {"targets": {target: {"tests": sum(r["target"] == target for r in rows),
                                  "seconds": sum(r["seconds"] for r in rows if r["target"] == target)}
                        for target in sorted({r["target"] for r in rows})},
            "slowest": sorted(rows, key=lambda r: r["seconds"], reverse=True)[:15]}


def validate_summary(summary):
    reports.validate_summary(summary)


def validate_executed_tests(tree, selectors, inventory=None):
    return reports.native_execution(tree, selectors, inventory)


NAVIGATION_HITCH_TESTS = (
    "NotebookNavigationLoadUITests/testContinuousZoomWithProgramsMeetsSystemHitchBudget",
    "NotebookNavigationLoadUITests/testDensePageTurnsMeetSystemHitchBudget",
)
NAVIGATION_HITCH_ITERATIONS = 10
NAVIGATION_HITCH_RATIO_MS_PER_SECOND = 1.0
NAVIGATION_HITCH_TOTAL_SECONDS = 0.033


def selected_hitch_tests(selectors):
    return [case for case in NAVIGATION_HITCH_TESTS if any(
        "NotebookUITests/" + case == selector or ("NotebookUITests/" + case).startswith(selector + "/")
        for selector in selectors)]


def validate_hitch_metrics(metrics, selectors):
    # XCTest collects the actual system metric. A relative per-machine baseline
    # cannot bless a slow run, and absent instrumentation is never zero hitches.
    for case in selected_hitch_tests(selectors):
        runs = [run for test in metrics if test.get("testIdentifier", "").removesuffix("()") == case
                for run in test.get("testRuns", [])]
        release.require(bool(runs), "Нет системного измерения задержек: " + case)
        for run in runs:
            def samples(suffix, units, ceiling, label):
                matches = [metric for metric in run.get("metrics", [])
                           if metric.get("identifier") == "com.apple.dt.XCTMetric_Hitch-native-test." + suffix]
                release.require(len(matches) == 1, "Нет однозначного системного " + label + ": " + case)
                metric = matches[0]
                release.require(metric.get("unitOfMeasurement") in units,
                                "Неизвестная единица " + label + ": " + case)
                values = metric.get("measurements", [])
                release.require(isinstance(values, list) and len(values) >= NAVIGATION_HITCH_ITERATIONS
                                and all(type(value) in (int, float) and math.isfinite(value)
                                        and 0 <= value <= ceiling for value in values),
                                "Нарушен UX-бюджет " + label + ": " + case + " " + repr(values))
                return values

            ratios = samples("time.ratio", ("ms/s", "ms per s"),
                             NAVIGATION_HITCH_RATIO_MS_PER_SECOND, "hitch ratio <= 1 ms/s, 10 повторов")
            # This is TOTAL hitch time in EACH iteration, not a measured maximum
            # frame stall. Capping the sum also bounds any individual hitch and
            # prevents a long gesture/AX wait from diluting a freeze in the ratio.
            durations = samples("total.duration", ("s",), NAVIGATION_HITCH_TOTAL_SECONDS,
                                "суммарных hitches <= 33 ms за повтор")
            release.require(len(ratios) == len(durations), "Неполные пары системных измерений: " + case)


def ipad_lock_arguments(evidence, phase=""):
    release.require(phase in ("", "inventory", "execution"), "Неизвестный этап проверки iPad lock state.")
    name = "physical-ipad-lock-state" + ("-" + phase if phase else "") + ".json"
    return ["xcrun", "devicectl", "device", "info", "lockState", "--device", release.UDID,
            "--timeout", "30", "--json-output", str(evidence / name)]


def validate_ipad_lock_state(state):
    release.require(isinstance(state, dict) and state.get("deviceIdentifier") == release.DEVICE
                    and type(state.get("passcodeRequired")) is bool and type(state.get("unlockedSinceBoot")) is bool,
                    "Malformed physical iPad lock-state report.")
    release.require(state["unlockedSinceBoot"] and not state["passcodeRequired"],
                    "Физический iPad требует ввода кода. Разблокируйте устройство перед native-проверкой.")


def check_ipad_lock(root, evidence, command, phase=""):
    argv = ipad_lock_arguments(evidence, phase)
    command("unlocked-ipad" + ("-" + phase if phase else ""), argv, cwd=root)
    validate_ipad_lock_state(release.successful_json(Path(argv[-1]), "devicectl.device.info.lockState"))


def prepared_typesetter_stage(plan):
    value = plan.get("typesetterRuntime")
    release.require(isinstance(value, str) and Path(value).is_absolute()
                    and str(Path(value).resolve()) == value,
                    "Нет точного подготовленного Typesetter runtime в плане проверки.")
    return Path(value)


def validate_prerequisites(plan, evidence, commands):
    origin = Path(plan["sourceRoot"])
    required = prerequisites(plan)
    definitions = {
        "darwin": (["xcrun", "--sdk", "macosx", "--show-sdk-build-version"], origin),
        "icon-renderer": (["rsvg-convert", "--version"], origin),
        "mcp-dependencies": (["npm", "ci", "--ignore-scripts"], origin / "MCP"),
        "recognition-dependencies": (["npm", "ci", "--ignore-scripts", "--prefix", str(origin / "Tests/NotebookRecognitionHarness")], origin),
        "project": (["xcodegen", "generate", "--spec", "project.yml"], origin / "Applications"),
        "typescript": ([sys.executable, "-B", str(origin / "Applications/prepare_notebook_typescript.py"),
                        "--prepare", "--stage-root", str(origin / ".build/notebook-typescript-runtime")], origin),
        "codex": ([sys.executable, "-B", str(origin / "Applications/prepare_notebook_codex.py"),
                   "--prepare", "--stage-root", str(origin / ".build/notebook-codex-runtimes")], origin),
        "ipc-host": (["swift", "build", "--product", "notebook-ipc-test-host"], origin),
        "physical-ipad": (["xcrun", "devicectl", "device", "info", "details", "--device", release.DEVICE,
                            "--timeout", "30", "--json-output", str(evidence / "physical-ipad.json"),
                            "--omit-deprecated-fields-in-json"], origin),
        "unlocked-ipad": (ipad_lock_arguments(evidence), origin),
    }
    labels = {"project": "generate-project", "typescript": "typescript-resources", "codex": "codex-resources"}
    for prerequisite in required - {"typesetter"}:
        release.require(prerequisite in definitions, "Неизвестный prerequisite: " + prerequisite)
        argv, cwd = definitions[prerequisite]
        check_command(commands, labels.get(prerequisite, prerequisite), argv, cwd)
    if "typescript" in required:
        prepared_typescript(evidence, origin)
    if "codex" in required:
        report = prepared_codex(evidence, origin)
        release.require(str(prepared_codex_stage(plan)) == report["stage"],
                        "Codex prerequisite names another native build stage.")
        release.validate_node_commands(commands, prepared_codex_stage(plan))
        for name in ("toolchain.json", "toolchain-after.json"):
            release.require(release.read_json(evidence / name).get("node") == report["versions"]["node"],
                            "Node toolchain отличается от подготовленного source pin.")
    for platform, sdk in (("mac", "macosx"), ("ipad", "iphoneos")):
        if plan["checks"][platform]:
            check_command(commands, "typesetter-resources-" + sdk,
                          [sys.executable, "-B", str(origin / "Applications/prepare_notebook_typesetter.py"),
                           "--prepare", "--platform", sdk, "--stage", str(prepared_typesetter_stage(plan))], origin)
    if "physical-ipad" in required:
        release.validate_device(release.successful_json(evidence / "physical-ipad.json", "devicectl.device.info.details"))
    if "unlocked-ipad" in required:
        validate_ipad_lock_state(release.successful_json(evidence / "physical-ipad-lock-state.json", "devicectl.device.info.lockState"))


def native_arguments(root, evidence, plan, platform, selectors, action, typescript=None, configured=None):
    destination = "platform=macOS" if platform == "mac" else "platform=iOS,id=" + release.UDID
    derived = Path(tempfile.gettempdir()) / "notebook-selected-builds" / hashlib.sha256(str(root).encode()).hexdigest()[:16]
    if configured:
        release.require(platform == "ipad" and configured.parent == derived / "ipad/Build/Products"
                        and re.fullmatch(r"Notebook_iphoneos[^/]*\.xctestrun", configured.name), "Неверный источник xctestrun.")
        argv = [*native("explicit/" + platform, "", platform, selectors).command,
                "-quiet", "-xctestrun", str(configured), "-destination", destination,
                "-resultBundlePath", str(evidence / "ipad.xcresult"), "-parallel-testing-enabled", "NO",
                "-collect-test-diagnostics", "never", action]
    else:
        argv = [*native("explicit/" + platform, "", platform, selectors).command,
                "-quiet", "-project", "Notebook.xcodeproj", "-scheme",
                "NotebookRuntime" if platform == "mac" else "Notebook", "-configuration", "Debug",
                "-destination", destination, "-derivedDataPath", str(derived / platform),
                "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never", action]
        if action == "test-without-building":
            argv.extend(("-resultBundlePath", str(evidence / (platform + ".xcresult"))))
        if plan.get("optimized", False):
            argv.extend(("SWIFT_OPTIMIZATION_LEVEL=-O", "GCC_OPTIMIZATION_LEVEL=s"))
        argv.extend(native_mac_signing_settings() if platform == "mac" else native_ipad_signing_settings())
        argv.append("NOTEBOOK_TYPESETTER_RUNTIME=" + str(prepared_typesetter_stage(plan)))
        if platform == "mac":
            argv.extend(("NOTEBOOK_TYPESCRIPT_RUNTIME=" + str(typescript),
                         "NOTEBOOK_CODEX_RUNTIME=" + str(prepared_codex_stage(plan))))
    argv.extend("-only-testing:" + selector for selector in selectors)
    return argv


def validate_check_evidence(source, plan, evidence, commands):
    origin = Path(plan["sourceRoot"])
    checks = plan["checks"]
    validate_prerequisites(plan, evidence, commands)
    actual = {}
    typescript = prepared_typescript(evidence, origin) if "typescript" in prerequisites(plan) else None
    if checks["core"]:
        inventory, products = core_inventory(evidence, checks["core"], origin)
        expected = reports.resolve(checks["core"], list(inventory), core=True)
        check_command(commands, "core-package", ["swift", "package", "describe", "--type", "json"], origin)
        release.require([entry["label"] for entry in commands if entry["label"].startswith("core-inventory-")]
                        == ["core-inventory-" + product for product in products], "Swift inventory product commands differ from selection.")
        for product in products:
            check_command(commands, "core-inventory-" + product,
                          core_arguments(evidence, typescript=typescript, product=product), origin)
        for product, identities in core_products(expected).items():
            check_command(commands, "core-" + product, core_arguments(evidence, identities, typescript, product), origin)
        actual["core"] = core_execution(evidence, expected, origin)
        release.require(actual["core"] == release.read_json(evidence / "core-execution.json"), "Swift execution witness изменился.")
    for name in checks["commands"]:
        check = COMMANDS[name]
        argv, cwd, scripts = portable_arguments(origin, evidence, name)
        if name in ("mcp", "mcp-smoke"):
            if name == "mcp":
                check_command(commands, "mcp-check", ["npm", "run", "check"], origin / "MCP")
            check_command(commands, "ipc-binpath", ["swift", "build", "--show-bin-path"], origin)
            binpath = (evidence / "ipc-binpath.stdout.log").read_text().strip()
            release.require(Path(binpath).is_absolute() and Path(binpath).is_relative_to(origin / ".build"), "Неверный IPC host prerequisite.")
            argv = ["/usr/bin/env", "NOTEBOOK_IPC_TEST_HOST=" + str(Path(binpath) / "notebook-ipc-test-host"), *argv]
        check_command(commands, name, argv, cwd)
        if check.parser == "python-unittest":
            current = source / Path(check.command[0])
            actual[name] = reports.python_execution(release.read_json(evidence / (name + "-inventory.json")),
                        release.read_json(evidence / (name + "-execution.json")), current, reported_script=scripts[0])
        elif check.parser == "node-events":
            actual[name] = reports.node_execution(reports.rows(evidence / (name + ".stdout.log")), scripts, origin)
            release.require(release.read_json(evidence / (name + "-inventory.json")) == {"format": 1, "tests": actual[name]["planned"]}
                            and release.read_json(evidence / (name + "-execution.json")) == actual[name], "Node execution witness изменился.")
        else:
            expected = {"format": 1, "planned": [name], "executed": [name], "skipped": [], "failed": []}
            release.require(release.read_json(evidence / (name + "-inventory.json")) == {"format": 1, "tests": [name]}
                            and release.read_json(evidence / (name + "-execution.json")) == expected,
                            "Неполный отчёт исполняемого контракта: " + name)
            if check.parser == "json-contract":
                report = release.read_json(evidence / (name + ".stdout.log"))
                release.require(report.get("status") == check.success, "JSON contract не завершён: " + name)
            actual[name] = expected
    for platform in ("mac", "ipad"):
        if not checks[platform]:
            continue
        release.require((evidence / (platform + ".xcresult")).is_dir(), "Отсутствует xcresult выбранной платформы.")
        inventory = reports.native_inventory(release.read_json(evidence / (platform + "-inventory.json")))
        expected = reports.resolve(checks[platform], inventory)
        tree = release.read_json(evidence / (platform + "-tests.json"))
        actual[platform] = reports.native_execution(tree, checks[platform], inventory)
        reports.validate_summary(release.read_json(evidence / (platform + "-summary.json")), reports.native_outcomes(tree))
        release.require(actual[platform] == release.read_json(evidence / (platform + "-execution.json")), "Native execution witness изменился.")
        if platform == "ipad":
            for phase in ("inventory", "execution"):
                argv = ipad_lock_arguments(evidence, phase)
                check_command(commands, "unlocked-ipad-" + phase, argv, origin)
                validate_ipad_lock_state(release.successful_json(Path(argv[-1]), "devicectl.device.info.lockState"))
        configured = None
        if platform == "ipad" and any(selector.startswith("NotebookUITests/") for selector in expected):
            config = release.read_json(evidence / "ipad-configured-run.json")
            release.require(isinstance(config.get("path"), str), "Нет пути xctestrun текущего runner.")
            configured = Path(config["path"])
        args = native_arguments(origin, evidence, plan, platform, expected, "test-without-building", typescript, configured)
        check_command(commands, platform, args, origin / "Applications")
        enumerate_args = native_arguments(origin, evidence, plan, platform, checks[platform], "test-without-building", typescript, configured)
        enumerate_args = [value for value in enumerate_args if value not in ("-resultBundlePath", str(evidence / (platform + ".xcresult")))]
        enumerate_args.extend(("-enumerate-tests", "-test-enumeration-style", "flat", "-test-enumeration-format", "json",
                               "-test-enumeration-output-path", str(evidence / (platform + "-inventory.json"))))
        check_command(commands, platform + "-inventory", enumerate_args, origin / "Applications")
        check_command(commands, platform + "-build-for-testing",
                      native_arguments(origin, evidence, plan, platform, checks[platform], "build-for-testing", typescript), origin / "Applications")
        if selected_hitch_tests(checks[platform]):
            validate_hitch_metrics(release.read_json(evidence / (platform + "-metrics.json")), checks[platform])
    return actual


def validate_selected(source, evidence, receipt):
    source, evidence = source.resolve(), evidence.resolve()
    release.require(receipt.get("format") == 2 and receipt.get("status") == "passed"
                    and receipt.get("route") in ("./verify.sh:selected", "./verify.sh")
                    and receipt.get("scope") == "registry-contracts" and receipt.get("physicalAcceptance") is False,
                    "Маршрут не завершён текущим проверяющим владельцем или заявляет другую область приёмки.")
    plan = release.read_json(evidence / "selection.json")
    checks = validate_plan(plan)
    release.require((receipt["route"] == "./verify.sh") == (plan.get("selectionMode") == "full-registry"), "Scope receipt не соответствует маршруту.")
    release.require(not plan.get("unclassified") or plan.get("manualSelection"), "Для этих исходников явно выберите достаточные --profile/--test.")
    release.require(not set(plan.get("unclassified", [])) & {"Applications/iPad/NotebookDrawingFixture.swift", "Applications/UITests/DrawingResponsivenessTests.swift"},
                    "Изменённая UI-фикстура требует названного жестового сценария.")
    release.require(receipt.get("source") == release.source_inputs(source)
                    == release.read_json(evidence / "source-before.json") == release.read_json(evidence / "source-after.json"),
                    "Маршрут проверял другой набор исходников.")
    release.require(any(checks.values()), "Пустой план не выдаёт PASS.")
    if "codex" in prerequisites(plan):
        release.require(receipt.get("codexRuntime") == prepared_codex(evidence, Path(plan["sourceRoot"]))["identity"],
                        "Codex verification receipt differs from its source pin.")
    else:
        release.require("codexRuntime" not in receipt, "This verification did not admit a Codex runtime.")
    actual = validate_check_evidence(source, plan, evidence, read_commands(evidence))
    release.require(release.read_json(evidence / "completed.json") == {"format": 2, "checks": actual}, "Не все выбранные проверки исполнены.")
    release.require(release.read_json(evidence / "toolchain.json") == release.read_json(evidence / "toolchain-after.json"), "Инструменты изменились во время проверки.")
    release.require(receipt.get("artifacts") == release.verification_artifacts(evidence, full=False), "Свидетельства выбранного маршрута изменились.")
    return receipt


def native_ipad_signing_settings():
    # Physical verification owns a temporary app, never the admitted pair's
    # container, Keychain group or bundle. DEBUG fixtures use ordinary input.
    return ["-allowProvisioningUpdates", "CODE_SIGN_IDENTITY=Apple Development",
            "CODE_SIGN_STYLE=Automatic", "CODE_SIGNING_ALLOWED=YES",
            "DEVELOPMENT_TEAM=" + release.TEAM, "NOTEBOOK_BUNDLE_SUFFIX=.native-test"]


def native_ipad_cleanup_arguments(bundle=NATIVE_IPAD_BUNDLE):
    # xcodebuild leaves its physical-device test host installed and it can keep
    # running beside the admitted app. Remove only that exact isolated identity;
    # the production bundle and its container are never addressed here.
    script = r'''
import json
import subprocess
import sys
import time

device, bundle = sys.argv[1:]

def installed():
    result = subprocess.run([
        "xcrun", "devicectl", "device", "info", "apps",
        "--device", device, "--include-all-apps", "--bundle-id", bundle,
        "--timeout", "30", "--json-output", "-",
    ], capture_output=True, text=True)
    if result.returncode:
        sys.stderr.write(result.stderr)
        raise SystemExit(result.returncode)
    return [app for app in json.loads(result.stdout)["result"]["apps"]
            if app.get("bundleIdentifier") == bundle]

found = installed()
if found:
    result = subprocess.run([
        "xcrun", "devicectl", "device", "uninstall", "app",
        "--device", device, bundle, "--timeout", "60",
    ], capture_output=True, text=True)
    if result.returncode:
        sys.stderr.write(result.stderr)
        raise SystemExit(result.returncode)
    for _ in range(20):
        if not installed():
            break
        time.sleep(0.1)
if installed():
    raise SystemExit("XCTest bundle остался на физическом iPad: " + bundle)
print(json.dumps({"bundleIdentifier": bundle, "removed": bool(found)}, sort_keys=True))
'''
    release.require(bundle in (NATIVE_IPAD_BUNDLE, NATIVE_IPAD_UI_RUNNER), "Удалять можно только test identity.")
    return [sys.executable, "-B", "-c", script, release.UDID, bundle]


def install_native_ipad_ui_artifacts(products, evidence, command):
    # Keep installation outside the cold-launch watchdog, without prewarming.
    # Use Xcode's generated run file unchanged: CoreDevice still requires local
    # runner bundles and rejects UseDestinationArtifacts before starting tests.
    runs = list(products.glob("Notebook_iphoneos*.xctestrun"))
    release.require(len(runs) == 1, "Нужен один xctestrun текущей сборки iPad.")
    run = plistlib.loads(runs[0].read_bytes())
    release.require(run.get("NotebookUITests", {}).get("IsUITestBundle") is True,
                    "Нет ожидаемого UI target в xctestrun.")
    for name, bundle in (("Notebook.app", NATIVE_IPAD_BUNDLE),
                         ("NotebookUITests-Runner.app", NATIVE_IPAD_UI_RUNNER)):
        info = plistlib.loads((products / "Debug-iphoneos" / name / "Info.plist").read_bytes())
        release.require(info.get("CFBundleIdentifier") == bundle, "Preinstall допускает только test identity.")
    release.require(run["NotebookUITests"].get("UITargetAppPath") == "__TESTROOT__/Debug-iphoneos/Notebook.app",
                    "UI target должен быть приложением текущей сборки.")
    receipt = evidence / "ipad-install-app.json"
    command("ipad-install-app", ["xcrun", "devicectl", "device", "install", "app",
            "--device", release.UDID, products / "Debug-iphoneos/Notebook.app",
            "--timeout", "180", "--json-output", receipt], timeout=200)
    installed = release.successful_json(receipt, "devicectl.device.install.app")
    release.require(any(app.get("bundleID") == NATIVE_IPAD_BUNDLE for app in installed.get("installedApplications", [])),
                    "Установка test bundle не подтверждена.")
    return runs[0]


def native_mac_signing_settings():
    # Native tests have no persistent worker data. Give their sandbox a stable
    # signed identity separate from both the paired stand and the installed app.
    return ["CODE_SIGN_IDENTITY=Apple Development", "CODE_SIGN_STYLE=Automatic",
            "CODE_SIGNING_ALLOWED=YES", "DEVELOPMENT_TEAM=" + release.TEAM,
            "NOTEBOOK_MAC_BUNDLE_SUFFIX=.acceptance", "NOTEBOOK_ACCEPTANCE_ENABLED=YES",
            "NOTEBOOK_SCRIPT_BUNDLE_SUFFIX=.native-test"]


def run_selected(root, plan, evidence):
    root, evidence = root.resolve(), evidence.resolve()
    plan = {**plan, "format": 2, "sourceRoot": str(root)}
    checks = validate_plan(plan)
    release.require(not evidence.exists(), "Для проверки нужен новый каталог свидетельств.")
    evidence.mkdir(parents=True)
    before = release.source_inputs(root)
    release.write_json(evidence / "source-before.json", before)
    release.write_json(evidence / "selection.json", plan)
    required = prerequisites(plan)
    environment = {}
    command = release.release_commands(evidence, environment=environment)
    if "physical-ipad" in required:
        device = evidence / "physical-ipad.json"
        command("physical-ipad", ["xcrun", "devicectl", "device", "info", "details", "--device", release.DEVICE,
                "--timeout", "30", "--json-output", str(device), "--omit-deprecated-fields-in-json"], cwd=root)
        release.validate_device(release.successful_json(device, "devicectl.device.info.details"))
    if "unlocked-ipad" in required:
        check_ipad_lock(root, evidence, command)
    if "codex" in required:
        plan["codexRuntimeStage"] = str(release.prepare_codex_runtime(root, command, environment=environment))
        release.write_json(evidence / "selection.json", plan)
    toolchain = selected_toolchain(command, plan)
    if "codex" in required:
        release.require(toolchain.get("node") == prepared_codex(evidence, root)["versions"]["node"],
                        "Node toolchain отличается от подготовленного source pin.")
    release.write_json(evidence / "toolchain.json", toolchain)
    for prerequisite, argv in (("darwin", ["xcrun", "--sdk", "macosx", "--show-sdk-build-version"]),
                               ("icon-renderer", ["rsvg-convert", "--version"])):
        if prerequisite in required:
            command(prerequisite, argv, cwd=root)
    if "mcp-dependencies" in required:
        command("mcp-dependencies", ["npm", "ci", "--ignore-scripts"], cwd=root / "MCP")
    typescript = None
    if "typescript" in required:
        typescript = release.prepare_typescript_runtime(root, command)
    if "recognition-dependencies" in required:
        command("recognition-dependencies", ["npm", "ci", "--ignore-scripts", "--prefix",
                str(root / "Tests/NotebookRecognitionHarness")], cwd=root)
    ipc_host = None
    if "ipc-host" in required:
        command("ipc-host", ["swift", "build", "--product", "notebook-ipc-test-host"], cwd=root, timeout=600)
        output = command("ipc-binpath", ["swift", "build", "--show-bin-path"], cwd=root, read_output=True)[0]
        binpath = Path(output.decode().strip())
        release.require(binpath.is_absolute() and binpath.is_relative_to(root / ".build"), "Неверный IPC host prerequisite.")
        ipc_host = binpath / "notebook-ipc-test-host"
    if checks["core"]:
        inventory, _ = core_inventory(evidence, checks["core"], root, command, typescript)
        expected = reports.resolve(checks["core"], list(inventory), core=True)
        for product, identities in core_products(expected).items():
            command("core-" + product, core_arguments(evidence, identities, typescript, product), cwd=root, timeout=600)
        release.write_json(evidence / "core-execution.json", core_execution(evidence, expected, root))
    for name in checks["commands"]:
        check = COMMANDS[name]
        argv, cwd, scripts = portable_arguments(root, evidence, name)
        release.require(all(script.is_file() and not script.is_symlink() for script in scripts), "Отсутствует prerequisite источника: " + name)
        if name in ("mcp", "mcp-smoke"):
            if name == "mcp":
                command("mcp-check", ["npm", "run", "check"], cwd=root / "MCP", timeout=300)
            argv = ["/usr/bin/env", "NOTEBOOK_IPC_TEST_HOST=" + str(ipc_host), *argv]
        command(name, argv, cwd=cwd, timeout=600)
        if check.parser == "python-unittest":
            reports.python_execution(release.read_json(evidence / (name + "-inventory.json")),
                                     release.read_json(evidence / (name + "-execution.json")), scripts[0])
        else:
            if check.parser == "node-events":
                execution = reports.node_execution(reports.rows(evidence / (name + ".stdout.log")), scripts, root)
            else:
                if check.parser == "json-contract":
                    release.require(release.read_json(evidence / (name + ".stdout.log")).get("status") == check.success,
                                    "JSON contract не завершён: " + name)
                execution = {"format": 1, "planned": [name], "executed": [name], "skipped": [], "failed": []}
            release.write_json(evidence / (name + "-inventory.json"), {"format": 1, "tests": execution["planned"]})
            release.write_json(evidence / (name + "-execution.json"), execution)
    ipad_ui = any(selector.split("/")[0] == "NotebookUITests" for selector in checks["ipad"])
    if checks["ipad"]:
        command("ipad-native-test-cleanup-before", native_ipad_cleanup_arguments(), timeout=120)
        if ipad_ui:
            command("ipad-ui-runner-cleanup-before", native_ipad_cleanup_arguments(NATIVE_IPAD_UI_RUNNER), timeout=120)
    if checks["mac"] or checks["ipad"]:
        command("generate-project", ["xcodegen", "generate", "--spec", "project.yml"], cwd=root / "Applications")
    derived = Path(tempfile.gettempdir()) / "notebook-selected-builds" / hashlib.sha256(str(root).encode()).hexdigest()[:16]
    for platform in ("ipad", "mac"):
        if not checks[platform]:
            continue
        sdk = "macosx" if platform == "mac" else "iphoneos"
        # The release owner resolves an explicit stage or NOTEBOOK_TYPESETTER_RUNTIME.
        # Capture it once: both platforms and later receipt validation use these
        # exact prepared bytes, independently of the caller's current environment.
        typesetter = release.prepare_typesetter_runtime(root, command, sdk, stage=plan.get("typesetterRuntime"))
        plan["typesetterRuntime"] = str(typesetter)
        release.write_json(evidence / "selection.json", plan)
        try:
            command(platform + "-build-for-testing", native_arguments(root, evidence, plan, platform,
                    checks[platform], "build-for-testing", typescript), cwd=root / "Applications", timeout=1800)
            configured = None
            if platform == "mac":
                app = derived / "mac/Build/Products/Debug/NotebookRuntime.app"
                display = command("mac-native-signer", ["/usr/bin/codesign", "--display", "--verbose=4", app], read_output=True)
                signer, identity = release.development_signer(b"\n".join(display).decode(), release.MAC_BUNDLE + ".acceptance")
                release.restrict_test_script_services(app, root, command, bundle_identifier=release.MAC_BUNDLE + ".acceptance", signing_identity=signer)
                release.write_json(evidence / "mac-native-signature.json", {"identity": identity,
                    "workerBundleSuffix": ".native-test", "scope": "isolated stateless native-test workers"})
            elif ipad_ui:
                configured = install_native_ipad_ui_artifacts(derived / "ipad/Build/Products", evidence, command)
                release.write_json(evidence / "ipad-configured-run.json", {"path": str(configured), "sha256": release.file_digest(configured)})
                (evidence / "ipad-configured-run.plist").write_bytes(configured.read_bytes())
            enumeration = native_arguments(root, evidence, plan, platform, checks[platform], "test-without-building", typescript, configured)
            enumeration = [value for value in enumeration if value not in ("-resultBundlePath", str(evidence / (platform + ".xcresult")))]
            enumeration.extend(("-enumerate-tests", "-test-enumeration-style", "flat", "-test-enumeration-format", "json",
                                "-test-enumeration-output-path", str(evidence / (platform + "-inventory.json"))))
            if platform == "ipad":
                check_ipad_lock(root, evidence, command, "inventory")
            command(platform + "-inventory", enumeration, cwd=root / "Applications", timeout=300)
            inventory = reports.native_inventory(release.read_json(evidence / (platform + "-inventory.json")))
            expected = reports.resolve(checks[platform], inventory)
            args = native_arguments(root, evidence, plan, platform, expected, "test-without-building", typescript, configured)
            if platform == "ipad":
                check_ipad_lock(root, evidence, command, "execution")
            command(platform, args, cwd=root / "Applications", timeout=1800)
            result = evidence / (platform + ".xcresult")
            for report in ("summary", "tests"):
                output = command(platform + "-" + report, ["xcrun", "xcresulttool", "get", "test-results", report,
                                 "--path", str(result), "--compact"], read_output=True)[0]
                release.write_json(evidence / (platform + "-" + report + ".json"), json.loads(output))
            tree = release.read_json(evidence / (platform + "-tests.json"))
            execution = reports.native_execution(tree, checks[platform], inventory)
            reports.validate_summary(release.read_json(evidence / (platform + "-summary.json")), reports.native_outcomes(tree))
            release.write_json(evidence / (platform + "-execution.json"), execution)
            release.write_json(evidence / (platform + "-timings.json"), timing_report(tree))
            if selected_hitch_tests(checks[platform]):
                metrics = command(platform + "-metrics", ["xcrun", "xcresulttool", "get", "test-results", "metrics",
                                  "--path", str(result), "--compact"], read_output=True)[0]
                release.write_json(evidence / (platform + "-metrics.json"), json.loads(metrics))
                validate_hitch_metrics(json.loads(metrics), checks[platform])
        finally:
            if platform == "ipad":
                try:
                    command("ipad-native-test-cleanup-after", native_ipad_cleanup_arguments(), timeout=120)
                finally:
                    if ipad_ui:
                        command("ipad-ui-runner-cleanup-after", native_ipad_cleanup_arguments(NATIVE_IPAD_UI_RUNNER), timeout=120)
    after = release.source_inputs(root)
    release.write_json(evidence / "source-after.json", after)
    release.require(before == after, "Исходники изменились во время выбранных проверок.")
    observed_toolchain = selected_toolchain(command, plan, prefix="toolchain-after-")
    release.write_json(evidence / "toolchain-after.json", observed_toolchain)
    release.require(observed_toolchain == toolchain, "Сменился инструмент проверки.")
    actual = validate_check_evidence(root, plan, evidence, read_commands(evidence))
    release.write_json(evidence / "completed.json", {"format": 2, "checks": actual})
    return release.finish_verification(root, evidence)


@contextmanager
def verification_slot(root, plan):
    # Dependency preparation and SwiftPM share mutable build state only inside
    # one checkout. Xcode and the physical iPad additionally share a host slot.
    directory = Path(tempfile.gettempdir())
    checkout = hashlib.sha256(str(root.resolve()).encode()).hexdigest()[:16]
    paths = [directory / ("notebook-verification-" + checkout + ".lock")]
    if plan["checks"]["mac"] or plan["checks"]["ipad"]:
        paths.insert(0, directory / "notebook-verification.lock")
    with ExitStack() as locks:
        for path in paths:
            lock = locks.enter_context(path.open("w"))
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise release.ReleaseError("Другой маршрут использует этот checkout или native runner; второй не запущен.") from error
        yield


def main(argv=None):
    parser = argparse.ArgumentParser(description="Проверки по изменениям; --full отдельно запускает всю приёмку.")
    parser.add_argument("--full", action="store_true")
    parser.add_argument("--optimized", action="store_true", help="оптимизированный native код (-O) с изолированными DEBUG fixtures; режим записывается в свидетельства")
    parser.add_argument("--only", action="store_true", help="только явные --profile/--test, без автоматического добавления наборов")
    parser.add_argument("--plan", action="store_true", help="показать выбор, ничего не запускать")
    parser.add_argument("--base", default="HEAD", help="Git ref начала правки; по умолчанию незакоммиченные изменения")
    parser.add_argument("--profile", action="append", choices=sorted(PROFILES), default=[])
    parser.add_argument("--test", action="append", default=[], help="точный Swift/XCTest target/suite[/method]")
    parser.add_argument("--evidence-dir", type=Path)
    parser.add_argument("--timings", type=Path, help="прочитать времена из существующего xcresult без запуска тестов")
    args = parser.parse_args(argv)
    release.require(not (args.full and args.optimized), "--optimized относится к выбранным проверкам, не к полному маршруту.")
    release.require(not (args.full and args.only), "--full и --only задают разные области проверки.")
    if args.timings:
        tree = json.loads(subprocess.check_output(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(args.timings), "--compact"]))
        print(json.dumps(timing_report(tree), ensure_ascii=False, indent=2)); return
    plan = full_plan(ROOT) if args.full else make_plan(ROOT, args.base, args.profile, args.test, only=args.only)
    if not args.full:
        plan["optimized"] = args.optimized
    print(json.dumps(plan, ensure_ascii=False, indent=2), flush=True)
    if args.plan:
        return
    if not args.full:
        release.require(not plan["unclassified"] or plan["manualSelection"], "Неизвестен владелец части правок: выберите --profile/--test. Полный прогон сам не запустится.")
        if not any(plan["checks"].values()):
            print("Исполняемые изменения не выбраны. Для уже созданного коммита укажите --base HEAD^."); return
    with verification_slot(ROOT, plan):
        # Existing runners from before this selector also own the native slot.
        if plan["checks"]["mac"] or plan["checks"]["ipad"]:
            running = subprocess.run(["pgrep", "-x", "xcodebuild"], capture_output=True).returncode == 0
            release.require(not running, "Xcode уже занят другим владельцем; второй runner не запущен.")
        evidence = args.evidence_dir or ROOT / ".build" / (("full-" if args.full else "selected-") + time.strftime("%Y%m%d-%H%M%S"))
        run_selected(ROOT, plan, evidence.resolve())
        print("Контракты реестра прошли. Свидетельства:", evidence)



if __name__ == "__main__":
    try:
        main()
    except (release.ReleaseError, subprocess.SubprocessError, OSError, ValueError) as error:
        print("Проверка отклонена: " + str(error), file=sys.stderr)
        sys.exit(1)

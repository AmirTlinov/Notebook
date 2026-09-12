#!/usr/bin/env python3
"""Select checks by the changed owner; full acceptance is an explicit operation."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

import notebook_release as release

ROOT = Path(__file__).resolve().parents[1]
UI = "NotebookUITests/DrawingResponsivenessTests/"
PROFILES = {
    "computer-enrollment": {
        "core": ["ArchiveComputerPreparationTests", "NotebookArchiveActivationTests", "NotebookInstallationPairingGrantTests"],
        "mac": ["NotebookMacTests/NotebookArchiveLaunchTests", "NotebookMacTests/NotebookInstallationPairingTests"],
    },
    "computers": {
        "core": ["NotebookComputerStoreTests", "NotebookChatStoreTests", "NotebookProjectFileTests"],
        "ipad": ["NotebookTests/NotebookComputerControllerTests", "NotebookTests/NotebookChatControllerTests", "NotebookTests/NotebookFileControllerTests", "NotebookTests/NotebookRunControllerTests", "NotebookTests/NotebookVoiceControllerTests"],
    },
    "voice": {
        "commands": ["voice-audio"],
        "core": ["NotebookChatStoreTests", "NotebookCodexTests", "NotebookWakeAddressTests", "NotebookChatReadPositionTests"],
        "mac": ["NotebookMacTests/NotebookVoiceTests", "NotebookMacTests/NotebookCodexSidecarTests"],
        "ipad": ["NotebookTests/NotebookVoiceControllerTests", "NotebookTests/NotebookChatPanelTests", "NotebookTests/NotebookChatControllerTests"],
    },
    "project-runs": {
        "core": ["NotebookRunStoreTests", "NotebookChatStoreTests"],
        "mac": ["NotebookMacTests/NotebookProjectRunsTests", "NotebookMacTests/NotebookCodexSidecarTests"],
        "ipad": ["NotebookTests/NotebookRunControllerTests", "NotebookTests/NotebookChatControllerTests"],
    },
    "code-discussion": {
        "core": ["NotebookCodeDiscussionTests", "NotebookCodeStoreTests", "AgentInkTests"],
        "ipad": ["NotebookTests/NotebookCodeDiscussionTests", "NotebookTests/NotebookCodeAnnotationsTests", "NotebookTests/NotebookFileControllerTests"],
        "commands": ["mcp"],
    },
    "code-notes": {
        "core": ["NotebookCodeFragmentTests", "NotebookCodeStoreTests", "AgentInkTests"],
        "mac": ["NotebookMacTests/NotebookProjectFilesTests"],
        "ipad": ["NotebookTests/NotebookCodeAnnotationsTests", "NotebookTests/NotebookFileControllerTests"],
        "commands": ["mcp"],
    },
    "project-files": {
        "core": ["NotebookProjectFileTests", "NotebookChatStoreTests"],
        "mac": ["NotebookMacTests/NotebookProjectFilesTests", "NotebookMacTests/NotebookCodexSidecarTests"],
        "ipad": ["NotebookTests/NotebookFileControllerTests", "NotebookTests/NotebookChatControllerTests"],
    },
    "chat-transport": {"core": ["NotebookChatStoreTests"], "ipad": ["NotebookTests/NotebookTransportSessionTests/testCodexEnvelopeUsesTheSameAuthenticatedPeerAndReceiptID"]},
    "codex": {"core": ["NotebookCodexTests"]},
    "chat": {
        "core": ["NotebookChatStoreTests", "NotebookChatReadPositionTests"],
        "mac": ["NotebookMacTests/NotebookChatRenderingTests", "NotebookMacTests/NotebookCodexSidecarTests"],
        "ipad": ["NotebookTests/NotebookChatPanelTests", "NotebookTests/NotebookChatControllerTests", "NotebookTests/NotebookVoiceControllerTests"],
    },
    "chat-touch": {"ipad": [UI + "testCodexPanelCanCollapseFromTheWholeButtonAfterCreatingAChat",
                              UI + "testCodexPanelKeepsDraftWithoutMovingPaperOnCollapseAndRotation"]},
    "workspace-controls": {"ipad": ["NotebookTests/NotebookChatWindowTests",
                                      UI + "testChatMovesResizesAndOpensSettingsWithoutMovingPaper",
                                      UI + "testAgentNoticeExpiresAndHistoryKeepsItsActions"]},
    "documents": {
        "core": ["DocumentRenderRecipeTests", "DocumentDocumentTests", "DocumentEditingSessionTests"],
        "mac": ["NotebookMacTests/DocumentLargeSourceTests", "NotebookMacTests/DocumentRenderSessionTests",
                "NotebookMacTests/DocumentLinkNavigationTests",
                "NotebookMacTests/DocumentSnapshotTests", "NotebookMacTests/AddressedTargetRenderTests"],
        "ipad": ["NotebookTests/DocumentLargeSourceTests", "NotebookTests/DocumentResourceLeaseTests",
                 "NotebookTests/DocumentLinkNavigationTests",
                 "NotebookTests/DocumentPageSelectionTests", "NotebookTests/DocumentCutOriginTests"],
    },
    "page-turn": {"ipad": [UI + "testProseDocumentTurnsToDifferentTextAndBack",
                            UI + "testDocumentPageTurnShowsTheCommittedPhysicalPage"]},
    "scene-touch": {"ipad": [UI + "testDoubleTapOpensAWholePageImmediately",
                                UI + "testDocumentCoverUsesTheSamePhysicalCurl"]},
    "scene-composition": {
        "mac": ["NotebookMacTests/SceneRasterCompositionTests/" + name for name in (
            "testPainterOrderAlphaClippingAndTopLeftCoordinates",
            "testBoardCompositionStreamsMoreSourcePixelsThanItsBudget",
            "testInputInterruptionCannotPublishPartialComposition")],
        "ipad": ["NotebookTests/SceneCompositionTests/" + name for name in (
            "testMixedPaperCoversPublishInLandscapeWithoutDroppingTheirInputOwners",
            "testEmptyTileProofKeepsCoverageAndUnknownPagesKeepTheirPainter",
            "testEmptyTileProofRetainsACoverWhoseShadowCrossesTheBoundary",
            "testSmallStackKeepsBothPhysicalCoversUnderTheSharedBudget",
            "testNativePressureRemovesOnlyOptionalCarriersWithoutCoarseningTheirBacking",
            "testBytePressureCoarsensWholeBoundsWithoutChangingPinsOrPainterSources",
            "testByteReductionKeepsTheAlreadyAdmittedForwardPortalAndItsRealChildPixels",
            "testColdCacheMissDoesNotRequireDecodeScratchBeforeRenderingAStaticTile",
            "testTransparentRangesAndLiveMiddleProduceTheSamePixelsAsWholePainterOrder",
            "testForeignRevisionIsRejectedBeforeAnyRasterAllocation",
            "testCancellationAfterTheFirstCandidateTileKeepsTheWholePreviousCohortAndLeases",
            "testStopReleasesEveryRasterAfterTheLastShownCohortReferenceEnds",
            "testStopDrainsSupersededPreparationAndRejectsNewWork")],
    },
    "paper-resources": {
        "mac": ["NotebookMacTests/DocumentLargeSourceTests/testLargeIllustratedMathBookColdMountsAndTurnsToDistantPhysicalPagesWithinTheExistingDeadline",
                "NotebookMacTests/DocumentRenderSessionTests",
                "NotebookMacTests/DocumentRuntimeTests/testNativeReaderRejectsChangedLayoutAndPagePacketLengthsWithoutPublishingOrLeaking"],
        "ipad": ["NotebookTests/DocumentLargeSourceTests/testLargeBookOpensBesideDrawnPaperInTheSameSceneBudget",
                 "NotebookTests/DocumentLargeSourceTests/testLargeIllustratedMathBookColdMountsAndTurnsToDistantPhysicalPagesWithinTheExistingDeadline",
                 "NotebookTests/SceneCompositionTests/testMixedPaperCoversPublishInLandscapeWithoutDroppingTheirInputOwners",
                 "NotebookTests/SceneRenderResourcesTests/testInputCanBorrowUnusedPassiveSpaceButPassiveCannotBorrowTheProtectedHalf",
                 "NotebookTests/SceneRenderResourcesTests/testPhysicalHandoffChangesRolesAtomicallyAndSubmittedBytesOutliveTheOwnerLease",
                 "NotebookTests/SpatialInkHandoffTests/testMountedInputReaffirmationDoesNotInvalidateItsOwnObservedResourceGraph",
                 "NotebookTests/SpatialInkHandoffTests/testFullPortraitRetinaBudgetReadiesNonemptyParentAndChildWithoutLoweringInkDensity"],
    },
    "mcp": {"commands": ["mcp"]},
    "verification": {"commands": ["verification", "release"]},
}


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args])


def changed_files(root, base):
    commit = git(root, "rev-parse", "--verify", base + "^{commit}").decode().strip()
    paths = set(git(root, "diff", "--name-only", "-z", commit, "--").decode().split("\0"))
    paths.update(git(root, "ls-files", "--others", "--exclude-standard", "-z").decode().split("\0"))
    return commit, sorted(paths - {""})


def owners(path):
    """An unclassified implementation never silently falls back to all tests."""
    if path == "AGENTS.md" or path.startswith("docs/") or path == "README.md":
        return []
    if path in ("verify.sh", "Applications/notebook_verification.py", "Applications/notebook_release.py") or path.startswith(("Tests/NotebookVerification/", "Tests/NotebookRelease/")):
        return ["verification"]
    if path.startswith("MCP/"):
        return ["mcp"]
    name = Path(path).name
    if name in ("NotebookComputerStore.swift", "NotebookComputerStoreTests.swift", "NotebookComputerControllerTests.swift"):
        return ["computers"]
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
        return ["scene-composition", "documents"]
    if name in ("SceneCompositionTiles.swift", "SceneCompositionSource.swift", "SceneCompositionTests.swift"):
        return ["scene-composition"]
    if name == "NotebookChatPanel.swift":
        return ["chat", "chat-touch"]
    if name in ("NotebookRootView.swift", "NotebookCollaborationView.swift", "NotebookChatWindow.swift"):
        return ["chat", "chat-touch", "workspace-controls"]
    if "Chat" in name or name in ("NotebookCodexSidecar.swift",):
        return ["chat"]
    if name in ("IPadPageTurnController.swift", "PageTurnSurface.swift"):
        return ["documents", "page-turn"]
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
        if path in ("Applications/iPad/SimulatorDrawingFixture.swift", "Applications/UITests/DrawingResponsivenessTests.swift"):
            if not any(t.startswith(UI) and t.count("/") == 2 for t in tests):
                unknown.append(path)
            continue
        test = test_selector(path)
        found = owners(path)
        if test:
            if not only:
                direct.append(test)
        elif found is None:
            unknown.append(path)
        elif not only:
            selected.update(found)
    checks = {key: set() for key in ("core", "mac", "ipad", "commands")}
    for profile in sorted(selected):
        for key, values in PROFILES[profile].items():
            checks[key].update(values)
    for key, value in direct:
        checks[key].add(value)
    for test in tests:
        target = test.split("/", 1)[0]
        if target not in ("NotebookMacTests", "NotebookTests", "NotebookUITests") or not re.fullmatch(r"[A-Za-z0-9_/]+", test) or "/" not in test:
            raise release.ReleaseError("Укажите точный XCTest target/suite[/method], не весь target.")
        if target == "NotebookUITests" and test.count("/") < 2:
            raise release.ReleaseError("UI запускается по сценарию, не всем 44 тестам сразу.")
        checks["mac" if target == "NotebookMacTests" else "ipad"].add(test)
    return {"format": 1, "baseCommit": commit, "changedFiles": paths, "profiles": sorted(selected),
            "unclassified": unknown, "manualSelection": bool(profiles or tests),
            "selectionMode": "explicit-only" if only else "changed-owners",
            "checks": {key: sorted(values) for key, values in checks.items()}}


def timing_report(tree):
    rows = []
    def walk(node, target=""):
        name = node.get("name", "")
        if name in ("NotebookTests", "NotebookUITests", "NotebookMacTests"):
            target = name
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
    release.require(summary.get("passedTests", 0) > 0 and summary.get("failedTests", 0) == 0
                    and summary.get("skippedTests", 0) == 0 and summary.get("runtimeWarnings") == [],
                    "Нужны исполненные тесты без ошибок, пропусков и runtime warnings.")


def validate_executed_tests(tree, selectors):
    executed = set()
    def walk(node, target=""):
        if node.get("name") in ("NotebookTests", "NotebookUITests", "NotebookMacTests"):
            target = node["name"]
        if node.get("nodeType") == "Test Case" and node.get("result") == "Passed":
            executed.add(target + "/" + node.get("nodeIdentifier", "").removesuffix("()"))
        for child in node.get("children", []):
            walk(child, target)
    for node in tree.get("testNodes", []):
        walk(node)
    for selector in selectors:
        release.require(any(case == selector or case.startswith(selector + "/") for case in executed),
                        "Выбранный тест не исполнился: " + selector)


def validate_selected(source, evidence, receipt):
    release.require(receipt.get("format") == 1 and receipt.get("status") == "passed", "Выбранный маршрут не завершён.")
    plan = release.read_json(evidence / "selection.json")
    release.require(not plan["unclassified"] or plan["manualSelection"],
                    "Для этих исходников явно выберите достаточные --profile/--test.")
    release.require(not set(plan["unclassified"]) & {"Applications/iPad/SimulatorDrawingFixture.swift", "Applications/UITests/DrawingResponsivenessTests.swift"},
                    "Изменённая UI-фикстура требует названного жестового сценария.")
    release.require(receipt["source"] == release.source_inputs(source)
                    == release.read_json(evidence / "source-before.json") == release.read_json(evidence / "source-after.json"),
                    "Выбранные проверки выполнялись на других исходниках.")
    completed = release.read_json(evidence / "completed.json")
    release.require(completed == plan["checks"] and any(completed.values()), "Не все выбранные проверки исполнены.")
    commands = json.loads((evidence / "commands.json").read_text())
    release.require(commands and all(c.get("exitCode") == 0 for c in commands), "Команда не завершилась успешно.")
    expected = set(completed["commands"]) - {"mcp"}
    if "mcp" in completed["commands"]:
        expected.update(("mcp-check", "mcp-test"))
    if completed["core"]:
        expected.add("core")
    release.require(expected.issubset({c["label"] for c in commands}), "Отсутствует команда выбранной проверки.")
    for platform in ("mac", "ipad"):
        if completed[platform]:
            release.require((evidence / (platform + ".xcresult")).is_dir(), "Отсутствует xcresult выбранной платформы.")
            validate_summary(release.read_json(evidence / (platform + "-summary.json")))
            validate_executed_tests(release.read_json(evidence / (platform + "-tests.json")), completed[platform])
            command = next((c for c in commands if c["label"] == platform), None)
            release.require(command is not None and sorted(arg.removeprefix("-only-testing:") for arg in command["argv"]
                            if arg.startswith("-only-testing:")) == completed[platform], "Xcode исполнял другой набор тестов.")
    release.require(receipt["artifacts"] == release.verification_artifacts(evidence, full=False), "Свидетельства выбранного маршрута изменились.")
    return receipt


def select_simulator(inventory, device_id=None):
    available = [d for values in inventory["devices"].values() for d in values
                 if d.get("isAvailable", False) and ".iPad-" in d.get("deviceTypeIdentifier", "")]
    candidates = [d for d in available if d["udid"] == device_id] if device_id else [d for d in available if d["state"] == "Booted"]
    release.require(len(candidates) == 1, "Укажите NOTEBOOK_SIMULATOR_ID или запустите один iPad Simulator.")
    return candidates[0]


def run_selected(root, plan, evidence):
    release.require(not evidence.exists(), "Для проверки нужен новый каталог свидетельств.")
    evidence.mkdir(parents=True)
    before = release.source_inputs(root)
    release.write_json(evidence / "source-before.json", before)
    release.write_json(evidence / "selection.json", plan)
    command = release.release_commands(evidence)
    toolchain = release.read_toolchain(command)
    release.write_json(evidence / "toolchain.json", toolchain)
    checks = plan["checks"]
    if checks["core"]:
        output, _ = command("core", ["swift", "test", "--filter", "|".join(checks["core"])], cwd=root, timeout=600, read_output=True)
        release.require(re.search(rb"Test run with [1-9][0-9]* tests? .*passed", output), "Core не исполнил выбранные тесты.")
    for name in checks["commands"]:
        if name == "voice-audio":
            command(name, ["node", "--test", str(root / "Tests/NotebookVoiceHarness/audio.test.mjs")], cwd=root)
        elif name == "mcp":
            if not (root / "MCP/node_modules").is_dir():
                command("mcp-dependencies", ["npm", "ci", "--ignore-scripts"], cwd=root / "MCP")
            command("mcp-check", ["npm", "run", "check"], cwd=root / "MCP")
            command("mcp-test", ["npm", "test"], cwd=root / "MCP", timeout=300)
        else:
            script = "NotebookVerification" if name == "verification" else "NotebookRelease"
            command(name, [sys.executable, "-B", str(root / "Tests" / script / "run.py")], cwd=root)
    if checks["mac"] or checks["ipad"]:
        command("generate-project", ["xcodegen", "generate", "--spec", "project.yml"], cwd=root / "Applications")
    # Xcode still builds changed dependencies. Only its derived products are reused;
    # fixtures, test execution, source hashes and result bundles are always fresh.
    derived = Path(tempfile.gettempdir()) / "notebook-selected-builds" / hashlib.sha256(str(root).encode()).hexdigest()[:16]
    for platform, scheme in (("mac", "NotebookMac"), ("ipad", "Notebook")):
        if not checks[platform]:
            continue
        destination = "platform=macOS"
        if platform == "ipad":
            devices, _ = command("simulators", ["xcrun", "simctl", "list", "devices", "available", "--json"], read_output=True)
            device = select_simulator(json.loads(devices), os.environ.get("NOTEBOOK_SIMULATOR_ID"))
            destination = "platform=iOS Simulator,id=" + device["udid"]
        result = evidence / (platform + ".xcresult")
        args = ["xcrun", "xcodebuild", "-quiet", "-project", "Notebook.xcodeproj", "-scheme", scheme,
                "-configuration", "Debug", "-destination", destination, "-derivedDataPath", str(derived / platform),
                "-resultBundlePath", str(result), "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never",
                "test"] + ["-only-testing:" + selector for selector in checks[platform]]
        if platform == "mac":
            args.append("CODE_SIGNING_ALLOWED=NO")
        command(platform, args, cwd=root / "Applications", timeout=1800)
        summary, _ = command(platform + "-summary", ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result), "--compact"], read_output=True)
        summary = json.loads(summary); validate_summary(summary)
        release.write_json(evidence / (platform + "-summary.json"), summary)
        tests, _ = command(platform + "-tests", ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(result), "--compact"], read_output=True)
        tests = json.loads(tests)
        validate_executed_tests(tests, checks[platform])
        release.write_json(evidence / (platform + "-tests.json"), tests)
        release.write_json(evidence / (platform + "-timings.json"), timing_report(tests))
    release.write_json(evidence / "completed.json", checks)
    after = release.source_inputs(root)
    release.write_json(evidence / "source-after.json", after)
    release.require(before == after, "Исходники изменились во время выбранных проверок.")
    release.require(release.read_toolchain(command, prefix="toolchain-after-") == toolchain, "Сменился инструмент проверки.")
    receipt = {"format": 1, "route": "./verify.sh:selected", "status": "passed", "source": before,
               "artifacts": release.verification_artifacts(evidence, full=False)}
    release.write_json(evidence / "verification.json", receipt)
    return receipt


def main(argv=None):
    parser = argparse.ArgumentParser(description="Проверки по изменениям; --full отдельно запускает всю приёмку.")
    parser.add_argument("--full", action="store_true")
    parser.add_argument("--only", action="store_true", help="только явные --profile/--test, без автоматического добавления наборов")
    parser.add_argument("--plan", action="store_true", help="показать выбор, ничего не запускать")
    parser.add_argument("--base", default="HEAD", help="Git ref начала правки; по умолчанию незакоммиченные изменения")
    parser.add_argument("--profile", action="append", choices=sorted(PROFILES), default=[])
    parser.add_argument("--test", action="append", default=[], help="точный XCTest target/suite/method")
    parser.add_argument("--evidence-dir", type=Path)
    parser.add_argument("--timings", type=Path, help="прочитать времена из существующего xcresult без запуска тестов")
    args = parser.parse_args(argv)
    release.require(not (args.full and args.only), "--full и --only задают разные области проверки.")
    if args.timings:
        tree = json.loads(subprocess.check_output(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(args.timings), "--compact"]))
        print(json.dumps(timing_report(tree), ensure_ascii=False, indent=2)); return
    plan = {"route": "full", "notice": "Все нагрузки, native и UI; не обычная итерация."} if args.full else make_plan(ROOT, args.base, args.profile, args.test, only=args.only)
    print(json.dumps(plan, ensure_ascii=False, indent=2), flush=True)
    if args.plan:
        return
    if not args.full:
        release.require(not plan["unclassified"] or plan["manualSelection"], "Неизвестен владелец части правок: выберите --profile/--test. Полный прогон сам не запустится.")
        if not any(plan["checks"].values()):
            print("Исполняемые изменения не выбраны. Для уже созданного коммита укажите --base HEAD^."); return
    lock_path = Path(tempfile.gettempdir()) / "notebook-verification.lock"
    with lock_path.open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise release.ReleaseError("Другой маршрут уже выполняется; второй не запущен.")
        # Existing runners from before this selector also own the native slot.
        running = subprocess.run(["pgrep", "-x", "xcodebuild"], capture_output=True).returncode == 0
        release.require(not running, "Xcode уже занят другим владельцем; второй runner не запущен.")
        if args.full:
            env = os.environ.copy()
            if args.evidence_dir:
                env["NOTEBOOK_VERIFY_EVIDENCE_DIR"] = str(args.evidence_dir.resolve())
            subprocess.run(["/bin/bash", str(ROOT / "Tests/NotebookVerification/full.sh")], cwd=ROOT, env=env, check=True)
        else:
            evidence = args.evidence_dir or ROOT / ".build" / ("selected-" + time.strftime("%Y%m%d-%H%M%S"))
            run_selected(ROOT, plan, evidence.resolve())
            print("Выбранные проверки прошли; это не полный прогон. Свидетельства:", evidence)


if __name__ == "__main__":
    try:
        main()
    except (release.ReleaseError, subprocess.SubprocessError, OSError, ValueError) as error:
        print("Проверка отклонена: " + str(error), file=sys.stderr)
        sys.exit(1)

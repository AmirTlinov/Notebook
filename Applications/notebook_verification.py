#!/usr/bin/env python3
"""Select checks by the changed owner; full acceptance is an explicit operation."""
import argparse
import fcntl
import hashlib
import json
import math
import os
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
DOCUMENT_BROWSER_CONTRACTS = (
    "Tests/NotebookDocumentAcceptance/test_link_activation.mjs",
)
PROFILES = {
    "navigation-ux": {
        "ipad": ["NotebookTests/NotebookUXObservationTests",
                 "NotebookTests/NotebookNavigationLoadUXTests",
                 "NotebookTests/PageRasterPreparationTests",
                 "NotebookTests/PreparedAgentElementViewTests/testZoomReusesAdequateProgramPixelsWithoutSubmittingAnotherCapture",
                 "NotebookTests/PreparedAgentElementViewTests/testRasterReportsItsFirstLayoutWithoutAnotherSourceUpdate",
                 "NotebookTests/PreparedAgentElementViewTests/testUnchangedProgramCheckpointDoesNotInvalidateThePageReadWindow",
                 "NotebookTests/NotebookPageLifecycleUXTests/testPageMountsTheFullSizeErasureMaskOnlyWhileItHasLiveCoverage",
                 "NotebookTests/NotebookPageMotionUXTests",
                 "NotebookTests/NotebookSceneSelectionTests/testColdSwipeKeepsIntentUntilLiftAndReversalOrPinchCancelsIt",
                 "NotebookTests/ZoomOutCoverageTests/testInstalledPinchRevealsPixelsBeforeEitherFingerLifts",
                 "NotebookTests/ZoomOutCoverageTests/testMixedSceneRefinesPixelsWhileZoomRemainsHeld",
                 "NotebookTests/SceneCameraPlaneTests/testInstalledPlaneFollowsVisibleChildrenOutsideTheOldAnchorBounds",
                 "NotebookTests/SceneCompositionTests/testPrefetchedProgramsDoNotEvictPassiveSourcesFromTheirOwnQuota",
                 "NotebookTests/SceneCompositionTests/testPassivePrefetchDoesNotWaitForOffscreenProgramSnapshots",
                 "NotebookTests/PageTurnSelectionTests",
                 "NotebookUITests/NotebookNavigationLoadUITests/testDenseSVGPagesTurnForwardReverseAndRepeatedArrowsWithoutBlankLanding",
                 "NotebookUITests/NotebookNavigationLoadUITests/testContinuousZoomWithProgramsMeetsSystemHitchBudget",
                 "NotebookUITests/NotebookNavigationLoadUITests/testDensePageTurnsMeetSystemHitchBudget",
                 "NotebookUITests/NotebookNavigationLoadUITests/testTwentyFourPageProgramsAcceptFirstTapAfterZoomAndKeepStateAcrossTurns",
                 "NotebookUITests/NotebookNavigationLoadUITests/testTwentyFourBoardProgramsStayInteractiveAfterZoomOutAndBack"],
    },
    "collaboration-ux": {
        "ipad": ["NotebookTests/NotebookCollaborationLatencyTests", "NotebookTests/NotebookUXObservationTests",
                 "NotebookTests/NotebookActionDeliveryTests",
                 "NotebookTests/SharedAttentionTests/testDeliveryAndDisplayRequireDifferentEvidence"],
        "mac": ["NotebookMacTests/NotebookSelectionPublicationTests"],
    },
    "interaction-ux": {
        "ipad": ["NotebookTests/NotebookUXObservationTests", "NotebookTests/NotebookGestureLatencyTests",
                 "NotebookTests/NotebookSelectionCompositionTests", "NotebookTests/NotebookInteractionUXTests",
                 "NotebookTests/NotebookPageLifecycleUXTests",
                 "NotebookTests/NotebookColdInputUXTests",
                 "NotebookTests/PagePresentationTests/testColdRootInstallsTheStoredInkPageAtTheActualViewport",
                 "NotebookTests/NotebookDocumentOpeningTests/testHistoryReferenceInstallsAnUnloadedDocumentOutsideTheCurrentCamera",
                 "NotebookTests/NotebookDocumentOpeningTests/testHistoryReferenceInstallsAnUnloadedDocumentOnAnotherBoard",
                 "NotebookUITests/NotebookWorkspaceJourneyUITests/testColdBoardEntryAndRealSwipesShowEveryLeafAfterEvictionAndReturn",
                 "NotebookUITests/NotebookWorkspaceJourneyUITests/testFirstSelectionMoveDeleteAndColdReopenPreserveTheWholeComposition",
                 "NotebookUITests/NotebookWorkspaceJourneyUITests/testNewPageAcceptsFirstTextContactAndKeepsItOnThatPage",
                 "NotebookUITests/NotebookWorkspaceJourneyUITests/testMenusBackgroundAndRotationKeepFirstContactAndPageNavigation"],
    },
    "presentation": {
        "core": ["NotebookPresentationTests", "CodexDisplayProjectionTests", "wireCannotChooseRootPathsOrUnknownCommands", "stablePagePreservesExplicitViewportScale",
                 "viewportProjectionIsReversible", "documentCameraUsesItsOwnGeometry", "documentPageSelectionSurvivesViewportProjection"],
        "commands": ["mcp"],
        "mac": ["NotebookMacTests/NotebookPresentationRelayTests"],
        "ipad": ["NotebookTests/NotebookPresentationTests"],
    },
    "live-placement": {
        "core": ["BoardMergeOwnershipTests", "BoardPlacementMigrationTests", "NotebookBoardContentRevisionTests", "BoardHierarchyTests", "CollaborationTests", "PlacementActionOwnershipTests", "CollaborationCreationUndoTests",
                 "PortalIntegrityTests", "WorkspacePublicationTests", "NotebookReplicationTests",
                 "NotebookReferenceLiveSceneTests", "NotebookReferenceIndexTests", "NotebookReferenceInkTests",
                 "CollaborationComparableTests", "AgentInkTests",
                 "ArchiveConsolidationTests/latentAndConcurrentPlacementHeadsRemainIndependentOwners", "NotebookArchiveUnionTests",
                 "NotebookPageAppendTests/missingOrHashCorruptOrderDependenciesCannotPublishOrAcknowledgeThePage",
                 "NotebookArchiveActivationTests/replicaRetainsStoppedRequestAndDropsOnlyForeignLocalExecution"],
        "ipad": ["NotebookTests/NotebookLiveGesturePresentationTests",
                 "NotebookTests/NotebookLiveScenePublicationTests", "NotebookTests/NotebookGestureAdmissionTests", "NotebookTests/NotebookBoardRevisionTests",
                 "NotebookTests/NearbySyncTests", "NotebookTests/NotebookTransportSessionTests"],
    },
    "placement-scale": {
        "core": ["NotebookSQLScaleTests/oneHundredThousandOwnersKeepAnEditAndItsJournalAddressed"],
    },
    "computer-enrollment": {
        "core": ["ArchiveComputerPreparationTests", "NotebookArchiveActivationTests", "NotebookAccountDirectoryTests", "NotebookAccountBootstrapTests"],
        "mac": ["NotebookMacTests/NotebookArchiveLaunchTests", "NotebookMacTests/NotebookDeviceTrustTests", "NotebookMacTests/NotebookAccountConnectionTests", "NotebookMacTests/NotebookAccountWorkspaceTests"],
    },
    "computers": {
        "core": ["NotebookComputerStoreTests", "NotebookChatStoreTests", "NotebookProjectFileTests"],
        "ipad": ["NotebookTests/NotebookComputerControllerTests", "NotebookTests/NotebookChatControllerTests", "NotebookTests/NotebookFileControllerTests", "NotebookTests/NotebookRunControllerTests", "NotebookTests/NotebookVoiceControllerTests"],
    },
    "dictation": {
        "core": ["NotebookDictationTests", "NotebookChatStoreTests", "CodexDictationTests", "NotebookWakeAddressTests"],
        "mac": ["NotebookMacTests/NotebookDictationTests", "NotebookMacTests/NotebookCodexSidecarTests"],
        "ipad": ["NotebookTests/NotebookDictationControllerTests", "NotebookTests/NotebookDictationAudioTests", "NotebookTests/NotebookChatControllerTests",
                 "NotebookTests/NotebookVoiceControllerTests", "NotebookTests/NotebookAgentQuestionTests",
                 UI + "testDictationInputStopsIntoAnEditableExpandedChatAndSendsExactlyOnce",
                 UI + "testAddressedDictationSendsOnceFromTheCompanionWithoutOpeningOrClearingTheDraft",
                 UI + "testDictationControlBesideVoiceInvokesItsOwnerWithoutLosingTheDraftOrPaper"],
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
                                      UI + "testAgentChangesStayQuietAndHistoryKeepsItsActions"]},
    "document-web": {
        "commands": ["document-browser"],
        "mac": ["NotebookMacTests/DocumentRuntimeTests"],
        "ipad": ["NotebookTests/DocumentShellPreparationTests", "NotebookTests/DocumentPrintImageTests",
                 "NotebookTests/DocumentLinkActivationTests"],
    },
    "documents": {
        "commands": ["document-browser"],
        "core": ["DocumentRenderRecipeTests", "DocumentDocumentTests", "DocumentEditingSessionTests",
                 "NotebookDocumentBlockReadTests", "NotebookDocumentStateCommandTests"],
        "mac": ["NotebookMacTests/DocumentLargeSourceTests", "NotebookMacTests/DocumentRenderSessionTests",
                "NotebookMacTests/DocumentLinkNavigationTests",
                "NotebookMacTests/DocumentSnapshotTests", "NotebookMacTests/AddressedTargetRenderTests",
                "NotebookMacTests/DocumentNativeSourceSessionTests", "NotebookMacTests/DocumentProgramIdentityTests",
                "NotebookMacTests/DocumentRuntimeTests"],
        "ipad": ["NotebookTests/DocumentLargeSourceTests", "NotebookTests/DocumentResourceLeaseTests",
                 "NotebookTests/DocumentShellPreparationTests", "NotebookTests/DocumentPrintImageTests",
                 "NotebookTests/PhysicalWebViewportTests", "NotebookTests/NotebookDocumentOpeningTests",
                 "NotebookTests/DocumentLinkActivationTests",
                 "NotebookTests/DocumentProgramOwnerTests", "NotebookTests/DocumentProgramOverlayHostTests",
                 "NotebookTests/DocumentBlockRuntimeTests", "NotebookTests/DocumentPresentationRecorderTests",
                 "NotebookTests/NotebookDocumentStatePersistenceTests",
                 "NotebookTests/DocumentLinkNavigationTests",
                 "NotebookTests/DocumentPageSelectionTests", "NotebookTests/DocumentCutOriginTests"],
    },
    "submitted-pixels": {
        "ipad": ["NotebookTests/NotebookSubmittedPixelsTests", "NotebookTests/NotebookPinnedImageTests",
                 "NotebookTests/SharedAttentionTests", "NotebookTests/DocumentProgramOwnerTests",
                 "NotebookTests/NotebookCoverPresentationTests", "NotebookTests/PagePresentationTests"],
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
        "mac": ["NotebookMacTests/DocumentLargeSourceTests/testLargeIllustratedBookKeepsOnePrintArtifactAndRastersOnlyRequestedPages",
                "NotebookMacTests/DocumentRenderSessionTests",
                "NotebookMacTests/DocumentTypesetterBoundaryTests"],
        "ipad": ["NotebookTests/DocumentCanonicalPrintTests",
                 "NotebookTests/DocumentLargeSourceTests/testLargeIllustratedBookKeepsOnePrintArtifactAndRastersOnlyRequestedPages",
                 "NotebookTests/SceneCompositionTests/testMixedPaperCoversPublishInLandscapeWithoutDroppingTheirInputOwners",
                 "NotebookTests/SceneRenderResourcesTests/testInputCanBorrowUnusedPassiveSpaceButPassiveCannotBorrowTheProtectedHalf",
                 "NotebookTests/SceneRenderResourcesTests/testPhysicalHandoffChangesRolesAtomicallyAndSubmittedBytesOutliveTheOwnerLease",
                 "NotebookTests/SpatialInkHandoffTests/testMountedInputReaffirmationDoesNotInvalidateItsOwnObservedResourceGraph",
                 "NotebookTests/SpatialInkHandoffTests/testFullPortraitRetinaBudgetReadiesNonemptyParentAndChildWithoutLoweringInkDensity"],
    },
    "mcp": {"commands": ["mcp"]},
    "script-runtime": {
        "core": ["NotebookScriptAdmissionTests", "NotebookScriptCancellationTests", "NotebookScriptEffectOutcomeTests",
                 "NotebookScriptEffectRecoveryTests", "NotebookScriptHelpTests", "CodexRuntimeScopeTests",
                 "NotebookPublicProtocolTests", "NotebookScriptDeadlineTests", "NotebookQuickJSCancellationTests"],
        "mac": ["NotebookMacTests/NotebookScriptServiceTests"],
        "commands": ["mcp"],
    },
    "acceptance-bootstrap": {
        "core": ["CodexRuntimeScopeTests"],
        "mac": ["NotebookMacTests/NotebookAcceptanceLaunchTests"],
        "ipad": ["NotebookTests/NotebookAcceptanceLaunchTests"],
        "commands": ["verification", "release", "trace-harness"],
    },
    "verification": {"commands": ["verification", "release"]},
}


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args])


def document_browser_arguments(root):
    return ["node", "--test", *(str(root / path) for path in DOCUMENT_BROWSER_CONTRACTS)]


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
    if name in ("NotebookDocumentBlockReadTests.swift", "NotebookDocumentStateCommand.swift", "NotebookDocumentStateCommandTests.swift",
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


def native_test_bundle(node, inherited=""):
    if node.get("nodeType") in ("Unit test bundle", "UI test bundle"):
        name = node.get("name", "")
        return name if name in ("NotebookTests", "NotebookUITests", "NotebookMacTests",
                               "NotebookAcceptanceUITests", "NotebookMacAcceptanceUITests") else ""
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
    release.require(summary.get("passedTests", 0) > 0 and summary.get("failedTests", 0) == 0
                    and summary.get("skippedTests", 0) == 0 and summary.get("runtimeWarnings") == [],
                    "Нужны исполненные тесты без ошибок, пропусков и runtime warnings.")


def validate_executed_tests(tree, selectors):
    executed = set()
    def walk(node, target=""):
        target = native_test_bundle(node, target)
        if target and node.get("nodeType") == "Test Case" and node.get("result") == "Passed":
            executed.add(target + "/" + node.get("nodeIdentifier", "").removesuffix("()"))
        for child in node.get("children", []):
            walk(child, target)
    for node in tree.get("testNodes", []):
        walk(node)
    for selector in selectors:
        release.require(any(case == selector or case.startswith(selector + "/") for case in executed),
                        "Выбранный тест не исполнился: " + selector)


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


def validate_selected(source, evidence, receipt):
    release.require(receipt.get("format") == 1 and receipt.get("status") == "passed", "Выбранный маршрут не завершён.")
    plan = release.read_json(evidence / "selection.json")
    release.require(not plan["unclassified"] or plan["manualSelection"],
                    "Для этих исходников явно выберите достаточные --profile/--test.")
    release.require(not set(plan["unclassified"]) & {"Applications/iPad/NotebookDrawingFixture.swift", "Applications/UITests/DrawingResponsivenessTests.swift"},
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
    if "document-browser" in completed["commands"]:
        browser = next(c for c in commands if c["label"] == "document-browser")
        cwd = browser.get("cwd")
        release.require(isinstance(cwd, str) and Path(cwd).is_absolute()
                        and browser["argv"] == document_browser_arguments(Path(cwd)),
                        "Браузерные контракты документов исполняли другой набор или источник.")
    for platform in ("mac", "ipad"):
        if completed[platform]:
            release.require((evidence / (platform + ".xcresult")).is_dir(), "Отсутствует xcresult выбранной платформы.")
            validate_summary(release.read_json(evidence / (platform + "-summary.json")))
            validate_executed_tests(release.read_json(evidence / (platform + "-tests.json")), completed[platform])
            if selected_hitch_tests(completed[platform]):
                validate_hitch_metrics(release.read_json(evidence / (platform + "-metrics.json")), completed[platform])
            command = next((c for c in commands if c["label"] == platform), None)
            release.require(command is not None and sorted(arg.removeprefix("-only-testing:") for arg in command["argv"]
                            if arg.startswith("-only-testing:")) == completed[platform], "Xcode исполнял другой набор тестов.")
    release.require(receipt["artifacts"] == release.verification_artifacts(evidence, full=False), "Свидетельства выбранного маршрута изменились.")
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
    # The first XCUIApplication.launch otherwise installs its target inside the
    # gesture watchdog. Install the exact built artifacts WITHOUT launching them;
    # Xcode's documented destination-artifact mode forbids a second installation.
    runs = list(products.glob("Notebook_iphoneos*.xctestrun"))
    release.require(len(runs) == 1, "Нужен один xctestrun текущей сборки iPad.")
    run = plistlib.loads(runs[0].read_bytes())
    release.require(run.get("NotebookUITests", {}).get("IsUITestBundle") is True,
                    "Нет ожидаемого UI target в xctestrun.")
    apps = [("app", "Notebook.app", NATIVE_IPAD_BUNDLE),
            ("runner", "NotebookUITests-Runner.app", NATIVE_IPAD_UI_RUNNER)]
    # Validate both identities before the first device mutation.
    for _, name, bundle in apps:
        info = plistlib.loads((products / "Debug-iphoneos" / name / "Info.plist").read_bytes())
        release.require(info.get("CFBundleIdentifier") == bundle, "Preinstall допускает только test identity.")
    for name, bundle in (("NotebookTests", NATIVE_IPAD_BUNDLE), ("NotebookUITests", NATIVE_IPAD_UI_RUNNER)):
        target = run[name]
        release.require(target.get("TestHostBundleIdentifier") == bundle
                        and target.get("TestBundlePath") == "__TESTHOST__/PlugIns/" + name + ".xctest",
                        "xctestrun ссылается не на ожидаемый isolated test bundle.")
        target["UseDestinationArtifacts"] = True
        target["TestBundleDestinationRelativePath"] = target.pop("TestBundlePath")
        target.pop("TestHostPath")
        if name == "NotebookUITests":
            release.require(target.pop("UITargetAppPath") == "__TESTROOT__/Debug-iphoneos/Notebook.app",
                            "UI target должен быть приложением текущей сборки.")
            target["UITargetAppBundleIdentifier"] = NATIVE_IPAD_BUNDLE
        target["DependentProductPaths"] = [path.replace("__TESTROOT__", str(products))
                                           for path in target.get("DependentProductPaths", [])]
    configured = evidence / "ipad-installed.xctestrun"
    configured.write_bytes(plistlib.dumps(run))
    for label, name, bundle in apps:
        receipt = evidence / ("ipad-install-" + label + ".json")
        command("ipad-install-" + label, ["xcrun", "devicectl", "device", "install", "app",
                "--device", release.UDID, products / "Debug-iphoneos" / name,
                "--timeout", "180", "--json-output", receipt], timeout=200)
        installed = release.successful_json(receipt, "devicectl.device.install.app")
        release.require(any(app.get("bundleID") == bundle for app in installed.get("installedApplications", [])),
                        "Установка test bundle не подтверждена.")
    return configured


def native_mac_signing_settings():
    # Native tests have no persistent worker data. Give their sandbox a stable
    # signed identity separate from both the paired stand and the installed app.
    return ["CODE_SIGN_IDENTITY=Apple Development", "CODE_SIGN_STYLE=Automatic",
            "CODE_SIGNING_ALLOWED=YES", "DEVELOPMENT_TEAM=" + release.TEAM,
            "NOTEBOOK_BUNDLE_SUFFIX=.acceptance", "NOTEBOOK_ACCEPTANCE_ENABLED=YES",
            "NOTEBOOK_SCRIPT_BUNDLE_SUFFIX=.native-test"]


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
    ipad_ui = any(selector.split("/")[0] == "NotebookUITests" for selector in checks["ipad"])
    if checks["ipad"]:
        command("ipad-native-test-cleanup-before", native_ipad_cleanup_arguments(), timeout=120)
        if ipad_ui:
            command("ipad-ui-runner-cleanup-before", native_ipad_cleanup_arguments(NATIVE_IPAD_UI_RUNNER), timeout=120)
    # Every Mac host bundles the MCP sidecar, even a document-only XCTest
    # selection from a clean immutable source copy. Prepare its locked build
    # dependencies independently of whether MCP behavioral tests are selected.
    if checks["mac"] or "mcp" in checks["commands"]:
        command("mcp-dependencies", ["npm", "ci", "--ignore-scripts"], cwd=root / "MCP")
    if checks["core"]:
        output, _ = command("core", ["swift", "test", "--filter", "|".join(checks["core"])], cwd=root, timeout=600, read_output=True)
        release.require(re.search(rb"Test run with [1-9][0-9]* tests? .*passed", output), "Core не исполнил выбранные тесты.")
    for name in checks["commands"]:
        if name == "document-browser":
            command(name, document_browser_arguments(root), cwd=root)
        elif name == "voice-audio":
            command(name, ["node", "--test", str(root / "Tests/NotebookVoiceHarness/audio.test.mjs")], cwd=root)
        elif name == "mcp":
            command("mcp-check", ["npm", "run", "check"], cwd=root / "MCP")
            command("mcp-test", ["npm", "test"], cwd=root / "MCP", timeout=300)
        elif name == "trace-harness":
            command(name, [sys.executable, "-B", str(root / "Tests/NotebookDocumentAcceptance/test_system_trace.py")], cwd=root)
        else:
            script = "NotebookVerification" if name == "verification" else "NotebookRelease"
            command(name, [sys.executable, "-B", str(root / "Tests" / script / "run.py")], cwd=root)
    if checks["mac"] or checks["ipad"]:
        command("generate-project", ["xcodegen", "generate", "--spec", "project.yml"], cwd=root / "Applications")
    # Xcode still builds changed dependencies. Only its derived products are reused;
    # fixtures, test execution, source hashes and result bundles are always fresh.
    derived = Path(tempfile.gettempdir()) / "notebook-selected-builds" / hashlib.sha256(str(root).encode()).hexdigest()[:16]
    for platform, scheme in (("ipad", "Notebook"), ("mac", "NotebookMac")):
        if not checks[platform]:
            continue
        destination = "platform=macOS"
        if platform == "ipad":
            destination = "platform=iOS,id=" + release.UDID
        result = evidence / (platform + ".xcresult")
        args = ["xcrun", "xcodebuild", "-quiet", "-project", "Notebook.xcodeproj", "-scheme", scheme,
                "-configuration", "Debug", "-destination", destination, "-derivedDataPath", str(derived / platform),
                "-resultBundlePath", str(result), "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never",
                "test"] + ["-only-testing:" + selector for selector in checks[platform]]
        if plan.get("optimized", False):
            # Keep the isolated DEBUG fixtures; measure compiled application
            # code, not -Onone bookkeeping. Record this in selection.json.
            args.append("SWIFT_OPTIMIZATION_LEVEL=-O")
        if platform == "ipad":
            args.extend(native_ipad_signing_settings())
        runtime = release.prepare_typesetter_runtime(root, command, "macosx" if platform == "mac" else "iphoneos")
        args.append("NOTEBOOK_TYPESETTER_RUNTIME=" + str(runtime))
        if platform == "mac":
            release.prepare_codex_runtime(root, command)
            typescript_runtime = release.prepare_typescript_runtime(root, command)
            args.append("NOTEBOOK_TYPESCRIPT_RUNTIME=" + str(typescript_runtime))
            args.extend(native_mac_signing_settings())
            build_args = [value for value in args if value not in ("-resultBundlePath", str(result), "test")]
            command("mac-build-for-testing", build_args + ["build-for-testing"], cwd=root / "Applications", timeout=1800)
            app = derived / "mac/Build/Products/Debug/Notebook.app"
            display = command("mac-native-signer", ["/usr/bin/codesign", "--display", "--verbose=4", app], read_output=True)
            signer, identity = release.development_signer(b"\n".join(display).decode(), release.MAC_BUNDLE + ".acceptance")
            release.restrict_test_script_services(app, root, command, bundle_identifier=release.MAC_BUNDLE + ".acceptance", signing_identity=signer)
            release.write_json(evidence / "mac-native-signature.json", {"identity": identity,
                "workerBundleSuffix": ".native-test", "scope": "isolated stateless native-test workers"})
            args[args.index("test")] = "test-without-building"
        try:
            if platform == "ipad" and ipad_ui:
                build_args = [value for value in args if value not in ("-resultBundlePath", str(result), "test")]
                command("ipad-build-for-testing", build_args + ["build-for-testing"], cwd=root / "Applications", timeout=1800)
                configured = install_native_ipad_ui_artifacts(derived / "ipad/Build/Products", evidence, command)
                args = ["xcrun", "xcodebuild", "-quiet", "-xctestrun", str(configured),
                        "-destination", destination, "-resultBundlePath", str(result),
                        "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never",
                        "test-without-building"] + ["-only-testing:" + selector for selector in checks[platform]]
            command(platform, args, cwd=root / "Applications", timeout=1800)
            summary, _ = command(platform + "-summary", ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result), "--compact"], read_output=True)
            summary = json.loads(summary); validate_summary(summary)
            release.write_json(evidence / (platform + "-summary.json"), summary)
            tests, _ = command(platform + "-tests", ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(result), "--compact"], read_output=True)
            tests = json.loads(tests)
            validate_executed_tests(tests, checks[platform])
            release.write_json(evidence / (platform + "-tests.json"), tests)
            release.write_json(evidence / (platform + "-timings.json"), timing_report(tests))
            if selected_hitch_tests(checks[platform]):
                metrics, _ = command(platform + "-metrics", ["xcrun", "xcresulttool", "get", "test-results", "metrics", "--path", str(result), "--compact"], read_output=True)
                metrics = json.loads(metrics)
                release.write_json(evidence / (platform + "-metrics.json"), metrics)
                validate_hitch_metrics(metrics, checks[platform])
        finally:
            if platform == "ipad":
                try:
                    command("ipad-native-test-cleanup-after", native_ipad_cleanup_arguments(), timeout=120)
                finally:
                    if ipad_ui:
                        command("ipad-ui-runner-cleanup-after", native_ipad_cleanup_arguments(NATIVE_IPAD_UI_RUNNER), timeout=120)
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
    parser.add_argument("--optimized", action="store_true", help="оптимизированный native код (-O) с изолированными DEBUG fixtures; режим записывается в свидетельства")
    parser.add_argument("--only", action="store_true", help="только явные --profile/--test, без автоматического добавления наборов")
    parser.add_argument("--plan", action="store_true", help="показать выбор, ничего не запускать")
    parser.add_argument("--base", default="HEAD", help="Git ref начала правки; по умолчанию незакоммиченные изменения")
    parser.add_argument("--profile", action="append", choices=sorted(PROFILES), default=[])
    parser.add_argument("--test", action="append", default=[], help="точный XCTest target/suite/method")
    parser.add_argument("--evidence-dir", type=Path)
    parser.add_argument("--timings", type=Path, help="прочитать времена из существующего xcresult без запуска тестов")
    args = parser.parse_args(argv)
    release.require(not (args.full and args.optimized), "--optimized относится к выбранным проверкам, не к полному маршруту.")
    release.require(not (args.full and args.only), "--full и --only задают разные области проверки.")
    if args.timings:
        tree = json.loads(subprocess.check_output(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(args.timings), "--compact"]))
        print(json.dumps(timing_report(tree), ensure_ascii=False, indent=2)); return
    plan = {"route": "full", "notice": "Все нагрузки, native и UI; не обычная итерация."} if args.full else make_plan(ROOT, args.base, args.profile, args.test, only=args.only)
    if not args.full:
        plan["optimized"] = args.optimized
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

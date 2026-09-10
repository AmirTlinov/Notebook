import SwiftUI
import XCTest

@testable import Notebook

final class TwoFingerGestureClassifierTests: XCTestCase {
  func testPageTurnPreparesTheSheetBeyondTheCurrentLanding() {
    XCTAssertEqual(
      PageTurnPrewarmWindow.indices(
        displayedIndex: 2,
        anticipatedIndex: 3,
        lastDirection: nil,
        pageCount: 8
      ),
      Set([1, 2, 3, 4])
    )
    XCTAssertEqual(
      PageTurnPrewarmWindow.indices(
        displayedIndex: 3,
        anticipatedIndex: nil,
        lastDirection: 1,
        pageCount: 8
      ),
      Set([2, 3, 4, 5])
    )
  }

  func testLateModelAcknowledgementsCannotRewindRapidLandings() {
    var selection = PageTurnSelectionTracker(displayedIndex: 0)
    selection.recordLocalLanding(at: 1)
    selection.recordLocalLanding(at: 2)

    XCTAssertNil(selection.externalTarget(forModelIndex: 0))
    XCTAssertEqual(selection.displayedIndex, 2)
    XCTAssertNil(selection.externalTarget(forModelIndex: 1))
    XCTAssertEqual(selection.displayedIndex, 2)
    XCTAssertNil(selection.externalTarget(forModelIndex: 2))
    XCTAssertFalse(selection.awaitsLocalAcknowledgement)
  }

  @MainActor
  func testIPadPageTurnUsesTheSystemPageCurl() {
    let controller = IPadPageTurnController()
    controller.loadViewIfNeeded()

    XCTAssertEqual(controller.pageViewController.transitionStyle, .pageCurl)
    XCTAssertEqual(
      controller.pageViewController.navigationOrientation,
      .horizontal
    )
    XCTAssertFalse(controller.pageViewController.isDoubleSided)
  }

  @MainActor
  func testIPadCurlPrewarmsTheFollowingLivePageBeforeLanding() throws {
    let controller = IPadPageTurnController()
    let ownerID = UUID()
    let renderPage:
      @MainActor (Int, Bool, PageTurnReadiness) -> AnyView = {
        index, _, readiness in
        readiness(true)
        return AnyView(Text("Page \(index)"))
      }
    controller.update(
      ownerID: ownerID,
      sequenceRevision: "fixture-order",
      pageCount: 5,
      selectedIndex: 1,
      navigationIsEnabled: true,
      pageIsInteractive: true,
      canBeginNavigation: { true },
      page: renderPage,
      onCommit: { _, _ in },
      onTransitioningChange: { _ in }
    )
    controller.loadViewIfNeeded()
    let current = try XCTUnwrap(
      controller.pageViewController.viewControllers?.first
    )
    let target = try XCTUnwrap(
      controller.pageViewController(
        controller.pageViewController,
        viewControllerAfter: current
      )
    )

    controller.pageViewController(
      controller.pageViewController,
      willTransitionTo: [target]
    )

    XCTAssertNotNil(
      controller.cachedPageIdentities[3],
      "Пока лист 2 ещё в руке, лист 3 уже должен показать первый живой кадр"
    )
  }

  @MainActor
  func testTrailingNotebookLandingExposesTheNextBlankSheetImmediately() throws {
    let controller = IPadPageTurnController()
    let ownerID = UUID()
    let renderPage:
      @MainActor (Int, Bool, PageTurnReadiness) -> AnyView = {
        index, _, readiness in
        readiness(true)
        return AnyView(Text("Page \(index)"))
      }
    controller.update(
      ownerID: ownerID,
      sequenceRevision: "fixture-order",
      pageCount: 2,
      selectedIndex: 0,
      allowsTrailingPageCreation: true,
      navigationIsEnabled: true,
      pageIsInteractive: true,
      canBeginNavigation: { true },
      page: renderPage,
      onCommit: { _, _ in },
      onTransitioningChange: { _ in }
    )
    controller.loadViewIfNeeded()
    let current = try XCTUnwrap(
      controller.pageViewController.viewControllers?.first
    )
    let target = try XCTUnwrap(
      controller.pageViewController(
        controller.pageViewController,
        viewControllerAfter: current
      )
    )
    controller.pageViewController(
      controller.pageViewController,
      willTransitionTo: [target]
    )
    controller.pageViewController.setViewControllers(
      [target],
      direction: .forward,
      animated: false
    )
    controller.pageViewController(
      controller.pageViewController,
      didFinishAnimating: true,
      previousViewControllers: [current],
      transitionCompleted: true
    )

    XCTAssertNotNil(
      controller.cachedPageIdentities[2],
      "Новый чистый лист должен существовать до следующего движения пальца"
    )
  }

  @MainActor
  func testIPadTurnLandsTheAlreadyMountedTargetPage() async throws {
    let controller = IPadPageTurnController()
    let ownerID = UUID()
    controller.update(
      ownerID: ownerID,
      sequenceRevision: "fixture-order",
      pageCount: 2,
      selectedIndex: 0,
      navigationIsEnabled: true,
      pageIsInteractive: true,
      canBeginNavigation: { true },
      page: { index, _, readiness in
        readiness(true)
        return AnyView(Text("Page \(index)"))
      },
      onCommit: { _, _ in },
      onTransitioningChange: { _ in }
    )
    controller.loadViewIfNeeded()
    controller.view.frame = CGRect(x: 0, y: 0, width: 1_024, height: 1_366)
    controller.view.layoutIfNeeded()

    let targetIdentity = try XCTUnwrap(controller.cachedPageIdentities[1])

    controller.update(
      ownerID: ownerID,
      sequenceRevision: "fixture-order",
      pageCount: 2,
      selectedIndex: 1,
      navigationIsEnabled: true,
      pageIsInteractive: true,
      canBeginNavigation: { true },
      page: { index, _, readiness in
        readiness(true)
        return AnyView(Text("Page \(index)"))
      },
      onCommit: { _, _ in },
      onTransitioningChange: { _ in }
    )
    try? await Task.sleep(for: .milliseconds(650))

    XCTAssertEqual(controller.displayedIndex, 1)
    XCTAssertEqual(
      controller.visiblePageIdentity,
      targetIdentity,
      "Приземлиться должен тот же экземпляр страницы, который уже был виден в жесте"
    )
  }

  @MainActor
  func testIPadReverseCandidateRemainsOwnedByThePageController() throws {
    let controller = IPadPageTurnController()
    let ownerID = UUID()
    let renderPage:
      @MainActor (Int, Bool, PageTurnReadiness) -> AnyView = {
        index, _, readiness in
        readiness(true)
        return AnyView(Text("Page \(index)"))
      }
    controller.update(
      ownerID: ownerID,
      sequenceRevision: "fixture-order",
      pageCount: 3,
      selectedIndex: 1,
      navigationIsEnabled: true,
      pageIsInteractive: true,
      canBeginNavigation: { true },
      page: renderPage,
      onCommit: { _, _ in },
      onTransitioningChange: { _ in }
    )
    controller.loadViewIfNeeded()

    let current = try XCTUnwrap(
      controller.pageViewController.viewControllers?.first
    )
    let reverseCandidate = try XCTUnwrap(
      controller.pageViewController(
        controller.pageViewController,
        viewControllerBefore: current
      )
    )
    XCTAssertNil(reverseCandidate.parent)

    // SwiftUI can update the representable while UIKit still holds this
    // candidate for a page curl. The outer container must not adopt it again.
    controller.update(
      ownerID: ownerID,
      sequenceRevision: "fixture-order",
      pageCount: 3,
      selectedIndex: 1,
      navigationIsEnabled: true,
      pageIsInteractive: true,
      canBeginNavigation: { true },
      page: renderPage,
      onCommit: { _, _ in },
      onTransitioningChange: { _ in }
    )

    XCTAssertNil(
      reverseCandidate.parent,
      "Переданная UIKit страница не должна снова становиться дочерней у prewarm-контейнера"
    )
  }

  @MainActor
  func testPencilInvalidatesAnAlreadyStartedFingerSequence() throws {
    let gate = NotebookInputGate()
    let fingerRevision = try XCTUnwrap(gate.beginFingerSequence())
    let pencilSource = UUID()

    gate.beginPencilAction(source: pencilSource)
    XCTAssertFalse(gate.acceptsFingerSequence(fingerRevision))
    XCTAssertNil(gate.beginFingerSequence())

    gate.endPencilAction(source: pencilSource)
    XCTAssertFalse(
      gate.acceptsFingerSequence(fingerRevision),
      "Пересёкшуюся пару должен целиком завершить владелец Pencil"
    )
    XCTAssertNotNil(gate.beginFingerSequence())
  }

  func testSmallDeliberatePinchBelongsToTheCamera() {
    let intent = TwoFingerIntentArbiter.resolve(
      defersHorizontalMotionToPageTurn: true,
      translation: .zero,
      fingerDisplacements: [
        CGPoint(x: -4, y: 0),
        CGPoint(x: 4, y: 0),
      ],
      magnification: 1.025,
      elapsed: 0.08
    )

    XCTAssertEqual(intent, .magnification)
  }

  func testReleasedPinchRetainsItsMotionIdentity() {
    XCTAssertFalse(
      TwoFingerUndoClassifier.isTap(
        maximumFingerTravel: 5,
        maximumCentroidTravel: 0,
        maximumRelativeTravel: 5,
        elapsed: 0.12
      )
    )
  }

  func testQuietTwoFingerTapStillOwnsUndo() {
    XCTAssertTrue(
      TwoFingerUndoClassifier.isTap(
        maximumFingerTravel: 2.5,
        maximumCentroidTravel: 1.5,
        maximumRelativeTravel: 1.2,
        elapsed: 0.14
      )
    )
  }

  func testMagnificationDirectionSurvivesGestureAcquisition() {
    XCTAssertTrue(
      TwoFingerIntentArbiter.isOpeningApproach(magnification: 1.05)
    )
    XCTAssertFalse(
      TwoFingerIntentArbiter.isOpeningApproach(magnification: 0.95)
    )
  }

  func testNoisyHorizontalPageSwipeOwnsTheGestureBeforePinch() {
    let intent = TwoFingerIntentArbiter.resolve(
      defersHorizontalMotionToPageTurn: true,
      translation: CGPoint(x: -10, y: 0),
      fingerDisplacements: [
        CGPoint(x: -5, y: 0),
        CGPoint(x: -15, y: 0),
      ],
      magnification: 0.95,
      elapsed: 0.08
    )

    XCTAssertEqual(intent, .navigation)
  }

  func testTwelvePointCoherentTravelAcquiresThePageRail() {
    let acquired = TwoFingerIntentArbiter.resolve(
      defersHorizontalMotionToPageTurn: true,
      translation: CGPoint(x: -12, y: 0),
      fingerDisplacements: [
        CGPoint(x: -12, y: 0),
        CGPoint(x: -12, y: 0),
      ],
      magnification: 1,
      elapsed: 0.03
    )
    let waiting = TwoFingerIntentArbiter.resolve(
      defersHorizontalMotionToPageTurn: true,
      translation: CGPoint(x: -11.9, y: 0),
      fingerDisplacements: [
        CGPoint(x: -11.9, y: 0),
        CGPoint(x: -11.9, y: 0),
      ],
      magnification: 1,
      elapsed: 0.03
    )

    XCTAssertEqual(acquired, .navigation)
    XCTAssertEqual(waiting, .undecided)
  }

  func testTruePinchWithDriftingCentroidOwnsTheCamera() {
    let intent = TwoFingerIntentArbiter.resolve(
      defersHorizontalMotionToPageTurn: true,
      translation: CGPoint(x: 10, y: 4),
      fingerDisplacements: [
        CGPoint(x: -36, y: 2),
        CGPoint(x: 56, y: 6),
      ],
      magnification: 1.46,
      elapsed: 0.04
    )

    XCTAssertEqual(intent, .magnification)
  }

  func testFirstMovingFingerWaitsForEvidence() {
    let intent = TwoFingerIntentArbiter.resolve(
      defersHorizontalMotionToPageTurn: true,
      translation: CGPoint(x: -8, y: 0),
      fingerDisplacements: [
        CGPoint(x: -16, y: 0),
        .zero,
      ],
      magnification: 0.92,
      elapsed: 0.02
    )

    XCTAssertEqual(intent, .undecided)
  }

  func testAnchoredPinchStartsAfterTheEvidenceWindow() {
    let intent = TwoFingerIntentArbiter.resolve(
      defersHorizontalMotionToPageTurn: true,
      translation: CGPoint(x: 8, y: 0),
      fingerDisplacements: [
        .zero,
        CGPoint(x: 16, y: 0),
      ],
      magnification: 1.08,
      elapsed: 0.07
    )

    XCTAssertEqual(intent, .magnification)
  }

  func testFastBoardSampleIsSplitAroundCrossedCover() {
    let itemID = UUID()
    let intervals = SpatialSurfaceRouter.intervals(
      from: CGPoint(x: 0, y: 50),
      to: CGPoint(x: 300, y: 50),
      covers: [
        SpatialScreenSurface(
          id: .cover(itemID),
          frame: CGRect(x: 100, y: 0, width: 100, height: 100),
          zIndex: 1
        )
      ]
    )

    XCTAssertEqual(
      intervals.map(\.surface),
      [
        .board,
        .cover(itemID),
        .board,
      ])
    XCTAssertEqual(intervals[0].upperBound, 1.0 / 3.0, accuracy: 0.0001)
    XCTAssertEqual(intervals[1].upperBound, 2.0 / 3.0, accuracy: 0.0001)
  }

  func testTopCoverOwnsAnOverlappingSegment() {
    let lower = UUID()
    let upper = UUID()
    let intervals = SpatialSurfaceRouter.intervals(
      from: CGPoint(x: 0, y: 50),
      to: CGPoint(x: 300, y: 50),
      covers: [
        SpatialScreenSurface(
          id: .cover(lower),
          frame: CGRect(x: 50, y: 0, width: 200, height: 100),
          zIndex: 1
        ),
        SpatialScreenSurface(
          id: .cover(upper),
          frame: CGRect(x: 125, y: 0, width: 50, height: 100),
          zIndex: 2
        ),
      ]
    )

    XCTAssertTrue(intervals.contains { $0.surface == .cover(upper) })
    XCTAssertEqual(
      SpatialSurfaceRouter.surface(
        at: CGPoint(x: 150, y: 50),
        covers: [
          SpatialScreenSurface(
            id: .cover(lower),
            frame: CGRect(x: 50, y: 0, width: 200, height: 100),
            zIndex: 1
          ),
          SpatialScreenSurface(
            id: .cover(upper),
            frame: CGRect(x: 125, y: 0, width: 50, height: 100),
            zIndex: 2
          ),
        ]
      ),
      .cover(upper)
    )
  }

  @MainActor
  func testFirstConfirmedPairMotionIsNotDiscardedAtRecognition() {
    for direction: CGFloat in [-1, 1] {
      let gate = NotebookInputGate(), view = UIView(frame: .init(x: 0, y: 0, width: 500, height: 500))
      let recognizer = TwoFingerPaperGestureRecognizer()
      recognizer.inputGate = gate; view.addGestureRecognizer(recognizer)
      let first = PairMotionTouch(x: 60), second = PairMotionTouch(x: 300), event = UIEvent()
      recognizer.touchesBegan([first], with: event)
      first.point.x = 100
      recognizer.touchesMoved([first], with: event)
      recognizer.touchesBegan([second], with: event)
      first.point.x -= 4 * direction; second.point.x += 4 * direction
      first.time = 1.1; second.time = 1.1
      recognizer.touchesMoved([first, second], with: event)
      XCTAssertEqual(recognizer.intent, .magnification)
      XCTAssertEqual(recognizer.startCentroidValue, CGPoint(x: 200, y: 200))
      XCTAssertEqual(recognizer.magnification, 1 + 0.04 * direction, accuracy: 0.0001,
        "Recognition owns the measured motion from the established pair, not a second zero baseline")
      recognizer.touchesEnded([first, second], with: event)
      XCTAssertEqual(recognizer.magnification, 1 + 0.04 * direction, accuracy: 0.0001)
      view.removeGestureRecognizer(recognizer)
    }
  }

  @MainActor
  func testOneRecognizerOwnsTheWholeTwoFingerSequence() {
    let host = UIView(frame: CGRect(x: 0, y: 0, width: 800, height: 1_100))
    let scene = UIView(frame: host.bounds)
    host.addSubview(scene)
    let controller = WorkspaceGestureLayer.Coordinator(
      defersHorizontalMotionToPageTurn: true,
      isEnabled: true,
      inputGate: NotebookInputGate(),
      onCamera: { _ in },
      onUndo: {}
    )

    controller.install(on: host, inside: scene)
    controller.install(on: host, inside: scene)

    let paperRecognizers = (host.gestureRecognizers ?? []).compactMap {
      $0 as? TwoFingerPaperGestureRecognizer
    }
    XCTAssertEqual(paperRecognizers.count, 1)

    controller.uninstall()
    XCTAssertFalse(
      (host.gestureRecognizers ?? []).contains {
        $0 is TwoFingerPaperGestureRecognizer
      }
    )
  }
}

@MainActor
private final class PairMotionTouch: UITouch {
  var point: CGPoint, time: TimeInterval = 1
  init(x: CGFloat) { point = .init(x: x, y: 200); super.init() }
  override var timestamp: TimeInterval { time }
  override var type: UITouch.TouchType { .direct }
  override func location(in view: UIView?) -> CGPoint { point }
}

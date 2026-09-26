import Foundation
import NotebookCore
import XCTest
import SwiftUI
import UIKit
@testable import Notebook

final class PageTurnSelectionTests: XCTestCase {
  @MainActor
  func testReferenceUsesTheMountedNotebookOwnerWithoutPublishingAnUnpreparedTarget() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let item = try XCTUnwrap(model.workspace?.selectedItemID), original = try XCTUnwrap(model.activePage?.id)
    XCTAssertEqual(model.selectNotebookPage(1, notebookID: item, expectedRoot: model.notebookPageRoot(item)!), 1)
    let target = try XCTUnwrap(model.activePage?.id)
    XCTAssertEqual(model.selectNotebookPage(0, notebookID: item, expectedRoot: model.notebookPageRoot(item)!), 0)
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    let controller = IPadPageTurnController()
    var readiness: [Int: PageTurnReadiness] = [:]
    controller.update(ownerID: item, sequenceRevision: model.notebookPageRoot(item)!, pageCount: 2,
      selectedIndex: 0, navigationIsEnabled: true, pageIsInteractive: true, canBeginNavigation: { true },
      page: { index, _, ready in
        readiness[index] = ready
        if index == 0 { ready(true) }
        return AnyView(Color.white)
      }, onCommit: { index, source in
        XCTAssertEqual(model.selectNotebookPage(index, notebookID: item, expectedRoot: source), index)
      }, onTransitioningChange: { _ in }, notebookNavigation: model.notebookPageNavigation)
    controller.loadViewIfNeeded()
    let requested = await model.navigateToNotebookPage(id: target, isCurrent: { true })
    XCTAssertTrue(requested)
    XCTAssertEqual(model.activePage?.id, original, "A reference is intent, not a premature model landing")
    XCTAssertEqual(controller.displayedIndex, 0)
    try XCTUnwrap(readiness[1])(true)
    for _ in 0..<100 where controller.displayedIndex != 1 { await Task.yield() }
    XCTAssertEqual(controller.displayedIndex, 1)
    XCTAssertEqual(model.activePage?.id, target)
  }

  @MainActor
  func testColdReadyPageWaitsForTheNewContactAndCancellationRevokesItsHandoff() async throws {
    let controller = IPadPageTurnController(), navigation = NotebookPageNavigation(), gate = NotebookInputGate()
    let owner = UUID(), contact = UUID()
    var readiness: [Int: PageTurnReadiness] = [:], commits: [Int] = []
    controller.update(ownerID: owner, sequenceRevision: "contact-fence", pageCount: 3,
      selectedIndex: 0, navigationIsEnabled: true, pageIsInteractive: true, canBeginNavigation: { true },
      page: { index, _, ready in
        readiness[index] = ready; if index == 0 { ready(true) }; return AnyView(Color.white)
      }, onCommit: { index, _ in commits.append(index) }, onTransitioningChange: { _ in },
      notebookNavigation: navigation, inputGate: gate)
    controller.loadViewIfNeeded()
    XCTAssertTrue(navigation.send(.jump(2), ownerID: owner, source: "contact-fence"))
    gate.beginContact(source: contact)
    defer { gate.endContact(source: contact) }
    try XCTUnwrap(readiness[2])(true)
    for _ in 0..<10 { await Task.yield() }
    XCTAssertEqual(controller.displayedIndex, 0, "Readiness cannot take the page from a new contact")
    XCTAssertTrue(navigation.send(.cancel, ownerID: owner, source: "contact-fence"))
    gate.endContact(source: contact)
    try await Task.sleep(for: .milliseconds(60))
    XCTAssertEqual(controller.displayedIndex, 0, "A cancelled queued handoff cannot run after lift")
    XCTAssertTrue(commits.isEmpty)
    XCTAssertTrue(navigation.send(.jump(2), ownerID: owner, source: "contact-fence"))
    for _ in 0..<100 where controller.displayedIndex != 2 { await Task.yield() }
    XCTAssertEqual(controller.displayedIndex, 2)
    XCTAssertEqual(commits, [2])
  }

  @MainActor
  func testNewHumanContactCancelsAnAlreadyAdmittedPageReference() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let item = try XCTUnwrap(model.workspace?.selectedItemID)
    XCTAssertEqual(model.selectNotebookPage(1, notebookID: item, expectedRoot: model.notebookPageRoot(item)!), 1)
    let target = try XCTUnwrap(model.activePage?.id)
    XCTAssertEqual(model.selectNotebookPage(0, notebookID: item, expectedRoot: model.notebookPageRoot(item)!), 0)
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    let controller = IPadPageTurnController()
    var readiness: [Int: PageTurnReadiness] = [:]
    controller.update(ownerID: item, sequenceRevision: model.notebookPageRoot(item)!, pageCount: 2,
      selectedIndex: 0, navigationIsEnabled: true, pageIsInteractive: true, canBeginNavigation: { true },
      page: { index, _, ready in
        readiness[index] = ready; if index == 0 { ready(true) }; return AnyView(Color.white)
      }, onCommit: { _, _ in XCTFail("Cancelled reference landed") }, onTransitioningChange: { _ in },
      notebookNavigation: model.notebookPageNavigation)
    controller.loadViewIfNeeded()
    model.requestShow(.init(target: .init(kind: .page, id: target), revision: "fixture"))
    let requested = try XCTUnwrap(model.requestedReference)
    await model.resolveReferenceLocation(requested) { _ in }
    XCTAssertEqual(controller.displayedIndex, 0)
    model.inputGate.notifyAcceptedContact()
    XCTAssertNil(model.requestedReference)
    try XCTUnwrap(readiness[1])(true)
    for _ in 0..<50 { await Task.yield() }
    XCTAssertEqual(controller.displayedIndex, 0)
  }

  @MainActor
  func testNotebookAcknowledgementCannotBecomeAnUnrequestedReverseTurn() async throws {
    let controller = IPadPageTurnController(), navigation = NotebookPageNavigation(), owner = UUID()
    var commits: [Int] = []
    func configure(_ selected: Int) {
      controller.update(ownerID: owner, sequenceRevision: "one-navigation-owner", pageCount: 2,
        selectedIndex: selected, navigationIsEnabled: true, pageIsInteractive: true,
        canBeginNavigation: { true }, page: { index, _, ready in
          ready(true)
          return AnyView(index == 0 ? Color.blue : Color.red)
        }, onCommit: { index, _ in commits.append(index) }, onTransitioningChange: { _ in },
        notebookNavigation: navigation)
    }
    configure(0); controller.loadViewIfNeeded()
    for target in [1, 0] {
      XCTAssertTrue(navigation.send(.step(target == 1 ? 1 : -1), ownerID: owner, source: "one-navigation-owner"))
      for _ in 0..<100 where controller.displayedIndex != target { await Task.yield() }
      XCTAssertEqual(controller.displayedIndex, target)
      configure(target)
    }
    // A retained upstream hosting root can still publish the preceding model
    // snapshot. Only the bound navigation command can request another turn.
    configure(1)
    for _ in 0..<100 { await Task.yield() }
    XCTAssertEqual(controller.displayedIndex, 0, "An acknowledgement is not another navigation command")
    XCTAssertEqual(commits, [1, 0])
  }
  @MainActor
  func testRepeatedNotebookArrowsPrepareOnlyLatestTargetWithoutChangingPresenceEarly() async throws {
    let controller = IPadPageTurnController(), commands = NotebookPageNavigation(), owner = UUID()
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
    window.frame = scene.effectiveGeometry.coordinateSpace.bounds
    var selected = 0, landed: [Int] = [], readiness: [Int: PageTurnReadiness] = [:]
    func configure() {
      controller.update(ownerID: owner, sequenceRevision: "sheets", pageCount: 5, selectedIndex: selected,
        navigationIsEnabled: true, pageIsInteractive: true, canBeginNavigation: { false },
        page: { index, _, ready in
          readiness[index] = ready
          if index == 0 { ready(true) }
          return AnyView(Color.white.overlay(Text("Sheet \(index)")))
        }, onCommit: { index, _ in selected = index; landed.append(index); configure() },
        onTransitioningChange: { _ in }, notebookNavigation: commands)
    }
    configure(); window.rootViewController = controller; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    window.layoutIfNeeded()
    // This is the selection contract, not cold-opening latency. The source
    // must have reached its first native update before a visible turn starts.
    try await Task.sleep(for: .milliseconds(32))
    for _ in 0..<3 { XCTAssertTrue(commands.send(.step(1), ownerID: owner, source: "sheets")) }
    XCTAssertEqual(selected, 0, "Requested work is not a shown page")
    XCTAssertEqual(controller.displayedIndex, 0)
    let curl = try XCTUnwrap(controller.sheetController.view.subviews.compactMap { $0 as? SheetCurlMetalView }.first)
    let resolve = curl.onFrameReady
    var showedBend = false
    curl.onFrameReady = { image, progress, sequence, readiness in
      if readiness.isReady, progress > 0, progress < 1 { showedBend = true }
      resolve?(image, progress, sequence, readiness)
    }
    try XCTUnwrap(readiness[3])(true)
    let deadline = ContinuousClock.now + .seconds(2)
    while selected != 3, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(8)) }
    XCTAssertEqual(selected, 3)
    XCTAssertEqual(controller.displayedIndex, 3)
    XCTAssertTrue(showedBend, "A coalesced arrow destination still curls from the current paper; it is not a delayed pop")
    XCTAssertEqual(landed, [3], "Three accepted steps select page 3 without manufacturing obsolete page 1/2 landings")
    XCTAssertEqual(controller.sheetController.view.layer.speed, 1, "The page subtree must retain the system clock")
  }

  @MainActor
  func testDocumentSourceReplacementRetainsHostsButRevokesTheirPendingCapture() async throws {
    let controller = IPadPageTurnController(), documentID = UUID()
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
    var source = "old-source", actual = 0, sourceReady = true
    var request: DocumentPageNavigationRequest?
    var readiness: [String: [Int: PageTurnReadiness]] = [:]
    var landings: [DocumentPageLanding] = []
    func configure() {
      let revision = source
      controller.update(ownerID: documentID, sequenceRevision: revision, pageCount: 2,
        selectedIndex: actual, navigationIsEnabled: true, pageIsInteractive: true,
        canBeginNavigation: { true }, page: { index, _, ready in
          readiness[revision, default: [:]][index] = ready
          ready(index != 0 || sourceReady)
          return AnyView(index == 0 ? Color.blue : Color.red)
        }, onCommit: { _, _ in XCTFail("A document landing uses its typed receipt") },
        onTransitioningChange: { _ in },
        canonicalDocumentLayout: .init(pageCount: 2, sourceRevision: revision), documentSelection: request,
        documentNavigation: .init(bind: { _, _, _ in }, unbind: { _ in }, landed: { receipt in
          landings.append(receipt); actual = receipt.pageIndex
          if request?.id == receipt.requestID { request = nil }
        }, status: { _ in }))
    }
    configure(); window.rootViewController = controller; window.makeKeyAndVisible()
    defer { controller.sheetController.cancelMotion(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    window.layoutIfNeeded()
    let native = controller.sheetController, original = try XCTUnwrap(controller.visiblePageIdentity)
    let hosts = controller.cachedPageIdentities, checkReadiness = native.isSheetReadyForCapture
    var refusedCaptures = 0, captures = 0
    native.isSheetReadyForCapture = { sheet in
      let ready = checkReadiness(sheet)
      if !ready { refusedCaptures += 1 }
      return ready
    }
    native.onCaptureMeasured = { _ in captures += 1 }
    sourceReady = false
    try XCTUnwrap(readiness[source]?[0])(false)
    request = .init(id: UUID(), documentID: documentID, sourceRevision: source, pageIndex: 1)
    configure()
    let refused = ContinuousClock.now + .seconds(2)
    while refusedCaptures == 0, ContinuousClock.now < refused { try await Task.sleep(for: .milliseconds(2)) }
    XCTAssertGreaterThan(refusedCaptures, 0, "Exercise a real motion still waiting for its source image")
    XCTAssertNotNil(native.settlingPage)
    XCTAssertEqual(captures, 0)
    let oldReceipt = try XCTUnwrap(readiness[source]?[0])

    source = "new-source"; request = nil
    configure()
    XCTAssertEqual(controller.cachedPageIdentities, hosts, "Editing the document retains its native hosts")
    XCTAssertNil(native.settlingPage, "The old source's motion must end before new readiness can arrive")
    oldReceipt(true)
    XCTAssertFalse(controller.currentPagePreparation.isReady, "A retained host does not authorize an old source receipt")
    sourceReady = true
    try XCTUnwrap(readiness[source]?[0])(true)
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      DispatchQueue.main.async { continuation.resume() }
    }
    XCTAssertEqual(captures, 0, "New-source readiness cannot revive the retired capture")
    XCTAssertEqual(controller.visiblePageIdentity, original)
    XCTAssertEqual(controller.displayedIndex, 0); XCTAssertEqual(actual, 0)
    XCTAssertFalse(landings.contains { $0.pageIndex == 1 })

    request = .init(id: UUID(), documentID: documentID, sourceRevision: source, pageIndex: 1)
    configure()
    let completed = ContinuousClock.now + .seconds(2)
    while actual != 1, ContinuousClock.now < completed { try await Task.sleep(for: .milliseconds(2)) }
    XCTAssertEqual(captures, 1)
    XCTAssertEqual(controller.displayedIndex, 1); XCTAssertEqual(actual, 1)
    XCTAssertEqual(landings.filter { $0.pageIndex == 1 }.map(\.sourceRevision), [source])
  }

  @MainActor
  func testOpeningPreparationRetainsItsFailureKindAndRevokesLateSourceRetry() async throws {
    let controller = IPadPageTurnController(), ownerID = UUID()
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    var source = "first-source", readiness: PageTurnReadiness?, retries = 0
    func configure() {
      controller.update(ownerID: ownerID, sequenceRevision: source, pageCount: 1,
        selectedIndex: 0, navigationIsEnabled: false, pageIsInteractive: false,
        canBeginNavigation: { false }, page: { _, _, ready in
          readiness = ready; return AnyView(Color.white)
        }, onCommit: { _, _ in XCTFail("Preparation is not a page landing") }, onTransitioningChange: { _ in })
    }
    configure(); window.rootViewController = controller; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    XCTAssertFalse(controller.currentPagePreparation.isReady)
    for kind in [PageTurnPreparationFailure.Kind.resourceLimit, .snapshotPending, .preparationFailed] {
      let failure = PageTurnPreparationFailure(kind: kind, message: "Owned preparation failure") { retries += 1 }
      try XCTUnwrap(readiness).failed(failure)
      guard case .failed(let observed) = controller.currentPagePreparation else { return XCTFail("Only an explicit failure can pause opening") }
      XCTAssertEqual(observed.id, failure.id); XCTAssertEqual(observed.kind, kind)
      XCTAssertEqual(observed.message, failure.message)
      let before = retries
      observed.retry()
      XCTAssertEqual(retries, before + 1)
      if case .waiting = controller.currentPagePreparation {} else { XCTFail("Retry reuses this pending native page") }
      observed.retry()
      XCTAssertEqual(retries, before + 1, "An old Retry cannot repeat a stage already restarted")
    }
    let oldReadiness = try XCTUnwrap(readiness)
    oldReadiness.failed(.init(message: "Old source failed") { retries += 1 })
    guard case .failed(let stale) = controller.currentPagePreparation else { return XCTFail("Expected retained failure") }
    let beforeReplacement = retries
    source = "replacement-source"; configure()
    stale.retry()
    oldReadiness.failed(.init(message: "Late old failure") { retries += 1 })
    XCTAssertEqual(retries, beforeReplacement, "Source replacement revokes the failed heap's Retry")
    if case .waiting = controller.currentPagePreparation {} else { XCTFail("Old receipts cannot fail the replacement") }
    try XCTUnwrap(readiness)(true)
    let deadline = ContinuousClock.now + .seconds(1)
    while !controller.currentPagePreparation.isReady, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertTrue(controller.currentPagePreparation.isReady)
  }

  @MainActor
  func testDocumentIntentFailureRetryAndExternalLandingPreserveConfirmedPage() async throws {
    let controller = IPadPageTurnController(), documentID = UUID()
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene)
    var actual = 0, request: DocumentPageNavigationRequest?, status: DocumentPageNavigationStatus?
    var readiness: [Int: PageTurnReadiness] = [:], landings: [DocumentPageLanding] = []
    var retries = 0
    func configure() {
      controller.update(ownerID: documentID, sequenceRevision: "document-source", pageCount: 20,
        selectedIndex: actual, navigationIsEnabled: true, pageIsInteractive: true,
        canBeginNavigation: { true }, page: { index, _, ready in
          readiness[index] = ready
          if index == 0 { ready(true) }
          return AnyView(Text("Page \(index)"))
        }, onCommit: { _, _ in XCTFail("A document landing has its typed acknowledgment") },
        onTransitioningChange: { _ in }, canonicalDocumentLayout: .init(pageCount: 20, sourceRevision: "document-source"), documentSelection: request,
        documentNavigation: .init(bind: { _, _, _ in }, unbind: { _ in }, landed: { receipt in
          landings.append(receipt); actual = receipt.pageIndex
          if request?.id == receipt.requestID { request = nil }
          configure()
        }, status: { status = $0 }))
    }
    configure(); window.rootViewController = controller; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    let original = try XCTUnwrap(controller.visiblePageIdentity)
    request = .init(id: UUID(), documentID: documentID, sourceRevision: "document-source", pageIndex: 7)
    configure()
    let ready = try XCTUnwrap(readiness[7])
    XCTAssertEqual(ready.activity?.preparationDemand?.presentation, .live,
      "A distant document request does not require the page-curl snapshot path")
    ready.failed(.init(kind: .snapshotPending, message: "The requested capture is temporarily unavailable") { retries += 1 })
    let failedDeadline = ContinuousClock.now + .seconds(2)
    while status?.phase != .failed, ContinuousClock.now < failedDeadline { await Task.yield() }
    XCTAssertEqual(actual, 0)
    XCTAssertEqual(controller.displayedIndex, 0)
    XCTAssertEqual(controller.visiblePageIdentity, original)
    XCTAssertEqual(status?.target, 7)
    XCTAssertEqual(status?.phase, .failed)
    XCTAssertEqual(status?.failure?.kind, .snapshotPending)
    let staleRetry = try XCTUnwrap(status?.failure).retry
    staleRetry()
    XCTAssertEqual(retries, 1)
    ready(true)
    let landingDeadline = ContinuousClock.now + .seconds(2)
    while actual != 7, ContinuousClock.now < landingDeadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertEqual(actual, 7)
    XCTAssertNil(request)
    XCTAssertEqual(landings.filter { $0.pageIndex == 7 }.count, 1)
    staleRetry()
    XCTAssertEqual(retries, 1, "A retired failure cannot restart old preparation")
  }

  @MainActor
  func testDocumentLandingAIsAcknowledgedWhileNewerIntentBStillWaits() async throws {
    let controller = IPadPageTurnController(), documentID = UUID()
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene)
    var actual = 0, request: DocumentPageNavigationRequest?
    var readiness: [Int: PageTurnReadiness] = [:], landings: [DocumentPageLanding] = []
    func configure() {
      controller.update(ownerID: documentID, sequenceRevision: "document-source", pageCount: 20,
        selectedIndex: actual, navigationIsEnabled: true, pageIsInteractive: true, canBeginNavigation: { true },
        page: { index, _, ready in
          readiness[index] = ready
          if index == 0 { ready(true) }
          return AnyView(Text("Page \(index)"))
        }, onCommit: { _, _ in XCTFail("Typed document route required") }, onTransitioningChange: { _ in },
        canonicalDocumentLayout: .init(pageCount: 20, sourceRevision: "document-source"),
        documentSelection: request, documentNavigation: .init(bind: { _, _, _ in }, unbind: { _ in },
          landed: { receipt in
            landings.append(receipt); actual = receipt.pageIndex
            if request?.id == receipt.requestID { request = nil }
            configure()
          }, status: { _ in }))
    }
    configure(); window.rootViewController = controller; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    let first = DocumentPageNavigationRequest(id: UUID(), documentID: documentID, sourceRevision: "document-source", pageIndex: 7)
    let second = DocumentPageNavigationRequest(id: UUID(), documentID: documentID, sourceRevision: "document-source", pageIndex: 12)
    request = first; configure(); try XCTUnwrap(readiness[7])(true)
    request = second; configure()
    let firstDeadline = ContinuousClock.now + .seconds(2)
    while actual != 7, ContinuousClock.now < firstDeadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertEqual(actual, 7, "Already completed A is a fact even while B waits")
    XCTAssertEqual(request?.id, second.id)
    XCTAssertEqual(landings.first { $0.pageIndex == 7 }?.requestID, first.id)
    try XCTUnwrap(readiness[12])(true)
    let secondDeadline = ContinuousClock.now + .seconds(2)
    while actual != 12, ContinuousClock.now < secondDeadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertEqual(actual, 12)
    XCTAssertNil(request)
    XCTAssertEqual(landings.filter { $0.pageIndex == 7 || $0.pageIndex == 12 }.map(\.pageIndex), [7, 12])
  }

  @MainActor
  func testEarlyDocumentTargetWaitsForItsCanonicalSourceThenLandsWithinItsRealCount() async throws {
    let controller = IPadPageTurnController(), documentID = UUID()
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene)
    var actual = 0
    var layout: DocumentPageLayout?
    var request: DocumentPageNavigationRequest? = .init(id: UUID(), documentID: documentID,
      sourceRevision: "current-source", pageIndex: 50)
    var readiness: [Int: PageTurnReadiness] = [:], landings: [DocumentPageLanding] = []
    var status: DocumentPageNavigationStatus?
    func configure() {
      controller.update(ownerID: documentID, sequenceRevision: "current-source",
        pageCount: layout?.pageCount(for: "current-source") ?? 1, selectedIndex: actual,
        navigationIsEnabled: true, pageIsInteractive: true, canBeginNavigation: { true },
        page: { index, _, ready in
          readiness[index] = ready
          if index == 0 { ready(true) }
          return AnyView(Text("Page \(index)"))
        }, onCommit: { _, _ in XCTFail("Typed document route required") }, onTransitioningChange: { _ in },
        canonicalDocumentLayout: layout, documentSelection: request,
        documentNavigation: .init(bind: { _, _, _ in }, unbind: { _ in }, landed: { receipt in
          landings.append(receipt); actual = receipt.pageIndex
          if request?.id == receipt.requestID { request = nil }
          configure()
        }, status: { status = $0 }))
    }
    configure(); window.rootViewController = controller; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    let requestedID = try XCTUnwrap(request).id
    await Task.yield()
    XCTAssertEqual(actual, 0)
    XCTAssertEqual(request?.id, requestedID)
    XCTAssertNil(readiness[0]?.activity?.preparationDemand)
    XCTAssertNil(readiness[50], "An unknown count cannot allocate a speculative addressed page")
    layout = .init(pageCount: 60, sourceRevision: "retired-source"); configure()
    XCTAssertNil(readiness[0]?.activity?.preparationDemand)
    XCTAssertNil(readiness[50], "An older source count cannot validate the current request")
    layout = .init(pageCount: 3, sourceRevision: "current-source"); configure()
    let resolvedReadiness = try XCTUnwrap(readiness[2])
    XCTAssertEqual(readiness[0]?.activity?.preparationDemand?.pageIndex, 2)
    XCTAssertEqual(actual, 0, "Clamping a request is not a landing")
    XCTAssertEqual(request?.id, requestedID)
    resolvedReadiness(true)
    let deadline = ContinuousClock.now + .seconds(2)
    while actual != 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertEqual(actual, 2)
    XCTAssertNil(request)
    XCTAssertEqual(landings.last?.requestID, requestedID)
    XCTAssertTrue(landings.allSatisfy { $0.pageIndex == 0 || $0.pageIndex == 2 })
    let statusDeadline = ContinuousClock.now + .seconds(2)
    while status?.target != nil, ContinuousClock.now < statusDeadline { await Task.yield() }
    XCTAssertNil(status?.target, "The out-of-range request cannot leave a permanent preparing state")
  }

  @MainActor
  func testReorderedSequenceRevokesPreparedHostsAndRejectsTheirLateLanding() throws {
    let controller = IPadPageTurnController(), owner = UUID()
    var readiness: [String: [Int: PageTurnReadiness]] = [:]
    var commits: [(Int, String)] = []
    func configure(_ root: String) {
      controller.update(ownerID: owner, sequenceRevision: root, pageCount: 6, selectedIndex: 0,
        navigationIsEnabled: true, pageIsInteractive: true, canBeginNavigation: { true },
        page: { index, _, ready in
          readiness[root, default: [:]][index] = ready
          if root == "before" || index == 0 { ready(true) }
          return AnyView(Text("\(root):\(index)"))
        }, onCommit: { commits.append(($0, $1)) }, onTransitioningChange: { _ in })
    }
    configure("before"); controller.loadViewIfNeeded()
    let oldSource = try XCTUnwrap(controller.sheetController.page)
    let oldTarget = try XCTUnwrap(controller.sheetController(controller.sheetController, after: oldSource))
    let oldReady = try XCTUnwrap(readiness["before"]?[1])
    controller.sheetController(controller.sheetController, willTurnTo: oldTarget)
    configure("after")
    let current = try XCTUnwrap(controller.sheetController.page)
    XCTAssertFalse(current === oldSource)
    XCTAssertNil(oldTarget.parent, "A discarded sequence retains no mounted content")
    oldReady(true)
    XCTAssertNil(controller.sheetController(controller.sheetController, after: current))
    controller.sheetController(controller.sheetController, didTurnFrom: oldSource, completed: true)
    XCTAssertTrue(commits.isEmpty, "A late curl cannot reinterpret its slot in the replacement order")
    XCTAssertEqual(controller.displayedIndex, 0)
    try XCTUnwrap(readiness["after"]?[1])(true)
    XCTAssertNil(controller.sheetController(controller.sheetController, after: oldSource))
    XCTAssertNil(controller.sheetController(controller.sheetController, before: oldTarget))
    let target = try XCTUnwrap(controller.sheetController(controller.sheetController, after: current))
    controller.sheetController(controller.sheetController, willTurnTo: target)
    controller.sheetController.show(target, direction: .forward, animated: false)
    controller.sheetController(controller.sheetController, didTurnFrom: current, completed: true)
    XCTAssertEqual(commits.map(\.0), [1])
    XCTAssertEqual(commits.map(\.1), ["after"])
    XCTAssertLessThanOrEqual(controller.cachedPageIdentities.count, 4)
  }

  @MainActor
  func testColdFirstPageDoesNotManufactureDistantChildrenToFillFourSlots() throws {
    let controller = IPadPageTurnController()
    var built = Set<Int>()
    controller.update(ownerID: UUID(), sequenceRevision: "cold-order", pageCount: 4, selectedIndex: 0,
      navigationIsEnabled: true, pageIsInteractive: true, canBeginNavigation: { true },
      page: { index, _, ready in
        built.insert(index); ready(true); return AnyView(Text("Page \(index)"))
      }, onCommit: { _, _ in }, onTransitioningChange: { _ in })
    controller.loadViewIfNeeded()
    XCTAssertEqual(built, [0, 1], "Spare capacity is not a demand to construct two more pages")
    XCTAssertEqual(Set(controller.cachedPageIdentities.keys), [0, 1])
    let first = try XCTUnwrap(controller.sheetController.page)
    XCTAssertNotNil(controller.sheetController(controller.sheetController, after: first),
      "The immediately reachable sheet must still be ready for a real curl")
  }

  @MainActor
  func testColdStepPreparesItsPixelsBeforeMountingNewSpeculation() throws {
    let controller = IPadPageTurnController(), owner = UUID(), commands = NotebookPageNavigation()
    var callbacks: [Int: PageTurnReadiness] = [:]
    controller.update(ownerID: owner, sequenceRevision: "cold-priority", pageCount: 6, selectedIndex: 0,
      navigationIsEnabled: true, pageIsInteractive: true, canBeginNavigation: { true },
      page: { index, _, ready in
        callbacks[index] = ready; ready(index == 0); return AnyView(Text("Page \(index)"))
      }, onCommit: { _, _ in }, onTransitioningChange: { _ in }, notebookNavigation: commands)
    controller.loadViewIfNeeded()
    XCTAssertTrue(commands.send(.step(1), ownerID: owner, source: "cold-priority"))
    XCTAssertEqual(Set(controller.cachedPageIdentities.keys), [0, 1],
      "Spare hosts must not start layout while the requested first frame is still cold")
    try XCTUnwrap(callbacks[1])(true)
    XCTAssertNotNil(controller.cachedPageIdentities[2], "Once the target has pixels, resume the ordinary neighbour window")
    XCTAssertLessThanOrEqual(controller.cachedPageIdentities.count, 4)
  }

  func testFinitePrewarmWindowRetainsExistingNearestPagesWithinFourSlots() {
    for count in 1...8 {
      for current in 0..<count {
        for direction in [-1, 1] {
          let window = PageTurnPrewarmWindow.indices(displayedIndex: current,
            anticipatedIndex: nil, lastDirection: direction, pageCount: count, existingIndices: Set(0..<count))
          XCTAssertEqual(window.count, min(count, 4))
          XCTAssertTrue(window.contains(current))
          for neighbor in [current - 1, current + 1, current + direction * 2]
            where (0..<count).contains(neighbor) {
            XCTAssertTrue(window.contains(neighbor))
          }
          if count <= 4 { XCTAssertEqual(window, Set(0..<count)) }
        }
      }
    }
    XCTAssertEqual(PageTurnPrewarmWindow.indices(displayedIndex: 2,
      anticipatedIndex: 7, lastDirection: nil, pageCount: 10, existingIndices: []), Set([1, 2, 7, 8]),
      "A distant handoff keeps the source, landing and next sheet without a fifth speculative host")
    XCTAssertEqual(PageTurnPrewarmWindow.indices(displayedIndex: 7,
      anticipatedIndex: 2, lastDirection: nil, pageCount: 10, existingIndices: []), Set([1, 2, 6, 7]))
  }

  @MainActor
  func testRapidStepsPrepareTheLatestLeafWithoutReplacingEitherMovingHost() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
    let controller = IPadPageTurnController(), commands = NotebookPageNavigation(), notebook = UUID()
    controller.update(ownerID: notebook, sequenceRevision: "burst-window", pageCount: 10, selectedIndex: 0,
      navigationIsEnabled: true, pageIsInteractive: true, canBeginNavigation: { true },
      page: { index, _, ready in ready(true); return AnyView(Color.white.overlay(Text("Leaf \(index)"))) },
      onCommit: { _, _ in }, onTransitioningChange: { _ in }, notebookNavigation: commands)
    window.rootViewController = controller; window.makeKeyAndVisible()
    defer { controller.sheetController.cancelMotion(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    try await Task.sleep(for: .milliseconds(60))
    XCTAssertTrue(commands.send(.step(1), ownerID: notebook, source: "burst-window"))
    let original = controller.cachedPageIdentities
    for target in 2...7 {
      XCTAssertTrue(commands.send(.step(1), ownerID: notebook, source: "burst-window"))
      XCTAssertEqual(controller.displayedIndex, 0, "The actual first landing is still pending")
      XCTAssertEqual(controller.cachedPageIdentities[0], original[0])
      XCTAssertEqual(controller.cachedPageIdentities[1], original[1])
      XCTAssertNotNil(controller.cachedPageIdentities[target], "Preparation must overlap the preceding curl")
      XCTAssertLessThanOrEqual(controller.cachedPageIdentities.count, 4)
    }
    let deadline = ContinuousClock.now + .seconds(2)
    while controller.displayedIndex != 7, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
    XCTAssertEqual(controller.displayedIndex, 7)
  }

  @MainActor
  func testDistantRequestsDuringCurlKeepFourContentsAndOnlyTheLatestTargetSurvivesTheLocalAcknowledgement() async throws {
    let controller = IPadPageTurnController(), owner = UUID(), commands = NotebookPageNavigation()
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene)
    var commits: [Int] = [], rendered = Set<Int>()
    func configure(_ selected: Int) {
      controller.update(ownerID: owner, sequenceRevision: "fixture-order", pageCount: 20, selectedIndex: selected,
        navigationIsEnabled: true, pageIsInteractive: true, canBeginNavigation: { true },
        page: { index, _, ready in
          XCTAssertLessThanOrEqual(controller.cachedPageIdentities.count, 4,
            "The limit applies while a new child is being created, not just after reconciliation")
          rendered.insert(index); ready(true)
          return AnyView(Text("Page \(index)"))
        }, onCommit: { index, _ in commits.append(index) }, onTransitioningChange: { _ in }, notebookNavigation: commands)
    }
    configure(4); window.rootViewController = controller; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    let source = try XCTUnwrap(controller.sheetController.page)
    let landing = try XCTUnwrap(controller.sheetController(controller.sheetController, after: source))
    let preparedChild = landing.view
    controller.sheetController(controller.sheetController, willTurnTo: landing)
    let frozenWindow = controller.cachedPageIdentities
    for target in [12, 17, 9] {
      XCTAssertTrue(commands.send(.jump(target), ownerID: owner, source: "fixture-order"))
      XCTAssertEqual(controller.cachedPageIdentities, frozenWindow,
        "An external request cannot add or replace a child under an active curl")
      XCTAssertFalse(rendered.contains(target))
      XCTAssertFalse(source.view.isUserInteractionEnabled)
    }
    controller.sheetController.show(landing, direction: .forward, animated: false)
    controller.sheetController(controller.sheetController, didTurnFrom: source, completed: true)
    XCTAssertEqual(controller.displayedIndex, 5)
    XCTAssertTrue(landing.view === preparedChild, "The hand lands on its original prepared child")
    XCTAssertEqual(commits, [5], "The native landing still owns its normal selection publication")
    let targetIdentity = try XCTUnwrap(controller.cachedPageIdentities[9])
    XCTAssertNil(controller.cachedPageIdentities[12]); XCTAssertNil(controller.cachedPageIdentities[17])
    configure(5) // The ordered native writer acknowledges the intermediate landing.
    let deadline = ContinuousClock.now + .seconds(2)
    while controller.displayedIndex != 9, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(controller.displayedIndex, 9)
    XCTAssertEqual(controller.visiblePageIdentity, targetIdentity)
    XCTAssertEqual(commits, [5, 9], "The delayed external target must not be replaced by the local acknowledgement")
    configure(9)
    XCTAssertEqual(controller.displayedIndex, 9)
    XCTAssertLessThanOrEqual(controller.cachedPageIdentities.count, 4)
    XCTAssertFalse(rendered.contains(12)); XCTAssertFalse(rendered.contains(17))
  }

  @MainActor
  func testReturningExternalSelectionToTheSourceCancelsTheQueuedJumpWithoutReplacingCurlChildren() async throws {
    let controller = IPadPageTurnController(), owner = UUID(), commands = NotebookPageNavigation()
    var rendered = Set<Int>(), commits: [Int] = []
    var activity: PageTurnActivity?
    func configure(_ selected: Int) {
      controller.update(ownerID: owner, sequenceRevision: "fixture-order", pageCount: 20, selectedIndex: selected,
        navigationIsEnabled: true, pageIsInteractive: true, canBeginNavigation: { true },
        page: { index, _, ready in
          XCTAssertLessThanOrEqual(controller.cachedPageIdentities.count, 4)
          activity = ready.activity
          rendered.insert(index); ready(true); return AnyView(Text("Page \(index)"))
        }, onCommit: { index, _ in commits.append(index) }, onTransitioningChange: { _ in }, notebookNavigation: commands)
    }
    configure(0); controller.loadViewIfNeeded()
    let source = try XCTUnwrap(controller.sheetController.page)
    let sourceChild = source.view
    let landing = try XCTUnwrap(controller.sheetController(controller.sheetController, after: source))
    let landingChild = landing.view
    controller.sheetController(controller.sheetController, willTurnTo: landing)
    let frozenWindow = controller.cachedPageIdentities
    for target in [7, 12, 0] {
      XCTAssertTrue(commands.send(.jump(target), ownerID: owner, source: "fixture-order"))
      XCTAssertEqual(activity?.preparationDemand?.pageIndex, target == 0 ? nil : target)
      XCTAssertEqual(controller.cachedPageIdentities, frozenWindow)
    }
    controller.sheetController(controller.sheetController, didTurnFrom: source, completed: false)
    XCTAssertEqual(controller.displayedIndex, 0)
    XCTAssertNil(activity?.preparationDemand)
    XCTAssertTrue(source.view === sourceChild)
    XCTAssertTrue(source.view.isUserInteractionEnabled)
    XCTAssertTrue(commits.isEmpty)
    XCTAssertFalse(rendered.contains(7)); XCTAssertFalse(rendered.contains(12))
    let next = try XCTUnwrap(controller.sheetController(controller.sheetController, after: source))
    XCTAssertTrue(next === landing); XCTAssertTrue(next.view === landingChild)
    controller.sheetController(controller.sheetController, willTurnTo: next)
    controller.sheetController.show(next, direction: .forward, animated: false)
    controller.sheetController(controller.sheetController, didTurnFrom: source, completed: true)
    configure(1)
    XCTAssertEqual(controller.displayedIndex, 1, "The next ordinary turn cannot replay the cancelled external jump")
    XCTAssertEqual(commits, [1])
  }

  @MainActor
  func testAnUnpreparedExternalTargetReleasesThePreviousWindowBeforeCreatingItsReplacement() async throws {
    let controller = IPadPageTurnController(), owner = UUID(), commands = NotebookPageNavigation()
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene)
    var readiness: [Int: PageTurnReadiness] = [:], commits: [Int] = []
    func configure(_ selected: Int) {
      controller.update(ownerID: owner, sequenceRevision: "fixture-order", pageCount: 20, selectedIndex: selected,
        navigationIsEnabled: true, pageIsInteractive: true, canBeginNavigation: { true },
        page: { index, _, ready in
          XCTAssertLessThanOrEqual(controller.cachedPageIdentities.count, 4)
          if index >= 8 { XCTAssertNil(controller.cachedPageIdentities[2]) }
          readiness[index] = ready
          if index < 8 { ready(true) }
          return AnyView(Text("Page \(index)"))
        }, onCommit: { index, _ in commits.append(index) }, onTransitioningChange: { _ in }, notebookNavigation: commands)
    }
    configure(4); window.rootViewController = controller; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    XCTAssertTrue(commands.send(.jump(12), ownerID: owner, source: "fixture-order"))
    let expired = try XCTUnwrap(readiness[12])
    let activity = try XCTUnwrap(expired.activity)
    let firstDemand = try XCTUnwrap(activity.preparationDemand)
    XCTAssertEqual(firstDemand.pageIndex, 12)
    configure(4)
    XCTAssertEqual(activity.preparationDemand?.id, firstDemand.id, "A repeated model update must not restart accepted preparation")
    XCTAssertTrue(commands.send(.jump(17), ownerID: owner, source: "fixture-order"))
    let secondDemand = try XCTUnwrap(activity.preparationDemand)
    XCTAssertEqual(secondDemand.pageIndex, 17)
    XCTAssertNotEqual(secondDemand.id, firstDemand.id)
    XCTAssertNil(controller.cachedPageIdentities[12]); XCTAssertNil(controller.cachedPageIdentities[13])
    XCTAssertTrue(commands.send(.jump(9), ownerID: owner, source: "fixture-order"))
    XCTAssertNil(controller.cachedPageIdentities[17]); XCTAssertNil(controller.cachedPageIdentities[18])
    expired(true)
    XCTAssertEqual(controller.displayedIndex, 4, "A retired target cannot satisfy the latest target's readiness")
    let targetIdentity = try XCTUnwrap(controller.cachedPageIdentities[9])
    try XCTUnwrap(readiness[9])(true)
    let deadline = ContinuousClock.now + .seconds(2)
    while controller.displayedIndex != 9, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(controller.displayedIndex, 9)
    XCTAssertEqual(controller.visiblePageIdentity, targetIdentity)
    XCTAssertEqual(commits, [9], "Only the actual landing publishes selection")
    XCTAssertLessThanOrEqual(controller.cachedPageIdentities.count, 4)
    XCTAssertNil(activity.preparationDemand, "The native landing retires its demand")
  }

  @MainActor
  func testExternalTransitionsKeepTheirOwnFourContentsWhileNewerRequestsWait() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene), controller = IPadPageTurnController(), owner = UUID(), commands = NotebookPageNavigation()
    let previous = scene.windows.first(where: \.isKeyWindow)
    window.frame = scene.effectiveGeometry.coordinateSpace.bounds
    var rendered = Set<Int>()
    func configure(_ selected: Int) {
      controller.update(ownerID: owner, sequenceRevision: "fixture-order", pageCount: 20, selectedIndex: selected,
        navigationIsEnabled: true, pageIsInteractive: true, canBeginNavigation: { true },
        page: { index, _, ready in
          XCTAssertLessThanOrEqual(controller.cachedPageIdentities.count, 4)
          rendered.insert(index); ready(true); return AnyView(Text("Page \(index)"))
        }, onCommit: { _, _ in }, onTransitioningChange: { _ in }, notebookNavigation: commands)
    }
    configure(4); window.rootViewController = controller; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    window.layoutIfNeeded()
    try await Task.sleep(for: .milliseconds(32))
    // Adjacent pages curl; distant navigation deliberately installs directly
    // without a second crossfade over an already prepared destination.
    XCTAssertTrue(commands.send(.jump(5), ownerID: owner, source: "fixture-order"))
    XCTAssertEqual(controller.displayedIndex, 4, "This assertion samples the active external animation, before its completion")
    let frozenWindow = controller.cachedPageIdentities
    XCTAssertTrue(commands.send(.jump(17), ownerID: owner, source: "fixture-order")); XCTAssertEqual(controller.cachedPageIdentities, frozenWindow)
    XCTAssertTrue(commands.send(.jump(9), ownerID: owner, source: "fixture-order")); XCTAssertEqual(controller.cachedPageIdentities, frozenWindow)
    XCTAssertFalse(rendered.contains(17)); XCTAssertFalse(rendered.contains(9))
    let deadline = ContinuousClock.now + .seconds(2)
    while controller.displayedIndex != 9, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(controller.displayedIndex, 9)
    XCTAssertFalse(rendered.contains(17))
    XCTAssertLessThanOrEqual(controller.cachedPageIdentities.count, 4)
  }

  @MainActor
  func testQueuedExternalSelectionPreservesTrailingBlankCreationBeforeItsFinalSelection() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene), controller = IPadPageTurnController(), owner = UUID(), commands = NotebookPageNavigation()
    var reportedPageCount = 5, commits: [Int] = [], rendered = Set<Int>()
    func configure(_ selected: Int) {
      controller.update(ownerID: owner, sequenceRevision: "fixture-order", pageCount: reportedPageCount, selectedIndex: selected,
        allowsTrailingPageCreation: true, navigationIsEnabled: true, pageIsInteractive: true,
        canBeginNavigation: { true }, page: { index, _, ready in
          XCTAssertLessThanOrEqual(controller.cachedPageIdentities.count, 4)
          rendered.insert(index); ready(true); return AnyView(Text("Page \(index)"))
        }, onCommit: { target, _ in
          commits.append(target)
          if target == reportedPageCount - 1 { reportedPageCount += 1 }
        }, onTransitioningChange: { _ in }, notebookNavigation: commands)
    }
    configure(3); window.rootViewController = controller; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    let source = try XCTUnwrap(controller.sheetController.page)
    let blank = try XCTUnwrap(controller.sheetController(controller.sheetController, after: source))
    controller.sheetController(controller.sheetController, willTurnTo: blank)
    let frozenWindow = controller.cachedPageIdentities
    XCTAssertTrue(commands.send(.jump(0), ownerID: owner, source: "fixture-order"))
    XCTAssertEqual(controller.cachedPageIdentities, frozenWindow)
    controller.sheetController.show(blank, direction: .forward, animated: false)
    controller.sheetController(controller.sheetController, didTurnFrom: source, completed: true)
    XCTAssertEqual(commits, [4])
    XCTAssertEqual(reportedPageCount, 6, "Landing still creates exactly one notebook page")
    XCTAssertTrue(rendered.contains(5), "The next trailing blank is prepared before a later SwiftUI update")
    configure(4)
    let deadline = ContinuousClock.now + .seconds(2)
    while controller.displayedIndex != 0, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(controller.displayedIndex, 0)
    XCTAssertEqual(commits, [4, 0])
    XCTAssertEqual(reportedPageCount, 6)
    configure(0)
    XCTAssertEqual(controller.displayedIndex, 0)
    XCTAssertLessThanOrEqual(controller.cachedPageIdentities.count, 4)
  }

  @MainActor
  func testFiniteThreePageDocumentKeepsTheSameChildThroughAnImmediateReverse() throws {
    let controller = IPadPageTurnController(), owner = UUID()
    var committed = 0
    func configure() {
      controller.update(ownerID: owner, sequenceRevision: "fixture-order", pageCount: 3, selectedIndex: committed,
        navigationIsEnabled: true, pageIsInteractive: true, canBeginNavigation: { true },
        page: { index, _, ready in ready(true); return AnyView(Text("Page \(index)")) },
        onCommit: { index, _ in committed = index }, onTransitioningChange: { _ in })
    }
    configure(); controller.loadViewIfNeeded()
    let firstHost = try XCTUnwrap(controller.sheetController.page)
    let firstChild = firstHost.view
    for expected in [1, 2, 1, 0] {
      let previous = try XCTUnwrap(controller.sheetController.page)
      let forward = expected > controller.displayedIndex
      let target = try XCTUnwrap(forward
        ? controller.sheetController(controller.sheetController, after: previous)
        : controller.sheetController(controller.sheetController, before: previous))
      controller.sheetController(controller.sheetController, willTurnTo: target)
      controller.sheetController.show(target, direction: forward ? .forward : .reverse, animated: false)
      controller.sheetController(controller.sheetController, didTurnFrom: previous, completed: true)
      configure()
      XCTAssertEqual(controller.displayedIndex, expected)
      XCTAssertEqual(Set(controller.cachedPageIdentities.keys), Set([0, 1, 2]))
      XCTAssertTrue(firstHost.parent === controller.sheetController && firstHost.view === firstChild,
        "The original resident host stays mounted through every direction")
    }
    XCTAssertTrue(controller.sheetController.page === firstHost)
    XCTAssertTrue(firstHost.view === firstChild, "Reverse installs the exact original content, not a replacement")
  }

  @MainActor
  func testRapidNotebookLandingsAdvanceMemoryBeforePersistenceCatchesUp()
    async throws
  {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = NotebookStore(root: root)
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let notebookID = try XCTUnwrap(model.workspace?.selectedItemID)

    XCTAssertEqual(
      model.selectNotebookPage(1, notebookID: notebookID, expectedRoot: model.notebookPageRoot(notebookID) ?? ""),
      1
    )
    XCTAssertEqual(
      model.selectNotebookPage(2, notebookID: notebookID, expectedRoot: model.notebookPageRoot(notebookID) ?? ""),
      2
    )
    XCTAssertEqual(model.workspace?.selectedPageID.flatMap { model.notebookPageIndex($0, in: notebookID) }, 2)
    XCTAssertEqual(model.workspace?.selectedItem.pageIDs.count, 3)

    var persistedIndex: WorkspaceIndex?
    for _ in 0..<100 {
      if let candidate = try? store.loadIndex(),
        candidate.selectedPageIndex == 2
      {
        persistedIndex = candidate
        break
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    let persisted = try XCTUnwrap(persistedIndex)
    let selectedPageID = try XCTUnwrap(persisted.selectedPageID)
    XCTAssertEqual(try store.loadPage(selectedPageID).id, selectedPageID)
  }

  @MainActor
  func testEvictedSheetGetsANewHostAndRejectsOldReadiness() throws {
    let controller = IPadPageTurnController(), owner = UUID()
    var committed = 0
    var preparesImmediately = true
    var readiness: [Int: [PageTurnReadiness]] = [:]
    func configure() {
      controller.update(ownerID: owner, sequenceRevision: "fixture-order", pageCount: 6, selectedIndex: committed,
        navigationIsEnabled: true, pageIsInteractive: true, canBeginNavigation: { true },
        page: { index, _, ready in
          readiness[index, default: []].append(ready)
          if preparesImmediately { ready(true) }
          return AnyView(Text("Physical page \(index)"))
        }, onCommit: { index, _ in committed = index }, onTransitioningChange: { _ in })
    }
    func turn(forward: Bool) throws {
      let current = try XCTUnwrap(controller.sheetController.page)
      let next = try XCTUnwrap(forward
        ? controller.sheetController(controller.sheetController, after: current)
        : controller.sheetController(controller.sheetController, before: current))
      controller.sheetController(controller.sheetController, willTurnTo: next)
      controller.sheetController.show(next, direction: forward ? .forward : .reverse, animated: false)
      controller.sheetController(controller.sheetController, didTurnFrom: current, completed: true)
      configure()
    }
    configure(); controller.loadViewIfNeeded()
    let original = try XCTUnwrap(controller.sheetController.page)
    let expiredReadiness = try XCTUnwrap(readiness[0]?.last)
    try turn(forward: true)
    try turn(forward: true)
    XCTAssertEqual(controller.displayedIndex, 2)
    XCTAssertNil(controller.cachedPageIdentities[0], "The far page must release live content even while a test retains the retired controller")

    preparesImmediately = false
    try turn(forward: false)
    XCTAssertEqual(controller.displayedIndex, 1)
    XCTAssertNotEqual(controller.cachedPageIdentities[0], ObjectIdentifier(original))
    XCTAssertNil(original.parent, "Evicted content must not remain mounted")
    let current = try XCTUnwrap(controller.sheetController.page)
    XCTAssertNil(controller.sheetController(controller.sheetController, before: current))
    expiredReadiness(true)
    XCTAssertNil(controller.sheetController(controller.sheetController, before: current),
      "Readiness from the retired content cannot certify the replacement page")
    try XCTUnwrap(readiness[0]?.last)(true)
    expiredReadiness(false)
    let restored = try XCTUnwrap(controller.sheetController(controller.sheetController, before: current))
    XCTAssertFalse(restored === original, "A retired host cannot be resurrected with stale readiness")
  }

  @MainActor
  func testEvictedSheetPreparesItsReplacementInTheWindowBeforeReturning() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene)
    let controller = IPadPageTurnController(), owner = UUID()
    window.rootViewController = controller
    var committed = 0
    var preparedChildren: [Int: [UUID]] = [:]
    func configure() {
      controller.update(ownerID: owner, sequenceRevision: "fixture-order", pageCount: 6, selectedIndex: committed,
        navigationIsEnabled: true, pageIsInteractive: true, canBeginNavigation: { true },
        page: { index, _, readiness in
          AnyView(WindowPreparedPage(readiness: readiness, onFirstFrame: { identity in
            preparedChildren[index, default: []].append(identity)
          }))
        }, onCommit: { index, _ in committed = index }, onTransitioningChange: { _ in })
    }
    func turn(forward: Bool) async throws {
      let current = try XCTUnwrap(controller.sheetController.page)
      var next: UIViewController?
      let deadline = ContinuousClock.now + .seconds(3)
      repeat {
        next = forward
          ? controller.sheetController(controller.sheetController, after: current)
          : controller.sheetController(controller.sheetController, before: current)
        if next == nil { try await Task.sleep(for: .milliseconds(10)) }
      } while next == nil && ContinuousClock.now < deadline
      let destination = try XCTUnwrap(next, "A restored child must reach the real prewarm window without displaying its retired shell first")
      controller.sheetController(controller.sheetController, willTurnTo: destination)
      controller.sheetController.show(destination, direction: forward ? .forward : .reverse, animated: false)
      controller.sheetController(controller.sheetController, didTurnFrom: current, completed: true)
      configure()
      XCTAssertLessThanOrEqual(controller.cachedPageIdentities.count, 4)
    }
    configure(); window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    let originalHost = try XCTUnwrap(controller.sheetController.page)
    try await turn(forward: true)
    let originalChild = try XCTUnwrap(preparedChildren[0]?.first)
    try await turn(forward: true)
    XCTAssertNil(controller.cachedPageIdentities[0])
    try await turn(forward: false)
    XCTAssertFalse(originalHost.parent === controller,
      "Only the newly prepared child, never the retired host, belongs to prewarm containment")
    try await turn(forward: false)
    XCTAssertEqual(controller.displayedIndex, 0)
    XCTAssertFalse(controller.sheetController.page === originalHost)
    XCTAssertEqual(preparedChildren[0]?.count, 2)
    XCTAssertNotEqual(preparedChildren[0]?.last, originalChild,
      "The far content was released, and its replacement earned readiness from its own mounted view")
  }

  @MainActor
  func testExternalPageSelectionPublishesTransitionOutsideTheRepresentableUpdate() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene), controller = IPadPageTurnController(), owner = UUID(), commands = NotebookPageNavigation()
    var insideUpdate = false, preparesTarget = false
    var reported: [Bool] = []
    func update(selected: Int) {
      insideUpdate = true
      controller.update(ownerID: owner, sequenceRevision: "fixture-order", pageCount: 3, selectedIndex: selected,
        navigationIsEnabled: true, pageIsInteractive: true, canBeginNavigation: { true },
        page: { index, _, ready in if index == 0 || preparesTarget { ready(true) }; return AnyView(Text("Page \(index)")) },
        onCommit: { _, _ in }, onTransitioningChange: { active in
          XCTAssertFalse(insideUpdate, "SwiftUI state must not be published inside updateUIViewController")
          reported.append(active)
        }, notebookNavigation: commands)
      insideUpdate = false
    }
    update(selected: 0)
    window.rootViewController = controller; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    try await Task.sleep(for: .milliseconds(20))
    reported.removeAll()
    let previous = try XCTUnwrap(controller.sheetController.page)
    XCTAssertTrue(commands.send(.jump(1), ownerID: owner, source: "fixture-order"))
    preparesTarget = true
    update(selected: 0)
    XCTAssertTrue(reported.isEmpty)
    XCTAssertFalse(previous.view.isUserInteractionEnabled, "The page under the hand stops accepting content input immediately")
    let deadline = ContinuousClock.now + .seconds(2)
    while (!reported.contains(true) || reported.last != false), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(reported, [true, false])
    XCTAssertEqual(controller.displayedIndex, 1)
  }

  @MainActor
  func testTransitionNotificationDropsOldStartAfterFinishAndOwnerReplacement() async throws {
    let controller = IPadPageTurnController(), firstOwner = UUID(), secondOwner = UUID()
    var reported: [(UUID, Bool)] = []
    var activity: PageTurnActivity?
    func update(owner: UUID) {
      controller.update(ownerID: owner, sequenceRevision: "fixture-order", pageCount: 3, selectedIndex: 0,
        navigationIsEnabled: true, pageIsInteractive: true, canBeginNavigation: { true },
        page: { index, _, ready in activity = ready.activity; ready(true); return AnyView(Text("Page \(index)")) },
        onCommit: { _, _ in }, onTransitioningChange: { reported.append((owner, $0)) })
    }
    update(owner: firstOwner); controller.loadViewIfNeeded()
    try await Task.sleep(for: .milliseconds(20))
    reported.removeAll()
    let current = try XCTUnwrap(controller.sheetController.page)
    let next = try XCTUnwrap(controller.sheetController(controller.sheetController, after: current))
    let nativeActivity = try XCTUnwrap(activity)
    var acceptedStates: [Bool] = []
    let observation = nativeActivity.observe { acceptedStates.append($0) }
    defer { nativeActivity.removeObserver(observation) }
    controller.sheetController(controller.sheetController, willTurnTo: next)
    XCTAssertTrue(nativeActivity.isTransitioning, "WebKit capture admission changes in the accepted native event")
    XCTAssertEqual(acceptedStates, [true], "A deferred SwiftUI publication cannot leave an unlocked interval")
    XCTAssertFalse(current.view.isUserInteractionEnabled)
    XCTAssertTrue(reported.isEmpty)
    controller.sheetController(controller.sheetController, didTurnFrom: current, completed: false)
    XCTAssertFalse(nativeActivity.isTransitioning)
    XCTAssertEqual(acceptedStates, [true, false])
    update(owner: secondOwner)
    XCTAssertTrue(reported.isEmpty)
    try await Task.sleep(for: .milliseconds(20))
    XCTAssertEqual(reported.map(\.0), [secondOwner])
    XCTAssertEqual(reported.map(\.1), [false], "A cancelled old start cannot disable the new owner's input later")
  }

  @MainActor
  func testShowCanResolveItsBlockAfterTheCameraCommandHasCompleted() async throws {
    let resolution = NotebookReferencePageResolution(), documentID = UUID(), requestID = UUID()
    var requestedReferenceID: UUID? = requestID
    var readyPage: Int?
    var selectedPage = 0
    resolution.start(requestID: requestID, documentID: documentID,
      isCurrent: { requestedReferenceID == nil || requestedReferenceID == requestID },
      resolve: { readyPage }, apply: { selectedPage = $0 })
    requestedReferenceID = nil // completeShow finishes the command, not the pending layout.
    try await Task.sleep(for: .milliseconds(140))
    XCTAssertEqual(resolution.requestID, requestID)
    XCTAssertEqual(resolution.documentID, documentID)
    readyPage = 2
    let deadline = ContinuousClock.now + .seconds(1)
    while resolution.requestID != nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(selectedPage, 2)
    XCTAssertNil(resolution.requestID)
    XCTAssertNil(resolution.documentID)
  }

  @MainActor
  func testBackInvalidatesPendingBlockResolutionBeforeReturningToTheReadPage() async throws {
    let resolution = NotebookReferencePageResolution()
    var readyPage: Int?
    var selectedPage = 0
    var appliedPages: [Int] = []
    resolution.start(requestID: UUID(), documentID: UUID(), isCurrent: { true },
      resolve: { readyPage }, apply: { selectedPage = $0; appliedPages.append($0) })
    try await Task.sleep(for: .milliseconds(80))
    resolution.cancel() // Back invalidates the old Show before its camera returns.
    selectedPage = 2
    readyPage = 0 // The old document finishes layout after Back.
    try await Task.sleep(for: .milliseconds(160))
    XCTAssertEqual(selectedPage, 2, "Late search layout cannot return the reader to page one")
    XCTAssertTrue(appliedPages.isEmpty)
    XCTAssertNil(resolution.requestID)
  }

  @MainActor
  func testNewShowOwnsResolutionEvenWhenTheCancelledTaskFinishesLater() async throws {
    let resolution = NotebookReferencePageResolution(), secondID = UUID(), secondDocumentID = UUID()
    var firstPage: Int?, secondPage: Int?
    var appliedPages: [Int] = []
    resolution.start(requestID: UUID(), documentID: UUID(), isCurrent: { true },
      resolve: { firstPage }, apply: { appliedPages.append($0) })
    resolution.start(requestID: secondID, documentID: secondDocumentID, isCurrent: { true },
      resolve: { secondPage }, apply: { appliedPages.append($0) })
    firstPage = 7
    try await Task.sleep(for: .milliseconds(140))
    XCTAssertTrue(appliedPages.isEmpty)
    XCTAssertEqual(resolution.requestID, secondID, "The cancelled task's cleanup cannot clear the new request")
    XCTAssertEqual(resolution.documentID, secondDocumentID)
    secondPage = 3
    let deadline = ContinuousClock.now + .seconds(1)
    while resolution.requestID != nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(appliedPages, [3])
    XCTAssertNil(resolution.requestID)
  }

  @MainActor
  func testHumanPageChangeInvalidatesLateBlockResolution() async throws {
    let resolution = NotebookReferencePageResolution()
    var selectedPage = 0
    var readyPage: Int?
    resolution.start(requestID: UUID(), documentID: UUID(), isCurrent: { selectedPage == 0 },
      resolve: { readyPage }, apply: { selectedPage = $0 })
    selectedPage = 1
    readyPage = 4
    try await Task.sleep(for: .milliseconds(140))
    XCTAssertEqual(selectedPage, 1)
    XCTAssertNil(resolution.requestID)
  }

}

/// This fixture cannot certify readiness while its hosting view is offscreen.
/// It exercises real containment and layout, rather than calling ready in renderPage.
@MainActor
private struct WindowPreparedPage: UIViewRepresentable {
  let readiness: PageTurnReadiness
  let onFirstFrame: (UUID) -> Void

  func makeUIView(context: Context) -> WindowPreparedPageView {
    WindowPreparedPageView(readiness: readiness, onFirstFrame: onFirstFrame)
  }
  func updateUIView(_ view: WindowPreparedPageView, context: Context) {
    view.readiness = readiness
    view.reportFrameIfMounted()
  }
  static func dismantleUIView(_ view: WindowPreparedPageView, coordinator: ()) {
    view.readiness(false)
  }
}

@MainActor
private final class WindowPreparedPageView: UIView {
  var readiness: PageTurnReadiness
  private let onFirstFrame: (UUID) -> Void
  private let identity = UUID()
  private var hasFrame = false
  init(readiness: PageTurnReadiness, onFirstFrame: @escaping (UUID) -> Void) {
    self.readiness = readiness; self.onFirstFrame = onFirstFrame
    super.init(frame: .zero)
  }
  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("Use init(readiness:onFirstFrame:)") }
  override func didMoveToWindow() { super.didMoveToWindow(); reportFrameIfMounted() }
  override func layoutSubviews() { super.layoutSubviews(); reportFrameIfMounted() }
  func reportFrameIfMounted() {
    if !hasFrame, window != nil, bounds.width > 0, bounds.height > 0 {
      hasFrame = true
      onFirstFrame(identity)
    }
    if hasFrame { readiness(window != nil) }
  }
}

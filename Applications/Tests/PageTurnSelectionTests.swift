import Foundation
import NotebookCore
import XCTest
import SwiftUI
import UIKit
@testable import Notebook

final class PageTurnSelectionTests: XCTestCase {
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
    let oldSource = try XCTUnwrap(controller.pageViewController.viewControllers?.first)
    let oldTarget = try XCTUnwrap(controller.pageViewController(controller.pageViewController, viewControllerAfter: oldSource))
    let oldReady = try XCTUnwrap(readiness["before"]?[1])
    controller.pageViewController(controller.pageViewController, willTransitionTo: [oldTarget])
    configure("after")
    let current = try XCTUnwrap(controller.pageViewController.viewControllers?.first)
    XCTAssertFalse(current === oldSource)
    XCTAssertTrue(oldTarget.children.isEmpty, "A discarded sequence retains no live content in UIKit's shell")
    oldReady(true)
    XCTAssertNil(controller.pageViewController(controller.pageViewController, viewControllerAfter: current))
    controller.pageViewController(controller.pageViewController, didFinishAnimating: true,
      previousViewControllers: [oldSource], transitionCompleted: true)
    XCTAssertTrue(commits.isEmpty, "A late curl cannot reinterpret its slot in the replacement order")
    XCTAssertEqual(controller.displayedIndex, 0)
    try XCTUnwrap(readiness["after"]?[1])(true)
    XCTAssertNil(controller.pageViewController(controller.pageViewController, viewControllerAfter: oldSource))
    XCTAssertNil(controller.pageViewController(controller.pageViewController, viewControllerBefore: oldTarget))
    let target = try XCTUnwrap(controller.pageViewController(controller.pageViewController, viewControllerAfter: current))
    controller.pageViewController(controller.pageViewController, willTransitionTo: [target])
    controller.pageViewController.setViewControllers([target], direction: .forward, animated: false)
    controller.pageViewController(controller.pageViewController, didFinishAnimating: true,
      previousViewControllers: [current], transitionCompleted: true)
    XCTAssertEqual(commits.map(\.0), [1])
    XCTAssertEqual(commits.map(\.1), ["after"])
    XCTAssertLessThanOrEqual(controller.cachedPageIdentities.count, 4)
  }

  func testFinitePrewarmWindowKeepsNearestPagesWithinFourSlots() {
    for count in 1...8 {
      for current in 0..<count {
        for direction in [-1, 1] {
          let window = PageTurnPrewarmWindow.indices(displayedIndex: current,
            anticipatedIndex: nil, lastDirection: direction, pageCount: count)
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
      anticipatedIndex: 7, lastDirection: nil, pageCount: 10), Set([1, 2, 7, 8]),
      "A distant handoff keeps the source, landing and next sheet without a fifth speculative host")
    XCTAssertEqual(PageTurnPrewarmWindow.indices(displayedIndex: 7,
      anticipatedIndex: 2, lastDirection: nil, pageCount: 10), Set([1, 2, 6, 7]))
  }

  @MainActor
  func testDistantRequestsDuringCurlKeepFourContentsAndOnlyTheLatestTargetSurvivesTheLocalAcknowledgement() async throws {
    let controller = IPadPageTurnController(), owner = UUID()
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
        }, onCommit: { index, _ in commits.append(index) }, onTransitioningChange: { _ in })
    }
    configure(4); window.rootViewController = controller; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    let source = try XCTUnwrap(controller.pageViewController.viewControllers?.first)
    let landing = try XCTUnwrap(controller.pageViewController(controller.pageViewController, viewControllerAfter: source))
    let preparedChild = try XCTUnwrap(landing.children.first)
    controller.pageViewController(controller.pageViewController, willTransitionTo: [landing])
    let frozenWindow = controller.cachedPageIdentities
    for target in [12, 17, 9] {
      configure(target)
      XCTAssertEqual(controller.cachedPageIdentities, frozenWindow,
        "An external request cannot add or replace a child under an active curl")
      XCTAssertFalse(rendered.contains(target))
      XCTAssertFalse(source.view.isUserInteractionEnabled)
    }
    controller.pageViewController.setViewControllers([landing], direction: .forward, animated: false)
    controller.pageViewController(controller.pageViewController, didFinishAnimating: true,
      previousViewControllers: [source], transitionCompleted: true)
    XCTAssertEqual(controller.displayedIndex, 5)
    XCTAssertTrue(landing.children.first === preparedChild, "The hand lands on its original prepared child")
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
    let controller = IPadPageTurnController(), owner = UUID()
    var rendered = Set<Int>(), commits: [Int] = []
    func configure(_ selected: Int) {
      controller.update(ownerID: owner, sequenceRevision: "fixture-order", pageCount: 20, selectedIndex: selected,
        navigationIsEnabled: true, pageIsInteractive: true, canBeginNavigation: { true },
        page: { index, _, ready in
          XCTAssertLessThanOrEqual(controller.cachedPageIdentities.count, 4)
          rendered.insert(index); ready(true); return AnyView(Text("Page \(index)"))
        }, onCommit: { index, _ in commits.append(index) }, onTransitioningChange: { _ in })
    }
    configure(0); controller.loadViewIfNeeded()
    let source = try XCTUnwrap(controller.pageViewController.viewControllers?.first)
    let sourceChild = try XCTUnwrap(source.children.first)
    let landing = try XCTUnwrap(controller.pageViewController(controller.pageViewController, viewControllerAfter: source))
    let landingChild = try XCTUnwrap(landing.children.first)
    controller.pageViewController(controller.pageViewController, willTransitionTo: [landing])
    let frozenWindow = controller.cachedPageIdentities
    for target in [7, 12, 0] {
      configure(target)
      XCTAssertEqual(controller.cachedPageIdentities, frozenWindow)
    }
    controller.pageViewController(controller.pageViewController, didFinishAnimating: true,
      previousViewControllers: [source], transitionCompleted: false)
    XCTAssertEqual(controller.displayedIndex, 0)
    XCTAssertTrue(source.children.first === sourceChild)
    XCTAssertTrue(source.view.isUserInteractionEnabled)
    XCTAssertTrue(commits.isEmpty)
    XCTAssertFalse(rendered.contains(7)); XCTAssertFalse(rendered.contains(12))
    let next = try XCTUnwrap(controller.pageViewController(controller.pageViewController, viewControllerAfter: source))
    XCTAssertTrue(next === landing); XCTAssertTrue(next.children.first === landingChild)
    controller.pageViewController(controller.pageViewController, willTransitionTo: [next])
    controller.pageViewController.setViewControllers([next], direction: .forward, animated: false)
    controller.pageViewController(controller.pageViewController, didFinishAnimating: true,
      previousViewControllers: [source], transitionCompleted: true)
    configure(1)
    XCTAssertEqual(controller.displayedIndex, 1, "The next ordinary turn cannot replay the cancelled external jump")
    XCTAssertEqual(commits, [1])
  }

  @MainActor
  func testAnUnpreparedExternalTargetReleasesThePreviousWindowBeforeCreatingItsReplacement() async throws {
    let controller = IPadPageTurnController(), owner = UUID()
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
        }, onCommit: { index, _ in commits.append(index) }, onTransitioningChange: { _ in })
    }
    configure(4); window.rootViewController = controller; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    configure(12)
    let expired = try XCTUnwrap(readiness[12])
    configure(17)
    XCTAssertNil(controller.cachedPageIdentities[12]); XCTAssertNil(controller.cachedPageIdentities[13])
    configure(9)
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
    XCTAssertTrue(commits.isEmpty, "An external selection already present in the model is not published twice")
    XCTAssertLessThanOrEqual(controller.cachedPageIdentities.count, 4)
  }

  @MainActor
  func testExternalTransitionsKeepTheirOwnFourContentsWhileNewerRequestsWait() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene), controller = IPadPageTurnController(), owner = UUID()
    var rendered = Set<Int>()
    func configure(_ selected: Int) {
      controller.update(ownerID: owner, sequenceRevision: "fixture-order", pageCount: 20, selectedIndex: selected,
        navigationIsEnabled: true, pageIsInteractive: true, canBeginNavigation: { true },
        page: { index, _, ready in
          XCTAssertLessThanOrEqual(controller.cachedPageIdentities.count, 4)
          rendered.insert(index); ready(true); return AnyView(Text("Page \(index)"))
        }, onCommit: { _, _ in }, onTransitioningChange: { _ in })
    }
    configure(4); window.rootViewController = controller; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    configure(12)
    XCTAssertEqual(controller.displayedIndex, 4, "This assertion samples the active external animation, before its completion")
    let frozenWindow = controller.cachedPageIdentities
    configure(17); XCTAssertEqual(controller.cachedPageIdentities, frozenWindow)
    configure(9); XCTAssertEqual(controller.cachedPageIdentities, frozenWindow)
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
    let window = UIWindow(windowScene: scene), controller = IPadPageTurnController(), owner = UUID()
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
        }, onTransitioningChange: { _ in })
    }
    configure(3); window.rootViewController = controller; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    let source = try XCTUnwrap(controller.pageViewController.viewControllers?.first)
    let blank = try XCTUnwrap(controller.pageViewController(controller.pageViewController, viewControllerAfter: source))
    controller.pageViewController(controller.pageViewController, willTransitionTo: [blank])
    let frozenWindow = controller.cachedPageIdentities
    configure(0)
    XCTAssertEqual(controller.cachedPageIdentities, frozenWindow)
    controller.pageViewController.setViewControllers([blank], direction: .forward, animated: false)
    controller.pageViewController(controller.pageViewController, didFinishAnimating: true,
      previousViewControllers: [source], transitionCompleted: true)
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
    let firstShell = try XCTUnwrap(controller.pageViewController.viewControllers?.first)
    let firstChild = try XCTUnwrap(firstShell.children.first)
    for expected in [1, 2, 1, 0] {
      let previous = try XCTUnwrap(controller.pageViewController.viewControllers?.first)
      let forward = expected > controller.displayedIndex
      let target = try XCTUnwrap(forward
        ? controller.pageViewController(controller.pageViewController, viewControllerAfter: previous)
        : controller.pageViewController(controller.pageViewController, viewControllerBefore: previous))
      controller.pageViewController(controller.pageViewController, willTransitionTo: [target])
      controller.pageViewController.setViewControllers([target], direction: forward ? .forward : .reverse, animated: false)
      controller.pageViewController(controller.pageViewController, didFinishAnimating: true,
        previousViewControllers: [previous], transitionCompleted: true)
      configure()
      XCTAssertEqual(controller.displayedIndex, expected)
      XCTAssertEqual(Set(controller.cachedPageIdentities.keys), Set([0, 1, 2]))
      XCTAssertTrue(firstShell.children.first === firstChild,
        "A ready reverse page is not retired while the finite document fits the existing four-host budget")
    }
    XCTAssertTrue(controller.pageViewController.viewControllers?.first === firstShell)
  }

  @MainActor
  func testUIKitCachedShellInstallsItsRestoredChildWithoutASecondDataSourceRequest() throws {
    let controller = IPadPageTurnController(), owner = UUID()
    var committed = 0
    func configure() {
      controller.update(ownerID: owner, sequenceRevision: "fixture-order", pageCount: 6, selectedIndex: committed,
        navigationIsEnabled: true, pageIsInteractive: true, canBeginNavigation: { true },
        page: { index, _, ready in ready(true); return AnyView(Text("Page \(index)")) },
        onCommit: { index, _ in committed = index }, onTransitioningChange: { _ in })
    }
    configure(); controller.loadViewIfNeeded()
    let firstShell = try XCTUnwrap(controller.pageViewController.viewControllers?.first)
    for expected in [1, 2, 1] {
      let previous = try XCTUnwrap(controller.pageViewController.viewControllers?.first)
      let forward = expected > controller.displayedIndex
      let target = try XCTUnwrap(forward
        ? controller.pageViewController(controller.pageViewController, viewControllerAfter: previous)
        : controller.pageViewController(controller.pageViewController, viewControllerBefore: previous))
      controller.pageViewController(controller.pageViewController, willTransitionTo: [target])
      controller.pageViewController.setViewControllers([target], direction: forward ? .forward : .reverse, animated: false)
      controller.pageViewController(controller.pageViewController, didFinishAnimating: true,
        previousViewControllers: [previous], transitionCompleted: true)
      configure()
    }
    XCTAssertTrue(firstShell.children.isEmpty, "The replacement child is prepared separately from UIKit's cached shell")
    let shellParent = firstShell.parent
    // UIKit is allowed to reuse the shell it already retained, skipping before:.
    controller.pageViewController(controller.pageViewController, willTransitionTo: [firstShell])
    let installed = try XCTUnwrap(firstShell.children.first)
    XCTAssertTrue(installed.view.superview === firstShell.view)
    XCTAssertTrue(firstShell.parent === shellParent, "The handoff installs the child without reparenting UIKit's shell")
    XCTAssertLessThanOrEqual(controller.cachedPageIdentities.count, 4)
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
  func testRetiredUIKitShellReturnsWithNewReadinessWithoutBeingReparented() throws {
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
      let current = try XCTUnwrap(controller.pageViewController.viewControllers?.first)
      let next = try XCTUnwrap(forward
        ? controller.pageViewController(controller.pageViewController, viewControllerAfter: current)
        : controller.pageViewController(controller.pageViewController, viewControllerBefore: current))
      controller.pageViewController(controller.pageViewController, willTransitionTo: [next])
      controller.pageViewController.setViewControllers([next], direction: forward ? .forward : .reverse, animated: false)
      controller.pageViewController(controller.pageViewController, didFinishAnimating: true,
        previousViewControllers: [current], transitionCompleted: true)
      configure()
    }
    configure(); controller.loadViewIfNeeded()
    let original = try XCTUnwrap(controller.pageViewController.viewControllers?.first)
    let expiredReadiness = try XCTUnwrap(readiness[0]?.last)
    try turn(forward: true)
    try turn(forward: true)
    XCTAssertEqual(controller.displayedIndex, 2)
    XCTAssertNil(controller.cachedPageIdentities[0], "The far page must release live content even while UIKit retains its shell")

    preparesImmediately = false
    try turn(forward: false)
    XCTAssertEqual(controller.displayedIndex, 1)
    XCTAssertEqual(controller.cachedPageIdentities[0], ObjectIdentifier(original))
    XCTAssertFalse(original.parent === controller, "Restoring content must not steal UIKit's controller back into prewarm")
    let current = try XCTUnwrap(controller.pageViewController.viewControllers?.first)
    XCTAssertNil(controller.pageViewController(controller.pageViewController, viewControllerBefore: current))
    expiredReadiness(true)
    XCTAssertNil(controller.pageViewController(controller.pageViewController, viewControllerBefore: current),
      "Readiness from the retired content cannot certify the replacement page")
    try XCTUnwrap(readiness[0]?.last)(true)
    expiredReadiness(false)
    let restored = try XCTUnwrap(controller.pageViewController(controller.pageViewController, viewControllerBefore: current))
    XCTAssertTrue(restored === original, "UIKit's retained identity is also the prepared reverse candidate")
  }

  @MainActor
  func testRestoredUIKitShellPreparesItsNewChildInTheWindowBeforeReturning() async throws {
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
      let current = try XCTUnwrap(controller.pageViewController.viewControllers?.first)
      var next: UIViewController?
      let deadline = ContinuousClock.now + .seconds(3)
      repeat {
        next = forward
          ? controller.pageViewController(controller.pageViewController, viewControllerAfter: current)
          : controller.pageViewController(controller.pageViewController, viewControllerBefore: current)
        if next == nil { try await Task.sleep(for: .milliseconds(10)) }
      } while next == nil && ContinuousClock.now < deadline
      let destination = try XCTUnwrap(next, "A restored child must reach the real prewarm window without displaying its retired shell first")
      controller.pageViewController(controller.pageViewController, willTransitionTo: [destination])
      controller.pageViewController.setViewControllers([destination], direction: forward ? .forward : .reverse, animated: false)
      controller.pageViewController(controller.pageViewController, didFinishAnimating: true,
        previousViewControllers: [current], transitionCompleted: true)
      configure()
      XCTAssertLessThanOrEqual(controller.cachedPageIdentities.count, 4)
    }
    configure(); window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    let originalShell = try XCTUnwrap(controller.pageViewController.viewControllers?.first)
    try await turn(forward: true)
    let originalChild = try XCTUnwrap(preparedChildren[0]?.first)
    try await turn(forward: true)
    XCTAssertNil(controller.cachedPageIdentities[0])
    try await turn(forward: false)
    XCTAssertFalse(originalShell.parent === controller,
      "Only the newly prepared child, never UIKit's retained shell, belongs to prewarm containment")
    try await turn(forward: false)
    XCTAssertEqual(controller.displayedIndex, 0)
    XCTAssertTrue(controller.pageViewController.viewControllers?.first === originalShell)
    XCTAssertEqual(preparedChildren[0]?.count, 2)
    XCTAssertNotEqual(preparedChildren[0]?.last, originalChild,
      "The far content was released, and its replacement earned readiness from its own mounted view")
  }

  @MainActor
  func testExternalPageSelectionPublishesTransitionOutsideTheRepresentableUpdate() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene), controller = IPadPageTurnController(), owner = UUID()
    var insideUpdate = false
    var reported: [Bool] = []
    func update(selected: Int) {
      insideUpdate = true
      controller.update(ownerID: owner, sequenceRevision: "fixture-order", pageCount: 3, selectedIndex: selected,
        navigationIsEnabled: true, pageIsInteractive: true, canBeginNavigation: { true },
        page: { index, _, ready in ready(true); return AnyView(Text("Page \(index)")) },
        onCommit: { _, _ in }, onTransitioningChange: { active in
          XCTAssertFalse(insideUpdate, "SwiftUI state must not be published inside updateUIViewController")
          reported.append(active)
        })
      insideUpdate = false
    }
    update(selected: 0)
    window.rootViewController = controller; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    try await Task.sleep(for: .milliseconds(20))
    reported.removeAll()
    let previous = try XCTUnwrap(controller.pageViewController.viewControllers?.first)
    update(selected: 1)
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
    func update(owner: UUID) {
      controller.update(ownerID: owner, sequenceRevision: "fixture-order", pageCount: 3, selectedIndex: 0,
        navigationIsEnabled: true, pageIsInteractive: true, canBeginNavigation: { true },
        page: { index, _, ready in ready(true); return AnyView(Text("Page \(index)")) },
        onCommit: { _, _ in }, onTransitioningChange: { reported.append((owner, $0)) })
    }
    update(owner: firstOwner); controller.loadViewIfNeeded()
    try await Task.sleep(for: .milliseconds(20))
    reported.removeAll()
    let current = try XCTUnwrap(controller.pageViewController.viewControllers?.first)
    let next = try XCTUnwrap(controller.pageViewController(controller.pageViewController, viewControllerAfter: current))
    controller.pageViewController(controller.pageViewController, willTransitionTo: [next])
    XCTAssertFalse(current.view.isUserInteractionEnabled)
    XCTAssertTrue(reported.isEmpty)
    controller.pageViewController(controller.pageViewController, didFinishAnimating: true,
      previousViewControllers: [current], transitionCompleted: false)
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
    if hasFrame { readiness(true) }
  }
}

import NotebookCore
import SwiftUI
import UIKit
import XCTest
@testable import Notebook

final class CameraPresenceProjectionTests: XCTestCase {
  @MainActor
  func testUnsettledPresenceProjectsThePreparedSceneWithoutRepublishingItsContents() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let boardID = try XCTUnwrap(model.workspace?.rootBoardID)
    let viewport = SpatialPoint(x: 1194, y: 834)
    func presence(_ step: Int) -> SessionPresence {
      .init(boardID: boardID, mode: .board,
        camera: .init(center: .init(x: Double(step) * 0.31, y: Double(step) * -0.14),
          scale: 0.2 + Double(step) * 0.0001), viewport: viewport)
    }
    model.updatePresence(presence(0), settled: true)
    let saved = await model.finishPendingPersistence()
    XCTAssertTrue(saved)
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow)
    let window = UIWindow(windowScene: scene)
    window.frame = .init(x: 0, y: 0, width: viewport.x, height: viewport.y)
    let host = UIHostingController(rootView: SpatialWorkspaceView().environment(model))
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    let deadline = ContinuousClock.now + .seconds(8)
    while model.compositionTiles.published == nil, model.compositionTiles.failure == nil,
      ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    let cohort = try XCTUnwrap(model.compositionTiles.published, model.compositionTiles.failure ?? "Prepared scene required")
    // This is the model's continuous-presence contract, also used by incoming
    // camera updates. There is deliberately no private SwiftUI gesture state.
    model.updatePresence(presence(1), settled: false)
    try await Task.sleep(for: .milliseconds(80))
    let owners = cameraOwners(in: host)
    XCTAssertGreaterThanOrEqual(owners.count, 2, "The item and element planes are both installed")
    let baseline = Dictionary(uniqueKeysWithValues: owners.map {
      (ObjectIdentifier($0), ($0.contentPublicationCount, $0.cameraProjectionCount))
    })
    for step in 2...41 {
      model.updatePresence(presence(step), settled: false)
      window.layoutIfNeeded()
      try await Task.sleep(for: .milliseconds(8))
    }
    let final = cameraOwners(in: host)
    XCTAssertEqual(Set(final.map(ObjectIdentifier.init)), Set(baseline.keys))
    for owner in final {
      let before = try XCTUnwrap(baseline[ObjectIdentifier(owner)])
      XCTAssertEqual(owner.contentPublicationCount, before.0,
        "Continuous presence changes the native matrix, not UIHosting.rootView")
      XCTAssertGreaterThan(owner.cameraProjectionCount, before.1 + 10,
        "The check must observe actual updates, not a detached or frozen scene")
    }
    XCTAssertTrue(model.compositionTiles.published === cohort)
    model.updatePresence(presence(41), settled: true)
    let settled = await model.finishPendingPersistence()
    XCTAssertTrue(settled)
  }

  @MainActor
  private func cameraOwners(in controller: UIViewController) -> [any SceneCameraPlaneActivity] {
    (controller as? any SceneCameraPlaneActivity).map { [$0] } ??
      controller.children.flatMap { cameraOwners(in: $0) }
  }
}

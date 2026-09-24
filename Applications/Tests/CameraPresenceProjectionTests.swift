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
    model.selectWorkspaceItem(try XCTUnwrap(model.workspace?.selectedItemID),boardID:boardID)
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
    let controls = try XCTUnwrap(descendants(host.view).compactMap { $0 as? NotebookSelectionControlsView }.first)
    let cover = try XCTUnwrap(descendants(host.view).compactMap { $0 as? NotebookInteractionTouchView }.first)
    let outline = try XCTUnwrap(controls.subviews.first { $0.layer.borderWidth == 2 })
    let capsule = try XCTUnwrap(descendants(host.view).first { $0.accessibilityIdentifier == "notebook-context-menu" })
    XCTAssertTrue(capsule.isHidden,"Selected material no longer mounts a floating action strip")
    let owners = cameraOwners(in: host)
    XCTAssertGreaterThanOrEqual(owners.count, 2, "The item and element planes are both installed")
    let baseline = Dictionary(uniqueKeysWithValues: owners.map {
      (ObjectIdentifier($0), ($0.contentPublicationCount, $0.cameraProjectionCount))
    })
    for step in 2...41 {
      model.updatePresence(presence(step), settled: false)
      // Native projection must already be correct before a SwiftUI/layout tick.
      let physical = cover.convert(cover.bounds,to:controls)
      XCTAssertEqual(outline.frame.minX,physical.minX,accuracy:0.5)
      XCTAssertEqual(outline.frame.minY,physical.minY,accuracy:0.5)
      XCTAssertEqual(outline.frame.width,physical.width,accuracy:0.5)
      XCTAssertEqual(outline.frame.height,physical.height,accuracy:0.5)
      XCTAssertEqual(outline.layer.borderWidth,2)
      XCTAssertTrue(capsule.isHidden,"Camera projection cannot resurrect replaced floating controls")
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
  func testSelectionProjectsLargeZoomAndRejectsAStaleSwiftUIPublication() throws {
    let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous=scene.windows.first(where:\.isKeyWindow),window=UIWindow(windowScene:scene)
    let gate=NotebookInputGate(),menus=NotebookContextMenus(),projection=SceneNativeCameraProjection()
    let controls=NotebookSelectionControlsView(gate:gate,contextMenus:menus)
    let root=UIViewController();window.rootViewController=root;window.makeKeyAndVisible()
    controls.frame=root.view.bounds;menus.view.frame=root.view.bounds
    root.view.addSubview(controls);root.view.addSubview(menus.view)
    defer { controls.uninstall();menus.uninstall();window.isHidden=true;previous?.makeKey() }
    let anchor=SessionPresence(boardID:UUID(),mode:.board,camera:.init(scale:0.25),viewport:.init(x:834,y:1194))
    let frame=CGRect(x:210,y:280,width:210,height:300),id=UUID()
    func configure() {
      controls.configure(selectionID:id,frame:frame,scale:0.25,subject:.item(.notebook),
        camera:anchor,cameraProjection:projection,cornerRadius:4.5)
    }
    configure()
    let outline=try XCTUnwrap(controls.subviews.first { $0.layer.borderWidth == 2 })
    for scale in [0.5,1.2,0.15,0.7] {
      let current=SessionPresence(boardID:anchor.boardID,mode:.board,
        camera:.init(center:.init(x:20,y:-30),scale:scale),viewport:anchor.viewport)
      projection.update(current)
      configure() // A queued representable update still carries the old basis.
      let matrix=SceneCameraProjection(anchor:anchor,current:current)
      let origin=matrix.project(.init(x:frame.minX,y:frame.minY))
      XCTAssertEqual(outline.frame.minX,origin.x,accuracy:0.001)
      XCTAssertEqual(outline.frame.minY,origin.y,accuracy:0.001)
      XCTAssertEqual(outline.frame.width,frame.width*scale/0.25,accuracy:0.001)
      XCTAssertEqual(outline.layer.borderWidth,2)
      XCTAssertEqual(outline.layer.cornerRadius,18*scale,accuracy:0.001)
      XCTAssertEqual(controls.projectionScale,scale,accuracy:0.001)
    }
    controls.uninstall()
    let retired=outline.frame
    projection.update(anchor)
    XCTAssertEqual(outline.frame,retired,"A retired controls owner must not move again")
  }

  @MainActor private func descendants(_ view:UIView)->[UIView] { [view]+view.subviews.flatMap(descendants) }

  @MainActor
  private func cameraOwners(in controller: UIViewController) -> [any SceneCameraPlaneActivity] {
    (controller as? any SceneCameraPlaneActivity).map { [$0] } ??
      controller.children.flatMap { cameraOwners(in: $0) }
  }
}

import NotebookCore
import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import Notebook

@MainActor
final class NotebookLiveGesturePresentationTests: XCTestCase {
  func testMountedArtifactAndCornersStayAtBothDropsWhileTheOldCohortIsRetained() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("artifact-continuity-" + UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    let host = UIHostingController(rootView: AnyView(EmptyView()))
    let pencil = UUID()
    addTeardownBlock { @MainActor in
      model.inputGate.endPencilAction(source: pencil)
      host.rootView = AnyView(EmptyView()); window.isHidden = true; window.rootViewController = nil
      let saved = await model.shutdown(); XCTAssertTrue(saved)
      if saved { try FileManager.default.removeItem(at: root) }
    }
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    guard case .ready = model.loadState else {
      XCTFail("Gesture fixture failed to start: \(model.loadState)"); return
    }
    model.moveItem(try XCTUnwrap(model.workspace?.selectedItemID), to: .init(x: 100_000, y: 100_000))
    let initialSave = await model.finishPendingPersistence(); XCTAssertTrue(initialSave)
    let boardID = try XCTUnwrap(model.workspace?.rootBoardID)
    let before = try model.store.loadBoard(items: try XCTUnwrap(model.workspace).items)
    var after = before
    let element = SpatialElement(id: "accepted-artifact", surface: .board(boardID), kind: .web,
      frame: .init(x: 100, y: 200, width: 180, height: 120), worldOrigin: .zero,
      source: "An already mounted artifact", html: "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 180 120'><rect width='180' height='120' fill='#8c1ec8'/></svg>",
      css: "html,body,svg{margin:0;width:100%;height:100%;display:block}", stamp: .init(counter: 0, actor: model.actorID))
    XCTAssertTrue(after.upsertElement(element, in: boardID, expected: nil, actor: model.actorID))
    _ = try model.store.saveBoardEdits(before: before, after: after)
    await model.reloadExternalChanges()?.value
    window.frame = .init(x: 0, y: 0, width: 834, height: 1194)
    let presence = SessionPresence(boardID: boardID, mode: .board,
      camera: .init(center: .init(x: 417, y: 597), scale: 1), viewport: .init(x: 834, y: 1194))
    model.updatePresence(presence, settled: true)
    host.rootView = AnyView(SpatialWorkspaceView().environment(model).environment(\.displayScale, 2).ignoresSafeArea())
    window.rootViewController = host; window.makeKeyAndVisible()
    try await waitUntil {
      model.compositionTiles.published?.plan.allowsLive(.element(element.id), in: .board(boardID)) == true
        && !model.scenePreparationPending && !model.inputIsActive
        && model.compositionTiles.published?.sourceReceipts[
          .init(plane: .board(boardID), elementID: element.id)]?.hasCurrentPixels == true
    }
    let original = try XCTUnwrap(model.compositionTiles.published)
    // A visible program now owns a live WebKit, not a passive image view.
    // Follow that actual source through both gestures and the accepted resize.
    let source = agentElementSnapshotSource(element)
    try await waitUntil { self.liveWeb(in: host.view, source: source) != nil }
    let body = try XCTUnwrap(liveWeb(in: host.view, source: source))
    let recognizer = try XCTUnwrap(window.gestureRecognizers?.compactMap { $0 as? SceneSelectionRecognizer }.first)
    let observer = try XCTUnwrap(window.gestureRecognizers?.compactMap { $0 as? NotebookContactObserver }.first)
    let reference = EditableElementReference.spatial(boardID: boardID, elementID: element.id)
    let initialInk = model.spatialInk
    var expected = CGRect(x: 100, y: 200, width: 180, height: 120)
    assertFrame(body.convert(body.bounds, to: host.view), equals: expected)
    let baseline = try pixelPatch(in: host.view, at: .init(x: expected.midX, y: expected.midY), name: "artifact-before-drag")
    XCTAssertGreaterThan(baseline[0], 100); XCTAssertLessThan(baseline[1], 70); XCTAssertGreaterThan(baseline[2], 160)

    for (index, delta) in [CGSize(width: 120, height: 60), CGSize(width: 140, height: 50)].enumerated() {
      // Deliver the same native contact to its installed lifetime observer and
      // selection recognizer. Neither a new fixture host nor a model-only
      // projection supplies the pixels inspected below.
      // A window-mounted recognizer resets through UIKit's event cycle. Do
      // not send another synthetic down while a queued reset can erase it.
      // The previous Pencil barrier still retains the same old cohort here.
      try await waitUntil(diagnostic: {
        "UIKit has not finished the preceding contact: selection \(recognizer.state.rawValue), observer \(observer.state.rawValue)"
      }) { recognizer.state == .possible && observer.state == .possible }
      model.inputGate.endPencilAction(source: pencil)
      let touch = LiveArtifactTouch(window: window)
      touch.point = host.view.convert(.init(x: expected.midX, y: expected.midY), to: window)
      let nativePoint = touch.location(in: recognizer.coordinateView)
      let sourceIsInstalled = window.gestureRecognizers?.contains { $0 === recognizer } == true
      XCTAssertTrue(sourceIsInstalled, "The physical selection recognizer must not be replaced between drops")
      XCTAssertEqual(recognizer.state, .possible, "The synthetic contact starts after UIKit reset, drop \(index + 1)")
      XCTAssertNotNil(recognizer.onLift?(nativePoint),
        "The installed point route must resolve the shown artifact, drop \(index + 1), point \(nativePoint), body \(body.convert(body.bounds, to: host.view)), selection \(String(describing: model.selectionSession.target)), error \(model.agentRequestError ?? "none")")
      observer.touchesBegan([touch], with: UIEvent())
      recognizer.touchesBegan([touch], with: UIEvent())
      XCTAssertNil(model.selectionSession.manipulation,"A stationary touch must not begin a drag")
      touch.point.x += delta.width; touch.point.y += delta.height
      recognizer.touchesMoved([touch], with: UIEvent())
      XCTAssertEqual(model.selectionSession.manipulation?.reference,reference,"The selected material starts directly on movement, without another long hold")
      recognizer.touchesEnded([touch], with: UIEvent())
      observer.touchesEnded([touch], with: UIEvent())
      // A real input barrier prevents the asynchronous composition from
      // rescuing a lost drop. This does not fabricate a replacement cohort.
      XCTAssertTrue(model.inputGate.beginPencilAction(source: pencil))
      expected = expected.offsetBy(dx: delta.width, dy: delta.height)
      XCTAssertNil(model.selectionSession.manipulation)
      XCTAssertEqual(model.presentedElement(reference,cohort:original)?.frame,
        .init(x: expected.minX, y: expected.minY, width: expected.width, height: expected.height))
      try await waitUntil {
        host.view.layoutIfNeeded()
        return self.framesEqual(body.convert(body.bounds, to: host.view), expected)
      }
      XCTAssertTrue(model.compositionTiles.published === original, "The whole old cohort remains held at this sample")
      XCTAssertTrue(liveWeb(in: host.view, source: source) === body, "The same admitted runtime follows the accepted edit")
      try assertCornerFrame(in: host.view, expected: expected)
      let shown = try pixelPatch(in: host.view, at: .init(x: expected.midX, y: expected.midY), name: "artifact-after-drop-\(index + 1)-old-cohort")
      for channel in 0..<3 { XCTAssertEqual(shown[channel], baseline[channel], accuracy: 12) }
      XCTAssertEqual(model.presence?.camera, presence.camera)
      XCTAssertEqual(model.spatialInk, initialInk)
    }

    model.inputGate.endPencilAction(source: pencil)
    let resize = try XCTUnwrap(model.beginElementManipulation(reference, kind: .resize(.topLeading)))
    model.updateElementManipulation(resize,translation:.init(x:-40,y:-30))
    expected = .init(x: expected.minX - 40, y: expected.minY - 30, width: expected.width + 40, height: expected.height + 30)
    try await waitUntil {
      host.view.layoutIfNeeded()
      return self.framesEqual(body.convert(body.bounds, to: host.view), expected)
    }
    XCTAssertTrue(model.compositionTiles.published === original)
    XCTAssertNotNil(model.selectionSession.manipulation,"Content already follows the resize while the finger is down")
    XCTAssertTrue(liveWeb(in:host.view,source:source) === body)
    XCTAssertTrue(model.finishElementManipulation(resize,translation:.init(x:-40,y:-30)))
    XCTAssertTrue(model.inputGate.beginPencilAction(source:pencil))
    try assertCornerFrame(in: host.view, expected: expected)
    let resized = try pixelPatch(in: host.view, at: .init(x: expected.minX + 30, y: expected.minY + 30), name: "artifact-resized-old-cohort")
    for channel in 0..<3 { XCTAssertEqual(resized[channel], baseline[channel], accuracy: 12) }
    model.inputGate.endPencilAction(source: pencil)
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    XCTAssertEqual(try model.store.readSpatialElement(boardID: boardID, elementID: element.id)?.frame,
      .init(x: expected.minX, y: expected.minY, width: expected.width, height: expected.height))
  }

  func testBoardWholePublicationKeepsItsProgramAndVisibilityReturnRestoresCheckpoint() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("whole-runtime-" + UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    let previous = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.windows.first(where: \.isKeyWindow)
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    let host = UIHostingController(rootView: AnyView(EmptyView()))
    addTeardownBlock { @MainActor in
      host.rootView = AnyView(EmptyView()); window.isHidden = true; window.rootViewController = nil; previous?.makeKey()
      let saved = await model.shutdown(); XCTAssertTrue(saved)
      if saved { try FileManager.default.removeItem(at: root) }
    }
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    model.moveItem(try XCTUnwrap(model.workspace?.selectedItemID), to: .init(x: 100_000, y: 100_000))
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    let boardID = try XCTUnwrap(model.workspace?.rootBoardID)
    let before = try model.store.loadBoard(items: try XCTUnwrap(model.workspace).items)
    var after = before
    let stamp = VersionStamp(counter: 0, actor: model.actorID)
    let whole = SpatialElement(id: "whole", surface: .board(boardID), kind: .group,
      frame: .init(x: 100, y: 200, width: 400, height: 300), worldOrigin: .zero, source: "",
      basis: .init(size: .init(x: 400, y: 300)), stamp: stamp)
    let program = SpatialElement(id: "program", surface: .board(boardID), kind: .web,
      frame: .init(x: 20, y: 20, width: 180, height: 100), worldOrigin: .zero, source: "Whole runtime",
      html: "<button id='counter'>7</button><input id='value' value='initial'>", javaScript: """
        const counter=document.getElementById('counter'),input=document.getElementById('value');
        counter.textContent=notebook.state.count ?? 7;input.value=notebook.state.value ?? 'initial';
        counter.onclick=()=>counter.textContent=Number(counter.textContent)+1;
        window.runtimeNonce="boot";
        notebook.lifecycle({checkpoint:()=>({count:Number(counter.textContent),value:input.value})});
        notebook.ready(Promise.resolve());
        """, parentID: whole.id, stamp: stamp)
    let text = SpatialElement(id: "text", surface: .board(boardID), kind: .nativeText,
      frame: .init(x: 20, y: 150, width: 180, height: 10), worldOrigin: .zero,
      source: "Текст и программа внутри общего основания", parentID: whole.id, stamp: stamp)
    for element in [whole, program, text] {
      XCTAssertTrue(after.upsertElement(element, in: boardID, expected: nil, actor: model.actorID))
    }
    _ = try model.store.saveBoardEdits(before: before, after: after)
    await model.reloadExternalChanges()?.value
    let storedProgram = try XCTUnwrap(model.store.readSpatialElement(boardID: boardID, elementID: program.id))
    let storedText = try model.store.readSpatialElement(boardID: boardID, elementID: text.id)
    window.frame = .init(x: 0, y: 0, width: 834, height: 1194)
    let presence = SessionPresence(boardID: boardID, mode: .board,
      camera: .init(center: .init(x: 417, y: 597), scale: 1), viewport: .init(x: 834, y: 1194))
    model.updatePresence(presence, settled: true)
    host.rootView = AnyView(SpatialWorkspaceView().environment(model).environment(\.displayScale, 2).ignoresSafeArea())
    window.rootViewController = host; window.makeKeyAndVisible()
    let source = agentElementSnapshotSource(storedProgram), ref = EditableElementReference.spatial(boardID: boardID, elementID: whole.id)
    try await waitUntil(diagnostic: {
      let webs = self.descendants(host.view, as: WKWebView.self)
      return "Initial whole: pending=\(model.scenePreparationPending), failure=\(model.compositionTiles.failure ?? "none"), owners=\(String(describing:model.compositionTiles.published?.runtimeOwners)), webs=\(webs.count), diagnostics=\(SceneRenderResources.shared.diagnostics(for:[source]))"
    }) {
      self.liveWeb(in: host.view, source: source) != nil && !model.scenePreparationPending
    }
    let web = try XCTUnwrap(liveWeb(in: host.view, source: source))
    let original = try XCTUnwrap(model.compositionTiles.published)
    _ = try await web.evaluateJavaScript("window.runtimeNonce='kept';document.getElementById('counter').click();document.getElementById('value').value='kept';null")
    model.selectElement(ref)
    try await waitUntil { model.groupAllowsLiveManipulation(ref) }
    let contact = try XCTUnwrap(model.beginElementManipulation(ref, kind: .move))
    XCTAssertTrue(model.finishElementManipulation(contact, translation: .init(x: 60, y: 40)))
    let moved = await model.finishPendingPersistence(); XCTAssertTrue(moved)
    await model.reloadExternalChanges()?.value
    try await waitUntil {
      model.compositionTiles.published !== original && model.groupAllowsLiveManipulation(ref) && !model.scenePreparationPending
    }
    XCTAssertTrue(model.transformSelectedGroup(radians: .pi / 6, scale: 1.2))
    let rotated = await model.finishPendingPersistence(); XCTAssertTrue(rotated)
    await model.reloadExternalChanges()?.value
    let persistedWhole = try XCTUnwrap(model.store.readSpatialElement(boardID: boardID, elementID: whole.id))
    XCTAssertNotEqual(persistedWhole.basis, whole.basis)
    try await waitUntil {
      host.view.layoutIfNeeded()
      guard let cohort = model.compositionTiles.published,
        let placement = model.presentedGraphicGraph(boardID: boardID, cohort: cohort).placement(program.id) else { return false }
      let expected = NotebookElementPresentation(storedProgram, placement: placement).bounds
      return model.groupAllowsLiveManipulation(ref) && !model.scenePreparationPending
        && self.framesEqual(web.convert(web.bounds, to: host.view), expected)
    }
    XCTAssertTrue(liveWeb(in: host.view, source: source) === web, "Publication keeps the physical program, not merely its cached picture")
    XCTAssertEqual(web.bounds.size, CGSize(width: 180, height: 100))
    let retainedNonce = try await web.evaluateJavaScript("window.runtimeNonce") as? String
    XCTAssertEqual(retainedNonce, "kept")
    XCTAssertEqual(try model.store.readSpatialElement(boardID: boardID, elementID: program.id), storedProgram)
    XCTAssertEqual(try model.store.readSpatialElement(boardID: boardID, elementID: text.id), storedText)

    let basis = try XCTUnwrap(model.programStateBasis(focus: .board(boardID: boardID, elementID: program.id), rendered: source))
    XCTAssertNotNil(try model.store.checkpointProgramState(target: .init(kind: .board, id: boardID), rendered: source,
      state: source.state, basis: basis, actor: model.actorID), "Current addressed source accepts its unchanged state")
    let pendingValues = try await web.evaluateJavaScript("document.getElementById('counter').textContent+':'+document.getElementById('value').value") as? String
    XCTAssertEqual(pendingValues, "8:kept")

    // Leaving the scene may retire the heap, but only after the existing owner
    // has durably captured its explicit state. No second persistence path.
    model.clearSelection()
    model.updatePresence(SessionPresence(boardID: boardID, mode: .board,
      camera: .init(center: .init(x: 20_000, y: 20_000), scale: 1), viewport: presence.viewport), settled: true)
    let checkpoint: JSONValue = .object(["count": .number(8), "value": .string("kept")])
    try await waitUntil(diagnostic: {
      "Retirement: live=\(self.liveWeb(in:host.view,source:source) != nil), state=\(String(describing:try? model.store.readSpatialElement(boardID:boardID,elementID:program.id)?.state)), cue=\(model.actionCue ?? "none"), presence=\(String(describing:model.presence)), owners=\(String(describing:model.compositionTiles.published?.runtimeOwners)), pending=\(model.scenePreparationPending), focus=\(String(describing:model.interactiveElementFocus)), drafts=\(model.elementCommandDrafts.keys)"
    }) {
      self.liveWeb(in: host.view, source: source) == nil
        && (try? model.store.readSpatialElement(boardID: boardID, elementID: program.id)?.state) == checkpoint
    }
    model.updatePresence(presence, settled: true)
    let restoredSource = agentElementSnapshotSource(try XCTUnwrap(model.store.readSpatialElement(boardID: boardID, elementID: program.id)))
    try await waitUntil { self.liveWeb(in: host.view, source: restoredSource) != nil && !model.scenePreparationPending }
    let restored = try XCTUnwrap(liveWeb(in: host.view, source: restoredSource))
    XCTAssertFalse(restored === web, "Offscreen retirement releases the old browser context")
    let values = try await restored.evaluateJavaScript("document.getElementById('counter').textContent+':'+document.getElementById('value').value") as? String
    XCTAssertEqual(values, "8:kept")
    let reopened = try NotebookStore(root: root).readSpatialElement(boardID: boardID, elementID: program.id)
    XCTAssertEqual(reopened?.state, checkpoint)
    XCTAssertEqual(reopened?.frame, storedProgram.frame); XCTAssertEqual(reopened?.parentID, whole.id)
    XCTAssertEqual(try model.store.readSpatialElement(boardID: boardID, elementID: whole.id), persistedWhole)
  }

  private func assertCornerFrame(in view: UIView, expected: CGRect) throws {
    let controls = try XCTUnwrap(descendants(view, as: NotebookSelectionControlsView.self).first)
    let corners = (controls.accessibilityElements ?? []).compactMap { $0 as? UIAccessibilityElement }
    XCTAssertEqual(corners.count, 8)
    for corner in NotebookElementResizeHandle.allCases {
      let accessibility = try XCTUnwrap(corners.first { $0.accessibilityIdentifier == "resize-agent-element-" + corner.rawValue })
      let region = accessibility.accessibilityFrameInContainerSpace
      let center = controls.convert(CGPoint(x: region.midX, y: region.midY), to: view)
      let expectedPoint = corner.point(in: expected)
      XCTAssertEqual(center.x, expectedPoint.x, accuracy: 0.5)
      XCTAssertEqual(center.y, expectedPoint.y, accuracy: 0.5)
    }
  }

  private func liveWeb(in view: UIView, source: AgentElement) -> WKWebView? {
    descendants(view, as: WKWebView.self).first { web in
      (web.navigationDelegate as? AgentWebCoordinator)?.hasLiveSource(source) == true
        && web.window != nil && !web.isHidden
    }
  }

  private func descendants<T: UIView>(_ view: UIView, as type: T.Type) -> [T] {
    (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, as: type) }
  }

  private func framesEqual(_ actual: CGRect, _ expected: CGRect) -> Bool {
    abs(actual.minX - expected.minX) < 0.5 && abs(actual.minY - expected.minY) < 0.5
      && abs(actual.width - expected.width) < 0.5 && abs(actual.height - expected.height) < 0.5
  }

  private func assertFrame(_ actual: CGRect, equals expected: CGRect) {
    XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.5); XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.5)
    XCTAssertEqual(actual.width, expected.width, accuracy: 0.5); XCTAssertEqual(actual.height, expected.height, accuracy: 0.5)
  }

  private func waitUntil(diagnostic: () -> String = { "The admitted native artifact did not present its accepted frame" },
    _ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(predicate(), diagnostic(), file: file, line: line)
    guard predicate() else { throw CocoaError(.featureUnsupported) }
  }

  private func pixelPatch(in view: UIView, at point: CGPoint, name: String) throws -> [Double] {
    let format = UIGraphicsImageRendererFormat(); format.scale = 1
    let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { _ in
      view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
    }
    let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    let cg = try XCTUnwrap(image.cgImage)
    let context = try XCTUnwrap(CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8,
      bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(cg, in: .init(x: 0, y: 0, width: cg.width, height: cg.height))
    let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
    let x = Int(point.x.rounded()), y = Int(point.y.rounded())
    guard (5..<(cg.width - 5)).contains(x), (5..<(cg.height - 5)).contains(y) else { throw CocoaError(.coderInvalidValue) }
    var sums = [0.0, 0, 0]
    for row in (y - 4)...(y + 4) { for column in (x - 4)...(x + 4) {
      let offset = row * context.bytesPerRow + column * 4
      for channel in 0..<3 { sums[channel] += Double(bytes[offset + channel]) }
    }}
    return sums.map { $0 / 81 }
  }
}

@MainActor
private final class LiveArtifactTouch: UITouch {
  weak var sourceWindow: UIWindow?
  var point = CGPoint.zero
  init(window: UIWindow) { sourceWindow = window; super.init() }
  override var type: UITouch.TouchType { .direct }
  override var tapCount: Int { 1 }
  override func location(in view: UIView?) -> CGPoint {
    guard let view, let sourceWindow else { return point }; return view.convert(point, from: sourceWindow)
  }
}

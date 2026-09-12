import NotebookCore
import UIKit
import XCTest
@testable import Notebook

@MainActor final class NotebookElementManipulationTests: XCTestCase {
  func testEveryCornerKeepsTheOppositeCornerAtLimitsAndAtDifferentScales() {
    let original = CGRect(x: 100, y: 80, width: 200, height: 160)
    let reference = EditableElementReference.page(pageID: UUID(), elementID: "chart")
    let page = CGRect(x: 0, y: 0, width: 600, height: 800)
    for corner in NotebookElementCorner.allCases {
      for delta in [CGPoint(x: 30, y: 25), .init(x: -5000, y: -5000), .init(x: 5000, y: 5000)] {
        var contact = NotebookElementManipulation(reference: reference, kind: .resize(corner), frame: original, bounds: page)
        contact.update(translation: delta)
        let result = contact.frame
        XCTAssertEqual(corner.leading ? result.maxX : result.minX, corner.leading ? original.maxX : original.minX)
        XCTAssertEqual(corner.top ? result.maxY : result.minY, corner.top ? original.maxY : original.minY)
        XCTAssertGreaterThanOrEqual(result.width, 44); XCTAssertGreaterThanOrEqual(result.height, 44)
        XCTAssertTrue(page.contains(result))
        for scale in [0.15, 1, 3] {
          let screen = original.applying(.init(scaleX: scale, y: scale))
          let projected = contact.projected(over: screen, scale: scale)
          let expected = result.applying(.init(scaleX: scale, y: scale))
          XCTAssertEqual(projected.minX, expected.minX, accuracy: 0.000001)
          XCTAssertEqual(projected.minY, expected.minY, accuracy: 0.000001)
          XCTAssertEqual(projected.width, expected.width, accuracy: 0.000001)
          XCTAssertEqual(projected.height, expected.height, accuracy: 0.000001)
        }
      }
    }
  }

  func testLateLiftAndPencilCannotCommitAnOldContact() async throws {
    try await fixture { model, reference in
      model.selectElement(reference)
      let old = try XCTUnwrap(model.beginElementManipulation(reference, kind: .resize(.topLeading)))
      model.updateElementManipulation(old, translation: .init(x: -20, y: -30))
      model.selectElement(reference)
      XCTAssertTrue(model.isPointing, "Reselecting the same element cannot drop an accepted contact")
      let pencil = UUID(); XCTAssertTrue(model.inputGate.beginPencilAction(source: pencil))
      XCTAssertNil(model.selectionSession.manipulation)
      XCTAssertFalse(model.isPointing)
      XCTAssertFalse(model.finishElementManipulation(old, translation: .init(x: -100, y: -100)))
      model.inputGate.endPencilAction(source: pencil)
      let next = try XCTUnwrap(model.beginElementManipulation(reference, kind: .resize(.bottomTrailing)))
      model.cancelElementManipulation(old)
      XCTAssertEqual(model.selectionSession.manipulation?.id, next)
      model.clearSelection()
      XCTAssertFalse(model.finishElementManipulation(next, translation: .init(x: 100, y: 100)))
      await model.finishPendingPersistence()
      XCTAssertEqual(model.activePage?.elements.first?.frame, .init(x: 100, y: 80, width: 200, height: 160))
    }
  }

  func testResizeKeepsPaperAndRejectsASupersededContact() async throws {
    try await fixture { model, reference in
      let before = try XCTUnwrap(model.activePage), camera = model.presence?.camera
      model.selectElement(reference)
      let contact = try XCTUnwrap(model.beginElementManipulation(reference, kind: .resize(.topLeading)))
      XCTAssertTrue(model.finishElementManipulation(contact, translation: .init(x: -30, y: -20)))
      await model.finishPendingPersistence()
      let page = try model.store.loadPage(before.id)
      XCTAssertEqual(page.elements.first?.frame, .init(x: 70, y: 60, width: 230, height: 180))
      XCTAssertEqual(page.elements.first?.html, before.elements.first?.html)
      XCTAssertEqual(page.drawingData, before.drawingData); XCTAssertEqual(model.presence?.camera, camera)
      let next = try XCTUnwrap(model.beginElementManipulation(reference, kind: .resize(.bottomTrailing)))
      let replacement = try XCTUnwrap(model.beginElementManipulation(reference, kind: .move))
      XCTAssertTrue(model.finishElementManipulation(replacement, translation: .init(x: 10, y: 0)))
      XCTAssertFalse(model.finishElementManipulation(next, translation: .init(x: 100, y: 100)), "A replacement contact cannot be overwritten by the old lift")
      XCTAssertEqual(model.activePage?.elements.first?.frame, .init(x: 80, y: 60, width: 230, height: 180))
    }
  }

  func testCornerCommitKeepsConcurrentAgentContentAndInk() async throws {
    try await fixture { model, reference in
      let before = try XCTUnwrap(model.activePage)
      model.selectElement(reference)
      let contact = try XCTUnwrap(model.beginElementManipulation(reference, kind: .resize(.topLeading)))
      let target = CollaborationTarget(kind: .page, id: before.id), agent = UUID(), stroke = UUID()
      let action = CollaborationAction(summary: "Update the chart while its corner is held", expected: [
        .init(target: target, revision: before.agentStamp.revision, inkRevision: before.drawingStamp.revision)
      ], operations: [
        .init(kind: .updateElement, target: target, id: "chart", values: ["html": .string("<p>Agent's new explanation</p>")]),
        .init(kind: .appendInkStroke, target: target, id: stroke.uuidString, values: ["points": .array([
          .object(["x": .number(400), "y": .number(200)]), .object(["x": .number(420), "y": .number(240)])])])
      ])
      _ = try model.store.applyCollaborationAction(action, actor: agent)
      XCTAssertTrue(model.finishElementManipulation(contact, translation: .init(x: -30, y: -20)))
      let flushed = await model.finishPendingPersistence(); XCTAssertTrue(flushed)
      let merged = try model.store.loadPage(before.id)
      XCTAssertEqual(merged.elements.first?.frame, .init(x: 70, y: 60, width: 230, height: 180))
      XCTAssertEqual(merged.elements.first?.html, "<p>Agent's new explanation</p>")
      XCTAssertTrue(try PageInkDrawing.decode(merged.drawingData).actions.contains { $0.id == stroke && $0.isActive })
    }
  }

  func testOldTextEditorCannotReleaseAnotherBoardOrANewSelection() async throws {
    try await fixture { model, _ in
      let first = EditableElementReference.spatial(boardID: UUID(), elementID: "title")
      let second = EditableElementReference.spatial(boardID: UUID(), elementID: "title")
      model.selectElement(first); let old = model.selectionSession.id
      if case .spatial(let board, let id) = second { model.interactiveElementFocus = .board(boardID: board, elementID: id) }
      model.finishInteractiveElementInput(first, selectionID: old)
      XCTAssertTrue(model.selectionSession.isInteractive)
      let current = model.selectionSession.id
      model.finishInteractiveElementInput(first, selectionID: current)
      XCTAssertTrue(model.selectionSession.isInteractive, "The same local ID on another board is not this editor")
      model.clearSelection()
      if case .spatial(let board, let id) = second { model.interactiveElementFocus = .board(boardID: board, elementID: id) }
      model.finishInteractiveElementInput(second, selectionID: current)
      XCTAssertTrue(model.selectionSession.isInteractive)
      model.finishInteractiveElementInput(second, selectionID: model.selectionSession.id)
      XCTAssertFalse(model.selectionSession.isInteractive)
    }
  }

  func testMissingElementPinsKeepTheirBoardAddress() async throws {
    try await fixture { model, _ in
      let child = try XCTUnwrap(model.createBoard(at: .zero))
      await model.finishPendingPersistence()
      let root = try XCTUnwrap(model.presence?.boardID)
      let before = try model.store.loadBoard(items: try XCTUnwrap(model.workspace).items)
      var board = before
      let element = SpatialElement(id: "same-local-id", surface: .board(root), kind: .web,
        frame: .init(x: 0, y: 0, width: 100, height: 100), worldOrigin: .zero,
        source: "chart", html: "<b>Keep me</b>", stamp: .init(counter: 0, actor: model.actorID))
      XCTAssertTrue(board.upsertElement(element, in: root, expected: nil, actor: model.actorID))
      _ = try model.store.saveBoardEdits(before: before, after: board)
      let presence = SessionPresence(boardID: root, mode: .board, camera: .init(scale: 0.2), viewport: .init(x: 834, y: 1194))
      let state = try NotebookSceneState.read(store: model.store, presence: presence, viewport: presence.viewport,
        pinnedElements: [root: [element.id], child: [element.id]])
      XCTAssertEqual(state.missingPinnedElements, [child: [element.id]])
      XCTAssertNotNil(state.hierarchy.board(root)?.elements.first { $0.id == element.id })
    }
  }

  func testCornerAdmissionLeavesPencilAndUnrelatedPaperAvailable() throws {
    let gate = NotebookInputGate()
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    let controller = UIViewController(); window.rootViewController = controller; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    let controls = NotebookElementControlsView(gate: gate)
    controls.frame = controller.view.bounds
    controls.configure(selectionID: UUID(), frame: .init(x: 100, y: 150, width: 240, height: 180))
    controller.view.addSubview(controls); controls.layoutIfNeeded()
    let corner = controls.convert(.init(x: 100, y: 150), to: window)
    XCTAssertFalse(gate.permitsSceneContact(at: corner, kind: .finger))
    XCTAssertTrue(gate.permitsSceneContact(at: corner, kind: .pencil))
    XCTAssertTrue(gate.permitsSceneContact(at: controls.convert(.init(x: 220, y: 220), to: window), kind: .finger))
    let corners = (controls.accessibilityElements ?? []).compactMap { $0 as? UIAccessibilityElement }
    XCTAssertEqual(corners.count, 4)
    for corner in corners { XCTAssertEqual(corner.accessibilityFrameInContainerSpace.size, .init(width: 44, height: 44)) }
    for edgeFrame in [CGRect(x: 0, y: 0, width: 240, height: 180), controls.bounds.insetBy(dx: 2, dy: 2)] {
      controls.configure(selectionID: UUID(), frame: edgeFrame); controls.layoutIfNeeded()
      for corner in NotebookElementCorner.allCases {
        let point = controls.convert(corner.point(in: edgeFrame), to: window)
        XCTAssertTrue(window.hitTest(point, with: nil) === controls, "A screen edge cannot hide a corner under delete")
        XCTAssertTrue(gate.permitsSceneContact(at: point, kind: .pencil))
      }
    }
    controls.removeFromSuperview()
    XCTAssertTrue(gate.permitsSceneContact(at: corner, kind: .finger))
  }

  private func fixture(_ body: (NotebookAppModel, EditableElementReference) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize); await model.finishPendingPersistence()
    var page = try XCTUnwrap(model.activePage)
    page.replaceElements([.init(id: "chart", kind: .web, frame: .init(x: 100, y: 80, width: 200, height: 160), source: "source", html: "<p>Same material</p>")], actor: model.actorID)
    try model.store.savePage(page); await model.reloadExternalChanges()?.value
    try await body(model, .page(pageID: page.id, elementID: "chart"))
  }
}

import Foundation
import Testing
@testable import NotebookCore

@Suite("Scene dependencies follow actual addressed resolution")
struct NotebookSceneReadDependencyTests {
  private func fixture(_ body: (NotebookStore, UUID, CollaborationTarget) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    let header = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    try body(store, actor, .init(kind: .board, id: header.rootBoardID))
  }

  @Test func offscreenEndpointAndParentPoseBelongToTheBorrowedConnector() throws {
    try fixture { store, actor, target in
      func source(_ id: String) throws -> NotebookNativeElementSource {
        try .init(target: target, id: id, spatial: store.readSpatialElement(boardID: target.id, elementID: id))
      }
      func apply(_ edits: [CollaborationOperation]) throws {
        _ = try store.applyNativeElementEdits(edits, summary: "Scene witness regression", sources: edits.map { try source($0.id!) }, actor: actor)
      }
      let initial = try ["a", "b", "unseen"].enumerated().map { index, id in
        CollaborationOperation(kind: .insertElement, target: target, id: id, values: ["kind": .string("graphic"), "source": .string(""),
          "frame": try .encode(PageRect(x: Double(index) * 50, y: 0, width: 30, height: 30)), "worldOrigin": try .encode(WorldPoint.zero),
          "graphic": try .encode(NotebookGraphic(shape: .rectangle))])
      }
      try apply(initial)
      _ = try store.groupNativeElements([source("a"), source("b")], id: "whole", actor: actor)
      let connection = NotebookGraphicConnection(start: .init(point: .zero, binding: .init(elementID: "a")),
        end: .init(point: .zero, binding: .init(elementID: "b")))
      try apply([.init(kind: .insertElement, target: target, id: "edge", values: ["kind": .string("graphic"), "source": .string(""),
        "frame": try .encode(PageRect(x: 0, y: 0, width: 10, height: 10)), "worldOrigin": try .encode(WorldPoint.zero),
        "graphic": try .encode(NotebookGraphic(shape: .connector, connection: connection))])])
      let captured = try store.readRecordingSceneRecords { try store.readGraphicResolution(target: target, elementID: "edge") }
      #expect(captured.value.layout != nil)
      #expect(try captured.dependencies.isCurrent(store))
      try apply([.init(kind: .updateElement, target: target, id: "unseen", values: ["source": .string("Other source")])])
      #expect(try captured.dependencies.isCurrent(store), "Board container clocks are not the visible endpoint")
      try apply([.init(kind: .updateElement, target: target, id: "whole", values: ["frame": try .encode(PageRect(x: 500, y: 0, width: 80, height: 30))])])
      #expect(try !captured.dependencies.isCurrent(store), "The resolver really borrowed the shared parent placement")
      let next = try store.readRecordingSceneRecords { try store.readGraphicResolution(target: target, elementID: "edge") }
      try apply([.init(kind: .updateElement, target: target, id: "b", values: ["frame": try .encode(PageRect(x: 100, y: 0, width: 30, height: 30))])])
      #expect(try !next.dependencies.isCurrent(store))
    }
  }

  @Test func anEmptyClaimQueryDetectsANewOffscreenGraphicWinner() throws {
    try fixture { store, actor, target in
      let id = UUID(), surface = SurfaceID.board(target.id)
      let action = SpatialInkAction(id: id, tool: .pen, spans: [.init(surface: surface, samples: [
        .init(point: .init(x: 10, y: 10), worldPoint: .init(x: 10, y: 10), timeOffset: 0, width: 3, opacity: 1, force: 1, azimuth: 0, altitude: 1)
      ])], stamp: .init(counter: 1, actor: actor))
      _ = try store.commitSpatialInk(.append(action, journalStamp: action.stamp))
      let empty = try store.readRecordingSceneRecords { try store.graphicPresentation(on: surface, sourceInkIDs: [id]) }
      #expect(empty.value.suppressedInkIDs.isEmpty)
      let shape = NotebookGraphic(shape: .rectangle, sourceInkIDs: [id])
      let edit = CollaborationOperation(kind: .convertInkToElement, target: target, id: "claim", values: ["kind": .string("graphic"), "source": .string(""),
        "frame": try .encode(PageRect(x: 50_000, y: 0, width: 30, height: 30)), "worldOrigin": try .encode(WorldPoint.zero), "graphic": try .encode(shape)])
      _ = try store.applyNativeElementEdits([edit], summary: "Offscreen claim", sources: [.init(target: target, id: "claim")], actor: actor)
      #expect(try !empty.dependencies.isCurrent(store), "Absence, not only previously returned records, is part of the witness")
      let accepted = try store.readRecordingSceneRecords { try store.graphicPresentation(on: surface, sourceInkIDs: [id]) }
      #expect(accepted.value.suppressedInkIDs == [id])
      #expect(try accepted.dependencies.isCurrent(store))
    }
  }
}

import Foundation
import Testing
@testable import NotebookCore

@Suite("Erasure appearance in addressed and incremental reads", .serialized)
struct NotebookObservationAppearanceTests {
  @Test(arguments: [false, true])
  func erasureLeavesAuthoredContentAddressableButExitsImplicitObservation(board: Bool) throws {
    let f = try NotebookObservationReadTests.Fixture()
    let boardID = try f.store.workspaceHeader().rootBoardID
    let target = board ? CollaborationTarget(kind: .board, id: boardID) : f.target
    let surface: SurfaceID = board ? .board(boardID) : .page(f.pageID)
    let frame = PageRect(x: 0, y: 0, width: 100, height: 100)
    if board {
      let revision = try f.store.targetContentRevision(target: target)
      _ = try f.store.applyCollaborationAction(.init(summary: "Element", references: [.init(target: target, revision: revision)],
        expected: [.init(target: target, revision: revision)], operations: [.init(kind: .insertElement, target: target, id: "box",
          values: ["kind": .string("markdown"), "source": .string("authored"), "frame": try .encode(frame), "worldOrigin": try .encode(WorldPoint.zero)])]), actor: f.actor)
    } else { try f.put("box", source: "authored"); try f.put("unrelated"); try f.store.savePage(f.store.loadPage(f.pageID)) }
    let scope = NotebookObservationScope(target: target)
    let first = try f.store.observeContent(scope: scope)
    let sample = SpatialInkSample(point: .init(x: 50, y: 50), timeOffset: 0, width: 400, opacity: 1, force: 1, azimuth: 0, altitude: 1)
    let cut = InkElementTarget(elementID: "box", frame: frame, worldOrigin: board ? .zero : nil)
    let stamp = VersionStamp(counter: 100, actor: f.actor), id = UUID()
    if board {
      let spatialSample = SpatialInkSample(point: sample.point, worldPoint: .init(x: 50, y: 50), timeOffset: 0,
        width: 400, opacity: 1, force: 1, azimuth: 0, altitude: 1)
      let action = SpatialInkAction(id: id, tool: .eraser,
        spans: [SpatialInkSpan(surface: surface, samples: [spatialSample]).erasingElements([cut])], stamp: stamp)
      try f.store.commitSpatialInk(.append(action, journalStamp: stamp))
    } else {
      var page = try f.store.loadPage(f.pageID)
      let change = try page.prepareInkChange(.append(PageInkAction(id: id, tool: .eraser, samples: [sample]).erasingElements([cut])), stamp: stamp)
      let changed = page.publishInkChange(change); #expect(changed); try f.store.savePage(page)
    }
    let delta = try f.store.observeContent(scope: scope, since: first.checkpoint)
    #expect(delta.objects.map(\.id) == ["box"])
    #expect(delta.objects.first?.change == .outOfScope)
    let addressed = try f.store.observeContent(scope: .init(target: target, ids: ["box"], fields: [.content]))
    #expect(addressed.objects.first?.value?["content"]?["source"] == .string("authored"))
    #expect(addressed.objects.first?.value?["appearance"]?["state"] == .string("erased"))
    #expect(addressed.objects.first?.value?["appearance"]?["sourceIsCompleteAppearance"] == .bool(false))
    if !board {
      #expect(try f.store.readPageElementSnapshot(pageID: f.pageID, elementID: "box")?.appearance["state"] == .string("erased"))
    }
    let undoStamp = VersionStamp(counter: 101, actor: f.actor)
    if board {
      try f.store.commitSpatialInk(.state(actionID: id, creationStamp: stamp, isActive: false, stateStamp: undoStamp, journalStamp: undoStamp))
    } else {
      var page = try f.store.loadPage(f.pageID)
      let change = try page.prepareInkChange(.remove([id]), stamp: undoStamp)
      let changed = page.publishInkChange(change); #expect(changed); try f.store.savePage(page)
    }
    let restored = try f.store.observeContent(scope: scope, since: delta.checkpoint)
    #expect(restored.objects.first { $0.id == "box" }?.change == .upsert)
    #expect(restored.objects.first { $0.id == "box" }?.value?["appearance"]?["state"] == .string("intact"))
  }
}

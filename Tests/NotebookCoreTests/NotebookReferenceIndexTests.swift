import Foundation
import Testing
@testable import NotebookCore

@Suite("Addressed reference identities")
struct NotebookReferenceIndexTests {
  @Test func physicalOwnerTokensMatchCompleteSnapshotsAndBindPartialSources() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    let header = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    let item = try #require(try store.readItemHeaders(limit: 1).first)
    let targets = [CollaborationTarget(kind: .board, id: header.rootBoardID), .init(kind: .cover, id: item.id, boardID: header.rootBoardID)]
    let complete = try store.collaborationSnapshot()
    for target in targets {
      let expected = try store.referenceRevision(target: target)
      #expect(try NotebookStore.referenceRevision(target: target, files: complete) == expected)
      let partial = try store.referenceSourceFiles(target: target)
      #expect(partial["spatial-ink.json"] == nil)
      #expect(try NotebookStore.referenceRevision(target: target, files: partial) == expected)
      var changed = partial
      changed["board.json"] = changed["board.json"]?.setting("changed", .bool(true))
      #expect(throws: CollaborationError.self) { try NotebookStore.referenceRevision(target: target, files: changed) }
    }
    let before = try store.referenceIdentities(targets: targets)
    #expect(try store.moveWorkspaceItem(itemID: item.id, in: header.rootBoardID, to: .init(x: 4000, y: 5000), actor: actor))
    let after = try store.referenceIdentities(targets: targets)
    #expect(before[0].revision != after[0].revision)
    #expect(before[1] == after[1])
    let window = try store.readSceneWindow(boardID: header.rootBoardID, bounds: .init(origin: .zero, width: 10, height: 10), pinnedIDs: [item.id])
    #expect(Set(window.referenceIdentities.map(\.target)) == Set(targets))
    for target in targets { #expect(try store.referenceRevision(target: target) == NotebookStore.referenceRevision(target: target, files: store.collaborationSnapshot())) }
  }
  @Test func CoverOrderAndRegionalPixelsUseTheSamePagedSourceCut() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    let header = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    let item = try #require(try store.readItemHeaders(limit: 1).first), target = CollaborationTarget(kind: .cover, id: item.id, boardID: header.rootBoardID)
    let before = try store.loadBoard(items: [item.item])
    var after = before
    let ids = (0..<40).map { "element-" + String(format: "%03d", $0) }
    for id in ids {
      _ = after.upsertElement(.init(id: id, surface: .cover(item.id), kind: .nativeText, frame: .init(x: 10, y: 20, width: 40, height: 40), source: id, stamp: .init(counter: 0, actor: actor)), in: header.rootBoardID, expected: nil, actor: actor)
    }
    _ = try store.saveBoardEdits(before: before, after: after)
    let first = try store.referenceRevision(target: target)
    let region = PageRect(x: 0, y: 0, width: 100, height: 100)
    let request = try store.requestTargetRender(target: target, expectedRevision: store.targetContentRevision(target: target), region: region)
    let streamed = try store.regionalFingerprint(request, inkFingerprint: "final-raster-pixels")
    #expect(try streamed == NotebookStore.regionalFingerprint(request, inkFingerprint: "final-raster-pixels", files: store.collaborationSnapshot()))
    let action = CollaborationAction(additionalOwners: [target], summary: "Reverse the visible overlap", expected: [.init(target: target, revision: try store.targetContentRevision(target: target))],
      operations: [.init(kind: .reorderElements, target: target, values: ["ids": .array(ids.reversed().map(JSONValue.string))])])
    _ = try store.applyCollaborationAction(action, actor: actor)
    #expect(try store.referenceRevision(target: target) != first)
    #expect(try store.referenceRevision(target: target) == NotebookStore.referenceRevision(target: target, files: store.collaborationSnapshot()))
    #expect(throws: CollaborationError.self) { try store.regionalFingerprint(request, inkFingerprint: "final-raster-pixels") }
    let changed = try store.requestTargetRender(target: target, expectedRevision: store.targetContentRevision(target: target), region: region)
    #expect(try store.regionalFingerprint(changed, inkFingerprint: "final-raster-pixels") != streamed)
    let firstPage = try store.targetRenderRequests(target: target, limit: 1)
    #expect(firstPage.count == 1)
    let secondPage = try store.targetRenderRequests(target: target, afterID: firstPage[0].id, limit: 1)
    #expect(secondPage.count == 1 && secondPage[0].id != firstPage[0].id)
    #expect(try store.targetRenderRequests(target: target, afterID: secondPage[0].id, limit: 1).isEmpty)
    _ = try store.updateNativeSpatialText(boardID: header.rootBoardID, elementID: ids[20], text: "", finish: true, actor: actor)
    #expect(try store.referenceRevision(target: target) == NotebookStore.referenceRevision(target: target, files: store.collaborationSnapshot()))
  }

}

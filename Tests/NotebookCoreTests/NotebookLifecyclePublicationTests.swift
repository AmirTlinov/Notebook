import Foundation
import Testing
@testable import NotebookCore

@Suite("Lifecycle publication retains the completed physical owner cut", .serialized)
struct NotebookLifecyclePublicationTests {
  @Test func appendPublishesTheActualPageInkAndCompletePostItemBasis() throws {
    let f = try NotebookItemLifecycleTests.Fixture()
    let extent = try #require(try f.store.readItemLifecycle(f.itemID)), pageID = UUID()
    let workspace = CollaborationTarget(kind: .workspace, id: try f.store.workspaceHeader().rootBoardID)
    let base = try f.store.readBasis(targets: [workspace, extent.target])
    let action = CollaborationAction(summary: "Post append owners", expected: base.owners, operations: [
      .init(kind: .appendPage, target: extent.target, id: pageID.uuidString, values: [:])])
    let receipt = try f.store.applyCollaborationAction(action, actor: f.actor)
    let post = try #require(try f.store.readItemLifecycle(f.itemID))
    let page = CollaborationTarget(kind: .page, id: pageID)
    let header = try f.store.readContentHeader(target: page)
    #expect(receipt.revisions.first { $0.target == extent.target }?.lifecycleRevision == post.revision)
    #expect(receipt.revisions.first { $0.target == page }?.inkRevision == header.inkStamp?.revision)
    let result = try #require(try f.store.savedActionResult(receipt.id))
    let resultBasis = try #require(try result["basis"]?.decode(NotebookReadBasis.self))
    #expect(resultBasis.owners == receipt.revisions)
    let stroke = CollaborationOperation(kind: .appendInkStroke, target: page, id: UUID().uuidString,
      values: ["points": .array([.object(["x": .number(10), "y": .number(10)])])])
    let expected = try f.store.expectations(base: resultBasis, operations: [stroke])
    _ = try f.store.applyCollaborationAction(.init(summary: "Use completed birth without another read", expected: expected, operations: [stroke]), actor: f.actor)
    #expect(try PageInkDrawing.decode(f.store.loadPage(pageID).drawingData).actions.count == 1)
    #expect(try f.store.savedActionResult(receipt.id) == result,
      "A later first stroke does not refresh the original append result")
  }
}

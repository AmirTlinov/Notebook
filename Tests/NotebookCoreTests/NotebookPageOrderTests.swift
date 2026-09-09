import Foundation
import Testing
@testable import NotebookCore

@Suite("An authored page order survives derived merge and replay")
struct NotebookPageOrderTests {
  private let actorA = UUID(uuidString: "00000000-0000-4000-8000-000000000011")!
  private let actorB = UUID(uuidString: "00000000-0000-4000-8000-000000000022")!
  private let actorC = UUID(uuidString: "00000000-0000-4000-8000-000000000033")!

  private func changed(_ index: WorkspaceIndex, pages: [UUID], actor: UUID, human: Bool = true) throws -> WorkspaceIndex {
    let item = index.selectedItem
    let value = try JSONValue.encode(index).setting("stamp", .encode(index.stamp.advanced(by: actor)!))
      .setting("items", .array([JSONValue.encode(item).setting("pageIDs", .encode(pages))]))
    var next = try value.decode(WorkspaceIndex.self)
    try next.recordChanges(from: index, human: human)
    return next
  }

  @Test func pureMergeRetainsOriginalHeadsThroughEchoAppendReorderAndRemoval() throws {
    let base = WorkspaceIndex.initial(actor: actorA, pageSize: .init(width: 834, height: 1194)).index
    let first = base.selectedPageID!, a1 = UUID(), a2 = UUID(), b1 = UUID(), b2 = UUID()
    let a = try changed(changed(base, pages: [first, a1], actor: actorA), pages: [first, a1, a2], actor: actorA)
    let b = try changed(changed(base, pages: [first, b1], actor: actorB), pages: [first, b1, b2], actor: actorB)
    let left = try a.merging(b), right = try b.merging(a)
    let id = base.selectedItemID.uuidString.lowercased()
    #expect(left.selectedItem.pageIDs == [first, b1, b2] + [a1, a2].sorted { $0.uuidString < $1.uuidString })
    #expect(left.pageOrders[id] == right.pageOrders[id])
    #expect(try JSONValue.encode(left).decode(WorkspaceIndex.self).pageOrders == left.pageOrders)
    let echoed = try left.merging(a).merging(b).merging(right)
    #expect(echoed.pageOrders == left.pageOrders)
    #expect(echoed.selectedItem.pageIDs == left.selectedItem.pageIDs)

    var landed = left
    let selection = landed.selectPage(at: left.selectedItem.pageIDs.count, in: left.selectedItemID,
      actor: actorC, pageSize: .init(width: 834, height: 1194))
    let landing = try #require(selection)
    let appended = try landed.merging(a).merging(b)
    #expect(appended.selectedItem.pageIDs == left.selectedItem.pageIDs + [landing.pageID])
    #expect(appended.pageOrders[id]?.heads.count == 1)
    let reorder = try changed(appended, pages: appended.selectedItem.pageIDs.reversed(), actor: actorC, human: false)
    #expect(try reorder.merging(left).selectedItem.pageIDs == reorder.selectedItem.pageIDs)
    let removed = try changed(reorder, pages: reorder.selectedItem.pageIDs.filter { $0 != a1 }, actor: actorC)
    let mergedRemoval = try removed.merging(a).merging(b).merging(reorder)
    #expect(mergedRemoval.selectedItem.pageIDs == removed.selectedItem.pageIDs)
    #expect(mergedRemoval.pageOrders[id] == removed.pageOrders[id])
  }

  @Test func causalPruningPrecedesHumanPreferenceAndIsAssociative() throws {
    let page = UUID(), a = UUID(), b = UUID(), c = UUID()
    var nodes: [String: NotebookPageOrderNode] = [:]
    func root(_ pages: [UUID]) throws -> String {
      try NotebookPageOrderVector.build(pages) { node in let hash = try node.hash; nodes[hash] = node; return hash }
    }
    let initial = try NotebookPageOrderRegister.authored(root: root([page]), stamp: .init(counter: 0, actor: actorA), human: true, previous: nil)
    let aHead = try NotebookPageOrderRegister.authored(root: root([page, a]), stamp: .init(counter: 2, actor: actorA), human: true, previous: initial)
    let bHead = try NotebookPageOrderRegister.authored(root: root([page, a, b]), stamp: .init(counter: 3, actor: actorB), human: false, previous: aHead)
    let cHead = try NotebookPageOrderRegister.authored(root: root([page, c]), stamp: .init(counter: 1, actor: actorC), human: true, previous: initial)
    func merge(_ inputs: [NotebookPageOrderRegister]) throws -> NotebookPageOrderRegister {
      let result = try NotebookPageOrderRegister.normalize(inputs, live: [page, a, b, c],
        read: { hash in guard let node = nodes[hash] else { throw NotebookStorageError.blobMissing(hash) }; return node },
        write: { node in let hash = try node.hash; nodes[hash] = node; return hash })
      return result.register
    }
    let left = try merge([merge([aHead, cHead]), bHead])
    let right = try merge([aHead, merge([bHead, cHead])])
    #expect(left == right)
    #expect(left.heads.count == 2)
    #expect(left.winner == cHead.winner)
  }

  @Test func validNodesCannotInventAnUnauthoredVisiblePermutation() throws {
    let first = UUID(), second = UUID(), itemID = UUID()
    let base = WorkspaceIndex(items: [.notebook(id: itemID, title: "", pageIDs: [first, second])],
      selectedItemID: itemID, selectedPageID: first, stamp: .init(counter: 0, actor: actorA))
    var nodes = base.pageOrderNodes
    let reverseRoot = try NotebookPageOrderVector.build([second, first]) { node in
      let hash = try node.hash; nodes[hash] = node; return hash
    }
    let key = itemID.uuidString.lowercased(), previous = try #require(base.pageOrders[key])
    var forged = try JSONValue.encode(base).setting("items", .encode([WorkspaceItem.notebook(id: itemID, title: "", pageIDs: [second, first])])).decode(WorkspaceIndex.self)
    forged.pageOrderNodes = nodes
    forged.pageOrders[key] = .init(heads: previous.heads, visibleRoot: reverseRoot)
    #expect(throws: NotebookStorageError.invalidTransaction("unauthored visible page order")) { try forged.validatePageOrderWitness() }
    #expect(throws: NotebookStorageError.invalidTransaction("unauthored visible page order")) { try forged.merging(forged) }
  }

  @Test func oneDotCannotNameDifferentValuesOrContexts() throws {
    // A hash and actor/counter are contracts, not an arbitrary tie breaker.
    let version = ContentFieldVersion(stamp: .init(counter: 3, actor: actorA), human: true)
    let a = NotebookPageOrderHead(version: version, valueRoot: String(repeating: "a", count: 64))
    let b = NotebookPageOrderHead(version: version, valueRoot: String(repeating: "b", count: 64))
    #expect(throws: NotebookStorageError.transactionConflict) { try NotebookPageOrderRegister.frontier([a, b]) }
    let differentContext = ContentFieldVersion(stamp: version.stamp, human: true,
      observed: [actorA.uuidString.lowercased(): 3, actorB.uuidString.lowercased(): 1])
    #expect(throws: NotebookStorageError.transactionConflict) {
      try NotebookPageOrderRegister.frontier([a, .init(version: differentContext, valueRoot: a.valueRoot)])
    }
    let register = NotebookPageOrderRegister(heads: [a], visibleRoot: a.valueRoot)
    #expect(throws: NotebookStorageError.transactionConflict) {
      try NotebookPageOrderRegister.authored(root: a.valueRoot, stamp: .init(counter: 2, actor: actorA), human: true, previous: register)
    }
    let aliasActor = UUID(uuidString: "ABCDEFAB-0000-4000-8000-000000000011")!
    let uppercase = ContentFieldVersion(stamp: .init(counter: 3, actor: aliasActor), human: true, observed: [aliasActor.uuidString.uppercased(): 3])
    let raw = try JSONValue.encode(NotebookPageOrderRegister(heads: [.init(version: uppercase, valueRoot: a.valueRoot)], visibleRoot: a.valueRoot))
    #expect(throws: (any Error).self) { try raw.decode(NotebookPageOrderRegister.self).validate() }
  }

  @Test func projectionIsNotACanonicalMergeInputAndDoesNotFetchOtherNotebooks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-order-projection-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root)
    _ = try store.initializeWorkspace(actor: actorA, pageSize: .init(width: 834, height: 1194))
    let complete = try store.loadIndex()
    let projection = try store.workspaceProjection(items: [complete.selectedItem], selectedItemID: complete.selectedItemID, selectedPageID: complete.selectedPageID)
    #expect(projection.isProjection)
    #expect(projection.pageOrderNodes.count == 1)
    #expect(throws: (any Error).self) { try complete.merging(projection) }
    #expect(throws: (any Error).self) { try projection.validatePageOrderWitness() }
    #expect(try JSONValue.encode(projection).decode(WorkspaceIndex.self).isProjection)
  }
}

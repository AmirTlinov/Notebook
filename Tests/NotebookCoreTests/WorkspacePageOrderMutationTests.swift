import Foundation
import Testing
@testable import NotebookCore

@Suite("Workspace page-order mutations retain canonical values without copying unrelated nodes")
struct WorkspacePageOrderMutationTests {
  private let actor = UUID(uuidString: "00000000-0000-4000-8000-000000000041")!
  private let pageSize = PageSize(width: 834, height: 1194)

  @Test func largeConstructorProducesTheExactCanonicalOrderWitness() throws {
    let stamp = VersionStamp(counter: 0, actor: actor)
    let items = (0..<4_096).map { index in
      WorkspaceItem.notebook(title: "Notebook \(index)",
        pageIDs: (0..<(index.isMultiple(of: 257) ? 33 : 1)).map { _ in UUID() })
    }
    var expectedNodes: [String: NotebookPageOrderNode] = [:]
    var expectedOrders: [String: NotebookPageOrderRegister] = [:]
    for item in items {
      let root = try NotebookPageOrderVector.build(item.pageIDs) { node in
        let hash = try node.hash; expectedNodes[hash] = node; return hash
      }
      expectedOrders[item.id.uuidString.lowercased()] = try .authored(root: root, stamp: stamp, human: true, previous: nil)
    }
    let workspace = WorkspaceIndex(items: items, selectedItemID: items[0].id,
      selectedPageID: items[0].pageIDs[0], stamp: stamp)
    #expect(workspace.items == items)
    #expect(workspace.pageOrders == expectedOrders)
    #expect(workspace.pageOrderNodes == expectedNodes)
    #expect(workspace.stamp == stamp)
    #expect(workspace.selectedItemID == items[0].id)
    #expect(workspace.selectedPageID == items[0].pageIDs[0])
    try workspace.validatePageOrderWitness()
    #expect(try JSONValue.encode(workspace).decode(WorkspaceIndex.self) == workspace)
  }

  @Test func appendPreservesOtherOrdersAndItsPreviousValueThenRepeatedSelectionIsANoop() throws {
    let items = (0..<64).map { _ in WorkspaceItem.notebook(title: "", pageIDs: (0..<33).map { _ in UUID() }) }
    let original = WorkspaceIndex(items: items, selectedItemID: items[0].id,
      selectedPageID: items[0].pageIDs[0], stamp: .init(counter: 0, actor: actor))
    var workspace = original
    let selected = workspace.selectPage(at: 33, in: items[0].id, actor: actor, pageSize: pageSize)
    let result = try #require(selected)
    let created = try #require(result.createdPage)
    #expect(result.pageID == created.id && result.pageIndex == 33 && result.itemID == items[0].id)
    #expect(workspace.selectedItem.pageIDs == items[0].pageIDs + [created.id])
    #expect(workspace.selectedPageID == created.id)
    #expect(workspace.stamp == original.stamp.advanced(by: actor))
    for item in items.dropFirst() {
      #expect(workspace.item(id: item.id) == item)
      #expect(workspace.pageOrders[item.id.uuidString.lowercased()] == original.pageOrders[item.id.uuidString.lowercased()])
    }
    for (hash, node) in original.pageOrderNodes { #expect(workspace.pageOrderNodes[hash] == node) }
    #expect(original.items == items)
    #expect(original.selectedPageID == items[0].pageIDs[0])
    let appended = workspace
    #expect(workspace.selectPage(at: 33, in: items[0].id, actor: actor, pageSize: pageSize) == nil)
    #expect(workspace == appended)
    let selectedPrevious = workspace.selectPage(at: 32, in: items[0].id, actor: actor, pageSize: pageSize)
    let previous = try #require(selectedPrevious)
    #expect(previous.createdPage == nil && previous.pageID == items[0].pageIDs[32])
    #expect(workspace.pageOrderNodes == appended.pageOrderNodes && workspace.pageOrders == appended.pageOrders)
    #expect(workspace.stamp == appended.stamp)
    let selectedNext = workspace.selectPage(at: 33, in: items[0].id, actor: actor, pageSize: pageSize)
    let next = try #require(selectedNext)
    #expect(next.createdPage == nil && next.pageID == created.id)
    #expect(workspace == appended)
    try workspace.validatePageOrderWitness()
  }

  @Test func duplicatePageCreationLeavesTheCatalogAndItsWitnessUnchanged() {
    var workspace = WorkspaceIndex.initial(actor: actor, pageSize: pageSize).index
    let before = workspace
    #expect(workspace.createNotebook(title: "Duplicate page", actor: actor, pageSize: pageSize,
      itemID: UUID(), pageID: workspace.selectedPageID!) == nil)
    #expect(workspace == before)
  }

  @Test func appendAuthoredConflictDoesNotPublishNodesMembershipSelectionOrClock() throws {
    var workspace = WorkspaceIndex.initial(actor: actor, pageSize: pageSize).index
    let key = workspace.selectedItemID.uuidString.lowercased()
    let previous = try #require(workspace.pageOrders[key])
    workspace.pageOrders[key] = try .authored(root: previous.visibleRoot,
      stamp: .init(counter: 5, actor: actor), human: true, previous: previous)
    let before = workspace
    #expect(workspace.selectPage(at: 1, in: workspace.selectedItemID, actor: actor, pageSize: pageSize) == nil)
    #expect(workspace == before, "The new vector nodes remain private until the authored register succeeds")
  }

  @Test func changedOrderAuthoredConflictDoesNotLeakItsStagedNodes() throws {
    let base = WorkspaceIndex.initial(actor: actor, pageSize: pageSize).index
    let changed = WorkspaceItem.notebook(id: base.selectedItemID, title: "",
      pageIDs: base.selectedItem.pageIDs + [UUID()])
    // Keeping the old clock deliberately makes the next authored order fail
    // after vector construction, not before its node writes are exercised.
    var workspace = try JSONValue.encode(base).setting("items", .encode([changed])).decode(WorkspaceIndex.self)
    let beforeItems = workspace.items, beforeStamp = workspace.stamp
    #expect(throws: NotebookStorageError.transactionConflict) { try workspace.recordChanges(from: base, human: true) }
    #expect(workspace.pageOrderNodes == base.pageOrderNodes)
    #expect(workspace.pageOrders == base.pageOrders)
    #expect(workspace.items == beforeItems && workspace.stamp == beforeStamp)
    #expect(workspace.selectedPageID == base.selectedPageID)
  }

}

import Foundation
import Testing
@testable import NotebookCore

@Suite("Workspace page-order mutations retain canonical values without copying unrelated nodes")
struct WorkspacePageOrderMutationTests {
  private let actor = UUID(uuidString: "00000000-0000-4000-8000-000000000041")!
  private let pageSize = PageSize(width: 834, height: 1194)

  @Test func preparedPageAddsOnlyItsWitnessToTheCurrentProjection() throws {
    let fixture = try PageWindowFixture(count: 8); defer { fixture.clean() }
    let store = fixture.store, id = fixture.itemID
    func projection(_ pages: [UUID], title: String) throws -> WorkspaceIndex {
      try store.workspaceProjection(items: [.notebook(id: id, title: title, pageIDs: pages)],
        selectedItemID: id, selectedPageID: pages[0])
    }
    let prepared = try projection([fixture.pages[6]], title: "Old title")
    var current = try projection([fixture.pages[0], fixture.pages[1]], title: "Current title")
    let selected = current.selectItem(id, pageID: fixture.pages[1], actor: fixture.actor); #expect(selected)
    let before = current
    try current.includePageProjection(prepared, pageID: fixture.pages[6], in: id)
    #expect(current.selectedPageID == fixture.pages[1] && current.selectedItemID == id)
    #expect(current.selectedItem.title == "Current title")
    #expect(current.selectedItem.pageIDs == before.selectedItem.pageIDs + [fixture.pages[6]])
    #expect(current.stamp == before.stamp && current.pageOrders == before.pageOrders)
    #expect(current.pageOrderNodes == before.pageOrderNodes)
    #expect(current.collaboration.fields.count == before.collaboration.fields.count + 1)
    for (key, value) in before.collaboration.fields { #expect(current.collaboration.fields[key] == value) }
    let included = current
    try current.includePageProjection(prepared, pageID: fixture.pages[6], in: id)
    #expect(current == included)
    let key = fieldKey(["items", id.uuidString.lowercased(), "pageIDs", fixture.pages[6].uuidString.lowercased()])
    try store.commandTransaction {
      let address = "workspace.json#/collaboration/fields/@" + fieldKey([key])
      let fragment = try #require(try store.storedFragments(address: address, descendants: false).first)
      let birth = try fragment.value.decode(ContentFieldVersion.self)
      let updated = ContentFieldVersion(stamp: .init(counter: birth.stamp.counter + 1, actor: fixture.actor),
        human: true, previous: birth)
      try store.writeFragment(fragment.replacing(value: .encode(updated)), database: store.currentSQL!)
    }
    let newWitness = try projection([fixture.pages[6]], title: "Still not the current title")
    #expect(newWitness.collaboration.fields[key] != included.collaboration.fields[key])
    try current.includePageProjection(newWitness, pageID: fixture.pages[6], in: id)
    #expect(current.collaboration.fields[key] == newWitness.collaboration.fields[key],
      "An already represented UUID must still receive the validated current birth witness")
    #expect(current.items == included.items && current.selectedPageID == included.selectedPageID)
    let refreshed = current
    try fixture.reordered(Array(fixture.pages.reversed()))
    let reordered = try projection([fixture.pages[7]], title: "New order")
    #expect(throws: NotebookStorageError.transactionConflict) {
      try current.includePageProjection(reordered, pageID: fixture.pages[7], in: id)
    }
    #expect(current == refreshed, "A stale order cannot admit a differently interpreted slot")
  }

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

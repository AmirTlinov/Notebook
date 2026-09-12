import Foundation
import Testing
@testable import NotebookCore

@Suite("Conflicting placements cannot replace independent board content")
struct BoardMergeOwnershipTests {
  private let localActor = UUID(uuidString: "FFFFFFFF-FFFF-4FFF-8FFF-FFFFFFFFFFFF")!
  private let remoteActor = UUID(uuidString: "00000001-0000-4000-8000-000000000001")!

  @Test func placementObservationAcknowledgesAuthoredHeadsNotAnUnrelatedClock() throws {
    let id = UUID()
    let a = try WorkspacePlacement.authored(itemID: id, pose: .init(center: .zero, zIndex: 0),
      stamp: .init(counter: 0, actor: localActor), human: true, previous: nil)
    let b = try WorkspacePlacement.authored(itemID: id, pose: .init(center: .init(x: 100, y: 200), zIndex: 1),
      stamp: .init(counter: 10, actor: remoteActor), human: true, previous: nil)
    #expect(!b.hasObserved(a), "An absent actor is not an observation of its counter zero")
    #expect(!a.hasObserved(b))
    let merged = try a.merging(b)
    #expect(merged.hasObserved(a) && merged.hasObserved(b))
    let next = try WorkspacePlacement.authored(itemID: id, pose: b.pose,
      stamp: .init(counter: 11, actor: remoteActor), human: true, previous: merged)
    #expect(next.hasObserved(merged))
    #expect(!merged.hasObserved(next))
    let otherItem = try WorkspacePlacement.authored(itemID: UUID(), pose: next.pose,
      stamp: .init(counter: 12, actor: remoteActor), human: true, previous: nil)
    #expect(!otherItem.hasObserved(next))
  }

  @Test(arguments: [false, true], [false, true])
  func aBoardTransferKeepsOneAddressedOwnerInEitherRowOrder(childSortsFirst: Bool, fromStack: Bool) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let local = NotebookStore(root: root.appendingPathComponent("local"))
    let remote = NotebookStore(root: root.appendingPathComponent("remote"))
    let header = try local.initializeWorkspace(actor: localActor, pageSize: .init(width: 834, height: 1194))
    var index = try local.loadIndex(), tree = try local.loadBoard(items: index.items)
    let itemID = index.selectedItemID
    let childID = UUID(uuidString: childSortsFirst
      ? "00000001-0000-4000-8000-000000000002" : "FFFFFFFF-FFFF-4FFF-8FFF-FFFFFFFFFFFE")!
    let portal = index.createBoard(title: "Child", actor: localActor, boardID: childID)
    _ = try #require(portal)
    let created = tree.createBoard(childID, in: header.rootBoardID, near: .init(x: 1_000, y: 1_000), actor: localActor)
    #expect(created)
    if fromStack {
      let stacked = tree.createStack(moving: itemID, onto: childID, in: header.rootBoardID, actor: localActor)
      _ = try #require(stacked)
    }
    try local.saveBoardWorkspaceBundle(index: index, board: tree, boardID: childID)
    if fromStack {
      let address = "board.json#/boards/@" + header.rootBoardID.uuidString.lowercased() + "/board/placements/@" + itemID.uuidString.lowercased()
      let fragment = try #require(local.storedFragments(address: address, descendants: false).first)
      let previous = try fragment.value.decode(WorkspacePlacement.self)
      let pose = try #require(previous.pose)
      let invalid = try WorkspacePlacement.authored(itemID: itemID,
        pose: .init(center: pose.center.offsetBy(x: 100, y: 0), zIndex: pose.zIndex,
          stackID: pose.stackID, stackOrder: pose.stackOrder),
        stamp: .init(counter: previous.stamp.counter + 1, actor: remoteActor), human: true, previous: previous)
      do {
        try local.commandTransaction {
          _ = try local.writeFragment(fragment.replacing(value: .encode(invalid)), database: local.currentSQL!)
        }
        Issue.record("A member changed the fixed stack anchor without changing the other member")
      } catch NotebookStorageError.invalidTransaction(let reason) {
        #expect(reason == "stack UUID has one fixed anchor")
      }
      #expect(try local.storedFragments(address: address, descendants: false).first == fragment)
    }
    try remote.prepareEmptyWorkspace(workspaceID: header.workspaceID)
    try transferAll(from: local, to: remote, peer: localActor)
    try transferAll(from: remote, to: local, peer: remoteActor)

    var source = header.rootBoardID
    for destination in [childID, header.rootBoardID] {
      let before = try local.loadBoard(items: index.items)
      var after = before
      let removed = after.deleteItem(itemID, from: source, kind: .notebook,
        spatialInk: .init(stamp: before.stamp), actor: localActor)
      let added = after.addItem(itemID, to: destination, near: .init(x: -1_000_000, y: 1_000_000), actor: localActor)
      #expect(removed && added)
      _ = try local.saveBoardEdits(before: before, after: after)
      #expect(try local.ownerBoardID(of: itemID) == destination)
      #expect(try local.readBoardItem(itemID)?.id == destination)
      for _ in 0..<2 {
        try transferAll(from: local, to: remote, peer: localActor)
        try transferAll(from: remote, to: local, peer: remoteActor)
      }
      for store in [local, remote] {
        #expect(try store.ownerBoardID(of: itemID) == destination)
        #expect(try store.readBoardItem(itemID)?.id == destination)
        let saved = try store.loadBoard(items: index.items)
        #expect(saved.board(source)?.placements.first { $0.id == itemID }?.pose == nil)
        #expect(saved.board(destination)?.placement(of: itemID)?.center == .init(x: -1_000_000, y: 1_000_000))
        let pinned = try store.readSceneWindow(boardID: destination,
          bounds: .init(origin: .zero, width: 100, height: 100), pinnedIDs: [itemID])
        #expect(pinned.boards.first { $0.id == destination }?.board.placement(of: itemID) != nil)
      }
      #expect(try local.loadBoard(items: index.items) == remote.loadBoard(items: index.items))
      source = destination
    }
    // Re-indexing an old board's retained tombstone cannot retire the current
    // owner. Checkpoint installation and publication order share this writer.
    try local.commandTransaction {
      let address = "board.json#/boards/@" + childID.uuidString.lowercased() + "/board/placements/@" + itemID.uuidString.lowercased()
      let tombstone = try #require(local.storedFragments(address: address, descendants: false).first)
      #expect(try tombstone.value.decode(WorkspacePlacement.self).pose == nil)
      try local.updateAddressIndexes(tombstone, database: local.currentSQL!)
    }
    #expect(try local.ownerBoardID(of: itemID) == header.rootBoardID)
    #expect(try local.readBoardItem(itemID)?.id == header.rootBoardID)
    try local.commandTransaction {
      let database = local.currentSQL!, budget = NotebookPlacementBudget()
      try database.noteOwner(.item, itemID.uuidString.lowercased())
      try budget.withSQL(database) { try local.validateChangedOwnership(database: database) }
      #expect(budget.sqlSteps < 512, "The changed-item check joins exact owner keys, not the catalog")
    }
  }

  @Test func aSecondLiveBoardClaimRollsBackInsteadOfStealingTheAddressIndex() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root)
    let header = try store.initializeWorkspace(actor: localActor, pageSize: .init(width: 834, height: 1194))
    var index = try store.loadIndex(), tree = try store.loadBoard(items: index.items)
    let itemID = index.selectedItemID
    let portal = index.createBoard(title: "Child", actor: localActor)
    let child = try #require(portal)
    let created = tree.createBoard(child.id, in: header.rootBoardID, near: .zero, actor: localActor)
    #expect(created)
    try store.saveBoardWorkspaceBundle(index: index, board: tree, boardID: child.id)
    let before = try store.loadBoard(items: index.items), cursor = try store.currentChangeCursor()
    var invalid = before
    let added = invalid.addItem(itemID, to: child.id, near: .zero, actor: remoteActor)
    #expect(added)
    do { _ = try store.saveBoardEdits(before: before, after: invalid); Issue.record("Two live board owners were accepted") }
    catch NotebookStorageError.corruptRecord(let owner) {
      #expect(owner == "item requires exactly one live board: " + itemID.uuidString.lowercased())
    }
    #expect(try store.currentChangeCursor() == cursor)
    #expect(try store.loadBoard(items: index.items) == before)
    #expect(try store.ownerBoardID(of: itemID) == header.rootBoardID)
  }

  private func conflictingBoards(_ base: BoardDocument, boardID: UUID,
    items: [UUID]) throws -> (BoardDocument, BoardDocument) {
    var local = base, remote = base
    let moved = local.moveItem(items[0], to: .init(x: 100, y: 100), actor: localActor)
    #expect(moved)
    let note = SpatialElement(id: "independent-local-note", surface: .board(boardID), kind: .nativeText,
      frame: .init(x: 0, y: 0, width: 100, height: 80), worldOrigin: .zero,
      source: "This text does not belong to the disputed placement.",
      stamp: .init(counter: local.stamp.counter, actor: localActor))
    let inserted = local.upsertElement(note, expected: nil, actor: localActor)
    #expect(inserted)
    let stacked = remote.createStack(moving: items[0], onto: items[1], actor: remoteActor)
    _ = try #require(stacked)
    for position in [200.0, 300.0] {
      let moved = remote.moveItem(items[2], to: .init(x: position, y: position), actor: remoteActor)
      #expect(moved)
    }
    #expect(local.stamp < remote.stamp)
    return (local, remote)
  }

  @Test func concurrentPlacementClaimsPreserveIndependentContentAndConverge() throws {
    let ids = (0..<3).map { _ in UUID() }, boardID = UUID()
    let base = BoardDocument.initial(itemIDs: ids, actor: remoteActor)
    let (local, remote) = try conflictingBoards(base, boardID: boardID, items: ids)
    var left = local, right = remote
    _ = try left.merge(remote, itemIDs: Set(ids))
    _ = try right.merge(local, itemIDs: Set(ids))
    #expect(left == right)
    #expect(left.stacks.isEmpty)
    #expect(left.freeItems.first { $0.id == ids[0] }?.center == .init(x: 100, y: 100))
    #expect(left.freeItems.first { $0.id == ids[2] }?.center == .init(x: 300, y: 300))
    #expect(left.elements.map(\.id) == ["independent-local-note"])
    let accepted = left
    for echo in [base, local, remote, accepted] {
      _ = try left.merge(echo, itemIDs: Set(ids))
      #expect(left == accepted)
    }
    let items = ids.map { WorkspaceItem.document(id: $0, title: "Item") }
    var tree = BoardHierarchy(rootBoardID: boardID, boards: [.init(id: boardID, board: local)], stamp: local.stamp)
    let incomingTree = BoardHierarchy(rootBoardID: boardID, boards: [.init(id: boardID, board: remote)], stamp: remote.stamp)
    _ = try tree.merge(incomingTree, items: items)
    #expect(tree.board(boardID) == accepted)
  }

  @Test func unseenSceneMembersAreNotDeletionTombstones() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root)
    let header = try store.initializeWorkspace(actor: localActor, pageSize: .init(width: 834, height: 1194))
    let index = try store.loadIndex(), base = try store.loadBoard(items: index.items)
    var edited = base
    let ids = ["diagram/a~b", "ABCDEFAB-ABCD-4ABC-8ABC-ABCDEFABCDEF"]
    for id in ids {
      let inserted = edited.upsertElement(.init(id: id, surface: .board(header.rootBoardID), kind: .nativeText,
        frame: .init(x: 0, y: 0, width: 100, height: 80), worldOrigin: .init(x: 100_000, y: 100_000),
        source: "Outside this scene", stamp: .init(counter: edited.stamp.counter, actor: localActor)),
        in: header.rootBoardID, expected: nil, actor: localActor)
      #expect(inserted)
    }
    _ = try store.saveBoardEdits(before: base, after: edited)
    let scene = try store.readSceneWindow(boardID: header.rootBoardID,
      bounds: .init(origin: .zero, width: 200, height: 200))
    let bounded = try #require(scene.boards.first?.board)
    var localBoard = try #require(edited.board(header.rootBoardID))
    #expect(bounded.elements.isEmpty)
    for id in ids {
      #expect(!bounded.hasRemovedElement(id: id))
      #expect(!localBoard.hasRemovedElement(id: id))
      let removed = localBoard.removeElements(ids: [id], actor: localActor)
      #expect(removed == 1)
      #expect(localBoard.hasRemovedElement(id: id))
    }
    #expect(localBoard.hasRemovedElement(id: ids[1].lowercased()))
    #expect(!localBoard.hasRemovedElement(id: "never-seen"))
  }

  @Test func aPeerPlacementResolutionCommitsIndependentContentAndAcknowledgesOnce() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let local = NotebookStore(root: root.appendingPathComponent("local"))
    let remote = NotebookStore(root: root.appendingPathComponent("remote"))
    let header = try local.initializeWorkspace(actor: remoteActor, pageSize: .init(width: 834, height: 1194))
    var index = try local.loadIndex(), tree = try local.loadBoard(items: index.items)
    for number in 1...2 {
      let result = index.createNotebook(title: "Notebook \(number)", actor: remoteActor, pageSize: .init(width: 834, height: 1194))
      let created = try #require(result)
      let added = tree.addItem(created.item.id, to: header.rootBoardID, near: .zero, actor: remoteActor)
      #expect(added)
      try local.saveWorkspaceBundle(index: index, page: created.page, board: tree)
    }
    try remote.prepareEmptyWorkspace(workspaceID: header.workspaceID)
    try transferAll(from: local, to: remote, peer: localActor)
    try transferAll(from: remote, to: local, peer: remoteActor)
    let base = try local.loadBoard(items: index.items)
    let baseBoard = try #require(base.board(header.rootBoardID))
    let (localBoard, remoteBoard) = try conflictingBoards(baseBoard, boardID: header.rootBoardID, items: index.items.map(\.id))
    func hierarchy(_ board: BoardDocument) -> BoardHierarchy {
      .init(rootBoardID: header.rootBoardID, boards: [.init(id: header.rootBoardID, board: board)], stamp: board.stamp)
    }
    _ = try local.saveBoardEdits(before: base, after: hierarchy(localBoard))
    let pageID = try #require(index.items[0].pageIDs.first)
    var peerPage = try remote.loadPage(pageID)
    let pageEdited = peerPage.replaceElements([.init(id: "remote-page-note", kind: .markdown,
      frame: .init(x: 20, y: 20, width: 200, height: 80), source: "Remote content", html: "Remote content")], actor: remoteActor)
    #expect(pageEdited)
    try remote.commandTransaction {
      _ = try remote.savePage(peerPage)
      _ = try remote.saveBoardEdits(before: base, after: hierarchy(remoteBoard))
    }
    let incomingCursor = try local.peerCursor(peerID: remoteActor, direction: .incoming)
    let incoming = try #require(remote.changeJournal(after: incomingCursor).first)
    try stage(incoming, from: remote, to: local)
    _ = try local.applyRemoteChange(incoming, peerID: remoteActor)
    let localCursor = try local.currentChangeCursor()
    #expect(try local.applyRemoteChange(incoming, peerID: remoteActor) == incoming.sequence)
    #expect(try local.currentChangeCursor() == localCursor)
    try transferAll(from: local, to: remote, peer: localActor)
    try transferAll(from: remote, to: local, peer: remoteActor)
    let actual = try local.loadBoard(items: index.items)
    #expect(try local.loadPage(pageID) == peerPage)
    #expect(try remote.loadPage(pageID) == peerPage)
    let otherTree = try remote.loadBoard(items: index.items)
    #expect(otherTree == actual)
    #expect(actual.board(header.rootBoardID)?.elements.map(\.id) == ["independent-local-note"])
    #expect(actual.board(header.rootBoardID)?.stacks.isEmpty == true)
    #expect(try local.peerCursor(peerID: remoteActor, direction: .incoming) == remote.currentChangeCursor())
  }

  @Test func aDelayedElementBodyCannotRegressAnAcceptedFrame() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let local = NotebookStore(root: root.appendingPathComponent("local"))
    let remote = NotebookStore(root: root.appendingPathComponent("remote"))
    let header = try local.initializeWorkspace(actor: remoteActor, pageSize: .init(width: 834, height: 1194))
    let index = try local.loadIndex(), initial = try local.loadBoard(items: index.items)
    var created = initial
    let element = SpatialElement(id: "shared-text", surface: .board(header.rootBoardID), kind: .nativeText,
      frame: .init(x: 0, y: 0, width: 200, height: 80), worldOrigin: .zero,
      source: "Original", stamp: .init(counter: created.stamp.counter, actor: remoteActor))
    let added = created.upsertElement(element, in: header.rootBoardID, expected: nil, actor: remoteActor)
    #expect(added)
    _ = try local.saveBoardEdits(before: initial, after: created)
    try remote.prepareEmptyWorkspace(workspaceID: header.workspaceID)
    try transferAll(from: local, to: remote, peer: localActor)
    let before = try local.loadBoard(items: index.items)
    var after = before, moved = try #require(before.board(header.rootBoardID)?.elements.first)
    let frame = SpatialRect(x: 130, y: 210, width: 260, height: 120)
    let expected = moved.stamp
    let frameChanged = moved.update(frame: frame, actor: localActor)
    let framePublished = after.upsertElement(moved, in: header.rootBoardID, expected: expected, actor: localActor)
    #expect(frameChanged && framePublished)
    _ = try local.saveBoardEdits(before: before, after: after)
    _ = try remote.updateNativeSpatialText(boardID: header.rootBoardID, elementID: element.id,
      text: "Independent remote edit", finish: false, actor: remoteActor)
    try transferAll(from: remote, to: local, peer: remoteActor)
    try transferAll(from: local, to: remote, peer: localActor)
    try transferAll(from: remote, to: local, peer: remoteActor)
    for store in [local, remote] {
      let received = try #require(store.loadBoard(items: index.items).board(header.rootBoardID)?.elements.first)
      #expect(received.frame == frame)
      #expect(received.source == "Independent remote edit")
    }
    #expect(try local.loadBoard(items: index.items) == remote.loadBoard(items: index.items))
  }

  @Test func concurrentUnstackingKeepsBothAcceptedMovesAcrossThreeWayDelivery() throws {
    let ids = (0..<3).map { _ in UUID() }, boardID = UUID()
    var base = BoardDocument.initial(itemIDs: ids, actor: remoteActor)
    for id in ids.dropFirst() { let created = base.createStack(moving: id, onto: ids[0], actor: remoteActor); _ = try #require(created) }
    var a = base, b = base, c = base
    let movedA = a.unstackItem(ids[0], at: .init(x: 111, y: 111), actor: localActor)
    let movedB = b.unstackItem(ids[1], at: .init(x: 222, y: 222), actor: UUID(uuidString: "77777777-7777-4777-8777-777777777777")!)
    #expect(movedA && movedB)
    _ = c.upsertElement(.init(id: "third-peer-note", surface: .board(boardID), kind: .nativeText,
      frame: .init(x: 0, y: 0, width: 100, height: 80), worldOrigin: .zero,
      source: "Independent", stamp: base.stamp), expected: nil, actor: remoteActor)
    let result = try convergedPermutations([a, b, c], base: base, ids: ids)
    #expect(result.stacks.isEmpty)
    #expect(result.freeItems.first { $0.id == ids[0] }?.center == .init(x: 111, y: 111))
    #expect(result.freeItems.first { $0.id == ids[1] }?.center == .init(x: 222, y: 222))
    #expect(result.elements.map(\.id) == ["third-peer-note"])
  }

  @Test func concurrentStackOverflowRetainsEveryCardAndConverges() throws {
    let ids = (0..<6).map { _ in UUID() }, boardID = UUID()
    var base = BoardDocument.initial(itemIDs: ids, actor: remoteActor)
    for id in ids[1..<4] { let created = base.createStack(moving: id, onto: ids[0], actor: remoteActor); _ = try #require(created) }
    var a = base, b = base, c = base
    let created = a.createStack(moving: ids[4], onto: ids[0], actor: localActor); _ = try #require(created)
    let second = b.createStack(moving: ids[5], onto: ids[0], actor: UUID(uuidString: "77777777-7777-4777-8777-777777777777")!); _ = try #require(second)
    _ = c.upsertElement(.init(id: "third-peer-note", surface: .board(boardID), kind: .nativeText,
      frame: .init(x: 0, y: 0, width: 100, height: 80), worldOrigin: .zero,
      source: "Independent", stamp: base.stamp), expected: nil, actor: remoteActor)
    let result = try convergedPermutations([a, b, c], base: base, ids: ids)
    #expect(result.stacks.count == 1)
    #expect(result.stacks.first?.itemIDs.count == WorkspaceItemStack.maximumItemCount)
    #expect(result.freeItems.count == 1)
    #expect(result.freeItems.first?.center == result.stacks.first?.center)
    #expect(result.elements.map(\.id) == ["third-peer-note"])
  }

  @Test func threeCompetingStacksHaveOnePhysicalOwnerAndNoLostCards() throws {
    let ids = (0..<4).map { _ in UUID() }
    let base = BoardDocument.initial(itemIDs: ids, actor: remoteActor)
    let actors = [remoteActor, UUID(uuidString: "77777777-7777-4777-8777-777777777777")!, localActor]
    let alternatives = try (0..<3).map { offset -> BoardDocument in
      var next = base
      let created = next.createStack(moving: ids[0], onto: ids[offset + 1], actor: actors[offset]); _ = try #require(created)
      return next
    }
    let result = try convergedPermutations(alternatives, base: base, ids: ids)
    #expect(result.stacks.count == 1)
    #expect(Set(result.stacks[0].itemIDs) == [ids[0], ids[3]])
    #expect(Set(result.freeItems.map(\.id)) == [ids[1], ids[2]])
  }

  @Test func aMechanicalRemainderCannotOverruleItsLaterDeliveredRestack() throws {
    let ids = (0..<4).map { _ in UUID() }, boardID = UUID()
    var base = BoardDocument.initial(itemIDs: ids, actor: remoteActor)
    for id in ids[1..<3] {
      let created = base.createStack(moving: id, onto: ids[0], actor: remoteActor)
      _ = try #require(created)
    }
    var a = base, b = base, c = base
    for number in 0..<4 {
      _ = a.upsertElement(.init(id: "other-note-\(number)", surface: .board(boardID), kind: .nativeText,
        frame: .init(x: 0, y: 0, width: 100, height: 80), worldOrigin: .zero,
        source: "Independent", stamp: a.stamp), expected: nil, actor: localActor)
    }
    _ = a.unstackItem(ids[0], at: .init(x: 111, y: 111), actor: localActor)
    _ = b.unstackItem(ids[1], at: .init(x: 222, y: 222), actor: UUID(uuidString: "77777777-7777-4777-8777-777777777777")!)
    _ = c.unstackItem(ids[2], at: .init(x: 333, y: 333), actor: remoteActor)
    let restacked = c.createStack(moving: ids[2], onto: ids[3], actor: remoteActor)
    let newStack = try #require(restacked)
    _ = try a.merge(b, itemIDs: Set(ids))
    _ = try a.merge(c, itemIDs: Set(ids))
    #expect(a.stack(containing: ids[2])?.id == newStack)
  }

  @Test func concurrentUnstackingBothMembersNeverAuthorsTheOtherRemainder() throws {
    let ids = (0..<2).map { _ in UUID() }
    var base = BoardDocument.initial(itemIDs: ids, actor: remoteActor)
    let created = base.createStack(moving: ids[0], onto: ids[1], actor: remoteActor)
    _ = try #require(created)
    var a = base, b = base
    let movedA = a.unstackItem(ids[0], at: .init(x: 111, y: 111), actor: localActor)
    let movedB = b.unstackItem(ids[1], at: .init(x: 222, y: 222), actor: remoteActor)
    #expect(movedA && movedB)
    let merged = try convergedPermutations([a, b, base], base: base, ids: ids)
    #expect(merged.placement(of: ids[0])?.center == .init(x: 111, y: 111))
    #expect(merged.placement(of: ids[1])?.center == .init(x: 222, y: 222))
    #expect(merged.placements.first { $0.id == ids[0] }?.stamp.actor == localActor)
    #expect(merged.placements.first { $0.id == ids[1] }?.stamp.actor == remoteActor)
  }

  @Test func allThreeUnstackedItemsRetainTheirOwnIntentAcrossEveryDeliveryOrder() throws {
    let ids = (0..<3).map { _ in UUID() }, actors = [localActor, remoteActor, UUID()]
    var base = BoardDocument.initial(itemIDs: ids, actor: remoteActor)
    let first = base.createStack(moving: ids[0], onto: ids[1], actor: remoteActor)
    let second = base.createStack(moving: ids[2], onto: ids[1], actor: remoteActor)
    _ = try #require(first); _ = try #require(second)
    let copies = ids.enumerated().map { offset, id in
      var value = base
      let moved = value.unstackItem(id, at: .init(x: Double(offset + 1) * 111, y: 500), actor: actors[offset])
      #expect(moved)
      return value
    }
    let merged = try convergedPermutations(copies, base: base, ids: ids)
    for (offset, id) in ids.enumerated() {
      #expect(merged.placement(of: id)?.center == .init(x: Double(offset + 1) * 111, y: 500))
      #expect(merged.placements.first { $0.id == id }?.stamp.actor == actors[offset])
    }
  }

  @Test func threeWayHumanAndAgentPriorityIsAssociativeWithoutInventingObservation() throws {
    let item = UUID(), aID = localActor, bID = remoteActor, cID = UUID()
    let base = BoardDocument.initial(itemIDs: [item], actor: aID)
    let initial = try #require(base.placements.first)
    let a = try WorkspacePlacement.authored(itemID: item, pose: .init(center: .init(x: 100, y: 0), zIndex: 1),
      stamp: .init(counter: 10, actor: aID), human: true, previous: initial)
    let b = try WorkspacePlacement.authored(itemID: item, pose: .init(center: .init(x: 200, y: 0), zIndex: 2),
      stamp: .init(counter: 11, actor: bID), human: false, previous: a)
    let c = try WorkspacePlacement.authored(itemID: item, pose: .init(center: .init(x: 300, y: 0), zIndex: 3),
      stamp: .init(counter: 9, actor: cID), human: true, previous: initial)
    let values = [a,b,c].map { BoardDocument(placements: [$0], elements: [], stamp: $0.stamp, collaboration: base.collaboration) }
    let result = try convergedPermutations(values, base: base, ids: [item])
    #expect(result.placement(of: item)?.center == c.pose?.center)
    #expect(Set(result.placements[0].heads.map { $0.version.stamp }) == [b.stamp, c.stamp])
    #expect(result.stamp.counter == 11)
  }

  @Test(arguments: [false, true])
  func addressedPeerDeltasCannotBorrowAnotherItemsMembershipClock(reverseActors: Bool) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let a = NotebookStore(root: root.appendingPathComponent("a")), b = NotebookStore(root: root.appendingPathComponent("b"))
    let actorA = reverseActors ? remoteActor : localActor, actorB = reverseActors ? localActor : remoteActor
    let header = try a.initializeWorkspace(actor: remoteActor, pageSize: .init(width: 834, height: 1194))
    var index = try a.loadIndex(), tree = try a.loadBoard(items: index.items)
    for number in 1...2 {
      let createdValue = index.createNotebook(title: "Item \(number)", actor: remoteActor, pageSize: .init(width: 834, height: 1194))
      let created = try #require(createdValue)
      let added = tree.addItem(created.item.id, to: header.rootBoardID, near: .zero, actor: remoteActor)
      #expect(added)
      try a.saveWorkspaceBundle(index: index, page: created.page, board: tree)
    }
    let ids = index.items.map(\.id), beforeStack = tree
    let first = tree.createStack(moving: ids[0], onto: ids[1], in: header.rootBoardID, actor: remoteActor)
    let second = tree.createStack(moving: ids[2], onto: ids[1], in: header.rootBoardID, actor: remoteActor)
    _ = try #require(first); _ = try #require(second)
    _ = try a.saveBoardEdits(before: beforeStack, after: tree)
    try b.prepareEmptyWorkspace(workspaceID: header.workspaceID)
    try transferAll(from: a, to: b, peer: actorA)
    try transferAll(from: b, to: a, peer: actorB)
    let original = try a.loadBoard(items: index.items)
    var left = original, right = original
    let movedA = left.unstackItem(ids[0], in: header.rootBoardID, at: .init(x: 111, y: 111), actor: actorA)
    let movedB = right.unstackItem(ids[1], in: header.rootBoardID, at: .init(x: 222, y: 222), actor: actorB)
    #expect(movedA && movedB)
    _ = try a.saveBoardEdits(before: original, after: left)
    _ = try b.saveBoardEdits(before: original, after: right)
    try transferAll(from: a, to: b, peer: actorA)
    try transferAll(from: b, to: a, peer: actorB)
    try transferAll(from: a, to: b, peer: actorA)
    let merged = try a.loadBoard(items: index.items)
    #expect(try merged == b.loadBoard(items: index.items))
    #expect(merged.board(header.rootBoardID)?.placement(of: ids[0])?.center == .init(x: 111, y: 111))
    #expect(merged.board(header.rootBoardID)?.placement(of: ids[1])?.center == .init(x: 222, y: 222))
    #expect(try a.readBoardItem(ids[0])?.board.placement(of: ids[0])?.center == .init(x: 111, y: 111))
    #expect(try b.readBoardItem(ids[1])?.board.placement(of: ids[1])?.center == .init(x: 222, y: 222))
    #expect(try a.workspaceHeader().boardRevision == b.workspaceHeader().boardRevision)
  }

  @Test func oneCausalVersionCannotClaimTwoDifferentPlaces() throws {
    let ids = (0..<2).map { _ in UUID() }
    let base = BoardDocument.initial(itemIDs: ids, actor: localActor)
    var a = base, b = base
    _ = a.moveItem(ids[0], to: .init(x: 100, y: 100), actor: localActor)
    let created = b.createStack(moving: ids[0], onto: ids[1], actor: localActor); _ = try #require(created)
    let accepted = a
    do { _ = try a.merge(b, itemIDs: Set(ids)); Issue.record("A forked actor clock cannot author two locations.") }
    catch let error as NotebookStorageError { #expect(error == .transactionConflict) }
    #expect(a == accepted)
  }

  private func convergedPermutations(_ values: [BoardDocument], base: BoardDocument,
    ids: [UUID]) throws -> BoardDocument {
    let orders = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]
    var copies = try orders.map { order -> BoardDocument in
      var value = values[order[0]]
      for index in order.dropFirst() { _ = try value.merge(values[index], itemIDs: Set(ids)) }
      #expect(value.isValid(itemIDs: Set(ids)))
      #expect(value.itemIDs.count == ids.count)
      return value
    }
    for _ in 0..<6 {
      let sources = copies
      for index in copies.indices {
        for source in sources { _ = try copies[index].merge(source, itemIDs: Set(ids)) }
      }
      if copies.dropFirst().allSatisfy({ $0 == copies[0] }) { break }
    }
    let expected = try collaborationHash(copies[0])
    for original in copies {
      var copy = original
      #expect(try collaborationHash(copy) == expected)
      for echo in [base] + values + copies {
        let changed = try copy.merge(echo, itemIDs: Set(ids))
        #expect(!changed)
        #expect(try collaborationHash(copy) == expected)
      }
    }
    return copies[0]
  }

  private func transferAll(from source: NotebookStore, to destination: NotebookStore, peer: UUID) throws {
    while true {
      let cursor = try destination.peerCursor(peerID: peer, direction: .incoming)
      let changes = try source.changeJournal(after: cursor)
      if changes.isEmpty { return }
      for change in changes {
        try stage(change, from: source, to: destination)
        _ = try destination.applyRemoteChange(change, peerID: peer)
      }
    }
  }

  private func stage(_ change: NotebookDurableChange, from source: NotebookStore, to destination: NotebookStore) throws {
    while true {
      let hashes = try destination.missingBlobHashes(for: change)
      if hashes.isEmpty { return }
      for hash in hashes {
        let size = try source.blobSize(hash: hash)
        var data = Data()
        while Int64(data.count) < size {
          data += try source.readBlobChunk(hash: hash, offset: Int64(data.count), maxBytes: 1_048_576)
        }
        try destination.stageBlob(data: data, expectedHash: hash)
      }
    }
  }
}

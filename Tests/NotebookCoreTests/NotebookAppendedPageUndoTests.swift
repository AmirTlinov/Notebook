import Foundation
import Testing
@testable import NotebookCore

@Suite("Append undo removes only authenticated unadopted pages", .serialized)
struct NotebookAppendedPageUndoTests {
  private typealias Fixture = NotebookItemLifecycleTests.Fixture

  private func append(_ f: Fixture, stroke: UUID? = nil, additionalPage: UUID? = nil) throws -> (CollaborationReceipt, UUID) {
    let extent = try #require(try f.store.readItemLifecycle(f.itemID)), pageID = UUID()
    var command = NotebookCommand(command: .read); command.readSnapshots = true
    command.queries = [try JSONValue.object(["kind": .string("itemLifecycle"), "id": try .encode(f.itemID)]).decode(NotebookReadQuery.self)]
    let basis = try #require(try NotebookCommandDispatcher(store: f.store).handle(command).array.first?["basis"]?.decode(NotebookReadBasis.self))
    var operations = [CollaborationOperation(kind: .appendPage, target: extent.target, id: pageID.uuidString, values: [:])]
    if let additionalPage { operations.append(.init(kind: .appendPage, target: extent.target, id: additionalPage.uuidString, values: [:])) }
    if let stroke {
      operations.append(.init(kind: .appendInkStroke, target: .init(kind: .page, id: pageID), id: stroke.uuidString,
        values: ["points": .array([.object(["x": .number(12), "y": .number(18)])])]))
    }
    let expected = try f.store.expectations(base: basis, operations: operations)
    return (try f.store.applyCollaborationAction(.init(additionalOwners: [extent.target], summary: "Append one page",
      expected: expected, operations: operations), actor: f.actor), pageID)
  }

  private func remove(_ f: Fixture, receipt: CollaborationReceipt) throws -> (NotebookAppendedPageUndoPreparation, [NotebookLifecycleUndoChange]) {
    try f.store.commandTransaction {
      let prepared = try f.store.prepareAppendedNotebookPageUndo(receipt: receipt)
      let changes = try f.store.currentSQL!.withActionRecordCapture(actionID: UUID()) {
        try f.store.publishAppendedNotebookPageUndo(prepared, actor: UUID())
      }
      return (prepared, changes)
    }
  }

  private func createWithAppend(_ f: Fixture) throws -> (CollaborationReceipt, UUID, UUID, UUID) {
    let header = try f.store.workspaceHeader(), itemID = UUID(), first = UUID(), appended = UUID()
    let board = CollaborationTarget(kind: .board, id: header.rootBoardID)
    let cover = CollaborationTarget(kind: .cover, id: itemID, boardID: header.rootBoardID)
    let base = try f.store.readBasis(targets: [board, .init(kind: .workspace, id: header.rootBoardID)])
    let operations = [CollaborationOperation(kind: .createNotebook, target: board, id: itemID.uuidString,
      values: ["pageID": try .encode(first), "center": try .encode(WorldPoint.zero)]),
      CollaborationOperation(kind: .appendPage, target: cover, id: appended.uuidString, values: [:])]
    let expected = try f.store.expectations(base: base, operations: operations)
    let receipt = try f.store.applyCollaborationAction(.init(summary: "Create notebook with two own pages",
      expected: expected, operations: operations), actor: f.actor)
    return (receipt, itemID, first, appended)
  }

  @Test func undoOfNewNotebookWithItsOwnAppendedPageRemovesTheWholeCreation() throws {
    let f = try Fixture(), (receipt, item, first, appended) = try createWithAppend(f)
    #expect(try f.store.pageCount(in: item) == 2)
    let undone = try f.store.undoCollaborationAction(receipt.id, actor: UUID())
    #expect(undone.undo?.preservedLifecycle?.isEmpty ?? true)
    #expect(try f.store.readItemHeader(item) == nil)
    #expect(try f.store.ownerItemID(ofPage: first) == nil)
    #expect(try f.store.ownerItemID(ofPage: appended) == nil)
    #expect(try !f.store.hasStoredValue(pageFile(first)))
    #expect(try !f.store.hasStoredValue(pageFile(appended)))
    #expect(try f.store.readItemHeader(f.itemID) != nil)
    #expect(try f.store.loadPage(f.pageID).id == f.pageID)
  }

  @Test func humanContinuationOfAppendedPageProtectsItsCreatedNotebook() throws {
    let f = try Fixture(), (receipt, item, first, appended) = try createWithAppend(f)
    try f.write(appended, text: "Human owns this continuation")
    let before = try f.store.loadPage(appended)
    _ = try f.store.undoCollaborationAction(receipt.id, actor: UUID())
    #expect(try f.store.readItemHeader(item)?.pageCount == 2)
    #expect(try f.store.ownerItemID(ofPage: first) == item)
    #expect(try f.store.ownerItemID(ofPage: appended) == item)
    #expect(try f.store.loadPage(appended) == before)
    #expect(try f.store.loadPage(first).id == first)
    #expect(try f.store.readItemHeader(f.itemID) != nil)
  }

  @Test func unchangedAppendedPageIsRemovedAndItsUUIDStaysRetired() throws {
    let f = try Fixture(), (receipt, page) = try append(f), presence = try f.store.loadPresence()
    let (_, changes) = try remove(f, receipt: receipt)
    #expect(changes.count == 1 && changes.first?.kind == .removePage && changes.first?.pageID == page)
    #expect(changes.first?.item?.pageCount == 1)
    #expect(try f.store.ownerItemID(ofPage: page) == nil)
    #expect(try !f.store.hasStoredValue(pageFile(page)))
    #expect(try f.store.pageID(at: 0, in: f.itemID) == f.pageID)
    #expect(try f.store.pageCount(in: f.itemID) == 1)
    #expect(try f.store.loadPresence() == presence)
    #expect(throws: NotebookStorageError.self) {
      try f.store.commandTransaction { _ = try f.store.makePageAppendAdmission(itemID: f.itemID, pageID: page, actor: f.actor, human: false) }
    }
  }

  @Test func aLaterNativeAppendSurvivesAndDoesNotAdoptTheEarlierPage() throws {
    let f = try Fixture(), (receipt, page) = try append(f), later = try f.append(), laterBody = try f.store.loadPage(later)
    let (prepared, changes) = try remove(f, receipt: receipt)
    #expect(prepared.preserved.isEmpty && changes.count == 1)
    #expect(try f.store.pageCount(in: f.itemID) == 2)
    #expect(try f.store.pageID(at: 0, in: f.itemID) == f.pageID)
    #expect(try f.store.pageID(at: 1, in: f.itemID) == later)
    #expect(try f.store.ownerItemID(ofPage: page) == nil)
    #expect(try f.store.loadPage(later) == laterBody)
  }

  @Test func humanContentAndAnInvisibleForeignCausalObservationBothProtectThePage() throws {
    for invisible in [false, true] {
      let f = try Fixture(), (receipt, page) = try append(f)
      if invisible {
        try f.store.commandTransaction {
          let address = pageFile(page) + "#/collaboration/fields/@" + fieldKey(["elements/order"])
          let row = try #require(try f.store.storedFragments(address: address, descendants: false).first)
          let version = try row.value.decode(ContentFieldVersion.self)
          var observed = version.observed; observed[UUID().uuidString.lowercased()] = 0
          let changed = ContentFieldVersion(stamp: version.stamp, human: version.human, observed: observed)
          try f.store.writeFragment(row.replacing(value: try .encode(changed)), database: f.store.currentSQL!)
        }
      } else { try f.write(page, text: "Human continuation") }
      let before = try f.store.loadPage(page), cursor = try f.store.currentChangeCursor()
      let (prepared, changes) = try remove(f, receipt: receipt)
      #expect(prepared.preserved == [receipt.lifecycleChanges!.first!.target])
      #expect(changes.isEmpty)
      #expect(try f.store.loadPage(page) == before)
      #expect(try f.store.currentChangeCursor() == cursor)
    }
  }

  @Test func preflightBeforeOwnInkInverseStillAllowsItsCreatedPageToBeRemoved() throws {
    let f = try Fixture(), stroke = UUID(), (receipt, pageID) = try append(f, stroke: stroke)
    let changes = try f.store.commandTransaction {
      let prepared = try f.store.prepareAppendedNotebookPageUndo(receipt: receipt)
      #expect(prepared.pages.map(\.pageID) == [pageID])
      return try f.store.currentSQL!.withActionRecordCapture(actionID: UUID()) {
        var page = try f.store.loadPage(pageID)
        let drawing = try PageInkDrawing.decode(page.drawingData)
        #expect(try page.replaceDrawing(drawing.settingActive(false,for:[stroke],stamp:.init(counter:1,actor:UUID())).dataRepresentation(), actor: UUID()))
        _ = try f.store.savePage(page)
        return try f.store.publishAppendedNotebookPageUndo(prepared, actor: UUID())
      }
    }
    #expect(changes.first?.pageID == pageID)
    #expect(try f.store.ownerItemID(ofPage: pageID) == nil)
    #expect(try !f.store.hasStoredValue(pageFile(pageID)))
  }

  @Test func anOperationOrAnUnrelatedInverseCannotInventABirth() throws {
    let f = try Fixture(), (receipt, _) = try append(f)
    let target = receipt.lifecycleChanges!.first!.target, item = try #require(try f.store.readItemHeader(f.itemID))
    var forged = receipt
    forged.lifecycleChanges = [.init(kind: .appendPage, target: target, pageID: f.pageID, beforeItem: item, afterItem: item)]
    #expect(throws: NotebookStorageError.self) { _ = try remove(f, receipt: forged) }
    var absent = receipt; absent.lifecycleInverse = nil
    #expect(throws: NotebookStorageError.self) { _ = try remove(f, receipt: absent) }
    #expect(try f.store.loadPage(f.pageID).id == f.pageID)
  }

  @Test(arguments: ["duplicate", "continuedSibling", "unrelated", "malformed"])
  func claimedPageRemovalRequiresItsOwnCapturedEvidenceAndRollsBackTheWriter(fault: String) throws {
    let f = try Fixture(), continuedPage = UUID()
    let (original, removedPage) = try append(f, additionalPage: continuedPage)
    try f.write(continuedPage, text: "This sibling has an accepted human continuation")
    let accepted = try f.store.undoCollaborationAction(original.id, actor: UUID())
    let removal = try #require(accepted.undo?.lifecycleChanges?.first)
    #expect(accepted.undo?.lifecycleChanges?.count == 1 && removal.pageID == removedPage)
    #expect(accepted.undo?.preservedLifecycle == [removal.target])
    #expect(try f.store.ownerItemID(ofPage: removedPage) == nil)
    #expect(try f.store.ownerItemID(ofPage: continuedPage) == f.itemID)
    let file = "collaboration/actions/" + accepted.id.uuidString.lowercased() + ".json", address = file + "#"
    let raw = try f.store.storedValue(file), model = try f.store.actionReadModel(accepted.id)
    let result = try f.store.savedActionResult(accepted.id, version: model.actionVersion)
    let cursor = try f.store.currentChangeCursor(), readCursor = try f.store.currentReadCursor()
    let page = try f.store.loadPage(continuedPage), header = try f.store.readItemHeader(f.itemID)
    func hashes() throws -> [[String]] {
      try f.store.readTransaction { store in
        try store.currentSQL!.rows("SELECT address,hash FROM records ORDER BY address").map { [$0[0].text!, $0[1].text!] }
      }
    }
    func proofs() throws -> [[String]] {
      try f.store.readTransaction { store in
        try store.currentSQL!.rows("SELECT field,version,value FROM action_field_restorations WHERE address=? ORDER BY field",
          [.text(address)]).map { [$0[0].text!, $0[1].text!, $0[2].blob!.base64EncodedString()] }
      }
    }
    let beforeHashes = try hashes(), beforeProofs = try proofs()
    var forged = accepted
    switch fault {
    case "duplicate": forged.undo?.lifecycleChanges = [removal, removal]
    case "continuedSibling":
      // It really was born in this action and has the same cover, but the
      // authenticated inverse removed neither its membership nor its body.
      forged.undo?.lifecycleChanges = [removal, .init(kind: .removePage, target: removal.target,
        pageID: continuedPage, item: removal.item)]
    case "unrelated":
      forged.undo?.lifecycleChanges = [removal, .init(kind: .removePage, target: removal.target,
        pageID: f.pageID, item: removal.item)]
    case "malformed":
      forged.undo?.lifecycleChanges = [.init(kind: .removePage, target: removal.target, pageID: nil, item: removal.item)]
    default: Issue.record("Unexpected removal fault"); throw CancellationError()
    }
    do {
      try f.store.commandTransaction {
        try f.write(continuedPage, text: "This later write must roll back with the forged receipt")
        try f.store.publishRecords(writes: [file: try .encode(forged)])
      }
      Issue.record("An unauthenticated page removal must refuse the entire writer cut")
    } catch let error as NotebookStorageError {
      let reason = fault == "continuedSibling" ? "append restoration evidence" : "append restoration scope"
      #expect(error == .invalidTransaction(reason))
    }
    #expect(try f.store.currentChangeCursor() == cursor)
    #expect(try f.store.currentReadCursor() == readCursor)
    #expect(try f.store.storedValue(file) == raw)
    #expect(try f.store.actionReadModel(accepted.id) == model)
    #expect(try f.store.savedActionResult(accepted.id, version: model.actionVersion) == result)
    #expect(try f.store.loadPage(continuedPage) == page)
    #expect(try f.store.readItemHeader(f.itemID) == header)
    #expect(try hashes() == beforeHashes)
    #expect(try proofs() == beforeProofs)
  }
}

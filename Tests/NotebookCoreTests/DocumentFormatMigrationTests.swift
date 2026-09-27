import Foundation
import Testing
@testable import NotebookCore

@Suite(.serialized)
struct DocumentFormatMigrationTests {
  private func fixture(_ body: (NotebookStore, UUID, DocumentDocument) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("document-cutover-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    _ = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    let before = try store.loadIndex(), boardBefore = try store.loadBoard(items: before.items)
    let document = DocumentDocument(actor: actor, files: [.init(id: "main", path: "main.tex", source: "Before")])
    var after = before, boardAfter = boardBefore
    let created = after.createDocument(title: "Old document", actor: actor, documentID: document.id)
    #expect(created != nil)
    let placed = boardAfter.addItem(document.id, to: before.rootBoardID, near: .zero, actor: actor)
    #expect(placed)
    _ = try store.saveWorkspaceEdits(before: before, after: after, boardBefore: boardBefore, boardAfter: boardAfter,
      documents: [document], states: [.init(id: document.id, actor: actor)])
    try body(store, actor, document)
  }

  /// Manufacture the previous admitted rows only in this isolated fixture.
  /// No production path accepts or converts the removed block format.
  private func downgrade(_ store: NotebookStore, document: DocumentDocument) throws -> (String, Data) {
    let db = try NotebookSQLConnection(url: store.databaseURL, writable: true), file = documentFile(document.id)
    let value: JSONValue = .object(["format": .number(2), "id": try .encode(document.id),
      "paperSize": .string("a4"), "preamble": .string(""), "contentStamp": try .encode(document.contentStamp)])
    let root = NotebookStoredFragment(address: file + "#", file: file, parent: nil, collection: "", member: "", position: 0,
      value: value, collections: [.init(path: ["blocks"], kind: .array)])
    let block = NotebookStoredFragment(address: file + "#/blocks/@body", file: file, parent: file + "#", collection: "blocks", member: "body", position: 0,
      value: .object(["id": .string("body"), "kind": .string("markdown"), "source": .string("Retired original")]), collections: [])
    try db.run("BEGIN IMMEDIATE")
    do {
      try db.run("DELETE FROM records WHERE file=?", [.text(file)])
      for row in [root, block] {
        let hash = try db.putBlob(NotebookStore.storageEncoder.encode(row))
        try db.run("INSERT INTO records(address,file,parent,collection,member,position,hash) VALUES(?,?,?,?,?,?,?)", [
          .text(row.address), .text(row.file), row.parent.map(NotebookSQLValue.text) ?? .null,
          .text(row.collection), .text(row.member), .integer(Int64(row.position)), .text(hash)])
      }
      try db.run("PRAGMA user_version=25")
      try db.run("COMMIT")
    } catch { try? db.run("ROLLBACK"); throw error }
    let data = try NotebookStore.storageEncoder.encode(block)
    return (try db.putBlob(data), data)
  }

  @Test func removesOnlyRetiredDocumentsAndTheirExecutableRecoveryOnce() throws {
    try fixture { store, actor, document in
      let initial = try store.loadIndex(), notebook = try #require(initial.items.first { $0.kind == .notebook })
      let pageID = try #require(notebook.pageIDs.first), pageTarget = CollaborationTarget(kind: .page, id: pageID)
      let docTarget = CollaborationTarget(kind: .document, id: document.id), context = try store.appendContext(
        references: [.init(target: docTarget, revision: store.referenceRevision(target: docTarget))], author: .human, actor: actor, text: "Historical discussion")
      let operation = CollaborationOperation(kind: .patchDocumentFile, target: docTarget, id: "main", values: [
        "expectedVersion": try .encode(store.loadDocument(document.id).fileVersion(fileID: "main")),
        "range": .object(["location": .number(0), "length": .number(6)]), "expectedText": .string("Before"), "source": .string("After")])
      let mixed = CollaborationAction(summary: "Mixed document and notebook", expected: try [docTarget, pageTarget].map {
        .init(target: $0, revision: try store.targetContentRevision(target: $0))
      }, operations: [operation, .init(kind: .insertElement, target: pageTarget, id: "kept", values: ["kind": .string("web"),
        "frame": .object(["x": .number(10), "y": .number(10), "width": .number(200), "height": .number(100)]),
        "source": .string("<p>Preserved</p>"), "html": .string("<p>Preserved</p>")])])
      let receipt = try store.applyCollaborationAction(mixed, actor: actor)
      try store.commandTransaction { try store.recordNativeHistory(.command(receipt.id), domain: .page(pageID), actor: actor) }
      let runID = UUID()
      _ = try store.admitScriptRun(.init(op: .start, runID: runID, code: "not run"))
      _ = try store.setScriptRunState(runID, state: .running)
      let effect = try store.admitScriptEffect(runID, key: "old-edit", method: "transaction", arguments: .object(["operations": try .encode([operation])]))
      try store.saveDocumentDraft(.init(edit: .init(sessionID: UUID(), documentID: document.id, fileID: "main", baseSource: "After",
        baseVersion: store.loadDocument(document.id).fileVersion(fileID: "main"), source: "Draft", sequence: 1), selectionStart: 1, selectionEnd: 1))
      let beforePage = try store.loadPage(pageID), beforeContext = try store.sharedContextPage(contextID: context.id), identity = try store.workspaceHeader().workspaceID
      let peer = UUID(), cursor = try store.currentChangeCursor()
      try store.acknowledgePeer(peerID: peer, through: cursor)
      let (hash, bytes) = try downgrade(store, document: document)
      let opened = NotebookStore(root: store.root), after = try opened.loadIndex()
      #expect(after.rootBoardID == initial.rootBoardID && after.items == [notebook])
      #expect(try opened.workspaceHeader().workspaceID == identity)
      #expect(try opened.loadPage(pageID) == beforePage)
      #expect(try opened.sharedContextPage(contextID: context.id) == beforeContext)
      #expect(try opened.readItemHeader(document.id) == nil)
      #expect(try opened.storedValue(documentFile(document.id)) == nil)
      #expect(try opened.storedValue(stateFile(document.id)) == nil)
      #expect(try opened.documentEditingSessions().isEmpty)
      #expect(try opened.collaborationActionIfPresent(receipt.id) == nil)
      #expect(try opened.savedActionResult(receipt.id) == nil)
      #expect(try opened.nativeHistory(domain: .page(pageID), actor: actor).isEmpty)
      #expect(try opened.unfinishedScriptEffects().isEmpty)
      #expect(try opened.scriptEffect(runID, id: effect.id).error?["code"] == .string("document_format_retired"))
      #expect(try opened.scriptRun(runID)?.state == .interrupted)
      #expect(try opened.peerCursor(peerID: peer, direction: .outgoing) == cursor)
      #expect(try opened.readBlobChunk(hash: hash, offset: 0, maxBytes: 1_048_576) == bytes)
      #expect(throws: CollaborationError.self) { try opened.changeJournal(after: cursor - 1) }
      let changes = try opened.currentChangeCursor()
      #expect(changes == cursor + 1)
      #expect(try NotebookStore(root: store.root).loadIndex() == after)
      #expect(try opened.currentChangeCursor() == changes)
    }
  }

  @Test func pendingDeliveryRefusesCutoverWithoutChangingRowsOrPeerCursor() throws {
    try fixture { store, _, document in
      let peer = UUID()
      try store.acknowledgePeer(peerID: peer, through: 0)
      _ = try downgrade(store, document: document)
      let db = try NotebookSQLConnection(url: store.databaseURL, writable: false)
      let before = try db.rows("SELECT address,hash FROM records ORDER BY address").map { [$0[0].text, $0[1].text] }
      do { _ = try NotebookStore(root: store.root).workspaceHeader(); Issue.record("Pending document delivery was discarded") }
      catch let error as CollaborationError { #expect(error.code == "document_migration_pending_peer") }
      #expect(try db.rows("SELECT address,hash FROM records ORDER BY address").map { [$0[0].text, $0[1].text] } == before)
      #expect(try db.rows("PRAGMA user_version").first?[0].integer == 25)
      #expect(try db.rows("SELECT value FROM metadata WHERE key='document_outgoing_floor'").isEmpty)
      #expect(try db.rows("SELECT sequence FROM peer_cursors WHERE peer_id=? AND direction='outgoing'", [.text(peer.uuidString.lowercased())]).first?[0].integer == 0)
    }
  }

  @Test func lastDocumentIsReplacedByAnOrdinaryNotebookWithoutResettingWorkspace() throws {
    try fixture { store, actor, document in
      let notebook = try #require(try store.loadIndex().items.first { $0.kind == .notebook })
      try store.commandTransaction { try store.deleteWorkspaceItemContent(itemID: notebook.id, actor: actor, human: true) }
      let before = try store.workspaceHeader()
      _ = try downgrade(store, document: document)
      let opened = NotebookStore(root: store.root), after = try opened.loadIndex()
      #expect(after.items.count == 1 && after.items.first?.kind == .notebook)
      #expect(after.rootBoardID == before.rootBoardID)
      #expect(try opened.workspaceHeader().workspaceID == before.workspaceID)
      #expect(try opened.loadPage(#require(after.items.first?.pageIDs.first)).elements.isEmpty)
      #expect(try opened.storedValue(documentFile(document.id)) == nil)
    }
  }
}

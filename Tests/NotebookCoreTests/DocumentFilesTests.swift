import Foundation
import CSQLite
import Testing
@testable import NotebookCore

func notebookProgramFiles(path: String = "programs/counter", initialState: JSONValue = .number(0)) -> [DocumentFile] {
  [.init(id: "main", path: "main.tex", source: "\\documentclass{article}\n\\begin{document}\n\\NotebookInteractive[id=counter,width=100pt,height=60pt]{\(path)}\n\\end{document}"),
   .init(id: "program-html", path: path + "/index.html", source: "<button>+</button>"),
   .init(id: "program-js", path: path + "/main.js", source: "notebook.ready();"),
   .init(id: "program-config", path: path + "/program.json", source: String(decoding: try! JSONEncoder().encode(JSONValue.object(["initialState": initialState])), as: UTF8.self))]
}

final class DocumentFileFixture {
  let root: URL, store: NotebookStore, actor = UUID(), id: UUID
  var target: CollaborationTarget { .init(kind: .document, id: id) }
  init(files: [DocumentFile]? = nil) throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("document-files-" + UUID().uuidString)
    store = NotebookStore(root: root)
    _ = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    var index = try store.loadIndex(), board = try store.loadBoard(items: index.items)
    let created = index.createDocument(title: "Files", actor: actor)
    let item = try #require(created); id = item.id
    _ = board.addItem(id, to: index.rootBoardID, near: .zero, actor: actor)
    try store.saveDocumentWorkspaceBundle(index: index,
      document: .init(id: id, actor: actor, files: files ?? notebookProgramFiles() + [.init(id: "section", path: "sections/body.tex", source: "Before")]),
      state: .init(id: id, actor: actor), board: board)
  }
  deinit { try? FileManager.default.removeItem(at: root) }
  func file(_ id: String) throws -> NotebookDocumentFileRead { try #require(try store.readDocumentFile(documentID: self.id, fileID: id)) }
  func prepare(_ edit: DocumentSourceEdit) throws -> PreparedDocumentSourceEdit {
    try .init(edit: edit, workspaceID: store.storedWorkspaceID())
  }
  func patch(_ file: NotebookDocumentFileRead, to source: String) throws -> CollaborationOperation {
    .init(kind: .patchDocumentFile, target: target, id: file.file.id, values: ["expectedVersion": try .encode(file.sourceVersion),
      "range": .object(["location": .number(0), "length": .number(Double(file.file.source.utf16.count))]),
      "expectedText": .string(file.file.source), "source": .string(source)])
  }
  func apply(_ operations: [CollaborationOperation], basis: NotebookReadBasis? = nil) throws -> CollaborationReceipt {
    let base = try basis ?? store.readBasis(targets: [target])
    return try store.applyCollaborationAction(.init(summary: "Файловая правка", expected: base.owners, operations: operations), actor: actor)
  }
  func replica(_ name: String) throws -> NotebookStore {
    let destination = NotebookStore(root: root.appendingPathComponent(name))
    try destination.prepareEmptyWorkspace(workspaceID: store.workspaceHeader().workspaceID)
    try deliver(from: store, to: destination, peer: actor); return destination
  }
  func deliver(from source: NotebookStore, to destination: NotebookStore, peer: UUID) throws {
    let cursor = try destination.peerCursor(peerID: peer, direction: .incoming)
    for change in try source.changeJournal(after: cursor) {
      try stage(change, from: source, to: destination)
      _ = try destination.applyRemoteChange(change, peerID: peer)
    }
  }
  func stage(_ change: NotebookDurableChange, from source: NotebookStore, to destination: NotebookStore) throws {
    for _ in 0..<128 {
      let missing = try destination.missingBlobHashes(for: change)
      if missing.isEmpty { return }
      for hash in missing {
        var bytes = Data(); let size = try source.blobSize(hash: hash)
        while Int64(bytes.count) < size { bytes += try source.readBlobChunk(hash: hash, offset: Int64(bytes.count), maxBytes: 1_048_576) }
        try destination.stageBlob(data: bytes, expectedHash: hash)
      }
    }
    #expect(try destination.missingBlobHashes(for: change).isEmpty)
  }
}

struct NotebookDocumentCodecCounts: Codable, Sendable {
  struct Work: Codable, Sendable {
    var passes = 0
    var encodedBytes: Int64 = 0
    mutating func record(_ bytes: Int) { passes += 1; encodedBytes += Int64(bytes) }
  }
  var documentDecode = Work(), documentEncode = Work(), filesEncode = Work()
}

#if DEBUG
final class NotebookDocumentCodecSamples: @unchecked Sendable {
  private let lock = NSLock()
  private var counts = NotebookDocumentCodecCounts()
  func record(_ sample: NotebookDocumentCodecObservation.Sample) {
    lock.lock(); defer { lock.unlock() }
    switch sample.phase {
    case .documentDecode: counts.documentDecode.record(sample.encodedBytes)
    case .documentEncode: counts.documentEncode.record(sample.encodedBytes)
    case .filesEncode: counts.filesEncode.record(sample.encodedBytes)
    }
  }
  func snapshot() -> NotebookDocumentCodecCounts {
    lock.lock(); defer { lock.unlock() }
    return counts
  }
}
#endif

@Suite("File-backed LaTeX: one writer, exact files and independent programs", .serialized)
struct DocumentFilesTests {
  private final class SourceBlobCopies {
    let hash: String
    var count = 0
    init(hash: String) { self.hash = hash }
    func attach(_ database: NotebookSQLConnection) {
      sqlite3_trace_v2(database.handle, UInt32(SQLITE_TRACE_STMT), { _, pointer, raw, _ in
        guard let pointer, let raw else { return 0 }
        let statement = OpaquePointer(raw)
        guard let sql = sqlite3_sql(statement), String(cString: sql).hasPrefix("SELECT data FROM blobs") else { return 0 }
        let copies = Unmanaged<SourceBlobCopies>.fromOpaque(pointer).takeUnretainedValue()
        guard let expanded = sqlite3_expanded_sql(statement) else { return 0 }
        defer { sqlite3_free(expanded) }
        if String(cString: expanded).contains(copies.hash) { copies.count += 1 }
        return 0
      }, Unmanaged.passUnretained(self).toOpaque())
    }
  }
  @Test func actualFilesAreTheOnlyAuthoredContent() throws {
    let document = DocumentDocument(actor: UUID(), files: [.init(id: "main", path: "main.tex", source: "\\special{papersize=400pt,700pt}")])
    let value = try JSONValue.encode(document)
    #expect(value["format"] == .number(3))
    #expect(value["blocks"] == nil && value["preamble"] == nil && value["paperSize"] == nil)
    #expect(try value.decode(DocumentDocument.self) == document)
    #expect(throws: DecodingError.self) { try value.setting("format", .number(2)).decode(DocumentDocument.self) }
    #expect(!DocumentFile(id: "x", path: "../host.tex").isValid)
    #expect(!DocumentFile(id: "x", path: "/host.tex").isValid)
    #expect(DocumentTemplate.allCases.count == 5)
    #expect(DocumentTemplate.allCases.allSatisfy { $0.files.contains { $0.path == "main.tex" && $0.source.contains("\\begin{document}") } })
  }

  @Test func staleDocumentBasisStillEditsAnUnchangedFileAndBatchConflictIsAtomic() throws {
    let f = try DocumentFileFixture(), basis = try f.store.readBasis(targets: [f.target], includeSource: true)
    let section = try f.file("section"), main = try f.file("main")
    _ = try f.apply([f.patch(main, to: main.file.source + "\n% neighbour")])
    _ = try f.apply([f.patch(section, to: "Human adjacent file")], basis: basis)
    let before = try f.store.loadDocument(f.id), cursor = try f.store.currentChangeCursor()
    #expect(throws: CollaborationError.self) {
      try f.apply([.init(kind: .putDocumentFile, target: f.target, id: "new", values: ["path": .string("new.tex"), "source": .string("new"), "expectedVersion": .null]), f.patch(section, to: "stale")])
    }
    #expect(try f.store.loadDocument(f.id) == before)
    #expect(try f.store.currentChangeCursor() == cursor)
    #expect(try f.store.readDocumentFile(documentID: f.id, fileID: "new") == nil)
  }

  @Test func nativeDraftCommitIsIdempotentSurvivesBadTeXAndUndoPreservesNeighbors() throws {
    let f = try DocumentFileFixture(), file = try f.file("main"), neighbor = try f.file("section")
    let edit = DocumentSourceEdit(sessionID: UUID(), documentID: f.id, fileID: "main", baseSource: file.file.source,
      baseVersion: file.sourceVersion, source: "\\broken{", sequence: 1)
    try f.store.saveDocumentDraft(.init(edit: edit, selectionStart: 2, selectionEnd: 2))
    _ = try f.apply([f.patch(neighbor, to: "Independent")])
    let prepared = try f.prepare(edit)
    #if DEBUG
    let codec = NotebookDocumentCodecSamples()
    let result = try NotebookDocumentCodecObservation.withObserver(codec.record) {
      try f.store.commitDocumentSource(prepared, actor: f.actor)
    }
    let counts = codec.snapshot()
    // Both source SQL cuts and one action candidate remain. Receipt revision
    // also decodes its bounded, source-free content header.
    #expect(counts.documentDecode.passes == 4 && counts.documentDecode.encodedBytes > 0)
    #else
    let result = try f.store.commitDocumentSource(prepared, actor: f.actor)
    #endif
    #expect(result.status == .committed && result.publication?.file.source == edit.source)
    #expect(try f.file("main").sourceVersion == result.publication?.sourceVersion)
    #expect(try f.store.commitDocumentSource(prepared, actor: f.actor) == result)
    let reopened = NotebookStore(root: f.root)
    #expect(try reopened.readDocumentFile(documentID: f.id, fileID: "main")?.file.source == edit.source)
    #expect(try reopened.documentEditingSessions().isEmpty)
    _ = try reopened.undoCollaborationAction(#require(result.actionID), actor: UUID())
    #expect(try f.file("main").file.source == file.file.source)
    #expect(try f.file("section").file.source == "Independent")
    let old = DocumentSourceEdit(sessionID: UUID(), documentID: f.id, fileID: "section", baseSource: neighbor.file.source,
      baseVersion: neighbor.sourceVersion, source: "stale human", sequence: 1)
    #expect(try f.store.commitDocumentSource(f.prepare(old), actor: UUID()).status == .conflict)
    #expect(try f.store.documentEditingSessions().first?.edit.source == "stale human")
  }

  @Test func preparedNativeSourceRejectsPeerABAAndAReplacedWorkspaceBeforeCachedReplay() throws {
    let f = try DocumentFileFixture(), original = try f.file("section")
    let edit = DocumentSourceEdit(sessionID: UUID(), documentID: f.id, fileID: "section",
      baseSource: original.file.source, baseVersion: original.sourceVersion, source: "PreparedOnlyNeedle", sequence: 1)
    let prepared = try f.prepare(edit)
    _ = try f.apply([f.patch(original, to: "PeerNeedle")])
    _ = try f.apply([f.patch(f.file("section"), to: original.file.source)])
    let sourceBefore = try f.file("section"), deliveryBefore = try f.store.currentChangeCursor()
    let refusal = try f.store.commitDocumentSource(prepared, actor: f.actor)
    #expect(refusal.status == .conflict && refusal.actionID == nil)
    #expect(try f.file("section") == sourceBefore)
    #expect(try f.store.currentChangeCursor() == deliveryBefore)
    #expect(try f.store.search("PreparedOnlyNeedle").total == 0)
    #expect(try f.store.documentEditingSessions().contains { $0.edit == edit && $0.phase == .conflict })

    let fresh = try f.prepare(.init(sessionID: UUID(), documentID: f.id, fileID: "section",
      baseSource: sourceBefore.file.source, baseVersion: sourceBefore.sourceVersion, source: "AcceptedNeedle", sequence: 1))
    let accepted = try f.store.commitDocumentSource(fresh, actor: f.actor)
    #expect(accepted.status == .committed)
    try f.store.commandTransaction {
      try f.store.currentSQL!.run("UPDATE metadata SET value=? WHERE key='workspace_id'", [.text(UUID().uuidString.lowercased())])
    }
    let readBefore = try f.store.currentReadCursor(), changedWorkspaceCursor = try f.store.currentChangeCursor()
    do { _ = try f.store.commitDocumentSource(fresh, actor: f.actor); Issue.record("A cached Save crossed workspace identity") }
    catch let error as NotebookStoreError {
      if case .workspaceChanged = error {} else { Issue.record("An unrelated workspace refusal hid the identity guard") }
    }
    #expect(try f.store.currentReadCursor() == readBefore)
    #expect(try f.store.currentChangeCursor() == changedWorkspaceCursor)
    #expect(try f.store.sqlRead {
      try $0.rows("SELECT plain_text FROM search_entries WHERE address=?", [.text(fresh.search.input.address)]).first?[0].text
    } == "AcceptedNeedle")
  }

  @Test func preparedSaveKeepsLiteralUnicodeThroughActionDraftIndexUndoAndRedo() throws {
    let before = "a\u{301}\u{323}", after = "a\u{323}\u{301}"
    #expect(before == after && before.utf16.count == after.utf16.count)
    #expect(!DocumentFile.sourcesAreEqual(before, after))
    #expect(!DocumentFile.sourcesAreEqual(NSString(string: before) as String, NSString(string: after) as String))
    let f = try DocumentFileFixture(files: [.init(id: "main", path: "main.tex", source: before)])
    let file = try f.file("main"), cursor = try f.store.currentChangeCursor()
    let forged = CollaborationOperation(kind: .patchDocumentFile, target: f.target, id: "main", values: [
      "expectedVersion": try .encode(file.sourceVersion),
      "range": .object(["location": .number(0), "length": .number(Double(before.utf16.count))]),
      "expectedText": .string(after), "source": .string("forged")])
    do { _ = try f.apply([forged]); Issue.record("Canonical equivalence authorized a different literal range") }
    catch let error as CollaborationError { #expect(error.code == "file_conflict") }
    #expect(try f.store.currentChangeCursor() == cursor)
    let edit = DocumentSourceEdit(sessionID: UUID(), documentID: f.id, fileID: "main",
      baseSource: before, baseVersion: file.sourceVersion, source: after, sequence: 1)
    let prepared = try f.prepare(edit), result = try f.store.commitDocumentSource(prepared, actor: f.actor)
    let actionID = try #require(result.actionID)
    #expect(result.status == .committed)
    #expect(result.publication?.file.source.utf8.elementsEqual(after.utf8) == true)
    #expect(try f.file("main").file.source.utf8.elementsEqual(after.utf8))
    #expect(try f.file("main").sourceVersion != file.sourceVersion)
    let receipt = try f.store.collaborationAction(actionID)
    #expect(receipt.action.operations.first?.values["source"]?.string?.utf8.elementsEqual(after.utf8) == true)
    #expect(receipt.changes.contains { $0.path.last == .field("source") && $0.after?.string?.utf8.elementsEqual(after.utf8) == true })
    let draft = try f.store.sqlRead { _ in
      try #require(try f.store.storedValue("document-drafts/\(edit.sessionID.uuidString.lowercased()).json")).decode(DocumentEditingSession.self)
    }
    #expect(draft.phase == .committed && draft.edit == edit && draft.committedResult == result)
    #expect(try f.store.sqlRead {
      try $0.rows("SELECT plain_text FROM search_entries WHERE address=?", [.text(prepared.search.input.address)]).first?[0].text?.utf8.elementsEqual(after.utf8)
    } == true)
    let sameIDChangedBytes = try f.prepare(.init(sessionID: edit.sessionID, documentID: f.id, fileID: "main",
      baseSource: before, baseVersion: file.sourceVersion, source: before, sequence: 1))
    do { _ = try f.store.commitDocumentSource(sameIDChangedBytes, actor: f.actor); Issue.record("A completed Save accepted different literal bytes") }
    catch let error as CollaborationError { #expect(error.code == "stale_draft") }
    let cold = NotebookStore(root: f.root)
    _ = try cold.undoNativeAction(actionID, actor: f.actor)
    #expect(try f.file("main").file.source.utf8.elementsEqual(before.utf8))
    _ = try cold.redoNativeAction(actionID, actionID: UUID(), actor: f.actor)
    #expect(try f.file("main").file.source.utf8.elementsEqual(after.utf8))
    #expect(try f.store.search("a", filters: .init(kinds: [.document], target: f.target)).total == 1)
  }

  @Test(arguments: ["draft", "causal", "action"])
  func preparedTinySaveRefusesUnreservedPreviousEnvelopesBeforeTheirBodyCopy(owner: String) throws {
    let f = try DocumentFileFixture(), sessionID: UUID, store: NotebookStore, address: String
    if owner == "action" {
      let receipt = try f.apply([f.patch(f.file("section"), to: String(repeating: "LargeReceipt", count: 32_768))])
      _ = try f.store.undoCollaborationAction(receipt.id, actor: f.actor)
      store = try f.replica("receipt-collision"); sessionID = receipt.id
      address = "collaboration/actions/\(receipt.id.uuidString.lowercased()).json#"
    } else {
      store = f.store; sessionID = UUID()
      if owner == "draft" {
        let source = try f.file("section")
        try store.saveDocumentDraft(.init(edit: .init(sessionID: sessionID, documentID: f.id, fileID: "section",
          baseSource: source.file.source, baseVersion: source.sourceVersion,
          source: String(repeating: "old draft ", count: 131_072), sequence: 1)))
        address = "document-drafts/\(sessionID.uuidString.lowercased()).json#"
      } else {
        _ = try store.saveMergedDocument(try store.loadDocument(f.id).materializingCausalVersions())
        let field = fieldKey(["files", "section", "content"])
        address = documentFile(f.id) + "#/collaboration/fields/@" + fieldKey([field])
        let winner = ContentFieldVersion(stamp: .init(counter: 10, actor: f.actor), human: true)
          .retainingValue(.object(["source": .string("Before")]))
        let loser = ContentFieldVersion(stamp: .init(counter: 1, actor: UUID()), human: false)
          .retainingValue(.object(["source": .string(String(repeating: "retained loser ", count: 32_768))]))
        let version = try winner.joining(loser)
        try store.commandTransaction {
          let previous = try #require(try store.storedFragments(address: address, descendants: false).first)
          _ = try store.writeFragment(previous.replacing(value: .encode(version)), database: store.currentSQL!)
        }
      }
    }
    let source = try #require(try store.readDocumentFile(documentID: f.id, fileID: "section"))
    let prepared = try PreparedDocumentSourceEdit(edit: .init(sessionID: sessionID, documentID: f.id, fileID: "section",
      baseSource: source.file.source, baseVersion: source.sourceVersion, source: "tiny", sequence: 2), workspaceID: store.storedWorkspaceID())
    let hash = try #require(try store.sqlRead { try $0.rows("SELECT hash FROM records WHERE address=?", [.text(address)]).first?[0].text })
    let copies = SourceBlobCopies(hash: hash), readCursor = try store.currentReadCursor(), delivery = try store.currentChangeCursor()
    let draftPath = "document-drafts/\(sessionID.uuidString.lowercased()).json"
    let draftHash = try store.sqlRead { try $0.rows("SELECT hash FROM records WHERE address=?", [.text(draftPath + "#")]).first?[0].text }
    #expect(throws: NotebookStorageError.limitExceeded("document_source_finish")) {
      try store.commandTransaction {
        copies.attach(store.currentSQL!)
        defer { sqlite3_trace_v2(store.currentSQL!.handle, 0, nil, nil) }
        _ = try store.commitDocumentSource(prepared, actor: f.actor)
      }
    }
    #expect(copies.count == 0)
    #expect(try store.currentReadCursor() == readCursor)
    #expect(try store.currentChangeCursor() == delivery)
    #expect(try store.readDocumentFile(documentID: f.id, fileID: "section") == source)
    #expect(try store.sqlRead { try $0.rows("SELECT hash FROM records WHERE address=?", [.text(draftPath + "#")]).first?[0].text } == draftHash)
    #expect(try store.search("tiny").total == 0)
  }

  @Test(arguments: [NotebookStorageFault.beforeCommit, .afterCommit])
  func preparedNativeSourceAndIndexHaveOneRollbackAndUnknownCommitOutcome(_ fault: NotebookStorageFault) throws {
    let f = try DocumentFileFixture(), source = try f.file("section")
    let prepared = try f.prepare(.init(sessionID: UUID(), documentID: f.id, fileID: "section",
      baseSource: source.file.source, baseVersion: source.sourceVersion, source: "PreparedCommitNeedle", sequence: 1))
    let actor = f.actor, witnesses = NotebookAcceptedWriteWitnesses(root: f.root)
    let accepted = NotebookAcceptedWrite(witnesses: witnesses) { try $0.commitDocumentSource(prepared, actor: actor) }
    let failing = NotebookStore(root: f.root) { if $0 == fault { throw CocoaError(.fileWriteUnknown) } }
    let delivery = try f.store.currentChangeCursor(), revision = try f.store.currentReadCursor()
    do { _ = try accepted.apply(to: failing); Issue.record("The actual storage fault did not execute") }
    catch let error as NotebookAcceptedWriteError {
      #expect(error.outcome == (fault == .afterCommit ? .unresolved : .storageUnavailable))
    }
    if fault == .beforeCommit {
      #expect(try f.file("section") == source)
      #expect(try f.store.search("PreparedCommitNeedle").total == 0)
      #expect(try f.store.currentReadCursor() == revision)
      #expect(try f.store.currentChangeCursor() == delivery)
    } else {
      #expect(try f.file("section").file.source == "PreparedCommitNeedle")
      #expect(try f.store.search("PreparedCommitNeedle").total == 1)
      _ = try f.apply([f.patch(f.file("section"), to: "PeerAfterCommitNeedle")])
    }
    let beforeRetry = try f.store.currentChangeCursor()
    let result = try accepted.apply(to: f.store)
    #expect(result.status == .committed && result.publication?.file.source == "PreparedCommitNeedle")
    #expect(try accepted.apply(to: f.store) == result)
    if fault == .afterCommit {
      #expect(try f.file("section").file.source == "PeerAfterCommitNeedle")
      #expect(try f.store.search("PreparedCommitNeedle").total == 0)
      #expect(try f.store.search("PeerAfterCommitNeedle").total == 1)
      #expect(try f.store.currentChangeCursor() == beforeRetry)
    }
    try witnesses.flush(in: f.store)
  }

  @Test(arguments: [false, true])
  func preparedNativeSourcePreservesTheStoredUUIDSpellingAndUnicodeOrDeletesItsIndex(clear: Bool) throws {
    let rawID = "F61E5732-3721-4E72-9C74-D5C9171C1380"
    let f = try DocumentFileFixture(files: [.init(id: rawID, path: "main.tex", source: "OldNeedle")])
    let file = try f.file(rawID.lowercased())
    let source = clear ? " \t\r\n\u{a0}\u{2003} " : " \tCafe\u{301} <VectorNeedle> Русский 😀 nul\0tail \r\n終わり "
    let prepared = try f.prepare(.init(sessionID: UUID(), documentID: f.id, fileID: rawID.lowercased(),
      baseSource: file.file.source, baseVersion: file.sourceVersion, source: source, sequence: 1))
    let result = try f.store.commitDocumentSource(prepared, actor: f.actor)
    #expect(result.status == .committed && result.publication?.file.id == rawID)
    #expect(try f.file(rawID).file.source.utf8.elementsEqual(source.utf8))
    #expect(try f.store.search("OldNeedle").total == 0)
    if clear { #expect(try f.store.search("cafe").total == 0) }
    else {
      for query in ["cafe", "<VectorNeedle>", "РУС", "😀", "tail", "終"] {
        let result = try f.store.search(query)
        #expect(result.results.first?.elementID == rawID)
      }
      let acceptedHash = try f.store.sqlRead { database in
        try database.rows("SELECT hash FROM records WHERE address=?", [.text(prepared.search.input.address)]).first?[0].text
      }
      let cursor = try f.store.currentChangeCursor()
      #expect(try f.store.commitDocumentSource(prepared, actor: f.actor) == result)
      #expect(try f.store.currentChangeCursor() == cursor)
      #expect(try f.store.sqlRead {
        try $0.rows("SELECT hash FROM records WHERE address=?", [.text(prepared.search.input.address)]).first?[0].text
      } == acceptedHash)
    }
  }

  @Test func nativeFileRedoRetainsOrderedEditsAcrossReopeningWithoutTouchingNeighborsOrState() throws {
    let f = try DocumentFileFixture()
    let program = try f.store.documentProgramSource(documentID: f.id, instanceID: "counter", path: "programs/counter")
    _ = try f.store.checkpointDocumentState(documentID: f.id, programID: program.id, programPath: program.path,
      value: .number(7), sourceBasis: program.sourceBasis, stateVersion: nil, actor: f.actor)
    let state = try f.store.loadDocumentState(f.id)
    var actions: [UUID] = []
    for source in ["First", "Second"] {
      let file = try f.file("section")
      let prepared = try f.prepare(.init(sessionID: UUID(), documentID: f.id,
        fileID: file.file.id, baseSource: file.file.source, baseVersion: file.sourceVersion,
        source: source, sequence: 1))
      let result = try f.store.commitDocumentSource(prepared, actor: f.actor)
      actions.append(try #require(result.actionID))
    }
    for id in actions.reversed() { _ = try f.store.undoNativeAction(id, actor: f.actor) }
    #expect(try f.file("section").file.source == "Before")
    let main = try f.file("main"), neighbor = main.file.source + "\n% independent agent edit"
    _ = try f.apply([f.patch(main, to: neighbor)])
    let cold = NotebookStore(root: f.root)
    for (id, source) in zip(actions, ["First", "Second"]) {
      let repeatedID = UUID()
      let repeated = try cold.redoNativeAction(id, actionID: repeatedID, actor: f.actor)
      #expect(repeated.redoOf == id)
      #expect(try cold.redoNativeAction(id, actionID: repeatedID, actor: f.actor) == repeated)
      #expect(try f.file("section").file.source == source)
    }
    #expect(try f.file("main").file.source == neighbor)
    #expect(try cold.loadDocumentState(f.id) == state)
    #expect(try cold.nativeRedoHistory(domain: .document(f.id), actor: f.actor).isEmpty)
  }

  @Test(arguments: [CollaborationOperation.Kind.putDocumentFile, .renameDocumentFile, .removeDocumentFile])
  func nativeFileLifecycleRedoUsesTheExistingCausalInverse(_ kind: CollaborationOperation.Kind) throws {
    let f = try DocumentFileFixture(), main = try f.file("main"), section = try f.file("section")
    let operation: CollaborationOperation
    switch kind {
    case .putDocumentFile:
      operation = .init(kind: kind, target: f.target, id: "new", values: ["path": .string("new.tex"),
        "source": .string("New"), "expectedVersion": .null])
    case .renameDocumentFile:
      operation = .init(kind: kind, target: f.target, id: main.file.id, values: ["path": .string("book.tex"),
        "expectedVersion": try .encode(main.sourceVersion)])
    default:
      operation = .init(kind: kind, target: f.target, id: section.file.id,
        values: ["expectedVersion": try .encode(section.sourceVersion)])
    }
    let receipt = try f.store.applyCollaborationActionImmediately(.init(summary: "Native file action",
      expected: f.store.readBasis(targets: [f.target]).owners, operations: [operation]),
      actor: f.actor, requestFingerprint: nil, human: true)
    let accepted = try f.store.loadDocument(f.id)
    _ = try f.store.undoNativeAction(receipt.id, actor: f.actor)
    let cold = NotebookStore(root: f.root)
    let repeated = try cold.redoNativeAction(receipt.id, actionID: UUID(), actor: f.actor)
    #expect(try cold.loadDocument(f.id).files == accepted.files)
    #expect(try cold.loadDocument(f.id).entrypoint == accepted.entrypoint)
    _ = try cold.undoNativeAction(repeated.id, actor: f.actor)
    #expect(try f.file("main").file == main.file)
    #expect(try f.file("section").file == section.file)
    #expect(try cold.readDocumentFile(documentID: f.id, fileID: "new") == nil)
  }

  @Test func nativeFileRedoRejectsSameValuedPeerABA() throws {
    let f = try DocumentFileFixture(), file = try f.file("section")
    let prepared = try f.prepare(.init(sessionID: UUID(), documentID: f.id,
      fileID: file.file.id, baseSource: file.file.source, baseVersion: file.sourceVersion,
      source: "Human", sequence: 1))
    let result = try f.store.commitDocumentSource(prepared, actor: f.actor)
    let id = try #require(result.actionID)
    _ = try f.store.undoNativeAction(id, actor: f.actor)
    _ = try f.apply([f.patch(f.file("section"), to: "Peer")])
    _ = try f.apply([f.patch(f.file("section"), to: file.file.source)])
    #expect(throws: CollaborationError.self) { try f.store.redoNativeAction(id, actionID: UUID(), actor: f.actor) }
    #expect(try f.file("section").file.source == file.file.source)
  }

  @Test func renameKeepsIdentityUpdatesEntrypointAndRejectsCollidingOrStaleEdits() throws {
    let f = try DocumentFileFixture(), main = try f.file("main")
    let renamed = try f.store.renameDocumentFile(documentID: f.id, fileID: "main", path: "book.tex", actor: f.actor)
    #expect(renamed.document.entrypoint == "book.tex")
    #expect(try f.file("main").file.id == "main")
    #expect(try f.file("main").sourceVersion != main.sourceVersion)
    #expect(throws: CollaborationError.self) { try f.apply([f.patch(main, to: "stale")]) }
    #expect(throws: CollaborationError.self) { try f.store.insertDocumentFile(documentID: f.id, path: "book.tex", actor: f.actor) }
    let directory = try f.store.readDocumentDirectory(documentID: f.id)
    #expect(directory.entrypoint == "book.tex" && directory.files.count == 5)
    #expect(directory.files.first { $0.id == "main" }?.byteCount == main.file.byteCount)
  }

  @Test func sourceIndexNamesRealFilesAndUTF16Offsets() throws {
    let f = try DocumentFileFixture(files: [.init(id: "main", path: "main.tex", source: "\\input{sections/one}"),
      .init(id: "one", path: "sections/one.tex", source: "😀\\section{One}\n% \\label{ignored}\n\\label{real}\n\\ref{real}")])
    let index = try f.store.readDocumentStructure(documentID: f.id)
    #expect(index.entries.map(\.text) == ["One", "real", "real"])
    #expect(index.entries[0].utf16Offset == 2 && index.entries[0].fileID == "one")
    #expect(index.entries[1].line == 3 && index.entries[1].path == "sections/one.tex")
  }

  @Test func sourceIndexRetainsNestedTitlesAndSkipsVerbatimExamples() throws {
    let source = #"\section[Short]{Nested \emph{title}}"# + "\n" + #"\caption{First"# + "\n" + #"second \textbf{line}}"# + "\n"
      + #"\verb|\label{ignored}|"# + "\n" + #"\begin{verbatim}\label{also-ignored}\end{verbatim}"# + "\n"
      + #"\NotebookInteractive[id=osc,width=100pt,height=50pt]{programs/osc}"#
    let document = DocumentDocument(actor: UUID(), files: [.init(id: "main", path: "main.tex", source: source)])
    let entries = DocumentStructure(document: document).entries
    #expect(entries.count == 3)
    #expect(entries[0].text == #"Nested \emph{title}"#)
    #expect(entries[1].text == "First\nsecond \\textbf{line}" && entries[1].line == 2)
    #expect(entries[2].instanceID == "osc" && entries[2].text == "programs/osc" && entries[2].line == 6)
  }

  @Test func programIdentityIgnoresLayoutButIncludesABAAndRejectsLateCheckpoints() throws {
    let f = try DocumentFileFixture()
    let before = try f.store.documentProgramSource(documentID: f.id, instanceID: "counter", path: "programs/counter")
    let publication = try #require(try f.store.checkpointDocumentState(documentID: f.id, programID: before.id, programPath: before.path,
      value: .null, sourceBasis: before.sourceBasis, stateVersion: nil, actor: f.actor))
    _ = try f.apply([f.patch(f.file("main"), to: "Reflow, not a source change for the program")])
    let reflow = try f.store.documentProgramSource(documentID: f.id, instanceID: before.id, path: before.path)
    #expect(reflow.sourceBasis == before.sourceBasis && reflow.programPackage == before.programPackage)
    let script = try f.file("program-js")
    _ = try f.apply([f.patch(script, to: script.file.source + "// changed")])
    _ = try f.apply([f.patch(f.file("program-js"), to: script.file.source)])
    let changed = try f.store.documentProgramSource(documentID: f.id, instanceID: before.id, path: before.path)
    #expect(changed.programPackage == before.programPackage && changed.sourceBasis != before.sourceBasis)
    #expect(try f.store.checkpointDocumentState(documentID: f.id, programID: before.id, programPath: before.path,
      value: .number(99), sourceBasis: before.sourceBasis, stateVersion: publication.record.valueVersion, actor: f.actor) == nil)
    #expect(try f.store.loadDocumentState(f.id).value(for: before.id) == .null)
  }

  @Test func checkpointPublicationPreservesOtherInstancesAndReturnsTheStoredClockOnNoOp() throws {
    let f = try DocumentFileFixture()
    let source = try f.store.documentProgramSource(documentID: f.id, instanceID: "counter", path: "programs/counter")
    let publication = try #require(try f.store.checkpointDocumentState(documentID: f.id, programID: source.id,
      programPath: source.path, value: .number(3), sourceBasis: source.sourceBasis, stateVersion: nil, actor: f.actor))
    var local = DocumentStateJournal(id: f.id, actor: f.actor)
    let contact = local.commit(instanceID: "other", value: .number(7), actor: f.actor)
    #expect(contact)
    let neighbor = try #require(local.records.first { $0.id == "other" })
    let merged = local.merge(publication)
    #expect(merged && local.value(for: source.id) == .number(3))
    #expect(local.records.first { $0.id == "other" } == neighbor)
    #expect(local.stamp.counter == publication.journalStamp.counter + 1)
    let combinationStamp = local.stamp
    let retried = local.merge(publication)
    #expect(!retried && local.stamp == combinationStamp)

    var stored = try f.store.loadDocumentState(f.id)
    let advanced = stored.commit(instanceID: "other", value: .number(11), actor: f.actor)
    #expect(advanced)
    try f.store.saveDocumentState(stored)
    let cursor = try f.store.currentChangeCursor()
    let unchanged = try #require(try f.store.checkpointDocumentState(documentID: f.id, programID: source.id,
      programPath: source.path, value: .number(3), sourceBasis: source.sourceBasis,
      stateVersion: publication.record.valueVersion, actor: f.actor))
    #expect(unchanged.record == publication.record && unchanged.journalStamp == stored.stamp)
    #expect(try f.store.currentChangeCursor() == cursor)
  }

  @Test(arguments: [true, false])
  func replicatedSameDotSourceMutationRefusesTheWholeDelivery(unicode: Bool) throws {
    let before = unicode ? "a\u{301}\u{323}" : "original"
    let after = unicode ? "a\u{323}\u{301}" : "changed"
    let f = try DocumentFileFixture(files: [.init(id: "main", path: "main.tex", source: before),
      .init(id: "other", path: "other.tex", source: "unchanged neighbour")])
    let peer = try f.replica("same-dot"), original = try peer.loadDocument(f.id)
    // Preserve every causal field and change only the literal source bytes.
    let forged = try JSONValue.encode(original).setting("files", .array(try original.files.map {
      try .encode($0.id == "main" ? $0.replacingSource(after) : $0)
    })).decode(DocumentDocument.self)
    #expect(forged.isValid && forged.fileVersion(fileID: "main") == original.fileVersion(fileID: "main"))
    #expect(!DocumentFile.sourcesAreEqual(before, after))
    if unicode { #expect(before == after) }
    try refuseDocumentDelivery(forged, from: peer, fixture: f)
  }

  @Test func replicatedLosingSourceHeadCannotChangeItsLiteralPayload() throws {
    let before = "a\u{301}\u{323}", after = "a\u{323}\u{301}"
    let f = try DocumentFileFixture(files: [.init(id: "main", path: "main.tex", source: "base"),
      .init(id: "other", path: "other.tex", source: "unchanged neighbour")])
    let low = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    let high = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    var losing = try f.store.loadDocument(f.id), winner = losing
    let changedLosing = losing.replaceFileSource(id: "main", source: before, actor: low)
    let changedWinner = winner.replaceFileSource(id: "main", source: "visible winner", actor: high)
    #expect(changedLosing && changedWinner)
    try losing.merge(winner)
    #expect(losing.files[0].source == "visible winner")
    try f.store.saveDocument(losing)
    let peer = try f.replica("losing-dot"), original = try peer.loadDocument(f.id)
    let key = fieldKey(["files", "main", "content"])
    var fields = try #require(try JSONValue.encode(original)["collaboration"]?["fields"]).object
    var version = try #require(fields[key]).object
    var heads = try #require(version["heads"]).array
    #expect(heads.count == 2)
    let index = try #require(heads.firstIndex { $0["stamp"]?["actor"]?.string.flatMap(UUID.init(uuidString:)) == low })
    let body = try #require(heads[index]["value"])
    #expect(body["source"]?.string?.utf8.elementsEqual(before.utf8) == true)
    heads[index] = heads[index].setting("value", body.setting("source", .string(after)))
    version["heads"] = .array(heads); fields[key] = .object(version)
    let forged = try JSONValue.encode(original).setting("collaboration", .object(["fields": .object(fields)]))
      .decode(DocumentDocument.self)
    #expect(forged.isValid && forged.files == original.files)
    #expect(forged != original)
    #expect(forged.fileVersion(fileID: "main") == original.fileVersion(fileID: "main"))
    try refuseDocumentDelivery(forged, from: peer, fixture: f)
  }

  private func refuseDocumentDelivery(_ forged: DocumentDocument, from peer: NotebookStore,
    fixture f: DocumentFileFixture) throws {
    let peerID = UUID()
    try f.deliver(from: peer, to: f.store, peer: peerID)
    let before = try f.store.loadDocument(f.id)
    func hashes() throws -> [String: String] {
      try f.store.sqlRead { database in
        Dictionary(uniqueKeysWithValues: try database.rows("SELECT address,hash FROM records WHERE file=?", [.text(documentFile(f.id))])
          .map { ($0[0].text!, $0[1].text!) })
      }
    }
    let rows = try hashes(), read = try f.store.currentReadCursor(), authored = try f.store.currentChangeCursor()
    let incoming = try f.store.peerCursor(peerID: peerID, direction: .incoming)
    let sent = try peer.currentChangeCursor()
    // A valid new header is applied before the corrupted file. Refusal must
    // roll it back with the source, accepted marker, and both journal cursors.
    var publication = forged
    let changedHeader = publication.replaceContent(entrypoint: "other.tex", actor: peerID)
    #expect(changedHeader)
    #expect(publication.fileVersion(fileID: "main") == forged.fileVersion(fileID: "main"))
    #expect(publication.isValid)
    // Construct an untrusted peer packet below local typed merge admission;
    // the existing publisher still owns its transaction, journal, and hashes.
    try peer.publishCollaboration(writes: [documentFile(publication.id): try .encode(publication)])
    let changes = try peer.changeJournal(after: sent)
    #expect(changes.count == 1)
    let change = try #require(changes.last)
    try f.stage(change, from: peer, to: f.store)
    #expect(try f.store.missingBlobHashes(for: change).isEmpty)
    do {
      _ = try f.store.applyRemoteChange(change, peerID: peerID)
      Issue.record("An immutable source dot accepted another literal payload")
    } catch let error as NotebookStorageError {
      #expect(error == .invalidTransaction("content author value changed"))
    }
    #expect(try f.store.loadDocument(f.id) == before)
    #expect(try hashes() == rows) // Includes hidden-head bytes, whose JSON == may be canonical-equivalent.
    #expect(try f.store.currentReadCursor() == read)
    #expect(try f.store.currentChangeCursor() == authored)
    #expect(try f.store.peerCursor(peerID: peerID, direction: .incoming) == incoming)
    #expect(try f.store.sqlRead {
      try $0.rows("SELECT count(*) FROM received_transactions WHERE transaction_id=?",
        [.text(change.transactionID.uuidString.lowercased())]).first?[0].integer
    } == 0)
  }

  @Test func replicatedNewDotNormalizationSaveKeepsExactSourceThroughColdUndoAndRedo() throws {
    let before = "a\u{301}\u{323}", after = "a\u{323}\u{301}"
    let f = try DocumentFileFixture(files: [.init(id: "main", path: "main.tex", source: before)])
    let peer = try f.replica("literal-save"), file = try f.file("main")
    let prepared = try f.prepare(.init(sessionID: UUID(), documentID: f.id, fileID: "main",
      baseSource: before, baseVersion: file.sourceVersion, source: after, sequence: 1))
    let result = try f.store.commitDocumentSource(prepared, actor: f.actor)
    let actionID = try #require(result.actionID)
    #expect(result.status == .committed)
    try f.deliver(from: f.store, to: peer, peer: f.actor)
    let coldPeer = NotebookStore(root: peer.root)
    var delivered = try coldPeer.loadDocument(f.id)
    #expect(delivered.files[0].source.utf8.elementsEqual(after.utf8))
    #expect(delivered.fileVersion(fileID: "main") == (try f.file("main")).sourceVersion)
    #expect(delivered.fileVersion(fileID: "main") != file.sourceVersion)
    let noChange = try delivered.merge(delivered)
    #expect(!noChange)
    let read = try peer.currentReadCursor(), authored = try peer.currentChangeCursor()
    let latest = try #require(try f.store.changeJournal(after: 0).last)
    _ = try peer.applyRemoteChange(latest, peerID: f.actor)
    #expect(try peer.currentReadCursor() == read && peer.currentChangeCursor() == authored)
    let coldAuthor = NotebookStore(root: f.root)
    _ = try coldAuthor.undoNativeAction(actionID, actor: f.actor)
    try f.deliver(from: coldAuthor, to: peer, peer: f.actor)
    #expect(try coldPeer.loadDocument(f.id).files[0].source.utf8.elementsEqual(before.utf8))
    _ = try coldAuthor.redoNativeAction(actionID, actionID: UUID(), actor: f.actor)
    try f.deliver(from: coldAuthor, to: peer, peer: f.actor)
    #expect(try coldPeer.loadDocument(f.id).files[0].source.utf8.elementsEqual(after.utf8))
  }

  @Test func replicationReopensIndependentFilesAndStateWithoutASecondSource() throws {
    let f = try DocumentFileFixture(), b = try f.replica("peer"), peer = UUID()
    _ = try f.apply([f.patch(f.file("section"), to: "A section")])
    var remote = try b.loadDocument(f.id)
    let remoteChanged = remote.replaceFileSource(id: "main", source: "B main", actor: peer); #expect(remoteChanged); try b.saveMergedDocument(remote)
    try f.deliver(from: f.store, to: b, peer: f.actor)
    try f.deliver(from: b, to: f.store, peer: peer)
    let final = try f.store.loadDocument(f.id)
    #expect(final.files.first { $0.id == "main" }?.source == "B main")
    #expect(final.files.first { $0.id == "section" }?.source == "A section")
    let peerDocument = try b.loadDocument(f.id)
    // Delivery may have a different local header frontier; authored files and
    // their causal versions, rather than that delivery counter, must converge.
    #expect(peerDocument.files == final.files && peerDocument.entrypoint == final.entrypoint)
    #expect(peerDocument.collaboration == final.collaboration)
    #expect(try NotebookStore(root: b.root).loadDocument(f.id) == peerDocument)
    let source = try f.store.documentProgramSource(documentID: f.id, instanceID: "counter", path: "programs/counter")
    let peerSource = try b.documentProgramSource(documentID: f.id, instanceID: "counter", path: "programs/counter")
    #expect(peerSource.sourceBasis == source.sourceBasis)
    #expect(peerDocument.fileVersion(fileID: "main") == final.fileVersion(fileID: "main"))
    _ = try f.store.checkpointDocumentState(documentID: f.id, programID: source.id, programPath: source.path,
      value: .number(8), sourceBasis: source.sourceBasis, stateVersion: nil, actor: f.actor)
    try f.deliver(from: f.store, to: b, peer: f.actor)
    #expect(try b.loadDocumentState(f.id).value(for: "counter") == .number(8))
  }

  @Test func causalMergePreservesUnrelatedFileAndDoesNotResurrectDeletedSourceOnLateReceipt() throws {
    let actor = UUID(), f = try DocumentFileFixture()
    var left = try f.store.loadDocument(f.id), right = left
    let leftChanged = left.replaceFileSource(id: "main", source: "A", actor: actor); #expect(leftChanged)
    let rightChanged = right.replaceFileSource(id: "section", source: "B", actor: UUID()); #expect(rightChanged)
    try left.merge(right)
    #expect(left.files.first { $0.id == "main" }?.source == "A")
    #expect(left.files.first { $0.id == "section" }?.source == "B")
    let publication = try #require(DocumentFileSourcePublication(document: left, fileID: "main"))
    let removed = left.replaceContent(files: left.files.filter { $0.id != "main" }, actor: actor); #expect(removed)
    let deleted = left
    let merged = try left.mergeSource(publication); #expect(!merged && left == deleted)
  }
}

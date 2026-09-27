import Foundation
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
      for _ in 0..<128 {
        let missing = try destination.missingBlobHashes(for: change)
        if missing.isEmpty { break }
        for hash in missing {
          var bytes = Data(); let size = try source.blobSize(hash: hash)
          while Int64(bytes.count) < size { bytes += try source.readBlobChunk(hash: hash, offset: Int64(bytes.count), maxBytes: 1_048_576) }
          try destination.stageBlob(data: bytes, expectedHash: hash)
        }
      }
      _ = try destination.applyRemoteChange(change, peerID: peer)
    }
  }
}

@Suite("File-backed LaTeX: one writer, exact files and independent programs", .serialized)
struct DocumentFilesTests {
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
    let result = try f.store.commitDocumentSource(edit: edit, actor: f.actor)
    #expect(result.status == .committed && result.publication?.file.source == edit.source)
    #expect(try f.store.commitDocumentSource(edit: edit, actor: f.actor) == result)
    let reopened = NotebookStore(root: f.root)
    #expect(try reopened.readDocumentFile(documentID: f.id, fileID: "main")?.file.source == edit.source)
    #expect(try reopened.documentEditingSessions().isEmpty)
    _ = try reopened.undoCollaborationAction(#require(result.actionID), actor: UUID())
    #expect(try f.file("main").file.source == file.file.source)
    #expect(try f.file("section").file.source == "Independent")
    let old = DocumentSourceEdit(sessionID: UUID(), documentID: f.id, fileID: "section", baseSource: neighbor.file.source,
      baseVersion: neighbor.sourceVersion, source: "stale human", sequence: 1)
    #expect(try f.store.commitDocumentSource(edit: old, actor: UUID()).status == .conflict)
    #expect(try f.store.documentEditingSessions().first?.edit.source == "stale human")
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
      let result = try f.store.commitDocumentSource(edit: .init(sessionID: UUID(), documentID: f.id,
        fileID: file.file.id, baseSource: file.file.source, baseVersion: file.sourceVersion,
        source: source, sequence: 1), actor: f.actor)
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
    let result = try f.store.commitDocumentSource(edit: .init(sessionID: UUID(), documentID: f.id,
      fileID: file.file.id, baseSource: file.file.source, baseVersion: file.sourceVersion,
      source: "Human", sequence: 1), actor: f.actor)
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
    _ = left.merge(right)
    #expect(left.files.first { $0.id == "main" }?.source == "A")
    #expect(left.files.first { $0.id == "section" }?.source == "B")
    let publication = try #require(DocumentFileSourcePublication(document: left, fileID: "main"))
    let removed = left.replaceContent(files: left.files.filter { $0.id != "main" }, actor: actor); #expect(removed)
    let deleted = left
    let merged = left.mergeSource(publication); #expect(!merged && left == deleted)
  }
}

import CSQLite
import Foundation
import Testing
@testable import NotebookCore

@Suite("Native source commit addresses one program and its durable draft", .serialized)
struct NotebookDocumentSourceCommandTests {
  private let blockID = "text/a~😀"

  private func fixture(_ body: (NotebookStore, UUID, DocumentDocument) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-source-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    let document = DocumentDocument(actor: actor, blocks: [
      .interactive(id: blockID, html: "Before", css: "button{color:blue}", initialState: .number(3)),
      .markdown(id: "foreign", source: String(repeating: "x", count: 1_000_000)),
      .markdown(id: blockID + "/child", source: "Independent")])
    let index = WorkspaceIndex(items: [.document(id: document.id, title: "Source edit")],
      selectedItemID: document.id, selectedPageID: nil, stamp: .init(counter: 0, actor: actor))
    try store.saveDocumentWorkspaceBundle(index: index, document: document,
      state: .init(id: document.id, actor: actor),
      board: .initial(rootBoardID: index.rootBoardID, itemIDs: [document.id], actor: actor))
    try body(store, actor, store.loadDocument(document.id))
  }

  private func edit(_ document: DocumentDocument, source: String = "After", blockID: String? = nil) -> DocumentSourceEdit {
    let id = blockID ?? self.blockID
    return .init(sessionID: UUID(), documentID: document.id, blockID: id,
      baseSource: document.blocks.first { collaborationIdentity($0.id) == collaborationIdentity(id) }!.source,
      baseVersion: document.sourceVersion(blockID: id), source: source, sequence: 1)
  }

  @Test func ninetyNineThousandUnrelatedClocksAndAnInvalidForeignProgramStayUnread() throws {
    try fixture { store, actor, document in
      let file = documentFile(document.id), root = file + "#"
      try store.commandTransaction {
        for index in 0..<99_000 {
          let key = fieldKey(["blocks", "retired-\(index)", "content"])
          try store.writeFragment(.init(address: root + "/collaboration/fields/@" + fieldKey([key]), file: file,
            parent: root, collection: "collaboration/fields", member: key, position: 0,
            value: .encode(ContentFieldVersion(stamp: document.contentStamp, human: true)), collections: []), database: store.currentSQL!)
        }
        let hash = try store.currentSQL!.putBlob(Data("unrequested program or clock".utf8))
        for address in [root + "/blocks/@foreign", root + "/collaboration/fields/@" + fieldKey([fieldKey(["blocks", "retired-50000", "content"])])] {
          try store.currentSQL!.run("UPDATE records SET hash=? WHERE address=?", [.text(hash), .text(address)])
        }
      }
      let before = try recordIndex(store, file: file), cursor = try store.currentChangeCursor(), request = edit(document)
      try store.saveDocumentDraft(.init(edit: request, selectionStart: 2, selectionEnd: 2))
      let result = try bounded(store) { try store.commitDocumentSource(edit: request, actor: actor) }
      let publication = try #require(result.publication)
      #expect(result.status == .committed && publication.block.source == "After")
      #expect(publication.fields.count == 7 && publication.fields.values.allSatisfy(\.human))
      #expect(publication.block.css == document.blocks[0].css && publication.block.initialState == .number(3))
      #expect(try store.documentEditingSessions().isEmpty)
      let committed = try store.currentChangeCursor()
      #expect(committed == cursor + 1)
      let repeated = try bounded(store) { try store.commitDocumentSource(edit: request, actor: actor) }
      #expect(try repeated == result && store.currentChangeCursor() == committed)
      let changed = Set(try store.readChangedAddresses(after: cursor, through: committed).addresses)
      #expect(!changed.contains(root + "/blocks/@foreign"))
      #expect(!changed.contains { $0.hasPrefix(stateFile(document.id)) })
      let after = try recordIndex(store, file: file)
      #expect(after.count == before.count)
      #expect(after.filter { !changed.contains($0[0]) } == before.filter { !changed.contains($0[0]) })
      // The UI merges the receipt into its own complete document, never a
      // returned archive with two unrequested programs silently missing.
      var visible = document, expected = document
      let applied = visible.mergeSource(publication)
      let expectedApplied = expected.replaceBlockSource(id: blockID, source: request.source, actor: actor)
      #expect(applied && expectedApplied && visible == expected)

      let missingKey = fieldKey(["blocks", blockID, "css"])
      try store.commandTransaction {
        try store.removeFragment(root + "/collaboration/fields/@" + fieldKey([missingKey]), database: store.currentSQL!)
        let count = try store.currentSQL!.rows("SELECT count(*) FROM records WHERE parent=? AND collection='collaboration/fields'", [.text(root)]).first![0].integer!
        for index in Int(count)..<CollaborativeContent.maximumFieldCount {
          let key = "retired-filled-\(index)"
          try store.writeFragment(.init(address: root + "/collaboration/fields/@" + fieldKey([key]), file: file,
            parent: root, collection: "collaboration/fields", member: key, position: 0,
            value: .encode(ContentFieldVersion(stamp: document.contentStamp, human: true)), collections: []), database: store.currentSQL!)
        }
      }
      let overflow = edit(visible, source: "Must remain a draft")
      try store.saveDocumentDraft(.init(edit: overflow))
      let beforeOverflow = try store.currentChangeCursor()
      #expect(throws: NotebookStorageError.limitExceeded("document_causal_fields")) {
        try store.commitDocumentSource(edit: overflow, actor: actor)
      }
      #expect(try store.currentChangeCursor() == beforeOverflow)
      #expect(try store.documentEditingSessions().first?.phase == .editing)
      #expect(try store.readDocumentBlock(documentID: document.id, blockID: blockID)?.block.source == "After")
    }
  }

  @Test func committedSourcePreservesConcurrentCSSOrderPreambleAndNewerHumanText() throws {
    try fixture { store, actor, document in
      let result = try store.commitDocumentSource(edit: edit(document), actor: actor)
      let publication = try #require(result.publication)
      var visible = document
      let cssBlocks = document.blocks.map { $0.id == blockID ? DocumentBlock.interactive(id: blockID,
        html: $0.html, css: "button{color:red}", initialState: $0.initialState) : $0 }
      let rearranged = visible.replaceContent(preamble: "Human preamble", blocks: Array(cssBlocks.reversed()), actor: UUID())
      #expect(rearranged)
      let priorOrder = visible.blocks.map(\.id)
      let merged = visible.mergeSource(publication)
      #expect(merged && visible.blocks.map(\.id) == priorOrder && visible.preamble == "Human preamble")
      #expect(visible.blocks.last?.source == "After" && visible.blocks.last?.css == "button{color:red}")
      let changedAgain = visible.replaceBlockSource(id: blockID, source: "Later human text", actor: UUID())
      #expect(changedAgain)
      let later = visible
      _ = visible.mergeSource(publication)
      #expect(visible.blocks == later.blocks && visible.contentStamp == later.contentStamp)
      let removed = visible.replaceContent(blocks: visible.blocks.filter { $0.id != blockID }, actor: actor)
      #expect(removed)
      let beforeLateCallback = visible
      let resurrected = visible.mergeSource(publication)
      #expect(!resurrected && visible == beforeLateCallback)
    }
  }

  @Test func UUIDAliasesReachTheSameCausalSourceAndDoNotReplaceTheStoredID() throws {
    try fixture { store, actor, document in
      let id = UUID().uuidString
      var replacement = document
      let changed = replacement.replaceContent(blocks: [.markdown(id: id, source: "Before")], actor: actor)
      #expect(changed)
      try store.saveDocument(replacement)
      replacement = try store.loadDocument(document.id)
      let result = try store.commitDocumentSource(edit: edit(replacement, blockID: id.lowercased()), actor: actor)
      #expect(result.status == .committed && result.publication?.block.id == id)
      #expect(try store.loadDocument(document.id).sourceVersion(blockID: id).human)
    }
  }

  @Test(arguments: ["bytes", "fragments"])
  func admissionRejectsBeforeDecodingTheFirstAddressedBody(kind: String) throws {
    try fixture { store, actor, original in
      var document = original
      let state: JSONValue = kind == "bytes" ? .string(String(repeating: "x", count: 4 * 1_024 * 1_024))
        : .object(["blocks": .array((0..<4_096).map { .object(["id": .string("child-\($0)")]) })])
      let changed = document.replaceContent(blocks: [.interactive(id: blockID, html: "Before", initialState: state)], actor: actor)
      #expect(changed)
      try store.saveDocument(document)
      document = try store.loadDocument(document.id)
      if kind == "fragments" {
        try store.commandTransaction {
          let hash = try store.currentSQL!.putBlob(Data("invalid first source".utf8))
          try store.currentSQL!.run("UPDATE records SET hash=? WHERE address=?", [.text(hash), .text(documentFile(document.id) + "#/blocks/@" + fieldKey([blockID]))])
        }
      }
      let request = edit(document), cursor = try store.currentChangeCursor()
      #expect(throws: NotebookStorageError.limitExceeded("document_source_edit")) {
        try store.commitDocumentSource(edit: request, actor: actor)
      }
      #expect(try store.currentChangeCursor() == cursor)
      #expect(try store.documentEditingSessions().isEmpty)
    }
  }

  private enum Fault: Error { case injected }
  @Test(arguments: [NotebookStorageFault.afterRecordWrites, .beforeCommit, .afterCommit])
  func sourceDraftAndDeliveryHaveOneFailureBoundary(fault: NotebookStorageFault) throws {
    try fixture { store, actor, document in
      let request = edit(document), cursor = try store.currentChangeCursor()
      try store.saveDocumentDraft(.init(edit: request))
      let failing = NotebookStore(root: store.root) { point in
        if String(describing: point) == String(describing: fault) { throw Fault.injected }
      }
      #expect(throws: Fault.self) { try failing.commitDocumentSource(edit: request, actor: actor) }
      if case .afterCommit = fault {
        #expect(try store.loadDocument(document.id).blocks[0].source == "After")
        #expect(try store.documentEditingSessions().isEmpty)
        #expect(try store.currentChangeCursor() == cursor + 1)
      } else {
        #expect(try store.loadDocument(document.id) == document)
        #expect(try store.documentEditingSessions().first?.phase == .editing)
        #expect(try store.currentChangeCursor() == cursor)
      }
      #expect(try store.commitDocumentSource(edit: request, actor: actor).status == .committed)
      #expect(try store.currentChangeCursor() == cursor + 1)
    }
  }

  private func recordIndex(_ store: NotebookStore, file: String) throws -> [[String]] {
    try store.sqlRead { try $0.rows("SELECT address,hash,position FROM records WHERE file=? ORDER BY address", [.text(file)])
      .map { [$0[0].text!, $0[1].text!, String($0[2].integer!)] } }
  }
  private final class SQLCounter { var steps = 0 }
  private func bounded<T>(_ store: NotebookStore, _ operation: () throws -> T) throws -> T {
    let counter = SQLCounter()
    let value = try withExtendedLifetime(counter) {
      try store.commandTransaction {
        sqlite3_progress_handler(store.currentSQL!.handle, 1, { raw in
          let counter = Unmanaged<SQLCounter>.fromOpaque(raw!).takeUnretainedValue()
          counter.steps += 1; return counter.steps < 200_000 ? 0 : 1
        }, Unmanaged.passUnretained(counter).toOpaque())
        return try operation()
      }
    }
    #expect(counter.steps > 0 && counter.steps < 200_000)
    print("NATIVE_DOCUMENT_SOURCE_ADDRESSED foreign_fields=99000 vm=\(counter.steps)")
    return value
  }
}

import Foundation
import Testing
@testable import NotebookCore

@Suite("An exact document reference owns one authored file")
struct NotebookDocumentFileReferenceTests {
  private let selected = "selected/a~😀"
  private func fixture() throws -> DocumentFileFixture {
    try .init(files: [.init(id: selected, path: "main.tex", source: "Exact <source>"),
      .init(id: "sibling", path: "sibling.tex", source: "Unrelated source")])
  }

  @Test func projectedCompleteColdAndReplicaCutsHaveTheSameSelectedFileIdentity() throws {
    let f = try fixture(), revision = try f.store.referenceRevision(target: f.target, elementID: selected)
    let files = try f.store.referenceSourceFiles(target: f.target, elementID: selected)
    #expect(Set(files.keys) == [documentFile(f.id)])
    #expect(files[documentFile(f.id)]?["files"]?.array.map { $0["id"]?.string } == [selected])
    #expect(try NotebookStore.referenceRevision(target: f.target, elementID: selected, files: files) == revision)
    #expect(try NotebookStore.referenceRevision(target: f.target, elementID: selected, files: f.store.collaborationSnapshot()) == revision)
    #expect(try NotebookStore(root: f.root).referenceRevision(target: f.target, elementID: selected) == revision)
    let otherID = UUID(), other = try #require(files[documentFile(f.id)]).setting("id", .string(otherID.uuidString))
    #expect(try NotebookStore.referenceRevision(target: .init(kind: .document, id: otherID), elementID: selected,
      files: [documentFile(otherID): other]) != revision, "Identical file bytes and clocks still belong to their exact document")
    let peer = try f.replica("peer")
    #expect(try peer.referenceRevision(target: f.target, elementID: selected) == revision)
  }

  @Test func siblingChangesKeepTheFileReferenceButSameValuedSelectedSuccessorsChangeIt() throws {
    let f = try fixture(), original = try f.file(selected)
    let revision = try f.store.referenceRevision(target: f.target, elementID: selected)
    let whole = try f.store.referenceRevision(target: f.target)
    let sibling = try f.file("sibling")
    _ = try f.apply([f.patch(sibling, to: "Edited sibling")])
    #expect(try f.store.referenceRevision(target: f.target, elementID: selected) == revision)
    #expect(try f.store.referenceRevision(target: f.target) != whole)
    _ = try f.apply([f.patch(original, to: "Changed selected source")])
    _ = try f.apply([f.patch(f.file(selected), to: original.file.source)])
    #expect(try f.file(selected).file == original.file)
    #expect(try f.file(selected).sourceVersion != original.sourceVersion)
    #expect(try f.store.referenceRevision(target: f.target, elementID: selected) != revision)
  }

  @Test func corruptSiblingsAndStateCannotBlockAnExactReadWhileMissingFileStillRefuses() throws {
    let f = try fixture(), revision = try f.store.referenceRevision(target: f.target, elementID: selected)
    try f.store.commandTransaction {
      let database = try #require(f.store.currentSQL), corrupt = try database.putBlob(Data("unrequested body".utf8))
      for address in [documentFile(f.id) + "#/files/@sibling", stateFile(f.id) + "#"] {
        try database.run("UPDATE records SET hash=? WHERE address=?", [.text(corrupt), .text(address)])
      }
    }
    #expect(try f.store.referenceRevision(target: f.target, elementID: selected) == revision)
    #expect(try f.file(selected).file.source == "Exact <source>")
    #expect(throws: DecodingError.self) { _ = try f.store.referenceRevision(target: f.target) }
    do {
      _ = try f.store.referenceSourceFiles(target: f.target, elementID: "missing")
      Issue.record("A missing exact file must not fall back to a complete document")
    } catch let error as CollaborationError { #expect(error.code == "target_missing") }
  }

  @Test func savedAggregateEraContextAndPinnedFileRemainInspectableWithoutLiveHashFallback() throws {
    let f = try fixture(), document = try f.store.loadDocument(f.id), state = try f.store.loadDocumentState(f.id)
    // This is the exact previous immutable hashing recipe, used only to create
    // the historical fixture. Production never guesses it from current content.
    let aggregate = try collaborationHash(JSONValue.object(["document": try JSONValue.encode(document).setting("collaboration", nil),
      "state": try .encode(state)]))
    let reference = CollaborationReference(target: f.target, elementID: selected, revision: aggregate)
    let context = try f.store.appendContext(references: [reference], author: .human, actor: f.actor)
    let original = try f.file(selected)
    let source = AgentPinnedSource(id: reference.id, requestID: context.id, reference: reference,
      payload: .object(["reference": try .encode(reference), "file": try .encode(original.file), "elements": .array([])]))
    try f.store.saveAttentionEvidence([source], contextID: context.id)
    let file = "collaboration/attention/\(context.id.uuidString.lowercased())/\(reference.id.uuidString.lowercased()).json"
    func envelopes(_ store: NotebookStore) throws -> [[String]] {
      try store.sqlRead {
        try $0.rows("SELECT r.address,r.hash,b.data FROM records r JOIN blobs b ON b.hash=r.hash WHERE r.file=? ORDER BY r.address", [.text(file)])
          .map { [$0[0].text!, $0[1].text!, $0[2].blob!.base64EncodedString()] }
      }
    }
    let bytes = try envelopes(f.store)
    #expect(try f.store.referenceRevision(target: f.target, elementID: selected) != aggregate)
    _ = try f.apply([f.patch(original, to: "Current new source")])
    let reopened = NotebookStore(root: f.root)
    #expect(try reopened.sharedContextPage(contextID: context.id).entries.first?.references == [reference])
    #expect(try reopened.attentionEvidence(contextID: context.id, referenceID: reference.id) == source)
    #expect(try envelopes(reopened) == bytes, "Physical authored envelopes stay byte-identical; a transient JSON reconstruction has no canonical key order")
  }
}

import Foundation
import Testing
@testable import NotebookCore

@Suite("Code review and shared Pencil have one durable owner", .serialized)
struct NotebookCodeStoreTests {
  private func fixture(_ body: (NotebookStore, UUID) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("code-ink-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    _ = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    try body(store, actor)
  }
  private func fragment(_ actor: UUID) -> NotebookCodeFragment {
    let source = "print(4)\n"
    return .init(file: .init(computer: UUID(), project: "demo", root: "/demo", path: "main.py"),
      sourceHash: NotebookFileVersion.hash(Data(source.utf8)), utf16Offset: 0, text: source,
      width: 600, height: 120, fontSize: 15, stamp: .init(counter: 1, actor: actor))
  }
  private func action(_ fragment: NotebookCodeFragment, actor: UUID, counter: UInt64 = 2) -> SpatialInkAction {
    .init(tool: .pen, spans: [.init(surface: .codeFragment(fragment.id), samples: [
      .init(point: .init(x: 25, y: 25), timeOffset: 0, width: 2, opacity: 1, force: 1, azimuth: 0, altitude: 1)
    ])], stamp: .init(counter: counter, actor: actor))
  }
  @Test func contactAndMaterialAreAtomicIdempotentAndRestoredByFileIdentity() throws {
    try fixture { store, actor in
      let fragment = fragment(actor), action = action(fragment, actor: actor)
      let before = try store.currentChangeCursor()
      _ = try store.commitCodeInk(fragment: fragment, command: .append(action, journalStamp: action.stamp))
      #expect(try store.currentChangeCursor() == before + 1)
      #expect(try store.codeFragments(file: fragment.file) == [fragment])
      let reopened = NotebookStore(root: store.root)
      #expect(try reopened.codeAnnotation(fragment.id)?.ink.actions == [action])
      _ = try store.commitCodeInk(fragment: fragment, command: .append(action, journalStamp: action.stamp))
      #expect(try store.currentChangeCursor() == before + 1)
      let otherMac = NotebookFileAddress(computer: UUID(), project: fragment.file.project, root: fragment.file.root, path: fragment.file.path)
      #expect(try store.codeFragments(file: otherMac).isEmpty)
      #expect(try store.collaborationContent().codeFragments == [fragment])
      #expect(try store.collaborationContent().sourceFiles()[codeFragmentFile(fragment.id)] == JSONValue.encode(fragment))
    }
  }
  @Test func changedMaterialAndMisaddressedInkRollbackWithoutPublishing() throws {
    try fixture { store, actor in
      let fragment = fragment(actor), action = action(fragment, actor: actor)
      let alien = self.fragment(actor)
      #expect(throws: NotebookStorageError.self) { try store.commitCodeInk(fragment: alien, command: .append(action, journalStamp: action.stamp)) }
      #expect(try store.codeFragment(alien.id) == nil)
      _ = try store.commitCodeInk(fragment: fragment, command: .append(action, journalStamp: action.stamp))
      let altered = NotebookCodeFragment(id: fragment.id, file: fragment.file, sourceHash: fragment.sourceHash,
        utf16Offset: 0, text: "other", width: 600, height: 120, fontSize: 15, stamp: fragment.stamp)
      #expect(throws: NotebookStorageError.transactionConflict) { try store.captureCodeFragment(altered) }
      #expect(try store.codeAnnotation(fragment.id)?.fragment == fragment)
    }
  }
  @Test func humanAndAgentUndoOnlyTheirOwnUUIDs() throws {
    try fixture { store, human in
      let fragment = fragment(human), first = action(fragment, actor: human), agent = UUID()
      _ = try store.commitCodeInk(fragment: fragment, command: .append(first, journalStamp: first.stamp))
      let target = CollaborationTarget(kind: .codeFragment, id: fragment.id), id = UUID()
      let operation = CollaborationOperation(kind: .appendInkStroke, target: target, id: id.uuidString,
        values: ["points": .array([.object(["x": .number(40), "y": .number(40)])])])
      let proposal = CollaborationAction(summary: "Подчеркнул результат", expected: [.init(target: target,
        revision: fragment.stamp.revision, inkRevision: first.stamp.revision)], operations: [operation])
      let receipt = try store.applyCollaborationAction(proposal, actor: agent)
      var ink = try #require(try store.codeAnnotation(fragment.id)?.ink)
      #expect(Set(ink.actions.map(\.id)) == [first.id, id])
      let undoStamp = ink.stamp.advanced(by: human)!
      _ = try store.commitCodeInk(fragment: fragment, command: .state(actionID: first.id,
        creationStamp: first.stamp, isActive: false, stateStamp: undoStamp, journalStamp: undoStamp))
      let later = action(fragment, actor: human, counter: undoStamp.counter + 1)
      _ = try store.commitCodeInk(fragment: fragment, command: .append(later, journalStamp: later.stamp))
      _ = try store.undoCollaborationAction(receipt.id, actor: agent)
      ink = try #require(try store.codeAnnotation(fragment.id)?.ink)
      #expect(ink.actions.filter(\.isActive).map(\.id) == [later.id])
      #expect(ink.actions.count == 3 && ink.actions.first(where: { $0.id == first.id })?.spans == first.spans)
      #expect(try store.codeFragment(fragment.id) == fragment)
    }
  }
  @Test func explicitRebindingKeepsOriginalInkAndRejectsAStaleDestination() throws {
    try fixture { store, human in
      let original = fragment(human), first = action(original, actor: human)
      _ = try store.commitCodeInk(fragment: original, command: .append(first, journalStamp: first.stamp))
      let selected = fragment(human)
      let rebound = try store.rebindCodeFragment(original.id, expected: original.location, to: selected, actor: human)
      #expect(rebound.currentFile == selected.file && rebound.file == original.file)
      #expect(rebound.text == original.text && rebound.width == original.width)
      #expect(try store.codeFragments(file: original.file).isEmpty)
      #expect(try store.codeFragments(file: selected.file) == [rebound])
      #expect(try store.codeAnnotation(original.id)?.ink.actions == [first])
      #expect(throws: NotebookStorageError.transactionConflict) {
        try store.rebindCodeFragment(original.id, expected: original.location, to: selected, actor: UUID())
      }
      // The earlier Pencil capture can finish without resetting the new binding.
      let later = action(original, actor: human, counter: 10)
      _ = try store.commitCodeInk(fragment: original, command: .append(later, journalStamp: later.stamp))
      #expect(try store.codeFragment(original.id) == rebound)
      let reopened = NotebookStore(root: store.root)
      #expect(try reopened.codeFragments(file: selected.file) == [rebound])
      #expect(try reopened.codeAnnotation(original.id)?.ink.actions.count == 2)
    }
  }

  @Test func changedDestinationShowsOnlyAMarkerAndConcurrentBindingsConverge() throws {
    let original = fragment(UUID())
    let a = try original.rebinding(to: .init(file: original.file, sourceHash: NotebookFileVersion.hash(Data("new code".utf8)),
      utf16Offset: 0, text: "new code", stamp: .init(counter: 10, actor: UUID())))
    let b = try original.rebinding(to: .init(file: original.file, sourceHash: NotebookFileVersion.hash(Data("other".utf8)),
      utf16Offset: 0, text: "other", stamp: .init(counter: 11, actor: UUID())))
    #expect(!a.canOverlayCurrentText)
    #expect(a.range(in: "new code") == NSRange(location: 0, length: 8))
    #expect(a.range(in: "new code new code") == nil)
    #expect(a.text == original.text)
    #expect(try a.merging(b) == b.merging(a))
    #expect(try b.merging(original) == b)
    let collision = try original.rebinding(to: .init(file: b.currentFile, sourceHash: b.location.sourceHash,
      utf16Offset: 1, text: "different", stamp: b.location.stamp))
    #expect(throws: NotebookStorageError.transactionConflict) { try b.merging(collision) }
  }

  @Test func materialInkAndUndoReplicateTogetherAndKeepTheSameFileAddress() throws {
    try fixture { a, actor in
      let b = NotebookStore(root: a.root.appendingPathComponent("peer"))
      try b.prepareEmptyWorkspace(workspaceID: a.workspaceHeader().workspaceID)
      func deliver() throws {
        var cursor = try b.peerCursor(peerID: actor, direction: .incoming)
        for change in try a.changeJournal(after: cursor) {
          while true {
            let hashes = try b.missingBlobHashes(for: change)
            if hashes.isEmpty { break }
            for hash in hashes {
              let size = try a.blobSize(hash: hash)
              var bytes = Data()
              while bytes.count < size { bytes += try a.readBlobChunk(hash: hash, offset: Int64(bytes.count), maxBytes: 1_048_576) }
              try b.stageBlob(data: bytes, expectedHash: hash)
            }
          }
          cursor = try b.applyRemoteChange(change, peerID: actor)
        }
      }
      try deliver()
      let fragment = fragment(actor), contact = action(fragment, actor: actor)
      _ = try a.commitCodeInk(fragment: fragment, command: .append(contact, journalStamp: contact.stamp))
      try deliver()
      #expect(try b.codeFragments(file: fragment.file) == [fragment])
      #expect(try b.codeAnnotation(fragment.id) == a.codeAnnotation(fragment.id))
      let stamp = VersionStamp(counter: 10, actor: actor)
      _ = try a.commitCodeInk(fragment: fragment, command: .state(actionID: contact.id,
        creationStamp: contact.stamp, isActive: false, stateStamp: stamp, journalStamp: stamp))
      try deliver(); try deliver()
      #expect(try b.codeAnnotation(fragment.id)?.ink.actions.first?.isActive == false)
      #expect(try b.codeAnnotation(fragment.id)?.ink.actions.first?.spans == contact.spans)
      let selected = self.fragment(actor)
      let rebound = try a.rebindCodeFragment(fragment.id, expected: fragment.location, to: selected, actor: actor)
      try deliver()
      #expect(try b.codeFragments(file: fragment.file).isEmpty)
      #expect(try b.codeFragments(file: selected.file) == [rebound])
      #expect(try b.codeAnnotation(fragment.id)?.ink.actions.first?.isActive == false)
      try b.captureCodeFragment(fragment)
      #expect(try b.codeFragment(fragment.id) == rebound)
    }
  }

}

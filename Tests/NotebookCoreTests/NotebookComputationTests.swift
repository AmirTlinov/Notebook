import Foundation
import Testing
@testable import NotebookCore

@Suite("Computation owns a versioned interpretation of real ink", .serialized)
struct NotebookComputationTests {
  private enum Fault: Error { case disk }
  private let region = PageRect(x: 10, y: 10, width: 150, height: 100)

  private func stroke(_ tool: SpatialInkTool = .pen, x: Double = 30, id: UUID = UUID()) -> PageInkAction {
    .init(id: id, tool: tool, samples: [x, x + 10].enumerated().map {
      .init(point: .init(x: $0.element, y: 40), timeOffset: Double($0.offset) / 100,
        width: 3, opacity: 1, force: 1, azimuth: 0, altitude: 1)
    })
  }

  private func fixture(_ body: (NotebookStore, UUID, UUID, UUID) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-computation-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID(), notebook = UUID(), pageID = UUID()
    _ = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194),
      initialNotebookID: notebook, initialPageID: pageID)
    _ = try append(stroke(), store: store, pageID: pageID, actor: actor)
    try body(store, actor, notebook, pageID)
  }

  @discardableResult
  private func append(_ action: PageInkAction, store: NotebookStore, pageID: UUID, actor: UUID) throws -> PageDocument {
    var page = try store.loadPage(pageID)
    let change = try page.prepareInkChange(.append(action), stamp: .init(counter: page.drawingStamp.counter + 1, actor: actor))
    let published = page.publishInkChange(change); #expect(published)
    return try store.saveMergedPage(page)
  }

  private func activate(_ store: NotebookStore, _ actor: UUID, _ notebook: UUID, _ page: UUID, id: UUID = UUID()) throws -> NotebookComputationRead {
    try store.activateComputation(id: id, ink: store.readComputationInk(notebookID: notebook, pageID: page, region: region), actor: actor)
  }

  private func begin(_ record: NotebookComputation, store: NotebookStore, actor: UUID, attempt: UUID = UUID()) throws -> NotebookRecognitionInput {
    try store.beginComputationRecognition(pageID: record.source.pageID, id: record.id,
      expectedRevision: record.revision, attemptID: attempt,
      ink: store.readComputationInk(notebookID: record.source.notebookID, pageID: record.source.pageID, region: region), actor: actor)
  }

  private func output(_ text: String = "2 + 3", kind: NotebookRecognitionCandidate.Kind = .mathematics) -> NotebookRecognitionCandidates {
    // Authored domain fixture, not an OCR substitute or recognition acceptance.
    .init(recognizer: "authored-contract-fixture", candidates: [.init(kind: kind, text: text)])
  }

  @Test func activationWritesOnlyItsAddressAndNeverChangesTheInkSource() throws {
    try fixture { store, actor, notebook, page in
      let source = try store.readComputationInk(notebookID: notebook, pageID: page, region: region)
      let before = try store.currentChangeCursor(), original = try store.loadPage(page)
      let activated = try store.activateComputation(id: UUID(), ink: source, actor: actor)
      let address = pageFile(page) + "#/computations/@" + activated.computation.id.uuidString.lowercased()
      let changes = try store.readChangedAddresses(after: before, through: store.currentChangeCursor())
      #expect(Set(changes.addresses) == [pageFile(page) + "#", address])
      #expect(try store.loadPage(page).drawingData == original.drawingData)
      #expect(try store.loadPage(page).computations == [activated.computation])
      #expect(try store.readComputationInk(notebookID: notebook, pageID: page, region: region).source == source.source)
      let cursor = try store.currentChangeCursor()
      #expect(try store.activateComputation(id: activated.computation.id, ink: source, actor: actor).computation == activated.computation)
      #expect(try store.currentChangeCursor() == cursor)
    }
  }

  @Test func captureKeepsOriginalUUIDsSamplesAndPenEraserOrderWithoutInventingEndpoints() throws {
    try fixture { store, actor, notebook, page in
      let eraser = stroke(.eraser), crossing = stroke(x: 155), outside = stroke(x: 400), undone = stroke(x: 60)
      for action in [eraser, crossing, outside, undone] { try append(action, store: store, pageID: page, actor: actor) }
      var document = try store.loadPage(page)
      let removed = try document.prepareInkChange(.remove([undone.id]), stamp: .init(counter: 10, actor: actor))
      let published = document.publishInkChange(removed); #expect(published); try store.saveMergedPage(document)
      let capture = try store.readComputationInk(notebookID: notebook, pageID: page, region: region)
      #expect(capture.drawing.actions.map(\.tool) == [.pen, .eraser, .pen])
      #expect(capture.drawing.actions[1].id == eraser.id)
      #expect(capture.drawing.actions[2].samples == crossing.samples)
      #expect(capture.sampleRanges.last == .init(strokeID: crossing.id, lowerBound: 0, upperBound: 2))
      #expect(capture.drawing.actions.map(\.sequence) == [1, 2, 3])
    }
  }

  @Test func pythonWhitespaceAndCaseSurvivePublicationAndReopenButAreNeverAutoApproved() throws {
    try fixture { store, actor, notebook, page in
      let record = try activate(store, actor, notebook, page).computation
      let input = try begin(record, store: store, actor: actor)
      let code = "def F(x):\n\tif x < 0:\n\t\treturn -x\n    return x  \n"
      let packet = try input.preparing(output(code, kind: .python))
      let before = try store.currentChangeCursor()
      let accepted = try store.publishComputationRecognition(packet, actor: actor)
      #expect(accepted.computation.phase == .needsReview && accepted.sourceIsCurrent)
      #expect(accepted.computation.recognition?.candidates.first?.text == code)
      #expect(accepted.computation.recognition?.candidates.first?.bindings.isEmpty == true)
      let changes = try store.readChangedAddresses(after: before, through: store.currentChangeCursor())
      #expect(changes.addresses == [pageFile(page) + "#/computations/@" + record.id.uuidString.lowercased()])
      let reopened = NotebookStore(root: store.root)
      #expect(try reopened.readComputation(pageID: page, id: record.id).computation == accepted.computation)
      let cursor = try store.currentChangeCursor()
      #expect(try reopened.publishComputationRecognition(packet, actor: actor).computation == accepted.computation)
      #expect(try store.currentChangeCursor() == cursor)
    }
  }

  @Test(arguments: [SpatialInkTool.pen, .eraser])
  func aNewContactRejectsLateRecognition(_ tool: SpatialInkTool) throws {
    try fixture { store, actor, notebook, page in
      let record = try activate(store, actor, notebook, page).computation
      let input = try begin(record, store: store, actor: actor), packet = try input.preparing(output())
      try append(stroke(tool), store: store, pageID: page, actor: actor)
      let cursor = try store.currentChangeCursor()
      #expect(throws: CollaborationError.self) { try store.publishComputationRecognition(packet, actor: actor) }
      #expect(try store.currentChangeCursor() == cursor)
      #expect(try !store.readComputation(pageID: page, id: record.id).sourceIsCurrent)
      let current = try store.readComputation(pageID: page, id: record.id).computation
      let fresh = try begin(current, store: store, actor: actor)
      #expect(fresh.attemptID != input.attemptID && fresh.ink.source != input.ink.source)
      #expect(try store.publishComputationRecognition(fresh.preparing(output()), actor: actor).sourceIsCurrent)
      #expect(throws: NotebookStorageError.transactionConflict) { try store.publishComputationRecognition(packet, actor: actor) }
    }
  }

  @Test func undoRejectsAnOldSourceEvenWhenItHasTheSameNumberOfVisibleStrokes() throws {
    try fixture { store, actor, notebook, page in
      let second = stroke(x: 80)
      try append(second, store: store, pageID: page, actor: actor)
      let record = try activate(store, actor, notebook, page).computation
      let input = try begin(record, store: store, actor: actor)
      var document = try store.loadPage(page)
      let prepared = try document.prepareInkChange(.remove([second.id]), stamp: .init(counter: 10, actor: actor))
      let published = document.publishInkChange(prepared); #expect(published)
      try store.saveMergedPage(document)
      try append(stroke(x: 80), store: store, pageID: page, actor: actor)
      #expect(try store.readComputationInk(notebookID: notebook, pageID: page, region: region).drawing.actions.count == input.ink.drawing.actions.count)
      #expect(throws: CollaborationError.self) { try store.publishComputationRecognition(input.preparing(output()), actor: actor) }
    }
  }

  @Test func stopAndRemovalAreRetryableAndCannotBeUndoneByAnOldCallback() throws {
    try fixture { store, actor, notebook, page in
      let record = try activate(store, actor, notebook, page).computation
      let input = try begin(record, store: store, actor: actor), packet = try input.preparing(output())
      let stopped = try store.stopComputation(pageID: page, id: record.id, expectedRevision: input.revision, actor: actor)
      let cursor = try store.currentChangeCursor()
      #expect(try store.stopComputation(pageID: page, id: record.id, expectedRevision: input.revision, actor: actor).computation == stopped.computation)
      #expect(try store.currentChangeCursor() == cursor)
      #expect(throws: NotebookStorageError.transactionConflict) { try store.publishComputationRecognition(packet, actor: actor) }
      let removed = try store.removeComputation(pageID: page, id: record.id, expectedRevision: stopped.computation.revision, actor: actor)
      #expect(removed.computation.phase == .removed && removed.computation.recognition == nil)
      let after = try store.currentChangeCursor()
      #expect(try store.removeComputation(pageID: page, id: record.id, expectedRevision: stopped.computation.revision, actor: actor).computation == removed.computation)
      #expect(try store.activateComputation(id: record.id, ink: input.ink, actor: actor).computation == removed.computation)
      #expect(throws: CocoaError.self) { try begin(removed.computation, store: store, actor: actor) }
      #expect(try store.currentChangeCursor() == after)
    }
  }

  @Test func staleNativePageSavePreservesInterpretationAndStickyOrder() throws {
    try fixture { store, actor, notebook, page in
      let old = try store.loadPage(page)
      let first = try activate(store, actor, notebook, page).computation
      let second = try activate(store, actor, notebook, page).computation
      let input = try begin(first, store: store, actor: actor)
      let recognized = try store.publishComputationRecognition(input.preparing(output()), actor: actor).computation
      let merged = try store.saveMergedPage(old)
      #expect(merged.computations == [recognized, second])
      try store.savePage(old)
      #expect(try store.loadPage(page).computations == [recognized, second])
      #expect(try store.readPageComputations(pageID: page).map(\.computation.id) == [first.id, second.id])
    }
  }

  @Test func aCommittedCandidateBecomesStaleWithoutWritingAnotherResultOrLosingTheDrawing() throws {
    try fixture { store, actor, notebook, page in
      let record = try activate(store, actor, notebook, page).computation
      let input = try begin(record, store: store, actor: actor), packet = try input.preparing(output())
      let accepted = try store.publishComputationRecognition(packet, actor: actor).computation
      try append(stroke(x: 90), store: store, pageID: page, actor: actor)
      let cursor = try store.currentChangeCursor()
      let retry = try store.publishComputationRecognition(packet, actor: actor)
      #expect(retry.computation == accepted && !retry.sourceIsCurrent)
      #expect(try store.currentChangeCursor() == cursor)
      #expect(try PageInkDrawing.decode(store.loadPage(page).drawingData).actions.count == 2)
    }
  }

  @Test func publicationValidationRejectsInventedStrokeAlignmentAndUTF8Splitting() throws {
    try fixture { store, actor, notebook, page in
      try append(stroke(.eraser), store: store, pageID: page, actor: actor)
      let record = try activate(store, actor, notebook, page).computation, input = try begin(record, store: store, actor: actor)
      let pen = input.ink.sampleRanges[0], eraser = input.ink.sampleRanges[1]
      let badRanges: [NotebookInkSampleRange] = [eraser, .init(strokeID: UUID(), lowerBound: 0, upperBound: 1),
        .init(strokeID: pen.strokeID, lowerBound: 0, upperBound: 3)]
      for range in badRanges {
        let candidate = NotebookRecognitionCandidate(kind: .mathematics, text: "π", bindings: [.init(utf8LowerBound: 0, utf8UpperBound: 2, samples: [range])])
        #expect(throws: CollaborationError.self) { try input.preparing(.init(recognizer: "fixture", candidates: [candidate])) }
      }
      let split = NotebookRecognitionCandidate(kind: .mathematics, text: "π", bindings: [.init(utf8LowerBound: 0, utf8UpperBound: 1, samples: [pen])])
      #expect(throws: CollaborationError.self) { try input.preparing(.init(recognizer: "fixture", candidates: [split])) }
      let valid = NotebookRecognitionCandidate(kind: .mathematics, text: "π", bindings: [.init(utf8LowerBound: 0, utf8UpperBound: 2, samples: [pen])])
      #expect(try store.publishComputationRecognition(input.preparing(.init(recognizer: "fixture", candidates: [valid])), actor: actor).computation.recognition?.candidates == [valid])
    }
  }

  @Test func badOwnerEmptyRegionAndRasterBaselineAreNotExecutableInk() throws {
    try fixture { store, actor, notebook, page in
      #expect(throws: CocoaError.self) { try store.readComputationInk(notebookID: UUID(), pageID: page, region: region) }
      #expect(throws: CollaborationError.self) { try store.readComputationInk(notebookID: notebook, pageID: page, region: .init(x: 800, y: 0, width: 100, height: 100)) }
      #expect(throws: CollaborationError.self) { try store.readComputationInk(notebookID: notebook, pageID: page, region: .init(x: 400, y: 400, width: 100, height: 100)) }
      var document = try store.loadPage(page)
      let raster = PageInkDrawing(baselinePNG: Data([137, 80, 78, 71, 13, 10, 26, 10]), baselineActionCount: 1)
      let replaced = document.replaceDrawing(try raster.dataRepresentation(), stamp: .init(counter: 10, actor: actor)); #expect(replaced)
      try store.savePage(document)
      #expect(throws: CollaborationError.self) { try store.readComputationInk(notebookID: notebook, pageID: page, region: region) }
    }
  }

  @Test func transactionFailureDoesNotPublishAndAmbiguousCommitCanBeRetriedExactly() throws {
    try fixture { store, actor, notebook, page in
      let ink = try store.readComputationInk(notebookID: notebook, pageID: page, region: region), id = UUID()
      let before = try store.currentChangeCursor()
      let failing = NotebookStore(root: store.root, storageFault: { if $0 == .afterRecordWrites { throw Fault.disk } })
      #expect(throws: Fault.self) { try failing.activateComputation(id: id, ink: ink, actor: actor) }
      #expect(try store.currentChangeCursor() == before)
      #expect(try store.loadPage(page).computations == nil)
      let committed = NotebookStore(root: store.root, storageFault: { if $0 == .afterCommit { throw Fault.disk } })
      #expect(throws: Fault.self) { try committed.activateComputation(id: id, ink: ink, actor: actor) }
      let cursor = try store.currentChangeCursor()
      #expect(try store.activateComputation(id: id, ink: ink, actor: actor).computation.id == id)
      #expect(try store.currentChangeCursor() == cursor)
      let input = try begin(store.readComputation(pageID: page, id: id).computation, store: store, actor: actor)
      let prepared = try input.preparing(output())
      #expect(throws: Fault.self) { try failing.publishComputationRecognition(prepared, actor: actor) }
      #expect(try store.readComputation(pageID: page, id: id).computation.phase == .recognizing)
      #expect(throws: Fault.self) { try committed.publishComputationRecognition(prepared, actor: actor) }
      let finalCursor = try store.currentChangeCursor()
      #expect(try store.publishComputationRecognition(prepared, actor: actor).computation.phase == .needsReview)
      #expect(try store.currentChangeCursor() == finalCursor)
    }
  }

  @Test func pageMergeRejectsAConflictingComputationIdentityBeforeChangingAnyStream() throws {
    try fixture { store, actor, notebook, page in
      let activated = try activate(store, actor, notebook, page).computation
      _ = try begin(activated, store: store, actor: actor)
      let original = try store.readComputation(pageID: page, id: activated.id).computation
      var incoming = try store.loadPage(page), collision = original
      collision.attemptID = UUID()
      incoming.computations = [collision]
      #expect(incoming.isValid)
      let cursor = try store.currentChangeCursor()
      #expect(throws: NotebookStorageError.transactionConflict) { try store.saveMergedPage(incoming) }
      #expect(try store.currentChangeCursor() == cursor)
      #expect(try store.readComputation(pageID: page, id: original.id).computation == original)
    }
  }

  @Test func sourceIdentityChecksActualInkHashesNotJustClockEquality() throws {
    try fixture { store, actor, notebook, page in
      let record = try activate(store, actor, notebook, page).computation
      let input = try begin(record, store: store, actor: actor)
      let current = try store.loadPage(page)
      let changed = try PageInkDrawing.decode(current.drawingData).appending(stroke(x: 90))
      let altered = try JSONValue.encode(current).setting("drawingData", .encode(changed.dataRepresentation())).decode(PageDocument.self)
      #expect(altered.drawingStamp == current.drawingStamp)
      try store.savePage(altered)
      #expect(try !store.readComputation(pageID: page, id: record.id).sourceIsCurrent)
      #expect(throws: CollaborationError.self) { try store.publishComputationRecognition(input.preparing(output()), actor: actor) }
    }
  }

  @Test func anOversizedPageRejectsRecognitionBeforePointLoadingButStillAllowsStop() throws {
    try fixture { store, actor, notebook, page in
      let record = try activate(store, actor, notebook, page).computation
      let input = try begin(record, store: store, actor: actor)
      var document = try store.loadPage(page)
      let many = PageInkDrawing(actions: (0..<2_050).map { stroke(x: Double($0 % 200)) })
      let changed = document.replaceDrawing(try many.dataRepresentation(), stamp: .init(counter: 10, actor: actor))
      #expect(changed); try store.savePage(document)
      #expect(throws: NotebookStorageError.limitExceeded("computation_ink_bytes")) {
        try store.readComputationInk(notebookID: notebook, pageID: page, region: region)
      }
      #expect(try !store.readComputation(pageID: page, id: record.id).sourceIsCurrent)
      let stopped = try store.stopComputation(pageID: page, id: record.id, expectedRevision: input.revision, actor: actor)
      #expect(stopped.computation.phase == .stopped && !stopped.sourceIsCurrent)
    }
  }

  private func transferAll(_ source: NotebookStore, to destination: NotebookStore, peer: UUID, after: UInt64 = 0) throws {
    var cursor = after
    while true {
      let changes = try source.changeJournal(after: cursor)
      if changes.isEmpty { return }
      for change in changes {
        while true {
          let hashes = try destination.missingBlobHashes(for: change)
          if hashes.isEmpty { break }
          for hash in hashes {
            let size = try source.blobSize(hash: hash)
            var data = Data()
            while Int64(data.count) < size {
              data += try source.readBlobChunk(hash: hash, offset: Int64(data.count), maxBytes: 1_048_576)
            }
            try destination.stageBlob(data: data, expectedHash: hash)
          }
        }
        _ = try destination.applyRemoteChange(change, peerID: peer)
        cursor = change.sequence
      }
    }
  }

  @Test func independentActivationsAndRemovalConvergeThroughTheRealDeliveryJournal() throws {
    try fixture { store, actor, notebook, page in
      let other = NotebookStore(root: store.root.appendingPathComponent("peer")), peer = UUID()
      try other.prepareEmptyWorkspace(workspaceID: store.workspaceHeader().workspaceID)
      try transferAll(store, to: other, peer: actor)
      let a = try activate(store, actor, notebook, page).computation
      let b = try activate(other, peer, notebook, page).computation
      let input = try begin(a, store: store, actor: actor)
      let accepted = try store.publishComputationRecognition(input.preparing(output()), actor: actor).computation
      try transferAll(store, to: other, peer: actor)
      try transferAll(other, to: store, peer: peer)
      #expect(try store.loadPage(page).computations == other.loadPage(page).computations)
      #expect(Set(try store.readPageComputations(pageID: page).map(\.computation.id)) == [a.id, b.id])
      // One peer removes A while the other starts a newer interpretation of A.
      let removed = try store.removeComputation(pageID: page, id: a.id, expectedRevision: accepted.revision, actor: actor).computation
      let remoteInput = try begin(other.readComputation(pageID: page, id: a.id).computation, store: other, actor: peer)
      _ = try other.publishComputationRecognition(remoteInput.preparing(output("2 - 3")), actor: peer)
      try transferAll(store, to: other, peer: actor)
      try transferAll(other, to: store, peer: peer)
      #expect(try store.readComputation(pageID: page, id: a.id).computation == removed)
      #expect(try other.readComputation(pageID: page, id: a.id).computation == removed)
      #expect(try store.loadPage(page).computations == other.loadPage(page).computations)
      let before = try store.currentChangeCursor()
      try transferAll(other, to: store, peer: peer)
      #expect(try store.currentChangeCursor() == before)
    }
  }

  @Test func checkpointRoundTripPreservesAddressedComputationsAndTheirInkFingerprint() throws {
    try fixture { store, actor, notebook, page in
      let record = try activate(store, actor, notebook, page).computation
      let input = try begin(record, store: store, actor: actor)
      let accepted = try store.publishComputationRecognition(input.preparing(output()), actor: actor).computation
      let checkpoint = try NotebookCheckpoint(workspaceID: store.workspaceHeader().workspaceID,
        envelope: .init(content: store.collaborationContent()),
        presence: .init(mode: .board, camera: .init(), viewport: .init(x: 834, y: 1194), selectedItemID: notebook, notebookPageID: page))
      let destination = NotebookStore(root: store.root.appendingPathComponent("checkpoint"))
      _ = try destination.installCheckpoint(checkpoint)
      #expect(try destination.loadPage(page).computations == [accepted])
      #expect(try destination.readComputation(pageID: page, id: record.id).sourceIsCurrent)
      #expect(try destination.readComputationInk(notebookID: notebook, pageID: page, region: region).source == input.ink.source)
    }
  }

  @Test func deletingTheNotebookRemovesItsComputationsAndCannotPublishALateCandidate() throws {
    try fixture { store, actor, notebook, page in
      var workspace = try store.loadIndex(), board = try store.loadBoard(items: workspace.items)
      let created = workspace.createNotebook(title: "Retained", actor: actor, pageSize: .init(width: 834, height: 1194))
      let remaining = try #require(created)
      let placed = board.addItem(remaining.item.id, to: workspace.rootBoardID, near: .zero, actor: actor)
      #expect(placed); try store.saveWorkspaceBundle(index: workspace, page: remaining.page, board: board)
      let record = try activate(store, actor, notebook, page).computation
      let input = try begin(record, store: store, actor: actor)
      try store.deleteWorkspaceItem(itemID: notebook, actor: actor)
      let cursor = try store.currentChangeCursor()
      #expect(throws: CocoaError.self) { try store.readComputation(pageID: page, id: record.id) }
      #expect(throws: NotebookStorageError.transactionConflict) { try store.publishComputationRecognition(input.preparing(output()), actor: actor) }
      #expect(try store.currentChangeCursor() == cursor)
      #expect(try store.storedFragments(address: pageFile(page) + "#").isEmpty)
    }
  }


  @Test func aProgramFieldNamedComputationsIsContentNotASecondDomainCollection() throws {
    try fixture { store, actor, notebook, page in
      let record = try activate(store, actor, notebook, page).computation
      let state: JSONValue = .object(["computations": .array([.object(["id": .string("simulation"), "value": .number(3)])])])
      var document = try store.loadPage(page)
      let replaced = document.replaceElements([.init(id: "program", kind: .web, frame: .init(x: 200, y: 200, width: 100, height: 100), source: "Model", html: "<div>Model</div>", state: state)], actor: actor)
      #expect(replaced); try store.saveMergedPage(document)
      #expect(try store.loadPage(page).elements.first?.state == state)
      #expect(try store.readComputation(pageID: page, id: record.id).sourceIsCurrent)
      #expect(try store.loadPage(page).computations == [record])
      #expect(try store.loadPage(page).collaboration?.fields["computations"] == nil)
      let rows = try store.storedFragments(address: pageFile(page) + "#/elements/@program")
      #expect(!rows.contains { $0.collection.contains("computations") })
    }
  }


  @Test func agentElementEditsAndTheirUndoDoNotOwnOrEraseComputations() throws {
    try fixture { store, actor, notebook, page in
      let record = try activate(store, actor, notebook, page).computation
      let target = CollaborationTarget(kind: .page, id: page)
      let operation = CollaborationOperation(kind: .insertElement, target: target, id: "agent-note", values: [
        "kind": .string("web"), "frame": try .encode(PageRect(x: 200, y: 200, width: 100, height: 100)),
        "source": .string("Note"), "html": .string("<p>Note</p>")])
      let action = try CollaborationAction(summary: "Пояснить рядом", expected: [.init(target: target, revision: store.loadPage(page).agentStamp.revision)], operations: [operation])
      let receipt = try store.applyCollaborationAction(action, actor: UUID())
      let changed = try store.loadPage(page)
      #expect(changed.computations == [record])
      #expect(changed.collaboration?.fields["computations"] == nil)
      #expect(!receipt.changes.contains { $0.path.first == .field("computations") })
      _ = try store.undoCollaborationAction(receipt.id, actor: actor)
      let restored = try store.loadPage(page)
      #expect(restored.elements.isEmpty && restored.computations == [record])
      #expect(restored.collaboration?.fields["computations"] == nil)
      #expect(try store.readComputation(pageID: page, id: record.id).sourceIsCurrent)
    }
  }

  @Test func corruptUnorderedStrokeIsRejectedRatherThanGivenAnInventedSequence() throws {
    try fixture { store, _, notebook, page in
      let ink = try store.readComputationInk(notebookID: notebook, pageID: page, region: region)
      let address = pageFile(page) + "#/drawingData/actions/@" + ink.drawing.actions[0].id.uuidString.lowercased()
      try store.commandTransaction {
        let row = try #require(try store.storedFragments(address: address, descendants: false).first)
        try store.writeFragment(row.replacing(value: row.value.setting("sequence", .number(0))), database: store.currentSQL!)
      }
      #expect(throws: PageInkDrawing.InkError.self) { try store.readComputationInk(notebookID: notebook, pageID: page, region: region) }
    }
  }

}

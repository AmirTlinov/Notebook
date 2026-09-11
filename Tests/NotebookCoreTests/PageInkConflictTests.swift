import Foundation
import Testing
@testable import NotebookCore

@Suite("A conflicting page stroke cannot publish a candidate or acknowledge delivery")
struct PageInkConflictTests {
  enum Collision: String, CaseIterable, Sendable {
    case samples, tool, color, sequence, invalidDrawing
  }

  private func pages(id: UUID = UUID(), collision: Collision) throws -> (PageDocument, PageDocument) {
    let actor = UUID(), strokeID = UUID(), size = PageSize(width: 834, height: 1194)
    func drawing(changed: Bool) throws -> Data {
      if changed && collision == .invalidDrawing { return Data([0, 1, 2]) }
      let action = PageInkAction(id: strokeID, tool: changed && collision == .tool ? .eraser : .pen,
        color: changed && collision == .color ? .init(red: 1, green: 0, blue: 0) : .black,
        samples: (0..<32).map { offset in
          .init(point: .init(x: Double(offset) + (changed && collision == .samples ? 10 : 0), y: 20),
            timeOffset: Double(offset) / 120, width: 2, opacity: 1, force: 0.5, azimuth: 0, altitude: 1)
        }, sequence: changed && collision == .sequence ? 2 : 1)
      return try PageInkDrawing(actions: [action]).dataRepresentation()
    }
    let before = PageDocument(id: id, size: size, actor: actor, drawingData: try drawing(changed: false))
    let element = AgentElement(id: "must-not-publish", kind: .markdown,
      frame: .init(x: 30, y: 40, width: 100, height: 100), source: "Rejected with the stroke", html: "")
    let candidate = PageDocument(id: id, size: size, actor: actor,
      drawingData: try drawing(changed: true), elements: [element])
    return (before, try JSONValue.encode(candidate)
      .setting("drawingStamp", .encode(VersionStamp(counter: 10, actor: actor)))
      .setting("agentStamp", .encode(VersionStamp(counter: 10, actor: actor)))
      .decode(PageDocument.self))
  }

  @Test(arguments: Collision.allCases)
  func aDomainRefusalLeavesEveryFieldUnchanged(collision: Collision) throws {
    let (before, candidate) = try pages(collision: collision)
    var merged = before
    let changed = merged.merge(candidate)
    #expect(!changed)
    #expect(merged == before)
  }

  @Test(arguments: [Collision.samples, .tool, .color])
  func nativeAdmissionRejectsARepeatedUUIDWithDifferentMeasuredContent(collision: Collision) throws {
    let (before, candidate) = try pages(collision: collision)
    let action = try #require(PageInkDrawing.decode(candidate.drawingData).actions.first)
    #expect(throws: PageInkDrawing.InkError.self) {
      try before.prepareInkChange(.append(action), stamp: .init(counter: 11, actor: UUID()))
    }
    #expect(try PageInkDrawing.decode(before.drawingData).actions.first != action)
  }

  @Test func exactNativeReplayKeepsTheSequenceAndDoesNotResurrectUndoneInk() throws {
    let (page, _) = try pages(collision: .samples)
    let drawing = try PageInkDrawing.decode(page.drawingData)
    let accepted = try #require(drawing.actions.first)
    let measured = PageInkAction(id: accepted.id, tool: accepted.tool, color: accepted.color, samples: accepted.samples)
    let liveReplay = try page.prepareInkChange(.append(measured), stamp: .init(counter: 20, actor: UUID()))
    #expect(liveReplay.data == page.drawingData)
    #expect(liveReplay.stamp == page.drawingStamp)
    let removed = drawing.removing([accepted.id])
    let undone = PageDocument(id: page.id, size: page.size, actor: page.drawingStamp.actor,
      drawingData: try removed.dataRepresentation())
    let undoReplay = try undone.prepareInkChange(.append(measured), stamp: .init(counter: 30, actor: UUID()))
    #expect(undoReplay.data == undone.drawingData)
    #expect(undoReplay.stamp == undone.drawingStamp)
    #expect(undoReplay.drawing.actions.first?.sequence == accepted.sequence)
    #expect(undoReplay.drawing.activeActions.isEmpty)
  }

  @Test func exhaustedSequenceRefusesANewContactInsteadOfReportingAnUnchangedDrawing() throws {
    let (page, _) = try pages(collision: .samples)
    let action = try #require(PageInkDrawing.decode(page.drawingData).actions.first)
    let final = PageInkAction(id: action.id, tool: action.tool, color: action.color,
      samples: action.samples, sequence: VersionStamp.maximumCounter)
    let drawing = PageInkDrawing(actions: [final])
    let next = PageInkAction(tool: action.tool, color: action.color, samples: action.samples)
    #expect(throws: PageInkDrawing.InkError.self) { try drawing.appending(next) }
    #expect(try drawing.appending(action) == drawing)
  }

  @Test(arguments: Collision.allCases)
  func localPublicationRejectsTheCandidateAndKeepsAcceptedPoints(collision: Collision) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root)
    _ = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    let id = try #require(store.loadIndex().selectedPageID)
    let (original, candidate) = try pages(id: id, collision: collision)
    _ = try store.savePage(original)
    let accepted = try store.loadPage(id)
    let cursor = try store.currentChangeCursor()
    #expect(throws: PageInkDrawing.InkError.self) { try store.savePage(candidate) }
    #expect(try store.currentChangeCursor() == cursor)
    #expect(try NotebookStore(root: root).loadPage(id) == accepted)
  }

  @Test func theOnlyPageWriterMergesAStalePageInsteadOfErasingALaterContact() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root)
    _ = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    let id = try #require(store.loadIndex().selectedPageID)
    let (original, _) = try pages(id: id, collision: .samples)
    _ = try store.savePage(original)
    let first = try PageInkDrawing.decode(original.drawingData)
    let next = PageInkAction(tool: .pen, samples: try #require(first.actions.first).samples)
    let later = PageDocument(id: id, size: original.size, actor: UUID(),
      drawingData: try first.appending(next).dataRepresentation())
    _ = try store.savePage(later)
    let accepted = try store.loadPage(id), cursor = try store.currentChangeCursor()
    _ = try store.savePage(original)
    #expect(try NotebookStore(root: root).loadPage(id) == accepted)
    #expect(try store.currentChangeCursor() == cursor)
  }

  @Test(arguments: [Collision.samples, .tool, .color, .sequence])
  func thePhysicalRowWriterRejectsAChangedImmutableActionHeader(collision: Collision) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root)
    _ = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    let id = try #require(store.loadIndex().selectedPageID)
    let (original, candidate) = try pages(id: id, collision: collision)
    _ = try store.savePage(original)
    let before = try store.loadPage(id), cursor = try store.currentChangeCursor()
    #expect(throws: NotebookStorageError.self) { try store.publishRecords(writes: [pageFile(id): .encode(candidate)]) }
    #expect(try store.currentChangeCursor() == cursor)
    #expect(try NotebookStore(root: root).loadPage(id) == before)
  }

  @Test func thePhysicalRowWriterCannotReactivateAnAcceptedTombstone() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root)
    _ = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    let id = try #require(store.loadIndex().selectedPageID)
    let (original, _) = try pages(id: id, collision: .samples)
    _ = try store.savePage(original)
    let drawing = try PageInkDrawing.decode(original.drawingData)
    let undone = PageDocument(id: id, size: original.size, actor: UUID(),
      drawingData: try drawing.removing(Set(drawing.actions.map(\.id))).dataRepresentation())
    _ = try store.savePage(undone)
    let before = try store.loadPage(id), cursor = try store.currentChangeCursor()
    #expect(throws: NotebookStorageError.self) { try store.publishRecords(writes: [pageFile(id): .encode(original)]) }
    #expect(try store.currentChangeCursor() == cursor)
    #expect(try NotebookStore(root: root).loadPage(id) == before)
  }

  @Test(arguments: Collision.allCases)
  func workspacePublicationCannotBypassPageResolutionOrPublishEarlierMembership(collision: Collision) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    _ = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    let beforeIndex = try store.loadIndex(), id = try #require(beforeIndex.selectedPageID)
    let beforeBoard = try store.loadBoard(items: beforeIndex.items)
    let (original, candidate) = try pages(id: id, collision: collision)
    _ = try store.savePage(original)
    let beforePage = try store.loadPage(id), cursor = try store.currentChangeCursor()
    #expect(throws: PageInkDrawing.InkError.self) {
      try store.saveWorkspaceBundle(index: beforeIndex, page: candidate, board: beforeBoard)
    }
    var afterIndex = beforeIndex, afterBoard = beforeBoard
    let creation = afterIndex.createNotebook(title: "Must not publish", actor: actor, pageSize: original.size)
    let created = try #require(creation)
    let placed = afterBoard.addItem(created.item.id, to: beforeIndex.rootBoardID, near: .zero, actor: actor)
    #expect(placed)
    #expect(throws: PageInkDrawing.InkError.self) {
      try store.saveWorkspaceEdits(before: beforeIndex, after: afterIndex,
        boardBefore: beforeBoard, boardAfter: afterBoard, pages: [candidate, created.page])
    }
    #expect(try store.currentChangeCursor() == cursor)
    #expect(try store.loadIndex() == beforeIndex)
    #expect(try store.loadBoard(items: beforeIndex.items) == beforeBoard)
    #expect(try store.loadPage(id) == beforePage)
    #expect(try !store.hasStoredValue(pageFile(created.page.id)))
  }

  @Test(arguments: Collision.allCases)
  func archiveMergeCannotPublishOtherFieldsAfterAStrokeRefusal(collision: Collision) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root)
    _ = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    let id = try #require(store.loadIndex().selectedPageID)
    let (original, candidate) = try pages(id: id, collision: collision)
    _ = try store.savePage(original)
    let before = try store.collaborationContent()
    var incoming = before, result = before
    incoming.pages = [candidate]
    #expect(throws: PageInkDrawing.InkError.self) { try result.merge(incoming) }
    #expect(result == before)
  }

  @Test(arguments: [Collision.samples, .tool, .color, .sequence])
  func replicationRejectsTheWholeTransactionAndItsRepeatedCommand(collision: Collision) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let local = NotebookStore(root: root.appendingPathComponent("local"))
    let remote = NotebookStore(root: root.appendingPathComponent("remote"))
    let peerA = UUID(), peerB = UUID()
    let header = try local.initializeWorkspace(actor: peerA, pageSize: .init(width: 834, height: 1194))
    let id = try #require(local.loadIndex().selectedPageID)
    let (original, candidate) = try pages(id: id, collision: collision)
    try remote.prepareEmptyWorkspace(workspaceID: header.workspaceID)
    for change in try local.changeJournal(after: 0) { _ = try transfer(change, from: local, to: remote, peer: peerA) }
    for change in try remote.changeJournal(after: 0) { _ = try transfer(change, from: remote, to: local, peer: peerB) }
    _ = try local.savePage(original)
    let before = try local.loadPage(id), cursor = try local.currentChangeCursor()
    let received = try local.peerCursor(peerID: peerB, direction: .incoming)
    // Independent contacts claim the same UUID before either peer has seen
    // the other's stroke. Both local fragment publications are valid; only
    // the receiver can detect the collision with its accepted measurement.
    try remote.publishRecords(writes: [pageFile(id): .encode(candidate)])
    let change = try #require(remote.changeJournal(after: received).first)
    for _ in 0..<2 {
      #expect(throws: PageInkDrawing.InkError.self) { try transfer(change, from: remote, to: local, peer: peerB) }
      #expect(try local.peerCursor(peerID: peerB, direction: .incoming) == received)
      #expect(try local.currentChangeCursor() == cursor)
      #expect(try NotebookStore(root: local.root).loadPage(id) == before)
    }
  }

  private func transfer(_ change: NotebookDurableChange, from source: NotebookStore,
    to destination: NotebookStore, peer: UUID) throws -> UInt64 {
    while true {
      let hashes = try destination.missingBlobHashes(for: change)
      if hashes.isEmpty { break }
      for hash in hashes {
        let size = try source.blobSize(hash: hash)
        var bytes = Data()
        while Int64(bytes.count) < size {
          bytes += try source.readBlobChunk(hash: hash, offset: Int64(bytes.count), maxBytes: 1_048_576)
        }
        try destination.stageBlob(data: bytes, expectedHash: hash)
      }
    }
    return try destination.applyRemoteChange(change, peerID: peer)
  }
}

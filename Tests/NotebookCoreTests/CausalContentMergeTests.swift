import Foundation
import Testing
@testable import NotebookCore

@Suite struct CausalContentMergeTests {
  private let x = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
  private let y = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
  private let z = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
  private let orders = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]
  private var versions: [ContentFieldVersion] {
    [.init(stamp: .init(counter: 10, actor: x), human: true),
     .init(stamp: .init(counter: 11, actor: y), human: false,
       observed: [x.uuidString.lowercased(): 10, y.uuidString.lowercased(): 11]),
     .init(stamp: .init(counter: 9, actor: z), human: true)]
  }
  private struct State {
    let value: JSONValue
    let metadata: CollaborativeContent
    let stamp: VersionStamp
  }
  private func merge(_ a: State, _ b: State) throws -> State {
    let result = try CollaborativeContent.merge(local: a.value, incoming: b.value,
      localState: a.metadata, incomingState: b.metadata, localStamp: a.stamp, incomingStamp: b.stamp)
    return .init(value: result.value, metadata: result.state, stamp: max(a.stamp, b.stamp))
  }

  @Test func lateHumanEditSurvivesEveryDeliveryOrderAndParenthesization() throws {
    let values = versions.enumerated().map { index, version in
      State(value: .object(["text": .string(["a", "b", "c"][index])]),
        metadata: .init(fields: ["text": version]), stamp: version.stamp)
    }
    for order in orders {
      let a = values[order[0]], b = values[order[1]], c = values[order[2]]
      let left = try merge(merge(a, b), c), right = try merge(a, merge(b, c))
      #expect(left.value["text"] == .string("c"), "Delivery \(order)")
      #expect(right.value == left.value)
      #expect(right.metadata == left.metadata)
      for replay in values {
        let replayed = try merge(left, replay)
        #expect(replayed.value == left.value)
        #expect(replayed.metadata == left.metadata)
      }
      let cold = try JSONDecoder().decode(CollaborativeContent.self, from: JSONEncoder().encode(left.metadata))
      #expect(cold == left.metadata)
      let intermediate = try merge(a, b)
      let stored = try JSONDecoder().decode(CollaborativeContent.self, from: JSONEncoder().encode(intermediate.metadata))
      let resumed = try merge(.init(value: intermediate.value, metadata: stored, stamp: intermediate.stamp), c)
      #expect(resumed.value["text"] == .string("c"), "A cold join retains a non-winning author's value")
    }
  }

  @Test func aConcurrentRemovalDoesNotReauthorTheSurvivingPayloadOnReplay() throws {
    let original = JSONValue.object(["elements": .array([.object([
      "id": .string("material"), "source": .string("Keep this source"), "css": .string("black")])])])
    let removed = JSONValue.object(["elements": .array([])])
    let adopted = JSONValue.object(["elements": .array([.object([
      "id": .string("material"), "source": .string("Keep this source"), "css": .string("red")])])])
    var base = CollaborativeContent(); base.materializeVersions(in: original, fallback: versions[0].stamp)
    var deletion = base, edit = base
    deletion.record(before: original, after: removed, beforeStamp: versions[0].stamp, stamp: versions[1].stamp, human: false)
    edit.record(before: original, after: adopted, beforeStamp: versions[0].stamp, stamp: .init(counter: 11, actor: z), human: true)
    let states = [State(value: original, metadata: base, stamp: versions[0].stamp),
      State(value: removed, metadata: deletion, stamp: versions[1].stamp),
      State(value: adopted, metadata: edit, stamp: .init(counter: 11, actor: z))]
    for order in orders {
      var joined = try merge(merge(states[order[0]], states[order[1]]), states[order[2]])
      #expect(joined.value == adopted)
      for replay in states {
        joined = try merge(joined, replay)
        #expect(joined.value == adopted)
      }
    }
  }

  @Test func pagePayloadUsesTheSameCausalOwner() throws {
    let id = UUID(), pages = try (0..<3).map { try page(id: id, index: $0) }
    for order in orders {
      var left = pages[order[0]]
      _ = left.merge(pages[order[1]]); _ = left.merge(pages[order[2]])
      #expect(left.elements.first?.source == "c", "Page delivery \(order)")
      for old in pages { _ = left.merge(old); #expect(left.elements.first?.source == "c") }
    }
  }

  @Test func documentSourceAndBoardGeometryRetainTheSameIndependentHuman() throws {
    let id = UUID()
    let documents = try versions.enumerated().map { index, version in
      let document = DocumentDocument(id: id, actor: x, blocks: [.markdown(id: "body", source: ["a", "b", "c"][index])])
      return try JSONValue.encode(document).setting("contentStamp", .encode(version.stamp))
        .setting("collaboration", .encode(CollaborativeContent(fields: ["blocks/body/content": version]))).decode(DocumentDocument.self)
    }
    let boards = try versions.enumerated().map { index, version in
      let element = SpatialElement(id: "material", surface: .board(id), kind: .web,
        frame: .init(x: Double(index * 100), y: 10, width: 100, height: 100), worldOrigin: .zero,
        source: "same", stamp: .init(counter: 0, actor: x))
      let board = BoardDocument(freeItems: [], elements: [element], stamp: .init(counter: 0, actor: x))
      var fields = board.collaboration!.fields
      fields["elements/material/frame"] = version
      return try JSONValue.encode(board).setting("stamp", .encode(version.stamp))
        .setting("collaboration", .encode(CollaborativeContent(fields: fields))).decode(BoardDocument.self)
    }
    for order in orders {
      var document = documents[order[0]], board = boards[order[0]]
      for offset in order.dropFirst() {
        _ = document.merge(documents[offset]); _ = try board.merge(boards[offset], itemIDs: [])
      }
      #expect(document.blocks.first?.source == "c")
      #expect(board.elements.first?.frame.x == 200)
      for offset in 0..<3 {
        _ = document.merge(documents[offset]); _ = try board.merge(boards[offset], itemIDs: [])
        #expect(document.blocks.first?.source == "c")
        #expect(board.elements.first?.frame.x == 200)
      }
    }
  }

  private func page(id: UUID, index: Int) throws -> PageDocument {
    let version = versions[index]
    let element = AgentElement(id: "material", kind: .web, frame: .init(x: 10, y: 10, width: 100, height: 100),
      source: ["a", "b", "c"][index], html: "<button>Live</button>")
    var page = PageDocument(id: id, size: .init(width: 834, height: 1194), actor: x)
    let inserted = page.replaceElements([element], stamp: .init(counter: 1, actor: x)); #expect(inserted)
    var fields = page.collaboration!.fields
    fields["elements/material/content"] = version
    return try JSONValue.encode(page).setting("agentStamp", .encode(version.stamp))
      .setting("collaboration", .encode(CollaborativeContent(fields: fields))).decode(PageDocument.self)
  }

  @Test func twoSQLiteReplicasRetainALateHumanSourceAcrossDeliveryAndRestart() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("causal-field-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let local = NotebookStore(root: root.appendingPathComponent("local"))
    let remote = NotebookStore(root: root.appendingPathComponent("remote"))
    let (workspace, _) = try local.loadOrCreate(actor: x, pageSize: .init(width: 834, height: 1194))
    _ = try local.loadOrCreateBoard(workspace: workspace, actor: x)
    _ = try local.loadOrCreateSpatialInk(actor: x)
    let id = try #require(workspace.selectedPageID)
    _ = try local.savePage(page(id: id, index: 0))
    try remote.prepareEmptyWorkspace(workspaceID: local.workspaceHeader().workspaceID)
    try transfer(from: local, to: remote, peer: x)
    // Remote C has not seen B. Its first join with A must retain C even though A wins.
    _ = try remote.savePage(page(id: id, index: 2))
    _ = try local.savePage(page(id: id, index: 1))
    try transfer(from: local, to: remote, peer: x)
    try transfer(from: remote, to: local, peer: z)
    try transfer(from: local, to: remote, peer: x)
    for store in [local, remote, NotebookStore(root: local.root), NotebookStore(root: remote.root)] {
      #expect(try store.loadPage(id).elements.first?.source == "c")
      _ = try store.savePage(page(id: id, index: 0))
      _ = try store.savePage(page(id: id, index: 1))
      #expect(try store.loadPage(id).elements.first?.source == "c", "Old packets cannot replace the independent human edit")
    }
  }

  private func transfer(from source: NotebookStore, to destination: NotebookStore, peer: UUID) throws {
    while true {
      let cursor = try destination.peerCursor(peerID: peer, direction: .incoming)
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
      }
    }
  }
}

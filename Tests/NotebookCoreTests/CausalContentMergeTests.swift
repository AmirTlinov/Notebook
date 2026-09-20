import Foundation
import Testing
@testable import NotebookCore

@Suite struct CausalContentMergeTests {
  @Test func streamedBoardClocksMatchTheCanonicalFieldsAndPreserveExistingAuthors() throws {
    let actor=UUID(),other=UUID(),board=UUID(),stamp=VersionStamp(counter:3,actor:actor)
    let basis=NotebookElementBasis(size:.init(x:200,y:100))
    let elements:[SpatialElement] = [
      .init(id:"whole",surface:.board(board),kind:.group,frame:.init(x:20,y:30,width:400,height:200),worldOrigin:.zero,
        source:"",basis:basis,stamp:stamp),
      .init(id:"text/~",surface:.board(board),kind:.nativeText,frame:.init(x:4,y:5,width:100,height:60),worldOrigin:.zero,
        source:"Исходный текст",parentID:"whole",stamp:stamp),
      .init(id:"web",surface:.board(board),kind:.web,frame:.init(x:0,y:0,width:100,height:60),worldOrigin:.zero,
        source:"program",html:"<input>",state:.array([.number(1),.string("exact")]),basis:basis,stamp:stamp),
      .init(id:"shape",surface:.board(board),kind:.graphic,frame:.init(x:0,y:0,width:100,height:60),worldOrigin:.zero,
        source:"",graphic:.init(shape:.connector,connection:.init(start:.init(point:.init(x:0,y:0)),end:.init(point:.init(x:100,y:60)))),stamp:stamp)
    ]
    for values in [[],elements] {
      let key=fieldKey(["elements","text/~","content"])
      let retained=ContentFieldVersion(stamp:.init(counter:8,actor:other),human:false)
      let initial=CollaborativeContent(fields:[key:retained,"elements/retired/exists":retained])
      var expected=initial
      expected.materializeVersions(in:.object(["elements":try .encode(values)]),fallback:stamp)
      let actual=BoardDocument(placements:[],elements:values,stamp:stamp,collaboration:initial)
      #expect(actual.collaboration == expected)
      #expect(actual.collaboration?.fields[key] == retained)
      #expect(actual.elements == values)
    }
  }

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

  @Test func receivedContextCanAdvanceWithoutChangingTheAuthorOrValue() throws {
    let original = try storedClock(observed: [z.uuidString.lowercased(): 9])
    let accumulated = try storedClock(observed: [x.uuidString.lowercased(): 10,
      y.uuidString.lowercased(): 11, z.uuidString.lowercased(): 9])
    for (a, b) in [(original, accumulated), (accumulated, original)] {
      let joined = try a.resolving(value: .string("c"), with: b, incomingValue: .string("c"))
      #expect(joined.value == .string("c"))
      #expect(joined.version == accumulated)
      #expect(joined.version.isValid)
      #expect(try JSONValue.encode(joined.version)["heads"] == nil,
        "Received history is one register context, not a second copy on its author")
      #expect(try a.joining(b) == accumulated)
      #expect(throws: NotebookStorageError.invalidTransaction("content author value changed")) {
        try a.resolving(value: .string("c"), with: b, incomingValue: .string("forged"))
      }
    }
  }

  @Test func aNewEditAfterTheJoinSupersedesAllConcurrentValues() throws {
    let values = versions.enumerated().map { index, version in
      State(value: .object(["text": .string(["a", "b", "c"][index])]),
        metadata: .init(fields: ["text": version]), stamp: version.stamp)
    }
    let joined = try merge(merge(values[0], values[2]), values[1])
    let nextStamp = VersionStamp(counter: 12, actor: x)
    let next = State(value: .object(["text": .string("d")]), metadata: .init(fields: ["text":
      .init(stamp: nextStamp, human: false, previous: joined.metadata.fields["text"])]), stamp: nextStamp)
    for replay in values + [joined] {
      let result = try merge(next, replay)
      #expect(result.value == next.value, "Human priority applies to concurrency, not superseded edits")
      #expect(result.metadata == next.metadata)
      #expect(result.metadata.isValid)
    }
  }

  /// These are exactly the compact stored clocks written before concurrent
  /// values were retained. Observations could grow while the winner stayed C.
  private func storedClock(observed: [String: UInt64]) throws -> ContentFieldVersion {
    try JSONValue.object(["stamp": .encode(VersionStamp(counter: 9, actor: z)),
      "human": .bool(true), "observed": .encode(observed)]).decode(ContentFieldVersion.self)
  }

  @Test func twoSQLiteReplicasAcceptStoredAccumulatedContextAndContinueEditing() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("causal-upgrade-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let local = NotebookStore(root: root.appendingPathComponent("local"))
    let remote = NotebookStore(root: root.appendingPathComponent("remote"))
    let (workspace, _) = try local.loadOrCreate(actor: x, pageSize: .init(width: 834, height: 1194))
    _ = try local.loadOrCreateBoard(workspace: workspace, actor: x)
    _ = try local.loadOrCreateSpatialInk(actor: x)
    let id = try #require(workspace.selectedPageID)
    let original = try page(id: id, index: 2)
    let received = try storedClock(observed: [x.uuidString.lowercased(): 10,
      y.uuidString.lowercased(): 11, z.uuidString.lowercased(): 9])
    var fields = original.collaboration!.fields
    fields["elements/material/content"] = received
    let accumulated = try JSONValue.encode(original)
      .setting("collaboration", .encode(CollaborativeContent(fields: fields))).decode(PageDocument.self)
    _ = try local.savePage(original)
    try remote.prepareEmptyWorkspace(workspaceID: local.workspaceHeader().workspaceID)
    try transfer(from: local, to: remote, peer: x)
    _ = try NotebookStore(root: remote.root).savePage(accumulated)
    try transfer(from: remote, to: local, peer: z)
    try transfer(from: local, to: remote, peer: x)
    for store in [NotebookStore(root: local.root), NotebookStore(root: remote.root)] {
      let cold = try store.loadPage(id)
      #expect(cold.elements.first?.source == "c")
      #expect(cold.collaboration?.fields["elements/material/content"] == received)
      _ = try store.savePage(original)
      #expect(try store.loadPage(id).collaboration?.fields["elements/material/content"] == received)
    }
    var edited = try local.loadPage(id)
    let material = try #require(edited.elements.first)
    let changed = edited.replaceElements([.init(id: material.id, kind: material.kind, frame: material.frame,
      source: "After update", html: material.html)], stamp: .init(counter: 12, actor: x))
    #expect(changed)
    _ = try local.savePage(edited)
    try transfer(from: local, to: remote, peer: x)
    for store in [NotebookStore(root: local.root), NotebookStore(root: remote.root)] {
      _ = try store.savePage(accumulated)
      #expect(try store.loadPage(id).elements.first?.source == "After update")
    }
  }

  @Test func aConcurrentRemovalDoesNotReauthorTheSurvivingPayloadOnReplay() throws {
    let graphic: JSONValue = .object(["vertices":.array([.number(1),.number(2)]),
      "connection":.object(["start":.object(["point":.number(3)]),"end":.object(["point":.number(4)])])])
    let original = JSONValue.object(["elements": .array([.object([
      "id": .string("material"), "source": .string("Keep this source"), "css": .string("black"),"graphic":graphic])])])
    let removed = JSONValue.object(["elements": .array([])])
    let adopted = JSONValue.object(["elements": .array([.object([
      "id": .string("material"), "source": .string("Keep this source"), "css": .string("red"),"graphic":graphic])])])
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

  @Test func clearedOptionalGeometrySurvivesReorderingReplayAndSnapshotJoins() throws {
    let original: JSONValue = .object(["elements":.array([.object([
      "id":.string("ink"),"source":.string("exact"),"css":.string("black"),
      "graphic":.object(["label":.string("keep"),"transform":.object(["tx":.number(5)]),
        "connection":.object(["bend":.number(3),"routing":.string("curved")])])])])])
    let cleared: JSONValue = .object(["elements":.array([.object([
      "id":.string("ink"),"source":.string("exact"),
      "graphic":.object(["label":.string("keep"),"connection":.object(["routing":.string("curved")])])])])])
    var metadata=CollaborativeContent();metadata.materializeVersions(in:original,fallback:versions[0].stamp)
    let before=State(value:original,metadata:metadata,stamp:versions[0].stamp)
    let stamp=VersionStamp(counter:12,actor:x)
    metadata.record(before:original,after:cleared,beforeStamp:before.stamp,stamp:stamp,human:true)
    let after=State(value:cleared,metadata:metadata,stamp:stamp)
    let snapshot=try merge(before,after)
    let states=[before,after,snapshot]
    for order in orders {
      let a=states[order[0]],b=states[order[1]],c=states[order[2]]
      let left=try merge(merge(a,b),c),right=try merge(a,merge(b,c))
      #expect(left.value == cleared);#expect(right.value == cleared)
      #expect(left.metadata == right.metadata)
      for replay in states { #expect(try merge(left,replay).value == cleared) }
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

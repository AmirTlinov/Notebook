import CSQLite
import Foundation
import Testing
@testable import NotebookCore

@Suite("Addressed human PAGE ink source reads", .serialized)
struct NotebookPageInkReadTests {
  private final class Fixture {
    let content: NotebookItemLifecycleTests.Fixture
    let actions: [PageInkAction]
    var store: NotebookStore { content.store }
    var pageID: UUID { content.pageID }

    init() throws {
      content = try NotebookItemLifecycleTests.Fixture()
      // UUID traversal deliberately differs from authored drawing order.
      actions = [5, 1, 4, 2, 3].enumerated().map { offset, suffix in
        PageInkAction(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!,
          tool: suffix == 4 ? .eraser : .pen,
          samples: (0...offset).map { sample in
            .init(point: .init(x: Double(sample + 10), y: Double(suffix + 20)),
              timeOffset: Double(sample) / 120, width: 2, opacity: 1, force: 0.5, azimuth: 0, altitude: 1)
          }, sequence: UInt64(offset + 1), isActive: suffix != 2)
      }
      let drawing = PageInkDrawing(baselinePNG: Data([137, 80, 78, 71, 13, 10, 26, 10]),
        baselineActionCount: 7, actions: actions)
      var page = try content.store.loadPage(content.pageID)
      let changed = page.replaceDrawing(try drawing.dataRepresentation(), actor: content.actor)
      #expect(changed)
      _ = try content.store.savePage(page)
    }

    func query(_ kind: String, id: UUID? = nil, elementID: String? = nil,
      limit: Int? = nil, after: UUID? = nil, next: String? = nil) throws -> NotebookReadQuery {
      var raw: [String: JSONValue] = ["kind": .string(kind), "id": try .encode(id ?? pageID)]
      if let elementID { raw["elementID"] = .string(elementID) }
      if let limit { raw["limit"] = .number(Double(limit)) }
      if let after { raw["after"] = try .encode(after) }
      if let next { raw["next"] = .string(next) }
      return try JSONValue.object(raw).decode(NotebookReadQuery.self)
    }

    func read(_ query: NotebookReadQuery) throws -> JSONValue {
      var command = NotebookCommand(command: .read)
      command.queries = [query]; command.readSnapshots = true
      return try #require(try NotebookCommandDispatcher(store: store).handle(command).array.first)
    }

    func corruptBody(_ address: String) throws {
      try store.commandTransaction {
        try store.currentSQL!.run("UPDATE blobs SET data=? WHERE hash=(SELECT hash FROM records WHERE address=?)",
          [.blob(Data("Unrequested body must not be decoded".utf8)), .text(address)])
      }
    }
  }

  @Test func directoryPaginatesSourceMetadataWithAnHonestBaselineAndFrozenBasis() throws {
    let f = try Fixture(), firstQuery = try f.query("pageInkActions", limit: 2)
    let first = try f.read(firstQuery), firstData = try #require(first["data"])
    #expect(firstData["baseline"] == .object(["present": .bool(true), "actionCount": .number(7)]))
    let header = try #require(try firstData["header"]?.decode(NotebookContentHeader.self))
    let basis = try #require(try first["basis"]?.decode(NotebookReadBasis.self))
    #expect(basis.owners.count == 1)
    #expect(basis.owners.first?.target == .init(kind: .page, id: f.pageID))
    #expect(basis.owners.first?.revision == header.contentStamp.revision)
    #expect(basis.owners.first?.inkRevision == header.inkStamp?.revision)

    var snapshot = first, entries: [JSONValue] = []
    while true {
      entries += snapshot["data"]?["actions"]?.array ?? []
      guard let next = snapshot["coverage"]?["next"]?.string else {
        #expect(snapshot["coverage"]?["complete"] == .bool(true))
        #expect(snapshot["data"]?["nextActionID"] == nil)
        break
      }
      #expect(snapshot["coverage"]?["complete"] == .bool(false))
      #expect(snapshot["data"]?["nextActionID"] == snapshot["data"]?["actions"]?.array.last?["id"])
      snapshot = try f.read(f.query("pageInkActions", limit: 2, next: next))
      #expect(snapshot["basis"] == first["basis"])
      #expect(snapshot["cursor"] == first["cursor"])
    }
    let expected = f.actions.sorted { $0.id.uuidString < $1.id.uuidString }
    #expect(entries.count == expected.count)
    for (entry, action) in zip(entries, expected) {
      #expect(entry["id"] == (try .encode(action.id)))
      #expect(entry["tool"] == (try .encode(action.tool)))
      #expect(entry["sequence"] == .number(Double(action.sequence)))
      #expect(entry["isActive"] == .bool(action.isActive))
      #expect(entry["samples"] == nil && entry["sampleCount"] == nil)
    }
    let next = try #require(first["coverage"]?["next"]?.string)
    try f.content.write(f.pageID, text: "A newer cut cannot continue the old directory")
    do { _ = try f.read(f.query("pageInkActions", limit: 2, next: next)); Issue.record("A stale directory cursor was accepted") }
    catch let error as CollaborationError { #expect(error.code == "read_cursor_stale") }
  }

  @Test func exactHumanStrokePreservesMeasurementsAndMissingIDIsNull() throws {
    let f = try Fixture(), action = f.actions[2]
    let value = try f.read(f.query("pageInkAction", elementID: action.id.uuidString))
    let raw = try #require(value["data"]?["action"])
    let exact = try raw.setting("samples",raw["relations"]).decode(PageInkAction.self)
    #expect(try raw["samples"]?.decode([SpatialInkSample].self).elementsEqual(action.samples,by:InkSampleRelations.sameBits) == true)
    #expect(exact == action)
    #expect(exact.tool == .eraser)
    let header = try #require(try value["data"]?["header"]?.decode(NotebookContentHeader.self))
    let basis = try #require(try value["basis"]?.decode(NotebookReadBasis.self))
    #expect(basis.owners.count == 1 && basis.owners.first?.inkRevision == header.inkStamp?.revision)
    #expect(value["coverage"]?["complete"] == .bool(true))
    let missing = try f.read(f.query("pageInkAction", elementID: UUID().uuidString))
    #expect(missing["data"] == .null)
  }

  @Test func metadataNeverReadsSamplesOrRasterAndExactReadAvoidsOtherBodies() throws {
    let f = try Fixture(), address = pageFile(f.pageID) + "#/drawingData"
    for action in f.actions.dropFirst() {
      try f.corruptBody(address + "/actions/@" + action.id.uuidString.lowercased() + "/samples")
    }
    try f.corruptBody(address + "/baselinePNG")
    let directory = try f.read(f.query("pageInkActions", limit: 64))
    #expect(directory["data"]?["actions"]?.array.count == 5)
    #expect(directory["data"]?["baseline"]?["present"] == .bool(true))
    let exact = try f.read(f.query("pageInkAction", elementID: f.actions[0].id.uuidString))
    let raw=try #require(exact["data"]?["action"])
    #expect(try raw.setting("samples",raw["relations"]).decode(PageInkAction.self) == f.actions[0])
  }

  @Test func retiredSourceCannotBeReadThroughEitherQuery() throws {
    let f = try Fixture(), header = try f.store.workspaceHeader()
    let board = CollaborationTarget(kind: .board, id: header.rootBoardID)
    let basis = try f.store.readBasis(targets: [board, .init(kind: .workspace, id: header.rootBoardID)])
    _ = try f.store.applyCollaborationAction(.init(summary: "Keep neighbor", expected: basis.owners, operations: [
      .init(kind: .createNotebook, target: board, id: UUID().uuidString,
        values: ["center": try .encode(WorldPoint.zero), "pageID": try .encode(UUID())])
    ]), actor: f.content.actor)
    _ = try f.store.deleteWorkspaceItem(itemID: f.content.itemID, actor: f.content.actor)
    #expect(try f.store.hasStoredValue(pageFile(f.pageID)), "Deletion retains physical sources, not read authority")
    for kind in ["pageInkActions", "pageInkAction"] {
      let query = try f.query(kind, elementID: kind == "pageInkAction" ? f.actions[0].id.uuidString : nil)
      do { _ = try f.read(query); Issue.record("A retired PAGE source was exposed") }
      catch let error as CollaborationError { #expect(error.code == "target_missing") }
    }
  }

  @Test func exactBodiesShareTheExistingFourBodyBatchCapAndDirectoryLimit() throws {
    let f = try Fixture()
    var command = NotebookCommand(command: .read)
    command.readSnapshots = true
    command.queries = try f.actions.map { try f.query("pageInkAction", elementID: $0.id.uuidString) }
    do { _ = try NotebookCommandDispatcher(store: f.store).handle(command); Issue.record("Five addressed ink bodies were accepted") }
    catch let error as CollaborationError { #expect(error.code == "resource_limit") }
    do { _ = try f.read(f.query("pageInkActions", limit: 65)); Issue.record("An unbounded metadata directory was accepted") }
    catch let error as CollaborationError { #expect(error.code == "resource_limit") }
  }
}

extension NotebookPageInkReadTests {
  @Test func oneHumanStrokeAmongOneHundredThousandSourcesStaysAddressed() throws {
    let f = try Fixture(), file = pageFile(f.pageID), parent = pageFile(f.pageID) + "#/drawingData"
    func id(_ offset: Int) -> UUID {
      UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", offset))!
    }
    let selected = PageInkAction(id: UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!,
      tool: .pen, measurements: f.actions[0].samples, sequence: 100_006)
    let seedStarted = ContinuousClock.now
    try f.store.commandTransaction {
      let db = f.store.currentSQL!
      func write(_ action: PageInkAction, position: Int) throws {
        let address = parent + "/actions/@" + action.id.uuidString.lowercased()
        for row in try NotebookRecordCodec.encode(.encode(action), file: file, address: address,
          parent: parent, collection: "actions", member: action.id.uuidString.lowercased(), position: position) {
          try f.store.writeFragment(row, database: db)
        }
      }
      for offset in 0..<100_000 {
        try write(.init(id: id(offset), tool: .pen, measurements: f.actions[0].samples,
          sequence: UInt64(offset + 6)), position: offset + 5)
      }
      try write(selected, position: 100_005)
    }
    print("PAGE_INK_READ_SEED foreign_actions=100000 elapsed=\(seedStarted.duration(to: .now))")
    // Poison a late directory member, not merely an object outside that page.
    // Its metadata must stay readable without interpreting the samples.
    try f.corruptBody(parent + "/actions/@" + id(99_999).uuidString.lowercased() + "/samples")
    try f.corruptBody(parent + "/baselinePNG")
    let cursor = try f.store.currentReadCursor()
    let counter = UnsafeMutablePointer<Int>.allocate(capacity: 1)
    counter.initialize(to: 0)
    defer { counter.deinitialize(count: 1); counter.deallocate() }
    let started = ContinuousClock.now
    let values = try f.store.readTransaction { store in
      sqlite3_progress_handler(store.currentSQL!.handle, 1, { pointer in
        let count = pointer!.assumingMemoryBound(to: Int.self)
        count.pointee += 1
        return count.pointee > 20_000 ? 1 : 0
      }, counter)
      defer { sqlite3_progress_handler(store.currentSQL!.handle, 0, nil, nil) }
      let directory = try f.read(f.query("pageInkActions", limit: 4, after: id(99_997)))
      let action = try f.read(f.query("pageInkAction", elementID: selected.id.uuidString))
      return (directory, action)
    }
    #expect(values.0["data"]?["actions"]?.array.count == 3)
    #expect(values.0["coverage"]?["complete"] == .bool(true))
    let raw=try #require(values.1["data"]?["action"])
    #expect(try raw.setting("samples",raw["relations"]).decode(PageInkAction.self) == selected)
    #expect(counter.pointee > 0 && counter.pointee < 20_000)
    #expect(try f.store.currentReadCursor() == cursor)
    print("PAGE_INK_ADDRESSED_READ foreign_actions=100000 SQL_instructions=\(counter.pointee) elapsed=\(started.duration(to: .now))")
  }
}

import Foundation
import Testing
import NotebookCore
@testable import NotebookArchiveTransfer

private enum TransferFault: Error { case injected }

@Suite("Offline conversion preserves source owners and refuses unsafe publication")
struct ArchiveTransferTests {
  private struct Fixture {
    let root: URL
    let page: PageDocument
    let context: SharedContext
  }

  private func temporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("transfer-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func write(_ value: some Encodable, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(value).write(to: url)
  }

  private func fixture(at root: URL) throws -> Fixture {
    let actor = UUID()
    let initial = WorkspaceIndex.initial(actor: actor, pageSize: .init(width: 834, height: 1194))
    var catalog = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(initial.index)) as? [String: Any])
    catalog["format"] = 3
    catalog["selectedItemID"] = initial.index.selectedItemID.uuidString
    catalog["selectedPageID"] = initial.page.id.uuidString
    for key in ["collaboration", "pageOrders", "pageOrderNodes", "isProjection"] { catalog.removeValue(forKey: key) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: catalog).write(to: root.appendingPathComponent("workspace.json"))
    try write(BoardHierarchy.initial(rootBoardID: initial.index.rootBoardID, itemIDs: initial.index.items.map(\.id), actor: actor), to: root.appendingPathComponent("board.json"))
    try write(SpatialInkJournal(stamp: .init(counter: 0, actor: actor)), to: root.appendingPathComponent("spatial-ink.json"))
    let presence = SessionPresence(mode: .board, camera: .init(), viewport: .init(x: 834, y: 1194))
    var oldPresence = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(presence)) as? [String: Any])
    oldPresence["format"] = 4
    try JSONSerialization.data(withJSONObject: oldPresence).write(to: root.appendingPathComponent("last-context.json"))
    try write(initial.page, to: root.appendingPathComponent("pages/\(initial.page.id.uuidString.lowercased()).json"))
    let context = SharedContext(entries: [.init(author: .human, references: [], text: "Сохрани вопрос", stamp: .init(counter: 1, actor: actor))])
    try write(context, to: root.appendingPathComponent("collaboration/contexts/\(context.id.uuidString.lowercased()).json"))
    try write(SharedContextSelection(contextID: context.id, stamp: .init(counter: 2, actor: actor)), to: root.appendingPathComponent("collaboration/selection.json"))
    try write(["format": 2], to: root.appendingPathComponent("collaboration/format.json"))
    return .init(root: root, page: initial.page, context: context)
  }

  @Test func copiesEveryLiveOwnerWithoutChangingSourceAndRetainsOrphanEvidence() throws {
    let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try fixture(at: root.appendingPathComponent("backup"))
    let orphan = "pages/\(UUID().uuidString.lowercased()).json"
    let orphanBytes = Data("not a live page; never resurrect it".utf8)
    try orphanBytes.write(to: fixture.root.appendingPathComponent(orphan))
    let original = try inventory(fixture.root), id = UUID(), destination = root.appendingPathComponent("prepared")
    let report = try ArchiveTransfer.prepare(source: fixture.root, destination: destination, workspaceID: id)
    let store = NotebookStore(root: destination.appendingPathComponent("archive"))
    #expect(try store.loadPage(fixture.page.id) == fixture.page)
    #expect(try store.sharedContexts().contexts == [fixture.context])
    #expect(try store.sharedContexts().selection?.contextID == fixture.context.id)
    #expect(try store.loadPresence().notebookPageID == fixture.page.id)
    #expect(try store.workspaceHeader().workspaceID == id)
    #expect(try inventory(fixture.root) == original)
    #expect(report.sourceFiles == original)
    #expect(report.unreferencedFilesRetainedInSource == [orphan])
    #expect(!report.inputQuiescenceProven && !report.installedApplicationsChanged)
    #expect(try Data(contentsOf: fixture.root.appendingPathComponent(orphan)) == orphanBytes)
    #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("report.json").path))
  }

  @Test func binaryInkPreservesUUIDPointsUndoAndBaselineBytes() throws {
    let sample = SpatialInkSample(point: .init(x: 17.25, y: 39.5), timeOffset: 0.02,
      width: 2, opacity: 0.4, force: 0.7, azimuth: 0.3, altitude: 1.1)
    let first = PageInkAction(tool: .pen, samples: [sample], sequence: 0)
    let second = PageInkAction(tool: .eraser, samples: [sample], sequence: 8, isActive: false)
    let png = Data([137, 80, 78, 71, 13, 10, 26, 10])
    let drawing = PageInkDrawing(baselinePNG: png, baselineActionCount: 7, actions: [first, second])
    let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
    var fields = try #require(PropertyListSerialization.propertyList(from: encoder.encode(drawing), format: nil) as? [String: Any])
    var actions = try #require(fields["actions"] as? [[String: Any]])
    actions[0].removeValue(forKey: "sequence"); actions[0].removeValue(forKey: "isActive"); fields["actions"] = actions
    let bytes = try PropertyListSerialization.data(fromPropertyList: fields, format: .binary, options: 0)
    let result = try PageInkDrawing.decode(convertLegacyInk(Data("NotebookInk/1\n".utf8) + bytes))
    #expect(result == drawing)
    #expect(result.actions.map(\.id) == [first.id, second.id])
    #expect(result.baselinePNG == png)
    #expect(result.actions[1].isActive == false)
  }

  @Test func rejectsUnknownInkAndInvalidSamplesWithoutTrapping() throws {
    #expect(throws: ArchiveTransferError.self) { try convertLegacyInk(Data("PencilKit".utf8)) }
    let invalid: [String: Any] = ["baselineActionCount": -1, "actions": []]
    let bytes = try PropertyListSerialization.data(fromPropertyList: invalid, format: .binary, options: 0)
    #expect(throws: PageInkDrawing.InkError.self) { try convertLegacyInk(Data("NotebookInk/1\n".utf8) + bytes) }
  }

  @Test func unknownCanonicalOwnerRefusesBeforeAnyOutput() throws {
    let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try fixture(at: root.appendingPathComponent("backup")), output = root.appendingPathComponent("prepared")
    try Data("pending human input".utf8).write(to: fixture.root.appendingPathComponent("unrecognized-journal.json"))
    #expect(throws: ArchiveTransferError.self) { try ArchiveTransfer.prepare(source: fixture.root, destination: output, workspaceID: UUID()) }
    #expect(!FileManager.default.fileExists(atPath: output.path))
  }

  @Test func missingPageRefusesWithoutPublishing() throws {
    let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try fixture(at: root.appendingPathComponent("backup")), output = root.appendingPathComponent("prepared")
    try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("pages/\(fixture.page.id.uuidString.lowercased()).json"))
    #expect(throws: ArchiveTransferError.self) { try ArchiveTransfer.prepare(source: fixture.root, destination: output, workspaceID: UUID()) }
    #expect(!FileManager.default.fileExists(atPath: output.path))
  }

  @Test func finalSourceChangeOrFailurePublishesNothingAndRemovesOnlyOwnStaging() throws {
    let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try fixture(at: root.appendingPathComponent("backup")), output = root.appendingPathComponent("prepared")
    #expect(throws: TransferFault.self) {
      try ArchiveTransfer.prepare(source: fixture.root, destination: output, workspaceID: UUID()) { throw TransferFault.injected }
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["backup"])
    #expect(throws: ArchiveTransferError.self) {
      try ArchiveTransfer.prepare(source: fixture.root, destination: output, workspaceID: UUID()) {
        try Data("new bytes".utf8).write(to: fixture.root.appendingPathComponent("mcp-actor.txt"))
      }
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["backup"])
  }

  @Test func existingOrConcurrentDestinationIsNeverReplaced() throws {
    let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try fixture(at: root.appendingPathComponent("backup")), output = root.appendingPathComponent("prepared")
    let bytes = Data("another owner's destination".utf8)
    #expect(throws: (any Error).self) {
      try ArchiveTransfer.prepare(source: fixture.root, destination: output, workspaceID: UUID()) { try bytes.write(to: output) }
    }
    #expect(try Data(contentsOf: output) == bytes)
    #expect(throws: ArchiveTransferError.self) { try ArchiveTransfer.prepare(source: fixture.root, destination: output, workspaceID: UUID()) }
    #expect(try Data(contentsOf: output) == bytes)
  }

  @Test func symlinkAndNestedDestinationCannotRedirectTransfer() throws {
    let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try fixture(at: root.appendingPathComponent("backup")), output = root.appendingPathComponent("prepared")
    let link = root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.root)
    #expect(throws: ArchiveTransferError.self) {
      try ArchiveTransfer.prepare(source: fixture.root, destination: link.appendingPathComponent("nested"), workspaceID: UUID())
    }
    try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("previews"), withDestinationURL: root)
    #expect(throws: ArchiveTransferError.self) { try ArchiveTransfer.prepare(source: fixture.root, destination: output, workspaceID: UUID()) }
    #expect(!FileManager.default.fileExists(atPath: output.path))
  }
  @Test func restoresOnlyReceiptBoundEmptyAgentEntries() throws {
    struct Receipt: Encodable {
      let id: UUID; let action: CollaborationAction; let createdAt: Date
      let revisions: [CollaborationExpectation] = []; let changes: [String] = []
    }
    let id = UUID(), date = Date(timeIntervalSinceReferenceDate: 1234)
    let action = CollaborationAction(id: id, summary: "Существующее описание действия", expected: [], operations: [])
    let receipt = try JSONDecoder().decode(CollaborationReceipt.self,
      from: JSONEncoder().encode(Receipt(id: id, action: action, createdAt: date)))
    let placeholder = SharedContextEntry(id: id, author: .agent, references: [],
      stamp: .init(counter: 1, actor: id), createdAt: date)
    let converted = try convertLegacyContexts([.init(id: id, entries: [placeholder])], actions: [receipt])
    #expect(converted.restoredSummaryEntryIDs == [id])
    #expect(converted.contexts[0].entries[0].text == action.summary)
    #expect(converted.contexts[0].entries[0].id == placeholder.id)
    #expect(converted.contexts[0].entries[0].createdAt == placeholder.createdAt)
    #expect(converted.contexts[0].entries[0].stamp == placeholder.stamp)
    #expect(throws: ArchiveTransferError.self) {
      try convertLegacyContexts([.init(id: id, entries: [placeholder])], actions: [])
    }
    let human = SharedContextEntry(id: id, author: .human, references: [],
      stamp: placeholder.stamp, createdAt: date)
    #expect(throws: ArchiveTransferError.self) {
      try convertLegacyContexts([.init(id: id, entries: [human])], actions: [receipt])
    }
  }

}

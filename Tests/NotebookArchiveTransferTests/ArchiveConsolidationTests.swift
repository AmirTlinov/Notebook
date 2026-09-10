import Foundation
import NotebookCore
import Testing
@testable import NotebookArchiveTransfer

@Suite("Offline consolidation retains both archives and stopped requests")
struct ArchiveConsolidationTests {
  private struct Fixture {
    let root: URL
    let legacy: LegacyArchiveFixture
    let peer: URL
    let current: NotebookStore
    let request: AgentRequest
    let page: PageDocument
    var destination: URL { root.appendingPathComponent("combined") }

    init(root: URL) throws {
      self.root = root
      legacy = try LegacyArchiveFixture.make(at: root.appendingPathComponent("legacy-ipad"))
      peer = root.appendingPathComponent("legacy-mac")
      try FileManager.default.copyItem(at: legacy.root, to: peer)
      current = NotebookStore(root: root.appendingPathComponent("current"))
      let actor = UUID()
      _ = try current.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
      let content = try current.collaborationContent()
      page = content.pages[0]
      try current.savePresence(.init(mode: .page, camera: .init(), viewport: .init(x: 834, y: 1194),
        focusedItemID: content.workspace.selectedItemID, openProgress: 1,
        selectedItemID: content.workspace.selectedItemID, notebookPageID: page.id))
      let target = CollaborationTarget(kind: .page, id: page.id)
      let reference = try CollaborationReference(target: target, region: .init(x: 10, y: 10, width: 40, height: 40),
        revision: current.referenceRevision(target: target))
      let context = try current.appendContext(references: [reference], author: .human, actor: actor, text: "Фрагмент", select: true)
      let id = UUID()
      let source = try AgentPinnedSource.capture(requestID: id, reference: reference, files: content.sourceFiles())
      request = try current.createAgentRequest(id: id, contextID: context.id, replyTo: context.entries[0].id,
        question: "Остановленный вопрос", grant: .init(mode: .question, references: [reference]), sources: [source], actor: actor)
      try current.requestAgentStop(request.id, actor: actor)
      try Data("keep non-SQL application data".utf8).write(to: current.root.appendingPathComponent("retained-local-file"))
    }

    func prepare(beforePublication: (() throws -> Void)? = nil) throws -> ArchiveConsolidationReport {
      try ArchiveConsolidation.prepare(legacyIPad: legacy.root, legacyMac: peer, current: current.root,
        destination: destination, beforePublication: beforePublication)
    }
  }

  @Test func retainsCurrentOwnersSelectionStoppedRequestAndEveryLegacyOwner() throws {
    let root = try transferTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let f = try Fixture(root: root)
    let presence = try f.current.loadPresence(), request = try f.current.agentRequest(f.request.id)
    let selection = try f.current.sharedContexts().selection, workspaceID = try f.current.workspaceHeader().workspaceID
    let before = try [f.legacy.root, f.peer, f.current.root].map(inventory)
    let report = try f.prepare(), output = NotebookStore(root: f.destination.appendingPathComponent("archive"))
    #expect(report.itemCount == 2 && report.pageCount == 2)
    #expect(try output.loadPage(f.legacy.page.id) == f.legacy.page)
    #expect(try output.loadPage(f.page.id) == f.page)
    #expect(try output.loadPresence() == presence)
    #expect(try output.agentRequest(f.request.id) == request)
    #expect(try output.agentRequest(f.request.id)?.execution == nil)
    #expect(try output.agentRequest(f.request.id)?.stopRequested == true)
    #expect(try output.sharedContexts().selection == selection)
    #expect(try output.sharedContexts().contexts.contains(f.legacy.context))
    #expect(report.workspaceID == workspaceID)
    #expect(report.retainedCurrentRecordCount > 0)
    #expect(!report.inputQuiescenceProven && !report.installedApplicationsChanged)
    #expect(try Data(contentsOf: output.root.appendingPathComponent("retained-local-file")) == Data("keep non-SQL application data".utf8))
    #expect(try [f.legacy.root, f.peer, f.current.root].map(inventory) == before)
  }

  @Test func refusesMacOnlyHistoryAndDoesNotPublishPartialArchive() throws {
    let root = try transferTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let f = try Fixture(root: root)
    let extra = SharedContext(entries: [.init(author: .human, references: [], text: "Только на Mac", stamp: .init(counter: 1, actor: UUID()))])
    try writeTransferFixture(extra, to: f.peer.appendingPathComponent("collaboration/contexts/\(extra.id.uuidString.lowercased()).json"))
    let before = try inventory(f.current.root)
    #expect(throws: ArchiveTransferError.self) { try f.prepare() }
    #expect(!FileManager.default.fileExists(atPath: f.destination.path))
    #expect(try inventory(f.current.root) == before)
  }

  @Test func sourceChangeBeforePublicationRefusesAndKeepsAllBackups() throws {
    let root = try transferTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let f = try Fixture(root: root)
    #expect(throws: ArchiveTransferError.self) {
      try f.prepare { try Data("new input".utf8).write(to: f.current.root.appendingPathComponent("retained-local-file")) }
    }
    #expect(!FileManager.default.fileExists(atPath: f.destination.path))
    #expect(try f.current.loadPage(f.page.id) == f.page)
    #expect(try f.current.agentRequest(f.request.id)?.stopRequested == true)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".notebook-consolidation-") })
  }

  @Test func competingPublicationIsNeverOverwrittenOrRemoved() throws {
    let root = try transferTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let f = try Fixture(root: root)
    let sentinel = f.destination.appendingPathComponent("sentinel")
    #expect(throws: (any Error).self) {
      try f.prepare {
        try FileManager.default.createDirectory(at: f.destination, withIntermediateDirectories: false)
        try Data("another publisher".utf8).write(to: sentinel)
      }
    }
    #expect(try Data(contentsOf: sentinel) == Data("another publisher".utf8))
    #expect(throws: ArchiveTransferError.self) { try f.prepare() }
  }

  @Test func unknownCurrentOwnerIsCopiedButNeverInterpretedAsLegacy() throws {
    let root = try transferTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let f = try Fixture(root: root)
    let before = try ArchiveRecordProof.read(f.current.root)
    #expect(before.contains { $0.file.hasPrefix("agent/sources/") })
    let report = try f.prepare()
    let protected = before.filter { !["workspace.json", "board.json", "spatial-ink.json"].contains($0.file) }
    #expect(protected.allSatisfy(report.afterRecords.contains))
  }

  @Test func historicalAddressCannotBeReboundToTheOtherArchive() throws {
    let root = try transferTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let f = try Fixture(root: root)
    let extra = SharedContext(entries: [.init(author: .human,
      references: [.init(target: .init(kind: .page, id: f.page.id), revision: "historical")],
      stamp: .init(counter: 1, actor: UUID()))])
    for archive in [f.legacy.root, f.peer] {
      try writeTransferFixture(extra, to: archive.appendingPathComponent("collaboration/contexts/\(extra.id.uuidString.lowercased()).json"))
    }
    #expect(throws: ArchiveTransferError.self) { try f.prepare() }
    #expect(!FileManager.default.fileExists(atPath: f.destination.path))
  }

  @Test func physicalIdentityCollisionAndLossyMergeAreRejected() throws {
    let root = try transferTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let f = try Fixture(root: root)
    let content = try f.current.collaborationContent()
    #expect(throws: ArchiveTransferError.self) {
      try ArchiveConsolidation.requireIndependentOwners(current: content, incoming: content)
    }
    var lost = content; lost.pages = []
    #expect(throws: ArchiveTransferError.self) { try ArchiveConsolidation.requirePreserved(content, in: lost) }
  }

  @Test func activeRootNestedSourcesAndMissingDatabaseAreRejectedWithoutCreation() throws {
    let root = try transferTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let f = try Fixture(root: root)
    #expect(throws: ArchiveTransferError.self) {
      try ArchiveConsolidation.prepare(legacyIPad: f.legacy.root, legacyMac: f.peer,
        current: NotebookStore.defaultRoot, destination: f.destination)
    }
    #expect(throws: ArchiveTransferError.self) {
      try ArchiveConsolidation.prepare(legacyIPad: root, legacyMac: f.peer, current: f.current.root, destination: f.destination)
    }
    let empty = root.appendingPathComponent("empty")
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
    #expect(throws: ArchiveTransferError.self) {
      try ArchiveConsolidation.prepare(legacyIPad: f.legacy.root, legacyMac: f.peer, current: empty, destination: f.destination)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: empty.path).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: f.destination.path))
  }

  private func baseline(at root: URL, page: PageDocument, variant: UInt8, original: Data?) throws {
    let png = Data([137, 80, 78, 71, 13, 10, 26, 10, variant])
    let payload = PageInkDrawing(baselinePNG: png, baselineActionCount: 1)
    let ink = try Data("NotebookInk/1\n".utf8) + PropertyListEncoder().encode(payload)
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(page)) as? [String: Any])
    json["drawingData"] = ink.base64EncodedString()
    let path = "pages/\(page.id.uuidString.lowercased()).json"
    try JSONSerialization.data(withJSONObject: json).write(to: root.appendingPathComponent(path))
    if let original {
      json["drawingData"] = original.base64EncodedString()
      let url = root.appendingPathComponent("migrations/before-ink-v1/" + path)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONSerialization.data(withJSONObject: json).write(to: url)
    }
  }

  @Test func baselineDecisionReportsBothHashesAndTheSharedOriginalBytes() throws {
    let root = try transferTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let f = try Fixture(root: root)
    let fixture = try #require(Bundle.module.url(forResource: "one-stroke", withExtension: "pkd", subdirectory: "Resources"))
    let original = try Data(contentsOf: fixture)
    try baseline(at: f.legacy.root, page: f.legacy.page, variant: 1, original: original)
    try baseline(at: f.peer, page: f.legacy.page, variant: 2, original: original)
    let report = try f.prepare(), choice = try #require(report.selectedIPadBaselines.first)
    #expect(choice.pageID == f.legacy.page.id)
    #expect(choice.originalPencilKitSHA256 == digest(original))
    #expect(choice.retainedIPadPNGSHA256 != choice.peerPNGSHA256)
    let output = NotebookStore(root: f.destination.appendingPathComponent("archive"))
    let drawing = try PageInkDrawing.decode(output.loadPage(f.legacy.page.id).drawingData)
    #expect(digest(try #require(drawing.baselinePNG)) == choice.retainedIPadPNGSHA256)
  }

  @Test(arguments: [false, true]) func differentOrMissingOriginalBytesForbidChoosingABaseline(missing: Bool) throws {
    let root = try transferTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let f = try Fixture(root: root)
    try baseline(at: f.legacy.root, page: f.legacy.page, variant: 1, original: Data("original A".utf8))
    try baseline(at: f.peer, page: f.legacy.page, variant: 2, original: missing ? nil : Data("original B".utf8))
    #expect(throws: ArchiveTransferError.self) { try f.prepare() }
    #expect(!FileManager.default.fileExists(atPath: f.destination.path))
  }

  @Test func matchingGarbageIsNotAcceptedAsOriginalPencilKit() throws {
    let root = try transferTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let f = try Fixture(root: root), invalid = Data("not PencilKit".utf8)
    try baseline(at: f.legacy.root, page: f.legacy.page, variant: 1, original: invalid)
    try baseline(at: f.peer, page: f.legacy.page, variant: 2, original: invalid)
    #expect(throws: ArchiveTransferError.self) { try f.prepare() }
    #expect(!FileManager.default.fileExists(atPath: f.destination.path))
  }

  @Test func MacOnlyInkAndChangedImmutablePointsCannotBeLost() throws {
    let root = try transferTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let f = try Fixture(root: root), actor = UUID(), id = UUID()
    func journal(x: Double) -> SpatialInkJournal {
      .init(actions: [.init(id: id, tool: .pen,
        spans: [.init(surface: .board(WorkspaceRoot.boardID), samples: [.init(point: .init(x: x, y: 2), worldPoint: .init(x: x, y: 2),
          timeOffset: 0, width: 2, opacity: 1, force: 1, azimuth: 0, altitude: 1)])],
        stamp: .init(counter: 1, actor: actor))], stamp: .init(counter: 1, actor: actor))
    }
    try writeTransferFixture(journal(x: 1), to: f.peer.appendingPathComponent("spatial-ink.json"))
    #expect(throws: ArchiveTransferError.self) { try f.prepare() }
    try writeTransferFixture(journal(x: 2), to: f.legacy.root.appendingPathComponent("spatial-ink.json"))
    #expect(throws: ArchiveTransferError.self) { try f.prepare() }
    #expect(!FileManager.default.fileExists(atPath: f.destination.path))
  }
}

import Foundation
import Testing
@testable import NotebookCore

private enum ActivationFailure: Error { case injected }

@Suite("Archive activation never exposes an incomplete or rolled-back owner")
struct NotebookArchiveActivationTests {
  private struct Fixture {
    let base: URL
    let source: URL
    let candidate: URL
    let target = NotebookArchiveTarget(role: .iPad, bundleID: "test.notebook.ipad", actorID: UUID())
    let transitionID = UUID()
    var control: URL { NotebookArchiveActivation.controlURL(for: source) }
    init() throws {
      base = FileManager.default.temporaryDirectory.appendingPathComponent("archive-activation-" + UUID().uuidString)
      source = base.appendingPathComponent("Notebook")
      candidate = base.appendingPathComponent("converted")
      try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
      // Core must preserve these opaque bytes, not attempt a legacy decoder.
      try Data("old handwritten original".utf8).write(to: source.appendingPathComponent("workspace.json"))
      let store = NotebookStore(root: candidate)
      _ = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
      try store.savePresence(.init(mode: .board, camera: .init(), viewport: .init(x: 834, y: 1194)))
      try store.commandTransaction {
        try store.publishRecords(writes: ["document-drafts/test.json": .object(["text": .string("unsent draft")]),
          "collaboration/custom-owner.json": .object(["value": .string("keep unknown non-domain owner")])])
      }
    }
    func prepare(_ activation: NotebookArchiveActivation = .init()) throws -> NotebookArchiveActivationManifest {
      try activation.prepare(source: source, candidate: candidate, output: control, transitionID: transitionID, target: target)
    }
    func launch(_ activation: NotebookArchiveActivation = .init()) throws -> NotebookArchiveLaunch {
      try activation.launch(root: source, target: target)
    }
  }

  @Test func missingPayloadDoesNotCreateOrOpenAnArchive() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let target = NotebookArchiveTarget(role: .iPad, bundleID: "test", actorID: UUID())
    #expect(try NotebookArchiveActivation().launch(root: root, target: target) == .unchanged)
    #expect(!FileManager.default.fileExists(atPath: root.path))
  }

  @Test func exchangesWholeDirectoriesAndRequiresBothReceipts() throws {
    let value = try Fixture(); defer { try? FileManager.default.removeItem(at: value.base) }
    let before = try NotebookArchiveFingerprint.read(value.source)
    let originalCandidate = try NotebookArchiveFingerprint.read(value.candidate)
    let manifest = try value.prepare()
    #expect(try NotebookArchiveFingerprint.read(value.source) == before)
    #expect(try NotebookArchiveFingerprint.read(value.candidate) == originalCandidate)
    guard case .waitingForPair(let receipt) = try value.launch() else { Issue.record("pair must not start yet"); return }
    #expect(try NotebookArchiveFingerprint.read(value.source) == manifest.candidate)
    #expect(try NotebookArchiveFingerprint.read(value.control.appendingPathComponent("candidate")) == before)
    #expect(try NotebookStore(root: value.source).storedValue("document-drafts/test.json")?["text"]?.string == "unsent draft")
    #expect(throws: NotebookStorageError.self) { try NotebookArchiveAdmission(receipts: [receipt]) }
    #expect(throws: NotebookStorageError.self) { try NotebookArchiveAdmission(receipts: [receipt, receipt]) }
    // A real second device independently activates its own archive.
    let macRoot = value.base.appendingPathComponent("Mac")
    try FileManager.default.createDirectory(at: macRoot, withIntermediateDirectories: false)
    try Data("independent Mac original".utf8).write(to: macRoot.appendingPathComponent("workspace.json"))
    let target = NotebookArchiveTarget(role: .mac, bundleID: "test.notebook.mac", actorID: UUID())
    let macControl = NotebookArchiveActivation.controlURL(for: macRoot)
    _ = try NotebookArchiveActivation().prepare(source: macRoot, candidate: value.candidate, output: macControl,
      transitionID: value.transitionID, target: target)
    guard case .waitingForPair(let mac) = try NotebookArchiveActivation().launch(root: macRoot, target: target) else {
      Issue.record("Mac must await the pair"); return
    }
    let admission = try NotebookArchiveAdmission(receipts: [receipt, mac])
    try admission.publish(at: value.control); try admission.publish(at: macControl)
    #expect(try value.launch() == .admitted(receipt))
    #expect(try NotebookArchiveActivation().launch(root: macRoot, target: target) == .admitted(mac))
  }

  @Test(arguments: [NotebookArchiveActivationFault.beforeSwap, .afterSwap, .beforeReceipt, .afterReceipt])
  func everyInterruptedActivationRecoversWithoutASwapBack(point: NotebookArchiveActivationFault) throws {
    let value = try Fixture(); defer { try? FileManager.default.removeItem(at: value.base) }
    let manifest = try value.prepare()
    let interrupted = NotebookArchiveActivation(fault: { if $0 == point { throw ActivationFailure.injected } })
    #expect(throws: ActivationFailure.self) { try value.launch(interrupted) }
    guard case .waitingForPair(let receipt) = try value.launch() else { Issue.record("recovery must retain admission gate"); return }
    #expect(receipt.transitionID == value.transitionID)
    #expect(try NotebookArchiveFingerprint.read(value.source) == manifest.candidate)
    #expect(try NotebookArchiveFingerprint.read(value.control.appendingPathComponent("candidate")) == manifest.source)
    #expect(try value.launch() == .waitingForPair(receipt))
  }

  @Test func aNewWriteIsNeverReplacedByThePreparedSnapshot() throws {
    let value = try Fixture(); defer { try? FileManager.default.removeItem(at: value.base) }
    _ = try value.prepare()
    guard case .waitingForPair(let receipt) = try value.launch() else { Issue.record("missing receipt"); return }
    let store = NotebookStore(root: value.source)
    let presence = SessionPresence(mode: .board, camera: .init(center: .init(x: 72, y: 19), scale: 0.5), viewport: .init(x: 834, y: 1194))
    try store.savePresence(presence)
    #expect(try value.launch() == .waitingForPair(receipt))
    #expect(try store.loadPresence() == presence)
  }

  @Test(arguments: ["source", "candidate", "identity", "disk"])
  func invalidPreparationCannotChangeOriginal(reason: String) throws {
    let value = try Fixture(); defer { try? FileManager.default.removeItem(at: value.base) }
    _ = try value.prepare()
    if reason == "source" { try Data("newly saved stroke".utf8).write(to: value.source.appendingPathComponent("later.json")) }
    if reason == "candidate" { try Data("corruption".utf8).write(to: value.control.appendingPathComponent("candidate/extra.json")) }
    let before = try NotebookArchiveFingerprint.read(value.source)
    let activation = NotebookArchiveActivation(availableBytes: { _ in reason == "disk" ? 0 : UInt64.max })
    let target = reason == "identity" ? NotebookArchiveTarget(role: .iPad, bundleID: value.target.bundleID, actorID: UUID()) : value.target
    #expect(throws: NotebookStorageError.self) { try activation.launch(root: value.source, target: target) }
    #expect(try NotebookArchiveFingerprint.read(value.source) == before)
    #expect(!FileManager.default.fileExists(atPath: value.control.appendingPathComponent("activation.json").path))
  }

  @Test(arguments: [NotebookArchiveActivationFault.afterCandidateCopy, .beforeManifestPublication])
  func interruptedPreparationPublishesNothing(point: NotebookArchiveActivationFault) throws {
    let value = try Fixture(); defer { try? FileManager.default.removeItem(at: value.base) }
    let before = try NotebookArchiveFingerprint.read(value.source), candidate = try NotebookArchiveFingerprint.read(value.candidate)
    let failure = NotebookArchiveActivation(fault: { if $0 == point { throw ActivationFailure.injected } })
    #expect(throws: ActivationFailure.self) { try value.prepare(failure) }
    #expect(!FileManager.default.fileExists(atPath: value.control.path))
    #expect(try NotebookArchiveFingerprint.read(value.source) == before)
    #expect(try NotebookArchiveFingerprint.read(value.candidate) == candidate)
  }

  @Test func symlinkAndExistingPayloadAreRejected() throws {
    let value = try Fixture(); defer { try? FileManager.default.removeItem(at: value.base) }
    let link = value.source.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: value.candidate)
    #expect(throws: NotebookStorageError.self) { try value.prepare() }
    try FileManager.default.removeItem(at: link)
    _ = try value.prepare()
    let manifest = try Data(contentsOf: value.control.appendingPathComponent("transition.json"))
    #expect(throws: NotebookStorageError.self) { try value.prepare() }
    #expect(try Data(contentsOf: value.control.appendingPathComponent("transition.json")) == manifest)
  }

  @Test func replicaRetainsStoppedRequestAndDropsOnlyForeignLocalExecution() throws {
    let value = try Fixture(); defer { try? FileManager.default.removeItem(at: value.base) }
    let store = NotebookStore(root: value.candidate), actor = UUID()
    let content = try store.collaborationContent(), page = try #require(content.pages.first)
    let target = CollaborationTarget(kind: .page, id: page.id)
    let reference = try CollaborationReference(target: target, region: .init(x: 0, y: 0, width: 20, height: 20), revision: store.referenceRevision(target: target))
    let context = try store.appendContext(references: [reference], author: .human, actor: actor, text: "Existing question", select: false)
    let id = UUID(), source = try AgentPinnedSource.capture(requestID: UUID(), reference: reference, files: content.sourceFiles())
    let pinned = AgentPinnedSource(id: source.id, requestID: id, reference: reference, payload: source.payload, image: nil)
    let request = AgentRequest(id: id, contextID: context.id, questionEntryID: context.entry.id,
      grant: try .init(mode: .question, references: [reference]), authorDeviceID: actor, sourceIDs: [reference.id])
    // Import a historical stopped record, never start a removed executor to seed it.
    try store.publishRecords(writes: [store.agentRequestFile(id): .encode(request),
      store.agentSourceFile(id, reference.id): .encode(pinned),
      store.agentStopFile(id): .encode(AgentStopIntent(requestID: id, authorDeviceID: actor))])
    _ = try store.collaborationActorID()
    let job = NotebookChatInput(author: actor, action: .create(title: "Do not execute twice"))
    _ = try store.saveChatInput(job)
    try store.commandTransaction {
      try store.currentSQL!.run("INSERT INTO peer_cursors(peer_id,direction,sequence) VALUES(?,'incoming',7)", [.text(UUID().uuidString)])
    }
    let before = try NotebookArchiveFingerprint.read(store.root)
    let replicaURL = value.base.appendingPathComponent("replica"), presence = SessionPresence(mode: .board,
      camera: .init(center: .init(x: 100, y: 200)), viewport: .init(x: 500, y: 400))
    let proof = try store.prepareReplicaSnapshot(at: replicaURL, presence: presence)
    #expect(try NotebookArchiveFingerprint.read(store.root) == before)
    let replica = NotebookStore(root: replicaURL)
    #expect(try replica.archiveContentProof().sharedRecordsSHA256 == proof.sharedRecordsSHA256)
    #expect(try replica.agentRequest(id)?.request == request)
    #expect(try replica.agentRequest(id)?.stopRequested == true)
    #expect(try replica.agentRequest(id)?.execution == nil)
    #expect(try replica.loadPresence() == presence)
    #expect(try replica.storedValue("document-drafts/test.json") == nil)
    #expect(try replica.storedValue("local/actor.json") == nil)
    #expect(try replica.chatJob(job.id) == nil)
    #expect(try store.chatJob(job.id) != nil)
    #expect(try replica.sqlRead { try $0.rows("SELECT * FROM peer_cursors").isEmpty })
    #expect(throws: NotebookStorageError.self) { try store.prepareReplicaSnapshot(at: replicaURL, presence: presence) }
  }

  @Test func completedLaunchNeedsNoHistoricalInventoryAndKeepsNewWrites() throws {
    let value = try Fixture(); defer { try? FileManager.default.removeItem(at: value.base) }
    _ = try value.prepare()
    guard case .waitingForPair(let receipt) = try value.launch() else { Issue.record("missing receipt"); return }
    // A completed receipt must not depend on proportional historical input
    // inventories, even if that old report is moved to external evidence.
    try FileManager.default.removeItem(at: value.control.appendingPathComponent("transition.json"))
    let store = NotebookStore(root: value.source)
    let updated = SessionPresence(mode: .board, camera: .init(center: .init(x: 91, y: 17)), viewport: .init(x: 500, y: 400))
    try store.savePresence(updated)
    #expect(try value.launch() == .waitingForPair(receipt))
    #expect(try store.loadPresence() == updated)
  }

  @Test func lateSourceChangeIsCheckedImmediatelyBeforeExchange() throws {
    let value = try Fixture(); defer { try? FileManager.default.removeItem(at: value.base) }
    let manifest = try value.prepare(), file = value.source.appendingPathComponent("later.json")
    let owner = NotebookArchiveActivation(fault: { point in
      if point == .beforeSwap { try Data("last accepted input".utf8).write(to: file) }
    })
    #expect(throws: NotebookStorageError.transactionConflict) { try value.launch(owner) }
    #expect(try Data(contentsOf: file) == Data("last accepted input".utf8))
    #expect(try NotebookArchiveFingerprint.read(value.control.appendingPathComponent("candidate")) == manifest.candidate)
  }

  @Test func sharedProofIncludesPlacementOfRecordsNotOnlyTheirBytes() throws {
    let value = try Fixture(); defer { try? FileManager.default.removeItem(at: value.base) }
    let store = NotebookStore(root: value.candidate), before = try store.archiveContentProof()
    // A corrupted ordering must not impersonate the same portable archive even
    // if every addressed value and all of its immutable bytes are unchanged.
    try store.commandTransaction {
      try store.currentSQL!.run("UPDATE records SET position=position+1 WHERE file='collaboration/custom-owner.json'")
    }
    let after = try store.archiveContentProof()
    #expect(before.sharedRecordCount == after.sharedRecordCount)
    #expect(before.sharedRecordsSHA256 != after.sharedRecordsSHA256)
  }

  @Test func corruptCompletedReceiptCannotAdmitAModel() throws {
    let value = try Fixture(); defer { try? FileManager.default.removeItem(at: value.base) }
    _ = try value.prepare()
    guard case .waitingForPair(let receipt) = try value.launch() else { Issue.record("missing receipt"); return }
    let damaged = NotebookArchiveActivationReceipt(transitionID: receipt.transitionID, target: receipt.target,
      manifestSHA256: String(repeating: "z", count: 64), content: receipt.content)
    try NotebookArchiveFiles.publish(damaged, at: value.control.appendingPathComponent("activation.json"))
    #expect(throws: NotebookStorageError.self) { try value.launch() }
  }
}

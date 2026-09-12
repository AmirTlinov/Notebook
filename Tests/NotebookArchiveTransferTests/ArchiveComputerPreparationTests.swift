import Foundation
import NotebookCore
import Testing
@testable import NotebookArchiveTransfer

@Suite("A second Mac enrolls without replacing the current pair", .serialized)
struct ArchiveComputerPreparationTests {
  private struct Fixture {
    let root: URL, iPad: URL, firstMac: URL, fresh: URL
    let padTarget = NotebookArchiveTarget(role: .iPad, bundleID: "com.amirtlinov.notebook.preview", actorID: UUID())
    let firstTarget = NotebookArchiveTarget(role: .mac, bundleID: "com.amirtlinov.notebook.mac", actorID: UUID())
    let nextTarget = NotebookArchiveTarget(role: .mac, bundleID: "com.amirtlinov.notebook.mac", actorID: UUID())
    let admission: NotebookArchiveAdmission
    init() throws {
      root = try transferTestRoot(); iPad = root.appendingPathComponent("iPad"); firstMac = root.appendingPathComponent("firstMac"); fresh = root.appendingPathComponent("newMac")
      let candidate = root.appendingPathComponent("candidate"), actor = UUID()
      let store = NotebookStore(root: candidate)
      _ = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
      try store.savePresence(.init(mode: .board, camera: .init(center: .init(x: 340, y: 128), scale: 0.4), viewport: .init(x: 834, y: 1194)))
      let activation = NotebookArchiveActivation(), transition = UUID()
      var receipts: [NotebookArchiveActivationReceipt] = []
      for (path, target) in [(iPad, padTarget), (firstMac, firstTarget)] {
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        _ = try activation.prepare(source: path, candidate: candidate, output: NotebookArchiveActivation.controlURL(for: path), transitionID: transition, target: target)
        guard case .waitingForPair(let receipt) = try activation.launch(root: path, target: target) else { throw CocoaError(.fileReadCorruptFile) }
        receipts.append(receipt)
      }
      admission = try .init(receipts: receipts)
      for path in [iPad, firstMac] { try admission.publish(at: NotebookArchiveActivation.controlURL(for: path)) }
      try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: false)
    }
    var request: ArchiveComputerRequest { .init(currentIPad: iPad.path, freshMac: fresh.path, mac: nextTarget) }
    var protected: [URL] { [iPad, firstMac, NotebookArchiveActivation.controlURL(for: iPad), NotebookArchiveActivation.controlURL(for: firstMac)] }
  }
  private func deliver(_ source: NotebookStore, _ target: NotebookStore, peer: UUID) throws {
    let cursor = try target.peerCursor(peerID: peer, direction: .incoming)
    for change in try source.changeJournal(after: cursor) {
      while true {
        let missing = try target.missingBlobHashes(for: change)
        if missing.isEmpty { break }
        for hash in missing {
          let size = try source.blobSize(hash: hash)
          var bytes = Data()
          while bytes.count < size { bytes += try source.readBlobChunk(hash: hash, offset: Int64(bytes.count), maxBytes: 1_048_576) }
          try target.stageBlob(data: bytes, expectedHash: hash)
        }
      }
      _ = try target.applyRemoteChange(change, peerID: peer)
    }
  }
  @Test func currentMaterialAndCursorContinueOnAnIndependentMacWithoutCopyingLocalWork() throws {
    let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    let source = NotebookStore(root: f.iPad)
    let file = NotebookFileAddress(computer: f.firstTarget.actorID, project: "demo", root: "/project", path: "main.py")
    let note = NotebookCodeFragment(file: file, sourceHash: NotebookFileVersion.hash(Data("print(4)".utf8)), utf16Offset: 0,
      text: "print(4)", width: 600, height: 100, fontSize: 15, stamp: .init(counter: 9, actor: f.padTarget.actorID))
    try source.captureCodeFragment(note)
    try source.saveFileDraft(.init(address: file, text: "private unsent draft"))
    _ = try source.saveChatInput(.init(author: f.padTarget.actorID, action: .create(title: "Do not execute this on the new Mac")), to: f.firstTarget.actorID)
    try source.saveChatPanel(.init(threadID: nil, draft: "private chat draft", sidecarID: f.firstTarget.actorID), author: f.padTarget.actorID)
    let frontier = try source.currentChangeCursor(), before = try f.protected.map(NotebookArchiveFingerprint.read)
    let output = f.root.appendingPathComponent("output"), report = try ArchiveComputerPreparation.prepare(f.request, output: output)
    #expect(!report.installedApplicationsChanged)
    #expect(report.source.cursor == String(frontier))
    #expect(try f.protected.map(NotebookArchiveFingerprint.read) == before)
    let control = NotebookArchiveActivation.controlURL(for: f.fresh)
    try FileManager.default.copyItem(at: output.appendingPathComponent("mac"), to: control)
    let activation = NotebookArchiveActivation()
    guard case .waitingForPair(let receipt) = try activation.launch(root: f.fresh, target: f.nextTarget) else { Issue.record("new Mac must wait for actual receipt admission"); return }
    let admission = try report.source.admission(receipt: receipt, manifest: report.manifest)
    #expect(throws: (any Error).self) { try admission.publish(at: NotebookArchiveActivation.controlURL(for: f.iPad)) }
    #expect(throws: (any Error).self) { try NotebookInstallationPairingGrant(admission: admission) }
    try admission.publish(at: control)
    #expect(try activation.launch(root: f.fresh, target: f.nextTarget) == .admitted(receipt))
    let next = NotebookStore(root: f.fresh)
    #expect(try next.codeFragment(note.id) == note)
    #expect(try next.fileDraft(file) == nil)
    #expect(try next.recentChatJobs(author: f.padTarget.actorID).isEmpty)
    #expect(try next.activeChatComputer(author: f.padTarget.actorID) == nil)
    #expect(try next.peerCursor(peerID: f.padTarget.actorID, direction: .incoming) == frontier)
    #expect(try f.protected.map(NotebookArchiveFingerprint.read) == before)
    let later = NotebookCodeFragment(file: file, sourceHash: note.sourceHash, utf16Offset: 0, text: note.text,
      width: 500, height: 100, fontSize: 15, stamp: .init(counter: 10, actor: f.padTarget.actorID))
    try source.captureCodeFragment(later)
    try deliver(source, next, peer: f.padTarget.actorID)
    #expect(try next.codeFragment(later.id) == later)
    let camera = try source.loadPresence()
    try deliver(next, source, peer: f.nextTarget.actorID)
    #expect(try source.codeFragment(note.id) == note)
    #expect(try source.loadPresence() == camera)
    #expect(try source.fileDraft(file)?.text == "private unsent draft")
    #expect(try activation.launch(root: f.fresh, target: f.nextTarget) == .admitted(receipt), "Later content must not roll back to the prepared snapshot")
  }
  @Test func existingContentAndCopiedDeviceIdentityAreRefusedWithoutChangingTheCurrentPair() throws {
    let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    let before = try f.protected.map(NotebookArchiveFingerprint.read)
    let copied = ArchiveComputerRequest(currentIPad: f.iPad.path, freshMac: f.fresh.path, mac: f.firstTarget)
    #expect(throws: (any Error).self) { try ArchiveComputerPreparation.prepare(copied, output: f.root.appendingPathComponent("copy")) }
    try Data("existing local content".utf8).write(to: f.fresh.appendingPathComponent("do-not-replace"))
    #expect(throws: (any Error).self) { try ArchiveComputerPreparation.prepare(f.request, output: f.root.appendingPathComponent("refused")) }
    #expect(try String(contentsOf: f.fresh.appendingPathComponent("do-not-replace"), encoding: .utf8) == "existing local content")
    #expect(try f.protected.map(NotebookArchiveFingerprint.read) == before)
  }
}

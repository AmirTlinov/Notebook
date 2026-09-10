import Foundation
import NotebookCore
import Testing
@testable import NotebookArchiveTransfer

@Suite("External pair preparation preserves Lab and gives Mac independent admission")
struct ArchivePairPreparationTests {
  @Test func bothDeviceCopiesActivateTheSameContentAndKeepTheStoppedQuestion() throws {
    let root = try transferTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try ArchiveConsolidationTests.Fixture(root: root)
    let author = UUID()
    var index = try fixture.current.loadIndex(), board = try fixture.current.loadBoard(items: index.items)
    let created = index.createDocument(title: "Portable program", actor: author)
    let item = try #require(created)
    let placed = board.addItem(item.id, to: index.rootBoardID, near: .zero, actor: author)
    #expect(placed)
    try fixture.current.saveDocumentWorkspaceBundle(index: index,
      document: .init(id: item.id, actor: author, blocks: [.interactive(id: "counter", html: "<button>Before</button>",
        initialState: .object(["records": .array([.object(["id": .string("value"), "count": .number(7)])])]))]),
      state: .init(id: item.id, actor: author), board: board)
    let request = ArchivePairRequest(transitionID: UUID(), legacyIPad: fixture.legacy.root.path,
      legacyMac: fixture.peer.path, currentIPad: fixture.current.root.path,
      iPad: .init(role: .iPad, bundleID: "com.amirtlinov.notebook.preview", actorID: UUID()),
      mac: .init(role: .mac, bundleID: "com.amirtlinov.notebook.mac", actorID: UUID()))
    let before = try [fixture.legacy.root, fixture.peer, fixture.current.root].map(inventory)
    let output = root.appendingPathComponent("pair"), report = try ArchivePairPreparation.prepare(request, output: output)
    #expect(report.iPadManifest.content.sharedRecordsSHA256 == report.macManifest.content.sharedRecordsSHA256)
    #expect(report.iPadManifest.target.actorID != report.macManifest.target.actorID)
    #expect(!report.installedApplicationsChanged)
    #expect(try [fixture.legacy.root, fixture.peer, fixture.current.root].map(inventory) == before)
    let ipad = root.appendingPathComponent("running-ipad"), mac = root.appendingPathComponent("running-mac")
    try FileManager.default.copyItem(at: fixture.current.root, to: ipad)
    try FileManager.default.copyItem(at: fixture.peer, to: mac)
    for (name, destination) in [("ipad", ipad), ("mac", mac)] {
      try FileManager.default.copyItem(at: output.appendingPathComponent(name), to: NotebookArchiveActivation.controlURL(for: destination))
    }
    let activation = NotebookArchiveActivation()
    guard case .waitingForPair(let ipadReceipt) = try activation.launch(root: ipad, target: request.iPad),
      case .waitingForPair(let macReceipt) = try activation.launch(root: mac, target: request.mac) else {
      Issue.record("neither copy may start the model before admission"); return
    }
    let admission = try NotebookArchiveAdmission(receipts: [ipadReceipt, macReceipt])
    for destination in [ipad, mac] {
      try admission.publish(at: NotebookArchiveActivation.controlURL(for: destination))
      let store = NotebookStore(root: destination)
      #expect(try store.agentRequest(fixture.request.id)?.stopRequested == true)
      #expect(try store.agentRequest(fixture.request.id)?.execution == nil)
      #expect(try store.loadPage(fixture.page.id) == fixture.page)
      #expect(try store.loadPage(fixture.legacy.page.id) == fixture.legacy.page)
    }
    #expect(try activation.launch(root: ipad, target: request.iPad) == .admitted(ipadReceipt))
    #expect(try activation.launch(root: mac, target: request.mac) == .admitted(macReceipt))
    let a = NotebookStore(root: ipad), b = NotebookStore(root: mac)
    let ipadSeed = try #require(a.changeJournal(after: 0).first), macSeed = try #require(b.changeJournal(after: 0).first)
    #expect(ipadSeed.sequence == 1 && macSeed.sequence == 1)
    try deliver(ipadSeed, from: a, to: b, peer: request.iPad.actorID)
    try deliver(macSeed, from: b, to: a, peer: request.mac.actorID)
    #expect(try a.currentChangeCursor() == 1 && b.currentChangeCursor() == 1,
      "Identical prepared seeds must not create a delivery echo")
    var edited = try a.loadDocument(item.id)
    let changed = edited.replaceBlockSource(id: "counter", source: "<button>After activation</button>", actor: request.iPad.actorID)
    #expect(changed)
    try a.saveMergedDocument(edited)
    let update = try #require(a.changeJournal(after: 1).first)
    #expect(update.sequence == 2)
    try deliver(update, from: a, to: b, peer: request.iPad.actorID)
    #expect(try a.loadDocument(item.id) == b.loadDocument(item.id))
    #expect(try b.loadDocument(item.id).blocks[0].html == "<button>After activation</button>")
    #expect(try [fixture.legacy.root, fixture.peer, fixture.current.root].map(inventory) == before)
  }

  private func deliver(_ change: NotebookDurableChange, from source: NotebookStore, to destination: NotebookStore, peer: UUID) throws {
    while true {
      let hashes = try destination.missingBlobHashes(for: change)
      if hashes.isEmpty { break }
      for hash in hashes {
        let size = try source.blobSize(hash: hash)
        var data = Data()
        while Int64(data.count) < size { data += try source.readBlobChunk(hash: hash, offset: Int64(data.count), maxBytes: 1_048_576) }
        try destination.stageBlob(data: data, expectedHash: hash)
      }
    }
    _ = try destination.applyRemoteChange(change, peerID: peer)
  }

  @Test func originalBundleCannotBeChosenAsTheNewIPadDestination() throws {
    let root = try transferTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try ArchiveConsolidationTests.Fixture(root: root)
    let request = ArchivePairRequest(transitionID: UUID(), legacyIPad: fixture.legacy.root.path,
      legacyMac: fixture.peer.path, currentIPad: fixture.current.root.path,
      iPad: .init(role: .iPad, bundleID: "com.amirtlinov.notebook", actorID: UUID()),
      mac: .init(role: .mac, bundleID: "com.amirtlinov.notebook.mac", actorID: UUID()))
    let output = root.appendingPathComponent("pair")
    #expect(throws: ArchiveTransferError.self) { try ArchivePairPreparation.prepare(request, output: output) }
    #expect(!FileManager.default.fileExists(atPath: output.path))
  }
}

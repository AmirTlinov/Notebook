import Foundation
import NotebookCore
import Testing
@testable import NotebookArchiveTransfer

@Suite("External pair preparation preserves Lab and gives Mac independent admission")
struct ArchivePairPreparationTests {
  @Test func bothDeviceCopiesActivateTheSameContentAndKeepTheStoppedQuestion() throws {
    let root = try transferTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try ArchiveConsolidationTests.Fixture(root: root)
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
    #expect(try [fixture.legacy.root, fixture.peer, fixture.current.root].map(inventory) == before)
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

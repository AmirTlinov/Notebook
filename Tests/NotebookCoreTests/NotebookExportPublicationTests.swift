import Foundation
import Testing
@testable import NotebookCore

func stageExportFixture(_ data: Data, path: String = "document.pdf", store: NotebookStore) throws -> NotebookExportFile {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try data.write(to: url); defer { try? FileManager.default.removeItem(at: url) }
  let file = try NotebookExportFile.inspect(url, path: path)
  var offset: Int64 = 0
  for part in file.file.parts {
    try store.stageBlob(file: url, expectedHash: part.sha256, byteCount: Int64(part.byteCount), range: offset..<(offset+Int64(part.byteCount)))
    offset += Int64(part.byteCount)
  }
  return file
}

struct NotebookExportPublicationTests {
  private func publish(_ store: NotebookStore, _ publication: NotebookExportPublication) throws -> NotebookExportReceipt {
    try store.publishDocumentExport(store.prepareDocumentExport(publication))
  }
  private func fixture() throws -> (NotebookStore, DocumentDocument) {
    let store = NotebookStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("notebook-print-package-\(UUID())"))
    _ = try store.loadOrCreate(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    let actor = UUID()
    var index = try store.loadIndex(), board = try store.loadBoard(items: index.items)
    let created = index.createDocument(title: "Print fixture", actor: actor)
    let item = try #require(created)
    let added = board.addItem(item.id, to: index.rootBoardID, near: .zero, actor: actor)
    #expect(added)
    let document = DocumentDocument(id: item.id, actor: actor, blocks: [.markdown(id: "body", source: "Printed")])
    try store.saveDocumentWorkspaceBundle(index: index, document: document,
      state: .init(id: item.id, actor: actor), board: board)
    return (store, try store.loadDocument(document.id))
  }
  @Test func packageAddressBindsSourceAndAssetsAndPreservesPriorExportBytes() throws {
    let (store, document) = try fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
    let pdf = Data("%PDF-controlled-final".utf8), image = Data("%PDF-controlled-image".utf8)
    func publish(_ source: String, _ asset: Data = image) throws -> NotebookExportReceipt {
      try self.publish(store, .init(cut: try .init(document: document, state: store.loadDocumentState(document.id)),
        source: source, artifact: stageExportFixture(pdf, store: store), log: "", assets: [stageExportFixture(asset, path: "notebook-image-0.pdf", store: store)]))
    }
    let first = try publish("first"), repeatFirst = try publish("first"), second = try publish("second")
    let third = try publish("first", Data("%PDF-another-image".utf8))
    #expect(first.packageSHA256 == repeatFirst.packageSHA256)
    #expect(first.artifact.sha256 == second.artifact.sha256)
    #expect(first.packageSHA256 != second.packageSHA256 && first.packageSHA256 != third.packageSHA256)
    #expect(try String(contentsOfFile: first.source!.path, encoding: .utf8) == "first")
    #expect(try Data(contentsOf: URL(fileURLWithPath: #require(first.assets?.first?.path))) == image)
    #expect(try FileManager.default.contentsOfDirectory(atPath: store.root.appendingPathComponent("exports").path).allSatisfy { !$0.hasPrefix(".pending-") })
  }
  @Test func stalePublicationNeverInstallsAPartialPackage() throws {
    let (store, document) = try fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
    let cut = try NotebookExportCut(document: document, state: store.loadDocumentState(document.id))
    var edited = document
    let changed = edited.replaceBlockSource(id: "body", source: "Edited after request", actor: UUID()); #expect(changed)
    try store.saveDocument(edited)
    do {
      _ = try self.publish(store, .init(cut: cut,
        source: "source", artifact: stageExportFixture(Data("%PDF-result".utf8), store: store), log: ""))
      Issue.record("An export of stale content cannot publish")
    } catch let error as CollaborationError { #expect(error.code == "revision_conflict") }
    #expect(try FileManager.default.contentsOfDirectory(atPath: store.root.appendingPathComponent("exports").path).isEmpty)
  }
  @Test func assetNamesCannotEscapeThePreparedPackage() throws {
    let (store, document) = try fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
    #expect(throws: CollaborationError.self) {
      try self.publish(store, .init(cut: try .init(document: document, state: store.loadDocumentState(document.id)),
        source: "source", artifact: stageExportFixture(Data("%PDF-result".utf8), store: store), log: "", assets: [NotebookExportFile(file: .init(path: "../outside.pdf", mimeType: "application/pdf", byteCount: 0, parts: []), sha256: String(repeating: "a", count: 64))]))
    }
    #expect(!FileManager.default.fileExists(atPath: store.root.appendingPathComponent("outside.pdf").path))
  }
  @Test func preparationAndCommitHaveDistinctOwnership() throws {
    let (store, document) = try fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
    let publication = NotebookExportPublication(cut: try .init(document: document, state: store.loadDocumentState(document.id)),
      source: "native command", artifact: try stageExportFixture(Data("%PDF-native-export".utf8), store: store), log: "")
    let prepared = try store.prepareDocumentExport(publication)
    #expect(!FileManager.default.fileExists(atPath: prepared.receipt.artifact.path))
    #expect(store.currentSQL == nil)
    #expect(throws: NotebookStorageError.self) {
      try store.commandTransaction { try store.prepareDocumentExport(publication) }
    }
    let receipt = try store.publishDocumentExport(prepared)
    #expect(try String(contentsOfFile: receipt.source!.path, encoding: .utf8) == "native command")
  }
  @Test func stateAndCausalABAInvalidateAQueuedCutWithoutChangingPriorArtifacts() throws {
    let (store, document) = try fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
    let cut = try NotebookExportCut(document: document, state: store.loadDocumentState(document.id))
    let publication = NotebookExportPublication(cut: cut, source: "same source", artifact: try stageExportFixture(Data("%PDF-same".utf8), store: store), log: "")
    let saved = try publish(store, publication)
    #expect(saved.cutSHA256 == (try cut.sha256))
    #expect(try Data(contentsOf: URL(fileURLWithPath: saved.cut.path)) == cut.canonicalData())
    var state = cut.state
    let changed = state.commit(blockID: "body", value: .number(1), actor: UUID()); #expect(changed)
    try store.saveDocumentState(state)
    do { _ = try publish(store, publication); Issue.record("State changed, source did not") }
    catch let error as CollaborationError { #expect(error.code == "revision_conflict") }
    let reset = state.commit(blockID: "body", value: .null, actor: UUID()); #expect(reset)
    try store.saveDocumentState(state)
    #expect(throws: CollaborationError.self) { try publish(store, publication) }
    let next = try NotebookExportCut(document: document, state: state)
    let newReceipt = try self.publish(store, .init(cut: next, source: publication.source, artifact: publication.artifact, log: ""))
    #expect(newReceipt.artifact.sha256 == saved.artifact.sha256)
    #expect(newReceipt.packageSHA256 != saved.packageSHA256)
    #expect(newReceipt.cutSHA256 != saved.cutSHA256)
    #expect(try Data(contentsOf: URL(fileURLWithPath: saved.artifact.path)) == Data("%PDF-same".utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath: store.root.appendingPathComponent("exports").path).allSatisfy { !$0.hasPrefix(".pending-") })
  }
  @Test func sourceMapAndSyncTeXAreBoundToTheExactAtomicPrintPackage() throws {
    let (store, document) = try fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
    let source = "header\nPrinted\nend\n", pdf = Data("%PDF-controlled".utf8)
    let syncTeX = Data([0x1f, 0x8b, 0x08, 0x00])
    let map = try DocumentPrintSourceMap(document: document, source: source, pdf: pdf,
      ranges: [.init(blockID: "body", firstLine: 2, lastLine: 2)])
    let receipt = try self.publish(store, .init(cut: try .init(document: document, state: store.loadDocumentState(document.id)),
      source: source, artifact: stageExportFixture(pdf, store: store), log: "",
      sourceMap: map, syncTeX: stageExportFixture(syncTeX, path: "document.synctex.gz", store: store)))
    let bytes = try Data(contentsOf: URL(fileURLWithPath: #require(receipt.sourceMap?.path)))
    #expect(try JSONDecoder().decode(DocumentPrintSourceMap.self, from: bytes) == map)
    #expect(try Data(contentsOf: URL(fileURLWithPath: #require(receipt.syncTeX?.path))) == syncTeX)
    #expect(throws: CollaborationError.self) {
      try self.publish(store, .init(cut: try .init(document: document, state: store.loadDocumentState(document.id)),
        source: source, artifact: stageExportFixture(Data("%PDF-other".utf8), store: store), log: "", sourceMap: map, syncTeX: stageExportFixture(syncTeX, path: "document.synctex.gz", store: store)))
    }
    #expect(throws: CollaborationError.self) {
      try self.publish(store, .init(cut: try .init(document: document, state: store.loadDocumentState(document.id)),
        source: source, artifact: stageExportFixture(pdf, store: store), log: "", sourceMap: map))
    }
  }
  @Test func badWholeHashAndMissingPartsNeverPublishOrLeavePendingFiles() throws {
    let (store, document) = try fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
    let cut = try NotebookExportCut(document: document, state: store.loadDocumentState(document.id))
    let valid = try stageExportFixture(Data("%PDF-integrity".utf8), store: store)
    let prior = try publish(store, .init(cut: cut, source: "source", artifact: valid, log: ""))
    let incorrect = NotebookExportFile(file: valid.file, sha256: String(repeating: "a", count: 64))
    #expect(throws: NotebookStorageError.self) { try store.prepareDocumentExport(.init(cut: cut, source: "source", artifact: incorrect, log: "")) }
    let missing = NotebookExportFile(file: .init(path: "document.pdf", mimeType: "application/pdf", byteCount: 12,
      parts: [.init(sha256: String(repeating: "b", count: 64), byteCount: 12)]), sha256: valid.sha256)
    #expect(throws: NotebookStorageError.self) { try store.prepareDocumentExport(.init(cut: cut, source: "source", artifact: missing, log: "")) }
    #expect(try Data(contentsOf: URL(fileURLWithPath: prior.artifact.path)) == Data("%PDF-integrity".utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath: store.root.appendingPathComponent("exports").path).count == 1)
  }

  @Test func cancellationBeforePreparationLeavesThePriorPackageWhole() async throws {
    let (store, document) = try fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
    let cut = try NotebookExportCut(document: document, state: store.loadDocumentState(document.id))
    let file = try stageExportFixture(Data("%PDF-cancel".utf8), store: store)
    let publication = NotebookExportPublication(cut: cut, source: "source", artifact: file, log: "")
    let prior = try publish(store, publication)
    let task = Task.detached {
      withUnsafeCurrentTask { $0?.cancel() }
      return try store.prepareDocumentExport(publication)
    }
    do { _ = try await task.value; Issue.record("Cancelled preparation cannot produce a capability") }
    catch is CancellationError { }
    #expect(try Data(contentsOf: URL(fileURLWithPath: prior.artifact.path)) == Data("%PDF-cancel".utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath: store.root.appendingPathComponent("exports").path).count == 1)
  }

  @Test func durableCancellationAndPublicationHaveOneWriterWinnerAcrossRestart() throws {
    let (store, document) = try fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
    let cut = try NotebookExportCut(document: document, state: store.loadDocumentState(document.id))
    let file = try stageExportFixture(Data("%PDF-cancel-race".utf8), store: store)
    func job(_ id: UUID) throws -> NotebookPreparedExport {
      try store.saveScriptExportJob(id, value: .object(["status": .string("running"), "jobID": .string(id.uuidString.lowercased()), "cutSHA256": .string(try cut.sha256)]))
      return try store.prepareDocumentExport(.init(cut: cut, source: "source", artifact: file, log: "", jobID: id))
    }
    func cancellation(_ id: UUID) throws -> NotebookScriptEffectAddress {
      let run = UUID()
      _ = try store.admitScriptRun(.init(op: .start, runID: run, apiVersion: 2, code: "cancel"))
      _ = try store.setScriptRunState(run, state: .running)
      var effect = try store.admitScriptEffect(run, key: "stop", method: "cancelExport", arguments: .object(["key": .string("stop"), "jobID": .string(id.uuidString)]))
      effect.state = .committing; try store.saveScriptEffect(run, effect: effect)
      return .init(runID: run, effectID: effect.id)
    }
    let savedID = UUID(), saved = try store.publishDocumentExport(job(savedID))
    let late = try cancellation(savedID), won = try store.cancelScriptExport(savedID, effect: late)
    #expect(won["status"]?.string == "saved")
    #expect(won["receipt"]?["artifact"]?["sha256"] == .string(saved.artifact.sha256))
    let cancelledID = UUID(), prepared = try job(cancelledID), address = try cancellation(cancelledID)
    let cancelled = try store.cancelScriptExport(cancelledID, effect: address)
    #expect(cancelled["status"]?.string == "cancelled")
    #expect(throws: CancellationError.self) { try store.publishDocumentExport(prepared) }
    try store.saveScriptExportJob(cancelledID, value: .object(["status": .string("running")]))
    let reopened = NotebookStore(root: store.root)
    try reopened.interruptUnfinishedScriptExports()
    #expect(try reopened.scriptExportJob(cancelledID) == cancelled)
    #expect(try reopened.reconcileScriptEffect(address.runID, id: address.effectID).value == cancelled)
    #expect(try reopened.cancelScriptExport(cancelledID, effect: address) == cancelled)
    #expect(try Data(contentsOf: URL(fileURLWithPath: saved.artifact.path)) == Data("%PDF-cancel-race".utf8))
  }

  @Test func pngOptionsBindPageIdentityAndRejectWrongExtentOrFormat() throws {
    let (store, document) = try fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
    let cut = try NotebookExportCut(document: document, state: store.loadDocumentState(document.id))
    #expect(throws: CollaborationError.self) { try NotebookExportOptions(format: .pdf, pageIndex: 0).validate() }
    #expect(throws: CollaborationError.self) { try NotebookExportOptions(format: .png, pixelWidth: 4097).validate() }
    // Storage inspects bounded headers, not a second image decoder. The native
    // exporter test supplies and visually checks the complete real PNG.
    let header = Data([137,80,78,71,13,10,26,10,0,0,0,13,73,72,68,82,0,0,6,64,0,0,8,215])
    let image = try stageExportFixture(header, path: "document.png", store: store)
    let first = try publish(store, .init(cut: cut, source: "", artifact: image, log: "", options: .init(format: .png, pageIndex: 0, pixelWidth: 1600)))
    let otherPage = try publish(store, .init(cut: cut, source: "", artifact: image, log: "", options: .init(format: .png, pageIndex: 1, pixelWidth: 1600)))
    #expect(first.artifact.sha256 == otherPage.artifact.sha256)
    #expect(first.packageSHA256 != otherPage.packageSHA256)
    #expect(first.source == nil && first.sourceMap == nil)
    #expect(throws: CollaborationError.self) { try store.prepareDocumentExport(.init(cut: cut, source: "", artifact: image, log: "", options: .init(format: .png, pixelWidth: 800))) }
    #expect(throws: CollaborationError.self) { try store.prepareDocumentExport(.init(cut: cut, source: "", artifact: image, log: "")) }
  }

}

import Foundation
import CryptoKit
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
  private func fixture(blocks: [DocumentBlock] = [.markdown(id: "body", source: "Printed")]) throws -> (NotebookStore, DocumentDocument) {
    let store = NotebookStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("notebook-print-package-\(UUID())"))
    _ = try store.loadOrCreate(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    let actor = UUID()
    var index = try store.loadIndex(), board = try store.loadBoard(items: index.items)
    let created = index.createDocument(title: "Print fixture", actor: actor)
    let item = try #require(created)
    let added = board.addItem(item.id, to: index.rootBoardID, near: .zero, actor: actor)
    #expect(added)
    let document = DocumentDocument(id: item.id, actor: actor, blocks: blocks)
    try store.saveDocumentWorkspaceBundle(index: index, document: document,
      state: .init(id: item.id, actor: actor), board: board)
    return (store, try store.loadDocument(document.id))
  }
  @Test func presentedCutRequiresExactNativeProvenanceAndPublishesOnlyThosePixels() throws {
    let (store, document) = try fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
    let target = CollaborationTarget(kind: .document, id: document.id)
    let files = try store.referenceSourceFiles(target: target)
    let region = PageRect(x: 1, y: 1, width: 1, height: 1)
    let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="))
    func captured(_ provenance: AgentPinnedImage.Presentation?) throws -> NotebookExportOptions {
      let reference = CollaborationReference(target: target, elementID: "body", region: region, pageIndex: 0,
        revision: try store.referenceRevision(target: target, elementID: "body"))
      let context = try store.appendContext(references: [reference], author: .human, actor: UUID(), select: true)
      let image = try AgentPinnedImage(referenceID: reference.id, sourceRevision: reference.revision,
        region: region, worldOrigin: nil, pageIndex: 0, pixelWidth: 1, pixelHeight: 1, pixelsPerPoint: 1,
        png: png, sha256: SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined(), presentation: provenance)
      let source = try AgentPinnedSource.capture(requestID: context.id, reference: reference, files: files).withVisual(image)
      try store.saveAttentionEvidence([source], contextID: context.id)
      return .init(format: .png, moment: .presented, attention: .init(contextID: context.id, referenceID: reference.id))
    }
    let cache = try captured(nil)
    #expect(throws: CollaborationError.self) { try store.readDocumentExportCut(documentID: document.id, options: cache) }
    let provenance = AgentPinnedImage.Presentation(device: .iOSSimulator), options = try captured(provenance)
    let cut = try store.readDocumentExportCut(documentID: document.id, options: options), job = UUID()
    #expect(cut.presented?.image?.presentation == provenance)
    #expect((try cut.sha256) != (try NotebookExportCut(document: document, state: cut.state).sha256))
    #expect(throws: CollaborationError.self) { try NotebookExportOptions(format: .png, pixelWidth: 1600, moment: .presented, attention: options.attention).validate(cut: cut) }
    #expect(throws: CollaborationError.self) { try NotebookExportOptions(format: .png).validate(cut: cut) }
    let file = try stageExportFixture(png, path: "document.png", store: store)
    let publication = NotebookExportPublication(cut: cut, source: "", artifact: file, log: "", options: options, jobID: job)
    let receipt = try publish(store, publication)
    #expect(try Data(contentsOf: URL(fileURLWithPath: receipt.artifact.path)) == png)
    #expect(try store.scriptExportJob(job)?["moment"] == .string("presented"))
    #expect(try JSONDecoder().decode(NotebookExportCut.self, from: Data(contentsOf: URL(fileURLWithPath: receipt.cut.path))) == cut)
    var otherBytes = png; otherBytes.append(0)
    #expect(throws: CollaborationError.self) { try store.prepareDocumentExport(.init(cut: cut, source: "", artifact: stageExportFixture(otherBytes, path: "document.png", store: store), log: "", options: options)) }
    let queued = try store.prepareDocumentExport(.init(cut: cut, source: "", artifact: file, log: "", options: options))
    var changed = document; let didChange = changed.replaceBlockSource(id: "body", source: "New source", actor: UUID()); #expect(didChange); try store.saveDocument(changed)
    #expect(throws: CollaborationError.self) { try store.readDocumentExportCut(documentID: document.id, options: options) }
    #expect(throws: CollaborationError.self) { try store.publishDocumentExport(queued) }
    #expect(try Data(contentsOf: URL(fileURLWithPath: receipt.artifact.path)) == png)
  }

  @Test func presentedModelRequiresTheExactExplicitCheckpointAndNeverLabelsOtherProgramsShown() throws {
    let (store, document) = try fixture(blocks: [.interactive(id: "model", html: "<p>Selected</p>", initialState: .object(["phase": .number(0.5)]))])
    defer { try? FileManager.default.removeItem(at: store.root) }
    let state = try store.loadDocumentState(document.id), value = document.blocks[0].initialState
    let target = CollaborationTarget(kind: .document, id: document.id)
    let reference = CollaborationReference(target: target, elementID: "model", region: .init(x: 1, y: 1, width: 1, height: 1), pageIndex: 0,
      revision: try store.referenceRevision(target: target, elementID: "model"))
    let context = try store.appendContext(references: [reference], author: .human, actor: UUID(), select: true)
    let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="))
    func cut(_ program: AgentPinnedImage.Presentation.Program?) throws -> NotebookExportCut {
      let image = try AgentPinnedImage(referenceID: reference.id, sourceRevision: reference.revision, region: reference.region!, worldOrigin: nil,
        pageIndex: 0, pixelWidth: 1, pixelHeight: 1, pixelsPerPoint: 1, png: png,
        sha256: SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined(), presentation: .init(device: .iOSSimulator, program: program))
      let source = try AgentPinnedSource.capture(requestID: context.id, reference: reference, files: store.referenceSourceFiles(target: target)).withVisual(image)
      return try .init(document: document, state: state, presented: source)
    }
    func options(_ format: NotebookExportOptions.Format, blockID: String? = nil) -> NotebookExportOptions {
      .init(format: format, pixelWidth: format == .mp4 ? 640 : nil, blockID: blockID,
        video: format == .mp4 ? .init(start: 0, end: 1, framesPerSecond: 4) : nil,
        moment: .presented, attention: .init(contextID: context.id, referenceID: reference.id))
    }
    let selected = try cut(.init(blockID: "model", sourceVersion: document.sourceVersion(blockID: "model"), state: value))
    for format in [NotebookExportOptions.Format.svg, .html, .mp4, .pdf, .package] {
      let option = options(format, blockID: [.svg, .html, .mp4].contains(format) ? "model" : nil)
      try option.validate(cut: selected)
      #expect(throws: CollaborationError.self) { try option.validate(cut: cut(nil)) }
      #expect(throws: CollaborationError.self) { try option.validate(cut: cut(.init(blockID: "model", sourceVersion: document.sourceVersion(blockID: "model"), state: .null))) }
      let other = DocumentDocument(actor: UUID(), blocks: document.blocks)
      #expect(throws: CollaborationError.self) { try option.validate(cut: cut(.init(blockID: "model", sourceVersion: other.sourceVersion(blockID: "model"), state: value))) }
    }
    #expect(throws: CollaborationError.self) { try options(.svg, blockID: "different").validate(cut: selected) }
    #expect(throws: CollaborationError.self) { try cut(.init(blockID: "different", sourceVersion: document.sourceVersion(blockID: "model"), state: value)) }
    // A static checkpoint is not an assertion that an unrelated program was shown.
    var mixed = document
    let appended = mixed.replaceContent(blocks: document.blocks + [.interactive(id: "running", html: "<p>Other model</p>")], actor: UUID())
    #expect(appended)
    let mixedCut = try NotebookExportCut(document: mixed, state: state, presented: selected.presented)
    try options(.html, blockID: "model").validate(cut: mixedCut)
    for format in [NotebookExportOptions.Format.pdf, .package, .mp4] {
      #expect(throws: CollaborationError.self) { try options(format, blockID: format == .mp4 ? "model" : nil).validate(cut: mixedCut) }
    }
    try store.saveAttentionEvidence([selected.presented!], contextID: context.id)
    #expect(try store.readDocumentExportCut(documentID: document.id, options: options(.pdf)).presented == selected.presented)
    var advanced = state; let changed = advanced.commit(blockID: "model", value: .object(["phase": .number(0.75)]), actor: UUID()); #expect(changed)
    try store.saveDocumentState(advanced)
    #expect(throws: CollaborationError.self) { try store.readDocumentExportCut(documentID: document.id, options: options(.pdf)) }
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

  @Test func portableDirectoryStreamsUniquePartsAndRejectsAnIncompleteClosure() throws {
    let (store, original) = try fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
    let main = try stageExportFixture(Data("throw Error('Not executed by export/import')".utf8), path: "main.js", store: store)
    var parts: [NotebookProgramPackage.Part] = []
    // Nine distinct physical 4 MiB payloads, not one repeated logical blob.
    for value in 1...9 {
      let bytes = Data(repeating: UInt8(value), count: NotebookProgramPackage.partBytes)
      parts += try stageExportFixture(bytes, path: "data.bin", store: store).file.parts
    }
    let package = NotebookProgramPackage(javaScript: "main.js", files: [
      .init(path: "data.bin", mimeType: "application/octet-stream", byteCount: Int64(9 * NotebookProgramPackage.partBytes), parts: parts), main.file])
    let hash = try store.stageProgramPackage(package)
    let document = DocumentDocument(id: original.id, actor: UUID(), blocks: [.interactive(id: "scene", html: "", programPackage: hash, height: 800)])
    try store.saveDocument(document)
    let cut = try NotebookExportCut(document: store.loadDocument(document.id), state: store.loadDocumentState(document.id))
    let portable = NotebookPortableDocument(cut: cut, packages: [.init(sha256: hash, value: package)])
    let assets = try portable.blobs(), data = try portable.data(), manifest = try stageExportFixture(data, path: "document.package", store: store)
    let options = NotebookExportOptions(format: .package)
    let receipt = try publish(store, .init(cut: cut, source: "", artifact: manifest, log: "", options: options, assets: assets))
    do {
      #expect(receipt.assets == nil)
      #expect(receipt.cutSHA256 == (try cut.sha256))
      #expect(assets.reduce(Int64(0), { $0 + $1.file.byteCount }) > 32*1024*1024)
      let path = URL(fileURLWithPath: receipt.artifact.path), directory = path.deletingLastPathComponent()
      #expect(try JSONDecoder().decode(NotebookPortableDocument.self, from: Data(contentsOf: path)).cut == cut)
      for asset in assets {
        #expect(try NotebookExportFile.inspect(directory.appendingPathComponent(asset.file.path), path: asset.file.path) == asset)
      }
      let sources = package.files.map { file in NotebookProgramImport.Source(path: file.path,
        partPaths: file.parts.map { directory.appendingPathComponent("blob-" + $0.sha256).path }) }
      try NotebookProgramImport(packageHash: hash, package: package, sources: sources).validate(expectedHash: hash)
      #expect(throws: NotebookStorageError.self) {
        try NotebookProgramImport(packageHash: hash, package: package, sources: [.init(path: "data.bin", partPaths: []), sources[1]]).validate(expectedHash: hash)
      }
      #expect(throws: CollaborationError.self) {
        try publish(store, .init(cut: cut, source: "", artifact: manifest, log: "", options: options, assets: Array(assets.dropLast())))
      }
      #expect(try Data(contentsOf: path) == data)
    }
    #expect(throws: CollaborationError.self) { try NotebookPortableDocument(cut: cut, packages: []).data() }
  }

  @Test func videoOptionsAndPublicationBindTheExplicitTimeline() throws {
    let (store, document) = try fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
    func options(_ end: Double = 1, width: Int = 640, fps: Int = 4) -> NotebookExportOptions {
      .init(format: .mp4, pixelWidth: width, blockID: "body", video: .init(start: 0, end: end, framesPerSecond: fps))
    }
    try options().validate()
    #expect(throws: CollaborationError.self) { try options(1.1).validate() }
    #expect(throws: CollaborationError.self) { try options(width: 641).validate() }
    #expect(throws: CollaborationError.self) { try options(fps: 61).validate() }
    #expect(throws: CollaborationError.self) { try options(1000).validate() }
    #expect(throws: CollaborationError.self) { try NotebookExportOptions(format: .mp4, blockID: "body").validate() }
    let cut = try NotebookExportCut(document: document, state: store.loadDocumentState(document.id))
    // Bounded container header check; Mac decodes complete native-encoded media.
    let bytes = Data([0,0,0,20]) + Data("ftypisom00000000".utf8)
    let file = try stageExportFixture(bytes, path: "document.mp4", store: store)
    let first = try publish(store, .init(cut: cut, source: "", artifact: file, log: "", options: options()))
    let other = try publish(store, .init(cut: cut, source: "", artifact: file, log: "", options: options(2)))
    #expect(first.packageSHA256 != other.packageSHA256)
    #expect(first.artifact.mimeType == "video/mp4")
    #expect(throws: CollaborationError.self) {
      try publish(store, .init(cut: cut, source: "", artifact: stageExportFixture(Data("bad mp4 header".utf8), path: "document.mp4", store: store), log: "", options: options()))
    }
    #expect(try Data(contentsOf: URL(fileURLWithPath: first.artifact.path)) == bytes)
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

  @Test func standaloneHTMLUsesTheSameCutAndPublicationFence() throws {
    let (store, document) = try fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
    let cut = try NotebookExportCut(document: document, state: store.loadDocumentState(document.id))
    let data = Data("<!doctype html><html><body>Offline</body></html>".utf8)
    let options = NotebookExportOptions(format: .html, blockID: "body")
    let receipt = try publish(store, .init(cut: cut, source: "", artifact: stageExportFixture(data, path: "document.html", store: store), log: "", options: options))
    #expect(receipt.artifact.mimeType == "text/html")
    #expect(try Data(contentsOf: URL(fileURLWithPath: receipt.artifact.path)) == data)
    #expect(receipt.cutSHA256 == (try cut.sha256))
    #expect(throws: CollaborationError.self) { try NotebookExportOptions(format: .html).validate() }
    #expect(throws: CollaborationError.self) {
      try publish(store, .init(cut: cut, source: "", artifact: stageExportFixture(Data("not html".utf8), path: "document.html", store: store), log: "", options: options))
    }
  }

  @Test func vectorExportRejectsActiveOrExternalResourcesButKeepsLocalDefinitions() throws {
    let prefix = "<svg xmlns='http://www.w3.org/2000/svg' width='200' height='100'>"
    try NotebookExportSVG.validate(Data((prefix+"<defs><linearGradient id='paint'><stop stop-color='blue'/></linearGradient></defs><path d='M0 0L100 50' fill='url(#paint)'/><text x='10' y='30' font-size='14' font-family='sans-serif'>Vector</text></svg>").utf8))
    for value in ["<style>text{fill:blue}</style>", "<rect style='background-image:image-set(\"https://example.com/x\" 1x)'/>", "<script>alert(1)</script>","<foreignObject/>","<animate attributeName='x'/>","<image href='https://example.com/a.png'/>","<path style='fill:url(https://example.com/paint)'/>","<path style='fill:url(https://example.com/paint'/>","<style>@import 'https://example.com/x';</style>","<path onload='fetch(1)'/>","<use href='#local' xml:base='https://example.com/'/>"] {
      #expect(throws: CollaborationError.self) { try NotebookExportSVG.validate(Data((prefix+value+"</svg>").utf8)) }
    }
    #expect(throws: CollaborationError.self) { try NotebookExportSVG.validate(Data("<!DOCTYPE svg [<!ENTITY x 'boom'>]><svg xmlns='http://www.w3.org/2000/svg'>&x;</svg>".utf8)) }
    #expect(throws: CollaborationError.self) { try NotebookExportOptions(format: .svg).validate() }
  }

}

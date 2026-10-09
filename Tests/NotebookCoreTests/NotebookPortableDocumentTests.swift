import Foundation
import CryptoKit
import Darwin
import Testing
@testable import NotebookCore

@Suite(.serialized)
struct NotebookPortableDocumentTests {
  private enum Disk: Error { case unavailable }
  private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
  private func prepare(_ data: Data, targetBoardID: UUID, actor: UUID, requestID: UUID = UUID()) throws
    -> NotebookPortableDocumentImport.Prepared {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("portable-fixture-" + UUID().uuidString + ".notex")
    try data.write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let inspection = try NotebookPortableDocumentImport.inspect(file: file, expectedHash: hash(data))
    let raw = try inspection.readMetadata(), metadata = try raw.decode()
    let sources = try metadata.readSources()
    return try sources.prepare(requestID: requestID, targetBoardID: targetBoardID, center: .zero, actor: actor)
  }
  private func fixture() throws -> (NotebookStore, NotebookExportCut) {
    let actor = UUID(), store = NotebookStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("notebook-portable-\(UUID())"))
    _ = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    let binary = Data([0, 1, 2, 127, 255])
    try store.stageBlob(data: binary, expectedHash: hash(binary))
    let file = NotebookProgramPackage.File(path: "assets/data.bin", mimeType: "application/octet-stream", byteCount: Int64(binary.count),
      parts: [.init(sha256: hash(binary), byteCount: binary.count)])
    var document = DocumentDocument(actor: actor, files: [
      .init(id: "main", path: "main.tex", source: "\\documentclass{article}\n\\usepackage{notebook}\n\\begin{document}\n\\input{chapters/one}\n\\NotebookInteractive[id=osc,width=100pt,height=100pt]{programs/osc}\n\\end{document}\n"),
      .init(id: "chapter", path: "chapters/one.tex", source: "UTF-8: Привет 😀\n"),
      .init(id: "program", path: "programs/osc/index.html", source: "<button>Do not execute on import</button>"),
      .init(id: "binary", path: "assets/data.bin", resource: file)])
    _ = document.replaceFileSource(id: "chapter", source: "A changed chapter. Привет 😀\n", actor: actor)
    var state = DocumentStateJournal(id: document.id, actor: actor)
    _ = state.commit(instanceID: "osc", value: .object(["phase": .number(0.75)]), actor: actor)
    return (store, try .init(document: document, state: state))
  }
  @Test func zipContainsRealSourcesAndRoundTripsTheExactCut() throws {
    let (store, cut) = try fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
    let data = try store.exportPortableDocument(cut: cut)
    #expect(data.starts(with: Data([0x50, 0x4b, 3, 4])))
    let entries = try NotebookDocumentZIP.decode(data)
    #expect(entries["files/chapters/one.tex"] == Data("A changed chapter. Привет 😀\n".utf8))
    #expect(entries["manifest.json"] != nil && entries["state.json"] != nil)
    #expect(!String(decoding: entries["manifest.json"]!, as: UTF8.self).contains("A changed chapter"))
    let portable = try NotebookPortableDocument(data: data)
    #expect(portable.cut == cut); #expect(portable.derived == nil)
    #expect(portable.files["assets/data.bin"] == Data([0, 1, 2, 127, 255]))
  }
  @Test func fullSixteenMiBSourceBudgetRoundTripsAndPreparesOnePortableExport() throws {
    let (store, small) = try fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
    let headers = ["\\documentclass{article}\n\\begin{document}\nFull capacity.\\input{sections/one}\\input{sections/two}\\input{sections/three}\\end{document}\n%", "% One\n%", "% Two\n%", "% Three\n%"]
    let paths = ["main.tex", "sections/one.tex", "sections/two.tex", "sections/three.tex"]
    let files = zip(paths, headers).enumerated().map { index, entry in
      DocumentFile(id: "file-\(index)", path: entry.0,
        source: entry.1 + String(repeating: "x", count: DocumentFile.maximumSourceLength-entry.1.utf8.count))
    }
    let document = DocumentDocument(actor: UUID(), files: files)
    #expect(document.files.reduce(0, { $0+Int($1.byteCount) }) == DocumentDocument.maximumSourceBytes)
    let cut = try NotebookExportCut(document: document, state: .init(id: document.id, actor: small.state.stamp.actor))
    let bytes = try store.exportPortableDocument(cut: cut)
    #expect(bytes.count < NotebookDocumentZIP.maximumBytes)
    #expect(try NotebookPortableDocument(data: bytes).cut == cut)
    let artifact = try stageExportFixture(bytes, path: "document.notex", store: store)
    let prepared = try store.prepareDocumentExport(.init(cut: cut, source: "", artifact: artifact, log: "", options: .init(format: .package)))
    #expect(prepared.receipt.cut.byteCount > DocumentDocument.maximumSourceBytes)
    #expect(prepared.receipt.artifact.byteCount == bytes.count)
  }
  @Test func oversizedCausalFrontierAndStateHaveExplicitIndependentBudgets() throws {
    let (store, cut) = try fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
    let original = DocumentDocument(actor: UUID(), files: [.init(id: "main", path: "main.tex", source: "Initial")])
    var left = original, right = original
    let changedLeft = left.replaceFileSource(id: "main", source: String(repeating: "a", count: DocumentFile.maximumSourceLength), actor: UUID()); #expect(changedLeft)
    let changedRight = right.replaceFileSource(id: "main", source: String(repeating: "b", count: DocumentFile.maximumSourceLength), actor: UUID()); #expect(changedRight)
    let merged = try left.merge(right); #expect(merged)
    let concurrent = try NotebookExportCut(document: left, state: .init(id: left.id, actor: UUID()))
    var state = cut.state
    let committed = state.commit(instanceID: "large", value: .string(String(repeating: "s", count: NotebookPortableDocument.maximumStateBytes)), actor: UUID()); #expect(committed)
    for oversized in [concurrent, try .init(document: cut.document, state: state)] {
      do { _ = try store.exportPortableDocument(cut: oversized); Issue.record("Oversized metadata or state was admitted") }
      catch let error as CollaborationError { #expect(error.code == "resource_limit") }
    }
    // The primary source budget is unchanged by rejected export preparation.
    #expect(left.isValid && left.files[0].byteCount == DocumentFile.maximumSourceLength)
  }
  @Test func oversizedOptionalPDFIsDiscardedWithoutLosingSources() throws {
    let (store, cut) = try fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
    var pdf = Data("%PDF-1.4\n".utf8); pdf.append(Data(count: 16*1024*1024))
    let revision = String(repeating: "a", count: 64), source = try #require(cut.document.files.first { $0.path == cut.document.entrypoint }).source
    let map = try DocumentPrintSourceMap(document: cut.document, source: source, pdf: pdf, compilerRevision: revision)
    let bytes = try store.exportPortableDocument(cut: cut,
      derived: .init(pdf: pdf, syncTeX: Data([0x1f, 0x8b]), interactiveMap: Data(), sourceMap: map))
    let portable = try NotebookPortableDocument(data: bytes, compilerRevision: revision)
    #expect(portable.cut == cut && portable.derived == nil)
    #expect(try !NotebookDocumentZIP.decode(bytes).keys.contains { $0.hasPrefix("derived/") })
  }
  @Test func importCreatesOneNewCopyWithStateAndUndo() throws {
    let (store, cut) = try fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
    let data = try store.exportPortableDocument(cut: cut), actor = UUID(), index = try store.loadIndex()
    let requestID = UUID()
    let plan = try prepare(data, targetBoardID: index.rootBoardID, actor: actor, requestID: requestID)
    let command = plan.command()
    let imported = try command.apply(to: store)
    let retried = try command.apply(to: store)
    #expect(retried.documentID == imported.documentID && retried.receipt == imported.receipt)
    #expect(imported.documentID != cut.document.id)
    #expect(imported.receipt.action.operations.count == 1)
    #expect(imported.receipt.action.operations[0].kind == .createDocument)
    let document = try store.loadDocument(imported.documentID), state = try store.loadDocumentState(imported.documentID)
    #expect(document.files == cut.document.files); #expect(document.entrypoint == cut.document.entrypoint)
    #expect(state.value(for: "osc") == cut.state.value(for: "osc"))
    let binary = try #require(document.files.first { $0.id == "binary" })
    #expect(try store.readDocumentFileBytes(binary) == Data([0, 1, 2, 127, 255]))
    _ = try store.undoNativeAction(imported.receipt.action.id, actor: actor)
    #expect(!(try store.loadIndex()).items.contains { $0.id == imported.documentID })
  }
  @Test func sourceHashAndCRCFailuresNeverCreateAnItem() throws {
    let (store, cut) = try fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
    let index = try store.loadIndex(), actor = UUID(), original = try store.exportPortableDocument(cut: cut)
    var archive = try NotebookDocumentZIP.decode(original)
    archive["files/chapters/one.tex"] = Data("Tampered".utf8)
    let changed = try NotebookDocumentZIP.encode(archive)
    #expect(throws: CollaborationError.self) { try prepare(changed, targetBoardID: index.rootBoardID, actor: actor).command().apply(to: store) }
    var damaged = original
    let marker = try #require(damaged.range(of: Data("A changed chapter".utf8))).lowerBound
    damaged[marker] ^= 1
    #expect(throws: CollaborationError.self) { try NotebookPortableDocument(data: damaged) }
    #expect(throws: CollaborationError.self) { try prepare(damaged, targetBoardID: index.rootBoardID, actor: actor) }
    let file = store.root.appendingPathComponent("changed-input.notex")
    try original.write(to: file)
    #expect(throws: CollaborationError.self) { try NotebookPortableDocumentImport.inspect(file: file, expectedHash: String(repeating: "0", count: 64)) }
    #expect(try store.loadIndex() == index)
  }
  @Test func unknownImportCommitReturnsItsOriginalCopyAfterAPeerSourceEdit() throws {
    let (store, cut) = try fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
    let actor = UUID(), actionID = UUID(), boardID = try store.loadIndex().rootBoardID
    let plan = try prepare(store.exportPortableDocument(cut: cut), targetBoardID: boardID, actor: actor, requestID: actionID)
    let command = plan.command()
    let failing = NotebookStore(root: store.root) { phase in if phase == .afterCommit { throw Disk.unavailable } }
    #expect(throws: Disk.self) { try command.apply(to: failing) }
    let original = try store.loadDocument(plan.documentID), receipt = try store.collaborationAction(actionID)
    var peer = original
    let changed = peer.replaceFileSource(id: "chapter", source: "Peer owns the later chapter.", actor: UUID())
    #expect(changed); try store.saveDocument(peer)
    let cursor = try store.currentChangeCursor(), readCursor = try store.currentReadCursor()
    let retry = try command.apply(to: NotebookStore(root: store.root))
    #expect(retry.document == original && retry.document != peer && retry.receipt == receipt)
    #expect(try store.loadDocument(plan.documentID) == peer)
    let afterCursor = try store.currentChangeCursor(), afterReadCursor = try store.currentReadCursor()
    #expect(afterCursor == cursor && afterReadCursor == readCursor)
    #expect(try store.nativeHistory(domain: .board(boardID), actor: actor) == [.command(actionID)])
  }
  @Test func sourceEscapingIsAdmittedBeforeBuildingTheAuthoredOperation() throws {
    let (store, small) = try fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
    let index = try store.loadIndex(), cursor = try store.currentChangeCursor()
    // The authored model still accepts these complete files. Import's finite
    // finish distinguishes their actual JSON expansion without truncating any.
    for source in [String(repeating: "x", count: 3*1_048_576),
      String(repeating: "\\\"", count: 1_048_576), String(repeating: "\0", count: 1_048_576)] {
      let document = DocumentDocument(actor: UUID(), files: [.init(id: "main", path: "main.tex", source: source)])
      let cut = try NotebookExportCut(document: document, state: .init(id: document.id, actor: small.state.stamp.actor))
      let bytes = try store.exportPortableDocument(cut: cut)
      do { _ = try prepare(bytes, targetBoardID: index.rootBoardID, actor: UUID()); Issue.record("An oversized real finish was admitted") }
      catch let error as CollaborationError { #expect(error.code == "resource_limit") }
      #expect(try NotebookPortableDocument(data: bytes).cut == cut)
    }
    let afterIndex = try store.loadIndex(), afterCursor = try store.currentChangeCursor()
    #expect(afterIndex == index && afterCursor == cursor)
  }
  @Test func acceptedEscapedAndUnicodeSourcesKeepEveryAuthoredByte() throws {
    let (store, small) = try fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
    let boardID = try store.loadIndex().rootBoardID
    for source in [String(repeating: "\\\"", count: 262_144), String(repeating: "\0", count: 131_072),
      String(repeating: "😀/e\u{301}\u{2028}\t", count: 2_000)] {
      let document = DocumentDocument(actor: UUID(), files: [.init(id: "main", path: "main.tex", source: source)])
      let cut = try NotebookExportCut(document: document, state: .init(id: document.id, actor: small.state.stamp.actor))
      let plan = try prepare(store.exportPortableDocument(cut: cut), targetBoardID: boardID, actor: UUID())
      let encoded = try JSONEncoder().encode(JSONValue.object(plan.operation.values))
      _ = try NotebookJSONAdmission.allocationCost(encoded, maximumBytes: plan.cost.completionBytes)
      let imported = try plan.command().apply(to: store)
      #expect(imported.document.files.first?.source == source)
      #expect(try store.loadDocument(imported.documentID).files.first?.source == source)
    }
  }
  @Test func exactPresentedPixelsAndSemanticStateRemainChargedDuringPreparation() throws {
    let (store, cut) = try fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
    let region = PageRect(x: 0, y: 0, width: 1, height: 1)
    let reference = CollaborationReference(target: .init(kind: .document, id: cut.document.id), elementID: "osc",
      region: region, revision: cut.document.contentStamp.revision)
    let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="))
    let program = AgentPinnedImage.Presentation.Program(instanceID: "osc", programPath: "programs/osc/index.html",
      sourceBasis: String(repeating: "a", count: 64), state: .string(String(repeating: "p", count: 65_536)))
    let image = try AgentPinnedImage(referenceID: reference.id, sourceRevision: reference.revision, region: region,
      worldOrigin: nil, pageIndex: nil, pixelWidth: 1, pixelHeight: 1, pixelsPerPoint: 1, png: png, sha256: hash(png),
      presentation: .init(device: .iPad, program: program))
    let presented = AgentPinnedSource(id: reference.id, requestID: UUID(), reference: reference,
      payload: .object(["semantic": .string(String(repeating: "s", count: 65_536))]), image: image)
    let visualCut = try NotebookExportCut(document: cut.document, state: cut.state, presented: presented)
    func sources(_ value: NotebookExportCut) throws -> NotebookPortableDocumentImport.Sources {
      let file = store.root.appendingPathComponent(UUID().uuidString + ".notex")
      try store.exportPortableDocument(cut: value).write(to: file)
      let inspection = try NotebookPortableDocumentImport.inspect(file: file)
      return try inspection.readMetadata().decode().readSources()
    }
    let plain = try sources(cut), visual = try sources(visualCut)
    #expect(visual.cut == visualCut)
    #expect(visual.preparationCost.payloadBytes - plain.preparationCost.payloadBytes >= presented.retainedPayloadBytes)
    #expect(presented.retainedPayloadBytes >= image.retainedPayloadBytes + presented.payload.retainedPayloadBytes)
  }
  @Test func binarySourceReadReservesTheActualFourMiBPartBeforeAccumulatingIt() throws {
    let (store, small) = try fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
    let body = Data(repeating: 0x7f, count: 8*1_048_576)
    let pieces = stride(from: 0, to: body.count, by: NotebookProgramPackage.partBytes).map {
      body.subdata(in: $0..<min($0+NotebookProgramPackage.partBytes, body.count))
    }
    for piece in pieces { try store.stageBlob(data: piece, expectedHash: hash(piece)) }
    let resource = NotebookProgramPackage.File(path: "assets/eight.bin", mimeType: "application/octet-stream", byteCount: Int64(body.count),
      parts: pieces.map { .init(sha256: hash($0), byteCount: $0.count) })
    let document = DocumentDocument(actor: UUID(), files: [.init(id: "main", path: "main.tex", source: "Small main."),
      .init(id: "binary", path: resource.path, resource: resource)])
    let cut = try NotebookExportCut(document: document, state: .init(id: document.id, actor: small.state.stamp.actor))
    let bytes = try store.exportPortableDocument(cut: cut), file = store.root.appendingPathComponent("binary.notex")
    try bytes.write(to: file)
    let inspection = try NotebookPortableDocumentImport.inspect(file: file)
    let metadata = try inspection.readMetadata().decode(), readCost = try metadata.sourceReadCost
    #expect(readCost.completionBytes >= 2*NotebookProgramPackage.partBytes + 2*1_048_576)
    let sources = try metadata.readSources(), plan = try sources.prepare(requestID: UUID(), targetBoardID: store.loadIndex().rootBoardID,
      center: .zero, actor: UUID())
    let output = try plan.command().apply(to: store)
    let imported = try #require(output.document.files.first { $0.id == "binary" })
    #expect(try store.readDocumentFileBytes(imported) == body)
  }
  @Test func streamingPreparationMeasuresTinyAndOneMiBRealCreatePhases() async throws {
    for size in [256, 1_048_576] {
      let (store, small) = try fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
      let source = String(repeating: "x", count: size)
      let document = DocumentDocument(actor: UUID(), files: [.init(id: "main", path: "main.tex", source: source)])
      let cut = try NotebookExportCut(document: document, state: .init(id: document.id, actor: small.state.stamp.actor))
      let archive = try store.exportPortableDocument(cut: cut), boardID = try store.loadIndex().rootBoardID
      let memory = PortableImportMemorySample(), sampler = Task.detached {
        while !Task.isCancelled {
          memory.record()
          do { try await Task.sleep(for: .milliseconds(2)) } catch { return }
        }
      }
      let execution = await Task.detached { [self] in
        let plan = try prepare(archive, targetBoardID: boardID, actor: UUID())
        memory.record()
        let output = try plan.command().apply(to: store)
        memory.record()
        return (plan.cost, output.document.files.first?.source)
      }.result
      sampler.cancel(); await sampler.value
      let outcome = try execution.get()
      let report = memory.report()
      #expect(outcome.1 == source && outcome.0.bytes <= NotebookPortableDocumentImport.maximumPreparationBytes)
      print("PORTABLE_IMPORT source_bytes=\(size) payload_credit=\(outcome.0.payloadBytes) finish_credit=\(outcome.0.completionBytes) process_baseline=\(report.baseline) process_sampled_peak=\(report.peak) samples=\(report.count) scope=process-inclusive-preparation-and-create")
    }
  }
  @Test func matchingDerivedSnapshotCanBeReboundButStaleCompilerIsDiscarded() throws {
    let (store, cut) = try fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
    let revision = String(repeating: "a", count: 64), source = try #require(cut.document.files.first { $0.path == "main.tex" }).source
    let pdf = Data("%PDF-1.4\nfixture".utf8), sync = Data([0x1f, 0x8b])
    let map = try DocumentPrintSourceMap(document: cut.document, source: source, pdf: pdf, compilerRevision: revision)
    let derived = NotebookPortableDocument.Derived(pdf: pdf, syncTeX: sync, interactiveMap: Data(), sourceMap: map)
    let data = try store.exportPortableDocument(cut: cut, derived: derived)
    #expect(try NotebookPortableDocument(data: data, compilerRevision: String(repeating: "b", count: 64)).derived == nil)
    #expect(try NotebookPortableDocument(data: data, compilerRevision: revision).derived?.pdf == pdf)
    let plan = try prepare(data, targetBoardID: store.loadIndex().rootBoardID, actor: UUID())
    let imported = try plan.command().apply(to: store)
    let cacheRead = try plan.cache?.readDerivedBytes(document: imported.document)
    let bytes = try #require(cacheRead)
    #expect(bytes.decodingCost.completionBytes > 8 * 1_048_576)
    let candidate = try bytes.decode(compilerRevision: revision)
    let retained = try #require(candidate)
    let document = try store.loadDocument(imported.documentID)
    #expect(retained.sourceMap.documentID == imported.documentID)
    #expect(retained.sourceMap.inputSHA256 == map.inputSHA256)
    try retained.validate(document: document, compilerRevision: revision)
  }
  @Test func zipDeniesTraversalDuplicateNamesAndSymlinks() throws {
    #expect(throws: CollaborationError.self) { try NotebookDocumentZIP.encode(["../secret": Data()]) }
    let original = try NotebookDocumentZIP.encode(["aaaa/bbbb": Data([1])])
    var traversal = original
    let name = Data("aaaa/bbbb".utf8), unsafe = Data("../x/bbbb".utf8)
    while let range = traversal.range(of: name) { traversal.replaceSubrange(range, with: unsafe) }
    #expect(throws: CollaborationError.self) { try NotebookDocumentZIP.decode(traversal) }
    var symlink = original
    let central = try #require(symlink.range(of: Data([0x50, 0x4b, 1, 2]))).lowerBound
    symlink[central+40] = 0xff; symlink[central+41] = 0xa1
    #expect(throws: CollaborationError.self) { try NotebookDocumentZIP.decode(symlink) }
    let two = try NotebookDocumentZIP.encode(["first": Data([1]), "other": Data([2])])
    // Keep the binary transport intact while changing both occurrences of one name.
    var collision = two
    while let range = collision.range(of: Data("other".utf8)) { collision.replaceSubrange(range, with: Data("first".utf8)) }
    #expect(throws: CollaborationError.self) { try NotebookDocumentZIP.decode(collision) }
  }
  @Test func zipReadsDeflateWithoutAnExternalExtractor() throws {
    // Python zipfile's deflated UTF-8 file fixture, not a runtime process.
    let data = try #require(Data(base64Encoded: "UEsDBBQAAAAIAAAAIQCe2EKwCQAAAAcAAAAIAAAAbWFpbi50ZXjzSM3JyVfkAgBQSwECFAMUAAAACAAAACEAnthCsAkAAAAHAAAACAAAAAAAAAAAAAAAgAEAAAAAbWFpbi50ZXhQSwUGAAAAAAEAAQA2AAAALwAAAAAA"))
    #expect(try NotebookDocumentZIP.decode(data)["main.tex"] == Data("Hello!\n".utf8))
  }
}

private final class PortableImportMemorySample: @unchecked Sendable {
  private let lock = NSLock()
  private let baseline: UInt64
  private var peak: UInt64
  private var count = 0
  init() { baseline = Self.bytes(); peak = baseline }
  func record() { let value = Self.bytes(); lock.lock(); peak = max(peak, value); count += 1; lock.unlock() }
  func report() -> (baseline: UInt64, peak: UInt64, count: Int) {
    lock.lock(); defer { lock.unlock() }; return (baseline, peak, count)
  }
  private static func bytes() -> UInt64 {
    var value = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &value) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return status == KERN_SUCCESS ? value.phys_footprint : 0
  }
}

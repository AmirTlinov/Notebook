import Foundation
import CryptoKit
import Testing
@testable import NotebookCore

struct NotebookPortableDocumentTests {
  private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
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
    let merged = left.merge(right); #expect(merged)
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
    let imported = try store.importPortableDocument(data: data, targetBoardID: index.rootBoardID, center: .zero, actor: actor, requestID: requestID)
    let retried = try store.importPortableDocument(data: data, targetBoardID: index.rootBoardID, center: .zero, actor: actor, requestID: requestID)
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
    #expect(throws: CollaborationError.self) { try store.importPortableDocument(data: changed, targetBoardID: index.rootBoardID, center: .zero, actor: actor) }
    var damaged = original
    let marker = try #require(damaged.range(of: Data("A changed chapter".utf8))).lowerBound
    damaged[marker] ^= 1
    #expect(throws: CollaborationError.self) { try NotebookPortableDocument(data: damaged) }
    #expect(try store.loadIndex() == index)
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
    let imported = try store.importPortableDocument(data: data, targetBoardID: store.loadIndex().rootBoardID, center: .zero, actor: UUID(), compilerRevision: revision)
    let retained = try #require(imported.derived), document = try store.loadDocument(imported.documentID)
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

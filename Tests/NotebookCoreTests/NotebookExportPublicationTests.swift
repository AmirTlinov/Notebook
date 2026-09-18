import Foundation
import Testing
@testable import NotebookCore

struct NotebookExportPublicationTests {
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
      try store.publishDocumentExport(.init(documentID: document.id, expectedRevision: document.contentStamp.revision,
        source: source, pdf: pdf, log: "", assets: [.init(name: "notebook-image-0.pdf", data: asset)]))
    }
    let first = try publish("first"), repeatFirst = try publish("first"), second = try publish("second")
    let third = try publish("first", Data("%PDF-another-image".utf8))
    #expect(first.packageSHA256 == repeatFirst.packageSHA256)
    #expect(first.pdfSHA256 == second.pdfSHA256)
    #expect(first.packageSHA256 != second.packageSHA256 && first.packageSHA256 != third.packageSHA256)
    #expect(try String(contentsOfFile: first.texPath, encoding: .utf8) == "first")
    #expect(try Data(contentsOf: URL(fileURLWithPath: #require(first.assets?.first?.path))) == image)
    #expect(try FileManager.default.contentsOfDirectory(atPath: store.root.appendingPathComponent("exports").path).allSatisfy { !$0.hasPrefix(".pending-") })
  }
  @Test func stalePublicationNeverInstallsAPartialPackage() throws {
    let (store, document) = try fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
    do {
      _ = try store.publishDocumentExport(.init(documentID: document.id, expectedRevision: "wrong-revision",
        source: "source", pdf: Data("%PDF-result".utf8), log: ""))
      Issue.record("An export of stale content cannot publish")
    } catch let error as CollaborationError { #expect(error.code == "revision_conflict") }
    #expect(try FileManager.default.contentsOfDirectory(atPath: store.root.appendingPathComponent("exports").path).isEmpty)
  }
  @Test func assetNamesCannotEscapeThePreparedPackage() throws {
    let (store, document) = try fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
    #expect(throws: CollaborationError.self) {
      try store.publishDocumentExport(.init(documentID: document.id, expectedRevision: document.contentStamp.revision,
        source: "source", pdf: Data("%PDF-result".utf8), log: "", assets: [.init(name: "../outside.pdf", data: Data("%PDF-asset".utf8))]))
    }
    #expect(!FileManager.default.fileExists(atPath: store.root.appendingPathComponent("outside.pdf").path))
  }
  @Test func nativeCommandLetsExportOwnItsPreparationAndCommitBoundary() throws {
    let (store, document) = try fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
    var command = NotebookCommand(command: .publishExport)
    command.export = .init(documentID: document.id, expectedRevision: document.contentStamp.revision,
      source: "native command", pdf: Data("%PDF-native-export".utf8), log: "")
    let reply = try NotebookCommandDispatcher(store: store).handle(command)
    let receipt = try reply.decode(NotebookExportReceipt.self)
    #expect(try String(contentsOfFile: receipt.texPath, encoding: .utf8) == "native command")
    #expect(store.currentSQL == nil)
    #expect(throws: NotebookStorageError.self) {
      try store.commandTransaction { try store.publishDocumentExport(command.export!) }
    }
  }
  @Test func historicalReceiptDoesNotNeedNewPackageMetadata() throws {
    let bytes = Data(#"{"documentID":"7E7A0000-0000-4000-8000-000000000040","texPath":"old.tex","pdfPath":"old.pdf","pdfSHA256":"old-hash","byteCount":8,"log":"old"}"#.utf8)
    let receipt = try JSONDecoder().decode(NotebookExportReceipt.self, from: bytes)
    #expect(receipt.texPath == "old.tex" && receipt.assets == nil && receipt.packageSHA256 == nil)
  }
  @Test func sourceMapAndSyncTeXAreBoundToTheExactAtomicPrintPackage() throws {
    let (store, document) = try fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
    let source = "header\nPrinted\nend\n", pdf = Data("%PDF-controlled".utf8)
    let syncTeX = Data([0x1f, 0x8b, 0x08, 0x00])
    let map = try DocumentPrintSourceMap(document: document, source: source, pdf: pdf,
      ranges: [.init(blockID: "body", firstLine: 2, lastLine: 2)])
    let receipt = try store.publishDocumentExport(.init(documentID: document.id,
      expectedRevision: document.contentStamp.revision, source: source, pdf: pdf, log: "",
      sourceMap: map, syncTeX: syncTeX))
    let bytes = try Data(contentsOf: URL(fileURLWithPath: #require(receipt.sourceMap?.path)))
    #expect(try JSONDecoder().decode(DocumentPrintSourceMap.self, from: bytes) == map)
    #expect(try Data(contentsOf: URL(fileURLWithPath: #require(receipt.syncTeX?.path))) == syncTeX)
    #expect(throws: CollaborationError.self) {
      try store.publishDocumentExport(.init(documentID: document.id, expectedRevision: document.contentStamp.revision,
        source: source, pdf: Data("%PDF-other".utf8), log: "", sourceMap: map, syncTeX: syncTeX))
    }
    #expect(throws: CollaborationError.self) {
      try store.publishDocumentExport(.init(documentID: document.id, expectedRevision: document.contentStamp.revision,
        source: source, pdf: pdf, log: "", sourceMap: map))
    }
  }
}

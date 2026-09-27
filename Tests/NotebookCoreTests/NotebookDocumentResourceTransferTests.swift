import Foundation
import Testing
@testable import NotebookCore

@Suite("Document resources use the existing immutable blob and file CAS owners", .serialized)
struct NotebookDocumentResourceTransferTests {
  @Test func binaryReplacementUndoAndRedoFollowTheSameContentOwner() throws {
    let f = try DocumentFileFixture(), path = "figures/chart.png"
    func resource(_ byte: UInt8) throws -> NotebookProgramPackage.File {
      let bytes = Data([byte]), hash = NotebookProgramPackage.hash(bytes)
      try f.store.stageBlob(data: bytes, expectedHash: hash)
      return .init(path: path, mimeType: "image/png", byteCount: 1, parts: [.init(sha256: hash, byteCount: 1)])
    }
    let first = try resource(1), second = try resource(2)
    _ = try f.apply([.init(kind: .putDocumentFile, target: f.target, id: "chart", values: [
      "path": .string(path), "resource": try .encode(first), "expectedVersion": .null])])
    let file = try f.file("chart")
    let action = CollaborationAction(summary: "Replace binary resource", expected: try f.store.readBasis(targets: [f.target]).owners,
      operations: [.init(kind: .putDocumentFile, target: f.target, id: "chart", values: [
        "path": .string(path), "resource": try .encode(second), "expectedVersion": try .encode(file.sourceVersion)])])
    let receipt = try f.store.applyCollaborationActionImmediately(action, actor: f.actor, requestFingerprint: nil, human: true)
    #expect(receipt.changes.allSatisfy { $0.afterVersion != nil })
    _ = try f.store.undoNativeAction(receipt.id, actor: f.actor)
    #expect(try f.file("chart").file.resource == first)
    let repeated = try NotebookStore(root: f.root).redoNativeAction(receipt.id, actionID: UUID(), actor: f.actor)
    #expect(try f.file("chart").file.resource == second)
    _ = try f.store.undoNativeAction(repeated.id, actor: f.actor)
    #expect(try f.file("chart").file.resource == first)
  }

  @Test func stagingIsNotPublicationAndFileCASReadsAcrossPartsAfterReopen() throws {
    let f = try DocumentFileFixture(files: [.init(id: "main", path: "main.tex", source: "\\documentclass{article}\\begin{document}Resource\\end{document}")])
    var bytes = Data(repeating: 41, count: NotebookProgramPackage.partBytes + 37)
    bytes[NotebookProgramPackage.partBytes - 1] = 42; bytes[NotebookProgramPackage.partBytes] = 43
    let url = f.root.appendingPathComponent("chart.pdf"); try bytes.write(to: url)
    let request = NotebookDocumentResourceImportRequest(filePath: url.path, path: "figures/chart.pdf", sha256: NotebookProgramPackage.hash(bytes))
    let prepared = try NotebookDocumentResourceImport.prepare(request)
    #expect(prepared.resource.parts.count == 2)
    #expect(prepared.resource.mimeType == "application/pdf")
    let cursor = try f.store.currentChangeCursor()
    for _ in 0..<2 {
      var offset: Int64 = 0
      for part in prepared.resource.parts {
        let end = offset + Int64(part.byteCount)
        try f.store.stageBlob(file: prepared.fileURL, expectedHash: part.sha256, byteCount: Int64(part.byteCount), range: offset..<end)
        offset = end
      }
    }
    #expect(try f.store.currentChangeCursor() == cursor, "SHA staging is not a content mutation")
    #expect(try f.store.readDocumentFile(documentID: f.id, fileID: "chart") == nil)
    let mainBefore = try f.file("main")
    _ = try f.apply([.init(kind: .putDocumentFile, target: f.target, id: "chart", values: [
      "path": .string(prepared.resource.path), "resource": try .encode(prepared.resource), "expectedVersion": .null])])
    let mainAfter = try f.file("main")
    #expect(mainAfter.file == mainBefore.file && mainAfter.sourceVersion == mainBefore.sourceVersion, "Adding a resource cannot rewrite its neighbour")
    let addressed = try f.file("chart"), offset = NotebookProgramPackage.partBytes - 2
    #expect(addressed.file.source.isEmpty)
    let result = try NotebookStore(root: f.root).readDocumentFileBytes(documentID: f.id, fileID: "chart",
      sourceVersion: addressed.sourceVersion, offset: Int64(offset), maxBytes: 7)
    #expect(Data(base64Encoded: result.base64) == bytes.subdata(in: offset..<(offset+7)))
    #expect(result.sourceVersion == addressed.sourceVersion && result.totalBytes == Int64(bytes.count))
    #expect(!result.eof && result.byteCount == 7)
    let eof = try f.store.readDocumentFileBytes(documentID: f.id, fileID: "chart", sourceVersion: addressed.sourceVersion,
      offset: Int64(bytes.count), maxBytes: 1)
    #expect(eof.eof && eof.base64.isEmpty && eof.byteCount == 0)
    _ = try f.apply([.init(kind: .renameDocumentFile, target: f.target, id: "chart", values: [
      "path": .string("figures/renamed.pdf"), "expectedVersion": try .encode(addressed.sourceVersion)])])
    #expect(throws: CollaborationError.self) {
      try f.store.readDocumentFileBytes(documentID: f.id, fileID: "chart", sourceVersion: addressed.sourceVersion, offset: 0, maxBytes: 7)
    }
  }

  @Test func explicitByteWindowsAlsoReadTextAndRejectUnboundedOrStaleRanges() throws {
    let text = "A🧪Б", f = try DocumentFileFixture(files: [.init(id: "main", path: "main.tex", source: text)])
    let addressed = try f.file("main")
    let value = try f.store.readDocumentFileBytes(documentID: f.id, fileID: "main", sourceVersion: addressed.sourceVersion,
      offset: 1, maxBytes: 4)
    #expect(Data(base64Encoded: value.base64) == Data("🧪".utf8))
    for (offset, maxBytes) in [(Int64(-1), 1), (Int64(0), 0), (Int64(0), 1_048_577), (Int64(text.utf8.count+1), 1)] {
      #expect(throws: CollaborationError.self) {
        try f.store.readDocumentFileBytes(documentID: f.id, fileID: "main", sourceVersion: addressed.sourceVersion, offset: offset, maxBytes: maxBytes)
      }
    }
    _ = try f.apply([f.patch(addressed, to: "Changed")])
    #expect(throws: CollaborationError.self) {
      try f.store.readDocumentFileBytes(documentID: f.id, fileID: "main", sourceVersion: addressed.sourceVersion, offset: 0, maxBytes: 7)
    }
  }

  @Test func preparationRejectsLocalIndirectionBadHashesOversizeAndPathEscape() throws {
    let f = try DocumentFileFixture(), url = f.root.appendingPathComponent("raw.png"), bytes = Data([137,80,78,71,0,255])
    try bytes.write(to: url)
    let hash = NotebookProgramPackage.hash(bytes)
    for path in ["../chart.png", "/host.png", "a/../chart.png"] {
      #expect(throws: CollaborationError.self) {
        try NotebookDocumentResourceImport.prepare(.init(filePath: url.path, path: path, sha256: hash))
      }
    }
    #expect(throws: NotebookStorageError.self) {
      try NotebookDocumentResourceImport.prepare(.init(filePath: url.path, path: "chart.png", sha256: String(repeating: "0", count: 64)))
    }
    let link = f.root.appendingPathComponent("link.png")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
    #expect(throws: (any Error).self) {
      try NotebookDocumentResourceImport.prepare(.init(filePath: link.path, path: "chart.png", sha256: hash))
    }
    let file = try FileHandle(forWritingTo: url); defer { try? file.close() }
    try file.truncate(atOffset: UInt64(DocumentDocument.maximumSourceBytes)+1)
    #expect(throws: NotebookStorageError.self) {
      try NotebookDocumentResourceImport.prepare(.init(filePath: url.path, path: "chart.png", sha256: hash))
    }
  }
}

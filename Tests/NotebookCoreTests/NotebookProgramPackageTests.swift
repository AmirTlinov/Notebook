import CryptoKit
import Foundation
import Darwin
import Testing
@testable import NotebookCore

@Suite("Immutable program packages share bounded SHA blob storage")
struct NotebookProgramPackageTests {
  private func fixture(_ body: (NotebookStore, URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root)
    _ = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    try body(store, root)
  }
  private func part(_ bytes: Data) -> NotebookProgramPackage.Part {
    .init(sha256: NotebookProgramPackage.hash(bytes), byteCount: bytes.count)
  }
  private func package(_ bytes: Data, path: String = "main.js") -> NotebookProgramPackage {
    .init(javaScript: path, files: [.init(path: path, mimeType: "text/javascript", byteCount: Int64(bytes.count), parts: bytes.isEmpty ? [] : [part(bytes)])])
  }

  @Test func namespaceMIMEEntryAndPartInvariantsRejectAmbiguousPublications() throws {
    for path in ["../main.js", "a/../main.js", "a//main.js", "a/./main.js", "/main.js", "main.js?token=1", "a%2fb.js", "a\\b.js", "https://host/main.js"] {
      #expect(!NotebookProgramPackage.validPath(path))
    }
    #expect(NotebookProgramPackage.validPath("@vendor/worker-1.mjs"))
    let bytes = Data("export const value=1".utf8), good = package(bytes)
    try good.validate()
    let file = good.files[0]
    for invalid in [
      NotebookProgramPackage(javaScript: "missing.js", files: [file]),
      NotebookProgramPackage(javaScript: file.path, files: [file, file]),
      NotebookProgramPackage(javaScript: file.path, files: [.init(path: file.path, mimeType: "text/html", byteCount: file.byteCount, parts: file.parts)]),
      NotebookProgramPackage(javaScript: file.path, files: [.init(path: file.path, mimeType: file.mimeType, byteCount: file.byteCount + 1, parts: file.parts)]),
      NotebookProgramPackage(javaScript: file.path, files: [.init(path: file.path, mimeType: file.mimeType, byteCount: file.byteCount * 2, parts: file.parts + file.parts)])
    ] { #expect(throws: (any Error).self) { try invalid.validate() } }
  }

  @Test func packageAdmissionIsIdempotentAndCannotPublishMissingParts() throws {
    try fixture { store, _ in
      let bytes = Data("export default 42".utf8), descriptor = package(bytes)
      let cursor = try store.currentChangeCursor()
      #expect(throws: (any Error).self) { try store.stageProgramPackage(descriptor) }
      try store.stageBlob(data: bytes, expectedHash: part(bytes).sha256)
      let root = try store.stageProgramPackage(descriptor)
      #expect(try store.stageProgramPackage(descriptor) == root)
      #expect(try store.readProgramPackage(root) == descriptor)
      #expect(try store.currentChangeCursor() == cursor, "Staging is not a causal scene publication")
      #expect(try store.readProgramFile(descriptor.files[0], offset: 7, maxBytes: 5) == bytes.subdata(in: 7..<12))
      #expect(try store.readProgramFile(descriptor.files[0], offset: Int64(bytes.count), maxBytes: 1).isEmpty)
      #expect(throws: (any Error).self) { try store.readProgramFile(descriptor.files[0], offset: -1, maxBytes: 1) }
      #expect(throws: (any Error).self) { try store.readProgramFile(descriptor.files[0], offset: 0, maxBytes: 1_048_577) }
    }
  }

  @Test func fileRangesKeepTheWholeFileContractAndRollbackBadSegments() throws {
    try fixture { store, root in
      let file = root.appendingPathComponent("source.bin"), bytes = Data("before-payload-after".utf8), payload = Data("payload".utf8)
      try bytes.write(to: file)
      let hash = part(payload).sha256
      #expect(throws: (any Error).self) { try store.stageBlob(file: file, expectedHash: hash, byteCount: 7) }
      #expect(throws: (any Error).self) { try store.blobSize(hash: hash) }
      #expect(throws: (any Error).self) { try store.stageBlob(file: file, expectedHash: hash, byteCount: 7, range: 0..<7) }
      #expect(throws: (any Error).self) { try store.stageBlob(file: file, expectedHash: hash, byteCount: 7, range: 7..<15) }
      try store.stageBlob(file: file, expectedHash: hash, byteCount: 7, range: 7..<14)
      #expect(try store.readBlobChunk(hash: hash, offset: 0, maxBytes: 10) == payload)
    }
  }

  @Test func largeSourceAndThreeHundredMiBFileReadAcrossPartsWithoutLargeBuffers() throws {
    try fixture { store, root in
      let file = root.appendingPathComponent("large.bin")
      #expect(FileManager.default.createFile(atPath: file.path, contents: nil))
      let output = try FileHandle(forWritingTo: file)
      defer { try? output.close() }
      let zero = Data(repeating: 0, count: NotebookProgramPackage.partBytes)
      var last = zero; last[last.count - 1] = 73
      let zeroPart = part(zero), lastPart = part(last)
      // A sparse on-disk fixture is 300 MiB, but neither the fixture nor the
      // production read/stage path allocates a 300 MiB Data value.
      try output.truncate(atOffset: 300 * 1024 * 1024)
      try output.seek(toOffset: 296 * 1024 * 1024); try output.write(contentsOf: last); try output.synchronize()
      try store.stageBlob(file: file, expectedHash: zeroPart.sha256, byteCount: Int64(zero.count), range: 0..<Int64(zero.count))
      try store.stageBlob(file: file, expectedHash: lastPart.sha256, byteCount: Int64(last.count), range: Int64(296 * 1024 * 1024)..<Int64(300 * 1024 * 1024))
      let source = Data(repeating: 32, count: 1_048_577), sourcePart = part(source)
      try store.stageBlob(data: source, expectedHash: sourcePart.sha256)
      let dataFile = NotebookProgramPackage.File(path: "data.bin", mimeType: "application/octet-stream", byteCount: 300 * 1024 * 1024,
        parts: Array(repeating: zeroPart, count: 74) + [lastPart])
      let descriptor = NotebookProgramPackage(javaScript: "main.js", files: [dataFile,
        .init(path: "main.js", mimeType: "text/javascript", byteCount: Int64(source.count), parts: [sourcePart])])
      let hash = try store.stageProgramPackage(descriptor)
      let reopened = try NotebookStore(root: root).readProgramPackage(hash)
      #expect(reopened == descriptor)
      #expect(try store.readProgramFile(dataFile, offset: Int64(4 * 1024 * 1024 - 3), maxBytes: 7) == Data(repeating: 0, count: 7))
      #expect(try store.readProgramFile(dataFile, offset: dataFile.byteCount - 2, maxBytes: 1_048_576) == Data([0,73]))
      let second = NotebookProgramPackage(javaScript: "main.js", module: false, files: descriptor.files)
      #expect(try store.stageProgramPackage(second) != hash)
      let distinct = try store.readTransaction { try $0.currentSQL!.rows("SELECT count(*) FROM blobs WHERE hash IN (?,?)", [.text(zeroPart.sha256), .text(lastPart.sha256)])[0][0].integer }
      #expect(distinct == 2, "Repeated files and publications share their immutable bytes")
    }
  }

  @Test func fileCapabilityRejectsPipesDevicesSymlinksAndOversizedMetadata() throws {
    try fixture { store, root in
      let pipe = root.appendingPathComponent("pipe"), link = root.appendingPathComponent("link")
      #expect(mkfifo(pipe.path, 0o600) == 0)
      try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/etc/hosts")
      for file in [pipe, link, URL(fileURLWithPath: "/dev/zero")] {
        #expect(throws: (any Error).self) { try NotebookProgramImport.read(file: file, expectedHash: String(repeating: "a", count: 64)) }
        #expect(throws: (any Error).self) { try store.stageBlob(file: file, expectedHash: String(repeating: "a", count: 64), byteCount: 1, range: 0..<1) }
      }
      let large = root.appendingPathComponent("huge.json")
      try Data(repeating: 32, count: 2_097_153).write(to: large)
      #expect(throws: (any Error).self) { try NotebookProgramImport.read(file: large, expectedHash: String(repeating: "a", count: 64)) }
    }
  }

  @Test func corruptOrForeignManifestDoesNotBecomeAReadableNamespace() throws {
    try fixture { store, root in
      let bytes = Data("export{}".utf8), descriptor = package(bytes)
      try store.stageBlob(data: bytes, expectedHash: part(bytes).sha256)
      let hash = try store.stageProgramPackage(descriptor)
      let foreignRoot = root.appendingPathComponent("other-workspace")
      let foreign = NotebookStore(root: foreignRoot)
      _ = try foreign.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
      #expect(throws: (any Error).self) { try foreign.readProgramPackage(hash) }
      try store.commandTransaction { try store.currentSQL!.run("UPDATE blobs SET data=? WHERE hash=?", [.blob(Data("{}".utf8)), .text(hash)]) }
      #expect(throws: (any Error).self) { try store.readProgramPackage(hash) }
    }
  }
}

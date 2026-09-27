import Foundation
import CryptoKit
import NotebookCore

/// Derived artifacts only. Content and causal undo remain in DocumentDocument.
/// Disk eviction never changes a document; it only requires recompilation.
public actor NotebookPrintedDocumentStore {
  private let compiler: NotebookTypesetter
  private let directory: URL
  private let resources: URL
  private struct Job { let id = UUID(); let task: Task<NotebookPrintedDocument, Error>; var readers: Set<UUID>; var saved = false }
  private var jobs: [String: Job] = [:]
  /// Requests reaching the real artifact owner, including cache reads. This is
  /// an aggregate diagnostic, not another retained history of document values.
  public private(set) var artifactRequestCount: UInt64 = 0
  public init(resources: URL, directory: URL) { compiler = .init(resources: resources); self.directory = directory; self.resources = resources }
  public func artifact(for document: DocumentDocument, input: NotebookTypesetterInput? = nil) async throws -> NotebookPrintedDocument {
    artifactRequestCount &+= 1
    let key = try cacheKey(document)
    let reader = UUID()
    let job: Job
    if var existing = jobs[key], !existing.task.isCancelled {
      existing.readers.insert(reader); jobs[key] = existing; job = existing
    } else {
      if let artifact = try? load(document, key: key) { return artifact }
      guard jobs.count < 4 else { throw NotebookTypesetterError("typesetter_busy") }
      let compiler = compiler
      job = Job(task: Task { try await compiler.compile(document, input: input) }, readers: [reader]); jobs[key] = job
    }
    defer { release(key: key, jobID: job.id, reader: reader) }
    return try await withTaskCancellationHandler {
      let value = try await job.task.value
      try Task.checkCancellation()
      // This is an evictable derived cache, not content persistence. Lack of
      // cache space cannot discard a successfully compiled visible page.
      if var current = jobs[key], current.id == job.id, !current.saved {
        try? save(value, key: key)
        current.saved = true; jobs[key] = current
      }
      return value
    } onCancel: { Task { await self.release(key: key, jobID: job.id, reader: reader) } }
  }
  public func compilerRevision() throws -> String {
    String(decoding: try read(resources.appendingPathComponent("revision.txt"), limit: 256), as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
  /// Import admits only an exact, compiler-matched derived snapshot. No VM is
  /// started; cache failure is independent of the already committed source.
  public func adopt(_ derived: NotebookPortableDocument.Derived, for document: DocumentDocument, input: NotebookTypesetterInput) throws {
    try input.validate(document: document)
    try derived.validate(document: document, compilerRevision: compilerRevision())
    let pages = try NotebookTypesetter.pages(derived.pdf)
    let projection = try NotebookPrintedDocument.projection(syncTeX: derived.syncTeX, files: derived.sourceMap.files, pages: pages)
    let regions = projection.interactiveRegions
    guard try NotebookPrintedDocument.regionMap(regions) == derived.interactiveMap else { throw NotebookTypesetterError("print_cache_invalid") }
    let source = document.files.first { $0.path == document.entrypoint && $0.resource == nil }!.source
    let value = NotebookPrintedDocument(document: document, source: source, pdf: derived.pdf, syncTeX: derived.syncTeX,
      sourceMap: derived.sourceMap, assets: input.files.filter { $0.path != input.entrypoint }.map { .init(name: $0.path, data: $0.data) },
      interactiveMap: derived.interactiveMap, pages: pages, interactiveRegions: regions, diagnostics: [],
      log: "portable_document_precompiled", guestMemoryBytes: 0)
    try save(value, key: cacheKey(document))
  }
  private func cacheKey(_ document: DocumentDocument) throws -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let revision = try read(resources.appendingPathComponent("revision.txt"), limit: 256)
    return SHA256.hash(data: Data(DocumentPrintSourceMap.renderingRecipe.utf8)+revision+(try encoder.encode(document))).map { String(format: "%02x", $0) }.joined()
  }
  private func release(key: String, jobID: UUID, reader: UUID) {
    guard var job = jobs[key], job.id == jobID else { return }
    job.readers.remove(reader)
    if job.readers.isEmpty { jobs[key] = nil; job.task.cancel() } else { jobs[key] = job }
  }
  private struct Metadata: Codable {
    let map: DocumentPrintSourceMap
    let assetNames: [String]
    let hashes: [String: String]
    let log: String
    let diagnostics: [NotebookPrintDiagnostic]
    let guestMemoryBytes: Int
  }
  private func load(_ document: DocumentDocument, key: String) throws -> NotebookPrintedDocument {
    let folder = directory.appendingPathComponent(key, isDirectory: true)
    let meta = try JSONDecoder().decode(Metadata.self, from: read(folder.appendingPathComponent("map.json"), limit: 8*1024*1024))
    let source = String(decoding: try read(folder.appendingPathComponent("source.tex"), limit: 4*1024*1024), as: UTF8.self)
    let pdf = try read(folder.appendingPathComponent("document.pdf"), limit: 16*1024*1024)
    try meta.map.validate(document: document, source: source, pdf: pdf)
    guard meta.map.compilerRevision == String(decoding: try read(resources.appendingPathComponent("revision.txt"), limit: 256), as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines) else { throw NotebookTypesetterError("print_cache_invalid") }
    let expected = document.files.map(\.path).filter { $0 != document.entrypoint }.sorted()
    guard meta.assetNames == expected else { throw NotebookTypesetterError("print_cache_invalid") }
    var assets: [NotebookPrintedAsset] = [], remaining = 16*1024*1024
    for (index, name) in meta.assetNames.enumerated() {
      let data = try read(folder.appendingPathComponent("file-\(index)"), limit: remaining)
      remaining -= data.count; assets.append(.init(name: name, data: data))
    }
    let interactiveMap = try read(folder.appendingPathComponent("document.nbmap"), limit: 4*1024*1024)
    let pages = try NotebookTypesetter.pages(pdf)
    let frozen = try NotebookTypesetterInput(entrypoint: document.entrypoint,
      files: [.init(path: document.entrypoint, data: Data(source.utf8))]+assets.map { .init(path: $0.name, data: $0.data) })
    try frozen.validate(document: document)
    let syncTeX = try read(folder.appendingPathComponent("document.synctex.gz"), limit: 4*1024*1024)
    let regions = try NotebookPrintedDocument.projection(syncTeX: syncTeX, files: meta.map.files, pages: pages).interactiveRegions
    guard try NotebookPrintedDocument.regionMap(regions) == interactiveMap else { throw NotebookTypesetterError("print_cache_invalid") }
    for (name, data) in [("document.synctex.gz", syncTeX), ("document.nbmap", interactiveMap)] + assets.map({ ("input:"+$0.name, $0.data) }) {
      guard meta.hashes[name] == Self.hash(data) else { throw NotebookTypesetterError("print_cache_invalid") }
    }
    try Task.checkCancellation()
    try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: folder.path)
    return .init(document: document, source: source, pdf: pdf,
      syncTeX: syncTeX, sourceMap: meta.map,
      assets: assets, interactiveMap: interactiveMap, pages: pages, interactiveRegions: regions, diagnostics: meta.diagnostics,
      log: meta.log, guestMemoryBytes: meta.guestMemoryBytes)
  }
  private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
  public func vectorPDF(_ svg: Data) async throws -> Data { try await compiler.convertSVG(svg) }
  public func trimIdleCompiler() async { await compiler.trimIdle() }
  private func read(_ url: URL, limit: Int) throws -> Data {
    try Task.checkCancellation()
    let size = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
    guard size.isRegularFile == true, size.isSymbolicLink != true, let count = size.fileSize, count <= limit else { throw NotebookTypesetterError("print_cache_invalid") }
    let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
    let data = try file.read(upToCount: limit+1) ?? Data()
    guard data.count == count else { throw NotebookTypesetterError("print_cache_invalid") }
    return data
  }
  private func save(_ value: NotebookPrintedDocument, key: String) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    let pending = directory.appendingPathComponent("pending-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: pending, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: pending) }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let hashes = Dictionary(uniqueKeysWithValues: ([ ("document.synctex.gz", value.syncTeX), ("document.nbmap", value.interactiveMap) ] + value.assets.map { ("input:"+$0.name, $0.data) }).map { ($0.0, Self.hash($0.1)) })
    let metadata = Metadata(map: value.sourceMap, assetNames: value.assets.map(\.name), hashes: hashes, log: value.log, diagnostics: value.diagnostics, guestMemoryBytes: value.guestMemoryBytes)
    for (name, data) in [("map.json", try encoder.encode(metadata)), ("source.tex", Data(value.source.utf8)),
      ("document.pdf", value.pdf), ("document.synctex.gz", value.syncTeX), ("document.nbmap", value.interactiveMap)]
      + value.assets.enumerated().map({ ("file-\($0.offset)", $0.element.data) }) {
      try data.write(to: pending.appendingPathComponent(name), options: .atomic)
    }
    let target = directory.appendingPathComponent(key, isDirectory: true)
    if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
    try fm.moveItem(at: pending, to: target)
    func modified(_ url: URL) -> Date { (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
    let entries = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey])
    for orphan in entries where orphan.lastPathComponent.hasPrefix("pending-") && modified(orphan) < Date().addingTimeInterval(-3600) {
      try? fm.removeItem(at: orphan)
    }
    let folders = entries.filter { $0.lastPathComponent.count == 64 }.sorted { modified($0) > modified($1) }
    var kept = 0
    for folder in folders {
      let files = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])
      let cost = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
      kept += cost
      if kept > 128*1024*1024, folder != target { try fm.removeItem(at: folder) }
    }
  }
}

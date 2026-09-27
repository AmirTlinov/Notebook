import Foundation
import CryptoKit
import NotebookCore

/// Derived artifacts only. Exact compiler input dependencies identify pixels;
/// every reader binds those pixels back to its own immutable causal document.
public actor NotebookPrintedDocumentStore {
  private let compiler: NotebookTypesetter
  private let directory: URL
  private let resources: URL
  private struct Job { let id = UUID(); let task: Task<NotebookPrintedDocument, Error>; let demand: NotebookTypesetterDemand; var readers: Set<UUID>; var saved = false }
  private var jobs: [String: Job] = [:]
  private final class WeakArtifact {
    weak var value: NotebookPrintedDocument?
    init(_ value: NotebookPrintedDocument) { self.value = value }
  }
  // Mounted sources own lifetime and accounting. The store can reuse their
  // immutable projection without pinning closed documents in a global cache.
  private var mounted: [WeakArtifact] = []
  private func remember(_ artifact: NotebookPrintedDocument) -> NotebookPrintedDocument {
    mounted = mounted.filter { $0.value != nil }
    if mounted.count >= 32 { mounted.removeFirst() }
    mounted.append(WeakArtifact(artifact)); return artifact
  }
  public private(set) var artifactRequestCount: UInt64 = 0
  public init(resources: URL, directory: URL) { compiler = .init(resources: resources); self.directory = directory; self.resources = resources }

  public func artifact(for document: DocumentDocument, input: NotebookTypesetterInput? = nil,
    priority: NotebookTypesetter.Priority = .current, demand: NotebookTypesetterDemand? = nil,
    inputFactory: (@Sendable () async throws -> NotebookTypesetterInput)? = nil) async throws -> NotebookPrintedDocument {
    artifactRequestCount &+= 1
    try Task.checkCancellation()
    let demand = demand ?? NotebookTypesetterDemand(priority: priority)
    demand.beginMeasurement()
    defer { demand.finishMeasurement() }
    let lookupStart = ContinuousClock.now
    if let input { try input.validate(document: document) }
    let revision = try compilerRevision()
    mounted = mounted.filter { $0.value != nil }
    for value in mounted.reversed().compactMap(\.value) where try value.dependencies.matches(document, compilerRevision: revision) {
      demand.record("lookup", since: lookupStart)
      demand.record("memoryLookup", since: lookupStart)
      return remember(try value.bound(to: document))
    }
    if let artifact = try cached(document, compilerRevision: revision) {
      demand.record("lookup", since: lookupStart)
      demand.record("diskLookup", since: lookupStart)
      return remember(artifact)
    }
    demand.record("lookup", since: lookupStart)
    try Task.checkCancellation()
    let keyStart = ContinuousClock.now
    let key = try DocumentPrintDependencies.namespaceIdentity(document, compilerRevision: revision)
    demand.record("namespace", since: keyStart)
    let reader = UUID(), job: Job, coalesced: Bool
    if var existing = jobs[key], !existing.task.isCancelled {
      demand.join(existing.demand)
      coalesced = true
      existing.readers.insert(reader); jobs[key] = existing; job = existing
    } else {
      coalesced = false
      guard jobs.count < 4 else { throw NotebookTypesetterError("typesetter_busy") }
      let compiler = compiler
      demand.beginJob()
      job = Job(task: Task {
        let inputStart = ContinuousClock.now
        let frozen: NotebookTypesetterInput
        if let input { frozen = input }
        else if let inputFactory { frozen = try await inputFactory() }
        else { frozen = try NotebookTypesetterInput(document: document) }
        demand.record("inputs", since: inputStart)
        try Task.checkCancellation()
        return try await compiler.compile(document, input: frozen, priority: priority, demand: demand)
      }, demand: demand, readers: [reader])
      jobs[key] = job
    }
    defer { release(key: key, jobID: job.id, reader: reader) }
    return try await withTaskCancellationHandler {
      let waitStart = ContinuousClock.now
      let value = try await PrintedArtifactReader.wait(for: job.task)
      demand.record("wait", since: waitStart)
      if coalesced { demand.record("coalescedWait", since: waitStart) }
      try Task.checkCancellation()
      if var current = jobs[key], current.id == job.id, !current.saved {
        let saveStart = ContinuousClock.now
        try? save(value)
        demand.record("save", since: saveStart)
        current.saved = true; jobs[key] = current
      }
      let bindStart = ContinuousClock.now
      defer { demand.record("bind", since: bindStart) }
      return remember(try value.bound(to: document))
    } onCancel: { Task { await self.release(key: key, jobID: job.id, reader: reader) } }
  }
  public func compilerRevision() throws -> String {
    String(decoding: try read(resources.appendingPathComponent("revision.txt"), limit: 256), as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
  public func adopt(_ derived: NotebookPortableDocument.Derived, for document: DocumentDocument, input: NotebookTypesetterInput) throws {
    try input.validate(document: document)
    try derived.validate(document: document, compilerRevision: compilerRevision())
    let pages = try NotebookTypesetter.pages(derived.pdf)
    let projection = try NotebookPrintedDocument.projection(syncTeX: derived.syncTeX, files: derived.sourceMap.files, pages: pages)
    guard try NotebookPrintedDocument.regionMap(projection.interactiveRegions) == derived.interactiveMap else { throw NotebookTypesetterError("print_cache_invalid") }
    let source = document.files.first { $0.path == document.entrypoint && $0.resource == nil }!.source
    let value = NotebookPrintedDocument(document: document, source: source, pdf: derived.pdf, syncTeX: derived.syncTeX,
      sourceMap: derived.sourceMap, interactiveMap: derived.interactiveMap, pages: pages, projection: projection,
      dependencies: try .init(namespace: document, compilerRevision: compilerRevision()), diagnostics: [],
      log: "portable_document_precompiled", guestMemoryBytes: 0)
    try save(value)
  }
  private func release(key: String, jobID: UUID, reader: UUID) {
    guard var job = jobs[key], job.id == jobID else { return }
    job.readers.remove(reader)
    if job.readers.isEmpty { jobs[key] = nil; job.task.cancel() } else { jobs[key] = job }
  }
  private struct Metadata: Codable {
    let dependencies: DocumentPrintDependencies
    let pdfSHA256: String
    let hashes: [String: String]
    let log: String
    let diagnostics: [NotebookPrintDiagnostic]
    let guestMemoryBytes: Int
  }
  private func cached(_ document: DocumentDocument, compilerRevision: String) throws -> NotebookPrintedDocument? {
    let fm = FileManager.default
    guard let folders = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
    let ordered = folders.filter { NotebookProgramPackage.validHash($0.lastPathComponent) }.sorted {
      ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
    }
    for folder in ordered {
      try Task.checkCancellation()
      guard let meta = try? JSONDecoder().decode(Metadata.self, from: read(folder.appendingPathComponent("map.json"), limit: 8*1024*1024)),
        (try? meta.dependencies.identity) == folder.lastPathComponent,
        (try? meta.dependencies.matches(document, compilerRevision: compilerRevision)) == true else { continue }
      if let value = try? load(document, folder: folder, metadata: meta) { return value }
    }
    return nil
  }
  private func load(_ document: DocumentDocument, folder: URL, metadata meta: Metadata) throws -> NotebookPrintedDocument {
    let source = document.files.first { $0.path == document.entrypoint && $0.resource == nil }!.source
    let pdf = try read(folder.appendingPathComponent("document.pdf"), limit: 16*1024*1024)
    guard Self.hash(pdf) == meta.pdfSHA256 else { throw NotebookTypesetterError("print_cache_invalid") }
    let interactiveMap = try read(folder.appendingPathComponent("document.nbmap"), limit: 4*1024*1024)
    let syncTeX = try read(folder.appendingPathComponent("document.synctex.gz"), limit: 4*1024*1024)
    guard meta.hashes["document.synctex.gz"] == Self.hash(syncTeX),
      meta.hashes["document.nbmap"] == Self.hash(interactiveMap) else { throw NotebookTypesetterError("print_cache_invalid") }
    let map = try DocumentPrintSourceMap(document: document, source: source, pdfSHA256: meta.pdfSHA256,
      compilerRevision: meta.dependencies.compilerRevision)
    let pages = try NotebookTypesetter.pages(pdf)
    let projection = try NotebookPrintedDocument.projection(syncTeX: syncTeX, files: map.files, pages: pages)
    guard try NotebookPrintedDocument.regionMap(projection.interactiveRegions) == interactiveMap else { throw NotebookTypesetterError("print_cache_invalid") }
    try Task.checkCancellation()
    try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: folder.path)
    return .init(document: document, source: source, pdf: pdf, syncTeX: syncTeX, sourceMap: map,
      interactiveMap: interactiveMap, pages: pages, projection: projection, dependencies: meta.dependencies,
      diagnostics: meta.diagnostics.map { $0.bound(to: document) }, log: meta.log, guestMemoryBytes: meta.guestMemoryBytes)
  }
  private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
  public func vectorPDF(_ svg: Data, priority: NotebookTypesetter.Priority = .current) async throws -> Data {
    try await compiler.convertSVG(svg, priority: priority)
  }
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
  private func save(_ value: NotebookPrintedDocument) throws {
    let fm = FileManager.default, key = try value.dependencies.identity
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    let pending = directory.appendingPathComponent("pending-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: pending, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: pending) }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let hashes = ["document.synctex.gz": Self.hash(value.syncTeX), "document.nbmap": Self.hash(value.interactiveMap)]
    let metadata = Metadata(dependencies: value.dependencies, pdfSHA256: value.sourceMap.pdfSHA256,
      hashes: hashes, log: value.log, diagnostics: value.diagnostics, guestMemoryBytes: value.guestMemoryBytes)
    for (name, data) in [("map.json", try encoder.encode(metadata)), ("document.pdf", value.pdf),
      ("document.synctex.gz", value.syncTeX), ("document.nbmap", value.interactiveMap)] {
      try data.write(to: pending.appendingPathComponent(name), options: .atomic)
    }
    let target = directory.appendingPathComponent(key, isDirectory: true)
    if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
    try fm.moveItem(at: pending, to: target)
    func modified(_ url: URL) -> Date { (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
    let entries = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
    for orphan in entries where orphan.lastPathComponent.hasPrefix("pending-") && modified(orphan) < Date().addingTimeInterval(-3600) {
      try? fm.removeItem(at: orphan)
    }
    let folders = entries.filter { $0.lastPathComponent.count == 64 }.sorted { modified($0) > modified($1) }
    var kept = 0
    for folder in folders {
      let files = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])
      kept += files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
      if kept > 128*1024*1024, folder != target { try fm.removeItem(at: folder) }
    }
  }
}

extension NotebookPrintedDocument {
  func bound(to document: DocumentDocument) throws -> NotebookPrintedDocument {
    if self.document == document { return self }
    guard try dependencies.matches(document, compilerRevision: sourceMap.compilerRevision),
      let source = document.files.first(where: { $0.path == document.entrypoint && $0.resource == nil })?.source else {
      throw NotebookTypesetterError("print_cache_invalid")
    }
    let map = try DocumentPrintSourceMap(document: document, source: source, pdfSHA256: sourceMap.pdfSHA256,
      compilerRevision: sourceMap.compilerRevision)
    return .init(document: document, source: source, pdf: pdf, syncTeX: syncTeX, sourceMap: map,
      interactiveMap: interactiveMap, pages: pages, projection: projection.rebinding(files: map.files),
      dependencies: dependencies, diagnostics: diagnostics.map { $0.bound(to: document) }, log: log, guestMemoryBytes: guestMemoryBytes)
  }
}

private extension NotebookPrintDiagnostic {
  func bound(to document: DocumentDocument) -> Self {
    .init(fileID: path.flatMap { path in document.files.first { $0.path == path }?.id },
      path: path, line: line, severity: severity, message: message)
  }
}

/// Cancelling a subscriber ends its wait immediately. The shared task's last
/// reader separately owns cancellation of queued/admitted compiler work.
private final class PrintedArtifactReader: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<NotebookPrintedDocument, Error>?
  private var completed = false
  private var earlyResult: Result<NotebookPrintedDocument, Error>?
  private func attach(_ continuation: CheckedContinuation<NotebookPrintedDocument, Error>) {
    lock.lock()
    if let result = earlyResult { earlyResult = nil; lock.unlock(); continuation.resume(with: result) }
    else { self.continuation = continuation; lock.unlock() }
  }
  private func finish(_ result: Result<NotebookPrintedDocument, Error>) {
    lock.lock()
    guard !completed else { lock.unlock(); return }
    completed = true
    let continuation = continuation; self.continuation = nil
    if continuation == nil { earlyResult = result }
    lock.unlock(); continuation?.resume(with: result)
  }
  static func wait(for task: Task<NotebookPrintedDocument, Error>) async throws -> NotebookPrintedDocument {
    let reader = PrintedArtifactReader()
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        reader.attach(continuation)
        Task { reader.finish(await task.result) }
      }
    } onCancel: { reader.finish(.failure(CancellationError())) }
  }
}

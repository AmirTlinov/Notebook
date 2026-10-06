import Foundation
import CryptoKit
import NotebookCore

/// Derived artifacts only. Exact compiler input dependencies identify pixels;
/// every reader binds those pixels back to its own immutable causal document.
public actor NotebookPrintedDocumentStore {
  private let compiler: NotebookTypesetter
  private let directory: URL
  private let resources: URL
  private var disk: NotebookPrintedArtifactCache?
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
    var source = DocumentPrintDependencies.Source(document)
    if let input { try input.validate(document: document) }
    let revision = try compilerRevision()
    mounted = mounted.filter { $0.value != nil }
    for value in mounted.reversed().compactMap(\.value) where try value.dependencies.matches(&source, compilerRevision: revision) {
      demand.record("lookup", since: lookupStart)
      demand.record("memoryLookup", since: lookupStart)
      let bindStart = ContinuousClock.now
      defer { demand.record("bind", since: bindStart) }
      return remember(try value.bound(to: &source))
    }
    if let artifact = try cached(&source, compilerRevision: revision) {
      demand.record("lookup", since: lookupStart)
      demand.record("diskLookup", since: lookupStart)
      return remember(artifact)
    }
    demand.record("lookup", since: lookupStart)
    try Task.checkCancellation()
    let keyStart = ContinuousClock.now
    let key = try DocumentPrintDependencies.namespaceIdentity(&source, compilerRevision: revision)
    demand.record("namespace", since: keyStart)
    let reader = UUID(), job: Job, coalesced: Bool
    if var existing = jobs[key], !existing.task.isCancelled {
      demand.join(existing.demand)
      coalesced = true
      existing.readers.insert(reader); jobs[key] = existing; job = existing
    } else {
      coalesced = false
      let compiler = compiler, preparedSource = source
      demand.beginJob()
      job = Job(task: Task {
        try await compiler.compile(source: preparedSource, input: input, priority: priority,
          demand: demand, inputFactory: inputFactory)
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
        try? save(value, source: &source)
        demand.record("save", since: saveStart)
        current.saved = true; jobs[key] = current
      }
      try Task.checkCancellation()
      let bindStart = ContinuousClock.now
      defer { demand.record("bind", since: bindStart) }
      return remember(try value.bound(to: &source))
    } onCancel: { Task { await self.release(key: key, jobID: job.id, reader: reader) } }
  }
  public func compilerRevision() throws -> String {
    String(decoding: try read(resources.appendingPathComponent("revision.txt"), limit: 256), as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
  public func adopt(_ derived: NotebookPortableDocument.Derived, for document: DocumentDocument, input: NotebookTypesetterInput,
    allowance: NotebookPrintedDocument.CacheAdoptionCost) throws {
    try Task.checkCancellation()
    try allowance.validate(derived)
    try input.validate(document: document)
    try derived.validate(document: document, compilerRevision: compilerRevision())
    let pages = try NotebookTypesetter.pages(derived.pdf)
    let projection = try NotebookPrintedDocument.projection(syncTeX: derived.syncTeX, files: derived.sourceMap.files, pages: pages,
      allocationBytes: allowance.projectionBytes)
    guard try NotebookPrintedDocument.regionMap(projection.interactiveRegions) == derived.interactiveMap else { throw NotebookTypesetterError("print_cache_invalid") }
    var indexedSource = DocumentPrintDependencies.Source(document)
    let source = indexedSource.file(at: document.entrypoint)!.source
    let value = NotebookPrintedDocument(document: document, source: source, pdf: derived.pdf, syncTeX: derived.syncTeX,
      sourceMap: derived.sourceMap, interactiveMap: derived.interactiveMap, pages: pages, projection: projection,
      dependencies: try .init(namespace: &indexedSource, compilerRevision: compilerRevision()), diagnostics: [],
      log: "portable_document_precompiled", guestMemoryBytes: 0)
    try save(value, source: &indexedSource)
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
  /// Every successful print reads its entrypoint. It selects the input group;
  /// the observed read set still decides which version inside that group fits.
  private func bucket(_ source: inout DocumentPrintDependencies.Source, compilerRevision: String) throws -> String {
    guard let file = source.file(at: source.entrypoint), file.resource == nil else {
      throw NotebookTypesetterError("typesetter_entrypoint_missing_encoding_or_limit")
    }
    let key = Self.hash(try JSONEncoder().encode([DocumentPrintSourceMap.renderingRecipe,
      compilerRevision, source.entrypoint, String(try source.digest(at: source.entrypoint).dropFirst("text:".count))]))
    return key
  }
  private func diskCache() throws -> NotebookPrintedArtifactCache {
    if let disk { return disk }
    let cache = try NotebookPrintedArtifactCache(directory: directory)
    disk = cache
    return cache
  }
  private func cached(_ source: inout DocumentPrintDependencies.Source, compilerRevision: String) throws -> NotebookPrintedDocument? {
    let bucket = try bucket(&source, compilerRevision: compilerRevision)
    guard let cache = try? diskCache() else { return nil }
    var metadata: Metadata?
    while let record = try? cache.find(in: bucket, matching: { identity, bytes in
      try Task.checkCancellation()
      guard let meta = try? JSONDecoder().decode(Metadata.self, from: bytes),
        (try? meta.dependencies.identity) == identity,
        (try? meta.dependencies.matches(&source, compilerRevision: compilerRevision)) == true else { return false }
      metadata = meta
      return true
    }) {
      if let metadata {
        do { return try load(source.document, record: record, metadata: metadata) }
        catch is CancellationError { throw CancellationError() }
        catch { }
      }
      // A corrupt derived record cannot block a valid older version or editing.
      try Task.checkCancellation()
      do { try cache.remove(record.identity) } catch { return nil }
    }
    return nil
  }
  private func load(_ document: DocumentDocument, record: NotebookPrintedArtifactCache.Record, metadata meta: Metadata) throws -> NotebookPrintedDocument {
    let source = document.files.first { $0.path == document.entrypoint && $0.resource == nil }!.source
    let pdf = record.pdf, syncTeX = record.syncTeX, interactiveMap = record.interactiveMap
    guard Self.hash(pdf) == meta.pdfSHA256,
      meta.hashes["document.synctex.gz"] == Self.hash(syncTeX),
      meta.hashes["document.nbmap"] == Self.hash(interactiveMap) else { throw NotebookTypesetterError("print_cache_invalid") }
    let map = try DocumentPrintSourceMap(document: document, source: source, pdfSHA256: meta.pdfSHA256,
      compilerRevision: meta.dependencies.compilerRevision)
    let pages = try NotebookTypesetter.pages(pdf)
    let projection = try NotebookPrintedDocument.projection(syncTeX: syncTeX, files: map.files, pages: pages)
    guard try NotebookPrintedDocument.regionMap(projection.interactiveRegions) == interactiveMap else { throw NotebookTypesetterError("print_cache_invalid") }
    try Task.checkCancellation()
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
  private func save(_ value: NotebookPrintedDocument, source: inout DocumentPrintDependencies.Source) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let metadata = Metadata(dependencies: value.dependencies, pdfSHA256: value.sourceMap.pdfSHA256,
      hashes: ["document.synctex.gz": Self.hash(value.syncTeX), "document.nbmap": Self.hash(value.interactiveMap)],
      log: value.log, diagnostics: value.diagnostics, guestMemoryBytes: value.guestMemoryBytes)
    try diskCache().save(.init(identity: value.dependencies.identity, metadata: encoder.encode(metadata),
      pdf: value.pdf, syncTeX: value.syncTeX, interactiveMap: value.interactiveMap),
      in: bucket(&source, compilerRevision: value.dependencies.compilerRevision))
  }

}

extension NotebookPrintedDocument {
  func bound(to indexed: inout DocumentPrintDependencies.Source) throws -> NotebookPrintedDocument {
    let document = indexed.document
    if self.document == document { return self }
    guard try dependencies.matches(&indexed, compilerRevision: sourceMap.compilerRevision),
      let file = indexed.file(at: document.entrypoint), file.resource == nil else {
      throw NotebookTypesetterError("print_cache_invalid")
    }
    let source = file.source
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

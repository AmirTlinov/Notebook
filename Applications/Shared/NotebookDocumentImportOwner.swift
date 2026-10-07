import Foundation
import NotebookCore
import NotebookTypesetter

@MainActor
final class NotebookDocumentImportOwner {
  struct Result: Sendable {
    let documentID: UUID
    let actionID: UUID
    let cachedPrint: Bool
    var response: JSONValue {
      .object(["status": .string("imported"), "documentID": .string(documentID.uuidString.lowercased()),
        "actionID": .string(actionID.uuidString.lowercased()), "cachedPrint": .bool(cachedPrint)])
    }
  }
  private let persistence: NotebookPersistenceQueue
  private let actor: UUID
  private let printStore: NotebookPrintedDocumentStore
  private var preparations: [UUID: Task<Result, Error>] = [:]
  private var cacheJobs: [UUID: Task<Void, Never>] = [:]
  private var stopped = false
  var optionalJobCount: Int { cacheJobs.count }
  var hasPendingAuthoredPreparation: Bool { !preparations.isEmpty }
  #if DEBUG
    static var onAuthoredPreparation: (@MainActor () async -> Void)?
  #endif
  init(persistence: NotebookPersistenceQueue, actor: UUID,
    printStore: NotebookPrintedDocumentStore = DocumentCanonicalPrint.store) {
    self.persistence = persistence; self.actor = actor; self.printStore = printStore
  }
  func stop() {
    stopped = true
    for task in preparations.values { task.cancel() }
    for task in cacheJobs.values { task.cancel() }
  }
  func close() async {
    stop()
    // The task's own cleanup releases its reservation and staging. Joining
    // only a body read would leave a resumable preparation outside this owner.
    while !preparations.isEmpty || !cacheJobs.isEmpty {
      let imports = Array(preparations.values), caches = Array(cacheJobs.values)
      for task in imports { _ = await task.result }
      for task in caches { await task.value }
    }
  }
  func run(_ request: NotebookDocumentImportRequest) async throws -> Result {
    try request.validate()
    return try await run(file: URL(fileURLWithPath: request.filePath), expectedHash: request.sha256,
      requestID: request.id, targetBoardID: request.targetBoardID, center: request.center)
  }

  func run(file: URL, targetBoardID: UUID, center: WorldPoint) async throws -> Result {
    try await run(file: file, expectedHash: nil, requestID: UUID(), targetBoardID: targetBoardID,
      center: center)
  }

  private func run(file: URL, expectedHash: String?, requestID: UUID, targetBoardID: UUID,
    center: WorldPoint) async throws -> Result {
    guard !stopped else { throw CancellationError() }
    guard persistence.permitsNewWorkspaceMutation else {
      throw CollaborationError("workspace_selection_pending", "Выбор пространства ещё сохраняется.")
    }
    guard center.isValid else { throw CollaborationError("invalid_document_import", "Нужно точное место импорта документа.") }
    let initial = Self.cost(NotebookPortableDocumentImport.directoryCost)
    guard let reservation = persistence.reserveWrite(initial) else {
      throw NotebookPersistenceQueue.Failure(message: "Сохранение заполнено. Документ ещё не прочитан; повторите после восстановления записи.")
    }
    let id = UUID()
    let task = Task { [self] in
      defer { preparations[id] = nil; persistence.releaseWriteReservation(reservation) }
      return try await prepare(file: file, expectedHash: expectedHash, requestID: requestID,
        targetBoardID: targetBoardID, center: center, reservation: reservation, initial: initial)
    }
    preparations[id] = task
    return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
  }

  private func prepare(file: URL, expectedHash: String?, requestID: UUID, targetBoardID: UUID,
    center: WorldPoint, reservation: NotebookPersistenceAdmission.Reservation,
    initial: NotebookPersistenceAdmission.Cost) async throws -> Result {
    #if DEBUG
      await Self.onAuthoredPreparation?()
    #endif
    var held = initial.bytes
    func next(_ value: NotebookPortableDocumentImport.Cost) throws {
      guard !stopped else { throw CancellationError() }
      let next = Self.cost(value)
      if next.bytes > held { try persistence.extendPreparationReservation(reservation, to: next) }
      else { try persistence.resizeWriteReservation(reservation, to: next) }
      held = next.bytes
    }
    let inspection = try await worker { try NotebookPortableDocumentImport.inspect(file: file, expectedHash: expectedHash) }
    try next(inspection.metadataReadCost)
    var raw: NotebookPortableDocumentImport.MetadataBytes? = try await worker { try inspection.readMetadata() }
    try next(raw!.decodeCost)
    var metadata: NotebookPortableDocumentImport.Metadata?
    do { let bytes = raw!; metadata = try await worker { try bytes.decode() } }
    raw = nil
    try next(metadata!.sourceReadCost)
    var sources: NotebookPortableDocumentImport.Sources?
    do { let typed = metadata!; sources = try await worker { try typed.readSources() } }
    metadata = nil
    try next(sources!.preparationCost)
    var prepared: NotebookPortableDocumentImport.Prepared?
    do {
      let material = sources!, actor = actor
      prepared = try await worker { try material.prepare(requestID: requestID, targetBoardID: targetBoardID,
        center: center, actor: actor) }
    }
    sources = nil
    try next(prepared!.cost)
    // Preparation is optional and never occupies the writer. This completed
    // plan transfers the same physical credit only when its FIFO slot is ready.
    let cache = prepared!.cache
    guard !stopped else { throw CancellationError() }
    try Task.checkCancellation()
    let saved = try Self.accept(prepared!, reservation: reservation, persistence: persistence)
    prepared = nil
    let imported = try await saved.value
    if !stopped, let cache { scheduleCache(cache, document: imported.document) }
    return .init(documentID: imported.documentID, actionID: imported.receipt.id, cachedPrint: false)
  }

  private func scheduleCache(_ cache: NotebookPortableDocumentImport.Cache,
    document: DocumentDocument) {
    guard !stopped, cacheJobs.count < 2, let initial = cache.cost(for: document),
      let reservation = persistence.reserveWrite(Self.cost(initial)) else { return }
    let id = UUID()
    cacheJobs[id] = Task { [self] in
      defer { cacheJobs[id] = nil; persistence.releaseWriteReservation(reservation) }
      do {
        let revision = try await printStore.compilerRevision()
        guard !stopped else { throw CancellationError() }
        if let bytes = try await worker({ try cache.readDerivedBytes(document: document) }) {
          try persistence.extendPreparationReservation(reservation, to: Self.cost(bytes.decodingCost))
          guard let derived = try await worker({ try bytes.decode(compilerRevision: revision) }) else { return }
          let expansion = try NotebookPrintedDocument.cacheAdoptionCost(derived)
          guard expansion.bytes <= NotebookPortableDocumentImport.maximumPreparationBytes-bytes.decodingCost.bytes else {
            throw NotebookStorageError.limitExceeded("portable_cache_memory")
          }
          let next = NotebookPersistenceAdmission.Cost(payloadBytes: bytes.decodingCost.payloadBytes,
            completionBytes: bytes.decodingCost.completionBytes + expansion.bytes)
          try persistence.extendPreparationReservation(reservation, to: next)
          let input = try await worker {
            try NotebookTypesetterInput(document: document) { try cache.readResource($0) }
          }
          guard !stopped else { throw CancellationError() }
          try await printStore.adopt(derived, for: document, input: input,
            allowance: expansion)
        }
      } catch { /* Optional cache admission never delays or retracts authored import. */ }
    }
  }

  private static func cost(_ cost: NotebookPortableDocumentImport.Cost) -> NotebookPersistenceAdmission.Cost {
    .init(payloadBytes: cost.payloadBytes, completionBytes: cost.completionBytes)
  }

  private static func accept(_ plan: NotebookPortableDocumentImport.Prepared,
    reservation: NotebookPersistenceAdmission.Reservation, persistence: NotebookPersistenceQueue)
    throws -> Task<NotebookPortableDocumentImport.Output, Error> {
    let command = plan.command(), retained = cost(plan.cost)
    return try persistence.enqueuePreparedCommand(reservation: reservation, Task {
      NotebookPersistenceQueue.PreparedCommand(cost: retained, operation: { try command.apply(to: $0) })
    }, publishesChanges: true)
  }

  /// Cancellation stops the actual body worker; its join always precedes
  /// releasing or increasing the reservation for the following phase.
  private func worker<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
    guard !stopped else { throw CancellationError() }
    try Task.checkCancellation()
    let task = Task.detached(priority: .utility, operation: operation)
    let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    try Task.checkCancellation()
    return value
  }
}

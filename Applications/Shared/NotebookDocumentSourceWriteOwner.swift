import Foundation
import NotebookCore

/// Source indexing is pure preparation. Only its completed immutable plan
/// enters the existing writer, after the released human contact has settled.
@MainActor
final class NotebookDocumentSourceWriteOwner {
  private let persistence: NotebookPersistenceQueue
  private let inputGate: NotebookInputGate
  private let actor: UUID
  private var operations: [UUID: Task<DocumentSourceCommitResult, Error>] = [:]
  private var preparingID: UUID?
  private var stopped = false
  var hasPendingAuthoredPreparation: Bool { !operations.isEmpty }
  #if DEBUG
    static var onPreparationWorker: (@Sendable () async -> Void)?
  #endif

  init(persistence: NotebookPersistenceQueue, inputGate: NotebookInputGate, actor: UUID) {
    self.persistence = persistence; self.inputGate = inputGate; self.actor = actor
  }

  func begin(edit: DocumentSourceEdit, workspaceID: UUID,
    continuing: @escaping @MainActor () -> Bool) throws -> Task<DocumentSourceCommitResult, Error> {
    try Task.checkCancellation()
    guard !stopped, continuing() else { throw CancellationError() }
    try persistence.requireMutationAdmission()
    // Editor switches can finish one session while starting the next. One
    // unaccepted preparation keeps their aggregate work within 64 MiB, leaving
    // the same 256 MiB writer room for the real 192 MiB Pencil reservation.
    guard preparingID == nil else {
      throw NotebookPersistenceQueue.Failure(message: "Предыдущий исходник ещё подготавливается. Повторите после завершения подготовки.")
    }
    let initial = Self.cost(try PreparedDocumentSourceEdit.cost(for: edit))
    guard let reservation = persistence.reserveWrite(initial) else {
      throw NotebookPersistenceQueue.Failure(message: "Сохранение заполнено. Повторите после восстановления записи.")
    }
    let id = UUID()
    preparingID = id
    let task = Task<DocumentSourceCommitResult, Error> { [self] in
      // execute has dropped its worker and plan before the provisional credit
      // is released. An accepted reservation belongs to the FIFO instead.
      defer {
        if preparingID == id { preparingID = nil }
        operations[id] = nil
        persistence.releaseWriteReservation(reservation)
      }
      return try await execute(id: id, edit: edit, workspaceID: workspaceID,
        reservation: reservation, continuing: continuing)
    }
    operations[id] = task
    return task
  }

  func stop() {
    stopped = true
    for task in operations.values { task.cancel() }
  }

  func close() async {
    stop()
    while !operations.isEmpty {
      let tasks = Array(operations.values)
      for task in tasks { _ = await task.result }
    }
  }

  private func execute(id: UUID, edit: DocumentSourceEdit, workspaceID: UUID,
    reservation: NotebookPersistenceAdmission.Reservation,
    continuing: @MainActor () -> Bool) async throws -> DocumentSourceCommitResult {
    try Task.checkCancellation()
    guard !stopped, continuing() else { throw CancellationError() }
    let prepared = try await prepare(edit: edit, workspaceID: workspaceID)
    try persistence.resizeWriteReservation(reservation, to: Self.cost(prepared.retainedCost))
    while true {
      let inputGeneration = inputGate.acceptedContactGeneration
      guard await inputGate.waitUntilIdle() else { throw CancellationError() }
      try Task.checkCancellation()
      guard !stopped, continuing() else { throw CancellationError() }
      // Resuming this task is a later MainActor turn. A new contact may have
      // begun or even lifted after the preceding idle callback completed.
      if !inputGate.isActive, inputGate.acceptedContactGeneration == inputGeneration { break }
    }
    try persistence.requireMutationAdmission()
    let cost = Self.cost(prepared.cost)
    try persistence.extendPreparationReservation(reservation, to: cost)
    try Task.checkCancellation()
    guard !stopped, continuing() else { throw CancellationError() }
    let actor = actor
    return try await withCheckedThrowingContinuation { continuation in
      do {
        try persistence.enqueueCommand(owner: .document(edit.documentID), reservation: reservation,
          cost: cost, { try $0.commitDocumentSource(prepared, actor: actor) },
          completion: { continuation.resume(with: $0) })
        if preparingID == id { preparingID = nil }
      } catch { continuation.resume(throwing: error) }
    }
  }

  private func prepare(edit: DocumentSourceEdit, workspaceID: UUID) async throws -> PreparedDocumentSourceEdit {
    #if DEBUG
      let observer = Self.onPreparationWorker
    #endif
    let worker = Task.detached(priority: .utility) {
      #if DEBUG
        await observer?()
      #endif
      try Task.checkCancellation()
      let prepared = try PreparedDocumentSourceEdit(edit: edit, workspaceID: workspaceID)
      try Task.checkCancellation()
      return prepared
    }
    return try await withTaskCancellationHandler {
      let result = await worker.result
      try Task.checkCancellation()
      return try result.get()
    } onCancel: { worker.cancel() }
  }

  private static func cost(_ value: PreparedDocumentSourceEdit.Cost) -> NotebookPersistenceAdmission.Cost {
    .init(payloadBytes: value.payloadBytes, completionBytes: value.completionBytes)
  }
}

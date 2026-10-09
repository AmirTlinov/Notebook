import Foundation
import NotebookCore
import WebKit

/// One isolated program's state and lifecycle boundary. Physical hosts supply
/// their addressed writer and source basis; paper, board and export share the
/// same freeze, retry, resume and accepted-commit ordering.
@MainActor
final class ProgramSession<Basis: Sendable> {
  struct Checkpoint: Sendable {
    let value: JSONValue
    let basis: Basis
    let selection: ProgramSemanticSelection?
  }
  private struct Frozen {
    let snapshot: NotebookProgramStateTransfer.Checkpoint
    let basis: Basis
  }
  let stateTransfer: NotebookProgramStateTransfer
  private let web: WKWebView
  private let lease: WebSurfaceLease
  private let controller: String
  private let expectedToken: String?
  private let isCurrent: @MainActor () -> Bool
  private var revoked = false
  private var frozen: Frozen?
  private var checkpointTask: Task<Checkpoint, Error>?
  private var finishing: Task<Bool, Error>?
  private var commitsClosed = false
  private var checkpointFailed = false
  private(set) var checkpointed: Checkpoint?
  var isCheckpointing: Bool { checkpointTask != nil }
  var hasPendingCheckpoint: Bool { checkpointFailed || frozen != nil || stateTransfer.hasPendingCheckpoint }

  init(resources: SceneRenderResources, web: WKWebView, lease: WebSurfaceLease,
    controller: String, expectedToken: String? = nil, grantsInitialCredit: Bool = true,
    isCurrent: @escaping @MainActor () -> Bool) {
    self.web = web; self.lease = lease; self.controller = controller
    self.expectedToken = expectedToken; self.isCurrent = isCurrent
    stateTransfer = .init(resources: resources, grantsInitialCredit: grantsInitialCredit)
  }

  private func validate() throws {
    try Task.checkCancellation()
    guard !revoked, isCurrent() else { throw CancellationError() }
  }

  /// The frozen value retains the exact basis which supplied it across disk
  /// retry. A later basis cannot authorize an earlier browser snapshot.
  func checkpoint(prepare: @escaping @MainActor () async throws -> Basis,
    basisAfterFreeze: (@MainActor (Basis) -> Basis)? = nil,
    accepts: @escaping @MainActor (Basis, Basis?) -> Bool,
    persist: @escaping @MainActor (JSONValue, Basis, Int) async throws -> Basis?,
    didAccept: @escaping @MainActor (Checkpoint) -> Void) async throws -> Checkpoint {
    if let checkpointTask { return try await checkpointTask.value }
    if let checkpointed, accepts(checkpointed.basis, checkpointed.basis) { return checkpointed }
    let task = Task { @MainActor [self] in
      var completed = false
      defer { checkpointTask = nil; if !completed { checkpointFailed = true } }
      try validate()
      if let finishing { _ = try await finishing.value }
      let borrow = try lease.borrow(); defer { borrow.release() }
      try await stateTransfer.drain()
      try validate()
      if frozen == nil {
        let basis = try await prepare()
        try validate()
        let descriptor = try await NotebookProgramBridge.lifecycle("checkpoint", controller: controller,
          argument: .object(["retry": .bool(true), "serialized": .bool(true)]), expectedToken: expectedToken, in: web)
        let snapshot = try await stateTransfer.checkpoint(NotebookProgramBridge.stateSnapshot(descriptor)) { [self] revision, offset in
          try await NotebookProgramBridge.readState(revision, offset: offset, controller: controller, expectedToken: expectedToken, in: web)
        }
        try validate()
        frozen = .init(snapshot: snapshot, basis: basisAfterFreeze?(basis) ?? basis)
      }
      guard let frozen, accepts(frozen.basis, nil) else { throw CancellationError() }
      let value = frozen.snapshot.value
      guard let accepted = try await persist(value, frozen.basis, frozen.snapshot.admittedBytes) else {
        throw SceneRenderError.snapshotPending("program_checkpoint_not_accepted")
      }
      try validate()
      guard accepts(frozen.basis, accepted) else { throw CancellationError() }
      let selection = await NotebookProgramBridge.semanticSelection(controller: controller, expectedToken: expectedToken, in: web)
      try validate()
      guard accepts(frozen.basis, accepted) else { throw CancellationError() }
      let result = Checkpoint(value: value, basis: accepted, selection: selection)
      didAccept(result)
      checkpointed = result; checkpointFailed = false; completed = true
      frozen.snapshot.release(); self.frozen = nil
      return result
    }
    checkpointTask = task
    return try await task.value
  }

  /// An unfinished readiness promise cannot discard previously accepted
  /// commits. Every close route joins this same transport boundary.
  func finishAccepted() async throws -> Bool {
    if let finishing { return try await finishing.value }
    let task = Task { @MainActor [self] in
      defer { finishing = nil }
      try validate()
      let borrow = try lease.borrow(); defer { borrow.release() }
      commitsClosed = true
      let hasHeap = try await stateTransfer.finishAccepted(controller: controller, expectedToken: expectedToken, in: web)
      try validate()
      return hasHeap
    }
    finishing = task
    return try await task.value
  }

  func resume(commitsEnabled: Bool = true) async throws {
    if let checkpointTask { _ = try await checkpointTask.value }
    if let finishing { _ = try await finishing.value }
    try validate()
    guard !hasPendingCheckpoint, !stateTransfer.hasFailure else {
      throw SceneRenderError.snapshotPending("program_checkpoint_pending")
    }
    let borrow = try lease.borrow(); defer { borrow.release() }
    _ = try await NotebookProgramBridge.lifecycle("resume", controller: controller, expectedToken: expectedToken, in: web)
    try validate()
    if commitsClosed {
      _ = try await NotebookProgramBridge.lifecycle("setCommitEnabled", controller: controller,
        argument: .bool(commitsEnabled), expectedToken: expectedToken, in: web)
      try validate()
      commitsClosed = false
    }
    checkpointed = nil
  }

  /// Export/seek uses the same isolated controller and actual surface borrow.
  func perform(_ operation: String, argument: JSONValue? = nil) async throws -> JSONValue {
    try validate()
    let borrow = try lease.borrow(); defer { borrow.release() }
    let value = try await NotebookProgramBridge.lifecycle(operation, controller: controller,
      argument: argument, expectedToken: expectedToken, in: web)
    try validate()
    return value
  }

  func awaitCheckpoint() async { _ = try? await checkpointTask?.value }
  func forgetCompletedCheckpoint() { checkpointed = nil }
  func invalidate() {
    guard !revoked else { return }
    revoked = true; checkpointTask?.cancel(); finishing?.cancel()
    stateTransfer.revoke(); checkpointed = nil; frozen = nil
  }
  isolated deinit { invalidate() }
}

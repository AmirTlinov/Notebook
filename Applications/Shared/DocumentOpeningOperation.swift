import Foundation
import NotebookCore

extension DocumentRenderSession {
  /// One accepted document opening. The app supplies storage/publication policy;
  /// this session owns the request, its one physical read and its terminal state.
  @MainActor final class Opening {
    struct Request: Sendable {
      let id = UUID()
      let documentID: UUID
      let boardID: UUID
      let workspaceID: UUID
      let pageIndex: Int
    }
    enum Outcome: Equatable {
      case completed, cancelled, superseded, failed(String)
    }
    enum Phase: Equatable { case reading, preparingSource, completed, cancelled, superseded, failed(String) }
    @MainActor struct Policy {
      let beginRead: () -> (admission: UUID, draftEpoch: UInt64)
      let endRead: (UUID) -> Void
      let fence: (@escaping @MainActor @Sendable (Result<Void, Error>) -> Void) -> Void
      let read: (Request) async throws -> NotebookSceneState.OpenedDocument?
      let isCurrent: (Request) -> Bool
      let waitForPublication: (NotebookSceneState.OpenedDocument, Request) async throws -> Void
      let accepts: (NotebookSceneState.OpenedDocument, Request, UUID) async throws -> Bool
      let publish: (NotebookSceneState.OpenedDocument, Request, UInt64) -> Void
      let failed: (Error) -> Void
      let revoked: (Request) -> Void
      let observe: (String, Request) -> Void
    }
    @MainActor private final class Fence {
      private var result: Result<Void, Error>?
      private var continuation: CheckedContinuation<Void, Error>?
      func finish(_ result: Result<Void, Error>) {
        guard self.result == nil else { return }
        self.result = result
        let continuation = continuation; self.continuation = nil
        continuation?.resume(with: result)
      }
      func wait() async throws {
        if let result { return try result.get() }
        try await withCheckedThrowingContinuation { continuation = $0 }
      }
    }
    private struct Read {
      let admission: UUID
      let draftEpoch: UInt64
      let task: Task<NotebookSceneState.OpenedDocument?, Error>
    }
    let request: Request
    private let session: DocumentRenderSession
    private let store: NotebookStore
    private let policy: Policy
    private var read: Read?
    private(set) var task: Task<Void, Never>?
    private(set) var phase: Phase = .reading
    private(set) var outcome: Outcome?
    private(set) var sourceVersion: VersionStamp?
    private var acceptedSource: DocumentDocument?
    #if os(iOS)
    private var sourcePreparation: DocumentPagePresentationOwner.OpeningPreparation?
    #endif

    init(session: DocumentRenderSession, store: NotebookStore, request: Request, policy: Policy,
      accepted: DocumentDocument? = nil, predecessor: Task<Void, Never>? = nil) {
      precondition(request.documentID == session.documentID)
      self.session = session; self.store = store; self.request = request; self.policy = policy
      if let accepted {
        sourceVersion = accepted.contentStamp
        #if os(iOS)
        prepareSource(accepted)
        #else
        finish(.completed)
        #endif
        if let predecessor {
          task = Task { @MainActor [self] in await predecessor.value; task = nil }
        }
        return
      }
      // Register the first fence in the accepting MainActor segment. A
      // superseding request waits for the previous physical read to drain.
      if predecessor == nil { read = beginRead() }
      task = Task { @MainActor [self] in
        if let predecessor { await predecessor.value }
        await run()
        task = nil
      }
    }

    private func beginRead() -> Read {
      let registration = policy.beginRead(), fence = Fence(), request = request, policy = policy
      policy.observe("opening_body_read_begin", request)
      policy.fence { fence.finish($0) }
      let task = Task { @MainActor in
        // Cancellation releases the reader after its submitted FIFO fence,
        // never by pretending that an earlier accepted writer has completed.
        try await fence.wait()
        try Task.checkCancellation()
        guard policy.isCurrent(request) else { throw CancellationError() }
        let value = try await policy.read(request)
        try Task.checkCancellation()
        return value
      }
      return .init(admission: registration.admission, draftEpoch: registration.draftEpoch, task: task)
    }

    private func run() async {
      while true {
        if read == nil {
          guard outcome == nil, !Task.isCancelled, policy.isCurrent(request) else {
            if outcome == nil { finish(.cancelled) }
            return
          }
          read = beginRead()
        }
        guard let current = read else { return }
        let completion = await current.task.result
        read = nil
        defer { policy.endRead(current.admission) }
        guard outcome == nil, !Task.isCancelled, policy.isCurrent(request) else {
          if outcome == nil { finish(.cancelled) }
          return
        }
        do {
          guard let opened = try completion.get(), opened.header.workspaceID == request.workspaceID else {
            finish(.cancelled); return
          }
          policy.observe("opening_body_read_end", request)
          try await policy.waitForPublication(opened, request)
          try Task.checkCancellation()
          guard outcome == nil, policy.isCurrent(request) else {
            if outcome == nil { finish(.superseded) }; return
          }
          guard try await policy.accepts(opened, request, current.admission) else { continue }
          try Task.checkCancellation()
          guard outcome == nil, policy.isCurrent(request) else {
            if outcome == nil { finish(.superseded) }; return
          }
          phase = .preparingSource
          sourceVersion = opened.document.contentStamp
          #if os(iOS)
          prepareSource(opened.document)
          #endif
          policy.publish(opened, request, current.draftEpoch)
          policy.observe("opening_body_published", request)
          #if !os(iOS)
          finish(.completed)
          #endif
          return
        } catch {
          guard outcome == nil, policy.isCurrent(request) else {
            if outcome == nil { finish(.superseded) }; return
          }
          if error is CancellationError { finish(.cancelled) }
          else { policy.failed(error); finish(.failed(error.localizedDescription)) }
          return
        }
      }
    }

    #if os(iOS)
    private func prepareSource(_ document: DocumentDocument) {
      guard outcome == nil, document.id == request.documentID else { return }
      if sourcePreparation?.matches(document) == true { return }
      sourcePreparation?.onOutcome = { _ in }; sourcePreparation?.close()
      sourceVersion = document.contentStamp
      acceptedSource = document
      phase = .preparingSource
      let owner = DocumentPagePresentationOwner.shared(documentID: request.documentID, resources: .shared)
      sourcePreparation = owner.prepareOpening(document: document, pageIndex: request.pageIndex,
        store: store)
      sourcePreparation?.onOutcome = { [weak self] result in
        guard let self, outcome == nil else { return }
        switch result {
        case .completed: finish(.completed)
        case .cancelled: finish(.cancelled)
        case .superseded: finish(.superseded)
        case .failed(let message): finish(.failed(message))
        }
      }
    }
    #endif

    func sourceDidChange(_ document: DocumentDocument?) {
      guard outcome == nil, let acceptedSource, acceptedSource != document else { return }
      cancel(superseded: true)
    }
    func cancel(superseded: Bool = false) { finish(superseded ? .superseded : .cancelled) }
    private func finish(_ result: Outcome) {
      guard outcome == nil else { return }
      outcome = result
      acceptedSource = nil
      switch result {
      case .completed: phase = .completed
      case .cancelled: phase = .cancelled
      case .superseded: phase = .superseded
      case .failed(let message): phase = .failed(message)
      }
      if result != .completed { read?.task.cancel(); policy.revoked(request) }
      #if os(iOS)
      sourcePreparation?.onOutcome = { _ in }
      sourcePreparation?.close(); sourcePreparation = nil
      #endif
    }
    isolated deinit { read?.task.cancel() }
  }
}

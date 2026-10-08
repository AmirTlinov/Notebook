import Foundation
import NotebookCore
import NotebookCodex

/// The runtime owns one official executor connection. Workspace routes retain
/// their accepted journals; a surface is only a detachable presentation.
@MainActor
final class NotebookCodexHost {
  private var server: CodexAppServer?
  private var scope: CodexRuntimeScope?
  private var accountGeneration = UUID()
  private var changingAccount = false
  private var events: Task<Void, Never>?
  private let workspaceWriters: NotebookWorkspaceWriters?
  private let discoverInstallation: @Sendable () throws -> CodexRuntimeInstallation
  private struct WorkspaceRoute {
    let sidecar: NotebookCodexSidecar
    let persistence: NotebookPersistenceQueue
  }
  private var routes: [UUID: WorkspaceRoute] = [:]

  init(workspaceWriters: NotebookWorkspaceWriters? = nil,
    discoverInstallation: @escaping @Sendable () throws -> CodexRuntimeInstallation = { try CodexRuntimeInstallation.discover() }) {
    self.workspaceWriters = workspaceWriters
    self.discoverInstallation = discoverInstallation
  }

  deinit { events?.cancel() }

  #if DEBUG
    /// Native acceptance installs a concrete already owned route. It uses the
    /// real sidecar/file worker and never starts an external Codex process.
    convenience init(workspaceID: UUID, sidecar: NotebookCodexSidecar, persistence: NotebookPersistenceQueue) {
      self.init()
      admitFixtureRoute(workspaceID: workspaceID, sidecar: sidecar, persistence: persistence)
    }
    func admitFixtureRoute(workspaceID: UUID, sidecar: NotebookCodexSidecar, persistence: NotebookPersistenceQueue) {
      precondition(routes[workspaceID] == nil && server == nil)
      routes[workspaceID] = .init(sidecar: sidecar, persistence: persistence)
    }
  #endif

  private var persistenceQueues: [NotebookPersistenceQueue] {
    workspaceWriters?.persistenceQueues ?? routes.values.map(\.persistence)
  }

  func workspace(persistence: NotebookPersistenceQueue,
    workspaceID: UUID, computerID: UUID, directory: URL, scope: CodexRuntimeScope?,
    entry: URL, socket: URL, isWorkspaceOpen: @escaping () -> Bool,
    authorizePeer: @escaping (UUID) -> Bool, publish: @escaping (NotebookChatEnvelope, UUID) -> Void) async throws -> NotebookCodexSidecar {
    guard isWorkspaceOpen() else { throw CodexBridgeError.unavailable }
    if let route = routes[workspaceID] {
      guard route.persistence === persistence else { throw CodexBridgeError.unsafeEndpoint }
      route.sidecar.authorizePeer = authorizePeer; route.sidecar.attachView(publish: publish)
      return route.sidecar
    }
    if server != nil, self.scope != scope { throw CodexBridgeError.unsafeEndpoint }
    if server == nil {
      let installation = try await Task.detached(priority: .userInitiated, operation: discoverInstallation).value
      guard isWorkspaceOpen() else { throw CodexBridgeError.unavailable }
      if server == nil {
        server = CodexAppServer(installation: installation, scope: scope); self.scope = scope
      }
      guard self.scope == scope else { throw CodexBridgeError.unsafeEndpoint }
    }
    if events == nil, let owner = server {
      events = Task { [weak self] in
        for await _ in owner.events {
          guard let self, !Task.isCancelled, server === owner else { break }
          let pending = await owner.drainEvents()
          guard !Task.isCancelled, server === owner else { break }
          for event in pending {
            for route in routes.values { route.sidecar.receiveEvent(event) }
          }
        }
      }
    }
    guard let owner = server else { throw CodexBridgeError.unavailable }
    try await owner.registerWorkspace(workspaceID, entry: entry, socket: socket)
    // Admission can close while registration suspends. Only a live workspace
    // may attach a presentation or start recovering its accepted journal.
    guard server === owner, isWorkspaceOpen() else {
      // A concurrent attachment may already own this registration. Otherwise
      // release the exact executor's slot, including after host shutdown.
      if server !== owner || routes[workspaceID] == nil {
        try await owner.unregisterWorkspace(workspaceID)
      }
      throw CodexBridgeError.unavailable
    }
    if let route = routes[workspaceID] {
      guard route.persistence === persistence else { throw CodexBridgeError.unsafeEndpoint }
      route.sidecar.authorizePeer = authorizePeer; route.sidecar.attachView(publish: publish)
      return route.sidecar
    }
    let route = NotebookCodexSidecar(persistence: persistence, server: owner, workspaceID: workspaceID,
      computerID: computerID, directory: directory, publish: publish)
    route.authorizePeer = authorizePeer
    route.prepareThread = { thread in try await owner.bindWorkspace(workspaceID, threadID: thread) }
    route.accountAdmission = { [weak self] in
      guard let self, !changingAccount else { return nil }; return accountGeneration
    }
    route.accountIdentity = {
      try await owner.account(.read, includeLimits: false).account?.identity
    }
    route.accountRequest = { [weak self] query in
      guard let self else { throw CodexBridgeError.unavailable }
      return try await self.account(query)
    }
    routes[workspaceID] = .init(sidecar: route, persistence: persistence)
    route.start()
    return route
  }

  /// Deletion must not discard journals still receiving output or approvals.
  func removeWorkspace(_ id: UUID) async throws {
    guard let route = routes[id] else {
      try await server?.unregisterWorkspace(id)
      return
    }
    let pending = try await route.persistence.submit { try !$0.pendingChatJobs().isEmpty || !$0.activeRuns().isEmpty }
    guard !pending, await server?.hasActiveWork(workspace: id) != true else { throw CodexBridgeError.busy }
    try await server?.unregisterWorkspace(id)
    await route.sidecar.stop()
    routes.removeValue(forKey: id)
    guard await route.persistence.flush() else { throw NotebookTransportError.storageUnavailable }
  }

  func account(_ query: CodexAccountQuery) async throws -> CodexAccountState {
    if server == nil {
      let installation = try await Task.detached(priority: .userInitiated, operation: discoverInstallation).value
      if server == nil { server = CodexAppServer(installation: installation) }
    }
    let mutating: Bool
    if case .read = query { mutating = false } else { mutating = true }
    if mutating {
      guard !changingAccount else { throw CodexBridgeError.busy }
      changingAccount = true; accountGeneration = UUID()
    }
    defer { if mutating { changingAccount = false } }
    if mutating {
      for writer in persistenceQueues {
        guard try await writer.submit({ try !$0.pendingChatJobs().contains(where: { $0.state == .saved || $0.state == .attempting }) }) else { throw CodexBridgeError.busy }
      }
    }
    return try await server!.account(query)
  }

  func hasActiveWork(workspace: UUID) async -> Bool {
    if routes[workspace]?.sidecar.hasPendingFileWork == true { return true }
    if let route = routes[workspace],
      (try? await route.persistence.submit({ try !$0.pendingChatJobs().isEmpty || !$0.activeRuns().isEmpty })) != false { return true }
    return await server?.hasActiveWork(workspace: workspace) ?? false
  }
  // Checked in the same MainActor turn as the source seal. A timed-out reply
  // may still own a physical effect and its original journal completion.
  func hasPendingFileWork(workspace: UUID) -> Bool {
    routes[workspace]?.sidecar.hasPendingFileWork == true
  }
  func hasActiveWork() async -> Bool {
    if routes.values.contains(where: { $0.sidecar.hasPendingFileWork }) { return true }
    for writer in persistenceQueues {
      if (try? await writer.submit({ try !$0.pendingChatJobs().isEmpty || !$0.activeRuns().isEmpty })) != false { return true }
    }
    return await server?.hasActiveWork() ?? false
  }

  func shutdown() async {
    for route in routes.values { await route.sidecar.stop() }
    await server?.close()
    events?.cancel(); events = nil; routes.removeAll(); server = nil
  }
}

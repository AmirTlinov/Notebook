import Foundation
import NotebookCore
import NotebookCodex

/// The Mac application owns one official executor connection. Workspace routes
/// retain their accepted journals; a window is only a detachable presentation.
@MainActor
final class NotebookCodexHost {
  private var server: CodexAppServer?
  private var scope: CodexRuntimeScope?
  private var accountGeneration = UUID()
  private var changingAccount = false
  private var events: Task<Void, Never>?
  private let workspaceWriters: NotebookWorkspaceWriters?
  private struct WorkspaceRoute {
    let sidecar: NotebookCodexSidecar
    let persistence: NotebookPersistenceQueue
  }
  private var routes: [UUID: WorkspaceRoute] = [:]

  init(workspaceWriters: NotebookWorkspaceWriters? = nil) {
    self.workspaceWriters = workspaceWriters
  }

  private var persistenceQueues: [NotebookPersistenceQueue] {
    workspaceWriters?.persistenceQueues ?? routes.values.map(\.persistence)
  }

  func workspace(persistence: NotebookPersistenceQueue, installation: CodexRuntimeInstallation,
    workspaceID: UUID, computerID: UUID, directory: URL, scope: CodexRuntimeScope?,
    entry: URL, socket: URL, authorizePeer: @escaping (UUID) -> Bool, publish: @escaping (NotebookChatEnvelope, UUID) -> Void) async throws -> NotebookCodexSidecar {
    if let route = routes[workspaceID] {
      guard route.persistence === persistence else { throw CodexBridgeError.unsafeEndpoint }
      route.sidecar.authorizePeer = authorizePeer; route.sidecar.attachView(publish: publish)
      return route.sidecar
    }
    if server != nil, self.scope != scope { throw CodexBridgeError.unsafeEndpoint }
    if server == nil {
      let owner = CodexAppServer(installation: installation, scope: scope)
      server = owner; self.scope = scope
    }
    if events == nil, let owner = server {
      events = Task { [weak self] in
        for await event in owner.events {
          guard let self, !Task.isCancelled else { break }
          for route in routes.values { route.sidecar.receiveEvent(event) }
        }
      }
    }
    try await server!.registerWorkspace(workspaceID, entry: entry, socket: socket)
    // Registration suspends; another window may already have installed this route.
    if let route = routes[workspaceID] {
      guard route.persistence === persistence else { throw CodexBridgeError.unsafeEndpoint }
      route.sidecar.authorizePeer = authorizePeer; route.sidecar.attachView(publish: publish)
      return route.sidecar
    }
    let route = NotebookCodexSidecar(persistence: persistence, server: server!, workspaceID: workspaceID,
      computerID: computerID, directory: directory, publish: publish)
    route.authorizePeer = authorizePeer
    route.prepareThread = { [server] thread in try await server?.bindWorkspace(workspaceID, threadID: thread) }
    route.accountAdmission = { [weak self] in
      guard let self, !changingAccount else { return nil }; return accountGeneration
    }
    route.accountIdentity = { [server] in
      guard let server else { throw CodexBridgeError.unavailable }
      return try await server.account(.read, includeLimits: false).account?.identity
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
    if let route = routes[id] {
      let pending = try await route.persistence.submit { try !$0.pendingChatJobs().isEmpty || !$0.activeRuns().isEmpty }
      guard !pending, await server?.hasActiveWork(workspace: id) != true else { throw CodexBridgeError.busy }
      try await server?.unregisterWorkspace(id)
      await route.sidecar.stop()
      routes.removeValue(forKey: id)
      guard await route.persistence.flush() else { throw NotebookTransportError.storageUnavailable }
    }
  }

  func account(_ query: CodexAccountQuery) async throws -> CodexAccountState {
    if server == nil {
      let installation = try await Task.detached(priority: .userInitiated) { try CodexRuntimeInstallation.discover() }.value
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
    if let route = routes[workspace],
      (try? await route.persistence.submit({ try !$0.pendingChatJobs().isEmpty || !$0.activeRuns().isEmpty })) != false { return true }
    return await server?.hasActiveWork(workspace: workspace) ?? false
  }
  func hasActiveWork() async -> Bool {
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

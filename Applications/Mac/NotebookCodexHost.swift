import Foundation
import NotebookCore
import NotebookCodex

/// The Mac application owns one official executor connection. Workspace routes
/// retain their accepted journals; a window is only a detachable presentation.
@MainActor
final class NotebookCodexHost {
  private var server: CodexAppServer?
  private var scope: CodexRuntimeScope?
  private var events: Task<Void, Never>?
  private var routes: [UUID: NotebookCodexSidecar] = [:]
  private var writers: [URL: NotebookPersistenceQueue] = [:]
  private var roots: [UUID: URL] = [:]

  func persistence(for store: NotebookStore) -> NotebookPersistenceQueue {
    let root = store.root.standardizedFileURL.resolvingSymlinksInPath()
    if let writer = writers[root] { return writer }
    let writer = NotebookPersistenceQueue(store: store); writers[root] = writer
    return writer
  }

  func workspace(store: NotebookStore, persistence: NotebookPersistenceQueue, installation: CodexRuntimeInstallation,
    workspaceID: UUID, computerID: UUID, directory: URL, scope: CodexRuntimeScope?,
    entry: URL, socket: URL, authorizePeer: @escaping (UUID) -> Bool, publish: @escaping (NotebookChatEnvelope, UUID) -> Void) async throws -> NotebookCodexSidecar {
    if let route = routes[workspaceID] { route.authorizePeer = authorizePeer; route.attachView(publish: publish); return route }
    if server != nil, self.scope != scope { throw CodexBridgeError.unsafeEndpoint }
    if server == nil {
      let owner = CodexAppServer(installation: installation, scope: scope)
      server = owner; self.scope = scope
    }
    if events == nil, let owner = server {
      events = Task { [weak self] in
        for await event in owner.events {
          guard let self, !Task.isCancelled else { break }
          for route in routes.values { route.receiveEvent(event) }
        }
      }
    }
    try await server!.registerWorkspace(workspaceID, entry: entry, socket: socket)
    // Registration suspends; another window may already have installed this route.
    if let route = routes[workspaceID] { route.authorizePeer = authorizePeer; route.attachView(publish: publish); return route }
    let route = NotebookCodexSidecar(persistence: persistence, server: server!, workspaceID: workspaceID,
      computerID: computerID, directory: directory, publish: publish)
    route.authorizePeer = authorizePeer
    route.prepareThread = { [server] thread in try await server?.bindWorkspace(workspaceID, threadID: thread) }
    route.accountIdentity = { [server] in
      guard let server else { throw CodexBridgeError.unavailable }
      return try await server.account(.read, includeLimits: false).account?.identity
    }
    route.accountRequest = { [weak self] query in
      guard let self else { throw CodexBridgeError.unavailable }
      return try await self.account(query)
    }
    routes[workspaceID] = route; roots[workspaceID] = store.root.standardizedFileURL.resolvingSymlinksInPath()
    route.start()
    return route
  }

  /// Deletion must not discard journals still receiving output or approvals.
  func removeWorkspace(_ id: UUID) async throws {
    if let root = roots[id], let writer = writers[root] {
      let pending = try await writer.submit { try !$0.pendingChatJobs().isEmpty || !$0.activeRuns().isEmpty }
      guard !pending, await server?.hasActiveWork(workspace: id) != true else { throw CodexBridgeError.busy }
      try await server?.unregisterWorkspace(id)
      await routes[id]?.stop(); routes.removeValue(forKey: id); roots.removeValue(forKey: id)
      guard await writer.flush() else { throw NotebookTransportError.storageUnavailable }
      writers.removeValue(forKey: root)
    }
  }

  func account(_ query: CodexAccountQuery) async throws -> CodexAccountState {
    if server == nil {
      let installation = try await Task.detached(priority: .userInitiated) { try CodexRuntimeInstallation.discover() }.value
      if server == nil { server = CodexAppServer(installation: installation) }
    }
    if case .read = query {} else {
      for writer in writers.values {
        guard try await writer.submit({ try !$0.pendingChatJobs().contains(where: { $0.state == .saved || $0.state == .attempting }) }) else { throw CodexBridgeError.busy }
      }
    }
    return try await server!.account(query)
  }

  func hasActiveWork(workspace: UUID) async -> Bool {
    if let root = roots[workspace], let writer = writers[root],
      (try? await writer.submit({ try !$0.pendingChatJobs().isEmpty || !$0.activeRuns().isEmpty })) != false { return true }
    return await server?.hasActiveWork(workspace: workspace) ?? false
  }
  func hasActiveWork() async -> Bool {
    for writer in writers.values {
      if (try? await writer.submit({ try !$0.pendingChatJobs().isEmpty || !$0.activeRuns().isEmpty })) != false { return true }
    }
    return await server?.hasActiveWork() ?? false
  }

  func shutdown() async {
    for route in routes.values { await route.stop() }
    await server?.close()
    events?.cancel(); events = nil; routes.removeAll(); server = nil
    for writer in writers.values { _ = await writer.flush() }
    writers.removeAll(); roots.removeAll()
  }
}

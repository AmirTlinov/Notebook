import Foundation
import NotebookCore

enum NotebookWorkspaceLoadState: Equatable {
  case loading, ready, failed(String)
}

enum NotebookWorkspaceShutdownPhase: Equatable {
  case running, closing, draining, stopped
}

enum NotebookPersistenceBoundary {
  case acceptedInput, quiescent
}

struct NotebookWorkspaceTransition: Equatable {
  let id: UUID
  let workspaceID: UUID
  let cursor: UInt64
  let inputGeneration: UInt64
  let mutationGeneration: UInt64
}

/// The catalog opens an admitted workspace without selecting a presentation.
/// Native surfaces and the headless runtime borrow the same writer registry.
struct NotebookWorkspaceOpenConfiguration {
  let store: NotebookStore
  let persistence: NotebookPersistenceQueue
  let commandSocketURL: URL?
  let allowsCodexRegistration: Bool
  let pairingActivationID: UUID?
  let opensDefaultAccountWorkspace: Bool
  let requiresExistingAccountContent: Bool
  let expectedWorkspaceID: UUID?
  var preferences: UserDefaults = .standard
  var pairingService: String? = nil
  var acceptance: NotebookAcceptanceConfiguration? = nil
}

/// Admission, catalog selection and drain are shared by native and headless
/// owners. A camera, input device or mounted scene is not part of this boundary.
@MainActor
protocol NotebookWorkspaceLifecycle: AnyObject, Sendable {
  static var defaultPageSize: PageSize { get }
  static func open(_ configuration: NotebookWorkspaceOpenConfiguration) -> Self
  var workspaceRuntime: NotebookWorkspaceRuntime { get }
  var store: NotebookStore { get }
  var admittedWorkspaceID: UUID? { get }
  var loadState: NotebookWorkspaceLoadState { get }
  var shutdownPhase: NotebookWorkspaceShutdownPhase { get }
  var awaitingAccountContent: Bool { get }
  var persistenceFailure: String? { get }
  var workspaceName: String { get set }
  var publishesWorkspaceName: Bool { get set }
  var accountConnection: NotebookAccountConnection? { get }
  var accountWorkspaceNameSaved: (@MainActor (String, Set<UUID>) async -> Void)? { get set }
  var workspaceDeleted: (@MainActor () -> Void)? { get set }
  var openDefaultAccountWorkspace: (@MainActor (UUID) -> Void)? { get set }
  var allowsCodexRegistration: Bool { get }
  var acceptance: NotebookAcceptanceConfiguration? { get }
  func admitWorkspaceIdentity(_ id: UUID) throws
  func start(pageSize: PageSize) async
  func finishStartup() async
  func refreshDeviceConnection()
  func retryPendingPersistence()
  func prepareAutomaticWorkspaceSwitch() async -> NotebookWorkspaceTransition?
  func freezeAutomaticWorkspaceSwitch(_ transition: NotebookWorkspaceTransition) async throws -> Bool
  func commitAutomaticWorkspaceSwitch(_ transition: NotebookWorkspaceTransition)
  func rollbackAutomaticWorkspaceSwitch(_ transition: NotebookWorkspaceTransition)
  func freezeManualWorkspaceSelection() -> UUID?
  func finishManualWorkspaceSelection(_ id: UUID)
  func finishPendingInteraction(boundary: NotebookPersistenceBoundary,
    continuing: @MainActor () -> Bool) async -> Bool
  func waitForPersistenceLifecycle<Value: Sendable>(_ task: Task<Value, Never>) async
    -> NotebookPersistenceQueue.LifecycleResult<Value>
  func shutdown() async -> Bool
  #if os(macOS)
  var codexHost: NotebookCodexHost? { get set }
  var runtimeSocketKey: String? { get }
  var runtimeStartupPending: Bool { get }
  var agentStartupError: String? { get }
  func startCodexSidecar() async
  func executeLocalCommand(_ command: NotebookCommand) async throws -> JSONValue
  #endif
}

extension NotebookWorkspaceLifecycle {
  func finishPendingInteraction(boundary: NotebookPersistenceBoundary = .quiescent) async -> Bool {
    await finishPendingInteraction(boundary: boundary, continuing: { true })
  }
}

extension NotebookAppModel {
  func start(pageSize: PageSize) async { await start(pageSize: pageSize, viewport: nil) }
  static func open(_ configuration: NotebookWorkspaceOpenConfiguration) -> NotebookAppModel {
    .init(store: configuration.store, commandSocketURL: configuration.commandSocketURL,
      allowsCodexRegistration: configuration.allowsCodexRegistration,
      pairingActivationID: configuration.pairingActivationID,
      preferences: configuration.preferences, pairingService: configuration.pairingService,
      opensDefaultAccountWorkspace: configuration.opensDefaultAccountWorkspace,
      requiresExistingAccountContent: configuration.requiresExistingAccountContent,
      expectedWorkspaceID: configuration.expectedWorkspaceID,
      acceptance: configuration.acceptance, persistenceQueue: configuration.persistence)
  }
}

/// Bootstrap identity is shared by admitted native and headless owners.
enum NotebookWorkspaceIdentity {
  static let initialNotebookID = UUID(uuidString: "7E7A0000-0000-4000-8000-000000000001")!
  static let initialPageID = UUID(uuidString: "7E7A0000-0000-4000-8000-000000000002")!
  static let defaultPageSize = PageSize(width: WorkspaceItemGeometry.notebook.width,
    height: WorkspaceItemGeometry.notebook.height)
  static func actor(defaults: UserDefaults) -> UUID {
    let key = "notebook.actor-id"
    if let raw = defaults.string(forKey: key), let id = UUID(uuidString: raw) { return id }
    let id = UUID(); defaults.set(id.uuidString, forKey: key); return id
  }
}

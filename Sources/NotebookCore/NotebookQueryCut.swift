import Foundation

/// A synchronous borrow of one admitted SQLite read snapshot. It exposes only
/// domain reads; retaining the value cannot retain or reopen its snapshot.
public struct NotebookQueryCut {
  private let store: NotebookStore
  private let connection: NotebookSQLConnection
  private let identity: UUID

  init(store: NotebookStore, connection: NotebookSQLConnection, identity: UUID) {
    self.store = store; self.connection = connection; self.identity = identity
  }

  private func requireActive() throws {
    guard store.currentSQL === connection, !connection.writable,
      connection.readSnapshotIdentity == identity else {
      throw CollaborationError("read_cut_expired", "Чтение принадлежит завершённому или другому снимку Notebook.")
    }
    try connection.checkReadAllowance()
  }

  public func handle(_ command: NotebookReadCommand, nativeActor: UUID? = nil) throws -> JSONValue {
    try requireActive()
    return try NotebookCommandDispatcher(store: store, nativeActor: nativeActor).handleRead(command)
  }

  public func storedWorkspaceID() throws -> UUID {
    try requireActive(); return try store.storedWorkspaceID()
  }
  public func workspaceHeader() throws -> NotebookWorkspaceHeader {
    try requireActive(); return try store.workspaceHeader()
  }
  public func readObservedPresenceIfAvailable() throws -> SessionPresence? {
    try requireActive(); return try store.readObservedPresenceIfAvailable()
  }
  public func readSelectionPublication() throws -> NotebookSelectionSnapshot {
    try requireActive(); return try store.readSelectionPublication()
  }
  public func observeContent(scope: NotebookObservationScope, since: String? = nil, next: String? = nil,
    limit: Int = 32) throws -> NotebookObservation {
    try requireActive(); return try store.observeContent(scope: scope, since: since, next: next, limit: limit)
  }
  public func readItemHeader(_ id: UUID) throws -> NotebookItemHeader? {
    try requireActive(); return try store.readItemHeader(id)
  }
  public func referenceRevision(target: CollaborationTarget, elementID: String? = nil) throws -> String {
    try requireActive(); return try store.referenceRevision(target: target, elementID: elementID)
  }
  public func readPanel(_ request: NotebookPanelReadRequest, actor: UUID) throws -> JSONValue {
    try requireActive(); return try store.readPanel(request, actor: actor)
  }
  public func requestPanelPresentation(_ request: NotebookPanelPresentationRequest) throws -> NotebookPanelPresentationCut {
    try requireActive(); return try store.requestPanelPresentation(request)
  }
  public func loadPage(_ id: UUID) throws -> PageDocument {
    try requireActive(); return try store.loadPage(id)
  }
  public func readBoardNodeHeader(_ id: UUID) throws -> BoardNode? {
    try requireActive(); return try store.readBoardNodeHeader(id)
  }
  public func readBoardItem(_ id: UUID) throws -> BoardNode? {
    try requireActive(); return try store.readBoardItem(id)
  }
  public func boardHasContent(_ id: UUID) throws -> Bool {
    try requireActive(); return try store.boardHasContent(id)
  }
  public func readCurrentScenePaintOrder(boardID: UUID, coverID: UUID? = nil, bounds: WorkspaceSpatialBounds,
    after: NotebookScenePaintPosition? = nil, limit: Int = 32,
    groupPoses: [String: NotebookElementPlacement.Source] = [:]) throws -> NotebookScenePaintPage {
    try requireActive()
    return try store.readCurrentScenePaintOrder(boardID: boardID, coverID: coverID, bounds: bounds,
      after: after, limit: limit, groupPoses: groupPoses)
  }
  public func spatialInkHistoryStates(ids: Set<UUID>) throws -> [UUID: NotebookSpatialInkHistoryState] {
    try requireActive(); return try store.spatialInkHistoryStates(ids: ids)
  }
  public func sceneRecordsAreCurrent(_ dependencies: NotebookSceneRecordDependencies) throws -> Bool {
    try requireActive(); return try dependencies.isCurrent(store)
  }
  public func spatialInkRecordsAreCurrent(_ records: NotebookSpatialInkWindowRecords) throws -> Bool {
    try requireActive(); return try records.isCurrent(store)
  }
  public func presenceGeneration() throws -> String {
    try requireActive(); return try store.presenceGeneration()
  }
  public func sharedContexts(contextID: UUID?, limit: Int = 64, afterContextID: UUID? = nil,
    expectedCursor: String? = nil) throws -> SharedContextDirectory {
    try requireActive()
    return try store.sharedContexts(contextID: contextID, limit: limit, afterContextID: afterContextID, expectedCursor: expectedCursor)
  }
  public func loadCurrentViewReceipt() throws -> CurrentViewReceipt? {
    try requireActive(); return try store.loadCurrentViewReceipt()
  }
  public func readContentHeader(target: CollaborationTarget) throws -> NotebookContentHeader {
    try requireActive(); return try store.readContentHeader(target: target)
  }
  public func readBasis(targets: [CollaborationTarget], includeSource: Bool = false) throws -> NotebookReadBasis {
    try requireActive(); return try store.readBasis(targets: targets, includeSource: includeSource)
  }
  public func currentReadCursor() throws -> UInt64 {
    try requireActive(); return try store.currentReadCursor()
  }
  public func scriptExportJob(_ id: UUID) throws -> JSONValue? {
    try requireActive(); return try store.scriptExportJob(id)
  }
  public func readDocumentExportCut(documentID: UUID, options: NotebookExportOptions) throws -> NotebookExportCut {
    try requireActive(); return try store.readDocumentExportCut(documentID: documentID, options: options)
  }
  public func expectations(base: NotebookReadBasis, operations: [CollaborationOperation]) throws -> [CollaborationExpectation] {
    try requireActive(); return try store.expectations(base: base, operations: operations)
  }
  public func unfinishedScriptEffects(after: UUID? = nil, limit: Int = 64) throws -> [NotebookScriptEffectAddress] {
    try requireActive(); return try store.unfinishedScriptEffects(after: after, limit: limit)
  }
  public func unfinishedScriptRuns() throws -> [NotebookScriptRun] {
    try requireActive(); return try store.unfinishedScriptRuns()
  }
  public func scriptRunPage(_ id: UUID, after: Int = 0) throws -> JSONValue {
    try requireActive(); return try store.scriptRunPage(id, after: after)
  }
  public func attentionEvidence(contextID: UUID, referenceID: UUID) throws -> AgentPinnedSource? {
    try requireActive(); return try store.attentionEvidence(contextID: contextID, referenceID: referenceID)
  }
}

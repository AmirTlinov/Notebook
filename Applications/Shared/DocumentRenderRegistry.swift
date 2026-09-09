import Foundation
import NotebookCore
import Observation

struct DocumentBlockRegion: Equatable {
  let id: String
  let pageIndex: Int
  let frame: PageRect
}

/// The actual WebKit layout names the block fragments on each physical sheet.
@MainActor
@Observable
final class DocumentRenderRegistry {
  static let shared = DocumentRenderRegistry()
  struct Entry {
    let token: String
    let pageIndex: Int
    let layout: DocumentLayoutRecord
    var regions: [DocumentBlockRegion] { layout.regions }
    let diagnostics: [RenderDiagnostic]
  }
  private var entries: [UUID: [Entry]] = [:]
  private struct SessionKey: Hashable {
    let documentID: UUID
    let resources: ObjectIdentifier
  }
  private final class WeakSession {
    weak var value: DocumentRenderSession?
    init(_ value: DocumentRenderSession) { self.value = value }
  }
  @ObservationIgnored private var sessions: [SessionKey: WeakSession] = [:]

  func session(documentID: UUID, resources: SceneRenderResources) -> DocumentRenderSession {
    let key = SessionKey(documentID: documentID, resources: ObjectIdentifier(resources))
    if let value = sessions[key]?.value { return value }
    sessions = sessions.filter { $0.value.value != nil }
    let value = DocumentRenderSession(documentID: documentID)
    sessions[key] = WeakSession(value)
    return value
  }
  private struct LiveSurface {
    let documentID: UUID
    let token: String
    let pageIndex: Int
    let generation: UInt64
    let isAttached: @MainActor () -> Bool
  }
  @ObservationIgnored private var liveSurfaces: [UUID: LiveSurface] = [:]
  private final class Renderer {
    weak var value: DocumentWebCoordinator?
    init(_ value: DocumentWebCoordinator) { self.value = value }
  }
  @ObservationIgnored private var renderers: [UUID: Renderer] = [:]
  @ObservationIgnored private var editingOwners: [UUID: UUID] = [:]
  @ObservationIgnored private var editingTransfers: [UUID: Task<Void, Never>] = [:]
  @ObservationIgnored private var editingGenerations: [UUID: UInt64] = [:]
  @ObservationIgnored private var editingDrafts: [UUID: [UUID: DocumentEditingSession]] = [:]
  @ObservationIgnored private var finishedDrafts: [UUID: Set<UUID>] = [:]
  private struct SourceEditTask {
    let documentID: UUID
    let task: Task<Void, Never>
  }
  @ObservationIgnored private var sourceEdits: [UUID: SourceEditTask] = [:]

  func mountRenderer(_ renderer: DocumentWebCoordinator, hostID: UUID) {
    guard renderers[hostID]?.value !== renderer else { return }
    renderers = renderers.filter { $0.value.value != nil }
    renderers[hostID] = Renderer(renderer)
  }

  func unmountRenderer(hostID: UUID) {
    guard renderers[hostID] != nil else { return }
    let documentID = renderers[hostID]?.value?.payload?.documentID
    for documentID in editingOwners.keys.filter({ editingOwners[$0] == hostID }) {
      setEditingOwner(documentID: documentID, hostID: hostID, active: false)
    }
    renderers[hostID] = nil
    if let documentID { releaseEditingIfUnmounted(documentID) }
  }

  /// Page curl keeps several renderers alive, but only its current host can
  /// publish text. A handoff drains the prior textarea before restoring another.
  func setEditingOwner(documentID: UUID, hostID: UUID, active: Bool) {
    let previousID = editingOwners[documentID]
    guard active ? previousID != hostID : previousID == hostID else { return }
    let previous = previousID.flatMap { renderers[$0]?.value }
    previous?.revokeEditingOwnership()
    editingOwners[documentID] = active ? hostID : nil
    let generation = (editingGenerations[documentID] ?? 0) &+ 1
    editingGenerations[documentID] = generation
    let preceding = editingTransfers[documentID]
    if previous == nil, preceding == nil, active, !sourceEdits.values.contains(where: { $0.documentID == documentID }) {
      renderers[hostID]?.value?.activateEditing(drafts: Array(editingDrafts[documentID, default: [:]].values))
      return
    }
    editingTransfers[documentID] = Task { @MainActor [weak self] in
      await preceding?.value
      if let previous { await previous.flushEditingDraft() }
      guard let self else { return }
      for source in Array(sourceEdits.values).filter({ $0.documentID == documentID }) { await source.task.value }
      guard editingGenerations[documentID] == generation else { return }
      editingTransfers[documentID] = nil
      if active, editingOwners[documentID] == hostID {
        renderers[hostID]?.value?.activateEditing(drafts: Array(editingDrafts[documentID, default: [:]].values))
      }
      releaseEditingIfUnmounted(documentID)
    }
  }

  @discardableResult
  func recordDraft(_ draft: DocumentEditingSession) -> Bool {
    let documentID = draft.edit.documentID
    guard !isDraftFinished(documentID: documentID, sessionID: draft.id) else { return false }
    guard editingDrafts[documentID]?[draft.id].map({ $0.edit.sequence >= draft.edit.sequence }) != true else { return true }
    editingDrafts[documentID, default: [:]][draft.id] = draft
    return true
  }

  func removeDraft(documentID: UUID, sessionID: UUID) {
    finishedDrafts[documentID, default: []].insert(sessionID)
    editingDrafts[documentID]?[sessionID] = nil
    for renderer in renderers.values where renderer.value?.payload?.documentID == documentID {
      renderer.value?.removeEditingDraft(sessionID)
    }
  }

  func isDraftFinished(documentID: UUID, sessionID: UUID) -> Bool {
    finishedDrafts[documentID]?.contains(sessionID) == true
  }

  func commitSource(_ edit: DocumentSourceEdit,
    using commit: @escaping (DocumentSourceEdit) async throws -> DocumentSourceCommitResult.Status) {
    guard sourceEdits[edit.sessionID] == nil, !isDraftFinished(documentID: edit.documentID, sessionID: edit.sessionID) else { return }
    let task = Task { @MainActor [weak self] in
      let status: String
      do { status = try await commit(edit).rawValue } catch { status = "error" }
      guard let self else { return }
      if status == "committed" { removeDraft(documentID: edit.documentID, sessionID: edit.sessionID) }
      for renderer in renderers.values where renderer.value?.payload?.documentID == edit.documentID {
        renderer.value?.completeSourceEdit(edit, status: status)
      }
      sourceEdits[edit.sessionID] = nil
      releaseEditingIfUnmounted(edit.documentID)
    }
    sourceEdits[edit.sessionID] = .init(documentID: edit.documentID, task: task)
  }

  private func releaseEditingIfUnmounted(_ documentID: UUID) {
    guard editingTransfers[documentID] == nil, !sourceEdits.values.contains(where: { $0.documentID == documentID }),
      !renderers.values.contains(where: { $0.value?.payload?.documentID == documentID && $0.value?.isInvalidated == false }) else { return }
    editingOwners[documentID] = nil; editingGenerations[documentID] = nil
    editingDrafts[documentID] = nil; finishedDrafts[documentID] = nil
  }

  func rasterProducer(documentID: UUID, token: String, resources: SceneRenderResources, excluding hostID: UUID) -> DocumentWebCoordinator? {
    renderers.first { id, renderer in
      id != hostID && renderer.value?.canShareSnapshot == true
        && renderer.value?.resourceOwner === resources
        && renderer.value?.payload?.documentID == documentID && renderer.value?.payload?.renderToken == token
    }?.value.value
  }

  /// Layout history can resolve an address, but only the exact mounted current
  /// surface can confirm what the person is seeing now.
  func hasLiveSurface(document: DocumentDocument, state: DocumentStateJournal, pageIndex: Int) -> Bool {
    let token = DocumentSnapshotCache.token(document: document, state: state, pageIndex: pageIndex)
    return liveSurfaces.values.contains {
      $0.documentID == document.id && $0.token == token && $0.pageIndex == pageIndex && $0.isAttached()
    }
  }

  func publishLive(documentID: UUID, token: String, pageIndex: Int, hostID: UUID, generation: UInt64,
    isAttached: @escaping @MainActor () -> Bool) {
    if let previous = liveSurfaces[hostID], previous.generation > generation { return }
    liveSurfaces[hostID] = .init(documentID: documentID, token: token, pageIndex: pageIndex,
      generation: generation, isAttached: isAttached)
  }

  func revokeLive(hostID: UUID, through generation: UInt64) {
    guard let previous = liveSurfaces[hostID], previous.generation <= generation else { return }
    liveSurfaces[hostID] = nil
  }

  func entry(document: DocumentDocument, state: DocumentStateJournal, pageIndex: Int) -> Entry? {
    let token = "\(document.contentStamp.revision)|\(state.stamp.revision)"
    return entries[document.id]?.last { $0.token.hasPrefix(token) && $0.pageIndex == pageIndex }
  }

  func regions(document: DocumentDocument, state: DocumentStateJournal) -> [DocumentBlockRegion] {
    let token = "\(document.contentStamp.revision)|\(state.stamp.revision)"
    return entries[document.id]?.last(where: { $0.token.hasPrefix(token) })?.regions ?? []
  }

  func publish(documentID: UUID, token: String, receipt: NSDictionary, geometry: WorkspaceItemGeometry) throws {
    guard let pageIndex = receipt["pageIndex"] as? Int, let key = receipt["sourceKey"] as? String,
      let source = sessions.values.lazy.compactMap(\.value)
        .filter({ $0.documentID == documentID }).compactMap({ $0.source(key: key) }).first else {
      throw DocumentSessionError.invalidLayout
    }
    let layout = try source.acceptLayout(receipt, geometry: geometry)
    guard (0..<layout.pageCount).contains(pageIndex) else { throw DocumentSessionError.invalidLayout }
    let diagnostics = (receipt["diagnostics"] as? [[String: String]] ?? []).map {
      RenderDiagnostic(kind: $0["kind"] ?? "render_error", elementID: $0["blockID"], message: $0["message"] ?? "")
    }
    var values = entries[documentID] ?? []
    if let previous = values.last(where: { $0.token == token && $0.pageIndex == pageIndex }),
      previous.layout === layout, previous.diagnostics == diagnostics { return }
    values.removeAll { $0.token == token && $0.pageIndex == pageIndex }
    values.append(.init(token: token, pageIndex: pageIndex, layout: layout, diagnostics: diagnostics))
    entries[documentID] = Array(values.suffix(8))
  }
}

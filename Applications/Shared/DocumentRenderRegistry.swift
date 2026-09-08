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
    let regions: [DocumentBlockRegion]
    let diagnostics: [RenderDiagnostic]
  }
  private var entries: [UUID: [Entry]] = [:]
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

  func publish(documentID: UUID, token: String, receipt: NSDictionary, geometry: WorkspaceItemGeometry) {
    let width = (receipt["width"] as? NSNumber)?.doubleValue ?? geometry.width
    let height = (receipt["height"] as? NSNumber)?.doubleValue ?? geometry.height
    guard width > 0, height > 0, let pageIndex = (receipt["pageIndex"] as? NSNumber)?.intValue else { return }
    let regions = (receipt["regions"] as? [[String: Any]] ?? []).compactMap { value -> DocumentBlockRegion? in
      guard let id = value["id"] as? String, let page = value["pageIndex"] as? Int,
        let x = value["x"] as? Double, let y = value["y"] as? Double,
        let w = value["width"] as? Double, let h = value["height"] as? Double, w > 0, h > 0 else { return nil }
      return .init(id: id, pageIndex: page, frame: .init(x:x * geometry.width / width,y:y * geometry.height / height,
        width:w * geometry.width / width,height:h * geometry.height / height))
    }
    let diagnostics = (receipt["diagnostics"] as? [[String: String]] ?? []).map { RenderDiagnostic(kind: $0["kind"] ?? "render_error", elementID: $0["blockID"], message: $0["message"] ?? "") }
    var values = entries[documentID] ?? []
    values.removeAll { $0.token == token && $0.pageIndex == pageIndex }
    values.append(.init(token: token, pageIndex: pageIndex, regions: regions, diagnostics: diagnostics))
    entries[documentID] = Array(values.suffix(8))
  }
}

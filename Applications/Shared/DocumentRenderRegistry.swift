import Foundation
import NotebookCore
import Observation

struct DocumentBlockRegion: Equatable {
  let id: String
  let pageIndex: Int
  let frame: PageRect
  let sourceOffset: Double
}

enum DocumentPresentationScope {
  case paper, block(String), region(PageRect), page
}

/// The actual WebKit layout names the block fragments on each physical sheet.
@MainActor
@Observable
final class DocumentRenderRegistry {
  static let shared = DocumentRenderRegistry()
  @MainActor struct Entry {
    let token: String
    let pageIndex: Int
    let layout: DocumentLayoutRecord
    var regions: [DocumentBlockRegion] { layout.regions }
    let diagnostics: [RenderDiagnostic]
  }
  @MainActor private struct PublishedEntry {
    let token: String
    let sourceStamp: VersionStamp
    let programIDs: Set<String>
    let pageIndex: Int
    weak var layout: DocumentLayoutRecord?
    let diagnostics: [RenderDiagnostic]
    var retained: Entry? {
      layout.map { Entry(token: token, pageIndex: pageIndex, layout: $0, diagnostics: diagnostics) }
    }
  }
  // The registry locates a measured source; it is not another cache owner.
  // A live source, raster entry or an actual reader retains the shared layout.
  private var entries: [UUID: [PublishedEntry]] = [:]
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
    let isAttached: @MainActor (DocumentPresentationScope) -> Bool
    let feedback: @MainActor ([NotebookAgentFeedback.Episode]) -> Void
  }
  @ObservationIgnored private var liveSurfaces: [UUID: LiveSurface] = [:]
  private struct LiveObserver {
    let documentID: UUID
    let changed: @MainActor () -> Void
  }
  @ObservationIgnored private var liveObservers: [UUID: LiveObserver] = [:]

  func observeLive(documentID: UUID, changed: @escaping @MainActor () -> Void) -> UUID {
    let id = UUID(); liveObservers[id] = .init(documentID: documentID, changed: changed); return id
  }

  func removeLiveObserver(_ id: UUID) { liveObservers[id] = nil }
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
  @ObservationIgnored private var retiringEditors: [UUID: SourceEditTask] = [:]

  func retainRetiringEditor(documentID: UUID, drain: Task<Void, Never>) {
    let id = UUID()
    let task = Task { @MainActor [weak self] in
      await drain.value
      guard let self else { return }
      retiringEditors[id] = nil; releaseEditingIfUnmounted(documentID)
    }
    retiringEditors[id] = .init(documentID: documentID, task: task)
  }

  /// Explicit background/close fencing reads the actual textarea without
  /// dismissing it. A view update never invokes this document-level boundary.
  func finishEditing(documentID: UUID) async -> Bool {
    for source in Array(sourceEdits.values).filter({ $0.documentID == documentID }) { await source.task.value }
    await editingTransfers[documentID]?.value
    if let host = editingOwners[documentID], let renderer = renderers[host]?.value,
      !renderer.isInvalidated, !(await renderer.checkpointEditingDraft()) { return false }
    for editor in Array(retiringEditors.values).filter({ $0.documentID == documentID }) { await editor.task.value }
    return true
  }

  func setAgentFeedback(_ episodes: [NotebookAgentFeedback.Episode]) {
    for surface in Array(liveSurfaces.values) {
      let active = surface.isAttached(.paper) ? episodes.filter {
        $0.subject.reference.target.kind == .document && $0.subject.reference.target.id == surface.documentID
      } : []
      surface.feedback(active)
    }
  }

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
      !retiringEditors.values.contains(where: { $0.documentID == documentID }),
      !renderers.values.contains(where: { $0.value?.payload?.documentID == documentID && $0.value?.isInvalidated == false }) else { return }
    editingOwners[documentID] = nil; editingGenerations[documentID] = nil
    editingDrafts[documentID] = nil; finishedDrafts[documentID] = nil
  }

  func rasterProducer(documentID: UUID, token: String, resources: SceneRenderResources, excluding hostID: UUID) -> DocumentWebCoordinator? {
    renderers.first { id, renderer in
      id != hostID && renderer.value?.canShareSnapshot == true
        && renderer.value?.resourceOwner === resources
        && renderer.value?.payload?.documentID == documentID && renderer.value?.payload?.rasterToken == token
    }?.value.value
  }

  /// Layout history can resolve an address, but only the exact mounted current
  /// surface can confirm what the person is seeing now.
  func hasLiveSurface(document: DocumentDocument, state: DocumentStateJournal, pageIndex: Int,
    scope: DocumentPresentationScope = .page) -> Bool {
    let token = DocumentSnapshotCache.token(document: document, state: state, pageIndex: pageIndex)
    return liveSurfaces.values.contains {
      $0.documentID == document.id && $0.token == token && $0.pageIndex == pageIndex && $0.isAttached(scope)
    }
  }

  func publishLive(documentID: UUID, token: String, pageIndex: Int, hostID: UUID, generation: UInt64,
    feedback: @escaping @MainActor ([NotebookAgentFeedback.Episode]) -> Void = { _ in },
    isAttached: @escaping @MainActor (DocumentPresentationScope) -> Bool) {
    if let previous = liveSurfaces[hostID] {
      if previous.generation > generation { return }
      if previous.token != token || previous.pageIndex != pageIndex { previous.feedback([]) }
    }
    liveSurfaces[hostID] = .init(documentID: documentID, token: token, pageIndex: pageIndex,
      generation: generation, isAttached: isAttached, feedback: feedback)
    for observer in Array(liveObservers.values) where observer.documentID == documentID { observer.changed() }
  }

  func revokeLive(hostID: UUID, through generation: UInt64) {
    guard let previous = liveSurfaces[hostID], previous.generation <= generation else { return }
    previous.feedback([])
    liveSurfaces[hostID] = nil
  }

  func entry(document: DocumentDocument, pageIndex: Int) -> Entry? {
    return entries[document.id]?.last { $0.layout != nil && $0.sourceStamp == document.contentStamp && $0.pageIndex == pageIndex }?.retained
  }

  func layout(document: DocumentDocument) -> DocumentLayoutRecord? {
    entries[document.id]?.last(where: { $0.layout != nil && $0.sourceStamp == document.contentStamp })?.layout
  }

  func programIDs(document: DocumentDocument, pageIndex: Int) -> Set<String>? {
    guard let entry = entries[document.id]?.last(where: { $0.layout != nil && $0.sourceStamp == document.contentStamp }),
      let layout = entry.layout, (0..<layout.pageCount).contains(pageIndex) else { return nil }
    return layout.blockIDs(on: [pageIndex]).intersection(entry.programIDs)
  }

  func regions(document: DocumentDocument) -> [DocumentBlockRegion] {
    layout(document: document)?.regions ?? []
  }

  func layoutReferenceCount(documentID: UUID) -> Int { entries[documentID]?.count ?? 0 }

  func publish(documentID: UUID, token: String, receipt: NSDictionary, geometry: WorkspaceItemGeometry) throws {
    guard let pageIndex = receipt["pageIndex"] as? Int, let key = receipt["sourceKey"] as? String,
      let source = sessions.values.lazy.compactMap(\.value)
        .filter({ $0.documentID == documentID }).compactMap({ $0.source(key: key) }).first else {
      throw DocumentSessionError.invalidLayout
    }
    let layout = try source.acceptLayout(receipt, geometry: geometry)
    guard (0..<layout.pageCount).contains(pageIndex) else { throw DocumentSessionError.invalidLayout }
    layout.whenReleased(by: self) { [weak self] in
      guard let self else { return }
      let live = entries[documentID]?.filter { $0.layout != nil } ?? []
      entries[documentID] = live.isEmpty ? nil : live
    }
    let diagnostics = (receipt["diagnostics"] as? [[String: String]] ?? []).map {
      RenderDiagnostic(kind: $0["kind"] ?? "render_error", elementID: $0["blockID"], message: $0["message"] ?? "")
    }
    var values = entries[documentID]?.filter { $0.layout != nil } ?? []
    if let previous = values.last(where: { $0.token == token && $0.pageIndex == pageIndex }),
      previous.layout === layout, previous.diagnostics == diagnostics { return }
    values.removeAll { $0.token == token && $0.pageIndex == pageIndex }
    values.append(.init(token: token, sourceStamp: source.stamp, programIDs: source.programIDs,
      pageIndex: pageIndex, layout: layout, diagnostics: diagnostics))
    entries[documentID] = Array(values.suffix(8))
  }
}

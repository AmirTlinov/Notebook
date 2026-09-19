import Foundation
import NotebookCore
import Observation
import WebKit

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
    let paper: @MainActor () -> DocumentPaperRaster?
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
    var retiringValue: DocumentWebCoordinator?
    var retiringWeb: WKWebView?
    init(_ value: DocumentWebCoordinator) { self.value = value }
  }
  @ObservationIgnored private var renderers: [UUID: Renderer] = [:]
  @ObservationIgnored private var editingOwners: [UUID: UUID] = [:]
  func checkpointPrograms(documentID: UUID? = nil, resume: Bool) async -> Bool {
    #if os(iOS)
      return await DocumentPagePresentationOwner.checkpointPrograms(documentID: documentID, resume: resume)
    #else
      let owners = renderers.values.compactMap(\.value).filter {
        !$0.isInvalidated && $0.resourceOwner === SceneRenderResources.shared && (documentID == nil || $0.payload?.documentID == documentID)
      }
      let tasks = owners.map { owner in Task { @MainActor in await owner.checkpointPrograms(resume: resume) } }
      var accepted = true
      for task in tasks { if !(await task.value) { accepted = false } }
      return accepted
    #endif
  }

  func resumePrograms() async {
    #if os(iOS)
      await DocumentPagePresentationOwner.resumePrograms()
    #else
      for entry in Array(renderers.values) where entry.retiringValue == nil {
        if let owner = entry.value, owner.resourceOwner === SceneRenderResources.shared, !owner.isInvalidated { await owner.resumePrograms() }
      }
    #endif
  }


  func retainRetiringProgram(_ renderer: DocumentWebCoordinator, web: WKWebView, hostID: UUID) {
    let entry = renderers[hostID] ?? Renderer(renderer)
    entry.retiringValue = renderer; entry.retiringWeb = web; renderers[hostID] = entry
  }

  func retryRetiringPrograms() {
    #if os(iOS)
      DocumentPagePresentationOwner.retryRetiringPrograms()
    #else
      for entry in Array(renderers.values) { entry.retiringValue?.retireAfterProgramCheckpoint() }
    #endif
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
    if let documentID, editingOwners[documentID] == hostID { editingOwners[documentID] = nil }
  }

  /// Only the current paper host can request the native source editor. The
  /// editor's session and its durable draft are owned by the window/model, not
  /// by any page WebKit, so page handoff has no second writer to drain.
  func setEditingOwner(documentID: UUID, hostID: UUID, active: Bool) {
    let previous = editingOwners[documentID]
    guard active ? previous != hostID : previous == hostID else { return }
    previous.flatMap { renderers[$0]?.value }?.revokeEditingOwnership()
    editingOwners[documentID] = active ? hostID : nil
    if active { renderers[hostID]?.value?.activateEditing() }
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

  /// Borrow the installed, accounted paper pixels. A prepared or detached page
  /// is not a mask for feedback on the current source.
  func installedPaper(document: DocumentDocument, state: DocumentStateJournal, pageIndex: Int) -> DocumentPaperRaster? {
    let token = DocumentSnapshotCache.token(document: document, state: state, pageIndex: pageIndex)
    return liveSurfaces.values.first {
      $0.documentID == document.id && $0.token == token && $0.pageIndex == pageIndex && $0.isAttached(.paper)
    }?.paper()
  }

  func publishLive(documentID: UUID, token: String, pageIndex: Int, hostID: UUID, generation: UInt64,
    paper: @escaping @MainActor () -> DocumentPaperRaster? = { nil },
    isAttached: @escaping @MainActor (DocumentPresentationScope) -> Bool) {
    if let previous = liveSurfaces[hostID] {
      if previous.generation > generation { return }
    }
    liveSurfaces[hostID] = .init(documentID: documentID, token: token, pageIndex: pageIndex,
      generation: generation, isAttached: isAttached, paper: paper)
    for observer in Array(liveObservers.values) where observer.documentID == documentID { observer.changed() }
  }

  func revokeLive(hostID: UUID, through generation: UInt64) {
    guard let previous = liveSurfaces[hostID], previous.generation <= generation else { return }
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

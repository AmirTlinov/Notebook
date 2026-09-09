import Foundation
import NotebookCore

/// One completed pointing contact retains the values that were on screen.
/// Encoding and hashing happen on the model's existing persistence worker;
/// another contact or a new camera cannot redirect this selection.
struct NotebookAttentionSelection: Sendable {
  struct Fragment: Sendable {
    let id = UUID()
    let target: CollaborationTarget
    let elementID: String?
    let region: PageRect
    let worldOrigin: WorldPoint?
    let pageIndex: Int?
    let label: String
  }

  let fragments: [Fragment]
  private let workspace: WorkspaceIndex
  private let hierarchy: BoardHierarchy
  private let ink: SpatialInkJournal
  private let pages: [PageDocument]
  private let documents: [DocumentDocument]
  private let states: [DocumentStateJournal]
  // Retaining this value is constant-time. Only addressed physical paper is
  // read later; document programs never enter a board/cover reference hash.
  private let paperSources: [UUID: DocumentDocument]
  private let visuals: NotebookFrozenVisualSources?
  private let referenceIdentities: [NotebookReferenceIdentity]

  init(fragments: [Fragment], workspace: WorkspaceIndex, hierarchy: BoardHierarchy,
    ink: SpatialInkJournal, pages: [UUID: PageDocument], documents: [UUID: DocumentDocument],
    states: [UUID: DocumentStateJournal], visuals: NotebookFrozenVisualSources? = nil,
    referenceIdentities: [NotebookReferenceIdentity] = []) {
    self.fragments = fragments
    self.workspace = workspace; self.hierarchy = hierarchy; self.ink = ink
    let pageIDs = Set(fragments.filter { $0.target.kind == .page }.map { $0.target.id })
    let documentIDs = Set(fragments.filter { $0.target.kind == .document }.map { $0.target.id })
    self.pages = pageIDs.compactMap { pages[$0] }
    self.documents = documentIDs.compactMap { documents[$0] }
    self.states = documentIDs.compactMap { states[$0] }
    paperSources = documents
    self.visuals = visuals
    let targets = Set(fragments.map(\.target))
    self.referenceIdentities = referenceIdentities.filter { targets.contains($0.target) }
  }

  func sourceFiles() throws -> [String: JSONValue] {
    try Task.checkCancellation()
    let content = CollaborationContent(workspace: workspace, hierarchy: hierarchy,
      ink: ink, pages: pages, documents: documents, states: states)
    let paths = content.referenceFilePaths(for: fragments.map(\.target))
    var files = try content.sourceFiles(including: paths)
    for path in paths where path.hasPrefix("documents/") && files[path] == nil {
      try Task.checkCancellation()
      guard let id = UUID(uuidString: String(path.dropFirst("documents/".count).dropLast(".json".count))),
        let document = paperSources[id] else { continue }
      files[path] = .object(["paperSize": try .encode(document.paperSize)])
    }
    return referenceIdentities.isEmpty ? files : try NotebookStore.bindReferenceIdentities(referenceIdentities, to: files)
  }

  func resolvedReferences() throws -> [CollaborationReference] {
    let files = try sourceFiles()
    return try fragments.map { fragment in
      try Task.checkCancellation()
      return .init(id: fragment.id, target: fragment.target, elementID: fragment.elementID,
        region: fragment.region, worldOrigin: fragment.worldOrigin, pageIndex: fragment.pageIndex,
        revision: try NotebookStore.referenceRevision(target: fragment.target, elementID: fragment.elementID, files: files),
        label: fragment.label)
    }
  }

  @MainActor
  func renderPinnedImages(references: [CollaborationReference],
    resources: SceneRenderResources = .shared) async throws -> NotebookPinnedImages {
    let worker = Task.detached(priority: .utility) { try self.resolvedReferences() }
    let resolved = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    guard Set(references.map(\.id)).count == references.count,
      references.allSatisfy({ resolved.contains($0) }) else {
      throw CollaborationError("source_conflict", "Изображение относится к другому завершённому указанию.")
    }
    var images: [UUID: AgentPinnedImage] = [:]
    var unavailable: [UUID: String] = [:]
    var totalBytes = 0
    for reference in references {
      try Task.checkCancellation()
      let boardID = reference.target.kind == .board ? reference.target.id : reference.target.boardID
      let element = boardID.flatMap { hierarchy.board($0) }?.elements.first { $0.id == reference.elementID }
      do {
        let image = try await NotebookPinnedImageRenderer.render(reference: reference,
          page: pages.first { $0.id == reference.target.id }, document: documents.first { $0.id == reference.target.id },
          state: states.first { $0.id == reference.target.id }, element: element, visuals: visuals, resources: resources)
        guard image.png.count <= NotebookPinnedImageRenderer.maximumTotalBytes - totalBytes else {
          unavailable[reference.id] = "request_image_limit: изображения вопроса превышают 4 МиБ"
          continue
        }
        images[reference.id] = image; totalBytes += image.png.count
      } catch let error as SceneRenderError {
        unavailable[reference.id] = error.description
      }
    }
    return .init(images: images, unavailable: unavailable)
  }
}

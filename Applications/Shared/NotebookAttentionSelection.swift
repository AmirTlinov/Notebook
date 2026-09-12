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
  private var ink: SpatialInkJournal
  private let pages: [PageDocument]
  private let documents: [DocumentDocument]
  private let states: [DocumentStateJournal]
  // Retaining this value is constant-time. Only addressed physical paper is
  // read later; document programs never enter a board/cover reference hash.
  private let paperSources: [UUID: DocumentDocument]
  private let visuals: NotebookFrozenVisualSources?
  private var referenceIdentities: [NotebookReferenceIdentity]
  private var installedInk: [SurfaceID: SpatialInkInstalledSource]
  private var requiredInk: Set<SurfaceID>
  private var referenceBasis: NotebookReferenceBasis?
  private let workspaceID: UUID?

  init(fragments: [Fragment], workspace: WorkspaceIndex, hierarchy: BoardHierarchy,
    ink: SpatialInkJournal, pages: [UUID: PageDocument], documents: [UUID: DocumentDocument],
    states: [UUID: DocumentStateJournal], visuals: NotebookFrozenVisualSources? = nil,
    referenceIdentities: [NotebookReferenceIdentity] = [],
    installedInk: [SurfaceID: SpatialInkInstalledSource] = [:], requiredInk: Set<SurfaceID> = [],
    referenceBasis: NotebookReferenceBasis? = nil) {
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
    self.installedInk = installedInk; self.requiredInk = requiredInk; self.referenceBasis = referenceBasis
    workspaceID = referenceBasis?.workspaceID
  }

  func sourceFiles() throws -> [String: JSONValue] {
    try resolvingPresentedSources().encodedSourceFiles()
  }

  private func encodedSourceFiles() throws -> [String: JSONValue] {
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

  struct Sealed: Sendable {
    let selection: NotebookAttentionSelection
    let references: [CollaborationReference]
    let workspaceID: UUID
  }

  /// Runs in the existing command queue, after preceding ink writes and before
  /// the next contact's write. A newer global cursor is not itself a conflict.
  func seal(in store: NotebookStore) throws -> Sealed {
    let normalized = try resolvingPresentedSources()
    let references = try normalized.resolvedReferences()
    return try store.readTransaction { store in
      let header = try store.workspaceHeader()
      guard workspaceID == nil || workspaceID == header.workspaceID else {
        throw CollaborationError("capture_source_changed", "Рабочее пространство указания изменилось.")
      }
      if !requiredInk.isEmpty {
        let current = try store.readSpatialInk(surfaces: Array(requiredInk))
        for surface in requiredInk {
          let expected = try installedInk[surface]!.referenceInk()
          let actual = try NotebookReferenceInk(surface: surface, actions: current.actions)
          guard expected == actual else {
            throw CollaborationError("capture_source_changed", "Установленные чернила отличаются от сохранённого источника. Укажите область после готовности чернил.")
          }
        }
      }
      for reference in references {
        guard try store.referenceRevision(target: reference.target, elementID: reference.elementID) == reference.revision else {
          throw CollaborationError("capture_source_changed", "Статический источник указания изменился. Укажите фрагмент снова.")
        }
      }
      return .init(selection: normalized, references: references, workspaceID: header.workspaceID)
    }
  }

  private func resolvingPresentedSources() throws -> Self {
    let wholeScene = fragments.contains { $0.elementID == nil && [.board, .cover].contains($0.target.kind) }
    guard !requiredInk.isEmpty || (wholeScene && referenceBasis != nil) else { return self }
    guard requiredInk.count <= 8, requiredInk.allSatisfy({ installedInk[$0]?.surface == $0 }), let referenceBasis else {
      throw CollaborationError("capture_source_pending", "Чернила указанной поверхности ещё не установлены. Укажите область после их готовности.")
    }
    let sources = try requiredInk.map { try installedInk[$0]!.referenceInk() }
    let identities = try referenceBasis.replacing(ink: sources,
      workspace: wholeScene ? workspace : nil, hierarchy: wholeScene ? hierarchy : nil)
    let directSurfaces = Set(fragments.compactMap { fragment -> SurfaceID? in
      switch fragment.target.kind {
      case .board: return .board(fragment.target.id)
      case .cover: return .cover(fragment.target.id)
      default: return nil
      }
    })
    var bySurface = Dictionary(uniqueKeysWithValues: sources.filter { directSurfaces.contains($0.surface) }.map { ($0.surface, $0) })
    for surface in directSurfaces where bySurface[surface] == nil {
      bySurface[surface] = try .init(surface: surface, actions: ink.actions)
    }
    var actions: [UUID: SpatialInkAction] = [:]
    for source in bySurface.values.sorted(by: { String(describing: $0.surface) < String(describing: $1.surface) }) {
      for action in source.actions {
        if let previous = actions[action.id] {
          guard previous.tool == action.tool, previous.color == action.color, previous.stamp == action.stamp,
            previous.stateStamp == action.stateStamp, previous.isActive == action.isActive else {
            throw CollaborationError("capture_source_changed", "Живые и неподвижные поверхности содержат разные состояния одного контакта.")
          }
          actions[action.id] = .init(id: action.id, tool: action.tool, color: action.color,
            spans: previous.spans + action.spans, stamp: action.stamp, isActive: action.isActive, stateStamp: action.stateStamp)
        } else { actions[action.id] = action }
      }
    }
    var value = self
    value.ink = .init(actions: actions.values.sorted {
      $0.stamp == $1.stamp ? $0.id.uuidString < $1.id.uuidString : $0.stamp < $1.stamp
    }, stamp: ink.stamp)
    let targets = Set(fragments.map(\.target))
    value.referenceIdentities = identities.filter { targets.contains($0.target) }
    value.installedInk = [:]; value.requiredInk = []; value.referenceBasis = nil
    return value
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

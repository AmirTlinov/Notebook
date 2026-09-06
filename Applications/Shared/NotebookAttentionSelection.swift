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

  init(fragments: [Fragment], workspace: WorkspaceIndex, hierarchy: BoardHierarchy,
    ink: SpatialInkJournal, pages: [UUID: PageDocument], documents: [UUID: DocumentDocument],
    states: [UUID: DocumentStateJournal]) {
    self.fragments = fragments
    self.workspace = workspace; self.hierarchy = hierarchy; self.ink = ink
    let pageIDs = Set(fragments.filter { $0.target.kind == .page }.map { $0.target.id })
    let documentIDs = Set(fragments.filter { $0.target.kind == .document }.map { $0.target.id })
    self.pages = pageIDs.compactMap { pages[$0] }
    self.documents = documentIDs.compactMap { documents[$0] }
    self.states = documentIDs.compactMap { states[$0] }
    paperSources = documents
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
    return files
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
}

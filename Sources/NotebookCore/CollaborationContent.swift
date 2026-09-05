import Foundation

/// One completed cut of the existing content owners crosses the device link.
/// Their field merge rules preserve local edits before this cut is published.
public struct CollaborationContent: Codable, Equatable, Sendable {
  public var workspace: WorkspaceIndex
  public var hierarchy: BoardHierarchy
  public var ink: SpatialInkJournal
  public var pages: [PageDocument]
  public var documents: [DocumentDocument]
  public var states: [DocumentStateJournal]

  public init(workspace: WorkspaceIndex, hierarchy: BoardHierarchy, ink: SpatialInkJournal,
    pages: [PageDocument], documents: [DocumentDocument], states: [DocumentStateJournal]) {
    self.workspace = workspace; self.hierarchy = hierarchy; self.ink = ink
    self.pages = pages.sorted { $0.id.uuidString < $1.id.uuidString }
    self.documents = documents.sorted { $0.id.uuidString < $1.id.uuidString }
    self.states = states.sorted { $0.id.uuidString < $1.id.uuidString }
  }

  public mutating func merge(_ incoming: Self) {
    _ = workspace.merge(incoming.workspace)
    _ = hierarchy.merge(incoming.hierarchy, items: workspace.items)
    _ = ink.merge(incoming.ink)
    var pages = Dictionary(uniqueKeysWithValues: self.pages.map { ($0.id, $0) })
    for other in incoming.pages { if pages[other.id] != nil { _ = pages[other.id]!.merge(other) } else { pages[other.id] = other } }
    var documents = Dictionary(uniqueKeysWithValues: self.documents.map { ($0.id, $0) })
    for other in incoming.documents { if documents[other.id] != nil { _ = documents[other.id]!.merge(other) } else { documents[other.id] = other } }
    var states = Dictionary(uniqueKeysWithValues: self.states.map { ($0.id, $0) })
    for other in incoming.states { if states[other.id] != nil { _ = states[other.id]!.merge(other) } else { states[other.id] = other } }
    let pageIDs = Set(workspace.items.flatMap(\.pageIDs))
    let documentIDs = Set(workspace.items.filter { $0.kind == .document }.map(\.id))
    self.pages = pages.values.filter { pageIDs.contains($0.id) }.sorted { $0.id.uuidString < $1.id.uuidString }
    self.documents = documents.values.filter { documentIDs.contains($0.id) }.sorted { $0.id.uuidString < $1.id.uuidString }
    self.states = states.values.filter { documentIDs.contains($0.id) }.sorted { $0.id.uuidString < $1.id.uuidString }
  }

  public func sourceFiles() throws -> [String: JSONValue] {
    var files: [String: JSONValue] = ["workspace.json": try .encode(workspace), "board.json": try .encode(hierarchy), "spatial-ink.json": try .encode(ink)]
    for page in pages { files["pages/\(page.id.uuidString.lowercased()).json"] = try .encode(page) }
    for document in documents { files["documents/\(document.id.uuidString.lowercased()).json"] = try .encode(document) }
    for state in states { files["document-states/\(state.id.uuidString.lowercased()).json"] = try .encode(state) }
    return files
  }
}

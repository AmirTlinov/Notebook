import Foundation
import NotebookCore

/// Only the active selection is local metadata. Each space keeps its own SQL
/// owner; opening an account space never retargets or merges the current one.
struct NotebookWorkspaceLibrary: Sendable {
  let originalRoot: URL
  private var selectionURL: URL {
    originalRoot.deletingLastPathComponent().appendingPathComponent(originalRoot.lastPathComponent + ".selected-space.json")
  }
  func selectedRoot() throws -> URL {
    guard FileManager.default.fileExists(atPath: selectionURL.path) else { return originalRoot }
    let data = try Data(contentsOf: selectionURL)
    guard data.count <= 128 else { throw NotebookStorageError.invalidTransaction("workspace selection") }
    let id = try JSONDecoder().decode(UUID.self, from: data)
    let selected = try root(for: id), store = NotebookStore(root: selected)
    guard FileManager.default.fileExists(atPath: store.databaseURL.path), try store.storedWorkspaceID() == id else {
      throw NotebookStoreError.workspaceChanged
    }
    return selected
  }
  func root(for id: UUID) throws -> URL {
    let original = NotebookStore(root: originalRoot)
    if FileManager.default.fileExists(atPath: original.databaseURL.path), try original.storedWorkspaceID() == id { return originalRoot }
    return originalRoot.deletingLastPathComponent()
      .appendingPathComponent(originalRoot.lastPathComponent + ".spaces", isDirectory: true)
      .appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
  }
  func prepare(_ id: UUID) throws -> URL {
    let root = try root(for: id), store = NotebookStore(root: root)
    if !FileManager.default.fileExists(atPath: store.databaseURL.path) { try store.prepareEmptyWorkspace(workspaceID: id) }
    guard try store.storedWorkspaceID() == id else { throw NotebookStoreError.workspaceChanged }
    return root
  }
  func select(_ id: UUID) throws -> URL {
    let root = try prepare(id)
    try JSONEncoder().encode(id).write(to: selectionURL, options: .atomic)
    return root
  }
}

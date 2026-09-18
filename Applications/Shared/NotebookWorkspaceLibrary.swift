import Foundation
import NotebookCore

/// One local catalog owns selection and storage locations, never notebook data.
/// The original activation marker and Codex working directory belong to the
/// installation, not to an individual vault.
struct NotebookWorkspaceLibrary: Sendable {
  struct Entry: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var needsNamePublication = false
  }
  struct CloudDeletion: Codable, Sendable { let account: String; let name: String }
  struct Catalog: Codable, Sendable {
    let format: Int
    var originalID: UUID?
    var selectedID: UUID?
    var entries: [Entry]
    var deleting: Set<UUID>
    var pendingCloudDeletion: [UUID: CloudDeletion]
  }
  let originalRoot: URL
  private var catalogURL: URL { sibling("spaces.json") }
  private var oldSelectionURL: URL { sibling("selected-space.json") }
  private var managedRoot: URL { sibling("spaces", isDirectory: true) }
  private func sibling(_ suffix: String, isDirectory: Bool = false) -> URL {
    originalRoot.deletingLastPathComponent().appendingPathComponent(originalRoot.lastPathComponent + "." + suffix, isDirectory: isDirectory)
  }

  static func name(_ value: String) throws -> String {
    let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.utf8.count <= 240 else {
      throw NotebookStorageError.invalidTransaction("Введите непустое, более короткое название.")
    }
    return name
  }

  func catalog() throws -> Catalog {
    if FileManager.default.fileExists(atPath: catalogURL.path) {
      let data = try Data(contentsOf: catalogURL)
      guard data.count <= 262_144 else { throw NotebookTransportError.resourceLimit }
      let value = try JSONDecoder().decode(Catalog.self, from: data)
      guard value.format == 1, value.entries.count <= 32, value.deleting.count <= 32, value.pendingCloudDeletion.count <= 32,
        Set(value.entries.map(\.id)).count == value.entries.count,
        value.selectedID == nil || value.entries.contains(where: { $0.id == value.selectedID }),
        Set(value.entries.map(\.id)).isDisjoint(with: value.deleting) else { throw NotebookStoreError.workspaceChanged }
      return value
    }
    let original = NotebookStore(root: originalRoot)
    let id = FileManager.default.fileExists(atPath: original.databaseURL.path) ? try original.storedWorkspaceID() : nil
    var entries = id.map { [Entry(id: $0, name: "Моё пространство")] } ?? []
    if FileManager.default.fileExists(atPath: managedRoot.path) {
      for directory in try FileManager.default.contentsOfDirectory(at: managedRoot, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
        guard let spaceID = UUID(uuidString: directory.lastPathComponent),
          try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { continue }
        let store = NotebookStore(root: directory)
        guard FileManager.default.fileExists(atPath: store.databaseURL.path), try store.storedWorkspaceID() == spaceID else { continue }
        entries.append(.init(id: spaceID, name: "Пространство"))
      }
    }
    let selected: UUID?
    if FileManager.default.fileExists(atPath: oldSelectionURL.path) {
      let data = try Data(contentsOf: oldSelectionURL)
      guard data.count <= 128 else { throw NotebookStoreError.workspaceChanged }
      selected = try JSONDecoder().decode(UUID.self, from: data)
      guard entries.contains(where: { $0.id == selected }) else { throw NotebookStoreError.workspaceChanged }
    } else { selected = id }
    return .init(format: 1, originalID: id, selectedID: selected, entries: entries, deleting: [], pendingCloudDeletion: [:])
  }

  private func save(_ value: Catalog) throws {
    try FileManager.default.createDirectory(at: catalogURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(value).write(to: catalogURL, options: .atomic)
    if FileManager.default.fileExists(atPath: oldSelectionURL.path) { try FileManager.default.removeItem(at: oldSelectionURL) }
  }

  func selectedRoot() throws -> URL? {
    let value = try catalog()
    if let id = value.selectedID, value.pendingCloudDeletion[id] == nil {
      let root = try root(for: id), store = NotebookStore(root: root)
      guard FileManager.default.fileExists(atPath: store.databaseURL.path), try store.storedWorkspaceID() == id else { throw NotebookStoreError.workspaceChanged }
      return root
    }
    // Only a genuinely new installation gets its initial local notebook.
    return FileManager.default.fileExists(atPath: catalogURL.path) ? nil : originalRoot
  }

  func root(for id: UUID) throws -> URL {
    let value = try catalog()
    let root = value.originalID == id ? originalRoot : managedRoot.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    if FileManager.default.fileExists(atPath: root.path),
      try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw NotebookStoreError.workspaceChanged }
    return root
  }

  func prepare(_ id: UUID) throws -> URL {
    let root = try root(for: id), store = NotebookStore(root: root)
    if !FileManager.default.fileExists(atPath: store.databaseURL.path) { try store.prepareEmptyWorkspace(workspaceID: id) }
    guard try store.storedWorkspaceID() == id else { throw NotebookStoreError.workspaceChanged }
    return root
  }

  @discardableResult func select(_ id: UUID, name: String? = nil, publishName: Bool = false) throws -> URL {
    let root = try prepare(id)
    var value = try catalog()
    guard !value.deleting.contains(id) else { throw NotebookStoreError.workspaceChanged }
    if !value.entries.contains(where: { $0.id == id }) {
      guard value.entries.count < 32 else { throw NotebookTransportError.resourceLimit }
      value.entries.append(.init(id: id, name: try Self.name(name ?? "Пространство")))
    }
    if let name, let index = value.entries.firstIndex(where: { $0.id == id }) {
      value.entries[index].name = try Self.name(name)
      value.entries[index].needsNamePublication = publishName || value.entries[index].needsNamePublication
    }
    value.selectedID = id
    try save(value)
    return root
  }

  func rename(_ id: UUID, name: String, publish: Bool = false) throws {
    var value = try catalog()
    guard let index = value.entries.firstIndex(where: { $0.id == id }) else { return }
    value.entries[index].name = try Self.name(name)
    value.entries[index].needsNamePublication = publish
    try save(value)
  }

  func acknowledgeName(_ id: UUID, name: String) throws {
    var value = try catalog()
    guard let index = value.entries.firstIndex(where: { $0.id == id }), value.entries[index].name == name else { return }
    value.entries[index].needsNamePublication = false
    try save(value)
  }

  /// First retire the catalog entry durably, then remove only its owned files.
  /// An interrupted removal is resumed; it cannot be rediscovered at startup.
  func remove(_ id: UUID) throws {
    var value = try catalog()
    value.entries.removeAll { $0.id == id }
    if value.selectedID == id { value.selectedID = nil }
    value.pendingCloudDeletion[id] = nil
    value.deleting.insert(id)
    try save(value)
    try finishRemovals()
  }

  func beginCloudRemoval(_ id: UUID, account: String, name: String = "Пространство") throws {
    var value = try catalog()
    value.pendingCloudDeletion[id] = .init(account: account, name: name)
    try save(value)
  }

  func finishRemovals() throws {
    var value = try catalog()
    for id in value.deleting {
      let root = try root(for: id)
      if FileManager.default.fileExists(atPath: root.path) {
        if root == originalRoot {
          for child in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            where ![".notebook-activation.json", "Codex"].contains(child.lastPathComponent) {
            try FileManager.default.removeItem(at: child)
          }
        } else { try FileManager.default.removeItem(at: root) }
      }
      value.deleting.remove(id)
      try save(value)
    }
  }
}

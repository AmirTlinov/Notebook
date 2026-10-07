import Foundation
import CryptoKit
import Darwin
import NotebookCore

/// One local catalog owns selection and storage locations, never notebook data.
/// The original activation marker and Codex working directory belong to the
/// installation, not to an individual vault.
actor NotebookWorkspaceLibrary {
  struct Entry: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var needsNamePublication = false
  }
  struct CloudDeletion: Codable, Equatable, Sendable { let account: String; let name: String }
  struct Catalog: Codable, Equatable, Sendable {
    let format: Int
    var originalID: UUID?
    var selectedID: UUID?
    var entries: [Entry]
    var deleting: Set<UUID>
    var pendingCloudDeletion: [UUID: CloudDeletion]
  }
  struct Snapshot: Sendable {
    let revision: String
    let catalog: Catalog
    let selectedRoot: URL?
    let roots: [UUID: URL]
    let cleanupFailure: String?
  }
  struct SelectionTicket: Sendable {
    let id = UUID()
    let baseRevision: String
    let workspaceID: UUID
    let root: URL
    let catalog: Catalog
    fileprivate let bytes: Data
    fileprivate let digest: String
  }
  enum SelectionOutcome: Sendable {
    case committed(Snapshot)
    case rejected(String)
    case unresolved(String)
  }
  enum FaultPoint: Hashable, Sendable { case beforePublication, afterPublication, resolutionRead, cleanup }
  private struct Selection {
    let ticket: SelectionTicket
    var committed: Snapshot?
    var publicationIsVisible = false
    var unresolved = false
  }
  private struct CatalogCut {
    let catalog: Catalog
    let revision: String
    let isPersisted: Bool
  }
  nonisolated let originalRoot: URL
  private let fault: (@Sendable (FaultPoint) throws -> Void)?
  private var selection: Selection?
  private var cleanupFailure: String?
  init(originalRoot: URL, fault: (@Sendable (FaultPoint) throws -> Void)? = nil) {
    self.originalRoot = originalRoot; self.fault = fault
  }
  private var catalogURL: URL { sibling("spaces.json") }
  private var oldSelectionURL: URL { sibling("selected-space.json") }
  private var managedRoot: URL { sibling("spaces", isDirectory: true) }
  private func sibling(_ suffix: String, isDirectory: Bool = false) -> URL {
    originalRoot.deletingLastPathComponent().appendingPathComponent(originalRoot.lastPathComponent + "." + suffix, isDirectory: isDirectory)
  }

  nonisolated static func name(_ value: String) throws -> String {
    let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.utf8.count <= 240 else {
      throw NotebookStorageError.invalidTransaction("Введите непустое, более короткое название.")
    }
    return name
  }

  func snapshot() throws -> Snapshot {
    guard selection?.unresolved != true else { throw NotebookStorageError.invalidTransaction("Исход выбора пространства ещё не подтверждён.") }
    return try snapshot(from: catalogCut())
  }

  private func snapshot(from cut: CatalogCut) throws -> Snapshot {
    let value = cut.catalog
    var roots: [UUID: URL] = [:]
    for entry in value.entries { roots[entry.id] = try checkedRoot(for: entry.id, in: value) }
    let selected: URL?
    if let id = value.selectedID, value.pendingCloudDeletion[id] == nil {
      let root = try checkedRoot(for: id, in: value)
      guard FileManager.default.fileExists(atPath: NotebookStore(root: root).databaseURL.path),
        try NotebookStore(root: root).storedWorkspaceID() == id else { throw NotebookStoreError.workspaceChanged }
      selected = root
    } else { selected = cut.isPersisted ? nil : originalRoot }
    return .init(revision: cut.revision, catalog: value, selectedRoot: selected, roots: roots,
      cleanupFailure: cleanupFailure)
  }

  func prepareSelection(_ id: UUID, name: String? = nil, publishName: Bool = false) throws -> SelectionTicket {
    guard selection == nil else { throw NotebookStorageError.invalidTransaction("Выбор пространства ещё не завершён.") }
    let observed = try catalogCut()
    guard !observed.catalog.deleting.contains(id), observed.catalog.pendingCloudDeletion[id] == nil else { throw NotebookStoreError.workspaceChanged }
    let root = try prepareRoot(id, in: observed.catalog)
    // Preparing a new root can change absent-catalog discovery. The ticket's
    // DTO and revision must come from the same cut after that owned effect.
    let current = try catalogCut()
    guard observed.isPersisted == current.isPersisted,
      !observed.isPersisted || current.revision == observed.revision else { throw NotebookStoreError.workspaceChanged }
    var value = current.catalog
    guard !value.deleting.contains(id), value.pendingCloudDeletion[id] == nil else { throw NotebookStoreError.workspaceChanged }
    if !value.entries.contains(where: { $0.id == id }) {
      guard value.entries.count < 32 else { throw NotebookTransportError.resourceLimit }
      value.entries.append(.init(id: id, name: try Self.name(name ?? "Пространство")))
    }
    if let name, let index = value.entries.firstIndex(where: { $0.id == id }) {
      value.entries[index].name = try Self.name(name)
      value.entries[index].needsNamePublication = publishName || value.entries[index].needsNamePublication
    }
    value.selectedID = id
    let bytes = try Self.encode(value)
    let ticket = SelectionTicket(baseRevision: current.revision, workspaceID: id, root: root,
      catalog: value, bytes: bytes, digest: Self.hash(bytes))
    selection = .init(ticket: ticket)
    return ticket
  }

  /// A cancelled observer cannot abandon publication. The retained launch
  /// opening resolves this same ticket before another catalog mutation enters.
  func commitSelection(_ ticket: SelectionTicket) -> SelectionOutcome {
    guard selection?.ticket.id == ticket.id else { return .rejected("Выбор принадлежит другому переходу.") }
    if let committed = selection?.committed { return .committed(committed) }
    do {
      try fault?(.resolutionRead)
      let current = try catalogCut()
      if current.revision != ticket.digest {
        guard current.revision == ticket.baseRevision, selection?.publicationIsVisible == false else {
          if selection?.publicationIsVisible == true {
            selection?.unresolved = true
            return .unresolved("Каталог изменился до подтверждения сохранения.")
          }
          selection = nil; return .rejected("Каталог изменился. Повторите выбор из текущего списка.")
        }
        guard try NotebookStore(root: ticket.root).storedWorkspaceID() == ticket.workspaceID else {
          throw NotebookStoreError.workspaceChanged
        }
        try fault?(.beforePublication)
        try publish(ticket.bytes)
        selection?.publicationIsVisible = true
        try fault?(.afterPublication)
      } else { selection?.publicationIsVisible = true }
      // Retrying a visible replacement completes directory durability before
      // acknowledging it. Exact bytes remain owned through an I/O failure.
      try synchronizeDirectory()
      selection?.unresolved = false
      removeOldSelectionAfterCommit()
      // Publication already has a known outcome. Return the prepared exact
      // cut; a later read or cleanup cannot undo it or substitute another DTO.
      var roots: [UUID: URL] = [:]
      for entry in ticket.catalog.entries {
        roots[entry.id] = ticket.catalog.originalID == entry.id ? originalRoot
          : managedRoot.appendingPathComponent(entry.id.uuidString.lowercased(), isDirectory: true)
      }
      let committed = Snapshot(revision: ticket.digest, catalog: ticket.catalog,
        selectedRoot: ticket.root, roots: roots, cleanupFailure: cleanupFailure)
      selection?.committed = committed; selection?.unresolved = false
      return .committed(committed)
    } catch {
      // publish throws only before rename succeeds. An unreadable base before
      // publication therefore rejects this attempt without a catalog change.
      if selection?.publicationIsVisible == false {
        selection = nil; return .rejected(error.localizedDescription)
      }
      selection?.unresolved = true
      return .unresolved(error.localizedDescription)
    }
  }

  func finishSelection(_ ticket: SelectionTicket) {
    guard selection?.ticket.id == ticket.id, selection?.committed != nil else { return }
    selection = nil
  }
  func cancelSelection(_ ticket: SelectionTicket) {
    guard selection?.ticket.id == ticket.id, selection?.committed == nil, selection?.unresolved == false else { return }
    selection = nil
  }

  private static func encode(_ value: Catalog) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let bytes = try encoder.encode(value)
    guard bytes.count <= 262_144 else { throw NotebookTransportError.resourceLimit }
    return bytes
  }
  private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

  private func read(_ url: URL, maximumBytes: Int) throws -> Data {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(descriptor) }
    var before = stat(), after = stat()
    guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
      before.st_size >= 0, before.st_size <= maximumBytes else { throw NotebookTransportError.resourceLimit }
    var data = Data(count: Int(before.st_size))
    try data.withUnsafeMutableBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let count = Darwin.read(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count-offset)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw NotebookStoreError.workspaceChanged }; offset += count
      }
    }
    var extra: UInt8 = 0
    guard Darwin.read(descriptor, &extra, 1) == 0, fstat(descriptor, &after) == 0,
      before.st_dev == after.st_dev, before.st_ino == after.st_ino, before.st_size == after.st_size,
      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
      before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
      throw NotebookStoreError.workspaceChanged
    }
    return data
  }

  private func publish(_ bytes: Data) throws {
    try FileManager.default.createDirectory(at: catalogURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let temporary = catalogURL.deletingLastPathComponent().appendingPathComponent(".notebook-catalog-" + UUID().uuidString)
    let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(descriptor); try? FileManager.default.removeItem(at: temporary) }
    try bytes.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let written = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count-offset)
        if written < 0, errno == EINTR { continue }
        guard written > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }; offset += written
      }
    }
    guard fsync(descriptor) == 0, Darwin.rename(temporary.path, catalogURL.path) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }
  private func synchronizeDirectory() throws {
    let descriptor = open(catalogURL.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(descriptor) }
    guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
  }
  private func removeOldSelectionAfterCommit() {
    do {
      try fault?(.cleanup)
      if FileManager.default.fileExists(atPath: oldSelectionURL.path) { try FileManager.default.removeItem(at: oldSelectionURL) }
      cleanupFailure = nil
    } catch { cleanupFailure = error.localizedDescription }
  }

  private func catalog() throws -> Catalog { try catalogCut().catalog }
  private func catalogCut() throws -> CatalogCut {
    if let data = try readIfPresent(catalogURL, maximumBytes: 262_144) {
      return try catalogCut(from: data)
    }
    let original = NotebookStore(root: originalRoot)
    let id = FileManager.default.fileExists(atPath: original.databaseURL.path) ? try original.storedWorkspaceID() : nil
    var entries = id.map { [Entry(id: $0, name: "Моё пространство")] } ?? []
    if FileManager.default.fileExists(atPath: managedRoot.path) {
      guard let directories = FileManager.default.enumerator(at: managedRoot,
        includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey], options: [.skipsSubdirectoryDescendants]) else {
        throw NotebookStoreError.workspaceChanged
      }
      for case let directory as URL in directories {
        guard let spaceID = UUID(uuidString: directory.lastPathComponent),
          try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { continue }
        let store = NotebookStore(root: directory)
        guard FileManager.default.fileExists(atPath: store.databaseURL.path), try store.storedWorkspaceID() == spaceID else { continue }
        guard entries.count < 32 else { throw NotebookTransportError.resourceLimit }
        entries.append(.init(id: spaceID, name: "Пространство"))
      }
    }
    let selected: UUID?
    if let data = try readIfPresent(oldSelectionURL, maximumBytes: 128) {
      selected = try JSONDecoder().decode(UUID.self, from: data)
      guard entries.contains(where: { $0.id == selected }) else { throw NotebookStoreError.workspaceChanged }
    } else { selected = id }
    entries.sort { $0.id.uuidString < $1.id.uuidString }
    let value = Catalog(format: 1, originalID: id, selectedID: selected, entries: entries, deleting: [], pendingCloudDeletion: [:])
    // A concurrently materialized catalog takes precedence over discovery.
    if let data = try readIfPresent(catalogURL, maximumBytes: 262_144) { return try catalogCut(from: data) }
    return .init(catalog: value, revision: "absent:" + Self.hash(try Self.encode(value)), isPersisted: false)
  }

  private func catalogCut(from data: Data) throws -> CatalogCut {
    let value = try JSONDecoder().decode(Catalog.self, from: data)
    guard value.format == 1, value.entries.count <= 32, value.deleting.count <= 32, value.pendingCloudDeletion.count <= 32,
      Set(value.entries.map(\.id)).count == value.entries.count,
      value.selectedID == nil || value.entries.contains(where: { $0.id == value.selectedID }),
      Set(value.entries.map(\.id)).isDisjoint(with: value.deleting) else { throw NotebookStoreError.workspaceChanged }
    return .init(catalog: value, revision: Self.hash(data), isPersisted: true)
  }

  private func readIfPresent(_ url: URL, maximumBytes: Int) throws -> Data? {
    do { return try read(url, maximumBytes: maximumBytes) }
    catch let error as POSIXError where error.code == .ENOENT { return nil }
  }

  @discardableResult
  private func save(_ value: Catalog) throws -> CatalogCut {
    guard selection == nil else { throw NotebookStorageError.invalidTransaction("Выбор пространства ещё не завершён.") }
    let bytes = try Self.encode(value)
    try publish(bytes)
    try synchronizeDirectory()
    removeOldSelectionAfterCommit()
    return .init(catalog: value, revision: Self.hash(bytes), isPersisted: true)
  }

  func root(for id: UUID) throws -> URL {
    let value = try catalog()
    return try checkedRoot(for: id, in: value)
  }

  private func checkedRoot(for id: UUID, in value: Catalog) throws -> URL {
    let root = value.originalID == id ? originalRoot : managedRoot.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    if FileManager.default.fileExists(atPath: root.path),
      try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw NotebookStoreError.workspaceChanged }
    return root
  }

  func prepare(_ id: UUID) throws -> URL {
    try prepareRoot(id, in: catalog())
  }

  private func prepareRoot(_ id: UUID, in value: Catalog) throws -> URL {
    let root = try checkedRoot(for: id, in: value), store = NotebookStore(root: root)
    if !FileManager.default.fileExists(atPath: store.databaseURL.path) { try store.prepareEmptyWorkspace(workspaceID: id) }
    guard try store.storedWorkspaceID() == id else { throw NotebookStoreError.workspaceChanged }
    return root
  }

  @discardableResult
  func rename(_ id: UUID, name: String, publish: Bool = false, expectedRevision: String? = nil) throws -> Snapshot {
    let cut = try catalogCut()
    if let expectedRevision, cut.revision != expectedRevision { throw NotebookStoreError.workspaceChanged }
    var value = cut.catalog
    guard let index = value.entries.firstIndex(where: { $0.id == id }) else { return try snapshot(from: cut) }
    value.entries[index].name = try Self.name(name)
    value.entries[index].needsNamePublication = publish
    return try snapshot(from: save(value))
  }

  func acknowledgeName(_ id: UUID, name: String, expectedRevision: String) throws -> Snapshot {
    let cut = try catalogCut()
    guard cut.revision == expectedRevision else { throw NotebookStoreError.workspaceChanged }
    var value = cut.catalog
    guard let index = value.entries.firstIndex(where: { $0.id == id }), value.entries[index].name == name else { return try snapshot(from: cut) }
    value.entries[index].needsNamePublication = false
    return try snapshot(from: save(value))
  }

  /// One cloud response changes names on the exact catalog cut it observed.
  /// A local rename or a selection admitted in between wins over that response.
  func refreshCloudNames(_ names: [UUID: String], expectedRevision: String) throws -> Snapshot {
    let cut = try catalogCut()
    guard cut.revision == expectedRevision else { throw NotebookStoreError.workspaceChanged }
    var value = cut.catalog
    for index in value.entries.indices where !value.entries[index].needsNamePublication {
      if let name = names[value.entries[index].id] { value.entries[index].name = try Self.name(name) }
    }
    return try snapshot(from: value == cut.catalog ? cut : save(value))
  }

  /// Initial model registration can materialize an absent catalog. It never
  /// repoints an existing selection based on the currently visible model.
  func registerCurrentWorkspace(_ id: UUID, name: String) throws -> Snapshot {
    let cut = try catalogCut(), current = cut.catalog
    if !current.entries.contains(where: { $0.id == id }) {
      guard !cut.isPersisted, current.selectedID == id else {
        throw NotebookStoreError.workspaceChanged
      }
    }
    if !cut.isPersisted {
      var value = current
      if let index = value.entries.firstIndex(where: { $0.id == id }) { value.entries[index].name = try Self.name(name) }
      return try snapshot(from: save(value))
    }
    return try snapshot(from: cut)
  }
  func boundAccount(for id: UUID, expectedRevision: String? = nil) throws -> String? {
    let cut = try catalogCut()
    if let expectedRevision, cut.revision != expectedRevision { throw NotebookStoreError.workspaceChanged }
    let location = try checkedRoot(for: id, in: cut.catalog)
    guard try NotebookStore(root: location).storedWorkspaceID() == id else { throw NotebookStoreError.workspaceChanged }
    return try NotebookStore(root: location).cloudConfiguration().account
  }

  /// First retire the catalog entry durably, then remove only its owned files.
  /// An interrupted removal is resumed; it cannot be rediscovered at startup.
  @discardableResult
  func remove(_ id: UUID, expectedRevision: String? = nil) throws -> Snapshot {
    let cut = try catalogCut()
    if let expectedRevision, cut.revision != expectedRevision { throw NotebookStoreError.workspaceChanged }
    var value = cut.catalog
    value.entries.removeAll { $0.id == id }
    if value.selectedID == id { value.selectedID = nil }
    value.pendingCloudDeletion[id] = nil
    value.deleting.insert(id)
    try save(value)
    try finishRemovals()
    return try snapshot()
  }

  @discardableResult
  func beginCloudRemoval(_ id: UUID, account: String, name: String = "Пространство", expectedRevision: String? = nil) throws -> Snapshot {
    let cut = try catalogCut()
    if let expectedRevision, cut.revision != expectedRevision { throw NotebookStoreError.workspaceChanged }
    var value = cut.catalog
    value.pendingCloudDeletion[id] = .init(account: account, name: name)
    return try snapshot(from: save(value))
  }

  func finishRemovals() throws {
    var value = try catalog()
    for id in value.deleting {
      let root = try checkedRoot(for: id, in: value)
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

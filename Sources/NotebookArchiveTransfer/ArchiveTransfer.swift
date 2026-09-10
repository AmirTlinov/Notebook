import CryptoKit
import Foundation
import NotebookCore

struct ArchiveTransferError: Error, CustomStringConvertible {
  let description: String
  static func invalidSource(_ message: String) -> Self { .init(description: message) }
}

struct SourceFileProof: Codable, Equatable {
  let path: String
  let bytes: UInt64
  let sha256: String
}

struct ArchiveSource {
  let root: URL
  let files: [SourceFileProof]
  let checkpoint: NotebookCheckpoint
  let convertedPageIDs: [UUID]
  let restoredSummaryEntryIDs: [UUID]
  let unreferencedFiles: [String]

  static func read(root: URL, workspaceID: UUID) throws -> Self {
    let files = try inventory(root)
    let paths = Set(files.map(\.path))
    let allowedRoots: Set<String> = ["workspace.json", "board.json", "spatial-ink.json", "last-context.json",
      "pages", "documents", "document-states", "collaboration", "migrations", "runtime", "previews", "mcp-actor.txt", ".mutation.lock"]
    guard paths.allSatisfy({ allowedRoots.contains(String($0.split(separator: "/")[0])) }) else {
      let unknown = paths.filter { !allowedRoots.contains(String($0.split(separator: "/")[0])) }.sorted()
      throw ArchiveTransferError.invalidSource("unknown archive owners: \(unknown.prefix(5).joined(separator: ", ")); no files may be silently dropped")
    }
    let historyRoots: Set<String> = ["format.json", "selection.json", "contexts", "actions", "delivery", "render-requests"]
    guard paths.filter({ $0.hasPrefix("collaboration/") }).allSatisfy({ historyRoots.contains(String($0.split(separator: "/")[1])) }) else {
      throw ArchiveTransferError.invalidSource("unknown collaboration owner")
    }
    let proofs = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })
    func data(_ path: String) throws -> Data {
      guard let proof = proofs[path] else { throw ArchiveTransferError.invalidSource("missing owner: \(path)") }
      guard proof.bytes <= 512 * 1024 * 1024 else { throw ArchiveTransferError.invalidSource("owner exceeds the offline conversion budget: \(path)") }
      let value = try Data(contentsOf: root.appendingPathComponent(path))
      guard UInt64(value.count) == proof.bytes, digest(value) == proof.sha256 else {
        throw ArchiveTransferError.invalidSource("source changed during read: \(path)")
      }
      return value
    }
    func decode<T: Decodable>(_ path: String, _: T.Type) throws -> T {
      do { return try JSONDecoder().decode(T.self, from: data(path)) }
      catch { throw ArchiveTransferError.invalidSource("\(path): \(error)") }
    }
    func history<T: Decodable & Identifiable>(_ folder: String, _: T.Type) throws -> [T] where T.ID == UUID {
      try paths.filter { $0.hasPrefix("collaboration/\(folder)/") }.sorted().map { path in
        let value = try decode(path, T.self)
        guard path == "collaboration/\(folder)/\(value.id.uuidString.lowercased()).json" else {
          throw ArchiveTransferError.invalidSource("history filename does not address its UUID: \(path)")
        }
        return value
      }
    }
    let workspace = try decode("workspace.json", LegacyWorkspace.self).converted()
    let presence = try decode("last-context.json", LegacyPresence.self).converted(workspace: workspace)
    let hierarchy = try decode("board.json", BoardHierarchy.self)
    let ink = try decode("spatial-ink.json", SpatialInkJournal.self)
    let pages = try workspace.items.flatMap(\.pageIDs).map { id in
      let value = try convertLegacyPage(data("pages/\(id.uuidString.lowercased()).json"))
      guard value.id == id else { throw ArchiveTransferError.invalidSource("page UUID differs from address") }
      return value
    }
    let documents = try workspace.items.filter { $0.kind == .document }.map { item in
      let value = try decode("documents/\(item.id.uuidString.lowercased()).json", DocumentDocument.self)
      guard value.id == item.id else { throw ArchiveTransferError.invalidSource("document UUID differs from address") }
      return value
    }
    let states = try documents.map { document in
      let value = try decode("document-states/\(document.id.uuidString.lowercased()).json", DocumentStateJournal.self)
      guard value.id == document.id else { throw ArchiveTransferError.invalidSource("state UUID differs from address") }
      return value
    }
    struct HistoryFormat: Decodable { let format: Int }
    guard try decode("collaboration/format.json", HistoryFormat.self).format == 2 else {
      throw ArchiveTransferError.invalidSource("expected collaboration format 2")
    }
    let actions = try history("actions", CollaborationReceipt.self)
    let contexts = try convertLegacyContexts(history("contexts", SharedContext.self), actions: actions)
    let envelope = try CollaborationEnvelope(content: .init(workspace: workspace, hierarchy: hierarchy, ink: ink,
      pages: pages, documents: documents, states: states), actions: actions,
      contexts: contexts.contexts,
      selection: paths.contains("collaboration/selection.json") ? decode("collaboration/selection.json", SharedContextSelection.self) : nil,
      delivery: history("delivery", DeviceActionReceipt.self))
    let checkpoint = NotebookCheckpoint(workspaceID: workspaceID, envelope: envelope, presence: presence)
    try checkpoint.validate()
    var liveFiles = Set(pages.map { "pages/\($0.id.uuidString.lowercased()).json" })
    for document in documents {
      liveFiles.insert("documents/\(document.id.uuidString.lowercased()).json")
      liveFiles.insert("document-states/\(document.id.uuidString.lowercased()).json")
    }
    let unreferenced = paths.filter { path in
      ["pages/", "documents/", "document-states/"].contains(where: path.hasPrefix) && !liveFiles.contains(path)
    }.sorted()
    return Self(root: root, files: files, checkpoint: checkpoint,
      convertedPageIDs: pages.filter { !$0.drawingData.isEmpty }.map(\.id).sorted { $0.uuidString < $1.uuidString },
      restoredSummaryEntryIDs: contexts.restoredSummaryEntryIDs,
      unreferencedFiles: unreferenced)
  }
}

struct ArchiveTransferReport: Codable {
  let format: Int
  let source: String
  let sourceFiles: [SourceFileProof]
  let checkpoint: NotebookCheckpointReceipt
  let convertedPageIDs: [UUID]
  let restoredSummaryEntryIDs: [UUID]
  let unreferencedFilesRetainedInSource: [String]
  let inputQuiescenceProven: Bool
  let installedApplicationsChanged: Bool
}

enum ArchiveTransfer {
  /// Publishes a verified offline directory, never an active application root.
  /// The destination must not exist. All original files remain in the backup.
  static func prepare(source root: URL, destination: URL, workspaceID: UUID,
    beforePublication: (() throws -> Void)? = nil) throws -> ArchiveTransferReport {
    let manager = FileManager.default
    let root = root.standardizedFileURL.resolvingSymlinksInPath()
    let destination = destination.standardizedFileURL.resolvingSymlinksInPath()
    let activeRoot = NotebookStore.defaultRoot.standardizedFileURL.resolvingSymlinksInPath()
    guard !manager.fileExists(atPath: destination.path),
      !destination.path.hasPrefix(root.path + "/"),
      root != activeRoot, !root.path.hasPrefix(activeRoot.path + "/"),
      destination != activeRoot, !destination.path.hasPrefix(activeRoot.path + "/") else {
      throw ArchiveTransferError.invalidSource("use an independent backup and a new offline destination")
    }
    let source = try ArchiveSource.read(root: root, workspaceID: workspaceID)
    let staging = destination.deletingLastPathComponent().appendingPathComponent(".notebook-transfer-" + UUID().uuidString)
    try manager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? manager.removeItem(at: staging) }
    let store = NotebookStore(root: staging.appendingPathComponent("archive"))
    let receipt = try store.installCheckpoint(source.checkpoint)
    let contexts = try store.sharedContexts()
    let readback = try NotebookCheckpoint(workspaceID: store.workspaceHeader().workspaceID,
      envelope: .init(content: store.collaborationContent(), actions: store.collaborationActions(),
        contexts: contexts.contexts, selection: contexts.selection, delivery: store.deviceActionReceipts()),
      presence: store.loadPresence())
    try readback.validate()
    guard readback == source.checkpoint, try store.currentChangeCursor() == 1 else {
      throw ArchiveTransferError.invalidSource("checkpoint readback differs from the prepared owners")
    }
    let report = ArchiveTransferReport(format: 1, source: root.path, sourceFiles: source.files,
      checkpoint: receipt, convertedPageIDs: source.convertedPageIDs,
      restoredSummaryEntryIDs: source.restoredSummaryEntryIDs,
      unreferencedFilesRetainedInSource: source.unreferencedFiles,
      inputQuiescenceProven: false, installedApplicationsChanged: false)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(report).write(to: staging.appendingPathComponent("report.json"), options: [.atomic])
    try beforePublication?()
    guard try inventory(root) == source.files else {
      throw ArchiveTransferError.invalidSource("source changed before publication")
    }
    // Foundation move refuses an existing destination; it cannot replace a
    // concurrent publisher. The staging directory is on the same volume.
    try manager.moveItem(at: staging, to: destination)
    return report
  }
}

func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

func inventory(_ root: URL) throws -> [SourceFileProof] {
  let manager = FileManager.default
  let root = root.standardizedFileURL.resolvingSymlinksInPath()
  var enumerationError: Error?
  guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey],
    errorHandler: { _, error in enumerationError = error; return false }) else { throw ArchiveTransferError.invalidSource("source is not a readable directory") }
  var result: [SourceFileProof] = []
  for case let url as URL in enumerator {
    let properties = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
    guard properties.isSymbolicLink != true, properties.isRegularFile == true || properties.isDirectory == true else {
      throw ArchiveTransferError.invalidSource("source contains a link or special file: \(url.path)")
    }
    if properties.isDirectory == true { continue }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256(), size: UInt64 = 0
    while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { hash.update(data: chunk); size += UInt64(chunk.count) }
    let path = url.standardizedFileURL.resolvingSymlinksInPath().path
    guard path.hasPrefix(root.path + "/") else { throw ArchiveTransferError.invalidSource("file escaped the source directory") }
    result.append(.init(path: String(path.dropFirst(root.path.count + 1)), bytes: size,
      sha256: hash.finalize().map { String(format: "%02x", $0) }.joined()))
  }
  if let enumerationError { throw enumerationError }
  return result.sorted { $0.path < $1.path }
}

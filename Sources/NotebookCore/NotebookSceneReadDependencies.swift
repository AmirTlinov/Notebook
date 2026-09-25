import Foundation

/// Exact records actually borrowed by a scene's element/placement resolver.
/// Container clocks are not pixel sources. Membership queries are retained too,
/// so a new off-window claimant cannot silently change the visible winner.
public struct NotebookSceneRecordDependencies: Equatable, Sendable {
  enum Query: Hashable, Sendable {
    case elementRecords(String, descendants: Bool)
    case graphicClaims(String, strokes: [String])

    func rows(_ database: NotebookSQLConnection) throws -> [[String]] {
      switch self {
      case .elementRecords(let address, let descendants):
        let tail = descendants ? " OR (address>=? AND address<?)" : ""
        let args: [NotebookSQLValue] = [.text(address)] + (descendants ? [.text(address + "/"), .text(address + "0")] : [])
        return try database.rows("SELECT address,hash FROM records WHERE address=?" + tail + " ORDER BY address LIMIT 8193", args)
          .map { [$0[0].text!, $0[1].text!] }
      case .graphicClaims(let owner, let strokes):
        let placeholders = Array(repeating: "?", count: strokes.count).joined(separator: ",")
        return try database.rows("SELECT DISTINCT address FROM graphic_sources WHERE owner=? AND stroke_id IN (" + placeholders + ") ORDER BY address LIMIT 4097",
          [.text(owner)] + strokes.map(NotebookSQLValue.text)).map { [$0[0].text!] }
      }
    }
  }
  var queries: [Query: [[String]]] = [:]
  public init() {}
  public mutating func merge(_ other: Self) throws {
    for (query, rows) in other.queries { try record(query, rows: rows) }
  }
  mutating func record(_ query: Query, rows: [[String]]) throws {
    guard rows.count <= 8192, queries[query] != nil || queries.count < 8192 else {
      throw NotebookStorageError.limitExceeded("scene_source_dependencies")
    }
    if let old = queries[query], old != rows { throw NotebookStorageError.transactionConflict }
    queries[query] = rows
  }
  public func isCurrent(_ store: NotebookStore) throws -> Bool {
    try store.readTransaction { _ in
      for (query, expected) in queries where try query.rows(store.currentSQL!) != expected { return false }
      return true
    }
  }
}

final class NotebookSceneReadRecorder {
  var dependencies = NotebookSceneRecordDependencies()
  func records(_ address: String, descendants: Bool, rows: [[NotebookSQLValue]]) throws {
    // A graphic's causal lookup walks board container headers. Those headers'
    // stamps include unrelated edits, while the addressed field below owns the
    // arbitration. Board liveness/camera are separate semantic scene reads.
    guard address.contains("/board/elements/@") || address.contains("/board/collaboration/fields/@") else { return }
    try dependencies.record(.elementRecords(address, descendants: descendants), rows: rows.map { [$0[0].text!, $0[1].text!] }.sorted { $0[0] < $1[0] })
  }
  func claims(owner: String, strokes: [UUID], rows: [[NotebookSQLValue]]) throws {
    try dependencies.record(.graphicClaims(owner, strokes: strokes.map { $0.uuidString.lowercased() }.sorted()),
      rows: rows.map { [$0[0].text!] }.sorted { $0[0] < $1[0] })
  }
}

extension NotebookStore {
  /// Recording shares the resolver's existing synchronous read cut. Only hashes
  /// and bounded query witnesses escape, never copied bodies or a held snapshot.
  public func readRecordingSceneRecords<Value>(_ read: () throws -> Value) throws -> (value: Value, dependencies: NotebookSceneRecordDependencies) {
    try readTransaction { _ in
      let database = currentSQL!, previous = database.sceneReadRecorder, recorder = NotebookSceneReadRecorder()
      database.sceneReadRecorder = recorder
      defer { database.sceneReadRecorder = previous }
      let value = try read()
      if let previous { try previous.dependencies.merge(recorder.dependencies) }
      return (value, recorder.dependencies)
    }
  }

  /// A current index page, not a cross-transaction snapshot cursor. The scene
  /// reader owns continuation by revalidating its prior query/record witnesses.
  /// Public agent pagination continues to use readScenePaintOrder's strict cut.
  public func readCurrentScenePaintOrder(boardID: UUID, coverID: UUID? = nil, bounds: WorkspaceSpatialBounds,
    after: NotebookScenePaintPosition? = nil, limit: Int = 32,
    groupPoses: [String: NotebookElementPlacement.Source] = [:]) throws -> NotebookScenePaintPage {
    try readTransaction { _ in
      var cursor: NotebookScenePaintCursor?
      if let after {
        let target = coverID.map { CollaborationTarget(kind: .cover, id: $0, boardID: boardID) } ?? .init(kind: .board, id: boardID)
        let poses = try checkedGroupPoses(groupPoses, target: target)
        let hash = try collaborationHash(["bounds": try JSONValue.encode(bounds), "coverID": coverID.map { .string($0.uuidString.lowercased()) } ?? .null, "groupPoses": try .encode(poses)])
        cursor = .init(revision: try currentChangeCursor(), boardID: boardID, boundsHash: hash, layer: after.layer, zIndex: after.zIndex, address: after.key)
      }
      return try readScenePaintOrder(boardID: boardID, coverID: coverID, bounds: bounds, after: cursor, limit: limit, groupPoses: groupPoses)
    }
  }
}

extension NotebookScenePaintCursor {
  public var position: NotebookScenePaintPosition { .init(layer: layer, zIndex: zIndex, key: address) }
}

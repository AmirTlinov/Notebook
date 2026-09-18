import Foundation

/// A source directory, not a description of visible marks. UUID order is for
/// bounded traversal; sequence and erasers retain their native drawing meaning.
public struct NotebookPageInkActionMetadata: Codable, Equatable, Sendable {
  public let id: UUID
  public let tool: SpatialInkTool
  public let color: SpatialInkColor
  public let sequence: UInt64
  public let isActive: Bool
}

public struct NotebookPageInkBaselineMetadata: Codable, Equatable, Sendable {
  public let present: Bool
  public let actionCount: Int
}

public struct NotebookPageInkDirectory: Codable, Equatable, Sendable {
  public let header: NotebookContentHeader
  public let baseline: NotebookPageInkBaselineMetadata
  public let actions: [NotebookPageInkActionMetadata]
  public let nextActionID: UUID?
}

public struct NotebookPageInkActionRead: Codable, Equatable, Sendable {
  public let header: NotebookContentHeader
  public let action: PageInkAction
}

extension NotebookStore {
  /// The existing member index supplies only addresses. Metadata admission is
  /// bounded before any header is decoded; neither raster nor samples are read.
  public func readPageInkActions(pageID: UUID, after: UUID? = nil,
    limit: Int = 32) throws -> NotebookPageInkDirectory {
    guard (1...64).contains(limit) else { throw NotebookStorageError.limitExceeded("page_ink_directory") }
    return try readTransaction { _ in
      let header = try readContentHeader(target: .init(kind: .page, id: pageID))
      let file = pageFile(pageID), root = pageFile(pageID) + "#/drawingData"
      let drawing = try boundedStoredFragments([(root, false)], maximumCount: 1,
        maximumBytes: 262_144, budget: "page_ink_header")
      guard let row = drawing.first, row.file == file, row.parent == file + "#",
        row.collection == "drawingData", row.member.isEmpty, row.position == 0,
        row.value["baselinePNG"] == nil, row.value["actions"] == nil,
        let count = try row.value["baselineActionCount"]?.decode(Int.self), (0...1_000_000).contains(count) else {
        throw NotebookStorageError.corruptRecord(root)
      }
      let present = try !currentSQL!.rows("SELECT 1 FROM records WHERE address=?",
        [.text(root + "/baselinePNG")]).isEmpty
      let collections: [NotebookStoredCollection] = [.init(path: ["actions"], kind: .array)]
        + (present ? [.init(path: ["baselinePNG"], kind: .value)] : [])
      guard Set(row.collections.map(\.path)) == Set(collections.map(\.path)),
        row.collections.count == collections.count,
        collections.allSatisfy(row.collections.contains) else { throw NotebookStorageError.corruptRecord(root) }
      let members = try currentSQL!.rows("""
        SELECT address,member FROM records
        WHERE parent=? AND collection='actions' AND member>? ORDER BY member LIMIT ?
        """, [.text(root), .text(after?.uuidString.lowercased() ?? ""), .integer(Int64(limit + 1))])
      let addresses = members.prefix(limit).map { ($0[0].text!, false) }
      let fragments = try boundedStoredFragments(addresses, maximumCount: limit,
        maximumBytes: 4 * 1_024 * 1_024, budget: "page_ink_directory_headers")
      let actions = try fragments.map { fragment -> NotebookPageInkActionMetadata in
        let metadata = try fragment.value.decode(NotebookPageInkActionMetadata.self)
        guard metadata.color.isValid, metadata.sequence > 0, metadata.sequence <= VersionStamp.maximumCounter,
          fragment.file == file, fragment.parent == root, fragment.collection == "actions",
          fragment.member == metadata.id.uuidString.lowercased(),
          fragment.address == root + "/actions/@" + fragment.member,
          fragment.value["samples"] == nil,
          fragment.collections == [.init(path: ["samples"], kind: .value)] else {
          throw NotebookStorageError.corruptRecord(fragment.address)
        }
        return metadata
      }
      return .init(header: header, baseline: .init(present: present, actionCount: count), actions: actions,
        nextActionID: members.count > limit ? actions.last?.id : nil)
    }
  }

  /// One exact native source, with the same four-MiB addressed-body window as
  /// elements and document blocks. The outer command's sticky allowance also
  /// charges metadata, header and basis; no helper grants additional reads.
  public func readPageInkAction(pageID: UUID, actionID: UUID) throws -> NotebookPageInkActionRead? {
    try readTransaction { _ in
      let header = try readContentHeader(target: .init(kind: .page, id: pageID))
      let file = pageFile(pageID), parent = pageFile(pageID) + "#/drawingData"
      let member = actionID.uuidString.lowercased(), address = parent + "/actions/@" + actionID.uuidString.lowercased()
      let rows = try boundedStoredFragments([(address, true)], maximumCount: 2,
        maximumBytes: 4 * 1_024 * 1_024, budget: "page_ink_action")
      guard !rows.isEmpty else { return nil }
      guard let root = rows.first(where: { $0.address == address }), root.file == file,
        root.parent == parent, root.collection == "actions", root.member == member else {
        throw NotebookStorageError.corruptRecord(address)
      }
      let action = try NotebookRecordCodec.decode(rows, root: address).decode(PageInkAction.self)
      guard action.id == actionID, action.sequence > 0 else { throw NotebookStorageError.corruptRecord(address) }
      let canonical = try NotebookRecordCodec.encode(.encode(action), file: file, address: address,
        parent: parent, collection: "actions", member: member, position: root.position)
      guard Dictionary(uniqueKeysWithValues: canonical.map { ($0.address, $0) })
        == Dictionary(uniqueKeysWithValues: rows.map { ($0.address, $0) }) else {
        throw NotebookStorageError.corruptRecord(address)
      }
      return .init(header: header, action: action)
    }
  }
}

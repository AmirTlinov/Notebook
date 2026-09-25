import Foundation

extension NotebookStore {
  public func readPageElement(pageID: UUID, elementID: String) throws -> AgentElement? {
    guard !elementID.isEmpty, elementID.utf16.count <= 120 else {
      throw NotebookStorageError.invalidTransaction("page element address")
    }
    return try readTransaction { _ in
      let address = pageFile(pageID) + "#/elements/@" + fieldKey([collaborationIdentity(elementID)])
      let rows = try boundedStoredFragments([(address, true)], maximumCount: 4096,
        maximumBytes: 4 * 1_024 * 1_024, budget: "page_element_read")
      guard !rows.isEmpty else { return nil }
      let element = try NotebookRecordCodec.decode(rows, root: address).decode(AgentElement.self)
      guard collaborationIdentity(element.id) == collaborationIdentity(elementID) else {
        throw NotebookStorageError.corruptRecord(address)
      }
      return element
    }
  }

  public func inkRevision(on target: CollaborationTarget) throws -> String? {
    try readTransaction { _ in
      let file = target.kind == .page ? "pages/\(target.id.uuidString.lowercased()).json" : "spatial-ink.json"
      let key = target.kind == .page ? "drawingStamp" : "stamp"
      return try storedFragments(address: file + "#", descendants: false).first?.value[key]?.decode(VersionStamp.self).revision
    }
  }

  /// Resolve claims by ink address, including claimants outside the viewport.
  /// This is not a full-board read and missing scene membership is not deletion.
  public func graphicPresentation(on surface: SurfaceID, sourceInkIDs: Set<UUID>) throws -> NotebookGraphicPresentation {
    try readTransaction { _ in .init(try graphicClaimants(on: surface, sourceInkIDs: sourceInkIDs).map(\.candidate)) }
  }

  struct GraphicClaimant {
    let fragment: NotebookStoredFragment
    let candidate: NotebookGraphicPresentation.Candidate
  }

  func graphicClaimants(on surface: SurfaceID, sourceInkIDs: Set<UUID>) throws -> [GraphicClaimant] {
      guard let owner = surface.ownerID else { return [] }
      let ownerKey = surface.kind.rawValue + ":" + owner.uuidString.lowercased()
      var pending = sourceInkIDs, visited = Set<UUID>(), read = Set<String>()
      var candidates: [GraphicClaimant] = []
      while !pending.isEmpty {
        let batch = Array(pending.prefix(128)); pending.subtract(batch); visited.formUnion(batch)
        let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
        let rows = try currentSQL!.rows("SELECT DISTINCT address FROM graphic_sources WHERE owner=? AND stroke_id IN (\(placeholders)) ORDER BY address LIMIT 4097",
          [.text(ownerKey)] + batch.map { .text($0.uuidString.lowercased()) })
        try currentSQL!.sceneReadRecorder?.claims(owner: ownerKey, strokes: batch, rows: rows)
        for row in rows {
          let address = row[0].text!
          guard read.insert(address).inserted else { continue }
          guard read.count <= 4096 else { throw NotebookStorageError.limitExceeded("graphic_claims") }
          guard let fragment = try storedFragments(address: address, descendants: false).first,
            let id = fragment.value["id"]?.string,
            let graphic = try fragment.value["graphic"]?.decode(NotebookGraphic.self) else {
            throw NotebookStorageError.corruptRecord(address)
          }
          let prefix: [CollaborationPathComponent]
          if surface.kind == .page { prefix = [] }
          else {
            guard let boardID = fragment.parent?.components(separatedBy: "@").last else { throw NotebookStorageError.corruptRecord(address) }
            prefix = [.field("boards"), .member(boardID), .field("board")]
          }
          let path = prefix + [.field("elements"), .member(id), .field("graphic"), .field("sourceInkIDs")]
          guard let version = try collaborationFieldVersion(path: path, read: {
            try readCollaborationValue(file: fragment.file, path: $0)
          }) else { throw NotebookStorageError.corruptRecord("graphic source version") }
          candidates.append(.init(fragment: fragment, candidate: .init(id: id, graphic: graphic, version: version)))
          pending.formUnion(Set(graphic.sourceInkIDs).subtracting(visited))
        }
      }
      return candidates
  }
}

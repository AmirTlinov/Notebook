import Foundation

extension NotebookStore {
  /// The physical source is addressed. A board/cover without an element or
  /// region returns its light metadata and complete identity, not an archive.
  public func referenceSourceFiles(target: CollaborationTarget, elementID: String? = nil,
    region: PageRect? = nil, worldOrigin: WorldPoint? = nil) throws -> [String: JSONValue] {
    try readTransaction { _ in
      try readReferenceSourceFiles(target: target, elementID: elementID, region: region, worldOrigin: worldOrigin)
    }
  }

  func readReferenceSourceFiles(target: CollaborationTarget, elementID: String? = nil,
    region: PageRect? = nil, worldOrigin: WorldPoint? = nil) throws -> [String: JSONValue] {
    try Task.checkCancellation()
    let suffix = target.id.uuidString.lowercased() + ".json"
    switch target.kind {
    case .codeFragment:
      let file = codeFragmentFile(target.id)
      guard elementID == nil, let value = try storedValue(file) else { throw referenceMissing(target) }
      return [file: value, "spatial-ink.json": try .encode(readSpatialInk(surfaces: [.codeFragment(target.id)]))]
    case .page:
      let file = "pages/" + suffix
      if let elementID {
        guard let header = try storedFragments(address: file + "#", descendants: false).first,
          let element = try storedMember(file: file, collection: "elements", id: elementID) else { throw referenceMissing(target) }
        return [file: header.value.setting("elements", .array([element]))]
      }
      guard try hasStoredValue(file) else { throw referenceMissing(target) }
      return [file: try .encode(loadPage(target.id))]
    case .document:
      let file = "documents/" + suffix, state = "document-states/" + suffix
      if let elementID {
        guard let header = try storedFragments(address: file + "#", descendants: false).first,
          let block = try storedMember(file: file, collection: "blocks", id: elementID) else { throw referenceMissing(target) }
        let record = try storedMember(file: state, collection: "records", id: elementID)
        return [file: header.value.setting("blocks", .array([block])), state: .object(["records": .array(record.map { [$0] } ?? [])])]
      }
      guard try hasStoredValue(file) else { throw referenceMissing(target) }
      return [file: try .encode(loadDocument(target.id)), state: try .encode(loadDocumentState(target.id))]
    case .workspace:
      return ["workspace.json": try .encode(loadIndex())]
    case .board, .cover:
      guard let boardID = target.kind == .board ? target.id : target.boardID,
        let board = try readBoardNodeHeader(boardID), let hierarchy = try storedFragments(address: "board.json#", descendants: false).first,
        let workspace = try storedFragments(address: "workspace.json#", descendants: false).first else { throw referenceMissing(target) }
      let identity = try referenceIdentities(targets: [target])
      var node = try JSONValue.encode(board), items: [JSONValue] = [], files: [String: JSONValue] = [:]
      if target.kind == .cover {
        guard let item = try readItemHeader(target.id) else { throw referenceMissing(target) }
        items = [try .encode(item.item)]
        if item.kind == .document, let paper = try readDocumentPaperSize(target.id) { files["documents/" + suffix] = .object(["paperSize": try .encode(paper)]) }
      }
      var elements: [JSONValue] = []
      if let elementID {
        guard let element = try readSpatialElement(boardID: boardID, elementID: elementID),
          element.surface == (target.kind == .board ? .board(target.id) : .cover(target.id)) else { throw referenceMissing(target) }
        elements = [try .encode(element)]
      } else if let region {
        let bounds = WorkspaceSpatialBounds(origin: (target.kind == .board ? (worldOrigin ?? .zero) : .zero).offsetBy(x: region.x, y: region.y), width: region.width, height: region.height)
        var cursor: NotebookScenePaintCursor?
        repeat {
          let page = try readScenePaintOrder(boardID: boardID, coverID: target.kind == .cover ? target.id : nil, bounds: bounds, after: cursor)
          for entry in page.entries {
            guard case .element(let id) = entry.id, let element = try readSpatialElement(boardID: boardID, elementID: id) else { continue }
            guard elements.count < 128 else { throw NotebookStorageError.limitExceeded("reference_sources") }
            elements.append(try .encode(element))
          }
          cursor = page.next
        } while cursor != nil
      }
      node = node.setting("board", node["board"]!.setting("elements", .array(elements)))
      files["workspace.json"] = workspace.value.setting("items", .array(items))
      files["board.json"] = hierarchy.value.setting("boards", .array([node]))
      return try Self.bindReferenceIdentities(identity, to: files)
    }
  }

  private func referenceMissing(_ target: CollaborationTarget) -> CollaborationError {
    CollaborationError("target_missing", "Физический владелец либо его элемент отсутствует.", target: target)
  }

  public func targetContentRevision(target: CollaborationTarget) throws -> String {
    try readTransaction { _ in
      let value: JSONValue?
      switch target.kind {
      case .workspace:
        guard let workspace = try storedFragments(address: "workspace.json#", descendants: false).first?.value,
          workspace["rootBoardID"]?.string.flatMap(UUID.init(uuidString:)) == target.id else { throw referenceMissing(target) }
        value = workspace["stamp"]
      case .codeFragment: value = try storedFragments(address: codeFragmentFile(target.id) + "#", descendants: false).first?.value["stamp"]
      case .page: value = try storedFragments(address: pageFile(target.id) + "#", descendants: false).first?.value["agentStamp"]
      case .document: value = try storedFragments(address: documentFile(target.id) + "#", descendants: false).first?.value["contentStamp"]
      case .board:
        guard let revision = try boardContentRevision(target.id) else { throw referenceMissing(target) }
        return revision
      case .cover:
        guard let boardID = target.boardID, try ownerBoardID(of: target.id) == boardID,
          let revision = try boardContentRevision(boardID) else { throw referenceMissing(target) }
        return revision
      }
      guard let value else { throw referenceMissing(target) }
      return try value.decode(VersionStamp.self).revision
    }
  }
}

import Foundation

extension NotebookGraphicResolution {
  /// Agent reads expose this same projection without substituting it for the
  /// authored frame or bindings. Hidden intent remains addressable and editable.
  public func readProjection() throws -> JSONValue {
    switch self {
    case .geometry(let layout): return .object(["state":.string("geometry"),"frame":try .encode(layout.frame)])
    case .hidden: return .object(["state":.string("hidden")])
    case .pending(let ids): return .object(["state":.string("pending"),"dependencies":.array(ids.sorted().map(JSONValue.string))])
    }
  }
}

extension PageDocument {
  public func graphicReadProjection() throws -> JSONValue {
    var value = try JSONValue.encode(self)
    let graph = graphicGraph()
    value = try value.setting("elements",.array(elements.map { element in
      let raw = try JSONValue.encode(element)
      return try element.graphic == nil ? raw : raw.setting("graphicResolution",graph.resolve(element.id).readProjection())
    }))
    return value
  }
}

extension NotebookStore {
  /// Resolve two addressed endpoints, including off-window and hidden records.
  /// The canonical record stays unchanged; callers receive a derived layout.
  public func readGraphicResolution(target: CollaborationTarget, elementID: String) throws -> NotebookGraphicResolution {
    try readTransaction { _ in
      let surface: SurfaceID
      switch target.kind {
      case .page: surface = .page(target.id)
      case .board: surface = .board(target.id)
      case .cover: surface = .cover(target.id)
      default: throw NotebookStorageError.invalidTransaction("graphic owner")
      }
      func read(_ id: String) throws -> NotebookGraphicGraph.Node? {
        let graphic: NotebookGraphic, frame: PageRect, origin: WorldPoint
        if target.kind == .page {
          guard let value = try readPageElement(pageID: target.id, elementID: id), let payload = value.graphic else { return nil }
          graphic = payload; frame = value.frame; origin = .zero
        } else {
          guard let value = try readSpatialElement(boardID: target.boardID ?? target.id, elementID: id),
            value.surface == surface, let payload = value.graphic else { return nil }
          graphic = payload; frame = .init(x: value.frame.x,y: value.frame.y,width: value.frame.width,height: value.frame.height)
          origin = value.worldOrigin ?? .zero
        }
        let shown = try graphic.showsGeometry && (graphic.sourceInkIDs.isEmpty
          || graphicPresentation(on: surface, sourceInkIDs: Set(graphic.sourceInkIDs)).geometryIDs.contains(id))
        return .init(id: id, graphic: graphic, frame: frame, origin: origin, surface: surface, shown: shown)
      }
      guard let element = try read(elementID) else { return .pending([elementID]) }
      var nodes = [element]
      for id in Set(element.graphic.connection?.bindings.map(\.elementID) ?? []) {
        if let node = try read(id) { nodes.append(node) }
      }
      return NotebookGraphicGraph(nodes).resolve(elementID)
    }
  }

  /// Endpoint sources are part of a bounded read, not additional live hosts.
  /// Reading a claim component preserves the same ink/geometry arbitration as
  /// the spatial index, even when its winning author lies outside the window.
  func appendGraphicDependencies(to rows: inout [NotebookStoredFragment], boardAddress: String) throws {
    var seen = Set(rows.map(\.address))
    guard seen.count <= 4096 else { throw NotebookStorageError.limitExceeded("graphic_dependencies") }
    let initial = rows.filter { $0.collection == "board/elements" }
    var dependencies: [NotebookStoredFragment] = []
    for row in initial {
      guard let graphic = try row.value["graphic"]?.decode(NotebookGraphic.self) else { continue }
      for id in Set(graphic.connection?.bindings.map(\.elementID) ?? []) {
        let address = boardAddress + "/board/elements/@" + fieldKey([collaborationIdentity(id)])
        if seen.insert(address).inserted, let dependency = try storedFragments(address: address, descendants: false).first {
          guard seen.count <= 4096 else { throw NotebookStorageError.limitExceeded("graphic_dependencies") }
          dependencies.append(dependency)
        }
      }
    }
    rows += dependencies
    for row in dependencies {
      guard let graphic = try row.value["graphic"]?.decode(NotebookGraphic.self), !graphic.sourceInkIDs.isEmpty,
        let surface = try row.value["surface"]?.decode(SurfaceID.self) else { continue }
      for claimant in try graphicClaimants(on: surface, sourceInkIDs: Set(graphic.sourceInkIDs)) {
        if seen.insert(claimant.fragment.address).inserted {
          guard seen.count <= 4096 else { throw NotebookStorageError.limitExceeded("graphic_dependencies") }
          rows.append(claimant.fragment)
        }
      }
    }
    guard rows.count <= 4096 else { throw NotebookStorageError.limitExceeded("graphic_dependencies") }
  }

  func dependentGraphicAddresses(owner: String, id: String) throws -> [String] {
    try currentSQL!.rows("SELECT DISTINCT address FROM graphic_bindings WHERE owner=? AND target_id=?",
      [.text(owner), .text(collaborationIdentity(id))]).compactMap { $0[0].text }
  }
}

import Foundation

/// A movable physical owner, or one stable element on a surface. Ink is never a subject.
public struct CollaborationSubject: Codable, Hashable, Sendable {
  public let target: CollaborationTarget
  public let elementID: String?
  public init(target: CollaborationTarget, elementID: String? = nil) { self.target = target; self.elementID = elementID }
}

public struct CollaborationPlacementItem: Codable, Sendable {
  public enum Direction: String, Codable, Sendable { case right, below, free }
  public let id: String
  public let size: PageSize
  public let relativeTo: CollaborationReference?
  /// A preceding result in this same package can anchor the next part of a thought.
  public let relativeToID: String?
  public let direction: Direction
  public init(id: String, size: PageSize, relativeTo: CollaborationReference? = nil,
    relativeToID: String? = nil, direction: Direction = .free) {
    self.id = id; self.size = size; self.relativeTo = relativeTo; self.relativeToID = relativeToID; self.direction = direction
  }
}

public struct CollaborationPlacementRequest: Codable, Sendable {
  public let target: CollaborationTarget
  public let expectedRevision: String
  public let items: [CollaborationPlacementItem]
  public let movable: [CollaborationSubject]
  public let contextID: UUID?
  public let additionalOwners: [CollaborationTarget]
  public let worldOrigin: WorldPoint?
  public init(target: CollaborationTarget, expectedRevision: String, items: [CollaborationPlacementItem],
    movable: [CollaborationSubject] = [], contextID: UUID? = nil, additionalOwners: [CollaborationTarget] = [], worldOrigin: WorldPoint? = nil) {
    self.target = target; self.expectedRevision = expectedRevision; self.items = items; self.movable = movable
    self.contextID = contextID; self.additionalOwners = additionalOwners; self.worldOrigin = worldOrigin
  }
}

public struct CollaborationPlacement: Codable, Sendable {
  public enum Status: String, Codable, Sendable { case ready, snapshotPending = "snapshot_pending", unavailable = "placement_unavailable" }
  public struct Item: Codable, Sendable {
    public let id: String
    public let frame: PageRect
    public let worldOrigin: WorldPoint?
  }
  public let status: Status
  public let target: CollaborationTarget
  public let placements: [Item]
  public let moves: [CollaborationOperation]
  public let expected: [CollaborationExpectation]
  public let contextID: UUID?
  public let additionalOwners: [CollaborationTarget]
  public let sourceRevision: String
  public let suggestion: String?
  public let renderRequest: TargetRenderRequest?
}

extension NotebookStore {
  /// Calculation only. Every proposal names the final ink and geometry inspected,
  /// so applying it later must pass the normal transaction's revision checks again.
  public func suggestCollaborationPlacement(_ request: CollaborationPlacementRequest) throws -> CollaborationPlacement {
    guard (1...32).contains(request.items.count), request.movable.count <= 32, request.additionalOwners.count <= 32,
      Set(request.items.map(\.id)).count == request.items.count,
      Set(request.movable).count == request.movable.count,
      request.items.allSatisfy({ !$0.id.isEmpty && $0.id.count <= 120 && $0.size.isValid && $0.size.width <= 2048 && $0.size.height <= 2048 && ($0.relativeTo == nil || $0.relativeToID == nil) }) else {
      throw CollaborationError("invalid_placement", "Пакет содержит до 32 уникальных элементов и явно разрешённых перемещений.")
    }
    var preceding = Set<String>()
    for item in request.items {
      if let id = item.relativeToID, !preceding.contains(id) { throw CollaborationError("invalid_placement", "Опора должна предшествовать элементу в том же пакете.") }
      preceding.insert(item.id)
    }
    let files = try collaborationSnapshot()
    let content = try CollaborationContent(files: files)
    let contexts = try files["collaboration/contexts.json"]?.decode(SharedContextSnapshot.self) ?? .init()
    let context = try Self.placementContext(request.contextID, in: contexts.contexts)
    let target = request.target
    let actual = try Self.targetContentRevision(target: target, files: files)
    guard actual == request.expectedRevision.lowercased() else {
      throw CollaborationError("revision_conflict", "Геометрия изменилась.", target: target, expected: request.expectedRevision, actual: actual)
    }
    let source = try Self.referenceRevision(target: target, files: files)
    let expected = [CollaborationExpectation(target: target, revision: actual, sourceRevision: source)]
    func result(_ status: CollaborationPlacement.Status, placements: [CollaborationPlacement.Item] = [], moves: [CollaborationOperation] = [], suggestion: String? = nil, render: TargetRenderRequest? = nil) -> CollaborationPlacement {
      .init(status: status, target: target, placements: placements, moves: moves, expected: expected, contextID: request.contextID,
        additionalOwners: request.additionalOwners, sourceRevision: source, suggestion: suggestion, renderRequest: render)
    }
    guard target.kind != .document && target.kind != .workspace else {
      return result(.unavailable, suggestion: "Продолжите поток документа операцией insertBlock после выбранного блока.")
    }
    let geometry = try PlacementGeometry(target: target, content: content, origin: request.worldOrigin, anchor: request.items.first?.relativeTo)
    let existingIDs = Set(geometry.obstacles.compactMap { $0.subject?.elementID })
    guard existingIDs.isDisjoint(with: request.items.map(\.id)) else { throw CollaborationError("invalid_placement", "Новые ID не заменяют существующие элементы.") }
    var movable: [PlacementGeometry.Obstacle] = []
    for subject in request.movable {
      guard let obstacle = geometry.obstacles.first(where: { $0.subject == subject }), obstacle.canMove else {
        throw CollaborationError("placement_unavailable", "Перемещаемый предмет должен быть свободным участником этой поверхности. Стопку сохраняйте целиком.", target: subject.target)
      }
      try Self.requireCompositionScope(subject, references: context?.entries.flatMap(\.references) ?? [], additionalOwners: request.additionalOwners, files: files)
      movable.append(obstacle)
    }
    let render = try requestTargetRender(target: target, expectedRevision: actual,
      region: target.kind == .board ? .init(x: 0, y: 0, width: geometry.extent.width, height: geometry.extent.height) : nil, worldOrigin: geometry.origin)
    guard let data = try? Data(contentsOf: targetReceiptURL(render.id)),
      let receipt = try? JSONDecoder().decode(TargetRenderReceipt.self, from: data), receipt.status == "ready",
      receipt.request == render, render.sourceRevision == source else {
      return result(.snapshotPending, suggestion: "Подготавливается карта окончательных чернил. Повторите пакет после снимка.", render: render)
    }
    let fixed = geometry.obstacles.filter { obstacle in !movable.contains { $0.subject == obstacle.subject } }.map(\.frame) + receipt.inkRegions
    func pack(allowMoves: Bool) throws -> ([CollaborationPlacement.Item], [CollaborationOperation])? {
      var obstacles = allowMoves ? fixed : geometry.obstacles.map(\.frame) + receipt.inkRegions
      var placements: [CollaborationPlacement.Item] = []
      for item in request.items {
        let anchor: PageRect
        if let id = item.relativeToID {
          guard let previous = placements.first(where: { $0.id == id }) else { throw CollaborationError("invalid_placement", "Опора должна предшествовать элементу в том же пакете.") }
          anchor = previous.frame
        } else { anchor = try geometry.anchor(item.relativeTo) }
        guard let frame = Self.freeCollaborationFrame(size: item.size, extent: geometry.extent, anchor: anchor,
          direction: item.direction.rawValue, obstacles: obstacles) else { return nil }
        placements.append(.init(id: item.id, frame: frame, worldOrigin: geometry.origin)); obstacles.append(frame)
      }
      var moves: [CollaborationOperation] = []
      if allowMoves {
        for obstacle in movable {
          let frame: PageRect
          if Self.collaborationFrameIsFree(obstacle.frame, extent: geometry.extent, obstacles: obstacles) { frame = obstacle.frame }
          else if let available = Self.freeCollaborationFrame(size: .init(width: obstacle.frame.width, height: obstacle.frame.height),
            extent: geometry.extent, anchor: obstacle.frame, direction: "free", obstacles: obstacles) { frame = available }
          else { return nil }
          obstacles.append(frame)
          if frame != obstacle.frame, let subject = obstacle.subject {
            if let id = subject.elementID {
              var values = ["frame": try JSONValue.encode(frame)]
              if let origin = geometry.origin { values["worldOrigin"] = try .encode(origin) }
              moves.append(.init(kind: .updateElement, target: subject.target, id: id, values: values))
            } else if let origin = geometry.origin {
              moves.append(.init(kind: .moveItem, target: target, id: subject.target.id.uuidString,
                values: ["center": try .encode(origin.offsetBy(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2))]))
            }
          }
        }
      }
      return (placements, moves)
    }
    if let packed = try pack(allowMoves: false) { return result(.ready, placements: packed.0) }
    if !movable.isEmpty, let packed = try pack(allowMoves: true) { return result(.ready, placements: packed.0, moves: packed.1) }
    return result(.unavailable, suggestion: "Весь пакет здесь не помещается. Уменьшите композицию либо продолжите на другом листе или участке доски.")
  }

  static func placementContext(_ id: UUID?, in contexts: [SharedContext]) throws -> SharedContext? {
    guard let id else { return nil }
    guard let context = contexts.first(where: { $0.id == id }) else { throw CollaborationError("context_missing", "Общий фрагмент не найден.") }
    return context
  }

  public static func freeCollaborationFrame(size: PageSize, extent: PageSize, anchor: PageRect,
    direction: String, obstacles: [PageRect]) -> PageRect? {
    guard size.isValid, extent.isValid, size.width <= extent.width, size.height <= extent.height else { return nil }
    var preferred: PageRect?
    if direction == "right" { preferred = .init(x: anchor.x + anchor.width + 24, y: max(20, anchor.y), width: size.width, height: size.height) }
    if direction == "below" { preferred = .init(x: max(20, anchor.x), y: anchor.y + anchor.height + 24, width: size.width, height: size.height) }
    if let preferred, collaborationFrameIsFree(preferred, extent: extent, obstacles: obstacles) { return preferred }
    // Iterate rather than allocate every grid candidate. The caller bounds the surface.
    var y = 20.0
    while y + size.height <= extent.height - 20 {
      var x = 20.0
      while x + size.width <= extent.width - 20 {
        let candidate = PageRect(x: x, y: y, width: size.width, height: size.height)
        if collaborationFrameIsFree(candidate, extent: extent, obstacles: obstacles) { return candidate }
        x += 32
      }
      y += 32
    }
    return nil
  }

  static func collaborationFrameIsFree(_ rect: PageRect, extent: PageSize, obstacles: [PageRect]) -> Bool {
    guard rect.x >= 0, rect.y >= 0, rect.x + rect.width <= extent.width, rect.y + rect.height <= extent.height else { return false }
    return !obstacles.contains { rect.x < $0.x + $0.width + 24 && rect.x + rect.width + 24 > $0.x
      && rect.y < $0.y + $0.height + 24 && rect.y + rect.height + 24 > $0.y }
  }
}

private struct PlacementGeometry {
  struct Obstacle {
    let subject: CollaborationSubject?
    let frame: PageRect
    let canMove: Bool
  }
  let target: CollaborationTarget
  let extent: PageSize
  let origin: WorldPoint?
  let obstacles: [Obstacle]

  init(target: CollaborationTarget, content: CollaborationContent, origin requestedOrigin: WorldPoint?, anchor: CollaborationReference?) throws {
    self.target = target
    var origin = target.kind == .board ? (requestedOrigin ?? anchor?.worldOrigin ?? .zero) : nil
    var extent = PageSize(width: 2048, height: 2048)
    var obstacles: [Obstacle] = []
    if target.kind == .page {
      guard let page = content.pages.first(where: { $0.id == target.id }) else { throw CollaborationError("target_missing", "Лист отсутствует.") }
      extent = page.size
      obstacles = page.elements.map { .init(subject: .init(target: target, elementID: $0.id), frame: $0.frame, canMove: true) }
    } else {
      guard let board = content.hierarchy.board(target.boardID ?? target.id) else { throw CollaborationError("target_missing", "Доска отсутствует.") }
      func itemGeometry(_ id: UUID) -> WorkspaceItemGeometry {
        content.documents.first(where: { $0.id == id }).map { .document($0.paperSize) } ?? .notebook
      }
      if target.kind == .cover {
        let g = itemGeometry(target.id); extent = .init(width: g.width, height: g.height)
      } else if requestedOrigin == nil, let anchor, anchor.target.kind == .cover, let center = board.focusedCenter(of: anchor.target.id) {
        let g = itemGeometry(anchor.target.id); origin = center.offsetBy(x: -g.width / 2 - 20, y: -g.height / 2 - 20)
      }
      for element in board.elements where element.surface == (target.kind == .board ? .board(target.id) : .cover(target.id)) {
        let delta = origin.flatMap { local in element.worldOrigin.map { local.delta(to: $0) } } ?? .zero
        obstacles.append(.init(subject: .init(target: target, elementID: element.id),
          frame: .init(x: element.frame.x + delta.x, y: element.frame.y + delta.y, width: element.frame.width, height: element.frame.height), canMove: true))
      }
      if let origin {
        for id in board.itemIDs {
          guard let center = board.focusedCenter(of: id) else { continue }
          let g = itemGeometry(id), delta = origin.delta(to: center)
          let stacked = board.stacks.contains { $0.itemIDs.contains(id) }
          let margin = stacked ? g.width : 0
          obstacles.append(.init(subject: .init(target: .init(kind: .cover, id: id, boardID: target.id)),
            frame: .init(x: delta.x - g.width / 2 - margin, y: delta.y - g.height / 2 - margin, width: g.width + margin * 2, height: g.height + margin * 2), canMove: !stacked))
        }
      }
    }
    self.extent = extent; self.origin = origin; self.obstacles = obstacles
  }

  func anchor(_ reference: CollaborationReference?) throws -> PageRect {
    guard let reference else { return .init(x: 20, y: 20, width: 1, height: 1) }
    if let obstacle = obstacles.first(where: { $0.subject == .init(target: reference.target, elementID: reference.elementID) }) { return obstacle.frame }
    guard reference.target == target, let region = reference.region else { throw CollaborationError("invalid_placement", "Опора должна принадлежать поверхности размещения.") }
    let delta = origin.flatMap { local in reference.worldOrigin.map { local.delta(to: $0) } } ?? .zero
    return .init(x: region.x + delta.x, y: region.y + delta.y, width: region.width, height: region.height)
  }
}

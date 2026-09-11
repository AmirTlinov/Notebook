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
  /// Does not place content, but may enqueue the exact ink render it requires.
  /// The native command queue owns that request. Every proposal names the final
  /// ink and geometry; applying it must pass the usual revision checks again.
  public func suggestCollaborationPlacement(_ request: CollaborationPlacementRequest) throws -> CollaborationPlacement {
    guard (1...32).contains(request.items.count), request.movable.count <= 32, request.additionalOwners.count <= 32,
      Set(request.items.map { collaborationIdentity($0.id) }).count == request.items.count,
      Set(request.movable.map { CollaborationSubject(target: $0.target, elementID: $0.elementID.map(collaborationIdentity)) }).count == request.movable.count,
      (request.worldOrigin?.isValid ?? true),
      request.items.allSatisfy({ !$0.id.isEmpty && $0.id.count <= 120 && $0.size.isValid && $0.size.width <= 2048 && $0.size.height <= 2048 && ($0.relativeTo == nil || $0.relativeToID == nil)
        && ($0.relativeTo?.worldOrigin?.isValid ?? true) && ($0.relativeTo?.region.map(placementValidRect) ?? true) }) else {
      throw CollaborationError("invalid_placement", "Пакет содержит до 32 уникальных элементов и явно разрешённых перемещений.")
    }
    var preceding = Set<String>()
    for item in request.items {
      if let id = item.relativeToID, !preceding.contains(id) { throw CollaborationError("invalid_placement", "Опора должна предшествовать элементу в том же пакете.") }
      preceding.insert(item.id)
    }
    var references: [UUID: CollaborationReference] = [:]
    for reference in request.items.compactMap(\.relativeTo) {
      if let previous = references[reference.id], previous != reference {
        throw CollaborationError("invalid_placement", "ID опоры принадлежит одному исходному фрагменту.")
      }
      references[reference.id] = reference
    }
    let budget = NotebookPlacementBudget()
    let cut = try readPlacement(request, budget: budget)
    let target = request.target, actual = cut.revision, source = cut.sourceRevision
    let expected = [CollaborationExpectation(target: target, revision: actual, sourceRevision: source)]
    func result(_ status: CollaborationPlacement.Status, placements: [CollaborationPlacement.Item] = [], moves: [CollaborationOperation] = [], suggestion: String? = nil, render: TargetRenderRequest? = nil) -> CollaborationPlacement {
      .init(status: status, target: target, placements: placements, moves: moves, expected: expected, contextID: request.contextID,
        additionalOwners: request.additionalOwners, sourceRevision: source, suggestion: suggestion, renderRequest: render)
    }
    guard let geometry = cut.geometry else {
      return result(.unavailable, suggestion: "Продолжите поток документа операцией insertBlock после выбранного блока.")
    }
    let movable = cut.movable
    let render = try placementRender(cut, budget: budget)
    let candidateReceipt: TargetRenderReceipt?
    do { candidateReceipt = try loadTargetRenderReceipt(render.id) }
    catch let error as CollaborationError where error.code == "resource_limit" { throw NotebookPlacementBudget.exceeded("ink_map_bytes") }
    catch { candidateReceipt = nil }
    guard let receipt = candidateReceipt, receipt.status == "ready",
      receipt.request == render, render.sourceRevision == source else {
      return result(.snapshotPending, suggestion: "Подготавливается карта окончательных чернил. Повторите пакет после снимка.", render: render)
    }
    guard receipt.inkRegions.count <= NotebookPlacementBudget.maximumObstacles else { throw NotebookPlacementBudget.exceeded("ink_regions") }
    guard receipt.inkRegions.allSatisfy(placementValidRect) else {
      throw CollaborationError("invalid_artifact", "Карта окончательных чернил содержит некорректную область.")
    }
    let fixed = geometry.obstacles.filter { obstacle in !movable.contains { $0.subject == obstacle.subject } }.map(\.frame) + receipt.inkRegions
    func pack(allowMoves: Bool) throws -> ([CollaborationPlacement.Item], [CollaborationOperation])? {
      try Task.checkCancellation()
      var obstacles = allowMoves ? fixed : geometry.obstacles.map(\.frame) + receipt.inkRegions
      var placements: [CollaborationPlacement.Item] = []
      for item in request.items {
        let anchor: PageRect
        if let id = item.relativeToID {
          guard let previous = placements.first(where: { $0.id == id }) else { throw CollaborationError("invalid_placement", "Опора должна предшествовать элементу в том же пакете.") }
          anchor = previous.frame
        } else { anchor = geometry.anchor(item.relativeTo) }
        guard let frame = try Self.findCollaborationFrame(size: item.size, extent: geometry.extent, anchor: anchor,
          direction: item.direction.rawValue, isFree: { try Self.placementFrameIsFree($0, extent: geometry.extent, obstacles: obstacles, budget: budget) }) else { return nil }
        placements.append(.init(id: item.id, frame: frame, worldOrigin: geometry.origin)); obstacles.append(frame)
      }
      var moves: [CollaborationOperation] = []
      if allowMoves {
        for obstacle in movable {
          let frame: PageRect
          if try Self.placementFrameIsFree(obstacle.frame, extent: geometry.extent, obstacles: obstacles, budget: budget) { frame = obstacle.frame }
          else if obstacle.frame.width <= PageSize.maximumDimension, obstacle.frame.height <= PageSize.maximumDimension,
            let available = try Self.findCollaborationFrame(size: .init(width: obstacle.frame.width, height: obstacle.frame.height),
              extent: geometry.extent, anchor: obstacle.frame, direction: "free",
              isFree: { try Self.placementFrameIsFree($0, extent: geometry.extent, obstacles: obstacles, budget: budget) }) { frame = available }
          else { return nil }
          obstacles.append(frame)
          if frame != obstacle.frame {
            let subject = obstacle.subject
            if let id = subject.elementID {
              var values = ["frame": try JSONValue.encode(frame)]
              if let origin = geometry.origin { values["worldOrigin"] = try .encode(origin) }
              moves.append(.init(kind: .updateElement, target: subject.target, id: id, values: values))
            } else if let origin = geometry.origin {
              moves.append(.init(kind: .moveItem, target: target, id: subject.target.id.uuidString,
                values: ["center": try .encode(placementOffset(origin, x: frame.x + frame.width / 2, y: frame.y + frame.height / 2))]))
            }
          }
        }
      }
      try Task.checkCancellation()
      return (placements, moves)
    }
    if let packed = try pack(allowMoves: false) { return result(.ready, placements: packed.0) }
    if !movable.isEmpty, let packed = try pack(allowMoves: true) { return result(.ready, placements: packed.0, moves: packed.1) }
    return result(.unavailable, suggestion: "Весь пакет здесь не помещается. Уменьшите композицию либо продолжите на другом листе или участке доски.")
  }

  // The only side effect of planning is an addressed render request. The
  // writer binds it to the complete read cut, not merely its geometry stamp.
  func placementRender(_ cut: NotebookPlacementRead, budget: NotebookPlacementBudget) throws -> TargetRenderRequest {
    guard let geometry = cut.geometry else { throw CollaborationError("placement_unavailable", "Поверхность не поддерживает размещение рамок.") }
    if let origin = geometry.origin {
      // JSONValue currently carries numeric coordinates as Double. Reject an
      // unrepresentable render before the command, instead of rounding a tile
      // or publishing a request that cannot subsequently be decoded.
      try requirePlacementJSONCoordinates(origin)
      try requirePlacementJSONCoordinates(placementOffset(origin, x: geometry.extent.width, y: geometry.extent.height))
    }
    let target = geometry.target, actual = cut.revision, source = cut.sourceRevision
    return try commandTransaction {
      try budget.withSQL(currentSQL!) {
        let current = try targetContentRevision(target: target)
        guard current == actual else {
          throw CollaborationError("revision_conflict", "Геометрия изменилась.", target: target, expected: actual, actual: current)
        }
        let currentSource = try placementSourceRevision(target)
        guard currentSource == source else {
          throw CollaborationError("source_conflict", "Рассмотренное содержание изменилось.", target: target, expected: source, actual: currentSource)
        }
        return try requestTargetRender(target: target, expectedRevision: actual,
          region: target.kind == .board ? .init(x: 0, y: 0, width: geometry.extent.width, height: geometry.extent.height) : nil, worldOrigin: geometry.origin)
      }
    }
  }

  public static func freeCollaborationFrame(size: PageSize, extent: PageSize, anchor: PageRect,
    direction: String, obstacles: [PageRect]) -> PageRect? {
    findCollaborationFrame(size: size, extent: extent, anchor: anchor, direction: direction,
      isFree: { collaborationFrameIsFree($0, extent: extent, obstacles: obstacles) })
  }

  private static func findCollaborationFrame(size: PageSize, extent: PageSize, anchor: PageRect,
    direction: String, isFree: (PageRect) throws -> Bool) rethrows -> PageRect? {
    guard size.isValid, extent.isValid, size.width <= extent.width, size.height <= extent.height else { return nil }
    var preferred: PageRect?
    if direction == "right" { preferred = .init(x: anchor.x + anchor.width + 24, y: max(20, anchor.y), width: size.width, height: size.height) }
    if direction == "below" { preferred = .init(x: max(20, anchor.x), y: anchor.y + anchor.height + 24, width: size.width, height: size.height) }
    if let preferred, try isFree(preferred) { return preferred }
    // Iterate rather than allocate every grid candidate. The caller bounds the surface.
    var y = 20.0
    while y + size.height <= extent.height - 20 {
      var x = 20.0
      while x + size.width <= extent.width - 20 {
        let candidate = PageRect(x: x, y: y, width: size.width, height: size.height)
        if try isFree(candidate) { return candidate }
        x += 32
      }
      y += 32
    }
    return nil
  }

  private static func placementFrameIsFree(_ rect: PageRect, extent: PageSize,
    obstacles: [PageRect], budget: NotebookPlacementBudget) throws -> Bool {
    guard rect.isContained(in: extent) else { return false }
    for obstacle in obstacles {
      try budget.compare()
      if collaborationFramesOverlap(rect, obstacle) { return false }
    }
    return true
  }

  private static func collaborationFramesOverlap(_ rect: PageRect, _ obstacle: PageRect) -> Bool {
    rect.x < obstacle.x + obstacle.width + 24 && rect.x + rect.width + 24 > obstacle.x
      && rect.y < obstacle.y + obstacle.height + 24 && rect.y + rect.height + 24 > obstacle.y
  }

  static func collaborationFrameIsFree(_ rect: PageRect, extent: PageSize, obstacles: [PageRect]) -> Bool {
    rect.isContained(in: extent) && !obstacles.contains { collaborationFramesOverlap(rect, $0) }
  }
}

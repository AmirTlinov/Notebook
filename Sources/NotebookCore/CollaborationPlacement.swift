import Foundation

public struct CollaborationPlacement: Codable, Sendable {
  public let status: String
  public let target: CollaborationTarget
  public let frame: PageRect?
  public let worldOrigin: WorldPoint?
  public let expected: [CollaborationExpectation]
  public let sourceRevision: String
  public let suggestion: String?
  public let renderRequest: TargetRenderRequest?
}

extension NotebookStore {
  public func suggestCollaborationPlacement(target: CollaborationTarget, expectedRevision: String,
    size: PageSize, relativeTo reference: CollaborationReference?, direction: String) throws -> CollaborationPlacement {
    guard size.isValid, ["right", "below", "free"].contains(direction) else {
      throw CollaborationError("invalid_placement", "Укажите положительный размер и направление right, below либо free.")
    }
    let content = try collaborationContent(), files = try content.sourceFiles()
    let actual = try Self.targetContentRevision(target: target, files: files)
    guard actual == expectedRevision.lowercased() else { throw CollaborationError("revision_conflict", "Геометрия изменилась.", target: target, expected: expectedRevision, actual: actual) }
    let source = try Self.referenceRevision(target: target, files: files)
    let expected = [CollaborationExpectation(target: target, revision: actual, sourceRevision: source)]
    var extent = PageSize(width: 2048, height: 2048)
    var origin: WorldPoint? = target.kind == .board ? (reference?.worldOrigin ?? .zero) : nil
    var anchor = reference?.region ?? PageRect(x: 20, y: 20, width: 1, height: 1)
    var obstacles: [PageRect] = []
    switch target.kind {
    case .page:
      guard let page = content.pages.first(where: { $0.id == target.id }) else { throw CollaborationError("target_missing", "Лист отсутствует.") }
      extent = page.size; obstacles = page.elements.map(\.frame)
      if let id = reference?.elementID, let element = page.elements.first(where: { $0.id == id }) { anchor = element.frame }
    case .cover, .board:
      guard let board = content.hierarchy.board(target.boardID ?? target.id) else { throw CollaborationError("target_missing", "Доска отсутствует.") }
      let geometry = content.documents.first(where: { $0.id == target.id }).map { WorkspaceItemGeometry.document($0.paperSize) } ?? .notebook
      if target.kind == .cover { extent = .init(width: geometry.width, height: geometry.height) }
      if target.kind == .board, let reference, reference.target.kind == .cover,
        let center = board.focusedCenter(of: reference.target.id) {
        let g = content.documents.first(where: { $0.id == reference.target.id }).map { WorkspaceItemGeometry.document($0.paperSize) } ?? .notebook
        origin = center.offsetBy(x: -g.width / 2 - 20, y: -g.height / 2 - 20)
        anchor = .init(x: 20, y: 20, width: g.width, height: g.height)
      }
      for element in board.elements where element.surface == (target.kind == .board ? .board(target.id) : .cover(target.id)) {
        var rect = PageRect(x: element.frame.x, y: element.frame.y, width: element.frame.width, height: element.frame.height)
        if let origin, let world = element.worldOrigin {
          let delta = origin.delta(to: world)
          rect = .init(x: delta.x + rect.x, y: delta.y + rect.y, width: rect.width, height: rect.height)
        }
        obstacles.append(rect)
        if element.id == reference?.elementID { anchor = rect }
      }
      if let origin {
        for id in board.itemIDs {
          guard let center = board.focusedCenter(of: id) else { continue }
          let g = content.documents.first(where: { $0.id == id }).map { WorkspaceItemGeometry.document($0.paperSize) } ?? .notebook
          let delta = origin.delta(to: center)
          // The full fan reserves its cover sweep, independently of camera zoom.
          let margin = board.stacks.contains { $0.itemIDs.contains(id) } ? g.width : 0
          obstacles.append(.init(x: delta.x - g.width / 2 - margin, y: delta.y - g.height / 2 - margin,
            width: g.width + margin * 2, height: g.height + margin * 2))
        }
      }
    case .document, .workspace:
      return .init(status: "placement_unavailable", target: target, frame: nil, worldOrigin: nil,
        expected: expected, sourceRevision: source, suggestion: "Продолжите поток документа операцией insertBlock после выбранного блока.", renderRequest: nil)
    }
    let render = try requestTargetRender(target: target, expectedRevision: actual,
      region: target.kind == .board ? .init(x: 0, y: 0, width: extent.width, height: extent.height) : nil, worldOrigin: origin)
    guard let data = try? Data(contentsOf: targetReceiptURL(render.id)),
      let receipt = try? JSONDecoder().decode(TargetRenderReceipt.self, from: data), receipt.status == "ready",
      receipt.request.sourceRevision == source else {
      return .init(status: "snapshot_pending", target: target, frame: nil, worldOrigin: origin,
        expected: expected, sourceRevision: source, suggestion: "Подготавливается карта окончательных чернил. Повторите размещение после снимка.", renderRequest: render)
    }
    obstacles.append(contentsOf: receipt.inkRegions)
    let result = Self.freeCollaborationFrame(size: size, extent: extent, anchor: anchor, direction: direction, obstacles: obstacles)
    return .init(status: result == nil ? "placement_unavailable" : "ready", target: target, frame: result, worldOrigin: origin,
      expected: expected, sourceRevision: source,
      suggestion: result == nil ? "На этой поверхности место занято. Продолжите на новом листе либо рядом с предметом на доске." : nil, renderRequest: nil)
  }

  public static func freeCollaborationFrame(size: PageSize, extent: PageSize, anchor: PageRect,
    direction: String, obstacles: [PageRect]) -> PageRect? {
    let gap = 24.0
    var candidates: [PageRect] = []
    if direction == "right" { candidates.append(.init(x: anchor.x + anchor.width + gap, y: max(20,anchor.y), width: size.width, height: size.height)) }
    if direction == "below" { candidates.append(.init(x: max(20,anchor.x), y: anchor.y + anchor.height + gap, width: size.width, height: size.height)) }
    var y = 20.0
    while y + size.height <= extent.height - 20 {
      var x = 20.0
      while x + size.width <= extent.width - 20 {
        candidates.append(.init(x:x,y:y,width:size.width,height:size.height)); x += 32
      }
      y += 32
    }
    return candidates.first { rect in
      guard rect.x >= 0, rect.y >= 0, rect.x + rect.width <= extent.width, rect.y + rect.height <= extent.height else { return false }
      return !obstacles.contains { other in rect.x < other.x + other.width + gap && rect.x + rect.width + gap > other.x
        && rect.y < other.y + other.height + gap && rect.y + rect.height + gap > other.y }
    }
  }
}

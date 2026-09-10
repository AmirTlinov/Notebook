import CSQLite
import Foundation

/// A proposal has a finite read and packing allowance. Reaching it is not an
/// empty region: no partial plan may escape as a successful placement.
final class NotebookPlacementBudget {
  static let maximumObstacles = 4_096
  static let maximumSourceBytes = 16 * 1_024 * 1_024
  private let maximumSQLSteps: Int
  private let maximumComparisons: Int
  private(set) var sqlSteps = 0
  private(set) var comparisons = 0
  private(set) var inspectedObstacles = 0
  private var metadataBytes = 0
  private var interrupted = false
  private var cancelled = false

  init(sqlSteps: Int = 500_000, comparisons: Int = 4_000_000) {
    maximumSQLSteps = sqlSteps; maximumComparisons = comparisons
  }

  func withSQL<T>(_ database: NotebookSQLConnection, _ operation: () throws -> T) throws -> T {
    try Task.checkCancellation()
    // SQLite resets the progress interval for short statements. Interval one
    // counts their total too; a sequence of indexed point reads cannot evade
    // the allowance simply because each individual statement is inexpensive.
    sqlite3_progress_handler(database.handle, 1, { pointer in
      guard let pointer else { return 1 }
      let budget = Unmanaged<NotebookPlacementBudget>.fromOpaque(pointer).takeUnretainedValue()
      budget.sqlSteps += 1
      if budget.sqlSteps & 255 == 0 { budget.cancelled = withUnsafeCurrentTask { $0?.isCancelled ?? false } }
      budget.interrupted = budget.sqlSteps > budget.maximumSQLSteps
      return budget.cancelled || budget.interrupted ? 1 : 0
    }, Unmanaged.passUnretained(self).toOpaque())
    defer { sqlite3_progress_handler(database.handle, 0, nil, nil) }
    do { return try operation() }
    catch {
      if cancelled { throw CancellationError() }
      if interrupted { throw Self.exceeded("sql_work") }
      throw error
    }
  }

  func inspectObstacle() throws {
    try Task.checkCancellation()
    inspectedObstacles += 1
    guard inspectedObstacles <= Self.maximumObstacles else { throw Self.exceeded("obstacles") }
  }

  func inspectMetadata(bytes: Int) throws {
    metadataBytes += bytes
    guard bytes >= 0, metadataBytes <= 8 * 1_024 * 1_024 else { throw Self.exceeded("metadata_bytes") }
  }

  func compare() throws {
    comparisons += 1
    if comparisons & 255 == 0 { try Task.checkCancellation() }
    guard comparisons <= maximumComparisons else { throw Self.exceeded("packing_work") }
  }

  static func exceeded(_ boundary: String) -> CollaborationError {
    .init("placement_budget", "Область слишком сложна для одного расчёта размещения (\(boundary)). Выберите меньшую область или другой участок; частичное размещение не создано.")
  }
}

struct NotebookPlacementGeometry {
  struct Obstacle {
    let subject: CollaborationSubject
    let frame: PageRect
    let canMove: Bool
    let source: CompositionSubjectGeometry?
  }
  let target: CollaborationTarget
  let extent: PageSize
  let origin: WorldPoint?
  let obstacles: [Obstacle]
  let anchors: [UUID: PageRect]

  func anchor(_ reference: CollaborationReference?) -> PageRect {
    reference.flatMap { anchors[$0.id] } ?? .init(x: 20, y: 20, width: 1, height: 1)
  }
}

struct NotebookPlacementRead {
  let revision: String
  let sourceRevision: String
  let geometry: NotebookPlacementGeometry?
  let movable: [NotebookPlacementGeometry.Obstacle]
}

extension NotebookStore {
  /// The complete source identity and every inspected rectangle come from the
  /// same WAL cut. Heavy sources of other owners are never decoded here.
  func readPlacement(_ request: CollaborationPlacementRequest, budget: NotebookPlacementBudget) throws -> NotebookPlacementRead {
    try readTransaction { _ in
      try budget.withSQL(currentSQL!) {
        let target = request.target
        if target.kind == .cover, target.boardID == nil {
          throw CollaborationError("target_missing", "Обложка должна принадлежать указанной доске.", target: target)
        }
        if let id = request.contextID { try requirePlacementContext(id) }
        let revision = try targetContentRevision(target: target)
        guard revision == request.expectedRevision.lowercased() else {
          throw CollaborationError("revision_conflict", "Геометрия изменилась.", target: target, expected: request.expectedRevision, actual: revision)
        }
        let source = try placementSourceRevision(target)
        guard target.kind != .document && target.kind != .workspace else {
          return .init(revision: revision, sourceRevision: source, geometry: nil, movable: [])
        }
        var origin = target.kind == .board ? (request.worldOrigin ?? request.items.first?.relativeTo?.worldOrigin ?? .zero) : nil
        let extent: PageSize
        if target.kind == .page {
          guard let size = try storedFragments(address: pageFile(target.id) + "#", descendants: false).first?.value["size"]?.decode(PageSize.self), size.isValid else {
            throw NotebookStorageError.corruptRecord(pageFile(target.id))
          }
          extent = size
        } else if target.kind == .cover {
          let size = try placementItemGeometry(target.id)
          extent = .init(width: size.width, height: size.height)
        } else {
          extent = .init(width: 2_048, height: 2_048)
          if request.worldOrigin == nil, let anchor = request.items.first?.relativeTo,
            anchor.target.kind == .cover,
            let carrier = try placementCarrier(anchor.target.id, boardID: target.id) {
            origin = try placementOffset(carrier.center, x: -carrier.size.width / 2 - 20, y: -carrier.size.height / 2 - 20)
          }
        }
        // These finite endpoints also reject a requested region beyond the
        // representable tile range before WorldPoint normalization could trap.
        if let origin { _ = try placementOffset(origin, x: extent.width, y: extent.height) }
        var obstacles: [NotebookPlacementGeometry.Obstacle] = []
        var subjects: [CollaborationSubject: NotebookPlacementGeometry.Obstacle] = [:]
        func subject(_ requested: CollaborationSubject) throws -> NotebookPlacementGeometry.Obstacle? {
          if let cached = subjects[requested] { return cached }
          let result = try placementObstacle(requested, on: target, origin: origin, budget: budget)
          if let result { subjects[requested] = result }
          return result
        }
        for item in request.items {
          let file = target.kind == .page ? pageFile(target.id) : "board.json"
          let collection = target.kind == .page ? "elements" : "boards/@" + (target.boardID ?? target.id).uuidString.lowercased() + "/board/elements"
          let address = file + "#/" + collection + "/@" + fieldKey([collaborationIdentity(item.id)])
          guard try currentSQL!.rows("SELECT 1 FROM records WHERE address=?", [.text(address)]).isEmpty else {
            throw CollaborationError("invalid_placement", "Новые ID не заменяют существующие элементы.")
          }
        }
        let movable = try request.movable.map { requested in
          guard let result = try subject(requested), result.canMove else {
            throw CollaborationError("placement_unavailable", "Перемещаемый предмет должен быть свободным участником этой поверхности. Стопку сохраняйте целиком.", target: requested.target)
          }
          return result
        }
        try requirePlacementScope(movable, contextID: request.contextID, additionalOwners: request.additionalOwners, budget: budget)
        var anchors: [UUID: PageRect] = [:]
        for reference in request.items.compactMap(\.relativeTo) {
          if let value = try subject(.init(target: reference.target, elementID: reference.elementID)) { anchors[reference.id] = value.frame }
          else {
            guard reference.target == target, let region = reference.region else {
              throw CollaborationError("invalid_placement", "Опора должна принадлежать поверхности размещения.")
            }
            let delta = compositionDelta(from: origin, to: reference.worldOrigin)
            anchors[reference.id] = .init(x: region.x + delta.x, y: region.y + delta.y, width: region.width, height: region.height)
          }
        }
        let elementParent = target.kind == .page ? pageFile(target.id) + "#" : "board.json#/boards/@" + (target.boardID ?? target.id).uuidString.lowercased()
        let collection = target.kind == .page ? "elements" : "board/elements"
        var after = ""
        repeat {
          // The member index excludes the catalogue's physical items entirely.
          // Filtering happens without loading program text, drawing or state.
          let rows: [[NotebookSQLValue]]
          if target.kind == .page {
            rows = try currentSQL!.rows("SELECT member FROM records WHERE parent=? AND collection=? AND member>? ORDER BY member LIMIT 32",
              [.text(elementParent), .text(collection), .text(after)])
          } else if target.kind == .cover {
            let lower = try placementOffset(.zero, x: -24, y: -24)
            let upper = try placementOffset(.zero, x: extent.width + 24, y: extent.height + 24)
            guard let boardID = target.boardID else { throw NotebookStorageError.corruptRecord("placement cover owner") }
            rows = try currentSQL!.rows("""
              SELECT paint_key FROM spatial_entries INDEXED BY spatial_owner
              WHERE owner_id=? AND board_id=? AND kind='coverElement' AND paint_key>?
              AND (min_tx<? OR (min_tx=? AND min_x<=?)) AND (max_tx>? OR (max_tx=? AND max_x>=?))
              AND (min_ty<? OR (min_ty=? AND min_y<=?)) AND (max_ty>? OR (max_ty=? AND max_y>=?))
              ORDER BY paint_key LIMIT 32
              """, [.text(target.id.uuidString.lowercased()), .text(boardID.uuidString.lowercased()), .text(after),
                .integer(upper.tileX), .integer(upper.tileX), .real(upper.localX), .integer(lower.tileX), .integer(lower.tileX), .real(lower.localX),
                .integer(upper.tileY), .integer(upper.tileY), .real(upper.localY), .integer(lower.tileY), .integer(lower.tileY), .real(lower.localY)])
          } else {
            let lower = try placementOffset(origin ?? .zero, x: -24, y: -24)
            let upper = try placementOffset(origin ?? .zero, x: extent.width + 24, y: extent.height + 24)
            rows = try currentSQL!.rows("""
              SELECT r.member FROM records r INDEXED BY record_members
              CROSS JOIN spatial_entries s INDEXED BY spatial_address ON s.address=r.address
              WHERE r.parent=? AND r.collection=? AND r.member>?
              AND s.kind=? AND (? IS NULL OR s.owner_id=?)
              AND (s.min_tx<? OR (s.min_tx=? AND s.min_x<=?)) AND (s.max_tx>? OR (s.max_tx=? AND s.max_x>=?))
              AND (s.min_ty<? OR (s.min_ty=? AND s.min_y<=?)) AND (s.max_ty>? OR (s.max_ty=? AND s.max_y>=?))
              ORDER BY r.member LIMIT 32
              """, [.text(elementParent), .text(collection), .text(after), .text(target.kind == .board ? "element" : "coverElement"),
                target.kind == .cover ? .text(target.id.uuidString.lowercased()) : .null, .text(target.id.uuidString.lowercased()),
                .integer(upper.tileX), .integer(upper.tileX), .real(upper.localX), .integer(lower.tileX), .integer(lower.tileX), .real(lower.localX),
                .integer(upper.tileY), .integer(upper.tileY), .real(upper.localY), .integer(lower.tileY), .integer(lower.tileY), .real(lower.localY)])
          }
          for row in rows {
            try budget.inspectObstacle()
            let id = row[0].text!
            if let obstacle = try subject(.init(target: target, elementID: id)), placementTouchesWindow(obstacle.frame, extent: extent) { obstacles.append(obstacle) }
          }
          guard rows.count == 32 else { break }
          after = rows.last![0].text!
        } while true
        if let origin {
          for id in try placementNearbyItems(boardID: target.id, origin: origin, extent: extent, budget: budget) {
            try budget.inspectObstacle()
            if let obstacle = try subject(.init(target: .init(kind: .cover, id: id, boardID: target.id))), placementTouchesWindow(obstacle.frame, extent: extent) { obstacles.append(obstacle) }
          }
        }
        // Explicit off-window owners still take part in the all-or-nothing
        // recomposition, even when they did not affect the spatial broad phase.
        for value in movable where !obstacles.contains(where: { $0.subject == value.subject }) { obstacles.append(value) }
        return .init(revision: revision, sourceRevision: source,
          geometry: .init(target: target, extent: extent, origin: origin, obstacles: obstacles, anchors: anchors), movable: movable)
      }
    }
  }

  func placementSourceRevision(_ target: CollaborationTarget) throws -> String {
    let files: [String]
    switch target.kind {
    case .page: files = [pageFile(target.id)]
    case .document: files = [documentFile(target.id), stateFile(target.id)]
    case .workspace: files = ["workspace.json"]
    case .board, .cover: files = []
    }
    var bytes: Int64 = 0
    for file in files {
      let size = try currentSQL!.rows("SELECT COALESCE(SUM(length(b.data)),0) FROM records r JOIN blobs b ON b.hash=r.hash WHERE r.file=?", [.text(file)]).first![0].integer!
      bytes += size
      guard bytes <= NotebookPlacementBudget.maximumSourceBytes else { throw NotebookPlacementBudget.exceeded("source_bytes") }
    }
    return try referenceRevision(target: target)
  }

  private func requirePlacementContext(_ id: UUID) throws {
    guard let root = try storedFragments(address: contextFile(id) + "#", descendants: false).first else {
      throw CollaborationError("context_missing", "Общий фрагмент не найден.")
    }
    guard root.value["id"]?.string.flatMap(UUID.init(uuidString:)) == id else { throw NotebookStorageError.corruptRecord(root.address) }
  }

  private func requirePlacementScope(_ movable: [NotebookPlacementGeometry.Obstacle], contextID: UUID?,
    additionalOwners: [CollaborationTarget], budget: NotebookPlacementBudget) throws {
    var unresolved = movable.filter { !additionalOwners.contains($0.subject.target) }
    guard !unresolved.isEmpty else { return }
    guard let contextID else { throw Self.compositionScopeError(unresolved[0].subject) }
    for reference in try contextReferences(contextID) {
      try budget.inspectMetadata(bytes: Self.storageEncoder.encode(reference).count)
      unresolved = try unresolved.filter { obstacle in
        try !Self.compositionScopeContains(obstacle.subject, reference: reference,
          pageOwner: ownerItemID(ofPage:), boardOwner: ownerBoardID(of:), geometry: { obstacle.source })
      }
      if unresolved.isEmpty { return }
    }
    if let first = unresolved.first { throw Self.compositionScopeError(first.subject) }
  }

  private func placementItemGeometry(_ id: UUID) throws -> WorkspaceItemGeometry {
    guard let item = try readItemHeader(id) else { throw NotebookStorageError.corruptRecord("placement item") }
    if item.kind == .document {
      guard let paper = try readDocumentPaperSize(id) else { throw NotebookStorageError.corruptRecord(documentFile(id)) }
      return .document(paper)
    }
    return .notebook
  }

  private func placementCarrier(_ id: UUID, boardID: UUID) throws -> (center: WorldPoint, size: WorkspaceItemGeometry, stacked: Bool)? {
    guard let address = try currentSQL!.rows("SELECT address FROM item_owners WHERE item_id=? AND board_id=?", [.text(id.uuidString.lowercased()), .text(boardID.uuidString.lowercased())]).first?[0].text,
      let record = try storedFragments(address: address, descendants: false).first else { return nil }
    let center: WorldPoint, stacked = record.collection == "board/stacks"
    if stacked {
      let stack = try record.value.decode(WorkspaceItemStack.self)
      guard let value = WorkspaceItemStackPresentation.focusedCenter(of: id, in: stack) else { throw NotebookStorageError.corruptRecord(address) }
      center = value
    } else { center = try record.value.decode(FreeItemPlacement.self).center }
    return (center, try placementItemGeometry(id), stacked)
  }

  private func placementObstacle(_ subject: CollaborationSubject, on target: CollaborationTarget, origin: WorldPoint?,
    budget: NotebookPlacementBudget) throws -> NotebookPlacementGeometry.Obstacle? {
    if let id = subject.elementID {
      guard subject.target == target else { return nil }
      let parent = target.kind == .page ? pageFile(target.id) + "#" : "board.json#/boards/@" + (target.boardID ?? target.id).uuidString.lowercased()
      let address = parent + (target.kind == .page ? "/elements/@" : "/board/elements/@") + fieldKey([collaborationIdentity(id)])
      let rows = try currentSQL!.rows("""
        SELECT length(b.data), CASE WHEN length(b.data)<=2097152 THEN json_object(
          'id',json_extract(CAST(b.data AS TEXT),'$.value.id'),
          'frame',json_extract(CAST(b.data AS TEXT),'$.value.frame'),
          'worldOrigin',json_extract(CAST(b.data AS TEXT),'$.value.worldOrigin'),
          'surface',json_extract(CAST(b.data AS TEXT),'$.value.surface')) END
        FROM records r JOIN blobs b ON b.hash=r.hash WHERE r.address=?
        """, [.text(address)])
      guard let row = rows.first else { return nil }
      try budget.inspectMetadata(bytes: Int(row[0].integer!))
      guard let data = row[1].text else { throw NotebookPlacementBudget.exceeded("element_metadata") }
      let value = try JSONDecoder().decode(JSONValue.self, from: Data(data.utf8))
      guard let frame = try value["frame"]?.decode(PageRect.self), placementValidRect(frame),
        let sourceID = value["id"]?.string else { throw NotebookStorageError.corruptRecord(address) }
      var elementOrigin: WorldPoint?
      if target.kind != .page {
        guard let surface = try value["surface"]?.decode(SurfaceID.self),
          surface == (target.kind == .board ? .board(target.id) : .cover(target.id)) else { return nil }
        if case .object = value["worldOrigin"] { elementOrigin = try value["worldOrigin"]?.decode(WorldPoint.self) }
        guard target.kind == .board ? elementOrigin?.isValid == true : elementOrigin == nil else {
          throw NotebookStorageError.corruptRecord(address)
        }
      }
      let delta = compositionDelta(from: origin, to: elementOrigin)
      return .init(subject: .init(target: target, elementID: sourceID),
        frame: .init(x: frame.x + delta.x, y: frame.y + delta.y, width: frame.width, height: frame.height), canMove: true,
        source: .init(frame: frame, origin: elementOrigin))
    }
    guard target.kind == .board, subject.target.kind == .cover, subject.target.boardID == target.id,
      let origin, let carrier = try placementCarrier(subject.target.id, boardID: target.id) else { return nil }
    let delta = compositionDelta(from: origin, to: carrier.center), g = carrier.size, margin = carrier.stacked ? g.width : 0
    return .init(subject: subject, frame: .init(x: delta.x - g.width / 2 - margin, y: delta.y - g.height / 2 - margin,
      width: g.width + margin * 2, height: g.height + margin * 2), canMove: !carrier.stacked, source: nil)
  }

  /// Every physical cover has a finite paper size; the max-five fan determines
  /// the exact bound between its indexed minimum and the conservative packing
  /// rectangle. Enumerating the few X tiles lets the existing two-axis index
  /// skip arbitrarily many far-positive AND far-negative physical owners.
  private func placementNearbyItems(boardID: UUID, origin: WorldPoint, extent: PageSize, budget: NotebookPlacementBudget) throws -> [UUID] {
    let padding = Self.placementItemPadding
    let lower = try placementOffset(origin, x: -padding.left - 24, y: -padding.top - 24)
    let upper = try placementOffset(origin, x: extent.width + padding.right + 24, y: extent.height + padding.bottom + 24)
    var result: [UUID] = [], tile = lower.tileX
    while true {
      let remaining = NotebookPlacementBudget.maximumObstacles - budget.inspectedObstacles - result.count
      let rows = try currentSQL!.rows("""
        SELECT owner_id FROM spatial_entries INDEXED BY spatial_board_tiles
        WHERE board_id=? AND min_tx=? AND min_ty>=? AND min_ty<=? AND kind='item'
        ORDER BY min_ty,layer,z_index,paint_key LIMIT ?
        """, [.text(boardID.uuidString.lowercased()), .integer(tile), .integer(lower.tileY), .integer(upper.tileY), .integer(Int64(max(remaining + 1, 1)))])
      guard rows.count <= remaining else { throw NotebookPlacementBudget.exceeded("obstacles") }
      result += try rows.map {
        guard let id = $0[0].text.flatMap(UUID.init(uuidString:)) else { throw NotebookStorageError.corruptRecord("spatial item") }
        return id
      }
      if tile == upper.tileX { break }
      tile += 1
    }
    return result
  }

  private static let placementItemPadding: (left: Double, top: Double, right: Double, bottom: Double) = {
    let sizes = [WorkspaceItemGeometry.notebook] + DocumentPaperSize.allCases.map(WorkspaceItemGeometry.document)
    var left = 0.0, top = 0.0, right = 0.0, bottom = 0.0
    for size in sizes {
      left = max(left, size.width); top = max(top, size.height)
      right = max(right, size.width / 2); bottom = max(bottom, size.height / 2)
      for count in 2...WorkspaceItemStack.maximumItemCount {
        let stack = WorkspaceItemStack(center: .zero, zIndex: 0, itemIDs: (0..<count).map { _ in UUID() }, stamp: .init(counter: 0, actor: WorkspaceRoot.boardID))
        for id in stack.itemIDs {
          let collapsed = WorkspaceItemStackPresentation.boardCenter(of: id, in: stack, cameraScale: SpatialCamera.minimumScale, viewport: .init(x: 834, y: 1194))!
          let focused = WorkspaceItemStackPresentation.focusedCenter(of: id, in: stack)!
          let c = compositionDelta(from: .zero, to: collapsed), f = compositionDelta(from: .zero, to: focused)
          left = max(left, size.width * 2 + f.x - min(0, c.x, f.x))
          top = max(top, size.height + size.width + f.y - min(0, c.y, f.y))
          right = max(right, size.width * 1.5); bottom = max(bottom, size.height / 2 + size.width)
        }
      }
    }
    return (left, top, right, bottom)
  }()
}

func placementValidRect(_ rect: PageRect) -> Bool {
  [rect.x, rect.y, rect.width, rect.height, rect.x + rect.width, rect.y + rect.height].allSatisfy(\.isFinite)
    && rect.width > 0 && rect.height > 0
}

private func requireExactPlacementTile(_ tile: Int64) throws {
  guard Int64(exactly: Double(tile)) == tile else {
    throw CollaborationError("invalid_placement", "Мировая область не представима точно в текущем числовом формате запроса снимка. Размещение не опубликовано.")
  }
}

func requirePlacementJSONCoordinates(_ point: WorldPoint) throws {
  try requireExactPlacementTile(point.tileX)
  try requireExactPlacementTile(point.tileY)
}

private func placementTouchesWindow(_ frame: PageRect, extent: PageSize) -> Bool {
  frame.x < extent.width + 24 && frame.y < extent.height + 24 && frame.x + frame.width + 24 > 0 && frame.y + frame.height + 24 > 0
}

func placementOffset(_ origin: WorldPoint, x: Double, y: Double) throws -> WorldPoint {
  func axis(_ tile: Int64, _ local: Double, _ delta: Double) throws -> (Int64, Double) {
    let value = local + delta, offset = floor(value / WorldPoint.tileSize)
    guard value.isFinite, offset >= Double(Int64.min), offset < Double(Int64.max) else {
      throw CollaborationError("invalid_placement", "Область выходит за диапазон мировых координат.")
    }
    let sum = tile.addingReportingOverflow(Int64(offset))
    guard !sum.overflow else { throw CollaborationError("invalid_placement", "Область выходит за диапазон мировых координат.") }
    return (sum.partialValue, value - offset * WorldPoint.tileSize)
  }
  let a = try axis(origin.tileX, origin.localX, x), b = try axis(origin.tileY, origin.localY, y)
  return .init(tileX: a.0, tileY: b.0, localX: a.1, localY: b.1)
}

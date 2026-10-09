import CoreGraphics
import Foundation

/// One closed material read from one SQLite snapshot. Geometry coverage is
/// explicit; absent off-window bodies are never interpreted as deleted content.
/// Ink keeps its own immutable source and borrows this same outer QueryCut.
public struct NotebookPageMaterialWindow: Sendable {
  public let header: NotebookPageWindowHeader
  public let page: NotebookPageMetadata
  public let changeCursor: UInt64
  public let sourceRevision: String
  public let coverage: CGRect
  /// Original durable painter order, restricted to material touching coverage.
  public let elements: [AgentElement]
  /// Off-window parents, endpoint bodies and competing source-ink claimants.
  public let dependencies: [AgentElement]
  public let sources: [String: NotebookNativeElementSource]
  public let graphicGraph: NotebookGraphicGraph
  public let graphicPresentation: NotebookGraphicPresentation
  public let elementErasures: InkElementErasureMap
  public let sourceInkIDs: Set<UUID>
  public let elementPins: Set<String>
  let snapshotIdentity: UUID
  let sourceOrder: [String]

  public var readCursor: UInt64 { page.position.readCursor }
  public func source(for id: String) -> NotebookNativeElementSource? { sources[collaborationIdentity(id)] }
  public func covers(_ bounds: CGRect, sourceInkIDs: Set<UUID> = [], elementPins: Set<String> = []) -> Bool {
    coverage.contains(bounds) && sourceInkIDs.isSubset(of: self.sourceInkIDs)
      && elementPins.allSatisfy { sources[collaborationIdentity($0)] != nil }
  }
}

extension NotebookStore {
  /// Cold page presentation selects coarse index leaves before opening any
  /// body. Limits refuse an incomplete cut; a caller retains its previous cut
  /// while requesting a smaller area. There is no full-page fallback.
  public func readPageMaterialWindow(itemID: UUID, pageID: UUID, bounds: CGRect,
    expectedVisibleRoot: String? = nil, sourceInkIDs: Set<UUID> = [], elementPins: Set<String> = [], limit: Int = 256) throws -> NotebookPageMaterialWindow {
    try readPageMaterialWindow(itemID: itemID, pageID: pageID, bounds: bounds, expectedVisibleRoot: expectedVisibleRoot,
      sourceInkIDs: sourceInkIDs, elementPins: elementPins, limit: limit, ink: .init(store: self, pageID: pageID))
  }

  func readPageMaterialWindow(itemID: UUID, pageID: UUID, bounds: CGRect, expectedVisibleRoot: String?,
    sourceInkIDs: Set<UUID>, elementPins: Set<String>, limit: Int, ink: NotebookPageInkWindowReader) throws -> NotebookPageMaterialWindow {
    guard !bounds.isNull, !bounds.isInfinite, bounds.width > 0, bounds.height > 0,
      [bounds.minX, bounds.minY, bounds.maxX, bounds.maxY].allSatisfy(\.isFinite),
      (1...4096).contains(limit), sourceInkIDs.count <= 8192, elementPins.count <= 4096 else {
      throw NotebookStorageError.limitExceeded("page_material_window")
    }
    return try readTransaction { _ in
      let database = currentSQL!
      guard !database.writable, let snapshotIdentity = database.readSnapshotIdentity else {
        throw NotebookStorageError.invalidTransaction("page material requires an active query cut")
      }
      guard try pageMaterialIndexIsAdmitted(database) else {
        throw CollaborationError("page_material_not_admitted", "Локальный индекс материалов страницы ещё не принят.")
      }
      let snapshot = try NotebookPageReadSnapshot(store: self, itemID: itemID, expectedVisibleRoot: expectedVisibleRoot)
      guard let position = try snapshot.position(of: pageID) else { throw snapshot.missingPage() }
      let page = try snapshot.metadata(at: position)
      guard let revision = try pageSourceRevision(pageID) else { throw NotebookStorageError.corruptRecord(pageFile(pageID)) }
      let sources = NotebookPageMaterialSources(store: self, pageID: pageID, capturesVersions: true)
      let candidateIDs = try pageMaterialCandidates(pageID: pageID, bounds: bounds, limit: limit,
        sources: sources, database: database)
      for id in candidateIDs { try sources.include(id) }
      for id in elementPins { try sources.include(id, provesAbsence: true) }
      try sources.includeClaims(sourceInkIDs)
      let graph = try sources.graph()
      let material = sources.orderedElements.filter { element in
        guard candidateIDs.contains(collaborationIdentity(element.id)) else { return false }
        if element.graphic != nil {
          guard let node = graph.node(element.id),
            let box = NotebookGraphicVisibility.bounds(node, in: graph, parent: false) else { return false }
          return NotebookGraphicVisibility.intersects(box, bounds)
        }
        guard element.kind != .group, let placement = graph.placement(element.id) else { return false }
        return NotebookGraphicVisibility.intersects(NotebookElementPresentation(element, placement: placement).bounds, bounds)
      }
      let visible = Set(material.map { collaborationIdentity($0.id) })
      let erasures = try pageMaterialErasures(pageID: pageID, elementIDs: visible, database: database, ink: ink)
      return .init(header: snapshot.header, page: page, changeCursor: try currentChangeCursor(), sourceRevision: revision,
        coverage: bounds, elements: material, dependencies: sources.orderedElements.filter { !visible.contains(collaborationIdentity($0.id)) },
        sources: sources.nativeSources, graphicGraph: graph, graphicPresentation: sources.presentation,
        elementErasures: erasures, sourceInkIDs: sourceInkIDs, elementPins: Set(elementPins.map(collaborationIdentity)),
        snapshotIdentity: snapshotIdentity, sourceOrder: sources.orderedElements.map(\.id))
    }
  }

  private func pageMaterialCandidates(pageID: UUID, bounds: CGRect, limit: Int,
    sources: NotebookPageMaterialSources, database: NotebookSQLConnection) throws -> Set<String> {
    let page = pageID.uuidString.lowercased()
    var candidates = Set<String>(), visited = Set<String>(), visitedRows = 0
    func visit(parent: String?, bounds: CGRect, depth: Int) throws {
      guard depth < 64 else { throw NotebookStorageError.limitExceeded("element_group_depth") }
      let key = Self.spatialSpaceKey(board: page, parent: parent)
      let rows = try database.rows("""
        SELECT e.element_id,e.is_group FROM page_material_ranges r
          CROSS JOIN page_material_entries e ON e.rowid=r.entry
        WHERE r.min_space<=? AND r.max_space>=? AND r.min_x<=? AND r.max_x>=?
          AND r.min_y<=? AND r.max_y>=? AND e.page_id=? AND e.parent_id IS ? AND e.has_paint=1
          AND e.min_x<=? AND e.max_x>=? AND e.min_y<=? AND e.max_y>=? LIMIT ?
        """, [.integer(key), .integer(key), .real(bounds.maxX), .real(bounds.minX), .real(bounds.maxY), .real(bounds.minY),
          .text(page), parent.map(NotebookSQLValue.text) ?? .null,
          .real(bounds.maxX), .real(bounds.minX), .real(bounds.maxY), .real(bounds.minY), .integer(Int64(4097 - visitedRows))])
      visitedRows += rows.count
      guard visitedRows <= 4096 else { throw NotebookStorageError.limitExceeded("page_material_dependencies") }
      for row in rows {
        let id = row[0].text!
        if row[1].integer == 0 {
          candidates.insert(id)
          guard candidates.count <= limit else { throw NotebookStorageError.limitExceeded("page_material_window") }
        } else if visited.insert(id).inserted {
          guard let element = try sources.include(id), let basis = element.basis else { throw NotebookStorageError.corruptRecord(id) }
          let transform = try basis.placement(in: element.frame), inverse = transform.inverted()
          let determinant = transform.a * transform.d - transform.b * transform.c
          guard determinant.isFinite, determinant != 0 else { throw NotebookStorageError.corruptRecord(id) }
          let local = NotebookGraphicVisibility.outward(bounds, through: inverse)
          guard !local.isInfinite else { throw NotebookStorageError.limitExceeded("page_material_bounds") }
          try visit(parent: id, bounds: local, depth: depth + 1)
        }
      }
    }
    try visit(parent: nil, bounds: bounds, depth: 0)
    return candidates
  }

  private func pageMaterialErasures(pageID: UUID, elementIDs: Set<String>, database: NotebookSQLConnection,
    ink: NotebookPageInkWindowReader) throws -> InkElementErasureMap {
    guard !elementIDs.isEmpty else { return .init() }
    var addresses = Set<String>()
    let ordered = elementIDs.sorted()
    for batch in stride(from: 0, to: elementIDs.count, by: 128) {
      let ids = Array(ordered.dropFirst(batch).prefix(128))
      let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
      let rows = try database.rows("SELECT DISTINCT address FROM ink_element_erasures WHERE kind='page' AND owner_id=? AND element_id IN (" + placeholders + ") LIMIT 4097",
        [.text(pageID.uuidString.lowercased())] + ids.map(NotebookSQLValue.text))
      addresses.formUnion(rows.compactMap { $0[0].text })
      guard addresses.count <= 4096 else { throw NotebookStorageError.limitExceeded("page_material_erasures") }
    }
    var result = InkElementErasureMap(), bytes = 0
    for address in addresses.sorted() {
      guard let header = try storedFragments(address: address, descendants: false).first else { throw NotebookStorageError.corruptRecord(address) }
      guard header.value["isActive"] == .bool(true) else { continue }
      guard let id = UUID(uuidString: header.member) else { throw NotebookStorageError.corruptRecord(address) }
      let action = try ink.action(id)
      bytes += action.samples.payloadBytes
      guard bytes <= 16 * 1_024 * 1_024 else { throw NotebookStorageError.limitExceeded("page_material_erasures") }
      for (part, target) in (action.elementTargets ?? []).enumerated() where elementIDs.contains(collaborationIdentity(target.elementID)) {
        result.insert(.init(target: target, measurements: action.samples), at: action.sequence, actionID: action.id,
          part: part, for: collaborationIdentity(target.elementID))
      }
    }
    return result
  }
}

/// Finite closure inside the caller's synchronous snapshot. It cannot retain
/// the store in the returned graph: only immutable source descriptors escape.
final class NotebookPageMaterialSources {
  let store: NotebookStore
  let pageID: UUID
  let capturesVersions: Bool
  private var elements: [String: AgentElement] = [:]
  private var positions: [String: (Int64, String)] = [:]
  private var absent = Set<String>()
  private var pending: [String] = []
  private var expanded = Set<String>()
  private var claimedStrokes = Set<UUID>()
  private var candidates: [String: NotebookGraphicPresentation.Candidate] = [:]
  private var retainedBytes = 0
  private(set) var nativeSources: [String: NotebookNativeElementSource] = [:]
  var claimedElementIDs: Set<String> { Set(candidates.keys) }
  var orderedElements: [AgentElement] {
    elements.values.sorted { positions[collaborationIdentity($0.id)]! < positions[collaborationIdentity($1.id)]! }
  }
  var presentation: NotebookGraphicPresentation {
    .init(elements.values.compactMap { element in
      guard let graphic = element.graphic else { return nil }
      return candidates[collaborationIdentity(element.id)] ?? .init(id: element.id, graphic: graphic,
        version: .init(stamp: .init(counter: 0, actor: pageID), human: true))
    })
  }

  init(store: NotebookStore, pageID: UUID, capturesVersions: Bool) {
    self.store = store; self.pageID = pageID; self.capturesVersions = capturesVersions
  }

  @discardableResult
  func include(_ id: String, provesAbsence: Bool = false) throws -> AgentElement? {
    let key = collaborationIdentity(id)
    if let element = elements[key] { return element }
    if absent.contains(key), !provesAbsence || nativeSources[key] != nil { return nil }
    guard elements.count + absent.count < 4096 else { throw NotebookStorageError.limitExceeded("page_material_dependencies") }
    guard let element = try store.readPageElement(pageID: pageID, elementID: id) else {
      absent.insert(key)
      if provesAbsence {
        let target = CollaborationTarget(kind: .page, id: pageID)
        let source = try NotebookNativeElementSource(target: target, id: id, versions: store.readNativeElementVersions(target: target, id: id))
        retainedBytes += source.retainedPayloadBytes
        guard retainedBytes <= 16 * 1_024 * 1_024 else { throw NotebookStorageError.limitExceeded("page_material_bytes") }
        nativeSources[key] = source
      }
      return nil
    }
    let address = pageFile(pageID) + "#/elements/@" + fieldKey([key])
    guard let order = try store.currentSQL!.rows("SELECT position,member FROM records WHERE address=?", [.text(address)]).first,
      element.hasValidSource else { throw NotebookStorageError.corruptRecord(address) }
    let target = CollaborationTarget(kind: .page, id: pageID)
    let versions = try capturesVersions ? store.readNativeElementVersions(target: target, id: element.id) : nil
    let source = NotebookNativeElementSource(target: target, id: element.id, page: element, versions: versions)
    retainedBytes += source.retainedPayloadBytes
    guard retainedBytes <= 16 * 1_024 * 1_024 else { throw NotebookStorageError.limitExceeded("page_material_bytes") }
    elements[key] = element; positions[key] = (order[0].integer!, order[1].text!)
    nativeSources[key] = source; pending.append(key)
    return element
  }

  func includeClaims(_ strokes: Set<UUID>) throws {
    let unread = strokes.subtracting(claimedStrokes)
    guard !unread.isEmpty else { return }
    claimedStrokes.formUnion(unread)
    try store.forEachGraphicClaimant(on: .page(pageID), sourceInkIDs: unread) { claimant in
      let id = claimant.candidate.id
      guard let element = try include(id), let graphic = element.graphic else {
        throw NotebookStorageError.corruptRecord(claimant.fragment.address)
      }
      candidates[collaborationIdentity(id)] = .init(id: id, graphic: graphic, version: claimant.candidate.version)
      claimedStrokes.formUnion(graphic.sourceInkIDs)
    }
  }

  func graph() throws -> NotebookGraphicGraph {
    while let id = pending.popLast() {
      guard expanded.insert(id).inserted, let element = elements[id] else { continue }
      if let parent = element.parentID { try include(parent) }
      if let graphic = element.graphic {
        try includeClaims(Set(graphic.sourceInkIDs))
        for binding in graphic.connection?.bindings ?? [] { try include(binding.elementID) }
      }
    }
    return .page(id: pageID, elements: orderedElements, shown: presentation.geometryIDs)
  }
}

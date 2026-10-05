import Foundation

/// A complete, bounded selection read. Membership is read from the authored
/// index; the display window contributes no descendants or completeness claim.
public struct NotebookElementTransfer: Sendable {
  public let elements: [AgentElement]
  public let graph: NotebookGraphicGraph
  public let surface: SurfaceID
  public let rootOrigin: WorldPoint
  public let witness: NotebookElementTransferWitness
  public let inkKeys: [String: NotebookInkPaintKey]
}

/// Cut checks this same source cut after the system clipboard accepts its bytes.
/// A newly added child invalidates the cut even when its group's body is equal.
public struct NotebookElementTransferWitness: Equatable, Sendable {
  public let target: CollaborationTarget
  public let sources: [NotebookNativeElementSource]
  public let groupChildren: [String: [String]]

  func validateMembership(in store: NotebookStore) throws {
    for (id, children) in groupChildren {
      guard try store.readElementChildren(target: target, parentID: id, limit: 33) == children else {
        throw CollaborationError("revision_conflict", "Состав группы изменился. Повторите вырезание.")
      }
    }
  }
}

extension NotebookStore {
  public func readElementTransfer(target: CollaborationTarget, rootIDs: [String],
    observedSources: [NotebookNativeElementSource] = [], expectedInkRevision:String? = nil) throws -> NotebookElementTransfer {
    guard [.page, .board, .cover].contains(target.kind), (1...32).contains(rootIDs.count),
      Set(rootIDs.map(collaborationIdentity)).count == rootIDs.count,
      observedSources.count <= 64, observedSources.allSatisfy({ $0.target == target }) else {
      throw CollaborationError("invalid_reference", "Выберите от 1 до 32 объектов одной поверхности.")
    }
    return try readTransaction { _ in
      try currentSQL!.limitReads(.init(rows: 8_192, bytes: 32 * 1_024 * 1_024,
        valueBytes: 16 * 1_024 * 1_024, reason: "selection_transfer_read"))
      if let expectedInkRevision, try inkRevision(on:target) != expectedInkRevision {
        throw CollaborationError("revision_conflict", "Рукописное содержимое изменилось. Повторите действие.")
      }
      let surface: SurfaceID = target.kind == .page ? .page(target.id)
        : target.kind == .cover ? .cover(target.id) : .board(target.id)
      var sources: [String: NotebookNativeElementSource] = [:]
      func source(_ id: String) throws -> NotebookNativeElementSource {
        try Task.checkCancellation()
        let key = collaborationIdentity(id)
        if let source = sources[key] { return source }
        guard sources.count < 64 else {
          throw CollaborationError("selection_limit", "У выделения слишком много связанных исходников.")
        }
        let value = try readNativeElementSource(target: target, id: id)
        guard value.page != nil || value.spatial?.surface == surface else {
          throw CollaborationError("revision_conflict", "Выбранный объект исчез или сменил поверхность.")
        }
        sources[key] = value
        return value
      }
      for observed in observedSources {
        let current = try source(observed.id)
        guard current.page == observed.page, current.spatial == observed.spatial,
          (current.versions ?? [:]) == (observed.versions ?? [:]) else {
          throw CollaborationError("revision_conflict", "Выделение изменилось. Повторите действие.")
        }
      }
      var selected = Set<String>(), pending = rootIDs, next = 0
      var memberships: [String: [String]] = [:]
      while next < pending.count {
        let id = pending[next]; next += 1
        guard selected.insert(collaborationIdentity(id)).inserted else { continue }
        guard selected.count <= 32 else {
          throw CollaborationError("selection_limit", "За один раз можно перенести до 32 объектов вместе со всем составом групп.")
        }
        let value = try source(id)
        guard value.placementSource?.isGroup == true else { continue }
        let children = try readElementChildren(target: target, parentID: value.id, limit: 33)
        guard children.count <= 32 else {
          throw CollaborationError("selection_limit", "Группа целиком превышает предел 32 объектов.")
        }
        memberships[value.id] = children
        pending += children
      }

      // The immutable graph needs only addressed ancestors and external binding
      // endpoints. They are source witnesses, never copied group descendants.
      var dependencies = Array(sources.values.map(\.id)), visited = Set<String>(), dependencyIndex = 0
      while dependencyIndex < dependencies.count {
        let id = dependencies[dependencyIndex]; dependencyIndex += 1
        guard visited.insert(collaborationIdentity(id)).inserted else { continue }
        let value = try source(id)
        if let parent = value.placementSource?.parentID {
          guard try source(parent).placementSource?.isGroup == true else {
            throw CollaborationError("incomplete_fragment", "У выделения отсутствует исходная группа.")
          }
          dependencies.append(parent)
        }
        for endpoint in (value.page?.graphic ?? value.spatial?.graphic)?.connection?.bindings ?? [] {
          // An absent endpoint remains pending in the canonical graphic. It does
          // not make an otherwise complete authored group disappear from Copy.
          let current = try readNativeElementSource(target: target, id: endpoint.elementID)
          if current.page != nil || current.spatial?.surface == surface {
            _ = try source(endpoint.elementID); dependencies.append(endpoint.elementID)
          }
        }
      }
      let resolver = NotebookElementPlacement.Resolver { sources[collaborationIdentity($0)]?.placementSource }
      var nodes: [NotebookGraphicGraph.Node] = []
      var groups: [String: NotebookGraphicGraph.ElementSource] = [:]
      var bodies: [String: NotebookGraphicGraph.ElementSource] = [:]
      for (key, value) in sources {
        guard let pose = value.placementSource, let placement = try resolver.resolve(value.id, source: pose) else {
          throw CollaborationError("incomplete_fragment", "Не удалось прочитать полное локальное основание выделения.")
        }
        let body = NotebookGraphicGraph.ElementSource(source: pose, surface: surface,
          text: value.page?.source ?? value.spatial?.source,
          textStyle: value.page?.textStyle ?? value.spatial?.textStyle ?? .standard)
        bodies[key] = body
        if pose.isGroup { groups[key] = body }
        if let graphic = value.page?.graphic ?? value.spatial?.graphic {
          nodes.append(.init(id: value.id, graphic: graphic, frame: pose.frame,
            surface: surface, shown: graphic.showsGeometry, placement: placement))
        }
      }
      let owner = target.kind.rawValue + ":" + target.id.uuidString.lowercased()
        + (target.kind == .page ? "|elements" : "")
      let placeholders = Array(repeating: "?", count: selected.count).joined(separator: ",")
      let order = try currentSQL!.rows("SELECT member FROM reference_element_order WHERE owner_key=? AND member IN (\(placeholders)) ORDER BY position,member",
        [.text(owner)] + selected.sorted().map { .text($0) }).compactMap { $0[0].text }
      guard order.count == selected.count else {
        throw NotebookStorageError.corruptRecord("selection_transfer_order")
      }
      let elements = try order.map { id -> AgentElement in
        let value = try source(id)
        if let page = value.page { return page }
        let spatial = value.spatial!
        return .init(id: spatial.id, kind: AgentElementKind(rawValue: spatial.kind.rawValue)!,
          frame: .init(x: spatial.frame.x, y: spatial.frame.y, width: spatial.frame.width, height: spatial.frame.height),
          source: spatial.source, html: spatial.html, css: spatial.css, javaScript: spatial.javaScript,
          programPackage: spatial.programPackage, state: spatial.state, graphic: spatial.graphic,
          textStyle: spatial.kind == .nativeText ? spatial.textStyle : nil,
          parentID: spatial.parentID, basis: spatial.basis)
      }
      let graph = NotebookGraphicGraph(nodes, groupSources: groups, elementSources: bodies)
      let contacts=Dictionary(uniqueKeysWithValues:elements.compactMap { element in
        element.graphic?.sourceInkContactID.map { (element.id,$0) }
      })
      var inkKeys:[String:NotebookInkPaintKey]=[:]
      if target.kind == .page {
        for (id,contact) in contacts {
          let address=pageFile(target.id)+"#/drawingData/actions/@"+contact.uuidString.lowercased()
          guard let row=try boundedStoredFragments([(address,false)],maximumCount:1,
            maximumBytes:262_144,budget:"transfer_ink_header").first else {
            throw CollaborationError("incomplete_fragment","Не удалось прочитать порядок исходной рукописи.")
          }
          let header=try row.value.decode(NotebookPageInkActionMetadata.self)
          guard header.id == contact,header.tool == .pen,header.sequence > 0 else {
            throw NotebookStorageError.corruptRecord(address)
          }
          inkKeys[id] = .page(sequence:header.sequence,id:contact)
        }
      } else if !contacts.isEmpty {
        let headers=try spatialInkHistoryStates(ids:Set(contacts.values))
        for (id,contact) in contacts {
          guard let header=headers[contact],header.surfaces.contains(surface) else {
            throw CollaborationError("incomplete_fragment","Не удалось прочитать порядок исходной рукописи.")
          }
          inkKeys[id] = .spatial(stamp:header.result.creationStamp,id:contact)
        }
      }
      guard let origin = graph.placement(rootIDs[0])?.origin else {
        throw CollaborationError("incomplete_fragment", "Не удалось прочитать основание выделения.")
      }
      return .init(elements: elements, graph: graph, surface: surface, rootOrigin: origin,
        witness: .init(target: target, sources: sources.values.sorted { $0.id < $1.id }, groupChildren: memberships),inkKeys:inkKeys)
    }
  }
}

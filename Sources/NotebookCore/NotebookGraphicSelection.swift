import Foundation

/// Exact author-visible preconditions, not a refreshed owner revision. Both a
/// single contact and a multi-object action enter the same transaction below.
public struct NotebookNativeElementSource: Sendable {
  public let target: CollaborationTarget
  public let id: String
  public let page: AgentElement?
  public let spatial: SpatialElement?
  public init(target: CollaborationTarget, id: String, page: AgentElement? = nil, spatial: SpatialElement? = nil) {
    self.target = target; self.id = id; self.page = page; self.spatial = spatial
  }
}

extension NotebookStore {
  public func applyNativeElementEdits(_ operations: [CollaborationOperation], summary: String,
    sources: [NotebookNativeElementSource], moveToFront: Bool? = nil, copiedFrom: [String:String] = [:], actor: UUID
  ) throws -> (receipt: CollaborationReceipt, sources: [NotebookNativeElementSource]) {
    try commandTransaction(readAllowance: .agentCommand) {
      guard let target = operations.first?.target, [.page,.board,.cover].contains(target.kind),
        !operations.isEmpty, operations.count <= 32, !sources.isEmpty, sources.count <= 64,
        operations.allSatisfy({ $0.target == target }), sources.allSatisfy({ $0.target == target }),
        Set(sources.map(\.id)).count == sources.count else {
        throw CollaborationError("invalid_operation", "Одна поверхность: не более 32 правок и 64 проверяемых исходников.")
      }
      for source in sources {
        let page = target.kind == .page ? try readPageElement(pageID: target.id, elementID: source.id) : nil
        let spatial = target.kind == .page ? nil : try readSpatialElement(boardID: target.boardID ?? target.id, elementID: source.id)
        guard page == source.page, spatial == source.spatial else {
          throw CollaborationError("revision_conflict", "Выбранный элемент \(source.id) изменился до завершения действия.")
        }
      }
      guard operations.allSatisfy({ operation in
        operation.id.map { id in sources.contains { $0.id == id } } == true
      }) else { throw CollaborationError("invalid_operation", "Каждая правка требует своего исходного элемента.") }
      var admitted = operations
      if !copiedFrom.isEmpty {
        guard operations.allSatisfy({ $0.kind == .insertElement }), Set(operations.compactMap(\.id)) == Set(copiedFrom.keys),
          Set(copiedFrom.values).count == copiedFrom.count,
          Set(copiedFrom.values).isSubset(of:Set(sources.filter { $0.page != nil || $0.spatial != nil }.map(\.id))) else {
          throw CollaborationError("invalid_operation", "Копирование называет каждый новый ID и его проверенный исходник.")
        }
        let owner = target.kind.rawValue + ":" + target.id.uuidString.lowercased() + (target.kind == .page ? "|elements" : "")
        let placeholders = Array(repeating:"?",count:copiedFrom.count).joined(separator:",")
        let order = try currentSQL!.rows("SELECT member FROM reference_element_order WHERE owner_key=? AND member IN (\(placeholders)) ORDER BY position,member",
          [.text(owner)] + copiedFrom.values.map { .text($0) }).compactMap { $0[0].text }
        guard order.count == copiedFrom.count else { throw CollaborationError("revision_conflict", "Порядок исходников изменился.") }
        let positions = Dictionary(uniqueKeysWithValues:order.enumerated().map { ($0.element,$0.offset) })
        admitted.sort { positions[copiedFrom[$0.id!]!]! < positions[copiedFrom[$1.id!]!]! }
      }
      if let moveToFront {
        guard operations.count == 1, operations[0].kind == .reorderElements else {
          throw CollaborationError("invalid_operation", "Порядок меняется одной перестановкой выбранных объектов.")
        }
        let owner = target.kind.rawValue + ":" + target.id.uuidString.lowercased() + (target.kind == .page ? "|elements" : "")
        let order = try currentSQL!.rows("SELECT member FROM reference_element_order WHERE owner_key=? ORDER BY position,member", [.text(owner)]).compactMap { $0[0].text }
        let selected = Set(sources.map(\.id)), moving = order.filter { selected.contains($0) }
        guard moving.count == selected.count else { throw CollaborationError("revision_conflict", "Членство выбора изменилось.") }
        let rest = order.filter { !selected.contains($0) }
        admitted = [.init(kind:.reorderElements,target:target,id:operations[0].id,
          values:["ids":.array((moveToFront ? rest+moving : moving+rest).map(JSONValue.string))])]
      }
      let revision = try targetContentRevision(target: target)
      let ink = operations.contains { $0.kind == .convertInkToElement } ? try inkRevision(on: target) : nil
      let receipt = try applyNativeGraphicAction(.init(summary: summary,
        references: admitted.map { .init(target:target,elementID:$0.kind == .reorderElements ? nil : $0.id,revision:revision) },
        expected: [.init(target: target, revision: revision, inkRevision: ink)], operations: admitted), actor: actor)
      return (receipt, try sources.map { source in
        .init(target: target, id: source.id,
          page: target.kind == .page ? try readPageElement(pageID: target.id, elementID: source.id) : nil,
          spatial: target.kind == .page ? nil : try readSpatialElement(boardID: target.boardID ?? target.id, elementID: source.id))
      })
    }
  }
}

/// Shared geometry for an explicit finite selection. No document, camera or
/// undo state lives here. Bindings inside a moved/copied selection stay bound.
public enum NotebookGraphicSelection {
  public enum Alignment: String, CaseIterable, Sendable { case left, center, right, top, middle, bottom }
  public struct Member: Equatable, Sendable {
    public let id: String
    public let frame: PageRect
    public let origin: WorldPoint
    public let graphic: NotebookGraphic
    public let layout: NotebookGraphicLayout
    public init(id: String, frame: PageRect, origin: WorldPoint = .zero, graphic: NotebookGraphic, layout: NotebookGraphicLayout) {
      self.id = id; self.frame = frame; self.origin = origin; self.graphic = graphic; self.layout = layout
    }
  }
  public struct Edit: Equatable, Sendable {
    public let id: String
    public let frame: PageRect
    public let graphic: NotebookGraphic
  }

  public static func translated(_ members: [Member], by delta: SpatialPoint, detachingExternalBindings: Bool = false) -> [Edit] {
    let ids = Set(members.map(\.id))
    return members.map { member in
      var graphic = member.graphic
      if delta != .zero || detachingExternalBindings, var connection = graphic.connection {
        var detached = false
        for terminal in NotebookGraphicConnection.Terminal.allCases {
          let endpoint = terminal == .start ? connection.start : connection.end
          if let binding = endpoint.binding, !ids.contains(binding.elementID) {
            detached = true
            let p = terminal == .start ? member.layout.start : member.layout.end
            let free = NotebookGraphicConnection.Endpoint(point: .init(x: member.layout.frame.x+p.x-member.frame.x,
              y: member.layout.frame.y+p.y-member.frame.y))
            if terminal == .start { connection.start = free } else { connection.end = free }
          }
        }
        if detached {
          let layout = member.layout, dx = layout.end.x-layout.start.x, dy = layout.end.y-layout.start.y
          let length = max(0.001,hypot(dx,dy))
          connection.bendPosition = min(1,max(0,((layout.bend.x-layout.start.x)*dx+(layout.bend.y-layout.start.y)*dy)/(length*length)))
          connection.bend = (-dy*(layout.bend.x-(layout.start.x+layout.end.x)/2)+dx*(layout.bend.y-(layout.start.y+layout.end.y)/2))/length
        }
        graphic.connection = connection
      }
      return .init(id: member.id, frame: .init(x: member.frame.x+delta.x,y: member.frame.y+delta.y,
        width: member.frame.width,height: member.frame.height), graphic: graphic)
    }
  }

  public static func aligned(_ members: [Member], to alignment: Alignment) -> [Edit] {
    let nodes = members.filter { $0.graphic.connection == nil }
    guard let origin = nodes.first?.origin else { return [] }
    let boxes = nodes.map { node -> PageRect in
      let d = origin.delta(to: node.origin)
      return .init(x:d.x+node.frame.x,y:d.y+node.frame.y,width:node.frame.width,height:node.frame.height)
    }
    let left = boxes.map(\.x).min()!, top = boxes.map(\.y).min()!
    let right = boxes.map { $0.x+$0.width }.max()!, bottom = boxes.map { $0.y+$0.height }.max()!
    return zip(nodes,boxes).map { node, box in
      var x = node.frame.x, y = node.frame.y
      switch alignment {
      case .left: x += left-box.x
      case .center: x += (left+right-box.width)/2-box.x
      case .right: x += right-box.width-box.x
      case .top: y += top-box.y
      case .middle: y += (top+bottom-box.height)/2-box.y
      case .bottom: y += bottom-box.height-box.y
      }
      return .init(id:node.id,frame:.init(x:x,y:y,width:node.frame.width,height:node.frame.height),graphic:node.graphic)
    }
  }

  public static func duplicated(_ members: [Member], namespace: UUID, offset: SpatialPoint) -> [Edit] {
    let ids = Dictionary(uniqueKeysWithValues: members.map { ($0.id, NotebookStore.submissionID(namespace,suffix:$0.id).uuidString.lowercased()) })
    return translated(members,by:offset,detachingExternalBindings:true).map { edit in
      let old = edit.graphic
      var connection = old.connection
      for terminal in NotebookGraphicConnection.Terminal.allCases {
        guard var endpoint = terminal == .start ? connection?.start : connection?.end,
          var binding = endpoint.binding, let id = ids[binding.elementID] else { continue }
        binding.elementID = id; endpoint.binding = binding
        if terminal == .start { connection?.start = endpoint } else { connection?.end = endpoint }
      }
      // Copies are new authored objects, not competing claims on old ink.
      let graphic = NotebookGraphic(shape:old.shape,style:old.style,label:old.label,
        connection:connection,vertices:old.vertices,cornerRadius:old.cornerRadius)
      return .init(id:ids[edit.id]!,frame:edit.frame,graphic:graphic)
    }
  }
}

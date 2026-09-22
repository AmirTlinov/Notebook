import Foundation

/// Exact author-visible preconditions, not a refreshed owner revision. Both a
/// single contact and a multi-object action enter the same transaction below.
public struct NotebookNativeElementSource: Equatable, Sendable {
  public let target: CollaborationTarget
  public let id: String
  public let page: AgentElement?
  public let spatial: SpatialElement?
  public init(target: CollaborationTarget, id: String, page: AgentElement? = nil, spatial: SpatialElement? = nil) {
    self.target = target; self.id = id; self.page = page; self.spatial = spatial
  }
}

/// A layer action applies to the complete painter order inside the same native
/// transaction. Selected members retain their own order, including disjoint runs.
public enum NotebookElementLayerMove: String, CaseIterable, Sendable {
  case lower, higher, toBack, toFront

  public func canApply(to order: [String], selected: Set<String>) -> Bool {
    zip(order,order.dropFirst()).contains { lower,higher in
      switch self {
      case .lower, .toBack: return !selected.contains(lower) && selected.contains(higher)
      case .higher, .toFront: return selected.contains(lower) && !selected.contains(higher)
      }
    }
  }

  public func applying(to order: [String], selected: Set<String>) -> [String] {
    guard order.count > 1, !selected.isEmpty else { return order }
    switch self {
    case .toBack, .toFront:
      let moving = order.filter { selected.contains($0) }, rest = order.filter { !selected.contains($0) }
      return self == .toFront ? rest+moving : moving+rest
    case .lower, .higher:
      var result = order
      // Traverse against the movement so every selected run crosses exactly
      // one unselected neighbour, never the entire stack in one command.
      if self == .higher {
        for i in (0..<result.count-1).reversed() where selected.contains(result[i]) && !selected.contains(result[i+1]) {
          result.swapAt(i,i+1)
        }
      } else {
        for i in 1..<result.count where selected.contains(result[i]) && !selected.contains(result[i-1]) {
          result.swapAt(i,i-1)
        }
      }
      return result
    }
  }
}

extension NotebookStore {
  public func applyNativeElementEdits(_ operations: [CollaborationOperation], summary: String,
    sources: [NotebookNativeElementSource], layerMove: NotebookElementLayerMove? = nil, copiedFrom: [String:String] = [:], expectedInkRevision: String? = nil,
    actionID:UUID=UUID(),actor: UUID
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
      if let layerMove {
        guard operations.count == 1, operations[0].kind == .reorderElements else {
          throw CollaborationError("invalid_operation", "Порядок меняется одной перестановкой выбранных объектов.")
        }
        let owner = target.kind.rawValue + ":" + target.id.uuidString.lowercased() + (target.kind == .page ? "|elements" : "")
        let order = try currentSQL!.rows("SELECT member FROM reference_element_order WHERE owner_key=? ORDER BY position,member", [.text(owner)]).compactMap { $0[0].text }
        let selected = Set(sources.map(\.id)), moving = order.filter { selected.contains($0) }
        guard moving.count == selected.count else { throw CollaborationError("revision_conflict", "Членство выбора изменилось.") }
        admitted = [.init(kind:.reorderElements,target:target,id:operations[0].id,
          values:["ids":.array(layerMove.applying(to:order,selected:selected).map(JSONValue.string))])]
      }
      let revision = try targetContentRevision(target: target)
      if let expectedInkRevision, try inkRevision(on:target) != expectedInkRevision {
        throw CollaborationError("revision_conflict","Чернила изменились во время выделения. Повторите лассо.")
      }
      let ink = operations.contains { $0.kind == .convertInkToElement } ? try inkRevision(on: target) : nil
      let receipt = try applyNativeGraphicAction(.init(id:actionID,summary: summary,
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
    public let graphic: NotebookGraphic
    public let layout: NotebookGraphicLayout
    public let body: NotebookGraphicLayout
    public let placement: NotebookElementPlacement
    public var origin: WorldPoint { placement.origin }
    public init(id:String,frame:PageRect,graphic:NotebookGraphic,layout:NotebookGraphicLayout,
      body:NotebookGraphicLayout,placement:NotebookElementPlacement) {
      self.id=id;self.frame=frame;self.graphic=graphic;self.layout=layout;self.body=body;self.placement=placement
    }
    public var visibleFrame: PageRect { graphic.mask.flatMap { layout.selectionFrame(mask:$0) } ?? layout.frame }
  }
  public struct Edit: Equatable, Sendable {
    public let id: String
    public let frame: PageRect
    public let graphic: NotebookGraphic
    public let basis: NotebookElementBasis?
  }

  /// Resolve an external endpoint once in its authored body. Internal bindings
  /// remain relationships, including when members have different parents.
  private static func detached(_ member:Member,selected:Set<String>) -> NotebookGraphic {
    var graphic=member.graphic
    guard var connection=graphic.connection else { return graphic }
    var detached=false
    for terminal in NotebookGraphicConnection.Terminal.allCases {
      let endpoint=terminal == .start ? connection.start : connection.end
      if let binding=endpoint.binding,!selected.contains(binding.elementID) {
        detached=true
        let p=terminal == .start ? member.body.start : member.body.end
        let free=NotebookGraphicConnection.Endpoint(point:.init(x:member.body.frame.x+p.x,y:member.body.frame.y+p.y))
        if terminal == .start { connection.start=free } else { connection.end=free }
      }
    }
    if detached {
      let l=member.body,dx=l.end.x-l.start.x,dy=l.end.y-l.start.y,length=max(0.001,hypot(dx,dy))
      connection.bendPosition=min(1,max(0,((l.bend.x-l.start.x)*dx+(l.bend.y-l.start.y)*dy)/(length*length)))
      connection.bend=(-dy*(l.bend.x-(l.start.x+l.end.x)/2)+dx*(l.bend.y-(l.start.y+l.end.y)/2))/length
    }
    graphic.connection=connection;return graphic
  }

  public static func translated(_ members:[Member],by delta:SpatialPoint,detachingExternalBindings:Bool=false) -> [Edit] {
    let ids=Set(members.map(\.id))
    var edits:[Edit]=[]
    for member in members {
      guard let local=member.placement.parentVector(delta) else { return [] }
      edits.append(.init(id:member.id,frame:.init(x:member.frame.x+local.x,y:member.frame.y+local.y,
        width:member.frame.width,height:member.frame.height),
        graphic:delta != .zero || detachingExternalBindings ? detached(member,selected:ids) : member.graphic,
        basis:member.placement.basis))
    }
    return edits
  }

  public static func bounds(_ members:[Member],relativeTo origin:WorldPoint) -> CGRect {
    members.reduce(CGRect.null) { bounds,member in
      let f=member.visibleFrame,d=origin.delta(to:member.origin)
      return bounds.union(.init(x:d.x+f.x,y:d.y+f.y,width:f.width,height:f.height))
    }
  }

  /// Every transform edits relative placement, not measurement arrays, stroke
  /// widths or a second graphic transform. The same edits preview and persist.
  public static func transformed(_ members:[Member],by change:CGAffineTransform,relativeTo origin:WorldPoint) -> [Edit] {
    let ids=Set(members.map(\.id))
    var edits:[Edit]=[]
    for member in members {
      let d=origin.delta(to:member.origin)
      let local=CGAffineTransform(translationX:d.x,y:d.y).concatenating(change)
        .concatenating(.init(translationX:-d.x,y:-d.y))
      guard let pose=try? member.placement.applyingSurfaceTransform(local) else { return [] }
      edits.append(.init(id:member.id,frame:pose.frame,graphic:detached(member,selected:ids),basis:pose.basis))
    }
    return edits
  }

  public static func aligned(_ members:[Member],to alignment:Alignment) -> [Edit] {
    let nodes=members.filter { $0.graphic.connection == nil }
    guard let origin=nodes.first?.origin else { return [] }
    let box=bounds(nodes,relativeTo:origin)
    return nodes.flatMap { member in
      let f=member.visibleFrame,d=origin.delta(to:member.origin)
      let x=d.x+f.x,y=d.y+f.y,delta:SpatialPoint
      switch alignment {
      case .left: delta = .init(x:box.minX-x,y:0)
      case .center: delta = .init(x:box.midX-x-f.width/2,y:0)
      case .right: delta = .init(x:box.maxX-x-f.width,y:0)
      case .top: delta = .init(x:0,y:box.minY-y)
      case .middle: delta = .init(x:0,y:box.midY-y-f.height/2)
      case .bottom: delta = .init(x:0,y:box.maxY-y-f.height)
      }
      return translated([member],by:delta)
    }
  }

  public static func duplicated(_ members:[Member],namespace:UUID,offset:SpatialPoint) -> [Edit] {
    let ids=Dictionary(uniqueKeysWithValues:members.map { ($0.id,NotebookStore.submissionID(namespace,suffix:$0.id).uuidString.lowercased()) })
    return translated(members,by:offset,detachingExternalBindings:true).map { edit in
      let old=edit.graphic
      var connection=old.connection
      for terminal in NotebookGraphicConnection.Terminal.allCases {
        guard var endpoint=terminal == .start ? connection?.start : connection?.end,
          var binding=endpoint.binding,let id=ids[binding.elementID] else { continue }
        binding.elementID=id;endpoint.binding=binding
        if terminal == .start { connection?.start=endpoint } else { connection?.end=endpoint }
      }
      let graphic=NotebookGraphic(shape:old.shape,style:old.style,label:old.label,
        connection:connection,vertices:old.vertices,cornerRadius:old.cornerRadius,freehand:old.freehand,transform:old.transform,path:old.path,mask:old.mask)
      return .init(id:ids[edit.id]!,frame:edit.frame,graphic:graphic,basis:edit.basis)
    }
  }

  public static func transformed(_ members:[Member],radians:Double=0,scale:Double=1) -> [Edit] {
    guard let origin=members.first?.origin,radians.isFinite,scale.isFinite,scale>0 else { return [] }
    let box=bounds(members,relativeTo:origin)
    let change=CGAffineTransform(translationX:-box.midX,y:-box.midY)
      .concatenating(.init(rotationAngle:radians)).concatenating(.init(scaleX:scale,y:scale))
      .concatenating(.init(translationX:box.midX,y:box.midY))
    return transformed(members,by:change,relativeTo:origin)
  }
}

import Foundation

/// Exact author-visible preconditions, not a refreshed owner revision. Both a
/// single contact and a multi-object action enter the same transaction below.
public struct NotebookNativeElementSource: Equatable, Sendable {
  public let target: CollaborationTarget
  public let id: String
  public let page: AgentElement?
  public let spatial: SpatialElement?
  public let versions: [String: ContentFieldVersion]?
  public init(target: CollaborationTarget, id: String, page: AgentElement? = nil, spatial: SpatialElement? = nil,
    versions: [String: ContentFieldVersion]? = nil) {
    self.target = target; self.id = id; self.page = page; self.spatial = spatial; self.versions = versions
  }
}

extension CollaborativeContent {
  /// Fixed addressed lookups, including optional fields that may have been
  /// removed. A same-valued peer edit still changes its causal source.
  public func elementVersions(id: String) -> [String: ContentFieldVersion] {
    Self.elementVersionKeys(id: id).reduce(into: [:]) { result, key in result[key] = fields[key] }
  }

  static func elementVersionKeys(id: String) -> [String] {
    AgentElement.causalFieldKeys(id: id, allGraphicFields: true)
      + ["surface", "worldOrigin"].map { fieldKey(["elements", collaborationIdentity(id), $0]) }
  }
}

extension NotebookStore {
  public func readNativeElementSource(target: CollaborationTarget, id: String) throws -> NotebookNativeElementSource {
    guard [.page, .board, .cover].contains(target.kind), !id.isEmpty, id.utf16.count <= 120 else {
      throw CollaborationError("invalid_reference", "Нужен адрес элемента листа, доски или обложки.")
    }
    return try readTransaction { _ in
      let root = target.kind == .page ? pageFile(target.id) + "#"
        : "board.json#/boards/@" + (target.boardID ?? target.id).uuidString.lowercased() + "/board"
      let keys = CollaborativeContent.elementVersionKeys(id: id)
      let rows = try boundedStoredFragments(keys.map { (root + "/collaboration/fields/@" + fieldKey([$0]), false) },
        maximumCount: keys.count, maximumBytes: 1_048_576, budget: "native_element_versions")
      let versions = try Dictionary(uniqueKeysWithValues: rows.map { ($0.member, try $0.value.decode(ContentFieldVersion.self)) })
      return try .init(target: target, id: id,
        page: target.kind == .page ? readPageElement(pageID: target.id, elementID: id) : nil,
        spatial: target.kind == .page ? nil : readSpatialElement(boardID: target.boardID ?? target.id, elementID: id),
        versions: versions)
    }
  }
}

extension NotebookNativeCommand where Source == NotebookNativeElementSource {
  public convenience init(_ operations: [CollaborationOperation], summary: String,
    sources: [NotebookNativeElementSource], layerMove: NotebookElementLayerMove? = nil,
    copiedFrom: [String:String] = [:], expectedInkRevision: String? = nil, inkReadSets:[NotebookInkReadSet] = [],
    transferWitness: NotebookElementTransferWitness? = nil,
    actionID: UUID = UUID(), actor: UUID, requestFingerprint: String? = nil) {
    self.init { store, didPrepare in
      try store.commitNativeElementEdits(operations, summary: summary, sources: sources,
        layerMove: layerMove, copiedFrom: copiedFrom, expectedInkRevision: expectedInkRevision, inkReadSets:inkReadSets,
        transferWitness: transferWitness,
        actionID: actionID, actor: actor, requestFingerprint: requestFingerprint, didPrepare: didPrepare)
    }
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
    sources: [NotebookNativeElementSource], layerMove: NotebookElementLayerMove? = nil, copiedFrom: [String:String] = [:], expectedInkRevision: String? = nil, inkReadSets:[NotebookInkReadSet] = [],
    transferWitness: NotebookElementTransferWitness? = nil,
    actionID:UUID=UUID(),actor: UUID, requestFingerprint: String? = nil
  ) throws -> (receipt: CollaborationReceipt, sources: [NotebookNativeElementSource]) {
    try NotebookNativeCommand(operations, summary: summary, sources: sources,
      layerMove: layerMove, copiedFrom: copiedFrom, expectedInkRevision: expectedInkRevision, inkReadSets:inkReadSets,
      transferWitness: transferWitness,
      actionID: actionID, actor: actor, requestFingerprint: requestFingerprint).apply(to: self)
  }

  fileprivate func commitNativeElementEdits(_ operations: [CollaborationOperation], summary: String,
    sources: [NotebookNativeElementSource], layerMove: NotebookElementLayerMove?, copiedFrom: [String:String],
    expectedInkRevision: String?, inkReadSets:[NotebookInkReadSet], transferWitness: NotebookElementTransferWitness?, actionID: UUID, actor: UUID,
    requestFingerprint: String?,
    didPrepare: (NotebookNativeCommand<NotebookNativeElementSource>.Output) -> Void
  ) throws -> NotebookNativeCommand<NotebookNativeElementSource>.Output {
    try commandTransaction(readAllowance: Self.inkSelectionReadAllowance(inkReadSets)) {
      guard let target = operations.first?.target, [.page,.board,.cover].contains(target.kind),
        !operations.isEmpty, operations.count <= 32, !sources.isEmpty, sources.count <= 64,
        operations.allSatisfy({ $0.target == target }), sources.allSatisfy({ $0.target == target }),
        Set(sources.map(\.id)).count == sources.count else {
        throw CollaborationError("invalid_operation", "Одна поверхность: не более 32 правок и 64 проверяемых исходников.")
      }
      for source in sources {
        let current = try readNativeElementSource(target: target, id: source.id)
        guard current.page == source.page, current.spatial == source.spatial,
          source.versions.map({ $0 == current.versions }) ?? true else {
          throw CollaborationError("revision_conflict", "Выбранный элемент \(source.id) изменился до завершения действия.")
        }
      }
      if let witness = transferWitness {
        guard witness.target == target, witness.sources.allSatisfy({ expected in
          sources.contains { $0 == expected }
        }) else { throw CollaborationError("invalid_operation", "Перенос требует всех проверенных исходников.") }
        try witness.validateMembership(in: self)
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
        let selectedSources=sources.filter{copiedFrom.values.contains($0.id)}
        let contacts=Dictionary(uniqueKeysWithValues:selectedSources.compactMap { source -> (String,UUID)? in
          (source.page?.graphic ?? source.spatial?.graphic)?.sourceInkContactID.map{(source.id,$0)}
        })
        var keys:[String:NotebookInkPaintKey]=[:]
        if target.kind == .page {
          // Only bounded headers: duplicating a contact never reads its samples
          // or walks the surrounding page history to recover its painter rank.
          let parent=pageFile(target.id)+"#/drawingData/actions/@"
          for (element,id) in contacts {
            let address=parent+id.uuidString.lowercased()
            guard let row=try boundedStoredFragments([(address,false)],maximumCount:1,
              maximumBytes:262_144,budget:"copied_ink_header").first else {
              throw CollaborationError("revision_conflict","Исходный рукописный контакт отсутствует.")
            }
            let header=try row.value.decode(NotebookPageInkActionMetadata.self)
            guard header.id == id,header.tool == .pen,header.sequence > 0 else {
              throw NotebookStorageError.corruptRecord(address)
            }
            keys[element] = .page(sequence:header.sequence,id:id)
          }
        } else if !contacts.isEmpty {
          let surface:SurfaceID = target.kind == .cover ? .cover(target.id) : .board(target.id)
          let headers=try spatialInkHistoryStates(ids:Set(contacts.values))
          for (element,id) in contacts {
            guard let header=headers[id],header.surfaces.contains(surface) else {
              throw CollaborationError("revision_conflict","Исходный рукописный контакт отсутствует на поверхности.")
            }
            keys[element] = .spatial(stamp:header.result.creationStamp,id:id)
          }
        }
        let positions = Dictionary(uniqueKeysWithValues:NotebookInkPaintKey.ordering(order,keys:keys).enumerated().map { ($0.element,$0.offset) })
        admitted.sort { positions[copiedFrom[$0.id!]!]! < positions[copiedFrom[$1.id!]!]! }
      }
      if let layerMove {
        guard sources.allSatisfy({($0.page?.graphic ?? $0.spatial?.graphic)?.sourceInkContactID == nil}) else {
          throw CollaborationError("unsupported_operation","Порядок принятого рукописного контакта сохраняется при перемещении.")
        }
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
      try validateInkReadSets(inkReadSets,target:target)
      if inkReadSets.isEmpty,let expectedInkRevision, try inkRevision(on:target) != expectedInkRevision {
        throw CollaborationError("revision_conflict","Чернила изменились во время выделения. Повторите лассо.")
      }
      let ink = operations.contains { $0.kind == .convertInkToElement } ? try inkRevision(on: target) : nil
      let receipt = try applyNativeAction(.init(id:actionID,summary: summary,
        references: admitted.map { .init(target:target,elementID:$0.kind == .reorderElements ? nil : $0.id,revision:revision) },
        expected: [.init(target: target, revision: revision, inkRevision: ink)], operations: admitted), actor: actor, requestFingerprint: requestFingerprint)
      let result = (receipt, try sources.map { source in
        try readNativeElementSource(target: target, id: source.id)
      })
      didPrepare(result)
      return result
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

  /// Maps an already painted surface point to the edit's surface point. The
  /// placement resolver retains the member's ancestor chain, so a child of a
  /// rotated/scaled group cannot be previewed by stretching its bounding box.
  public static func displayTransform(from member:Member,to edit:Edit) -> CGAffineTransform? {
    guard member.id == edit.id,
      let target=try? member.placement.updating(frame:edit.frame,basis:edit.basis).transform else { return nil }
    let source=member.placement.transform,det=source.a*source.d-source.b*source.c
    guard det.isFinite,det != 0 else { return nil }
    let transform=source.inverted().concatenating(target)
    return [transform.a,transform.b,transform.c,transform.d,transform.tx,transform.ty].allSatisfy(\.isFinite)
      ? transform : nil
  }

  /// Resolve an external endpoint once in its authored body. Internal bindings
  /// remain relationships, including when members have different parents.
  private static func detached(_ member:Member,selected:Set<String>) -> NotebookGraphic {
    var graphic=member.graphic
    guard let connection=graphic.connection,
      connection.bindings.contains(where:{ !selected.contains($0.elementID) }) else { return graphic }
    graphic.connection=connection.detachingEndpoints(in:member.body,retainingBindingsTo:selected)
    return graphic
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

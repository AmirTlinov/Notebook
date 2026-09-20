import CoreGraphics
import Foundation

/// Addressed placement, not a materialized copy of the descendants. Geometry
/// and input consume the same local-to-surface map; world origin stays tiled.
public struct NotebookElementPlacement: Equatable, Sendable {
  public struct Source: Codable, Equatable, Sendable {
    public var frame: PageRect
    public var origin: WorldPoint
    public var parentID: String?
    public var basis: NotebookElementBasis?
    public let isGroup: Bool
    public init(frame: PageRect,origin: WorldPoint = .zero,parentID: String? = nil,basis: NotebookElementBasis? = nil,isGroup: Bool = false) {
      self.frame=frame;self.origin=origin;self.parentID=parentID;self.basis=basis;self.isGroup=isGroup
    }
  }
  /// Only groups allocate a shared frame. Leaves retain one local map in their
  /// existing descriptor, not a copied array of all ancestor matrices.
  final class Frame: Sendable {
    let id: String
    let parent: Frame?
    let local: CGAffineTransform
    let transform: CGAffineTransform
    let origin: WorldPoint
    let rootID: String
    let depth: Int
    init(id: String, source: Source, parent: Frame?) throws {
      self.id=id;self.parent=parent;local=try NotebookElementPlacement.local(source)
      transform=local.concatenating(parent?.transform ?? .identity)
      try NotebookElementPlacement.validate(transform)
      origin=parent?.origin ?? source.origin;rootID=parent?.rootID ?? id;depth=(parent?.depth ?? 0)+1
    }
  }
  /// Both an addressed SQL read and the existing graphic graph use this one
  /// resolver. Its group frames are shared within the immutable source cut.
  final class Resolver {
    private let read: (String) throws -> Source?
    private var frames: [String:Frame] = [:]
    init(read: @escaping (String) throws -> Source?) { self.read=read }
    func resolve(_ id: String) throws -> NotebookElementPlacement? {
      guard let source=try read(id) else { return nil }
      return try resolve(id,source:source)
    }
    func resolve(_ id: String,source: Source) throws -> NotebookElementPlacement? {
      var parent: Frame?
      if let parentID=source.parentID {
        guard let value=try frame(parentID,visiting:[collaborationIdentity(id)]) else { return nil }
        parent=value
      }
      guard (parent?.depth ?? 0)<64 else { throw NotebookStorageError.limitExceeded("element_group_depth") }
      return try .init(id:id,source:source,parent:parent)
    }
    private func frame(_ id: String,visiting: Set<String>) throws -> Frame? {
      let key=collaborationIdentity(id)
      guard !visiting.contains(key) else { return nil }
      guard visiting.count<64 else { throw NotebookStorageError.limitExceeded("element_group_depth") }
      if let frame=frames[key] { return frame }
      guard let source=try read(id),source.isGroup else { return nil }
      var parent: Frame?
      if let parentID=source.parentID {
        guard let value=try frame(parentID,visiting:visiting.union([key])) else { return nil }
        parent=value
      }
      let result=try Frame(id:id,source:source,parent:parent);frames[key]=result;return result
    }
  }
  public let rootID: String
  public let origin: WorldPoint
  public private(set) var localSize: SpatialPoint
  public private(set) var transform: CGAffineTransform
  private var local: CGAffineTransform
  public let basis: NotebookElementBasis?
  private let parent: Frame?
  public var ancestors: [String] {
    var values: [String]=[],frame=parent
    while let current=frame { values.append(current.id);frame=current.parent }
    return values
  }
  public func descends(from id: String) -> Bool {
    let key=collaborationIdentity(id)
    var frame=parent
    while let current=frame {
      if collaborationIdentity(current.id) == key { return true };frame=current.parent
    }
    return false
  }
  public var parentID: String? { parent?.id }
  public var localTransform: CGAffineTransform { local }
  public var parentTransform: CGAffineTransform { parent?.transform ?? .identity }
  var parentOrigin: WorldPoint { parent == nil ? origin : .zero }
  public var bounds: CGRect { CGRect(x:0,y:0,width:localSize.x,height:localSize.y).applying(transform) }
  public init(id: String,frame: PageRect,origin: WorldPoint = .zero) {
    rootID=id;self.origin=origin;localSize = .init(x:frame.width,y:frame.height)
    local = .init(translationX:frame.x,y:frame.y);transform=local;parent=nil;basis=nil
  }
  private init(id: String,source: Source,parent: Frame?) throws {
    self.parent=parent;rootID=parent?.rootID ?? id;origin=parent?.origin ?? source.origin;basis=source.basis
    localSize=source.basis?.size ?? .init(x:source.frame.width,y:source.frame.height)
    local=try Self.local(source);transform=local.concatenating(parent?.transform ?? .identity)
    try Self.validate(transform)
  }
  /// A frame draft changes placement, not its shared ancestry. The plain
  /// element's body resizes; an explicit basis retains its original local size.
  public func updating(frame: PageRect,basis: NotebookElementBasis?) throws -> Self {
    try .init(id:rootID,source:.init(frame:frame,origin:origin,parentID:nil,basis:basis,isGroup:false),parent:parent)
  }

  /// A physical edit changes this one local descriptor. Descendant bodies,
  /// internal relationships and the tiled world origin are never rewritten.
  public func applyingSurfaceTransform(_ change: CGAffineTransform) throws -> (frame:PageRect,basis:NotebookElementBasis) {
    let parent=parentTransform,det=parent.a*parent.d-parent.b*parent.c
    guard det.isFinite,det != 0 else { throw NotebookStorageError.limitExceeded("element_group_projection") }
    let local=transform.concatenating(change).concatenating(parent.inverted())
    let bounds=CGRect(x:0,y:0,width:localSize.x,height:localSize.y).applying(local)
    let frame=PageRect(x:bounds.minX,y:bounds.minY,width:bounds.width,height:bounds.height)
    guard NotebookElementBasis.validLocalFrame(frame) else { throw NotebookStorageError.limitExceeded("element_group_projection") }
    let basis=NotebookElementBasis(size:localSize,transform:.init(
      a:local.a*localSize.x/bounds.width,b:local.b*localSize.x/bounds.height,
      c:local.c*localSize.y/bounds.width,d:local.d*localSize.y/bounds.height,
      tx:(local.tx-bounds.minX)/bounds.width,ty:(local.ty-bounds.minY)/bounds.height))
    guard basis.isValid else { throw NotebookStorageError.limitExceeded("element_group_projection") }
    return (frame,basis)
  }

  public func parentVector(_ vector: SpatialPoint) -> SpatialPoint? { Self.vector(vector,through:parentTransform) }
  public func bodyVector(_ vector: SpatialPoint) -> SpatialPoint? { Self.vector(vector,through:transform) }
  private static func vector(_ v: SpatialPoint,through t: CGAffineTransform) -> SpatialPoint? {
    let det=t.a*t.d-t.b*t.c
    guard det.isFinite,det != 0 else { return nil }
    let p=SpatialPoint(x:(t.d*v.x-t.c*v.y)/det,y:(t.a*v.y-t.b*v.x)/det)
    return p.x.isFinite && p.y.isFinite ? p : nil
  }
  public static func == (a: Self,b: Self) -> Bool {
    a.origin == b.origin && a.rootID == b.rootID && a.localSize == b.localSize && a.local == b.local
      && a.transform == b.transform && a.basis == b.basis && a.ancestors == b.ancestors
  }
  private static func local(_ source: Source) throws -> CGAffineTransform {
    try source.basis?.placement(in:source.frame) ?? .init(translationX:source.frame.x,y:source.frame.y)
  }
  private static func validate(_ t: CGAffineTransform) throws {
    guard [t.a,t.b,t.c,t.d,t.tx,t.ty].allSatisfy(\.isFinite) else {
      throw NotebookStorageError.limitExceeded("element_group_projection")
    }
  }
  /// Removing the IDENTICAL shared outer frame is structural factoring, not
  /// approximate matrix inversion/cancellation. Internal bindings therefore
  /// retain their local curve when the whole group moves or stretches.
  public func point(_ point: SpatialPoint,from other: Self) -> SpatialPoint? {
    var a=parent,b=other.parent
    while (a?.depth ?? 0)>(b?.depth ?? 0) { a=a?.parent }
    while (b?.depth ?? 0)>(a?.depth ?? 0) { b=b?.parent }
    while a !== b { a=a?.parent;b=b?.parent }
    let common=a
    func inner(_ value: Self) -> CGAffineTransform {
      var result=value.local,frame=value.parent
      while frame !== common,let current=frame { result=result.concatenating(current.local);frame=current.parent }
      return result
    }
    let own=inner(self),foreign=inner(other)
    let determinant=own.a*own.d-own.b*own.c
    guard determinant.isFinite,determinant != 0 else { return nil }
    let delta=common == nil ? origin.delta(to:other.origin) : .zero
    let map=foreign.concatenating(.init(translationX:delta.x,y:delta.y)).concatenating(own.inverted())
    let p=CGPoint(x:point.x,y:point.y).applying(map)
    guard p.x.isFinite,p.y.isFinite else { return nil }
    return .init(x:p.x,y:p.y)
  }
}

extension CollaborationWorkspace {
  /// Validate the complete authored action, including groups inserted after
  /// their members. Delivered concurrent state is not repaired by this check.
  func validateElementParents(action: CollaborationAction, scope: NotebookStore) throws {
    for (index,operation) in action.operations.enumerated() {
      guard let child = operation.id, operation.values["parentID"]?.string != nil,
        [.insertElement,.updateElement].contains(operation.kind) else { continue }
      do {
        let target = operation.target
        let elements: [JSONValue]
        if target.kind == .page { elements = files["pages/\(target.id.uuidString.lowercased()).json"]?["elements"]?.array ?? [] }
        else {
          elements = files["board.json"]?["boards"]?.array.first {
            $0["id"]?.string.flatMap(UUID.init(uuidString:)) == (target.boardID ?? target.id)
          }?["board"]?["elements"]?.array ?? []
        }
        let values = Dictionary(uniqueKeysWithValues:elements.compactMap { value in value["id"]?.string.map { (collaborationIdentity($0),value) } })
        let removed = Set(action.operations.filter { $0.target == target && $0.kind == .removeElement }.compactMap(\.id).map(collaborationIdentity))
        var visited: Set<String> = [collaborationIdentity(child)]
        var parent = values[collaborationIdentity(child)]?["parentID"]?.string
        while let id = parent {
          guard NotebookElementBasis.validParent(id,childID:child), visited.count < 64,
            visited.insert(collaborationIdentity(id)).inserted, !removed.contains(collaborationIdentity(id)) else {
            throw CollaborationError("invalid_parent","Вложенные группы не образуют цикл и не превышают 64 уровня.",target:target)
          }
          let value: JSONValue?
          if let local = values[collaborationIdentity(id)] { value = local }
          else if target.kind == .page { value = try scope.readPageElement(pageID:target.id,elementID:id).map(JSONValue.encode) }
          else { value = try scope.readSpatialElement(boardID:target.boardID ?? target.id,elementID:id).map(JSONValue.encode) }
          guard let value, value["kind"]?.string == "group" else {
            throw CollaborationError("invalid_parent","Родитель объекта — существующая группа этой поверхности.",target:target)
          }
          if target.kind != .page {
            let surface: SurfaceID = target.kind == .cover ? .cover(target.id) : .board(target.id)
            guard try value["surface"]?.decode(SurfaceID.self) == surface else {
              throw CollaborationError("invalid_parent","Группа и её участники принадлежат одной поверхности.",target:target)
            }
          }
          parent = value["parentID"]?.string
        }
      } catch let error as CollaborationError { throw error.atOperation(index,operation) }
    }
  }
}

extension NotebookStore {
  /// A bounded slice of membership in the existing reference/order index. The
  /// group pose is not in this key, so moving it does not rewrite its children.
  public func readElementChildren(target: CollaborationTarget, parentID: String?, afterElementID: String? = nil,
    limit: Int = 64) throws -> [String] {
    guard [.page,.board,.cover].contains(target.kind), (1...1024).contains(limit) else {
      throw NotebookStorageError.invalidTransaction("element group window")
    }
    return try readTransaction { _ in
      let owner = target.kind.rawValue+":"+target.id.uuidString.lowercased()+(target.kind == .page ? "|elements" : "")
      var args: [NotebookSQLValue] = [.text(owner),parentID.map { .text(collaborationIdentity($0)) } ?? .null]
      var seek = ""
      if let afterElementID {
        guard let anchor = try currentSQL!.rows("SELECT position,member FROM reference_element_order WHERE owner_key=? AND parent_id IS ? AND member=?",args+[.text(afterElementID)]).first else {
          throw NotebookStorageError.invalidTransaction("element group cursor")
        }
        seek = " AND (position,member)>(?,?)"; args += [anchor[0],anchor[1]]
      }
      return try currentSQL!.rows("SELECT member FROM reference_element_order WHERE owner_key=? AND parent_id IS ?"+seek+" ORDER BY position,member LIMIT ?",
        args+[.integer(Int64(limit))]).compactMap { $0[0].text }
    }
  }

  public func readElementPlacement(target: CollaborationTarget, elementID: String,
    groupPoses: [String:NotebookElementPlacement.Source] = [:]) throws -> NotebookElementPlacement? {
    try readTransaction { _ in
      let poses = try checkedGroupPoses(groupPoses,target:target)
      return try NotebookElementPlacement.Resolver {
        try poses[collaborationIdentity($0)] ?? self.elementGroupingSource(target:target,id:$0)
      }.resolve(elementID)
    }
  }

  /// Creating membership necessarily addresses each selected object once.
  /// Later pose edits name only the group through applyNativeElementEdits.
  public func groupNativeElements(_ sources: [NotebookNativeElementSource], id: String, actor: UUID
  ) throws -> CollaborationReceipt {
    try commandTransaction(readAllowance:.agentCommand) {
      let operations=try Self.elementGroupingEdits(sources,id:id)
      // Insertion adds a nonpainted address. The original flat painter order is
      // untouched, including unselected objects between selected members.
      return try applyNativeElementEdits(operations,summary:"Сгруппировать объекты",
        sources:sources+[.init(target:operations[0].target,id:id)],actor:actor).receipt
    }
  }

  /// The app and store prepare the same finite membership action; persistence
  /// still validates the exact sources atomically through the existing writer.
  public static func elementGroupingEdits(_ sources: [NotebookNativeElementSource],id: String) throws -> [CollaborationOperation] {
      guard let target = sources.first?.target, (2...31).contains(sources.count),
        sources.allSatisfy({ $0.target == target }), Set(sources.map { collaborationIdentity($0.id) }).count == sources.count,
        !id.isEmpty, id.utf16.count <= 120, !sources.contains(where:{ collaborationIdentity($0.id) == collaborationIdentity(id) }) else {
        throw CollaborationError("invalid_operation","Группа получает свободный ID и от 2 до 31 выбранного объекта одной поверхности.")
      }
      let members = try sources.map { source -> NotebookElementPlacement.Source in
        guard let element = source.placementSource else {
          throw CollaborationError("revision_conflict","Выбранный объект исчез до группировки.")
        }
        return element
      }
      let parent = members[0].parentID, origin = members[0].origin
      guard members.allSatisfy({ $0.parentID.map(collaborationIdentity) == parent.map(collaborationIdentity) }) else {
        throw CollaborationError("invalid_operation","Группировка выбирает соседей одного локального основания.")
      }
      let frames = members.map { member -> CGRect in
        let d = origin.delta(to:member.origin), f = member.frame
        return .init(x:d.x+f.x,y:d.y+f.y,width:f.width,height:f.height)
      }
      let bounds = frames.reduce(CGRect.null) { $0.union($1) }
      let basis = NotebookElementBasis(size:.init(x:bounds.width,y:bounds.height))
      guard basis.isValid else { throw CollaborationError("invalid_operation","Группа выходит за допустимый локальный размер.") }
      let groupFrame = PageRect(x:bounds.minX,y:bounds.minY,width:bounds.width,height:bounds.height)
      var values: [String:JSONValue] = ["kind":.string("group"),"source":.string(""),
        "frame":try .encode(groupFrame),"basis":try .encode(basis)]
      if let parent { values["parentID"] = .string(parent) }
      if target.kind == .board { values["worldOrigin"] = try .encode(origin) }
      var operations: [CollaborationOperation] = [.init(kind:.insertElement,target:target,id:id,values:values)]
      for (source,frame) in zip(sources,frames) {
        var patch: [String:JSONValue] = ["parentID":.string(id),
          "frame":try .encode(PageRect(x:frame.minX-bounds.minX,y:frame.minY-bounds.minY,width:frame.width,height:frame.height))]
        if target.kind == .board { patch["worldOrigin"] = try .encode(WorldPoint.zero) }
        operations.append(.init(kind:.updateElement,target:target,id:source.id,values:patch))
      }
      return operations
  }

  func elementGroupingSource(target: CollaborationTarget,id: String) throws -> NotebookElementPlacement.Source? {
    if target.kind == .page {
      return try readPageElement(pageID:target.id,elementID:id).map {
        .init(frame:$0.frame,origin:.zero,parentID:$0.parentID,basis:$0.basis,isGroup:$0.kind == .group)
      }
    }
    guard target.kind == .board || target.kind == .cover else {
      throw NotebookStorageError.invalidTransaction("element grouping owner")
    }
    let surface: SurfaceID = target.kind == .board ? .board(target.id) : .cover(target.id)
    guard let element = try readSpatialElement(boardID:target.boardID ?? target.id,elementID:id),element.surface == surface else { return nil }
    return .init(frame:.init(x:element.frame.x,y:element.frame.y,width:element.frame.width,height:element.frame.height),
      origin:element.worldOrigin ?? .zero,parentID:element.parentID,basis:element.basis,isGroup:element.kind == .group)
  }
}

extension NotebookNativeElementSource {
  public var placementSource: NotebookElementPlacement.Source? {
    if let page { return .init(frame:page.frame,parentID:page.parentID,basis:page.basis,isGroup:page.kind == .group) }
    if let spatial { return .init(frame:.init(x:spatial.frame.x,y:spatial.frame.y,width:spatial.frame.width,height:spatial.frame.height),
      origin:spatial.worldOrigin ?? .zero,parentID:spatial.parentID,basis:spatial.basis,isGroup:spatial.kind == .group) }
    return nil
  }
}

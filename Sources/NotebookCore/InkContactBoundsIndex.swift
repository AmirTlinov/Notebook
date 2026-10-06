import CoreGraphics
import Foundation

/// The prepared ink root owns contact bounds and material size before input is
/// admitted. Pen and eraser partitions serve lasso and causal reads together;
/// an append rebuilds at most one 256-contact block per affected surface.
struct InkContactBoundsIndex:Sendable {
  private struct Address:Hashable,Sendable {let surface:SurfaceID?;let tool:SpatialInkTool}
  private struct Contact:Sendable {
    let id:UUID
    let order:Int
    let bounds:WorkspaceSpatialBounds
    let materialBytes:Int
    let erasures:[InkElementErasure]
    var active:Bool
  }
  private struct Block:Sendable {
    let contacts:[Contact]
    let activeIDs:Set<UUID>
    let bounds:WorkspaceSpatialBounds?
    let index:WorkspaceSpatialIndex
    var retainedMetadataBytes:Int {
      128+contacts.capacity*MemoryLayout<Contact>.stride
        + contacts.reduce(0) {$0+$1.erasures.capacity*MemoryLayout<InkElementErasure>.stride}
        + activeIDs.capacity*2*(MemoryLayout<UUID>.stride+8)+index.retainedMetadataBytes
    }
    init(_ contacts:[Contact]) {
      self.contacts=contacts
      let active=contacts.enumerated().filter {$0.element.active}
      activeIDs=Set(active.map(\.element.id))
      bounds=active.first.map {first in active.dropFirst().reduce(first.element.bounds) {$0.union($1.element.bounds)}}
      index = .init(entries:active.map {
        .init(id:.element($0.element.id.uuidString),bounds:$0.element.bounds,zIndex:Double($0.offset))
      })
    }
  }
  private var blocks:[Address:[Block]] = [:]
  private var blockBytes=0
  private var positionBytes=0
  private var targetBytes=0
  private struct Position:Sendable {let address:Address;let block:Int;let offset:Int}
  private var positions:InkActionMapNode<UUID,[Position]>?
  private var masks:[SurfaceID:InkElementErasureMap] = [:]
  private var ordinal=0
  var retainedMetadataBytes:Int {
    256+blockBytes+positionBytes+targetBytes
      + blocks.capacity*2*(MemoryLayout<Address>.stride+MemoryLayout<[Block]>.stride+8)
      + masks.capacity*2*(MemoryLayout<SurfaceID>.stride+MemoryLayout<InkElementErasureMap>.stride+8)
  }
  init() {}
  init(page actions:[PageInkAction]) {
    var groups:[Address:[Contact]]=[:]
    for action in actions {
      groups[.init(surface:nil,tool:action.tool),default:[]].append(Self.contact(action,order:ordinal));ordinal += 1
    }
    build(groups)
  }
  init(spatial actions:[SpatialInkAction]) {
    var groups:[Address:[Contact]]=[:]
    for action in actions {
      for (surface,contact) in Self.contacts(action,order:ordinal) {
        groups[.init(surface:surface,tool:action.tool),default:[]].append(contact)
        applyMasks(contact,on:surface,active:contact.active)
      }
      ordinal += 1
    }
    build(groups)
  }
  private mutating func build(_ groups:[Address:[Contact]]) {
    var positions:[UUID:[Position]]=[:]
    for (address,contacts) in groups {
      let group:[Block]=stride(from:0,to:contacts.count,by:256).map {
        .init(Array(contacts[$0..<min($0+256,contacts.count)]))
      }
      blocks[address]=group
      blockBytes += group.capacity*MemoryLayout<Block>.stride+group.reduce(0) {$0+$1.retainedMetadataBytes}
      positionBytes += contacts.count*(MemoryLayout<Position>.stride*2+128)
      for (offset,contact) in contacts.enumerated() {
        positions[contact.id,default:[]].append(.init(address:address,block:offset/256,offset:offset%256))
      }
    }
    let ordered=positions.sorted {$0.key<$1.key}.map {($0.key,$0.value)}
    self.positions=InkActionMapNode.balanced(ordered,0,ordered.count)
  }

  private static func materialBytes(id:UUID,tool:SpatialInkTool,color:SpatialInkColor,
    spans:[(Int,InkMeasurements)])->Int {
    64+spans.reduce(0) { total,span in
      total+InkSampleRelations(sourceID:id,span:span.0,measurements:span.1,
        header:.init(tool:tool,color:color)).payloadBytes+MemoryLayout<NotebookFreehand.Layer>.stride+256
    }
  }
  private mutating func append(_ contact:Contact,on surface:SurfaceID?,tool:SpatialInkTool) {
    let key=Address(surface:surface,tool:tool)
    var group=blocks[key] ?? [],tail:[Contact]=[]
    let priorCapacity=group.capacity
    if let last=group.last,last.contacts.count<256 {
      tail=group.removeLast().contacts;blockBytes -= last.retainedMetadataBytes
    }
    let position=Position(address:key,block:group.count,offset:tail.count)
    tail.append(contact);let block=Block(tail);group.append(block);blocks[key]=group
    blockBytes += block.retainedMetadataBytes+(group.capacity-priorCapacity)*MemoryLayout<Block>.stride
    positionBytes += MemoryLayout<Position>.stride*2+128
    let updated=(positions?.value(for:contact.id) ?? [])+[position]
    positions=positions?.inserting(contact.id,updated) ?? .init(contact.id,updated)
  }
  private static func contact(_ action:PageInkAction,order:Int)->Contact {
    .init(id:action.id,order:order,bounds:NotebookInkReadSet.bounds(of:action.samples),
      materialBytes:Self.materialBytes(id:action.id,tool:action.tool,color:action.color,spans:[(0,action.samples)]),
      erasures:[],active:action.isActive)
  }
  mutating func append(_ action:PageInkAction) {
    append(Self.contact(action,order:ordinal),on:nil,tool:action.tool)
    ordinal += 1
  }
  private static func contacts(_ action:SpatialInkAction,order:Int)->[(SurfaceID,Contact)] {
    var surfaces:[SurfaceID:[(Int,SpatialInkSpan)]]=[:]
    for (offset,span) in action.spans.enumerated() {surfaces[span.surface,default:[]].append((offset,span))}
    return surfaces.map { surface,spans in
      let bounds=spans.dropFirst().reduce(NotebookInkReadSet.bounds(of:spans[0].1.samples)) {$0.union(NotebookInkReadSet.bounds(of:$1.1.samples))}
      let erasures=spans.flatMap {_,span in (span.elementTargets ?? []).map {InkElementErasure(target:$0,measurements:span.samples)}}
      return (surface,.init(id:action.id,order:order,bounds:bounds,
        materialBytes:Self.materialBytes(id:action.id,tool:action.tool,color:action.color,spans:spans.map {($0.0,$0.1.samples)}),
        erasures:erasures,active:action.isActive))
    }
  }
  private mutating func applyMasks(_ contact:Contact,on surface:SurfaceID?,active:Bool) {
    guard let surface,!contact.erasures.isEmpty else {return}
    var map=masks[surface] ?? .init()
    let before=masks[surface]?.retainedMetadataBytes ?? 0
    for (part,cut) in contact.erasures.enumerated() {
      if active {map.insert(cut,at:UInt64(contact.order),actionID:contact.id,part:part,for:cut.target.elementID)}
      else {map.remove(at:UInt64(contact.order),actionID:contact.id,part:part,for:cut.target.elementID)}
    }
    if map.isEmpty {masks.removeValue(forKey:surface)} else {masks[surface]=map}
    targetBytes += (map.isEmpty ? 0:map.retainedMetadataBytes)-before
  }
  mutating func append(_ action:SpatialInkAction) {
    for (surface,contact) in Self.contacts(action,order:ordinal) {
      append(contact,on:surface,tool:action.tool);applyMasks(contact,on:surface,active:contact.active)
    }
    ordinal += 1
  }
  mutating func setActive(_ active:Bool,for ids:Set<UUID>) {
    var affected:[Address:[Int:Set<Int>]]=[:]
    for id in ids {
      for position in positions?.value(for:id) ?? [] {
        affected[position.address,default:[:]][position.block,default:[]].insert(position.offset)
      }
    }
    for (address,changes) in affected {
      guard var group=blocks[address] else {continue}
      for (block,offsets) in changes {
        var contacts=group[block].contacts
        guard offsets.contains(where:{contacts[$0].active != active}) else {continue}
        let prior=group[block].retainedMetadataBytes
        for offset in offsets where contacts[offset].active != active {
          applyMasks(contacts[offset],on:address.surface,active:active)
          contacts[offset].active=active
        }
        group[block] = .init(contacts)
        blockBytes += group[block].retainedMetadataBytes-prior
      }
      blocks[address]=group
    }
  }
  private func query(on surface:SurfaceID?,tool:SpatialInkTool,in bounds:WorkspaceSpatialBounds,limit:Int?,
    excluding:Set<UUID> = [],including:(Contact)->Bool = {_ in true}) throws ->[Contact] {
    var result:[Contact]=[]
    for block in blocks[.init(surface:surface,tool:tool)] ?? [] {
      guard block.bounds?.intersects(bounds) == true else {continue}
      let found:[WorkspaceSpatialEntry]
      if !excluding.isEmpty {
        // Iterate the bounded block, not Set.subtracting's larger operand.
        let visible=block.activeIDs.filter {!excluding.contains($0)}
        if visible.isEmpty {continue}
        // A claimed journal may leave one visible contact in each block.
        // Address that remainder rather than traversing hidden geometry.
        if visible.count < block.activeIDs.count/2 {
          found=visible.compactMap {block.index.entry(id:.element($0.uuidString))}.filter {$0.bounds.intersects(bounds)}
        } else {found=block.index.intersections(in:bounds,limit:256).entries}
      } else {found=block.index.intersections(in:bounds,limit:256).entries}
      for entry in found {
        let contact=block.contacts[Int(entry.zIndex)]
        guard !excluding.contains(contact.id),including(contact) else {continue}
        if limit.map({result.count >= $0}) == true {
          throw CollaborationError("selection_limit","В этой области слишком много штрихов.")
        }
        result.append(contact)
      }
    }
    return result
  }
  /// Existing causal readers request only the eraser partition, without a
  /// lasso limit; each block contains at most 256 entries.
  func candidates(on surface:SurfaceID?,in bounds:WorkspaceSpatialBounds)->Set<UUID> {
    Set(try! query(on:surface,tool:.eraser,in:bounds,limit:nil).map(\.id))
  }
  func regionContacts(on surface:SurfaceID?,in bounds:WorkspaceSpatialBounds,
    excluding:Set<UUID>,maximumCount:Int,isActive:(UUID)->Bool) throws ->(ids:[UUID],bytes:Int) {
    let pens=try query(on:surface,tool:.pen,in:bounds,limit:maximumCount,excluding:excluding) {isActive($0.id)}
    var bytes=MemoryLayout<NotebookGraphic>.stride+MemoryLayout<NotebookFreehand>.stride
    var contacts=pens
    for pen in pens {bytes += pen.materialBytes}
    if let first=pens.first {
      let whole=pens.dropFirst().reduce(first.bounds) {$0.union($1.bounds)}
      let erasers=try query(on:surface,tool:.eraser,in:whole,limit:maximumCount)
      for cut in erasers where isActive(cut.id) {bytes += cut.materialBytes;contacts.append(cut)}
    }
    return (contacts.sorted {$0.order < $1.order}.map(\.id),bytes)
  }
  func capturedErasures(on surface:SurfaceID,for ids:Set<String>)->InkElementErasureMap {
    masks[surface]?.capturing(ids) ?? .init()
  }
}

/// An addressed admission cut of an already input-ready root. Exact measured
/// geometry can still be preparing; no decoding or full-history walk is needed.
public struct NotebookInkRegionCapture:Sendable {
  public struct Contact:Sendable {
    public let id:UUID
    public let tool:SpatialInkTool
    public let color:SpatialInkColor
    public let sources:[InkSampleRelations]
    public let allowsWholeContact:Bool
  }
  public let contacts:[Contact]
  public let materialBytes:Int
  public let erasures:InkElementErasureMap
  /// Only addressed immutable relations survive lift, never their journal or
  /// its full contact index. Shared relation nodes are conservatively charged.
  public var retainedPayloadBytes:Int {
    let ink=128+contacts.capacity*MemoryLayout<Contact>.stride+materialBytes
    return ink+erasures.retainedPayloadBytes
  }
}

extension PageInkSource {
  public func regionCapture(in bounds:WorkspaceSpatialBounds,elements:Set<String>,excluding:Set<UUID>,
    maximumCount:Int) throws ->NotebookInkRegionCapture? {
    guard let prepared=preparedProjection else {return nil}
    let cut=try prepared.contactIndex.regionContacts(on:nil,in:bounds,excluding:excluding,
      maximumCount:maximumCount) {prepared.drawing.action(id:$0)?.isActive == true}
    let contacts=cut.ids.compactMap {id -> NotebookInkRegionCapture.Contact? in
      guard let action=prepared.drawing.action(id:id) else {return nil}
      let source=InkSampleRelations(sourceID:id,measurements:action.samples,header:.init(tool:action.tool,color:action.color))
      return .init(id:id,tool:action.tool,color:action.color,sources:[source],allowsWholeContact:true)
    }
    let cuts=prepared.erasures.values.capturing(elements)
    return .init(contacts:contacts,materialBytes:cut.bytes,erasures:cuts)
  }
}

extension SpatialInkJournal {
  public func regionCapture(on surface:SurfaceID,in bounds:WorkspaceSpatialBounds,elements:Set<String>,
    excluding:Set<UUID>,maximumCount:Int) throws ->NotebookInkRegionCapture {
    let cut=try storage.contactIndex.regionContacts(on:surface,in:bounds,excluding:excluding,
      maximumCount:maximumCount) {action(id:$0)?.isActive == true}
    let contacts=cut.ids.compactMap {id -> NotebookInkRegionCapture.Contact? in
      guard let action=action(id:id) else {return nil}
      let sources=action.spans.enumerated().filter {$0.element.surface == surface}.map {index,span in
        InkSampleRelations(sourceID:id,span:index,measurements:span.samples,header:.init(tool:action.tool,color:action.color))
      }
      return .init(id:id,tool:action.tool,color:action.color,sources:sources,
        allowsWholeContact:action.spans.allSatisfy {$0.surface == surface})
    }
    return .init(contacts:contacts,materialBytes:cut.bytes,
      erasures:storage.contactIndex.capturedErasures(on:surface,for:elements))
  }
}

import Foundation

/// Immutable addressed mask projection. Old page sources retain their roots;
/// accepting one cut copies only its target and paint-order search paths.
/// Arrays are disclosed lazily by the material consumer for that one target.
public struct InkElementErasureMap:Sendable,Equatable,Sequence,ExpressibleByDictionaryLiteral {
  private struct PaintKey:Comparable,Sendable {
    let sequence:UInt64
    let action:String
    let part:Int
    static func <(lhs:Self,rhs:Self)->Bool {
      if lhs.sequence != rhs.sequence {return lhs.sequence<rhs.sequence}
      if lhs.action != rhs.action {return lhs.action<rhs.action}
      return lhs.part<rhs.part
    }
  }
  private final class Cuts:@unchecked Sendable {
    let root:InkActionMapNode<PaintKey,InkElementErasure>?
    let payloadBytes:Int
    let metadataBytes:Int
    let count:Int
    private let lock=NSLock()
    private var cached:[InkElementErasure]?
    init(root:InkActionMapNode<PaintKey,InkElementErasure>?,payloadBytes:Int,metadataBytes:Int,count:Int) {
      self.root=root;self.payloadBytes=payloadBytes;self.metadataBytes=metadataBytes;self.count=count
    }
    init(_ values:[InkElementErasure]) {
      root=InkActionMapNode.balanced(values.enumerated().map{(PaintKey(sequence:UInt64($0.offset),action:"",part:0),$0.element)},0,values.count)
      count=values.count
      metadataBytes=values.reduce(128) {$0+Self.metadata($1)}
        + Swift.max(0,values.capacity-values.count*2)*MemoryLayout<InkElementErasure>.stride
      payloadBytes=metadataBytes+values.reduce(0) {$0+$1.samples.payloadBytes}
      cached=values
    }
    static func metadata(_ value:InkElementErasure)->Int {
      // Persistent paint node and the lazily disclosed array can coexist.
      256+MemoryLayout<InkElementErasure>.stride*3+value.target.elementID.utf8.count*2
    }
    var values:[InkElementErasure] {lock.withLock {
      if let cached {return cached}
      var result:[InkElementErasure]=[];result.reserveCapacity(count)
      root?.values(into:&result);cached=result;return result
    }}
  }
  private struct Entry:Sendable {let key:String;let cuts:Cuts}
  private var root:InkActionMapNode<String,Entry>?
  public private(set) var retainedPayloadBytes=128
  private(set) var retainedMetadataBytes=128
  public init() {}
  public init(dictionary:[String:[InkElementErasure]]) {
    let entries=dictionary.sorted{$0.key<$1.key}.map{($0.key,Entry(key:$0.key,cuts:Cuts($0.value)))}
    root=InkActionMapNode.balanced(entries,0,entries.count)
    for (_,entry) in entries {account(entry,adding:true)}
  }
  public init(dictionaryLiteral elements:(String,[InkElementErasure])...) {
    self.init(dictionary:Dictionary(elements,uniquingKeysWith:{$1}))
  }
  public var isEmpty:Bool {root == nil}
  private mutating func account(_ entry:Entry,adding:Bool) {
    let sign=adding ? 1 : -1,base=entry.key.utf8.count*2+128
    retainedPayloadBytes += sign*(base+entry.cuts.payloadBytes)
    retainedMetadataBytes += sign*(base+entry.cuts.metadataBytes)
  }
  private mutating func set(_ entry:Entry?,for key:String) {
    if let old=root?.value(for:key) {account(old,adding:false)}
    guard let entry else {root=root?.removing(key);return}
    root=root?.inserting(key,entry) ?? .init(key,entry);account(entry,adding:true)
  }
  /// Shares only addressed immutable mask roots. Disclosure of their arrays is
  /// left to the material worker, even for a target with a long eraser history.
  public func capturing(_ ids:Set<String>)->Self {
    var result=Self()
    for id in ids {if let entry=root?.value(for:id) {result.set(entry,for:id)}}
    return result
  }
  public subscript(_ key:String)->[InkElementErasure]? {
    get {root?.value(for:key)?.cuts.values}
    set {
      set(newValue.map {Entry(key:key,cuts:Cuts($0))},for:key)
    }
  }
  public subscript(_ key:String,default fallback:@autoclosure ()->[InkElementErasure])->[InkElementErasure] {
    get {self[key] ?? fallback()}
    set {self[key]=newValue}
  }
  mutating func insert(_ value:InkElementErasure,at sequence:UInt64,actionID:UUID? = nil,part:Int=0,for key:String) {
    let paint=PaintKey(sequence:sequence,action:actionID?.uuidString ?? "",part:part)
    let old=root?.value(for:key)?.cuts,previous=old?.root?.value(for:paint)
    let metadata=(old?.metadataBytes ?? 128)+Cuts.metadata(value)-(previous.map(Cuts.metadata) ?? 0)
    let payload=(old?.payloadBytes ?? 128)+Cuts.metadata(value)+value.samples.payloadBytes
      - (previous.map {Cuts.metadata($0)+$0.samples.payloadBytes} ?? 0)
    set(.init(key:key,cuts:Cuts(root:old?.root?.inserting(paint,value) ?? .init(paint,value),
      payloadBytes:payload,metadataBytes:metadata,count:(old?.count ?? 0)+(previous == nil ? 1:0))),for:key)
  }
  mutating func remove(at sequence:UInt64,actionID:UUID? = nil,part:Int=0,for key:String) {
    let paint=PaintKey(sequence:sequence,action:actionID?.uuidString ?? "",part:part)
    guard let old=root?.value(for:key),let previous=old.cuts.root?.value(for:paint) else {return}
    guard let remaining=old.cuts.root?.removing(paint) else {set(nil,for:key);return}
    let metadata=Cuts.metadata(previous)
    set(.init(key:key,cuts:Cuts(root:remaining,payloadBytes:old.cuts.payloadBytes-metadata-previous.samples.payloadBytes,
      metadataBytes:old.cuts.metadataBytes-metadata,count:old.cuts.count-1)),for:key)
  }
  public var keys:[String] {InkActionSequence(root:root).map(\.key)}
  public struct Iterator:IteratorProtocol {
    private var base:InkActionSequence<String,Entry>.Iterator
    fileprivate init(_ map:InkElementErasureMap) {base=InkActionSequence(root:map.root).makeIterator()}
    public mutating func next()->(key:String,value:[InkElementErasure])? {
      guard let entry=base.next() else {return nil};return (entry.key,entry.cuts.values)
    }
  }
  public func makeIterator()->Iterator {.init(self)}
  public mutating func merge<S:Sequence>(_ other:S,uniquingKeysWith combine:([InkElementErasure],[InkElementErasure])->[InkElementErasure]) where S.Element == (key:String,value:[InkElementErasure]) {
    for (key,value) in other {self[key]=self[key].map{combine($0,value)} ?? value}
  }
  public func filter(_ includes:((key:String,value:[InkElementErasure])) throws->Bool) rethrows->Self {
    var result=Self()
    for entry in self where try includes(entry) {result[entry.key]=entry.value}
    return result
  }
  public static func ==(lhs:Self,rhs:Self)->Bool {
    if lhs.root === rhs.root {return true}
    var a=InkActionSequence(root:lhs.root).makeIterator(),b=InkActionSequence(root:rhs.root).makeIterator()
    while let x=a.next() {
      guard let y=b.next(),x.key == y.key else {return false}
      if x.cuts !== y.cuts && x.cuts.values != y.cuts.values {return false}
    }
    return b.next() == nil
  }
}

import Foundation

/// Immutable addressed mask projection. Old page sources retain their roots;
/// accepting one cut copies only its target and paint-order search paths.
/// Arrays are disclosed lazily by the material consumer for that one target.
public struct InkElementErasureMap:Sendable,Equatable,Sequence,ExpressibleByDictionaryLiteral {
  private struct PaintKey:Comparable,Sendable {
    let sequence:UInt64
    let action:String
    static func <(lhs:Self,rhs:Self)->Bool {
      lhs.sequence == rhs.sequence ? lhs.action<rhs.action:lhs.sequence<rhs.sequence
    }
  }
  private final class Cuts:@unchecked Sendable {
    let root:InkActionMapNode<PaintKey,InkElementErasure>?
    private let lock=NSLock()
    private var cached:[InkElementErasure]?
    init(root:InkActionMapNode<PaintKey,InkElementErasure>?) {self.root=root}
    init(_ values:[InkElementErasure]) {
      root=InkActionMapNode.balanced(values.enumerated().map{(PaintKey(sequence:UInt64($0.offset),action:""),$0.element)},0,values.count)
      cached=values
    }
    var values:[InkElementErasure] {lock.withLock {
      if let cached {return cached}
      var result:[InkElementErasure]=[];root?.values(into:&result);cached=result;return result
    }}
  }
  private struct Entry:Sendable {let key:String;let cuts:Cuts}
  private var root:InkActionMapNode<String,Entry>?
  public init() {}
  public init(dictionary:[String:[InkElementErasure]]) {
    let entries=dictionary.sorted{$0.key<$1.key}.map{($0.key,Entry(key:$0.key,cuts:Cuts($0.value)))}
    root=InkActionMapNode.balanced(entries,0,entries.count)
  }
  public init(dictionaryLiteral elements:(String,[InkElementErasure])...) {
    self.init(dictionary:Dictionary(elements,uniquingKeysWith:{$1}))
  }
  public var isEmpty:Bool {root == nil}
  public subscript(_ key:String)->[InkElementErasure]? {
    get {root?.value(for:key)?.cuts.values}
    set {
      guard let newValue else {root=root?.removing(key);return}
      let entry=Entry(key:key,cuts:Cuts(newValue))
      root=root?.inserting(key,entry) ?? .init(key,entry)
    }
  }
  public subscript(_ key:String,default fallback:@autoclosure ()->[InkElementErasure])->[InkElementErasure] {
    get {self[key] ?? fallback()}
    set {self[key]=newValue}
  }
  mutating func insert(_ value:InkElementErasure,at sequence:UInt64,actionID:UUID? = nil,for key:String) {
    let paint=PaintKey(sequence:sequence,action:actionID?.uuidString ?? "")
    let old=root?.value(for:key)?.cuts.root
    let entry=Entry(key:key,cuts:Cuts(root:old?.inserting(paint,value) ?? .init(paint,value)))
    root=root?.inserting(key,entry) ?? .init(key,entry)
  }
  mutating func remove(at sequence:UInt64,actionID:UUID? = nil,for key:String) {
    let paint=PaintKey(sequence:sequence,action:actionID?.uuidString ?? "")
    guard let old=root?.value(for:key) else {return}
    guard let remaining=old.cuts.root?.removing(paint) else {root=root?.removing(key);return}
    root=root?.inserting(key,.init(key:key,cuts:Cuts(root:remaining)))
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

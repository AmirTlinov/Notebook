import Foundation

/// One disposable lookup belongs to one immutable BoardDocument element value.
/// Copies share it until a mutation resets the cache; no derived map is stored.
final class BoardElementLookupCache: @unchecked Sendable {
  private let lock=NSLock()
  private var prepared:BoardElementLookup?
  init(_ elements:[SpatialElement]?=nil) { prepared=elements.map(BoardElementLookup.init) }
  init(_ prepared:BoardElementLookup) { self.prepared=prepared }
  func value(for elements:[SpatialElement])->BoardElementLookup {
    lock.lock();defer { lock.unlock() }
    if let prepared { return prepared }
    let value=BoardElementLookup(elements);prepared=value;return value
  }
}

struct BoardElementLookup: Sendable {
  private var positions:[String:Int]
  init(_ elements:[SpatialElement]) {
    positions=Dictionary(elements.enumerated().map {
      ($0.element.id,$0.offset)
    },uniquingKeysWith:{ first,_ in first })
  }
  func position(of id:String)->Int? { positions[id] }
  mutating func insert(_ id:String,at position:Int) { positions[id]=position }
}

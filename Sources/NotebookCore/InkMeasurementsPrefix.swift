import Foundation

extension InkMeasurements {
  /// Exact prefix equality for a replacement display source. Shared immutable
  /// branches are skipped; a growing contact does not decode its old events.
  public func unchangedPrefix(comparedTo other: Self) -> Int {
    func prefix(_ a: InkSampleRelations.Sequence, _ b: InkSampleRelations.Sequence) -> Int {
      if a === b || a.sameRepresentation(as:b) { return a.count }
      if a.count <= InkSampleRelations.blockSize {
        var left: [SpatialInkSample] = [], right: [SpatialInkSample] = []
        a.forEachSample(in:0..<a.count) { left.append($0) }
        b.forEachSample(in:0..<b.count) { right.append($0) }
        return zip(left,right).prefix(while:InkSampleRelations.sameBits).count
      }
      let middle=a.count/2
      let head=prefix(a.slice(0..<middle),b.slice(0..<middle))
      return head < middle ? head : middle+prefix(a.slice(middle..<a.count),b.slice(middle..<b.count))
    }
    let count=Swift.min(count,other.count)
    return prefix(storage.root.slice(0..<count),other.storage.root.slice(0..<count))
  }
}

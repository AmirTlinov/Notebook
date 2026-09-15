import Foundation
import CoreFoundation
import NotebookCore

/// The measured DOM's compact addresses. Its owning DocumentLayoutRecord keeps
/// the existing layout reservation; neither the view nor a bookmark copies text.
struct DocumentReadingIndex: Equatable, Sendable {
  struct Segment: Equatable, Sendable {
    let blockID: String
    let nodeID: String
    let textOffset: Int
    let start: Int
    let end: Int
    let pageIndex: Int
    let y: Double
  }
  let segments: [Segment]
  private let pages: [Int: [Int]]
  private let blocks: [String: [Int]]

  init(rows: [[Any]], blockIDs: Set<String>, pageCount: Int, scale: Double) throws {
    guard rows.count <= 524_288, scale.isFinite, scale > 0 else { throw DocumentSessionError.invalidLayout }
    var segments: [Segment] = [], pages: [Int: [Int]] = [:], blocks: [String: [Int]] = [:]
    for row in rows {
      guard row.count == 7, let block = row[0] as? String, blockIDs.contains(block),
        let node = row[1] as? String, node.utf8.count == 16,
        node.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
        throw DocumentSessionError.invalidLayout
      }
      func integer(_ index: Int) throws -> Int {
        guard let value = row[index] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
          let number = Int(exactly: value.doubleValue), (0...Int(Int32.max)).contains(number) else {
          throw DocumentSessionError.invalidLayout
        }
        return number
      }
      let offset = try integer(2), start = try integer(3), end = try integer(4), page = try integer(5)
      guard start < end, offset <= Int(Int32.max) - end, page < pageCount,
        let number = row[6] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
        number.doubleValue.isFinite, number.doubleValue >= 0, (number.doubleValue * scale).isFinite else {
        throw DocumentSessionError.invalidLayout
      }
      pages[page, default: []].append(segments.count)
      blocks[block, default: []].append(segments.count)
      segments.append(.init(blockID: block, nodeID: node, textOffset: offset,
        start: start, end: end, pageIndex: page, y: number.doubleValue * scale))
    }
    self.segments = segments; self.pages = pages; self.blocks = blocks
  }

  func matches(_ other: Self, tolerance: Double) -> Bool {
    segments.count == other.segments.count && zip(segments, other.segments).allSatisfy { left, right in
      left.blockID == right.blockID && left.nodeID == right.nodeID && left.textOffset == right.textOffset
        && left.start == right.start && left.end == right.end && left.pageIndex == right.pageIndex
        && abs(left.y - right.y) <= tolerance
    }
  }

  func matchesPrefix(of other: Self, pageCount: Int, tolerance: Double) -> Bool {
    let prefix = other.segments.filter { $0.pageIndex < pageCount }
    return segments.count == prefix.count && zip(segments, prefix).allSatisfy { left, right in
      left.blockID == right.blockID && left.nodeID == right.nodeID && left.textOffset == right.textOffset
        && left.start == right.start && left.end == right.end && left.pageIndex == right.pageIndex
        && abs(left.y - right.y) <= tolerance
    }
  }

  func anchor(page: Int, blockOrder: [String], y: Double = 0) -> DocumentReadingAnchor? {
    guard let indices = pages[page], let index = indices.min(by: {
      let lhs = segments[$0], rhs = segments[$1]
      let left = abs(lhs.y - y), right = abs(rhs.y - y)
      return left == right ? $0 < $1 : left < right
    }) else { return nil }
    let value = segments[index]
    return .init(blockID: value.blockID, nodeID: value.nodeID,
      textOffset: value.textOffset, offset: value.start, blockOrder: blockOrder)
  }

  func page(for anchor: DocumentReadingAnchor, survivingBlockOrder: [String],
    regions: [DocumentBlockRegion]) -> Int? {
    let survivors = Set(survivingBlockOrder)
    let block: String
    if survivors.contains(anchor.blockID) { block = anchor.blockID }
    else if let origin = anchor.blockOrder.firstIndex(of: anchor.blockID),
      let nearest = anchor.blockOrder.enumerated().filter({ survivors.contains($0.element) }).min(by: {
        let left = abs($0.offset - origin), right = abs($1.offset - origin)
        // The following surviving block wins an equal-distance deletion.
        return left == right ? $0.offset > $1.offset : left < right
      }) { block = nearest.element }
    else { guard let first = survivingBlockOrder.first else { return nil }; block = first }
    let candidates = (blocks[block] ?? []).map { segments[$0] }
    guard block == anchor.blockID, !candidates.isEmpty else {
      return regions.first { $0.id == block }?.pageIndex ?? candidates.first?.pageIndex
    }
    let matches = candidates.filter { $0.nodeID == anchor.nodeID }
    let node = matches.min { abs($0.textOffset - anchor.textOffset) < abs($1.textOffset - anchor.textOffset) }
    let offset = (node?.textOffset ?? anchor.textOffset) + anchor.offset
    let choices = node.map { node in matches.filter { $0.textOffset == node.textOffset } } ?? candidates
    func distance(_ value: Segment) -> Int {
      let start = value.textOffset + value.start, end = value.textOffset + value.end
      return offset < start ? start - offset : offset >= end ? offset - end + 1 : 0
    }
    return choices.min {
      let left = distance($0), right = distance($1)
      return left == right ? $0.textOffset + $0.start < $1.textOffset + $1.start : left < right
    }?.pageIndex
  }
}

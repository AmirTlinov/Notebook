import Foundation
import NotebookCore

/// The canonical print's compact source addresses. Its owning DocumentLayoutRecord keeps
/// the existing layout reservation; neither the view nor a bookmark copies text.
struct DocumentReadingIndex: Equatable, Sendable {
  struct Segment: Equatable, Sendable {
    let fileID: String
    let nodeID: String
    let textOffset: Int
    let start: Int
    let end: Int
    let pageIndex: Int
    let y: Double
  }
  let segments: [Segment]
  private let pages: [Int: [Int]]
  private let files: [String: [Int]]

  init(segments: [Segment], fileIDs: Set<String>, pageCount: Int) throws {
    guard segments.count <= 524_288 else { throw DocumentSessionError.invalidLayout }
    var pages: [Int: [Int]] = [:], files: [String: [Int]] = [:]
    for (index, value) in segments.enumerated() {
      guard fileIDs.contains(value.fileID), value.nodeID.utf8.count == 16,
        value.nodeID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
        value.start >= 0, value.start < value.end, value.end <= Int(Int32.max),
        value.textOffset >= 0, value.textOffset <= Int(Int32.max)-value.end,
        (0..<pageCount).contains(value.pageIndex), value.y.isFinite, value.y >= 0
      else { throw DocumentSessionError.invalidLayout }
      pages[value.pageIndex, default: []].append(index)
      files[value.fileID, default: []].append(index)
    }
    self.segments = segments; self.pages = pages; self.files = files
  }

  func matches(_ other: Self, tolerance: Double) -> Bool {
    segments.count == other.segments.count && zip(segments, other.segments).allSatisfy { left, right in
      left.fileID == right.fileID && left.nodeID == right.nodeID && left.textOffset == right.textOffset
        && left.start == right.start && left.end == right.end && left.pageIndex == right.pageIndex
        && abs(left.y - right.y) <= tolerance
    }
  }

  func anchor(page: Int, fileOrder: [String], y: Double = 0) -> DocumentReadingAnchor? {
    guard let indices = pages[page], let index = indices.min(by: {
      let lhs = segments[$0], rhs = segments[$1]
      let left = abs(lhs.y - y), right = abs(rhs.y - y)
      return left == right ? $0 < $1 : left < right
    }) else { return nil }
    let value = segments[index]
    return .init(fileID: value.fileID, nodeID: value.nodeID,
      textOffset: value.textOffset, offset: value.start, fileOrder: fileOrder)
  }

  func page(for anchor: DocumentReadingAnchor, survivingFileOrder: [String],
    regions: [DocumentBlockRegion]) -> Int? {
    let survivors = Set(survivingFileOrder)
    let file: String
    if survivors.contains(anchor.fileID) { file = anchor.fileID }
    else if let origin = anchor.fileOrder.firstIndex(of: anchor.fileID),
      let nearest = anchor.fileOrder.enumerated().filter({ survivors.contains($0.element) }).min(by: {
        let left = abs($0.offset - origin), right = abs($1.offset - origin)
        // The following surviving file wins an equal-distance deletion.
        return left == right ? $0.offset > $1.offset : left < right
      }) { file = nearest.element }
    else { guard let first = survivingFileOrder.first else { return nil }; file = first }
    let candidates = (files[file] ?? []).map { segments[$0] }
    guard file == anchor.fileID, !candidates.isEmpty else {
      return regions.first { $0.kind == .file && $0.id == file }?.pageIndex ?? candidates.first?.pageIndex
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

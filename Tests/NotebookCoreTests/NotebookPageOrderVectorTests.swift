import Foundation
import Testing
@testable import NotebookCore

private final class PageOrderVectorMemory {
  var nodes: [String: NotebookPageOrderNode] = [:]
  var reads: [String] = []
  var writes: [String] = []

  func read(_ hash: String) throws -> NotebookPageOrderNode {
    reads.append(hash)
    guard let node = nodes[hash] else { throw NotebookStorageError.blobMissing(hash) }
    return node
  }

  func write(_ node: NotebookPageOrderNode) throws -> String {
    let hash = try node.hash
    if let previous = nodes[hash], previous != node { throw NotebookStorageError.blobHashMismatch }
    nodes[hash] = node; writes.append(hash)
    return hash
  }
}

@Suite("Page order has one canonical bounded persistent vector", .serialized)
struct NotebookPageOrderVectorTests {
  private func page(_ index: Int) -> UUID {
    let value = UInt64(index)
    return UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 1,
      UInt8(truncatingIfNeeded: value >> 56), UInt8(truncatingIfNeeded: value >> 48),
      UInt8(truncatingIfNeeded: value >> 40), UInt8(truncatingIfNeeded: value >> 32),
      UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
      UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)))
  }

  @Test(arguments: [0, 1, 30, 31, 32, 33, 1_022, 1_023, 1_024, 1_025, 32_767, 32_768, 99_999])
  func oneAppendMatchesCanonicalBuildAtEveryPackingBoundary(count: Int) throws {
    let memory = PageOrderVectorMemory(), rebuilt = PageOrderVectorMemory()
    let pages = (0..<count).map(page), next = page(count)
    let root = try NotebookPageOrderVector.build(pages, write: memory.write)
    let height = try #require(memory.nodes[root]).height
    memory.reads.removeAll(); memory.writes.removeAll()
    let appended = try NotebookPageOrderVector.append(to: root, pageID: next, read: memory.read, write: memory.write)
    #expect(memory.reads.count == height + 1)
    #expect(Set(memory.reads).count == memory.reads.count)
    #expect(memory.writes.count <= height + 2)
    let expected = try NotebookPageOrderVector.build(pages + [next], write: rebuilt.write)
    #expect(appended == expected)
    #expect(try NotebookPageOrderVector.materialize(appended, read: memory.read) == pages + [next])
    #expect(try NotebookPageOrderVector.materialize(root, read: memory.read) == pages)
    if count == 99_999 {
      let spine = try NotebookPageOrderVector.rightSpine(appended, read: memory.read)
      #expect(spine.count == 4)
    }
  }

  @Test func repeatedAppendsKeepOldRootsAndRoundTripThroughTheSameCodec() throws {
    let memory = PageOrderVectorMemory()
    var root = try NotebookPageOrderVector.build([], write: memory.write)
    var retained: [(root: String, count: Int)] = [(root, 0)]
    for index in 0..<1_025 {
      root = try NotebookPageOrderVector.append(to: root, pageID: page(index), read: memory.read, write: memory.write)
      if [1, 31, 32, 33, 1_023, 1_024, 1_025].contains(index + 1) { retained.append((root, index + 1)) }
    }
    for old in retained {
      #expect(try NotebookPageOrderVector.materialize(old.root, read: memory.read) == (0..<old.count).map(page))
    }
    let decoded = try memory.nodes.mapValues { try JSONDecoder().decode(NotebookPageOrderNode.self, from: $0.canonicalData()) }
    #expect(decoded == memory.nodes)
    #expect(try NotebookPageOrderVector.materialize(root) { hash in
      try #require(decoded[hash])
    } == (0..<1_025).map(page))
  }

  @Test func addressedLookupReadsOnePathAmongOneHundredThousandPages() throws {
    let memory = PageOrderVectorMemory(), pages = (0..<100_000).map(page)
    let root = try NotebookPageOrderVector.build(pages, write: memory.write)
    for index in [0, 31, 32, 1_023, 1_024, 32_767, 32_768, 99_999] {
      memory.reads.removeAll()
      #expect(try NotebookPageOrderVector.pageID(at: index, in: root, read: memory.read) == pages[index])
      #expect(memory.reads.count == 4)
      #expect(Set(memory.reads).count == 4)
    }
    for index in [-1, 100_000, Int.max] {
      memory.reads.removeAll()
      #expect(try NotebookPageOrderVector.pageID(at: index, in: root, read: memory.read) == nil)
      #expect(memory.reads.count == (index < 0 ? 0 : 1))
    }
    let empty = try NotebookPageOrderVector.build([], write: memory.write)
    #expect(try NotebookPageOrderVector.pageID(at: 0, in: empty, read: memory.read) == nil)
  }

  @Test func addressedLookupRejectsCorruptionOnItsRequestedPath() throws {
    let memory = PageOrderVectorMemory()
    let left = try memory.write(.init(height: 0, count: 31, pages: (0..<31).map(page)))
    let right = try memory.write(.init(height: 0, count: 1, pages: [page(32)]))
    let wrongCount = try memory.write(.init(height: 1, count: 33, children: [left, right]))
    memory.reads.removeAll()
    #expect(throws: NotebookStorageError.self) {
      try NotebookPageOrderVector.pageID(at: 0, in: wrongCount, read: memory.read)
    }
    #expect(memory.reads == [wrongCount, left])
    let wrongHeight = try memory.write(.init(height: 2, count: 1_025, children: [left, right]))
    #expect(throws: NotebookStorageError.self) {
      try NotebookPageOrderVector.pageID(at: 1_024, in: wrongHeight, read: memory.read)
    }
    let valid = try NotebookPageOrderVector.build((0..<33).map(page), write: memory.write)
    #expect(throws: NotebookStorageError.blobHashMismatch) {
      try NotebookPageOrderVector.pageID(at: 32, in: valid) { hash in
        hash == valid ? try memory.read(hash) : .init(height: 0, count: 1, pages: [page(999)])
      }
    }
  }

  @Test(arguments: [0, 31, 32, 1_023, 1_024, 32_767, 32_768, 99_999])
  func appendDiffVisitsOnlyItsNewSlotAndDoesNotReadAnUnchangedPrefix(count: Int) throws {
    let memory = PageOrderVectorMemory()
    let old = try NotebookPageOrderVector.build((0..<count).map(page), write: memory.write)
    let next = try NotebookPageOrderVector.append(to: old, pageID: page(count), read: memory.read, write: memory.write)
    let oldSpine = try NotebookPageOrderVector.rightSpine(old, read: memory.read)
    let newSpine = try NotebookPageOrderVector.rightSpine(next, read: memory.read)
    memory.reads.removeAll()
    var indices: [Int] = [], pages: [UUID] = []
    try NotebookPageOrderVector.visitChangedPages(from: old, to: next, read: memory.read) { index, page in
      indices.append(index); pages.append(page)
    }
    #expect(indices == [count])
    #expect(pages == [page(count)])
    #expect(memory.reads.count <= oldSpine.count + newSpine.count)
    #expect(Set(memory.reads).isSubset(of: Set(oldSpine.keys).union(newSpine.keys)))
    #expect(Set(memory.reads).count == memory.reads.count)
  }

  @Test func changedIntervalsDoNotConfuseMovedSharedLeavesWithAnUnchangedOrder() throws {
    let memory = PageOrderVectorMemory(), pages = (0..<100).map(page)
    let old = try NotebookPageOrderVector.build(pages, write: memory.write)
    let moved = Array(pages[32..<64]) + Array(pages[0..<32]) + Array(pages[64..<100])
    let next = try NotebookPageOrderVector.build(moved, write: memory.write)
    var values: [Int: UUID] = [:]
    try NotebookPageOrderVector.visitChangedPages(from: old, to: next, read: memory.read) { index, page in
      #expect(values[index] == nil); values[index] = page
    }
    #expect(values.count == 64)
    #expect(values.keys.sorted() == Array(0..<64))
    for (index, page) in values { #expect(page == moved[index]) }
    memory.reads.removeAll(); values.removeAll()
    try NotebookPageOrderVector.visitChangedPages(from: next, to: next, read: memory.read) { values[$0] = $1 }
    #expect(values.isEmpty)
    #expect(memory.reads == [next])
  }

  @Test func shrinkingAndNewMembershipDiffsMatchExactlyTheirChangedVisibleSlots() throws {
    let memory = PageOrderVectorMemory(), original = (0..<1_025).map(page)
    let root = try NotebookPageOrderVector.build(original, write: memory.write)
    let variants = [Array(original.prefix(1_024)), Array(original.prefix(32)), [],
      Array(original.dropFirst()), [page(2_000)] + original, [page(2_001)] + Array(original.dropFirst())]
    for pages in variants {
      let next = try NotebookPageOrderVector.build(pages, write: memory.write)
      var values: [Int: UUID] = [:]
      try NotebookPageOrderVector.visitChangedPages(from: root, to: next, read: memory.read) { index, page in
        #expect(values[index] == nil); values[index] = page
      }
      let expected = Dictionary(uniqueKeysWithValues: pages.enumerated().compactMap { index, page -> (Int, UUID)? in
        original.indices.contains(index) && original[index] == page ? nil : (index, page)
      })
      #expect(values == expected)
    }
    var initial: [UUID] = []
    try NotebookPageOrderVector.visitChangedPages(from: nil, to: root, read: memory.read) { index, page in
      #expect(index == initial.count); initial.append(page)
    }
    #expect(initial == original)
  }

  @Test func changedPathCorruptionAndARejectedVisitAreNotSilentlySkipped() throws {
    let memory = PageOrderVectorMemory()
    let original = (0..<33).map(page), old = try NotebookPageOrderVector.build(original, write: memory.write)
    let left = try memory.write(.init(height: 0, count: 31, pages: (0..<31).map(page)))
    let right = try memory.write(.init(height: 0, count: 1, pages: [page(32)]))
    let corrupt = try memory.write(.init(height: 1, count: 33, children: [left, right]))
    #expect(throws: NotebookStorageError.self) {
      try NotebookPageOrderVector.visitChangedPages(from: old, to: corrupt, read: memory.read) { _, _ in }
    }
    let next = try NotebookPageOrderVector.append(to: old, pageID: page(33), read: memory.read, write: memory.write)
    var visits = 0
    #expect(throws: NotebookStorageError.transactionConflict) {
      try NotebookPageOrderVector.visitChangedPages(from: old, to: next, read: memory.read) { _, _ in
        visits += 1; throw NotebookStorageError.transactionConflict
      }
    }
    #expect(visits == 1)
    #expect(try NotebookPageOrderVector.materialize(old, read: memory.read) == original)
  }

  @Test func duplicateUUIDsAreRejectedByCompleteAdmission() throws {
    let memory = PageOrderVectorMemory()
    #expect(throws: NotebookStorageError.self) {
      try NotebookPageOrderVector.build([page(1), page(1)], write: memory.write)
    }
    #expect(memory.writes.isEmpty)
    let first = try memory.write(.init(height: 0, count: 32, pages: (0..<32).map(page)))
    let last = try memory.write(.init(height: 0, count: 1, pages: [page(0)]))
    let root = try memory.write(.init(height: 1, count: 33, children: [first, last]))
    #expect(throws: NotebookStorageError.self) { try NotebookPageOrderVector.materialize(root, read: memory.read) }
    let small = try NotebookPageOrderVector.build([page(1)], write: memory.write)
    #expect(throws: NotebookStorageError.self) {
      try NotebookPageOrderVector.append(to: small, pageID: page(1), read: memory.read, write: memory.write)
    }
  }

  @Test func nodeMetadataIsRejectedBeforeAnyChildCanBeRead() throws {
    let key = String(repeating: "a", count: 64)
    let invalid: [NotebookPageOrderNode] = [
      .init(format: 2, height: 0, count: 1, pages: [page(1)]),
      .init(height: -1, count: 1, pages: [page(1)]),
      .init(height: Int.max, count: 1, children: [key]),
      .init(height: 0, count: -1),
      .init(height: 3, count: NotebookPageOrderVector.maximumPages + 1, children: [key]),
      .init(height: 0, count: 2, pages: [page(1)]),
      .init(height: 0, count: 1, pages: [page(1)], children: [key]),
      .init(height: 1, count: 33, children: [key]),
      .init(height: 1, count: 33, children: [key, key]),
      .init(height: 1, count: 1, children: [String(repeating: "G", count: 64)]),
      .init(height: 1, count: 0),
    ]
    for node in invalid {
      var reads = 0
      #expect(throws: NotebookStorageError.self) {
        try NotebookPageOrderVector.materialize(key) { _ in reads += 1; return node }
      }
      #expect(reads == 1)
    }
    let encoded = try JSONEncoder().encode(invalid[0])
    let decoded = try JSONDecoder().decode(NotebookPageOrderNode.self, from: encoded)
    #expect(decoded.format == 2)
    #expect(throws: NotebookStorageError.self) { try decoded.validate() }
  }

  @Test func nonMinimalAndUnevenTreesCannotMasqueradeAsTheCanonicalValue() throws {
    let memory = PageOrderVectorMemory()
    let leaf = try memory.write(.init(height: 0, count: 32, pages: (0..<32).map(page)))
    let redundant = try memory.write(.init(height: 1, count: 32, children: [leaf]))
    memory.reads.removeAll()
    #expect(throws: NotebookStorageError.self) { try NotebookPageOrderVector.materialize(redundant, read: memory.read) }
    #expect(memory.reads == [redundant])
    let left = try memory.write(.init(height: 0, count: 31, pages: (0..<31).map(page)))
    let right = try memory.write(.init(height: 0, count: 2, pages: [page(31), page(32)]))
    let uneven = try memory.write(.init(height: 1, count: 33, children: [left, right]))
    #expect(throws: NotebookStorageError.self) { try NotebookPageOrderVector.materialize(uneven, read: memory.read) }
    #expect(throws: NotebookStorageError.self) { try NotebookPageOrderVector.rightSpine(uneven, read: memory.read) }
    #expect(throws: NotebookStorageError.self) {
      try NotebookPageOrderVector.append(to: uneven, pageID: page(33), read: memory.read, write: memory.write)
    }
    // Both hashes are distinct and the parent count looks plausible, but its
    // children have the wrong height. A hash alone is not a shape admission.
    let wrongHeight = try memory.write(.init(height: 2, count: 1_025, children: [leaf, right]))
    #expect(throws: NotebookStorageError.self) { try NotebookPageOrderVector.materialize(wrongHeight, read: memory.read) }
  }

  @Test func canonicalReadAndWriteHashesAreCheckedAndMissingNodesStayErrors() throws {
    let memory = PageOrderVectorMemory()
    let node = NotebookPageOrderNode(height: 0, count: 1, pages: [page(1)])
    let root = try memory.write(node)
    #expect(throws: NotebookStorageError.blobHashMismatch) {
      try NotebookPageOrderVector.materialize(root) { _ in .init(height: 0, count: 1, pages: [page(2)]) }
    }
    #expect(throws: NotebookStorageError.blobHashMismatch) {
      try NotebookPageOrderVector.build([page(1)]) { _ in String(repeating: "0", count: 64) }
    }
    #expect(throws: NotebookStorageError.blobMissing(root)) {
      try NotebookPageOrderVector.materialize(root) { throw NotebookStorageError.blobMissing($0) }
    }
    #expect(throws: NotebookStorageError.blobHashMismatch) {
      try NotebookPageOrderVector.append(to: root, pageID: page(2), read: memory.read) { _ in String(repeating: "0", count: 64) }
    }
    #expect(try NotebookPageOrderVector.materialize(root, read: memory.read) == [page(1)])
  }

  @Test func malformedHashesAndOverlargeValuesDoNotReachStorage() throws {
    for hash in ["", String(repeating: "a", count: 63), String(repeating: "a", count: 65),
      String(repeating: "A", count: 64), "../../not-a-node"] {
      var reads = 0
      #expect(throws: NotebookStorageError.self) {
        try NotebookPageOrderVector.rightSpine(hash) { _ in reads += 1; return .init(height: 0, count: 0) }
      }
      #expect(reads == 0)
    }
    var writes = 0
    #expect(throws: NotebookStorageError.limitExceeded("page_order_pages")) {
      try NotebookPageOrderVector.build(Array(repeating: page(1), count: NotebookPageOrderVector.maximumPages + 1)) { node in
        writes += 1; return try node.hash
      }
    }
    #expect(writes == 0)
  }
}

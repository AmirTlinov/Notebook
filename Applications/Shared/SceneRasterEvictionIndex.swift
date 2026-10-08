import Foundation

/// The pool's unretained entries, ordered by their existing access clock.
/// Each eligible UUID has one heap slot; pixels and layout leases stay in the pool.
struct SceneRasterEvictionIndex {
  private struct Entry {
    let id: UUID
    var access: UInt64
  }
  private var heap: [Entry] = []
  private var positions: [UUID: Int] = [:]

  #if DEBUG
  struct Diagnostics {
    let entryCount: Int
    let positionCount: Int
    let oldestLookups: Int
    let comparisons: Int
  }
  private var oldestLookups = 0
  private var comparisons = 0
  var diagnostics: Diagnostics {
    .init(entryCount: heap.count, positionCount: positions.count,
      oldestLookups: oldestLookups, comparisons: comparisons)
  }
  #endif

  mutating func oldestID() -> UUID? {
    #if DEBUG
    oldestLookups += 1
    #endif
    return heap.first?.id
  }

  mutating func insert(_ id: UUID, access: UInt64) {
    precondition(positions[id] == nil)
    positions[id] = heap.count
    heap.append(.init(id: id, access: access))
    siftUp(from: heap.count - 1)
  }

  mutating func remove(_ id: UUID) {
    guard let position = positions.removeValue(forKey: id) else {
      preconditionFailure("An eligible raster must have exactly one eviction slot")
    }
    let last = heap.removeLast()
    guard position < heap.count else { return }
    heap[position] = last
    positions[last.id] = position
    repair(at: position)
  }

  mutating func updateAccess(_ id: UUID, to access: UInt64) {
    guard let position = positions[id] else {
      preconditionFailure("Only an unretained raster has an eviction slot")
    }
    heap[position].access = access
    repair(at: position)
  }

  private mutating func repair(at position: Int) {
    if position > 0, precedes(position, (position - 1) / 2) { siftUp(from: position) }
    else { siftDown(from: position) }
  }

  private mutating func siftUp(from start: Int) {
    var position = start
    while position > 0 {
      let parent = (position - 1) / 2
      guard precedes(position, parent) else { return }
      swap(position, parent)
      position = parent
    }
  }

  private mutating func siftDown(from start: Int) {
    var position = start
    while position < heap.count / 2 {
      let left = position * 2 + 1, right = left + 1
      let child = right < heap.count && precedes(right, left) ? right : left
      guard precedes(child, position) else { return }
      swap(position, child)
      position = child
    }
  }

  private mutating func precedes(_ left: Int, _ right: Int) -> Bool {
    #if DEBUG
    comparisons += 1
    #endif
    return heap[left].access < heap[right].access
  }

  private mutating func swap(_ first: Int, _ second: Int) {
    heap.swapAt(first, second)
    positions[heap[first].id] = first
    positions[heap[second].id] = second
  }
}

import Testing
@testable import NotebookCore

@Suite("Ink action map")
struct InkActionMapTests {
  @Test("Captured values and active iterators preserve order across successor mutations")
  func capturedValues() {
    let expected = [3, 1, 4, 2]
    var map = InkActionMap<Int, Int>(entries: [(30, 4), (10, 3), (40, 2), (20, 1)])
    let captured = map.values
    var iterator = captured.makeIterator()
    var independent = captured.makeIterator()
    #expect(iterator.next() == 3)

    map[10] = nil
    map[20] = 99
    map[5] = -1
    map[50] = 0

    #expect(captured.count == 4 && captured.underestimatedCount == 4)
    #expect(!captured.isEmpty && captured.first == 3)
    #expect(captured.map { $0 } == expected)
    #expect(Array(captured) == expected)
    #expect(captured.first(where: { $0 < 3 }) == 1)
    #expect(captured.contains(4) && !captured.contains(99))
    var remaining: [Int] = []
    while let value = iterator.next() { remaining.append(value) }
    #expect(remaining == [1, 4, 2])
    #expect(iterator.next() == nil)
    #expect(independent.next() == 3)

    let successor = [-1, 99, 4, 2, 0]
    #expect(Array(map.values) == successor)
    #expect(map.values.count == successor.count && map.values.first == -1)
    #expect(map.values.underestimatedCount == successor.count)

    let empty = InkActionMap<Int, Int>().values
    #expect(empty.isEmpty && empty.count == 0 && empty.underestimatedCount == 0)
    #expect(empty.first == nil && Array(empty).isEmpty)
  }
}

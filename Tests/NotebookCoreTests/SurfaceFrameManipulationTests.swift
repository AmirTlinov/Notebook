import NotebookCore
import Testing

@Suite struct SurfaceFrameManipulationTests {
  @Test func everyHandleKeepsTheOppositeEdgesAtLimits() throws {
    let original = SpatialRect(x: 100, y: 80, width: 200, height: 160)
    let page = SpatialRect(x: 0, y: 0, width: 600, height: 800)
    for handle in NotebookElementResizeHandle.allCases {
      let contact = try #require(SurfaceFrameManipulation(kind: .resize(handle), original: original, bounds: page))
      for delta in [SpatialPoint(x: 30, y: 25), .init(x: -5000, y: -5000), .init(x: 5000, y: 5000)] {
        let result = try #require(contact.frame(at: delta))
        #expect(handle.leading ? result.x + result.width == original.x + original.width : result.x == original.x)
        #expect(handle.top ? result.y + result.height == original.y + original.height : result.y == original.y)
        #expect(result.width >= 1 && result.height >= 1)
        #expect(result.x >= page.x && result.y >= page.y)
        #expect(result.x + result.width <= page.x + page.width && result.y + result.height <= page.y + page.height)
      }
      #expect(contact.frame(at: .zero) == original)
    }
  }

  @Test func clampedMovementReversesFromItsStartingFrame() throws {
    let original = SpatialRect(x: 100, y: 80, width: 200, height: 160)
    let contact = try #require(SurfaceFrameManipulation(kind: .move, original: original,
      bounds: .init(x: 0, y: 0, width: 600, height: 800)))
    #expect(contact.frame(at: .init(x: 5000, y: -5000)) == .init(x: 400, y: 0, width: 200, height: 160))
    #expect(contact.frame(at: .init(x: 20, y: -10)) == .init(x: 120, y: 70, width: 200, height: 160))
    #expect(contact.frame(at: .zero) == original)
    let resize = try #require(SurfaceFrameManipulation(kind: .resize(.topLeading), original: original, bounds: contact.bounds))
    #expect(resize.frame(at: .init(x: 5000, y: 5000)) == .init(x: 299, y: 239, width: 1, height: 1))
    #expect(resize.frame(at: .init(x: 20, y: 10)) == .init(x: 120, y: 90, width: 180, height: 150))
    let outside = SpatialRect(x: -10, y: -15, width: 200, height: 160)
    #expect(try #require(SurfaceFrameManipulation(kind: .move, original: outside, bounds: contact.bounds)).frame(at: .zero) == outside)
  }

  @Test func touchTargetsDoNotLimitAuthoredGeometry() throws {
    let small = try #require(SurfaceFrameManipulation(kind: .resize(.bottomTrailing),
      original: .init(x: 100, y: 100, width: 40, height: 32)))
    #expect(small.frame(at: .init(x: -28, y: -20)) == .init(x: 100, y: 100, width: 12, height: 12))
    let tiny = try #require(SurfaceFrameManipulation(kind: .resize(.bottomTrailing),
      original: .init(x: 0, y: 0, width: 0.4, height: 0.6)))
    #expect(tiny.frame(at: .init(x: -10, y: -10)) == tiny.original)
    let large = try #require(SurfaceFrameManipulation(kind: .resize(.topLeading),
      original: .init(x: 100, y: 100, width: 3000, height: 2200)))
    #expect(large.frame(at: .init(x: -400, y: -500)) == .init(x: -300, y: -400, width: 3400, height: 2700))
    #expect(NotebookElementResizeHandle.visible(in: .init(x: 40, y: 32)).count == 4)
    #expect(NotebookElementResizeHandle.visible(in: .init(x: 160, y: 32)).count == 6)
  }

  @Test func overflowRefusesTheWholePose() throws {
    #expect(SurfaceFrameManipulation(kind: .move,
      original: .init(x: .greatestFiniteMagnitude, y: 0, width: .greatestFiniteMagnitude, height: 1)) == nil)
    let move = try #require(SurfaceFrameManipulation(kind: .move,
      original: .init(x: 1e308, y: 0, width: 1, height: 1)))
    #expect(move.frame(at: .init(x: 1e308, y: 12)) == nil)
    let resize = try #require(SurfaceFrameManipulation(kind: .resize(.bottomTrailing),
      original: .init(x: -1e308, y: 0, width: 1e308, height: 1)))
    #expect(resize.frame(at: .init(x: 1e308, y: 12)) == nil)
    #expect(resize.frame(at: .zero) == resize.original)
  }
}

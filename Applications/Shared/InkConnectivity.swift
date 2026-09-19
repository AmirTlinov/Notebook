import Metal

#if canImport(NotebookCore)
  import NotebookCore
#endif

/// Two immutable templates shared by every measured stroke and LOD. No per-stroke
/// neighbor/index arrays. Caps occupy fixed vertex slots beyond the 257-node strip.
final class InkConnectivity: @unchecked Sendable {
  let pen: any MTLBuffer
  let eraser: any MTLBuffer
  static let capBase = (InkRenderGeometry.maximumSegments + 1) * 2
  init?(device: any MTLDevice) {
    var pen: [UInt16] = []
    var eraser: [UInt16] = []
    func fan(_ base: Int, segments: Int, closed: Bool) -> [UInt16] {
      (0..<segments).flatMap { i in
        [
          UInt16(base), UInt16(base + 1 + i),
          UInt16(base + 1 + (closed ? (i + 1) % segments : i + 1)),
        ]
      }
    }
    pen += fan(Self.capBase, segments: 12, closed: false)
    pen += fan(Self.capBase + 14, segments: 12, closed: false)
    eraser += fan(0, segments: 24, closed: true)
    for segment in 0..<InkRenderGeometry.maximumSegments {
      let a = segment * 2
      pen += [a, a + 1, a + 2, a + 1, a + 3, a + 2].map(UInt16.init)
      let b = 25 + segment * 29
      eraser += [b, b + 1, b + 2, b + 1, b + 3, b + 2].map(UInt16.init)
      eraser += fan(b + 4, segments: 24, closed: true)
    }
    guard
      let p = pen.withUnsafeBytes({
        device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
      }),
      let e = eraser.withUnsafeBytes({
        device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
      })
    else { return nil }
    self.pen = p
    self.eraser = e
    p.label = "Shared ink connectivity"
    e.label = "Shared eraser connectivity"
  }
  func draw(nodes: Int, flags: UInt32, encoder: any MTLRenderCommandEncoder) {
    let count = InkRenderGeometry.vertexCount(nodes: nodes, flags: flags)
    guard count > 0 else { return }
    if flags & 8 != 0 {
      encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: count)
      return
    }
    precondition(nodes <= InkRenderGeometry.maximumSegments + 1)
    let disk = nodes == 1
    let erase = flags & 4 != 0
    let offset: Int
    if disk {
      offset = 0
    } else if erase {
      offset = flags & 1 != 0 ? 0 : 72
    } else {
      offset = flags & 1 != 0 ? 0 : (flags & 2 != 0 ? 36 : 72)
    }
    // A start-only pen skips the absent end cap in a second, tiny range.
    if !disk, !erase, flags & 3 == 1 {
      encoder.drawIndexedPrimitives(
        type: .triangle, indexCount: 36, indexType: .uint16, indexBuffer: pen, indexBufferOffset: 0)
      encoder.drawIndexedPrimitives(
        type: .triangle, indexCount: (nodes - 1) * 6, indexType: .uint16, indexBuffer: pen,
        indexBufferOffset: 144)
    } else {
      encoder.drawIndexedPrimitives(
        type: .triangle, indexCount: count, indexType: .uint16,
        indexBuffer: disk || erase ? eraser : pen, indexBufferOffset: offset * 2)
    }
  }
}

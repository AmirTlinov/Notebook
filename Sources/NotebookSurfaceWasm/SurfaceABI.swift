import NotebookSurface

/// Numeric buffers are owned by the browser adapter. Domain decisions stay in
/// NotebookSurface; this boundary only validates and marshals its values.
@_cdecl("notebook_surface_alloc")
public func surfaceAllocate(_ byteCount: Int32) -> UnsafeMutableRawPointer? {
  guard byteCount > 0, byteCount <= 64 * 1024 * 1024 else { return nil }
  return .allocate(byteCount: Int(byteCount), alignment: 8)
}

@_cdecl("notebook_surface_free")
public func surfaceFree(_ pointer: UnsafeMutableRawPointer?) { pointer?.deallocate() }

private func point(_ values: UnsafePointer<Double>) -> WorldPoint? {
  guard let x = Int64(exactly: values[0]), let y = Int64(exactly: values[1]) else { return nil }
  return WorldPoint(exactTileX: x, tileY: y, localX: values[2], localY: values[3])
}

private func write(_ point: WorldPoint, to output: UnsafeMutablePointer<Double>) {
  output[0] = Double(point.tileX); output[1] = Double(point.tileY)
  output[2] = point.localX; output[3] = point.localY
}

/// Input: center[4], scale, viewport[2], start[2], current[2], magnification.
/// Output: center[4], scale. One transform covers pan, wheel and pinch.
@_cdecl("notebook_surface_camera")
public func surfaceCamera(_ input: UnsafePointer<Double>, _ output: UnsafeMutablePointer<Double>) -> Int32 {
  guard (0..<12).allSatisfy({ input[$0].isFinite }), let center = point(input),
    (SpatialCamera.minimumScale...SpatialCamera.maximumScale).contains(input[4]),
    input[5] > 0, input[6] > 0 else { return 0 }
  let camera = SpatialCamera(center: center, scale: input[4]).pinched(
    by: input[11], from: .init(x: input[7], y: input[8]),
    to: .init(x: input[9], y: input[10]), viewport: .init(x: input[5], y: input[6]))
  write(camera.center, to: output); output[4] = camera.scale
  return 1
}

/// Input: origin[4], displacement[2]. Output: normalized address[4].
@_cdecl("notebook_surface_offset")
public func surfaceOffset(_ input: UnsafePointer<Double>, _ output: UnsafeMutablePointer<Double>) -> Int32 {
  guard let origin = point(input), let next = origin.addressOffset(x: input[4], y: input[5]) else { return 0 }
  write(next, to: output)
  return 1
}

/// Input: origin[4], destination[4]. Output: local displacement[2].
@_cdecl("notebook_surface_delta")
public func surfaceDelta(_ input: UnsafePointer<Double>, _ output: UnsafeMutablePointer<Double>) -> Int32 {
  guard let origin = point(input), let destination = point(input + 4) else { return 0 }
  let delta = origin.delta(to: destination)
  output[0] = delta.x; output[1] = delta.y
  return 1
}

/// Measured display points: x, y, radius and premultiplied RGBA (7 floats).
@_cdecl("notebook_surface_stroke_capacity")
public func surfaceStrokeCapacity(_ count: Int32) -> Int32 {
  guard count > 0, count <= 65_536 else { return 0 }
  return Int32(max(72, (Int(count) - 1) * 6 + 2 * InkStrokeGeometry.roundCapVertexCount))
}

/// Measured display points: x, y, radius and premultiplied RGBA (7 floats).
/// Output triangles: x, y and premultiplied RGBA (6 floats per vertex).
/// A negative result reports insufficient vertex capacity without writing.
@_cdecl("notebook_surface_stroke")
public func surfaceStroke(_ input: UnsafePointer<Float>, _ count: Int32,
  _ output: UnsafeMutablePointer<Float>, _ capacity: Int32) -> Int32 {
  guard count > 0, count <= 65_536, capacity >= 0 else { return 0 }
  var points: [InkStrokeGeometry.RenderPoint] = []
  points.reserveCapacity(Int(count))
  for i in 0..<Int(count) {
    let p = input + i * 7
    guard (0..<7).allSatisfy({ p[$0].isFinite }), p[2] >= 0 else { return 0 }
    let position = SIMD2<Float>(p[0], p[1])
    if let previous = points.last {
      let delta = position - previous.position
      // A squared length overflow otherwise normalizes to zero and silently
      // collapses a finite strip before the final mesh validation can see it.
      guard (delta.x * delta.x + delta.y * delta.y).isFinite else { return 0 }
    }
    points.append(.init(position: position, radius: p[2],
      premultipliedColor: .init(p[3], p[4], p[5], p[6])))
  }
  var vertices: [InkStrokeGeometry.Vertex] = []
  vertices.reserveCapacity(Int(surfaceStrokeCapacity(count)))
  InkStrokeGeometry.appendStrokeVertices(renderPoints: points, to: &vertices)
  guard vertices.count <= capacity else { return -Int32(vertices.count) }
  // Finite samples can still overflow a direction, miter or cap. Refuse the
  // complete mesh before publishing any coordinates to the GPU adapter.
  guard vertices.allSatisfy({ $0.position.x.isFinite && $0.position.y.isFinite }) else { return 0 }
  for (i, vertex) in vertices.enumerated() {
    let p = output + i * 6
    p[0] = vertex.position.x; p[1] = vertex.position.y
    p[2] = vertex.premultipliedColor.x; p[3] = vertex.premultipliedColor.y
    p[4] = vertex.premultipliedColor.z; p[5] = vertex.premultipliedColor.w
  }
  return Int32(vertices.count)
}

@main
enum SurfaceModule { static func main() {} }

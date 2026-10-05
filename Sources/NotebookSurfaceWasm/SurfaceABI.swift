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

@_cdecl("notebook_surface_minimum_scale")
public func surfaceMinimumScale() -> Double { SpatialCamera.minimumScale }

@_cdecl("notebook_surface_maximum_scale")
public func surfaceMaximumScale() -> Double { SpatialCamera.maximumScale }

/// Input: normalized force, previous filtered force (negative for first sample),
/// elapsed seconds. Output: width, opacity, filtered force, RGB. The platform
/// reports measurements; the same native pen style resolves their appearance.
@_cdecl("notebook_surface_pen_sample")
public func surfacePenSample(_ input: UnsafePointer<Double>, _ output: UnsafeMutablePointer<Double>) -> Int32 {
  guard (0..<3).allSatisfy({ input[$0].isFinite }), input[2] >= 0 else { return 0 }
  let force = PencilPressureSmoothing.value(force: input[0], previous: input[1] < 0 ? nil : input[1], elapsed: input[2])
  let style = PenStyle.standard, color = style.color.components
  output[0] = style.width; output[1] = style.opacity(force: force); output[2] = force
  output[3] = color.red; output[4] = color.green; output[5] = color.blue
  return 1
}

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
    let startingCamera = SpatialCamera(admitting: center, scale: input[4]),
    input[5] > 0, input[6] > 0 else { return 0 }
  let camera = CameraGestureTrajectory(startingCamera: startingCamera,
    startingCentroid: .init(x: input[7], y: input[8]), viewport: .init(x: input[5], y: input[6]))
    .camera(at: input[11], centroid: .init(x: input[9], y: input[10]))
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

private let resizeHandles = NotebookElementResizeHandle.allCases

/// Kind: move=0; resize=1...8 in NotebookElementResizeHandle.allCases order.
/// Input: original[x,y,width,height], translation[x,y], hasBounds[0|1],
/// bounds[x,y,width,height]. Output: admitted frame[x,y,width,height].
@_cdecl("notebook_surface_manipulate_frame")
public func surfaceManipulateFrame(_ kind: Int32, _ input: UnsafePointer<Double>,
  _ output: UnsafeMutablePointer<Double>) -> Int32 {
  func rectangle(_ values: UnsafePointer<Double>) -> SpatialRect? {
    guard (0..<4).allSatisfy({ values[$0].isFinite }), values[2] > 0, values[3] > 0 else { return nil }
    return .init(x: values[0], y: values[1], width: values[2], height: values[3])
  }
  let operation: SurfaceFrameManipulation.Kind
  if kind == 0 { operation = .move }
  else {
    guard kind >= 1, kind <= Int32(resizeHandles.count) else { return 0 }
    let index = Int(kind) - 1
    operation = .resize(resizeHandles[index])
  }
  guard let original = rectangle(input), input[4].isFinite, input[5].isFinite else { return 0 }
  let bounds: SpatialRect?
  switch input[6] {
  case 0: bounds = nil
  case 1:
    guard let admitted = rectangle(input + 7) else { return 0 }
    bounds = admitted
  default: return 0
  }
  guard let manipulation = SurfaceFrameManipulation(kind: operation, original: original, bounds: bounds),
    let frame = manipulation.frame(at: .init(x: input[4], y: input[5])) else { return 0 }
  output[0] = frame.x; output[1] = frame.y; output[2] = frame.width; output[3] = frame.height
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

private final class SurfaceInkContact {
  var geometry = IncrementalInkGeometry()
  var count = 0
}

@_cdecl("notebook_surface_ink_create")
public func surfaceInkCreate() -> UnsafeMutableRawPointer {
  Unmanaged.passRetained(SurfaceInkContact()).toOpaque()
}

@_cdecl("notebook_surface_ink_free")
public func surfaceInkFree(_ pointer: UnsafeMutableRawPointer) {
  Unmanaged<SurfaceInkContact>.fromOpaque(pointer).release()
}

/// The caller owns a cumulative measured/predicted input buffer. Updating its
/// tail normalizes only that suffix through the same owner as native ink.
@_cdecl("notebook_surface_ink_update")
public func surfaceInkUpdate(_ pointer: UnsafeMutableRawPointer, _ input: UnsafePointer<Float>,
  _ count: Int32, _ changedFrom: Int32) -> Int32 {
  guard count > 0, count <= 65_536, changedFrom >= 0, changedFrom <= count else { return 0 }
  let contact = Unmanaged<SurfaceInkContact>.fromOpaque(pointer).takeUnretainedValue()
  guard changedFrom <= contact.count else { return 0 }
  let start = max(0, Int(changedFrom) - 1)
  for i in start..<Int(count) {
    let p = input + i * 7
    guard (0..<7).allSatisfy({ p[$0].isFinite }), abs(p[0]) <= 1e9, abs(p[1]) <= 1e9,
      p[2] >= 0, p[2] <= 1e6, (0...1).contains(p[6]) else { return 0 }
  }
  func point(_ i: Int) -> InkStrokeGeometry.RenderPoint {
    let p = input + i * 7
    return .init(position: .init(p[0], p[1]), radius: p[2], premultipliedColor: .init(p[3], p[4], p[5], p[6]))
  }
  contact.geometry.update(count: Int(count), changedFrom: Int(changedFrom), point: point,
    forEach: { range, emit in for i in range { emit(point(i)) } })
  contact.count = Int(count)
  return Int32(contact.geometry.nodes.count)
}

@_cdecl("notebook_surface_ink_dirty_start")
public func surfaceInkDirtyStart(_ pointer: UnsafeMutableRawPointer) -> Int32 {
  Int32(Unmanaged<SurfaceInkContact>.fromOpaque(pointer).takeUnretainedValue().geometry.rebuiltNodeStart)
}

@_cdecl("notebook_surface_ink_vertex_count")
public func surfaceInkVertexCount(_ pointer: UnsafeMutableRawPointer) -> Int32 {
  Int32(InkRenderGeometry.vertexCount(nodes: Unmanaged<SurfaceInkContact>.fromOpaque(pointer)
    .takeUnretainedValue().geometry.nodes.count, flags: 3))
}

/// Dirty nodes are position.xy, edge.xy, radius and alpha. No unchanged prefix
/// crosses WASM or uploads to the GPU during ordinary measured input.
@_cdecl("notebook_surface_ink_nodes")
public func surfaceInkNodes(_ pointer: UnsafeMutableRawPointer, _ output: UnsafeMutablePointer<Float>, _ capacity: Int32) -> Int32 {
  let contact = Unmanaged<SurfaceInkContact>.fromOpaque(pointer).takeUnretainedValue()
  let nodes = contact.geometry.nodes, start = contact.geometry.rebuiltNodeStart
  let count = nodes.count - start
  guard capacity >= count else { return -Int32(count) }
  for i in start..<nodes.count {
    let n = nodes[i], p = output + (i - start) * 6
    p[0] = n.position.x; p[1] = n.position.y; p[2] = n.edge.x; p[3] = n.edge.y
    p[4] = n.radius; p[5] = n.alpha
  }
  return Int32(count)
}

@main
enum SurfaceModule { static func main() {} }

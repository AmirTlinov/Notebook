import MetalKit
import PencilKit
import UIKit

enum SpatialInkRenderLayer {
  case ink(PKDrawing)
  case eraseRect(CGRect)
}

struct VisibleInkStrokeRun {
  let points: [PKStrokePoint]
  let roundsStart: Bool
  let roundsEnd: Bool
}

enum InkStrokeGeometry {
  private static let endpointTolerance: CGFloat = 0.001

  /// PencilKit keeps the original path after a bitmap erase and clips it with
  /// a mask. Rendering the raw path would therefore paint erased ink again.
  static func visibleRuns(for stroke: PKStroke) -> [VisibleInkStrokeRun] {
    guard !stroke.path.isEmpty else { return [] }
    guard stroke.mask != nil else {
      return [
        VisibleInkStrokeRun(
          points: Array(stroke.path),
          roundsStart: true,
          roundsEnd: true
        )
      ]
    }

    let pathStart: CGFloat = 0
    let pathEnd = CGFloat(stroke.path.count - 1)
    return stroke.maskedPathRanges.compactMap { range in
      let lower = max(pathStart, range.lowerBound)
      let upper = min(pathEnd, range.upperBound)
      guard lower <= upper else { return nil }

      let visibleStroke = stroke.substroke(range: lower...upper)
      let points = Array(visibleStroke.path)
      guard !points.isEmpty else { return nil }
      return VisibleInkStrokeRun(
        points: points,
        roundsStart: lower <= pathStart + endpointTolerance,
        roundsEnd: upper >= pathEnd - endpointTolerance
      )
    }
  }
}

/// One mutable geometry record follows a pen stroke from Pencil-down to disk.
@MainActor
final class ActiveInkStroke {
  let style: PenStyle
  private(set) var measuredPoints: [PKStrokePoint] = []
  private(set) var predictedPoints: [PKStrokePoint] = []
  private(set) var revision: UInt64 = 0

  init(style: PenStyle) {
    self.style = style
  }

  func replaceMeasuredTail(
    from startIndex: Int,
    with points: [PKStrokePoint]
  ) {
    let start = min(max(startIndex, 0), measuredPoints.count)
    measuredPoints.replaceSubrange(start..., with: points)
    revision &+= 1
  }

  func replacePredictions(with points: [PKStrokePoint]) {
    predictedPoints = points
    revision &+= 1
  }
}

/// One mutable eraser path is composited by Metal while Pencil is moving.
@MainActor
final class ActiveEraserStroke {
  private(set) var measuredPoints: [PKStrokePoint] = []
  private(set) var revision: UInt64 = 0

  func replaceMeasuredTail(
    from startIndex: Int,
    with points: [PKStrokePoint]
  ) {
    let start = min(max(startIndex, 0), measuredPoints.count)
    measuredPoints.replaceSubrange(start..., with: points)
    revision &+= 1
  }
}

/// The only view that turns notebook ink into pixels on iPad.
///
/// PencilKit remains the file format. Metal owns every live pixel: it draws
/// ink and subtracts the active eraser before PencilKit computes persistence.
@MainActor
final class InkCanvasView: MTKView, MTKViewDelegate {
  private enum RenderOperation: Equatable {
    case ink
    case erase
  }

  private struct Vertex {
    var position: SIMD2<Float>
    var premultipliedColor: SIMD4<Float>
  }

  private struct CommittedBatch {
    let operation: RenderOperation
    var vertices: [Vertex]
    var buffer: (any MTLBuffer)?
  }

  private struct RenderPoint {
    var position: SIMD2<Float>
    var radius: Float
    var premultipliedColor: SIMD4<Float>
  }

  private static let capSegments = 12
  private static let framesInFlight = 3
  private static let minimumDistanceSquared: Float = 0.0001

  private let commandQueue: (any MTLCommandQueue)?
  private let inkPipelineState: (any MTLRenderPipelineState)?
  private let eraserPipelineState: (any MTLRenderPipelineState)?
  private let inFlightSemaphore = DispatchSemaphore(
    value: InkCanvasView.framesInFlight
  )

  private var committedVertices: [Vertex] = []
  private var committedBuffer: (any MTLBuffer)?
  private var committedBatches: [CommittedBatch] = []
  private var committedStrokeCount = 0

  private var activeInkStroke: ActiveInkStroke?
  private var activeEraserStroke: ActiveEraserStroke?
  private var builtActiveIdentity: ObjectIdentifier?
  private var builtActiveRevision: UInt64?
  private var activeVertices: [Vertex] = []
  private var activeBuffers = Array<(any MTLBuffer)?>(
    repeating: nil,
    count: InkCanvasView.framesInFlight
  )
  private var activeBufferCapacities = Array(
    repeating: 0,
    count: InkCanvasView.framesInFlight
  )
  private var frameSlot = 0
  private var hasPresentedFrame = false

  init(frame: CGRect) {
    let device = MTLCreateSystemDefaultDevice()
    commandQueue = device?.makeCommandQueue()

    if let device,
      let library = try? device.makeDefaultLibrary(bundle: .main),
      let vertexFunction = library.makeFunction(name: "paperInkVertex"),
      let fragmentFunction = library.makeFunction(name: "paperInkFragment")
    {
      let sampleCount = device.supportsTextureSampleCount(4) ? 4 : 1
      let inkDescriptor = MTLRenderPipelineDescriptor()
      inkDescriptor.label = "Notebook Ink"
      inkDescriptor.vertexFunction = vertexFunction
      inkDescriptor.fragmentFunction = fragmentFunction
      inkDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
      inkDescriptor.rasterSampleCount = sampleCount

      let inkAttachment = inkDescriptor.colorAttachments[0]!
      inkAttachment.isBlendingEnabled = true
      inkAttachment.rgbBlendOperation = .add
      inkAttachment.alphaBlendOperation = .add
      inkAttachment.sourceRGBBlendFactor = .one
      inkAttachment.sourceAlphaBlendFactor = .one
      inkAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
      inkAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
      inkPipelineState = try? device.makeRenderPipelineState(
        descriptor: inkDescriptor
      )

      let eraserDescriptor = MTLRenderPipelineDescriptor()
      eraserDescriptor.label = "Notebook Eraser"
      eraserDescriptor.vertexFunction = vertexFunction
      eraserDescriptor.fragmentFunction = fragmentFunction
      eraserDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
      eraserDescriptor.rasterSampleCount = sampleCount

      let eraserAttachment = eraserDescriptor.colorAttachments[0]!
      eraserAttachment.isBlendingEnabled = true
      eraserAttachment.rgbBlendOperation = .add
      eraserAttachment.alphaBlendOperation = .add
      eraserAttachment.sourceRGBBlendFactor = .zero
      eraserAttachment.sourceAlphaBlendFactor = .zero
      eraserAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
      eraserAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
      eraserPipelineState = try? device.makeRenderPipelineState(
        descriptor: eraserDescriptor
      )
    } else {
      inkPipelineState = nil
      eraserPipelineState = nil
    }

    super.init(frame: frame, device: device)

    colorPixelFormat = .bgra8Unorm
    sampleCount = device?.supportsTextureSampleCount(4) == true ? 4 : 1
    clearColor = MTLClearColorMake(0, 0, 0, 0)
    framebufferOnly = true
    enableSetNeedsDisplay = false
    isPaused = false
    preferredFramesPerSecond = 120
    autoResizeDrawable = true
    backgroundColor = .clear
    isOpaque = false
    isUserInteractionEnabled = false
    layer.isOpaque = false
    layer.opacity = 0
    if let metalLayer = layer as? CAMetalLayer {
      metalLayer.presentsWithTransaction = false
      metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
      metalLayer.maximumDrawableCount = Self.framesInFlight
    }
    delegate = self
  }

  @available(*, unavailable)
  required init(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if let screen = window?.windowScene?.screen {
      preferredFramesPerSecond = screen.maximumFramesPerSecond
    }
    if window != nil {
      isPaused = false
    }
  }

  /// Replaces the page atomically. This is used for load, undo, and sync.
  func apply(_ drawing: PKDrawing) {
    committedVertices = makeVertices(for: drawing)
    committedBuffer = nil
    committedBatches.removeAll(keepingCapacity: true)
    committedStrokeCount = drawing.strokes.count
    discardActiveAction()
    requestFrame()
  }

  /// Rebuilds the ordered board/cover composite in this same Metal owner.
  /// Erase rectangles hide ink belonging to surfaces behind an opaque cover.
  func applySpatial(_ layers: [SpatialInkRenderLayer]) {
    committedVertices.removeAll(keepingCapacity: true)
    committedBuffer = nil
    committedBatches.removeAll(keepingCapacity: true)
    committedStrokeCount = 0

    for layer in layers {
      switch layer {
      case .ink(let drawing):
        appendCommitted(makeVertices(for: drawing), operation: .ink)
      case .eraseRect(let rect):
        appendCommitted(rectangleVertices(rect), operation: .erase)
      }
    }
    discardActiveAction()
    requestFrame()
  }

  /// Publishes the newest Pencil samples. Rendering happens on the display
  /// clock, never inside the touch callback.
  func displayActiveStroke(_ stroke: ActiveInkStroke) {
    if activeInkStroke !== stroke {
      activeInkStroke = stroke
      activeEraserStroke = nil
      builtActiveIdentity = nil
      builtActiveRevision = nil
    }
    requestFrame()
  }

  /// Shows a destination-out brush over the stable page. PencilKit does not
  /// produce any visible intermediate drawings while the gesture is active.
  func displayActiveEraser(_ stroke: ActiveEraserStroke) {
    if activeEraserStroke !== stroke {
      activeEraserStroke = stroke
      activeInkStroke = nil
      builtActiveIdentity = nil
      builtActiveRevision = nil
    }
    requestFrame()
  }

  /// Moves the exact active mesh into the page. No second renderer and no
  /// visual replacement are involved.
  func commitActiveStroke(in drawing: PKDrawing) {
    if let activeInkStroke,
      !activeInkStroke.measuredPoints.isEmpty,
      drawing.strokes.count == committedStrokeCount + 1
    {
      let components = activeInkStroke.style.color.components
      var vertices: [Vertex] = []
      appendStrokeVertices(
        points: activeInkStroke.measuredPoints,
        color: SIMD4(
          Float(components.red),
          Float(components.green),
          Float(components.blue),
          1
        ),
        to: &vertices
      )
      appendCommitted(vertices, operation: .ink)
      committedStrokeCount = drawing.strokes.count
    } else {
      committedVertices = makeVertices(for: drawing)
      committedBuffer = nil
      committedBatches.removeAll(keepingCapacity: true)
      committedStrokeCount = drawing.strokes.count
    }
    discardActiveAction()
    requestFrame()
  }

  /// Keeps the exact Metal eraser gesture in the action order. The PencilKit
  /// result is persistence for Mac and reload, not a second live renderer.
  func commitActiveEraser(in drawing: PKDrawing) {
    if let activeEraserStroke,
      !activeEraserStroke.measuredPoints.isEmpty
    {
      var vertices: [Vertex] = []
      appendStrokeVertices(
        points: activeEraserStroke.measuredPoints,
        color: SIMD4(1, 1, 1, 1),
        to: &vertices
      )
      appendCommitted(vertices, operation: .erase)
      committedStrokeCount = drawing.strokes.count
    }
    discardActiveAction()
    requestFrame()
  }

  func clearActiveAction() {
    guard activeInkStroke != nil || activeEraserStroke != nil else { return }
    discardActiveAction()
    requestFrame()
  }

  func mtkView(
    _ view: MTKView,
    drawableSizeWillChange size: CGSize
  ) {
    requestFrame()
  }

  func draw(in view: MTKView) {
    guard inFlightSemaphore.wait(timeout: .now()) == .success else { return }
    var mustSignal = true
    defer {
      if mustSignal {
        inFlightSemaphore.signal()
      }
    }

    guard let commandQueue,
      let commandBuffer = commandQueue.makeCommandBuffer(),
      let descriptor = currentRenderPassDescriptor,
      let drawable = currentDrawable
    else { return }

    descriptor.colorAttachments[0].loadAction = .clear
    descriptor.colorAttachments[0].clearColor = clearColor
    guard let encoder = commandBuffer.makeRenderCommandEncoder(
      descriptor: descriptor
    ) else { return }

    if committedBuffer == nil, !committedVertices.isEmpty {
      committedBuffer = makeBuffer(for: committedVertices)
    }
    for index in committedBatches.indices
      where committedBatches[index].buffer == nil
    {
      committedBatches[index].buffer = makeBuffer(
        for: committedBatches[index].vertices
      )
    }
    let active = prepareActiveBuffer(in: frameSlot)

    if inkPipelineState != nil, eraserPipelineState != nil {
      encoder.label = "Notebook Ink"
      var viewportSize = SIMD2<Float>(
        Float(max(bounds.width, 1)),
        Float(max(bounds.height, 1))
      )
      encoder.setVertexBytes(
        &viewportSize,
        length: MemoryLayout<SIMD2<Float>>.stride,
        index: 1
      )
      draw(
        buffer: committedBuffer,
        vertexCount: committedVertices.count,
        operation: .ink,
        with: encoder
      )
      for batch in committedBatches {
        draw(
          buffer: batch.buffer,
          vertexCount: batch.vertices.count,
          operation: batch.operation,
          with: encoder
        )
      }
      if let active {
        draw(
          buffer: active.buffer,
          vertexCount: activeVertices.count,
          operation: active.operation,
          with: encoder
        )
      }
    }
    encoder.endEncoding()

    commandBuffer.present(drawable)
    commandBuffer.addCompletedHandler { [inFlightSemaphore] _ in
      inFlightSemaphore.signal()
    }
    commandBuffer.commit()
    mustSignal = false
    frameSlot = (frameSlot + 1) % Self.framesInFlight

    if !hasPresentedFrame {
      // The first drawable may contain Metal's diagnostic magenta. Reveal the
      // layer only after its transparent clear has reached the GPU once.
      commandBuffer.waitUntilCompleted()
      hasPresentedFrame = true
      layer.opacity = 1
    }

    if activeInkStroke == nil, activeEraserStroke == nil {
      isPaused = true
    }
  }

  private func requestFrame() {
    isPaused = false
  }

  private func discardActiveAction() {
    activeInkStroke = nil
    activeEraserStroke = nil
    builtActiveIdentity = nil
    builtActiveRevision = nil
    activeVertices.removeAll(keepingCapacity: true)
  }

  private func prepareActiveBuffer(
    in slot: Int
  ) -> (buffer: any MTLBuffer, operation: RenderOperation)? {
    let identity: ObjectIdentifier
    let revision: UInt64
    let measured: [PKStrokePoint]
    let predicted: [PKStrokePoint]
    let color: SIMD4<Float>
    let operation: RenderOperation

    if let activeInkStroke {
      identity = ObjectIdentifier(activeInkStroke)
      revision = activeInkStroke.revision
      measured = activeInkStroke.measuredPoints
      predicted = activeInkStroke.predictedPoints
      let components = activeInkStroke.style.color.components
      color = SIMD4(
        Float(components.red),
        Float(components.green),
        Float(components.blue),
        1
      )
      operation = .ink
    } else if let activeEraserStroke {
      identity = ObjectIdentifier(activeEraserStroke)
      revision = activeEraserStroke.revision
      measured = activeEraserStroke.measuredPoints
      predicted = []
      color = SIMD4(1, 1, 1, 1)
      operation = .erase
    } else {
      activeVertices.removeAll(keepingCapacity: true)
      builtActiveIdentity = nil
      builtActiveRevision = nil
      return nil
    }

    if builtActiveIdentity != identity || builtActiveRevision != revision {
      activeVertices = makeVertices(
        measured: measured,
        predicted: predicted,
        color: color
      )
      builtActiveIdentity = identity
      builtActiveRevision = revision
    }
    guard !activeVertices.isEmpty else { return nil }

    let requiredLength = activeVertices.count * MemoryLayout<Vertex>.stride
    if requiredLength > activeBufferCapacities[slot] {
      activeBufferCapacities[slot] = max(
        4096,
        nextPowerOfTwo(requiredLength)
      )
      activeBuffers[slot] = device?.makeBuffer(
        length: activeBufferCapacities[slot],
        options: .storageModeShared
      )
      activeBuffers[slot]?.label = "Active Pencil Stroke \(slot)"
    }
    guard let buffer = activeBuffers[slot] else {
      return nil
    }
    // Every in-flight frame owns its slot. The CPU never overwrites vertices
    // that a preceding GPU command buffer may still be reading.
    copy(activeVertices, to: buffer)
    return (buffer, operation)
  }

  private func appendCommitted(
    _ vertices: [Vertex],
    operation: RenderOperation
  ) {
    guard !vertices.isEmpty else { return }
    if committedBatches.last?.operation == operation {
      committedBatches[committedBatches.count - 1].vertices.append(
        contentsOf: vertices
      )
      committedBatches[committedBatches.count - 1].buffer = nil
    } else {
      committedBatches.append(
        CommittedBatch(
          operation: operation,
          vertices: vertices,
          buffer: nil
        )
      )
    }
  }

  private func rectangleVertices(_ rect: CGRect) -> [Vertex] {
    guard !rect.isNull, !rect.isEmpty else { return [] }
    let color = SIMD4<Float>(1, 1, 1, 1)
    let topLeft = vertex(
      at: SIMD2(Float(rect.minX), Float(rect.minY)),
      color: color
    )
    let topRight = vertex(
      at: SIMD2(Float(rect.maxX), Float(rect.minY)),
      color: color
    )
    let bottomLeft = vertex(
      at: SIMD2(Float(rect.minX), Float(rect.maxY)),
      color: color
    )
    let bottomRight = vertex(
      at: SIMD2(Float(rect.maxX), Float(rect.maxY)),
      color: color
    )
    return [
      topLeft, bottomLeft, topRight,
      topRight, bottomLeft, bottomRight,
    ]
  }

  private func makeBuffer(for vertices: [Vertex]) -> (any MTLBuffer)? {
    guard let device, !vertices.isEmpty else { return nil }
    return vertices.withUnsafeBytes { bytes in
      guard let baseAddress = bytes.baseAddress else { return nil }
      let buffer = device.makeBuffer(
        bytes: baseAddress,
        length: bytes.count,
        options: .storageModeShared
      )
      buffer?.label = "Committed Notebook Ink"
      return buffer
    }
  }

  private func copy(_ vertices: [Vertex], to buffer: any MTLBuffer) {
    vertices.withUnsafeBytes { source in
      guard let baseAddress = source.baseAddress else { return }
      buffer.contents().copyMemory(
        from: baseAddress,
        byteCount: source.count
      )
    }
  }

  private func draw(
    buffer: (any MTLBuffer)?,
    vertexCount: Int,
    operation: RenderOperation,
    with encoder: any MTLRenderCommandEncoder
  ) {
    guard let buffer, vertexCount > 0 else { return }
    let pipeline = operation == .ink
      ? inkPipelineState
      : eraserPipelineState
    guard let pipeline else { return }
    encoder.setRenderPipelineState(pipeline)
    encoder.setVertexBuffer(buffer, offset: 0, index: 0)
    encoder.drawPrimitives(
      type: .triangle,
      vertexStart: 0,
      vertexCount: vertexCount
    )
  }

  private func makeVertices(for drawing: PKDrawing) -> [Vertex] {
    var vertices: [Vertex] = []
    let pointCount = drawing.strokes.reduce(0) { $0 + $1.path.count }
    vertices.reserveCapacity(pointCount * 6)
    for stroke in drawing.strokes {
      for run in InkStrokeGeometry.visibleRuns(for: stroke) {
        appendStrokeVertices(
          points: run.points,
          color: rgba(for: stroke.ink.color),
          roundsStart: run.roundsStart,
          roundsEnd: run.roundsEnd,
          to: &vertices
        )
      }
    }
    return vertices
  }

  private func makeVertices(
    measured: [PKStrokePoint],
    predicted: [PKStrokePoint],
    color: SIMD4<Float>
  ) -> [Vertex] {
    var points = measured
    points.reserveCapacity(measured.count + predicted.count)
    points.append(contentsOf: predicted)
    var vertices: [Vertex] = []
    vertices.reserveCapacity(points.count * 6)
    appendStrokeVertices(points: points, color: color, to: &vertices)
    return vertices
  }

  private func appendStrokeVertices(
    points: [PKStrokePoint],
    color: SIMD4<Float>,
    roundsStart: Bool = true,
    roundsEnd: Bool = true,
    to vertices: inout [Vertex]
  ) {
    let renderPoints = renderPoints(from: points, color: color)
    guard let first = renderPoints.first else { return }

    guard renderPoints.count > 1 else {
      appendDisk(at: first, to: &vertices)
      return
    }

    let offsets = crossSectionOffsets(for: renderPoints)
    for index in 0..<(renderPoints.count - 1) {
      let start = renderPoints[index]
      let end = renderPoints[index + 1]
      let startOffset = offsets[index]
      let endOffset = offsets[index + 1]

      let startLeft = vertex(
        at: start.position + startOffset,
        color: start.premultipliedColor
      )
      let startRight = vertex(
        at: start.position - startOffset,
        color: start.premultipliedColor
      )
      let endLeft = vertex(
        at: end.position + endOffset,
        color: end.premultipliedColor
      )
      let endRight = vertex(
        at: end.position - endOffset,
        color: end.premultipliedColor
      )

      vertices.append(contentsOf: [
        startLeft, startRight, endLeft,
        startRight, endRight, endLeft,
      ])
    }

    if roundsStart {
      let firstDirection = unitDirection(
        from: renderPoints[0].position,
        to: renderPoints[1].position
      )
      appendRoundCap(
        at: first,
        outward: -firstDirection,
        to: &vertices
      )
    }
    if roundsEnd, let last = renderPoints.last {
      let lastDirection = unitDirection(
        from: renderPoints[renderPoints.count - 2].position,
        to: last.position
      )
      appendRoundCap(at: last, outward: lastDirection, to: &vertices)
    }
  }

  private func renderPoints(
    from points: [PKStrokePoint],
    color: SIMD4<Float>
  ) -> [RenderPoint] {
    var result: [RenderPoint] = []
    result.reserveCapacity(points.count)

    for point in points {
      let position = SIMD2<Float>(
        Float(point.location.x),
        Float(point.location.y)
      )
      let alpha = min(max(Float(point.opacity) * color.w, 0), 1)
      let renderPoint = RenderPoint(
        position: position,
        radius: max(Float(point.size.width / 2), 0.25),
        premultipliedColor: SIMD4(
          color.x * alpha,
          color.y * alpha,
          color.z * alpha,
          alpha
        )
      )

      if let last = result.last,
        distanceSquared(last.position, position) < Self.minimumDistanceSquared
      {
        result[result.count - 1] = renderPoint
      } else {
        result.append(renderPoint)
      }
    }
    return result
  }

  private func crossSectionOffsets(
    for points: [RenderPoint]
  ) -> [SIMD2<Float>] {
    var offsets: [SIMD2<Float>] = []
    offsets.reserveCapacity(points.count)

    for index in points.indices {
      let incoming: SIMD2<Float>
      let outgoing: SIMD2<Float>
      if index == points.startIndex {
        outgoing = unitDirection(
          from: points[index].position,
          to: points[index + 1].position
        )
        incoming = outgoing
      } else if index == points.index(before: points.endIndex) {
        incoming = unitDirection(
          from: points[index - 1].position,
          to: points[index].position
        )
        outgoing = incoming
      } else {
        incoming = unitDirection(
          from: points[index - 1].position,
          to: points[index].position
        )
        outgoing = unitDirection(
          from: points[index].position,
          to: points[index + 1].position
        )
      }

      let incomingNormal = SIMD2<Float>(-incoming.y, incoming.x)
      let outgoingNormal = SIMD2<Float>(-outgoing.y, outgoing.x)
      let normalSum = incomingNormal + outgoingNormal
      let normal = lengthSquared(normalSum) > 0.0001
        ? normalize(normalSum)
        : outgoingNormal
      let denominator = max(abs(dot(normal, outgoingNormal)), 0.55)
      let miterLength = min(
        points[index].radius / denominator,
        points[index].radius * 1.8
      )
      offsets.append(normal * miterLength)
    }
    return offsets
  }

  private func appendDisk(
    at point: RenderPoint,
    to vertices: inout [Vertex]
  ) {
    appendArc(
      at: point,
      startAngle: 0,
      sweep: 2 * .pi,
      segments: Self.capSegments * 2,
      to: &vertices
    )
  }

  private func appendRoundCap(
    at point: RenderPoint,
    outward: SIMD2<Float>,
    to vertices: inout [Vertex]
  ) {
    let middleAngle = atan2(outward.y, outward.x)
    appendArc(
      at: point,
      startAngle: middleAngle - (.pi / 2),
      sweep: .pi,
      segments: Self.capSegments,
      to: &vertices
    )
  }

  private func appendArc(
    at point: RenderPoint,
    startAngle: Float,
    sweep: Float,
    segments: Int,
    to vertices: inout [Vertex]
  ) {
    let center = vertex(
      at: point.position,
      color: point.premultipliedColor
    )
    for segment in 0..<segments {
      let firstAngle = startAngle
        + (Float(segment) / Float(segments)) * sweep
      let secondAngle = startAngle
        + (Float(segment + 1) / Float(segments)) * sweep
      let first = point.position + SIMD2(
        cos(firstAngle) * point.radius,
        sin(firstAngle) * point.radius
      )
      let second = point.position + SIMD2(
        cos(secondAngle) * point.radius,
        sin(secondAngle) * point.radius
      )
      vertices.append(center)
      vertices.append(vertex(at: first, color: point.premultipliedColor))
      vertices.append(vertex(at: second, color: point.premultipliedColor))
    }
  }

  private func rgba(for color: UIColor) -> SIMD4<Float> {
    let resolved = color.resolvedColor(with: traitCollection)
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 1
    if resolved.getRed(
      &red,
      green: &green,
      blue: &blue,
      alpha: &alpha
    ) {
      return SIMD4(Float(red), Float(green), Float(blue), Float(alpha))
    }
    var white: CGFloat = 0
    resolved.getWhite(&white, alpha: &alpha)
    return SIMD4(Float(white), Float(white), Float(white), Float(alpha))
  }

  private func vertex(
    at position: SIMD2<Float>,
    color: SIMD4<Float>
  ) -> Vertex {
    Vertex(position: position, premultipliedColor: color)
  }

  private func unitDirection(
    from start: SIMD2<Float>,
    to end: SIMD2<Float>
  ) -> SIMD2<Float> {
    let delta = end - start
    guard lengthSquared(delta) > Self.minimumDistanceSquared else {
      return SIMD2(1, 0)
    }
    return normalize(delta)
  }

  private func distanceSquared(
    _ first: SIMD2<Float>,
    _ second: SIMD2<Float>
  ) -> Float {
    lengthSquared(first - second)
  }

  private func lengthSquared(_ value: SIMD2<Float>) -> Float {
    dot(value, value)
  }

  private func nextPowerOfTwo(_ value: Int) -> Int {
    guard value > 1 else { return 1 }
    return 1 << (Int.bitWidth - (value - 1).leadingZeroBitCount)
  }
}

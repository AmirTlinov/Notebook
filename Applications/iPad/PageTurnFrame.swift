import CoreImage
import Metal
import UIKit

/// Immutable physical page pixels. The material owners supply their accepted
/// images and GPU ink; a curl borrows this cut until its last GPU command ends.
@MainActor
final class PageTurnFrame {
  struct CompositionTiming: Sendable {
    let workerBegan, encodingBegan, encodingEnded, submitted: TimeInterval
    let gpuBegan, gpuEnded, completionReceived: TimeInterval
  }
  struct ImageLayer {
    let image: CGImage
    let frame: CGRect
    init(image: CGImage, frame: CGRect) { self.image = image; self.frame = frame }
  }
  enum Layer: Sendable {
    case image(CGImage, CGRect)
    case frame(PageTurnFrame, CGRect)
  }
  let id = UUID()
  let texture: any MTLTexture
  let logicalSize: CGSize
  let allocationPriority: SceneAllocationPriority
  private let reservation: RasterReservation
  var byteCount: Int { reservation.byteCount }
  @MainActor private final class MaterialBorrow {
    let values: [AnyObject]
    init(_ values: [AnyObject]) { self.values = values }
  }
  private var onRelease: (@MainActor () -> Void)?

  private init(texture: any MTLTexture, size: CGSize, reservation: RasterReservation,
    priority: SceneAllocationPriority, onRelease: (@MainActor () -> Void)?) {
    self.texture = texture; logicalSize = size; self.reservation = reservation
    allocationPriority = priority
    self.onRelease = onRelease
  }

  static func compose(size: CGSize, scale: Double, images: [ImageLayer],
    resources: SceneRenderResources = .shared,
    priority: SceneAllocationPriority = .passive,
    ink: InkCanvasView.AcceptedFrameLease? = nil, retaining: [AnyObject] = [],
    onRelease: (@MainActor () -> Void)? = nil) async throws -> PageTurnFrame {
    try await compose(size: size, scale: scale, layers: images.map { .image($0.image, $0.frame) },
      resources: resources, priority: priority, ink: ink, retaining: retaining, onRelease: onRelease)
  }

  static func compose(size: CGSize, scale: Double, layers: [Layer],
    resources: SceneRenderResources = .shared,
    priority: SceneAllocationPriority = .passive,
    inputFallback: Bool = false,
    ink: InkCanvasView.AcceptedFrameLease? = nil, retaining: [AnyObject] = [],
    onRelease: (@MainActor () -> Void)? = nil,
    onCompositionMeasured: (@MainActor (CompositionTiming, TimeInterval) -> Void)? = nil) async throws -> PageTurnFrame {
    try Task.checkCancellation()
    let gpu = SheetCurlGPU.shared
    guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0, scale.isFinite, scale > 0,
      size.width * scale <= 8192, size.height * scale <= 8192,
      let device = gpu.device, let context = gpu.imageContext,
      let command = gpu.commandQueue?.makeCommandBuffer() else { throw SceneRenderError.snapshotPending("page_compositor") }
    let width = Int(ceil(size.width * scale)), height = Int(ceil(size.height * scale))
    guard width <= 8192, height <= 8192 else { throw SceneRenderError.resourceLimit }
    // A reusable static cut first asks for passive storage. An accepted turn
    // can still take an ephemeral cut when that cache budget is occupied.
    let preferred = resources.reserveRaster(pixelWidth: width, pixelHeight: height, backingCount: 1, priority: priority)
    let fallback = preferred == nil && inputFallback && priority == .passive
      ? resources.reserveRaster(pixelWidth: width, pixelHeight: height, backingCount: 1, priority: .input) : nil
    guard let reservation = preferred ?? fallback else { throw SceneRenderError.resourceLimit }
    let admittedPriority: SceneAllocationPriority = preferred == nil ? .input : priority
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
      width: width, height: height, mipmapped: false)
    descriptor.storageMode = .private; descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
    guard let texture = device.makeTexture(descriptor: descriptor) else { reservation.release(); throw SceneRenderError.resourceLimit }
    // Extract immutable material on its owner actor. The worker neither reads
    // page state nor releases the reservations backing these textures/images.
    var inputs: [PageTurnComposition.Layer] = layers.map { layer in
      switch layer {
      case .image(let image, let frame):
        return .image(image, frame)
      case .frame(let frame, let destination):
        return .texture(frame.texture, destination)
      }
    }
    if let ink { inputs.append(.texture(ink.texture, ink.logicalBounds)) }
    let composition = PageTurnComposition(layers: inputs, size: size, scale: scale,
      context: context, texture: texture, command: command)
    let borrow = MaterialBorrow(retaining)
    let measuresComposition = onCompositionMeasured != nil
    let worker = Task.detached(priority: priority == .input ? .userInitiated : .utility) { [layers, ink, borrow] in
      defer { withExtendedLifetime((layers, ink, borrow)) {} }
      return try await composition.render(measured: measuresComposition)
    }
    do {
      let result = try await withTaskCancellationHandler {
        try await worker.value
      } onCancel: {
        worker.cancel()
      }
      if let timing = result.timing { onCompositionMeasured?(timing, CACurrentMediaTime()) }
      try Task.checkCancellation()
      guard result.succeeded else { throw SceneRenderError.snapshotPending("page_compositor_gpu") }
      return .init(texture: texture, size: size, reservation: reservation, priority: admittedPriority, onRelease: onRelease)
    } catch {
      reservation.release()
      throw error
    }
  }

  isolated deinit { onRelease?(); reservation.release() }
}

/// One worker exclusively encodes this command. CIContext supports concurrent
/// renders; all input pixels are immutable and retained by the page borrower.
/// Metal's Objective-C protocols do not declare that ownership as Sendable.
private final class PageTurnComposition: @unchecked Sendable {
  enum Layer {
    case image(CGImage, CGRect)
    case texture(any MTLTexture, CGRect)
  }
  private let layers: [Layer]
  private let size: CGSize
  private let scale: Double
  private let context: CIContext
  private let texture: any MTLTexture
  private let command: any MTLCommandBuffer

  init(layers: [Layer], size: CGSize, scale: Double, context: CIContext,
    texture: any MTLTexture, command: any MTLCommandBuffer) {
    self.layers = layers; self.size = size; self.scale = scale
    self.context = context; self.texture = texture; self.command = command
  }

  nonisolated func render(measured: Bool) async throws -> (succeeded: Bool, timing: PageTurnFrame.CompositionTiming?) {
    let workerBegan = measured ? CACurrentMediaTime() : 0
    try Task.checkCancellation()
    let extent = CGRect(x: 0, y: 0, width: texture.width, height: texture.height)
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    var output = CIImage(color: .clear).cropped(to: extent)
    for layer in layers {
      try Task.checkCancellation()
      let pixels: CIImage, rect: CGRect, dimensions: CGSize
      switch layer {
      case .image(let image, let frame):
        pixels = CIImage(cgImage: image); rect = frame
        dimensions = .init(width: image.width, height: image.height)
      case .texture(let texture, let destination):
        guard let image = CIImage(mtlTexture: texture, options: [.colorSpace: colorSpace])
        else { throw SceneRenderError.snapshotPending("page_material_texture") }
        // Owned page/ink textures use a top-left origin; CI uses bottom-left.
        pixels = image.transformed(by: CGAffineTransform(translationX: 0, y: Double(texture.height)).scaledBy(x: 1, y: -1))
        rect = destination; dimensions = .init(width: texture.width, height: texture.height)
      }
      let input = pixels.transformed(by: CGAffineTransform(
        translationX: rect.minX * scale, y: (size.height - rect.maxY) * scale)
        .scaledBy(x: rect.width * scale / dimensions.width, y: rect.height * scale / dimensions.height))
      output = input.composited(over: output)
    }
    output = output.transformed(by: CGAffineTransform(translationX: 0, y: Double(texture.height)).scaledBy(x: 1, y: -1))
    try Task.checkCancellation()
    // Graph compilation and image upload are synchronous CPU work even when
    // the resulting GPU command is awaited asynchronously.
    let encodingBegan = measured ? CACurrentMediaTime() : 0
    context.render(output, to: texture, commandBuffer: command, bounds: extent, colorSpace: colorSpace)
    let encodingEnded = measured ? CACurrentMediaTime() : 0
    command.label = "PageTurn.composeAcceptedMaterials"
    return await withCheckedContinuation { continuation in
      let submitted = measured ? CACurrentMediaTime() : 0
      command.addCompletedHandler { command in
        let timing = measured ? PageTurnFrame.CompositionTiming(workerBegan: workerBegan,
          encodingBegan: encodingBegan, encodingEnded: encodingEnded, submitted: submitted,
          gpuBegan: command.gpuStartTime, gpuEnded: command.gpuEndTime,
          completionReceived: CACurrentMediaTime()) : nil
        continuation.resume(returning: (command.status == .completed, timing))
      }
      // Once submitted, cancellation drains this fence before the main owner
      // may release either the output allocation or any borrowed source.
      command.commit()
    }
  }
}

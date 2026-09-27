import CoreImage
import Metal
import UIKit

/// Immutable physical page pixels. The material owners supply their accepted
/// images and GPU ink; a curl borrows this cut until its last GPU command ends.
@MainActor
final class PageTurnFrame {
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
    onRelease: (@MainActor () -> Void)? = nil) async throws -> PageTurnFrame {
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
    let extent = CGRect(x: 0, y: 0, width: width, height: height)
    var output = CIImage(color: .clear).cropped(to: extent)
    for layer in layers {
      let pixels: CIImage, rect: CGRect, dimensions: CGSize
      switch layer {
      case .image(let image, let frame):
        pixels = CIImage(cgImage: image); rect = frame
        dimensions = .init(width: image.width, height: image.height)
      case .frame(let frame, let destination):
        guard let image = CIImage(mtlTexture: frame.texture, options: [.colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
        else { reservation.release(); throw SceneRenderError.snapshotPending("page_material_texture") }
        pixels = image.transformed(by: CGAffineTransform(translationX: 0, y: Double(frame.texture.height)).scaledBy(x: 1, y: -1))
        rect = destination; dimensions = .init(width: frame.texture.width, height: frame.texture.height)
      }
      let input = pixels.transformed(by: CGAffineTransform(
        translationX: rect.minX * scale, y: (size.height - rect.maxY) * scale)
        .scaledBy(x: rect.width * scale / dimensions.width, y: rect.height * scale / dimensions.height))
      output = input.composited(over: output)
    }
    if let ink {
      guard let pixels = CIImage(mtlTexture: ink.texture, options: [.colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
      else { reservation.release(); throw SceneRenderError.snapshotPending("page_ink_texture") }
      let rect = ink.logicalBounds
      // Ink's Metal row zero is the physical page top. CI composition uses bottom-left.
      let input = pixels.transformed(by: CGAffineTransform(translationX: 0, y: Double(ink.texture.height)).scaledBy(x: 1, y: -1))
        .transformed(by: CGAffineTransform(translationX: rect.minX * scale, y: (size.height - rect.maxY) * scale)
          .scaledBy(x: rect.width * scale / Double(ink.texture.width), y: rect.height * scale / Double(ink.texture.height)))
      output = input.composited(over: output)
    }
    // The analytic page shader samples top-left page coordinates.
    output = output.transformed(by: CGAffineTransform(translationX: 0, y: Double(height)).scaledBy(x: 1, y: -1))
    context.render(output, to: texture, commandBuffer: command, bounds: extent,
      colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    command.label = "PageTurn.composeAcceptedMaterials"
    let borrow = MaterialBorrow(retaining)
    let succeeded = await withCheckedContinuation { continuation in
      command.addCompletedHandler { [layers, ink, borrow] command in
        _ = (layers, ink, borrow)
        continuation.resume(returning: command.status == .completed)
      }
      command.commit()
    }
    guard succeeded else { reservation.release(); throw SceneRenderError.snapshotPending("page_compositor_gpu") }
    return .init(texture: texture, size: size, reservation: reservation, priority: admittedPriority, onRelease: onRelease)
  }

  isolated deinit { onRelease?(); reservation.release() }
}

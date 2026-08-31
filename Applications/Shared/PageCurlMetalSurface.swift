import Metal
import MetalKit
import QuartzCore
import SwiftUI

#if os(iOS)
  import UIKit
#else
  import AppKit
#endif

/// Metal is a readout adapter. PageMotionController remains the only owner of
/// progress, velocity, interruption and the durable page commit.
struct NotebookPageCurlMetalSurface: View {
  let textureKey: String
  let baseImage: CGImage
  let movingImage: CGImage
  let projection: PageCurlProjection
  let gripY: CGFloat

  var body: some View {
    if PageCurlMetalSupport.isAvailable {
      PlatformPageCurlMetalSurface(
        textureKey: textureKey,
        baseImage: baseImage,
        movingImage: movingImage,
        progress: projection.progress,
        direction: projection.direction,
        gripY: gripY
      )
    }
  }
}

enum PageCurlMetalSupport {
  static let isAvailable: Bool = {
    guard let device = MTLCreateSystemDefaultDevice() else { return false }
    return (try? NotebookPageCurlRenderer(device: device)) != nil
  }()
}

#if os(iOS)
private struct PlatformPageCurlMetalSurface: UIViewRepresentable {
  let textureKey: String
  let baseImage: CGImage
  let movingImage: CGImage
  let progress: CGFloat
  let direction: CGFloat
  let gripY: CGFloat

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeUIView(context: Context) -> NotebookPageCurlMetalView {
    let view = NotebookPageCurlMetalView()
    context.coordinator.textureKey = textureKey
    view.renderer?.setTextures(base: baseImage, moving: movingImage)
    view.renderer?.setProjection(
      progress: progress,
      direction: direction,
      gripY: gripY
    )
    return view
  }

  func updateUIView(
    _ view: NotebookPageCurlMetalView,
    context: Context
  ) {
    if context.coordinator.textureKey != textureKey {
      context.coordinator.textureKey = textureKey
      view.renderer?.setTextures(base: baseImage, moving: movingImage)
    }
    view.renderer?.setProjection(
      progress: progress,
      direction: direction,
      gripY: gripY
    )
  }

  final class Coordinator {
    var textureKey: String?
  }
}

@MainActor
private final class NotebookPageCurlMetalView: UIView {
  let renderer: NotebookPageCurlRenderer?

  override class var layerClass: AnyClass { CAMetalLayer.self }

  override init(frame: CGRect) {
    if let device = MTLCreateSystemDefaultDevice() {
      renderer = try? NotebookPageCurlRenderer(device: device)
    } else {
      renderer = nil
    }
    super.init(frame: frame)
    isOpaque = true
    backgroundColor = UIColor(
      red: PaperAppearance.background.red,
      green: PaperAppearance.background.green,
      blue: PaperAppearance.background.blue,
      alpha: 1
    )
    renderer?.attach(to: metalLayer)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("NotebookPageCurlMetalView is created programmatically")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let scale = traitCollection.displayScale
    metalLayer.contentsScale = scale
    metalLayer.drawableSize = CGSize(
      width: max(1, bounds.width * scale),
      height: max(1, bounds.height * scale)
    )
    renderer?.requestFrame()
  }

  private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
}
#else
private struct PlatformPageCurlMetalSurface: NSViewRepresentable {
  let textureKey: String
  let baseImage: CGImage
  let movingImage: CGImage
  let progress: CGFloat
  let direction: CGFloat
  let gripY: CGFloat

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NotebookPageCurlMetalView {
    let view = NotebookPageCurlMetalView()
    context.coordinator.textureKey = textureKey
    view.renderer?.setTextures(base: baseImage, moving: movingImage)
    view.renderer?.setProjection(
      progress: progress,
      direction: direction,
      gripY: gripY
    )
    return view
  }

  func updateNSView(
    _ view: NotebookPageCurlMetalView,
    context: Context
  ) {
    if context.coordinator.textureKey != textureKey {
      context.coordinator.textureKey = textureKey
      view.renderer?.setTextures(base: baseImage, moving: movingImage)
    }
    view.renderer?.setProjection(
      progress: progress,
      direction: direction,
      gripY: gripY
    )
  }

  final class Coordinator {
    var textureKey: String?
  }
}

@MainActor
private final class NotebookPageCurlMetalView: NSView {
  let renderer: NotebookPageCurlRenderer?

  override init(frame: NSRect) {
    if let device = MTLCreateSystemDefaultDevice() {
      renderer = try? NotebookPageCurlRenderer(device: device)
    } else {
      renderer = nil
    }
    super.init(frame: frame)
    wantsLayer = true
    layer = CAMetalLayer()
    layer?.backgroundColor = NSColor(
      calibratedRed: PaperAppearance.background.red,
      green: PaperAppearance.background.green,
      blue: PaperAppearance.background.blue,
      alpha: 1
    ).cgColor
    renderer?.attach(to: metalLayer)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("NotebookPageCurlMetalView is created programmatically")
  }

  override func layout() {
    super.layout()
    let scale = window?.backingScaleFactor
      ?? NSScreen.main?.backingScaleFactor
      ?? 2
    metalLayer.contentsScale = scale
    metalLayer.drawableSize = CGSize(
      width: max(1, bounds.width * scale),
      height: max(1, bounds.height * scale)
    )
    renderer?.requestFrame()
  }

  private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
}
#endif

private final class NotebookPageCurlRenderer: NSObject,
  CAMetalDisplayLinkDelegate
{
  private struct Vertex {
    let position: SIMD2<Float>
    let uv: SIMD2<Float>
  }

  private struct Uniforms {
    var progress: Float
    var direction: Float
    var gripY: Float
    var aspect: Float
    var kind: UInt32
  }

  private enum RendererError: Error {
    case commandQueue
    case library
    case function
    case pipeline
    case sampler
    case vertexBuffer
  }

  private let queue: MTLCommandQueue
  private let pipeline: MTLRenderPipelineState
  private let sampler: MTLSamplerState
  private let vertices: MTLBuffer
  private let textureLoader: MTKTextureLoader
  private weak var layer: CAMetalLayer?
  private var displayLink: CAMetalDisplayLink?
  private var baseTexture: MTLTexture?
  private var movingTexture: MTLTexture?
  private var progress: CGFloat = 0
  private var direction: CGFloat = -1
  private var gripY: CGFloat = 0.5
  private var needsFrame = false

  init(device: MTLDevice) throws {
    guard let queue = device.makeCommandQueue() else {
      throw RendererError.commandQueue
    }
    self.queue = queue
    textureLoader = MTKTextureLoader(device: device)

    let mesh = Self.makeVertices()
    guard let vertices = device.makeBuffer(
      bytes: mesh,
      length: mesh.count * MemoryLayout<Vertex>.stride
    ) else { throw RendererError.vertexBuffer }
    self.vertices = vertices

    guard let library = device.makeDefaultLibrary() else {
      throw RendererError.library
    }
    guard let vertex = library.makeFunction(name: "notebookPageCurlVertex"),
      let fragment = library.makeFunction(name: "notebookPageCurlFragment")
    else { throw RendererError.function }
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = vertex
    descriptor.fragmentFunction = fragment
    descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
    descriptor.colorAttachments[0].isBlendingEnabled = true
    descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
    descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
    descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
    descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
    guard let pipeline = try? device.makeRenderPipelineState(
      descriptor: descriptor
    ) else { throw RendererError.pipeline }
    self.pipeline = pipeline

    let samplerDescriptor = MTLSamplerDescriptor()
    samplerDescriptor.minFilter = .linear
    samplerDescriptor.magFilter = .linear
    samplerDescriptor.sAddressMode = .clampToEdge
    samplerDescriptor.tAddressMode = .clampToEdge
    guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
      throw RendererError.sampler
    }
    self.sampler = sampler
    super.init()
  }

  deinit {
    displayLink?.invalidate()
  }

  func attach(to layer: CAMetalLayer) {
    self.layer = layer
    layer.device = queue.device
    layer.pixelFormat = .bgra8Unorm
    layer.framebufferOnly = true
    layer.maximumDrawableCount = 3
    let link = CAMetalDisplayLink(metalLayer: layer)
    link.delegate = self
    link.preferredFrameLatency = 1
    link.preferredFrameRateRange = CAFrameRateRange(
      minimum: 60,
      maximum: 120,
      preferred: 120
    )
    link.add(to: .main, forMode: .common)
    link.isPaused = true
    displayLink = link
  }

  func setTextures(base: CGImage, moving: CGImage) {
    let options: [MTKTextureLoader.Option: Any] = [
      .SRGB: false,
      .origin: MTKTextureLoader.Origin.topLeft,
    ]
    baseTexture = try? textureLoader.newTexture(cgImage: base, options: options)
    movingTexture = try? textureLoader.newTexture(
      cgImage: moving,
      options: options
    )
    requestFrame()
  }

  func setProjection(
    progress: CGFloat,
    direction: CGFloat,
    gripY: CGFloat
  ) {
    self.progress = min(max(progress, 0), 1)
    self.direction = direction < 0 ? -1 : 1
    self.gripY = min(max(gripY, 0), 1)
    requestFrame()
  }

  func requestFrame() {
    needsFrame = true
    displayLink?.isPaused = false
  }

  func metalDisplayLink(
    _ link: CAMetalDisplayLink,
    needsUpdate update: CAMetalDisplayLink.Update
  ) {
    guard needsFrame else {
      link.isPaused = true
      return
    }
    needsFrame = false
    render(to: update.drawable)
    if !needsFrame { link.isPaused = true }
  }

  private func render(to drawable: any CAMetalDrawable) {
    guard let baseTexture, let movingTexture,
      let commandBuffer = queue.makeCommandBuffer()
    else { return }
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = drawable.texture
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColor(
      red: PaperAppearance.background.red,
      green: PaperAppearance.background.green,
      blue: PaperAppearance.background.blue,
      alpha: 1
    )
    guard let encoder = commandBuffer.makeRenderCommandEncoder(
      descriptor: pass
    ) else { return }
    encoder.setRenderPipelineState(pipeline)
    encoder.setVertexBuffer(vertices, offset: 0, index: 0)
    encoder.setFragmentSamplerState(sampler, index: 0)
    draw(kind: 0, texture: baseTexture, encoder: encoder, drawable: drawable)
    draw(kind: 2, texture: movingTexture, encoder: encoder, drawable: drawable)
    draw(kind: 1, texture: movingTexture, encoder: encoder, drawable: drawable)
    encoder.endEncoding()
    commandBuffer.present(drawable)
    commandBuffer.commit()
  }

  private func draw(
    kind: UInt32,
    texture: MTLTexture,
    encoder: MTLRenderCommandEncoder,
    drawable: any CAMetalDrawable
  ) {
    var uniforms = Uniforms(
      progress: Float(progress),
      direction: Float(direction),
      gripY: Float(gripY),
      aspect: Float(drawable.texture.width) / Float(drawable.texture.height),
      kind: kind
    )
    encoder.setVertexBytes(
      &uniforms,
      length: MemoryLayout<Uniforms>.stride,
      index: 1
    )
    encoder.setFragmentBytes(
      &uniforms,
      length: MemoryLayout<Uniforms>.stride,
      index: 1
    )
    encoder.setFragmentTexture(texture, index: 0)
    encoder.drawPrimitives(
      type: .triangle,
      vertexStart: 0,
      vertexCount: vertices.length / MemoryLayout<Vertex>.stride
    )
  }

  /// This is the only Ransel implementation detail carried into Notebook:
  /// a dense deterministic sheet mesh. It has no gesture or timing state.
  private static func makeVertices() -> [Vertex] {
    let columns = 64
    let rows = 24
    var result: [Vertex] = []
    result.reserveCapacity(columns * rows * 6)
    for row in 0..<rows {
      for column in 0..<columns {
        let x0 = Float(column) / Float(columns)
        let x1 = Float(column + 1) / Float(columns)
        let y0 = Float(row) / Float(rows)
        let y1 = Float(row + 1) / Float(rows)
        result.append(contentsOf: [
          Vertex(position: [x0, y0], uv: [x0, y0]),
          Vertex(position: [x1, y0], uv: [x1, y0]),
          Vertex(position: [x0, y1], uv: [x0, y1]),
          Vertex(position: [x1, y0], uv: [x1, y0]),
          Vertex(position: [x1, y1], uv: [x1, y1]),
          Vertex(position: [x0, y1], uv: [x0, y1]),
        ])
      }
    }
    return result
  }
}

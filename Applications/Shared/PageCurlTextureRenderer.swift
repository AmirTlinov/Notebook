import NotebookCore
import PencilKit
import WebKit

#if os(iOS)
  import UIKit
  private typealias PageCurlNativeImage = UIImage
#else
  import AppKit
  private typealias PageCurlNativeImage = NSImage
#endif

struct PageCurlTextureDescriptor: Hashable {
  let pageID: UUID?
  let drawingStamp: VersionStamp?
  let agentStamp: VersionStamp?
  let width: Double
  let height: Double
  let scale: CGFloat

  init(
    page: PageDocument?,
    fallbackSize: PageSize,
    scale: CGFloat
  ) {
    pageID = page?.id
    drawingStamp = page?.drawingStamp
    agentStamp = page?.agentStamp
    width = page?.size.width ?? fallbackSize.width
    height = page?.size.height ?? fallbackSize.height
    self.scale = scale
  }

  var cacheKey: String {
    let identity = pageID?.uuidString.lowercased() ?? "blank"
    let drawing = drawingStamp.map {
      "\($0.counter):\($0.actor.uuidString.lowercased())"
    } ?? "none"
    let agent = agentStamp.map {
      "\($0.counter):\($0.actor.uuidString.lowercased())"
    } ?? "none"
    return "\(identity)|\(drawing)|\(agent)|\(width)x\(height)@\(scale)"
  }
}

@MainActor
final class PageCurlTextureCache {
  static let shared = PageCurlTextureCache()

  private final class ImageBox {
    let image: CGImage

    init(_ image: CGImage) {
      self.image = image
    }
  }

  private let images = NSCache<NSString, ImageBox>()

  private init() {
    images.countLimit = 12
    images.totalCostLimit = 128 * 1_024 * 1_024
  }

  func image(
    for page: PageDocument?,
    fallbackSize: PageSize,
    scale: CGFloat
  ) -> CGImage? {
    let descriptor = PageCurlTextureDescriptor(
      page: page,
      fallbackSize: fallbackSize,
      scale: scale
    )
    return images.object(forKey: descriptor.cacheKey as NSString)?.image
  }

  func prepare(
    page: PageDocument?,
    fallbackSize: PageSize,
    scale: CGFloat
  ) async {
    let descriptor = PageCurlTextureDescriptor(
      page: page,
      fallbackSize: fallbackSize,
      scale: scale
    )
    let key = descriptor.cacheKey as NSString
    guard images.object(forKey: key) == nil,
      let image = await PageCurlTextureRenderer.render(
        page: page,
        fallbackSize: fallbackSize,
        scale: scale
      ),
      !Task.isCancelled
    else { return }
    images.setObject(
      ImageBox(image),
      forKey: key,
      cost: image.bytesPerRow * image.height
    )
  }
}

@MainActor
private enum PageCurlTextureRenderer {
  static func render(
    page: PageDocument?,
    fallbackSize: PageSize,
    scale: CGFloat
  ) async -> CGImage? {
    let size = page?.size ?? fallbackSize
    let snapshots = await elementSnapshots(page?.elements ?? [])
    guard snapshots.count == (page?.elements.count ?? 0) else { return nil }

    #if os(iOS)
      return renderIOS(
        page: page,
        size: size,
        scale: scale,
        snapshots: snapshots
      )
    #else
      return renderMac(
        page: page,
        size: size,
        scale: scale,
        snapshots: snapshots
      )
    #endif
  }

  private static func elementSnapshots(
    _ elements: [AgentElement]
  ) async -> [(AgentElement, PageCurlNativeImage)] {
    var result: [(AgentElement, PageCurlNativeImage)] = []
    result.reserveCapacity(elements.count)
    for element in elements {
      guard !Task.isCancelled,
        let image = await PageCurlWebSnapshotter.snapshot(element)
      else { return [] }
      result.append((element, image))
    }
    return result
  }

  private static func drawPaper(
    in context: CGContext,
    size: CGSize,
    scale: CGFloat
  ) {
    context.setFillColor(
      red: PaperAppearance.background.red,
      green: PaperAppearance.background.green,
      blue: PaperAppearance.background.blue,
      alpha: 1
    )
    context.fill(CGRect(origin: .zero, size: size))
    context.saveGState()
    context.setShouldAntialias(false)
    context.setStrokeColor(
      red: PaperAppearance.grid.red,
      green: PaperAppearance.grid.green,
      blue: PaperAppearance.grid.blue,
      alpha: PaperAppearance.gridOpacity
    )
    context.setLineWidth(1 / max(scale, 1))
    var x = 0.0
    while x <= size.width {
      context.move(to: CGPoint(x: x, y: 0))
      context.addLine(to: CGPoint(x: x, y: size.height))
      x += PhysicalPaper.gridSpacing
    }
    var y = 0.0
    while y <= size.height {
      context.move(to: CGPoint(x: 0, y: y))
      context.addLine(to: CGPoint(x: size.width, y: y))
      y += PhysicalPaper.gridSpacing
    }
    context.strokePath()
    context.restoreGState()
  }

  #if os(iOS)
    private static func renderIOS(
      page: PageDocument?,
      size: PageSize,
      scale: CGFloat,
      snapshots: [(AgentElement, UIImage)]
    ) -> CGImage? {
      let logicalSize = CGSize(width: size.width, height: size.height)
      let format = UIGraphicsImageRendererFormat()
      format.scale = scale
      format.opaque = true
      format.preferredRange = .standard
      let renderer = UIGraphicsImageRenderer(size: logicalSize, format: format)
      let image = renderer.image { output in
        drawPaper(in: output.cgContext, size: logicalSize, scale: scale)
        let bounds = CGRect(origin: .zero, size: logicalSize)
        if let page, !page.drawingData.isEmpty,
          let drawing = try? PKDrawing(data: page.drawingData)
        {
          drawing.image(from: bounds, scale: scale).draw(in: bounds)
        }
        for (element, snapshot) in snapshots {
          snapshot.draw(in: CGRect(
            x: element.frame.x,
            y: element.frame.y,
            width: element.frame.width,
            height: element.frame.height
          ))
        }
      }
      return image.cgImage
    }
  #else
    private static func renderMac(
      page: PageDocument?,
      size: PageSize,
      scale: CGFloat,
      snapshots: [(AgentElement, NSImage)]
    ) -> CGImage? {
      let pixelWidth = max(1, Int((size.width * scale).rounded(.up)))
      let pixelHeight = max(1, Int((size.height * scale).rounded(.up)))
      guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelWidth,
        pixelsHigh: pixelHeight,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bitmapFormat: [],
        bytesPerRow: 0,
        bitsPerPixel: 0
      ) else { return nil }
      bitmap.size = NSSize(width: size.width, height: size.height)
      guard let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
        return nil
      }
      NSGraphicsContext.saveGraphicsState()
      defer { NSGraphicsContext.restoreGraphicsState() }
      NSGraphicsContext.current = graphics
      graphics.imageInterpolation = .high
      let logicalSize = CGSize(width: size.width, height: size.height)
      drawPaper(in: graphics.cgContext, size: logicalSize, scale: scale)
      let bounds = CGRect(origin: .zero, size: logicalSize)
      if let page, !page.drawingData.isEmpty,
        let drawing = try? PKDrawing(data: page.drawingData)
      {
        PaperInkRenderer.image(
          from: drawing,
          bounds: bounds,
          scale: scale
        ).draw(in: bounds)
      }
      for (element, snapshot) in snapshots {
        snapshot.draw(in: CGRect(
          x: element.frame.x,
          y: size.height - element.frame.y - element.frame.height,
          width: element.frame.width,
          height: element.frame.height
        ))
      }
      graphics.flushGraphics()
      return bitmap.cgImage
    }
  #endif
}

@MainActor
private enum PageCurlWebSnapshotter {
  static func snapshot(_ element: AgentElement) async -> PageCurlNativeImage? {
    let coordinator = AgentWebCoordinator(onState: { _ in })
    let webView = AgentWebCoordinator.makeWebView(coordinator: coordinator)
    webView.frame = CGRect(
      x: 0,
      y: 0,
      width: element.frame.width,
      height: element.frame.height
    )
    defer {
      coordinator.onNavigationCompletion = nil
      webView.stopLoading()
      webView.navigationDelegate = nil
      webView.configuration.userContentController
        .removeScriptMessageHandler(forName: "notebook")
    }

    let loaded = await withCheckedContinuation { continuation in
      coordinator.onNavigationCompletion = { _, success in
        continuation.resume(returning: success)
      }
      coordinator.load(element, in: webView)
    }
    guard loaded, !Task.isCancelled else { return nil }
    try? await Task.sleep(for: .milliseconds(16))
    guard !Task.isCancelled else { return nil }

    #if os(iOS)
      webView.layoutIfNeeded()
    #else
      webView.layoutSubtreeIfNeeded()
    #endif
    return await withCheckedContinuation { continuation in
      webView.takeSnapshot(with: nil) { image, _ in
        continuation.resume(returning: image)
      }
    }
  }
}

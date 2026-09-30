#if os(iOS)
import NotebookCore
import CoreText
import SwiftUI
import UIKit

/// A pending/error slot is real page content. Its installed view and a curl
/// borrow the same accounted image; neither claims that the program is ready.
@MainActor
final class PageElementStatusPresentation {
  struct Key: Equatable, Sendable {
    let source: AgentElement
    let rasterSource: SceneRasterSource
    let message: String
    let canRetry: Bool
    let scale: Double
    let previousRaster: UUID?
  }
  let id = UUID()
  let key: Key
  let cut: SceneRasterCut
  init(key: Key, cut: SceneRasterCut) { self.key = key; self.cut = cut }

  static func prepare(_ key: Key, raster: RasterLease?, resources: SceneRenderResources) async throws -> PageElementStatusPresentation {
    try Task.checkCancellation()
    let region = key.rasterSource.captureRegion
      ?? .init(x: 0, y: 0, width: key.source.frame.width, height: key.source.frame.height)
    let size = CGSize(width: region.width, height: region.height)
    guard key.scale.isFinite, key.scale > 0, size.width.isFinite, size.height.isFinite,
      size.width > 0, size.height > 0, size.width * key.scale <= 8192, size.height * key.scale <= 8192,
      let allocation = resources.reserveRaster(pixelWidth: Int(ceil(size.width * key.scale)),
        pixelHeight: Int(ceil(size.height * key.scale))) else { throw SceneRenderError.resourceLimit }
    // Borrow the exact old pixels across the worker, even if their presenter
    // advances meanwhile. This source-owned output has no cache or second
    // screen representation: the native view and a curl retain the same cut.
    let previous = raster?.retainedCopy()
    defer { previous?.release() }
    let image = previous?.image.cgImage
    let oldRegion = previous?.source.captureRegion
      ?? .init(x: 0, y: 0, width: key.source.frame.width, height: key.source.frame.height)
    let priorFrame = CGRect(x: oldRegion.x - region.x, y: size.height - (oldRegion.y - region.y) - oldRegion.height,
      width: oldRegion.width, height: oldRegion.height)
    let fontSize = UIFont.preferredFont(forTextStyle: .caption1).pointSize
    let task = Task.detached(priority: .userInitiated) {
      try render(key, size: size, previous: image, priorFrame: priorFrame,
        fontSize: fontSize)
    }
    do {
      let image = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
      try Task.checkCancellation()
      return .init(key: key, cut: .init(source: key.rasterSource, pixelScale: key.scale,
        pixels: .init(image: image, reservation: allocation)))
    } catch { allocation.release(); throw error }
  }

  /// Status typography and its one destination buffer never occupy the UI
  /// actor while the actual programs are delivering their first frame.
  nonisolated private static func render(_ key: Key, size: CGSize, previous: CGImage?, priorFrame: CGRect,
    fontSize: CGFloat) throws -> CGImage {
    assert(!Thread.isMainThread)
    try Task.checkCancellation()
    guard let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil),
      let retryFont = CTFontCreateCopyWithSymbolicTraits(font, fontSize, nil, .traitBold, .traitBold)
      else { throw SceneRenderError.resourceLimit }
    let width = Int(ceil(size.width * key.scale)), height = Int(ceil(size.height * key.scale))
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
      bytesPerRow: ((width * 4 + 63) / 64) * 64, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw SceneRenderError.resourceLimit }
    context.scaleBy(x: key.scale, y: key.scale)
    if let previous { context.draw(previous, in: priorFrame) }
    var alignment = CTTextAlignment.center
    let paragraph = withUnsafePointer(to: &alignment) { value in
      var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: value)
      return CTParagraphStyleCreate(&setting, 1)
    }
    func text(_ value: String, font: CTFont, color: CGColor) -> CTFramesetter {
      CTFramesetterCreateWithAttributedString(NSAttributedString(string: value, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph]))
    }
    let message = text(key.message, font: font, color: CGColor(gray: 0.42, alpha: 1))
    let retry = key.canRetry ? text("Повторить", font: retryFont,
      color: CGColor(red: 0, green: 0.48, blue: 1, alpha: 1)) : nil
    let availableWidth = max(1, size.width - 16)
    func measured(_ text: CTFramesetter) -> CGSize {
      let result = CTFramesetterSuggestFrameSizeWithConstraints(text, CFRange(location: 0, length: 0), nil,
        CGSize(width: availableWidth, height: .greatestFiniteMagnitude), nil)
      return .init(width: ceil(result.width), height: ceil(result.height))
    }
    let messageSize = measured(message), retrySize = retry.map(measured) ?? .zero
    let gap: CGFloat = retry == nil ? 0 : 6
    let badgeSize = CGSize(width: min(size.width, max(messageSize.width, retrySize.width) + 16),
      height: min(size.height, messageSize.height + retrySize.height + gap + 16))
    let badge = CGRect(x: (size.width - badgeSize.width) / 2, y: (size.height - badgeSize.height) / 2,
      width: badgeSize.width, height: badgeSize.height)
    context.setFillColor(CGColor(red: 0.96, green: 0.96, blue: 0.95, alpha: 1))
    context.addPath(CGPath(roundedRect: badge, cornerWidth: 8, cornerHeight: 8, transform: nil)); context.fillPath()
    func draw(_ text: CTFramesetter, in rect: CGRect) {
      guard rect.width > 0, rect.height > 0 else { return }
      CTFrameDraw(CTFramesetterCreateFrame(text, CFRange(location: 0, length: 0),
        CGPath(rect: rect, transform: nil), nil), context)
    }
    draw(message, in: CGRect(x: badge.minX + 8, y: badge.minY + 8 + retrySize.height + gap,
      width: max(1, badge.width - 16), height: messageSize.height))
    if let retry { draw(retry, in: CGRect(x: badge.minX + 8, y: badge.minY + 8,
      width: max(1, badge.width - 16), height: retrySize.height)) }
    try Task.checkCancellation()
    guard let image = context.makeImage() else { throw SceneRenderError.resourceLimit }
    return image
  }
}

struct PageElementStatusView: UIViewRepresentable {
  let presentation: PageElementStatusPresentation
  let onInstallation: (PageElementStatusPresentation, SceneSourceInstallation) -> Void
  let retry: () -> Void
  func makeUIView(context: Context) -> NativeView { NativeView() }
  func updateUIView(_ view: NativeView, context: Context) {
    view.onInstallation = onInstallation; view.retry = retry; view.install(presentation)
  }
  static func dismantleUIView(_ view: NativeView, coordinator: ()) { view.uninstall() }

  final class NativeView: UIControl, SceneSourceInstallationOwner {
    private var presentation: PageElementStatusPresentation?
    private var retired = false
    private let imageLayer = CALayer()
    var onInstallation: ((PageElementStatusPresentation, SceneSourceInstallation) -> Void)?
    var retry: (() -> Void)?
    init() {
      super.init(frame: .zero)
      isOpaque = false; backgroundColor = .clear
      layer.addSublayer(imageLayer); imageLayer.contentsGravity = .resize; imageLayer.shouldRasterize = false
      addTarget(self, action: #selector(activated), for: .touchUpInside)
      isAccessibilityElement = true
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init()") }
    func install(_ value: PageElementStatusPresentation) {
      guard !retired else { return }
      if presentation !== value {
        withdraw(); presentation = value
        CATransaction.begin(); CATransaction.setDisableActions(true)
        imageLayer.contents = value.cut.image; imageLayer.contentsScale = value.key.scale
        layoutImage()
        CATransaction.commit()
      }
      isUserInteractionEnabled = value.key.canRetry
      accessibilityLabel = value.key.message + (value.key.canRetry ? ". Повторить" : "")
      accessibilityTraits = value.key.canRetry ? .button : .staticText
      acknowledge()
    }
    func isShowing(_ installation: SceneSourceInstallation) -> Bool {
      !retired && presentation?.id == installation.entryID
        && presentation?.cut.source == installation.source && SceneSourceVisibility.isVisible(self)
    }
    private func layoutImage() {
      guard let presentation else { return }
      let source = presentation.key.source
      let rect = presentation.cut.source.captureRegion
        ?? .init(x: 0, y: 0, width: source.frame.width, height: source.frame.height)
      let sx = bounds.width / max(1, source.frame.width), sy = bounds.height / max(1, source.frame.height)
      CATransaction.begin(); CATransaction.setDisableActions(true)
      imageLayer.frame = .init(x: rect.x * sx, y: rect.y * sy, width: rect.width * sx, height: rect.height * sy)
      CATransaction.commit()
    }
    override func layoutSubviews() { super.layoutSubviews(); layoutImage(); acknowledge() }
    override func didMoveToWindow() { super.didMoveToWindow(); acknowledge() }
    private func acknowledge() {
      guard let presentation else { return }
      onInstallation?(presentation, .init(source: presentation.cut.source, entryID: presentation.id, owner: self))
    }
    private func withdraw() {
      let old = presentation; presentation = nil
      if let old { onInstallation?(old, .init(source: old.cut.source, entryID: old.id, owner: self)) }
    }
    func uninstall() {
      guard !retired else { return }; retired = true; withdraw()
      imageLayer.contents = nil; onInstallation = nil; retry = nil
    }
    @objc private func activated() { if presentation?.key.canRetry == true { retry?() } }
  }
}
#endif

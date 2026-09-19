import CoreGraphics
import Foundation
import QuartzCore
#if os(iOS)
import UIKit
typealias PaperPlatformView = UIView
#else
import AppKit
typealias PaperPlatformView = NSView
#endif

@MainActor
final class DocumentPaperRaster {
  let page: DocumentPrintedPage
  let sourceKey: String
  let image: CGImage
  private let reservation: RasterReservation
  init(page: DocumentPrintedPage, sourceKey: String, image: CGImage, reservation: RasterReservation) {
    self.page = page; self.sourceKey = sourceKey; self.image = image; self.reservation = reservation
  }
  static func prepare(page: DocumentPrintedPage, sourceKey: String, pixelWidth: Int,
    resources: SceneRenderResources, waits: (Bool) -> Void) async throws -> DocumentPaperRaster {
    let height = Int(ceil(Double(pixelWidth)*page.height/page.width))
    let reservation = try await resources.acquirePassiveDerivedBytes(pixelWidth*height*8) { waits(true) }
    defer { waits(false) }
    do {
      let image = try await page.image(width: pixelWidth)
      try Task.checkCancellation()
      return .init(page: page, sourceKey: sourceKey, image: image, reservation: reservation)
    } catch { reservation.release(); throw error }
  }
  isolated deinit { reservation.release() }
}

/// Its rectangle is projected by the existing physical viewport. Refinement
/// changes pixels only; this view has no scroll view, camera, layout or input.
@MainActor
final class DocumentPaperView: PaperPlatformView {
  private(set) var raster: DocumentPaperRaster?
  private var refinement: Task<Void, Never>?
  private weak var resources: SceneRenderResources?
  #if os(iOS)
  private var paperLayer: CALayer { layer }
  #else
  private var paperLayer: CALayer { layer! }
  #endif
  init() {
    super.init(frame: .zero)
    #if os(iOS)
    isUserInteractionEnabled = false; isAccessibilityElement = false
    #else
    wantsLayer = true; setAccessibilityElement(false)
    #endif
    paperLayer.backgroundColor = CGColor(gray: 1, alpha: 1)
  }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init()") }
  func install(_ raster: DocumentPaperRaster, resources: SceneRenderResources) {
    refinement?.cancel(); refinement = nil; self.resources = resources
    self.raster = raster
    CATransaction.begin(); CATransaction.setDisableActions(true)
    paperLayer.contents = raster.image; paperLayer.contentsGravity = .resize
    CATransaction.commit()
  }
  func clear() {
    refinement?.cancel(); refinement = nil
    paperLayer.contents = nil; raster = nil; resources = nil
  }
  #if os(iOS)
  override func layoutSubviews() { super.layoutSubviews(); refine() }
  #else
  override func layout() { super.layout(); refine() }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  #endif
  func refine() {
    guard refinement == nil, let raster, let resources, window != nil else { return }
    #if os(iOS)
    let size = convert(bounds, to: window).size
    let scale = window?.screen.scale ?? 2
    #else
    let size = convert(bounds, to: nil).size
    let scale = window?.backingScaleFactor ?? 2
    #endif
    let requested = max(256, Int(ceil(size.width * scale)))
    let maximum = Int(sqrt(16_777_216 * raster.page.width / raster.page.height))
    let width = min(maximum, requested)
    guard width > Int(Double(raster.image.width)*1.2) else { return }
    let height = Int(ceil(Double(width)*raster.page.height/raster.page.width))
    guard let charge = resources.reserveDerivedBytes(width*height*8, priority: .passive) else { return }
    refinement = Task { @MainActor [weak self] in
      defer { self?.refinement = nil }
      do {
        let image = try await raster.page.image(width: width)
        guard !Task.isCancelled, let self, self.raster === raster else { charge.release(); return }
        install(.init(page: raster.page, sourceKey: raster.sourceKey, image: image, reservation: charge), resources: resources)
      } catch { charge.release() }
    }
  }
  isolated deinit { refinement?.cancel() }
}

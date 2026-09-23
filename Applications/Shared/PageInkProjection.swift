import SwiftUI
#if os(iOS)
import UIKit
typealias PageInkHost = UIView
#else
import AppKit
typealias PageInkHost = NSView
#endif

/// Projects the same measured page geometry into a screen-sized Metal crop.
/// It observes the existing camera; it owns neither camera nor input coordinates.
@MainActor
final class PageInkProjection: ScenePlaneProjectionObserver {
  private weak var host: PageInkHost?
  private weak var canvas: InkCanvasView?
  private weak var projection: ScenePlaneProjection?

  init(host: PageInkHost? = nil, canvas: InkCanvasView? = nil) { self.host = host; self.canvas = canvas }

  func attach(host:PageInkHost,canvas:InkCanvasView) { self.host=host;self.canvas=canvas }

  /// SwiftUI reports its next pose before applying the native ancestor matrix.
  /// Join the native layout phase of that transaction, not the old conversion.
  func invalidateLayout() {
    #if os(iOS)
    host?.setNeedsLayout()
    #else
    host?.needsLayout=true
    #endif
  }

  func observe(_ value: ScenePlaneProjection?) {
    if projection !== value {
      projection?.remove(self); projection = value; value?.register(self)
    }
    refresh()
  }

  func stop() { projection?.remove(self); projection = nil; host = nil; canvas = nil }
  func scenePlaneDidProject() { refresh() }

  func refresh() {
    guard let host, let canvas, let window = host.window, !host.bounds.isEmpty else { return }
    #if os(iOS)
    let visible = SceneSourceVisibility.visibleRect(host)
    let origin = host.convert(CGPoint.zero, to: window)
    let x = host.convert(CGPoint(x: 1, y: 0), to: window)
    let y = host.convert(CGPoint(x: 0, y: 1), to: window)
    let backing = window.windowScene?.screen.scale ?? host.traitCollection.displayScale
    #else
    let visible = host.visibleRect.intersection(host.convert(window.contentView?.bounds ?? .zero, from: window.contentView))
    let origin = host.convert(CGPoint.zero, to: nil)
    let x = host.convert(CGPoint(x: 1, y: 0), to: nil)
    let y = host.convert(CGPoint(x: 0, y: 1), to: nil)
    let backing = window.backingScaleFactor
    #endif
    let density = max(hypot(x.x-origin.x, x.y-origin.y), hypot(y.x-origin.x, y.y-origin.y)) * backing
    guard density.isFinite, density > 0 else { return }
    canvas.isHidden = visible.isNull || visible.isEmpty
    guard !canvas.isHidden else { return }
    // A two-pixel fringe and pixel-grid rounding prevent clipping antialiased edges.
    let padded = visible.insetBy(dx: -2/density, dy: -2/density).intersection(host.bounds)
    let lo = CGPoint(x: floor(padded.minX*density)/density, y: floor(padded.minY*density)/density)
    let hi = CGPoint(x: ceil(padded.maxX*density)/density, y: ceil(padded.maxY*density)/density)
    canvas.projectPage(region: CGRect(x: lo.x, y: lo.y, width: hi.x-lo.x, height: hi.y-lo.y),
      sourceSize: host.bounds.size, pixelDensity: density)
  }
}

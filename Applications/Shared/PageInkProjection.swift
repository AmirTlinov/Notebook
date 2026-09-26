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
  private var isSceneVisible = true
  private var refinesDetails = true
  private weak var pageReadiness: PageTurnReadiness?
  private weak var activity: PageTurnActivity?
  private var preparationObserver: UUID?
  private var pageIsCurrent = true
  private var notebookIsVisible = true

  /// Native page demand promotes the exact next sheet before its cached ready
  /// bit can authorize capture. SwiftUI's global notebook visibility is not a
  /// current/prewarm role: all retained sheets are mounted in that same window.
  func observePage(_ readiness: PageTurnReadiness?, isCurrent: Bool, isVisible: Bool) {
    if activity !== readiness?.activity {
      if let preparationObserver { activity?.removePreparationObserver(preparationObserver) }
      activity=readiness?.activity
      preparationObserver=activity?.observePreparation { [weak self] change in
        guard let self else { return }
        switch change {
        case .demand: refreshPageRole()
        case .refine(let pageIndex):
          guard pageReadiness?.pageIndex == pageIndex, isSceneVisible else { return }
          refresh(refining:true)
          if canvas?.isStableFramePresented == false { pageReadiness?(false) }
        }
      }
    }
    pageReadiness=readiness;pageIsCurrent=isCurrent;notebookIsVisible=isVisible
    refreshPageRole()
  }

  private func refreshPageRole() {
    let index=pageReadiness?.pageIndex
    let demanded=index != nil && activity?.preparationDemand?.pageIndex == index
    let installed=index != nil && activity?.installedPreparation?.pageIndex == index
    let required = activity == nil || pageIsCurrent || demanded || installed
      || pageReadiness?.isInActiveTurn() == true
    // Install the promoted native crop before un-parking its drawable demand.
    setSceneVisible(notebookIsVisible && required)
    canvas?.setPageBackingRequired(required)
    if canvas?.isStableFramePresented == false { pageReadiness?(false) }
  }

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

  /// The page-turn owner already distinguishes visible sheets from retained
  /// neighbours. A hidden neighbour prepares once, not once per foreign camera
  /// sample; promotion immediately uses the current native projection.
  func setSceneVisible(_ visible:Bool) {
    guard isSceneVisible != visible else { return }
    isSceneVisible=visible;refresh(refining:visible ? true : nil)
  }

  func setRefinesDetails(_ refines:Bool) {
    guard refinesDetails != refines else { return }
    refinesDetails=refines;refresh()
  }

  func stop() {
    if let preparationObserver { activity?.removePreparationObserver(preparationObserver) }
    preparationObserver=nil;activity=nil;pageReadiness=nil
    projection?.remove(self);projection=nil;host=nil;canvas=nil
  }
  func scenePlaneDidProject() { refresh() }

  func refresh(refining:Bool? = nil) {
    let refinesDetails=refining ?? self.refinesDetails
    guard let host, let canvas, let window = host.window, !host.bounds.isEmpty else { return }
    guard isSceneVisible || canvas.pageRenderRegion == nil || canvas.pageSourceSize != host.bounds.size else { return }
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
    // A two-pixel fringe is real coverage, not an excuse to resize every
    // sample. Reuse the already admitted crop at the scene's movement quality;
    // settled publication refines magnification and reclaims deep minification.
    let visibleWithFringe=visible.insetBy(dx:-2/density,dy:-2/density).intersection(host.bounds)
    if let previous=canvas.pageRenderRegion,canvas.pageSourceSize == host.bounds.size,
      previous.width > 0,previous.height > 0,previous.contains(visibleWithFringe) {
      let available=min(canvas.drawableSize.width/previous.width,canvas.drawableSize.height/previous.height)
      let allowance=refinesDetails ? 1.0 : SceneCameraProjection.maximumUnrefinedMagnification
      if density <= available*allowance+0.000_001,(!refinesDetails || density/available >= 0.6) { return }
    }
    // The existing native tile-pool guard is finite and clamped to the sheet;
    // it buys nearby pan coverage without a second surface or a page cache.
    let backingSize=InkCanvasView.sceneBackingSize(viewport:.init(x:visibleWithFringe.width,y:visibleWithFringe.height),
      displayScale:density)
    let padded=CGRect(x:visibleWithFringe.midX-backingSize.x/2,y:visibleWithFringe.midY-backingSize.y/2,
      width:backingSize.x,height:backingSize.y).intersection(host.bounds)
    let lo = CGPoint(x: floor(padded.minX*density)/density, y: floor(padded.minY*density)/density)
    let hi = CGPoint(x: ceil(padded.maxX*density)/density, y: ceil(padded.maxY*density)/density)
    canvas.projectPage(region: CGRect(x: lo.x, y: lo.y, width: hi.x-lo.x, height: hi.y-lo.y),
      sourceSize: host.bounds.size, pixelDensity: density)
  }
}

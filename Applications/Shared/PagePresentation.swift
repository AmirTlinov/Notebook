import NotebookCore
import SwiftUI

/// Readiness identifies the accepted ink root, not just a reusable view.
struct PageInkPresentation:Equatable {
  let pageID:UUID
  let stamp:VersionStamp
  func matches(_ page:PageDocument)->Bool { page.id == pageID && page.drawingStamp == stamp }
}

/// Native input and overlay publish into the same mounted paper receipt.
/// Queries read it directly; a SwiftUI redraw is not another readiness owner.
@MainActor final class PageSurfaceReadiness {
  private var ink:PageInkPresentation?
  private var graphics:ObjectIdentifier?
  private var shownGraphics:(id:UUID,size:PageSize,stamp:VersionStamp)?
  func recordInk(_ receipt:PageInkPresentation?) { ink=receipt }
  func recordGraphics(_ ready:Bool,page:PageDocument) {
    if ready {
      graphics=page.elementSourceIdentity
      shownGraphics=(page.id,page.size,page.agentStamp)
    } else if graphics == page.elementSourceIdentity { graphics=nil }
  }
  func isReady(_ page:PageDocument)->Bool {
    ink?.matches(page) == true && graphics == page.elementSourceIdentity
  }
  func hasInstalledGraphics(_ page:PageDocument)->Bool {
    shownGraphics?.id == page.id && shownGraphics?.size == page.size && shownGraphics?.stamp == page.agentStamp
  }
}

#if os(iOS)
import UIKit
import OSLog

/// Installed paper owns this evidence. A cached raster, a prepared neighbour
/// or a former mount cannot acknowledge a newly opened page.
@MainActor
final class NotebookPagePresentationRegistry {
  private struct WeakOwner { weak var value: PagePresentationNativeView? }
  private var owners: [ObjectIdentifier: WeakOwner] = [:]

  func register(_ owner: PagePresentationNativeView) {
    owners[ObjectIdentifier(owner)] = .init(value: owner)
  }

  func remove(_ owner: PagePresentationNativeView) { owners[ObjectIdentifier(owner)] = nil }

  func isPresented(_ page: PageDocument) -> Bool {
    owners = owners.filter { $0.value.value != nil }
    return owners.values.contains { $0.value?.isPresenting(page) == true }
  }

  func hasInstalledGraphics(_ page:PageDocument) -> Bool {
    owners = owners.filter { $0.value.value != nil }
    return owners.values.contains { $0.value?.hasInstalledGraphics(page) == true }
  }
}

struct PagePresentationView: UIViewRepresentable {
  @Environment(NotebookAppModel.self) private var model
  @Environment(\.scenePlaneProjection) private var projection
  let page: PageDocument
  let isCurrent: Bool
  let isVisible: Bool
  let readiness:PageSurfaceReadiness
  let activity: PageTurnActivity?
  var onVisibleRegion: (CGRect) -> Void = { _ in }

  func makeUIView(context: Context) -> PagePresentationNativeView { PagePresentationNativeView() }
  func updateUIView(_ view: PagePresentationNativeView, context: Context) {
    view.update(model: model, page: page, isCurrent: isCurrent, isVisible: isVisible,
      readiness:readiness, activity:activity)
    view.onVisibleRegion = onVisibleRegion
    view.viewport.observe(projection)
    view.scheduleVisibleRegion()
  }
  static func dismantleUIView(_ view: PagePresentationNativeView, coordinator: ()) { view.uninstall() }
}

@MainActor
final class PagePresentationNativeView: UIView, NotebookScenePresentationOwner {
  private weak var model: NotebookAppModel?
  private var pageID:UUID?
  private var pageSize:PageSize?
  private var isCurrent = false
  private var isVisible = false
  private var readiness:PageSurfaceReadiness?
  private var activity: PageTurnActivity?
  private var retired = false
  lazy var viewport = PageViewportProjection(host:self)
  var onVisibleRegion: (CGRect) -> Void {
    get { viewport.onRegion }
    set { viewport.onRegion = newValue }
  }

  init() {
    super.init(frame: .zero)
    isUserInteractionEnabled = false; isOpaque = false; backgroundColor = .clear
    accessibilityElementsHidden = true
  }
  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("Use init()") }

  func update(model: NotebookAppModel, page: PageDocument, isCurrent: Bool,
    isVisible: Bool, readiness:PageSurfaceReadiness, activity: PageTurnActivity?) {
    guard !retired else { return }
    if pageID != page.id {
      Logger(subsystem: "com.amirtlinov.notebook", category: "PaperGeometry")
        .notice("Mounted paper size: \(page.size.width) x \(page.size.height)")
    }
    if self.model !== model {
      self.model?.pagePresentations.remove(self)
      self.model?.unregisterScenePresentation(self)
      self.model = model
      model.pagePresentations.register(self)
      model.registerScenePresentation(self)
    }
    pageID=page.id;pageSize=page.size;self.isCurrent=isCurrent;self.isVisible=isVisible
    self.readiness=readiness;self.activity=activity
    viewport.isVisible = isVisible
  }

  override func layoutSubviews() { super.layoutSubviews(); scheduleVisibleRegion() }
  override func didMoveToWindow() { super.didMoveToWindow(); scheduleVisibleRegion() }

  func scheduleVisibleRegion() { viewport.refresh() }

  func isPresenting(_ page: PageDocument) -> Bool {
    readiness?.isReady(page) == true && isShowingCurrentPaper(page)
  }

  /// A new ink contact cannot disable unchanged, installed graphics. This
  /// grants local hit testing, not a receipt that the whole page was shown.
  func hasInstalledGraphics(_ page:PageDocument) -> Bool {
    readiness?.hasInstalledGraphics(page) == true && isShowingCurrentPaper(page)
  }

  private func isShowingCurrentPaper(_ page:PageDocument) -> Bool {
    guard !retired, isCurrent, isVisible, activity?.isTransitioning != true,
      pageID == page.id, pageSize == page.size, let window, !window.isHidden, !bounds.isEmpty,
      convert(bounds, to: window).intersects(window.bounds) else { return false }
    var ancestor: UIView? = self
    while let view = ancestor {
      guard !view.isHidden, view.alpha > 0.001 else { return false }
      ancestor = view.superview
    }
    return true
  }

  func uninstall() {
    guard !retired else { return }
    retired = true; pageID=nil;pageSize=nil;readiness=nil;activity=nil
    viewport.stop()
    model?.pagePresentations.remove(self)
    model?.unregisterScenePresentation(self)
    model = nil
  }
}
#else
struct PagePresentationView: NSViewRepresentable {
  @Environment(\.scenePlaneProjection) private var projection
  let page: PageDocument
  let isCurrent: Bool
  let isVisible: Bool
  let readiness:PageSurfaceReadiness
  let activity: PageTurnActivity?
  var onVisibleRegion: (CGRect) -> Void = { _ in }
  func makeNSView(context:Context) -> PagePresentationNativeView { .init(frame:.zero) }
  func updateNSView(_ view:PagePresentationNativeView,context:Context) {
    view.viewport.onRegion=onVisibleRegion;view.viewport.isVisible=isVisible
    view.viewport.observe(projection)
  }
  static func dismantleNSView(_ view:PagePresentationNativeView,coordinator:()) { view.viewport.stop() }
}

final class PagePresentationNativeView: NSView {
  lazy var viewport=PageViewportProjection(host:self)
  override var isFlipped:Bool { true }
  override func hitTest(_ point:NSPoint) -> NSView? { nil }
  override func layout() { super.layout();viewport.refresh() }
  override func viewDidMoveToWindow() { super.viewDidMoveToWindow();viewport.refresh() }
}
#endif

#if os(iOS)
private typealias PageViewportHost=UIView
#else
private typealias PageViewportHost=NSView
#endif

/// Reads the existing native camera, including held gestures. This is display
/// demand, not background preparation, current-page focus or a second camera.
@MainActor
final class PageViewportProjection: ScenePlaneProjectionObserver {
  private weak var host:PageViewportHost?
  private weak var projection:ScenePlaneProjection?
  private var task:Task<Void,Never>?
  private var published:CGRect?
  private var stopped=false
  var isVisible=false
  var onRegion:(CGRect)->Void = { _ in }
  fileprivate init(host:PageViewportHost) { self.host=host }
  func observe(_ value:ScenePlaneProjection?) {
    if projection !== value { projection?.remove(self);projection=value;value?.register(self) }
    refresh()
  }
  func scenePlaneDidProject() { refresh() }
  func refresh() {
    guard !stopped,task == nil else { return }
    task=Task { @MainActor [weak self] in
      guard let self else { return };task=nil
      guard !stopped else { return }
      let region=region()
      guard region != published else { return };published=region;onRegion(region)
    }
  }
  private func region() -> CGRect {
    guard isVisible,let host,let window=host.window,SceneSourceVisibility.isMounted(host) else { return .null }
    #if os(iOS)
    let visible=SceneSourceVisibility.visibleRect(host)
    let origin=host.convert(CGPoint.zero,to:window),x=host.convert(CGPoint(x:1,y:0),to:window),y=host.convert(CGPoint(x:0,y:1),to:window)
    let backing=window.windowScene?.screen.scale ?? host.traitCollection.displayScale
    #else
    let visible=host.visibleRect.intersection(host.convert(window.contentView?.bounds ?? .zero,from:window.contentView))
    let origin=host.convert(CGPoint.zero,to:nil),x=host.convert(CGPoint(x:1,y:0),to:nil),y=host.convert(CGPoint(x:0,y:1),to:nil)
    let backing=window.backingScaleFactor
    #endif
    guard !visible.isNull,!visible.isEmpty else { return .null }
    let density=max(hypot(x.x-origin.x,x.y-origin.y),hypot(y.x-origin.x,y.y-origin.y))*backing
    guard density.isFinite,density>0 else { return host.bounds }
    // Geometry outside the clip can still contribute antialiased edge pixels.
    return visible.insetBy(dx:-2/density,dy:-2/density).intersection(host.bounds)
  }
  func stop() {
    stopped=true;task?.cancel();task=nil;projection?.remove(self);projection=nil;host=nil;onRegion={ _ in }
  }
}

import NotebookCore
import SwiftUI

/// One accepted slot owns preparation per addressed element. Native hosts
/// borrow it; only source removal or read-window retirement is terminal.
@MainActor
final class PageAgentPreparationOwner {
  private struct PageDemand: Equatable {
    let model: ObjectIdentifier
    let pageID: UUID
    let elements: ObjectIdentifier
    let size: PageSize
    let renderingScale: Double
    let displayScale: Double
    let allowsInteraction: Bool
    let inputEnabled: Bool
    let focus: InteractiveElementReference?
    let permitsPreparation: Bool
    let pageIndex: Int?
    let visibleRegion: CGRect?
  }
  private var accepted: PageDemand?
  // Retain the immutable cache whose ObjectIdentifier is the accepted key.
  private var acceptedPage: PageDocument?
  private let resources: SceneRenderResources
  private var elements: [String: PreparedAgentElementPreparationOwner] = [:]
  private var pageID: UUID?
  private weak var boundActivity: PageTurnActivity?
  private var boundPageIndex: Int?

  func bindPresentation(activity: PageTurnActivity, pageIndex: Int) {
    guard !isRetired, boundActivity !== activity || boundPageIndex != pageIndex else { return }
    boundActivity = activity; boundPageIndex = pageIndex
    for owner in elements.values {
      owner.bindPresentation(activity: activity, context: .init(owner: activity.rasters, pageIndex: pageIndex))
    }
  }

  static func visibleRegion(page: PageDocument, item: RenderedWorkspaceItem, presence: SessionPresence) -> CGRect? {
    let scale = min(item.geometry.width / page.size.width, item.geometry.height / page.size.height) * presence.camera.scale
    guard scale > 0 else { return nil }
    let center = presence.camera.worldToScreen(item.center, viewport: presence.viewport)
    let origin = CGPoint(x: center.x - page.size.width * scale / 2, y: center.y - page.size.height * scale / 2)
    return CGRect(x: -origin.x / scale, y: -origin.y / scale,
      width: presence.viewport.x / scale, height: presence.viewport.y / scale)
      .intersection(CGRect(x: 0, y: 0, width: page.size.width, height: page.size.height))
  }
  private(set) var isRetired = false

  init(resources: SceneRenderResources = .shared) { self.resources = resources }

  func owner(for id: String) -> PreparedAgentElementPreparationOwner {
    if let owner = elements[id] { return owner }
    let owner = PreparedAgentElementPreparationOwner(resources: resources)
    if isRetired { owner.retire() } else { elements[id] = owner }
    return owner
  }

  /// Source publication is independent of a mounted shell. Preserve each
  /// runtime's role and heap while replacing its exact source/state and crop.
  func reconcile(page: PageDocument, model: NotebookAppModel) {
    guard !isRetired else { return }
    if acceptedPage?.elementSourceIdentity == page.elementSourceIdentity, acceptedPage?.size == page.size { return }
    let previous = acceptedPage
    acceptedPage = page; accepted = nil; pageID = page.id
    guard !elements.isEmpty else { return }
    let next = model.pageGraphicDisplay(page, in: nil)
    let old = previous.map { model.pageGraphicDisplay($0, in: nil) }
    for (id, owner) in elements {
      guard let source = page.element(id: id), source.graphic == nil, source.kind != .nativeText,
        let presentation = model.elementPresentation(.page(pageID: page.id, elementID: id), graph: next.graph),
        let demand = owner.demand else {
        elements.removeValue(forKey: id)?.retire(afterUpdate: true); continue
      }
      let oldScale = old.flatMap { model.elementPresentation(.page(pageID: page.id, elementID: id), graph: $0.graph)?.maximumScale } ?? presentation.maximumScale
      let density = demand.policy.minimumScale(for: demand.source) / max(oldScale, 0.0001)
      let policy = Self.capturePolicy(for: source, presentation: presentation, pageSize: page.size,
        renderingScale: density, displayScale: 1)
      owner.acceptSource(agentElementSnapshotSource(source), policy: policy)
    }
  }

  static func capturePolicy(for element: AgentElement, presentation: NotebookElementPresentation,
    pageSize: PageSize, renderingScale: Double, displayScale: Double) -> AgentSnapshotPolicy {
    let body = CGRect(origin: .zero, size: presentation.bodySize)
    let region = CGRect(x: 0, y: 0, width: pageSize.width, height: pageSize.height)
      .applying(presentation.placement.transform.inverted()).intersection(body)
    let density = renderingScale * displayScale * presentation.maximumScale
    if region == body { return .exact(scale: density) }
    return .region(.init(x: region.minX, y: region.minY, width: region.width, height: region.height), scale: density)
  }

  /// The accepted read window submits this demand before scene composition.
  /// A later mount supplies installation callbacks through bindPresentation.
  func prepare(page: PageDocument, model: NotebookAppModel, renderingScale: Double, displayScale: Double,
    allowsInteraction: Bool, inputEnabled: Bool, visibleRegion: CGRect?, activity: PageTurnActivity?, rasterPreparation: PageRasterPreparation.Context?,
    cohort: SceneCompositionCohort?) {
    guard !isRetired, renderingScale > 0, displayScale > 0 else { return }
    let next = PageDemand(model: ObjectIdentifier(model), pageID: page.id, elements: page.elementSourceIdentity,
      size: page.size, renderingScale: renderingScale, displayScale: displayScale,
      allowsInteraction: allowsInteraction, inputEnabled: inputEnabled, focus: model.interactiveElementFocus,
      permitsPreparation: model.permitsPagePreparation, pageIndex: rasterPreparation?.pageIndex, visibleRegion: visibleRegion)
    // The host can be reconfigured on a camera/layout sample. Its immutable
    // page identity and capture policy make those samples constant work.
    // Local preview changes are still delivered by the mounted physical shell.
    guard accepted != next else { return }
    NotebookNavigationObservation.webPreparation("page_preparation_accepted", ownerID: page.id, sourceID: page.id.uuidString)
    accepted = next; acceptedPage = page
    if let pageID, pageID != page.id { removeAll(afterUpdate: true) }
    pageID = page.id
    let display = model.pageGraphicDisplay(page, in: visibleRegion)
    let sources = display.elements.filter { $0.graphic == nil && $0.kind != .nativeText }
    let kept = Set(sources.map(\.id))
    for id in Array(elements.keys) where !kept.contains(id) { elements.removeValue(forKey: id)?.retire(afterUpdate: true) }
    for source in sources {
      let focus = InteractiveElementReference.page(pageID: page.id, elementID: source.id)
      guard let presentation = model.elementPresentation(.page(pageID: page.id, elementID: source.id), graph: display.graph) else { continue }
      let element = agentElementSnapshotSource(source)
      // A moving/unmounted item's visible slice is not yet known. Its native
      // viewport will accept live demand; do not invent a whole-page runtime
      // membership merely to start earlier.
      if element.requiresLiveRuntime, visibleRegion == nil { continue }
      let focused = model.interactiveElementFocus == focus
      let active = allowsInteraction && element.requiresLiveRuntime
        && (focused || (source.kind == .web && visibleRegion?.intersects(presentation.bounds) == true))
      let policy = Self.capturePolicy(for: source, presentation: presentation, pageSize: page.size,
        renderingScale: renderingScale, displayScale: displayScale)
      let pageID = page.id, elementID = element.id
      owner(for: source.id).accept(.init(model: model,
        demand: .init(source: element, basis: model.programStateBasis(focus: focus, rendered: element),
          active: active, inputEnabled: inputEnabled, focused: focused,
          permitsPreparation: model.permitsPagePreparation, policy: policy,
          capture: nil, fallbackEntryID: nil, runtimeFailure: nil),
        focus: focus, pageTurnActivity: activity, rasterPreparation: rasterPreparation, cohort: cohort,
        onState: { [weak model] state, completion in
          model?.commitElementState(pageID: pageID, elementID: elementID, state: state, onCommitted: completion) ?? false
        }))
    }
  }

  private func removeAll(afterUpdate: Bool) {
    let previous = elements; elements.removeAll()
    for owner in previous.values { owner.retire(afterUpdate: afterUpdate) }
  }
  func retire(afterUpdate: Bool = false) {
    guard !isRetired else { return }; isRetired = true; removeAll(afterUpdate: afterUpdate)
    accepted = nil; acceptedPage = nil
  }
  isolated deinit { retire() }
}

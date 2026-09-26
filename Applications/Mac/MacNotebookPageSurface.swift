import AppKit
import NotebookCore
import SwiftUI

struct MacNotebookPageSurface: NSViewRepresentable {
  @Environment(NotebookAppModel.self) private var model
  @Environment(\.scenePlaneProjection) private var projection
  let notebookID: UUID
  let displayProjection: Double

  func makeNSView(context: Context) -> MacNotebookPageView { .init(frame: .zero) }
  func updateNSView(_ view: MacNotebookPageView, context: Context) {
    view.update(model: model, notebookID: notebookID, scale: displayProjection, projection: projection)
  }
  static func dismantleNSView(_ view: MacNotebookPageView, coordinator: ()) { view.uninstall() }
}

/// AppKit's bounded reader owns publication, not individual source arrivals.
/// Prepared neighbours remain mounted behind the current opaque paper. A
/// completed page changes z-order once, then acknowledges its model selection.
@MainActor final class MacNotebookPageView: NSView {
  private enum Source: Equatable {
    case missing, blank
    case page(UUID, PageSize, VersionStamp, ObjectIdentifier)
  }
  @MainActor private final class Slot {
    let host = NSHostingView(rootView: AnyView(EmptyView()))
    var source: Source = .missing
    var generation = UUID()
    var ready = false
    var current = false
    var scale = 0.0
    var refinesDetails: Bool?
    var failure: PageTurnPreparationFailure?
  }
  private weak var model: NotebookAppModel?
  private var notebookID: UUID?
  private var root = ""
  private let controllerID = UUID()
  private let activity = PageTurnActivity()
  private var slots: [Int: Slot] = [:]
  private var pageCount = 1
  private var displayed = 0
  private var hasShown = false
  private var pending: Int?
  private var sequentialTarget: Int?
  private var lastDirection: Int?
  private var scale = 1.0
  private var projection: ScenePlaneProjection?
  private var advancing: Task<Void, Never>?
  private var retired = false
  private let loading = NSHostingView(rootView: AnyView(Color.white.overlay { ProgressView("Готовим лист…") }))

  override var isFlipped: Bool { true }
  var presentedPageView: NSView? {
    guard hasShown, let host = slots[displayed]?.host, subviews.last === host else { return nil }
    return host
  }

  override init(frame: NSRect) { super.init(frame: frame); addSubview(loading) }
  required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

  func update(model: NotebookAppModel, notebookID: UUID, scale: Double, projection: ScenePlaneProjection?) {
    guard !retired, let root = model.notebookPageRoot(notebookID) else { return }
    if self.model !== model || self.notebookID != notebookID || self.root != root {
      self.model?.notebookPageNavigation.unbind(controllerID)
      if let old = self.notebookID { self.model?.retainNotebookPageWindow([], in: old, root: self.root) }
      for slot in slots.values { slot.host.removeFromSuperview(); slot.host.rootView = AnyView(EmptyView()) }
      slots.removeAll(); pending = nil; sequentialTarget = nil; lastDirection = nil; hasShown = false
      self.model = model; self.notebookID = notebookID; self.root = root
      displayed = model.workspace?.selectedPageID.flatMap { model.notebookPageIndex($0, in: notebookID) } ?? 0
      addSubview(loading)
    }
    self.scale = scale; self.projection = projection
    pageCount = model.notebookPageCount(notebookID) + 1
    model.notebookPageNavigation.bind(controllerID, ownerID: notebookID, source: root) { [weak self] in
      self?.request($0) ?? false
    }
    refresh(); scheduleAdvance()
  }

  override func layout() {
    super.layout()
    loading.frame = bounds
    for slot in slots.values { slot.host.frame = bounds }
  }
  override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); scheduleAdvance() }
  override func hitTest(_ point: NSPoint) -> NSView? {
    // Covered prewarm programs and ink must never receive a click through an
    // otherwise transparent part of the current physical sheet.
    presentedPageView?.hitTest(convert(point, from: superview))
  }

  private var target: Int? {
    if let pending { return pending }
    guard let sequentialTarget, sequentialTarget != displayed else { return nil }
    return displayed + (sequentialTarget > displayed ? 1 : -1)
  }
  private func request(_ command: NotebookPageNavigation.Command) -> Bool {
    guard !retired, let model, model.presence?.mode == .page,
      model.presence?.focusedItemID == notebookID else { return false }
    switch command {
    case .step(let direction):
      guard direction == -1 || direction == 1 else { return false }
      sequentialTarget = min(pageCount - 1, max(0, (sequentialTarget ?? pending ?? displayed) + direction))
      pending = nil
    case .cancel:
      sequentialTarget = nil; pending = nil
    case .jump(let index):
      guard (0..<pageCount).contains(index) else { return false }
      sequentialTarget = nil; pending = index == displayed ? nil : index
    }
    refresh(); scheduleAdvance()
    return true
  }
  private func source(at index: Int) -> Source {
    guard let model, let notebookID else { return .missing }
    if index == model.notebookPageCount(notebookID) { return .blank }
    guard let page = model.notebookPage(at: index, in: notebookID) else { return .missing }
    return .page(page.id, page.size, page.drawingStamp, page.elementSourceIdentity)
  }
  private func refresh() {
    guard !retired, let model, let notebookID else { return }
    let target = target
    activity.prepare(target, presentation: .live)
    activity.rasters.prioritize(displayed: displayed, target: target)
    let needed = PageTurnPrewarmWindow.indices(displayedIndex: displayed, anticipatedIndex: target,
      lastDirection: lastDirection, pageCount: pageCount, existingIndices: Set(slots.keys))
    model.retainNotebookPageWindow(needed, in: notebookID, root: root, target: target)
    for index in Array(slots.keys) where !needed.contains(index) {
      if let slot = slots.removeValue(forKey: index) {
        slot.host.removeFromSuperview(); slot.host.rootView = AnyView(EmptyView())
      }
    }
    for index in needed.sorted(by: { priority($0) < priority($1) }) {
      let slot: Slot
      if let existing = slots[index] { slot = existing }
      else {
        slot = Slot(); slots[index] = slot
        addSubview(slot.host, positioned: .below, relativeTo: subviews.last)
        slot.host.frame = bounds
      }
      let source = source(at: index), current = hasShown && index == displayed
      let refinesDetails = model.presencePhase == .settled
      guard slot.scale != scale || slot.source != source || slot.current != current
        || slot.refinesDetails != refinesDetails else { continue }
      if slot.source != source { slot.ready = false; slot.failure = nil }
      slot.source = source; slot.scale = scale; slot.current = current; slot.refinesDetails = refinesDetails
      let generation = UUID(); slot.generation = generation
      let readiness = PageTurnReadiness(activity: activity, pageIndex: index,
        onFailure: { [weak self, weak slot] failure in
          guard let self, let slot, self.slots[index] === slot, slot.generation == generation else { return }
          slot.failure = failure; self.scheduleAdvance()
        }) { [weak self, weak slot] ready in
          guard let self, let slot, self.slots[index] === slot, slot.generation == generation else { return }
          slot.ready = ready; if ready { slot.failure = nil }; self.scheduleAdvance()
        }
      slot.host.rootView = AnyView(NotebookPageView(notebookID: notebookID, index: index,
        isCurrent: current, isInteractive: current, isVisible: true,
        onRenderReady: readiness, displayProjection: scale, refinesDetails: refinesDetails)
        .accessibilityHidden(!current).background(Color.white).environment(model).environment(\.scenePlaneProjection, projection))
    }
  }
  private func priority(_ index: Int) -> Int { index == displayed ? 0 : index == target ? 1 : 2 + abs(index - displayed) }

  private func scheduleAdvance() {
    guard !retired, advancing == nil else { return }
    advancing = Task { @MainActor [weak self] in
      guard let self else { return }
      advancing = nil
      advance()
    }
  }
  private func advance() {
    guard !retired, let model, let notebookID else { return }
    let next = hasShown ? target : displayed
    guard let next else {
      model.notebookPageNavigation.report(nil, ownerID: notebookID, controllerID: controllerID, source: root)
      return
    }
    let status = NotebookPageNavigation.Status(ownerID: notebookID, target: next, failure: slots[next]?.failure)
    guard let slot = slots[next], slot.ready, slot.source == source(at: next), window != nil else {
      model.notebookPageNavigation.report(status, ownerID: notebookID, controllerID: controllerID, source: root)
      return
    }
    let expectedRoot = root, generation = slot.generation
    model.inputGate.performAfterIdle { [weak self, weak slot, weak model] in
      guard let self, let slot, let model, !retired, root == expectedRoot, slots[next] === slot,
        slot.generation == generation, slot.ready, slot.source == source(at: next),
        (hasShown ? target : displayed) == next else { return }
      let previous = displayed, hadShown = hasShown
      CATransaction.begin(); CATransaction.setDisableActions(true)
      addSubview(slot.host, positioned: .above, relativeTo: nil)
      loading.removeFromSuperview()
      displayed = next; hasShown = true
      if pending == next { pending = nil }
      if sequentialTarget == next { sequentialTarget = nil }
      lastDirection = previous == next ? lastDirection : (next > previous ? 1 : -1)
      CATransaction.commit()
      if hadShown, next != previous { _ = model.selectNotebookPage(next, notebookID: notebookID, expectedRoot: expectedRoot) }
      activity.didInstall(activity.preparationDemand)
      refresh(); scheduleAdvance()
    }
  }

  func uninstall() {
    guard !retired else { return }; retired = true
    advancing?.cancel(); advancing = nil
    model?.notebookPageNavigation.unbind(controllerID)
    if let notebookID { model?.retainNotebookPageWindow([], in: notebookID, root: root) }
    for slot in slots.values { slot.host.rootView = AnyView(EmptyView()); slot.host.removeFromSuperview() }
    slots.removeAll(); model = nil; activity.prepare(nil)
  }
}

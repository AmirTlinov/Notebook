import NotebookCore
import SwiftUI

#if os(iOS)
import UIKit

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
}

struct PagePresentationView: UIViewRepresentable {
  @Environment(NotebookAppModel.self) private var model
  let page: PageDocument
  let isCurrent: Bool
  let isVisible: Bool
  let isReady: Bool
  let activity: PageTurnActivity?

  func makeUIView(context: Context) -> PagePresentationNativeView { PagePresentationNativeView() }
  func updateUIView(_ view: PagePresentationNativeView, context: Context) {
    view.update(model: model, page: page, isCurrent: isCurrent, isVisible: isVisible,
      isReady: isReady, activity: activity)
  }
  static func dismantleUIView(_ view: PagePresentationNativeView, coordinator: ()) { view.uninstall() }
}

@MainActor
final class PagePresentationNativeView: UIView, NotebookScenePresentationOwner {
  private struct Source: Equatable {
    let id: UUID
    let size: PageSize
    let ink: VersionStamp
    let elements: VersionStamp
    init(_ page: PageDocument) {
      id = page.id; size = page.size; ink = page.drawingStamp; elements = page.agentStamp
    }
  }
  private weak var model: NotebookAppModel?
  private var source: Source?
  private var isCurrent = false
  private var isVisible = false
  private var isReady = false
  private var activity: PageTurnActivity?
  private var retired = false

  init() {
    super.init(frame: .zero)
    isUserInteractionEnabled = false; isOpaque = false; backgroundColor = .clear
    accessibilityElementsHidden = true
  }
  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("Use init()") }

  func update(model: NotebookAppModel, page: PageDocument, isCurrent: Bool,
    isVisible: Bool, isReady: Bool, activity: PageTurnActivity?) {
    guard !retired else { return }
    if self.model !== model {
      self.model?.pagePresentations.remove(self)
      self.model?.unregisterScenePresentation(self)
      self.model = model
      model.pagePresentations.register(self)
      model.registerScenePresentation(self)
    }
    source = Source(page); self.isCurrent = isCurrent; self.isVisible = isVisible
    self.isReady = isReady; self.activity = activity
  }

  func isPresenting(_ page: PageDocument) -> Bool {
    guard !retired, isCurrent, isVisible, isReady, activity?.isTransitioning != true,
      source == Source(page), let window, !window.isHidden, !bounds.isEmpty,
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
    retired = true; source = nil; activity = nil
    model?.pagePresentations.remove(self)
    model?.unregisterScenePresentation(self)
    model = nil
  }
}
#else
struct PagePresentationView: View {
  let page: PageDocument
  let isCurrent: Bool
  let isVisible: Bool
  let isReady: Bool
  let activity: PageTurnActivity?
  var body: some View { Color.clear.accessibilityHidden(true) }
}
#endif

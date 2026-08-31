import SwiftUI
import UIKit

enum PageTurnPlatformContract {
  @MainActor
  static func makePageViewController() -> UIPageViewController {
    let controller = UIPageViewController(
      transitionStyle: .pageCurl,
      navigationOrientation: .horizontal,
      options: [
        .spineLocation: NSNumber(
          value: UIPageViewController.SpineLocation.min.rawValue
        )
      ]
    )
    controller.isDoubleSided = false
    controller.view.backgroundColor = .clear
    return controller
  }
}

/// The iPad executor for `PageTurnSurface`.
///
/// UIKit owns the physical curl. This container owns only page identity:
/// neighbouring live pages are mounted behind the visible page until Metal and
/// WebKit have presented them, then that exact controller is handed to UIKit.
@MainActor
final class IPadPageTurnController: UIViewController,
  UIPageViewControllerDataSource,
  UIPageViewControllerDelegate
{
  private let prewarmView = UIView()
  let pageViewController = PageTurnPlatformContract.makePageViewController()

  private var controllers: [Int: IPadIndexedPageHostingController] = [:]
  private var readyPages: [Int: Bool] = [:]
  private var ownerID: UUID?
  private var pageCount = 1
  private var selectedIndex = 0
  private(set) var displayedIndex = 0
  private var navigationIsEnabled = false
  private var pageIsInteractive = false
  private var canBeginNavigation: @MainActor () -> Bool = { true }
  private var renderPage:
    @MainActor (
      Int,
      Bool,
      PageTurnReadiness
    ) -> AnyView = { _, _, readiness in
      readiness(true)
      return AnyView(EmptyView())
    }
  private var onCommit: @MainActor (Int) -> Void = { _ in }
  private var onTransitioningChange: @MainActor (Bool) -> Void = { _ in }

  private var hasInstalledPage = false
  private var isTransitioning = false
  private var pendingExternalIndex: Int?
  private var pendingModelCommit: (source: Int, target: Int)?
  private var transitionRevision: UInt64 = 0

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear
    view.isOpaque = false
    view.clipsToBounds = true

    prewarmView.backgroundColor = .clear
    prewarmView.isOpaque = false
    prewarmView.isUserInteractionEnabled = false
    prewarmView.accessibilityElementsHidden = true
    view.addSubview(prewarmView)

    addChild(pageViewController)
    view.addSubview(pageViewController.view)
    pageViewController.didMove(toParent: self)
    pageViewController.dataSource = self
    pageViewController.delegate = self

    installDisplayedPage()
    configureSystemGestures()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    prewarmView.frame = view.bounds
    pageViewController.view.frame = view.bounds
    for controller in controllers.values
    where controller.view.superview === prewarmView {
      controller.view.frame = prewarmView.bounds
      controller.view.setNeedsLayout()
      controller.view.layoutIfNeeded()
    }
  }

  func update(
    ownerID: UUID,
    pageCount: Int,
    selectedIndex: Int,
    navigationIsEnabled: Bool,
    pageIsInteractive: Bool,
    canBeginNavigation: @escaping @MainActor () -> Bool,
    page:
      @escaping @MainActor (
        Int,
        Bool,
        PageTurnReadiness
      ) -> AnyView,
    onCommit: @escaping @MainActor (Int) -> Void,
    onTransitioningChange: @escaping @MainActor (Bool) -> Void
  ) {
    let ownerChanged = self.ownerID != ownerID
    self.ownerID = ownerID
    self.pageCount = max(1, pageCount)
    self.selectedIndex = min(max(0, selectedIndex), self.pageCount - 1)
    self.navigationIsEnabled = navigationIsEnabled
    self.pageIsInteractive = pageIsInteractive
    self.canBeginNavigation = canBeginNavigation
    renderPage = page
    self.onCommit = onCommit
    self.onTransitioningChange = onTransitioningChange

    if ownerChanged {
      transitionRevision &+= 1
      setTransitioning(false)
      pendingExternalIndex = nil
      pendingModelCommit = nil
      displayedIndex = self.selectedIndex
      if isViewLoaded { replaceOwnerPages() }
    } else if let pendingModelCommit {
      if self.selectedIndex == pendingModelCommit.target {
        self.pendingModelCommit = nil
        if displayedIndex != self.selectedIndex {
          requestExternalSelection(self.selectedIndex)
        }
      } else if self.selectedIndex != pendingModelCommit.source {
        self.pendingModelCommit = nil
        requestExternalSelection(self.selectedIndex)
      }
    } else if displayedIndex != self.selectedIndex {
      requestExternalSelection(self.selectedIndex)
    }

    guard isViewLoaded else { return }
    retainNeededControllers()
    refreshRenderedPages()
    refreshControllerState()
    configureSystemGestures()
  }

  func pageViewController(
    _ pageViewController: UIPageViewController,
    viewControllerBefore viewController: UIViewController
  ) -> UIViewController? {
    guard navigationIsEnabled,
      let current = viewController as? IPadIndexedPageHostingController
    else { return nil }
    return preparedController(at: current.pageIndex - 1)
  }

  func pageViewController(
    _ pageViewController: UIPageViewController,
    viewControllerAfter viewController: UIViewController
  ) -> UIViewController? {
    guard navigationIsEnabled,
      let current = viewController as? IPadIndexedPageHostingController
    else { return nil }
    return preparedController(at: current.pageIndex + 1)
  }

  func pageViewController(
    _ pageViewController: UIPageViewController,
    willTransitionTo pendingViewControllers: [UIViewController]
  ) {
    let target = pendingViewControllers.first as? IPadIndexedPageHostingController
    guard canBeginNavigation(),
      let target,
      readyPages[target.pageIndex] == true
    else {
      cancelSystemGestures()
      return
    }
    setTransitioning(true)
    refreshControllerState()
  }

  func pageViewController(
    _ pageViewController: UIPageViewController,
    didFinishAnimating finished: Bool,
    previousViewControllers: [UIViewController],
    transitionCompleted completed: Bool
  ) {
    if completed,
      let visible = pageViewController.viewControllers?.first
        as? IPadIndexedPageHostingController
    {
      let source = displayedIndex
      displayedIndex = visible.pageIndex
      if displayedIndex != selectedIndex {
        pendingModelCommit = (source: source, target: displayedIndex)
      }
    } else if let previous = previousViewControllers.first
      as? IPadIndexedPageHostingController
    {
      displayedIndex = previous.pageIndex
    }

    setTransitioning(false)
    retainNeededControllers()
    refreshRenderedPages()
    refreshControllerState()

    if completed, displayedIndex != selectedIndex {
      onCommit(displayedIndex)
    }
    runPendingExternalSelection()
  }

  @objc private func systemGestureChanged(_ gesture: UIGestureRecognizer) {
    guard gesture.state == .began, !canBeginNavigation() else { return }
    gesture.isEnabled = false
    gesture.isEnabled = navigationIsEnabled && pageCount > 1
  }

  private func installDisplayedPage() {
    guard isViewLoaded, !hasInstalledPage else { return }
    hasInstalledPage = true
    let controller = controllerForPage(at: displayedIndex)
    transferToPageViewController(controller)
    pageViewController.setViewControllers(
      [controller],
      direction: .forward,
      animated: false
    )
    retainNeededControllers()
    refreshRenderedPages()
    refreshControllerState()
  }

  private func replaceOwnerPages() {
    guard isViewLoaded else { return }
    let oldControllers = Array(controllers.values)
    controllers.removeAll()
    readyPages.removeAll()
    hasInstalledPage = true

    let controller = controllerForPage(at: displayedIndex)
    transferToPageViewController(controller)
    pageViewController.setViewControllers(
      [controller],
      direction: .forward,
      animated: false
    )
    for oldController in oldControllers where oldController !== controller {
      detachFromPrewarming(oldController)
    }
    retainNeededControllers()
    refreshRenderedPages()
    refreshControllerState()
  }

  private func preparedController(
    at index: Int
  ) -> IPadIndexedPageHostingController? {
    guard index >= 0, index < pageCount else { return nil }
    let controller = controllerForPage(at: index)
    mountForPrewarming(controller)
    guard readyPages[index] == true else { return nil }
    transferToPageViewController(controller)
    return controller
  }

  private func controllerForPage(
    at index: Int
  ) -> IPadIndexedPageHostingController {
    if let controller = controllers[index] { return controller }

    readyPages[index] = false
    let controller = IPadIndexedPageHostingController(
      pageIndex: index,
      rootView: AnyView(EmptyView())
    )
    controller.view.backgroundColor = .clear
    controller.view.accessibilityIdentifier = "page-turn-page-\(index)"
    controllers[index] = controller
    controller.rootView = hostedPage(
      at: index,
      isCurrent: index == displayedIndex,
      hostID: controller.hostID
    )
    controller.loadViewIfNeeded()
    return controller
  }

  private func retainNeededControllers() {
    guard isViewLoaded else { return }
    var required = Set<Int>()
    for index in (displayedIndex - 1)...(displayedIndex + 1)
    where index >= 0 && index < pageCount {
      required.insert(index)
    }
    if let pendingExternalIndex { required.insert(clamped(pendingExternalIndex)) }

    for index in required {
      let controller = controllerForPage(at: index)
      if index != displayedIndex { mountForPrewarming(controller) }
    }

    for index in Array(controllers.keys) where !required.contains(index) {
      guard let controller = controllers[index],
        controller.containmentOwner != .pageViewController,
        controller.parent == nil || controller.parent === self
      else {
        continue
      }
      detachFromPrewarming(controller)
      controllers[index] = nil
      readyPages[index] = nil
    }
  }

  private func mountForPrewarming(
    _ controller: IPadIndexedPageHostingController
  ) {
    guard controller.pageIndex != displayedIndex,
      controller.containmentOwner == .detached,
      controller.parent == nil,
      controller.view.superview !== prewarmView
    else { return }
    controller.containmentOwner = .prewarming
    addChild(controller)
    prewarmView.addSubview(controller.view)
    controller.view.frame = prewarmView.bounds
    controller.view.isUserInteractionEnabled = false
    controller.view.accessibilityElementsHidden = true
    controller.didMove(toParent: self)
    controller.view.setNeedsLayout()
    controller.view.layoutIfNeeded()
  }

  private func refreshRenderedPages() {
    for (index, controller) in controllers {
      controller.rootView = hostedPage(
        at: index,
        isCurrent: index == displayedIndex,
        hostID: controller.hostID
      )
    }
  }

  private func refreshControllerState() {
    for (index, controller) in controllers {
      let isCurrent = index == displayedIndex
      controller.view.accessibilityElementsHidden = !isCurrent
      controller.view.isUserInteractionEnabled =
        isCurrent && pageIsInteractive && !isTransitioning
    }
  }

  private func hostedPage(
    at index: Int,
    isCurrent: Bool,
    hostID: UUID
  ) -> AnyView {
    let readiness = PageTurnReadiness { [weak self] ready in
      self?.setPage(ready: ready, at: index, hostID: hostID)
    }
    return AnyView(
      renderPage(index, isCurrent, readiness)
        .ignoresSafeArea()
    )
  }

  private func setPage(ready: Bool, at index: Int, hostID: UUID) {
    guard controllers[index]?.hostID == hostID else { return }
    guard readyPages[index] != ready else { return }
    readyPages[index] = ready
    guard ready else { return }
    runPendingExternalSelection()
  }

  private func requestExternalSelection(_ requestedIndex: Int) {
    let target = clamped(requestedIndex)
    guard target != displayedIndex else {
      pendingExternalIndex = nil
      return
    }
    pendingExternalIndex = target
    let targetController = controllerForPage(at: target)
    mountForPrewarming(targetController)
    guard isViewLoaded,
      !isTransitioning,
      readyPages[target] == true
    else {
      retainNeededControllers()
      return
    }

    pendingExternalIndex = nil
    transitionRevision &+= 1
    let revision = transitionRevision
    let adjacent = abs(target - displayedIndex) == 1
    let direction: UIPageViewController.NavigationDirection =
      target > displayedIndex ? .forward : .reverse
    setTransitioning(true)
    refreshControllerState()
    transferToPageViewController(targetController)

    if adjacent {
      pageViewController.setViewControllers(
        [targetController],
        direction: direction,
        animated: pageViewController.viewIfLoaded?.window != nil
      ) { [weak self] finished in
        guard let self, transitionRevision == revision else { return }
        completeExternalSelection(target, finished: finished)
      }
    } else {
      UIView.transition(
        with: pageViewController.view,
        duration: 0.14,
        options: [.transitionCrossDissolve, .allowAnimatedContent]
      ) {
        self.pageViewController.setViewControllers(
          [targetController],
          direction: direction,
          animated: false
        )
      } completion: { [weak self] finished in
        guard let self, transitionRevision == revision else { return }
        completeExternalSelection(target, finished: finished)
      }
    }
  }

  private func completeExternalSelection(_ target: Int, finished: Bool) {
    if finished { displayedIndex = target }
    setTransitioning(false)
    retainNeededControllers()
    refreshRenderedPages()
    refreshControllerState()
    runPendingExternalSelection()
  }

  private func runPendingExternalSelection() {
    guard pendingModelCommit == nil else { return }
    let target = pendingExternalIndex ?? selectedIndex
    guard target != displayedIndex else {
      pendingExternalIndex = nil
      return
    }
    requestExternalSelection(target)
  }

  private func transferToPageViewController(
    _ controller: IPadIndexedPageHostingController
  ) {
    switch controller.containmentOwner {
    case .pageViewController:
      return
    case .prewarming:
      detachFromPrewarming(controller)
    case .detached:
      break
    }
    controller.containmentOwner = .pageViewController
  }

  private func detachFromPrewarming(
    _ controller: IPadIndexedPageHostingController
  ) {
    guard controller.containmentOwner == .prewarming else { return }
    let wasChild = controller.parent === self
    if wasChild { controller.willMove(toParent: nil) }
    controller.view.removeFromSuperview()
    if wasChild { controller.removeFromParent() }
    controller.containmentOwner = .detached
  }

  private func configureSystemGestures() {
    let enabled = navigationIsEnabled && pageCount > 1
    for gesture in pageViewController.gestureRecognizers {
      gesture.allowedTouchTypes = [
        NSNumber(value: UITouch.TouchType.direct.rawValue)
      ]
      gesture.cancelsTouchesInView = true
      if gesture.isEnabled != enabled { gesture.isEnabled = enabled }
      gesture.removeTarget(self, action: #selector(systemGestureChanged))
      gesture.addTarget(self, action: #selector(systemGestureChanged))
    }
  }

  private func cancelSystemGestures() {
    let enabled = navigationIsEnabled && pageCount > 1
    for gesture in pageViewController.gestureRecognizers {
      gesture.isEnabled = false
      gesture.isEnabled = enabled
    }
    setTransitioning(false)
    refreshControllerState()
  }

  private func setTransitioning(_ value: Bool) {
    guard isTransitioning != value else { return }
    isTransitioning = value
    onTransitioningChange(value)
  }

  private func clamped(_ index: Int) -> Int {
    min(max(0, index), max(0, pageCount - 1))
  }

  var cachedPageIdentities: [Int: ObjectIdentifier] {
    controllers.mapValues(ObjectIdentifier.init)
  }

  var visiblePageIdentity: ObjectIdentifier? {
    pageViewController.viewControllers?.first.map(ObjectIdentifier.init)
  }
}

@MainActor
private final class IPadIndexedPageHostingController:
  UIHostingController<AnyView>
{
  let pageIndex: Int
  let hostID = UUID()
  var containmentOwner = IPadPageHostContainmentOwner.detached

  init(pageIndex: Int, rootView: AnyView) {
    self.pageIndex = pageIndex
    super.init(rootView: rootView)
  }

  @available(*, unavailable)
  required init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }
}

private enum IPadPageHostContainmentOwner {
  case detached
  case prewarming
  case pageViewController
}

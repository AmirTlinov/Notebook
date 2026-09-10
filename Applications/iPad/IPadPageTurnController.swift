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

  private var controllers: [Int: IPadIndexedPageController] = [:]
  private var retiredControllers: [Int: WeakIPadPageController] = [:]
  private var readyPages: [Int: Bool] = [:]
  private var ownerID: UUID?
  private var sequenceRevision = ""
  private var pageCount = 1
  private var selectedIndex = 0
  private var selection = PageTurnSelectionTracker(displayedIndex: 0)
  private var allowsTrailingPageCreation = false
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
  private var onCommit: @MainActor (Int, String) -> Void = { _, _ in }
  private var onTransitioningChange: @MainActor (Bool) -> Void = { _ in }

  private var hasInstalledPage = false
  private var isTransitioning = false
  private var isUpdatingContents = false
  private var pendingExternalIndex: Int?
  private var anticipatedIndex: Int?
  private var lastTurnDirection: Int?
  private var transitionRevision: UInt64 = 0
  private var transitionNotificationRevision: UInt64 = 0
  private var transitionNotificationTask: Task<Void, Never>?
  private var publishedTransitionState = false

  var displayedIndex: Int { selection.displayedIndex }

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
    for controller in controllers.values {
      controller.layoutPrewarmingContent(in: prewarmView)
    }
  }

  func update(
    ownerID: UUID,
    sequenceRevision: String,
    pageCount: Int,
    selectedIndex: Int,
    allowsTrailingPageCreation: Bool = false,
    navigationIsEnabled: Bool,
    pageIsInteractive: Bool,
    canBeginNavigation: @escaping @MainActor () -> Bool,
    page:
      @escaping @MainActor (
        Int,
        Bool,
        PageTurnReadiness
      ) -> AnyView,
    onCommit: @escaping @MainActor (Int, String) -> Void,
    onTransitioningChange: @escaping @MainActor (Bool) -> Void
  ) {
    let ownerChanged = self.ownerID != ownerID || self.sequenceRevision != sequenceRevision
    let previousSelectedIndex = self.selectedIndex
    let awaitedLocalAcknowledgement = selection.awaitsLocalAcknowledgement
    self.ownerID = ownerID
    self.sequenceRevision = sequenceRevision
    self.allowsTrailingPageCreation = allowsTrailingPageCreation
    let reportedPageCount = max(1, pageCount)
    self.pageCount =
      !ownerChanged && allowsTrailingPageCreation
        && selection.awaitsLocalAcknowledgement
      ? max(self.pageCount, reportedPageCount)
      : reportedPageCount
    self.selectedIndex = min(max(0, selectedIndex), self.pageCount - 1)
    self.navigationIsEnabled = navigationIsEnabled
    self.pageIsInteractive = pageIsInteractive
    self.canBeginNavigation = canBeginNavigation
    renderPage = page
    self.onCommit = onCommit
    self.onTransitioningChange = onTransitioningChange

    if ownerChanged {
      transitionRevision &+= 1
      setTransitioning(false, resetsPublication: true)
      pendingExternalIndex = nil
      anticipatedIndex = nil
      lastTurnDirection = nil
      selection.reset(to: self.selectedIndex)
      if isViewLoaded { replaceOwnerPages() }
    } else if let target = selection.externalTarget(
      forModelIndex: self.selectedIndex
    ) {
      requestExternalSelection(target)
    } else if previousSelectedIndex != self.selectedIndex,
      !awaitedLocalAcknowledgement,
      isTransitioning || pendingExternalIndex != nil {
      // Returning to the source is also a new external intent. A repeated
      // source index during an ordinary curl, or a local acknowledgement, is not.
      requestExternalSelection(self.selectedIndex)
    }

    guard isViewLoaded else { return }
    retainNeededControllers()
    refreshRenderedPages()
    refreshControllerState()
    configureSystemGestures()
    runPendingExternalSelection()
  }

  func pageViewController(
    _ pageViewController: UIPageViewController,
    viewControllerBefore viewController: UIViewController
  ) -> UIViewController? {
    guard navigationIsEnabled,
      let current = viewController as? IPadIndexedPageController,
      controllers[current.pageIndex] === current
    else { return nil }
    return preparedController(at: current.pageIndex - 1)
  }

  func pageViewController(
    _ pageViewController: UIPageViewController,
    viewControllerAfter viewController: UIViewController
  ) -> UIViewController? {
    guard navigationIsEnabled,
      let current = viewController as? IPadIndexedPageController,
      controllers[current.pageIndex] === current
    else { return nil }
    return preparedController(at: current.pageIndex + 1)
  }

  func pageViewController(
    _ pageViewController: UIPageViewController,
    willTransitionTo pendingViewControllers: [UIViewController]
  ) {
    let target = pendingViewControllers.first as? IPadIndexedPageController
    guard canBeginNavigation(),
      let target,
      controllers[target.pageIndex] === target,
      readyPages[target.pageIndex] == true
    else {
      cancelSystemGestures()
      return
    }
    // UIKit may reuse its cached shell without asking the data source again.
    // Its restored child has earned readiness in prewarm, but is not yet inside
    // that shell. The delegate handoff must install it too.
    transferToPageViewController(target)
    anticipatedIndex = target.pageIndex
    retainNeededControllers()
    setTransitioning(true)
    refreshControllerState()
  }

  func pageViewController(
    _ pageViewController: UIPageViewController,
    didFinishAnimating finished: Bool,
    previousViewControllers: [UIViewController],
    transitionCompleted completed: Bool
  ) {
    guard previousViewControllers.allSatisfy({ old in
      guard let old = old as? IPadIndexedPageController else { return false }
      return controllers[old.pageIndex] === old
    }), let shown = pageViewController.viewControllers?.first as? IPadIndexedPageController,
      controllers[shown.pageIndex] === shown else { return }
    if completed,
      let visible = pageViewController.viewControllers?.first
        as? IPadIndexedPageController
    {
      let source = displayedIndex
      let target = visible.pageIndex
      if target == selectedIndex {
        selection.recordExternalLanding(at: target)
      } else {
        selection.recordLocalLanding(at: target)
      }
      if allowsTrailingPageCreation, target == pageCount - 1,
        pageCount < Int.max
      {
        pageCount += 1
      }
      lastTurnDirection = target == source ? nil : (target > source ? 1 : -1)
    } else if let previous = previousViewControllers.first
      as? IPadIndexedPageController
    {
      if previous.pageIndex != displayedIndex {
        selection.recordExternalLanding(at: previous.pageIndex)
      }
    }
    anticipatedIndex = nil

    setTransitioning(false)
    retainNeededControllers()
    refreshRenderedPages()
    refreshControllerState()

    if completed, displayedIndex != selectedIndex {
      onCommit(displayedIndex, sequenceRevision)
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
    isUpdatingContents = true
    guard let controller = controllerForPage(at: displayedIndex) else { isUpdatingContents = false; return }
    transferToPageViewController(controller)
    pageViewController.setViewControllers(
      [controller],
      direction: .forward,
      animated: false
    )
    isUpdatingContents = false
    retainNeededControllers()
    refreshRenderedPages()
    refreshControllerState()
    runPendingExternalSelection()
  }

  private func replaceOwnerPages() {
    guard isViewLoaded else { return }
    let oldControllers = Array(controllers.values)
    controllers.removeAll()
    retiredControllers.removeAll()
    readyPages.removeAll()
    hasInstalledPage = true
    isUpdatingContents = true

    // UIKit can retain the old shells, but their content must release its
    // resource before the replacement owner creates its first hosting child.
    for oldController in oldControllers {
      retireContent(of: oldController, preservingUIKitIdentity: false)
    }
    guard let controller = controllerForPage(at: displayedIndex) else { isUpdatingContents = false; return }
    transferToPageViewController(controller)
    pageViewController.setViewControllers(
      [controller],
      direction: .forward,
      animated: false
    )
    isUpdatingContents = false
    retainNeededControllers()
    refreshRenderedPages()
    refreshControllerState()
  }

  private func preparedController(
    at index: Int
  ) -> IPadIndexedPageController? {
    guard index >= 0, index < pageCount,
      let controller = controllers[index] else { return nil }
    mountForPrewarming(controller)
    guard readyPages[index] == true else { return nil }
    transferToPageViewController(controller)
    return controller
  }

  private func controllerForPage(
    at index: Int
  ) -> IPadIndexedPageController? {
    if let controller = controllers[index] { return controller }
    guard !isTransitioning, controllers.count < PageTurnPrewarmWindow.capacity else { return nil }
    let wasUpdating = isUpdatingContents
    isUpdatingContents = true
    defer { isUpdatingContents = wasUpdating }

    readyPages[index] = false
    let restored = retiredControllers.removeValue(forKey: index)?.controller
    let controller = restored ?? IPadIndexedPageController(
      pageIndex: index,
      rootView: AnyView(EmptyView())
    )
    if restored != nil { controller.renewContentIdentity() }
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
    // A curl keeps its exact prepared window until UIKit returns both source
    // and landing. External requests replace one index, never add live content.
    guard isViewLoaded, !isTransitioning, !isUpdatingContents else { return }
    isUpdatingContents = true
    defer { isUpdatingContents = false }
    retiredControllers = retiredControllers.filter { $0.value.controller != nil }
    let target = anticipatedIndex ?? pendingExternalIndex.map(clamped)
    let required = PageTurnPrewarmWindow.indices(
      displayedIndex: displayedIndex,
      anticipatedIndex: target,
      lastDirection: lastTurnDirection,
      pageCount: pageCount
    )
    // UIKit may retain a controller after its curl finishes. That identity is
    // not a reason to retain every WebKit/Metal page visited in this document.
    // Keep the live window and the complete in-flight turn; retire only content
    // that neither can display. Never reparent a controller already handed off.
    let visible = Set((pageViewController.viewControllers ?? []).map(ObjectIdentifier.init))
    for index in Array(controllers.keys) where !required.contains(index) {
      guard let controller = controllers[index],
        !visible.contains(ObjectIdentifier(controller))
      else { continue }
      controllers[index] = nil
      readyPages[index] = nil
      retireContent(of: controller)
    }

    // Retire the old window first. The current sheet and requested landing
    // get admission before speculative neighbours, including a shrinking count.
    let ordered = required.sorted {
      let left = $0 == displayedIndex ? 0 : ($0 == target ? 1 : 2)
      let right = $1 == displayedIndex ? 0 : ($1 == target ? 1 : 2)
      return left == right ? $0 < $1 : left < right
    }
    for index in ordered {
      guard let controller = controllerForPage(at: index) else { continue }
      if index != displayedIndex { mountForPrewarming(controller) }
    }
  }

  private func retireContent(
    of controller: IPadIndexedPageController,
    preservingUIKitIdentity: Bool = true
  ) {
    if preservingUIKitIdentity, controller.wasHandedToUIKit {
      retiredControllers[controller.pageIndex] = WeakIPadPageController(controller)
    }
    // The shell can remain in UIKit's private curl cache. Its content is our
    // bounded resource: remove the child, not UIKit's controller identity.
    controller.retireContent()
  }

  private func mountForPrewarming(
    _ controller: IPadIndexedPageController
  ) {
    guard controller.pageIndex != displayedIndex else { return }
    controller.prepareContent(in: self, container: prewarmView)
  }

  private func refreshRenderedPages() {
    let wasUpdating = isUpdatingContents
    isUpdatingContents = true
    defer { isUpdatingContents = wasUpdating }
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
    pendingExternalIndex = target
    guard isViewLoaded, !isTransitioning, !isUpdatingContents else { return }
    guard target != displayedIndex else {
      pendingExternalIndex = nil
      retainNeededControllers()
      return
    }
    retainNeededControllers()
    guard let targetController = controllers[target] else { return }
    mountForPrewarming(targetController)
    guard readyPages[target] == true else { return }

    pendingExternalIndex = nil
    anticipatedIndex = target
    retainNeededControllers()
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
    // A local landing may have published its selection while this external
    // target waited. Confirm the final target without overwriting a newer one.
    let confirmsSelection = finished && pendingExternalIndex == nil && target != selectedIndex
    if finished {
      let source = displayedIndex
      if confirmsSelection { selection.recordLocalLanding(at: target) }
      else { selection.recordExternalLanding(at: target) }
      lastTurnDirection = target > source ? 1 : -1
    }
    anticipatedIndex = nil
    setTransitioning(false)
    retainNeededControllers()
    refreshRenderedPages()
    refreshControllerState()
    if confirmsSelection { onCommit(target, sequenceRevision) }
    runPendingExternalSelection()
  }

  private func runPendingExternalSelection() {
    guard !isTransitioning, !isUpdatingContents,
      !selection.awaitsLocalAcknowledgement else { return }
    let target = pendingExternalIndex ?? selectedIndex
    guard target != displayedIndex else {
      pendingExternalIndex = nil
      return
    }
    requestExternalSelection(target)
  }

  private func transferToPageViewController(
    _ controller: IPadIndexedPageController
  ) {
    controller.installPreparedContent()
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

  private func setTransitioning(_ value: Bool, resetsPublication: Bool = false) {
    guard isTransitioning != value || resetsPublication else { return }
    // UIKit and input admission change in this event. A SwiftUI observer cannot
    // be called from updateUIViewController, which may initiate an external turn.
    isTransitioning = value
    transitionNotificationRevision &+= 1
    let revision = transitionNotificationRevision, owner = ownerID
    transitionNotificationTask?.cancel()
    transitionNotificationTask = Task { @MainActor [weak self] in
      guard let self, !Task.isCancelled, transitionNotificationRevision == revision,
        ownerID == owner else { return }
      transitionNotificationTask = nil
      let current = isTransitioning
      guard publishedTransitionState != current || resetsPublication else { return }
      publishedTransitionState = current
      onTransitioningChange(current)
    }
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

/// UIKit owns this shell for its entire curl lifetime. The separately owned
/// hosting child can be retired and prepared again without reparenting the shell.
@MainActor
private final class IPadIndexedPageController: UIViewController {
  let pageIndex: Int
  private(set) var hostID = UUID()
  private(set) var wasHandedToUIKit = false
  private var content: UIHostingController<AnyView>?

  var rootView: AnyView {
    get { content?.rootView ?? AnyView(EmptyView()) }
    set {
      if let content {
        content.rootView = newValue
      } else {
        let host = UIHostingController(rootView: newValue)
        host.view.backgroundColor = .clear
        content = host
      }
    }
  }

  init(pageIndex: Int, rootView: AnyView) {
    self.pageIndex = pageIndex
    super.init(nibName: nil, bundle: nil)
    self.rootView = rootView
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear
    view.isOpaque = false
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    if let content, content.parent === self { content.view.frame = view.bounds }
  }

  func renewContentIdentity() { hostID = UUID() }

  /// A newly created hosting child needs a real visible window to run SwiftUI
  /// tasks and produce its WebKit/Metal frame. The retired UIKit shell does not.
  func prepareContent(in owner: UIViewController, container: UIView) {
    guard let content, content.parent == nil else { return }
    owner.addChild(content)
    container.addSubview(content.view)
    content.view.frame = container.bounds
    content.view.isUserInteractionEnabled = false
    content.view.accessibilityElementsHidden = true
    content.didMove(toParent: owner)
    container.setNeedsLayout()
    content.view.setNeedsLayout()
  }

  func layoutPrewarmingContent(in container: UIView) {
    guard let content, content.view.superview === container else { return }
    content.view.frame = container.bounds
  }

  /// Transfer the already rendered child exactly once. An existing live child
  /// stays inside its UIKit shell, including while UIKit caches the neighbour.
  func installPreparedContent() {
    wasHandedToUIKit = true
    guard let content, content.parent !== self else { return }
    detach(content)
    loadViewIfNeeded()
    addChild(content)
    view.addSubview(content.view)
    content.view.frame = view.bounds
    content.view.isUserInteractionEnabled = true
    content.view.accessibilityElementsHidden = false
    content.didMove(toParent: self)
    view.setNeedsLayout()
  }

  func retireContent() {
    guard let content else { return }
    detach(content)
    self.content = nil
  }

  private func detach(_ content: UIViewController) {
    let hasParent = content.parent != nil
    if hasParent { content.willMove(toParent: nil) }
    content.view.removeFromSuperview()
    if hasParent { content.removeFromParent() }
  }

  @available(*, unavailable)
  required init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }
}

/// UIKit, not this registry, retains shells handed to a curl.
@MainActor
private final class WeakIPadPageController {
  weak var controller: IPadIndexedPageController?

  init(_ controller: IPadIndexedPageController) {
    self.controller = controller
  }
}

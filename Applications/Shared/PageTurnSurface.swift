import SwiftUI

#if os(iOS)
  import UIKit
#elseif os(macOS)
  import AppKit
  import QuartzCore
#endif

/// The only owner of a page turn. Notebook and document code provide pages and
/// accept a completed selection; they never animate a page themselves.
///
/// The UIKit bridge follows the thin container pattern from Pages. The AppKit
/// surface follows Flipbook's staging, depth-cue and velocity-carrying pattern.
/// Their MIT licenses live in docs/licenses.
struct PageTurnSurface: View {
  let ownerID: UUID
  let pageCount: Int
  let selectedIndex: Int
  let navigationIsEnabled: Bool
  let pageIsInteractive: Bool
  let canBeginNavigation: @MainActor () -> Bool
  let page: @MainActor (_ index: Int, _ isCurrent: Bool) -> AnyView
  let onCommit: @MainActor (Int) -> Void
  let onTransitioningChange: @MainActor (Bool) -> Void

  var body: some View {
    PlatformPageTurnSurface(
      ownerID: ownerID,
      pageCount: max(1, pageCount),
      selectedIndex: min(max(0, selectedIndex), max(0, pageCount - 1)),
      navigationIsEnabled: navigationIsEnabled,
      pageIsInteractive: pageIsInteractive,
      canBeginNavigation: canBeginNavigation,
      page: page,
      onCommit: onCommit,
      onTransitioningChange: onTransitioningChange
    )
    .accessibilityIdentifier("page-turn-surface")
    .accessibilityValue("Страница \(selectedIndex + 1) из \(max(1, pageCount))")
  }
}

#if os(iOS)
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

  private struct PlatformPageTurnSurface: UIViewControllerRepresentable {
    let ownerID: UUID
    let pageCount: Int
    let selectedIndex: Int
    let navigationIsEnabled: Bool
    let pageIsInteractive: Bool
    let canBeginNavigation: @MainActor () -> Bool
    let page: @MainActor (Int, Bool) -> AnyView
    let onCommit: @MainActor (Int) -> Void
    let onTransitioningChange: @MainActor (Bool) -> Void

    func makeCoordinator() -> Coordinator {
      Coordinator(surface: self)
    }

    func makeUIViewController(context: Context) -> UIPageViewController {
      let controller = PageTurnPlatformContract.makePageViewController()
      context.coordinator.attach(to: controller)
      return controller
    }

    func updateUIViewController(
      _ controller: UIPageViewController,
      context: Context
    ) {
      context.coordinator.update(from: self)
    }

    @MainActor
    final class Coordinator: NSObject,
      UIPageViewControllerDataSource,
      UIPageViewControllerDelegate
    {
      private weak var pageViewController: UIPageViewController?
      private var controllers: [Int: IndexedPageHostingController] = [:]
      private var ownerID: UUID
      private var pageCount: Int
      private var selectedIndex: Int
      private var displayedIndex: Int
      private var navigationIsEnabled: Bool
      private var pageIsInteractive: Bool
      private var canBeginNavigation: @MainActor () -> Bool
      private var renderPage: @MainActor (Int, Bool) -> AnyView
      private var onCommit: @MainActor (Int) -> Void
      private var onTransitioningChange: @MainActor (Bool) -> Void
      private var isTransitioning = false
      private var pendingExternalIndex: Int?
      private var pendingModelCommit: (source: Int, target: Int)?
      private var transitionRevision: UInt64 = 0

      init(surface: PlatformPageTurnSurface) {
        ownerID = surface.ownerID
        pageCount = surface.pageCount
        selectedIndex = surface.selectedIndex
        displayedIndex = surface.selectedIndex
        navigationIsEnabled = surface.navigationIsEnabled
        pageIsInteractive = surface.pageIsInteractive
        canBeginNavigation = surface.canBeginNavigation
        renderPage = surface.page
        onCommit = surface.onCommit
        onTransitioningChange = surface.onTransitioningChange
      }

      func attach(to controller: UIPageViewController) {
        pageViewController = controller
        controller.dataSource = self
        controller.delegate = self
        let initial = controllerForPage(at: displayedIndex)
        controller.setViewControllers(
          [initial],
          direction: .forward,
          animated: false
        )
        configureSystemGestures()
        retainNearbyControllers()
        refreshControllers()
      }

      func update(from surface: PlatformPageTurnSurface) {
        let ownerChanged = ownerID != surface.ownerID
        ownerID = surface.ownerID
        pageCount = max(1, surface.pageCount)
        selectedIndex = clamped(surface.selectedIndex)
        navigationIsEnabled = surface.navigationIsEnabled
        pageIsInteractive = surface.pageIsInteractive
        canBeginNavigation = surface.canBeginNavigation
        renderPage = surface.page
        onCommit = surface.onCommit
        onTransitioningChange = surface.onTransitioningChange

        if ownerChanged {
          transitionRevision &+= 1
          setTransitioning(false)
          pendingExternalIndex = nil
          pendingModelCommit = nil
          controllers.removeAll()
          displayedIndex = selectedIndex
          if let pageViewController {
            pageViewController.setViewControllers(
              [controllerForPage(at: displayedIndex)],
              direction: .forward,
              animated: false
            )
          }
        } else if let pendingModelCommit {
          if selectedIndex == pendingModelCommit.target {
            self.pendingModelCommit = nil
            if displayedIndex != selectedIndex {
              presentExternalSelection(selectedIndex)
            }
          } else if selectedIndex != pendingModelCommit.source {
            self.pendingModelCommit = nil
            presentExternalSelection(selectedIndex)
          }
        } else if displayedIndex != selectedIndex {
          presentExternalSelection(selectedIndex)
        }

        controllers = controllers.filter { $0.key < pageCount }
        retainNearbyControllers()
        refreshControllers()
        configureSystemGestures()
      }

      func pageViewController(
        _ pageViewController: UIPageViewController,
        viewControllerBefore viewController: UIViewController
      ) -> UIViewController? {
        guard let current = viewController as? IndexedPageHostingController else {
          return nil
        }
        let index = current.pageIndex - 1
        return index >= 0 ? controllerForPage(at: index) : nil
      }

      func pageViewController(
        _ pageViewController: UIPageViewController,
        viewControllerAfter viewController: UIViewController
      ) -> UIViewController? {
        guard let current = viewController as? IndexedPageHostingController else {
          return nil
        }
        let index = current.pageIndex + 1
        return index < pageCount ? controllerForPage(at: index) : nil
      }

      func pageViewController(
        _ pageViewController: UIPageViewController,
        willTransitionTo pendingViewControllers: [UIViewController]
      ) {
        guard canBeginNavigation() else {
          cancelSystemGestures()
          return
        }
        setTransitioning(true)
        refreshControllers()
      }

      func pageViewController(
        _ pageViewController: UIPageViewController,
        didFinishAnimating finished: Bool,
        previousViewControllers: [UIViewController],
        transitionCompleted completed: Bool
      ) {
        if completed,
          let visible = pageViewController.viewControllers?.first
            as? IndexedPageHostingController
        {
          let source = displayedIndex
          displayedIndex = visible.pageIndex
          if displayedIndex != selectedIndex {
            pendingModelCommit = (source: source, target: displayedIndex)
            onCommit(displayedIndex)
          }
        } else if let previous = previousViewControllers.first
          as? IndexedPageHostingController
        {
          displayedIndex = previous.pageIndex
        }
        setTransitioning(false)
        retainNearbyControllers()
        refreshControllers()
        runPendingExternalSelection()
      }

      @objc private func systemGestureChanged(_ gesture: UIGestureRecognizer) {
        guard gesture.state == .began, !canBeginNavigation() else { return }
        gesture.isEnabled = false
        gesture.isEnabled = navigationIsEnabled
      }

      private func configureSystemGestures() {
        guard let pageViewController else { return }
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
        guard let pageViewController else { return }
        let enabled = navigationIsEnabled && pageCount > 1
        for gesture in pageViewController.gestureRecognizers {
          gesture.isEnabled = false
          gesture.isEnabled = enabled
        }
        setTransitioning(false)
      }

      private func controllerForPage(
        at index: Int
      ) -> IndexedPageHostingController {
        if let controller = controllers[index] { return controller }
        let controller = IndexedPageHostingController(
          pageIndex: index,
          rootView: hostedPage(at: index, isCurrent: false)
        )
        controller.view.backgroundColor = .clear
        controller.view.accessibilityIdentifier = "page-turn-page-\(index)"
        controllers[index] = controller
        return controller
      }

      private func refreshControllers() {
        for (index, controller) in controllers {
          let isCurrent = index == displayedIndex
          controller.rootView = hostedPage(at: index, isCurrent: isCurrent)
          controller.view.isUserInteractionEnabled =
            isCurrent
            && pageIsInteractive && !isTransitioning
        }
      }

      private func retainNearbyControllers() {
        guard !isTransitioning else { return }
        let lower = max(0, displayedIndex - 1)
        let upper = min(pageCount - 1, displayedIndex + 1)
        controllers = controllers.filter { lower...upper ~= $0.key }
        if lower <= upper {
          for index in lower...upper {
            controllerForPage(at: index).loadViewIfNeeded()
          }
        }
      }

      private func hostedPage(at index: Int, isCurrent: Bool) -> AnyView {
        AnyView(renderPage(index, isCurrent).ignoresSafeArea())
      }

      private func presentExternalSelection(_ requestedIndex: Int) {
        let target = clamped(requestedIndex)
        guard target != displayedIndex, let pageViewController else { return }
        guard !isTransitioning else {
          pendingExternalIndex = target
          return
        }

        transitionRevision &+= 1
        let revision = transitionRevision
        let adjacent = abs(target - displayedIndex) == 1
        let direction: UIPageViewController.NavigationDirection =
          target > displayedIndex ? .forward : .reverse
        let targetController = controllerForPage(at: target)
        setTransitioning(true)
        refreshControllers()

        if adjacent {
          pageViewController.setViewControllers(
            [targetController],
            direction: direction,
            animated: true
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
            pageViewController.setViewControllers(
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
        retainNearbyControllers()
        refreshControllers()
        runPendingExternalSelection()
      }

      private func runPendingExternalSelection() {
        Task { @MainActor [weak self] in
          guard let self else { return }
          guard pendingModelCommit == nil else { return }
          let target = pendingExternalIndex ?? selectedIndex
          pendingExternalIndex = nil
          if target != displayedIndex { presentExternalSelection(target) }
        }
      }

      private func setTransitioning(_ value: Bool) {
        guard isTransitioning != value else { return }
        isTransitioning = value
        onTransitioningChange(value)
      }

      private func clamped(_ index: Int) -> Int {
        min(max(0, index), max(0, pageCount - 1))
      }
    }
  }

  @MainActor
  private final class IndexedPageHostingController:
    UIHostingController<AnyView>
  {
    let pageIndex: Int

    init(pageIndex: Int, rootView: AnyView) {
      self.pageIndex = pageIndex
      super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
      fatalError("init(coder:) is not supported")
    }
  }
#elseif os(macOS)
  private struct PlatformPageTurnSurface: NSViewRepresentable {
    let ownerID: UUID
    let pageCount: Int
    let selectedIndex: Int
    let navigationIsEnabled: Bool
    let pageIsInteractive: Bool
    let canBeginNavigation: @MainActor () -> Bool
    let page: @MainActor (Int, Bool) -> AnyView
    let onCommit: @MainActor (Int) -> Void
    let onTransitioningChange: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> MacPageTurnView {
      let view = MacPageTurnView()
      update(view)
      return view
    }

    func updateNSView(_ view: MacPageTurnView, context: Context) {
      update(view)
    }

    private func update(_ view: MacPageTurnView) {
      view.update(
        ownerID: ownerID,
        pageCount: pageCount,
        selectedIndex: selectedIndex,
        navigationIsEnabled: navigationIsEnabled,
        pageIsInteractive: pageIsInteractive,
        canBeginNavigation: canBeginNavigation,
        page: page,
        onCommit: onCommit,
        onTransitioningChange: onTransitioningChange
      )
    }
  }

  enum MacPageTurnDecision {
    static let commitProgress: CGFloat = 0.34
    static let projectionDuration: CGFloat = 0.20

    static func commits(progress: CGFloat, velocity: CGFloat) -> Bool {
      progress + velocity * projectionDuration >= commitProgress
    }
  }

  /// AppKit counterpart of UIKit's page container. This view owns input,
  /// progress, settling and commit for every kind of page. Its layer structure
  /// follows Flipbook's useful lesson: stage faces first, then animate one
  /// transform and its two depth cues in the same transaction.
  @MainActor
  final class MacPageTurnView: NSView {
    private enum TurnState {
      case idle
      case pending(delta: CGFloat)
      case dragging(forward: Bool)
      case settling(forward: Bool)
    }

    private let restingHost = NSHostingView(rootView: AnyView(EmptyView()))
    private let baseHost = NSHostingView(rootView: AnyView(EmptyView()))
    private let movingContainer = NSView()
    private let movingHost = NSHostingView(rootView: AnyView(EmptyView()))
    private let verso = PageVersoView()
    private let movingShade = PageGradientView()
    private let castShadow = PageGradientView()

    private var ownerID: UUID?
    private var pageCount = 1
    private var selectedIndex = 0
    private(set) var displayedIndex = 0
    private var navigationIsEnabled = false
    private var pageIsInteractive = false
    private var canBeginNavigation: @MainActor () -> Bool = { true }
    private var renderPage: @MainActor (Int, Bool) -> AnyView = { _, _ in
      AnyView(EmptyView())
    }
    private var onCommit: @MainActor (Int) -> Void = { _ in }
    private var onTransitioningChange: @MainActor (Bool) -> Void = { _ in }

    private var state = TurnState.idle
    private var progress: CGFloat = 0
    private var velocity: CGFloat = 0
    private var lastTimestamp: TimeInterval = 0
    private var pendingExternalIndex: Int?
    private var pendingModelCommit: (source: Int, target: Int)?
    private var eventMonitor: Any?
    private var syntheticEndTask: Task<Void, Never>?
    private var transitionRevision: UInt64 = 0
    private var consumesMomentum = false

    override init(frame frameRect: NSRect) {
      super.init(frame: frameRect)
      wantsLayer = true
      layer?.backgroundColor = NSColor.clear.cgColor
      layer?.masksToBounds = true

      for view in [
        restingHost, baseHost, movingContainer, movingHost, verso,
        movingShade, castShadow,
      ] {
        view.wantsLayer = true
      }
      restingHost.layer?.backgroundColor = NSColor.clear.cgColor
      baseHost.layer?.backgroundColor = NSColor.clear.cgColor
      movingContainer.layer = CATransformLayer()
      movingContainer.layer?.backgroundColor = NSColor.clear.cgColor
      movingHost.layer?.backgroundColor = NSColor.clear.cgColor
      movingHost.layer?.isDoubleSided = false
      movingShade.layer?.isDoubleSided = false
      verso.layer?.isDoubleSided = false

      movingContainer.addSubview(movingHost)
      movingContainer.addSubview(movingShade)
      movingContainer.addSubview(verso)
      addSubview(baseHost)
      addSubview(castShadow)
      addSubview(movingContainer)
      addSubview(restingHost)

      baseHost.isHidden = true
      castShadow.isHidden = true
      movingContainer.isHidden = true
      configureGradients()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) is not supported")
    }

    isolated deinit {
      if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
      syntheticEndTask?.cancel()
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      installEventMonitor()
    }

    override func layout() {
      super.layout()
      for view in [restingHost, baseHost, castShadow, movingContainer] {
        view.frame = bounds
      }
      for view in [movingHost, movingShade, verso] {
        view.frame = movingContainer.bounds
      }
      var perspective = CATransform3DIdentity
      perspective.m34 = -1 / max(1_200, bounds.width * 1.8)
      layer?.sublayerTransform = perspective
      apply(progress: progress, forward: currentDirection)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
      guard pageIsInteractive, case .idle = state else { return nil }
      return super.hitTest(point)
    }

    func update(
      ownerID: UUID,
      pageCount: Int,
      selectedIndex: Int,
      navigationIsEnabled: Bool,
      pageIsInteractive: Bool,
      canBeginNavigation: @escaping @MainActor () -> Bool,
      page: @escaping @MainActor (Int, Bool) -> AnyView,
      onCommit: @escaping @MainActor (Int) -> Void,
      onTransitioningChange: @escaping @MainActor (Bool) -> Void
    ) {
      let ownerChanged = self.ownerID != ownerID
      self.ownerID = ownerID
      self.pageCount = max(1, pageCount)
      self.selectedIndex = clamped(selectedIndex)
      self.navigationIsEnabled = navigationIsEnabled
      self.pageIsInteractive = pageIsInteractive
      self.canBeginNavigation = canBeginNavigation
      renderPage = page
      self.onCommit = onCommit
      self.onTransitioningChange = onTransitioningChange

      if ownerChanged {
        transitionRevision &+= 1
        state = .idle
        pendingExternalIndex = nil
        pendingModelCommit = nil
        displayedIndex = self.selectedIndex
        resetLayers()
      } else if let pendingModelCommit {
        if self.selectedIndex == pendingModelCommit.target {
          self.pendingModelCommit = nil
          if displayedIndex != self.selectedIndex {
            presentExternalSelection(self.selectedIndex)
          }
        } else if self.selectedIndex != pendingModelCommit.source {
          self.pendingModelCommit = nil
          presentExternalSelection(self.selectedIndex)
        }
      } else if displayedIndex != self.selectedIndex {
        presentExternalSelection(self.selectedIndex)
      }
      if case .idle = state { showRestingPage() }
    }

    private var currentDirection: Bool {
      switch state {
      case .dragging(let forward), .settling(let forward): forward
      case .idle, .pending: true
      }
    }

    private func configureGradients() {
      movingShade.gradient.colors = [
        NSColor.black.withAlphaComponent(0.36).cgColor,
        NSColor.black.withAlphaComponent(0.015).cgColor,
      ]
      movingShade.gradient.startPoint = CGPoint(x: 0, y: 0.5)
      movingShade.gradient.endPoint = CGPoint(x: 1, y: 0.5)
      movingShade.gradient.opacity = 0
      verso.shade.opacity = 0

      castShadow.gradient.colors = [
        NSColor.black.withAlphaComponent(0.40).cgColor,
        NSColor.black.withAlphaComponent(0.12).cgColor,
        NSColor.clear.cgColor,
      ]
      castShadow.gradient.startPoint = CGPoint(x: 0, y: 0.5)
      castShadow.gradient.endPoint = CGPoint(x: 1, y: 0.5)
      castShadow.gradient.opacity = 0
    }

    private func installEventMonitor() {
      if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
      eventMonitor = nil
      guard let window else { return }
      eventMonitor = NSEvent.addLocalMonitorForEvents(
        matching: [.scrollWheel, .keyDown]
      ) { [weak self, weak window] event in
        guard let self, let window, event.window === window else { return event }
        return self.handle(event)
      }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
      guard navigationIsEnabled else { return event }

      if event.type == .keyDown {
        guard !isEditingText(in: window?.firstResponder) else { return event }
        if event.keyCode == 123, displayedIndex > 0 {
          startProgrammaticTurn(to: displayedIndex - 1, notifies: true)
          return nil
        }
        if event.keyCode == 124, displayedIndex + 1 < pageCount {
          startProgrammaticTurn(to: displayedIndex + 1, notifies: true)
          return nil
        }
        return event
      }

      let local = convert(event.locationInWindow, from: nil)
      guard bounds.contains(local) else { return event }
      guard event.hasPreciseScrollingDeltas else { return event }
      // AppKit reports the content scroll direction. The page follows the
      // fingers, so the physical translation has the opposite sign.
      let horizontal = -event.scrollingDeltaX
      let vertical = -event.scrollingDeltaY
      let momentum = !event.momentumPhase.isEmpty
      if momentum {
        guard consumesMomentum || ownsTurn else { return event }
        if ownsTurn { endGesture() }
        if event.momentumPhase.contains(.ended)
          || event.momentumPhase.contains(.cancelled)
        {
          consumesMomentum = false
        }
        return nil
      }

      if event.phase.contains(.began) {
        guard canBeginNavigation() else { return event }
        beginGesture()
      }
      let horizontalOwns =
        ownsTurn
        || (abs(horizontal) > 0.05 && abs(horizontal) > abs(vertical))
      guard horizontalOwns else { return event }
      moveGesture(
        deltaX: horizontal,
        deltaY: vertical,
        timestamp: event.timestamp
      )
      if event.phase.contains(.cancelled) {
        settle(commits: false)
      } else if event.phase.contains(.ended) {
        endGesture()
        consumesMomentum = true
      } else {
        scheduleSyntheticEnd()
      }
      return nil
    }

    private var ownsTurn: Bool {
      switch state {
      case .idle: false
      case .pending, .dragging, .settling: true
      }
    }

    private func beginGesture() {
      switch state {
      case .settling(let forward):
        interruptSettlement(forward: forward)
      case .idle:
        state = .pending(delta: 0)
        progress = 0
      case .pending, .dragging:
        break
      }
      velocity = 0
      lastTimestamp = 0
    }

    private func moveGesture(
      deltaX: CGFloat,
      deltaY: CGFloat,
      timestamp: TimeInterval
    ) {
      switch state {
      case .idle:
        beginGesture()
        moveGesture(deltaX: deltaX, deltaY: deltaY, timestamp: timestamp)
      case .pending(let accumulated):
        let total = accumulated + deltaX
        guard abs(total) > 4 else {
          state = .pending(delta: total)
          return
        }
        guard abs(deltaY) <= abs(total) * 2 else {
          state = .idle
          return
        }
        beginDragging(forward: total < 0, initialDelta: total)
        lastTimestamp = timestamp
      case .dragging(let forward):
        let previous = progress
        let delta =
          -deltaX / max(bounds.width, 1)
          * (forward ? 1 : -1)
        progress = min(max(progress + delta, 0), 1)
        if lastTimestamp > 0, timestamp > lastTimestamp {
          let sample = (progress - previous) / CGFloat(timestamp - lastTimestamp)
          velocity = velocity * 0.72 + sample * 0.28
        }
        lastTimestamp = timestamp
        apply(progress: progress, forward: forward)
      case .settling:
        break
      }
    }

    private func beginDragging(forward: Bool, initialDelta: CGFloat) {
      let target = displayedIndex + (forward ? 1 : -1)
      guard target >= 0, target < pageCount else {
        state = .idle
        return
      }
      state = .dragging(forward: forward)
      progress = min(
        max(-initialDelta / max(bounds.width, 1) * (forward ? 1 : -1), 0),
        1
      )
      stage(forward: forward)
      apply(progress: progress, forward: forward)
      onTransitioningChange(true)
    }

    private func stage(forward: Bool) {
      let target = displayedIndex + (forward ? 1 : -1)
      let baseIndex = forward ? target : displayedIndex
      let movingIndex = forward ? displayedIndex : target
      baseHost.rootView = renderPage(baseIndex, false)
      movingHost.rootView = renderPage(movingIndex, false)
      restingHost.isHidden = true
      baseHost.isHidden = false
      castShadow.isHidden = false
      movingContainer.isHidden = false
    }

    private func apply(progress: CGFloat, forward: Bool) {
      guard !movingContainer.isHidden else { return }
      let value = min(max(progress, 0), 1)
      let angle = forward ? -.pi * value : -.pi * (1 - value)
      let lift = sin(value * .pi)
      let layer = movingContainer.layer
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      layer?.anchorPoint = CGPoint(x: 0, y: 0.5)
      layer?.position = CGPoint(x: 0, y: bounds.midY)
      layer?.transform = CATransform3DMakeRotation(angle, 0, 1, 0)
      movingShade.gradient.opacity = Float(min(value * 2, 1) * lift * 0.82)
      verso.shade.opacity = Float(min((1 - value) * 2, 1) * lift * 0.82)
      castShadow.gradient.opacity = Float(lift * 0.92)
      CATransaction.commit()
    }

    private func endGesture() {
      switch state {
      case .pending:
        state = .idle
      case .dragging:
        settle(
          commits: MacPageTurnDecision.commits(
            progress: progress,
            velocity: velocity
          ))
      case .idle, .settling:
        break
      }
    }

    private func settle(commits: Bool, notifies: Bool = true) {
      guard case .dragging(let forward) = state,
        let layer = movingContainer.layer
      else { return }
      state = .settling(forward: forward)
      transitionRevision &+= 1
      let revision = transitionRevision
      let target: CGFloat = commits ? 1 : 0
      let targetAngle = forward ? -.pi * target : -.pi * (1 - target)
      let finalTransform = CATransform3DMakeRotation(targetAngle, 0, 1, 0)
      let spring = CASpringAnimation(keyPath: "transform")
      spring.fromValue = layer.presentation()?.transform ?? layer.transform
      spring.toValue = finalTransform
      spring.damping = 32
      spring.stiffness = 260
      spring.mass = 1
      let remaining = abs(target - progress)
      if remaining > 0.01 {
        let carried = commits ? max(velocity, 0) : max(-velocity, 0)
        spring.initialVelocity = min(carried / remaining, 12)
      }
      spring.duration = spring.settlingDuration

      CATransaction.begin()
      CATransaction.setCompletionBlock { [weak self] in
        guard let self, transitionRevision == revision else { return }
        finish(forward: forward, commits: commits, notifies: notifies)
      }
      layer.add(spring, forKey: "page-settle")
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      layer.transform = finalTransform
      CATransaction.commit()
      CATransaction.setAnimationDuration(min(spring.settlingDuration, 0.55))
      movingShade.gradient.opacity = 0
      verso.shade.opacity = 0
      castShadow.gradient.opacity = 0
      CATransaction.commit()
    }

    private func interruptSettlement(forward: Bool) {
      transitionRevision &+= 1
      guard let layer = movingContainer.layer else { return }
      let transform = layer.presentation()?.transform ?? layer.transform
      var angle = atan2(transform.m31, transform.m11)
      if angle > 0 { angle -= 2 * .pi }
      layer.removeAllAnimations()
      progress =
        forward
        ? min(max(-angle / .pi, 0), 1)
        : min(max(1 + angle / .pi, 0), 1)
      state = .dragging(forward: forward)
      apply(progress: progress, forward: forward)
    }

    private func finish(forward: Bool, commits: Bool, notifies: Bool) {
      let source = displayedIndex
      if commits { displayedIndex += forward ? 1 : -1 }
      resetLayers()
      state = .idle
      progress = 0
      velocity = 0
      showRestingPage()
      if commits, notifies {
        pendingModelCommit = (source: source, target: displayedIndex)
      }
      onTransitioningChange(false)
      if commits, notifies {
        onCommit(displayedIndex)
      }
      if let pending = pendingExternalIndex {
        pendingExternalIndex = nil
        presentExternalSelection(pending)
      }
    }

    private func startProgrammaticTurn(to target: Int, notifies: Bool) {
      let target = clamped(target)
      guard target != displayedIndex else { return }
      guard case .idle = state else {
        pendingExternalIndex = target
        return
      }
      guard abs(target - displayedIndex) == 1 else {
        crossfade(to: target)
        if notifies {
          pendingModelCommit = (source: selectedIndex, target: target)
          onCommit(target)
        }
        return
      }
      let forward = target > displayedIndex
      state = .dragging(forward: forward)
      progress = 0.015
      velocity = 2.4
      stage(forward: forward)
      apply(progress: progress, forward: forward)
      onTransitioningChange(true)
      settle(commits: true, notifies: notifies)
    }

    private func presentExternalSelection(_ target: Int) {
      let target = clamped(target)
      guard target != displayedIndex else { return }
      startProgrammaticTurn(to: target, notifies: false)
    }

    private func crossfade(to target: Int) {
      transitionRevision &+= 1
      displayedIndex = clamped(target)
      restingHost.layer?.add(
        {
          let transition = CATransition()
          transition.type = .fade
          transition.duration = 0.14
          return transition
        }(), forKey: "page-crossfade")
      showRestingPage()
    }

    private func showRestingPage() {
      restingHost.rootView = renderPage(displayedIndex, true)
      restingHost.isHidden = false
    }

    private func resetLayers() {
      movingContainer.layer?.removeAllAnimations()
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      movingContainer.layer?.transform = CATransform3DIdentity
      movingShade.gradient.opacity = 0
      verso.shade.opacity = 0
      castShadow.gradient.opacity = 0
      CATransaction.commit()
      baseHost.isHidden = true
      castShadow.isHidden = true
      movingContainer.isHidden = true
      restingHost.isHidden = false
    }

    private func scheduleSyntheticEnd() {
      syntheticEndTask?.cancel()
      syntheticEndTask = Task { [weak self] in
        try? await Task.sleep(for: .milliseconds(80))
        guard !Task.isCancelled, let self, ownsTurn else { return }
        endGesture()
      }
    }

    private func isEditingText(in responder: NSResponder?) -> Bool {
      responder is NSTextView
    }

    private func clamped(_ index: Int) -> Int {
      min(max(0, index), max(0, pageCount - 1))
    }
  }

  @MainActor
  private final class PageGradientView: NSView {
    let gradient = CAGradientLayer()

    override init(frame frameRect: NSRect) {
      super.init(frame: frameRect)
      wantsLayer = true
      layer = gradient
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) is not supported")
    }

    override func layout() {
      super.layout()
      gradient.frame = bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }

  @MainActor
  private final class PageVersoView: NSView {
    let shade = CAGradientLayer()

    override init(frame frameRect: NSRect) {
      super.init(frame: frameRect)
      wantsLayer = true
      layer?.backgroundColor =
        NSColor(
          red: 0.972,
          green: 0.966,
          blue: 0.938,
          alpha: 1
        ).cgColor
      layer?.transform = CATransform3DMakeRotation(.pi, 0, 1, 0)
      shade.colors = [
        NSColor.black.withAlphaComponent(0.36).cgColor,
        NSColor.black.withAlphaComponent(0.015).cgColor,
      ]
      shade.startPoint = CGPoint(x: 1, y: 0.5)
      shade.endPoint = CGPoint(x: 0, y: 0.5)
      shade.opacity = 0
      layer?.addSublayer(shade)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) is not supported")
    }

    override func layout() {
      super.layout()
      shade.frame = bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }
#endif

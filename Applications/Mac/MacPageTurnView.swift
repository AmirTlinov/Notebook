import AppKit
import QuartzCore
import SwiftUI

/// The macOS executor for `PageTurnSurface`.
///
/// Nearby pages remain mounted. A turn reparents the exact live page into the
/// matte transform layer, so WebKit, ink and their opacity never swap owners at
/// the landing frame.
@MainActor
final class MacPageTurnView: NSView {
  private enum TurnState {
    case idle
    case pending(delta: CGFloat)
    case waiting(forward: Bool)
    case dragging(forward: Bool)
    case settling(forward: Bool)
  }

  private let pagesView = NSView()
  private let movingContainer = NSView()
  private let movingShade = MacPageGradientView()
  private let verso = MacPageVersoView()
  private let castShadow = MacPageGradientView()

  private var pageHosts: [Int: NSHostingView<AnyView>] = [:]
  private var pageHostIDs: [Int: UUID] = [:]
  private var readyPages: [Int: Bool] = [:]
  private var ownerID: UUID?
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
  private var onCommit: @MainActor (Int) -> Void = { _ in }
  private var onTransitioningChange: @MainActor (Bool) -> Void = { _ in }

  private var state = TurnState.idle
  private var progress: CGFloat = 0
  private var velocity: CGFloat = 0
  private var lastTimestamp: TimeInterval = 0
  private var movingPageIndex: Int?
  private var pendingGestureIndex: Int?
  private var pendingExternalIndex: Int?
  private var anticipatedIndex: Int?
  private var lastTurnDirection: Int?
  private var eventMonitor: Any?
  private var syntheticEndTask: Task<Void, Never>?
  private var transitionRevision: UInt64 = 0
  private var consumesMomentum = false
  private var isTransitioning = false

  var displayedIndex: Int { selection.displayedIndex }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor
    layer?.masksToBounds = true

    pagesView.wantsLayer = true
    pagesView.layer?.backgroundColor = NSColor.clear.cgColor
    movingContainer.wantsLayer = true
    movingContainer.layer = CATransformLayer()
    movingContainer.layer?.backgroundColor = NSColor.clear.cgColor
    movingShade.layer?.isDoubleSided = false
    verso.layer?.isDoubleSided = false

    movingContainer.addSubview(movingShade)
    movingContainer.addSubview(verso)
    addSubview(pagesView)
    addSubview(castShadow)
    addSubview(movingContainer)

    movingContainer.isHidden = true
    castShadow.isHidden = true
    configureMaterial()
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
    pagesView.frame = bounds
    castShadow.frame = bounds
    movingContainer.frame = bounds
    movingShade.frame = movingContainer.bounds
    verso.frame = movingContainer.bounds
    for host in pageHosts.values where host.superview === pagesView {
      host.frame = pagesView.bounds
    }
    if let movingPageIndex {
      pageHosts[movingPageIndex]?.frame = movingContainer.bounds
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
    onCommit: @escaping @MainActor (Int) -> Void,
    onTransitioningChange: @escaping @MainActor (Bool) -> Void
  ) {
    let ownerChanged = self.ownerID != ownerID
    self.ownerID = ownerID
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
      movingContainer.layer?.removeAllAnimations()
      setTransitioning(false)
      state = .idle
      progress = 0
      pendingExternalIndex = nil
      pendingGestureIndex = nil
      anticipatedIndex = nil
      lastTurnDirection = nil
      selection.reset(to: self.selectedIndex)
      removeAllPageHosts()
      resetStage()
    } else if let target = selection.externalTarget(
      forModelIndex: self.selectedIndex
    ) {
      requestExternalSelection(target)
    }

    removeDistantPageHosts()
    retainNearbyPageHosts()
    refreshPageHosts()
    if case .idle = state { showRestingPage() }
  }

  private var currentDirection: Bool {
    switch state {
    case .waiting(let forward), .dragging(let forward),
      .settling(let forward):
      forward
    case .idle, .pending: true
    }
  }

  private var ownsTurn: Bool {
    switch state {
    case .idle: false
    case .pending, .waiting, .dragging, .settling: true
    }
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
    guard bounds.contains(local), event.hasPreciseScrollingDeltas else {
      return event
    }
    // AppKit reports content scrolling; the paper follows the fingers.
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
      ownsTurn || (abs(horizontal) > 0.05 && abs(horizontal) > abs(vertical))
    guard horizontalOwns else { return event }
    moveGesture(
      deltaX: horizontal,
      deltaY: vertical,
      timestamp: event.timestamp
    )
    if event.phase.contains(.cancelled) {
      cancelGesture()
    } else if event.phase.contains(.ended) {
      endGesture()
      consumesMomentum = true
    } else {
      scheduleSyntheticEnd()
    }
    return nil
  }

  private func beginGesture() {
    switch state {
    case .settling(let forward):
      interruptSettlement(forward: forward)
    case .idle:
      state = .pending(delta: 0)
      progress = 0
      anticipatedIndex = nil
    case .pending, .waiting, .dragging:
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
      let forward = total < 0
      let target = displayedIndex + (forward ? 1 : -1)
      guard target >= 0, target < pageCount else {
        state = .idle
        return
      }
      anticipateTurn(to: target)
      if readyPages[target] == true {
        beginDragging(forward: forward, initialDelta: total)
      } else {
        state = .waiting(forward: forward)
        progress = min(
          max(-total / max(bounds.width, 1) * (forward ? 1 : -1), 0),
          1
        )
        velocity = 0
        setTransitioning(true)
        refreshPageHosts()
      }
      lastTimestamp = timestamp
    case .waiting(let forward):
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
      let target = displayedIndex + (forward ? 1 : -1)
      if readyPages[target] == true { activateWaitingGesture(forward: forward) }
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
    guard target >= 0, target < pageCount, readyPages[target] == true else {
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
    setTransitioning(true)
    refreshPageHosts()
  }

  private func stage(forward: Bool) {
    let target = displayedIndex + (forward ? 1 : -1)
    let baseIndex = forward ? target : displayedIndex
    let movingIndex = forward ? displayedIndex : target
    let base = hostForPage(at: baseIndex)
    let moving = hostForPage(at: movingIndex)

    attachToRestingStack(base)
    attachToRestingStack(moving)
    base.layer?.zPosition = 1
    moving.removeFromSuperview()
    movingContainer.addSubview(
      moving,
      positioned: .below,
      relativeTo: movingShade
    )
    moving.frame = movingContainer.bounds
    moving.layer?.isDoubleSided = false
    movingPageIndex = movingIndex
    movingContainer.isHidden = false
    castShadow.isHidden = false
  }

  private func apply(progress: CGFloat, forward: Bool) {
    guard !movingContainer.isHidden else { return }
    let value = min(max(progress, 0), 1)
    let angle = forward ? -.pi * value : -.pi * (1 - value)
    let lift = sin(value * .pi)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    movingContainer.layer?.anchorPoint = CGPoint(x: 0, y: 0.5)
    movingContainer.layer?.position = CGPoint(x: 0, y: bounds.midY)
    movingContainer.layer?.transform = CATransform3DMakeRotation(
      angle,
      0,
      1,
      0
    )
    movingShade.gradient.opacity = Float(lift * 0.58)
    verso.shade.opacity = Float(lift * 0.46)
    castShadow.gradient.opacity = Float(lift * 0.72)
    CATransaction.commit()
  }

  private func endGesture() {
    switch state {
    case .pending:
      state = .idle
      anticipatedIndex = nil
      retainNearbyPageHosts()
    case .waiting(let forward):
      let target = displayedIndex + (forward ? 1 : -1)
      let commits = PageTurnDecision.commits(
        progress: progress,
        velocity: velocity
      )
      state = .idle
      progress = 0
      velocity = 0
      if commits {
        pendingGestureIndex = target
        runPendingGestureTurn()
      } else {
        anticipatedIndex = nil
        setTransitioning(false)
        retainNearbyPageHosts()
        refreshPageHosts()
        showRestingPage()
      }
    case .dragging:
      settle(
        commits: PageTurnDecision.commits(
          progress: progress,
          velocity: velocity
        )
      )
    case .idle, .settling:
      break
    }
  }

  private func cancelGesture() {
    switch state {
    case .pending:
      state = .idle
      anticipatedIndex = nil
      retainNearbyPageHosts()
    case .waiting:
      state = .idle
      progress = 0
      velocity = 0
      anticipatedIndex = nil
      setTransitioning(false)
      retainNearbyPageHosts()
      refreshPageHosts()
      showRestingPage()
    case .dragging:
      settle(commits: false)
    case .idle, .settling:
      break
    }
  }

  private func activateWaitingGesture(forward: Bool) {
    let waitingProgress = progress
    let waitingVelocity = velocity
    state = .idle
    beginDragging(forward: forward, initialDelta: 0)
    guard case .dragging = state else {
      state = .waiting(forward: forward)
      progress = waitingProgress
      velocity = waitingVelocity
      return
    }
    progress = waitingProgress
    velocity = waitingVelocity
    apply(progress: progress, forward: forward)
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
    spring.damping = 34
    spring.stiffness = 285
    spring.mass = 1
    let remaining = abs(target - progress)
    if remaining > 0.01 {
      let carried = commits ? max(velocity, 0) : max(-velocity, 0)
      spring.initialVelocity = min(carried / remaining, 12)
    }
    spring.duration = min(spring.settlingDuration, 0.50)

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
    fadeMaterialLayers(duration: spring.duration)
    CATransaction.commit()
  }

  private func interruptSettlement(forward: Bool) {
    transitionRevision &+= 1
    guard let layer = movingContainer.layer else { return }
    let transform = layer.presentation()?.transform ?? layer.transform
    var angle = atan2(transform.m31, transform.m11)
    if angle > 0 { angle -= 2 * .pi }
    layer.removeAllAnimations()
    movingShade.gradient.removeAllAnimations()
    verso.shade.removeAllAnimations()
    castShadow.gradient.removeAllAnimations()
    progress =
      forward
      ? min(max(-angle / .pi, 0), 1)
      : min(max(1 + angle / .pi, 0), 1)
    state = .dragging(forward: forward)
    apply(progress: progress, forward: forward)
  }

  private func finish(forward: Bool, commits: Bool, notifies: Bool) {
    let source = displayedIndex
    if commits {
      let target = source + (forward ? 1 : -1)
      if notifies, target != selectedIndex {
        selection.recordLocalLanding(at: target)
      } else {
        selection.recordExternalLanding(at: target)
      }
      if allowsTrailingPageCreation, target == pageCount - 1,
        pageCount < Int.max
      {
        pageCount += 1
      }
      lastTurnDirection = forward ? 1 : -1
    }
    anticipatedIndex = nil
    restoreMovingPage()
    resetStage()
    state = .idle
    progress = 0
    velocity = 0
    removeDistantPageHosts()
    retainNearbyPageHosts()
    refreshPageHosts()
    showRestingPage()
    setTransitioning(false)
    if commits, notifies { onCommit(displayedIndex) }
    runPendingExternalSelection()
  }

  private func requestExternalSelection(_ requestedIndex: Int) {
    let target = clamped(requestedIndex)
    guard target != displayedIndex else {
      pendingExternalIndex = nil
      return
    }
    guard case .idle = state, readyPages[target] == true else {
      pendingExternalIndex = target
      return
    }
    startProgrammaticTurn(to: target, notifies: false)
  }

  private func startProgrammaticTurn(to requestedIndex: Int, notifies: Bool) {
    let target = clamped(requestedIndex)
    guard target != displayedIndex else {
      pendingExternalIndex = nil
      return
    }
    anticipateTurn(to: target)
    guard case .idle = state, readyPages[target] == true else {
      pendingExternalIndex = target
      return
    }
    guard abs(target - displayedIndex) == 1 else {
      crossfade(to: target)
      if notifies {
        selection.recordLocalLanding(at: target)
        onCommit(target)
      }
      return
    }
    let forward = target > displayedIndex
    beginDragging(
      forward: forward,
      initialDelta: forward ? -1 : 1
    )
    guard case .dragging = state else { return }
    progress = 0.012
    velocity = 2.5
    apply(progress: progress, forward: forward)
    settle(commits: true, notifies: notifies)
  }

  private func crossfade(to target: Int) {
    transitionRevision &+= 1
    setTransitioning(true)
    selection.recordExternalLanding(at: clamped(target))
    anticipatedIndex = nil
    lastTurnDirection = nil
    removeDistantPageHosts()
    retainNearbyPageHosts()
    refreshPageHosts()
    let transition = CATransition()
    transition.type = .fade
    transition.duration = 0.14
    pagesView.layer?.add(transition, forKey: "page-crossfade")
    showRestingPage()
    setTransitioning(false)
    runPendingExternalSelection()
  }

  private func runPendingExternalSelection() {
    guard !selection.awaitsLocalAcknowledgement else { return }
    let target = pendingExternalIndex ?? selectedIndex
    guard target != displayedIndex else {
      pendingExternalIndex = nil
      return
    }
    guard readyPages[target] == true else { return }
    pendingExternalIndex = nil
    requestExternalSelection(target)
  }

  private func runPendingGestureTurn() {
    guard let target = pendingGestureIndex,
      case .idle = state,
      readyPages[target] == true
    else { return }
    pendingGestureIndex = nil
    startProgrammaticTurn(to: target, notifies: true)
  }

  private func hostForPage(at index: Int) -> NSHostingView<AnyView> {
    if let host = pageHosts[index] { return host }
    readyPages[index] = false
    let hostID = UUID()
    let host = NSHostingView(rootView: AnyView(EmptyView()))
    host.wantsLayer = true
    host.layer?.backgroundColor = NSColor.clear.cgColor
    pagesView.addSubview(host)
    pageHosts[index] = host
    pageHostIDs[index] = hostID
    host.rootView = hostedPage(
      at: index,
      isCurrent: false,
      hostID: hostID
    )
    return host
  }

  private func retainNearbyPageHosts() {
    for index in retainedPageIndices() {
      let host = hostForPage(at: index)
      if index != movingPageIndex { attachToRestingStack(host) }
      host.frame = pagesView.bounds
    }
  }

  private func removeDistantPageHosts() {
    guard case .idle = state else { return }
    let retained = retainedPageIndices()
    for index in Array(pageHosts.keys) where !retained.contains(index) {
      removePageHost(at: index)
    }
  }

  private func removePageHost(at index: Int) {
    guard let host = pageHosts.removeValue(forKey: index) else { return }
    readyPages[index] = nil
    pageHostIDs[index] = nil
    host.removeFromSuperview()
  }

  private func removeAllPageHosts() {
    for index in Array(pageHosts.keys) { removePageHost(at: index) }
  }

  private func anticipateTurn(to target: Int) {
    anticipatedIndex = target
    retainNearbyPageHosts()
  }

  private func retainedPageIndices() -> Set<Int> {
    var retained = PageTurnPrewarmWindow.indices(
      displayedIndex: displayedIndex,
      anticipatedIndex: anticipatedIndex,
      lastDirection: lastTurnDirection,
      pageCount: pageCount
    )
    if let pendingExternalIndex {
      retained.insert(clamped(pendingExternalIndex))
    }
    if let pendingGestureIndex {
      retained.insert(clamped(pendingGestureIndex))
    }
    return retained
  }

  private func refreshPageHosts() {
    let idle: Bool
    if case .idle = state { idle = true } else { idle = false }
    for (index, host) in pageHosts {
      let isCurrent = index == displayedIndex
      guard let hostID = pageHostIDs[index] else { continue }
      host.rootView = hostedPage(
        at: index,
        isCurrent: idle && isCurrent,
        hostID: hostID
      )
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
    guard pageHostIDs[index] == hostID else { return }
    guard readyPages[index] != ready else { return }
    readyPages[index] = ready
    guard ready else { return }
    if case .waiting(let forward) = state,
      displayedIndex + (forward ? 1 : -1) == index
    {
      activateWaitingGesture(forward: forward)
      return
    }
    runPendingGestureTurn()
    runPendingExternalSelection()
  }

  private func attachToRestingStack(_ host: NSHostingView<AnyView>) {
    guard host.superview !== pagesView else { return }
    host.removeFromSuperview()
    pagesView.addSubview(host)
    host.frame = pagesView.bounds
  }

  private func showRestingPage() {
    restoreMovingPage()
    for (index, host) in pageHosts {
      attachToRestingStack(host)
      host.frame = pagesView.bounds
      host.layer?.zPosition = index == displayedIndex ? 1 : 0
    }
  }

  private func restoreMovingPage() {
    guard let movingPageIndex,
      let host = pageHosts[movingPageIndex]
    else {
      self.movingPageIndex = nil
      return
    }
    host.removeFromSuperview()
    pagesView.addSubview(host)
    host.frame = pagesView.bounds
    self.movingPageIndex = nil
  }

  private func resetStage() {
    movingContainer.layer?.removeAllAnimations()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    movingContainer.layer?.transform = CATransform3DIdentity
    movingShade.gradient.opacity = 0
    verso.shade.opacity = 0
    castShadow.gradient.opacity = 0
    CATransaction.commit()
    movingContainer.isHidden = true
    castShadow.isHidden = true
  }

  private func configureMaterial() {
    movingShade.gradient.colors = [
      NSColor.black.withAlphaComponent(0.14).cgColor,
      NSColor.black.withAlphaComponent(0.01).cgColor,
    ]
    movingShade.gradient.startPoint = CGPoint(x: 0, y: 0.5)
    movingShade.gradient.endPoint = CGPoint(x: 1, y: 0.5)
    movingShade.gradient.opacity = 0

    castShadow.gradient.colors = [
      NSColor.black.withAlphaComponent(0.18).cgColor,
      NSColor.black.withAlphaComponent(0.045).cgColor,
      NSColor.clear.cgColor,
    ]
    castShadow.gradient.startPoint = CGPoint(x: 0, y: 0.5)
    castShadow.gradient.endPoint = CGPoint(x: 1, y: 0.5)
    castShadow.gradient.opacity = 0
  }

  private func fadeMaterialLayers(duration: CFTimeInterval) {
    for layer in [movingShade.gradient, verso.shade, castShadow.gradient] {
      let animation = CABasicAnimation(keyPath: "opacity")
      animation.fromValue = layer.presentation()?.opacity ?? layer.opacity
      animation.toValue = 0
      animation.duration = duration
      layer.add(animation, forKey: "page-material-settle")
      layer.opacity = 0
    }
  }

  private func setTransitioning(_ value: Bool) {
    guard isTransitioning != value else { return }
    isTransitioning = value
    onTransitioningChange(value)
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
private final class MacPageGradientView: NSView {
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
private final class MacPageVersoView: NSView {
  let shade = CAGradientLayer()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor =
      NSColor(
        red: PaperAppearance.background.red,
        green: PaperAppearance.background.green,
        blue: PaperAppearance.background.blue,
        alpha: 1
      ).cgColor
    layer?.transform = CATransform3DMakeRotation(.pi, 0, 1, 0)
    shade.colors = [
      NSColor.black.withAlphaComponent(0.12).cgColor,
      NSColor.black.withAlphaComponent(0.01).cgColor,
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

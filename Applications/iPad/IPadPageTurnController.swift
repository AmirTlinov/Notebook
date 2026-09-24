import NotebookCore
import SwiftUI
import UIKit

/// Failure dependency for the sheet curl. It never takes content input: a
/// successful admission blocker only denies the dependent page recognizers.
/// Resolve after touchdown has let selection reserve its original contact.
final class PageTurnAdmissionRecognizer: UIGestureRecognizer {
  var canBeginNavigation: () -> Bool = { true }
  /// Returning false keeps this contact until lift rather than losing a swipe
  /// to an absent render-ready neighbour.
  var prepareDirection: (Int) -> Bool = { _ in true }
  var finishColdSwipe: (Bool) -> Void = { _ in }
  private var coldDirection: Int?
  private var contacts: [UITouch: CGPoint] = [:]
  private var beganAt: TimeInterval = 0
  override init(target: Any?, action: Selector?) {
    super.init(target:target,action:action)
    name = "NotebookPageTurnAdmission"
    allowedTouchTypes = [NSNumber(value:UITouch.TouchType.direct.rawValue)]
    cancelsTouchesInView = false; delaysTouchesBegan = false; delaysTouchesEnded = false
  }
  convenience init() { self.init(target:nil,action:nil) }
  override func canPrevent(_ other: UIGestureRecognizer) -> Bool { false }
  override func canBePrevented(by other: UIGestureRecognizer) -> Bool { false }
  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
    for touch in touches { contacts[touch] = touch.location(in:view?.window) }
    beganAt = touches.map(\.timestamp).max() ?? 0
    if !canBeginNavigation() || contacts.count > 2 { state = .began }
  }
  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
    guard state == .possible || coldDirection != nil else { return }
    guard canBeginNavigation() else { cancelColdSwipe(); state = .began; return }
    let pairs = contacts.map { (start:$0.value, end:$0.key.location(in:view?.window)) }
    let deltas = pairs.map { CGPoint(x:$0.end.x-$0.start.x,y:$0.end.y-$0.start.y) }
    if pairs.count == 1, let delta = deltas.first, hypot(delta.x,delta.y) >= 4 {
      if coldDirection != nil { return }
      if abs(delta.x) > abs(delta.y) { resolveHorizontal(delta.x) }
      else { state = .began }
    } else if pairs.count == 2 {
      let startDistance = hypot(pairs[0].start.x-pairs[1].start.x,pairs[0].start.y-pairs[1].start.y)
      let distance = hypot(pairs[0].end.x-pairs[1].end.x,pairs[0].end.y-pairs[1].end.y)
      let intent = TwoFingerIntentArbiter.resolve(defersHorizontalMotionToPageTurn:true,
        translation:.init(x:(deltas[0].x+deltas[1].x)/2,y:(deltas[0].y+deltas[1].y)/2),
        fingerDisplacements:deltas,magnification:distance/max(1,startDistance),
        elapsed:(touches.map(\.timestamp).max() ?? beganAt)-beganAt)
      if intent == .navigation, coldDirection == nil { resolveHorizontal((deltas[0].x+deltas[1].x)/2) }
      else if intent == .magnification { cancelColdSwipe(); state = .began }
    }
  }
  private func resolveHorizontal(_ translation: CGFloat) {
    let direction = translation < 0 ? 1 : -1
    if prepareDirection(direction) { state = .failed }
    else { coldDirection = direction; state = .began }
  }
  private func cancelColdSwipe() {
    guard coldDirection != nil else { return }
    coldDirection = nil; finishColdSwipe(false)
  }
  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
    if let direction = coldDirection {
      let delta = contacts.map { $0.key.location(in:view?.window).x - $0.value.x }
      let distance = delta.reduce(0,+) / CGFloat(max(1,delta.count))
      coldDirection = nil
      finishColdSwipe(canBeginNavigation() && -distance * CGFloat(direction) >= IPadSheetCurlController.minimumGestureTravel)
    }
    state = .ended
  }
  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { cancelColdSwipe(); state = .cancelled }
  override func reset() { super.reset(); cancelColdSwipe(); contacts.removeAll() }
}

/// The iPad executor for `PageTurnSurface`.
///
/// The shared sheet renderer owns physical bending. This container owns page identity:
/// neighbouring live pages are mounted behind the visible page until Metal and
/// WebKit have presented them, and stay mounted through the entire turn.
@MainActor
final class IPadPageTurnController: UIViewController {
  private let observationID = UUID()
  let sheetController = IPadSheetCurlController()
  private let navigationAdmission = PageTurnAdmissionRecognizer()

  private var controllers: [Int: IPadIndexedPageController] = [:]
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
  private let pageTurnActivity = PageTurnActivity()
  private var isTransitioning = false
  private var isUpdatingContents = false
  private var pendingExternalIndex: Int?
  private var sequentialTarget: Int?
  private var coldGestureTarget: Int?
  private var notebookNavigation: NotebookPageNavigation?
  private weak var inputGate: NotebookInputGate?
  private var notebookStatusRevision: UInt64 = 0
  private var lastNotebookStatus: String?
  private var onWindowChange: @MainActor (Set<Int>, String) -> Void = { _, _ in }
  private var anticipatedIndex: Int?
  private var lastTurnDirection: Int?
  private var transitionRevision: UInt64 = 0
  private var transitionNotificationRevision: UInt64 = 0
  private var transitionNotificationTask: Task<Void, Never>?
  private var publishedTransitionState = false
  private let documentControllerID = UUID()
  private var canonicalDocumentLayout: DocumentPageLayout?
  private var resolvedDocumentTarget: Int? {
    guard let request = documentSelection,
      let count = canonicalDocumentLayout?.pageCount(for: sequenceRevision) else { return nil }
    return min(max(0, request.pageIndex), count - 1)
  }
  private var documentSelection: DocumentPageNavigationRequest?
  private var documentNavigation: DocumentPageNavigationCallbacks?
  private var documentLandingRevision: UInt64 = 0
  private var documentStatusRevision: UInt64 = 0
  private var preparationFailures: [Int: PageTurnPreparationFailure] = [:]
  private struct DocumentStatusKey: Equatable {
    let source: String
    let request: UUID?
    let target: Int?
    let phase: DocumentPageNavigationStatus.Phase?
    let failure: UUID?
  }
  private var lastDocumentStatus: DocumentStatusKey?
  private var lastDocumentLanding: String?

  isolated deinit {
    pageTurnActivity.prepare(nil)
    documentNavigation?.unbind(documentControllerID)
    notebookNavigation?.unbind(documentControllerID)
    onWindowChange([], sequenceRevision)
  }

  private func observe(_ stage: String, target: Int? = nil, reason: String? = nil) {
    guard NotebookNavigationObservation.enabled else { return }
    func index(_ value: Int?) -> JSONValue { value.map { .number(Double($0)) } ?? .null }
    NotebookNavigationObservation.recordDocument(stage, ownerID: observationID, documentID: ownerID,
      fields: ["displayed": index(displayedIndex), "selected": index(selectedIndex),
        "target": index(target), "pending": index(pendingExternalIndex), "anticipated": index(anticipatedIndex),
        "preparationDemandID": pageTurnActivity.preparationDemand.map { .string($0.id.uuidString) } ?? .null,
        "preparationTarget": index(pageTurnActivity.preparationDemand?.pageIndex),
        "reason": reason.map(JSONValue.string) ?? .null,
        "transitionRevision": .string(String(transitionRevision)),
        "transitioning": .bool(isTransitioning), "updatingContents": .bool(isUpdatingContents),
        "window": .bool(viewIfLoaded?.window != nil), "pageCount": index(pageCount),
        "controllers": .array(controllers.keys.sorted().compactMap { page in
          guard let controller = controllers[page] else { return nil }
          return .object(["page": index(page), "hostID": .string(controller.hostID.uuidString),
            "ready": readyPages[page].map(JSONValue.bool) ?? .null,
            "nativeCurrent": .bool(page == displayedIndex), "window": .bool(controller.viewIfLoaded?.window != nil)])
        })])
  }

  var displayedIndex: Int { selection.displayedIndex }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    publishDocumentLanding(at: displayedIndex,
      requestID: resolvedDocumentTarget == displayedIndex ? documentSelection?.id : nil)
    publishDocumentStatus()
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear
    view.isOpaque = false
    view.clipsToBounds = true

    addChild(sheetController)
    view.addSubview(sheetController.view)
    sheetController.didMove(toParent: self)
    sheetController.neighbor = { [weak self] current, direction in
      guard let self else { return nil }
      return direction == .forward ? self.sheetController(self.sheetController, after: current)
        : self.sheetController(self.sheetController, before: current)
    }
    sheetController.willTurn = { [weak self] target in
      guard let self else { return false }
      return self.sheetController(self.sheetController, willTurnTo: target)
    }
    sheetController.didTurn = { [weak self] source, completed in
      guard let self else { return }
      self.sheetController(self.sheetController, didTurnFrom: source, completed: completed)
    }
    sheetController.onFailure = { [weak self] error in
      guard let self, let target = self.anticipatedIndex else { return }
      self.pendingExternalIndex = target
      self.preparationFailures[target] = .init(message: "Не удалось подготовить перелистывание") { [weak self] in
        guard let self else { return }
        self.preparationFailures[target] = nil
        self.requestExternalSelection(target)
      }
      self.publishDocumentStatus()
    }
    navigationAdmission.canBeginNavigation = { [weak self] in
      guard let self else { return false }
      return navigationIsEnabled && canBeginNavigation()
    }
    navigationAdmission.prepareDirection = { [weak self] direction in
      guard let self, !isTransitioning else { return true }
      let target = displayedIndex + direction
      guard (0..<pageCount).contains(target), readyPages[target] != true else { return true }
      coldGestureTarget = target; anticipatedIndex = target
      prepareExternalTarget(target); retainNeededControllers(); publishDocumentStatus()
      return false
    }
    navigationAdmission.finishColdSwipe = { [weak self] accepted in
      guard let self, let target = coldGestureTarget else { return }
      coldGestureTarget = nil; anticipatedIndex = nil
      if accepted { sequentialTarget = nil; requestExternalSelection(target) }
      else { prepareExternalTarget(nil); retainNeededControllers(); publishDocumentStatus() }
    }
    sheetController.view.addGestureRecognizer(navigationAdmission)

    installDisplayedPage()
    configureSystemGestures()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    sheetController.view.frame = view.bounds
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
    onTransitioningChange: @escaping @MainActor (Bool) -> Void,
    canonicalDocumentLayout: DocumentPageLayout? = nil,
    documentSelection: DocumentPageNavigationRequest? = nil,
    documentNavigation: DocumentPageNavigationCallbacks? = nil,
    notebookNavigation: NotebookPageNavigation? = nil,
    onWindowChange: @escaping @MainActor (Set<Int>, String) -> Void = { _, _ in },
    inputGate: NotebookInputGate? = nil
  ) {
    let previousResolvedTarget = resolvedDocumentTarget
    self.canonicalDocumentLayout = canonicalDocumentLayout
    let replacesDocument = self.ownerID != ownerID || documentNavigation == nil
    let ownerChanged = self.ownerID != ownerID || self.sequenceRevision != sequenceRevision
    if ownerChanged {
      self.notebookNavigation?.unbind(documentControllerID)
      self.onWindowChange([], self.sequenceRevision)
    }
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
    self.documentNavigation = documentNavigation
    self.notebookNavigation = notebookNavigation
    self.inputGate = inputGate
    self.onWindowChange = onWindowChange
    notebookNavigation?.bind(documentControllerID, ownerID: ownerID, source: sequenceRevision) { [weak self] command in
      self?.requestNotebookNavigation(command) ?? false
    }
    documentNavigation?.bind(documentControllerID, ownerID, sequenceRevision)
    if !navigationIsEnabled, notebookNavigation != nil {
      sequentialTarget = nil; coldGestureTarget = nil; pendingExternalIndex = nil
      if !isTransitioning { anticipatedIndex = nil; prepareExternalTarget(nil) }
    }

    if ownerChanged {
      observe("page_turn_owner_changed")
      pageTurnActivity.didInstall(nil)
      pageTurnActivity.prepare(nil)
      transitionRevision &+= 1
      setTransitioning(false, resetsPublication: true)
      pendingExternalIndex = nil
      sequentialTarget = nil
      coldGestureTarget = nil
      lastNotebookStatus = nil
      anticipatedIndex = nil
      lastTurnDirection = nil
      preparationFailures.removeAll()
      lastDocumentStatus = nil
      lastDocumentLanding = nil
      self.documentSelection = nil
      selection.reset(to: self.selectedIndex)
      if isViewLoaded {
        if replacesDocument { replaceOwnerPages() }
        else {
          // A source revision changes page readiness, not the window's native
          // editing session. Existing paper stays until its replacement is ready.
          readyPages.removeAll()
          refreshRenderedPages()
        }
      }
    } else { selection.acknowledge(self.selectedIndex) }

    if documentNavigation != nil {
      let next = documentSelection.flatMap { value in
        value.documentID == ownerID && value.sourceRevision == sequenceRevision ? value : nil
      }
      let requestChanged = self.documentSelection != next
      self.documentSelection = next
      if requestChanged || previousResolvedTarget != resolvedDocumentTarget {
        // Only the current source's canonical layout can resolve a remote or
        // early reference target. The first real page prepares that layout.
        pendingExternalIndex = resolvedDocumentTarget
        prepareExternalTarget(resolvedDocumentTarget)
        publishDocumentStatus()
      }
    }

    guard isViewLoaded else { return }
    retainNeededControllers()
    refreshRenderedPages()
    refreshControllerState()
    configureSystemGestures()
    runPendingExternalSelection()
    if documentNavigation != nil, !isTransitioning {
      publishDocumentLanding(at: displayedIndex,
        requestID: self.resolvedDocumentTarget == displayedIndex ? self.documentSelection?.id : nil)
    }
  }

  func sheetController(
    _ sheetController: IPadSheetCurlController,
    before viewController: UIViewController
  ) -> UIViewController? {
    guard navigationIsEnabled,
      let current = viewController as? IPadIndexedPageController,
      controllers[current.pageIndex] === current
    else { return nil }
    return preparedController(at: current.pageIndex - 1)
  }

  func sheetController(
    _ sheetController: IPadSheetCurlController,
    after viewController: UIViewController
  ) -> UIViewController? {
    guard navigationIsEnabled,
      let current = viewController as? IPadIndexedPageController,
      controllers[current.pageIndex] === current
    else { return nil }
    return preparedController(at: current.pageIndex + 1)
  }

  @discardableResult
  func sheetController(_ sheetController: IPadSheetCurlController, willTurnTo target: UIViewController) -> Bool {
    guard canBeginNavigation(), let target = target as? IPadIndexedPageController,
      controllers[target.pageIndex] === target, readyPages[target.pageIndex] == true else { return false }
    anticipatedIndex = target.pageIndex
    retainNeededControllers()
    setTransitioning(true)
    refreshControllerState()
    return true
  }

  func sheetController(_ sheetController: IPadSheetCurlController, didTurnFrom previous: UIViewController, completed: Bool) {
    guard let previous = previous as? IPadIndexedPageController,
      controllers[previous.pageIndex] === previous,
      let shown = sheetController.page as? IPadIndexedPageController,
      controllers[shown.pageIndex] === shown else { return }
    if completed {
      let source = displayedIndex, target = shown.pageIndex
      selection.recordLocalLanding(at: target)
      if allowsTrailingPageCreation, target == pageCount - 1, pageCount < Int.max { pageCount += 1 }
      lastTurnDirection = target == source ? nil : (target > source ? 1 : -1)
    } else if previous.pageIndex != displayedIndex { selection.reset(to: previous.pageIndex) }
    anticipatedIndex = nil
    setTransitioning(false)
    retainNeededControllers()
    refreshRenderedPages()
    refreshControllerState()
    if completed, documentNavigation != nil {
      publishDocumentLanding(at: displayedIndex, requestID: nil, deferred: false)
    } else if completed { onCommit(displayedIndex, sequenceRevision) }
    runPendingExternalSelection()
  }

  private func installDisplayedPage() {
    guard isViewLoaded, !hasInstalledPage else { return }
    hasInstalledPage = true
    isUpdatingContents = true
    guard let controller = controllerForPage(at: displayedIndex) else { isUpdatingContents = false; return }
    sheetController.show(
      controller,
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
    sheetController.cancelMotion(notify: false)
    let oldControllers = Array(controllers.values)
    controllers.removeAll()
    readyPages.removeAll()
    hasInstalledPage = true
    isUpdatingContents = true

    // Release the previous owner's finite window before preparing the new one.
    for oldController in oldControllers {
      retireContent(of: oldController)
    }
    guard let controller = controllerForPage(at: displayedIndex) else { isUpdatingContents = false; return }
    sheetController.show(
      controller,
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
    let controller = IPadIndexedPageController(pageIndex: index, rootView: AnyView(EmptyView()))
    controller.view.backgroundColor = .clear
    controller.view.accessibilityIdentifier = "page-turn-page-\(index)"
    controllers[index] = controller
    observe("page_turn_controller_created", target: index, reason: "new")
    controller.rootView = hostedPage(
      at: index,
      isCurrent: index == displayedIndex,
      hostID: controller.hostID
    )
    controller.loadViewIfNeeded()
    return controller
  }

  private func retainNeededControllers() {
    // A curl keeps its exact prepared window until it returns both source
    // and landing. External requests replace one index, never add live content.
    guard isViewLoaded, !isTransitioning, !isUpdatingContents else { return }
    isUpdatingContents = true
    defer { isUpdatingContents = false }
    let target = anticipatedIndex ?? pendingExternalIndex.map(clamped)
    pageTurnActivity.rasters.prioritize(displayed: displayedIndex, target: target)
    let required = PageTurnPrewarmWindow.indices(
      displayedIndex: displayedIndex,
      anticipatedIndex: target,
      lastDirection: lastTurnDirection,
      pageCount: pageCount,
      existingIndices: Set(controllers.keys)
    )
    onWindowChange(required, sequenceRevision)
    // Exactly the finite window owns mounted hosts. No hidden platform cache
    // retains shells or causes a second content lifetime on reverse turns.
    for index in Array(controllers.keys) where !required.contains(index) {
      guard let controller = controllers[index],
        sheetController.page !== controller
      else { continue }
      controllers[index] = nil
      readyPages[index] = nil
      preparationFailures[index] = nil
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

  private func retireContent(of controller: IPadIndexedPageController) {
    observe("page_turn_content_retire", target: controller.pageIndex)
    sheetController.retire(controller)
    controller.rootView = AnyView(EmptyView())
  }

  private func mountForPrewarming(_ controller: IPadIndexedPageController) {
    sheetController.prepare(controller)
  }

  private func refreshRenderedPages() {
    guard !isTransitioning else { return }
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
    let sourceRevision = sequenceRevision
    let readiness = PageTurnReadiness(activity: pageTurnActivity, pageIndex: index, onFailure: { [weak self] failure in
      guard let self, self.sequenceRevision == sourceRevision, self.controllers[index]?.hostID == hostID else { return }
      self.preparationFailures[index] = failure
      self.publishDocumentStatus()
    }) { [weak self] ready in
      guard self?.sequenceRevision == sourceRevision else { return }
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
    if ready { preparationFailures[index] = nil }
    observe("page_turn_readiness", target: index, reason: ready ? "ready" : "not_ready")
    guard ready else { return }
    if documentNavigation != nil, index == displayedIndex, hasInstalledPage {
      publishDocumentLanding(at: index, requestID: resolvedDocumentTarget == index ? documentSelection?.id : nil)
    }
    publishDocumentStatus()
    runPendingExternalSelection()
  }

  private func requestExternalSelection(_ requestedIndex: Int) {
    guard (0..<pageCount).contains(requestedIndex) else { return }
    let target = clamped(requestedIndex)
    pendingExternalIndex = target
    prepareExternalTarget(target)
    observe("page_turn_external_request", target: target)
    guard isViewLoaded, !isTransitioning, !isUpdatingContents else { return }
    guard target != displayedIndex else {
      pendingExternalIndex = nil
      retainNeededControllers()
      return
    }
    retainNeededControllers()
    guard preparationFailures[target] == nil else { publishDocumentStatus(); return }
    guard let targetController = controllers[target] else { return }
    mountForPrewarming(targetController)
    guard readyPages[target] == true else {
      observe("page_turn_external_wait", target: target, reason: "passive_target_not_ready")
      publishDocumentStatus()
      return
    }

    // Readiness can arrive during a new contact, long after command admission.
    // The physical input owner fences the actual handoff, not merely the tap.
    let source = sequenceRevision, hostID = targetController.hostID
    let install: NotebookInputCompletion = { [weak self, weak targetController] in
      guard let self, let targetController, sequenceRevision == source, pendingExternalIndex == target,
        controllers[target]?.hostID == hostID, readyPages[target] == true,
        !isTransitioning, !isUpdatingContents else { return }
      beginExternalSelection(target, targetController: targetController)
    }
    if let inputGate { inputGate.performAfterIdle(install) } else { install() }
  }

  private func beginExternalSelection(_ target: Int, targetController: IPadIndexedPageController) {
    pendingExternalIndex = nil
    anticipatedIndex = target
    retainNeededControllers()
    transitionRevision &+= 1
    let revision = transitionRevision
    let requestID = documentSelection?.id
    let preparation = pageTurnActivity.preparationDemand
    let adjacent = abs(target - displayedIndex) == 1
    let direction: IPadSheetCurlController.Direction =
      target > displayedIndex ? .forward : .reverse
    setTransitioning(true)
    publishDocumentStatus()
    observe("page_turn_external_begin", target: target)
    refreshControllerState()

    // Adjacent turns confirm the displayed endpoint. A distant prepared
    // destination installs directly, without an unrelated second animation.
    sheetController.show(
      targetController,
      direction: direction,
      animated: adjacent && sheetController.viewIfLoaded?.window != nil
    ) { [weak self] finished in
      guard let self, transitionRevision == revision else { return }
      completeExternalSelection(target, finished: finished, requestID: requestID, preparation: preparation)
    }
  }

  private func requestNotebookNavigation(_ command: NotebookPageNavigation.Command) -> Bool {
    // Explicit commands arrive after their caller's input fence. The gesture
    // predicate rejects native buttons and zoomed paper; it cannot govern the
    // very arrow that requested navigation or drop taps during a previous curl.
    guard navigationIsEnabled else { return false }
    switch command {
    case .cancel:
      sequentialTarget = nil; coldGestureTarget = nil; pendingExternalIndex = nil
      sheetController.cancelMotion()
      anticipatedIndex = nil; prepareExternalTarget(nil)
      retainNeededControllers(); refreshControllerState(); publishDocumentStatus()
    case .step(let delta):
      guard delta == -1 || delta == 1 else { return false }
      sequentialTarget = clamped((sequentialTarget ?? pendingExternalIndex ?? anticipatedIndex ?? displayedIndex) + delta)
    case .jump(let index):
      guard (0..<pageCount).contains(index) else { return false }
      sequentialTarget = nil
      requestExternalSelection(index)
      return true
    }
    runPendingExternalSelection()
    return true
  }

  private func completeExternalSelection(_ target: Int, finished: Bool, requestID: UUID?,
    preparation: PageTurnActivity.PreparationDemand?) {
    observe("page_turn_external_completion", target: target, reason: finished ? "finished" : "interrupted")
    if finished {
      let source = displayedIndex
      selection.recordLocalLanding(at: target)
      lastTurnDirection = target > source ? 1 : -1
    }
    anticipatedIndex = nil
    pageTurnActivity.didInstall(finished ? preparation : nil)
    prepareExternalTarget(pendingExternalIndex)
    setTransitioning(false)
    retainNeededControllers()
    refreshRenderedPages()
    refreshControllerState()
    observe("page_turn_external_inputs_published", target: target)
    if finished, documentNavigation != nil { publishDocumentLanding(at: target, requestID: requestID, deferred: false) }
    else if finished {
      isUpdatingContents = true
      onCommit(target, sequenceRevision)
      isUpdatingContents = false
    }
    publishDocumentStatus()
    let completedRevision = transitionRevision
    Task { @MainActor [weak self] in
      guard let self, transitionRevision == completedRevision else { return }
      runPendingExternalSelection()
    }
  }

  private func runPendingExternalSelection() {
    guard !isTransitioning, !isUpdatingContents, coldGestureTarget == nil else { return }
    if let target = sequentialTarget {
      if target == displayedIndex {
        sequentialTarget = nil; pendingExternalIndex = nil
        pageTurnActivity.prepare(nil); publishDocumentStatus()
        return
      }
      requestExternalSelection(displayedIndex + (target > displayedIndex ? 1 : -1))
      return
    }
    let target: Int
    if documentNavigation != nil {
      guard let requested = pendingExternalIndex ?? resolvedDocumentTarget else { return }
      target = requested
    } else {
      guard let requested = pendingExternalIndex else { return }
      target = requested
    }
    guard target != displayedIndex else {
      pendingExternalIndex = nil
      pageTurnActivity.prepare(nil)
      publishDocumentStatus()
      return
    }
    requestExternalSelection(target)
  }

  private func prepareExternalTarget(_ page: Int?) {
    let target = page.flatMap { $0 == displayedIndex ? nil : $0 }
    let live = documentNavigation != nil && target.map { abs($0 - displayedIndex) > 1 } == true
    pageTurnActivity.prepare(target, presentation: live ? .live : .snapshot)
  }

  private func publishDocumentLanding(at page: Int, requestID: UUID?, deferred: Bool = true) {
    guard let callbacks = documentNavigation, let ownerID,
      pageIsInteractive, viewIfLoaded?.window != nil, hasInstalledPage, readyPages[page] == true,
      let shown = sheetController.page as? IPadIndexedPageController,
      shown.pageIndex == page, controllers[page] === shown else { return }
    let pageKey = "\(sequenceRevision)|\(shown.hostID)|\(page)|"
    let key = pageKey + (requestID?.uuidString ?? "local")
    guard lastDocumentLanding != key,
      !(requestID == nil && lastDocumentLanding?.hasPrefix(pageKey) == true) else { return }
    lastDocumentLanding = key
    documentLandingRevision &+= 1
    let receipt = DocumentPageLanding(controllerID: documentControllerID, documentID: ownerID,
      sourceRevision: sequenceRevision, revision: documentLandingRevision, pageIndex: page, requestID: requestID)
    // Delegate/completion landings publish in their native turn, before another
    // contact can see a new page with the old model origin. Initial readiness
    // can originate in a representable update and must defer its observable write.
    if !deferred { callbacks.landed(receipt); return }
    Task { @MainActor [weak self] in
      guard let self, self.ownerID == receipt.documentID, self.sequenceRevision == receipt.sourceRevision else { return }
      callbacks.landed(receipt)
    }
  }

  private func publishDocumentStatus() {
    publishNotebookStatus()
    guard let callbacks = documentNavigation, let ownerID else { return }
    let request = documentSelection
    let target = request.flatMap { request -> Int? in
      let target = resolvedDocumentTarget ?? request.pageIndex
      return resolvedDocumentTarget != nil && target == displayedIndex
        && !isTransitioning && readyPages[target] == true ? nil : target
    } ?? (readyPages[displayedIndex] != true && preparationFailures[displayedIndex] != nil ? displayedIndex : nil)
    let failure = target.flatMap { readyPages[$0] == true ? nil : preparationFailures[$0] }
    let phase: DocumentPageNavigationStatus.Phase? = target == nil ? nil
      : failure != nil ? .failed : isTransitioning ? .transitioning : .preparing
    let key = DocumentStatusKey(source: sequenceRevision, request: request?.id,
      target: target, phase: phase, failure: failure?.id)
    guard key != lastDocumentStatus else { return }
    lastDocumentStatus = key; documentStatusRevision &+= 1
    let retry = failure.map { failure in
      PageTurnPreparationFailure(kind: failure.kind, message: failure.message) { [weak self] in
        guard let self, self.documentSelection?.id == request?.id,
          self.sequenceRevision == key.source, let target,
          self.preparationFailures[target]?.id == failure.id else { return }
        self.preparationFailures[target] = nil
        self.publishDocumentStatus()
        failure.retry()
      }
    }
    let status = DocumentPageNavigationStatus(controllerID: documentControllerID, documentID: ownerID,
      sourceRevision: sequenceRevision, revision: documentStatusRevision, requestID: request?.id,
      target: target, phase: phase, failure: retry)
    Task { @MainActor [weak self] in
      guard let self, self.ownerID == status.documentID, self.sequenceRevision == status.sourceRevision,
        self.documentStatusRevision == status.revision else { return }
      callbacks.status(status)
    }
  }

  private func publishNotebookStatus() {
    guard let notebookNavigation, let ownerID else { return }
    let target = isTransitioning ? nil : (pendingExternalIndex ?? coldGestureTarget)
    let failure = target.flatMap { preparationFailures[$0] }
    let key = "\(sequenceRevision)|\(target.map(String.init) ?? "-")|\(failure?.id.uuidString ?? "-")"
    guard lastNotebookStatus != key else { return }
    lastNotebookStatus = key; notebookStatusRevision &+= 1
    let revision = notebookStatusRevision, source = sequenceRevision
    let value = target.map { NotebookPageNavigation.Status(ownerID: ownerID, target: $0, failure: failure) }
    Task { @MainActor [weak self] in
      guard let self, notebookStatusRevision == revision else { return }
      notebookNavigation.report(value, ownerID: ownerID, controllerID: documentControllerID, source: source)
    }
  }

  private func configureSystemGestures() {
    let enabled = navigationIsEnabled && pageCount > 1
    if sheetController.pan.isEnabled != enabled { sheetController.pan.isEnabled = enabled }
    sheetController.pan.require(toFail: navigationAdmission)
  }

  private func setTransitioning(_ value: Bool, resetsPublication: Bool = false) {
    guard isTransitioning != value || resetsPublication else { return }
    // UIKit and input admission change in this event. A SwiftUI observer cannot
    // be called from updateUIViewController, which may initiate an external turn.
    isTransitioning = value
    pageTurnActivity.update(value)
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

  var preparedPageIndices: Set<Int> { Set(readyPages.compactMap { $0.value ? $0.key : nil }) }

  #if DEBUG
  var navigationStateDescription: String {
    "shown=\(displayedIndex),selected=\(selectedIndex),ack=\(selection.awaitsLocalAcknowledgement),pending=\(String(describing:pendingExternalIndex)),queued=\(String(describing:sequentialTarget)),anticipated=\(String(describing:anticipatedIndex)),turning=\(isTransitioning),updating=\(isUpdatingContents),enabled=\(navigationIsEnabled)"
  }
  #endif

  var cachedPageIdentities: [Int: ObjectIdentifier] {
    controllers.mapValues(ObjectIdentifier.init)
  }

  var visiblePageIdentity: ObjectIdentifier? {
    sheetController.page.map(ObjectIdentifier.init)
  }
}

/// One hosting lifetime per resident page. Z-order, not reparenting, selects it.
@MainActor
private final class IPadIndexedPageController: UIHostingController<AnyView> {
  let pageIndex: Int
  let hostID = UUID()
  init(pageIndex: Int, rootView: AnyView) {
    self.pageIndex = pageIndex
    super.init(rootView: rootView)
    view.backgroundColor = .clear
    safeAreaRegions = []
  }
  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("Use init(pageIndex:rootView:)") }
}

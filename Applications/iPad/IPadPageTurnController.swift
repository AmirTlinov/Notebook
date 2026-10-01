import NotebookCore
import SwiftUI
import UIKit

/// Failure dependency for the sheet curl. It never takes content input: a
/// successful admission blocker only denies the dependent page recognizers.
/// Resolve after touchdown has let selection reserve its original contact.
final class PageTurnAdmissionRecognizer: UIGestureRecognizer {
  var canBeginNavigation: () -> Bool = { true }
  weak var inputGate: NotebookInputGate?
  var navigationSource: UUID?
  var contactSequenceDidReset: () -> Void = {}
  /// Returning false retains this contact while its neighbour prepares.
  var prepareDirection: (Int) -> Bool = { _ in true }
  var updateColdSwipe: (CGFloat) -> Void = { _ in }
  var finishColdSwipe: (Bool) -> Void = { _ in }
  private var coldDirection: Int?
  private var contacts: [UITouch: CGPoint] = [:]
  var contactIDs: Set<ObjectIdentifier> { Set(contacts.keys.map(ObjectIdentifier.init)) }
  private var beganAt: TimeInterval = 0
  private var motionSamples: [(time: TimeInterval, x: CGFloat)] = []
  private(set) var releaseVelocity: CGFloat = 0
  private(set) var releaseDuration: TimeInterval = .infinity

  private func sampleMotion() -> (distance: CGFloat, velocity: CGFloat) {
    let distance = contacts.reduce(CGFloat.zero) { $0 + $1.key.location(in: view?.window).x - $1.value.x }
      / CGFloat(max(1, contacts.count))
    let time = contacts.keys.map(\.timestamp).max() ?? beganAt
    // The same short recent-motion interval as workspace gestures. A stopped
    // finger has zero velocity; a recent reversal can cancel a long drag.
    motionSamples.removeAll { time - $0.time > 0.08 }
    if motionSamples.last?.time != time { motionSamples.append((time, distance)) }
    guard let first = motionSamples.first, time - first.time > 0.001 else { return (distance, 0) }
    return (distance, (distance - first.x) / (time - first.time))
  }
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
    for touch in touches {
      if let inputGate { _ = NotebookSceneFingerRouting.owner(of: touch, gate: inputGate) }
      contacts[touch] = touch.location(in:view?.window)
    }
    if let inputGate, let navigationSource {
      inputGate.retainNavigationContacts(source: navigationSource, contacts: contactIDs)
    }
    beganAt = touches.map(\.timestamp).max() ?? 0
    releaseVelocity = 0; releaseDuration = .infinity
    motionSamples.removeAll(); _ = sampleMotion()
    if !canBeginNavigation() || contacts.count > 2 { cancelColdSwipe(); state = .began }
  }
  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
    guard state == .possible || coldDirection != nil else { return }
    guard canBeginNavigation() else { cancelColdSwipe(); state = .began; return }
    _ = sampleMotion()
    let pairs = contacts.map { (start:$0.value, end:$0.key.location(in:view?.window)) }
    let deltas = pairs.map { CGPoint(x:$0.end.x-$0.start.x,y:$0.end.y-$0.start.y) }
    if pairs.count == 1, let delta = deltas.first {
      if coldDirection != nil { updateColdSwipe(delta.x) }
      else if hypot(delta.x,delta.y) >= 4 {
        if abs(delta.x) > abs(delta.y) { resolveHorizontal(delta.x) }
        else { state = .began }
      }
    } else if pairs.count == 2 {
      let startDistance = hypot(pairs[0].start.x-pairs[1].start.x,pairs[0].start.y-pairs[1].start.y)
      let distance = hypot(pairs[0].end.x-pairs[1].end.x,pairs[0].end.y-pairs[1].end.y)
      let intent = TwoFingerIntentArbiter.resolve(defersHorizontalMotionToPageTurn:true,
        translation:.init(x:(deltas[0].x+deltas[1].x)/2,y:(deltas[0].y+deltas[1].y)/2),
        fingerDisplacements:deltas,magnification:distance/max(1,startDistance),
        elapsed:(touches.map(\.timestamp).max() ?? beganAt)-beganAt)
      if intent == .navigation, coldDirection == nil { resolveHorizontal((deltas[0].x+deltas[1].x)/2) }
      else if intent == .magnification { cancelColdSwipe(); state = .began }
      else if coldDirection != nil { updateColdSwipe((deltas[0].x+deltas[1].x)/2) }
    }
  }
  private func resolveHorizontal(_ translation: CGFloat) {
    let direction = translation < 0 ? 1 : -1
    if prepareDirection(direction) { state = .failed }
    else { coldDirection = direction; state = .began; updateColdSwipe(translation) }
  }
  private func cancelColdSwipe() {
    guard coldDirection != nil else { return }
    coldDirection = nil; finishColdSwipe(false)
  }
  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
    if let direction = coldDirection {
      let motion = sampleMotion(), sign = -CGFloat(direction)
      releaseVelocity = motion.velocity
      releaseDuration = max(0, (touches.map(\.timestamp).max() ?? beganAt)-beganAt)
      updateColdSwipe(motion.distance)
      coldDirection = nil
      finishColdSwipe(IPadSheetCurlController.completesGesture(travel: motion.distance * sign,
        velocity: motion.velocity * sign, ended: canBeginNavigation()))
    }
    state = .ended
  }
  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { cancelColdSwipe(); state = .cancelled }
  override func reset() {
    super.reset(); cancelColdSwipe(); contacts.removeAll(); motionSamples.removeAll()
    contactSequenceDidReset()
  }
}

/// The iPad executor for `PageTurnSurface`.
///
/// The shared sheet renderer owns physical bending. This container owns page identity:
/// neighbouring live pages are mounted behind the visible page until Metal and
/// WebKit have presented them, and stay mounted through the entire turn.
@MainActor
final class IPadPageTurnController: UIViewController {
  private let sceneNotifications: NotificationCenter
  private var sceneObservers: [NSObjectProtocol] = []
  private weak var mountedWindow: UIWindow?
  private var observedSceneIsActive = false

  init(sceneNotifications: NotificationCenter = .default) {
    self.sceneNotifications = sceneNotifications
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError("Use init(sceneNotifications:)") }

  private var permitsSceneNavigation: Bool {
    // Headless native composition retains its direct-install route. A mounted
    // interaction belongs to its own scene, including willDeactivate's edge
    // before UIKit updates activationState or removes any native view.
    guard let window = viewIfLoaded?.window, let scene = window.windowScene else { return true }
    return window === mountedWindow ? observedSceneIsActive
      : scene.activationState == .foregroundActive
  }

  private func observeMountedSceneLifetime() {
    for (name, active) in [(UIScene.didActivateNotification, true),
      (UIScene.willDeactivateNotification, false), (UIScene.didDisconnectNotification, false)] {
      sceneObservers.append(sceneNotifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
        guard let scene = note.object as? UIWindowScene else { return }
        MainActor.assumeIsolated {
          guard let self, !self.isRetired, self.viewIfLoaded?.window?.windowScene === scene else { return }
          self.observedSceneIsActive = active
          if !active { self.cancelNavigationInteraction(outcome: .cancelled) }
          self.configureSystemGestures()
        }
      })
    }
  }
  private func mountedWindowDidChange(_ window: UIWindow?) {
    guard !isRetired, mountedWindow !== window else { return }
    let replacesWindow = mountedWindow != nil
    mountedWindow = window
    let scene = window?.windowScene
    observedSceneIsActive = scene?.activationState == .foregroundActive
    // Detachment ends the mounted lifetime. Activation received while absent
    // belongs to no interaction here; remount seeds the new lifetime directly.
    // A willDeactivate edge in the unchanged window is never reseeded merely
    // because UIKit has not updated activationState yet.
    if replacesWindow || !observedSceneIsActive { cancelNavigationInteraction(outcome: .cancelled) }
    configureSystemGestures()
  }
  private let observationID = UUID()
  let sheetController = IPadSheetCurlController()
  private let navigationAdmission = PageTurnAdmissionRecognizer()
  private let navigationClaimID = UUID()

  private var controllers: [Int: IPadIndexedPageController] = [:]
  private struct PagePreparation {
    var readiness = PageTurnReadiness.State.waiting
    // Belongs to this resident host, and follows its UUID when pages reorder.
    // A local content revision can revoke today's receipt, not its cold-start
    // priority over neighbours. Host/source retirement discards this state.
    var initialContentInstalled = false
    var presentationFailure: PageTurnPreparationFailure?
    var captureFailure: PageTurnPreparationFailure?
    func failure(requiresCapture: Bool) -> PageTurnPreparationFailure? {
      requiresCapture ? captureFailure : presentationFailure
    }
    mutating func record(_ failure: PageTurnPreparationFailure) {
      if failure.requiresCapture { captureFailure = failure }
      else { presentationFailure = failure }
    }
    mutating func clearFailure(requiresCapture: Bool) {
      if requiresCapture { captureFailure = nil } else { presentationFailure = nil }
    }
  }
  private var pagePreparations: [Int: PagePreparation] = [:]
  private var ownerID: UUID?
  private var sequenceRevision = ""
  private var pageIdentities: [Int: UUID] = [:]
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

  private var isRetired = false
  private var preparationSourceStorage: PageTurnPreparationSource?
  var preparationSource: PageTurnPreparationSource {
    if let preparationSourceStorage { return preparationSourceStorage }
    let source = PageTurnPreparationSource(currentPageID: { [weak self] in
      guard let self, !isRetired else { return nil }
      return controllers[displayedIndex]?.pageID
    }) { [weak self] refine in
      guard let self, !isRetired else { return .waiting }
      return prepareCurrentPage(refinesDetails: refine)
    }
    preparationSourceStorage = source
    return source
  }
  private var lastLayoutSize = CGSize.zero
  private var hasInstalledPage = false
  let pageTurnActivity = PageTurnActivity()
  private var isTransitioning = false
  private var isUpdatingContents = false
  // One latest destination for gestures, steps and explicit selections.
  // The kind affects distant-jump animation, not the ownership of the index.
  private var requestedIndex: Int?
  private var requestIsStep = false
  private var coldGestureTarget: Int?
  private var coldGestureTranslation: CGFloat = 0
  private var coldGestureIsTurning = false
  private var notebookNavigation: NotebookPageNavigation?
  private weak var inputGate: NotebookInputGate?
  private var notebookStatusRevision: UInt64 = 0
  private var lastNotebookStatus: String?
  private var onWindowChange: @MainActor (Set<Int>, Int?, String, UUID) -> Void = { _, _, _, _ in }
  private var anticipatedIndex: Int?
  private var lastTurnDirection: Int?
  /// One admitted physical pair. Indices are directory positions and may
  /// move; these UUIDs and native hosts remain the operation's identities.
  @MainActor private final class Operation {
    let id = UUID()
    let ownerID: UUID?
    let source: IPadIndexedPageController
    let target: IPadIndexedPageController
    let sourceID: UUID?, targetID: UUID?
    let gesture: Bool
    let documentSource: DocumentTurnSourceLease?
    let preparation: PageTurnActivity.PreparationDemand?
    var frames: [UUID: PageTurnFrame] = [:]
    #if DEBUG
    var reportedEndpointWait = false
    #endif
    var completion: ((Bool) -> Void)?
    private(set) var outcome: PageTurnOutcome?
    func complete(_ outcome: PageTurnOutcome) {
      guard self.outcome == nil else { return }
      self.outcome = outcome
      let completion = completion; self.completion = nil
      frames.removeAll(); completion?(outcome == .completed)
    }
    init(ownerID: UUID?, source: IPadIndexedPageController,
      target: IPadIndexedPageController, gesture: Bool,
      documentSource: DocumentTurnSourceLease?, preparation: PageTurnActivity.PreparationDemand?, completion: ((Bool) -> Void)?) {
      self.ownerID = ownerID; self.source = source; self.target = target
      sourceID = source.pageID; targetID = target.pageID; self.gesture = gesture
      self.documentSource = documentSource; self.preparation = preparation; self.completion = completion
    }
    func contains(_ host: IPadIndexedPageController) -> Bool {
      (source === host && sourceID == host.pageID) || (target === host && targetID == host.pageID)
    }
  }
  private var operation: Operation?
  private struct DeferredDocumentUpdate {
    let revision: String
    let callbacks: DocumentPageNavigationCallbacks
    let resolve: (DocumentTurnSourceLease, Int) async throws -> Int
    let apply: (Int) -> Void
  }
  private var deferredDocument: DeferredDocumentUpdate?
  private var documentAdoption: Task<Void, Never>?
  private var documentAdoptionID: UUID?
  private var terminalDocumentSource: DocumentTurnSourceLease?
  private var terminalDocumentPage = 0
  private var documentAdoptionFailure: PageTurnPreparationFailure?
  private var isAdoptingDocumentSource: Bool { deferredDocument != nil && operation == nil }

  private func discardDeferredDocument() {
    documentAdoption?.cancel(); documentAdoption = nil; documentAdoptionID = nil
    deferredDocument = nil; terminalDocumentSource = nil; documentAdoptionFailure = nil
  }
  private func adoptDeferredDocument() {
    guard !isRetired, operation == nil, documentAdoptionID == nil, let pending = deferredDocument else { return }
    let id = UUID(), owner = ownerID, source = terminalDocumentSource, page = terminalDocumentPage
    documentAdoptionID = id; documentAdoptionFailure = nil
    refreshControllerState(); publishDocumentStatus(); preparationSourceStorage?.changed()
    guard documentAdoptionID == id, deferredDocument?.revision == pending.revision else { return }
    documentAdoption = Task { @MainActor [weak self] in
      do {
        let landing: Int
        if let source { landing = try await pending.resolve(source, page) } else { landing = page }
        try Task.checkCancellation()
        guard let self, !isRetired, ownerID == owner, documentAdoptionID == id,
          operation == nil, let latest = deferredDocument, latest.revision == pending.revision else { return }
        documentAdoption = nil; documentAdoptionID = nil; deferredDocument = nil; terminalDocumentSource = nil
        latest.apply(landing)
      } catch {
        guard !Task.isCancelled, let self, !isRetired, documentAdoptionID == id else { return }
        documentAdoption = nil; documentAdoptionID = nil
        documentAdoptionFailure = .init(message: "Не удалось подготовить обновлённый документ") { [weak self] in self?.adoptDeferredDocument() }
        publishDocumentStatus(); preparationSourceStorage?.changed()
      }
    }
  }
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
    for observer in sceneObservers { sceneNotifications.removeObserver(observer) }
    documentAdoption?.cancel()
    if let operation {
      sheetController.resolveMotion(operation.id, completed: false, presented: false)
      operation.complete(.cancelled)
    }
    inputGate?.endNavigation(source: navigationClaimID)
    pageTurnActivity.prepare(nil); pageTurnActivity.didInstall(nil); pageTurnActivity.update(false)
    preparationSourceStorage?.retire()
    documentNavigation?.unbind(documentControllerID)
    notebookNavigation?.unbind(documentControllerID)
    onWindowChange([], nil, sequenceRevision, documentControllerID)
  }

  func uninstall() {
    guard !isRetired else { return }
    isRetired = true; transitionRevision &+= 1
    for observer in sceneObservers { sceneNotifications.removeObserver(observer) }
    sceneObservers.removeAll(); mountedWindow = nil
    discardDeferredDocument()
    inputGate?.endNavigation(source: navigationClaimID)
    requestedIndex = nil; coldGestureTarget = nil; anticipatedIndex = nil
    transitionNotificationTask?.cancel(); transitionNotificationTask = nil
    if let operation { resolveOperation(operation.id, outcome: .cancelled, presented: false, notify: false) }
    pageTurnActivity.prepare(nil); pageTurnActivity.didInstall(nil); pageTurnActivity.update(false)
    for controller in controllers.values { retireContent(of: controller) }
    controllers.removeAll(); pagePreparations.removeAll()
    preparationSourceStorage?.retire()
    documentNavigation?.unbind(documentControllerID); documentNavigation = nil
    notebookNavigation?.unbind(documentControllerID); notebookNavigation = nil
    onWindowChange([], nil, sequenceRevision, documentControllerID); onWindowChange = { _, _, _, _ in }
  }

  private func observe(_ stage: String, target: Int? = nil, reason: String? = nil) {
    guard NotebookNavigationObservation.enabled else { return }
    func index(_ value: Int?) -> JSONValue { value.map { .number(Double($0)) } ?? .null }
    NotebookNavigationObservation.recordDocument(stage, ownerID: observationID, documentID: ownerID,
      fields: ["displayed": index(displayedIndex), "selected": index(selectedIndex),
        "target": index(target), "pending": index(requestedIndex), "anticipated": index(anticipatedIndex),
        "preparationDemandID": pageTurnActivity.preparationDemand.map { .string($0.id.uuidString) } ?? .null,
        "preparationTarget": index(pageTurnActivity.preparationDemand?.pageIndex),
        "reason": reason.map(JSONValue.string) ?? .null,
        "transitionRevision": .string(String(transitionRevision)),
        "transitioning": .bool(isTransitioning), "updatingContents": .bool(isUpdatingContents),
        "window": .bool(viewIfLoaded?.window != nil), "pageCount": index(pageCount),
        "controllers": .array(controllers.keys.sorted().compactMap { page in
          guard let controller = controllers[page] else { return nil }
          return .object(["page": index(page), "hostID": .string(controller.hostID.uuidString),
            "ready": pagePreparations[page].map { .bool($0.readiness.presented) } ?? .null,
            "capturable": pagePreparations[page].map { .bool($0.readiness.capturable) } ?? .null,
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

  override func loadView() {
    let root = IPadPageTurnView(frame: .zero)
    root.windowChanged = { [weak self] window in self?.mountedWindowDidChange(window) }
    view = root
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    let existingHosts = Set(controllers.values.map(\.hostID))
    observeMountedSceneLifetime()
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
      return self.canBeginTurn(to: target)
    }
    sheetController.beginOperation = { [weak self] source, target, gesture, completion in
      self?.beginOperation(source: source, target: target, gesture: gesture, completion: completion)
    }
    sheetController.resolveOperation = { [weak self] id, outcome, presented, notify in
      self?.resolveOperation(id, outcome: outcome, presented: presented, notify: notify)
    }
    sheetController.didAcceptTurn = { [weak self] target in
      guard let self, let target = target as? IPadIndexedPageController,
        controllers[target.pageIndex] === target else { return }
      requestedIndex = target.pageIndex; requestIsStep = true
    }
    sheetController.acquireSheetFrame = { [weak self] controller in
      guard let self, let sheet = controller as? IPadIndexedPageController,
        let operation = self.operation, operation.ownerID == ownerID,
        operation.contains(sheet), controllers[sheet.pageIndex] === sheet else {
        throw PageTurnMaterialUnavailable.changed
      }
      try Task.checkCancellation()
      // Acceptance belongs to this physical operation, one host at a time.
      // A missing/replaced other sheet cannot recapture an already accepted
      // live cut or replace its retained pixels with a later source version.
      if let accepted = operation.frames[sheet.hostID] { return accepted }
      guard let readiness = sheet.readiness, !readiness.isRetired else { throw PageTurnMaterialUnavailable.changed }
      let frame = try await readiness.acquireFrame(priority: .input)
      try Task.checkCancellation()
      guard self.operation === operation, operation.ownerID == ownerID,
        operation.contains(sheet), controllers[sheet.pageIndex] === sheet, sheet.readiness === readiness,
        !readiness.isRetired else {
        NotebookNavigationObservation.onPageMaterialPreparation?("acquire_rejected_controller_owner", sheet.hostID, sheet.pageID, frame.id, nil, CACurrentMediaTime())
        throw PageTurnMaterialUnavailable.changed
      }
      operation.frames[sheet.hostID] = frame
      return frame
    }
    sheetController.hasAcceptedSheetFrame = { [weak self] sheet in
      guard let self, !isRetired, let sheet = sheet as? IPadIndexedPageController,
        let operation, operation.ownerID == ownerID, operation.contains(sheet),
        controllers[sheet.pageIndex] === sheet else { return false }
      return operation.frames[sheet.hostID] != nil
    }
    sheetController.isSheetPresented = { [weak self] sheet in
      guard let self, let sheet = sheet as? IPadIndexedPageController else { return false }
      let ready = controllers[sheet.pageIndex] === sheet && pageIsPresented(at: sheet.pageIndex)
      #if DEBUG
      if !ready, operation?.reportedEndpointWait == false {
        operation?.reportedEndpointWait = true; updatePageDiagnostic("endpoint_wait")
      }
      #endif
      return ready
    }
    sheetController.isSheetReadyForCapture = { [weak self] sheet in
      guard let self, let sheet = sheet as? IPadIndexedPageController else { return false }
      return controllers[sheet.pageIndex] === sheet && pageIsCapturable(at: sheet.pageIndex)
    }
    sheetController.idleOutputHost = { [weak self] sheet in
      guard let self, !isRetired,
        let sheet = sheet as? IPadIndexedPageController,
        controllers[sheet.pageIndex] === sheet,
        let readiness = sheet.readiness, !readiness.isRetired,
        let host = readiness.idleOutputHost,
        let window = sheet.viewIfLoaded?.window,
        host.window === window, host.canParkOutput else { return nil }
      if notebookNavigation != nil {
        guard let pageID = sheet.pageID, let paper = host as? PagePresentationNativeView,
          paper.isOutputHost(for: pageID, in: window) else { return nil }
      } else if documentNavigation == nil { return nil }
      return host
    }
    sheetController.onStageLiveSheet = { [weak self] sheet in
      guard let self, let sheet = sheet as? IPadIndexedPageController,
        controllers[sheet.pageIndex] === sheet else { return }
      pageTurnActivity.stagePresentation(at: sheet.pageIndex)
      #if DEBUG
      updatePageDiagnostic("staged")
      #endif
    }
    sheetController.onFailure = { [weak self] error in
      guard let self, let target = self.anticipatedIndex else { return }
      if self.requestedIndex == nil { self.requestedIndex = target }
      self.pagePreparations[target, default: .init()].captureFailure = .init(requiresCapture: true, message: "Не удалось подготовить перелистывание") { [weak self] in
        guard let self else { return }
        self.pagePreparations[target]?.captureFailure = nil
        self.requestExternalSelection(target)
      }
      self.publishDocumentStatus()
    }
    navigationAdmission.navigationSource = navigationClaimID
    navigationAdmission.contactSequenceDidReset = { [weak self] in
      guard let self, operation == nil, coldGestureTarget == nil else { return }
      inputGate?.endNavigation(source: navigationClaimID)
    }
    navigationAdmission.canBeginNavigation = { [weak self] in
      guard let self else { return false }
      return permitsSceneNavigation && navigationIsEnabled && !isAdoptingDocumentSource && canBeginNavigation()
    }
    navigationAdmission.prepareDirection = { [weak self] direction in
      guard let self else { return true }
      // A fresh swipe during a released sheet's landing is still a contact,
      // not a failed pan. Keep it in the same admission path as a cold leaf.
      // Otherwise the dependent pan refuses motion != nil and loses it forever.
      let settling = (sheetController.settlingPage as? IPadIndexedPageController)?.pageIndex
      if isTransitioning && settling == nil { return true }
      let origin = requestedIndex ?? (isTransitioning ? (settling ?? displayedIndex) : displayedIndex)
      let target = origin + direction
      guard (0..<pageCount).contains(target), claimNavigation(contacts: navigationAdmission.contactIDs) else { return true }
      prepareExternalTarget(target)
      guard isTransitioning || origin != displayedIndex || !pageIsCapturable(at: target) || !pageIsCapturable(at: displayedIndex) else { return true }
      coldGestureTarget = target; coldGestureTranslation = 0
      if !isTransitioning { anticipatedIndex = target }
      coldGestureIsTurning = sheetController.grabSettlement(direction: direction > 0 ? .forward : .reverse)
      retainNeededControllers(); publishDocumentStatus()
      return false
    }
    navigationAdmission.updateColdSwipe = { [weak self] translation in
      guard let self else { return }
      let origin = sheetController.view.convert(CGPoint.zero, from: view.window)
      let point = sheetController.view.convert(CGPoint(x: translation, y: 0), from: view.window)
      coldGestureTranslation = point.x - origin.x
      beginPreparedColdTurn()
      if coldGestureIsTurning { sheetController.updateInteractiveTurn(translation: coldGestureTranslation) }
    }
    navigationAdmission.finishColdSwipe = { [weak self] accepted in
      guard let self else { return }
      let target = coldGestureTarget ?? (coldGestureIsTurning ? anticipatedIndex : nil)
      coldGestureTarget = nil
      if accepted, let target {
        requestedIndex = target; requestIsStep = true
        sheetController.noteNavigationIntent()
      }
      if coldGestureIsTurning {
        coldGestureIsTurning = false
        let origin = sheetController.view.convert(CGPoint.zero, from: view.window)
        let velocityPoint = sheetController.view.convert(CGPoint(x: navigationAdmission.releaseVelocity, y: 0), from: view.window)
        sheetController.endInteractiveTurn(completed: accepted, velocity: velocityPoint.x-origin.x,
          travel: coldGestureTranslation, duration: navigationAdmission.releaseDuration, recordsIntent: false)
        return
      }
      sheetController.endInteractiveTurn(completed: false, recordsIntent: false)
      if self.operation == nil { inputGate?.endNavigation(source: navigationClaimID) }
      if !isTransitioning { anticipatedIndex = nil }
      prepareExternalTarget(requestedIndex); retainNeededControllers(); publishDocumentStatus()
      runPendingExternalSelection()
    }
    sheetController.view.addGestureRecognizer(navigationAdmission)

    installDisplayedPage()
    retainNeededControllers()
    if refreshRenderedPages(only: existingHosts) { retainNeededControllers() }
    refreshControllerState()
    runPendingExternalSelection()
    configureSystemGestures()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    sheetController.view.frame = view.bounds
    if lastLayoutSize != view.bounds.size {
      lastLayoutSize = view.bounds.size; preparationSourceStorage?.changed()
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
    onTransitioningChange: @escaping @MainActor (Bool) -> Void,
    canonicalDocumentLayout: DocumentPageLayout? = nil,
    documentSelection: DocumentPageNavigationRequest? = nil,
    documentNavigation: DocumentPageNavigationCallbacks? = nil,
    notebookNavigation: NotebookPageNavigation? = nil,
    onWindowChange: @escaping @MainActor (Set<Int>, Int?, String, UUID) -> Void = { _, _, _, _ in },
    inputGate: NotebookInputGate? = nil,
    pageIdentities: [Int: UUID] = [:]
  ) {
    guard !isRetired else { return }
    let existingHosts = Set(controllers.values.map(\.hostID))
    let ownerChanged = self.ownerID != ownerID
    if ownerChanged || (self.sequenceRevision == sequenceRevision && deferredDocument != nil) { discardDeferredDocument() }
    if !ownerChanged, let documentNavigation, self.sequenceRevision != sequenceRevision,
      operation != nil || deferredDocument != nil {
      // The admitted operation retains its paper, layout, hosts and render
      // closure. A source successor is adopted only after its terminal pose.
      let replaced = deferredDocument?.revision != sequenceRevision
      deferredDocument = .init(revision: sequenceRevision, callbacks: documentNavigation, resolve: documentNavigation.resolveSourceLanding,
        apply: { [weak self] landing in
          self?.update(ownerID: ownerID, sequenceRevision: sequenceRevision, pageCount: max(pageCount, landing + 1),
            selectedIndex: landing, allowsTrailingPageCreation: allowsTrailingPageCreation,
            navigationIsEnabled: navigationIsEnabled, pageIsInteractive: pageIsInteractive,
            canBeginNavigation: canBeginNavigation, page: page, onCommit: onCommit,
            onTransitioningChange: onTransitioningChange, canonicalDocumentLayout: canonicalDocumentLayout,
            documentSelection: documentSelection, documentNavigation: documentNavigation,
            notebookNavigation: notebookNavigation, onWindowChange: onWindowChange, inputGate: inputGate,
            pageIdentities: pageIdentities)
        })
      self.navigationIsEnabled = navigationIsEnabled; self.pageIsInteractive = pageIsInteractive
      self.canBeginNavigation = canBeginNavigation
      if replaced {
        documentAdoption?.cancel(); documentAdoption = nil; documentAdoptionID = nil; documentAdoptionFailure = nil
      }
      refreshControllerState()
      if operation == nil { adoptDeferredDocument() }
      return
    }
    let previousResolvedTarget = resolvedDocumentTarget
    self.canonicalDocumentLayout = canonicalDocumentLayout
    let sequenceChanged = self.sequenceRevision != sequenceRevision
    let documentSourceChanged = !ownerChanged && sequenceChanged && documentNavigation != nil
    if !ownerChanged, (sequenceChanged || self.pageIdentities != pageIdentities), documentNavigation == nil {
      reconcilePageOrder(pageIdentities, count: max(1, pageCount), sequenceChanged: sequenceChanged)
    }
    self.pageIdentities = pageIdentities
    if ownerChanged {
      self.notebookNavigation?.unbind(documentControllerID)
      self.onWindowChange([], nil, self.sequenceRevision, documentControllerID)
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
    if self.inputGate !== inputGate { self.inputGate?.endNavigation(source: navigationClaimID) }
    self.inputGate = inputGate
    navigationAdmission.inputGate = inputGate
    self.onWindowChange = onWindowChange
    notebookNavigation?.bind(documentControllerID, ownerID: ownerID, source: sequenceRevision) { [weak self] command in
      self?.requestNotebookNavigation(command) ?? false
    }
    documentNavigation?.bind(documentControllerID, ownerID, sequenceRevision)
    if !navigationIsEnabled, notebookNavigation != nil {
      requestedIndex = nil; requestIsStep = false; coldGestureTarget = nil
      if !isTransitioning { anticipatedIndex = nil; prepareExternalTarget(nil) }
    }

    if ownerChanged || documentSourceChanged {
      inputGate?.endNavigation(source: navigationClaimID)
      observe("page_turn_owner_changed")
      pageTurnActivity.didInstall(nil)
      pageTurnActivity.prepare(nil)
      transitionRevision &+= 1
      setTransitioning(false, resetsPublication: true)
      requestedIndex = nil
      requestIsStep = false
      coldGestureTarget = nil
      coldGestureIsTurning = false
      lastNotebookStatus = nil
      anticipatedIndex = nil
      lastTurnDirection = nil
      pagePreparations.removeAll()
      lastDocumentStatus = nil
      lastDocumentLanding = nil
      self.documentSelection = nil
      selection.reset(to: self.selectedIndex)
      if isViewLoaded {
        if ownerChanged { replaceOwnerPages() }
        else {
          // Document pagination belongs to its source, unlike a notebook's
          // UUID directory. Keep its native editing hosts, but retire any
          // request and readiness receipt admitted by the previous source.
          sheetController.cancelMotion(outcome: .superseded, notify: false)
          for controller in controllers.values {
            controller.readiness?.retire(); controller.readiness = nil; controller.readinessID = UUID()
          }
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
        requestIsStep = false
        requestedIndex = resolvedDocumentTarget
        prepareExternalTarget(resolvedDocumentTarget)
        publishDocumentStatus()
      }
    }

    guard isViewLoaded else { return }
    installDisplayedPage()
    retainNeededControllers()
    if refreshRenderedPages(only: existingHosts) { retainNeededControllers() }
    refreshControllerState()
    configureSystemGestures()
    beginPreparedColdTurn()
    runPendingExternalSelection()
    if ownerChanged || documentSourceChanged || sequenceChanged { preparationSourceStorage?.changed() }
    if documentNavigation != nil, !isTransitioning {
      publishDocumentLanding(at: displayedIndex,
        requestID: self.resolvedDocumentTarget == displayedIndex ? self.documentSelection?.id : nil)
    }
  }

  private func claimNavigation(contacts: Set<ObjectIdentifier>) -> Bool {
    guard permitsSceneNavigation else { return false }
    return inputGate?.claimNavigation(source: navigationClaimID, kind: .pageTurn, contacts: contacts) { [weak self] in
      self?.cancelNavigationInteraction()
    } ?? true
  }

  private func cancelNavigationInteraction(outcome: PageTurnOutcome = .superseded) {
    transitionRevision &+= 1
    requestedIndex = nil; requestIsStep = false; coldGestureTarget = nil; anticipatedIndex = nil
    coldGestureIsTurning = false
    sheetController.cancelMotion(outcome: outcome, notify: false)
    inputGate?.endNavigation(source: navigationClaimID)
    pageTurnActivity.didInstall(nil); prepareExternalTarget(nil)
    setTransitioning(false); retainNeededControllers(); refreshControllerState(); publishDocumentStatus()
  }

  private func beginOperation(source: UIViewController, target: UIViewController,
    gesture: Bool, completion: ((Bool) -> Void)?) -> UUID? {
    guard operation == nil, !isAdoptingDocumentSource, let source = source as? IPadIndexedPageController,
      let target = target as? IPadIndexedPageController,
      controllers[source.pageIndex] === source, controllers[target.pageIndex] === target,
      claimNavigation(contacts: gesture ? navigationAdmission.contactIDs : []) else { return nil }
    if gesture {
      transitionRevision &+= 1; coldGestureTarget = nil; anticipatedIndex = target.pageIndex
      prepareExternalTarget(target.pageIndex)
      retainNeededControllers(); setTransitioning(true); refreshControllerState()
    }
    let next = Operation(ownerID: ownerID, source: source, target: target,
      gesture: gesture, documentSource: documentNavigation?.retainSource(), preparation: pageTurnActivity.preparationDemand, completion: completion)
    operation = next
    return next.id
  }

  private func resolveOperation(_ id: UUID, outcome: PageTurnOutcome, presented: Bool, notify: Bool) {
    guard let current = operation, current.id == id else { return }
    // Consume terminal ownership BEFORE callbacks: they may synchronously
    // replace an order, admit the next gesture or dismantle this controller.
    let landingIsCurrent = current.ownerID == ownerID
      && controllers[current.source.pageIndex] === current.source
      && controllers[current.target.pageIndex] === current.target
      && current.source.pageID == current.sourceID && current.target.pageID == current.targetID
    let terminal = outcome == .completed && !landingIsCurrent ? .superseded : outcome
    let landed = terminal == .completed
    operation = nil
    if deferredDocument != nil {
      terminalDocumentSource = current.documentSource
      terminalDocumentPage = landed ? current.target.pageIndex : current.source.pageIndex
    }
    inputGate?.endNavigation(source: navigationClaimID)
    sheetController.resolveMotion(id, completed: landed, presented: presented && landingIsCurrent)
    if !notify {
      coldGestureIsTurning = false
      pageTurnActivity.didInstall(nil); setTransitioning(false)
    } else if current.gesture {
      let preparation: PageTurnActivity.PreparationDemand? = current.preparation.map {
        .init(id: $0.id, pageIndex: current.target.pageIndex, presentation: $0.presentation)
      }
      finishGestureOperation(source: current.source, completed: landed, preparation: preparation)
      sheetController.didTurn(current.source, landed)
    }
    current.complete(terminal)
    #if DEBUG
    updatePageDiagnostic("terminal_\(terminal)")
    #endif
    if deferredDocument != nil { adoptDeferredDocument() }
  }

  func sheetController(
    _ sheetController: IPadSheetCurlController,
    before viewController: UIViewController
  ) -> UIViewController? {
    guard navigationIsEnabled, !isAdoptingDocumentSource,
      let current = viewController as? IPadIndexedPageController,
      controllers[current.pageIndex] === current
    else { return nil }
    return preparedController(at: current.pageIndex - 1)
  }

  func sheetController(
    _ sheetController: IPadSheetCurlController,
    after viewController: UIViewController
  ) -> UIViewController? {
    guard navigationIsEnabled, !isAdoptingDocumentSource,
      let current = viewController as? IPadIndexedPageController,
      controllers[current.pageIndex] === current
    else { return nil }
    return preparedController(at: current.pageIndex + 1)
  }

  @discardableResult
  private func canBeginTurn(to target: UIViewController) -> Bool {
    guard permitsSceneNavigation, canBeginNavigation(), let target = target as? IPadIndexedPageController,
      controllers[target.pageIndex] === target, pageIsCapturable(at: target.pageIndex),
      pageIsCapturable(at: displayedIndex) else { return false }
    return true
  }

  private func finishGestureOperation(source previous: UIViewController, completed: Bool,
    preparation: PageTurnActivity.PreparationDemand?) {
    guard isTransitioning, let previous = previous as? IPadIndexedPageController,
      controllers[previous.pageIndex] === previous,
      let shown = sheetController.page as? IPadIndexedPageController,
      controllers[shown.pageIndex] === shown else { return }
    if completed {
      let target = shown.pageIndex
      recordLanding(at: target)
      if allowsTrailingPageCreation, target == pageCount - 1, pageCount < Int.max { pageCount += 1 }
    } else if previous.pageIndex != displayedIndex { selection.reset(to: previous.pageIndex) }
    pageTurnActivity.didInstall(completed ? preparation : nil)
    anticipatedIndex = nil
    prepareExternalTarget(coldGestureTarget ?? requestedIndex)
    setTransitioning(false)
    retainNeededControllers()
    refreshRenderedPages()
    refreshControllerState()
    if completed, documentNavigation != nil {
      publishDocumentLanding(at: displayedIndex, requestID: nil, deferred: false)
    } else if completed { onCommit(displayedIndex, sequenceRevision) }
    coldGestureIsTurning = false
    beginPreparedColdTurn()
    runPendingExternalSelection()
  }

  private func installDisplayedPage() {
    guard isViewLoaded, !hasInstalledPage else { return }
    hasInstalledPage = true
    isUpdatingContents = true
    guard let controller = controllerForPage(at: displayedIndex) else { isUpdatingContents = false; return }
    sheetController.install(controller)
    isUpdatingContents = false
  }

  /// Order is a directory of stable bodies, not their hosting lifetime. The
  /// provisional last sheet adopts the UUID created by its accepted landing.
  private func reconcilePageOrder(_ identities: [Int: UUID], count: Int, sequenceChanged: Bool) {
    let positions = Dictionary(uniqueKeysWithValues: identities.map { ($0.value, $0.key) })
    let previous = pageIdentities
    let originalDisplayed = displayedIndex, originalTarget = anticipatedIndex
    // Only an accepted local creation can turn a provisional shell into a
    // stored UUID. Other unknown slots cannot acquire another body's identity.
    let createdIndex = allowsTrailingPageCreation && selection.awaitsLocalAcknowledgement
      && selection.pendingIndex == displayedIndex && controllers[displayedIndex]?.pageID == nil
      ? displayedIndex : nil
    func remap(_ index: Int?) -> Int? {
      guard let index else { return nil }
      if let id = previous[index] {
        if let next = positions[id] { return next }
        return !sequenceChanged && index < count && identities[index] == nil ? index : nil
      }
      return index < count && (!sequenceChanged || index == createdIndex) ? index : nil
    }
    let displayed = remap(displayedIndex) ?? min(displayedIndex, count - 1)
    selection.remap(to: displayed, pending: remap(selection.pendingIndex))
    requestedIndex = remap(requestedIndex)
    coldGestureTarget = remap(coldGestureTarget)
    anticipatedIndex = remap(anticipatedIndex)
    var retained: [Int: IPadIndexedPageController] = [:]
    var preparations: [Int: PagePreparation] = [:]
    var remapped: [Int: Int] = [:]
    for (oldIndex, controller) in controllers {
      let next: Int?
      if let id = controller.pageID {
        // The scene read resolves every loaded resident UUID under the new
        // root. Absence there is removal, never permission to reuse its slot.
        next = positions[id] ?? (!sequenceChanged && identities[oldIndex] == nil ? remap(oldIndex) : nil)
      } else { next = remap(oldIndex) }
      guard let next, retained[next] == nil else {
        if sheetController.containsInActiveTurn(controller) || oldIndex == originalDisplayed || oldIndex == originalTarget {
          transitionRevision &+= 1
          sheetController.cancelMotion(notify: false)
          prepareExternalTarget(coldGestureTarget ?? requestedIndex)
        }
        if sheetController.page === controller { hasInstalledPage = false }
        retireContent(of: controller); continue
      }
      remapped[oldIndex] = next
      controller.pageIndex = next
      controller.readiness?.pageIndex = next
      controller.pageID = identities[next] ?? controller.pageID
      controller.view.accessibilityIdentifier = "page-turn-page-\(next)"
      retained[next] = controller
      if let old = pagePreparations[oldIndex] {
        preparations[next] = .init(readiness: old.readiness, initialContentInstalled: old.initialContentInstalled)
      }
    }
    pageTurnActivity.remapElementFrames(remapped)
    controllers = retained; pagePreparations = preparations
    if operation == nil, coldGestureTarget == nil { inputGate?.endNavigation(source: navigationClaimID) }
  }

  private func replaceOwnerPages() {
    guard isViewLoaded else { return }
    sheetController.cancelMotion(outcome: .superseded, notify: false)
    let oldControllers = Array(controllers.values)
    controllers.removeAll()
    pagePreparations.removeAll()
    hasInstalledPage = true
    isUpdatingContents = true

    // Release the previous owner's finite window before preparing the new one.
    for oldController in oldControllers {
      retireContent(of: oldController)
    }
    guard let controller = controllerForPage(at: displayedIndex) else { isUpdatingContents = false; return }
    sheetController.install(controller)
    isUpdatingContents = false
  }

  private func preparedController(
    at index: Int
  ) -> IPadIndexedPageController? {
    guard index >= 0, index < pageCount,
      let controller = controllers[index] else { return nil }
    prepareExternalTarget(index)
    mountForPrewarming(controller)
    guard pageIsCapturable(at: index), pageIsCapturable(at: displayedIndex) else { return nil }
    return controller
  }

  private func controllerForPage(
    at index: Int
  ) -> IPadIndexedPageController? {
    if let controller = controllers[index] { return controller }
    guard (!isTransitioning || canPrepareFollowingStep), controllers.count < PageTurnPrewarmWindow.capacity else { return nil }
    let wasUpdating = isUpdatingContents
    isUpdatingContents = true
    defer { isUpdatingContents = wasUpdating }

    // Admit the physical leaf before its first factory can mount programs.
    // installDisplayedPage and owner replacement reach this path before the
    // normal neighbour-window pass, including an unresolved page UUID.
    onWindowChange(Set(controllers.keys).union([index]),
      anticipatedIndex ?? coldGestureTarget ?? requestedIndex.map(clamped), sequenceRevision, documentControllerID)
    pagePreparations[index] = .init()
    let controller = IPadIndexedPageController(pageIndex: index, rootView: AnyView(EmptyView()))
    controller.pageID = pageIdentities[index]
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

  private var canPrepareFollowingStep: Bool {
    isTransitioning && sheetController.settlingPage != nil && ((requestIsStep && requestedIndex != nil) || coldGestureTarget != nil)
  }

  private func retainNeededControllers() {
    // Source and landing stay pinned through their OS receipt. During a burst,
    // the other two slots can prepare the next demand instead of waiting idle.
    // Held curls and unrelated explicit jumps retain their original window.
    guard isViewLoaded, (!isTransitioning || canPrepareFollowingStep), !isUpdatingContents else { return }
    isUpdatingContents = true
    defer { isUpdatingContents = false }
    let target = canPrepareFollowingStep ? (coldGestureTarget ?? requestedIndex)
      : (anticipatedIndex ?? coldGestureTarget ?? requestedIndex.map(clamped))
    pageTurnActivity.prioritizeRasters(displayed: displayedIndex, target: target,
      displayedContentReady: pagePreparations[displayedIndex]?.initialContentInstalled == true)
    var required = PageTurnPrewarmWindow.indices(
      displayedIndex: displayedIndex,
      anticipatedIndex: target,
      lastDirection: lastTurnDirection,
      pageCount: pageCount,
      existingIndices: Set(controllers.keys),
      turningIndex: canPrepareFollowingStep ? anticipatedIndex : nil
    )
    let awaitingInitialCut = target == nil && pagePreparations[displayedIndex]?.initialContentInstalled != true
    if awaitingInitialCut || target.map({ !pageIsReadyForNavigation(to: $0) }) == true {
      // First install and an explicit cold target own preparation before new
      // speculation. Existing paper stays available for reversals; a demanded
      // target starts immediately even before the source's first visible cut.
      required = required.filter { $0 == displayedIndex || $0 == target || controllers[$0] != nil }
    }
    onWindowChange(required, target, sequenceRevision, documentControllerID)
    // Exactly the finite window owns mounted hosts. No hidden platform cache
    // retains shells or causes a second content lifetime on reverse turns.
    for index in Array(controllers.keys) where !required.contains(index) {
      guard let controller = controllers[index],
        sheetController.page !== controller
      else { continue }
      controllers[index] = nil
      pagePreparations[index] = nil
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
    if sheetController.page === controller {
      // A camera waiting on this physical leaf receives a terminal outcome.
      // Its replacement leaf gets a new source, even at the same directory index.
      preparationSourceStorage?.retire(); preparationSourceStorage = nil
    }
    observe("page_turn_content_retire", target: controller.pageIndex)
    controller.readiness?.retire(); controller.readiness = nil
    pageTurnActivity.retireElementFrames(at: controller.pageIndex)
    sheetController.retire(controller)
    controller.rootView = AnyView(EmptyView())
  }

  private func mountForPrewarming(_ controller: IPadIndexedPageController) {
    sheetController.prepare(controller)
  }

  @discardableResult
  private func refreshRenderedPages(only hosts: Set<UUID>? = nil) -> Bool {
    guard !isTransitioning else { return false }
    let hadInitialCut = pagePreparations[displayedIndex]?.initialContentInstalled == true
    let wasUpdating = isUpdatingContents
    isUpdatingContents = true
    defer { isUpdatingContents = wasUpdating }
    for (index, controller) in controllers {
      // Creation already installed this accepted closure's body. Existing
      // hosts still take every update, including unchanged sequence revisions.
      guard hosts?.contains(controller.hostID) != false else { continue }
      controller.pageID = pageIdentities[index] ?? controller.pageID
      controller.rootView = hostedPage(
        at: index,
        isCurrent: index == displayedIndex,
        hostID: controller.hostID
      )
    }
    // A synchronous readiness callback cannot expand the window while this
    // pass owns its contents. An accepted update completes it afterwards.
    return !hadInitialCut && pagePreparations[displayedIndex]?.initialContentInstalled == true
  }

  private func refreshControllerState() {
    for (index, controller) in controllers {
      let isCurrent = index == displayedIndex
      controller.view.accessibilityElementsHidden = !isCurrent
      controller.view.isUserInteractionEnabled =
        isCurrent && pageIsInteractive && !isTransitioning && !isAdoptingDocumentSource
    }
  }

  private func hostedPage(
    at index: Int,
    isCurrent: Bool,
    hostID: UUID
  ) -> AnyView {
    // The receipt belongs to this retained physical host. Replacing it on
    // every root-view update left the controller's cached ready state attached
    // to a new, empty frame provider. Only a different document source or host
    // retires it; ordinary content updates publish through the same owner.
    if let readiness = controllers[index]?.readiness {
      return AnyView(renderPage(index, isCurrent, readiness).ignoresSafeArea())
    }
    let receiptID = UUID()
    controllers[index]?.readinessID = receiptID
    func current(_ owner: IPadPageTurnController) -> IPadIndexedPageController? {
      owner.controllers.values.first { $0.hostID == hostID && $0.readinessID == receiptID }
    }
    let preparationSource: PageTurnReadiness.AgentPreparationSource = notebookNavigation == nil ? .autonomous : .notebook({ [weak self] in
      guard let self, !isRetired, let controller = current(self), let ownerID,
        notebookNavigation?.isBound(ownerID: ownerID, source: sequenceRevision, controllerID: documentControllerID) == true else { return nil }
      return .init(address: .init(itemID: ownerID, index: controller.pageIndex, root: sequenceRevision),
        pageID: controller.pageID, controllerID: documentControllerID)
    })
    let readiness = PageTurnReadiness(activity: pageTurnActivity, pageIndex: index,
      agentPreparationSource: preparationSource, isInActiveTurn: { [weak self] in
      guard let self, let controller = current(self) else { return false }
      return self.sheetController.containsInActiveTurn(controller)
    }, onFailure: { [weak self] failure in
      guard let self, let controller = current(self) else { return }
      self.pagePreparations[controller.pageIndex, default: .init()].record(failure)
      self.publishDocumentStatus()
      if controller.pageIndex == displayedIndex { preparationSourceStorage?.changed() }
    }, onMaterialChanged: { [weak self] in
      guard let self, let controller = current(self) else { return }
      self.sheetController.sheetReadinessDidChange(controller)
      if controller.pageIndex == displayedIndex { preparationSourceStorage?.changed() }
    }) { [weak self] _ in
      guard let self, let controller = current(self), let state = controller.readiness?.state else { return }
      self.setPage(state: state, at: controller.pageIndex, hostID: hostID)
    }
    controllers[index]?.readiness = readiness
    return AnyView(
      renderPage(index, isCurrent, readiness)
        .ignoresSafeArea()
    )
  }

  private func setPage(state: PageTurnReadiness.State, at index: Int, hostID: UUID) {
    guard controllers[index]?.hostID == hostID else { return }
    guard pagePreparations[index]?.readiness != state else { return }
    let installedInitialCut = state.presented && pagePreparations[index]?.initialContentInstalled != true
    pagePreparations[index, default: .init()].readiness = state
    #if DEBUG
    updatePageDiagnostic("readiness_\(index)")
    #endif
    if state.presented { pagePreparations[index]?.initialContentInstalled = true }
    if index == displayedIndex {
      pageTurnActivity.prioritizeRasters(displayed: displayedIndex,
        target: pageTurnActivity.preparationDemand?.pageIndex,
        displayedContentReady: pagePreparations[index]?.initialContentInstalled == true)
    }
    // Recovery acknowledges only the successful branch. A painted page does
    // not repair an independently failed capture, nor can that error mask paint.
    if state.presented { pagePreparations[index]?.presentationFailure = nil }
    if state.capturable { pagePreparations[index]?.captureFailure = nil }
    if index == displayedIndex { preparationSourceStorage?.changed() }
    observe("page_turn_readiness", target: index, reason: state.capturable ? "capturable" : state.presented ? "presented" : "not_ready")
    if let controller = controllers[index] { sheetController.sheetReadinessDidChange(controller) }
    if state.presented, documentNavigation != nil, index == displayedIndex, hasInstalledPage {
      publishDocumentLanding(at: index, requestID: resolvedDocumentTarget == index ? documentSelection?.id : nil)
    }
    publishDocumentStatus()
    beginPreparedColdTurn()
    runPendingExternalSelection()
    // A mounted status/error cut is a real visible result too. Waiting for
    // author interactivity or capturability here would starve its neighbours.
    if installedInitialCut, index == displayedIndex { retainNeededControllers() }
  }

  private func beginPreparedColdTurn() {
    guard permitsSceneNavigation, let target = coldGestureTarget, target != displayedIndex,
      pageIsCapturable(at: target), pageIsCapturable(at: displayedIndex),
      let controller = controllers[target],
      !isTransitioning, !isUpdatingContents, !isAdoptingDocumentSource, navigationIsEnabled, canBeginNavigation() else { return }
    coldGestureIsTurning = sheetController.beginInteractiveTurn(
      direction: target > displayedIndex ? .forward : .reverse, target: controller)
    if coldGestureIsTurning { sheetController.updateInteractiveTurn(translation: coldGestureTranslation) }
  }

  private func requestExternalSelection(_ index: Int, asStep: Bool = false) {
    guard permitsSceneNavigation, (0..<pageCount).contains(index) else { return }
    let target = clamped(index)
    self.requestedIndex = target; requestIsStep = asStep
    prepareExternalTarget(target)
    if let controller = controllers[target] { sheetController.retargetSettlement(to: controller) }
    observe("page_turn_external_request", target: target)
    guard isViewLoaded, !isTransitioning, !isUpdatingContents else { return }
    guard target != displayedIndex else {
      requestedIndex = nil
      retainNeededControllers()
      return
    }
    retainNeededControllers()
    guard navigationPreparationFailure(to: target) == nil else { publishDocumentStatus(); return }
    guard let targetController = controllers[target] else { return }
    mountForPrewarming(targetController)
    guard pageIsReadyForNavigation(to: target) else {
      observe("page_turn_external_wait", target: target, reason: "passive_target_not_ready")
      publishDocumentStatus()
      return
    }

    // Readiness can arrive during a new contact, long after command admission.
    // The physical input owner fences the actual handoff, not merely the tap.
    let source = sequenceRevision, hostID = targetController.hostID
    let install: NotebookInputCompletion = { [weak self, weak targetController] in
      guard let self, permitsSceneNavigation, let targetController, sequenceRevision == source, requestedIndex == target,
        controllers[target]?.hostID == hostID, pageIsReadyForNavigation(to: target),
        !isTransitioning, !isUpdatingContents else { return }
      beginExternalSelection(target, targetController: targetController)
    }
    if let inputGate { inputGate.performAfterIdle(install) } else { install() }
  }

  private func beginExternalSelection(_ target: Int, targetController: IPadIndexedPageController) {
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

    // A burst retains its latest requested leaf, not an animation queue for
    // every superseded index. It still bends from the actual displayed paper.
    // Distant reference jumps keep their separate direct-install semantics.
    sheetController.show(
      targetController,
      direction: direction,
      animated: (adjacent || requestIsStep) && sheetController.viewIfLoaded?.window != nil
    ) { [weak self] finished in
      guard let self, transitionRevision == revision else { return }
      let currentTarget = targetController.pageIndex
      let installed = preparation.map { PageTurnActivity.PreparationDemand(id: $0.id,
        pageIndex: currentTarget, presentation: $0.presentation) }
      completeExternalSelection(currentTarget, finished: finished, requestID: requestID, preparation: installed)
    }
  }

  private func requestNotebookNavigation(_ command: NotebookPageNavigation.Command) -> Bool {
    // Explicit commands arrive after their caller's input fence. The gesture
    // predicate rejects native buttons and zoomed paper; it cannot govern the
    // very arrow that requested navigation or drop taps during a previous curl.
    guard permitsSceneNavigation, navigationIsEnabled, !isAdoptingDocumentSource else { return false }
    switch command {
    case .cancel:
      requestedIndex = nil; requestIsStep = false; coldGestureTarget = nil
      coldGestureIsTurning = false
      sheetController.cancelMotion()
      anticipatedIndex = nil; prepareExternalTarget(nil)
      retainNeededControllers(); refreshControllerState(); publishDocumentStatus()
    case .step(let delta):
      guard delta == -1 || delta == 1 else { return false }
      let settling = (sheetController.settlingPage as? IPadIndexedPageController)?.pageIndex
      requestedIndex = clamped((requestedIndex ?? settling ?? anticipatedIndex ?? displayedIndex) + delta)
      requestIsStep = true
      sheetController.noteNavigationIntent()
      if let target = requestedIndex, let controller = controllers[target] { sheetController.retargetSettlement(to: controller) }
      retainNeededControllers()
    case .jump(let index):
      guard (0..<pageCount).contains(index) else { return false }
      requestIsStep = false
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
      recordLanding(at: target)
    }
    anticipatedIndex = nil
    pageTurnActivity.didInstall(finished ? preparation : nil)
    prepareExternalTarget(coldGestureTarget ?? requestedIndex)
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
    coldGestureIsTurning = false
    beginPreparedColdTurn()
    let completedRevision = transitionRevision
    Task { @MainActor [weak self] in
      guard let self, transitionRevision == completedRevision else { return }
      runPendingExternalSelection()
    }
  }

  private func recordLanding(at target: Int) {
    let source = displayedIndex
    selection.recordLocalLanding(at: target)
    preparationSourceStorage?.changed()
    lastTurnDirection = target == source ? nil : (target > source ? 1 : -1)
    // Consume the fulfilled intent before publishing selection or enabling a
    // new contact. A later run-loop task is too late to own this boundary.
    if requestedIndex == target { requestedIndex = nil }
    if requestedIndex == nil { requestIsStep = false }
  }

  private func runPendingExternalSelection() {
    guard permitsSceneNavigation, !isTransitioning, !isUpdatingContents, !isAdoptingDocumentSource, coldGestureTarget == nil else { return }
    let target: Int
    if documentNavigation != nil {
      guard let requested = requestedIndex ?? resolvedDocumentTarget else { return }
      target = requested
    } else {
      guard let requested = requestedIndex else { return }
      target = requested
    }
    guard target != displayedIndex else {
      requestedIndex = nil; requestIsStep = false
      pageTurnActivity.prepare(nil)
      publishDocumentStatus()
      return
    }
    requestExternalSelection(target, asStep: requestIsStep)
  }

  private func prepareExternalTarget(_ page: Int?) {
    let target = page.flatMap { $0 == displayedIndex ? nil : $0 }
    let live = documentNavigation != nil && target.map { abs($0 - displayedIndex) > 1 } == true
    pageTurnActivity.prepare(target, presentation: live ? .live : .snapshot)
    pageTurnActivity.prioritizeRasters(displayed: displayedIndex, target: target,
      displayedContentReady: pagePreparations[displayedIndex]?.initialContentInstalled == true)
  }

  private func publishDocumentLanding(at page: Int, requestID: UUID?, deferred: Bool = true) {
    guard let callbacks = documentNavigation, let ownerID,
      pageIsInteractive, viewIfLoaded?.window != nil, hasInstalledPage, pageIsPresented(at: page),
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
    if isAdoptingDocumentSource, let pending = deferredDocument {
      pending.callbacks.bind(documentControllerID, ownerID, pending.revision)
      let phase: DocumentPageNavigationStatus.Phase = documentAdoptionFailure == nil ? .preparing : .failed
      let key = DocumentStatusKey(source: pending.revision, request: nil, target: terminalDocumentPage,
        phase: phase, failure: documentAdoptionFailure?.id)
      guard lastDocumentStatus != key else { return }
      lastDocumentStatus = key; documentStatusRevision &+= 1
      pending.callbacks.status(.init(controllerID: documentControllerID, documentID: ownerID,
        sourceRevision: pending.revision, revision: documentStatusRevision, requestID: nil,
        target: terminalDocumentPage, phase: phase, failure: documentAdoptionFailure))
      return
    }
    let request = documentSelection
    let target = request.flatMap { request -> Int? in
      let target = resolvedDocumentTarget ?? request.pageIndex
      return resolvedDocumentTarget != nil && target == displayedIndex
        && !isTransitioning && pageIsPresented(at: target) ? nil : target
    } ?? (!pageIsPresented(at: displayedIndex) && presentationFailure(at: displayedIndex) != nil ? displayedIndex : nil)
    let failure = documentAdoptionFailure ?? target.flatMap { navigationPreparationFailure(to: $0) }
    let phase: DocumentPageNavigationStatus.Phase? = target == nil ? nil
      : failure != nil ? .failed : isTransitioning ? .transitioning : .preparing
    let key = DocumentStatusKey(source: sequenceRevision, request: request?.id,
      target: target, phase: phase, failure: failure?.id)
    guard key != lastDocumentStatus else { return }
    lastDocumentStatus = key; documentStatusRevision &+= 1
    let retry = failure
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
    let target = isTransitioning ? nil : (requestedIndex ?? coldGestureTarget)
    let failure = target.flatMap { navigationPreparationFailure(to: $0) }
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
    let enabled = permitsSceneNavigation && navigationIsEnabled && pageCount > 1
    if sheetController.pan.isEnabled != enabled { sheetController.pan.isEnabled = enabled }
    if navigationAdmission.isEnabled != permitsSceneNavigation { navigationAdmission.isEnabled = permitsSceneNavigation }
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

  private func pageIsPresented(at index: Int) -> Bool { pagePreparations[index]?.readiness.presented == true }
  private func pageIsCapturable(at index: Int) -> Bool { pagePreparations[index]?.readiness.capturable == true }
  private func navigationRequiresCapture(to index: Int) -> Bool {
    index != displayedIndex && (abs(index - displayedIndex) == 1 || requestIsStep)
  }
  private func pageIsReadyForNavigation(to index: Int) -> Bool {
    if navigationRequiresCapture(to: index) {
      return pageIsCapturable(at: index) && pageIsCapturable(at: displayedIndex)
    }
    return pageIsPresented(at: index)
  }
  private func presentationFailure(at index: Int) -> PageTurnPreparationFailure? {
    retryablePreparationFailure(at: index, requiresCapture: false, requiresCurrentPage: index == displayedIndex)
  }
  private func navigationPreparationFailure(to index: Int) -> PageTurnPreparationFailure? {
    if let failure = presentationFailure(at: index) { return failure }
    guard navigationRequiresCapture(to: index) else { return nil }
    return presentationFailure(at: displayedIndex)
      ?? retryablePreparationFailure(at: index, requiresCapture: true)
      ?? retryablePreparationFailure(at: displayedIndex, requiresCapture: true)
  }

  private func retryablePreparationFailure(at index: Int, requiresCapture: Bool,
    requiresCurrentPage: Bool = false) -> PageTurnPreparationFailure? {
    guard let failure = pagePreparations[index]?.failure(requiresCapture: requiresCapture),
      let hostID = controllers[index]?.hostID else { return nil }
    let source = sequenceRevision, owner = ownerID, request = documentSelection?.id
    return .init(id: failure.id, kind: failure.kind, requiresCapture: failure.requiresCapture, message: failure.message) { [weak self] in
      guard let self, ownerID == owner, sequenceRevision == source,
        controllers[index]?.hostID == hostID, pagePreparations[index]?.failure(requiresCapture: requiresCapture)?.id == failure.id,
        documentSelection?.id == request, !requiresCurrentPage || displayedIndex == index else { return }
      pagePreparations[index]?.clearFailure(requiresCapture: requiresCapture)
      publishDocumentStatus()
      failure.retry()
    }
  }

  func prepareCurrentPage(refinesDetails: Bool) -> PageTurnPreparationState {
    if refinesDetails {
      guard hasInstalledPage, let current = controllers[displayedIndex],
        sheetController.page === current, current.viewIfLoaded?.window != nil else { return .waiting }
      if case .failed = currentPagePreparation { return currentPagePreparation }
      pageTurnActivity.refinePresentation(at: displayedIndex)
    }
    return currentPagePreparation
  }

  var currentPagePreparation: PageTurnPreparationState {
    if isAdoptingDocumentSource { return documentAdoptionFailure.map { .failed($0) } ?? .waiting }
    // Opening exposes the installed writable paper. A neighbouring program's
    // boot or failure cannot hold that paper behind its closed cover. Complete
    // content and an immutable curl cut retain their independent requirements.
    if hasInstalledPage, pagePreparations[displayedIndex]?.readiness.paperReady == true { return .ready }
    if let failure = presentationFailure(at: displayedIndex) { return .failed(failure) }
    return .waiting
  }
  var preparedPageIndices: Set<Int> { Set(pagePreparations.compactMap { $0.value.readiness.capturable ? $0.key : nil }) }
  var presentedPageIndices: Set<Int> { Set(pagePreparations.compactMap { $0.value.readiness.presented ? $0.key : nil }) }

  #if DEBUG
  private func updatePageDiagnostic(_ event: String) {
    guard NotebookNavigationObservation.pageTurnDiagnosticsEnabled, isViewLoaded else { return }
    let indices = Set([displayedIndex, operation?.target.pageIndex].compactMap { $0 })
    let states = indices.sorted().map { index in
      "\(index):\(String(describing: controllers[index]?.readiness?.state));entry=\(String(describing: controllers[index]?.readiness?.notebookPageSource?.sourceVersion.elements));\(controllers[index]?.readiness?.presentationDiagnostic?() ?? "no source")"
    }
    view.accessibilityValue = "\(event); \(navigationStateDescription); staged=\(String(describing: sheetController.diagnosticStagedSheet)); \(states.joined(separator: " | "))"
  }
  var navigationStateDescription: String {
    "shown=\(displayedIndex),selected=\(selectedIndex),ack=\(selection.awaitsLocalAcknowledgement),pending=\(String(describing:requestedIndex)),step=\(requestIsStep),anticipated=\(String(describing:anticipatedIndex)),turning=\(isTransitioning),updating=\(isUpdatingContents),enabled=\(navigationIsEnabled)"
  }
  #endif

  var cachedPageIdentities: [Int: ObjectIdentifier] {
    controllers.mapValues(ObjectIdentifier.init)
  }

  var visiblePageIdentity: ObjectIdentifier? {
    sheetController.page.map(ObjectIdentifier.init)
  }
}

/// The native root reports mounting; its controller owns scene admission and
/// cancellation. A retained controller can enter a new lifetime in the same scene.
@MainActor
private final class IPadPageTurnView: UIView {
  var windowChanged: ((UIWindow?) -> Void)?
  override func didMoveToWindow() {
    super.didMoveToWindow(); windowChanged?(window)
  }
}

/// One hosting lifetime per resident page. Z-order, not reparenting, selects it.
@MainActor
private final class IPadIndexedPageController: UIHostingController<AnyView> {
  var pageIndex: Int
  var pageID: UUID?
  var readinessID = UUID()
  let hostID = UUID()
  var readiness: PageTurnReadiness?
  init(pageIndex: Int, rootView: AnyView) {
    self.pageIndex = pageIndex
    super.init(rootView: rootView)
    view.backgroundColor = .clear
    safeAreaRegions = []
  }
  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("Use init(pageIndex:rootView:)") }
}

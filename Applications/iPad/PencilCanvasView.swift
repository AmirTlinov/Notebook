import NotebookCore
import PencilKit
import SwiftUI
import UIKit

struct PencilCanvasView: UIViewRepresentable {
  @Environment(NotebookAppModel.self) private var model: NotebookAppModel?
  @Environment(\.scenePlaneProjection) private var projection
  let pageID: UUID
  let source: PageInkSource
  var suppressedInkIDs: Set<UUID> = []
  let isInputEnabled: Bool
  let penStyle: PenStyle
  let eraserStyle: EraserStyle
  let drawingTool: DrawingTool
  let inputGate: NotebookInputGate
  let reserveAction: (UUID) -> VersionStamp?
  let releaseAction: (UUID, VersionStamp) -> Void
  let acceptAction: (PageInkAction, UUID, VersionStamp, NotebookQuickShapeFit?) -> PreparedPageInkChange?
  let onRenderReady: (Bool) -> Void
  var resolveQuickShape: (NotebookQuickShapeFit, Double) -> NotebookQuickShapeFit = { fit, _ in fit }
  var onWorkingGraphic: (NotebookWorkingGraphic?, UUID) -> Void = { _, _ in }
  var pageEraserSource: () -> NotebookPageEraserSource? = { nil }
  var onEraserFailure: (Error) -> Void = { _ in }
  var onLiveElementErasing: (ActiveEraserStroke?) -> Void = { _ in }
  var onElementErasing: ([NotebookElementErasing], UUID) -> Void = { _, _ in }

  func makeCoordinator() -> Coordinator {
    Coordinator(
      inputGate: inputGate,
      reserveAction: reserveAction,
      releaseAction: releaseAction,
      acceptAction: acceptAction
    )
  }

  func makeUIView(context: Context) -> PaperCanvasContainerView {
    let paper = PaperCanvasContainerView()
    paper.inkProjection.observe(projection)
    paper.touchView.toolController = model?.drawingTools
    paper.touchView.toolInputGate = inputGate
    paper.touchView.quickShapePageID = pageID
    paper.touchView.resolveQuickShape = resolveQuickShape
    paper.touchView.onWorkingGraphic = onWorkingGraphic
    paper.touchView.pageEraserSource = pageEraserSource
    paper.touchView.onEraserFailure = onEraserFailure
    paper.touchView.onLiveElementErasing = onLiveElementErasing
    paper.touchView.onElementErasing = onElementErasing
    paper.inkView.onRenderReadinessChange = { ready in
      Task { @MainActor in onRenderReady(ready) }
    }
    paper.setInputEnabled(isInputEnabled)
    context.coordinator.attach(to: paper)
    context.coordinator.setPageFinisherCurrent(isInputEnabled)
    context.coordinator.apply(
      penStyle,
      eraserStyle: eraserStyle,
      tool: drawingTool,
      to: paper
    )
    context.coordinator.apply(source, pageID: pageID, to: paper, suppressedIDs: suppressedInkIDs)
    return paper
  }

  func updateUIView(_ paper: PaperCanvasContainerView, context: Context) {
    paper.inkProjection.observe(projection)
    paper.touchView.toolController = model?.drawingTools
    paper.touchView.toolInputGate = inputGate
    paper.touchView.quickShapePageID = pageID
    paper.touchView.resolveQuickShape = resolveQuickShape
    paper.touchView.onWorkingGraphic = onWorkingGraphic
    paper.touchView.pageEraserSource = pageEraserSource
    paper.touchView.onEraserFailure = onEraserFailure
    paper.touchView.onLiveElementErasing = onLiveElementErasing
    paper.touchView.onElementErasing = onElementErasing
    paper.inkView.onRenderReadinessChange = { ready in
      Task { @MainActor in onRenderReady(ready) }
    }
    paper.setInputEnabled(isInputEnabled)
    context.coordinator.use(inputGate)
    context.coordinator.setPageFinisherCurrent(isInputEnabled)
    context.coordinator.reserveAction = reserveAction
    context.coordinator.releaseAction = releaseAction
    context.coordinator.acceptAction = acceptAction
    context.coordinator.apply(
      penStyle,
      eraserStyle: eraserStyle,
      tool: drawingTool,
      to: paper
    )
    context.coordinator.apply(source, pageID: pageID, to: paper, suppressedIDs: suppressedInkIDs)
  }

  static func dismantleUIView(
    _ paper: PaperCanvasContainerView,
    coordinator: Coordinator
  ) {
    paper.inkView.onRenderReadinessChange = nil
    paper.touchView.onLiveElementErasing(nil)
    paper.touchView.onLiveElementErasing = { _ in }
    paper.touchView.pageEraserSource = { nil }
    paper.touchView.onEraserFailure = { _ in }
    coordinator.detach(from: paper)
    paper.touchView.onElementErasing = { _, _ in }
  }

  @MainActor
  final class Coordinator: NSObject {
    var reserveAction: (UUID) -> VersionStamp?
    var releaseAction: (UUID, VersionStamp) -> Void
    private var suppressedInkIDs = Set<UUID>()
    private var actionReservation: (pageID: UUID, stamp: VersionStamp)?
    var acceptAction: (PageInkAction, UUID, VersionStamp, NotebookQuickShapeFit?) -> PreparedPageInkChange?

    private let inputSourceID = UUID()
    private var inputGate: NotebookInputGate
    private var pencilActionIsActive = false
    private var pageID: UUID?
    private var modelSource: PageInkSource?
    private var modelStamp:VersionStamp?
    private var appliedDrawing = PageInkDrawing()
    private var appliedPenStyle: PenStyle?
    private var appliedEraserStyle: EraserStyle?
    private var appliedDrawingTool: DrawingTool?
    private var decodeTask: Task<Void, Never>?
    private var decodeGeneration: UInt64 = 0
    private weak var attachedPaper: PaperCanvasContainerView?
    private var pageFinisherIsCurrent = false

    init(
      inputGate: NotebookInputGate,
      reserveAction: @escaping (UUID) -> VersionStamp?,
      releaseAction: @escaping (UUID, VersionStamp) -> Void,
      acceptAction: @escaping (PageInkAction, UUID, VersionStamp, NotebookQuickShapeFit?) -> PreparedPageInkChange?
    ) {
      self.inputGate = inputGate
      self.reserveAction = reserveAction
      self.releaseAction = releaseAction
      self.acceptAction = acceptAction
    }

    func attach(to paper: PaperCanvasContainerView) {
      attachedPaper = paper
      paper.touchView.simulatesPencilContacts = inputGate.simulatesPencilContacts
      paper.admitsPencilContact = { [weak self, weak paper] touch in
        guard let self, let paper else { return false }
        return inputGate.permitsSceneContact(at: touch.preciseLocation(in: paper.window), kind: .pencil)
      }
      paper.touchView.canBeginAction = { [weak self] in self?.inputGate.permitsNewContact == true }
      paper.touchView.onActionWillBegin = { [weak self] in self?.reserveMeasuredAction() == true }
      paper.touchView.onActionCancelled = { [weak self] in self?.releaseMeasuredAction() }
      paper.touchView.onActionActivityChange = { [weak self] active in
        self?.setPencilActionActive(active)
      }
      paper.touchView.onDrawingMutation = { [weak self, weak paper] mutation in
        guard let self, let paper else { return }
        commit(mutation, on: paper, fit: paper.touchView.completedQuickShape)
      }
      registerPageFinisher(on: paper)
    }

    /// Admission, renderer delta and Undo registration finish in the same
    /// actor segment as the measured lift. Storage owns only the later append.
    func commit(
      _ mutation: PageInkAction,
      on paper: PaperCanvasContainerView, fit: NotebookQuickShapeFit? = nil
    ) {
      guard let reservation = actionReservation else {
        restoreModelDrawing(on: paper)
        return
      }
      actionReservation = nil
      let pageID = reservation.pageID, stamp = reservation.stamp
      decodeTask?.cancel()
      decodeTask = nil
      if let fit { suppressedInkIDs.formUnion(fit.precedingStrokeIDs + [mutation.id]) }
      guard let accepted=acceptAction(mutation,pageID,stamp,fit) else {
        restoreModelDrawing(on:paper);return
      }
      guard pageID == self.pageID else { return }
      modelStamp=accepted.stamp;appliedDrawing=accepted.drawing
      paper.settle(accepted,suppressedInkIDs:suppressedInkIDs)
    }

    private func reserveMeasuredAction() -> Bool {
      guard actionReservation == nil, let pageID, let stamp = reserveAction(pageID) else { return false }
      actionReservation = (pageID, stamp)
      return true
    }

    private func releaseMeasuredAction() {
      guard let reservation = actionReservation else { return }
      actionReservation = nil
      releaseAction(reservation.pageID, reservation.stamp)
    }

    private func registerPageFinisher(on paper: PaperCanvasContainerView) {
      inputGate.registerPageFinisher(source: inputSourceID) {
        [weak paper] _, completion in
        guard let paper else {
          completion()
          return
        }
        paper.touchView.finishCurrentAction(completion:completion)
      }
    }

    func use(_ gate: NotebookInputGate) {
      guard inputGate !== gate else { return }
      inputGate.setCurrentPageSource(
        inputSourceID,
        isCurrent: false
      )
      inputGate.unregisterPageFinisher(source: inputSourceID)
      if pencilActionIsActive {
        inputGate.endPencilAction(source: inputSourceID)
      }
      inputGate = gate
      attachedPaper?.touchView.simulatesPencilContacts = gate.simulatesPencilContacts
      if let attachedPaper { registerPageFinisher(on: attachedPaper) }
      inputGate.setCurrentPageSource(
        inputSourceID,
        isCurrent: pageFinisherIsCurrent
      )
      if pencilActionIsActive {
        inputGate.beginPencilAction(source: inputSourceID)
      }
    }

    func setPageFinisherCurrent(_ isCurrent: Bool) {
      guard pageFinisherIsCurrent != isCurrent else { return }
      pageFinisherIsCurrent = isCurrent
      if !isCurrent { attachedPaper?.touchView.endShapeSequence() }
      inputGate.setCurrentPageSource(
        inputSourceID,
        isCurrent: isCurrent
      )
    }

    func detach(from paper: PaperCanvasContainerView) {
      // A retiring sheet still owns its final measured samples. Transfer them
      // before removing callbacks or releasing the gate's Pencil source.
      paper.touchView.finishCurrentAction {}
      releaseMeasuredAction()
      paper.retireInput()
      paper.touchView.canBeginAction = { false }
      paper.touchView.onActionWillBegin = nil
      paper.touchView.onActionCancelled = nil
      paper.touchView.onActionActivityChange = nil
      paper.touchView.onDrawingMutation = nil
      inputGate.setCurrentPageSource(
        inputSourceID,
        isCurrent: false
      )
      inputGate.unregisterPageFinisher(source: inputSourceID)
      pageFinisherIsCurrent = false
      attachedPaper = nil
      decodeTask?.cancel()
      decodeTask = nil
      setPencilActionActive(false)
    }

    private func setPencilActionActive(_ active: Bool) {
      guard pencilActionIsActive != active else { return }
      pencilActionIsActive = active
      if active {
        inputGate.beginPencilAction(source: inputSourceID)
      } else {
        inputGate.endPencilAction(source: inputSourceID)
      }
    }

    func apply(
      _ style: PenStyle,
      eraserStyle: EraserStyle,
      tool: DrawingTool,
      to paper: PaperCanvasContainerView
    ) {
      guard
        style != appliedPenStyle
          || eraserStyle != appliedEraserStyle
          || tool != appliedDrawingTool
      else {
        return
      }
      appliedPenStyle = style
      appliedEraserStyle = eraserStyle
      appliedDrawingTool = tool
      paper.touchView.configure(
        penStyle: style,
        eraserStyle: eraserStyle,
        drawingTool: tool
      )
    }

    func apply(
      _ source: PageInkSource,
      pageID: UUID,
      to paper: PaperCanvasContainerView, suppressedIDs: Set<UUID> = []
    ) {
      let presentationChanged = suppressedInkIDs != suppressedIDs
      suppressedInkIDs = suppressedIDs
      let pageChanged = self.pageID != pageID
      if !pageChanged, let modelStamp, source.stamp < modelStamp {
        if presentationChanged { paper.inkView.setSuppressedPageActions(suppressedInkIDs) }
        return
      }
      if !pageChanged, modelStamp == source.stamp {
        if presentationChanged { paper.inkView.setSuppressedPageActions(suppressedInkIDs) }
        return
      }
      if pageChanged { paper.touchView.finishCurrentAction {} }
      self.pageID = pageID
      modelSource = source
      modelStamp = source.stamp
      if !pageChanged,paper.touchView.hasActiveAction { return }
      decodeTask?.cancel()
      decodeGeneration &+= 1
      let generation = decodeGeneration
      paper.inkView.prepareForDrawing()
      decodeTask = Task { [weak self, weak paper] in
        let prepared=await Task.detached(priority:.userInitiated) { try? source.drawing() }.value
        guard !Task.isCancelled, let self, let paper,
          decodeGeneration == generation, self.pageID == pageID else { return }
        decodeTask = nil
        guard let drawing=prepared else { return }
        appliedDrawing = drawing
        paper.apply(drawing, suppressedInkIDs: suppressedInkIDs)
      }
    }

    private func restoreModelDrawing(on paper: PaperCanvasContainerView?) {
      guard let paper, let source = modelSource, let pageID else { return }
      modelSource = nil
      apply(source, pageID: pageID, to: paper, suppressedIDs: suppressedInkIDs)
    }

  }
}

@MainActor
final class PaperCanvasContainerView: UIView {
  let inkView = InkCanvasView(frame: .zero)
  lazy var inkProjection = PageInkProjection(host: self, canvas: inkView)
  let touchView = PaperInputView(frame: .zero)
  var admitsPencilContact: (UITouch) -> Bool = { _ in true }
  private let pencil = PaperPencilGestureRecognizer()
  private var inputIsRetired = false

  override init(frame: CGRect) {
    super.init(frame: frame)

    backgroundColor = .clear
    isOpaque = false

    touchView.backgroundColor = .clear
    touchView.isOpaque = false
    touchView.isAccessibilityElement = true
    touchView.accessibilityLabel = "Лист"
    touchView.accessibilityIdentifier = "paper-input"
    touchView.presentActivePen = { [weak inkView] stroke in
      inkView?.displayActiveStroke(stroke)
    }
    touchView.commitActivePen = { [weak inkView] action in
      inkView?.commitActiveStroke(action)
    }
    touchView.presentActiveEraser = { [weak inkView] stroke in
      inkView?.displayActiveEraser(stroke)
    }
    touchView.commitActiveEraser = { [weak inkView] action in
      inkView?.commitActiveEraser(action)
    }
    touchView.clearActiveAction = { [weak inkView] in
      inkView?.clearActiveAction()
    }

    addSubview(inkView)
    addSubview(touchView)
    pencil.name = "NotebookPaperPencil"
    pencil.input = touchView
    pencil.canBeginContact = { [weak self] touch in
      guard let self, !inputIsRetired, touchView.isUserInteractionEnabled,
        sceneReceives(touch, inside: self) else { return false }
      return admitsPencilContact(touch)
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    inkProjection.refresh()
    touchView.frame = bounds
  }

  /// Hit testing precedes UIKit's touch classification, including on a real
  /// Pencil. The window recognizer receives the typed contact; this transparent
  /// layer never guesses its owner from an initially empty UIEvent.allTouches.
  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    nil
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    inkProjection.refresh()
    guard pencil.view !== window else { return }
    if pencil.view != nil { touchView.finishCurrentAction {}; touchView.endShapeSequence() }
    pencil.view?.removeGestureRecognizer(pencil)
    guard !inputIsRetired, let window else { return }
    pencil.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
    if touchView.simulatesPencilContacts {
      pencil.allowedTouchTypes.append(NSNumber(value: UITouch.TouchType.direct.rawValue))
    }
    window.addGestureRecognizer(pencil)
  }

  func retireInput() {
    inkProjection.stop()
    inputIsRetired = true
    touchView.finishCurrentAction {}
    touchView.endShapeSequence()
    pencil.isEnabled = false
    pencil.view?.removeGestureRecognizer(pencil)
    admitsPencilContact = { _ in false }
  }

  func apply(_ drawing: PageInkDrawing, suppressedInkIDs: Set<UUID> = []) {
    inkView.setSuppressedPageActions(suppressedInkIDs)
    inkView.apply(drawing)
    touchView.apply(drawing)
  }

  func settle(_ change: PreparedPageInkChange, suppressedInkIDs: Set<UUID> = []) {
    inkView.settle(change, suppressedInkIDs:suppressedInkIDs)
    touchView.acceptCommittedDrawing(change.drawing)
  }

  func setInputEnabled(_ enabled: Bool) {
    touchView.isUserInteractionEnabled = enabled
    touchView.isAccessibilityElement = enabled
    touchView.accessibilityElementsHidden = !enabled
    pencil.isEnabled = enabled && !inputIsRetired
  }
}

/// One typed contact feeds the existing measured ink owner. UIKit may initially
/// hit the HTML or hosting view underneath the paper; Pencil cancels that view's
/// contact, while ordinary fingers remain entirely outside this recognizer.
@MainActor
final class PaperPencilGestureRecognizer: UIGestureRecognizer {
  weak var input: PaperInputView?
  var canBeginContact: (UITouch) -> Bool = { _ in false }
  private var activeTouch: UITouch?

  override init(target: Any?, action: Selector?) {
    super.init(target: target, action: action)
    cancelsTouchesInView = true
    delaysTouchesBegan = false
    delaysTouchesEnded = false
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
    guard activeTouch == nil else { finishTracking(); state = .cancelled; return }
    guard let input, let touch = touches.first,
      input.acceptsDrawingTouch(touch), canBeginContact(touch) else {
      finishTracking(); state = .failed; return
    }
    input.touchesBegan([touch], with: event)
    guard input.hasActiveAction else { state = .failed; return }
    activeTouch = touch; state = .began
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
    guard let touch = activeTouch, touches.contains(touch) else { return }
    input?.touchesMoved([touch], with: event); state = .changed
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
    guard let touch = activeTouch, touches.contains(touch) else { return }
    activeTouch = nil
    input?.touchesEnded([touch], with: event); state = .ended
  }

  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
    guard let touch = activeTouch, touches.contains(touch) else { return }
    activeTouch = nil
    input?.touchesCancelled([touch], with: event); state = .cancelled
  }

  override func touchesEstimatedPropertiesUpdated(_ touches: Set<UITouch>) {
    input?.touchesEstimatedPropertiesUpdated(touches)
  }

  override func reset() { finishTracking(); super.reset() }

  private func finishTracking() {
    guard activeTouch != nil else { return }
    activeTouch = nil; input?.finishCurrentAction {}
  }
}

@MainActor
final class PaperInputView: UIView {
  var simulatesPencilContacts = false
  var canBeginAction: () -> Bool = { true }
  var onActionWillBegin: (() -> Bool)?
  var onActionCancelled: (() -> Void)?
  var onDrawingMutation: ((PageInkAction) -> Void)?
  var onActionActivityChange: ((Bool) -> Void)?
  var presentActivePen: ((ActiveInkStroke) -> Void)?
  var commitActivePen: ((PageInkAction) -> Void)?
  var presentActiveEraser: ((ActiveEraserStroke) -> Void)?
  var commitActiveEraser: ((PageInkAction) -> Void)?
  var clearActiveAction: (() -> Void)?
  var resolveQuickShape: (NotebookQuickShapeFit, Double) -> NotebookQuickShapeFit = { fit, _ in fit }
  var onWorkingGraphic: (NotebookWorkingGraphic?, UUID) -> Void = { _, _ in }
  var pageEraserSource: () -> NotebookPageEraserSource? = { nil }
  var onEraserFailure: (Error) -> Void = { _ in }
  var onLiveElementErasing: (ActiveEraserStroke?) -> Void = { _ in }
  var onElementErasing: ([NotebookElementErasing], UUID) -> Void = { _, _ in }

  weak var toolController: NotebookDrawingToolController?
  weak var toolInputGate: NotebookInputGate?
  private var toolContact: NotebookToolInputContact?
  var hasActiveAction: Bool { actionTool != nil || toolContact != nil }
  private let quickShape = NotebookQuickShapeSession()
  var quickShapePageID: UUID? { didSet { if oldValue != quickShapePageID { quickShape.cancel() } } }
  private(set) var completedQuickShape: NotebookQuickShapeFit?


  override var canBecomeFirstResponder: Bool { false }

  override var editingInteractionConfiguration: UIEditingInteractionConfiguration {
    .none
  }

  private struct Sample {
    var point: PKStrokePoint
    let timestamp: TimeInterval
  }

  private static let estimateWait = Duration.milliseconds(120)

  private var drawing = PageInkDrawing()
  private var penStyle = PenStyle.standard
  private var eraserStyle = EraserStyle.standard
  private var drawingTool = DrawingTool.pen

  private var activeTouch: UITouch?
  private var actionTool: DrawingTool?
  private var actionPenStyle: PenStyle?
  private var actionEraserStyle: EraserStyle?
  private var actionStrokeID = UUID()
  private var actionStartTimestamp: TimeInterval = 0
  private var samples: [Sample] = []
  private var predictedSamples: [Sample] = []
  private var activePenStroke: ActiveInkStroke?
  private var activeEraserStroke: ActiveEraserStroke?
  private var filteredPenForces: [CGFloat] = []
  private var pendingForceEstimates: [NSNumber: Int] = [:]
  private var actionHasEnded = false
  private var actionEndedNormally = false
  private var reportsPencilActivity = false

  private var finalizationTask: Task<Void, Never>?
  private var actionCompletions: [() -> Void] = []

  override init(frame: CGRect) {
    super.init(frame: frame)
    isMultipleTouchEnabled = true
    quickShape.onChange = { [weak self] fit in
      guard let self else { return }
      if let fit, let pageID = quickShapePageID {
        let color = (actionPenStyle ?? penStyle).color.components
        onWorkingGraphic(.init(strokeID: actionStrokeID, fit: fit, surface: .page(pageID),
          color: .init(red: color.red, green: color.green, blue: color.blue),
          width: Double(samples.first?.point.size.width ?? 2)), actionStrokeID)
        clearActiveAction?()
      } else {
        onWorkingGraphic(nil, actionStrokeID)
        if let activePenStroke { presentActivePen?(activePenStroke) }
      }
    }
    updateAccessibilityValue()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }

  func configure(
    penStyle: PenStyle,
    eraserStyle: EraserStyle,
    drawingTool: DrawingTool
  ) {
    if self.penStyle != penStyle || self.drawingTool != drawingTool { quickShape.cancel() }
    self.penStyle = penStyle
    self.eraserStyle = eraserStyle
    self.drawingTool = drawingTool
  }

  func apply(_ drawing: PageInkDrawing) {
    cancelCurrentAction()
    self.drawing = drawing
    updateAccessibilityValue()
  }

  /// Accepts the durable result without replacing the exact Metal mesh that
  /// was already committed under the person's hand.
  func acceptCommittedDrawing(_ drawing: PageInkDrawing) {
    self.drawing = drawing
    updateAccessibilityValue()
  }

  func endShapeSequence() { quickShape.cancel() }

  func finishCurrentAction(completion: @escaping () -> Void) {
    if let contact = toolContact { toolContact = nil; activeTouch = nil; contact.finish(cancelled:true) }
    if activeTouch != nil { quickShape.cancel(); actionEndedNormally = false }
    // The input gate calls this at every ordinary lift to join publication.
    // Draining a completed stroke is not a navigation/cancellation boundary.
    guard actionTool != nil else {
      completion()
      return
    }
    actionCompletions.append(completion)
    activeTouch = nil
    actionHasEnded = true
    predictedSamples = []
    pendingForceEstimates = [:]
    showMeasuredActionWithoutPredictions()
    finalizeAction()
  }

  override func canPerformAction(
    _ action: Selector,
    withSender sender: Any?
  ) -> Bool {
    false
  }

  override func buildMenu(with builder: any UIMenuBuilder) {}

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    guard let touch = drawingTouch(in: touches) else { return }
    beginAction(with: touch, event: event)
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
    guard let touch = drawingTouch(in: touches), touch === activeTouch else {
      return
    }
    updateAction(with: touch, event: event)
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
    guard let touch = drawingTouch(in: touches), touch === activeTouch else {
      return
    }
    if let contact = toolContact {
      toolContact = nil; activeTouch = nil
      contact.move(to:touch.preciseLocation(in:self)); contact.finish(); return
    }
    updateAction(with: touch, event: event)
    activeTouch = nil
    actionHasEnded = true
    actionEndedNormally = true
    predictedSamples = []
    showMeasuredActionWithoutPredictions()

    if pendingForceEstimates.isEmpty {
      finalizeAction()
    } else {
      scheduleFinalization()
    }
  }

  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
    guard let touch = drawingTouch(in: touches), touch === activeTouch else {
      return
    }
    if let contact = toolContact { toolContact = nil; activeTouch = nil; contact.finish(cancelled:true); return }
    quickShape.cancel()
    actionEndedNormally = false
    activeTouch = nil
    actionHasEnded = true
    predictedSamples = []
    showMeasuredActionWithoutPredictions()
    finalizeAction()
  }

  override func touchesEstimatedPropertiesUpdated(_ touches: Set<UITouch>) {
    guard actionTool != nil else { return }

    var firstChangedIndex: Int?
    for touch in touches where touch.type == .pencil {
      guard let updateIndex = touch.estimationUpdateIndex,
        let sampleIndex = pendingForceEstimates[updateIndex],
        samples.indices.contains(sampleIndex)
      else { continue }

      let timestamp = samples[sampleIndex].timestamp
      let updated = makeSample(from: touch, timestamp: timestamp)
      if samples[sampleIndex].point.location != updated.point.location { quickShape.cancel() }
      samples[sampleIndex] = updated
      firstChangedIndex = min(firstChangedIndex ?? sampleIndex, sampleIndex)

      if !touch.estimatedPropertiesExpectingUpdates.contains(.force) {
        pendingForceEstimates.removeValue(forKey: updateIndex)
      }
    }

    guard let firstChangedIndex else { return }
    rebuildProcessedActionPoints(from: firstChangedIndex)
    refreshAction()
    if actionHasEnded && pendingForceEstimates.isEmpty {
      finalizeAction()
    }
  }

  private func drawingTouch(in touches: Set<UITouch>) -> UITouch? {
    if let pencil = touches.first(where: { $0.type == .pencil }) {
      return pencil
    }
    return touches.first(where: acceptsDrawingTouch)
  }

  private var elementContact = InkElementContact([])
  private var reportedElementTargetIDs = Set<String>()
  private var activePageEraserSource: NotebookPageEraserSource?
  private var elementEraserFailed = false

  private func beginAction(with touch: UITouch, event: UIEvent?) {
    guard canBeginAction() else { return }
    if actionTool != nil {
      finalizeAction()
    }
    if !drawingTool.usesInkJournal {
      guard let controller = toolController, let gate = toolInputGate, let pageID = quickShapePageID else { return }
      let a = convert(CGPoint.zero,to:window), b = convert(CGPoint(x:1,y:0),to:window)
      toolContact = .init(controller:controller,gate:gate,view:self,
        address:.init(surface:.page(pageID),boardID:nil,worldOrigin:nil,bounds:bounds),
        point:touch.preciseLocation(in:self),screenScale:max(0.001,hypot(b.x-a.x,b.y-a.y)),
        toOwner:{ .init(x:$0.x,y:$0.y) })
      toolContact?.onFinish = { [weak self] in self?.toolContact = nil; self?.activeTouch = nil }
      if toolContact != nil { activeTouch = touch }
      return
    }
    guard onActionWillBegin?() != false else { return }

    activeTouch = touch
    actionTool = drawingTool
    elementContact = InkElementContact([])
    activePageEraserSource = drawingTool == .eraser ? pageEraserSource() : nil
    elementEraserFailed = false
    reportsPencilActivity = touch.type == .pencil || simulatesPencilContacts
    if reportsPencilActivity { onActionActivityChange?(true) }
    actionPenStyle = penStyle
    actionEraserStyle = eraserStyle
    actionStrokeID = UUID()
    actionStartTimestamp = touch.timestamp
    samples = []
    predictedSamples = []
    activePenStroke =
      actionTool?.drawsInk == true
      ? actionPenStyle.map { ActiveInkStroke(style:$0,sourceID:actionStrokeID) }
      : nil
    activeEraserStroke =
      actionTool == .eraser
      ? ActiveEraserStroke(sourceID:actionStrokeID,color:inkColor(actionPenStyle ?? penStyle))
      : nil
    filteredPenForces = []
    pendingForceEstimates = [:]
    actionHasEnded = false
    actionEndedNormally = false
    actionCompletions = []

    addActualSamples(for: touch, event: event)
    updatePredictions(for: touch, event: event)
    refreshAction()
    completedQuickShape = nil
    if actionTool == .pen, let first = samples.first?.point.location {
      let a = convert(CGPoint.zero, to: window), b = convert(CGPoint(x: 1, y: 0), to: window)
      let scale = max(0.001, hypot(b.x-a.x,b.y-a.y)), resolve = resolveQuickShape
      quickShape.begin(at: .init(x: first.x, y: first.y), screenScale:scale,resolve:{ resolve($0,scale) }) { [weak self] in
        self?.samples.map { .init(x: $0.point.location.x, y: $0.point.location.y) } ?? []
      }
    } else { quickShape.cancel() }
  }

  private func updateAction(with touch: UITouch, event: UIEvent?) {
    if let contact = toolContact { contact.move(to:touch.preciseLocation(in:self)); return }
    if quickShape.fit != nil {
      let point = touch.preciseLocation(in: self)
      quickShape.move(to: .init(x: point.x, y: point.y)); return
    }
    addActualSamples(for: touch, event: event)
    if let point = samples.last?.point.location { quickShape.move(to: .init(x: point.x, y: point.y)) }
    if quickShape.fit == nil {
      updatePredictions(for: touch, event: event)
      refreshAction()
    }
  }

  private func addActualSamples(for touch: UITouch, event: UIEvent?) {
    let coalesced = event?.coalescedTouches(for: touch) ?? [touch]
    var firstChangedIndex: Int?
    for sampleTouch in coalesced where acceptsDrawingTouch(sampleTouch) {
      guard let changedIndex = appendActualSample(from: sampleTouch) else {
        continue
      }
      firstChangedIndex = min(firstChangedIndex ?? changedIndex, changedIndex)
    }
    if let firstChangedIndex {
      rebuildProcessedActionPoints(from: firstChangedIndex)
    }
  }

  func acceptsDrawingTouch(_ touch: UITouch) -> Bool {
    touch.type == .pencil || (simulatesPencilContacts && touch.type == .direct)
  }

  @discardableResult
  private func appendActualSample(from touch: UITouch) -> Int? {
    let timestamp = max(0, touch.timestamp - actionStartTimestamp)
    let sample = makeSample(from: touch, timestamp: timestamp)

    if let lastIndex = samples.indices.last,
      abs(samples[lastIndex].timestamp - timestamp) < 0.000_001
    {
      samples[lastIndex] = sample
      pendingForceEstimates = pendingForceEstimates.filter {
        $0.value != lastIndex
      }
      registerForceEstimate(for: touch, at: lastIndex)
      return lastIndex
    }

    guard samples.last.map({ timestamp > $0.timestamp }) ?? true else {
      return nil
    }
    samples.append(sample)
    let sampleIndex = samples.count - 1
    registerForceEstimate(for: touch, at: sampleIndex)
    return sampleIndex
  }

  private func registerForceEstimate(for touch: UITouch, at sampleIndex: Int) {
    guard touch.estimatedPropertiesExpectingUpdates.contains(.force),
      let updateIndex = touch.estimationUpdateIndex
    else { return }
    pendingForceEstimates[updateIndex] = sampleIndex
  }

  private func updatePredictions(for touch: UITouch, event: UIEvent?) {
    guard actionTool?.drawsInk == true else {
      // A corrected pen prediction replaces temporary ink. A corrected eraser
      // prediction would make cleared ink flash back into existence.
      predictedSamples = []
      return
    }
    predictedSamples = (event?.predictedTouches(for: touch) ?? [])
      .filter(acceptsDrawingTouch)
      .map {
        makeSample(
          from: $0,
          timestamp: max(0, $0.timestamp - actionStartTimestamp)
        )
      }
  }

  private func makeSample(from touch: UITouch, timestamp: TimeInterval) -> Sample {
    let tool = actionTool ?? drawingTool
    let normalizedForce = normalizedForce(for: touch)
    let width: CGFloat
    let opacity: CGFloat
    switch tool {
    case .pen, .marker:
      let style = actionPenStyle ?? penStyle
      width = CGFloat(style.width)
      opacity = CGFloat(
        style.opacity(force:Double(normalizedForce))
      )
    case .eraser:
      let style = actionEraserStyle ?? eraserStyle
      width = CGFloat(
        style.maximumWidth
      )
      opacity = 1
    default: preconditionFailure("Non-ink contact entered the ink sampler")
    }
    let point = PKStrokePoint(
      location: touch.preciseLocation(in: self),
      timeOffset: timestamp,
      size: CGSize(width: width, height: width),
      opacity: opacity,
      force: normalizedForce,
      azimuth: touch.azimuthAngle(in: self),
      altitude: touch.altitudeAngle
    )
    return Sample(point: point, timestamp: timestamp)
  }

  private func normalizedForce(for touch: UITouch) -> CGFloat {
    #if targetEnvironment(simulator)
      if touch.type == .direct { return 1 }
    #endif
    return CGFloat(
      PencilPressure.normalized(
        force: Double(touch.force),
        maximum: Double(touch.maximumPossibleForce)
      )
    )
  }

  private func rebuildProcessedActionPoints(from changedIndex: Int) {
    if actionTool == .eraser, let activeEraserStroke {
      let startIndex = min(max(changedIndex, 0), samples.count)
      activeEraserStroke.replaceMeasuredTail(
        from: startIndex,
        with: samples[startIndex...].map { SpatialInkSample($0.point) }
      )
      if !elementEraserFailed,let source=activePageEraserSource,
        let bounds=pageEraserBounds(activeEraserStroke.measured,from:startIndex) {
        do {
          let query=try source.query(bounds:bounds)
          elementContact.update(activeEraserStroke.measured,from:startIndex,
            queried:query.targets,visitedNodes:query.visitedNodes)
        } catch { failElementEraser(error,sourceID:activeEraserStroke.measured.sourceID) }
      }
      let targets = elementContact.selected
      let targetIDs = Set(targets.map(\.elementID))
      if targetIDs != reportedElementTargetIDs, let pageID = quickShapePageID {
        reportedElementTargetIDs = targetIDs
        let id = activeEraserStroke.measured.sourceID
        onElementErasing(
          targets.isEmpty ? [] : [
            .init(
              id: id,
              surface: .page(pageID),
              samples: activeEraserStroke.measured.frozen().measurements,
              targets: targets
            )
          ],
          id
        )
      }
      return
    }

    guard actionTool?.drawsInk == true,
      let style = actionPenStyle,
      let activePenStroke
    else { return }
    let startIndex = min(max(changedIndex, 0), samples.count)

    if startIndex == 0 {
      filteredPenForces.removeAll(keepingCapacity: true)
    } else {
      filteredPenForces.removeSubrange(startIndex...)
    }

    var processedTail: [PKStrokePoint] = []
    processedTail.reserveCapacity(samples.count - startIndex)

    var previousForce = filteredPenForces.last
    var previousTimestamp =
      startIndex > 0
      ? samples[startIndex - 1].timestamp
      : nil

    for index in startIndex..<samples.count {
      let sample = samples[index]
      let filteredForce = filteredForce(
        sample.point.force,
        after: previousForce,
        elapsed: previousTimestamp.map { sample.timestamp - $0 }
      )
      filteredPenForces.append(filteredForce)
      processedTail.append(
        penPoint(
          from: sample.point,
          filteredForce: filteredForce,
          style: style
        )
      )
      previousForce = filteredForce
      previousTimestamp = sample.timestamp
    }
    activePenStroke.replaceMeasuredTail(
      from: startIndex,
      with: processedTail.map(SpatialInkSample.init)
    )
  }

  private func pageEraserBounds(_ source:InkSampleRelations.Contact,
    from changedIndex:Int)->CGRect? {
    guard source.count > changedIndex else { return nil }
    var bounds=CGRect.null
    let start=max(0,changedIndex-1)
    source.forEach(in:start..<source.count) { sample in
      let radius=sample.width/2
      bounds=bounds.union(.init(x:sample.point.x-radius,y:sample.point.y-radius,
        width:radius*2,height:radius*2))
    }
    return bounds.isNull ? nil : bounds
  }

  private func failElementEraser(_ error:Error,sourceID:UUID) {
    guard !elementEraserFailed else { return }
    elementEraserFailed=true;elementContact=InkElementContact([])
    if !reportedElementTargetIDs.isEmpty { onElementErasing([],sourceID) }
    reportedElementTargetIDs.removeAll(keepingCapacity:true)
    onEraserFailure(error)
  }

  private func processedPredictedPenPoints() -> [PKStrokePoint] {
    guard actionTool?.drawsInk == true, let style = actionPenStyle else { return [] }
    var result: [PKStrokePoint] = []
    result.reserveCapacity(predictedSamples.count)
    var previousForce = filteredPenForces.last
    var previousTimestamp = samples.last?.timestamp

    for sample in predictedSamples {
      let filteredForce = filteredForce(
        sample.point.force,
        after: previousForce,
        elapsed: previousTimestamp.map { sample.timestamp - $0 }
      )
      result.append(
        penPoint(
          from: sample.point,
          filteredForce: filteredForce,
          style: style
        )
      )
      previousForce = filteredForce
      previousTimestamp = sample.timestamp
    }
    return result
  }

  private func filteredForce(
    _ force: CGFloat,
    after previous: CGFloat?,
    elapsed: TimeInterval?
  ) -> CGFloat {
    CGFloat(
      PencilPressureSmoothing.value(
        force: Double(force),
        previous: previous.map(Double.init),
        elapsed: elapsed
      )
    )
  }

  private func penPoint(
    from point: PKStrokePoint,
    filteredForce: CGFloat,
    style: PenStyle
  ) -> PKStrokePoint {
    PKStrokePoint(
      location: point.location,
      timeOffset: point.timeOffset,
      size: point.size,
      opacity: CGFloat(
        style.opacity(force:Double(filteredForce))
      ),
      force: point.force,
      azimuth: point.azimuth,
      altitude: point.altitude,
      secondaryScale: point.secondaryScale,
      threshold: point.threshold
    )
  }

  private func showMeasuredActionWithoutPredictions() {
    guard quickShape.fit == nil else { return }
    if actionTool == .eraser, let activeEraserStroke {
      presentActiveEraser?(activeEraserStroke)
      onLiveElementErasing(activeEraserStroke)
    } else if let activePenStroke {
      activePenStroke.replacePredictions(with: [])
      presentActivePen?(activePenStroke)
    }
  }

  private func refreshAction() {
    guard actionTool != nil, !samples.isEmpty, quickShape.fit == nil else { return }
    predictedSamples = predictedSamples.filter {
      $0.timestamp > (samples.last?.timestamp ?? 0)
    }

    if actionTool == .eraser, let activeEraserStroke {
      presentActiveEraser?(activeEraserStroke)
      onLiveElementErasing(activeEraserStroke)
    } else if let activePenStroke {
      activePenStroke.replacePredictions(
        with: processedPredictedPenPoints().map(SpatialInkSample.init)
      )
      presentActivePen?(activePenStroke)
    }
  }

  private func inkColor(_ style: PenStyle) -> SpatialInkColor {
    let c=style.color.components;return .init(red:c.red,green:c.green,blue:c.blue)
  }
  private func actionMutation() -> PageInkAction? {
    guard let source=activePenStroke?.measured ?? activeEraserStroke?.measured else { return nil }
    let count=min(source.count,quickShape.fit?.sampleCount ?? source.count)
    guard count > 0 else { return nil }
    // Freeze the accepted tree; predictions never enter the durable source.
    let action = source.frozen(through:count).restoredAction()
    return PageInkAction(id: action.id, tool: action.tool, color: action.color, measurements: action.samples,
      sequence: action.sequence, isActive: action.isActive, elementTargets: elementContact.selected)
  }

  private func scheduleFinalization() {
    finalizationTask?.cancel()
    finalizationTask = Task { [weak self] in
      try? await Task.sleep(for: Self.estimateWait)
      guard !Task.isCancelled, let self else { return }
      finalizeAction()
    }
  }

  private func finalizeAction() {
    guard actionTool != nil else { return }
    finalizationTask?.cancel()
    finalizationTask = nil
    guard let mutation = actionMutation() else {
      finishActionWithoutMutation()
      return
    }
    finishAction(with: mutation)
  }

  private func finishAction(with mutation: PageInkAction) {
    let completions = actionCompletions
    let fit = quickShape.finish()
    let tool = actionTool
    let continuesSequence = actionEndedNormally && tool == .pen && actionPenStyle == penStyle
    if tool?.drawsInk == true, fit == nil {
      commitActivePen?(mutation)
    } else if tool == .eraser {
      commitActiveEraser?(mutation)
    }
    let reportedPencilActivity = clearAction(preservingShapeHistory: continuesSequence)
    if continuesSequence, fit == nil {
      quickShape.remember(mutation.id, points: mutation.samples.count <= 8192
        ? mutation.samples.map { .init(x:$0.point.x,y:$0.point.y) } : [])
    }
    completedQuickShape = fit
    onDrawingMutation?(mutation)
    completedQuickShape = nil
    if reportedPencilActivity { onActionActivityChange?(false) }
    for completion in completions {
      completion()
    }
  }

  private func finishActionWithoutMutation() {
    let completions = actionCompletions
    let reportedPencilActivity = clearAction()
    onActionCancelled?()
    if reportedPencilActivity { onActionActivityChange?(false) }
    for completion in completions {
      completion()
    }
  }

  private func cancelCurrentAction() {
    if let contact = toolContact { toolContact = nil; contact.finish(cancelled:true) }
    finalizationTask?.cancel()
    finalizationTask = nil
    let reportedPencilActivity = clearAction()
    onActionCancelled?()
    if reportedPencilActivity { onActionActivityChange?(false) }
  }

  private func clearAction(preservingShapeHistory: Bool = false) -> Bool {
    if preservingShapeHistory { quickShape.endContact() } else { quickShape.cancel() }
    let reportedPencilActivity = reportsPencilActivity
    clearActiveAction?()
    onLiveElementErasing(nil)
    if let id = activeEraserStroke?.measured.sourceID, !reportedElementTargetIDs.isEmpty {
      onElementErasing([], id)
    }
    reportedElementTargetIDs.removeAll(keepingCapacity: true)
    elementContact = InkElementContact([])
    activePageEraserSource = nil
    elementEraserFailed = false
    activeTouch = nil
    actionTool = nil
    actionPenStyle = nil
    actionEraserStyle = nil
    samples = []
    predictedSamples = []
    activePenStroke = nil
    activeEraserStroke = nil
    filteredPenForces = []
    pendingForceEstimates = [:]
    actionHasEnded = false
    actionEndedNormally = false
    actionCompletions = []
    reportsPencilActivity = false
    return reportedPencilActivity
  }

  private func updateAccessibilityValue() {
    accessibilityValue = "\(drawing.actionCount) действий пера"
  }
}

extension PenStyle {
  fileprivate func uiColor(alpha: Double) -> UIColor {
    let components = color.components
    return UIColor(
      red: CGFloat(components.red),
      green: CGFloat(components.green),
      blue: CGFloat(components.blue),
      alpha: CGFloat(alpha)
    )
  }
}

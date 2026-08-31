import PencilKit
import SwiftUI
import NotebookCore
import UIKit

struct PencilCanvasView: UIViewRepresentable {
  let pageID: UUID
  let drawingData: Data
  let isInputEnabled: Bool
  let penStyle: PenStyle
  let eraserStyle: EraserStyle
  let drawingTool: DrawingTool
  let pencilInputGate: PencilInputGate
  let reserveAction: (UUID) -> VersionStamp?
  let commitAction: (Data, Data, UUID, VersionStamp) -> Data?

  func makeCoordinator() -> Coordinator {
    Coordinator(
      pencilInputGate: pencilInputGate,
      reserveAction: reserveAction,
      commitAction: commitAction
    )
  }

  func makeUIView(context: Context) -> PaperCanvasContainerView {
    let paper = PaperCanvasContainerView()
    paper.setInputEnabled(isInputEnabled)
    context.coordinator.attach(to: paper)
    context.coordinator.apply(
      penStyle,
      eraserStyle: eraserStyle,
      tool: drawingTool,
      to: paper
    )
    context.coordinator.apply(drawingData, pageID: pageID, to: paper)
    return paper
  }

  func updateUIView(_ paper: PaperCanvasContainerView, context: Context) {
    paper.setInputEnabled(isInputEnabled)
    context.coordinator.use(pencilInputGate)
    context.coordinator.reserveAction = reserveAction
    context.coordinator.commitAction = commitAction
    context.coordinator.apply(
      penStyle,
      eraserStyle: eraserStyle,
      tool: drawingTool,
      to: paper
    )
    context.coordinator.apply(drawingData, pageID: pageID, to: paper)
  }

  static func dismantleUIView(
    _ paper: PaperCanvasContainerView,
    coordinator: Coordinator
  ) {
    coordinator.detach(from: paper)
  }

  @MainActor
  final class Coordinator: NSObject {
    var reserveAction: (UUID) -> VersionStamp?
    var commitAction: (Data, Data, UUID, VersionStamp) -> Data?

    private let inputSourceID = UUID()
    private var pencilInputGate: PencilInputGate
    private var pencilActionIsActive = false
    private var pageID: UUID?
    private var modelDrawingData: Data?
    private var appliedDrawing = PKDrawing()
    private var appliedPenStyle: PenStyle?
    private var appliedEraserStyle: EraserStyle?
    private var appliedDrawingTool: DrawingTool?
    private var serializationTails: [UUID: Task<Void, Never>] = [:]
    private var pendingLocalDeliveries: [UUID: Int] = [:]
    private var localDrawingData: [UUID: Data] = [:]

    init(
      pencilInputGate: PencilInputGate,
      reserveAction: @escaping (UUID) -> VersionStamp?,
      commitAction: @escaping (Data, Data, UUID, VersionStamp) -> Data?
    ) {
      self.pencilInputGate = pencilInputGate
      self.reserveAction = reserveAction
      self.commitAction = commitAction
    }

    func attach(to paper: PaperCanvasContainerView) {
      paper.touchView.onActionActivityChange = { [weak self] active in
        self?.setPencilActionActive(active)
      }
      paper.touchView.onDrawingChange = { [weak self, weak paper] drawing in
        guard let self,
          let pageID,
          let stamp = reserveAction(pageID)
        else {
          self?.restoreModelDrawing(on: paper)
          return
        }
        appliedDrawing = drawing
        if pendingLocalDeliveries[pageID, default: 0] == 0 {
          localDrawingData[pageID] = modelDrawingData ?? Data()
        }
        pendingLocalDeliveries[pageID, default: 0] += 1
        let previous = serializationTails[pageID]
        let deliver = commitAction
        serializationTails[pageID] = Task { [self] in
          await previous?.value
          let previousData = localDrawingData[pageID] ?? Data()
          let data = await Task.detached(priority: .utility) {
            drawing.dataRepresentation()
          }.value
          localDrawingData[pageID] = data
          let acceptedData = deliver(data, previousData, pageID, stamp)
          completeLocalDelivery(
            on: pageID,
            acceptedData: acceptedData,
            paper: paper
          )
        }
      }
      pencilInputGate.registerPageFinisher {
        [weak self, weak paper] completion in
        guard let self, let paper else {
          completion()
          return
        }
        paper.touchView.finishCurrentAction {
          self.afterLocalDeliveries(on: self.pageID, perform: completion)
        }
      }
    }

    func use(_ gate: PencilInputGate) {
      guard pencilInputGate !== gate else { return }
      if pencilActionIsActive {
        pencilInputGate.endPencilAction(source: inputSourceID)
      }
      pencilInputGate = gate
      if pencilActionIsActive {
        pencilInputGate.beginPencilAction(source: inputSourceID)
      }
    }

    func detach(from paper: PaperCanvasContainerView) {
      paper.touchView.onActionActivityChange = nil
      paper.touchView.onDrawingChange = nil
      setPencilActionActive(false)
    }

    private func setPencilActionActive(_ active: Bool) {
      guard pencilActionIsActive != active else { return }
      pencilActionIsActive = active
      if active {
        pencilInputGate.beginPencilAction(source: inputSourceID)
      } else {
        pencilInputGate.endPencilAction(source: inputSourceID)
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
      _ data: Data,
      pageID: UUID,
      to paper: PaperCanvasContainerView
    ) {
      let pageChanged = self.pageID != pageID
      if !pageChanged, modelDrawingData == data {
        return
      }
      let drawing = Self.drawing(from: data)
      self.pageID = pageID
      modelDrawingData = data
      if !pageChanged,
        (pendingLocalDeliveries[pageID, default: 0] > 0
          || paper.touchView.hasActiveAction)
      {
        return
      }
      guard pageChanged || drawing != appliedDrawing else { return }
      appliedDrawing = drawing
      paper.apply(drawing)
    }

    private func completeLocalDelivery(
      on deliveredPageID: UUID,
      acceptedData: Data?,
      paper: PaperCanvasContainerView?
    ) {
      let remaining = max(
        0,
        pendingLocalDeliveries[deliveredPageID, default: 1] - 1
      )
      pendingLocalDeliveries[deliveredPageID] = remaining == 0
        ? nil
        : remaining

      if remaining == 0 {
        serializationTails[deliveredPageID] = nil
        localDrawingData[deliveredPageID] = nil
      }
      guard remaining == 0,
        deliveredPageID == pageID,
        let paper
      else { return }
      guard let acceptedData else {
        restoreModelDrawing(on: paper)
        return
      }
      modelDrawingData = acceptedData
      let acceptedDrawing = Self.drawing(from: acceptedData)
      guard acceptedDrawing != appliedDrawing else { return }
      appliedDrawing = acceptedDrawing
      paper.apply(acceptedDrawing)
    }

    private func afterLocalDeliveries(
      on pageID: UUID?,
      perform action: @escaping @MainActor () -> Void
    ) {
      guard let pageID, let tail = serializationTails[pageID] else {
        action()
        return
      }
      Task {
        await tail.value
        action()
      }
    }

    private func restoreModelDrawing(on paper: PaperCanvasContainerView?) {
      guard let paper, let modelDrawingData else { return }
      let drawing = Self.drawing(from: modelDrawingData)
      appliedDrawing = drawing
      paper.apply(drawing)
    }

    private static func drawing(from data: Data) -> PKDrawing {
      guard !data.isEmpty else { return PKDrawing() }
      return (try? PKDrawing(data: data)) ?? PKDrawing()
    }
  }
}

@MainActor
final class PaperCanvasContainerView: UIView {
  let inkView = InkCanvasView(frame: .zero)
  let touchView = PaperInputView(frame: .zero)

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
    touchView.commitActivePen = { [weak inkView] drawing in
      inkView?.commitActiveStroke(in: drawing)
    }
    touchView.presentActiveEraser = { [weak inkView] stroke in
      inkView?.displayActiveEraser(stroke)
    }
    touchView.commitActiveEraser = { [weak inkView] drawing in
      inkView?.commitActiveEraser(in: drawing)
    }
    touchView.clearActiveAction = { [weak inkView] in
      inkView?.clearActiveAction()
    }

    addSubview(inkView)
    addSubview(touchView)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    inkView.frame = bounds
    touchView.frame = bounds
  }

  func apply(_ drawing: PKDrawing) {
    inkView.apply(drawing)
    touchView.apply(drawing)
  }

  func setInputEnabled(_ enabled: Bool) {
    touchView.isUserInteractionEnabled = enabled
    touchView.isAccessibilityElement = enabled
    touchView.accessibilityElementsHidden = !enabled
  }
}

@MainActor
final class PaperInputView: UIView {
  var onDrawingChange: ((PKDrawing) -> Void)?
  var onActionActivityChange: ((Bool) -> Void)?
  var presentActivePen: ((ActiveInkStroke) -> Void)?
  var commitActivePen: ((PKDrawing) -> Void)?
  var presentActiveEraser: ((ActiveEraserStroke) -> Void)?
  var commitActiveEraser: ((PKDrawing) -> Void)?
  var clearActiveAction: (() -> Void)?

  var hasActiveAction: Bool { actionTool != nil }

  override var canBecomeFirstResponder: Bool { false }

  override var editingInteractionConfiguration: UIEditingInteractionConfiguration {
    .none
  }

  private struct Sample {
    var point: PKStrokePoint
    let timestamp: TimeInterval
  }

  private static let estimateWait = Duration.milliseconds(120)

  private var drawing = PKDrawing()
  private var penStyle = PenStyle.standard
  private var eraserStyle = EraserStyle.standard
  private var drawingTool = DrawingTool.pen

  private var activeTouch: UITouch?
  private var actionTool: DrawingTool?
  private var actionPenStyle: PenStyle?
  private var actionEraserStyle: EraserStyle?
  private var actionBaseDrawing = PKDrawing()
  private var actionCreationDate = Date()
  private var actionPathID = UUID()
  private var actionStrokeID = UUID()
  private var actionRandomSeed = UInt32.random(in: 0...UInt32.max)
  private var actionStartTimestamp: TimeInterval = 0
  private var samples: [Sample] = []
  private var predictedSamples: [Sample] = []
  private var activePenStroke: ActiveInkStroke?
  private var activeEraserStroke: ActiveEraserStroke?
  private var filteredPenForces: [CGFloat] = []
  private var pendingForceEstimates: [NSNumber: Int] = [:]
  private var actionHasEnded = false
  private var reportsPencilActivity = false

  private var finalizationTask: Task<Void, Never>?
  private var eraserTask: Task<Void, Never>?
  private var actionCompletions: [() -> Void] = []

  override init(frame: CGRect) {
    super.init(frame: frame)
    isMultipleTouchEnabled = true
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
    self.penStyle = penStyle
    self.eraserStyle = eraserStyle
    self.drawingTool = drawingTool
  }

  func apply(_ drawing: PKDrawing) {
    cancelCurrentAction()
    self.drawing = drawing
    updateAccessibilityValue()
  }

  func finishCurrentAction(completion: @escaping () -> Void) {
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
    updateAction(with: touch, event: event)
    activeTouch = nil
    actionHasEnded = true
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
      samples[sampleIndex] = reconciledSample(
        previous: samples[sampleIndex],
        updated: updated
      )
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

  private func beginAction(with touch: UITouch, event: UIEvent?) {
    if actionTool != nil {
      guard actionTool != .eraser else {
        finalizeAction()
        return
      }
      finalizeAction()
    }

    activeTouch = touch
    actionTool = drawingTool
    reportsPencilActivity = touch.type == .pencil
    if reportsPencilActivity { onActionActivityChange?(true) }
    actionPenStyle = penStyle
    actionEraserStyle = eraserStyle
    actionBaseDrawing = drawing
    actionCreationDate = Date()
    actionPathID = UUID()
    actionStrokeID = UUID()
    actionRandomSeed = UInt32.random(in: 0...UInt32.max)
    actionStartTimestamp = touch.timestamp
    samples = []
    predictedSamples = []
    activePenStroke = actionTool == .pen
      ? actionPenStyle.map { ActiveInkStroke(style: $0) }
      : nil
    activeEraserStroke = actionTool == .eraser
      ? ActiveEraserStroke()
      : nil
    filteredPenForces = []
    pendingForceEstimates = [:]
    actionHasEnded = false
    actionCompletions = []

    addActualSamples(for: touch, event: event)
    updatePredictions(for: touch, event: event)
    refreshAction()
  }

  private func updateAction(with touch: UITouch, event: UIEvent?) {
    addActualSamples(for: touch, event: event)
    updatePredictions(for: touch, event: event)
    refreshAction()
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

  private func acceptsDrawingTouch(_ touch: UITouch) -> Bool {
    if touch.type == .pencil { return true }
    #if targetEnvironment(simulator)
      return touch.type == .direct
        && (
          !ProcessInfo.processInfo.arguments.contains(
            SimulatorDrawingFixture.fingerGestureArgument
          )
            || ProcessInfo.processInfo.arguments.contains(
              SimulatorDrawingFixture.mixedInputArgument
            )
        )
    #else
      return false
    #endif
  }

  @discardableResult
  private func appendActualSample(from touch: UITouch) -> Int? {
    let timestamp = max(0, touch.timestamp - actionStartTimestamp)
    let sample = makeSample(from: touch, timestamp: timestamp)

    if let lastIndex = samples.indices.last,
      abs(samples[lastIndex].timestamp - timestamp) < 0.000_001
    {
      samples[lastIndex] = reconciledSample(
        previous: samples[lastIndex],
        updated: sample
      )
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

  private func reconciledSample(
    previous: Sample,
    updated: Sample
  ) -> Sample {
    guard actionTool == .eraser else { return updated }
    let point = PKStrokePoint(
      location: updated.point.location,
      timeOffset: updated.point.timeOffset,
      size: CGSize(
        width: CGFloat(
          PencilEraserContact.reconciledWidth(
            previous: Double(previous.point.size.width),
            updated: Double(updated.point.size.width)
          )
        ),
        height: CGFloat(
          PencilEraserContact.reconciledWidth(
            previous: Double(previous.point.size.height),
            updated: Double(updated.point.size.height)
          )
        )
      ),
      opacity: 1,
      force: max(previous.point.force, updated.point.force),
      azimuth: updated.point.azimuth,
      altitude: updated.point.altitude,
      secondaryScale: updated.point.secondaryScale,
      threshold: updated.point.threshold
    )
    return Sample(point: point, timestamp: updated.timestamp)
  }

  private func registerForceEstimate(for touch: UITouch, at sampleIndex: Int) {
    guard touch.estimatedPropertiesExpectingUpdates.contains(.force),
      let updateIndex = touch.estimationUpdateIndex
    else { return }
    pendingForceEstimates[updateIndex] = sampleIndex
  }

  private func updatePredictions(for touch: UITouch, event: UIEvent?) {
    guard actionTool == .pen else {
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
    case .pen:
      let style = actionPenStyle ?? penStyle
      width = CGFloat(style.width)
      opacity = CGFloat(
        PencilPressureOpacity.value(
          force: Double(normalizedForce),
          minimum: style.minimumOpacity
        )
      )
    case .eraser:
      let style = actionEraserStyle ?? eraserStyle
      width = CGFloat(
        PencilPressureWidth.value(
          force: Double(normalizedForce),
          minimum: EraserStyle.minimumContactWidth,
          maximum: style.maximumWidth
        )
      )
      opacity = 1
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
        with: samples[startIndex...].map(\.point)
      )
      return
    }

    guard actionTool == .pen,
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
    var previousTimestamp = startIndex > 0
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
      with: processedTail
    )
  }

  private func processedPredictedPenPoints() -> [PKStrokePoint] {
    guard actionTool == .pen, let style = actionPenStyle else { return [] }
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
        PencilPressureOpacity.value(
          force: Double(filteredForce),
          minimum: style.minimumOpacity
        )
      ),
      force: point.force,
      azimuth: point.azimuth,
      altitude: point.altitude,
      secondaryScale: point.secondaryScale,
      threshold: point.threshold
    )
  }

  private func showMeasuredActionWithoutPredictions() {
    if actionTool == .eraser, let activeEraserStroke {
      presentActiveEraser?(activeEraserStroke)
    } else if let activePenStroke {
      activePenStroke.replacePredictions(with: [])
      presentActivePen?(activePenStroke)
    }
  }

  private func refreshAction() {
    guard actionTool != nil, !samples.isEmpty else { return }
    predictedSamples = predictedSamples.filter {
      $0.timestamp > (samples.last?.timestamp ?? 0)
    }

    if actionTool == .eraser, let activeEraserStroke {
      presentActiveEraser?(activeEraserStroke)
    } else if let activePenStroke {
      activePenStroke.replacePredictions(
        with: processedPredictedPenPoints()
      )
      presentActivePen?(activePenStroke)
    }
  }

  private func actionDrawing() -> PKDrawing {
    guard actionTool == .pen, let stroke = penStroke() else {
      return actionBaseDrawing
    }
    return PKDrawing(strokes: actionBaseDrawing.strokes + [stroke])
  }

  private func penStroke() -> PKStroke? {
    guard let style = actionPenStyle,
      let activePenStroke,
      !activePenStroke.measuredPoints.isEmpty
    else {
      return nil
    }
    let path = PKStrokePath(
      controlPoints: activePenStroke.measuredPoints,
      creationDate: actionCreationDate,
      id: actionPathID
    )
    return PKStroke(
      ink: PKInk(.monoline, color: style.uiColor(alpha: 1)),
      path: path,
      randomSeed: actionRandomSeed,
      id: actionStrokeID
    )
  }

  private func eraserPath() -> PKStrokePath {
    return PKStrokePath(
      controlPoints: samples.map(\.point),
      creationDate: actionCreationDate
    )
  }

  private func startEraserFinalComputation() {
    guard actionTool == .eraser,
      !samples.isEmpty,
      eraserTask == nil
    else { return }

    let baseDrawing = actionBaseDrawing
    let path = eraserPath()
    let pathID = actionPathID
    eraserTask = Task { [weak self] in
      let result = await Task.detached(priority: .userInitiated) {
        baseDrawing.erasingPath(path)
      }.value
      guard !Task.isCancelled, let self,
        actionTool == .eraser,
        actionPathID == pathID
      else { return }
      eraserTask = nil
      finishAction(with: result)
    }
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

    if actionTool == .eraser {
      finishEraserWhenReady()
      return
    }

    finishAction(with: actionDrawing())
  }

  private func finishEraserWhenReady() {
    actionHasEnded = true
    guard eraserTask == nil else { return }
    startEraserFinalComputation()
  }

  private func finishAction(with finalDrawing: PKDrawing) {
    let completions = actionCompletions
    drawing = finalDrawing
    updateAccessibilityValue()
    if actionTool == .pen {
      commitActivePen?(finalDrawing)
    } else {
      commitActiveEraser?(finalDrawing)
    }
    clearAction()
    onDrawingChange?(finalDrawing)
    for completion in completions {
      completion()
    }
  }

  private func cancelCurrentAction() {
    finalizationTask?.cancel()
    finalizationTask = nil
    eraserTask?.cancel()
    eraserTask = nil
    clearAction()
  }

  private func clearAction() {
    let reportedPencilActivity = reportsPencilActivity
    clearActiveAction?()
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
    actionCompletions = []
    reportsPencilActivity = false
    if reportedPencilActivity { onActionActivityChange?(false) }
  }

  private func updateAccessibilityValue() {
    accessibilityValue = "\(drawing.strokes.count) штрихов"
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

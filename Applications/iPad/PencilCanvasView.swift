import PencilKit
import SwiftUI
import TetradCore
import UIKit

struct PencilCanvasView: UIViewRepresentable {
  let pageID: UUID
  let drawingData: Data
  let penStyle: PenStyle
  let eraserStyle: EraserStyle
  let drawingTool: DrawingTool
  let onToggleTool: () -> Void
  let onNavigate: (_ horizontal: Bool, _ direction: Int) -> Void
  let onUndo: () -> Void
  let onChange: (Data, Bool) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(
      onToggleTool: onToggleTool,
      onNavigate: onNavigate,
      onUndo: onUndo,
      onChange: onChange
    )
  }

  func makeUIView(context: Context) -> PaperCanvasContainerView {
    let paper = PaperCanvasContainerView()
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
    context.coordinator.onToggleTool = onToggleTool
    context.coordinator.onNavigate = onNavigate
    context.coordinator.onUndo = onUndo
    context.coordinator.onChange = onChange
    context.coordinator.apply(
      penStyle,
      eraserStyle: eraserStyle,
      tool: drawingTool,
      to: paper
    )
    context.coordinator.apply(drawingData, pageID: pageID, to: paper)
  }

  @MainActor
  final class Coordinator: NSObject, UIPencilInteractionDelegate {
    var onToggleTool: () -> Void
    var onNavigate: (_ horizontal: Bool, _ direction: Int) -> Void
    var onUndo: () -> Void
    var onChange: (Data, Bool) -> Void

    private var pageID: UUID?
    private var appliedDrawing = PKDrawing()
    private var appliedPenStyle: PenStyle?
    private var appliedEraserStyle: EraserStyle?
    private var appliedDrawingTool: DrawingTool?
    private var pageGestures: TwoFingerPageGestureController?

    init(
      onToggleTool: @escaping () -> Void,
      onNavigate: @escaping (_ horizontal: Bool, _ direction: Int) -> Void,
      onUndo: @escaping () -> Void,
      onChange: @escaping (Data, Bool) -> Void
    ) {
      self.onToggleTool = onToggleTool
      self.onNavigate = onNavigate
      self.onUndo = onUndo
      self.onChange = onChange
    }

    func attach(to paper: PaperCanvasContainerView) {
      paper.touchView.onDrawingChange = { [weak self] drawing, settled in
        guard let self else { return }
        appliedDrawing = drawing
        onChange(drawing.dataRepresentation(), settled)
      }
      paper.touchView.addInteraction(UIPencilInteraction(delegate: self))

      let pageGestures = TwoFingerPageGestureController(
        onNavigate: { [weak self, weak paper] horizontal, direction in
          guard let self, let paper else { return }
          paper.touchView.finishCurrentAction {
            self.onNavigate(horizontal, direction)
          }
        },
        onUndo: { [weak self, weak paper] in
          guard let self, let paper else { return }
          paper.touchView.finishCurrentAction {
            self.onUndo()
          }
        }
      )
      pageGestures.install(on: paper.touchView)
      self.pageGestures = pageGestures
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
      let drawing = (try? PKDrawing(data: data)) ?? PKDrawing()
      guard self.pageID != pageID || drawing != appliedDrawing else { return }

      self.pageID = pageID
      appliedDrawing = drawing
      paper.apply(drawing)
    }

    func pencilInteraction(
      _ interaction: UIPencilInteraction,
      didReceiveTap tap: UIPencilInteraction.Tap
    ) {
      onToggleTool()
    }

    func pencilInteraction(
      _ interaction: UIPencilInteraction,
      didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze
    ) {
      guard squeeze.phase == .ended else { return }
      onToggleTool()
    }
  }
}

@MainActor
final class PaperCanvasContainerView: UIView {
  let canvasView = PKCanvasView(frame: .zero)
  let touchView = PaperInputView(frame: .zero)

  override init(frame: CGRect) {
    super.init(frame: frame)

    backgroundColor = .clear
    isOpaque = false

    canvasView.backgroundColor = .clear
    canvasView.isOpaque = false
    canvasView.isScrollEnabled = false
    canvasView.minimumZoomScale = 1
    canvasView.maximumZoomScale = 1
    canvasView.bouncesZoom = false
    canvasView.contentInset = .zero
    canvasView.contentInsetAdjustmentBehavior = .never
    canvasView.isUserInteractionEnabled = false

    touchView.backgroundColor = .clear
    touchView.isOpaque = false
    touchView.isAccessibilityElement = true
    touchView.accessibilityLabel = "Лист"
    touchView.accessibilityIdentifier = "paper-input"
    touchView.renderDrawing = { [weak canvasView] drawing in
      canvasView?.drawing = drawing
    }

    addSubview(canvasView)
    addSubview(touchView)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    canvasView.frame = bounds
    canvasView.contentSize = bounds.size
    canvasView.contentOffset = .zero
    canvasView.zoomScale = 1
    touchView.frame = bounds
  }

  func apply(_ drawing: PKDrawing) {
    canvasView.drawing = drawing
    canvasView.contentOffset = .zero
    canvasView.zoomScale = 1
    touchView.apply(drawing)
  }
}

@MainActor
final class PaperInputView: UIView {
  var onDrawingChange: ((PKDrawing, Bool) -> Void)?
  var renderDrawing: ((PKDrawing) -> Void)?

  override var canBecomeFirstResponder: Bool { false }

  override var editingInteractionConfiguration: UIEditingInteractionConfiguration {
    .none
  }

  private struct Sample {
    var point: PKStrokePoint
    let timestamp: TimeInterval
  }

  private static let liveInterval: TimeInterval = 1.0 / 30.0
  private static let eraserPreviewInterval: TimeInterval = 1.0 / 20.0
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
  private var pendingForceEstimates: [NSNumber: Int] = [:]
  private var actionHasEnded = false
  private var workingDrawing = PKDrawing()

  private var lastLiveEmission: TimeInterval = 0
  private var liveTask: Task<Void, Never>?
  private var finalizationTask: Task<Void, Never>?
  private var eraserTask: Task<Void, Never>?
  private var eraserDelayTask: Task<Void, Never>?
  private var eraserRevision = 0
  private var renderedEraserRevision = 0
  private var lastEraserPreviewStart: TimeInterval = 0
  private var eraserFinishRequested = false
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
    workingDrawing = drawing
    updateAccessibilityValue()
    setNeedsDisplay()
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
    setNeedsDisplay()

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
    finalizeAction()
  }

  override func touchesEstimatedPropertiesUpdated(_ touches: Set<UITouch>) {
    guard actionTool != nil else { return }

    var changed = false
    for touch in touches where touch.type == .pencil {
      guard let updateIndex = touch.estimationUpdateIndex,
        let sampleIndex = pendingForceEstimates[updateIndex],
        samples.indices.contains(sampleIndex)
      else { continue }

      let timestamp = samples[sampleIndex].timestamp
      samples[sampleIndex] = makeSample(from: touch, timestamp: timestamp)
      changed = true

      if !touch.estimatedPropertiesExpectingUpdates.contains(.force) {
        pendingForceEstimates.removeValue(forKey: updateIndex)
      }
    }

    guard changed else { return }
    refreshAction()
    if actionHasEnded && pendingForceEstimates.isEmpty {
      finalizeAction()
    }
  }

  override func draw(_ rect: CGRect) {
    super.draw(rect)
    guard actionTool == .pen,
      let style = actionPenStyle,
      let context = UIGraphicsGetCurrentContext()
    else { return }

    let visibleSamples = samples + predictedSamples
    guard let first = visibleSamples.first else { return }

    context.saveGState()
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.setLineCap(.butt)
    context.setLineJoin(.round)

    if visibleSamples.count == 1 {
      let width = first.point.size.width
      context.setFillColor(
        style.uiColor(alpha: Double(first.point.opacity)).cgColor
      )
      context.fillEllipse(
        in: CGRect(
          x: first.point.location.x - (width / 2),
          y: first.point.location.y - (width / 2),
          width: width,
          height: width
        )
      )
    } else {
      for (start, end) in zip(visibleSamples, visibleSamples.dropFirst()) {
        let opacity = (start.point.opacity + end.point.opacity) / 2
        let width = (start.point.size.width + end.point.size.width) / 2
        context.setStrokeColor(
          style.uiColor(alpha: Double(opacity)).cgColor
        )
        context.setLineWidth(width)
        context.beginPath()
        context.move(to: start.point.location)
        context.addLine(to: end.point.location)
        context.strokePath()
      }

      drawCap(for: first.point, style: style, in: context)
      if let last = visibleSamples.last {
        drawCap(for: last.point, style: style, in: context)
      }
    }

    context.restoreGState()
  }

  private func drawCap(
    for point: PKStrokePoint,
    style: PenStyle,
    in context: CGContext
  ) {
    let width = point.size.width
    context.setFillColor(
      style.uiColor(alpha: Double(point.opacity)).cgColor
    )
    context.fillEllipse(
      in: CGRect(
        x: point.location.x - (width / 2),
        y: point.location.y - (width / 2),
        width: width,
        height: width
      )
    )
  }

  private func drawingTouch(in touches: Set<UITouch>) -> UITouch? {
    if let pencil = touches.first(where: { $0.type == .pencil }) {
      return pencil
    }
    #if targetEnvironment(simulator)
      return touches.first { $0.type == .direct }
    #else
      return nil
    #endif
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
    actionPenStyle = penStyle
    actionEraserStyle = eraserStyle
    actionBaseDrawing = drawing
    workingDrawing = drawing
    actionCreationDate = Date()
    actionPathID = UUID()
    actionStrokeID = UUID()
    actionRandomSeed = UInt32.random(in: 0...UInt32.max)
    actionStartTimestamp = touch.timestamp
    samples = []
    predictedSamples = []
    pendingForceEstimates = [:]
    actionHasEnded = false
    lastLiveEmission = 0
    eraserRevision = 0
    renderedEraserRevision = 0
    lastEraserPreviewStart = 0
    eraserFinishRequested = false
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
    for sampleTouch in coalesced where acceptsDrawingTouch(sampleTouch) {
      appendActualSample(from: sampleTouch)
    }
  }

  private func acceptsDrawingTouch(_ touch: UITouch) -> Bool {
    if touch.type == .pencil { return true }
    #if targetEnvironment(simulator)
      return touch.type == .direct
    #else
      return false
    #endif
  }

  private func appendActualSample(from touch: UITouch) {
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
      return
    }

    guard samples.last.map({ timestamp > $0.timestamp }) ?? true else { return }
    samples.append(sample)
    registerForceEstimate(for: touch, at: samples.count - 1)
  }

  private func registerForceEstimate(for touch: UITouch, at sampleIndex: Int) {
    guard touch.estimatedPropertiesExpectingUpdates.contains(.force),
      let updateIndex = touch.estimationUpdateIndex
    else { return }
    pendingForceEstimates[updateIndex] = sampleIndex
  }

  private func updatePredictions(for touch: UITouch, event: UIEvent?) {
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
    let width: CGFloat
    let opacity: CGFloat
    switch tool {
    case .pen:
      let style = actionPenStyle ?? penStyle
      width = CGFloat(style.width)
      opacity = CGFloat(
        PencilPressureOpacity.value(
          force: Double(touch.force),
          minimum: style.minimumOpacity
        )
      )
    case .eraser:
      let style = actionEraserStyle ?? eraserStyle
      width = CGFloat(
        PencilPressureWidth.value(
          force: Double(touch.force),
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
      force: touch.force,
      azimuth: touch.azimuthAngle(in: self),
      altitude: touch.altitudeAngle
    )
    return Sample(point: point, timestamp: timestamp)
  }

  private func refreshAction() {
    guard actionTool != nil, !samples.isEmpty else { return }
    predictedSamples = predictedSamples.filter {
      $0.timestamp > (samples.last?.timestamp ?? 0)
    }

    if actionTool == .eraser {
      eraserRevision &+= 1
      scheduleEraserPreview()
    } else {
      scheduleLiveEmission()
    }
    setNeedsDisplay()
  }

  private func actionDrawing() -> PKDrawing {
    guard actionTool == .pen, let stroke = penStroke() else {
      return workingDrawing
    }
    return PKDrawing(strokes: actionBaseDrawing.strokes + [stroke])
  }

  private func penStroke() -> PKStroke? {
    guard let style = actionPenStyle, !samples.isEmpty else { return nil }
    let path = PKStrokePath(
      controlPoints: samples.map(\.point),
      creationDate: actionCreationDate,
      id: actionPathID
    )
    return PKStroke(
      ink: PKInk(.pen, color: style.uiColor(alpha: 1)),
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

  private func scheduleEraserPreview() {
    guard actionTool == .eraser,
      !samples.isEmpty,
      !actionHasEnded,
      eraserTask == nil,
      eraserDelayTask == nil
    else { return }

    let remaining =
      Self.eraserPreviewInterval
      - (CACurrentMediaTime() - lastEraserPreviewStart)
    if remaining <= 0 {
      startEraserComputation()
      return
    }

    eraserDelayTask = Task { [weak self] in
      let nanoseconds = UInt64(max(remaining, 0) * 1_000_000_000)
      try? await Task.sleep(nanoseconds: nanoseconds)
      guard !Task.isCancelled, let self else { return }
      eraserDelayTask = nil
      startEraserComputation()
    }
  }

  private func startEraserComputation() {
    guard actionTool == .eraser,
      !samples.isEmpty,
      eraserTask == nil
    else { return }

    lastEraserPreviewStart = CACurrentMediaTime()
    let baseDrawing = actionBaseDrawing
    let path = eraserPath()
    let pathID = actionPathID
    let revision = eraserRevision

    eraserTask = Task { [weak self] in
      let result = await Task.detached(priority: .userInitiated) {
        baseDrawing.erasingPath(path)
      }.value
      guard !Task.isCancelled, let self,
        actionTool == .eraser,
        actionPathID == pathID
      else { return }
      eraserTask = nil

      workingDrawing = result
      renderedEraserRevision = revision
      renderDrawing?(result)

      if eraserFinishRequested {
        if revision == eraserRevision {
          finishAction(with: result)
        } else {
          startEraserComputation()
        }
      } else if revision != eraserRevision {
        scheduleEraserPreview()
      }
    }
  }

  private func scheduleLiveEmission() {
    let now = CACurrentMediaTime()
    let remaining = Self.liveInterval - (now - lastLiveEmission)
    if remaining <= 0 {
      emitLiveNow()
      return
    }
    guard liveTask == nil else { return }

    liveTask = Task { [weak self] in
      let nanoseconds = UInt64(max(remaining, 0) * 1_000_000_000)
      try? await Task.sleep(nanoseconds: nanoseconds)
      guard !Task.isCancelled, let self else { return }
      liveTask = nil
      emitLiveNow()
    }
  }

  private func emitLiveNow() {
    guard actionTool != nil else { return }
    lastLiveEmission = CACurrentMediaTime()
    onDrawingChange?(actionDrawing(), false)
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
    liveTask?.cancel()
    liveTask = nil
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
    eraserFinishRequested = true
    eraserDelayTask?.cancel()
    eraserDelayTask = nil

    guard eraserTask == nil else { return }
    if renderedEraserRevision == eraserRevision {
      finishAction(with: workingDrawing)
    } else {
      startEraserComputation()
    }
  }

  private func finishAction(with finalDrawing: PKDrawing) {
    let completions = actionCompletions
    drawing = finalDrawing
    workingDrawing = finalDrawing
    updateAccessibilityValue()
    renderDrawing?(finalDrawing)
    clearAction()
    onDrawingChange?(finalDrawing, true)
    for completion in completions {
      completion()
    }
  }

  private func cancelCurrentAction() {
    liveTask?.cancel()
    liveTask = nil
    finalizationTask?.cancel()
    finalizationTask = nil
    eraserTask?.cancel()
    eraserTask = nil
    eraserDelayTask?.cancel()
    eraserDelayTask = nil
    clearAction()
  }

  private func clearAction() {
    activeTouch = nil
    actionTool = nil
    actionPenStyle = nil
    actionEraserStyle = nil
    samples = []
    predictedSamples = []
    pendingForceEstimates = [:]
    actionHasEnded = false
    eraserRevision = 0
    renderedEraserRevision = 0
    lastEraserPreviewStart = 0
    eraserFinishRequested = false
    actionCompletions = []
    setNeedsDisplay()
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

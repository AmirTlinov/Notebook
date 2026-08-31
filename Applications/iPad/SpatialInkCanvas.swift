import PencilKit
import SwiftUI
import NotebookCore
import UIKit

struct SpatialInkCanvas: UIViewRepresentable {
  let camera: SpatialCamera
  let viewport: SpatialPoint
  let notebooks: [SpatialNotebookSurface]
  let journal: SpatialInkJournal?
  let penStyle: PenStyle
  let eraserStyle: EraserStyle
  let drawingTool: DrawingTool
  let surfaceRegistry: SpatialInkSurfaceRegistry
  let pencilInputGate: PencilInputGate
  let onCommit: (SpatialInkTool, SpatialInkColor, [SpatialInkSpan]) -> Void
  let isEnabled: Bool

  func makeCoordinator() -> Coordinator {
    Coordinator(
      surfaceRegistry: surfaceRegistry,
      pencilInputGate: pencilInputGate,
      onCommit: onCommit
    )
  }

  func makeUIView(context: Context) -> SpatialInkContainerView {
    let view = SpatialInkContainerView()
    view.onWindowChange = { [weak coordinator = context.coordinator, weak view] window in
      guard let coordinator, let view else { return }
      coordinator.install(on: window, inside: view)
    }
    context.coordinator.update(
      view: view,
      camera: camera,
      viewport: viewport,
      notebooks: notebooks,
      journal: journal,
      penStyle: penStyle,
      eraserStyle: eraserStyle,
      drawingTool: drawingTool,
      surfaceRegistry: surfaceRegistry,
      pencilInputGate: pencilInputGate,
      isEnabled: isEnabled,
      onCommit: onCommit
    )
    return view
  }

  func updateUIView(_ view: SpatialInkContainerView, context: Context) {
    context.coordinator.update(
      view: view,
      camera: camera,
      viewport: viewport,
      notebooks: notebooks,
      journal: journal,
      penStyle: penStyle,
      eraserStyle: eraserStyle,
      drawingTool: drawingTool,
      surfaceRegistry: surfaceRegistry,
      pencilInputGate: pencilInputGate,
      isEnabled: isEnabled,
      onCommit: onCommit
    )
  }

  static func dismantleUIView(
    _ view: SpatialInkContainerView,
    coordinator: Coordinator
  ) {
    coordinator.uninstall()
  }

  @MainActor
  final class Coordinator {
    private struct RenderSignature: Equatable {
      let journalStamp: VersionStamp?
      let camera: SpatialCamera
      let viewport: SpatialPoint
    }

    private var surfaceRegistry: SpatialInkSurfaceRegistry
    private let inputSourceID = UUID()
    private var pencilInputGate: PencilInputGate
    private var pencilActionIsActive = false
    private weak var view: SpatialInkContainerView?
    private weak var window: UIWindow?
    private var recognizer: SpatialPencilGestureRecognizer?
    private var renderTask: Task<Void, Never>?
    private var renderGeneration = 0
    private var appliedSignature: RenderSignature?

    private var camera = SpatialCamera()
    private var viewport = SpatialPoint(x: 1, y: 1)
    private var notebooks: [SpatialNotebookSurface] = []
    private var journal: SpatialInkJournal?
    private var penStyle = PenStyle.standard
    private var eraserStyle = EraserStyle.standard
    private var drawingTool = DrawingTool.pen
    private var isEnabled = false
    private var onCommit: (
      SpatialInkTool,
      SpatialInkColor,
      [SpatialInkSpan]
    ) -> Void

    private var actionTool: DrawingTool?
    private var actionPenStyle: PenStyle?
    private var actionEraserStyle: EraserStyle?
    private var actionSamples: [PKStrokePoint] = []
    private var activePen: ActiveInkStroke?
    private var activeEraser: ActiveEraserStroke?
    private var currentSurface: SurfaceID?
    private var touchedSurfaces: Set<SurfaceID> = []
    private var previousFilteredForce: CGFloat?
    private var previousTimestamp: TimeInterval?
    private var actionStartTimestamp: TimeInterval = 0

    init(
      surfaceRegistry: SpatialInkSurfaceRegistry,
      pencilInputGate: PencilInputGate,
      onCommit: @escaping (
        SpatialInkTool,
        SpatialInkColor,
        [SpatialInkSpan]
      ) -> Void
    ) {
      self.surfaceRegistry = surfaceRegistry
      self.pencilInputGate = pencilInputGate
      self.onCommit = onCommit
    }

    func update(
      view: SpatialInkContainerView,
      camera: SpatialCamera,
      viewport: SpatialPoint,
      notebooks: [SpatialNotebookSurface],
      journal: SpatialInkJournal?,
      penStyle: PenStyle,
      eraserStyle: EraserStyle,
      drawingTool: DrawingTool,
      surfaceRegistry: SpatialInkSurfaceRegistry,
      pencilInputGate: PencilInputGate,
      isEnabled: Bool,
      onCommit: @escaping (
        SpatialInkTool,
        SpatialInkColor,
        [SpatialInkSpan]
      ) -> Void
    ) {
      self.view = view
      self.camera = camera
      self.viewport = viewport
      self.notebooks = notebooks.sorted { $0.zIndex < $1.zIndex }
      self.journal = journal
      self.penStyle = penStyle
      self.eraserStyle = eraserStyle
      self.drawingTool = drawingTool
      if self.surfaceRegistry !== surfaceRegistry {
        self.surfaceRegistry.unregister(view.inkView, for: .board)
        self.surfaceRegistry = surfaceRegistry
        appliedSignature = nil
      }
      if self.pencilInputGate !== pencilInputGate {
        if pencilActionIsActive {
          self.pencilInputGate.endPencilAction(source: inputSourceID)
        }
        self.pencilInputGate = pencilInputGate
        if pencilActionIsActive {
          self.pencilInputGate.beginPencilAction(source: inputSourceID)
        }
      }
      self.isEnabled = isEnabled
      self.onCommit = onCommit
      surfaceRegistry.register(view.inkView, for: .board)
      view.accessibilityValue = "\(journal?.actions.filter(\.isActive).count ?? 0) действий"
      recognizer?.isEnabled = isEnabled
      scheduleRenderIfNeeded()
      if let window = view.window { install(on: window, inside: view) }
    }

    func install(on window: UIWindow?, inside view: SpatialInkContainerView) {
      guard let window else {
        uninstall()
        return
      }
      guard self.window !== window else {
        recognizer?.isEnabled = isEnabled
        surfaceRegistry.register(view.inkView, for: .board)
        return
      }
      uninstall()
      surfaceRegistry.register(view.inkView, for: .board)
      let recognizer = SpatialPencilGestureRecognizer()
      recognizer.allowedTouchTypes = [
        NSNumber(value: UITouch.TouchType.pencil.rawValue)
      ]
      #if targetEnvironment(simulator)
        if !ProcessInfo.processInfo.arguments.contains(
          SimulatorDrawingFixture.fingerGestureArgument
        ) {
          recognizer.allowedTouchTypes.append(
            NSNumber(value: UITouch.TouchType.direct.rawValue)
          )
        }
      #endif
      recognizer.cancelsTouchesInView = true
      recognizer.isEnabled = isEnabled
      recognizer.onEvent = { [weak self] phase, touch, event in
        self?.handle(phase: phase, touch: touch, event: event)
      }
      window.addGestureRecognizer(recognizer)
      self.window = window
      self.view = view
      self.recognizer = recognizer
    }

    func uninstall() {
      renderTask?.cancel()
      renderTask = nil
      if let recognizer { window?.removeGestureRecognizer(recognizer) }
      recognizer = nil
      window = nil
      cancelAction()
      if let view {
        surfaceRegistry.unregister(view.inkView, for: .board)
      }
    }

    private func handle(
      phase: SpatialPencilGestureRecognizer.Phase,
      touch: UITouch,
      event: UIEvent
    ) {
      guard isEnabled else { return }
      switch phase {
      case .began:
        beginAction(touch: touch, event: event)
      case .moved:
        appendSamples(touch: touch, event: event)
      case .ended:
        appendSamples(touch: touch, event: event)
        finishAction()
      case .cancelled:
        finishAction()
      }
    }

    private func beginAction(touch: UITouch, event: UIEvent) {
      cancelAction()
      setPencilActionActive(touch.type == .pencil)
      actionTool = drawingTool
      actionPenStyle = penStyle
      actionEraserStyle = eraserStyle
      actionSamples = []
      currentSurface = nil
      touchedSurfaces = []
      previousFilteredForce = nil
      previousTimestamp = nil
      actionStartTimestamp = touch.timestamp
      appendSamples(touch: touch, event: event)
    }

    private func appendSamples(touch: UITouch, event: UIEvent) {
      guard let actionTool else { return }
      let actual = event.coalescedTouches(for: touch) ?? [touch]
      for sampleTouch in actual where accepts(sampleTouch) {
        let timestamp = max(0, sampleTouch.timestamp - actionStartTimestamp)
        guard actionSamples.last.map({ timestamp > $0.timeOffset }) ?? true else {
          continue
        }
        let point = makePoint(
          touch: sampleTouch,
          timestamp: timestamp,
          tool: actionTool
        )
        if let previous = actionSamples.last {
          routeMeasuredSegment(from: previous, to: point)
        } else {
          beginSegment(
            on: SpatialSurfaceRouter.surface(
              at: point.location,
              covers: screenSurfaces()
            ),
            with: point
          )
        }
        actionSamples.append(point)
      }
      guard !actionSamples.isEmpty else { return }

      if actionTool == .pen,
        let activePen,
        let currentSurface
      {
        let predictions = (event.predictedTouches(for: touch) ?? [])
          .filter(accepts)
          .map {
            makePoint(
              touch: $0,
              timestamp: max(0, $0.timestamp - actionStartTimestamp),
              tool: actionTool,
              updatesFilter: false
            )
          }
          .prefix { prediction in
            SpatialSurfaceRouter.surface(
              at: prediction.location,
              covers: screenSurfaces()
            ) == currentSurface
          }
          .map { livePoint($0, on: currentSurface) }
        activePen.replacePredictions(with: Array(predictions))
        surfaceRegistry.canvas(for: currentSurface)?
          .displayActiveStroke(activePen)
      }
    }

    private func finishAction() {
      guard let actionTool, !actionSamples.isEmpty else {
        cancelAction()
        return
      }
      defer { setPencilActionActive(false) }
      activePen?.replacePredictions(with: [])
      finishCurrentSegment()
      let spans = splitIntoSurfaceSpans(actionSamples)
      let components = (actionPenStyle ?? penStyle).color.components
      let color = SpatialInkColor(
        red: components.red,
        green: components.green,
        blue: components.blue
      )
      self.actionTool = nil
      actionPenStyle = nil
      actionEraserStyle = nil
      activePen = nil
      activeEraser = nil
      currentSurface = nil
      actionSamples = []
      previousFilteredForce = nil
      previousTimestamp = nil
      guard !spans.isEmpty else {
        for surface in touchedSurfaces {
          surfaceRegistry.finishAction(
            on: surface,
            keepingCommittedMesh: false
          )
        }
        touchedSurfaces = []
        return
      }
      onCommit(actionTool == .pen ? .pen : .eraser, color, spans)
      for surface in touchedSurfaces {
        surfaceRegistry.finishAction(
          on: surface,
          keepingCommittedMesh: true
        )
      }
      touchedSurfaces = []
      appliedSignature = nil
    }

    private func cancelAction() {
      if let currentSurface {
        surfaceRegistry.canvas(for: currentSurface)?.clearActiveAction()
      }
      let cancelledSurfaces = touchedSurfaces
      actionTool = nil
      actionPenStyle = nil
      actionEraserStyle = nil
      actionSamples = []
      activePen = nil
      activeEraser = nil
      currentSurface = nil
      touchedSurfaces = []
      previousFilteredForce = nil
      previousTimestamp = nil
      for surface in cancelledSurfaces {
        surfaceRegistry.finishAction(
          on: surface,
          keepingCommittedMesh: false
        )
        surfaceRegistry.applyStable(
          stableLayers(for: surface),
          to: surface
        )
      }
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

    private func routeMeasuredSegment(
      from start: PKStrokePoint,
      to end: PKStrokePoint
    ) {
      let intervals = SpatialSurfaceRouter.intervals(
        from: start.location,
        to: end.location,
        covers: screenSurfaces()
      )
      for interval in intervals {
        let lower = interpolate(start, end, t: Double(interval.lowerBound))
        if currentSurface != interval.surface {
          finishCurrentSegment()
          beginSegment(on: interval.surface, with: lower)
        }
        appendToCurrentSegment(
          interpolate(start, end, t: Double(interval.upperBound))
        )
      }
    }

    private func beginSegment(
      on surface: SurfaceID,
      with point: PKStrokePoint
    ) {
      currentSurface = surface
      touchedSurfaces.insert(surface)
      surfaceRegistry.beginAction(on: surface)
      if actionTool == .pen {
        let stroke = ActiveInkStroke(style: actionPenStyle ?? penStyle)
        activePen = stroke
        activeEraser = nil
      } else {
        activePen = nil
        activeEraser = ActiveEraserStroke()
      }
      appendToCurrentSegment(point)
    }

    private func appendToCurrentSegment(_ point: PKStrokePoint) {
      guard let currentSurface else { return }
      let localPoint = livePoint(point, on: currentSurface)
      if let activePen {
        activePen.replaceMeasuredTail(
          from: activePen.measuredPoints.count,
          with: [localPoint]
        )
        surfaceRegistry.canvas(for: currentSurface)?
          .displayActiveStroke(activePen)
      } else if let activeEraser {
        activeEraser.replaceMeasuredTail(
          from: activeEraser.measuredPoints.count,
          with: [localPoint]
        )
        surfaceRegistry.canvas(for: currentSurface)?
          .displayActiveEraser(activeEraser)
      }
    }

    private func finishCurrentSegment() {
      guard let currentSurface else { return }
      activePen?.replacePredictions(with: [])
      surfaceRegistry.canvas(for: currentSurface)?
        .commitActiveSpatialAction()
      activePen = nil
      activeEraser = nil
      self.currentSurface = nil
    }

    private func makePoint(
      touch: UITouch,
      timestamp: TimeInterval,
      tool: DrawingTool,
      updatesFilter: Bool = true
    ) -> PKStrokePoint {
      let force = normalizedForce(touch)
      let filtered: CGFloat
      if tool == .pen {
        filtered = CGFloat(
          PencilPressureSmoothing.value(
            force: Double(force),
            previous: previousFilteredForce.map(Double.init),
            elapsed: previousTimestamp.map { timestamp - $0 }
          )
        )
      } else {
        filtered = force
      }
      if updatesFilter {
        previousFilteredForce = filtered
        previousTimestamp = timestamp
      }
      let width: Double
      let opacity: Double
      if tool == .pen {
        let style = actionPenStyle ?? penStyle
        width = style.width
        opacity = PencilPressureOpacity.value(
          force: Double(filtered),
          minimum: style.minimumOpacity
        )
      } else {
        let style = actionEraserStyle ?? eraserStyle
        width = PencilPressureWidth.value(
          force: Double(filtered),
          minimum: EraserStyle.minimumContactWidth,
          maximum: style.maximumWidth
        )
        opacity = 1
      }
      let coordinateView = view ?? window
      return PKStrokePoint(
        location: touch.preciseLocation(in: coordinateView),
        timeOffset: timestamp,
        size: CGSize(width: width, height: width),
        opacity: opacity,
        force: force,
        azimuth: touch.azimuthAngle(in: coordinateView),
        altitude: touch.altitudeAngle
      )
    }

    private func normalizedForce(_ touch: UITouch) -> CGFloat {
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

    private func accepts(_ touch: UITouch) -> Bool {
      if touch.type == .pencil { return true }
      #if targetEnvironment(simulator)
        return touch.type == .direct
          && !ProcessInfo.processInfo.arguments.contains(
            SimulatorDrawingFixture.fingerGestureArgument
          )
      #else
        return false
      #endif
    }

    private func splitIntoSurfaceSpans(
      _ points: [PKStrokePoint]
    ) -> [SpatialInkSpan] {
      guard let first = points.first else { return [] }
      let covers = screenSurfaces()
      var result: [SpatialInkSpan] = []
      var currentSurface = SpatialSurfaceRouter.surface(
        at: first.location,
        covers: covers
      )
      var currentPoints = [convert(first, to: currentSurface)]
      var previousPoint = first

      for point in points.dropFirst() {
        let intervals = SpatialSurfaceRouter.intervals(
          from: previousPoint.location,
          to: point.location,
          covers: covers
        )
        for interval in intervals {
          if interval.surface != currentSurface {
            let boundary = interpolate(
              previousPoint,
              point,
              t: Double(interval.lowerBound)
            )
            result.append(
              SpatialInkSpan(surface: currentSurface, samples: currentPoints)
            )
            currentSurface = interval.surface
            currentPoints = [convert(boundary, to: currentSurface)]
          }
          let endpoint = interpolate(
            previousPoint,
            point,
            t: Double(interval.upperBound)
          )
          currentPoints.append(convert(endpoint, to: currentSurface))
        }
        previousPoint = point
      }
      if !currentPoints.isEmpty {
        result.append(
          SpatialInkSpan(surface: currentSurface, samples: currentPoints)
        )
      }
      return result
    }

    private func interpolate(
      _ start: PKStrokePoint,
      _ end: PKStrokePoint,
      t: Double
    ) -> PKStrokePoint {
      func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        a + (b - a) * t
      }
      return PKStrokePoint(
        location: CGPoint(
          x: mix(start.location.x, end.location.x),
          y: mix(start.location.y, end.location.y)
        ),
        timeOffset: start.timeOffset + (end.timeOffset - start.timeOffset) * t,
        size: CGSize(
          width: mix(start.size.width, end.size.width),
          height: mix(start.size.height, end.size.height)
        ),
        opacity: mix(start.opacity, end.opacity),
        force: mix(start.force, end.force),
        azimuth: mix(start.azimuth, end.azimuth),
        altitude: mix(start.altitude, end.altitude)
      )
    }

    private func screenSurfaces() -> [SpatialScreenSurface] {
      notebooks.map { notebook in
        let center = camera.worldToScreen(notebook.center, viewport: viewport)
        let rect = CGRect(
          x: center.x - NotebookGeometry.width * camera.scale / 2,
          y: center.y - NotebookGeometry.height * camera.scale / 2,
          width: NotebookGeometry.width * camera.scale,
          height: NotebookGeometry.height * camera.scale
        )
        return SpatialScreenSurface(
          id: .cover(notebook.notebookID),
          frame: rect,
          zIndex: notebook.zIndex
        )
      }
    }

    private func convert(
      _ point: PKStrokePoint,
      to surface: SurfaceID
    ) -> SpatialInkSample {
      let local: SpatialPoint
      if surface.kind == .cover,
        let notebookID = surface.ownerID,
        let notebook = notebooks.first(where: { $0.notebookID == notebookID })
      {
        let center = camera.worldToScreen(notebook.center, viewport: viewport)
        local = SpatialPoint(
          x: (point.location.x - center.x) / camera.scale
            + NotebookGeometry.width / 2,
          y: (point.location.y - center.y) / camera.scale
            + NotebookGeometry.height / 2
        )
      } else {
        let world = camera.screenToWorld(
          SpatialPoint(x: point.location.x, y: point.location.y),
          viewport: viewport
        )
        local = SpatialPoint(x: world.localX, y: world.localY)
        return SpatialInkSample(
          point: local,
          worldPoint: world,
          timeOffset: point.timeOffset,
          width: point.size.width / camera.scale,
          opacity: point.opacity,
          force: point.force,
          azimuth: point.azimuth,
          altitude: point.altitude
        )
      }
      return SpatialInkSample(
        point: local,
        timeOffset: point.timeOffset,
        width: point.size.width / camera.scale,
        opacity: point.opacity,
        force: point.force,
        azimuth: point.azimuth,
        altitude: point.altitude
      )
    }

    private func livePoint(
      _ point: PKStrokePoint,
      on surface: SurfaceID
    ) -> PKStrokePoint {
      guard surface.kind == .cover,
        let notebookID = surface.ownerID,
        let notebook = notebooks.first(where: { $0.notebookID == notebookID })
      else { return point }
      let center = camera.worldToScreen(notebook.center, viewport: viewport)
      return PKStrokePoint(
        location: CGPoint(
          x: (point.location.x - center.x) / camera.scale
            + NotebookGeometry.width / 2,
          y: (point.location.y - center.y) / camera.scale
            + NotebookGeometry.height / 2
        ),
        timeOffset: point.timeOffset,
        size: CGSize(
          width: point.size.width / camera.scale,
          height: point.size.height / camera.scale
        ),
        opacity: point.opacity,
        force: point.force,
        azimuth: point.azimuth,
        altitude: point.altitude
      )
    }

    private func stableLayers(for surface: SurfaceID) -> [SpatialInkRenderLayer] {
      if surface == .board {
        return SpatialInkComposer.boardLayers(
          journal: journal,
          camera: camera,
          viewport: viewport
        )
      }
      return SpatialInkComposer.localLayers(for: surface, journal: journal)
    }

    private func scheduleRenderIfNeeded() {
      guard actionTool == nil, let view else { return }
      let signature = RenderSignature(
        journalStamp: journal?.stamp,
        camera: camera,
        viewport: viewport
      )
      guard signature != appliedSignature else { return }
      appliedSignature = signature
      renderGeneration += 1
      let generation = renderGeneration
      let journal = journal
      let camera = camera
      let viewport = viewport
      renderTask?.cancel()
      renderTask = Task { [weak self, weak view] in
        let layers = await Task.detached(priority: .userInitiated) {
          SpatialInkComposer.boardLayers(
            journal: journal,
            camera: camera,
            viewport: viewport
          )
        }.value
        guard !Task.isCancelled,
          let self,
          let view,
          generation == renderGeneration,
          actionTool == nil
        else { return }
        surfaceRegistry.applyStable(layers, to: .board, in: view.inkView)
      }
    }
  }
}

@MainActor
final class SpatialInkContainerView: UIView {
  let inkView = InkCanvasView(frame: .zero)
  var onWindowChange: ((UIWindow?) -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
    isUserInteractionEnabled = false
    isAccessibilityElement = true
    accessibilityLabel = "Чернила доски и обложек"
    accessibilityIdentifier = "spatial-ink"
    addSubview(inkView)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    inkView.frame = bounds
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    onWindowChange?(window)
  }
}

@MainActor
final class SpatialPencilGestureRecognizer: UIGestureRecognizer {
  enum Phase {
    case began
    case moved
    case ended
    case cancelled
  }

  var onEvent: ((Phase, UITouch, UIEvent) -> Void)?
  private weak var activeTouch: UITouch?

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
    guard activeTouch == nil, let touch = touches.first else {
      state = .failed
      return
    }
    activeTouch = touch
    state = .began
    onEvent?(.began, touch, event)
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
    guard let touch = touches.first(where: { $0 === activeTouch }) else {
      return
    }
    state = .changed
    onEvent?(.moved, touch, event)
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
    guard let touch = touches.first(where: { $0 === activeTouch }) else {
      return
    }
    onEvent?(.ended, touch, event)
    activeTouch = nil
    state = .ended
  }

  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
    guard let touch = touches.first(where: { $0 === activeTouch }) else {
      return
    }
    onEvent?(.cancelled, touch, event)
    activeTouch = nil
    state = .cancelled
  }

  override func reset() {
    super.reset()
    activeTouch = nil
  }
}

enum SpatialInkComposer {
  static func boardLayers(
    journal: SpatialInkJournal?,
    camera: SpatialCamera,
    viewport: SpatialPoint
  ) -> [SpatialInkRenderLayer] {
    guard let journal else { return [] }
    return layers(for: .board, in: journal) { sample in
      guard let worldPoint = sample.worldPoint else { return nil }
      let screen = camera.worldToScreen(worldPoint, viewport: viewport)
      return point(
        sample,
        location: CGPoint(x: screen.x, y: screen.y),
        widthScale: camera.scale
      )
    }
  }

  static func localLayers(
    for surface: SurfaceID,
    journal: SpatialInkJournal?
  ) -> [SpatialInkRenderLayer] {
    guard let journal else { return [] }
    return layers(for: surface, in: journal) { sample in
      point(
        sample,
        location: CGPoint(x: sample.point.x, y: sample.point.y),
        widthScale: 1
      )
    }
  }

  private static func layers(
    for surface: SurfaceID,
    in journal: SpatialInkJournal,
    point transform: (SpatialInkSample) -> PKStrokePoint?
  ) -> [SpatialInkRenderLayer] {
    var result: [SpatialInkRenderLayer] = []
    for action in journal.actions where action.isActive {
      for span in action.spans where span.surface == surface {
        let points = span.samples.compactMap(transform)
        guard !points.isEmpty else { continue }
        if action.tool == .pen {
          result.append(.ink(points: points, color: action.color))
        } else {
          result.append(.erase(points: points))
        }
      }
    }
    return result
  }

  private static func point(
    _ sample: SpatialInkSample,
    location: CGPoint,
    widthScale: Double
  ) -> PKStrokePoint {
    PKStrokePoint(
      location: location,
      timeOffset: sample.timeOffset,
      size: CGSize(
        width: sample.width * widthScale,
        height: sample.width * widthScale
      ),
      opacity: sample.opacity,
      force: sample.force,
      azimuth: sample.azimuth,
      altitude: sample.altitude
    )
  }
}

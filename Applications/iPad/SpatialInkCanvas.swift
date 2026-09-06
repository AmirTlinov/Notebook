import PencilKit
import SwiftUI
import NotebookCore
import UIKit

struct SpatialInkCanvas: UIViewRepresentable {
  let boardID: UUID
  let camera: SpatialCamera
  let viewport: SpatialPoint
  let items: [SpatialWorkspaceItemSurface]
  let journal: SpatialInkJournal?
  let penStyle: PenStyle
  let eraserStyle: EraserStyle
  let drawingTool: DrawingTool
  let surfaceRegistry: SpatialInkSurfaceRegistry
  let inputGate: NotebookInputGate
  let onCommit: (SpatialInkTool, SpatialInkColor, [SpatialInkSpan]) -> Void
  let isEnabled: Bool

  func makeCoordinator() -> Coordinator {
    Coordinator(
      surfaceRegistry: surfaceRegistry,
      inputGate: inputGate,
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
      boardID: boardID,
      camera: camera,
      viewport: viewport,
      items: items,
      journal: journal,
      penStyle: penStyle,
      eraserStyle: eraserStyle,
      drawingTool: drawingTool,
      surfaceRegistry: surfaceRegistry,
      inputGate: inputGate,
      isEnabled: isEnabled,
      onCommit: onCommit
    )
    return view
  }

  func updateUIView(_ view: SpatialInkContainerView, context: Context) {
    context.coordinator.update(
      view: view,
      boardID: boardID,
      camera: camera,
      viewport: viewport,
      items: items,
      journal: journal,
      penStyle: penStyle,
      eraserStyle: eraserStyle,
      drawingTool: drawingTool,
      surfaceRegistry: surfaceRegistry,
      inputGate: inputGate,
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
    private var surfaceRegistry: SpatialInkSurfaceRegistry
    private let inputSourceID = UUID()
    private var inputGate: NotebookInputGate
    private var pencilActionIsActive = false
    private weak var view: SpatialInkContainerView?
    private weak var window: UIWindow?
    private var recognizer: SpatialPencilGestureRecognizer?
    private let preparation = SpatialInkMeshPreparation()

    private var camera = SpatialCamera()
    private var boardSurface = SurfaceID.board
    private var viewport = SpatialPoint(x: 1, y: 1)
    private var items: [SpatialWorkspaceItemSurface] = []
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
      inputGate: NotebookInputGate,
      onCommit: @escaping (
        SpatialInkTool,
        SpatialInkColor,
        [SpatialInkSpan]
      ) -> Void
    ) {
      self.surfaceRegistry = surfaceRegistry
      self.inputGate = inputGate
      self.onCommit = onCommit
    }

    func update(
      view: SpatialInkContainerView,
      boardID: UUID,
      camera: SpatialCamera,
      viewport: SpatialPoint,
      items: [SpatialWorkspaceItemSurface],
      journal: SpatialInkJournal?,
      penStyle: PenStyle,
      eraserStyle: EraserStyle,
      drawingTool: DrawingTool,
      surfaceRegistry: SpatialInkSurfaceRegistry,
      inputGate: NotebookInputGate,
      isEnabled: Bool,
      onCommit: @escaping (
        SpatialInkTool,
        SpatialInkColor,
        [SpatialInkSpan]
      ) -> Void
    ) {
      // Finish against the geometry that received the samples, before a new
      // owner or disabled input can cancel UIKit without a final touch event.
      if !isEnabled || boardSurface != .board(boardID) {
        finishAction()
      }
      self.view = view
      let nextBoardSurface = SurfaceID.board(boardID)
      if boardSurface != nextBoardSurface {
        surfaceRegistry.unregister(view.inkView, for: boardSurface)
        boardSurface = nextBoardSurface
        preparation.cancel()
      }
      self.camera = camera
      self.viewport = viewport
      view.inkView.project(camera: camera, viewport: viewport)
      self.items = items.sorted { $0.zIndex < $1.zIndex }
      self.journal = journal
      self.penStyle = penStyle
      self.eraserStyle = eraserStyle
      self.drawingTool = drawingTool
      if self.surfaceRegistry !== surfaceRegistry {
        self.surfaceRegistry.unregister(view.inkView, for: boardSurface)
        self.surfaceRegistry = surfaceRegistry
        preparation.cancel()
      }
      if self.inputGate !== inputGate {
        if pencilActionIsActive {
          self.inputGate.endPencilAction(source: inputSourceID)
        }
        self.inputGate = inputGate
        if pencilActionIsActive {
          self.inputGate.beginPencilAction(source: inputSourceID)
        }
      }
      self.isEnabled = isEnabled
      self.onCommit = onCommit
      surfaceRegistry.register(view.inkView, for: boardSurface)
      view.accessibilityValue = "\(journal?.actions.filter(\.isActive).count ?? 0) действий"
      recognizer?.isEnabled = isEnabled
      if let window = view.window { install(on: window, inside: view) }
      scheduleRenderIfNeeded()
    }

    func install(on window: UIWindow?, inside view: SpatialInkContainerView) {
      guard let window else {
        uninstall()
        return
      }
      guard self.window !== window else {
        recognizer?.isEnabled = isEnabled
        surfaceRegistry.register(view.inkView, for: boardSurface)
        return
      }
      uninstall()
      surfaceRegistry.register(view.inkView, for: boardSurface)
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
      recognizer.onEvent = { [weak self] event in
        self?.handle(event)
      }
      window.addGestureRecognizer(recognizer)
      self.window = window
      self.view = view
      self.recognizer = recognizer
      scheduleRenderIfNeeded()
    }

    func uninstall() {
      finishAction()
      preparation.cancel()
      recognizer?.onEvent = nil
      if let recognizer { window?.removeGestureRecognizer(recognizer) }
      recognizer = nil
      window = nil
      if let view {
        surfaceRegistry.unregister(view.inkView, for: boardSurface)
      }
    }

    private func handle(_ input: SpatialPencilGestureRecognizer.Event) {
      switch input {
      case .began(let touch, let event):
        guard isEnabled else { return }
        beginAction(touch: touch, event: event)
      case .moved(let touch, let event):
        guard isEnabled else { return }
        appendSamples(touch: touch, event: event)
      case .ended(let touch, let event):
        appendSamples(touch: touch, event: event)
        finishAction()
      case .cancelled:
        finishAction()
      }
    }

    private func beginAction(touch: UITouch, event: UIEvent) {
      finishAction()
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
              covers: screenSurfaces(),
              board: boardSurface
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
              covers: screenSurfaces(),
              board: boardSurface
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
      preparation.invalidateSource()
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

      }
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

    private func routeMeasuredSegment(
      from start: PKStrokePoint,
      to end: PKStrokePoint
    ) {
      let intervals = SpatialSurfaceRouter.intervals(
        from: start.location,
        to: end.location,
        covers: screenSurfaces(),
        board: boardSurface
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
        covers: covers,
        board: boardSurface
      )
      var currentPoints = [convert(first, to: currentSurface)]
      var previousPoint = first

      for point in points.dropFirst() {
        let intervals = SpatialSurfaceRouter.intervals(
          from: previousPoint.location,
          to: point.location,
          covers: covers,
          board: boardSurface
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
      items.map { item in
        let center = camera.worldToScreen(item.center, viewport: viewport)
        let rect = CGRect(
          x: center.x - item.geometry.width * camera.scale / 2,
          y: center.y - item.geometry.height * camera.scale / 2,
          width: item.geometry.width * camera.scale,
          height: item.geometry.height * camera.scale
        )
        return SpatialScreenSurface(
          id: .cover(item.itemID),
          frame: rect,
          zIndex: item.zIndex
        )
      }
    }

    private func convert(
      _ point: PKStrokePoint,
      to surface: SurfaceID
    ) -> SpatialInkSample {
      let local: SpatialPoint
      if surface.kind == .cover,
        let itemID = surface.ownerID,
        let item = items.first(where: { $0.itemID == itemID })
      {
        let center = camera.worldToScreen(item.center, viewport: viewport)
        local = SpatialPoint(
          x: (point.location.x - center.x) / camera.scale
            + item.geometry.width / 2,
          y: (point.location.y - center.y) / camera.scale
            + item.geometry.height / 2
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
        let itemID = surface.ownerID,
        let item = items.first(where: { $0.itemID == itemID })
      else { return point }
      let center = camera.worldToScreen(item.center, viewport: viewport)
      return PKStrokePoint(
        location: CGPoint(
          x: (point.location.x - center.x) / camera.scale
            + item.geometry.width / 2,
          y: (point.location.y - center.y) / camera.scale
            + item.geometry.height / 2
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


    private func scheduleRenderIfNeeded() {
      guard actionTool == nil, let view else { return }
      let surface = boardSurface
      let pending = preparation.update(surface: surface, journal: journal) { [weak self, weak view] mesh in
        guard let self, let view else { return }
        if let mesh { surfaceRegistry.applyStable(mesh, to: surface, in: view.inkView) }
        else { view.inkView.finishSpatialPreparation() }
      }
      if pending { view.inkView.prepareForDrawing() }
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
  enum Event {
    case began(UITouch, UIEvent)
    case moved(UITouch, UIEvent)
    case ended(UITouch, UIEvent)
    case cancelled
  }

  var onEvent: ((Event) -> Void)?
  private var activeTouch: UITouch?

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
    guard activeTouch == nil else {
      cancelTracking()
      state = .cancelled
      return
    }
    guard let touch = touches.first else {
      state = .failed
      return
    }
    activeTouch = touch
    state = .began
    onEvent?(.began(touch, event))
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
    guard let touch = touches.first(where: { $0 === activeTouch }) else {
      return
    }
    state = .changed
    onEvent?(.moved(touch, event))
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
    guard let touch = touches.first(where: { $0 === activeTouch }) else {
      return
    }
    activeTouch = nil
    onEvent?(.ended(touch, event))
    state = .ended
  }

  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
    guard touches.contains(where: { $0 === activeTouch }) else {
      return
    }
    cancelTracking()
    state = .cancelled
  }

  override func reset() {
    // isEnabled, competing recognizers and window detachment can end UIKit's
    // recognition without touchesCancelled. Every accepted contact still ends.
    cancelTracking()
    super.reset()
  }

  private func cancelTracking() {
    guard activeTouch != nil else { return }
    activeTouch = nil
    onEvent?(.cancelled)
  }
}

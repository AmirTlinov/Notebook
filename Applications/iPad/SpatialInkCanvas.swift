import PencilKit
import SwiftUI
import NotebookCore
import UIKit

struct SpatialInkCanvas: UIViewRepresentable {
  // The actual input coordinator and its accepted contact own this basis.
  // A cached SwiftUI configuration must not prolong a dismantled scene.
  weak var cohort: SceneCompositionCohort?
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
  let isItemBeingDeleted: (UUID) -> Bool
  /// Geometry preparation closes admission, not an accepted physical contact.
  /// Explicit isEnabled changes still finish that contact before teardown.
  let admitsNewContact: () -> Bool
  let onCommit: (SpatialInkTool, SpatialInkColor, [SpatialInkSpan]) -> SpatialInkAction?
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
      view: view, cohort: cohort,
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
      isItemBeingDeleted: isItemBeingDeleted,
      admitsNewContact: admitsNewContact,
      isEnabled: isEnabled,
      onCommit: onCommit
    )
    return view
  }

  func updateUIView(_ view: SpatialInkContainerView, context: Context) {
    context.coordinator.update(
      view: view, cohort: cohort,
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
      isItemBeingDeleted: isItemBeingDeleted,
      admitsNewContact: admitsNewContact,
      isEnabled: isEnabled,
      onCommit: onCommit
    )
  }

  static func dismantleUIView(
    _ view: SpatialInkContainerView,
    coordinator: Coordinator
  ) {
    coordinator.retire()
  }

  @MainActor
  final class Coordinator {
    private(set) var isRetired = false
    private var surfaceRegistry: SpatialInkSurfaceRegistry
    private let inputSourceID = UUID()
    private var inputGate: NotebookInputGate
    private var pencilActionIsActive = false
    private weak var view: SpatialInkContainerView?
    private weak var window: UIWindow?
    private var recognizer: SpatialPencilGestureRecognizer?

    private var camera = SpatialCamera()
    private var boardSurface = SurfaceID.board
    private var viewport = SpatialPoint(x: 1, y: 1)
    private var items: [SpatialWorkspaceItemSurface] = []
    private var cohort: SceneCompositionCohort?
    private var journal: SpatialInkJournal?
    private var penStyle = PenStyle.standard
    private var eraserStyle = EraserStyle.standard
    private var drawingTool = DrawingTool.pen
    private var isEnabled = false
    private var isItemBeingDeleted: (UUID) -> Bool = { _ in false }
    private var admitsNewContact: () -> Bool = { true }
    private var onCommit: (
      SpatialInkTool,
      SpatialInkColor,
      [SpatialInkSpan]
    ) -> SpatialInkAction?

    private var actionTool: DrawingTool?
    private var actionPenStyle: PenStyle?
    private var actionEraserStyle: EraserStyle?
    private struct ContactGeometry {
      let camera: SpatialCamera
      let viewport: SpatialPoint
      let surfaces: [SpatialScreenSurface]
      let blockedSurfaces: Set<SurfaceID>
      let cohort: SceneCompositionCohort?
      let leases: [SpatialInkSurfaceRegistry.ContactLease]
    }
    private var actionGeometry: ContactGeometry?
    private var lastActionPoint: PKStrokePoint?
    private var actionSpans: [SpatialInkSpan] = []
    private var segmentSamples: [SpatialInkSample] = []
    private(set) var routedSegmentCount = 0
    private(set) var rejectedWorldAddressCount = 0
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
      ) -> SpatialInkAction?
    ) {
      self.surfaceRegistry = surfaceRegistry
      self.inputGate = inputGate
      self.onCommit = onCommit
    }

    func update(
      view: SpatialInkContainerView,
      cohort: SceneCompositionCohort?,
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
      isItemBeingDeleted: @escaping (UUID) -> Bool,
      admitsNewContact: @escaping () -> Bool,
      isEnabled: Bool,
      onCommit: @escaping (
        SpatialInkTool,
        SpatialInkColor,
        [SpatialInkSpan]
      ) -> SpatialInkAction?
    ) {
      guard !isRetired else { return }
      // Finish against the geometry that received the samples, before a new
      // owner or disabled input can cancel UIKit without a final touch event.
      if !isEnabled || boardSurface != .board(boardID) {
        finishAction()
      }
      self.view = view
      self.cohort = cohort
      let nextBoardSurface = SurfaceID.board(boardID)
      if boardSurface != nextBoardSurface { boardSurface = nextBoardSurface }
      self.camera = camera
      self.viewport = viewport
      self.items = items.sorted { $0.zIndex < $1.zIndex }
      if self.journal != journal {
        view.accessibilityValue = "\(journal?.actions.filter(\.isActive).count ?? 0) действий"
      }
      self.journal = journal
      self.penStyle = penStyle
      self.eraserStyle = eraserStyle
      self.drawingTool = drawingTool
      if self.surfaceRegistry !== surfaceRegistry {
        finishAction()
        view.unmount()
        self.surfaceRegistry = surfaceRegistry
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
      self.isItemBeingDeleted = isItemBeingDeleted
      self.admitsNewContact = admitsNewContact
      self.onCommit = onCommit
      refreshNativeMount()
      recognizer?.isEnabled = isEnabled
      if let window = view.window { install(on: window, inside: view) }
      refreshNativeMount()
    }

    func install(on window: UIWindow?, inside view: SpatialInkContainerView) {
      guard !isRetired else { return }
      guard let window else {
        uninstall()
        return
      }
      guard self.window !== window else {
        recognizer?.isEnabled = isEnabled
        refreshNativeMount()
        return
      }
      uninstall()
      refreshNativeMount()
      let recognizer = SpatialPencilGestureRecognizer()
      recognizer.allowedTouchTypes = [
        NSNumber(value: UITouch.TouchType.pencil.rawValue)
      ]
      #if DEBUG && targetEnvironment(simulator)
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
      recognizer.canBeginContact = { [weak self] touch in
        guard let self, let view = self.view, isEnabled, admitsNewContact(),
          sceneReceives(touch, inside: view),
          inputGate.permitsSceneContact(at: touch.preciseLocation(in: self.window), kind: .pencil),
          let surfaces = admissionSurfaces() else { return false }
        let surface = SpatialSurfaceRouter.surface(at: touch.preciseLocation(in: view),
          covers: surfaces, board: boardSurface)
        return surface.kind != .cover || surface.ownerID.map { !isItemBeingDeleted($0) && !surfaceRegistry.isRetired(surface) } == true
      }
      recognizer.onEvent = { [weak self] event in
        self?.handle(event)
      }
      window.addGestureRecognizer(recognizer)
      self.window = window
      self.view = view
      self.recognizer = recognizer
      refreshNativeMount()
    }

    func uninstall() {
      finishAction()
      recognizer?.onEvent = nil
      recognizer?.canBeginContact = nil
      if let recognizer { window?.removeGestureRecognizer(recognizer) }
      recognizer = nil
      window = nil
      view?.unmount()
    }

    /// Temporary window transfer keeps input state for the same coordinator.
    /// SwiftUI dismantle is terminal: finish accepted samples first, then drop
    /// the source and callbacks even if UIKit still retains this coordinator.
    func retire() {
      guard !isRetired else { return }
      isRetired = true
      uninstall()
      view?.onWindowChange = nil
      view = nil; cohort = nil; journal = nil; items.removeAll()
      isEnabled = false
      isItemBeingDeleted = { _ in false }
      admitsNewContact = { false }
      onCommit = { _, _, _ in nil }
    }

    private func handle(_ input: SpatialPencilGestureRecognizer.Event) {
      switch input {
      case .began(let touch, let event):
        guard isEnabled, admitsNewContact() else { return }
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
      guard inputGate.permitsNewContact else { return }
      finishAction()
      guard let view, let surfaces = admissionSurfaces() else { return }
      var leases: [SpatialInkSurfaceRegistry.ContactLease] = []
      var frozen: [SpatialScreenSurface] = []
      for surface in surfaces {
        guard let lease = surfaceRegistry.acquireContact(on: surface.id, in: view) else {
          for lease in leases { lease.release() }
          return
        }
        leases.append(lease)
        frozen.append(lease.pose?.surface ?? surface)
      }
      if let lease = surfaceRegistry.acquireContact(on: boardSurface, in: view) { leases.append(lease) }
      // Freeze the installed native pose before any finger cancellation can
      // request a return animation. No sample is deferred or replayed later.
      actionGeometry = .init(camera: camera, viewport: viewport, surfaces: frozen,
        blockedSurfaces: Set(items.filter { isItemBeingDeleted($0.itemID) || surfaceRegistry.isRetired(.cover($0.itemID)) }.map { .cover($0.itemID) }),
        cohort: cohort, leases: leases)
      setPencilActionActive(touch.type == .pencil)
      actionTool = drawingTool
      actionPenStyle = penStyle
      actionEraserStyle = eraserStyle
      lastActionPoint = nil
      actionSpans = []
      segmentSamples = []
      routedSegmentCount = 0
      rejectedWorldAddressCount = 0
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
        guard lastActionPoint.map({ timestamp > $0.timeOffset }) ?? true else {
          continue
        }
        let point = makePoint(
          touch: sampleTouch,
          timestamp: timestamp,
          tool: actionTool
        )
        if let previous = lastActionPoint {
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
        lastActionPoint = point
      }
      guard lastActionPoint != nil else { return }

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
            ) == currentSurface && convert(prediction, to: currentSurface) != nil
          }
          .map { livePoint($0, on: currentSurface) }
        activePen.replacePredictions(with: Array(predictions))
        surfaceRegistry.canvas(for: currentSurface)?
          .displayActiveStroke(activePen)
      }
    }

    private func finishAction() {
      guard let actionTool, lastActionPoint != nil else {
        cancelAction()
        return
      }
      let geometry = actionGeometry
      defer {
        for lease in geometry?.leases ?? [] { lease.release() }
        actionGeometry = nil
        setPencilActionActive(false)
        refreshNativeMount()
      }
      activePen?.replacePredictions(with: [])
      finishCurrentSegment()
      let spans = actionSpans
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
      lastActionPoint = nil
      actionSpans = []
      segmentSamples = []
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
      let committed = onCommit(actionTool == .pen ? .pen : .eraser, color, spans)
      for surface in touchedSurfaces {
        surfaceRegistry.finishAction(
          on: surface,
          keepingCommittedMesh: committed != nil,
          committedAction: committed
        )
      }
      touchedSurfaces = []
    }

    private func cancelAction() {
      let geometry = actionGeometry
      defer {
        for lease in geometry?.leases ?? [] { lease.release() }
        actionGeometry = nil
        setPencilActionActive(false)
        refreshNativeMount()
      }
      if let currentSurface {
        surfaceRegistry.canvas(for: currentSurface)?.clearActiveAction()
      }
      let cancelledSurfaces = touchedSurfaces
      actionTool = nil
      actionPenStyle = nil
      actionEraserStyle = nil
      lastActionPoint = nil
      actionSpans = []
      segmentSamples = []
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
      routedSegmentCount += 1
      let intervals = SpatialSurfaceRouter.intervals(
        from: start.location,
        to: end.location,
        covers: screenSurfaces(),
        board: boardSurface
      )
      for interval in intervals {
        if actionGeometry?.blockedSurfaces.contains(interval.surface) == true {
          // A pending cover remains an occluder, never exposed writable board.
          // Only actions admitted after deletion began acquire this exclusion.
          finishCurrentSegment()
          continue
        }
        let lower = interpolate(start, end, t: Double(interval.lowerBound))
        if currentSurface != interval.surface {
          finishCurrentSegment()
          beginSegment(on: interval.surface, with: lower)
        }
        let upper = interpolate(start, end, t: Double(interval.upperBound))
        if currentSurface == nil { beginSegment(on: interval.surface, with: upper) }
        else { appendToCurrentSegment(upper) }
      }
    }

    private func beginSegment(
      on surface: SurfaceID,
      with point: PKStrokePoint
    ) {
      guard convert(point, to: surface) != nil else {
        rejectedWorldAddressCount += 1
        finishCurrentSegment()
        return
      }
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
      // This is the same measured segment used by the live canvas. Persist
      // its physical address now; Pencil-up never routes the whole action again.
      guard let sample = convert(point, to: currentSurface) else {
        // The valid prefix remains accepted. Re-entry starts a distinct span,
        // never a line through unaddressable space or a discarded whole contact.
        rejectedWorldAddressCount += 1
        finishCurrentSegment()
        return
      }
      segmentSamples.append(sample)
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
      if !segmentSamples.isEmpty {
        actionSpans.append(.init(surface: currentSurface, samples: segmentSamples))
        segmentSamples = []
      }
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
      #if DEBUG && targetEnvironment(simulator)
        return touch.type == .direct
          && !ProcessInfo.processInfo.arguments.contains(
            SimulatorDrawingFixture.fingerGestureArgument
          )
      #else
        return false
      #endif
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
      if let actionGeometry { return actionGeometry.surfaces }
      return items.map { item in
        if let view, let surface = surfaceRegistry.pose(for: .cover(item.itemID))?.screenSurface(in: view) { return surface }
        let center = camera.worldToScreen(item.center, viewport: viewport)
        return SpatialScreenSurface(
          id: .cover(item.itemID),
          localBounds: .init(x: 0, y: 0, width: item.geometry.width, height: item.geometry.height),
          localToScreen: CGAffineTransform(a: camera.scale, b: 0, c: 0, d: camera.scale,
            tx: center.x - item.geometry.width * camera.scale / 2,
            ty: center.y - item.geometry.height * camera.scale / 2),
          zIndex: item.zIndex
        )
      }
    }

    /// The caller passes the displayed cohort, not a newly prepared index. Its
    /// complete tile coverage and native registrations are the admission proof
    /// while a later placement is still being prepared. No unshown geometry
    /// or test-specific admission path can replace this installed source.
    private func admissionSurfaces() -> [SpatialScreenSurface]? {
      guard let view, view.window != nil else { return nil }
      let surfaces = screenSurfaces()
      guard let cohort, let boardID = boardSurface.ownerID else { return nil }
      let installedItems = cohort.frame.workset(boardID: boardID).items.map {
        SpatialWorkspaceItemSurface(itemID: $0.id, geometry: $0.geometry, center: $0.center, zIndex: $0.zIndex)
      }.sorted { $0.itemID < $1.itemID }
      let suppliedItems = items.sorted { $0.itemID < $1.itemID }
      guard cohort.nativeInk.isInstalled, cohort.nativeInk.registry === surfaceRegistry,
        view.inkView === surfaceRegistry.canvas(for: boardSurface), view.inkView?.window === view.window,
        cohort.plan.presentations[.board(boardID)] != nil, installedItems == suppliedItems,
        let coverage = cohort.plan.coverage[.board(boardID)]?.tiles,
        let first = coverage.first, let last = coverage.last,
        surfaceRegistry.canvas(for: boardSurface)?.installedSpatialSource?.surface == boardSurface,
        cohort.plan.tiles.allSatisfy({ cohort.rasters[$0].map { !$0.isReleased } == true }) else { return nil }
      let visible = WorkspaceSpatialBounds(origin: camera.screenToWorld(.zero, viewport: viewport),
        width: viewport.x / camera.scale, height: viewport.y / camera.scale)
      guard WorkspaceSpatialBounds(origin: first.origin, maximum: last.bounds.maximum).contains(visible) else { return nil }
      let viewportRect = CGRect(x: 0, y: 0, width: viewport.x, height: viewport.y)
      guard let native = view.inkView, native.bounds.contains(native.convert(viewportRect, from: view)) else { return nil }
      for surface in surfaces where surface.frame.intersects(viewportRect) {
        guard let id = surface.id.ownerID, cohort.plan.allowsLive(.item(id), in: .board(boardID)) else { continue }
        guard let pose = surfaceRegistry.pose(for: surface.id), pose.cohortID == cohort.id,
          pose.boardID == boardID, pose.screenSurface(in: view) != nil,
          let canvas = surfaceRegistry.canvas(for: surface.id), canvas.window === view.window, canvas.isDescendant(of: pose.contentView),
          canvas.installedSpatialSource?.surface == surface.id else { return nil }
      }
      return surfaces
    }

    private func convert(
      _ point: PKStrokePoint,
      to surface: SurfaceID
    ) -> SpatialInkSample? {
      let camera = actionGeometry?.camera ?? self.camera
      let viewport = actionGeometry?.viewport ?? self.viewport
      let local: SpatialPoint
      if surface.kind == .cover {
        guard let geometry = screenSurfaces().first(where: { $0.id == surface }) else { return nil }
        let converted = geometry.localPoint(point.location)
        local = SpatialPoint(x: converted.x, y: converted.y)
        return SpatialInkSample(point: local, timeOffset: point.timeOffset,
          width: point.size.width / geometry.screenScale, opacity: point.opacity, force: point.force,
          azimuth: geometry.localAzimuth(point.azimuth), altitude: point.altitude)
      } else {
        guard let world = camera.worldAddress(
          at: SpatialPoint(x: point.location.x, y: point.location.y),
          viewport: viewport
        ) else { return nil }
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
    }

    private func livePoint(
      _ point: PKStrokePoint,
      on surface: SurfaceID
    ) -> PKStrokePoint {
      guard surface.kind == .cover, let geometry = screenSurfaces().first(where: { $0.id == surface }) else {
        guard let view, let canvas = surfaceRegistry.canvas(for: surface) else { return point }
        // The retained board canvas has a fixed centered crop. Measured points
        // are expressed in that same canvas before building live GPU chunks.
        return PKStrokePoint(location: canvas.convert(point.location, from: view),
          timeOffset: point.timeOffset, size: point.size, opacity: point.opacity,
          force: point.force, azimuth: point.azimuth, altitude: point.altitude)
      }
      return PKStrokePoint(
        location: geometry.localPoint(point.location),
        timeOffset: point.timeOffset,
        size: CGSize(
          width: point.size.width / geometry.screenScale,
          height: point.size.height / geometry.screenScale
        ),
        opacity: point.opacity,
        force: point.force,
        azimuth: geometry.localAzimuth(point.azimuth),
        altitude: point.altitude
      )
    }


    private func refreshNativeMount() {
      guard !isRetired, actionGeometry == nil, let view, let id = boardSurface.ownerID else { return }
      view.update(lease: cohort?.nativeInk, surface: boardSurface, boardID: id, camera: camera, active: true)
    }

  }
}

@MainActor
final class SpatialInkContainerView: SpatialInkPhysicalMountView {
  var onWindowChange: ((UIWindow?) -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
    isUserInteractionEnabled = false
    isAccessibilityElement = true
    accessibilityLabel = "Чернила доски и обложек"
    accessibilityIdentifier = "spatial-ink"
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
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
  var canBeginContact: ((UITouch) -> Bool)?
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
    guard canBeginContact?(touch) != false else {
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

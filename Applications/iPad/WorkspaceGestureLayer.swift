import SwiftUI
import UIKit

struct WorkspaceGestureLayer: UIViewRepresentable {
  let isEnabled: Bool
  let isPageOpen: Bool
  let pencilInputGate: PencilInputGate
  let onCamera: (WorkspaceMagnificationPhase) -> Void
  let onNavigate: (Int) -> Void
  let onUndo: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(
      isPageOpen: isPageOpen,
      isEnabled: isEnabled,
      pencilInputGate: pencilInputGate,
      onCamera: onCamera,
      onNavigate: onNavigate,
      onUndo: onUndo
    )
  }

  func makeUIView(context: Context) -> GestureAnchorView {
    let view = GestureAnchorView()
    view.isUserInteractionEnabled = false
    view.onWindowChange = { [weak coordinator = context.coordinator, weak view] window in
      guard let coordinator, let view else { return }
      coordinator.install(on: window, inside: view)
    }
    return view
  }

  func updateUIView(_ view: GestureAnchorView, context: Context) {
    context.coordinator.onCamera = onCamera
    context.coordinator.onNavigate = onNavigate
    context.coordinator.onUndo = onUndo
    context.coordinator.isPageOpen = isPageOpen
    context.coordinator.isEnabled = isEnabled
    context.coordinator.pencilInputGate = pencilInputGate
    if let window = view.window {
      context.coordinator.install(on: window, inside: view)
    }
  }

  static func dismantleUIView(_ view: GestureAnchorView, coordinator: Coordinator) {
    coordinator.uninstall()
  }

  @MainActor
  final class Coordinator: NSObject, UIGestureRecognizerDelegate {
    var isPageOpen: Bool {
      didSet { recognizer?.isPageOpen = isPageOpen }
    }
    var isEnabled: Bool {
      didSet {
        if oldValue != isEnabled { recognizer?.isEnabled = isEnabled }
      }
    }
    var onCamera: (WorkspaceMagnificationPhase) -> Void
    var onNavigate: (Int) -> Void
    var onUndo: () -> Void
    var pencilInputGate: PencilInputGate {
      didSet { recognizer?.pencilInputGate = pencilInputGate }
    }

    private weak var hostView: UIView?
    private weak var sceneView: UIView?
    private var recognizer: TwoFingerPaperGestureRecognizer?
    private var repeatTask: Task<Void, Never>?

    init(
      isPageOpen: Bool,
      isEnabled: Bool,
      pencilInputGate: PencilInputGate,
      onCamera: @escaping (WorkspaceMagnificationPhase) -> Void,
      onNavigate: @escaping (Int) -> Void,
      onUndo: @escaping () -> Void
    ) {
      self.isPageOpen = isPageOpen
      self.isEnabled = isEnabled
      self.pencilInputGate = pencilInputGate
      self.onCamera = onCamera
      self.onNavigate = onNavigate
      self.onUndo = onUndo
    }

    func install(on hostView: UIView?, inside sceneView: UIView) {
      guard let hostView else {
        uninstall()
        return
      }
      guard self.hostView !== hostView || self.sceneView !== sceneView else {
        return
      }
      uninstall()
      let recognizer = TwoFingerPaperGestureRecognizer(
        target: self,
        action: #selector(handle)
      )
      recognizer.allowedTouchTypes = [
        NSNumber(value: UITouch.TouchType.direct.rawValue)
      ]
      recognizer.cancelsTouchesInView = true
      recognizer.delaysTouchesBegan = false
      recognizer.delaysTouchesEnded = false
      recognizer.isPageOpen = isPageOpen
      recognizer.pencilInputGate = pencilInputGate
      recognizer.isEnabled = isEnabled
      recognizer.delegate = self
      hostView.addGestureRecognizer(recognizer)
      self.hostView = hostView
      self.sceneView = sceneView
      self.recognizer = recognizer
    }

    func uninstall() {
      repeatTask?.cancel()
      repeatTask = nil
      if let recognizer { hostView?.removeGestureRecognizer(recognizer) }
      recognizer = nil
      hostView = nil
      sceneView = nil
    }

    @objc private func handle(_ recognizer: TwoFingerPaperGestureRecognizer) {
      switch recognizer.state {
      case .began where recognizer.intent == .hold:
        onUndo()
        startRepeating()
      case .began where recognizer.intent == .magnification
        || (recognizer.intent == .navigation && !isPageOpen):
        repeatTask?.cancel()
        onCamera(
          .began(
            centroid: recognizer.startCentroidValue,
            isOpeningApproach: recognizer.intent == .magnification
              && recognizer.isOpeningApproach
          )
        )
        onCamera(
          .changed(
            scale: recognizer.magnification,
            velocity: recognizer.magnificationVelocity,
            elapsed: recognizer.gestureElapsed,
            centroid: recognizer.centroid
          )
        )
      case .changed where recognizer.intent == .magnification
        || (recognizer.intent == .navigation && !isPageOpen):
        onCamera(
          .changed(
            scale: recognizer.magnification,
            velocity: recognizer.magnificationVelocity,
            elapsed: recognizer.gestureElapsed,
            centroid: recognizer.centroid
          )
        )
      case .ended:
        repeatTask?.cancel()
        repeatTask = nil
        switch recognizer.intent {
        case .tap:
          onUndo()
        case .navigation:
          if isPageOpen, let decision = recognizer.navigationDecision {
            onNavigate(decision.direction)
          } else {
            finishCamera(recognizer)
          }
        case .magnification:
          finishCamera(recognizer)
        case .hold, .undecided:
          break
        }
      case .cancelled, .failed:
        repeatTask?.cancel()
        repeatTask = nil
        if recognizer.intent == .magnification
          || (recognizer.intent == .navigation && !isPageOpen)
        {
          onCamera(.cancelled)
        }
      default:
        break
      }
    }

    private func startRepeating() {
      repeatTask?.cancel()
      repeatTask = Task { [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(for: .milliseconds(95))
          guard !Task.isCancelled, let self else { return }
          onUndo()
        }
      }
    }

    private func finishCamera(_ recognizer: TwoFingerPaperGestureRecognizer) {
      onCamera(
        .ended(
          scale: recognizer.magnification,
          velocity: recognizer.magnificationVelocity,
          elapsed: recognizer.gestureElapsed,
          centroid: recognizer.centroid
        )
      )
    }

    func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer,
      shouldReceive touch: UITouch
    ) -> Bool {
      guard let sceneView, sceneView.window != nil else {
        return false
      }
      return sceneView.bounds.contains(touch.location(in: sceneView))
    }

    func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer,
      shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
      true
    }
  }
}

@MainActor
final class GestureAnchorView: UIView {
  var onWindowChange: ((UIWindow?) -> Void)?

  override func didMoveToWindow() {
    super.didMoveToWindow()
    onWindowChange?(window)
  }
}

struct BoardPanView: UIViewRepresentable {
  let isEnabled: Bool
  let excludedFrames: [CGRect]
  let onTap: () -> Void
  let onBegan: () -> Void
  let onChanged: (CGPoint) -> Void
  let onEnded: (CGPoint) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(
      isEnabled: isEnabled,
      excludedFrames: excludedFrames,
      onTap: onTap,
      onBegan: onBegan,
      onChanged: onChanged,
      onEnded: onEnded
    )
  }

  func makeUIView(context: Context) -> GestureAnchorView {
    let view = GestureAnchorView()
    view.isUserInteractionEnabled = false
    view.onWindowChange = { [weak coordinator = context.coordinator, weak view] window in
      guard let coordinator, let view else { return }
      coordinator.install(on: window, inside: view)
    }
    return view
  }

  func updateUIView(_ view: GestureAnchorView, context: Context) {
    context.coordinator.isEnabled = isEnabled
    context.coordinator.excludedFrames = excludedFrames
    context.coordinator.onTap = onTap
    context.coordinator.onBegan = onBegan
    context.coordinator.onChanged = onChanged
    context.coordinator.onEnded = onEnded
    if let window = view.window {
      context.coordinator.install(on: window, inside: view)
    }
  }

  static func dismantleUIView(
    _ view: GestureAnchorView,
    coordinator: Coordinator
  ) {
    coordinator.uninstall()
  }

  @MainActor
  final class Coordinator: NSObject, UIGestureRecognizerDelegate {
    var isEnabled: Bool {
      didSet {
        guard oldValue != isEnabled else { return }
        pan?.isEnabled = isEnabled
        tap?.isEnabled = isEnabled
      }
    }
    var excludedFrames: [CGRect]
    var onTap: () -> Void
    var onBegan: () -> Void
    var onChanged: (CGPoint) -> Void
    var onEnded: (CGPoint) -> Void

    private weak var hostView: UIView?
    private weak var sceneView: UIView?
    private var pan: UIPanGestureRecognizer?
    private var tap: UITapGestureRecognizer?

    init(
      isEnabled: Bool,
      excludedFrames: [CGRect],
      onTap: @escaping () -> Void,
      onBegan: @escaping () -> Void,
      onChanged: @escaping (CGPoint) -> Void,
      onEnded: @escaping (CGPoint) -> Void
    ) {
      self.isEnabled = isEnabled
      self.excludedFrames = excludedFrames
      self.onTap = onTap
      self.onBegan = onBegan
      self.onChanged = onChanged
      self.onEnded = onEnded
    }

    func install(on hostView: UIView?, inside sceneView: UIView) {
      guard let hostView else {
        uninstall()
        return
      }
      guard self.hostView !== hostView || self.sceneView !== sceneView else {
        return
      }
      uninstall()
      let pan = UIPanGestureRecognizer(
        target: self,
        action: #selector(handle)
      )
      pan.minimumNumberOfTouches = 1
      pan.maximumNumberOfTouches = 1
      pan.allowedTouchTypes = [
        NSNumber(value: UITouch.TouchType.direct.rawValue)
      ]
      pan.cancelsTouchesInView = false
      pan.delegate = self
      pan.isEnabled = isEnabled
      let tap = UITapGestureRecognizer(
        target: self,
        action: #selector(handleTap)
      )
      tap.allowedTouchTypes = [
        NSNumber(value: UITouch.TouchType.direct.rawValue)
      ]
      tap.cancelsTouchesInView = false
      tap.delaysTouchesBegan = false
      tap.delaysTouchesEnded = false
      tap.delegate = self
      tap.isEnabled = isEnabled
      hostView.addGestureRecognizer(pan)
      hostView.addGestureRecognizer(tap)
      self.hostView = hostView
      self.sceneView = sceneView
      self.pan = pan
      self.tap = tap
    }

    func uninstall() {
      if let pan { hostView?.removeGestureRecognizer(pan) }
      if let tap { hostView?.removeGestureRecognizer(tap) }
      pan = nil
      tap = nil
      hostView = nil
      sceneView = nil
    }

    @objc func handle(_ pan: UIPanGestureRecognizer) {
      let translation = pan.translation(in: sceneView)
      switch pan.state {
      case .began:
        onBegan()
      case .changed:
        onChanged(translation)
      case .ended:
        onEnded(translation)
      case .cancelled, .failed:
        onEnded(.zero)
      default:
        break
      }
    }

    @objc private func handleTap() {
      onTap()
    }

    func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer,
      shouldReceive touch: UITouch
    ) -> Bool {
      guard let sceneView, sceneView.window != nil else { return false }
      let point = touch.location(in: sceneView)
      return sceneView.bounds.contains(point)
        && !excludedFrames.contains(where: { $0.contains(point) })
    }

    func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer,
      shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
      true
    }
  }
}

/// One direct-touch owner for a closed notebook. UIKit owns tap cadence and
/// reports `UITouch.tapCount`; this view owns pickup and movement from the same
/// finger stream. Pencil touches remain owned by the window-level spatial ink
/// recognizer.
struct NotebookInteractionView: UIViewRepresentable {
  let passthroughFrames: [CGRect]
  let onTap: (CGPoint, Int) -> Void
  let onLiftChanged: (Bool) -> Void
  let onTranslationChanged: (CGSize) -> Void
  let onTranslationEnded: (CGSize) -> Void

  func makeUIView(context: Context) -> NotebookInteractionTouchView {
    let view = NotebookInteractionTouchView()
    view.backgroundColor = .clear
    view.isMultipleTouchEnabled = true
    view.accessibilityElementsHidden = true
    return view
  }

  func updateUIView(
    _ view: NotebookInteractionTouchView,
    context: Context
  ) {
    view.passthroughFrames = passthroughFrames
    view.onTap = onTap
    view.onLiftChanged = onLiftChanged
    view.onTranslationChanged = onTranslationChanged
    view.onTranslationEnded = onTranslationEnded
  }

  static func dismantleUIView(
    _ view: NotebookInteractionTouchView,
    coordinator: Void
  ) {
    view.cancelInteraction()
  }
}

@MainActor
final class NotebookInteractionTouchView: UIView {
  private static let liftDelay: TimeInterval = 0.18
  private static let movementTolerance: CGFloat = 18

  var onTap: (CGPoint, Int) -> Void = { _, _ in }
  var onLiftChanged: (Bool) -> Void = { _ in }
  var onTranslationChanged: (CGSize) -> Void = { _ in }
  var onTranslationEnded: (CGSize) -> Void = { _ in }
  var passthroughFrames: [CGRect] = []

  private weak var activeTouch: UITouch?
  private var startPoint = CGPoint.zero
  private var latestTranslation = CGSize.zero
  private var maximumTravel: CGFloat = 0
  private var liftWorkItem: DispatchWorkItem?
  private var isLifted = false

  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    super.point(inside: point, with: event)
      && !passthroughFrames.contains(where: { $0.contains(point) })
  }

  override func touchesBegan(
    _ touches: Set<UITouch>,
    with event: UIEvent?
  ) {
    let directTouches = touches.filter { $0.type == .direct }
    guard activeTouch == nil, directTouches.count == 1,
      let touch = directTouches.first
    else {
      if !directTouches.isEmpty { cancelInteraction() }
      return
    }
    activeTouch = touch
    startPoint = touch.location(in: window)
    latestTranslation = .zero
    maximumTravel = 0
    scheduleLift()
  }

  override func touchesMoved(
    _ touches: Set<UITouch>,
    with event: UIEvent?
  ) {
    guard let activeTouch,
      touches.contains(where: { $0 === activeTouch })
    else { return }
    let point = activeTouch.location(in: window)
    latestTranslation = CGSize(
      width: point.x - startPoint.x,
      height: point.y - startPoint.y
    )
    maximumTravel = max(
      maximumTravel,
      hypot(latestTranslation.width, latestTranslation.height)
    )
    if !isLifted, maximumTravel > Self.movementTolerance {
      liftWorkItem?.cancel()
      liftWorkItem = nil
    }
    if isLifted { onTranslationChanged(latestTranslation) }
  }

  override func touchesEnded(
    _ touches: Set<UITouch>,
    with event: UIEvent?
  ) {
    guard let activeTouch,
      touches.contains(where: { $0 === activeTouch })
    else { return }
    let point = activeTouch.location(in: window)
    latestTranslation = CGSize(
      width: point.x - startPoint.x,
      height: point.y - startPoint.y
    )
    maximumTravel = max(
      maximumTravel,
      hypot(latestTranslation.width, latestTranslation.height)
    )
    finishInteraction(
      acceptTap: true,
      tapLocation: activeTouch.location(in: self),
      tapCount: activeTouch.tapCount
    )
  }

  override func touchesCancelled(
    _ touches: Set<UITouch>,
    with event: UIEvent?
  ) {
    guard let activeTouch,
      touches.contains(where: { $0 === activeTouch })
    else { return }
    cancelInteraction()
  }

  func cancelInteraction() {
    finishInteraction(acceptTap: false, tapLocation: .zero, tapCount: 0)
  }

  private func scheduleLift() {
    liftWorkItem?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
      guard let self, activeTouch != nil,
        maximumTravel <= Self.movementTolerance
      else { return }
      isLifted = true
      onLiftChanged(true)
    }
    liftWorkItem = workItem
    DispatchQueue.main.asyncAfter(
      deadline: .now() + Self.liftDelay,
      execute: workItem
    )
  }

  private func finishInteraction(
    acceptTap: Bool,
    tapLocation: CGPoint,
    tapCount: Int
  ) {
    let wasLifted = isLifted
    let translation = latestTranslation
    let wasTap = acceptTap && !wasLifted
      && maximumTravel <= Self.movementTolerance
    liftWorkItem?.cancel()
    liftWorkItem = nil
    activeTouch = nil
    latestTranslation = .zero
    maximumTravel = 0
    isLifted = false

    if wasLifted {
      onTranslationEnded(translation)
      onLiftChanged(false)
    } else if wasTap {
      onTap(tapLocation, tapCount)
    }
  }
}

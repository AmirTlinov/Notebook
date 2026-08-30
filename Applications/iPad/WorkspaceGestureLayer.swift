import SwiftUI
import UIKit

struct WorkspaceGestureLayer: UIViewRepresentable {
  let isEnabled: Bool
  let isPageOpen: Bool
  let onCamera: (WorkspaceMagnificationPhase) -> Void
  let onNavigate: (Int) -> Void
  let onUndo: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(
      isPageOpen: isPageOpen,
      isEnabled: isEnabled,
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

    private weak var hostView: UIView?
    private weak var sceneView: UIView?
    private var recognizer: TwoFingerPaperGestureRecognizer?
    private var repeatTask: Task<Void, Never>?

    init(
      isPageOpen: Bool,
      isEnabled: Bool,
      onCamera: @escaping (WorkspaceMagnificationPhase) -> Void,
      onNavigate: @escaping (Int) -> Void,
      onUndo: @escaping () -> Void
    ) {
      self.isPageOpen = isPageOpen
      self.isEnabled = isEnabled
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
            mayOpenNotebook: recognizer.intent == .magnification
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
  let onBegan: () -> Void
  let onChanged: (CGPoint) -> Void
  let onEnded: (CGPoint) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(onBegan: onBegan, onChanged: onChanged, onEnded: onEnded)
  }

  func makeUIView(context: Context) -> UIView {
    let view = UIView()
    view.backgroundColor = .clear
    let pan = UIPanGestureRecognizer(
      target: context.coordinator,
      action: #selector(Coordinator.handle)
    )
    pan.minimumNumberOfTouches = 1
    pan.maximumNumberOfTouches = 1
    pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
    pan.cancelsTouchesInView = false
    view.addGestureRecognizer(pan)
    context.coordinator.pan = pan
    pan.isEnabled = isEnabled
    return view
  }

  func updateUIView(_ view: UIView, context: Context) {
    context.coordinator.onBegan = onBegan
    context.coordinator.onChanged = onChanged
    context.coordinator.onEnded = onEnded
    context.coordinator.pan?.isEnabled = isEnabled
  }

  @MainActor
  final class Coordinator: NSObject {
    var onBegan: () -> Void
    var onChanged: (CGPoint) -> Void
    var onEnded: (CGPoint) -> Void
    weak var pan: UIPanGestureRecognizer?

    init(
      onBegan: @escaping () -> Void,
      onChanged: @escaping (CGPoint) -> Void,
      onEnded: @escaping (CGPoint) -> Void
    ) {
      self.onBegan = onBegan
      self.onChanged = onChanged
      self.onEnded = onEnded
    }

    @objc func handle(_ pan: UIPanGestureRecognizer) {
      let translation = pan.translation(in: pan.view)
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
  }
}

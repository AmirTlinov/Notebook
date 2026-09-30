import SwiftUI
import UIKit

/// This permanent root supplies the real scene before any model or WebKit host.
struct NotebookRenderSceneLifetime: UIViewRepresentable {
  final class Root: UIView {
    private let owner = UUID()
    private weak var scene: UIWindowScene?
    override init(frame: CGRect) { super.init(frame: frame); isUserInteractionEnabled = false }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func didMoveToWindow() {
      super.didMoveToWindow()
      guard scene !== window?.windowScene else { return }
      scene = window?.windowScene
      SceneRenderResources.shared.setWebConstructionScene(root: owner, scene: scene)
    }
    func retire() {
      scene = nil
      SceneRenderResources.shared.setWebConstructionScene(root: owner, scene: nil)
    }
  }
  func makeUIView(context: Context) -> Root { Root(frame: .zero) }
  func updateUIView(_ view: Root, context: Context) { }
  static func dismantleUIView(_ view: Root, coordinator: Void) { view.retire() }
}

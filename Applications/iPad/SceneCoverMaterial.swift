import NotebookCore
import SwiftUI
import UIKit

/// Shadow, portal face and portal clipping project the same native opening
/// sample. Their installed content is never rebuilt by animation progress.
struct SceneCoverMaterial<Content: View>: UIViewControllerRepresentable {
  @Environment(NotebookAppModel.self) private var model
  @Environment(\.sceneComposition) private var composition
  @Environment(\.workspaceSceneFrame) private var sceneFrame
  @Environment(\.scenePlaneProjection) private var projection
  @Environment(\.workspaceItemPose) private var pose
  @Environment(\.displayScale) private var displayScale
  let itemID: UUID
  let effect: SceneCoverMaterialEffect
  @ViewBuilder let content: () -> Content
  func makeUIViewController(context: Context) -> SceneCoverMaterialController { SceneCoverMaterialController() }
  func updateUIViewController(_ controller: SceneCoverMaterialController, context: Context) {
    controller.update(model: model, itemID: itemID, effect: effect,
      content: AnyView(content().environment(model).environment(\.sceneComposition, composition)
        .environment(\.workspaceSceneFrame, sceneFrame).environment(\.scenePlaneProjection, projection)
        .environment(\.workspaceItemPose, pose).environment(\.displayScale, displayScale)))
  }
  static func dismantleUIViewController(_ controller: SceneCoverMaterialController, coordinator: ()) { controller.uninstall() }
}

enum SceneCoverMaterialEffect {
  case shadow, portalFace
  case portalClip(cornerRadius: Double, hasContents: Bool)
}

@MainActor
final class SceneCoverMaterialController: UIViewController, SceneNativeCameraOwner {
  private let host = UIHostingController(rootView: AnyView(EmptyView()))
  private weak var model: NotebookAppModel?
  private var itemID: UUID?
  private var effect = SceneCoverMaterialEffect.shadow
  private var progress = 0.0
  private let maskLayer = CAShapeLayer()
  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear; view.clipsToBounds = false
    host.view.backgroundColor = .clear; host.safeAreaRegions = []
    addChild(host); view.addSubview(host.view); host.didMove(toParent: self)
  }
  override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); host.view.frame = view.bounds; applyProgress() }
  func update(model: NotebookAppModel, itemID: UUID, effect: SceneCoverMaterialEffect, content: AnyView) {
    loadViewIfNeeded(); host.rootView = content; self.effect = effect; applyProgress()
    if self.model !== model || self.itemID != itemID {
      uninstall(); self.model = model; self.itemID = itemID
      model.nativeCameraProjection.register(self)
    }
  }
  func projectSceneCamera(_ presence: SessionPresence) {
    progress = presence.focusedItemID == itemID ? presence.openProgress : 0
    applyProgress()
  }
  private func applyProgress() {
    switch effect {
    case .shadow:
      view.layer.mask = nil; view.alpha = CoverOpeningPhysics.restingShadowVisibility(progress)
      view.isUserInteractionEnabled = false
    case .portalFace:
      view.layer.mask = nil; view.alpha = max(0, 1 - progress)
      view.isUserInteractionEnabled = progress < 0.999
    case .portalClip(let cornerRadius, let hasContents):
      view.alpha = 1; view.isUserInteractionEnabled = true
      maskLayer.frame = view.bounds
      maskLayer.path = WorkspaceCoverOutline(kind: progress > 0 ? .notebook : .board,
        cornerRadius: cornerRadius * max(0, 1 - progress), hasContents: hasContents).path(in: view.bounds).cgPath
      view.layer.mask = maskLayer
    }
  }
  func uninstall() { model?.nativeCameraProjection.remove(self); model = nil; itemID = nil }
}

#if os(iOS)
import NotebookCore
import UIKit

/// A physical scene owner projects its already installed coordinate basis.
/// It neither writes the camera nor creates a new raster during this callback.
@MainActor
protocol SceneNativeCameraOwner: AnyObject {
  func projectSceneCamera(_ presence: SessionPresence)
}

/// The model's accepted camera sample reaches every mounted physical plane in
/// one native transaction. SwiftUI continues to publish source/layout changes,
/// but a delayed representable update cannot restore an older camera sample.
/// Entries are weak physical owners, bounded by the admitted scene workset;
/// this registry never visits stored workspace objects or retained screenshots.
@MainActor
final class SceneNativeCameraProjection {
  private struct WeakOwner { weak var value: (any SceneNativeCameraOwner)? }
  private var owners: [ObjectIdentifier: WeakOwner] = [:]
  private var current: SessionPresence?

  func current(for boardID: UUID) -> SessionPresence? {
    current?.boardID == boardID ? current : nil
  }

  func register(_ owner: any SceneNativeCameraOwner) {
    owners[ObjectIdentifier(owner)] = .init(value: owner)
    if let current { transact { owner.projectSceneCamera(current) } }
  }

  func remove(_ owner: any SceneNativeCameraOwner) {
    owners[ObjectIdentifier(owner)] = nil
  }

  func update(_ presence: SessionPresence?) {
    guard current != presence else { return }
    current = presence
    owners = owners.filter { $0.value.value != nil }
    // Reset is a real lifecycle boundary. A later mount cannot inherit the
    // sample of a space which the model has already closed.
    guard let presence else { return }
    transact {
      for entry in owners.values { entry.value?.projectSceneCamera(presence) }
    }
  }

  private func transact(_ update: () -> Void) {
    // Join UIKit's current transaction rather than committing an independent
    // render-tree update from every input callback. An explicit outer commit
    // synchronously flushed all mounted WebKit surfaces (~8 ms for 24 programs),
    // even though projecting every native owner together took less than 1 ms.
    // The ordinary end-of-frame transaction publishes the whole camera once;
    // hit testing already reads these new model-layer coordinates immediately.
    let disabled = CATransaction.disableActions()
    CATransaction.setDisableActions(true)
    defer { CATransaction.setDisableActions(disabled) }
    update()
  }
}
#endif

import Foundation
import XCTest
@testable import Notebook
#if os(iOS)
import SwiftUI
import UIKit
#endif

extension XCTestCase {
  /// The lifetime of the real writer extends through its background readers.
  /// On a failed shutdown leave the database intact as failure evidence.
  @MainActor
  func retainNotebookUntilTeardown(_ model: NotebookAppModel, removing root: URL) {
    addTeardownBlock {
      let stopped = await model.shutdown()
      let failure = await model.persistenceFailure
      XCTAssertTrue(stopped, "The store cannot be removed before its writer and background work acknowledge shutdown: \(failure ?? "no persistence diagnostic")")
      guard stopped else { return }
      if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }
  }

  #if os(iOS)
  /// This is the application scene, including its native paint acknowledgements
  /// and input owners. A prepared cohort alone cannot stand in for this mount.
  @MainActor
  @discardableResult
  func mountNotebookScene(_ model: NotebookAppModel, fullRoot: Bool = false) async throws -> UIWindow {
    let presence = try XCTUnwrap(model.presence)
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow)
    let window = UIWindow(windowScene: scene)
    window.frame = .init(x: 0, y: 0, width: presence.viewport.x, height: presence.viewport.y)
    let content = fullRoot ? AnyView(NotebookRootView()) : AnyView(SpatialWorkspaceView())
    let host = UIHostingController(rootView: content.environment(model).ignoresSafeArea())
    window.rootViewController = host; window.makeKeyAndVisible()
    addTeardownBlock { @MainActor in
      window.isHidden = true; window.rootViewController = nil; previous?.makeKey()
    }
    let deadline = ContinuousClock.now + .seconds(8)
    func hasInstalledPaper() -> Bool {
      guard presence.mode == .page else { return true }
      return model.activePage.map { model.pagePresentations.isPresented($0) } ?? false
    }
    while (model.compositionTiles.published?.isPaintInstalled != true || !hasInstalledPaper()), ContinuousClock.now < deadline {
      window.layoutIfNeeded()
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(model.compositionTiles.published?.isPaintInstalled == true,
      "Both physical camera planes must install their exact paint before capturing attention")
    XCTAssertTrue(hasInstalledPaper(), "The selected physical page must be current, visible and ready")
    return window
  }
  #endif
}

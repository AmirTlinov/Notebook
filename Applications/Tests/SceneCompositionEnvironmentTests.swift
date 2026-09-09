import NotebookCore
import SwiftUI
import UIKit
import XCTest
@testable import Notebook

@MainActor
final class SceneCompositionEnvironmentTests: XCTestCase {
  func testEnvironmentCopiesCompareByTheImmutableCohortIdentity() async throws {
    let resources = SceneRenderResources(), registry = SpatialInkSurfaceRegistry(), boardID = UUID()
    var first: SceneCompositionCohort? = try await WorkspaceInkFixture.prepare(boardID: boardID,
      camera: .init(), viewport: .init(x: 256, y: 256), items: [], registry: registry, resources: resources)
    let reference = SceneCompositionReference(first)
    var environment = EnvironmentValues()
    environment.sceneComposition = reference
    for _ in 0..<100 {
      var cameraSample = environment
      cameraSample.sceneComposition = .init(first)
      XCTAssertEqual(cameraSample.sceneComposition, reference,
        "A camera sample cannot create a new environment identity for the same prepared paint")
      XCTAssertTrue(cameraSample.sceneComposition.cohort === first)
    }
    var next: SceneCompositionCohort? = try await WorkspaceInkFixture.prepare(boardID: boardID,
      camera: .init(), viewport: .init(x: 256, y: 256), items: [], registry: registry, resources: resources)
    let replacement = SceneCompositionReference(next)
    XCTAssertNotEqual(replacement, reference)
    XCTAssertNotNil(reference.id)
    XCTAssertNotNil(replacement.id)
    first = nil; next = nil
    await registry.stopSceneInk()
    try await waitUntil { resources.rasterAdmission.pinnedBytes == 0 }
    XCTAssertNil(reference.cohort)
    XCTAssertNil(replacement.cohort)
    XCTAssertEqual(environment.sceneComposition, reference,
      "A detached cache preserves its identity without preserving the actual paint")
    XCTAssertEqual(resources.reservedBytes, 0)
  }

  func testRetainedUIKitViewAndTraitEnvironmentDoNotOwnUnmountedPaint() async throws {
    let resources = SceneRenderResources(), registry = SpatialInkSurfaceRegistry()
    var cohort: SceneCompositionCohort? = try await WorkspaceInkFixture.prepare(boardID: UUID(),
      camera: .init(), viewport: .init(x: 256, y: 256), items: [], registry: registry, resources: resources)
    weak let retired = cohort
    let reference = SceneCompositionReference(cohort)
    let native = SceneEnvironmentProbeView()
    let host = UIHostingController(rootView: SceneEnvironmentProbe(view: native)
      .environment(\.sceneComposition, reference))
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    window.frame = .init(x: 0, y: 0, width: 256, height: 256)
    window.rootViewController = host; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    try await waitUntil { native.environment.sceneComposition.id == reference.id && native.window === window }
    let cachedTraits = native.traitCollection
    let cachedEnvironment = native.environment
    XCTAssertTrue(cachedEnvironment.sceneComposition.cohort === cohort)
    XCTAssertGreaterThan(resources.rasterAdmission.pinnedBytes, 0)

    // No painted view is borrowed here: only UIKit and SwiftUI environment
    // copies survive. They must not extend the published paint's lifetime.
    window.isHidden = true; window.rootViewController = nil
    cohort = nil
    await registry.stopSceneInk()
    try await waitUntil { retired == nil && resources.rasterAdmission.pinnedBytes == 0 }
    withExtendedLifetime((host, native, cachedTraits, cachedEnvironment)) {
      XCTAssertNil(retired)
      XCTAssertNil(cachedEnvironment.sceneComposition.cohort)
      XCTAssertEqual(cachedEnvironment.sceneComposition.id, reference.id)
      XCTAssertEqual(native.environment.sceneComposition, reference)
      XCTAssertEqual(resources.rasterAdmission.pinnedBytes, 0)
      XCTAssertEqual(resources.reservedBytes, 0)
    }
  }

  private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertTrue(predicate(), "A non-owning environment cannot retain retired raster leases")
  }
}

private final class SceneEnvironmentProbeView: UIView {
  var environment = EnvironmentValues()
}

private struct SceneEnvironmentProbe: UIViewRepresentable {
  let view: SceneEnvironmentProbeView
  func makeUIView(context: Context) -> SceneEnvironmentProbeView { view }
  func updateUIView(_ view: SceneEnvironmentProbeView, context: Context) {
    view.environment = context.environment
  }
}

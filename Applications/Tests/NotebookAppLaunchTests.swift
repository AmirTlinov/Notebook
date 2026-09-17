#if DEBUG
  import NotebookCore
  import SwiftUI
  import UIKit
  import XCTest
  @testable import Notebook

  @MainActor
  final class NotebookAppLaunchTests: XCTestCase {
    func testBackgroundReadersWaitForTheInitialWorkspacePublication() async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent("launch-readers-\(UUID())")
      let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
      retainNotebookUntilTeardown(model, removing: root)
      let before = model.collaborationPreparationKey
      await model.refreshCollaborationDetails()
      await model.refreshReferenceStatuses()
      XCTAssertFalse(FileManager.default.fileExists(atPath: root.path),
        "A mounted history reader must not bootstrap SQLite before the startup writer")
      XCTAssertFalse(model.collaborationDetailsAreCurrent)
      XCTAssertFalse(before.permitsPreparation)

      await model.start(pageSize: NotebookAppModel.defaultPageSize)
      XCTAssertEqual(model.loadState, .ready)
      XCTAssertNotEqual(model.collaborationPreparationKey, before,
        "Readiness must restart the view's preparation task even for an empty history")
      await model.refreshCollaborationDetails()
      XCTAssertTrue(model.collaborationDetailsAreCurrent)
      XCTAssertNil(model.persistenceFailure)
    }

    func testMountedFreshRootStartsAndReopensItsSavedWorkspace() async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent("mounted-launch-\(UUID())")
      let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
      retainNotebookUntilTeardown(model, removing: root)
      let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
      let previous = scene.windows.first(where: \.isKeyWindow)
      let window = UIWindow(windowScene: scene)
      let host = UIHostingController(rootView: AnyView(NotebookRootView().environment(model)))
      window.rootViewController = host; window.makeKeyAndVisible()
      defer {
        host.rootView = AnyView(EmptyView()); window.isHidden = true
        window.rootViewController = nil; previous?.makeKey()
      }
      let deadline = ContinuousClock.now + .seconds(15)
      while model.loadState == .loading, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
      }
      XCTAssertEqual(model.loadState, .ready)
      let item = try XCTUnwrap(model.workspace?.selectedItemID)
      let destination = WorldPoint(x: 320, y: 180)
      model.moveItem(item, to: destination)
      let saved = await model.finishPendingPersistence()
      XCTAssertTrue(saved); XCTAssertNil(model.persistenceFailure)
      host.rootView = AnyView(EmptyView())
      let stopped = await model.shutdown(); XCTAssertTrue(stopped)

      let reopened = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
      retainNotebookUntilTeardown(reopened, removing: root)
      await reopened.start(pageSize: NotebookAppModel.defaultPageSize)
      XCTAssertEqual(reopened.loadState, .ready)
      XCTAssertEqual(reopened.board?.placement(of: item)?.center, destination)
      XCTAssertNil(reopened.persistenceFailure)
    }

    func testInjectedUnitHostDoesNotConstructAWorkspaceModel() {
      let launch = NotebookDebugLaunch(arguments: [],
        environment: ["XCTestConfigurationFilePath": "/isolated/NotebookTests.xctestconfiguration"])
      XCTAssertEqual(launch, .unitTestHost)
      XCTAssertNil(launch.makeLaunch().model)
    }

    func testExplicitDrawingFixtureStillLaunchesTheApplicationWithXCTestInjection() {
      let launch = NotebookDebugLaunch(arguments: [NotebookDrawingFixture.launchArgument],
        environment: ["XCTestConfigurationFilePath": "/isolated/NotebookUITests.xctestconfiguration"])
      XCTAssertEqual(launch, .drawingFixture)
    }

    func testOrdinaryDebugLaunchCannotConstructAModelBeforeArchiveAdmission() {
      let mode = NotebookDebugLaunch(arguments: [], environment: [:])
      XCTAssertEqual(mode, .workspace)
      let launch = mode.makeLaunch()
      XCTAssertNil(launch.model)
      XCTAssertNil(launch.pairingActivationID)
    }

    func testExplicitDrawingFixtureDoesNotRequireXCTestInjection() {
      XCTAssertEqual(NotebookDebugLaunch(arguments: [NotebookDrawingFixture.launchArgument],
        environment: [:]), .drawingFixture)
    }
  }
#endif

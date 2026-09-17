#if DEBUG
  import XCTest
  @testable import Notebook

  @MainActor
  final class NotebookAppLaunchTests: XCTestCase {
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

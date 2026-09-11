#if DEBUG && targetEnvironment(simulator)
  import XCTest
  @testable import Notebook

  @MainActor
  final class NotebookAppLaunchTests: XCTestCase {
    func testInjectedUnitHostDoesNotConstructAWorkspaceModel() {
      let launch = NotebookSimulatorLaunch(arguments: [],
        environment: ["XCTestConfigurationFilePath": "/isolated/NotebookTests.xctestconfiguration"])
      XCTAssertEqual(launch, .unitTestHost)
      XCTAssertNil(launch.makeLaunch().model)
    }

    func testExplicitDrawingFixtureStillLaunchesTheApplicationWithXCTestInjection() {
      let launch = NotebookSimulatorLaunch(arguments: [SimulatorDrawingFixture.launchArgument],
        environment: ["XCTestConfigurationFilePath": "/isolated/NotebookUITests.xctestconfiguration"])
      XCTAssertEqual(launch, .drawingFixture)
    }

    func testOrdinarySimulatorLaunchCannotConstructAModelBeforeArchiveAdmission() {
      let mode = NotebookSimulatorLaunch(arguments: [], environment: [:])
      XCTAssertEqual(mode, .workspace)
      let launch = mode.makeLaunch()
      XCTAssertNil(launch.model)
      XCTAssertNil(launch.pairingActivationID)
    }

    func testExplicitDrawingFixtureDoesNotRequireXCTestInjection() {
      XCTAssertEqual(NotebookSimulatorLaunch(arguments: [SimulatorDrawingFixture.launchArgument],
        environment: [:]), .drawingFixture)
    }
  }
#endif

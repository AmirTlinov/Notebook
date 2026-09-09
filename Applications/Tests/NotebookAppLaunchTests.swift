#if DEBUG && targetEnvironment(simulator)
  import XCTest
  @testable import Notebook

  @MainActor
  final class NotebookAppLaunchTests: XCTestCase {
    func testInjectedUnitHostDoesNotConstructAWorkspaceModel() {
      let launch = NotebookSimulatorLaunch(arguments: [],
        environment: ["XCTestConfigurationFilePath": "/isolated/NotebookTests.xctestconfiguration"])
      XCTAssertEqual(launch, .unitTestHost)
      XCTAssertNil(launch.makeModel())
    }

    func testExplicitDrawingFixtureStillLaunchesTheApplicationWithXCTestInjection() {
      let launch = NotebookSimulatorLaunch(arguments: [SimulatorDrawingFixture.launchArgument],
        environment: ["XCTestConfigurationFilePath": "/isolated/NotebookUITests.xctestconfiguration"])
      XCTAssertEqual(launch, .drawingFixture)
    }

    func testOrdinarySimulatorLaunchKeepsTheWorkspaceRuntime() {
      XCTAssertEqual(NotebookSimulatorLaunch(arguments: [], environment: [:]), .workspace)
    }

    func testExplicitDrawingFixtureDoesNotRequireXCTestInjection() {
      XCTAssertEqual(NotebookSimulatorLaunch(arguments: [SimulatorDrawingFixture.launchArgument],
        environment: [:]), .drawingFixture)
    }
  }
#endif

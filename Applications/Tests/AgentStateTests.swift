import TetradCore
import XCTest
@testable import Tetrad

final class AgentStateTests: XCTestCase {
  @MainActor
  func testInteractiveElementCanCommitAnyJSONRoot() {
    XCTAssertEqual(AgentWebCoordinator.decodeState(7), .number(7))
    XCTAssertEqual(AgentWebCoordinator.decodeState("готово"), .string("готово"))
    XCTAssertEqual(AgentWebCoordinator.decodeState(NSNull()), .null)
    XCTAssertEqual(
      AgentWebCoordinator.decodeState(["enabled": true]),
      .object(["enabled": .bool(true)])
    )
  }
}

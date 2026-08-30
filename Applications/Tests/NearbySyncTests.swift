import TetradCore
import XCTest
@testable import Tetrad

final class NearbySyncTests: XCTestCase {
  func testConsecutiveCameraFramesKeepOnlyTheFreshestPendingPresence() {
    var queue = WireSendQueue()
    let first = presence(centerX: 10)
    let newest = presence(centerX: 40)

    queue.enqueue(.presence(first))
    queue.enqueue(.presence(newest))

    XCTAssertEqual(queue.messages, [.presence(newest)])
  }

  func testAStateMutationKeepsItsPlaceBetweenCameraFrames() {
    var queue = WireSendQueue()
    let actor = UUID()
    let first = presence(centerX: 10)
    let newest = presence(centerX: 40)
    let journal = SpatialInkJournal(
      stamp: VersionStamp(counter: 0, actor: actor)
    )

    queue.enqueue(.presence(first))
    queue.enqueue(.spatialInk(journal))
    queue.enqueue(.presence(newest))

    XCTAssertEqual(
      queue.messages,
      [.presence(first), .spatialInk(journal), .presence(newest)]
    )
  }

  private func presence(centerX: Double) -> SessionPresence {
    SessionPresence(
      mode: .board,
      camera: SpatialCamera(center: WorldPoint(x: centerX, y: 0)),
      viewport: SpatialPoint(x: 1_024, y: 1_366)
    )
  }
}

import TetradCore
import XCTest
@testable import Tetrad

final class NearbySyncTests: XCTestCase {
  func testAnEmptySendQueueExposesNoMessages() {
    XCTAssertEqual(WireSendQueue().messages, [])
  }

  func testPresenceSequenceRejectsDuplicatesAndOlderFrames() {
    var tracker = PresenceSequenceTracker()
    let sessionID = UUID()
    let newest = envelope(
      sessionID: sessionID,
      sequence: 4,
      phase: .active,
      centerX: 40
    )
    let older = envelope(
      sessionID: sessionID,
      sequence: 3,
      phase: .active,
      centerX: 30
    )

    XCTAssertTrue(tracker.accepts(newest))
    XCTAssertFalse(tracker.accepts(newest))
    XCTAssertFalse(tracker.accepts(older))
    XCTAssertTrue(
      tracker.accepts(
        envelope(
          sessionID: UUID(),
          sequence: 1,
          phase: .settled,
          centerX: 50
        )
      )
    )
  }

  func testConsecutiveCameraFramesKeepOnlyTheFreshestPendingPresence() {
    var queue = WireSendQueue()
    let sessionID = UUID()
    let first = envelope(
      sessionID: sessionID,
      sequence: 1,
      phase: .active,
      centerX: 10
    )
    let newest = envelope(
      sessionID: sessionID,
      sequence: 2,
      phase: .active,
      centerX: 40
    )

    queue.enqueue(.presence(first))
    queue.enqueue(.presence(newest))

    XCTAssertEqual(queue.messages, [.presence(newest)])
  }

  func testAStateMutationKeepsItsPlaceBetweenCameraFrames() {
    var queue = WireSendQueue()
    let actor = UUID()
    let sessionID = UUID()
    let first = envelope(
      sessionID: sessionID,
      sequence: 1,
      phase: .active,
      centerX: 10
    )
    let newest = envelope(
      sessionID: sessionID,
      sequence: 2,
      phase: .active,
      centerX: 40
    )
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

  func testSettledPresenceCannotBeReplacedByTheNextGesture() {
    var queue = WireSendQueue()
    let sessionID = UUID()
    let settled = envelope(
      sessionID: sessionID,
      sequence: 8,
      phase: .settled,
      centerX: 30
    )
    let nextGesture = envelope(
      sessionID: sessionID,
      sequence: 9,
      phase: .active,
      centerX: 34
    )

    queue.enqueue(.presence(settled))
    queue.enqueue(.presence(nextGesture))

    XCTAssertEqual(queue.messages, [.presence(settled), .presence(nextGesture)])
  }

  func testPendingFullDrawingKeepsOnlyTheNewestRevision() {
    var queue = WireSendQueue()
    let pageID = UUID()
    let actor = UUID()
    queue.enqueue(
      .drawing(
        pageID: pageID,
        data: Data([1]),
        stamp: VersionStamp(counter: 1, actor: actor)
      )
    )
    let newest = WireMessage.drawing(
      pageID: pageID,
      data: Data([2]),
      stamp: VersionStamp(counter: 2, actor: actor)
    )
    queue.enqueue(newest)

    XCTAssertEqual(queue.messages, [newest])
  }

  private func envelope(
    sessionID: UUID,
    sequence: UInt64,
    phase: PresencePhase,
    centerX: Double
  ) -> PresenceEnvelope {
    PresenceEnvelope(
      sessionID: sessionID,
      sequence: sequence,
      phase: phase,
      presence: SessionPresence(
        mode: .board,
        camera: SpatialCamera(center: WorldPoint(x: centerX, y: 0)),
        viewport: SpatialPoint(x: 1_024, y: 1_366)
      )
    )
  }
}

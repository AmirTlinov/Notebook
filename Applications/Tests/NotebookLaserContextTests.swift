import NotebookCore
import XCTest
@testable import Notebook

@MainActor final class NotebookLaserContextTests: XCTestCase {
  func testOnlyLatestFiveUnexpiredCropsGoToOneMatchingMessage() async throws {
    var time = 100.0
    let queue = NotebookLaserContext(now:{ time })
    let scope = NotebookLaserContext.Scope(computer:UUID(),thread:"current")
    var rendered: [Int] = []
    for index in 0..<7 {
      queue.append(scope:scope) { rendered.append(index); return [] }
    }
    XCTAssertEqual(queue.count,5); XCTAssertTrue(rendered.isEmpty,"Pointing alone never submits or renders agent input")
    time = 129.999
    let taken = queue.take(scope:scope)
    XCTAssertEqual(taken.count,5); XCTAssertEqual(queue.count,0)
    _ = await NotebookLaserContext.images(taken)
    XCTAssertEqual(rendered,[2,3,4,5,6])
    XCTAssertTrue(queue.take(scope:scope).isEmpty)
    queue.append(scope:scope) { XCTFail("Expired crop rendered"); return [] }
    time += 30
    XCTAssertTrue(queue.take(scope:scope).isEmpty)
    queue.append(scope:scope) { XCTFail("Another task received pointing"); return [] }
    XCTAssertTrue(queue.take(scope:.init(computer:scope.computer,thread:"another")).isEmpty)
    XCTAssertEqual(queue.count,0)
  }

  func testNativeTypingAndHeldObjectsExcludePageNavigationUntilTheirContactEnds() {
    let gate = NotebookInputGate(), contact = NSObject(), view = NSObject()
    let id = ObjectIdentifier(contact)
    XCTAssertTrue(gate.permitsPageNavigation)
    _ = gate.fingerContactOwner(for:id) { .nativeInput(ObjectIdentifier(view)) }
    XCTAssertFalse(gate.permitsPageNavigation)
    gate.endFingerContacts([id])
    _ = gate.fingerContactOwner(for:id) { .scene }
    gate.claimSceneObjectContact(id)
    XCTAssertFalse(gate.permitsPageNavigation)
    gate.endFingerContacts([id]); XCTAssertTrue(gate.permitsPageNavigation)
  }
}

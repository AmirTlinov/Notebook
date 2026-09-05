import XCTest
import NotebookCore
@testable import Notebook

final class InputLatencyTests: XCTestCase {
  @MainActor
  func testCameraFinishesContactWithoutWaitingForArchivePublication() async throws {
    let gate = NotebookInputGate()
    let page = PageDocument(size: .init(width: 834, height: 1194), actor: UUID())
    let stamp = VersionStamp(counter: 1, actor: UUID())
    var release: CheckedContinuation<PreparedPageInkChange?, Never>?
    let began = expectation(description: "preparation suspended")
    let coordinator = PencilCanvasView.Coordinator(inputGate: gate, reserveAction: { _ in stamp }, commitAction: { _, _, _ in
      await withCheckedContinuation { continuation in release = continuation; began.fulfill() }
    })
    let paper = PaperCanvasContainerView()
    coordinator.attach(to: paper)
    coordinator.setPageFinisherCurrent(true)
    coordinator.apply(Data(), pageID: page.id, to: paper)
    let action = PageInkAction(tool: .pen, samples: [.init(point: .init(x: 10, y: 20), timeOffset: 0,
      width: 2, opacity: 1, force: 1, azimuth: 0, altitude: 1)])
    coordinator.commit(action, on: paper)
    await fulfillment(of: [began], timeout: 2)
    var cameraStarted = false, publicationFinished = false
    gate.performAfterPageContact { cameraStarted = true }
    gate.performAfterPageInput { publicationFinished = true }
    XCTAssertTrue(cameraStarted)
    XCTAssertFalse(publicationFinished)
    let change = try page.prepareInkChange(.append(action), stamp: stamp)
    release?.resume(returning: change)
    for _ in 0..<100 where !publicationFinished { await Task.yield() }
    XCTAssertTrue(publicationFinished)
    XCTAssertEqual(paper.touchView.accessibilityValue, "1 действий пера")
    coordinator.detach(from: paper)
  }
}

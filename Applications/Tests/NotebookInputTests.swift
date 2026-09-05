import UIKit
import NotebookCore
import XCTest
@testable import Notebook

final class NotebookInputTests: XCTestCase {
  @MainActor
  func testProbeRetainsContactWithoutAnyDisplayCallback() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("runtime"), withIntermediateDirectories: true)
    let monitor = InputFrameMonitor(root: root)
    monitor.begin(mode: "board")
    monitor.end()
    let url = root.appendingPathComponent("runtime/input-frames.json")
    for _ in 0..<100 where !FileManager.default.fileExists(atPath: url.path) { try await Task.sleep(for: .milliseconds(10)) }
    let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
    XCTAssertEqual(rows.count, 1)
    XCTAssertNotNil(rows[0]["lastServiceToEndMS"])
    XCTAssertEqual((rows[0]["cadence"] as? [String: Any])?["totalIntervals"] as? Int, 0)
  }

  @MainActor
  func testDisplayProbeDoesNotRetainAnUnmountedSurface() {
    var monitor: InputFrameMonitor? = .init(root: FileManager.default.temporaryDirectory)
    weak var weakMonitor = monitor
    monitor?.begin(mode: "board")
    monitor = nil
    XCTAssertNil(weakMonitor)
  }

  @MainActor
  func testContactObserverCannotClaimCameraOrInteractiveTouches() {
    let observer = NotebookContactObserver(gate: NotebookInputGate())
    let camera = UIPanGestureRecognizer()
    XCTAssertFalse(observer.canPrevent(camera))
    XCTAssertFalse(observer.canBePrevented(by: camera))
    XCTAssertFalse(observer.cancelsTouchesInView)
    XCTAssertFalse(observer.delaysTouchesBegan)
    XCTAssertFalse(observer.delaysTouchesEnded)
  }

  @MainActor
  func testIdleWaitsForAllContactsAndCurrentInkSerialization() async throws {
    let gate = NotebookInputGate(), first = UUID(), second = UUID(), page = UUID()
    var callbacks: [NotebookInputCompletion] = []
    var changes: [Bool] = []
    gate.onActivityChange = { changes.append($0) }
    gate.registerPageFinisher(source: page) { callbacks.append($0) }
    gate.setCurrentPageSource(page, isCurrent: true)
    gate.beginContact(source: first); gate.beginContact(source: second)
    gate.endContact(source: first)
    XCTAssertTrue(gate.isActive)
    XCTAssertTrue(callbacks.isEmpty)
    gate.endContact(source: second)
    for _ in 0..<20 where callbacks.isEmpty { await Task.yield() }
    XCTAssertEqual(callbacks.count, 1)
    gate.beginContact(source: first)
    gate.endContact(source: first)
    for _ in 0..<20 where callbacks.count < 2 { await Task.yield() }
    XCTAssertEqual(callbacks.count, 2)
    callbacks[0]()
    XCTAssertTrue(gate.isActive, "Предыдущий хвост не завершает новое касание")
    callbacks[1]()
    XCTAssertFalse(gate.isActive)
    XCTAssertEqual(changes, [true, false])
  }

  @MainActor
  func testIncomingCompositionWaitsForFingerAndMergesHumanContinuation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    model.start(pageSize: NotebookAppModel.defaultPageSize)
    var incoming = try XCTUnwrap(model.collaborationContent)
    let source = UUID()
    let element = AgentElement(id: "agent", kind: .web, frame: .init(x: 100, y: 100, width: 200, height: 80), source: "Agent", html: "Agent")
    XCTAssertTrue(incoming.pages[0].replaceElements([element], actor: UUID()))
    model.inputGate.beginContact(source: source)
    for _ in 0..<50 { model.receivePeerMessage(.collaboration(.init(content: incoming))) }
    XCTAssertTrue(try XCTUnwrap(model.activePage).elements.isEmpty)
    XCTAssertTrue(try model.store.loadPage(incoming.pages[0].id).elements.isEmpty)
    XCTAssertFalse(model.permitsBackgroundPreparation)
    var human = try model.store.loadPage(incoming.pages[0].id)
    XCTAssertTrue(human.replaceElements([.init(id: "human", kind: .markdown, frame: .init(x: 30, y: 400, width: 120, height: 90), source: "Human", html: "Human")], actor: model.actorID))
    _ = try model.store.saveMergedPage(human)
    model.inputGate.endContact(source: source)
    for _ in 0..<100 where model.inputGate.isActive { await Task.yield() }
    XCTAssertFalse(model.inputGate.isActive)
    XCTAssertEqual(Set(try XCTUnwrap(model.activePage).elements.map(\.id)), ["agent", "human"])
    XCTAssertEqual(Set(try model.store.loadPage(human.id).elements.map(\.id)), ["agent", "human"])
  }
}

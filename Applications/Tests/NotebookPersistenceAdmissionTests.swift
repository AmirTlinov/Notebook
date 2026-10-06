import Foundation
import XCTest
@testable import NotebookCore
@testable import Notebook

final class NotebookPersistenceAdmissionTests: XCTestCase {
  private enum Disk: Error { case unavailable }
  private final class ResidentBody: Sendable {
    let data: Data
    init(_ value: UInt8) { data = Data(repeating: value, count: 262_144) }
  }
  private final class BodyWitness {
    weak var value: ResidentBody?
    init(_ value: ResidentBody) { self.value = value }
  }

  @MainActor
  func testStorageFailureReachesABytePlateauAndRetryReleasesEachAcceptedBody() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let ready = root.appendingPathComponent("ready")
    let bodyBytes = 262_144
    let cost = NotebookPersistenceAdmission.Cost(payloadBytes: bodyBytes)
    let queue = NotebookPersistenceQueue(store: .init(root: root),
      admissionLimits: .init(maximumBytes: bodyBytes * 4, maximumOperations: 4))
    var commits = 0
    var bodies: [BodyWitness] = []
    queue.onCommit = { _ in commits += 1 }
    for index in 0..<4 {
      let body = ResidentBody(UInt8(index)); bodies.append(.init(body))
      let reservation = try XCTUnwrap(queue.reserveWrite(cost))
      try queue.enqueueReserved(owner: .pageInk(UUID()), reservation: reservation, cost: cost) { _ in
        guard FileManager.default.fileExists(atPath: ready.path) else { throw Disk.unavailable }
        return body.data.first == nil
      }
    }
    let blocked = await queue.flush()
    XCTAssertFalse(blocked)
    XCTAssertEqual(queue.pendingCount, 4)
    XCTAssertEqual(queue.acceptedPayloadBytes, bodyBytes * 4)
    XCTAssertEqual(queue.reservedWriteBytes, bodyBytes * 4)
    XCTAssertTrue(bodies.allSatisfy { $0.value != nil })
    XCTAssertEqual(queue.admittedOperationCount, 4)
    for _ in 0..<100 { XCTAssertNil(queue.reserveWrite(cost)) }
    XCTAssertEqual(queue.reservedWriteBytes, bodyBytes * 4)
    try Data().write(to: ready)
    queue.retry()
    let saved = await queue.flush()
    XCTAssertTrue(saved)
    XCTAssertEqual(commits, 4)
    XCTAssertEqual(queue.pendingCount, 0)
    XCTAssertEqual(queue.reservedWriteBytes, 0)
    XCTAssertEqual(queue.admittedOperationCount, 0)
    XCTAssertTrue(bodies.allSatisfy { $0.value == nil }, "Completed FIFO slots must release their exact captured bodies")
  }

  @MainActor
  func testPreparationShrinksItsCreditWhileBlockedAndKeepsTheResultAcrossRetry() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let queue = NotebookPersistenceQueue(store: .init(root: root),
      admissionLimits: .init(maximumBytes: 1_024, maximumOperations: 3))
    let marker = root.appendingPathComponent("ready")
    queue.enqueue { _ in
      guard FileManager.default.fileExists(atPath: marker.path) else { throw Disk.unavailable }
      return false
    }
    let blocked = await queue.flush()
    XCTAssertFalse(blocked)
    let reservation = try XCTUnwrap(queue.reserveWrite(.init(payloadBytes: 768, completionBytes: 256)))
    let prepared = expectation(description: "The material worker is finished")
    let result = try queue.enqueuePreparedCommand(reservation: reservation, Task {
      NotebookPersistenceQueue.PreparedCommand(cost: .init(payloadBytes: 128, completionBytes: 128),
        operation: { _ in 19 })
    }, publishesChanges: true)
    let shrinkWait = Task { @MainActor in
      let deadline = ContinuousClock.now + .seconds(2)
      while queue.acceptedPayloadBytes != 128, ContinuousClock.now < deadline { await Task.yield() }
      if queue.acceptedPayloadBytes == 128 { prepared.fulfill() }
    }
    await fulfillment(of: [prepared], timeout: 2)
    await shrinkWait.value
    XCTAssertEqual(queue.acceptedCompletionBytes, 128)
    XCTAssertEqual(queue.reservedWriteBytes, 256)
    let nextContact = try XCTUnwrap(queue.reserveWrite(.init(payloadBytes: 768)))
    result.cancel()
    queue.releaseWriteReservation(nextContact)
    XCTAssertEqual(queue.reservedWriteBytes, 256)
    try Data().write(to: marker)
    queue.retry()
    let saved = await queue.flush()
    XCTAssertTrue(saved)
    let value = try await result.value
    XCTAssertEqual(value, 19)
    XCTAssertEqual(queue.reservedWriteBytes, 0)
  }

  @MainActor
  func testAReservationCannotBeTransferredTwiceOrUsedByAnotherWriter() throws {
    let first = NotebookPersistenceAdmission(limits: .init(maximumBytes: 1_024, maximumOperations: 2))
    let other = NotebookPersistenceAdmission(limits: .init(maximumBytes: 1_024, maximumOperations: 2))
    let reserved = try XCTUnwrap(first.reserve(.init(payloadBytes: 512, completionBytes: 256)))
    XCTAssertThrowsError(try other.transfer(reserved))
    XCTAssertThrowsError(try first.transfer(reserved, retaining: .init(payloadBytes: 769)))
    XCTAssertEqual(first.occupiedBytes, 768)
    let charge = try first.transfer(reserved, retaining: .init(payloadBytes: 64, completionBytes: 128))
    XCTAssertThrowsError(try first.transfer(reserved))
    first.release(reserved)
    XCTAssertEqual(first.occupiedBytes, 192, "The contact cannot free credit already owned by accepted storage")
    first.releaseCharge(charge); first.releaseCharge(charge)
    XCTAssertEqual(first.occupiedBytes, 0)
  }

  func testLiveInkWorstLiteralBodyFitsItsFinishReserveAndRejectsTheNextMeasurement() throws {
    let samples = (0..<NotebookInkWriteAllowance.maximumMeasurements).map { index in
      SpatialInkSample(point: .init(x: Double(index).squareRoot(), y: sin(Double(index))),
        timeOffset: Double(index) / 120, width: 2.5, opacity: 1,
        force: Double(index % 97) / 100, azimuth: 0.4, altitude: 1.1)
    }
    let action = PageInkAction(tool: .pen, samples: samples)
    let cost = try NotebookInkWriteAllowance.cost(action)
    XCTAssertEqual(cost.payloadBytes, action.samples.payloadBytes + MemoryLayout<PageInkAction>.stride)
    XCTAssertLessThanOrEqual(cost.bytes, NotebookInkWriteAllowance.maximumCost.bytes)
    XCTAssertThrowsError(try NotebookInkWriteAllowance.cost(PageInkAction(tool: .pen, samples: samples + [samples.last!])))
  }

  func testElementAdmissionCountsSemanticStateInsteadOfOnlyItsWireTokens() throws {
    let target = CollaborationTarget(kind: .page, id: UUID())
    let reference = EditableElementReference.page(pageID: target.id, elementID: "source")
    func plan(_ state: JSONValue) -> NotebookElementCommandPlan {
      let element = AgentElement(id: "source", kind: .web, frame: .init(x: 0, y: 0, width: 200, height: 100),
        source: "", html: "<p>source</p>", state: state)
      return .init(target: target, references: [reference],
        sources: [reference: .init(target: target, id: "source", page: element)], sourceTasks: [:],
        operations: [.init(kind: .updateElement, target: target, id: "source", values: ["html": .string("<p>next</p>")])],
        summary: "Update", layerMove: nil, copiedFrom: [:], expectedInkRevision: nil)
    }
    let small = try NotebookElementWriteAllowance.cost(plan(.array(Array(repeating: .number(0), count: 100))))
    XCTAssertGreaterThan(small.payloadBytes, 200)
    XCTAssertGreaterThan(small.completionBytes, small.payloadBytes)
    XCTAssertThrowsError(try NotebookElementWriteAllowance.cost(plan(.array(Array(repeating: .number(0), count: 1_000_000)))))
  }

  func testElementAdmissionChargesAFrozenGraphOnceAndOnlyAsRetainedContent() throws {
    let target=CollaborationTarget(kind:.page,id:UUID()),frame=PageRect(x:0,y:0,width:20,height:20)
    let graph=NotebookGraphicGraph((0..<20).map { index in
      .init(id:"g\(index)",graphic:.init(shape:.rectangle,label:String(repeating:"body",count:1_024)),
        frame:frame,surface:.page(target.id),shown:true)
    })
    let refs=(0..<2).map { EditableElementReference.page(pageID:target.id,elementID:"g\($0)") }
    var plan=NotebookElementCommandPlan(target:target,references:refs,sources:[:],sourceTasks:[:],
      operations:[],summary:"Move",layerMove:nil,copiedFrom:[:],expectedInkRevision:nil)
    for ref in refs { plan.drafts[ref] = .init(source:.init(frame:frame),graphic:nil) }
    let plain=try NotebookElementWriteAllowance.cost(plan)
    for ref in refs {
      plan.drafts[ref]?.capture = .init(graph:graph,source:.init(frame:frame),id:ref.elementID)
    }
    let retained=try NotebookElementWriteAllowance.cost(plan)
    XCTAssertGreaterThanOrEqual(retained.payloadBytes-plain.payloadBytes,graph.retainedSourceBytes)
    XCTAssertLessThan(retained.payloadBytes-plain.payloadBytes,graph.retainedSourceBytes * 2)
    XCTAssertEqual(retained.completionBytes,plain.completionBytes,"Frozen scene content is neither the command inverse nor encoded again")
  }
}

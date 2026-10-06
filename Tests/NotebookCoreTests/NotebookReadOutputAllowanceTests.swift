import Foundation
import Testing
@testable import NotebookCore

@Suite("Addressed output borrows the aggregate read allowance")
struct NotebookReadOutputAllowanceTests {
  @Test func repeatedCompressedInkCannotRenewFlattenedOutputAndCaughtRefusalClosesTheCut() throws {
    let fixture = try NotebookItemLifecycleTests.Fixture(), store = fixture.store
    let samples: [SpatialInkSample] = (0..<16).map { index in
      let x = Double(index + 10), y = Double(index % 3 + 20)
      let offset = Double(index) / 32
      return SpatialInkSample(point: SpatialPoint(x: x, y: y), timeOffset: offset,
        width: 2, opacity: 1, force: 0.5, azimuth: 0, altitude: 1)
    }
    let seed = InkSampleRelations(sourceID: UUID(), revision: UUID(), samples: samples,
      header: .init(tool: .pen, color: .black, sequence: 1)).settingExit(.init(x: .zero, y: .zero, time: .one), revision: UUID())
    let repeated = try #require(seed.repeated(64, revision: UUID()))
    let encoded = try repeated.measurements.encodedRelations()
    #expect(repeated.measurements.count == 1_024 && encoded.count < 16_384)
    let action = repeated.restoredAction()
    var page = try store.loadPage(fixture.pageID)
    _ = try page.replaceDrawing(PageInkDrawing(actions: [action]).dataRepresentation(), actor: fixture.actor)
    try store.savePage(page)
    var query = NotebookReadQuery(kind: .pageInkAction, id: fixture.pageID)
    query.elementID = action.id.uuidString
    let single = command([query]), readCursor = try store.currentReadCursor(), deliveryCursor = try store.currentChangeCursor()
    let first = try NotebookCommandDispatcher(store: store).handle(single)
    #expect(first["values"]?.array.first?["action"]?["samples"]?.array.count == 1_024)
    do {
      _ = try NotebookCommandDispatcher(store: store).handle(command(Array(repeating: query, count: 8)))
      Issue.record("Repeated short relation bytes must not renew the expanded output allowance")
    } catch let error as CollaborationError { #expect(error.code == "resource_limit") }

    let reader = NotebookReadSession(store: store), admitted = try NotebookReadCommand(single)
    var admittedFirst = false, refusedSecond = false
    do {
      try reader.observe { cut in
        let database = try #require(store.currentSQL)
        try database.limitReads(.init(rows: 4_096, bytes: 8 * 1_024 * 1_024,
          valueBytes: 4 * 1_024 * 1_024, reason: "shared_output",
          jsonDecodeBytes: 18 * 1_024 * 1_024))
        let retained = try cut.handle(admitted); admittedFirst = retained["values"]?.array.count == 1
        do { _ = try cut.handle(admitted); Issue.record("A nested output phase renewed its parent's remaining credit") }
        catch let error as CollaborationError { #expect(error.code == "resource_limit"); refusedSecond = true }
        withExtendedLifetime(retained) { }
      }
      Issue.record("Catching output refusal must not make the read cut successful")
    } catch NotebookStorageError.limitExceeded { }
    #expect(admittedFirst && refusedSecond)
    #expect(try store.currentReadCursor() == readCursor)
    #expect(try store.currentChangeCursor() == deliveryCursor)
    #expect(try reader.observe { try $0.currentReadCursor() } == readCursor,
      "The refused output's allowance ends with its snapshot")
  }

  @Test func derivativeFilesPayAggregateSourceDecodeAndProjectionBeforeReturningRepeatedReceipts() throws {
    let fixture = try NotebookItemLifecycleTests.Fixture(), store = fixture.store
    let (receipt, data) = try derivative(store: store, pageID: fixture.pageID)
    let query = NotebookReadQuery(kind: .targetRenderReceipt, id: receipt.request.id)
    let single = command([query]), cursor = try store.currentReadCursor()
    let first = try NotebookCommandDispatcher(store: store).handle(single)
    #expect(first["values"]?.array.first?["diagnostics"]?.array.first?["message"] == .string(receipt.diagnostics[0].message))
    do {
      _ = try NotebookCommandDispatcher(store: store).handle(command(Array(repeating: query, count: 128)))
      Issue.record("Repeated filesystem receipts must share the same read allocation allowance")
    } catch let error as CollaborationError { #expect(error.code == "resource_limit") }

    let phase = try NotebookJSONAdmission.allocationCost(data, maximumBytes: Int.max), reader = NotebookReadSession(store: store)
    var admittedFirst = false, refusedSecond = false
    do {
      try reader.observe { _ in
        let database = try #require(store.currentSQL)
        try database.limitReads(.init(rows: 128, bytes: data.count * 4, valueBytes: data.count,
          reason: "shared_derivative", jsonDecodeBytes: phase * 3))
        let retained = try store.loadTargetRenderReceipt(receipt.request.id)
        admittedFirst = retained == receipt
        do { _ = try store.loadTargetRenderReceipt(receipt.request.id); Issue.record("A derivative helper renewed its decode credit") }
        catch NotebookStorageError.limitExceeded { refusedSecond = true }
        withExtendedLifetime(retained) { }
      }
      Issue.record("Caught derivative refusal must close the enclosing read snapshot")
    } catch NotebookStorageError.limitExceeded { }
    #expect(admittedFirst && refusedSecond)
    #expect(try store.currentReadCursor() == cursor)
    // This file is valid JSON. A source-byte refusal must win before the
    // buffer/decode path, including when its typed output would otherwise fit.
    do {
      try reader.observe { _ in
        try store.currentSQL!.limitReads(.init(rows: 16, bytes: data.count - 1,
          valueBytes: data.count, reason: "derivative_source", jsonDecodeBytes: phase * 8))
        _ = try store.loadTargetRenderReceipt(receipt.request.id)
      }
      Issue.record("The derivative source must be admitted before allocating its file buffer")
    } catch NotebookStorageError.limitExceeded { }
  }

  @Test func observationalOutputAdmissionDoesNotWithdrawAnAcceptedNativeWriter() throws {
    let fixture = try NotebookItemLifecycleTests.Fixture(), store = fixture.store
    let (receipt, _) = try derivative(store: store, pageID: fixture.pageID)
    try store.commandTransaction(readAllowance: .init(rows: 1_024, bytes: 1_048_576,
      valueBytes: 262_144, reason: "native_input", jsonDecodeBytes: 1)) {
      let actual = try store.loadTargetRenderReceipt(receipt.request.id)
      #expect(actual == receipt)
      try store.currentSQL!.run("INSERT INTO metadata(key,value) VALUES('native_output_scope','kept')")
    }
    let kept = try store.sqlRead { try $0.rows("SELECT value FROM metadata WHERE key='native_output_scope'").first?[0].text }
    #expect(kept == "kept")
  }

  private func command(_ queries: [NotebookReadQuery]) -> NotebookCommand {
    var request = NotebookCommand(command: .read); request.queries = queries
    return request
  }

  private func derivative(store: NotebookStore, pageID: UUID) throws -> (TargetRenderReceipt, Data) {
    let page = try store.loadPage(pageID)
    let request = try store.requestPageVision(pageID: pageID, expectedRevision: page.drawingStamp.revision)
    let receipt = TargetRenderReceipt(request: request, status: "error", diagnostics: [
      .init(kind: "render_error", message: String(repeating: "Measured source diagnostic. ", count: 2_048))])
    try store.saveTargetRender(receipt)
    return try (receipt, Data(contentsOf: store.targetReceiptURL(request.id)))
  }
}

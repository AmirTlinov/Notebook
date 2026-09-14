import XCTest
@testable import Notebook

@MainActor
final class DocumentPresentationRecorderTests: XCTestCase {
  @MainActor private final class Probe {
    var time = 10.0
    var installed = false
    var published = ""
  }
  func testLandingAttemptsKeepTheActionIdentityAndCannotFinishInputOrRewriteATerminalAttempt() throws {
    let probe = Probe(), recorder = DocumentPresentationRecorder(enabled: true, now: { probe.time }), document = UUID()
    let request = try XCTUnwrap(recorder.request(documentID: document, pageIndex: 9, cause: .page))
    probe.time = 10.1; recorder.demand(documentID: document, pageIndex: 9, token: "source")
    let identity = DocumentPagePreparationIdentity(requestID: request, attemptID: UUID(), coordinatorID: UUID(),
      documentID: document, generation: "1", runtimeID: UUID(), sourceKey: "source", stateKey: "state",
      token: "source", pageIndex: 9, configuredAt: probe.time)
    let trace = DocumentPagePreparationTrace(identity: identity, now: { probe.time })
    trace.mark(.payloadConfiguredAt)
    recorder.observeLanding(trace, stage: .preparing)
    probe.time = 10.2; trace.mark(.canonicalReadyAt); recorder.observeLanding(trace, stage: .capturing)
    probe.time = 10.8; recorder.observeLanding(trace, stage: .cancelled)
    recorder.observeLanding(trace, stage: .completed)
    let record = try XCTUnwrap(recorder.records.first), attempt = try XCTUnwrap(record.landingAttempts.first)
    XCTAssertEqual(record.landingAttempts.count, 1)
    XCTAssertEqual(attempt.identity.requestID, request)
    XCTAssertEqual(attempt.stage, .cancelled)
    XCTAssertEqual(attempt.captureStartedAt, 10.2)
    XCTAssertEqual(attempt.observedAt, 10.8)
    XCTAssertNil(record.contentReadyAt); XCTAssertNil(record.installedAt)
    recorder.cancel(documentID: document)
    recorder.request(documentID: document, pageIndex: 9, cause: .page)
    recorder.demand(documentID: document, pageIndex: 9, token: "source")
    recorder.observeLanding(trace, stage: .preparing)
    XCTAssertTrue(try XCTUnwrap(recorder.records.last).landingAttempts.isEmpty)
  }

  func testDisabledRecorderNeverObservesOrPublishesAnything() {
    let recorder = DocumentPresentationRecorder(enabled: false), id = UUID()
    XCTAssertNil(recorder.request(documentID: id, pageIndex: 0, cause: .open))
    recorder.demand(documentID: id, pageIndex: 0, token: "version")
    recorder.contentReady(documentID: id, pageIndex: 0, token: "version")
    recorder.observeInstallation(documentID: id, pageIndex: 0, token: "version",
      isInstalled: { XCTFail("Disabled instrumentation must not inspect a renderer"); return true },
      publish: { _ in XCTFail("Disabled instrumentation cannot change accessibility") })
    XCTAssertTrue(recorder.records.isEmpty)
  }

  func testContentReadinessDoesNotEndTheIntervalBeforeTheNativeOwnerIsInstalled() async throws {
    let probe = Probe()
    let recorder = DocumentPresentationRecorder(enabled: true, now: { probe.time }), id = UUID()
    let request = try XCTUnwrap(recorder.request(documentID: id, pageIndex: 3, cause: .page))
    XCTAssertEqual(recorder.request(documentID: id, pageIndex: 3, cause: .page), request)
    probe.time = 10.1; recorder.demand(documentID: id, pageIndex: 3, token: "source-1")
    probe.time = 10.2; recorder.contentReady(documentID: id, pageIndex: 3, token: "source-1")
    recorder.observeInstallation(documentID: id, pageIndex: 3, token: "source-1",
      isInstalled: { probe.installed }, publish: { probe.published = $0 })
    try await Task.sleep(for: .milliseconds(15))
    XCTAssertNil(recorder.records.first?.installedAt)
    probe.time = 10.4; probe.installed = true
    try await Task.sleep(for: .milliseconds(15))
    let record = try XCTUnwrap(recorder.records.first)
    XCTAssertEqual(try XCTUnwrap(record.requestToInstalledMS), 400, accuracy: 0.001)
    XCTAssertEqual(try XCTUnwrap(record.demandToContentReadyMS), 100, accuracy: 0.001)
    XCTAssertEqual(try JSONDecoder().decode(DocumentPresentationRecorder.Record.self, from: Data(probe.published.utf8)), record)
    XCTAssertNotEqual(recorder.request(documentID: id, pageIndex: 3, cause: .open), request,
      "A finished opening must not swallow the next actual repeat")
  }

  func testSupersededAndChangedSourcesStayExplicitAndTheJournalIsBounded() {
    let recorder = DocumentPresentationRecorder(enabled: true), id = UUID()
    recorder.request(documentID: id, pageIndex: 0, cause: .open)
    recorder.demand(documentID: id, pageIndex: 0, token: "source-1")
    recorder.demand(documentID: id, pageIndex: 0, token: "source-2")
    XCTAssertEqual(recorder.records.last?.failure, "source_changed")
    for page in 1...70 { recorder.request(documentID: id, pageIndex: page, cause: .page) }
    XCTAssertEqual(recorder.records.count, 64)
    XCTAssertTrue(recorder.records.dropLast().allSatisfy { $0.failure == "superseded" })
    recorder.cancel(documentID: id)
    XCTAssertEqual(recorder.records.last?.failure, "navigation_cancelled")
  }
  func testPageAttemptMetadataCannotAttachToAnotherRequestAndDoesNotCreateReadiness() throws {
    let probe = Probe(), recorder = DocumentPresentationRecorder(enabled: true), document = UUID()
    let old = try XCTUnwrap(recorder.request(documentID: document, pageIndex: 0, cause: .open))
    recorder.demand(documentID: document, pageIndex: 0, token: "same-source")
    let identity = DocumentPagePreparationIdentity(requestID: old, attemptID: UUID(), coordinatorID: UUID(),
      documentID: document, generation: "7", runtimeID: UUID(), sourceKey: "source", stateKey: "state",
      token: "same-source", pageIndex: 0, configuredAt: 10)
    let trace = DocumentPagePreparationTrace(identity: identity, now: { probe.time })
    probe.time = 10.1; trace.mark(.admittedAt)
    probe.time = 10.3; trace.mark(.admittedAt)
    XCTAssertEqual(try XCTUnwrap(trace.phasesMS["admittedAt"]), 100, accuracy: 0.001,
      "Repeated notifications retain the first actual milestone")
    XCTAssertNil(recorder.records.last?.contentReadyAt)
    XCTAssertNil(recorder.records.last?.installedAt)
    recorder.cancel(documentID: document)
    let current = try XCTUnwrap(recorder.request(documentID: document, pageIndex: 0, cause: .open))
    XCTAssertNotEqual(old, current)
    recorder.demand(documentID: document, pageIndex: 0, token: "same-source")
    recorder.contentReady(documentID: document, pageIndex: 0, token: "same-source", pagePreparation: trace)
    XCTAssertNil(recorder.records.last?.pagePreparationIdentity,
      "A prior same-token opening is not evidence for this new request")
    XCTAssertNil(recorder.records.last?.installedAt)
  }

  func testCurrentPageAttemptPublishesImmutableBoundedMetadata() throws {
    let probe = Probe(), recorder = DocumentPresentationRecorder(enabled: true), document = UUID()
    let request = try XCTUnwrap(recorder.request(documentID: document, pageIndex: 2, cause: .page))
    recorder.demand(documentID: document, pageIndex: 2, token: "current")
    XCTAssertEqual(recorder.preparationRequestID(documentID: document, pageIndex: 2, token: "current"), request)
    XCTAssertNil(recorder.preparationRequestID(documentID: document, pageIndex: 2, token: "old"))
    let identity = DocumentPagePreparationIdentity(requestID: request, attemptID: UUID(), coordinatorID: UUID(),
      documentID: document, generation: "9", runtimeID: UUID(), sourceKey: "source", stateKey: "state",
      token: "current", pageIndex: 2, configuredAt: 10)
    let trace = DocumentPagePreparationTrace(identity: identity, now: { probe.time })
    trace.mark(.payloadConfiguredAt)
    probe.time = 10.2; trace.mark(.canonicalReadyAt)
    recorder.contentReady(documentID: document, pageIndex: 2, token: "current", pagePreparation: trace)
    let accepted = try XCTUnwrap(recorder.records.last)
    for stage in DocumentPagePreparationTrace.Stage.allCases { trace.mark(stage) }
    XCTAssertEqual(recorder.records.last?.pagePreparationPhasesMS, accepted.pagePreparationPhasesMS)
    XCTAssertEqual(recorder.records.last?.pagePreparationIdentity, identity)
    XCTAssertEqual(trace.phasesMS.count, DocumentPagePreparationTrace.Stage.allCases.count)
    XCTAssertNil(recorder.records.last?.installedAt)
  }

  func testPageProbeRejectsAnotherAttemptAndKeepsFiniteBoundedIndependentClocks() throws {
    let identity = DocumentPagePreparationIdentity(requestID: UUID(), attemptID: UUID(), coordinatorID: UUID(),
      documentID: UUID(), generation: "1", runtimeID: UUID(), sourceKey: "source", stateKey: "state",
      token: "token", pageIndex: 0, configuredAt: 10)
    let trace = DocumentPagePreparationTrace(identity: identity, now: { 11 })
    trace.recordBrowserPhases(["receipt_raf1": 300], attemptID: UUID())
    trace.recordBrowserPhases(["unknown": 300], attemptID: identity.attemptID)
    trace.recordBrowserPhases(["receipt_raf1": .nan], attemptID: identity.attemptID)
    trace.recordBrowserPhases(["receipt_raf1": -1], attemptID: identity.attemptID)
    XCTAssertTrue(trace.browserPhasesMS.isEmpty)
    trace.mark(.pageReceiptReturnedAt)
    trace.recordBrowserPhases(["receipt_raf1": 300, "receipt_raf2": 600], attemptID: identity.attemptID)
    trace.recordBrowserPhases(["receipt_raf1": 900], attemptID: identity.attemptID)
    XCTAssertEqual(trace.browserPhasesMS["receipt_raf1"], 300)
    XCTAssertEqual(trace.phasesMS["pageReceiptReturnedAt"], 1_000)
    trace.recordNativeVisibility(["hasWindow": 1], at: .payloadConfiguredAt)
    trace.recordNativeVisibility(["hasWindow": .infinity], at: .pageReceiptReturnedAt)
    XCTAssertTrue(trace.nativeVisibility.isEmpty)
    trace.recordNativeVisibility(["hasWindow": 0], at: .pageReceiptReturnedAt)
    trace.recordNativeVisibility(["hasWindow": 1], at: .pageReceiptReturnedAt)
    XCTAssertEqual(trace.nativeVisibility["pageReceiptReturnedAt"], ["hasWindow": 0])
    trace.recordBrowserStates(["receipt_enter": ["documentHidden": 1]], attemptID: UUID())
    trace.recordBrowserStates(["receipt_enter": ["forcedLayout": 1]], attemptID: identity.attemptID)
    XCTAssertTrue(trace.browserStates.isEmpty)
    trace.recordBrowserStates(["receipt_enter": ["documentHidden": 1]], attemptID: identity.attemptID)
    XCTAssertEqual(trace.browserStates["receipt_enter"], ["documentHidden": 1])
  }

  func testCurrentProbePublishesAnImmutableCodableSnapshotWithoutInstallingPixels() throws {
    let recorder = DocumentPresentationRecorder(enabled: true), document = UUID()
    let request = try XCTUnwrap(recorder.request(documentID: document, pageIndex: 0, cause: .open))
    recorder.demand(documentID: document, pageIndex: 0, token: "token")
    let identity = DocumentPagePreparationIdentity(requestID: request, attemptID: UUID(), coordinatorID: UUID(),
      documentID: document, generation: "1", runtimeID: UUID(), sourceKey: "source", stateKey: "state",
      token: "token", pageIndex: 0, configuredAt: ProcessInfo.processInfo.systemUptime)
    let trace = DocumentPagePreparationTrace(identity: identity)
    trace.recordBrowserPhases(["render_images": 40], attemptID: identity.attemptID)
    trace.recordBrowserStates(["receipt_enter": ["documentHidden": 0]], attemptID: identity.attemptID)
    trace.recordNativeVisibility(["hasWindow": 1, "clippedIntersectionWidth": 240], at: .renderedAt)
    recorder.contentReady(documentID: document, pageIndex: 0, token: "token", pagePreparation: trace)
    let accepted = try XCTUnwrap(recorder.records.last)
    XCTAssertEqual(accepted.pagePreparationBrowserPhasesMS, ["render_images": 40])
    XCTAssertEqual(accepted.pagePreparationBrowserStates, ["receipt_enter": ["documentHidden": 0]])
    XCTAssertEqual(accepted.pagePreparationNativeVisibility?["renderedAt"]?["clippedIntersectionWidth"], 240)
    trace.recordBrowserPhases(["render_complete": 80], attemptID: identity.attemptID)
    trace.recordNativeVisibility(["hasWindow": 0], at: .pageReceiptReturnedAt)
    XCTAssertEqual(recorder.records.last, accepted)
    XCTAssertNil(accepted.installedAt)
    XCTAssertEqual(try JSONDecoder().decode(DocumentPresentationRecorder.Record.self,
      from: JSONEncoder().encode(accepted)), accepted)
  }

}

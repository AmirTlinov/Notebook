import Foundation
import NotebookCore
import NotebookTypesetter
import XCTest

@MainActor
final class DocumentPrintAdmissionTests: XCTestCase {
  private var resources: URL { Bundle.main.resourceURL!.appendingPathComponent("NotebookTypesetter") }
  private func document(_ text: String) -> DocumentDocument {
    .init(actor: UUID(), files: [.init(id: "main", path: "main.tex",
      source: "\\documentclass{article}\n\\begin{document}\n" + text + "\n\\end{document}\n")])
  }
  private func request(_ document: DocumentDocument, from store: NotebookPrintedDocumentStore,
    label: String, priority: NotebookTypesetter.Priority, probe: PrintAdmissionProbe,
    demand: NotebookTypesetterDemand? = nil) -> Task<NotebookPrintedDocument, Error> {
    Task {
      do {
        let result = try await store.artifact(for: document, priority: priority, demand: demand,
          inputFactory: { try await probe.input(document, label: label) })
        await probe.finished(label)
        return result
      } catch { await probe.finished(label); throw error }
    }
  }
  private func waitUntil(_ message: String, _ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !(await condition()) {
      guard ContinuousClock.now < deadline else { XCTFail(message); throw WaitFailure.timeout }
      try await Task.sleep(for: .milliseconds(5))
    }
  }
  private func assertCancelled(_ task: Task<NotebookPrintedDocument, Error>,
    file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await task.value; XCTFail("Cancelled reader returned an artifact", file: file, line: line) }
    catch { XCTAssertTrue(error is CancellationError, "\(error)", file: file, line: line) }
  }
  private enum WaitFailure: Error { case timeout }

  func testCurrentRequestPassesFourSpeculativeJobsAndJoinsMaterializationBeforeStarting() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = NotebookPrintedDocumentStore(resources: resources, directory: directory)
    let probe = PrintAdmissionProbe(holdingFirstInput: "speculative-0")
    var tasks: [Task<NotebookPrintedDocument, Error>] = []
    defer { tasks.forEach { $0.cancel() }; Task { await probe.release() } }
    tasks.append(request(document("Speculative zero"), from: store,
      label: "speculative-0", priority: .anticipated, probe: probe))
    try await waitUntil("The first namespace must own materialization") { await probe.isHoldingInput }
    for index in 1...3 {
      tasks.append(request(document("Speculative \(index)"), from: store,
        label: "speculative-\(index)", priority: .anticipated, probe: probe))
    }
    try await waitUntil("All four sources must have readers") { await store.artifactRequestCount == 4 }
    let current = request(document("Requested current paper"), from: store,
      label: "current", priority: .current, probe: probe)
    tasks.append(current)
    try await waitUntil("Current work must withdraw the active speculative attempt") {
      await probe.cancelledInputs.contains("speculative-0")
    }
    let heldStarts = await probe.starts
    XCTAssertEqual(heldStarts, ["speculative-0"], "Cancellation cannot release the slot before its actual worker joins")
    await probe.release()
    let printed = try await current.value
    XCTAssertTrue(printed.source.contains("Requested current paper"))
    for task in tasks.dropLast() { _ = try await task.value }
    let starts = await probe.starts, maximum = await probe.maximumConcurrentInputs
    XCTAssertEqual(Array(starts.prefix(2)), ["speculative-0", "current"])
    XCTAssertEqual(starts.filter { $0 == "speculative-0" }.count, 2,
      "A scheduling yield restarts the attempt while preserving the original reader's completion")
    XCTAssertEqual(starts.count, 6)
    XCTAssertEqual(maximum, 1, "Queued documents cannot materialize competing binary namespaces")
  }

  func testCurrentPrintYieldsTheActualVMAndSharedReadersKeepIndependentCancellation() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = NotebookPrintedDocumentStore(resources: resources, directory: directory)
    let probe = PrintAdmissionProbe()
    let demand = NotebookTypesetterDemand(priority: .anticipated)
    let looping = DocumentDocument(actor: UUID(), files: [.init(id: "main", path: "main.tex",
      source: "\\count255=0\\relax\\loop\\advance\\count255 by1\\count255=0\\relax\\iftrue\\repeat")])
    var tasks: [Task<NotebookPrintedDocument, Error>] = []
    defer { tasks.forEach { $0.cancel() } }
    let first = request(looping, from: store, label: "first", priority: .anticipated, probe: probe, demand: demand)
    tasks.append(first)
    try await waitUntil("The native input bridge must be ready") { demand.preparationPhasesMS["inputBridge"] != nil }
    // Leave the dispatch queue inside the genuine TeX loop, beyond preparation.
    try await Task.sleep(for: .milliseconds(100))
    let second = request(looping, from: store, label: "second", priority: .anticipated, probe: probe)
    tasks.append(second)
    try await waitUntil("Both readers must share the looping source") { await store.artifactRequestCount == 2 }
    let start = ContinuousClock.now
    let current = request(document("Foreground while another TeX program loops"), from: store,
      label: "current", priority: .current, probe: probe)
    tasks.append(current)
    _ = try await current.value
    let elapsed = start.duration(to: .now)
    XCTAssertLessThan(elapsed, .seconds(5), "Current input cannot wait for the speculative VM's 30-second deadline")
    try await waitUntil("The yielded source must retain its original readers and retry") {
      await probe.starts.filter { $0 == "first" }.count == 2
    }
    let finishedBeforeCancellation = await probe.completedReaders
    XCTAssertFalse(finishedBeforeCancellation.contains("first"))
    XCTAssertFalse(finishedBeforeCancellation.contains("second"))
    XCTAssertNotNil(demand.preparationPhasesMS["native"], "The interrupted attempt must have entered the actual VM")
    first.cancel()
    await assertCancelled(first)
    let finishedAfterOneReader = await probe.completedReaders
    XCTAssertFalse(finishedAfterOneReader.contains("second"), "One reader cannot cancel its shared producer")
    try await Task.sleep(for: .milliseconds(100))
    let previousNative = demand.preparationPhasesMS["native"]
    second.cancel()
    await assertCancelled(second)
    try await waitUntil("The final reader must stop and join the retried native VM") {
      demand.preparationPhasesMS["native"] != previousNative
    }
    // Bypass artifact cache: the same physical engine must accept the next job.
    let svg = Data("<svg xmlns='http://www.w3.org/2000/svg' width='20' height='20'><path d='M1 1H19V19H1Z'/></svg>".utf8)
    let recovered = try await store.vectorPDF(svg)
    XCTAssertTrue(recovered.starts(with: Data("%PDF-".utf8)))
    let starts = await probe.starts
    XCTAssertEqual(starts.filter { $0 == "first" }.count, 2)
    XCTAssertFalse(starts.contains("second"), "Coalescing keeps one producer across scheduling yields")
    let measurement = XCTAttachment(string: "Current paper through actual VM yield: \(elapsed); input attempts: \(starts); compiler phases: \(demand.preparationPhasesMS)")
    measurement.name = "Current print through speculative VM yield"; measurement.lifetime = .keepAlways; add(measurement)
  }

  func testCoalescedCurrentReaderPromotesAnAlreadyQueuedSourceWithoutReplacingItsJob() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = NotebookPrintedDocumentStore(resources: resources, directory: directory)
    let probe = PrintAdmissionProbe(holdingFirstInput: "active")
    var tasks: [Task<NotebookPrintedDocument, Error>] = []
    defer { tasks.forEach { $0.cancel() }; Task { await probe.release() } }
    let active = request(document("Speculative preparation already running"), from: store,
      label: "active", priority: .anticipated, probe: probe)
    tasks.append(active)
    try await waitUntil("The first source must own materialization") { await probe.isHoldingInput }
    let queuedDocument = document("The person selects the already anticipated document")
    let demand = NotebookTypesetterDemand(priority: .anticipated)
    let queued = request(queuedDocument, from: store, label: "queued", priority: .anticipated, probe: probe, demand: demand)
    tasks.append(queued)
    // The queue phase begins at actual executor enrollment. Store entry alone
    // would allow a late foreground enqueue to conceal a broken observer.
    try await waitUntil("The anticipated source must already be enrolled in the executor queue") {
      demand.preparationPhasesMS["queue"] != nil
    }
    let promoted = request(queuedDocument, from: store, label: "current-reader", priority: .current, probe: probe)
    tasks.append(promoted)
    try await waitUntil("Coalesced demand promotion must revoke the active speculative attempt") {
      await probe.cancelledInputs.contains("active")
    }
    let heldStarts = await probe.starts
    XCTAssertEqual(heldStarts, ["active"], "Promotion still waits for the previous materialization to join")
    await probe.release()
    let firstArtifact = try await queued.value, currentArtifact = try await promoted.value
    _ = try await active.value
    XCTAssertTrue(firstArtifact === currentArtifact, "Both readers receive the original shared producer's artifact")
    let starts = await probe.starts
    XCTAssertEqual(starts, ["active", "queued", "active"], "Promotion keeps the queued job and its single input factory")
  }

  func testJoinedExportProtectsSpeculativeProducerWhileCurrentWorkWaits() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = NotebookPrintedDocumentStore(resources: resources, directory: directory)
    let probe = PrintAdmissionProbe(holdingFirstInput: "shared")
    let source = document("A requested export shares the anticipated paper")
    var tasks: [Task<NotebookPrintedDocument, Error>] = []
    defer { tasks.forEach { $0.cancel() }; Task { await probe.release() } }
    let speculative = request(source, from: store, label: "shared", priority: .anticipated, probe: probe)
    tasks.append(speculative)
    try await waitUntil("The shared source must own preparation") { await probe.isHoldingInput }
    let export = request(source, from: store, label: "export", priority: .export, probe: probe)
    tasks.append(export)
    try await waitUntil("The export must join the existing source") { await store.artifactRequestCount == 2 }
    let currentDemand = NotebookTypesetterDemand(priority: .current)
    let current = request(document("A different current page"), from: store,
      label: "current", priority: .current, probe: probe, demand: currentDemand)
    tasks.append(current)
    try await waitUntil("Current demand must enter the executor queue") { currentDemand.preparationPhasesMS["queue"] != nil }
    let heldStarts = await probe.starts, cancellations = await probe.cancelledInputs
    XCTAssertEqual(heldStarts, ["shared"])
    XCTAssertTrue(cancellations.isEmpty, "Export protection survives joining a higher-ranked speculative demand")
    await probe.release()
    let shared = try await speculative.value, exported = try await export.value
    _ = try await current.value
    XCTAssertEqual(shared.pdf, exported.pdf)
    let starts = await probe.starts
    XCTAssertEqual(starts, ["shared", "current"], "Exported pixels come from the original shared operation without a scheduling restart")
  }
}

/// The first held factory deliberately does not finish when cancelled. Tests
/// release it explicitly to distinguish real completion from a withdrawn wait.
private actor PrintAdmissionProbe {
  private let heldLabel: String?
  private var released = false
  private var gates: [CheckedContinuation<Void, Never>] = []
  private var concurrentInputs = 0
  private(set) var maximumConcurrentInputs = 0
  private(set) var starts: [String] = []
  private(set) var cancelledInputs: Set<String> = []
  private(set) var completedReaders: Set<String> = []
  var isHoldingInput: Bool { !gates.isEmpty }
  init(holdingFirstInput label: String? = nil) { heldLabel = label }
  func input(_ document: DocumentDocument, label: String) async throws -> NotebookTypesetterInput {
    concurrentInputs += 1; maximumConcurrentInputs = max(maximumConcurrentInputs, concurrentInputs)
    starts.append(label)
    defer { concurrentInputs -= 1 }
    if label == heldLabel, !released {
      await withTaskCancellationHandler {
        await withCheckedContinuation { gates.append($0) }
      } onCancel: { Task { await self.cancelled(label) } }
    }
    try Task.checkCancellation()
    return try NotebookTypesetterInput(document: document)
  }
  private func cancelled(_ label: String) { cancelledInputs.insert(label) }
  func finished(_ label: String) { completedReaders.insert(label) }
  func release() { released = true; let continuations = gates; gates.removeAll(); continuations.forEach { $0.resume() } }
}

import Foundation
import NotebookCore
import XCTest
import WebKit
@testable import Notebook

@MainActor
final class ProgramStateTransferTests: XCTestCase {
  func testUnreadyHeapRetirementClosesAdmissionAndJoinsDelayedPullBeforeDurability() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    var page = try XCTUnwrap(model.activePage)
    let element = AgentElement(id: "early", kind: .web, frame: .init(x: 0, y: 0, width: 160, height: 120), source: "Early state", html: "<output>Early</output>")
    page.replaceElements([element], actor: model.actorID)
    try model.store.savePage(page); await model.reloadExternalChanges()?.value
    let basis = try XCTUnwrap(model.pages[page.id]?.programStateBasis(element.id))
    let owner = NotebookProgramStateTransfer(resources: SceneRenderResources())
    let web = WKWebView(frame: .init(x: 0, y: 0, width: 320, height: 200))
    web.loadHTMLString("""
      <script>
      const notebookLoadToken='early';
      \(NotebookProgramBridge.script)
      window.notebookProgram=createNotebookProgram({state:null,stateTransport:{credit:\(owner.initialCredit),
        requestCredit:()=>{},onSnapshot:snapshot=>window.fixtureSnapshot=snapshot}});
      notebookProgram.api.ready(new Promise(()=>{}));
      window.fixtureAccepted=notebookProgram.api.commit({early:1});
      notebookProgram.start().catch(()=>{});
      </script>
      """, baseURL: nil)
    let deadline = ContinuousClock.now + .seconds(5)
    var raw: [String: Any]?
    while raw == nil, ContinuousClock.now < deadline {
      raw = (try? await web.evaluateJavaScript("window.fixtureSnapshot")) as? [String: Any]
      if raw == nil { try await Task.sleep(for: .milliseconds(10)) }
    }
    let snapshot = try JSONDecoder().decode(NotebookProgramStateTransfer.Snapshot.self,
      from: JSONSerialization.data(withJSONObject: XCTUnwrap(raw)))
    let accepted = try await web.evaluateJavaScript("window.fixtureAccepted") as? Bool
    XCTAssertEqual(accepted, true)
    var heldRead: CheckedContinuation<Void, Never>?, failure: Error?
    owner.receive(snapshot, read: { revision, offset in
      await withCheckedContinuation { heldRead = $0 }
      return try await NotebookProgramBridge.readState(revision, offset: offset, controller: "notebookProgram", expectedToken: "early", in: web)
    }, acknowledge: { try await NotebookProgramBridge.acknowledgeState($0, controller: "notebookProgram", expectedToken: "early", in: web) },
      accept: { value, _ in
        let written = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
          if !model.commitElementState(pageID: page.id, elementID: element.id, state: value,
            onCommitted: .init(admittedBytes: snapshot.cost, sourceBasis: basis, { done.resume(returning: $0 != nil) })) {
            done.resume(returning: false)
          }
        }
        XCTAssertTrue(written)
      }, onFailure: { failure = $0 })
    while heldRead == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    let release = try XCTUnwrap(heldRead)
    var retired = false
    let retirement = Task { @MainActor in
      try await owner.finishAccepted(controller: "notebookProgram", expectedToken: "early", in: web)
      retired = true
    }
    try await Task.sleep(for: .milliseconds(40))
    XCTAssertFalse(retired, "A not-ready heap still owns the accepted revision before it reaches the writer")
    let late = try await web.evaluateJavaScript("notebookProgram.api.commit({late:2})") as? Bool
    XCTAssertEqual(late, false, "The closing boundary revokes new JS admission before draining")
    release.resume(); heldRead = nil
    try await retirement.value
    XCTAssertTrue(retired); XCTAssertNil(failure)
    XCTAssertEqual(try model.store.readPageElement(pageID: page.id, elementID: element.id)?.state, .object(["early": .number(1)]))
    let stopped = await model.shutdown()
    XCTAssertTrue(stopped)
  }

  func testOldDescriptorCannotReadAcknowledgeOrCreditANewContextInTheSameWebView() async throws {
    let web = WKWebView(frame: .init(x: 0, y: 0, width: 320, height: 200))
    func load(_ token: String, source: Int) async throws {
      web.loadHTMLString("""
        <script>
        const notebookLoadToken='\(token)';
        \(NotebookProgramBridge.script)
        window.notebookProgram=createNotebookProgram({state:null,stateTransport:{credit:1024,
          requestCredit:()=>{},onSnapshot:snapshot=>window.fixtureSnapshot=snapshot}});
        notebookProgram.api.commit({source:\(source)});
        </script>
        """, baseURL: nil)
      let deadline = ContinuousClock.now + .seconds(5)
      var installed = false
      while !installed, ContinuousClock.now < deadline {
        installed = (try? await web.evaluateJavaScript("typeof notebookLoadToken!=='undefined' && notebookLoadToken==='\(token)' && window.fixtureSnapshot?.revision==='1'")) as? Bool == true
        if !installed { try await Task.sleep(for: .milliseconds(10)) }
      }
      XCTAssertTrue(installed, "Each context starts its own snapshot revision at one")
    }
    try await load("old", source: 1)
    let previous = try await NotebookProgramBridge.readState("1", offset: 0, controller: "notebookProgram", expectedToken: "old", in: web)
    XCTAssertEqual(previous, "{\"source\":1}")
    try await load("replacement", source: 2)
    do {
      _ = try await NotebookProgramBridge.readState("1", offset: 0, controller: "notebookProgram", expectedToken: "old", in: web)
      XCTFail("A reused WK pointer and revision cannot authorize a read of the replacement program")
    } catch {
      XCTAssertEqual(error as? NotebookProgramCheckpointError, .superseded)
    }
    do {
      try await NotebookProgramBridge.acknowledgeState("1", controller: "notebookProgram", expectedToken: "old", in: web)
      XCTFail("An old ACK cannot remove the replacement context's same-numbered snapshot")
    } catch {
      XCTAssertEqual(error as? NotebookProgramCheckpointError, .superseded)
    }
    do {
      _ = try await NotebookProgramBridge.lifecycle("checkpoint", controller: "notebookProgram", expectedToken: "old", in: web)
      XCTFail("A delayed old checkpoint cannot suspend the replacement context")
    } catch {
      XCTAssertEqual(error as? NotebookProgramCheckpointError, .superseded)
    }
    let external = try await NotebookProgramStateEncoding.prepare(.object(["source": .number(99)]), resources: SceneRenderResources())
    do {
      _ = try await external.send(controller: "notebookProgram", revision: "1", expectedToken: "old", in: web)
      XCTFail("A delayed external state transfer must not enter a replacement heap")
    } catch { XCTAssertEqual(error as? NotebookProgramCheckpointError, .superseded) }
    let suspended = try await web.evaluateJavaScript("notebookProgram.suspended") as? Bool
    XCTAssertEqual(suspended, false)
    NotebookProgramBridge.grantStateCredit(100_000, controller: "notebookProgram", expectedToken: "old", in: web)
    let excess = try await web.evaluateJavaScript("notebookProgram.api.commit('x'.repeat(1000))") as? Bool
    XCTAssertEqual(excess, false, "Old context capacity cannot become unaccounted credit in a replacement heap")
    let current = try await NotebookProgramBridge.readState("1", offset: 0, controller: "notebookProgram", expectedToken: "replacement", in: web)
    XCTAssertEqual(current, "{\"source\":2}")
    try await NotebookProgramBridge.acknowledgeState("1", controller: "notebookProgram", expectedToken: "replacement", in: web)
  }

  func testRealWebKitPullPreservesUnicodeAcrossTheWindowBeyondFourMiB() async throws {
    let resources = SceneRenderResources(), owner = NotebookProgramStateTransfer(resources: resources)
    var granted = owner.initialCredit
    owner.requestCredit(48 * 1_024 * 1_024 - granted) { granted += $0 }
    XCTAssertEqual(granted, 48 * 1_024 * 1_024)
    let web = WKWebView(frame: .init(x: 0, y: 0, width: 320, height: 200))
    web.loadHTMLString("""
      <script>
      const notebookLoadToken='unicode';
      \(NotebookProgramBridge.script)
      window.notebookProgram=createNotebookProgram({state:null,stateTransport:{credit:\(granted),
        requestCredit:()=>{},onSnapshot:snapshot=>window.fixtureSnapshot=snapshot}});
      notebookProgram.api.commit('x'.repeat(262142)+'😀'+'я'.repeat(2097152));
      </script>
      """, baseURL: nil)
    let deadline = ContinuousClock.now + .seconds(5)
    var descriptor: [String: Any]?
    while descriptor == nil, ContinuousClock.now < deadline {
      descriptor = (try? await web.evaluateJavaScript("window.fixtureSnapshot")) as? [String: Any]
      if descriptor == nil { try await Task.sleep(for: .milliseconds(10)) }
    }
    let raw = try XCTUnwrap(descriptor)
    let snapshot = try JSONDecoder().decode(NotebookProgramStateTransfer.Snapshot.self,
      from: JSONSerialization.data(withJSONObject: raw))
    var accepted: JSONValue?, failures: [Error] = [], windows = 0
    owner.receive(snapshot, read: { revision, offset in
      windows += 1
      return try await NotebookProgramBridge.readState(revision, offset: offset, controller: "notebookProgram", expectedToken: "unicode", in: web)
    }, acknowledge: { try await NotebookProgramBridge.acknowledgeState($0, controller: "notebookProgram", expectedToken: "unicode", in: web) },
      accept: { value, _ in accepted = value }, onFailure: { failures.append($0) })
    try await owner.drain()
    XCTAssertTrue(failures.isEmpty); XCTAssertGreaterThan(windows, 1)
    guard let accepted, case .string(let value) = accepted else { return XCTFail("The same admitted owner must decode the actual WK scalar windows") }
    XCTAssertGreaterThan(value.utf8.count, 4 * 1_024 * 1_024)
    XCTAssertEqual(value, String(repeating: "x", count: 262142) + "😀" + String(repeating: "я", count: 2097152),
      "The first WK reply ends immediately before the surrogate pair, never inside it")
  }

  func testAdmittedReadCannotAdoptAReplacementPageProgramBeforeItsWriterCallback() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    var page = try XCTUnwrap(model.activePage)
    let element = AgentElement(id: "program", kind: .web, frame: .init(x: 0, y: 0, width: 160, height: 120),
      source: "Original", html: "<button>Original</button>")
    page.replaceElements([element], actor: model.actorID)
    try model.store.savePage(page); await model.reloadExternalChanges()?.value
    let captured = try XCTUnwrap(model.pages[page.id]?.programStateBasis(element.id))
    let owner = NotebookProgramStateTransfer(resources: SceneRenderResources())
    let json = "{\"late\":99}", cost = json.utf16.count * 8 + 512
    var firstRead: CheckedContinuation<Void, Never>?
    var failures: [Error] = [], admitted: [Bool] = [], acknowledgements: [String] = []
    owner.receive(.init(revision: "1", units: json.utf16.count, cost: cost), read: { _, _ in
      await withCheckedContinuation { firstRead = $0 }
      return json
    }, acknowledge: { acknowledgements.append($0) }, accept: { value, _ in
      let accepted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
        if !model.commitElementState(pageID: page.id, elementID: element.id, state: value,
          onCommitted: .init(admittedBytes: cost, sourceBasis: captured, { receipt in continuation.resume(returning: receipt != nil) })) {
          continuation.resume(returning: false)
        }
      }
      admitted.append(accepted)
      if !accepted { throw NotebookProgramCheckpointError.superseded }
    }, onFailure: { failures.append($0) })
    let deadline = ContinuousClock.now + .seconds(2)
    while firstRead == nil, failures.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    let releaseRead = try XCTUnwrap(firstRead, "An admitted descriptor must enter the async read before replacement")
    // Same element, same source bytes after ABA: only its causal identity changed.
    page.replaceElements([.init(id: element.id, kind: .web, frame: element.frame, source: "Replacement", html: "<button>Replacement</button>")], actor: model.actorID)
    page.replaceElements([element], actor: model.actorID)
    try model.store.savePage(page); await model.reloadExternalChanges()?.value
    let replacement = try XCTUnwrap(model.pages[page.id]?.programStateBasis(element.id))
    XCTAssertFalse(captured.hasSameSource(as: replacement))
    let cursor = try model.store.currentChangeCursor()
    releaseRead.resume(); firstRead = nil
    do { try await owner.drain(); XCTFail("The old source's delayed writer must be rejected") } catch {}
    XCTAssertEqual(admitted, [false]); XCTAssertTrue(acknowledgements.isEmpty); XCTAssertEqual(failures.count, 1)
    XCTAssertEqual(try model.store.readPageElement(pageID: page.id, elementID: element.id)?.state, element.state)
    XCTAssertEqual(try model.store.currentChangeCursor(), cursor)
    let currentAccepted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
      if !model.commitElementState(pageID: page.id, elementID: element.id, state: .number(1),
        onCommitted: .init(sourceBasis: replacement, { continuation.resume(returning: $0 != nil) })) {
        continuation.resume(returning: false)
      }
    }
    XCTAssertTrue(currentAccepted, "The current causal owner still uses the same addressed writer")
    XCTAssertEqual(try model.store.readPageElement(pageID: page.id, elementID: element.id)?.state, .number(1))
  }

  func testPassivePreparationDoesNotConsumeItsInitialStateBudgetAsUnusedWriteCredit() async throws {
    let resources = SceneRenderResources()
    let admission = resources.rasterAdmission
    let available = min(admission.byteLimit - admission.heldBytes,
      admission.passiveByteLimit - admission.pinnedBytes - admission.passiveReservedBytes)
    let pressure = try XCTUnwrap(resources.reserveDerivedBytes(available - 65_536, priority: .passive))
    defer { pressure.release() }
    let owner = NotebookProgramStateTransfer(resources: resources, grantsInitialCredit: false)
    XCTAssertEqual(owner.initialCredit, 0)
    let prepared = try await NotebookProgramStateEncoding.prepare(.object(["visible": .bool(true)]), resources: resources, forHTML: true)
    XCTAssertTrue(prepared.htmlJSON.contains("visible"))
  }

  func testEveryJSONRootTraversesTheSameAdmittedStateOwner() async throws {
    let resources = SceneRenderResources(), owner = NotebookProgramStateTransfer(resources: resources)
    let values: [JSONValue] = [.number(7), .string("готово"), .null, .object(["enabled": .bool(true)]), .array([.bool(false)])]
    var accepted: [JSONValue] = [], acknowledgements: [String] = [], failures: [Error] = []
    for (index, value) in values.enumerated() {
      let json = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
      let revision = String(index + 1)
      owner.receive(.init(revision: revision, units: json.utf16.count, cost: json.utf16.count * 8 + 512),
        read: { _, offset in XCTAssertEqual(offset, 0); return json },
        acknowledge: { acknowledgements.append($0) },
        accept: { value, _ in accepted.append(value) }, onFailure: { failures.append($0) })
    }
    try await owner.drain()
    XCTAssertTrue(failures.isEmpty)
    XCTAssertEqual(accepted, values)
    XCTAssertEqual(acknowledgements, ["1", "2", "3", "4", "5"])
  }

  func testThreeLargeAcceptedSnapshotsKeepFIFOAndTheirOwnerThroughRetirement() async throws {
    let resources = SceneRenderResources()
    var owner: NotebookProgramStateTransfer? = NotebookProgramStateTransfer(resources: resources)
    weak var retained = owner
    let payload = String(repeating: "x", count: 5 * 1_024 * 1_024)
    let jsons = (1...3).map { "\"\($0)" + payload + "\"" }
    let cost = jsons[0].utf16.count * 8 + 64
    var granted = 0
    owner!.requestCredit(cost * 3 - owner!.initialCredit) { granted += $0 }
    XCTAssertGreaterThan(granted, 0)
    var first: CheckedContinuation<Void, Never>?
    var accepted: [UInt64] = [], acknowledgements: [String] = [], failures: [Error] = []
    for (index, json) in jsons.enumerated() {
      let bytes = Data(json.utf8), revision = String(index + 1)
      owner!.receive(.init(revision: revision, units: json.utf16.count, cost: cost),
        read: { id, offset in
          if id == "1", offset == 0 { await withCheckedContinuation { first = $0 } }
          let end = min(bytes.count, offset + 262_144)
          return String(decoding: bytes[offset..<end], as: UTF8.self)
        }, acknowledge: { acknowledgements.append($0) },
        accept: { value, sequence in
          guard case .string(let text) = value else { XCTFail("Expected a string root"); return }
          XCTAssertEqual(text.first.map(String.init), String(sequence)); XCTAssertEqual(text.count, payload.count + 1)
          accepted.append(sequence)
        }, onFailure: { failures.append($0) })
    }
    let deadline = ContinuousClock.now + .seconds(2)
    while first == nil, failures.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    let releaseFirst = try XCTUnwrap(first, "The admitted first descriptor must begin reading; failures=\(failures)")
    owner = nil
    XCTAssertNotNil(retained, "An admitted addressed write is not owned by the retiring view")
    XCTAssertTrue(accepted.isEmpty)
    releaseFirst.resume(); first = nil
    try await retained?.drain()
    XCTAssertEqual(accepted, [1, 2, 3]); XCTAssertEqual(acknowledgements, ["1", "2", "3"])
    XCTAssertTrue(failures.isEmpty)
  }

  func testCheckpointRetainsItsAdditionalAdmissionThroughPersistence() async throws {
    let resources = SceneRenderResources(), owner = NotebookProgramStateTransfer(resources: resources)
    let json = "\"" + String(repeating: "x", count: 300_000) + "\""
    let cost = json.utf16.count * 8 + 64, before = resources.rasterAdmission.heldBytes
    let snapshot = try await owner.checkpoint(.init(revision: "frozen", units: json.utf16.count, cost: cost)) { _, offset in
      let bytes = Data(json.utf8)
      return String(decoding: bytes[offset..<min(bytes.count, offset + 262_144)], as: UTF8.self)
    }
    XCTAssertEqual(resources.rasterAdmission.heldBytes, before + cost - owner.initialCredit)
    await Task.yield() // The writer may suspend; extra bytes cannot be recycled at pull completion.
    XCTAssertEqual(snapshot.admittedBytes, cost)
    XCTAssertEqual(resources.rasterAdmission.heldBytes, before + cost - owner.initialCredit)
    snapshot.release()
    XCTAssertEqual(resources.rasterAdmission.heldBytes, before)
  }

  func testProgramWriterQueueKeepsEveryAcceptedRevisionAndCreditFenceAcrossDiskRetry() async throws {
    final class Writes: @unchecked Sendable {
      private let lock = NSLock()
      private var fails = true
      private var completed: [Int] = []
      var values: [Int] { lock.withLock { completed } }
      func write(_ value: Int) throws {
        try lock.withLock {
          if fails { fails = false; throw CocoaError(.fileWriteUnknown) }
          completed.append(value)
        }
      }
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let queue = NotebookPersistenceQueue(store: NotebookStore(root: root)), writes = Writes(), id = UUID()
    for value in 1...3 { queue.enqueue(owner: .elementState(id, "program")) { _ in try writes.write(value); return false } }
    XCTAssertEqual(queue.pendingCount, 3, "Every authored commit is a command, not a replaceable page frame")
    var creditReleased = false
    let fence = Task { @MainActor in await queue.finishAcceptedProgramWrites(); creditReleased = true }
    let deadline = ContinuousClock.now + .seconds(2)
    while queue.failure == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertNotNil(queue.failure); XCTAssertFalse(creditReleased)
    XCTAssertTrue(writes.values.isEmpty)
    queue.retry()
    await fence.value
    XCTAssertTrue(creditReleased); XCTAssertEqual(writes.values, [1, 2, 3])
  }

  func testNativeDeadlineRejectsALateBrowserReplyWithoutWaitingForItsPromise() async throws {
    let web = WKWebView(frame: .init(x: 0, y: 0, width: 320, height: 200))
    web.loadHTMLString("<script>window.fixtureReady=true</script>", baseURL: nil)
    let deadline = ContinuousClock.now + .seconds(3)
    while (try? await web.evaluateJavaScript("window.fixtureReady")) as? Bool != true, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    var returned: [JSONValue] = []
    let first = Task { @MainActor in
      do {
        returned.append(try await NotebookProgramBridge.request("state_read",
          script: "return await new Promise(resolve=>window.releaseLateState=resolve);", in: web, timeout: .milliseconds(40)))
        XCTFail("The native deadline must not wait for a parked browser promise")
      } catch { XCTAssertEqual(error as? SceneRenderError, .snapshotPending("program_state_read_timeout"), "Unexpected failure: \(error)") }
    }
    await first.value
    XCTAssertTrue(returned.isEmpty)
    _ = try await web.evaluateJavaScript("window.releaseLateState?.('obsolete')")
    let current = try await NotebookProgramBridge.request("state_read", script: "return 'current';", in: web)
    XCTAssertEqual(current, .string("current")); XCTAssertTrue(returned.isEmpty)
  }

  func testReadAndLostACKRetryResumeOnlyTheirFailedFIFOStage() async throws {
    enum Refused: Error { case read, acknowledgement }
    let resources = SceneRenderResources(), owner = NotebookProgramStateTransfer(resources: resources)
    let json = "{\"state\":1}", split = 5
    var reads: [String] = [], accepted: [UInt64] = [], acknowledgements: [String] = [], failures: [Error] = []
    var failRead = true, failACK = true
    for revision in 1...2 {
      owner.receive(.init(revision: String(revision), units: json.utf16.count, cost: 256), read: { id, offset in
        reads.append("\(id):\(offset)")
        if id == "1", offset == split, failRead { failRead = false; throw Refused.read }
        return offset == 0 ? String(json.prefix(split)) : String(json.dropFirst(split))
      }, acknowledge: { id in
        acknowledgements.append(id)
        if id == "1", failACK { failACK = false; throw Refused.acknowledgement }
      }, accept: { _, revision in accepted.append(revision) }, onFailure: { failures.append($0) })
    }
    do { try await owner.drain(); XCTFail("Read failure must remain visible") } catch {}
    XCTAssertTrue(owner.hasFailure); XCTAssertEqual(reads, ["1:0", "1:5"]); XCTAssertTrue(accepted.isEmpty)
    owner.retry()
    do { try await owner.drain(); XCTFail("Lost ACK must retain the already written head") } catch {}
    XCTAssertEqual(reads, ["1:0", "1:5", "1:5"]); XCTAssertEqual(accepted, [1])
    XCTAssertEqual(acknowledgements, ["1"])
    owner.retry(); try await owner.drain()
    XCTAssertFalse(owner.hasFailure); XCTAssertEqual(accepted, [1, 2])
    XCTAssertEqual(reads, ["1:0", "1:5", "1:5", "2:0", "2:5"])
    XCTAssertEqual(acknowledgements, ["1", "1", "2"]); XCTAssertEqual(failures.count, 2)
  }

  func testSourceRevocationJoinsAnEnteredWriterButDoesNotRunItsQueuedSuccessor() async throws {
    let owner = NotebookProgramStateTransfer(resources: SceneRenderResources())
    var release: CheckedContinuation<Void, Never>?, accepted: [UInt64] = [], ack: [String] = []
    for revision in 1...2 {
      owner.receive(.init(revision: String(revision), units: 1, cost: 128), read: { _, _ in "1" },
        acknowledge: { ack.append($0) }, accept: { _, revision in
          accepted.append(revision)
          await withCheckedContinuation { release = $0 }
        }, onFailure: { _ in XCTFail("Explicit source revocation is not retryable transport failure") })
    }
    let deadline = ContinuousClock.now + .seconds(2)
    while release == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
    let writer = try XCTUnwrap(release)
    owner.revoke()
    var drained = false
    let join = Task { @MainActor in try await owner.drain(); drained = true }
    await Task.yield(); XCTAssertFalse(drained)
    writer.resume(); release = nil
    try await join.value
    owner.retry(); try await owner.drain()
    XCTAssertEqual(accepted, [1]); XCTAssertTrue(ack.isEmpty); XCTAssertFalse(owner.hasFailure)
  }

  func testCheckpointReadRetryKeepsItsWindowsAndAdmissionUntilSnapshotOwnershipTransfers() async throws {
    enum Refused: Error { case read }
    let resources = SceneRenderResources(), owner = NotebookProgramStateTransfer(resources: resources)
    let json = "\"" + String(repeating: "x", count: 300_000) + "\""
    let descriptor = NotebookProgramStateTransfer.Snapshot(revision: "frozen", units: json.utf16.count, cost: json.utf16.count * 8 + 64)
    let before = resources.rasterAdmission.heldBytes
    var offsets: [Int] = [], fails = true
    let read: NotebookProgramStateTransfer.Read = { _, offset in
      offsets.append(offset)
      if offset > 0, fails { fails = false; throw Refused.read }
      let bytes = Data(json.utf8)
      return String(decoding: bytes[offset..<min(bytes.count, offset + 262_144)], as: UTF8.self)
    }
    do { _ = try await owner.checkpoint(descriptor, read: read); XCTFail("The frozen read should fail once") } catch {}
    XCTAssertTrue(owner.hasPendingCheckpoint)
    XCTAssertEqual(resources.rasterAdmission.heldBytes, before + descriptor.cost - owner.initialCredit)
    let snapshot = try await owner.checkpoint(descriptor, read: read)
    XCTAssertEqual(offsets, [0, 262_144, 262_144]); XCTAssertFalse(owner.hasPendingCheckpoint)
    XCTAssertEqual(snapshot.value, .string(String(repeating: "x", count: 300_000)))
    snapshot.release(); XCTAssertEqual(resources.rasterAdmission.heldBytes, before)
  }

  func testCheckpointRevocationRetainsReadAdmissionUntilTheLateWindowReturns() async throws {
    let resources = SceneRenderResources(), owner = NotebookProgramStateTransfer(resources: resources)
    let json = "\"" + String(repeating: "x", count: 300_000) + "\""
    let descriptor = NotebookProgramStateTransfer.Snapshot(revision: "frozen", units: json.utf16.count, cost: json.utf16.count * 8 + 64)
    let before = resources.rasterAdmission.heldBytes
    var held: CheckedContinuation<Void, Never>?, reads = 0
    let task = Task { @MainActor in
      do {
        _ = try await owner.checkpoint(descriptor) { _, _ in
          reads += 1
          await withCheckedContinuation { held = $0 }
          return String(json.prefix(262_144))
        }
        XCTFail("A revoked read cannot decode or publish its late window")
      } catch { XCTAssertTrue(error is NotebookProgramCheckpointError) }
    }
    let deadline = ContinuousClock.now + .seconds(2)
    while held == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
    let release = try XCTUnwrap(held)
    owner.revoke()
    XCTAssertEqual(resources.rasterAdmission.heldBytes, before + descriptor.cost - owner.initialCredit)
    release.resume(); held = nil
    await task.value
    XCTAssertEqual(reads, 1); XCTAssertEqual(resources.rasterAdmission.heldBytes, before)
  }

}

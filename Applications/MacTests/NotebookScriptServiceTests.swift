import Foundation
import AppKit
import NotebookCore
import NotebookScriptProtocol
import PDFKit
import Security
import XCTest
@testable import NotebookScriptHost

/// These tests require the actual two embedded, signed XPC services in the Mac
/// test host. A missing service is a failure, never an in-process substitute.
@MainActor
final class NotebookScriptServiceTests: XCTestCase {
  private static var checkedSandboxSignatures = false
  @MainActor private final class Owner {
    let store: NotebookStore
    var commitAccepted = false
    var holdCommit = false
    var releaseCommit: CheckedContinuation<Void, Never>?
    var holdPublication = false
    var publicationAccepted = false
    var releasePublication: CheckedContinuation<Void, Never>?
    var holdAdmission = false
    var admissionAccepted = false
    var releaseAdmission: CheckedContinuation<Void, Never>?
    var loseWriteReplies = false
    var nativeWrites = 0
    var reads = 0
    init(root: URL? = nil) throws {
      store = NotebookStore(root: root ?? FileManager.default.temporaryDirectory.appendingPathComponent("notebook-xpc-contract-\(UUID())"))
      _ = try store.loadOrCreate(actor: UUID(), pageSize: .init(width: 834, height: 1194))
      _ = try store.loadOrCreateSpatialInk(actor: UUID())
    }
    func command(_ request: NotebookCommand) async throws -> JSONValue {
      if request.command == .read { reads += 1 }
      if request.command == .commitAction, holdCommit {
        commitAccepted = true
        await withCheckedContinuation { releaseCommit = $0 }
      }
      if request.command == .publishExport, holdPublication {
        publicationAccepted = true
        await withCheckedContinuation { releasePublication = $0 }
      }
      let result = try NotebookCommandDispatcher(store: store).handle(request)
      if request.command == .commitAction || request.command == .undo {
        nativeWrites += 1
        if loseWriteReplies { throw CollaborationError("native_reply_lost", "Commit succeeded, reply was lost") }
      }
      return result
    }
    func persist(_ operation: @Sendable (NotebookStore) throws -> JSONValue) async throws -> JSONValue {
      let result = try operation(store)
      if holdAdmission, result.string("state") == "queued" {
        holdAdmission = false; admissionAccepted = true
        await withCheckedContinuation { releaseAdmission = $0 }
      }
      return result
    }
  }

  private func service(_ key: String) throws -> String {
    try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: key) as? String, "The host must embed its configured XPC services.")
  }

  private func coordinator(_ owner: Owner) async throws -> NotebookScriptCoordinator {
    try await requireRestrictedServiceSignatures()
    return NotebookScriptCoordinator(command: { try await owner.command($0) },
      persistence: { operation in try await owner.persist(operation) },
      workingDirectory: owner.store.root.appendingPathComponent("derived/script-runtime"),
      userServiceName: try service("NotebookScriptService"), markupServiceName: try service("NotebookMarkupService"))
  }

  private func requireRestrictedServiceSignatures() async throws {
    if Self.checkedSandboxSignatures { return }
    for (key, identifier) in [
      ("NotebookScriptService", "com.amirtlinov.notebook.script-service.native-test"),
      ("NotebookMarkupService", "com.amirtlinov.notebook.markup-service.native-test"),
    ] {
      let configured = try service(key)
      _ = try XCTUnwrap(configured == identifier ? true : nil,
        "Native contracts must use their own stateless worker identity, received: \(configured)")
    }
    let root = Bundle.main.bundleURL.appendingPathComponent("Contents/XPCServices", isDirectory: true)
    let entries: [(URL, [String: Bool])] = [
      (root.appendingPathComponent("NotebookScriptService.xpc"), ["com.apple.security.app-sandbox": true]),
      (root.appendingPathComponent("NotebookMarkupService.xpc"), ["com.apple.security.app-sandbox": true]),
      (root.appendingPathComponent("NotebookMarkupService.xpc/Contents/Helpers/tectonic"),
        ["com.apple.security.app-sandbox": true, "com.apple.security.inherit": true]),
      (root.appendingPathComponent("NotebookMarkupService.xpc/Contents/Helpers/notebook-image-compiler"),
        ["com.apple.security.app-sandbox": true, "com.apple.security.inherit": true]),
    ]
    // Security verifies the signed files and communicates with system services.
    // Keep that I/O off the main actor that owns the coordinator under test.
    let failures = await Task.detached(priority: .utility) {
      var failures: [String] = []
      for (url, expected) in entries {
        var candidate: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &candidate) == errSecSuccess,
          let code = candidate else {
          failures.append("Missing signed runtime: \(url)"); continue
        }
        guard SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else {
          failures.append("Invalid signed runtime: \(url)"); continue
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
          let values = information as? [String: Any],
          let entitlements = values[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else {
          failures.append("Missing signed entitlements: \(url)"); continue
        }
        // Xcode test used to inject read-only access to '/'. A test cannot claim
        // isolation under broader rights than the actual production services.
        if !NSDictionary(dictionary: entitlements).isEqual(to: expected) {
          failures.append("Unexpected actual runtime entitlements: \(entitlements)")
        }
      }
      return failures
    }.value
    _ = try XCTUnwrap(failures.isEmpty ? true : nil, failures.joined(separator: "\n"))
    Self.checkedSandboxSignatures = true
  }

  private func finish(_ host: NotebookScriptCoordinator, _ id: UUID) async throws -> JSONValue {
    let deadline = ContinuousClock.now + .seconds(38)
    while ContinuousClock.now < deadline {
      let page = try await host.handle(.init(op: .resume, runID: id, waitMilliseconds: 1000))
      if !["queued", "running"].contains(page.string("status") ?? "") { return page }
    }
    XCTFail("The native wall watchdog did not complete the real service.")
    return .null
  }

  func testSandboxedServiceAwaitsFiftyReadsAndHasNoAmbientCapabilities() async throws {
    let owner = try Owner(), host = try await coordinator(owner), id = UUID()
    defer { try? FileManager.default.removeItem(at: owner.store.root) }
    _ = try await host.handle(.init(op: .start, runID: id, apiVersion: 2, code: """
      const values=await Promise.all(Array.from({length:50},()=>nb.read({kind:'workspaceHeader'})));
      return {count:values.length,ids:values.map(x=>x.data.workspaceID),
        globals:[typeof process,typeof require,typeof fetch,typeof std,typeof os,typeof SharedArrayBuffer,typeof Atomics]};
      """))
    let result = try await finish(host, id)
    XCTAssertEqual(result.string("status"), "completed", "\(result)")
    XCTAssertEqual(result["result"]?["count"], .number(50))
    XCTAssertEqual(result["result"]?["globals"], .array(Array(repeating: .string("undefined"), count: 7)))
    await host.shutdown()
  }

  func testAddressedObservationAndPageReadCrossTheRealSandboxedSDK() async throws {
    let owner = try Owner(), host = try await coordinator(owner), id = UUID()
    defer { try? FileManager.default.removeItem(at: owner.store.root) }
    let pageID = try XCTUnwrap(owner.store.loadIndex().selectedPageID)
    var page = try owner.store.loadPage(pageID)
    let changed = page.replaceElements((0..<40).map { .init(id: "element-\($0)", kind: .markdown,
      frame: .init(x: 10, y: 10, width: 100, height: 100), source: "source-\($0)", html: "<p>\($0)</p>") }, actor: UUID())
    XCTAssertTrue(changed)
    try owner.store.savePage(page)
    _ = try await host.handle(.init(op: .start, runID: id, apiVersion: 2, code: """
      const query={target:{kind:'page',id:args.page},elementID:'element-39'};
      const first=await nb.observe(query);
      const second=await nb.observe({...query,since:first.data.checkpoint});
      const addressed=await nb.page({id:args.page,elementID:'element-39'});
      return {element:first.data.objects[0].value.content,unchanged:second.data.objects.length===0,
        direct:addressed.data.element,visual:first.data.visual.status};
      """, arguments: .object(["page": .string(pageID.uuidString)])))
    let result = try await finish(host, id)
    XCTAssertEqual(result.string("status"), "completed", "\(result)")
    XCTAssertEqual(result["result"]?["element"]?["id"], .string("element-39"))
    XCTAssertEqual(result["result"]?["element"], result["result"]?["direct"])
    XCTAssertEqual(result["result"]?["unchanged"], .bool(true))
    XCTAssertEqual(result["result"]?["visual"], .string("not_requested"))
    await host.shutdown()
  }

  func testIncrementalGeometryCrossesTheRealSandboxedSDK() async throws {
    let owner = try Owner(), host = try await coordinator(owner)
    defer { try? FileManager.default.removeItem(at: owner.store.root) }
    let pageID = try XCTUnwrap(owner.store.loadIndex().selectedPageID)
    var page = try owner.store.loadPage(pageID)
    let connection = NotebookGraphicConnection(start: .init(point: .init(x: 0, y: 0), binding: .init(elementID: "node")), end: .init(point: .init(x: 1, y: 1)))
    var node = AgentElement(id: "node", kind: .graphic, frame: .init(x: 10, y: 10, width: 100, height: 100), source: "", html: "", graphic: .init())
    let arrow = AgentElement(id: "arrow", kind: .graphic, frame: .init(x: 300, y: 10, width: 100, height: 100), source: "", html: "", graphic: .init(shape: .connector, connection: connection))
    XCTAssertTrue(page.replaceElements([node, arrow], actor: UUID()))
    try owner.store.savePage(page)
    let initialID = UUID()
    let query: JSONValue = .object(["target": try .encode(CollaborationTarget(kind: .page, id: pageID)),
      "ids": .array([.string("arrow")]), "fields": .array([.string("geometry")])])
    _ = try await host.handle(.init(op: .start, runID: initialID, apiVersion: 2, code: "return await nb.observe(args);", arguments: query))
    let initial = try await finish(host, initialID)
    XCTAssertEqual(initial.string("status"), "completed", "\(initial)")
    node = node.updating(frame: .init(x: 150, y: 10, width: 100, height: 100))
    XCTAssertTrue(page.replaceElements([node, arrow], actor: UUID()))
    try owner.store.savePage(page)
    var next = query.fields; next["since"] = initial["result"]?["data"]?["checkpoint"]
    let deltaID = UUID()
    _ = try await host.handle(.init(op: .start, runID: deltaID, apiVersion: 2, code: "return await nb.observe(args);", arguments: .object(next)))
    let delta = try await finish(host, deltaID)
    XCTAssertEqual(delta.string("status"), "completed", "\(delta)")
    XCTAssertEqual(delta["result"]?["data"]?["mode"], .string("delta"))
    let objects = delta["result"]?["data"]?.array("objects") ?? []
    XCTAssertEqual(objects.count, 1)
    XCTAssertEqual(objects.first?["id"], .string("arrow"))
    XCTAssertNotEqual(objects.first?["value"], initial["result"]?["data"]?.array("objects").first?["value"])
    XCTAssertEqual(try owner.store.loadPage(pageID).elements.first { $0.id == "arrow" }, arrow)
    await host.shutdown()
  }

  func testTrustedMarkupCanCompleteWhileTheUserInterpreterAwaitsTransaction() async throws {
    let owner = try Owner(), host = try await coordinator(owner), id = UUID()
    defer { try? FileManager.default.removeItem(at: owner.store.root) }
    let page = try owner.store.loadOrCreate(actor: UUID(), pageSize: .init(width: 834, height: 1194)).0.selectedPageID!
    _ = try await host.handle(.init(op: .start, runID: id, apiVersion: 2, code: """
      const p=await nb.page({id:args.page});
      const receipt=await nb.transaction('markdown',{summary:'XPC normalization',
        base:p.basis,
        operations:[{kind:'insertElement',target:{kind:'page',id:args.page},id:'proof',
          values:{kind:'markdown',source:'# Actual parser\\n\\n**Saved**',frame:{x:20,y:20,width:300,height:180}}}]});
      return {actionID:receipt.actionID};
      """, arguments: .object(["page": .string(page.uuidString)])))
    let result = try await finish(host, id)
    XCTAssertEqual(result.string("status"), "completed", "\(result)")
    let saved = try XCTUnwrap(owner.store.loadPage(page).elements.first { $0.id == "proof" })
    XCTAssertTrue(saved.html.contains("<strong>Saved</strong>"))
    let action = try XCTUnwrap(result["result"]?.string("actionID").flatMap(UUID.init(uuidString:)))
    XCTAssertNotNil(try owner.store.collaborationAction(action).requestFingerprint)
    await host.shutdown()
  }

  func testSDKV2LabelBasisAndEarlyEmitReturnOneImmutableResult() async throws {
    let owner = try Owner(), host = try await coordinator(owner), run = UUID()
    defer { try? FileManager.default.removeItem(at: owner.store.root) }
    let pageID = try XCTUnwrap(owner.store.loadIndex().selectedPageID)
    var page = try owner.store.loadPage(pageID)
    let element = AgentElement(id: "label-node", kind: .graphic, frame: .init(x: 20, y: 30, width: 200, height: 100),
      source: "", html: "", graphic: .init(label: "Before"))
    XCTAssertTrue(page.replaceElements([element], actor: UUID())); try owner.store.savePage(page)
    // Warm both signed service launch paths before testing the short-run budget.
    let warm = UUID()
    _ = try await host.handle(.init(op: .start, runID: warm, code: "const s=await nb.page({id:args.page}); return await nb.transaction('warm',{base:s.basis,summary:'Warm label',operations:[{kind:'updateElement',target:{kind:'page',id:args.page},id:'label-node',values:{graphic:{label:'Before'}}}]});", arguments: .object(["page": .string(pageID.uuidString)])))
    let warmed = try await finish(host, warm)
    XCTAssertEqual(warmed.string("status"), "completed", "\(warmed)")
    let result = try await host.handle(.init(op: .start, runID: run, code: """
      await emit({started:true});
      const s=await nb.page({id:args.page,elementID:'label-node'});
      return await nb.transaction('label',{base:s.basis,summary:'Change label',operations:[
        {kind:'updateElement',target:{kind:'page',id:args.page},id:s.data.element.id,values:{graphic:{label:'After'}}}
      ]});
      """, arguments: .object(["page": .string(pageID.uuidString)])))
    XCTAssertEqual(result.string("status"), "completed", "Early emit must not force an external resume: \(result)")
    XCTAssertEqual(result.array("events").count, 1)
    let saved = try XCTUnwrap(owner.store.readPageElement(pageID: pageID, elementID: "label-node"))
    XCTAssertEqual(saved.graphic?.label, "After")
    XCTAssertEqual(saved.source, element.source); XCTAssertEqual(saved.frame, element.frame)
    XCTAssertEqual(saved.graphic?.style, element.graphic?.style)
    let actionID = try XCTUnwrap(result["result"]?.string("actionID").flatMap(UUID.init(uuidString:)))
    let original = try XCTUnwrap(result["result"])
    _ = try owner.store.undoCollaborationAction(actionID, actor: UUID())
    XCTAssertEqual(try owner.store.savedActionResult(actionID), original)
    XCTAssertEqual(original["publication"]?.string("saved"), "confirmed")
    XCTAssertNotEqual(original["publication"]?.string("shownOnIPad"), "confirmed")
    XCTAssertEqual(try owner.store.scriptEffect(run, id: actionID).value, original)
    await host.shutdown()
  }

  func testSearchContinuationAndAddressedHitCrossTheRealSDK() async throws {
    let owner = try Owner(), host = try await coordinator(owner), id = UUID()
    defer { try? FileManager.default.removeItem(at: owner.store.root) }
    let pageID = try XCTUnwrap(owner.store.loadIndex().selectedPageID)
    var page = try owner.store.loadPage(pageID)
    let changed = page.replaceElements((0..<13).map { .init(id: String(format: "hit-%02d", $0), kind: .markdown,
      frame: .init(x: 10, y: 10, width: 100, height: 100), source: "needle \($0)", html: "<p>\($0)</p>") }, actor: UUID())
    XCTAssertTrue(changed)
    try owner.store.savePage(page)
    _ = try await host.handle(.init(op: .start, runID: id, apiVersion: 2, code: """
      const filters={kinds:['page'],target:{kind:'page',id:args.page}};
      let next, hits=[], pages=0;
      do { const result=await nb.search({query:'needle',limit:3,filters,...(next?{next}:{})});
        hits.push(...result.data.results); next=result.coverage.next; pages++;
      } while(next && pages<10);
      const hit=await nb.page({id:args.page,elementID:hits.at(-1).elementID});
      return {ids:hits.map(x=>x.elementID),pages,source:hit.data.element.source};
      """, arguments: .object(["page": .string(pageID.uuidString)])))
    let result = try await finish(host, id)
    XCTAssertEqual(result.string("status"), "completed", "\(result)")
    XCTAssertEqual(result["result"]?["pages"], .number(5))
    XCTAssertEqual(result["result"]?["ids"], .array((0..<13).map { .string(String(format: "hit-%02d", $0)) }))
    XCTAssertEqual(result["result"]?["source"], .string("needle 12"))
    await host.shutdown()
  }

  func testLostCommitAndUndoRepliesPreserveOriginalResultsAndNeverRepeatEffects() async throws {
    let owner = try Owner(), host = try await coordinator(owner), run = UUID()
    defer { try? FileManager.default.removeItem(at: owner.store.root) }
    let page = try XCTUnwrap(owner.store.loadIndex().selectedPageID)
    owner.loseWriteReplies = true
    _ = try await host.handle(.init(op: .start, runID: run, code: """
      const p=await nb.page({id:args.page});
      const action={base:p.basis,summary:'Lost native reply',operations:[
        {kind:'insertElement',target:{kind:'page',id:args.page},id:'lost-reply',values:{kind:'graphic',source:'',
          frame:{x:20,y:30,width:150,height:100},graphic:{shape:'ellipse',style:{stroke:{red:0,green:0,blue:0},strokeWidth:2},
          label:'One write',representation:'geometry',visible:true,sourceInkIDs:[]}}}]};
      const first=await nb.transaction('same',action);
      const second=await nb.transaction('same',action);
      let conflict;try{await nb.transaction('same',{...action,summary:'Changed key identity'});}catch(e){conflict=e.code;}
      const undo=await nb.undo('undo',{actionID:first.actionID});
      const undoAgain=await nb.undo('undo',{actionID:first.actionID});
      const originalAfterUndo=await nb.transaction('same',action);
      return {first,second,undo,undoAgain,originalAfterUndo,conflict};
      """, arguments: .object(["page": .string(page.uuidString)])))
    let result = try await finish(host, run)
    XCTAssertEqual(result.string("status"), "completed", "\(result)")
    XCTAssertEqual(result["result"]?["first"], result["result"]?["second"])
    XCTAssertEqual(result["result"]?["first"], result["result"]?["originalAfterUndo"])
    XCTAssertEqual(result["result"]?["undo"], result["result"]?["undoAgain"])
    XCTAssertEqual(result["result"]?["conflict"], .string("effect_id_conflict"))
    XCTAssertEqual(owner.nativeWrites, 2)
    XCTAssertEqual(result.array("effects").count, 2)
    XCTAssertTrue(result.array("effects").allSatisfy { $0.string("state") == "saved" })
    XCTAssertNil(try owner.store.readPageElement(pageID: page, elementID: "lost-reply"))
    let repeated = try await host.handle(.init(op: .resume, runID: run, waitMilliseconds: 0))
    XCTAssertEqual(repeated["result"], result["result"])
    XCTAssertEqual(owner.nativeWrites, 2)
    await host.shutdown()
  }

  func testCancellationPreservesAnAlreadyAcceptedNativeCommit() async throws {
    let owner = try Owner(), host = try await coordinator(owner), id = UUID()
    owner.holdCommit = true
    defer { owner.releaseCommit?.resume(); try? FileManager.default.removeItem(at: owner.store.root) }
    let page = try owner.store.loadOrCreate(actor: UUID(), pageSize: .init(width: 834, height: 1194)).0.selectedPageID!
    _ = try await host.handle(.init(op: .start, runID: id, apiVersion: 2, code: """
      const p=await nb.page({id:args.page});
      await nb.transaction('accepted',{summary:'accepted before cancel',
        base:p.basis,
        operations:[{kind:'insertElement',target:{kind:'page',id:args.page},id:'accepted',
          values:{kind:'markdown',source:'**accepted**',frame:{x:20,y:20,width:300,height:180}}}]});
      await nb.point('must-not-start',{references:[]});
      """, arguments: .object(["page": .string(page.uuidString)])))
    let deadline = ContinuousClock.now + .seconds(10)
    while !owner.commitAccepted, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    XCTAssertTrue(owner.commitAccepted)
    _ = try await host.handle(.init(op: .cancel, runID: id))
    owner.releaseCommit?.resume(); owner.releaseCommit = nil
    let result = try await finish(host, id)
    XCTAssertEqual(result.string("status"), "cancelled", "\(result)")
    XCTAssertEqual(result["error"]?.string("code"), "run_cancelled")
    XCTAssertEqual(result.array("effects").count, 1)
    XCTAssertEqual(result.array("effects").first?.string("state"), "saved")
    XCTAssertTrue(try owner.store.loadPage(page).elements.contains { $0.id == "accepted" })
    await host.shutdown()
  }

  func testLoopsErrorsAndOutputQuotaTerminateOnlyTheWorker() async throws {
    let owner = try Owner(), host = try await coordinator(owner)
    defer { try? FileManager.default.removeItem(at: owner.store.root) }
    for code in ["while(true){}", "throw new Error('deliberate-proof');", "return 'x'.repeat(300000);",
      "const a=[];while(true)a.push(new Uint8Array(1024*1024));"] {
      let id = UUID()
      _ = try await host.handle(.init(op: .start, runID: id, apiVersion: 2, code: code))
      let result = try await finish(host, id)
      XCTAssertEqual(result.string("status"), "failed", "\(result)")
      XCTAssertNotEqual(result["error"], .null)
    }
    let refused = UUID()
    _ = try await host.handle(.init(op: .start, runID: refused, apiVersion: 2, code: "await nb.page({id:'not-a-uuid'});"))
    let refusal = try await finish(host, refused)
    XCTAssertEqual(refusal.string("status"), "failed")
    XCTAssertTrue(refusal["error"]?.string("message")?.contains("invalid_reference") == true, "\(refusal)")
    let id = UUID()
    _ = try await host.handle(.init(op: .start, runID: id, apiVersion: 2, code: "return 42;"))
    let result = try await finish(host, id)
    XCTAssertEqual(result["result"], .number(42))
    await host.shutdown()
  }

  func testCancelStopsAwaitWithoutInventingAnEffectAndMarkupRefusesSource() async throws {
    let owner = try Owner(), host = try await coordinator(owner), id = UUID()
    defer { try? FileManager.default.removeItem(at: owner.store.root) }
    _ = try await host.handle(.init(op: .start, runID: id, apiVersion: 2,
      code: "for(let i=0;i<20;i++) await nb.wait({milliseconds:1000}); await nb.point('never',{references:[]});"))
    try await Task.sleep(for: .milliseconds(100))
    _ = try await host.handle(.init(op: .cancel, runID: id))
    let result = try await finish(host, id)
    XCTAssertEqual(result.string("status"), "cancelled")
    XCTAssertEqual(result["error"]?.string("code"), "run_cancelled")
    XCTAssertTrue(result.array("effects").isEmpty)
    let parser = NotebookXPCWorker(serviceName: try service("NotebookMarkupService")) { _ in .init(code: "unexpected_host") }
    let rejected = await parser.execute(.init(id: UUID(), code: "return 42", arguments: Data("{}".utf8)))
    XCTAssertEqual(rejected.code, "invalid_markup_request")
    parser.invalidate()
    await host.shutdown()
  }

  func testHostDeadlineIncludesXPCLaunchAndTheAwaitedWorker() async throws {
    try await requireRestrictedServiceSignatures()
    let worker = NotebookXPCWorker(serviceName: try service("NotebookScriptService")) { _ in .init(code: "unexpected_host") }
    let started = ContinuousClock.now
    let result = await worker.execute(.init(id: UUID(), code: "await new Promise(()=>{});", arguments: Data("{}".utf8)),
      deadline: .now + .milliseconds(200))
    XCTAssertEqual(result.code, "script_timeout")
    XCTAssertLessThan(started.duration(to: .now), .seconds(2))
    worker.invalidate()
    let next = NotebookXPCWorker(serviceName: try service("NotebookScriptService")) { _ in .init(code: "unexpected_host") }
    let healthy = await next.execute(.init(id: UUID(), code: "return 42;", arguments: Data("{}".utf8)), deadline: .now + .seconds(5))
    XCTAssertNil(healthy.code, "\(String(describing: healthy.message))")
    XCTAssertEqual(healthy.value, Data("42".utf8))
    next.invalidate()
  }

  func testPublicPlacementAndAtomicOperationDiagnosticsCrossTheRealSDK() async throws {
    let owner = try Owner(), host = try await coordinator(owner), id = UUID()
    defer { try? FileManager.default.removeItem(at: owner.store.root) }
    let page = try owner.store.loadOrCreate(actor: UUID(), pageSize: .init(width: 834, height: 1194)).0.selectedPageID!
    let target = CollaborationTarget(kind: .page, id: page)
    let placement: JSONValue = .object(["target": try .encode(target), "expectedRevision": .string(try owner.store.targetContentRevision(target: target)),
      "items": .array([.object(["id": .string("next-note"), "size": .object(["width": .number(180), "height": .number(100)]), "direction": .string("free")])])])
    let context = try await host.context(.init(method: "place", arguments: placement))
    XCTAssertEqual(context["data"]?.string("status"), "snapshot_pending")
    _ = try await host.handle(.init(op: .start, runID: id, apiVersion: 2, code: """
      const place=await nb.place(args.placement);
      const p=await nb.page({id:args.page}), target={kind:'page',id:args.page};
      const action={summary:'atomic rejected operation',base:p.basis,operations:[
        {kind:'insertElement',target,id:'must-remain-absent',values:{kind:'web',source:'private source',html:'<p>Absent</p>',frame:{x:20,y:20,width:200,height:100}}},
        {kind:'removeElement',target,id:'absent',values:{}}]};
      const failures=[];
      for(let i=0;i<2;i++) {
        try { await nb.transaction('atomic',action); }
        catch(e) { failures.push({code:e.code,operation:e.operation}); }
      }
      return {place:place.data.status,failures};
      """, arguments: .object(["page": .string(page.uuidString.lowercased()), "placement": placement])))
    let result = try await finish(host, id)
    XCTAssertEqual(result.string("status"), "completed", "\(result)")
    XCTAssertEqual(result["result"]?.string("place"), "snapshot_pending")
    let failures = result["result"]?.array("failures") ?? []
    XCTAssertEqual(failures.count, 2)
    XCTAssertEqual(failures.first, failures.last)
    XCTAssertEqual(failures.first?.string("code"), "target_missing")
    XCTAssertEqual(failures.first?["operation"]?["index"], .number(1))
    XCTAssertEqual(failures.first?["operation"]?.string("kind"), "removeElement")
    XCTAssertEqual(result.array("effects").count, 1)
    XCTAssertEqual(result.array("effects").first?.string("state"), "notSaved")
    XCTAssertEqual(result.array("effects").first?["error"]?["operation"], failures.first?["operation"])
    XCTAssertFalse(try owner.store.loadPage(page).elements.contains { $0.id == "must-remain-absent" })
    await host.shutdown()
  }

  func testStartupRecoversJobsBeforeTheFirstContextReadWithoutReplayingCode() async throws {
    let owner = try Owner(), run = UUID(), job = UUID()
    defer { try? FileManager.default.removeItem(at: owner.store.root) }
    _ = try owner.store.admitScriptRun(.init(op: .start, runID: run, apiVersion: 2,
      code: "throw new Error('must never replay');"))
    _ = try owner.store.setScriptRunState(run, state: .running)
    try owner.store.saveScriptExportJob(job, value: .object(["status": .string("running"), "jobID": .string(job.uuidString)]))
    let host = try await coordinator(owner)
    try await host.start()
    try await host.start()
    let status = try await host.context(.init(method: "exportStatus", arguments: .object(["jobID": .string(job.uuidString)])))
    XCTAssertEqual(status["data"]?.string("status"), "interrupted")
    XCTAssertEqual(try owner.store.scriptRun(run)?.state, .interrupted)
    let page = try await host.handle(.init(op: .resume, runID: run))
    XCTAssertEqual(page.string("status"), "interrupted")
    XCTAssertEqual(page["error"]?.string("code"), "owner_restarted")
    XCTAssertTrue(page.array("effects").isEmpty)
    await host.shutdown()
  }

  func testActualPDFJobOutlivesItsUserRunAndPublishesThroughTheNativeOwner() async throws {
    let owner = try Owner(), host = try await coordinator(owner), run = UUID()
    defer { owner.releasePublication?.resume(); try? FileManager.default.removeItem(at: owner.store.root) }
    // These packages were not part of the Mac user's small existing cache.
    // Full pinned resources preserve arbitrary supported TeX preambles.
    let svg = ##"<svg xmlns="http://www.w3.org/2000/svg" width="240" height="100"><style>.paint{fill:url(#gradient)}</style><defs><linearGradient id="gradient"><stop stop-color="yellow"/><stop offset="1" stop-color="blue"/></linearGradient><clipPath id="clip"><circle cx="210" cy="75" r="18"/></clipPath><filter id="blur"><feGaussianBlur stdDeviation="2"/></filter></defs><rect width="240" height="100" fill="#ed182a"/><text x="12" y="50" font-size="22" fill="white">Printed SVG vector</text><rect class="paint" x="190" y="55" width="40" height="40" clip-path="url(#clip)" filter="url(#blur)"/></svg>"##
    let svgURL = "data:image/svg+xml;base64," + Data(svg.utf8).base64EncodedString()
    let interactiveID = "collaboration-counter-1d13a2ed-6e64-4ff6-b973-aa1b28bc328e"
    let document = DocumentDocument(actor: UUID(), preamble: "\\usepackage{tikz,siunitx}", blocks: [
      .markdown(id: "print", source: "# Проверка PDF\n\n**Сохранённый** русский источник и формула $x_1$.\n\n<a href='#vector'>К рисунку</a> <a href='https://example.org/notebook'>Сайт</a>"),
      .markdown(id: "vector", source: "<h2 id='vector'>Векторное изображение</h2><img width='240' height='100' src='\(svgURL)'><p><a href='#проверка-pdf'>К началу</a></p>"),
      .latex(id: "math", source: "\\[E=mc^2,\\qquad \\int_0^1 x^2\\,dx=\\frac{1}{3}\\]\n\\begin{tikzpicture}\\draw (0,0) -- (1,1);\\end{tikzpicture}\\num{1234.5}"),
      .interactive(id: interactiveID, html: "<button>+1</button>")
    ])
    try owner.store.saveDocument(document); try owner.store.saveDocumentState(.init(id: document.id, actor: UUID()))
    owner.holdPublication = true
    _ = try await host.handle(.init(op: .start, runID: run, apiVersion: 2,
      code: "return await nb.export('actual-pdf',{documentID:args.documentID});",
      arguments: .object(["documentID": .string(document.id.uuidString)])))
    let completed = try await finish(host, run)
    XCTAssertEqual(completed.string("status"), "completed", "\(completed)")
    let job = try XCTUnwrap(completed["result"]?.string("jobID"))
    let deadline = ContinuousClock.now + .seconds(130)
    while !owner.publicationAccepted, ContinuousClock.now < deadline {
      let status = try await host.context(.init(method: "exportStatus", arguments: .object(["jobID": .string(job)])))
      if status["data"]?.string("status") == "failed" { XCTFail("Actual compiler failed: \(status)"); break }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTAssertTrue(owner.publicationAccepted, "Only the test barrier delays a real compiled PDF; no receipt or PDF is fabricated.")
    let another = UUID()
    _ = try await host.handle(.init(op: .start, runID: another, apiVersion: 2, code: "return 42;"))
    let independent = try await finish(host, another)
    XCTAssertEqual(independent["result"], .number(42))
    owner.releasePublication?.resume(); owner.releasePublication = nil
    var status: JSONValue = .null
    let publicationDeadline = ContinuousClock.now + .seconds(10)
    repeat {
      status = try await host.context(.init(method: "exportStatus", arguments: .object(["jobID": .string(job)])))
      if status["data"]?.string("status") != "saved" { try await Task.sleep(for: .milliseconds(25)) }
    } while status["data"]?.string("status") != "saved" && ContinuousClock.now < publicationDeadline
    XCTAssertEqual(status["data"]?.string("status"), "saved", "\(status)")
    let receipt = try XCTUnwrap(status["data"]?["receipt"]).decode(NotebookExportReceipt.self)
    let pdf = try Data(contentsOf: URL(fileURLWithPath: receipt.pdfPath))
    XCTAssertTrue(pdf.starts(with: Data("%PDF".utf8)))
    let exportedPDF = XCTAttachment(data: pdf, uniformTypeIdentifier: "com.adobe.pdf")
    exportedPDF.name = "export-html-svg-links-final-pdf"; exportedPDF.lifetime = .keepAlways; add(exportedPDF)
    XCTAssertGreaterThan(pdf.count, 1000)
    XCTAssertEqual(pdf.count, receipt.byteCount)
    XCTAssertTrue(PDFDocument(data: pdf)?.string?.contains("русский источник") == true,
      "The actual PDF must contain the printed Cyrillic text, not merely a valid PDF header.")
    XCTAssertTrue(try String(contentsOfFile: receipt.texPath, encoding: .utf8).contains("Проверка PDF"))
    let printed = try XCTUnwrap(PDFDocument(data: pdf))
    let pages = (0..<printed.pageCount).compactMap { printed.page(at: $0) }
    XCTAssertTrue((printed.string ?? "").filter { !$0.isWhitespace }.contains(interactiveID),
      "The complete interactive address must survive wrapping in the actual PDF")
    for page in pages {
      let paper = page.bounds(for: .mediaBox)
      for index in 0..<page.numberOfCharacters {
        let character = page.characterBounds(at: index)
        XCTAssertTrue(character.isEmpty || paper.contains(character),
          "Printed text must not be clipped by the page edge: \(character) outside \(paper)")
      }
    }
    let annotations = pages.flatMap(\.annotations).filter { $0.type == "Link" }
    XCTAssertGreaterThanOrEqual(annotations.count, 3, "The actual PDF keeps forward, backward and HTTPS links.")
    XCTAssertTrue(annotations.contains { ($0.action as? PDFActionURL)?.url?.absoluteString == "https://example.org/notebook" })
    XCTAssertEqual(receipt.assets?.count, 1)
    let renderedAsset = try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(receipt.assets?.first?.path)))
    XCTAssertTrue(PDFDocument(data: renderedAsset)?.string?.contains("Printed SVG vector") == true,
      "The SVG renderer prints real SVG text into the vector PDF; an alt label or a blank page does not pass.")
    XCTAssertTrue(pages.contains { page in
      let image = page.thumbnail(of: NSSize(width: 600, height: 850), for: .mediaBox)
      guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
      let width = cgImage.width, height = cgImage.height
      var pixels = [UInt8](repeating: 0, count: width * height * 4)
      guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
      context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
      return stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0] > 180 && pixels[$0 + 1] < 70 && pixels[$0 + 2] < 90 }.count > 1000
    }, "A substantial red SVG rectangle must be visible in the final compiled PDF.")
    XCTAssertFalse(receipt.log.contains("Missing character"))
    await host.shutdown()
  }

  func testActualCompilerCannotReadOutsideItsSandboxAndUserServiceRejectsCompilation() async throws {
    try await requireRestrictedServiceSignatures()
    let owner = try Owner(root: FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".notebook-xpc-sandbox-canary-\(UUID())", isDirectory: true))
    defer { try? FileManager.default.removeItem(at: owner.store.root) }
    let canary = owner.store.root.appendingPathComponent("compiler-outside-canary.tex")
    let marker = "NB_OUTSIDE_CANARY_READ_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    try Data("\\typeout{\(marker)}".utf8).write(to: canary)
    let source = "\\documentclass{article}\n\\begin{document}\nProbe.\\input{\(canary.path)}\n\\end{document}"
    let compiler = NotebookXPCWorker(serviceName: try service("NotebookMarkupService")) { _ in .init(code: "unexpected_host") }
    let result = await compiler.compile(.init(id: UUID(), source: source))
    XCTAssertEqual(result.code, "export_failed", "Actual signed child must be denied by App Sandbox: \(String(describing: result.message))")
    XCTAssertNil(result.value)
    XCTAssertTrue(result.message?.contains(canary.lastPathComponent) == true,
      "The native compiler must report its attempted access to this exact outside file.")
    XCTAssertFalse(result.message?.contains(marker) == true, "TeX must never read the host's harmless canary.")
    XCTAssertEqual(try String(contentsOf: canary, encoding: .utf8), "\\typeout{\(marker)}")
    compiler.invalidate()
    for body in ["<foreignObject width='20' height='20'><div xmlns='http://www.w3.org/1999/xhtml'>Must not vanish</div></foreignObject>",
      "<style>@import url(https://example.org/print.css);</style>", "<image href='\(canary.absoluteString)'/>"] {
      let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='40' height='40'>\(body)</svg>"
      // Production owns one XPC connection per compiler job. Each negative
      // sample must cross that real boundary, not reuse a completed lease.
      let imageCompiler = NotebookXPCWorker(serviceName: try service("NotebookMarkupService")) { _ in .init(code: "unexpected_host") }
      let rejectedImage = await imageCompiler.compile(.init(id: UUID(), source: "\\documentclass{article}\\begin{document}Image\\end{document}",
        assets: [.init(name: "notebook-image-0.pdf", mediaType: .svg, data: Data(svg.utf8))]))
      imageCompiler.invalidate()
      XCTAssertEqual(rejectedImage.code, "export_image_invalid", "Unsupported or external SVG content must fail explicitly: \(String(describing: rejectedImage.message))")
      XCTAssertNil(rejectedImage.value, "A missing image must never be published as a successful PDF.")
    }
    let user = NotebookXPCWorker(serviceName: try service("NotebookScriptService")) { _ in .init(code: "unexpected_host") }
    let rejected = await user.compile(.init(id: UUID(), source: "ignored"))
    user.invalidate()
    XCTAssertEqual(rejected.code, "compiler_unavailable")
  }

  func testCancelAndShutdownOwnAdmissionEvenWhenTheNativeReplyArrivesLate() async throws {
    for shutdown in [false, true] {
      let owner = try Owner(), host = try await coordinator(owner), id = UUID()
      defer { owner.releaseAdmission?.resume(); try? FileManager.default.removeItem(at: owner.store.root) }
      owner.holdAdmission = true
      let start = Task { try await host.handle(.init(op: .start, runID: id, apiVersion: 2,
        code: "return await nb.read({kind:'workspaceHeader'});")) }
      let deadline = ContinuousClock.now + .seconds(5)
      while !owner.admissionAccepted, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
      XCTAssertTrue(owner.admissionAccepted)
      var stopped = false
      let stop: Task<Void, Never>?
      if shutdown {
        stop = Task { await host.shutdown(); stopped = true }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(stopped, "Shutdown must wait for native admissions already in flight.")
      } else {
        stop = nil
        _ = try await host.handle(.init(op: .cancel, runID: id))
      }
      owner.releaseAdmission?.resume(); owner.releaseAdmission = nil
      _ = try await start.value
      await host.runningTask?.value
      await stop?.value
      XCTAssertEqual(try owner.store.scriptRun(id)?.state, .cancelled)
      XCTAssertEqual(owner.reads, 0, "A late queued snapshot must never restart cancelled JavaScript.")
      await host.shutdown()
    }
  }
}

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
      (root.appendingPathComponent("NotebookMarkupService.xpc/Contents/Helpers/notebook-typescript"),
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

  func testAddressedGraphReflowAndUndoCrossTheRealSandboxedSDK() async throws {
    let owner = try Owner(), host = try await coordinator(owner), run = UUID()
    defer { try? FileManager.default.removeItem(at: owner.store.root) }
    let pageID = try XCTUnwrap(owner.store.loadIndex().selectedPageID)
    var page = try owner.store.loadPage(pageID)
    let a = AgentElement(id: "a", kind: .graphic, frame: .init(x: 80, y: 80, width: 100, height: 100),
      source: "", html: "", graphic: .init(label: "A"))
    let b = AgentElement(id: "b", kind: .graphic, frame: .init(x: 420, y: 80, width: 100, height: 100),
      source: "", html: "", graphic: .init(label: "B"))
    let connection = NotebookGraphicConnection(
      start: .init(point: .zero, binding: .init(elementID: "a")),
      end: .init(point: .init(x: 100, y: 0), binding: .init(elementID: "b")))
    let arrow = AgentElement(id: "ab", kind: .graphic, frame: .init(x: 220, y: 130, width: 100, height: 10),
      source: "", html: "", graphic: .init(shape: .connector, label: "Before", connection: connection))
    XCTAssertTrue(page.replaceElements([a, b, arrow], actor: UUID()))
    try owner.store.savePage(page)
    _ = try await host.handle(.init(op: .start, runID: run, apiVersion: 2, code: """
      const target={kind:'page',id:args.page};
      const query={target,ids:['ab'],fields:['content','geometry'],expand:['outgoing']};
      const before=await nb.observe(query);
      if (!before.coverage.complete) throw new Error('Incomplete three-object graph');
      const nodes=before.data.objects.map(x=>x.value.content)
        .filter(x=>x.graphic.shape!=='connector').sort((a,b)=>a.id.localeCompare(b.id));
      if (nodes.length!==2) throw new Error('The bound endpoints were not addressed');
      const incoming=await nb.observe({target,ids:[nodes[0].id],expand:['incoming']});
      const center=nodes.reduce((sum,node)=>sum+node.frame.x+node.frame.width/2,0)/nodes.length;
      const top=Math.min(...nodes.map(node=>node.frame.y));
      const stride=Math.max(...nodes.map(node=>node.frame.height))+80;
      const operations=[{kind:'updateElement',target,id:'ab',values:{graphic:{
        label:nodes.map(node=>node.id).join(' → '),
        connection:{bend:Math.max(...nodes.map(node=>node.frame.width))/2,routing:'curved'}
      }}},...nodes.map((node,index)=>({kind:'updateElement',target,id:node.id,values:{frame:{
        ...node.frame,x:center-node.frame.width/2,y:top+index*stride
      }}}))];
      // Reading a graph grants a basis, not permission to rearrange it. The
      // earlier label edit must roll back with the later unauthorized move.
      let rejected;
      try { await nb.transaction('unscoped',{base:before.basis,summary:'No movement scope',operations}); }
      catch(error) { rejected=error.code; }
      const afterRejected=await nb.observe(query);
      const action={base:before.basis,summary:'Algorithmic graph reflow',additionalOwners:[target],operations};
      const receipt=await nb.transaction('reflow',action);
      const changed=await nb.observe({...query,since:before.data.checkpoint});
      const direct=await nb.page({id:args.page,elementID:'ab'});
      const undo=await nb.undo('undo-reflow',{actionID:receipt.actionID});
      const restored=await nb.observe(query);
      const originalAgain=await nb.transaction('reflow',action);
      return {before:before.data.objects,rejected,afterRejected:afterRejected.data.objects,
        incomingIDs:incoming.data.objects.map(x=>x.id),mode:changed.data.mode,
        changed:changed.data.objects,direct:direct.data,receipt,undo,
        restored:restored.data.objects,originalAgain};
      """, arguments: .object(["page": .string(pageID.uuidString)])))
    let result = try await finish(host, run)
    XCTAssertEqual(result.string("status"), "completed", "\(result)")
    let value = try XCTUnwrap(result["result"])
    XCTAssertEqual(Set(value.array("before").compactMap { $0.string("id") }), ["a", "b", "ab"])
    XCTAssertEqual(Set(try value["incomingIDs"]?.decode([String].self) ?? []), ["a", "ab"])
    XCTAssertEqual(value.string("rejected"), "composition_scope")
    XCTAssertEqual(value["afterRejected"], value["before"])
    XCTAssertEqual(value.string("mode"), "delta")
    XCTAssertEqual(Set(value.array("changed").compactMap { $0.string("id") }), ["a", "b", "ab"])
    for (id, y) in [("a", 80.0), ("b", 260.0)] {
      let node = try XCTUnwrap(value.array("changed").first { $0.string("id") == id }?["value"]?["content"])
      XCTAssertEqual(node["frame"], try .encode(PageRect(x: 250, y: y, width: 100, height: 100)))
    }
    let beforeArrow = try XCTUnwrap(value.array("before").first { $0.string("id") == "ab" }?["value"])
    let changedArrow = try XCTUnwrap(value.array("changed").first { $0.string("id") == "ab" }?["value"])
    let savedArrow = try XCTUnwrap(value["direct"]?["element"])
    XCTAssertEqual(savedArrow["frame"], try .encode(arrow.frame))
    XCTAssertEqual(savedArrow["graphic"]?["connection"]?["start"], try .encode(connection.start))
    XCTAssertEqual(savedArrow["graphic"]?["connection"]?["end"], try .encode(connection.end))
    XCTAssertEqual(savedArrow["graphic"]?.string("label"), "a → b")
    XCTAssertEqual(savedArrow["graphic"]?["connection"]?["bend"], .number(50))
    XCTAssertEqual(changedArrow["content"], savedArrow)
    XCTAssertEqual(changedArrow["graphicResolution"]?.string("state"), "geometry")
    XCTAssertEqual(changedArrow["graphicResolution"], value["direct"]?["graphicResolution"])
    XCTAssertNotEqual(changedArrow["graphicResolution"], beforeArrow["graphicResolution"])
    XCTAssertNotEqual(changedArrow["graphicResolution"]?["frame"], savedArrow["frame"])
    XCTAssertEqual(value["restored"], value["before"])
    XCTAssertEqual(value["receipt"]?["publication"]?.string("saved"), "confirmed")
    XCTAssertEqual(value["receipt"], value["originalAgain"])
    XCTAssertNotEqual(value["receipt"]?["actionVersion"], value["undo"]?["actionVersion"])
    XCTAssertEqual(value["undo"]?["undo"]?["preservedCount"], .number(0))
    let actionID = try XCTUnwrap(value["receipt"]?.string("actionID").flatMap(UUID.init(uuidString:)))
    let receipt = try owner.store.collaborationAction(actionID)
    XCTAssertEqual(receipt.action.operations.map(\.id), ["ab", "a", "b"])
    XCTAssertTrue((receipt.undo?.restored ?? 0) > 0)
    XCTAssertEqual(try owner.store.savedActionResult(actionID), value["receipt"])
    for element in [a, b, arrow] {
      XCTAssertEqual(try owner.store.readPageElement(pageID: pageID, elementID: element.id), element)
    }
    XCTAssertEqual(owner.nativeWrites, 2, "One atomic reflow, one undo, no rejected or replayed write")
    await host.shutdown()
  }

  func testJSAndTypeScriptAtomicallyCreateABoundGraphAndUndoIt() async throws {
    var createdGraphs: [[AgentElement]] = []
    for language in [NotebookScriptLanguage.javascript, .typescript] {
      let owner = try Owner(), host = try await coordinator(owner), run = UUID()
      defer { try? FileManager.default.removeItem(at: owner.store.root) }
      let pageID = try XCTUnwrap(owner.store.loadIndex().selectedPageID)
      let target = CollaborationTarget(kind: .page, id: pageID)
      let nodes = [
        AgentElement(id: "new-a", kind: .graphic, frame: .init(x: 50, y: 80, width: 100, height: 100),
          source: "", html: "", graphic: .init(label: "A")),
        AgentElement(id: "new-b", kind: .graphic, frame: .init(x: 400, y: 80, width: 100, height: 100),
          source: "", html: "", graphic: .init(label: "B")),
        AgentElement(id: "new-ab", kind: .graphic, frame: .init(x: 200, y: 130, width: 100, height: 10),
          source: "", html: "", graphic: .init(shape: .connector, label: "A → B", connection: .init(
            start: .init(point: .zero, binding: .init(elementID: "new-a")),
            end: .init(point: .init(x: 100, y: 0), binding: .init(elementID: "new-b"))))),
      ]
      let operations: [JSONValue] = try nodes.map { node in .object([
        "kind": .string("insertElement"), "target": try .encode(target), "id": .string(node.id),
        "values": .object(["kind": .string("graphic"), "source": .string(""),
          "frame": try .encode(node.frame), "graphic": try .encode(node.graphic)])]) }
      let encoded = String(decoding: try JSONEncoder().encode(operations), as: UTF8.self)
      let code = """
        const initial=await nb.page({id:'\(pageID.uuidString)'});
        const receipt=await nb.transaction('create-graph',{base:initial.basis,summary:'Create a connected graph',
          operations:\(encoded)});
        const graph=await nb.page({id:'\(pageID.uuidString)'});
        const undo=await nb.undo('remove-graph',{actionID:receipt.actionID});
        const empty=await nb.page({id:'\(pageID.uuidString)'});
        return {receipt,graph:graph.data,undo,empty:empty.data};
        """
      let request = NotebookScriptRequest(op: .start, runID: run, apiVersion: 2, code: code, language: language)
      _ = try await host.handle(request)
      let result = try await finish(host, run)
      XCTAssertEqual(result.string("status"), "completed", "\(result)")
      let value = try XCTUnwrap(result["result"])
      let elements = try XCTUnwrap(value["graph"]?["elements"]).decode([AgentElement].self)
      XCTAssertEqual(elements, nodes)
      createdGraphs.append(elements)
      let arrow = try XCTUnwrap(value["graph"]?.array("elements").first { $0.string("id") == "new-ab" })
      XCTAssertEqual(arrow["graphicResolution"]?.string("state"), "geometry")
      XCTAssertNotEqual(arrow["graphicResolution"]?["frame"], arrow["frame"])
      XCTAssertEqual(value["empty"]?.array("elements"), [])
      let actionID = try XCTUnwrap(value["receipt"]?.string("actionID").flatMap(UUID.init(uuidString:)))
      XCTAssertEqual(try owner.store.collaborationAction(actionID).action.operations.map(\.id), nodes.map(\.id))
      let replay = try await host.handle(request)
      XCTAssertEqual(replay["result"], result["result"])
      XCTAssertEqual(owner.nativeWrites, 2, "Three new bound objects share one write; undo shares one write; replay writes nothing")
      await host.shutdown()
    }
    XCTAssertEqual(createdGraphs.first, createdGraphs.last, "JS and TS produce the same domain objects in independent stores")
  }

  func testLifecycleRefusalAndRestoredAppendUndoCrossTheRealSDK() async throws {
    let owner = try Owner(), host = try await coordinator(owner), run = UUID()
    defer { try? FileManager.default.removeItem(at: owner.store.root) }
    let initial = try owner.store.workspaceHeader()
    let presence = SessionPresence(boardID: initial.rootBoardID, mode: .board,
      camera: .init(center: .init(x: 17, y: 29), scale: 0.7), viewport: .init(x: 834, y: 1194),
      selectedItemID: initial.selectedItemID, notebookPageID: initial.selectedPageID)
    try owner.store.savePresence(presence)
    let board = UUID(), notebook = UUID(), page = UUID()
    let code = """
      const rootID='\(initial.rootBoardID.uuidString)', boardID='\(board.uuidString)', notebookID='\(notebook.uuidString)';
      const root=await nb.board({id:rootID});
      await nb.transaction('board',{base:root.basis,summary:'Temporary child board',operations:[
        {kind:'createBoard',target:{kind:'board',id:rootID},id:boardID,values:{title:'Original board',center:{tileX:1,tileY:1,localX:0,localY:0}}}]});
      const child=await nb.board({id:boardID});
      await nb.transaction('notebook',{base:child.basis,summary:'Temporary notebook',operations:[
        {kind:'createNotebook',target:{kind:'board',id:boardID},id:notebookID,values:{title:'Own notebook',pageID:'\(page.uuidString)',center:{tileX:0,tileY:0,localX:0,localY:0}}}]});
      const extent=await nb.read({kind:'itemLifecycle',id:notebookID});
      const appendAction={base:extent.basis,summary:'Append before restored deletion',additionalOwners:[extent.data.target],
        operations:[{kind:'appendPage',target:extent.data.target,values:{}}]};
      const appended=await nb.transaction('append',appendAction);
      const parent=await nb.read({kind:'itemLifecycle',id:boardID});
      let refusal;
      try {
        await nb.transaction('nonempty',{base:parent.basis,summary:'Must atomically refuse',additionalOwners:[parent.data.target],operations:[
          {kind:'renameItem',target:{kind:'board',id:rootID},id:boardID,values:{title:'Must roll back'}},
          {kind:'deleteItem',target:parent.data.target,values:{}}]});
      } catch(error) { refusal={code:error.code,message:error.message,operation:error.operation}; }
      const unchanged=await nb.read({kind:'itemHeader',id:boardID});
      const first=await nb.read({kind:'itemLifecycle',id:notebookID});
      const deleted=await nb.transaction('delete-notebook',{base:first.basis,summary:'Delete child',additionalOwners:[first.data.target],
        operations:[{kind:'deleteItem',target:first.data.target,values:{}}]});
      await nb.undo('restore-notebook',{actionID:deleted.actionID});
      const tree=await nb.readMany({queries:[{kind:'itemLifecycle',id:notebookID},{kind:'itemLifecycle',id:boardID}]});
      const targets=tree.data.map(x=>x.target);
      const removed=await nb.transaction('delete-tree',{base:tree.basis,summary:'Explicit child before empty board',additionalOwners:targets,
        operations:targets.map(target=>({kind:'deleteItem',target,values:{}}))});
      await nb.undo('restore-tree',{actionID:removed.actionID});
      const undone=await nb.undo('undo-append',{actionID:appended.actionID});
      const directory=await nb.notebook({id:notebookID});
      const replay=await nb.transaction('append',appendAction);
      return {refusal,unchanged:unchanged.data,appended,undone,directory:directory.data,replay};
      """
    _ = try await host.handle(.init(op: .start, runID: run, apiVersion: 2, code: code))
    let result = try await finish(host, run)
    XCTAssertEqual(result.string("status"), "completed", "\(result)")
    let value = try XCTUnwrap(result["result"])
    XCTAssertEqual(value["refusal"]?["code"], .string("board_not_empty"))
    XCTAssertEqual(value["refusal"]?["operation"]?["index"], .number(1))
    XCTAssertEqual(value["unchanged"]?["title"], .string("Original board"))
    XCTAssertEqual(value["undone"]?["undo"]?["preservedCount"], .number(0))
    XCTAssertEqual(value["undone"]?.array("changed").first?["change"], .string("removePage"))
    XCTAssertEqual(value["directory"]?.array("pages").count, 1)
    XCTAssertEqual(value["appended"], value["replay"], "Replay keeps the original append result after undo")
    XCTAssertEqual(result.array("effects").filter { $0.string("state") == "notSaved" }.count, 1)
    XCTAssertEqual(owner.nativeWrites, 8, "Rejected rename/delete and replay never write")
    XCTAssertEqual(try owner.store.pageCount(in: notebook), 1)
    XCTAssertEqual(try owner.store.pageID(at: 0, in: notebook), page)
    XCTAssertEqual(try owner.store.workspaceHeader().selectedItemID, initial.selectedItemID)
    XCTAssertEqual(try owner.store.loadPresence(), presence)
    await host.shutdown()
  }

  func testExplicitConflictDeltaContinuationPreservesTheHumanLabel() async throws {
    let owner = try Owner(), host = try await coordinator(owner)
    defer { try? FileManager.default.removeItem(at: owner.store.root) }
    let pageID = try XCTUnwrap(owner.store.loadIndex().selectedPageID)
    var page = try owner.store.loadPage(pageID)
    let original = AgentElement(id: "shared-node", kind: .graphic, frame: .init(x: 80, y: 80, width: 120, height: 100),
      source: "", html: "", graphic: .init(label: "Before"))
    XCTAssertTrue(page.replaceElements([original], actor: UUID())); try owner.store.savePage(page)
    let readRun = UUID()
    _ = try await host.handle(.init(op: .start, runID: readRun, code: "return await nb.observe({target:{kind:'page',id:args.page},ids:['shared-node'],fields:['content']});",
      arguments: .object(["page": .string(pageID.uuidString)])))
    let initial = try await finish(host, readRun)
    XCTAssertEqual(initial.string("status"), "completed", "\(initial)")
    // This is a native human continuation between two program turns, not an
    // automatically refreshed base inside transaction admission.
    let human = AgentElement(id: original.id, kind: original.kind, frame: original.frame,
      source: original.source, html: original.html, graphic: .init(label: "Human revision"))
    XCTAssertTrue(page.replaceElements([human], actor: UUID())); try owner.store.savePage(page)
    let nextRun = UUID()
    _ = try await host.handle(.init(op: .start, runID: nextRun, code: """
      const target={kind:'page',id:args.page};
      let conflict;
      try { await nb.transaction('stale',{base:args.previous.basis,summary:'Stale write',operations:[
        {kind:'updateElement',target,id:'shared-node',values:{graphic:{label:'Must never save'}}}
      ]}); } catch(error) { conflict=error.code; }
      if(conflict!=='revision_conflict') throw new Error('Expected the stale base to fail');
      const delta=await nb.observe({target,ids:['shared-node'],fields:['content'],since:args.previous.data.checkpoint});
      const current=delta.data.objects.find(x=>x.id==='shared-node'&&x.change==='upsert').value.content;
      // The program chooses its merge only after inspecting the human delta.
      const receipt=await nb.transaction('continue',{base:delta.basis,summary:'Continue the human label',operations:[
        {kind:'updateElement',target,id:current.id,values:{graphic:{label:current.graphic.label+' — agent note'}}}
      ]});
      const changed=await nb.page({id:args.page,elementID:current.id});
      const undo=await nb.undo('undo-note',{actionID:receipt.actionID});
      return {conflict,delta:delta.data,changed:changed.data,receipt,undo};
      """, arguments: .object(["page": .string(pageID.uuidString), "previous": try XCTUnwrap(initial["result"])])))
    let final = try await finish(host, nextRun)
    XCTAssertEqual(final.string("status"), "completed", "\(final)")
    let value = try XCTUnwrap(final["result"])
    XCTAssertEqual(value.string("conflict"), "revision_conflict")
    XCTAssertEqual(value["delta"]?.string("mode"), "delta")
    XCTAssertEqual(value["delta"]?.array("objects").count, 1)
    XCTAssertEqual(value["delta"]?.array("objects").first?["value"]?["content"]?["graphic"]?.string("label"), "Human revision")
    XCTAssertEqual(value["changed"]?["element"]?["graphic"]?.string("label"), "Human revision — agent note")
    XCTAssertEqual(try owner.store.readPageElement(pageID: pageID, elementID: "shared-node"), human)
    XCTAssertEqual(owner.nativeWrites, 2, "The stale write has no effect; explicit continuation and undo are separate writes")
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

  func testDocumentSourceStructureStateAndUndoCrossTheRealSandboxedSDK() async throws {
    let owner = try Owner(), host = try await coordinator(owner), run = UUID()
    defer { try? FileManager.default.removeItem(at: owner.store.root) }
    let boardID = try owner.store.loadIndex().rootBoardID
    _ = try await host.handle(.init(op: .start, runID: run, apiVersion: 2, code: """
      const origin={tileX:0,tileY:0,localX:0,localY:0};
      const scene=await nb.board({id:args.board,bounds:{anchor:origin,
        region:{x:0,y:0,width:1200,height:1000}}});
      const documentID=await nb.id('document'), target={kind:'document',id:documentID};
      const created=await nb.transaction('create',{base:scene.basis,summary:'Create a real document',operations:[{
        kind:'createDocument',target:{kind:'board',id:args.board},id:documentID,values:{
          title:'Script lifecycle',center:{...origin,localX:700,localY:400},paperSize:'a4',preamble:'',blocks:[
            {id:'intro',kind:'markdown',source:'# Before'},
            {id:'counter',kind:'interactive',html:'<button>Count</button>',
              javaScript:'window.counter = 0;',initialState:{count:0},height:160}
          ]
        }
      }]});
      const original=await nb.document({id:documentID});
      const addressed=await nb.document({id:documentID,blockID:'counter'});
      const source=await nb.transaction('source',{base:addressed.basis,summary:'Edit source and structure',operations:[
        {kind:'updateBlock',target,id:'intro',values:{source:'# After'}},
        {kind:'insertBlock',target,id:'appendix',values:{kind:'markdown',source:'**Added**',afterID:'intro'}},
        {kind:'reorderBlocks',target,values:{ids:['counter','appendix','intro']}},
        {kind:'setPreamble',target,values:{preamble:'\\\\usepackage{amsmath}'}}
      ]});
      const afterSource=await nb.document({id:documentID});
      const beforeState=await nb.document({id:documentID,blockID:'counter'});
      const versions=beforeState.basis.owners.find(owner=>owner.target.kind==='document'&&owner.target.id.toLowerCase()===documentID.toLowerCase());
      if (!versions || !versions.revision || !versions.stateRevision) throw new Error('Missing source/state basis');
      const state=await nb.transaction('state',{base:beforeState.basis,summary:'Advance the program state',operations:[
        {kind:'setBlockState',target,id:'counter',values:{state:{count:7}}}
      ]});
      const afterState=await nb.document({id:documentID,blockID:'counter'});
      let stale;
      try { await nb.transaction('stale',{base:beforeState.basis,summary:'Reject all stale edits',operations:[
        {kind:'updateBlock',target,id:'intro',values:{source:'Must not be saved'}},
        {kind:'setBlockState',target,id:'counter',values:{state:{count:99}}}
      ]}); } catch(error) { stale=error.code; }
      const afterRejected=await nb.document({id:documentID});
      const rejectedState=await nb.document({id:documentID,blockID:'counter'});
      const undoSource=await nb.undo('undo-source',{actionID:source.actionID});
      const restoredSource=await nb.document({id:documentID});
      const retainedState=await nb.document({id:documentID,blockID:'counter'});
      const undoState=await nb.undo('undo-state',{actionID:state.actionID});
      const finalState=await nb.document({id:documentID,blockID:'counter'});
      return {documentID,created,source,state,versions,original:original.data,afterSource:afterSource.data,
        beforeState:beforeState.data,afterState:afterState.data,stale,afterRejected:afterRejected.data,
        rejectedState:rejectedState.data,undoSource,restoredSource:restoredSource.data,
        retainedState:retainedState.data,undoState,finalState:finalState.data};
      """, arguments: .object(["board": .string(boardID.uuidString.lowercased())])))
    let result = try await finish(host, run)
    XCTAssertEqual(result.string("status"), "completed", "\(result)")
    let value = try XCTUnwrap(result["result"])
    XCTAssertEqual(value["afterSource"]?.array("blocks").compactMap { $0.string("id") }, ["counter", "appendix", "intro"])
    XCTAssertEqual(value["afterSource"]?.array("blocks").first { $0.string("id") == "intro" }?.string("source"), "# After")
    XCTAssertEqual(value["afterSource"]?.string("preamble"), "\\usepackage{amsmath}")
    let appendix = try XCTUnwrap(value["afterSource"]?.array("blocks").first { $0.string("id") == "appendix" })
    // Document markdown owns source, unlike a prepared page AgentElement.
    // Its HTML belongs to the live document renderer, not a second saved copy.
    XCTAssertEqual(appendix.string("kind"), "markdown")
    XCTAssertEqual(appendix.string("source"), "**Added**")
    XCTAssertEqual(appendix.string("html"), "")
    XCTAssertEqual(value["afterState"]?["block"], value["beforeState"]?["block"])
    XCTAssertEqual(value["afterState"]?["state"], .object(["count": .number(7)]))
    XCTAssertEqual(value["afterState"]?["contentStamp"], value["beforeState"]?["contentStamp"])
    XCTAssertNotEqual(value["afterState"]?["stateStamp"], value["beforeState"]?["stateStamp"])
    XCTAssertNotNil(value["versions"]?.string("revision"))
    XCTAssertNotNil(value["versions"]?.string("stateRevision"))
    XCTAssertEqual(value.string("stale"), "revision_conflict")
    XCTAssertEqual(value["afterRejected"], value["afterSource"])
    XCTAssertEqual(value["rejectedState"], value["afterState"])
    XCTAssertEqual(value["restoredSource"]?["blocks"], value["original"]?["blocks"])
    XCTAssertEqual(value["restoredSource"]?["preamble"], value["original"]?["preamble"])
    XCTAssertEqual(value["retainedState"]?["state"], .object(["count": .number(7)]))
    XCTAssertEqual(value["finalState"]?["state"], .object(["count": .number(0)]))
    for key in ["created", "source", "state", "undoSource", "undoState"] {
      XCTAssertEqual(value[key]?["publication"]?.string("saved"), "confirmed")
    }
    XCTAssertEqual(value["undoSource"]?["undo"]?["preservedCount"], .number(0))
    XCTAssertEqual(value["undoState"]?["undo"]?["preservedCount"], .number(0))
    let documentID = try XCTUnwrap(value.string("documentID").flatMap(UUID.init(uuidString:)))
    let document = try owner.store.loadDocument(documentID)
    XCTAssertEqual(try owner.store.readItemHeader(documentID)?.kind, .document)
    XCTAssertEqual(try owner.store.ownerBoardID(of: documentID), boardID)
    XCTAssertEqual(document.blocks.map(\.id), ["intro", "counter"])
    XCTAssertEqual(document.blocks.first?.source, "# Before")
    XCTAssertEqual(document.preamble, "")
    XCTAssertEqual(try owner.store.loadDocumentState(documentID).value(for: "counter"), .object(["count": .number(0)]))
    XCTAssertEqual(owner.nativeWrites, 5, "Create, source, state and their two inverses; the stale action saves nothing")
    await host.shutdown()
  }

  func testHumanPageInkDiscoveryConversionAndUndoCrossTheRealSDK() async throws {
    let owner = try Owner(), host = try await coordinator(owner), run = UUID()
    defer { try? FileManager.default.removeItem(at: owner.store.root) }
    let pageID = try XCTUnwrap(owner.store.loadIndex().selectedPageID)
    var page = try owner.store.loadPage(pageID)
    let stroke = PageInkAction(tool: .pen, samples: [(80.0, 80.0), (180, 80), (180, 180), (80, 180), (80, 80)].enumerated().map { index, point in
      .init(point: .init(x: point.0, y: point.1), timeOffset: Double(index) / 120,
        width: 2, opacity: 1, force: 0.5, azimuth: 0, altitude: 1)
    })
    let drawing = try PageInkDrawing().appending(stroke)
    XCTAssertTrue(page.replaceDrawing(try drawing.dataRepresentation(), actor: UUID()))
    try owner.store.savePage(page)
    _ = try await host.handle(.init(op: .start, runID: run, apiVersion: 2, code: """
      const target={kind:'page',id:args.page};
      const directory=await nb.read({kind:'pageInkActions',id:args.page,limit:8});
      if(!directory.coverage.complete) throw new Error('Incomplete source fixture');
      const selected=directory.data.actions.find(a=>a.tool==='pen'&&a.isActive);
      const source=await nb.read({kind:'pageInkAction',id:args.page,elementID:selected.id});
      const points=source.data.action.samples.map(sample=>sample.point);
      const x=Math.min(...points.map(p=>p.x)), y=Math.min(...points.map(p=>p.y));
      const converted=await nb.transaction('convert',{base:source.basis,summary:'Convert discovered source',additionalOwners:[target],operations:[{
        kind:'convertInkToElement',target,id:'from-human',values:{kind:'graphic',source:'',
          frame:{x,y,width:Math.max(...points.map(p=>p.x))-x,height:Math.max(...points.map(p=>p.y))-y},
          graphic:{shape:'rectangle',label:'',style:{stroke:{red:0,green:0,blue:0},strokeWidth:2},
            representation:'geometry',visible:true,sourceInkIDs:[selected.id]}}
      }]});
      const graphic=await nb.page({id:args.page,elementID:'from-human'});
      const edit=await nb.transaction('label',{base:graphic.basis,summary:'Explain the figure',operations:[{
        kind:'updateElement',target,id:'from-human',values:{graphic:{label:'Native source'}}
      }]});
      const edited=await nb.page({id:args.page,elementID:'from-human'});
      const undoEdit=await nb.undo('undo-label',{actionID:edit.actionID});
      const undoConversion=await nb.undo('undo-conversion',{actionID:converted.actionID});
      const retained=await nb.read({kind:'pageInkAction',id:args.page,elementID:selected.id});
      const restored=await nb.page({id:args.page,elementID:'from-human'});
      return {directory:directory.data,source:source.data,converted,edited:edited.data,undoEdit,undoConversion,
        retained:retained.data,restored:restored.data};
      """, arguments: .object(["page": .string(pageID.uuidString)])))
    let result = try await finish(host, run)
    XCTAssertEqual(result.string("status"), "completed", "\(result)")
    let value = try XCTUnwrap(result["result"])
    XCTAssertEqual(value["directory"]?.array("actions").first?.string("id")?.lowercased(), stroke.id.uuidString.lowercased())
    XCTAssertNil(value["directory"]?.array("actions").first?["samples"])
    XCTAssertEqual(value["source"]?["action"], value["retained"]?["action"])
    XCTAssertEqual(try value["source"]?["action"]?.decode(PageInkAction.self), drawing.actions.first)
    XCTAssertEqual(value["edited"]?["element"]?["graphic"]?.string("label"), "Native source")
    XCTAssertEqual(value["restored"]?["element"]?["graphic"]?.string("representation"), "ink")
    XCTAssertEqual(value["converted"]?["publication"]?.string("saved"), "confirmed")
    XCTAssertEqual(try owner.store.loadPage(pageID).drawingData, page.drawingData)
    XCTAssertEqual(owner.nativeWrites, 4)
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
    let actor = UUID()
    var index = try owner.store.loadIndex(), board = try owner.store.loadBoard(items: index.items)
    let independentPageID = try XCTUnwrap(index.selectedPageID)
    let item = index.createDocument(title: "Actual PDF", actor: actor, documentID: document.id)
    XCTAssertNotNil(item)
    XCTAssertTrue(board.addItem(document.id, to: index.rootBoardID, near: .init(x: 900, y: 450), actor: actor))
    try owner.store.saveDocumentWorkspaceBundle(index: index, document: document,
      state: .init(id: document.id, actor: actor), board: board)
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
    _ = try await host.handle(.init(op: .start, runID: another, apiVersion: 2, code: """
      const page=await nb.read({kind:'pageHeader',id:args.page});
      return await nb.transaction('during-export',{base:page.basis,summary:'Write while PDF publication waits',operations:[
        {kind:'insertElement',target:{kind:'page',id:args.page},id:'during-export',values:{
          kind:'markdown',source:'**Writer available**',frame:{x:20,y:20,width:260,height:120}
        }}
      ]});
      """, arguments: .object(["page": .string(independentPageID.uuidString)])))
    let independent = try await finish(host, another)
    XCTAssertEqual(independent.string("status"), "completed", "\(independent)")
    XCTAssertEqual(independent["result"]?["publication"]?.string("saved"), "confirmed")
    let independentElement = try XCTUnwrap(owner.store.readPageElement(pageID: independentPageID, elementID: "during-export"))
    XCTAssertEqual(independentElement.source, "**Writer available**")
    XCTAssertTrue(independentElement.html.contains("<strong>Writer available</strong>"))
    XCTAssertEqual(owner.nativeWrites, 1, "A real native page commit completed before releasing PDF publication")
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

  func testPinnedTypeScriptCLICompilesInsideTheSignedSandboxBeforePublicAdmission() async throws {
    try await requireRestrictedServiceSignatures()
    let resources = Bundle.main.bundleURL.appendingPathComponent("Contents/XPCServices/NotebookMarkupService.xpc/Contents/Resources/NotebookTypeScript")
    let manifest = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: resources.appendingPathComponent("manifest.json")))
    let version = try XCTUnwrap(manifest.string("compilerVersion")), sdk = try XCTUnwrap(manifest.string("sdkVersion"))
    XCTAssertEqual(version, "7.0.2")
    for index in 0..<2 {
      let compiler = NotebookXPCWorker(serviceName: try service("NotebookMarkupService")) { _ in .init(code: "unexpected_host") }
      let prepared = await compiler.compileTypeScript(.init(id: UUID(), source: "const value: NotebookSDK.JSONValue = {count: 2}; return value;", compilerVersion: version, sdkVersion: sdk))
      compiler.invalidate()
      XCTAssertNil(prepared.code, prepared.message ?? "compiler failure")
      let value = try JSONDecoder().decode(NotebookTypeScriptResult.self, from: XCTUnwrap(prepared.value))
      XCTAssertGreaterThan(value.peakResidentBytes, 0)
      XCTAssertLessThanOrEqual(value.peakResidentBytes, 512*1024*1024)
      XCTAssertLessThan(value.wallMilliseconds, 10_000)
      print("TypeScript signed CLI attempt=\(index) wall_ms=\(value.wallMilliseconds) sampled_peak_rss=\(value.peakResidentBytes) sampled_cpu_ns=\(value.cpuNanoseconds)")
      let interpreter = NotebookXPCWorker(serviceName: try service("NotebookScriptService")) { _ in .init(code: "unexpected_host") }
      let executed = await interpreter.execute(.init(id: UUID(), code: value.javaScript, arguments: Data("null".utf8)))
      interpreter.invalidate()
      XCTAssertNil(executed.code, executed.message ?? "JS failure")
      XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(executed.value)), .object(["count": .number(2)]))
    }
    for source in ["const n: number = 'wrong'; await emit(n);", "const p:string = '/private/canary'; await import(p);"] {
      let compiler = NotebookXPCWorker(serviceName: try service("NotebookMarkupService")) { _ in .init(code: "unexpected_host") }
      let reply = await compiler.compileTypeScript(.init(id: UUID(), source: source, compilerVersion: version, sdkVersion: sdk))
      compiler.invalidate()
      XCTAssertEqual(reply.code, "typescript_diagnostic", reply.message ?? "")
      XCTAssertNil(reply.value); XCTAssertTrue(reply.message?.contains("notebook-user.ts(1,") == true)
    }
    let user = NotebookXPCWorker(serviceName: try service("NotebookScriptService")) { _ in .init(code: "unexpected_host") }
    let refused = await user.compileTypeScript(.init(id: UUID(), source: "return 1", compilerVersion: version, sdkVersion: sdk))
    user.invalidate(); XCTAssertEqual(refused.code, "compiler_unavailable")
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
  func testTypeScriptEditsThePublishedSelectionBeyondThePreviewWindow() async throws {
    let owner = try Owner(), host = try await coordinator(owner), id = UUID()
    defer { try? FileManager.default.removeItem(at: owner.store.root) }
    let pageID = try XCTUnwrap(owner.store.loadIndex().selectedPageID)
    var page = try owner.store.loadPage(pageID)
    page.replaceElements((0..<40).map { .init(id: "node-\($0)", kind: .graphic,
      frame: .init(x: 20, y: 20, width: 100, height: 100), source: "", html: "",
      graphic: .init(shape: .ellipse, label: "label-\($0)")) }, actor: UUID())
    try owner.store.savePage(page)
    let device = UUID(), connection = UUID(), target = CollaborationTarget(kind: .page, id: pageID)
    try owner.store.beginSelectionPublication(deviceID: device, connectionID: connection)
    try owner.store.acceptSelectionPublication(.init(deviceID: device, sessionID: UUID(), sequence: 1,
      selection: .init(id: UUID(), kind: .element, surface: target, target: target, elementID: "node-39")), connectionID: connection)
    _ = try await host.handle(.init(op: .start, runID: id, code: """
      const snapshot = await nb.observe();
      const choice = snapshot.data.selection;
      if (!choice || choice.status !== 'known' || choice.selection.kind !== 'element') throw new Error('Unknown selection');
      const selected = choice.selection;
      return await nb.transaction('selected-label', {base:snapshot.basis, summary:'Change the actual selection', operations:[
        {kind:'updateElement', target:selected.target, id:selected.elementID, values:{graphic:{label:'Обратная связь'}}}
      ]});
      """, language: .typescript))
    let result = try await finish(host, id)
    XCTAssertEqual(result.string("status"), "completed", "\(result)")
    XCTAssertEqual(result["result"]?["publication"]?.string("saved"), "confirmed")
    XCTAssertEqual(try owner.store.readPageElement(pageID: pageID, elementID: "node-39")?.graphic?.label, "Обратная связь")
    XCTAssertEqual(try owner.store.readPageElement(pageID: pageID, elementID: "node-0")?.graphic?.label, "label-0")
    XCTAssertEqual(owner.nativeWrites, 1)
    await host.shutdown()
  }

  func testTypeScriptTypeFailurePreventsEvenEarlierNativeEffects() async throws {
    let owner = try Owner(), host = try await coordinator(owner), id = UUID()
    defer { try? FileManager.default.removeItem(at: owner.store.root) }
    _ = try await host.handle(.init(op: .start, runID: id, code: """
      await emit('must not execute');
      const snapshot = await nb.read({kind:'workspaceHeader'});
      const wrong: number = 'not a number';
      return snapshot;
      """, language: .typescript))
    let result = try await finish(host, id)
    XCTAssertEqual(result.string("status"), "failed")
    XCTAssertEqual(result["error"]?.string("code"), "typescript_diagnostic", "\(result)")
    XCTAssertTrue(result["error"]?.string("message")?.contains("notebook-user.ts(3,") == true)
    XCTAssertEqual(result.array("events").count, 0)
    XCTAssertEqual(result.array("effects").count, 0)
    XCTAssertEqual(owner.reads, 0); XCTAssertEqual(owner.nativeWrites, 0)
    await host.shutdown()
  }

  func testEquivalentTypedAndJavaScriptProgramsUseTheSameDomainWriterAndNeverReplay() async throws {
    for language in [NotebookScriptLanguage.javascript, .typescript] {
      let owner = try Owner(), host = try await coordinator(owner), id = UUID()
      defer { try? FileManager.default.removeItem(at: owner.store.root) }
      let pageID = try XCTUnwrap(owner.store.loadIndex().selectedPageID)
      let input = language == .typescript ? "const input = args as {page:string}; const label: string = 'Typed SDK';" : "const input = args; const label = 'Typed SDK';"
      let code = input + """
        const s=await nb.page({id:input.page});
        return await nb.transaction('write',{base:s.basis,summary:'Equivalent program',operations:[
          {kind:'insertElement',target:{kind:'page',id:input.page},id:'typed-proof',values:{
            kind:'markdown',source:'# '+label,frame:{x:20,y:20,width:260,height:120}}}
        ]});
        """
      let request = NotebookScriptRequest(op: .start, runID: id, code: code,
        arguments: .object(["page": .string(pageID.uuidString)]), language: language)
      _ = try await host.handle(request)
      let result = try await finish(host, id)
      XCTAssertEqual(result.string("status"), "completed", "\(result)")
      XCTAssertEqual(result["result"]?["publication"]?.string("saved"), "confirmed")
      let element = try XCTUnwrap(owner.store.readPageElement(pageID: pageID, elementID: "typed-proof"))
      XCTAssertEqual(element.source, "# Typed SDK"); XCTAssertTrue(element.html.contains("Typed SDK"))
      XCTAssertEqual(owner.nativeWrites, 1)
      let saved = try XCTUnwrap(owner.store.scriptRun(id))
      XCTAssertEqual(saved.code, code); XCTAssertEqual(saved.language, language)
      if language == .typescript { XCTAssertEqual(saved.compilerVersion, "7.0.2"); XCTAssertEqual(saved.sdkVersion?.count, 64) }
      await host.shutdown()
      // Unavailable executors must not matter when attaching to an existing run.
      let restarted = NotebookScriptCoordinator(command: { try await owner.command($0) },
        persistence: { operation in try await owner.persist(operation) }, workingDirectory: owner.store.root,
        userServiceName: "unavailable.user.service", markupServiceName: "unavailable.compiler.service")
      let retry = try await restarted.handle(request)
      XCTAssertEqual(retry["result"], result["result"]); XCTAssertEqual(owner.nativeWrites, 1)
      await restarted.shutdown()
    }
  }

  func testTypeScriptRuntimeStackNamesTheOriginalSource() async throws {
    let owner = try Owner(), host = try await coordinator(owner), id = UUID()
    defer { try? FileManager.default.removeItem(at: owner.store.root) }
    _ = try await host.handle(.init(op: .start, runID: id,
      code: "const n: number = 2;\nawait emit(n);\nthrow new Error('original runtime line');", language: .typescript))
    let result = try await finish(host, id)
    XCTAssertEqual(result.string("status"), "failed", "\(result)")
    XCTAssertTrue(result["error"]?.string("message")?.contains("notebook-user.ts:3:") == true, "\(result)")
    XCTAssertEqual(result.array("events").first?["value"], .number(2))
    await host.shutdown()
  }

  func testCancellationDuringTypeScriptPreparationNeverStartsJavaScript() async throws {
    let owner = try Owner(), host = try await coordinator(owner), id = UUID()
    defer { try? FileManager.default.removeItem(at: owner.store.root) }
    // Emit is first at runtime but the entire large typed body must be checked
    // before any user execution. Unit coverage separately cancels an actual PID.
    let source = "await emit('must not run'); const values: number[] = ["
      + String(repeating: "1234,", count: 40_000) + "]; return values.length;"
    _ = try await host.handle(.init(op: .start, runID: id, code: source, language: .typescript, waitMilliseconds: 0))
    let deadline = ContinuousClock.now + .seconds(5)
    while host.worker == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
    XCTAssertNotNil(host.worker, "Cancellation must exercise the active preparation, not only the queued state")
    _ = try await host.handle(.init(op: .cancel, runID: id))
    let cancelled = try await finish(host, id)
    XCTAssertEqual(cancelled.string("status"), "cancelled", "\(cancelled)")
    XCTAssertEqual(cancelled["error"]?.string("code"), "run_cancelled")
    XCTAssertTrue(cancelled.array("events").isEmpty); XCTAssertTrue(cancelled.array("effects").isEmpty)
    try await Task.sleep(for: .milliseconds(250))
    let late = try await host.handle(.init(op: .resume, runID: id, waitMilliseconds: 0))
    XCTAssertEqual(late, cancelled, "A late reply must neither emit nor revive the run")
    XCTAssertEqual(owner.nativeWrites, 0)
    await host.shutdown()
  }

  func testTypeScriptPreparationCoexistsWithMarkupAndPDFConnections() async throws {
    try await requireRestrictedServiceSignatures()
    let identity = try XCTUnwrap(NotebookTypeScriptPreparation.bundledIdentity)
    let name = try service("NotebookMarkupService")
    let typed = NotebookXPCWorker(serviceName: name) { _ in .init(code: "unexpected_host") }
    let printer = NotebookXPCWorker(serviceName: name) { _ in .init(code: "unexpected_host") }
    let parser = NotebookMarkupQueue(serviceName: name)
    defer { typed.invalidate(); printer.invalidate() }
    let source = "const values: number[] = [" + String(repeating: "1234,", count: 30_000) + "]; return values.length;"
    async let compilation = typed.compileTypeScript(.init(id: UUID(), source: source,
      compilerVersion: identity.compilerVersion, sdkVersion: identity.sdkVersion))
    async let pdf = printer.compile(.init(id: UUID(), source: "\\documentclass{article}\\begin{document}Independent PDF\\end{document}"))
    async let markup = parser.normalize(.object(["kind": .string("action"), "preparation": .object([
      "action": .object(["operations": .array([.object(["values": .object(["source": .string("**Independent markup**")])])])]),
      "markdownOperations": .array([.number(0)])])]))
    let (prepared,printed,normalized) = try await (compilation,pdf,markup)
    XCTAssertNil(prepared.code, prepared.message ?? "TypeScript failure")
    XCTAssertNotNil(prepared.value)
    XCTAssertNil(printed.code, printed.message ?? "PDF failure")
    let document = try JSONDecoder().decode(NotebookCompilerResult.self, from: XCTUnwrap(printed.value))
    XCTAssertEqual(PDFDocument(data: document.pdf)?.pageCount, 1)
    XCTAssertTrue(normalized.array("operations").first?["values"]?.string("html")?.contains("<strong>Independent markup</strong>") == true)
  }
}

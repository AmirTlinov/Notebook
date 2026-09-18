import Foundation
import CryptoKit
import Testing
@testable import NotebookCore
@testable import NotebookScriptHost

@MainActor @Suite("Selection and historical message sources", .serialized)
struct NotebookSelectionReadTests {
  func host(_ owner: NotebookSDKV2ReadTests.Owner) -> NotebookScriptCoordinator {
    .init(command: { try await owner.read($0) }, persistence: { try await owner.persist($0) },
      workingDirectory: owner.store.root.appendingPathComponent("derived/script-runtime"))
  }

  @Test func persistedCameraIsNotEvidenceOfASelection() async throws {
    let owner = try NotebookSDKV2ReadTests.Owner(), coordinator = host(owner)
    defer { try? FileManager.default.removeItem(at: owner.store.root) }
    let value = try await coordinator.context(.init(method: "read", arguments: .object(["kind": .string("selection")])))
    #expect(value["data"]?["status"] == .string("unknown"))
    #expect(value["basis"]?["owners"] == .array([]))
    let image = try await coordinator.context(.init(method: "observe", arguments: .object(["includeImage": .bool(true)])))
    #expect(image["data"]?["visual"]?["status"] == .string("current_scene_unknown"))
    #expect(image["data"]?["visual"]?["artifact"] == nil)
  }

  @Test func historicalContextDoesNotBorrowTheCurrentCameraOrPixels() async throws {
    let owner = try NotebookSDKV2ReadTests.Owner(), coordinator = host(owner)
    defer { try? FileManager.default.removeItem(at: owner.store.root) }
    let pageID = try #require(owner.store.loadIndex().selectedPageID)
    let target = CollaborationTarget(kind: .page, id: pageID)
    let reference = CollaborationReference(target: target, revision: try owner.store.referenceRevision(target: target))
    let old = try owner.store.appendContext(references: [reference], author: .human, actor: UUID())
    let board = try owner.store.workspaceHeader().rootBoardID
    try owner.store.savePresence(.init(boardID: board, mode: .board, camera: .init(center: .init(x: 5000, y: 6000), scale: 2),
      viewport: .init(x: 834, y: 1194)))
    let value = try await coordinator.context(.init(method: "observe", arguments: .object([
      "contextID": .string(old.id.uuidString), "includeImage": .bool(true)])))
    #expect(value["data"]?["context"] != nil)
    #expect(value["data"]?["target"] == nil, "Historical context must not silently address the new camera's board")
    #expect(value["data"]?["visual"]?["status"] == .string("source_reference_required"))
    #expect(value["data"]?["visual"]?["artifact"] == nil)
    #expect(value["basis"]?["owners"] == .array([]), "Historical sources must be reread explicitly before changing today's content")
  }

  @Test func currentViewReceiptCannotCrossANewerSelectedSurfaceOrDisconnect() async throws {
    let owner = try NotebookSDKV2ReadTests.Owner(), coordinator = host(owner)
    defer { try? FileManager.default.removeItem(at: owner.store.root) }
    let store = owner.store, header = try store.workspaceHeader()
    let presence = SessionPresence(boardID: header.rootBoardID, mode: .board, camera: .init(), viewport: .init(x: 834, y: 1194))
    try store.savePresence(presence)
    let receipt = try CurrentViewReceipt(workspaceStamp: header.stamp, boardRevision: #require(header.boardRevision),
      spatialInkStamp: #require(header.spatialInkStamp), presence: presence, renderViewport: presence.viewport,
      surface: .board(boardID: header.rootBoardID), pngSHA256: String(repeating: "a", count: 64))
    try FileManager.default.createDirectory(at: store.currentViewRevisionURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(receipt).write(to: store.currentViewRevisionURL)
    let device = UUID(), connection = UUID(), session = UUID()
    try store.beginSelectionPublication(deviceID: device, connectionID: connection)
    func publish(_ sequence: UInt64, surface: CollaborationTarget) throws {
      try store.acceptSelectionPublication(.init(deviceID: device, sessionID: session, sequence: sequence,
        selection: .init(id: UUID(), kind: .empty, surface: surface)), connectionID: connection)
    }
    let args = JSONValue.object(["includeImage": .bool(true)])
    try publish(1, surface: .init(kind: .board, id: header.rootBoardID))
    let matching = try await coordinator.context(.init(method: "observe", arguments: args))
    #expect(matching["data"]?["visual"]?["status"] == .string("ready"))
    try publish(2, surface: .init(kind: .page, id: #require(store.readItemHeaders(limit: 1).first?.firstPageID)))
    let newer = try await coordinator.context(.init(method: "observe", arguments: args))
    #expect(newer["data"]?["visual"]?["status"] == .string("pending"))
    #expect(newer["data"]?["visual"]?["artifact"] == nil)
    try store.endSelectionPublication(deviceID: device, connectionID: connection)
    let disconnected = try await coordinator.context(.init(method: "observe", arguments: args))
    #expect(disconnected["data"]?["visual"]?["status"] == .string("current_scene_unknown"))
    #expect(disconnected["data"]?["visual"]?["artifact"] == nil)
  }

  @Test func actualSelectionBeyondPreviewWindowReadsOnlyThatElement() async throws {
    let owner = try NotebookSDKV2ReadTests.Owner(), coordinator = host(owner)
    defer { try? FileManager.default.removeItem(at: owner.store.root) }
    let pageID = try #require(owner.store.loadIndex().selectedPageID)
    var page = try owner.store.loadPage(pageID)
    let replaced = page.replaceElements((0..<40).map { .init(id: "element-\($0)", kind: .markdown,
      frame: .init(x: 0, y: 0, width: 100, height: 100), source: "source-\($0)", html: "<p>\($0)</p>") }, actor: UUID())
    #expect(replaced)
    try owner.store.savePage(page)
    let target = CollaborationTarget(kind: .page, id: pageID), device = UUID(), connection = UUID()
    let selected = NotebookSelection(id: UUID(), kind: .element, surface: target, target: target, elementID: "element-39")
    try owner.store.beginSelectionPublication(deviceID: device, connectionID: connection)
    #expect(try owner.store.acceptSelectionPublication(.init(deviceID: device, sessionID: UUID(), sequence: 7, selection: selected), connectionID: connection))
    try owner.store.commandTransaction {
      try owner.store.currentSQL!.run("UPDATE blobs SET data=? WHERE hash=(SELECT hash FROM records WHERE address=?)",
        [.blob(Data("unrequested body must not decode".utf8)), .text(pageFile(pageID) + "#/elements/@element-0")])
    }
    let value = try await coordinator.context(.init(method: "observe"))
    #expect(value["data"]?["selection"]?["status"] == .string("known"))
    #expect(value["data"]?["selection"]?["selection"]?["id"] == .string(selected.id.uuidString))
    #expect(value["data"]?["objects"]?.array.count == 1)
    #expect(value["data"]?["objects"]?.array.first?["id"] == .string("element-39"))
    #expect(value["data"]?["objects"]?.array.first?["value"]?["content"]?["source"] == .string("source-39"))
    #expect(value["coverage"]?["complete"] == .bool(true))
    let explicit = try await coordinator.context(.init(method: "observe", arguments: .object([
      "target": try .encode(target), "elementID": .string("element-38")])))
    #expect(explicit["data"]?["objects"]?.array.first?["id"] == .string("element-38"))
    #expect(explicit["data"]?["selection"] == nil, "An explicit address is not rewritten by the current selection")
  }

  @Test func selectedSetReadsOnlyItsExactMembers() async throws {
    let owner = try NotebookSDKV2ReadTests.Owner(), coordinator = host(owner)
    defer { try? FileManager.default.removeItem(at:owner.store.root) }
    let pageID = try #require(owner.store.loadIndex().selectedPageID)
    var page = try owner.store.loadPage(pageID)
    page.replaceElements((0..<40).map { .init(id:"e-\($0)",kind:.markdown,frame:.init(x:0,y:0,width:100,height:100),source:"source-\($0)",html:"<p>Text</p>") },actor:UUID())
    try owner.store.savePage(page)
    let target = CollaborationTarget(kind:.page,id:pageID), device = UUID(), connection = UUID()
    let selected = NotebookSelection(id:UUID(),kind:.elements,surface:target,target:target,elementIDs:["e-35","e-39"])
    #expect(selected.isValid)
    try owner.store.beginSelectionPublication(deviceID:device,connectionID:connection)
    #expect(try owner.store.acceptSelectionPublication(.init(deviceID:device,sessionID:UUID(),sequence:1,selection:selected),connectionID:connection))
    let value = try await coordinator.context(.init(method:"observe"))
    #expect(Set(value["data"]?["objects"]?.array.compactMap { $0["id"]?.string } ?? []) == ["e-35","e-39"])
    #expect(value["data"]?["selection"]?["selection"]?["kind"] == .string("elements"))
    #expect(value["coverage"]?["complete"] == .bool(true))
  }

  @Test(arguments: [false, true])
  func messageEvidenceKeepsExactSourceOrExplicitMissingPixels(hasPixels: Bool) async throws {
    let owner = try NotebookSDKV2ReadTests.Owner(), coordinator = host(owner)
    defer { try? FileManager.default.removeItem(at: owner.store.root) }
    let pageID = try #require(owner.store.loadIndex().selectedPageID), target = CollaborationTarget(kind: .page, id: pageID)
    let files = try owner.store.referenceSourceFiles(target: target)
    let reference = CollaborationReference(target: target, region: .init(x: 0, y: 0, width: 120, height: 120),
      revision: try NotebookStore.referenceRevision(target: target, files: files))
    let context = try owner.store.appendContext(references: [reference], author: .human, actor: UUID())
    let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="))
    let hash = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
    let pixels = try AgentPinnedImage(referenceID: reference.id, sourceRevision: reference.revision,
      region: reference.region!, worldOrigin: nil, pageIndex: nil, pixelWidth: 1, pixelHeight: 1,
      pixelsPerPoint: 1.0 / 120, png: png, sha256: hash)
    let source = try AgentPinnedSource.capture(requestID: context.id, reference: reference, files: files)
      .withVisual(hasPixels ? pixels : nil, unavailable: "original_pixels_unavailable")
    try owner.store.saveAttentionEvidence([source], contextID: context.id)
    var page = try owner.store.loadPage(pageID)
    page.replaceElements([.init(id: "later", kind: .markdown, frame: .init(x: 0, y: 0, width: 100, height: 100),
      source: "Later human content", html: "<p>Later</p>")], actor: UUID())
    try owner.store.savePage(page)
    let board = try owner.store.workspaceHeader().rootBoardID
    try owner.store.savePresence(.init(boardID: board, mode: .board, camera: .init(center: .init(x: 700, y: -700), scale: 2),
      viewport: .init(x: 834, y: 1194)))
    let device = UUID(), connection = UUID()
    try owner.store.beginSelectionPublication(deviceID: device, connectionID: connection)
    try owner.store.acceptSelectionPublication(.init(deviceID: device, sessionID: UUID(), sequence: 1,
      selection: .init(id: UUID(), kind: .empty, surface: .init(kind: .board, id: board))), connectionID: connection)
    let value = try await coordinator.context(.init(method: "attention", arguments: .object([
      "contextID": .string(context.id.uuidString), "referenceID": .string(reference.id.uuidString)])))
    #expect(value["data"]?["reference"] == (try .encode(reference)))
    #expect(value["data"]?["payload"] == source.payload)
    #expect(value["data"]?["status"] == .string(hasPixels ? "source_pixels" : "source_pixels_unavailable"))
    if hasPixels { #expect(value["data"]?["artifact"]?["expectedSHA256"] == .string(hash)) }
    else { #expect(value["data"]?["artifact"] == nil) }
    #expect(value["basis"]?["owners"] == .array([]))
  }
}

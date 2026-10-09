import Foundation
import Testing
@testable import NotebookCore

@Suite("Borrowed query cuts")
struct NotebookQueryCutTests {
  @Test func contentAndPixelReadsBorrowOneCutAndExpireWithoutAcceptingWrites() throws {
    try fixture { store in
      let workspace = try store.loadIndex(), item = try #require(workspace.items.first)
      let pageID = try #require(item.pageIDs.first), header = try store.workspaceHeader()
      let target = CollaborationTarget(kind: .page, id: pageID)
      var request = NotebookCommand(command: .read)
      request.queries = [.init(kind: .workspaceHeader)]
      let read = try NotebookReadCommand(request)
      let records = try store.readSpatialInkWindowRecords(coverage: [:], pinnedActionIDs: [], elementIDs: [:])
      let before = try store.currentReadCursor(), revision = try store.referenceRevision(target: target)
      let bounds = WorkspaceSpatialBounds(origin: .zero, width: 100, height: 100)
      let expired = try NotebookReadSession(store: store).observe { cut in
        let actualRevision = try cut.referenceRevision(target: target)
        let page = try cut.loadPage(pageID), content = try cut.readContentHeader(target: target)
        let result = try cut.handle(read)
        #expect(actualRevision == revision && page.id == pageID && content.target == target)
        #expect(result["values"]?.array.first?["workspaceID"] == .string(header.workspaceID.uuidString))
        let node = try cut.readBoardNodeHeader(header.rootBoardID), owner = try cut.readBoardItem(item.id)
        #expect(node?.id == header.rootBoardID && owner?.id == header.rootBoardID)
        let hasContent = try cut.boardHasContent(header.rootBoardID)
        #expect(hasContent)
        _ = try cut.readCurrentScenePaintOrder(boardID: header.rootBoardID, bounds: bounds)
        let ink = try cut.spatialInkHistoryStates(ids: [])
        let pixelsCurrent = try cut.sceneRecordsAreCurrent(.init()), inkCurrent = try cut.spatialInkRecordsAreCurrent(records)
        #expect(ink.isEmpty && pixelsCurrent && inkCurrent)
        return cut
      }
      expectExpired { _ = try expired.pendingTargetRenderRequests() }
      expectExpired { _ = try expired.loadPage(pageID) }
      expectExpired { _ = try expired.referenceRevision(target: target) }
      expectExpired { _ = try expired.handle(read) }
      expectExpired { _ = try expired.readContentHeader(target: target) }
      expectExpired { _ = try expired.readBoardNodeHeader(header.rootBoardID) }
      expectExpired { _ = try expired.readBoardItem(item.id) }
      expectExpired { _ = try expired.boardHasContent(header.rootBoardID) }
      expectExpired { _ = try expired.readCurrentScenePaintOrder(boardID: header.rootBoardID, bounds: bounds) }
      expectExpired { _ = try expired.spatialInkHistoryStates(ids: []) }
      expectExpired { _ = try expired.sceneRecordsAreCurrent(.init()) }
      expectExpired { _ = try expired.spatialInkRecordsAreCurrent(records) }
      let after = try store.currentReadCursor()
      #expect(after == before)
    }
  }
  @Test func escapedCutCannotReenterAReusedHandleOrAWriter() throws {
    try fixture { store in
      let reader = NotebookReadSession(store: store)
      var originalIdentity: UUID?, handle: ObjectIdentifier?
      let expired = try reader.observe { cut in
        let connection = try #require(store.currentSQL)
        originalIdentity = connection.readSnapshotIdentity; handle = ObjectIdentifier(connection)
        let actual = try cut.storedWorkspaceID(), expected = try store.storedWorkspaceID()
        #expect(actual == expected)
        return cut
      }
      expectExpired { _ = try expired.workspaceHeader() }
      try reader.observe { cut in
        let connection = try #require(store.currentSQL)
        #expect(ObjectIdentifier(connection) == handle)
        #expect(connection.readSnapshotIdentity != originalIdentity)
        expectExpired { _ = try expired.currentReadCursor() }
        let actual = try cut.workspaceHeader().workspaceID, expected = try store.storedWorkspaceID()
        #expect(actual == expected)
      }
      try store.commandTransaction {
        expectExpired { _ = try expired.storedWorkspaceID() }
        let connection = try #require(store.currentSQL)
        let forged = NotebookQueryCut(store: store, connection: connection,
          identity: connection.readSnapshotIdentity ?? UUID())
        expectExpired { _ = try forged.workspaceHeader() }
      }
    }
  }

  @Test func immutableReadCommandRefusesEveryMutationAndRetainsItsOriginalRequest() throws {
    let prohibited: [NotebookCommand.Kind] = [.apply, .admitAction, .commitAction, .undo, .point,
      .placement, .render, .pageVision, .presentation, .script, .scriptContext,
      .importProgram, .importDocument, .importDocumentResource, .runtimeStatus, .runtimeWorkspace]
    for kind in prohibited {
      #expect(!NotebookReadCommand.accepts(kind))
      do {
        _ = try NotebookReadCommand(.init(command: kind))
        Issue.record("A mutating or external command entered the read capability: \(kind)")
      } catch let error as CollaborationError { #expect(error.code == "read_command_required") }
    }
    let allowed: [NotebookCommand.Kind] = [.search, .read, .contexts, .action, .actions,
      .continuations, .referenceStatus, .referenceStatuses, .actionDetails, .reference,
      .delivery, .artifact, .scriptArtifact, .prepareAction]
    #expect(allowed.allSatisfy(NotebookReadCommand.accepts))
    try fixture { store in
      var wire = NotebookCommand(command: .read); wire.queries = [.init(kind: .workspaceHeader)]
      let read = try NotebookReadCommand(wire), cursor = try store.currentReadCursor()
      wire.command = .point; wire.queries = []
      wire.references = []; wire.contextID = UUID()
      let value = try NotebookReadSession(store: store).observe { try $0.handle(read) }
      let workspaceID = try store.storedWorkspaceID()
      #expect(value["values"]?.array.first?["workspaceID"] == .string(workspaceID.uuidString))
      #expect(try store.currentReadCursor() == cursor)
      var oversized = NotebookCommand(command: .read)
      oversized.queries = Array(repeating: .init(kind: .workspaceHeader), count: 129)
      do { _ = try NotebookReadCommand(oversized); Issue.record("The read command must refuse before resolving sources") }
      catch let error as CollaborationError { #expect(error.code == "resource_limit") }
    }
  }

  private func expectExpired(_ operation: () throws -> Void) {
    do { try operation(); Issue.record("The borrowed cut reopened or upgraded its source") }
    catch let error as CollaborationError { #expect(error.code == "read_cut_expired") }
    catch { Issue.record("Unexpected cut refusal: \(error)") }
  }

  private func fixture(_ operation: (NotebookStore) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("query-cut-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root)
    _ = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    try operation(store)
  }
}

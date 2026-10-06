import Foundation
import Testing
@testable import NotebookCore

@Suite("Borrowed query cuts")
struct NotebookQueryCutTests {
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
      .importProgram, .importDocument, .importDocumentResource, .panelEdit, .panelUndo,
      .panelPresentation, .runtimeStatus, .runtimeWorkspace]
    for kind in prohibited {
      #expect(!NotebookReadCommand.accepts(kind))
      do {
        _ = try NotebookReadCommand(.init(command: kind))
        Issue.record("A mutating or external command entered the read capability: \(kind)")
      } catch let error as CollaborationError { #expect(error.code == "read_command_required") }
    }
    let allowed: [NotebookCommand.Kind] = [.search, .read, .contexts, .action, .actions,
      .continuations, .referenceStatus, .referenceStatuses, .actionDetails, .reference,
      .delivery, .artifact, .scriptArtifact, .panelRead, .prepareAction]
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

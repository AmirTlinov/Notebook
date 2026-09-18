import Foundation
import Testing
@testable import NotebookCore

struct NotebookAccountBootstrapTests {
  @Test func emptyAccountReplicaCannotPublishACompetingInitialNotebook() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("account-bootstrap-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), space = UUID(), actor = UUID()
    try store.prepareEmptyWorkspace(workspaceID: space)
    try store.prepareCloudStorage()
    let source = try store.replicationSource(deviceID: actor)
    try store.enableCloud(account: "A", source: source)
    try store.prepareCloudUpload(account: "A", source: source)
    #expect(try store.storedWorkspaceID() == space)
    #expect(try !store.hasWorkspaceContent())
    #expect(try store.currentChangeCursor() == 0)
    #expect(try store.cloudOutbox(account: "A").isEmpty)
    #expect(try store.changeJournal(after: 0, limit: 16).isEmpty)
  }
}

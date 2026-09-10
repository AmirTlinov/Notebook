import Foundation
import Testing
@testable import NotebookCore

@Suite("A pinned program contains the state of that physical block")
struct AgentPinnedSourceTests {
  @Test(arguments: ["counter/a~b", "ABCDEF00-1234-4ABC-8DEF-1234567890AB"])
  func addressedStateIsFrozenWithoutDisclosingAnotherProgram(blockID: String) throws {
    let id = UUID(), actor = UUID(), requestID = UUID()
    let document = DocumentDocument(id: id, actor: actor, blocks: [
      .interactive(id: blockID, html: "<button>+</button>", initialState: .number(3)),
      .interactive(id: "private", html: "<p>unrequested source</p>")])
    var state = DocumentStateJournal(id: id, actor: actor)
    let first = state.commit(blockID: blockID, value: .number(7), actor: actor)
    let other = state.commit(blockID: "private", value: .string("unrequested state"), actor: actor)
    #expect(first && other)
    var files = [documentFile(id): try JSONValue.encode(document), stateFile(id): try JSONValue.encode(state)]
    let target = CollaborationTarget(kind: .document, id: id), selectedID = collaborationIdentity(blockID)
    let reference = CollaborationReference(target: target, elementID: selectedID,
      revision: try NotebookStore.referenceRevision(target: target, elementID: selectedID, files: files))
    let pinned = try AgentPinnedSource.capture(requestID: requestID, reference: reference, files: files)
    #expect(pinned.payload["state"] == .number(7))
    #expect(pinned.payload["block"] == (try JSONValue.encode(document.blocks[0])))
    #expect(pinned.payload["elements"] == .array([]))
    #expect(Set(pinned.payload.object.keys) == ["reference", "block", "state", "elements"])
    let changed = state.commit(blockID: blockID, value: .number(11), actor: actor)
    #expect(changed)
    files[stateFile(id)] = try .encode(state)
    #expect(throws: CollaborationError.self) {
      try AgentPinnedSource.capture(requestID: requestID, reference: reference, files: files)
    }
    #expect(pinned.payload["state"] == .number(7), "A later state cannot rewrite the frozen indication")
    let nextReference = CollaborationReference(target: target, elementID: selectedID,
      revision: try NotebookStore.referenceRevision(target: target, elementID: selectedID, files: files))
    let next = try AgentPinnedSource.capture(requestID: requestID, reference: nextReference, files: files)
    #expect(next.payload["state"] == .number(11))
  }

  @Test func aProgramWithoutCommittedStateRetainsOnlyItsInitialSourceValue() throws {
    let id = UUID(), actor = UUID()
    let document = DocumentDocument(id: id, actor: actor,
      blocks: [.interactive(id: "counter", html: "<button>+</button>", initialState: .number(3))])
    let files = [documentFile(id): try JSONValue.encode(document),
      stateFile(id): try JSONValue.encode(DocumentStateJournal(id: id, actor: actor))]
    let target = CollaborationTarget(kind: .document, id: id)
    let reference = CollaborationReference(target: target, elementID: "counter",
      revision: try NotebookStore.referenceRevision(target: target, elementID: "counter", files: files))
    let pinned = try AgentPinnedSource.capture(requestID: UUID(), reference: reference, files: files)
    #expect(pinned.payload["state"] == nil)
    #expect(pinned.payload["block"] == (try JSONValue.encode(document.blocks[0])))
  }
}

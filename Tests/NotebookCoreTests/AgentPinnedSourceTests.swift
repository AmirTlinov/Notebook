import Foundation
import CryptoKit
import Testing
@testable import NotebookCore

@Suite("A pinned program contains the state of that physical block")
struct AgentPinnedSourceTests {
  @Test func availableSourcePixelsDoNotCarryTheFallbackUnavailableReason() throws {
    let target = CollaborationTarget(kind: .page, id: UUID())
    let region = PageRect(x: 0, y: 0, width: 1, height: 1)
    let reference = CollaborationReference(target: target, region: region, revision: "source-at-send")
    let source = AgentPinnedSource(id: reference.id, requestID: UUID(), reference: reference,
      payload: .object(["reference": try .encode(reference)]))
    let png = try #require(Data(base64Encoded:
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="))
    let image = try AgentPinnedImage(referenceID: reference.id, sourceRevision: reference.revision,
      region: region, worldOrigin: nil, pageIndex: nil, pixelWidth: 1, pixelHeight: 1,
      pixelsPerPoint: 1, png: png, sha256: SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined())
    let unavailable = try source.withVisual(nil, unavailable: "source_pixels_unavailable")
    let available = try source.withVisual(image, unavailable: "source_pixels_unavailable")
    #expect(unavailable.payload["visual"] == .object([
      "status": .string("unavailable"), "reason": .string("source_pixels_unavailable")]))
    #expect(available.payload["visual"] == .object(["status": .string("source_pixels"), "reason": .null]))
    #expect(available.image == image)
    #expect(available.reference == source.reference)
    #expect(source.payload["visual"] == nil, "Adding image metadata cannot alter the original value")
  }

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

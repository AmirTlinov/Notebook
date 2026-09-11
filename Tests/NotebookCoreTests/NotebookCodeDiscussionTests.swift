import Foundation
import Testing
@testable import NotebookCore

@Suite("Code discussion keeps the reviewed material and machine address")
struct NotebookCodeDiscussionTests {
  @Test func linksRoundTripMachineIdentityAndRefuseAmbiguousOrUnsafeAddresses() throws {
    let file = NotebookFileAddress(computer: UUID(), project: "project & one", root: "/project/Учёба", path: "src/a b.py")
    for value: NotebookCodeLink in [.fragment(UUID()), .file(file, line: 27), .conversation(computer: UUID(), thread: UUID())] {
      #expect(NotebookCodeLink(url: value.url) == value)
    }
    for raw in ["notebook://code/no-id", "https://code/" + UUID().uuidString,
      NotebookCodeLink.file(file, line: 1).url.absoluteString + "&line=2",
      NotebookCodeLink.file(file, line: 0).url.absoluteString,
      "notebook://code/" + UUID().uuidString + "?unknown=1"] {
      #expect(NotebookCodeLink(url: try #require(URL(string: raw))) == nil)
    }
  }

  @Test func frozenCodeAndInkShareOneContextAndDoNotFollowLaterEdits() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), author = UUID()
    _ = try store.initializeWorkspace(actor: author, pageSize: .init(width: 834, height: 1194))
    try store.savePresence(.init(mode: .board, camera: .init(center: .init(x: 90, y: -50), scale: 0.7), viewport: .init(x: 834, y: 1194)))
    let before = try store.loadPresence()
    let file = NotebookFileAddress(computer: UUID(), project: "demo", root: "/code", path: "learn.py")
    let fragment = NotebookCodeFragment(file: file, sourceHash: NotebookFileVersion.hash(Data("print(4)\n".utf8)),
      utf16Offset: 0, text: "print(4)\n", width: 600, height: 400, fontSize: 15, stamp: .init(counter: 1, actor: author))
    let stroke = SpatialInkAction(tool: .pen, spans: [.init(surface: .codeFragment(fragment.id), samples: [
      .init(point: .init(x: 30, y: 60), timeOffset: 0, width: 2, opacity: 1, force: 1, azimuth: 0, altitude: 1)
    ])], stamp: .init(counter: 2, actor: author))
    _ = try store.commitCodeInk(fragment: fragment, command: .append(stroke, journalStamp: stroke.stamp))
    let annotation = try #require(try store.codeAnnotation(fragment.id)), reference = try annotation.reference()
    let context = try store.discussCode([annotation], references: [reference], images: [:], unavailable: [reference.id: "test has no renderer"], actor: author)
    #expect(try store.hasAttentionEvidence(contextID: context.id))
    let source = try #require(try store.attentionEvidence(contextID: context.id, referenceID: reference.id))
    #expect(source.payload["code"]?["text"]?.string == fragment.text)
    #expect(source.payload["ink"]?.array.count == 1)
    #expect(source.payload["link"]?.string == NotebookCodeLink.fragment(fragment.id).url.absoluteString)
    let undo = VersionStamp(counter: 3, actor: author)
    _ = try store.commitCodeInk(fragment: fragment, command: .state(actionID: stroke.id, creationStamp: stroke.stamp, isActive: false, stateStamp: undo, journalStamp: undo))
    #expect(try store.referenceRevision(target: reference.target) != reference.revision)
    #expect(try store.attentionEvidence(contextID: context.id, referenceID: reference.id) == source)
    #expect(try NotebookStore(root: root).hasAttentionEvidence(contextID: context.id))
    #expect(try store.loadPresence() == before)
  }
}

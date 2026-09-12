import XCTest
import SwiftUI
import NotebookCore
@testable import Notebook

@MainActor
final class NotebookFileControllerTests: XCTestCase {
  func testVisibleDirectoryUpdatesAfterCreationAndDeletionWithoutDroppingItsLoadedPages() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("tree-sync-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), author = UUID(), peer = UUID()
    _ = try store.initializeWorkspace(actor: author, pageSize: .init(width: 834, height: 1194))
    let queue = NotebookPersistenceQueue(store: store), project = CodexProject(id: "p", name: "Code", roots: ["/fixture"])
    let address = NotebookFileAddress(computer: peer, project: project.id, root: "/fixture", path: "")
    var chat: NotebookChatController!, generation = 0, paths: [String] = []
    chat = .init(persistence: queue, author: author) { envelope, _ in
      guard case .request(let query) = envelope.body else { return }
      let reply: NotebookChatReply
      switch query {
      case .catalogue: reply = .catalogue(.init(tasks: [], nextCursor: nil))
      case .projects: reply = .projects(.init(projects: [project], nextCursor: nil))
      case .activity: reply = .activity([])
      case .file(.directory(let folder, let after)):
        paths.append(folder.path)
        reply = .file(.directory(.init(entries: [.init(name: after == nil ? (generation == 0 ? "deleted.py" : "new.py") : "retained.py", kind: .file)], next: after == nil ? "next" : nil)))
      default: return XCTFail("No file mutation belongs to directory sync")
      }
      chat.receive(.init(id: envelope.id, body: .reply(reply)), peerID: peer)
    }
    await chat.start(); await chat.connect(peer)
    var state = NotebookFileWindowState(); state.project = project; state.sidebar = true
    await chat.files.installWindow(state, document: nil); chat.expanded = true
    await chat.files.expand(address); await chat.files.expand(address, more: true)
    generation = 1
    await chat.files.refreshVisibleDirectories(now: .now + .seconds(16))
    XCTAssertEqual(chat.files.directories[address]?.entries.map(\.name), ["new.py", "retained.py"])
    XCTAssertEqual(paths.count, 4); XCTAssertEqual(Set(paths), [""])
    chat.files.toggleSidebar()
    await chat.files.refreshVisibleDirectories(now: .now + .seconds(40))
    XCTAssertEqual(paths.count, 4)
    await chat.stop(); let saved = await queue.flush(); XCTAssertTrue(saved)
  }

  func testVisibleTreeRecoversAfterAccessReturnsAndRejectsLateErrorsFromAnotherProject() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("file-tree-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), author = UUID(), peer = UUID()
    _ = try store.initializeWorkspace(actor: author, pageSize: .init(width: 834, height: 1194))
    let queue = NotebookPersistenceQueue(store: store)
    let project = CodexProject(id: "first", name: "First", roots: ["/fixture"])
    let address = NotebookFileAddress(computer: peer, project: project.id, root: "/fixture", path: "")
    var chat: NotebookChatController!, reads = 0, held: NotebookChatEnvelope?
    chat = .init(persistence: queue, author: author) { envelope, _ in
      guard case .request(let query) = envelope.body else { return }
      let reply: NotebookChatReply
      switch query {
      case .catalogue: reply = .catalogue(.init(tasks: [], nextCursor: nil))
      case .projects: reply = .projects(.init(projects: [project], nextCursor: nil))
      case .file(.directory(let file, _)):
        if !file.path.isEmpty { held = envelope; return }
        reads += 1
        reply = reads == 1 ? .failure("Mac ожидает доступ к папке") : .file(.directory(.init(entries: [.init(name: "source.swift", kind: .file)], next: nil)))
      default: reply = .failure("Unexpected mutation")
      }
      chat.receive(.init(id: envelope.id, body: .reply(reply)), peerID: peer)
    }
    await chat.start(); await chat.connect(peer)
    var state = NotebookFileWindowState(); state.project = project; state.sidebar = true
    await chat.files.installWindow(state, document: nil)
    chat.expanded = true
    await chat.files.expand(address)
    XCTAssertEqual(reads, 1); XCTAssertNotNil(chat.files.directoryErrors[address]); XCTAssertNil(chat.files.error)
    await chat.files.refreshVisibleDirectories()
    XCTAssertEqual(reads, 1, "A denied read does not busy-loop")
    chat.expanded = false
    await chat.files.refreshVisibleDirectories(now: .now + .seconds(16))
    XCTAssertEqual(reads, 1, "A hidden tree does not poll the Mac")
    chat.expanded = true
    await chat.files.refreshVisibleDirectories(now: .now + .seconds(16))
    XCTAssertEqual(reads, 2); XCTAssertNil(chat.files.directoryErrors[address])
    XCTAssertEqual(chat.files.directories[address]?.entries.first?.name, "source.swift")
    let oldFolder = address.child("Sources")
    let oldRead = Task { await chat.files.expand(oldFolder) }
    let deadline = ContinuousClock.now + .seconds(3)
    while held == nil, .now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    let pending = try XCTUnwrap(held)
    await chat.files.expand(oldFolder)
    XCTAssertEqual(chat.files.loadingDirectories, [oldFolder], "Only one read can own this folder")
    chat.selectProject(.init(id: "second", name: "Second", roots: ["/second"]))
    chat.receive(.init(id: pending.id, body: .reply(.failure("Late failure from the first project"))), peerID: peer)
    await oldRead.value
    XCTAssertNil(chat.files.directoryErrors[oldFolder]); XCTAssertNil(chat.files.directories[address])
    XCTAssertNil(chat.files.error)
    await chat.stop(); let flushed = await queue.flush(); XCTAssertTrue(flushed)
  }

  func testLargeVersionedReadDraftAndFileSwitchNeverRedirectLateEditorCallbacks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("file-controller-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), author = UUID(), peer = UUID()
    _ = try store.initializeWorkspace(actor: author, pageSize: .init(width: 834, height: 1194))
    let queue = NotebookPersistenceQueue(store: store), source = String(repeating: "let sample = 42 // code\n", count: 18_000)
    let data = Data(source.utf8), project = CodexProject(id: "project", name: "Code", roots: ["/fixture"])
    let address = NotebookFileAddress(computer: peer, project: project.id, root: "/fixture", path: "source.swift")
    var chat: NotebookChatController!, chunks = 0
    chat = NotebookChatController(persistence: queue, author: author) { envelope, destination in
      XCTAssertEqual(destination, peer)
      guard case .request(let query) = envelope.body else { return }
      let reply: NotebookChatReply
      switch query {
      case .catalogue: reply = .catalogue(.init(tasks: [], nextCursor: nil))
      case .projects: reply = .projects(.init(projects: [project], nextCursor: nil))
      case .file(.read(let requested, let version, let offset)):
        XCTAssertEqual(requested, address); XCTAssertTrue(version == nil || version == .init(data)); chunks += 1
        reply = .file(.part(.init(version: .init(data), offset: offset, data: data.subdata(in: offset..<min(data.count, offset + NotebookFileVersion.chunkBytes)))))
      default: reply = .failure("not part of this read")
      }
      chat.receive(.init(id: envelope.id, body: .reply(reply)), peerID: peer)
    }
    await chat.start(); await chat.connect(peer)
    try store.savePresence(.init(mode: .board, camera: .init(center: .init(x: 321, y: -456), scale: 0.43), viewport: .init(x: 834, y: 1194)))
    let before = try store.loadPresence()
    await chat.files.open(address)
    XCTAssertEqual(chat.files.document?.text, source); XCTAssertGreaterThan(chunks, 4)
    chat.files.edit("human draft", address: address, selection: 4, scroll: 210)
    chat.files.toggleSidebar(); chat.files.toggleSidebar(); chat.files.close()
    await chat.files.open(address)
    XCTAssertEqual(chat.files.document?.text, "human draft"); XCTAssertEqual(chat.files.document?.scroll, 210)
    let second = address.child("second.swift")
    try store.saveFileDraft(.init(address: second, text: "second"))
    await chat.files.open(second)
    let late = NotebookCodeEditor.Coordinator(files: chat.files, address: address)
    let oldView = UITextView(); oldView.text = "late old callback"
    late.textViewDidChange(oldView)
    XCTAssertEqual(chat.files.document?.text, "second", "A dismantled editor cannot overwrite the new document")
    await chat.stop(); let saved = await queue.flush(); XCTAssertTrue(saved)
    XCTAssertEqual(try store.fileDraft(address)?.text, "human draft")
    XCTAssertEqual(try store.fileDraft(address)?.scroll, 210)
    XCTAssertEqual(try store.loadPresence(), before)
    let resumed = NotebookChatController(persistence: queue, author: author) { _, _ in XCTFail("Offline restore must not send") }
    await resumed.start(); XCTAssertEqual(resumed.files.document?.address, second)
    XCTAssertEqual(resumed.files.document?.text, "second"); await resumed.stop()
  }

  func testMountedNativeDocumentKeepsBoardAndCameraWhileEditingScrollingAndClosing() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("code-native-" + UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    let host = UIHostingController(rootView: NotebookRootView().environment(model))
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    window.frame = .init(x: 0, y: 0, width: 834, height: 1194); window.rootViewController = host; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    await model.start(pageSize: .init(width: 834, height: 1194))
    let chat = try XCTUnwrap(model.chat)
    let address = NotebookFileAddress(computer: UUID(), project: "code", root: "/fixture", path: "math.py")
    let source = (0..<500).map { "x\($0) = \($0) * 2" }.joined(separator: "\n")
    try model.store.saveFileDraft(.init(address: address, text: source))
    let before = model.presence
    await chat.files.open(address)
    try await Task.sleep(for: .milliseconds(150)); host.view.layoutIfNeeded()
    let view = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UITextView }.first { $0.accessibilityIdentifier == "notebook-code-text" })
    XCTAssertTrue(view.isFindInteractionEnabled); XCTAssertTrue(view.isScrollEnabled)
    chat.files.edit("😀\n" + source, address: address, selection: 0, scroll: 0)
    try await Task.sleep(for: .milliseconds(50))
    chat.files.edit("😃\n" + source, address: address, selection: 0, scroll: 0)
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertTrue(view.text.hasPrefix("😃\n"), "An external patch cannot split an emoji into replacement characters")
    view.setContentOffset(.init(x: 0, y: 480), animated: false)
    view.isEditable = true; view.selectedRange = .init(location: 0, length: 0); view.insertText("# human\n")
    XCTAssertTrue(chat.files.document?.text.hasPrefix("# human\n") == true)
    XCTAssertEqual(model.presence, before)
    let shot = XCTAttachment(image: UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) })
    shot.name = "native-vertical-code-over-mounted-board"; shot.lifetime = .keepAlways; add(shot)
    chat.files.close(); try await Task.sleep(for: .milliseconds(80))
    XCTAssertEqual(model.presence, before)
    await chat.files.open(address); XCTAssertTrue(chat.files.document?.text.hasPrefix("# human\n") == true)
  }
  func testReadingPositionRestoresWhenUIKitLaysOutTheViewport() {
    let view = NotebookCodeTextView()
    view.text = String(repeating: "a line\n", count: 200)
    view.initialScroll = 300
    view.frame = .init(x: 0, y: 0, width: 400, height: 500)
    view.layoutIfNeeded()
    XCTAssertNil(view.initialScroll); XCTAssertEqual(view.contentOffset.y, 300, accuracy: 1)
  }
  func testConfirmedRenameRestoresTheSameDraftAndNotesAtTheNewPath() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), author = UUID(), computer = UUID()
    _ = try store.initializeWorkspace(actor: author, pageSize: .init(width: 834, height: 1194))
    let queue = NotebookPersistenceQueue(store: store)
    let chat = NotebookChatController(persistence: queue, author: author) { _, _ in }
    await chat.start(); await chat.connect(computer)
    let file = NotebookFileAddress(computer: computer, project: "demo", root: "/project", path: "old.py")
    var draft = NotebookFileDraft(address: file, text: "print(4)"); draft.text = "print(8)"; draft.scroll = 120
    try store.saveFileDraft(draft)
    await chat.files.open(file)
    let fragment = NotebookCodeFragment(file: file, sourceHash: NotebookFileVersion.hash(Data(draft.text.utf8)), utf16Offset: 0,
      text: draft.text, width: 600, height: 100, fontSize: 15, stamp: .init(counter: 1, actor: author))
    try store.captureCodeFragment(fragment)
    await chat.files.rename(to: "new.py")
    let id = try XCTUnwrap(chat.files.document?.rename), job = try XCTUnwrap(store.chatJob(id))
    guard case .renameFile(let request) = job.input.action else { return XCTFail("Expected typed rename") }
    XCTAssertGreaterThan(UInt64(request.after)!, 0)
    chat.files.edit("late", address: file, selection: 0, scroll: 0)
    XCTAssertEqual(chat.files.document?.text, draft.text)
    await chat.files.rename(to: "second.py")
    XCTAssertEqual(chat.files.document?.rename, id)
    chat.files.receive(.init(input: job.input, state: .accepted, result: .renamed(request)))
    let deadline = ContinuousClock.now + .seconds(2)
    while chat.files.document?.address != request.destination, .now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertEqual(chat.files.document?.address, request.destination)
    XCTAssertEqual(chat.files.document?.text, draft.text); XCTAssertEqual(chat.files.document?.scroll, 120)
    XCTAssertEqual(chat.files.notes.fragments.first?.currentFile, request.destination)
    XCTAssertEqual(chat.files.notes.fragments.first?.text, fragment.text)
    XCTAssertNil(try store.fileDraft(file))
    await chat.stop(); let saved = await queue.flush(); XCTAssertTrue(saved)
  }
  private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
}

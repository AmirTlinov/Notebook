import NotebookCore
import SwiftUI
import XCTest
#if os(iOS)
import UIKit
#else
import AppKit
#endif
@testable import Notebook

@MainActor
final class DocumentNativeSourceSessionTests: XCTestCase {
  private func fixture() async throws -> (NotebookAppModel, UUID, DocumentSourceEditorSession) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let idResult = await model.createDocument(at: .zero)
    let id = try XCTUnwrap(idResult)
    await model.finishPendingPersistence()
    let presence = try XCTUnwrap(model.presence)
    model.selectItem(id)
    model.updatePresence(.init(boardID: presence.boardID, mode: .document,
      camera: presence.camera, viewport: presence.viewport, focusedItemID: id,
      openProgress: 1, selectedItemID: id), settled: true)
    await model.prepareDocumentOpening(id, pageIndex: 0)?.value
    let request = try await model.insertDocumentFile(documentID: id, path: "chapters/edit.tex")
    return (model, id, DocumentSourceEditorSession(request: request, model: model))
  }

  private func mountEditor(_ session: DocumentSourceEditorSession) async throws
    -> (view: SourceTextView, close: @MainActor () -> Void) {
    #if os(iOS)
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene: scene)
    let host = UIHostingController(rootView: DocumentNativeSourceEditor(session: session))
    window.rootViewController = host; window.makeKeyAndVisible()
    let nativeRoot = try XCTUnwrap(host.view)
    let close = { @MainActor in window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    func find(_ parent: UIView) -> SourceTextView? {
      if let view = parent as? SourceTextView { return view }
      for child in parent.subviews { if let view = find(child) { return view } }
      return nil
    }
    #else
    let host = NSHostingView(rootView: DocumentNativeSourceEditor(session: session))
    let window = NSWindow(contentRect: .init(x: -20_000, y: -20_000, width: 600, height: 500),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host; window.orderBack(nil)
    let nativeRoot = host
    let close = { @MainActor in window.orderOut(nil); window.close() }
    func find(_ parent: NSView) -> SourceTextView? {
      if let view = parent as? SourceTextView { return view }
      for child in parent.subviews { if let view = find(child) { return view } }
      return nil
    }
    #endif
    var mounted = false
    defer { if !mounted { close() } }
    let deadline = ContinuousClock.now + .seconds(5)
    while find(nativeRoot) == nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    let view = try XCTUnwrap(find(nativeRoot)); mounted = true
    return (view, close)
  }

  func testInputDuringSaveUsesTheAcceptedVersionAndCommonUndo() async throws {
    let (model, id, session) = try await fixture()
    let first = "First \u{00E9}", successor = "First e\u{0301}"
    XCTAssertEqual(first, successor, "The fixture differs only in literal Unicode source bytes")
    XCTAssertNotEqual(Array(first.utf8), Array(successor.utf8))
    let contact = UUID(); model.inputGate.beginContact(source: contact)
    session.input(first, selection: .init(location: first.utf16.count, length: 0), composing: false, scroll: 0)
    let saving = Task { await session.save() }
    while !session.saving { await Task.yield() }
    session.input(successor, selection: .init(location: successor.utf16.count, length: 0), composing: false, scroll: 0)
    model.inputGate.endContact(source: contact)
    await saving.value
    XCTAssertFalse(session.conflicted)
    let saved = try XCTUnwrap(try model.store.loadDocument(id).files.first { $0.id == session.fileID }?.source)
    XCTAssertEqual(Array(saved.utf8), Array(successor.utf8))
    XCTAssertTrue(try model.store.documentEditingSessions().isEmpty)
    model.undoLastSurfaceAction(); await model.finishPendingPersistence()
    let undone = try XCTUnwrap(try model.store.loadDocument(id).files.first { $0.id == session.fileID }?.source)
    XCTAssertEqual(Array(undone.utf8), Array(first.utf8))
    model.undoLastSurfaceAction(); await model.finishPendingPersistence()
    XCTAssertEqual(try model.store.loadDocument(id).files.first { $0.id == session.fileID }?.source, "")
  }

  func testComposingDraftRestoresExactSelectionWithoutPublishingHalfInput() async throws {
    let (model, id, session) = try await fixture()
    session.input("Неоконченный ввод", selection: .init(location: 2, length: 5), composing: true, scroll: 210)
    await session.checkpoint(); await model.finishPendingPersistence()
    let saved = try model.store.loadDocument(id)
    XCTAssertEqual(saved.files.first { $0.id == session.fileID }?.source, "")
    let file = try XCTUnwrap(saved.files.first { $0.id == session.fileID })
    let restored = DocumentSourceEditorSession(request: .init(documentID: id, file: file,
      version: saved.fileVersion(fileID: file.id), offset: 0), model: model)
    XCTAssertEqual(restored.text, session.text)
    XCTAssertEqual(restored.selection, NSRange(location: 2, length: 5))
    XCTAssertEqual(restored.restoredScroll, 210)
    XCTAssertEqual(try model.store.documentEditingSessions().last?.isComposing, true)
  }

  #if os(iOS)
  func testCodeWorkspaceKeepsTheNativeEditorAsTheHitTargetInsideItsControlRegion() async throws {
    let (model, _, _) = try await fixture()
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene: scene)
    let host = UIHostingController(rootView: NotebookRootView().environment(model))
    window.rootViewController = host; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    func views(_ parent: UIView) -> [UIView] { [parent] + parent.subviews.flatMap(views) }
    window.layoutIfNeeded()
    let document=try XCTUnwrap(model.activeDocument)
    let file=try XCTUnwrap(document.files.first { $0.path == document.entrypoint })
    NotificationCenter.default.post(name:DocumentSourceRequest.notification,
      object:DocumentSourceRequest(documentID:document.id,file:file,version:document.fileVersion(fileID:file.id)))
    let deadline = ContinuousClock.now + .seconds(5)
    while .now < deadline {
      window.layoutIfNeeded()
      if let editor = views(window).compactMap({ $0 as? SourceTextView }).first,
        editor.bounds.width > 0, editor.bounds.height > 0 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let editor = try XCTUnwrap(views(window).compactMap { $0 as? SourceTextView }.first)
    let point = editor.convert(CGPoint(x: editor.bounds.minX + editor.bounds.width * 0.35,
      y: editor.bounds.minY + editor.bounds.height * 0.25), to: window)
    let region = try XCTUnwrap(views(window).compactMap { $0 as? NotebookControlRegionView }.first {
      $0.bounds.contains($0.convert(point, from: window))
    })
    XCTAssertNil(region.hitTest(region.convert(point, from: window), with: nil), "The measured exclusion owns no native contact")
    XCTAssertTrue(model.loadState == .ready, "The full root's workspace input gate must be open")
    XCTAssertNil(editor.textLayoutManager, "The designated initializer keeps the source editor on TextKit 1")
    XCTAssertTrue(editor.isEditable && editor.isSelectable && editor.isUserInteractionEnabled)
    XCTAssertTrue(editor.canBecomeFirstResponder)
    let hit = window.hitTest(point, with: nil)
    var ancestors: [String] = [], current = hit
    while let view = current, ancestors.count < 8 {
      ancestors.append("\(type(of: view))[input=\(view.isUserInteractionEnabled),hidden=\(view.isHidden),alpha=\(view.alpha),frame=\(view.frame)]")
      current = view.superview
    }
    XCTAssertTrue(hit === editor || hit?.isDescendant(of: editor) == true,
      "The full root, including chat and chrome, must route the UI scenario's editor contact to UIKit: \(ancestors.joined(separator: ">"))")
  }
  #endif

  func testHistoryPauseRefusesNativeTextBeforeMutationAndResumeAdmitsTheSameEditor() async throws {
    let (model, id, session) = try await fixture()
    let original = "Начальный исходник 🪐"
    session.input(original, selection: .init(location: original.utf16.count, length: 0), composing: false, scroll: 0)
    await session.checkpoint()
    let saved = await model.finishPendingPersistence()
    XCTAssertTrue(saved, model.persistenceFailure ?? "")
    let document = try model.store.loadDocument(id)
    let drafts = model.documentEditingSessions
    let notice = session.notice

    let native = try await mountEditor(session); defer { native.close() }
    let view = native.view
    let coordinator = try XCTUnwrap(view.delegate as? DocumentNativeSourceEditor.Coordinator)
    func source() -> String {
      #if os(iOS)
      return view.text
      #else
      return view.string
      #endif
    }
    func select(_ range: NSRange) {
      #if os(iOS)
      view.selectedRange = range
      #else
      view.setSelectedRange(range)
      #endif
      coordinator.changed(view)
    }
    func insert(_ text: String) {
      #if os(iOS)
      view.insertText(text)
      #else
      view.insertText(text, replacementRange: view.selectedRange())
      #endif
    }
    XCTAssertEqual(source(), original)
    let request = NotebookHistoryReadiness.Request(id: UUID(), workspaceID: try XCTUnwrap(model.admittedWorkspaceID),
      devices: [model.actorID, UUID()], acceptedGeneration: 0)
    try model.historyReadiness.begin(request)
    defer {
      if model.historyReadiness.phase != .open {
        try? model.historyReadiness.finish(request, releaseWriter: { _ in })
      }
    }
    XCTAssertFalse(model.permitsAuthoredWork)
    insert("Refused")
    XCTAssertEqual(source(), original, "The native input owner must refuse before NSTextView/UITextView changes its source")
    #if os(iOS)
    view.deleteBackward()
    XCTAssertEqual(source(), original, "Native deletion reads the same admission before mutation")
    let end = try XCTUnwrap(view.position(from: view.beginningOfDocument, offset: original.utf16.count))
    let nativeRange = try XCTUnwrap(view.textRange(from: view.beginningOfDocument, to: end))
    view.replace(nativeRange, withText: "Refused replacement")
    XCTAssertEqual(source(), original, "A direct UITextInput replacement cannot bypass the delegate")
    view.setMarkedText("Refused IME", selectedRange: .init(location: 0, length: 0))
    XCTAssertEqual(source(), original, "A late composing input cannot change native text during the cut")
    XCTAssertNil(view.markedTextRange)
    #endif
    XCTAssertEqual(session.text, original)
    XCTAssertEqual(session.notice, notice)
    XCTAssertEqual(model.documentEditingSessions, drafts)

    session.navigate(2)
    let range = NSRange(location: 2, length: 3)
    select(range)
    let selection = try XCTUnwrap(session.messageSelection)
    XCTAssertEqual(selection.selectedText, (original as NSString).substring(with: range))
    XCTAssertFalse(selection.hasLocalDraft)
    XCTAssertNil(selection.sequence)
    let selectedScroll = session.restoredScroll
    session.input(original + "bypass", selection: .init(location: 0, length: 0), composing: true, scroll: 100)
    XCTAssertEqual(session.text, original, "A late native callback cannot mutate the session after refusal")
    XCTAssertEqual(session.selection, range)
    XCTAssertEqual(session.restoredScroll, selectedScroll)
    XCTAssertNotNil(session.messageSelection, "The refused change cannot start a composing draft")
    #if os(macOS)
    XCTAssertTrue(coordinator.textView(view, shouldChangeTextIn: range, replacementString: nil))
    #endif
    await session.checkpoint()
    let pausedSaved = await model.finishPendingPersistence()
    XCTAssertTrue(pausedSaved, model.persistenceFailure ?? "")
    XCTAssertEqual(try model.store.loadDocument(id), document)
    XCTAssertEqual(try model.store.documentEditingSessions(), drafts)

    try model.historyReadiness.finish(request, releaseWriter: { _ in XCTFail("This draining editor fixture holds no writer seal") })
    XCTAssertTrue(model.permitsAuthoredWork)
    insert("!")
    let expected = (original as NSString).replacingCharacters(in: range, with: "!")
    XCTAssertEqual(source(), expected, "The same mounted editor admits the next edit without a phase rerender")
    coordinator.changed(view)
    XCTAssertEqual(session.text, expected)
    await session.checkpoint()
    let resumedSaved = await model.finishPendingPersistence()
    XCTAssertTrue(resumedSaved, model.persistenceFailure ?? "")
    XCTAssertEqual(try model.store.loadDocument(id).files.first { $0.id == session.fileID }?.source, expected)
    XCTAssertTrue(try model.store.documentEditingSessions().isEmpty)
    XCTAssertFalse(session.conflicted)
  }

  func testConcurrentAgentEditPreservesDraftAndNeedsExplicitResolution() async throws {
    let (model, id, session) = try await fixture()
    let original = "My unfinished text", completed = "My completed text"
    session.input(original, selection: .init(location: 3, length: 10), composing: false, scroll: 0)
    await session.save(); await model.finishPendingPersistence()
    let initial = try model.store.loadDocument(id), initialVersion = initial.fileVersion(fileID: session.fileID)
    let native = try await mountEditor(session); defer { native.close() }
    let view = native.view, coordinator = try XCTUnwrap(view.delegate as? DocumentNativeSourceEditor.Coordinator)
    func mark(_ text: String, selected: NSRange) {
      #if os(iOS)
      view.setMarkedText(text, selectedRange: selected)
      #else
      view.setMarkedText(text, selectedRange: selected,
        replacementRange: view.hasMarkedText() ? view.markedRange() : view.selectedRange())
      #endif
      coordinator.changed(view)
    }
    func markedRange() -> NSRange {
      #if os(iOS)
      guard let range = view.markedTextRange else { return .init(location: NSNotFound, length: 0) }
      return .init(location: view.offset(from: view.beginningOfDocument, to: range.start),
        length: view.offset(from: range.start, to: range.end))
      #else
      return view.markedRange()
      #endif
    }
    func selectedRange() -> NSRange {
      #if os(iOS)
      view.selectedRange
      #else
      view.selectedRange()
      #endif
    }
    // IME can mark existing characters before changing any source byte. The
    // equality with base must not make this active composition replaceable.
    #if os(iOS)
    view.selectedRange = .init(location: 3, length: 10)
    #else
    view.setSelectedRange(.init(location: 3, length: 10))
    #endif
    coordinator.changed(view)
    mark("unfinished", selected: .init(location: 2, length: 3))
    let marked = markedRange(), selection = selectedRange(), navigation = session.navigation
    XCTAssertEqual(marked, NSRange(location: 3, length: 10))
    XCTAssertEqual(selection, NSRange(location: 5, length: 3))
    XCTAssertEqual(session.text, original); XCTAssertTrue(session.hasComposingInput)
    await session.checkpoint()
    await model.finishPendingPersistence()
    let fileID = session.fileID
    try await model.performStoreCommand(publishesChanges: true) { store in
      let document = try store.loadDocument(id), target = CollaborationTarget(kind: .document, id: id)
      _ = try store.applyCollaborationAction(.init(summary: "Agent edit", expected: [.init(target: target, revision: document.contentStamp.revision)],
        operations: [.init(kind: .putDocumentFile, target: target, id: fileID, values: ["path": .string("chapters/edit.tex"), "source": .string("Agent text"), "expectedVersion": try .encode(document.fileVersion(fileID: fileID))])]), actor: UUID())
    }
    await model.reloadExternalChanges()?.value
    let remote = try XCTUnwrap(model.documents[id])
    XCTAssertEqual(remote.files.first { $0.id == fileID }?.source, "Agent text")
    session.reconcile(remote)
    await session.checkpoint(); await model.finishPendingPersistence()
    XCTAssertEqual(session.text, original); XCTAssertTrue(session.hasComposingInput)
    XCTAssertEqual(session.selection, selection); XCTAssertEqual(session.navigation, navigation)
    XCTAssertEqual(markedRange(), marked); XCTAssertEqual(selectedRange(), selection)
    let draft = try XCTUnwrap(try model.store.documentEditingSessions().last)
    XCTAssertEqual(draft.edit.baseSource, original); XCTAssertEqual(draft.edit.baseVersion, initialVersion)
    XCTAssertTrue(draft.isComposing)
    mark("completed", selected: .init(location: 9, length: 0))
    view.unmarkText(); coordinator.changed(view)
    XCTAssertFalse(session.hasComposingInput); XCTAssertEqual(session.text, completed)
    await session.save()
    XCTAssertTrue(session.conflicted)
    XCTAssertEqual(session.text, completed)
    XCTAssertEqual(try model.store.loadDocument(id).files.first { $0.id == session.fileID }?.source, "Agent text")
    session.useCurrentDocument(); await model.finishPendingPersistence()
    XCTAssertFalse(session.conflicted)
    XCTAssertEqual(session.text, "Agent text")
    XCTAssertTrue(try model.store.documentEditingSessions().isEmpty)
  }

  func testNewFileUsesCommonUndoRatherThanASeparateEditorHistory() async throws {
    let (model, id, session) = try await fixture()
    XCTAssertEqual(try model.store.loadDocument(id).files.first { $0.id == session.fileID }?.path, "chapters/edit.tex")
    model.undoLastSurfaceAction(); await model.finishPendingPersistence()
    XCTAssertFalse(try model.store.loadDocument(id).files.contains { $0.id == session.fileID })
  }

  func testRapidSourceUndoAndRedoKeepTheirAcceptedDocumentAcrossAWriteBarrier() async throws {
    let (model, id, session) = try await fixture()
    for text in ["First", "Second"] {
      session.input(text, selection: .init(location: text.utf16.count, length: 0), composing: false, scroll: 0)
      await session.save()
    }
    let lock = try NotebookSQLWriteBlocker(store: model.store)
    defer { try? lock.release() }
    session.input("Third", selection: .init(location: 5, length: 0), composing: false, scroll: 0)
    session.undo(); session.undo()
    let deadline = ContinuousClock.now + .seconds(2)
    while !session.saving, ContinuousClock.now < deadline { await Task.yield() }
    XCTAssertTrue(session.saving)
    let notebook = try XCTUnwrap(model.workspace?.items.first { $0.kind == .notebook }?.id)
    model.selectItem(notebook)
    try lock.release()
    let undone = await model.finishPendingPersistence()
    XCTAssertTrue(undone, model.persistenceFailure ?? "")
    let afterUndo = try model.store.loadDocument(id)
    XCTAssertEqual(afterUndo.files.first { $0.id == session.fileID }?.source, "First",
      "Both accepted gestures must execute after the pending Third save, not cancel the same action twice")
    XCTAssertEqual(model.presence?.selectedItemID, notebook)
    session.reconcile(afterUndo)

    let redoLock = try NotebookSQLWriteBlocker(store: model.store)
    defer { try? redoLock.release() }
    session.redo(); session.redo()
    await Task.yield()
    try redoLock.release()
    let repeated = await model.finishPendingPersistence()
    XCTAssertTrue(repeated, model.persistenceFailure ?? "")
    XCTAssertEqual(try model.store.loadDocument(id).files.first { $0.id == session.fileID }?.source, "Third")
    XCTAssertEqual(model.presence?.selectedItemID, notebook, "Queued history never switches or edits the new surface")
  }

  func testMessageSelectionFreezesABoundedDraftWithoutSavingOrOpeningChat() async throws {
    let (model, id, session) = try await fixture()
    let text = String(repeating: "x", count: 15_999) + "🪴" + " end"
    session.input(text, selection: .init(location: 0, length: text.utf16.count), composing: false, scroll: 0)
    let selection = try XCTUnwrap(session.messageSelection)
    XCTAssertEqual(selection.documentID, id)
    XCTAssertEqual(selection.fileID, session.fileID)
    XCTAssertEqual(selection.selectionEnd, text.utf16.count)
    XCTAssertEqual(selection.selectedText, String(repeating: "x", count: 15_999))
    XCTAssertTrue(selection.hasLocalDraft); XCTAssertNotNil(selection.draftID); XCTAssertTrue(selection.truncated)
    session.input("Later", selection: .init(location: 0, length: 5), composing: true, scroll: 0)
    XCTAssertNil(session.messageSelection, "Half of an IME transaction is not a selected message fragment")
    XCTAssertEqual(selection.selectionEnd, text.utf16.count, "A later contact cannot replace the frozen Send-time fragment")
    XCTAssertEqual(try model.store.loadDocument(id).files.first { $0.id == session.fileID }?.source, "")
  }
}

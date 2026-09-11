import SwiftUI
import UIKit
import NotebookCore

/// A vertical native document in window space, above the still-mounted board.
struct NotebookCodeDocumentView: View {
  @Environment(NotebookAppModel.self) private var model
  @Bindable var files: NotebookFileController
  @State private var editing = false
  @State private var findRequest = 0
  @State private var undoRequest = 0
  @State private var showsComparison = false
  var body: some View {
    if let document = files.document {
      VStack(spacing: 0) {
        HStack(spacing: 0) {
          VStack(alignment: .leading, spacing: 3) {
            Text((document.address.path as NSString).lastPathComponent).font(.system(size: 16, weight: .medium)).lineLimit(1)
            Text(status(document)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
          }.padding(.leading, 16).frame(maxWidth: .infinity, alignment: .leading)
          control("arrow.clockwise", "Обновить файл") { Task { await files.refresh() } }
          control("magnifyingglass", "Найти в коде") { findRequest += 1 }
          control("arrow.uturn.backward", "Отменить изменение текста") { undoRequest += 1 }
          control(editing ? "keyboard.chevron.compact.down" : "keyboard", editing ? "Скрыть клавиатуру" : "Редактировать код") { editing.toggle() }
          Menu {
            Button("Сравнить с файлом на Mac") { showsComparison = true }
            if document.other != nil {
              Button("Использовать версию Mac") { files.resolveUsingMac() }
              Button("Использовать мой исправленный черновик") { files.resolveUsingDraft() }
            }
          } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("Действия с файлом")
          control("square.and.arrow.down", "Сохранить файл на Mac") { files.save() }
            .disabled(files.saving || document.pending != nil || document.other != nil || document.text == document.base)
          control("xmark", "Закрыть файл") { editing = false; files.close() }
        }
        .background(Color(.secondarySystemBackground).opacity(0.65))
        if let message = files.error ?? (document.other == nil ? nil : "Конфликт: черновик и версия Mac сохранены. Сравните их в меню файла.") {
          Text(message).font(.system(size: 12)).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading).padding(10)
        }
        Divider()
        NotebookCodeEditor(files: files, document: document, editing: editing, findRequest: findRequest, undoRequest: undoRequest)
          .id(document.address.id)
      }
      .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 14))
      .clipShape(RoundedRectangle(cornerRadius: 14))
      .shadow(color: .black.opacity(0.1), radius: 16, y: 4)
      .background(NotebookControlRegion(gate: model.inputGate))
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("notebook-code-document")
      .sheet(isPresented: $showsComparison) {
        NavigationStack {
          ScrollView {
            VStack(alignment: .leading, spacing: 20) {
              Text("Мой черновик").font(.headline)
              Text(files.document?.text ?? "").font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
              Divider()
              Text(document.other == nil ? "Принятая версия Mac" : "Изменённая версия Mac").font(.headline)
              Text(files.document?.other ?? files.document?.base ?? "").font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
          }.navigationTitle(document.address.path).toolbar { Button("Готово") { showsComparison = false } }
        }
      }
    }
  }
  private func status(_ document: NotebookFileDraft) -> String {
    if document.pending != nil { return "Черновик на iPad · ожидается подтверждение Mac" }
    if document.other != nil { return "Конфликт · обе версии сохранены" }
    if document.text != document.base { return "Черновик на iPad" }
    return files.notice ?? document.address.path
  }
  private func control(_ image: String, _ label: String, action: @escaping () -> Void) -> some View {
    Button(action: action) { Image(systemName: image).font(.system(size: 16)).frame(width: 44, height: 44) }
      .accessibilityLabel(label).accessibilityIdentifier("code-" + image)
  }
}

struct NotebookCodeEditor: UIViewRepresentable {
  let files: NotebookFileController
  let document: NotebookFileDraft
  let editing: Bool
  let findRequest: Int
  let undoRequest: Int
  func makeCoordinator() -> Coordinator { Coordinator(files: files, address: document.address) }
  func makeUIView(context: Context) -> NotebookCodeTextView {
    let view = NotebookCodeTextView()
    view.delegate = context.coordinator
    view.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
    view.textColor = .label; view.backgroundColor = .systemBackground
    view.autocorrectionType = .no; view.autocapitalizationType = .none
    view.smartDashesType = .no; view.smartQuotesType = .no; view.smartInsertDeleteType = .no
    view.spellCheckingType = .no; view.isFindInteractionEnabled = true
    view.textContainerInset = .init(top: 18, left: 16, bottom: 100, right: 24)
    view.textContainer.widthTracksTextView = true
    view.alwaysBounceVertical = true; view.keyboardDismissMode = .interactive
    view.isEditable = false; view.isSelectable = true; view.text = document.text
    view.selectedRange = NSRange(location: document.selection, length: 0)
    view.accessibilityIdentifier = "notebook-code-text"
    view.initialScroll = document.scroll
    return view
  }
  func updateUIView(_ view: NotebookCodeTextView, context: Context) {
    let owner = context.coordinator
    owner.applying = true; defer { owner.applying = false }
    if view.text != document.text, view.markedTextRange == nil {
      let selection = view.selectedRange, position = view.contentOffset
      let old = view.text! as NSString, new = document.text as NSString
      var start = 0, oldEnd = old.length, newEnd = new.length
      while start < min(oldEnd, newEnd), old.character(at: start) == new.character(at: start) { start += 1 }
      while oldEnd > start, newEnd > start, old.character(at: oldEnd - 1) == new.character(at: newEnd - 1) { oldEnd -= 1; newEnd -= 1 }
      // A changed emoji can share its high surrogate with the old value. Never
      // bridge an isolated UTF-16 half through String when forming a patch.
      func low(_ value: NSString, _ index: Int) -> Bool { index < value.length && (0xdc00...0xdfff).contains(value.character(at: index)) }
      if start > 0, low(old, start) || low(new, start) { start -= 1 }
      if low(old, oldEnd) { oldEnd += 1 }
      if low(new, newEnd) { newEnd += 1 }
      // UIKit records the same local undo operation rather than replacing the
      // editor or clearing its stack when an accepted remote change arrives.
      if let from = view.position(from: view.beginningOfDocument, offset: start),
        let to = view.position(from: view.beginningOfDocument, offset: oldEnd), let range = view.textRange(from: from, to: to) {
        view.replace(range, withText: new.substring(with: NSRange(location: start, length: newEnd - start)))
      }
      view.selectedRange = NSRange(location: min(selection.location, new.length), length: min(selection.length, max(0, new.length - selection.location)))
      view.setContentOffset(position, animated: false)
    }
    if view.isEditable != editing {
      view.isEditable = editing
      if editing { view.becomeFirstResponder() } else { view.resignFirstResponder() }
    }
    if owner.findRequest != findRequest { owner.findRequest = findRequest; view.findInteraction?.presentFindNavigator(showingReplace: false) }
    if owner.undoRequest != undoRequest { owner.undoRequest = undoRequest; view.undoManager?.undo(); owner.applying = false; owner.textViewDidChange(view) }

  }
  static func dismantleUIView(_ view: NotebookCodeTextView, coordinator: Coordinator) {
    coordinator.textViewDidChange(view); view.delegate = nil; view.resignFirstResponder()
  }
  @MainActor final class Coordinator: NSObject, UITextViewDelegate {
    let files: NotebookFileController
    let address: NotebookFileAddress
    var applying = false, findRequest = 0, undoRequest = 0
    init(files: NotebookFileController, address: NotebookFileAddress) { self.files = files; self.address = address }
    func textViewDidChange(_ view: UITextView) {
      guard !applying else { return }
      files.edit(view.text, address: address, selection: view.selectedRange.location, scroll: max(0, view.contentOffset.y))
    }
    func textViewDidChangeSelection(_ view: UITextView) { position(view) }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { if let view = scrollView as? UITextView { position(view) } }
    private func position(_ view: UITextView) {
      guard !applying, (view as? NotebookCodeTextView)?.initialScroll == nil else { return }
      files.readPosition(address: address, selection: view.selectedRange.location, scroll: max(0, view.contentOffset.y))
    }
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
      (textView.text as NSString).replacingCharacters(in: range, with: text).utf8.count <= NotebookFileVersion.maximumBytes
    }
  }
}

/// Restore only after UIKit has measured the real text viewport. Construction
/// and SwiftUI updates may precede layout; neither owns a usable scroll range.
final class NotebookCodeTextView: UITextView {
  var initialScroll: Double?
  override func layoutSubviews() {
    super.layoutSubviews()
    guard let initialScroll, bounds.height > 0 else { return }
    self.initialScroll = nil
    setContentOffset(.init(x: 0, y: min(initialScroll, max(0, contentSize.height - bounds.height))), animated: false)
  }
}

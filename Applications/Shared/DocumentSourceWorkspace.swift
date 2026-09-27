import Foundation
import Observation
import SwiftUI
import NotebookCore
import NotebookTypesetter

private struct DocumentPaperVisibility: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
  var documentPaperVisible: Bool {
    get { self[DocumentPaperVisibility.self] }
    set { self[DocumentPaperVisibility.self] = newValue }
  }
}

enum DocumentViewMode: String, CaseIterable { case paper = "Лист", beside = "Рядом", code = "Код" }

struct DocumentViewModePicker: View {
  @Binding var mode: DocumentViewMode
  var allowsBeside = true
  var body: some View {
    Picker("Представление документа", selection: $mode) {
      ForEach(DocumentViewMode.allCases.filter { allowsBeside || $0 != .beside }, id: \.self) { Text($0.rawValue).tag($0) }
    }.pickerStyle(.segmented).accessibilityIdentifier("document-view-mode")
  }
}

struct DocumentSourceRequest: Sendable {
  let documentID: UUID
  let file: DocumentFile
  let version: ContentFieldVersion
  let offset: Int
  var fileID: String { file.id }
  var source: String { file.source }
  init(documentID: UUID, file: DocumentFile, version: ContentFieldVersion, offset: Int = 0) {
    self.documentID = documentID; self.file = file; self.version = version; self.offset = offset
  }
  static let notification = Notification.Name("Notebook.documentSourceRequest")
}

/// The next message freezes the current native selection, including an
/// unfinished human draft. A draft never claims to be a saved file revision.
struct DocumentSourceMessageSelection: Codable, Sendable {
  let documentID: UUID
  let fileID: String
  let path: String
  let baseVersion: ContentFieldVersion
  let selectionStart: Int
  let selectionEnd: Int
  let selectedText: String
  let hasLocalDraft: Bool
  let draftID: UUID?
  let sequence: UInt64?
  let truncated: Bool
}

/// A view of one addressed field. The document and common command executor
/// remain the only content and undo owners; unfinished input is a durable draft.
@MainActor @Observable
final class DocumentSourceEditorSession {
  let documentID: UUID
  let fileID: String
  private(set) var path: String
  private(set) var text: String
  private(set) var selection = NSRange(location: 0, length: 0)
  private(set) var navigation = UUID()
  private(set) var notice: String?
  private(set) var saving = false
  private(set) var conflicted = false
  private var base: String
  private var version: ContentFieldVersion
  private var sessionID: UUID
  private var sequence: UInt64
  private var composing = false
  private var scroll: Double = 0
  private var pending: Task<Void, Never>?
  private var commitTask: Task<Void, Never>?
  private weak var model: NotebookAppModel?
  private var frozen: UUID?

  init(request: DocumentSourceRequest, model: NotebookAppModel) {
    self.model = model; documentID = request.documentID; fileID = request.fileID; path = request.file.path
    let draft = model.documentEditingSessions.last { $0.edit.documentID == request.documentID && $0.edit.fileID == request.fileID }
    text = draft?.edit.source ?? request.source; base = draft?.edit.baseSource ?? request.source
    version = draft?.edit.baseVersion ?? request.version; sessionID = draft?.id ?? UUID(); sequence = draft?.edit.sequence ?? 0
    let start = min(text.utf16.count, draft?.selectionStart ?? request.offset)
    selection = NSRange(location: start, length: min(text.utf16.count - start, max(0, (draft?.selectionEnd ?? start) - start)))
    scroll = draft?.scrollTop ?? 0
    conflicted = draft?.phase == .conflict || draft?.phase == .targetMissing
    if conflicted { notice = "Исходник изменился. Ваш черновик сохранён; сравните версии." }
    model.documentSourceEditor = self
  }
  var restoredScroll: Double { scroll }
  private var edit: DocumentSourceEdit {
    .init(sessionID: sessionID, documentID: documentID, fileID: fileID, baseSource: base,
      baseVersion: version, source: text, sequence: sequence)
  }
  func input(_ value: String, selection: NSRange, composing: Bool, scroll: Double) {
    let changed = text != value, compositionEnded = self.composing && !composing
    if changed, frozen == sessionID { sessionID = UUID(); sequence = 0 }
    text = value; self.selection = selection; self.composing = composing; self.scroll = max(0, scroll)
    guard changed || composing || compositionEnded else { return }
    persist()
    pending?.cancel()
    if !composing, !saving, !conflicted {
      pending = Task { [weak self] in
        do { try await Task.sleep(for: .milliseconds(500)); try Task.checkCancellation(); await self?.save() } catch { }
      }
    }
  }
  private func persist() {
    sequence += 1
    model?.saveDocumentDraft(.init(edit: edit, selectionStart: selection.location,
      selectionEnd: NSMaxRange(selection), isComposing: composing, scrollTop: scroll))
  }
  func save() async {
    if let commitTask { await commitTask.value; return }
    pending?.cancel(); pending = nil
    let task = Task { await commitInput() }
    commitTask = task
    await task.value
    commitTask = nil
  }
  private func commitInput() async {
    guard !saving, !composing, !conflicted, text != base, let model else { return }
    pending = nil; persist()
    let submitted = edit
    frozen = submitted.sessionID; saving = true; notice = "Сохранение…"
    do {
      var acceptedVersion: ContentFieldVersion?
      let status = try await model.commitDocumentSource(edit: submitted) { acceptedVersion = $0.publication?.sourceVersion }
      guard status == .committed, let acceptedVersion else {
        conflicted = true; notice = status == .targetMissing ? "Файл удалён. Черновик сохранён." : "Исходник изменился. Черновик сохранён; сравните версии."
        saving = false; frozen = nil; return
      }
      let unfinished = sessionID != submitted.sessionID ? sessionID : nil
      base = submitted.source; version = acceptedVersion
      sessionID = UUID(); sequence = 0; frozen = nil; saving = false; notice = "Сохранено"
      if text != base {
        // Persist the rebased successor before retiring the input typed while
        // the previous transaction was in flight. Neither session changes its
        // original owner, and a crash cannot erase this newer text.
        persist()
        if let unfinished { model.discardDocumentDraft(unfinished) }
        await commitInput()
      } else if let unfinished { model.discardDocumentDraft(unfinished) }
    } catch { saving = false; frozen = nil; notice = error.localizedDescription }
  }
  var messageSelection: DocumentSourceMessageSelection? {
    guard !composing, selection.length > 0 else { return nil }
    let source = text as NSString
    let start = min(max(0, selection.location), source.length)
    let end = min(max(start, NSMaxRange(selection)), source.length)
    var excerptEnd = min(end, start + 16_000)
    if excerptEnd < end, excerptEnd > start, (0xD800...0xDBFF).contains(source.character(at: excerptEnd - 1)) { excerptEnd -= 1 }
    let draft = text != base || conflicted
    return .init(documentID: documentID, fileID: fileID, path: path, baseVersion: version,
      selectionStart: start, selectionEnd: end,
      selectedText: source.substring(with: .init(location: start, length: excerptEnd - start)),
      hasLocalDraft: draft, draftID: draft ? sessionID : nil, sequence: draft ? sequence : nil,
      truncated: excerptEnd < end)
  }
  func undo() { performHistory(redo: false) }
  func redo() { performHistory(redo: true) }
  private func performHistory(redo: Bool) {
    model?.performSurfaceHistory(redo: redo, documentID: documentID) { [self] in
      await save()
      return !conflicted && !composing && text == base
    }
  }
  func reconcile(_ document: DocumentDocument) {
    if let file = document.files.first(where: { $0.id == fileID }) { path = file.path }
    guard !saving, text == base, document.id == documentID,
      let current = source(in: document), current.version != version else { return }
    base = current.text; text = base; version = current.version
    sessionID = UUID(); sequence = 0; notice = nil; navigate(selection.location)
  }
  private func source(in document: DocumentDocument) -> (text: String, version: ContentFieldVersion)? {
    return document.files.first(where: { $0.id == fileID && $0.isText }).map { ($0.source, document.fileVersion(fileID: fileID)) }
  }
  func navigate(_ offset: Int) {
    selection = NSRange(location: min(max(0, offset), text.utf16.count), length: 0); navigation = UUID()
  }
  func finish() { pending?.cancel(); pending = nil; if text != base { persist(); Task { await save() } } }
  /// A composing input is retained as a draft rather than committed halfway
  /// through an IME transaction. The caller drains the same persistence FIFO.
  func checkpoint() async { if composing { persist() }; await save() }
  var maximumSourceLength: Int { DocumentFile.maximumSourceLength }
  func useCurrentDocument() {
    guard !saving, let model, let document = model.documents[documentID], let current = source(in: document) else { return }
    model.discardDocumentDraft(sessionID)
    base = current.text; version = current.version; text = base
    sessionID = UUID(); sequence = 0; conflicted = false; notice = nil; navigate(0)
  }
  /// Resolving a conflict is explicit. It creates a new draft against the
  /// displayed current source; the following normal CAS can still reject it.
  func rebaseDraft() {
    guard !saving, let model, let document = model.documents[documentID], let current = source(in: document) else { return }
    let old = sessionID
    base = current.text; version = current.version
    sessionID = UUID(); sequence = 0; conflicted = false; persist(); model.discardDocumentDraft(old)
    Task { await save() }
  }
  var currentSource: String? { model?.documents[documentID].flatMap { source(in: $0)?.text } }
  isolated deinit { pending?.cancel() }
}

/// Window-space editing never installs a second scene or camera. Paper stays
/// mounted when code is shown; split width flows through the existing viewport.
struct DocumentSourceWorkspace<Paper: View>: View {
  @Environment(NotebookAppModel.self) private var model
  @Binding var mode: DocumentViewMode
  var topInset: CGFloat = 0
  let allowsBeside: Bool
  @State private var session: DocumentSourceEditorSession?
  @State private var resourceID: String?
  @State private var filePath = ""
  @State private var fileOperation: FileOperation?
  private enum FileOperation: String, Identifiable { case create, rename; var id: String { rawValue } }
  @State private var comparison = false
  @State private var printStatus = ""
  @State private var diagnostics: [NotebookPrintDiagnostic] = []
  @State private var printTask: Task<Void, Never>?
  @State private var printedSource: DocumentPrintedSource?
  let paper: Paper
  init(mode: Binding<DocumentViewMode>, topInset: CGFloat = 0, allowsBeside: Bool = true, @ViewBuilder paper: () -> Paper) {
    _mode = mode; self.topInset = topInset; self.allowsBeside = allowsBeside; self.paper = paper()
  }

  var body: some View {
    GeometryReader { geometry in
      let document = model.activeDocument
      let showing = document != nil && mode != .paper
      let width = mode == .code ? geometry.size.width : min(680, geometry.size.width * 0.48)
      let editorTop = topInset + 56
      ZStack(alignment: .leading) {
        paper.padding(.leading, showing && mode == .beside ? width : 0)
          .environment(\.documentPaperVisible, mode != .code)
          .opacity(mode == .code ? 0 : 1)
          .allowsHitTesting(mode != .code)
          .accessibilityHidden(mode == .code)
          .overlay(alignment: .bottom) {
            if mode == .paper, !printStatus.isEmpty {
              Text(printStatus).font(.caption).lineLimit(3).padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 24).padding(.bottom, 86).accessibilityIdentifier("document-print-status")
            }
          }
        if showing, let document {
          editor(document)
            .frame(width: width, height: max(0, geometry.size.height - editorTop), alignment: .top)
            .background(.background)
            #if os(iOS)
            .background(NotebookControlRegion(gate: model.inputGate))
            #endif
            .overlay(alignment: .trailing) {
              if mode == .beside { Rectangle().fill(.quaternary).frame(width: 1) }
            }.padding(.top, editorTop)
        }
      }
      .overlay(alignment: .topLeading) {
        if let document {
          header(document)
            .frame(maxWidth: min(460, (mode == .beside ? width : geometry.size.width) - 36), alignment: .leading)
            .padding(.horizontal, 18).padding(.top, topInset)
            #if os(iOS)
            .background(NotebookControlRegion(gate: model.inputGate))
            #endif
        }
      }
      .onChange(of: mode) { _, value in
        if value == .paper { session?.finish() }
        else if session == nil, resourceID == nil, let document, let file = document.files.first(where: { $0.path == document.entrypoint }) { open(.init(documentID: document.id, file: file, version: document.fileVersion(fileID: file.id))) }
      }
      .onChange(of: allowsBeside, initial: true) { _, allowed in
        if !allowed, mode == .beside { mode = .code }
      }
      .onChange(of: document) { _, value in if let value { session?.reconcile(value) } }
      .onChange(of: document?.id) { _, _ in session?.finish(); session = nil; resourceID = nil; mode = .paper }
      .onReceive(NotificationCenter.default.publisher(for: DocumentSourceRequest.notification)) { note in
        guard let request = note.object as? DocumentSourceRequest, request.documentID == model.activeDocument?.id else { return }
        open(request); if mode == .paper { mode = allowsBeside ? .beside : .code }
      }
      .onChange(of: document, initial: true) { _, value in preparePrint(value) }
    }
    .onDisappear { session?.finish(); printTask?.cancel(); printTask = nil }
    .sheet(isPresented: $comparison) {
      VStack(alignment: .leading, spacing: 12) {
        Text("Версии исходника").font(.headline)
        HStack(alignment: .top) {
          ScrollView { Text(session?.text ?? "").font(.system(.body, design: .monospaced)).textSelection(.enabled) }
          Divider()
          ScrollView { Text(session?.currentSource ?? "Файл удалён").font(.system(.body, design: .monospaced)).textSelection(.enabled) }
        }
        HStack {
          Button("Оставить черновик") { comparison = false }
          Spacer()
          Button("Принять текущий исходник") { session?.useCurrentDocument(); comparison = false }
          Button("Применить мой черновик") { session?.rebaseDraft(); comparison = false }.disabled(session?.currentSource == nil)
        }
      }.padding(20).frame(minWidth: 500, minHeight: 360)
    }
  }
  private func preparePrint(_ document: DocumentDocument?) {
    printTask?.cancel(); diagnostics = []
    guard let document else { printedSource = nil; printStatus = ""; return }
    printStatus = "Обновляем печатный лист…"
    printTask = Task {
      do {
        let owner = DocumentRenderRegistry.shared.session(documentID: document.id, resources: SceneRenderResources.shared)
        let source = owner.source(document, store: model.store)
        let printed = try await source.printedSource(resources: SceneRenderResources.shared)
        try Task.checkCancellation(); printedSource = printed; diagnostics = printed.artifact.diagnostics; printStatus = ""
      } catch is CancellationError { } catch {
        guard !Task.isCancelled else { return }
        diagnostics = (error as? NotebookTypesetterError)?.diagnostics ?? []
        printStatus = diagnostics.first?.message ?? error.localizedDescription
      }
    }
  }
  @ViewBuilder private func editor(_ document: DocumentDocument) -> some View {
    let resource = document.files.first { $0.id == resourceID }
    VStack(spacing: 0) {
      if let session {
        DocumentNativeSourceEditor(session: session,
          revealSelection: canRevealSelection(document) ? { revealSelection(document, range: $0) } : nil)
          .id(ObjectIdentifier(session))
          .accessibilityIdentifier("document-source-editor")
        HStack {
          Text(session.notice ?? "Изменения сохраняются автоматически").lineLimit(2)
          Spacer()
          if session.conflicted { Button("Сравнить") { comparison = true } }
        }.font(.caption).padding(12)
      } else if let resource {
        ContentUnavailableView("Двоичный ресурс", systemImage: "doc", description: Text(resource.path))
      } else {
        ProgressView("Открываем исходник…").frame(maxWidth: .infinity, maxHeight: .infinity)
          .onAppear { if let file = document.files.first(where: { $0.path == document.entrypoint }) {
            open(.init(documentID: document.id, file: file, version: document.fileVersion(fileID: file.id)))
          } }
      }
      ForEach(diagnostics) { diagnostic in
        Button("\(diagnostic.path ?? document.entrypoint):\(diagnostic.line): \(diagnostic.message)") {
          guard let file = document.files.first(where: { $0.path == (diagnostic.path ?? document.entrypoint) && $0.isText }) else { return }
          let offset = file.source.split(separator: "\n", omittingEmptySubsequences: false).prefix(max(0, diagnostic.line-1)).reduce(0) { $0 + $1.utf16.count + 1 }
          open(.init(documentID: document.id, file: file, version: document.fileVersion(fileID: file.id), offset: offset))
        }.font(.caption).lineLimit(2).padding(.horizontal, 12)
      }
      if !printStatus.isEmpty {
        Text(printStatus).font(.caption).foregroundStyle(.secondary).lineLimit(4).padding(12)
          .accessibilityIdentifier("document-print-status")
      }
    }
  }
  private func header(_ document: DocumentDocument) -> some View {
    HStack(spacing: 10) {
      DocumentViewModePicker(mode: $mode, allowsBeside: allowsBeside)
        .frame(width: allowsBeside ? 216 : 144)
      Menu {
        ForEach(document.files.sorted { $0.path < $1.path }) { file in
          Button(file.path) {
            open(.init(documentID: document.id, file: file, version: document.fileVersion(fileID: file.id)))
            if mode == .paper { mode = allowsBeside ? .beside : .code }
          }
        }
        Divider()
        Button("Новый файл…") { filePath = ""; fileOperation = .create }
        Button("Переименовать…") { filePath = session?.path ?? document.files.first { $0.id == resourceID }?.path ?? document.entrypoint; fileOperation = .rename }
      } label: {
        Label(session?.path ?? document.files.first { $0.id == resourceID }?.path ?? document.entrypoint, systemImage: "doc.text")
          .lineLimit(1).truncationMode(.middle).frame(width: 140, alignment: .leading)
      }.accessibilityIdentifier("document-source-menu")
    }.padding(6).frame(height: 44).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    .accessibilityElement(children: .contain).accessibilityIdentifier("document-source-header")
    .sheet(item: $fileOperation) { operation in
      VStack(alignment: .leading, spacing: 16) {
        Text(operation == .create ? "Новый файл" : "Переименовать файл").font(.headline)
        TextField("Относительный путь, например chapters/intro.tex", text: $filePath)
          .textFieldStyle(.roundedBorder)
        HStack {
          Button("Отмена") { fileOperation = nil }
          Spacer()
          Button("Сохранить") { changeFile(operation, document: document) }
            .disabled(filePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }.padding(20).frame(minWidth: 400)
    }
  }
  private func changeFile(_ operation: FileOperation, document: DocumentDocument) {
    let path = filePath, fileID = session?.fileID ?? resourceID ?? document.files.first { $0.path == document.entrypoint }?.id
    Task {
      await session?.save()
      guard session?.conflicted != true else { return }
      do {
        let request: DocumentSourceRequest
        if operation == .create { request = try await model.insertDocumentFile(documentID: document.id, path: path) }
        else if let fileID { request = try await model.renameDocumentFile(documentID: document.id, fileID: fileID, path: path) }
        else { return }
        fileOperation = nil; open(request)
        if mode == .paper { mode = allowsBeside ? .beside : .code }
      } catch { printStatus = error.localizedDescription }
    }
  }
  private func open(_ request: DocumentSourceRequest) {
    if !request.file.isText { session?.finish(); session = nil; resourceID = request.fileID; return }
    if session?.fileID == request.fileID, session?.documentID == request.documentID { session?.navigate(request.offset); return }
    session?.finish(); resourceID = nil; session = .init(request: request, model: model)
  }
  private func canRevealSelection(_ document: DocumentDocument) -> Bool {
    guard let session, let printedSource else { return false }
    return printedSource.artifact.document == document
      && session.text == document.files.first(where: { $0.id == session.fileID })?.source
  }
  private func revealSelection(_ document: DocumentDocument, range: NSRange) {
    guard canRevealSelection(document), let session,
      let reference = printedSource?.reference(fileID: session.fileID, sourceOffset: range.location) else { return }
    if mode == .code { mode = .paper }
    model.requestShow(reference)
  }
}

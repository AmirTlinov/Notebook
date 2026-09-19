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
  enum Contents: Sendable { case block(DocumentBlock), preamble(String) }
  let documentID: UUID
  let contents: Contents
  let version: ContentFieldVersion
  let offset: Int
  var blockID: String { if case .block(let block) = contents { block.id } else { "preamble" } }
  var source: String { switch contents { case .block(let block): block.source; case .preamble(let source): source } }
  var kind: DocumentBlockKind { if case .block(let block) = contents { block.kind } else { .latex } }
  var field: DocumentSourceEdit.Field { if case .preamble = contents { .preamble } else { .content } }
  init(documentID: UUID, block: DocumentBlock, version: ContentFieldVersion, offset: Int) {
    self.documentID = documentID; contents = .block(block); self.version = version; self.offset = offset
  }
  init(preamble document: DocumentDocument) {
    documentID = document.id; contents = .preamble(document.preamble); version = document.preambleVersion; offset = 0
  }
  static let notification = Notification.Name("Notebook.documentSourceRequest")
}

/// A view of one addressed field. The document and common command executor
/// remain the only content and undo owners; unfinished input is a durable draft.
@MainActor @Observable
final class DocumentSourceEditorSession {
  let documentID: UUID
  let blockID: String
  let kind: DocumentBlockKind
  let field: DocumentSourceEdit.Field
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
    self.model = model; documentID = request.documentID; blockID = request.blockID; kind = request.kind; field = request.field
    let draft = model.documentEditingSessions.last { $0.edit.documentID == request.documentID && $0.edit.blockID == request.blockID && ($0.edit.field ?? .content) == request.field }
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
    .init(sessionID: sessionID, documentID: documentID, blockID: blockID, baseSource: base,
      baseVersion: version, source: text, sequence: sequence, field: field)
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
      let status = try await model.commitDocumentSource(edit: submitted) { acceptedVersion = $0.publication?.sourceVersion ?? $0.preamblePublication?.sourceVersion }
      guard status == .committed, let acceptedVersion else {
        conflicted = true; notice = status == .targetMissing ? "Блок удалён. Черновик сохранён." : "Исходник изменился. Черновик сохранён; сравните версии."
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
  var canAskAgent: Bool { field == .content && selection.length > 0 && selection.length <= 16_000 && !conflicted }
  func askAgent() {
    let selected = selection, selectedText = text
    Task {
      await save()
      guard !conflicted, !composing, text == base, text == selectedText, canAskAgent else { return }
      model?.selectSourceForAgent(documentID: documentID, blockID: blockID, version: version, range: selected)
    }
  }
  func undo() {
    Task {
      await save()
      guard !conflicted, !composing, text == base else { return }
      model?.undoLastSurfaceAction()
    }
  }
  func reconcile(_ document: DocumentDocument) {
    guard !saving, text == base, document.id == documentID,
      let current = source(in: document), current.version != version else { return }
    base = current.text; text = base; version = current.version
    sessionID = UUID(); sequence = 0; notice = nil; navigate(selection.location)
  }
  private func source(in document: DocumentDocument) -> (text: String, version: ContentFieldVersion)? {
    if field == .preamble { return (document.preamble, document.preambleVersion) }
    return document.blocks.first(where: { $0.id == blockID }).map { ($0.source, document.sourceVersion(blockID: blockID)) }
  }
  func navigate(_ offset: Int) {
    selection = NSRange(location: min(max(0, offset), text.utf16.count), length: 0); navigation = UUID()
  }
  func finish() { pending?.cancel(); pending = nil; if text != base { persist(); Task { await save() } } }
  /// A composing input is retained as a draft rather than committed halfway
  /// through an IME transaction. The caller drains the same persistence FIFO.
  func checkpoint() async { if composing { persist() }; await save() }
  var maximumSourceLength: Int { field == .preamble ? 200_000 : DocumentBlock.maximumSourceLength }
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
  @State private var programID: String?
  @State private var find = 0
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
            .frame(width: width, height: max(0, geometry.size.height - topInset), alignment: .top)
            .background(.background)
            #if os(iOS)
            .background(NotebookControlRegion(gate: model.inputGate))
            #endif
            .overlay(alignment: .trailing) {
              if mode == .beside { Rectangle().fill(.quaternary).frame(width: 1) }
            }.padding(.top, topInset)
        }

      }
      .onChange(of: mode) { _, value in
        if value == .paper { session?.finish() }
      }
      .onChange(of: allowsBeside, initial: true) { _, allowed in
        if !allowed, mode == .beside { mode = .code }
      }
      .onChange(of: document) { _, value in if let value { session?.reconcile(value) } }
      .onChange(of: document?.id) { _, _ in session?.finish(); session = nil; programID = nil; mode = .paper }
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
          ScrollView { Text(session?.currentSource ?? "Блок удалён").font(.system(.body, design: .monospaced)).textSelection(.enabled) }
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
        let source = owner.source(document)
        let printed = try await source.printedSource(resources: SceneRenderResources.shared)
        try Task.checkCancellation(); printedSource = printed; printStatus = ""
      } catch is CancellationError { } catch {
        guard !Task.isCancelled else { return }
        diagnostics = (error as? NotebookTypesetterError)?.diagnostics ?? []
        printStatus = diagnostics.first?.message ?? error.localizedDescription
      }
    }
  }
  @ViewBuilder private func editor(_ document: DocumentDocument) -> some View {
    let program = document.blocks.first { $0.id == programID && $0.kind == .interactive }
    VStack(spacing: 0) {
      HStack {
        Menu {
          Button("Документ LaTeX") { showSource() }
          Divider()
          Button("Добавить LaTeX") { insert(.tex, document: document) }
          Button("Добавить текст") { insert(.markdown, document: document) }
          Divider()
          Button("Преамбула LaTeX") { open(.init(preamble: document)) }
          Divider()
          ForEach(document.blocks) { block in
            if block.kind == .interactive {
              Button("Программа · \(block.id)") { showSource(program: block.id) }
            } else {
              Button("\(block.kind.rawValue) · \(block.id)") { open(.init(documentID: document.id, block: block, version: document.sourceVersion(blockID: block.id), offset: 0)) }
            }
          }
        } label: { Label(session.map { $0.field == .preamble ? "Преамбула LaTeX" : "\($0.blockID) · \($0.kind.rawValue)" }
          ?? program.map { "Программа · \($0.id)" } ?? "Документ LaTeX", systemImage: "doc.text").lineLimit(1) }
        .accessibilityIdentifier("document-source-menu")
        Spacer()
        Button { find += 1 } label: { Image(systemName: "magnifyingglass") }.accessibilityLabel("Найти в исходнике")
        if let session {
          Button { revealSelection(document) } label: { Image(systemName: "doc.viewfinder") }.accessibilityLabel("Показать на листе")
          Button { session.askAgent() } label: { Image(systemName: "bubble.left.and.text.bubble.right") }
            .accessibilityLabel("Обсудить выделенный исходник").disabled(!session.canAskAgent)
          Button { session.undo() } label: { Image(systemName: "arrow.uturn.backward") }.accessibilityLabel("Отменить действие")
        }
      }.padding(14)
      if let session {
        DocumentNativeSourceEditor(session: session, findRequest: find).id(ObjectIdentifier(session))
          .accessibilityIdentifier("document-source-editor")
        HStack {
          Text(session.notice ?? "Изменения сохраняются автоматически").lineLimit(2)
          Spacer()
          if session.conflicted { Button("Сравнить") { comparison = true } }
        }.font(.caption).padding(12)
      } else if let program {
        DocumentProgramSourceView(block: program, store: model.store, findRequest: find).id(program.id)
      } else if let printedSource, printedSource.artifact.document == document {
        DocumentNativeSourceViewer(text: printedSource.artifact.source, findRequest: find)
          .accessibilityIdentifier("document-latex-source-viewer")
        Text("Собранный LaTeX · только чтение. Для правки выберите блок в меню исходника.")
          .font(.caption).foregroundStyle(.secondary).padding(12)
      } else {
        ContentUnavailableView("LaTeX ещё не собран", systemImage: "doc.text", description:
          Text("Исходники отдельных блоков и программ доступны в меню выше."))
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      ForEach(diagnostics) { diagnostic in
        Button("Строка \(diagnostic.line): \(diagnostic.message)") {
          if let id = diagnostic.blockID, let block = document.blocks.first(where: { $0.id == id }) {
            let offset = block.source.split(separator: "\n", omittingEmptySubsequences: false).prefix(diagnostic.line-1).reduce(0) { $0 + $1.utf16.count + 1 }
            open(.init(documentID: document.id, block: block, version: document.sourceVersion(blockID: id), offset: offset))
          } else { open(.init(preamble: document)) }
        }.font(.caption).lineLimit(2).padding(.horizontal, 12)
      }
      if !printStatus.isEmpty {
        Text(printStatus).font(.caption).foregroundStyle(.secondary).lineLimit(4).padding(12)
          .accessibilityIdentifier("document-print-status")
      }
    }
  }
  private func insert(_ kind: DocumentBlockKind, document: DocumentDocument) {
    Task {
      await session?.save()
      do { open(try await model.insertDocumentSource(documentID: document.id, kind: kind)) }
      catch { printStatus = error.localizedDescription }
    }
  }
  private func showSource(program: String? = nil) {
    session?.finish(); session = nil; programID = program
  }
  private func open(_ request: DocumentSourceRequest) {
    if case .block(let block) = request.contents, block.kind == .interactive { showSource(program: block.id); return }
    if session?.blockID == request.blockID, session?.field == request.field, session?.documentID == request.documentID { session?.navigate(request.offset); return }
    session?.finish(); programID = nil; session = .init(request: request, model: model)
  }
  private func revealSelection(_ document: DocumentDocument) {
    guard let session, let printedSource, printedSource.artifact.document == document,
      session.field == .content,
      session.text == document.blocks.first(where: { $0.id == session.blockID })?.source,
      let reference = printedSource.reference(blockID: session.blockID, sourceOffset: session.selection.location) else { return }
    if mode == .code { mode = .paper }
    model.requestShow(reference)
  }
}

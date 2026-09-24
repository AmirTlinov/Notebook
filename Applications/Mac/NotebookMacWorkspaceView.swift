import AppKit
import NotebookCore
import SwiftUI

/// A window is a presentation of the process-owned model, never another store.
struct NotebookMacWorkspaceRoot: View {
  let lifecycle: NotebookMacLifecycle
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    Group {
      if let model = lifecycle.launch.model {
        NotebookMacWorkspaceView(showPaste: lifecycle.showPaste)
          .environment(model).id(ObjectIdentifier(model))
          .disabled(model.shutdownPhase != .running)
          .onChange(of: scenePhase, initial: true) { _, phase in
            model.setSelectionSurfaceActive(phase == .active)
            if phase == .active { model.refreshDeviceConnection() }
          }
          .onDisappear {
            model.setSelectionSurfaceActive(false)
            Task { await model.finishPendingInteraction() }
          }
      } else if lifecycle.launch.hasNoWorkspace {
        NotebookWorkspacesView(launch: lifecycle.launch)
      } else {
        VStack(spacing: 16) {
          if lifecycle.launch.failure == nil { ProgressView() }
          Text(lifecycle.launch.message)
          if lifecycle.launch.failure != nil { Button("Повторить") { lifecycle.start() } }
        }.padding(32)
      }
    }
    .frame(minWidth: 760, minHeight: 520)
    .preferredColorScheme(.light)
    .sheet(isPresented: Binding(get: { lifecycle.launch.showsWorkspaces }, set: { lifecycle.launch.showsWorkspaces = $0 })) {
      NotebookWorkspacesView(launch: lifecycle.launch).frame(width: 560, height: 500)
    }
  }
}

struct NotebookMacWorkspaceView: View {
  @Environment(NotebookAppModel.self) private var model
  let showPaste: () -> Void
  @State private var showsSearch = false
  @State private var documentLayout: DocumentPageLayout?
  @State private var documentMode = DocumentViewMode.paper

  var body: some View {
    Group {
      switch model.loadState {
      case .ready:
        DocumentSourceWorkspace(mode: $documentMode) { NotebookMacCanvas(documentLayout: $documentLayout) }
      case .loading:
        VStack(spacing: 12) {
          ProgressView(model.awaitingAccountContent ? "Открываем ваши материалы…" : "Открываем пространство…")
          Button("Пространства") { model.openWorkspaceLibrary?(.spaces) }
        }
      case .failed(let message):
        ContentUnavailableView("Не удалось открыть пространство", systemImage: "exclamationmark.triangle", description: Text(message))
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(red: 0.965, green: 0.957, blue: 0.925))
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if let failure = model.persistenceFailure {
        HStack {
          Label("Изменения ещё не сохранены", systemImage: "exclamationmark.triangle")
          Text(failure).lineLimit(1).foregroundStyle(.secondary)
          Spacer()
          Button("Повторить") { model.retryPendingPersistence() }
        }.font(.callout).padding(10).background(.bar)
      }
    }
    .toolbar {
      ToolbarItem(placement: .principal) {
        if model.activeDocument != nil { DocumentViewModePicker(mode: $documentMode).frame(width: 224) }
      }
      ToolbarItemGroup(placement: .navigation) {
        Button(action: model.macGoBack) { Label("Назад", systemImage: "chevron.left") }
          .disabled(!model.macCanGoBack).keyboardShortcut("[", modifiers: .command)
          .accessibilityIdentifier("mac-workspace-back")
        Button { model.openWorkspaceLibrary?(.spaces) } label: {
          Text(model.workspaceName).lineLimit(1)
        }.accessibilityIdentifier("workspaces-open")
      }
      ToolbarItemGroup {
        if let presence = model.presence, presence.mode == .page || presence.mode == .document {
          Button { turnPage(-1) } label: { Label("Предыдущая страница", systemImage: "chevron.left") }
            .disabled(pageIndex == 0).accessibilityIdentifier("previous-page")
          Text("\(pageIndex + 1) / \(pageCount.map(String.init) ?? "…")")
            .monospacedDigit().accessibilityIdentifier("page-counter")
          Button { turnPage(1) } label: { Label("Следующая страница", systemImage: "chevron.right") }
            .disabled(presence.mode == .document && (pageCount == nil || pageIndex + 1 >= pageCount!))
            .accessibilityIdentifier("next-page")
        }
      }
      ToolbarItemGroup {
        if model.presence?.mode == .page || model.presence?.mode == .document {
          Menu {
            Button("По ширине") { model.macFitReading(.width) }
            Button("Вся страница") { model.macFitReading(.page) }
            Button("100%") { model.macFitReading(.actual) }
          } label: {
            Text("\(Int(((model.presence?.camera.scale ?? 1) * 100).rounded()))%")
              .monospacedDigit()
          }.accessibilityIdentifier("mac-reading-zoom")
        }
      }
      ToolbarItemGroup {
        if model.isPageOpen {
          Picker("Инструмент", selection: Binding(get: { model.macInputTool }, set: model.selectMacInputTool)) {
            Label("Выбор", systemImage: "cursorarrow").tag(MacNotebookInputTool.pointer)
            Label("Ручка", systemImage: "pencil.tip").tag(MacNotebookInputTool.pen)
            Label("Ластик", systemImage: "eraser").tag(MacNotebookInputTool.eraser)
          }.pickerStyle(.segmented).frame(width: 118).accessibilityIdentifier("mac-input-tool")
          Menu {
            ForEach(PenColor.allCases) { color in
              Button(color.name) { model.selectPenColor(color) }
            }
            Divider()
            ForEach([1.0, 2.2, 4.0, 8.0], id: \.self) { width in
              Button("Толщина \(width.formatted())") { model.selectPenWidth(width) }
            }
          } label: { Label("Параметры ручки", systemImage: "slider.horizontal.3") }
        }
        Menu {
          Button("Тетрадь") { model.macCreateItem(.notebook) }
          Button("Документ") { model.macCreateItem(.document) }
          Button("Доска") { model.macCreateItem(.board) }
        } label: { Label("Создать", systemImage: "plus") }
          .accessibilityIdentifier("create-workspace-item")
        Button(action: showPaste) { Label("Вставить", systemImage: "document.on.clipboard") }
          .disabled(model.pasteDestinations.isEmpty)
        Button { showsSearch = true } label: { Label("Найти", systemImage: "magnifyingglass") }
          .keyboardShortcut("f", modifiers: .command)
      }
    }
    .sheet(isPresented: $showsSearch) { NotebookSearchView().environment(model).frame(width: 560, height: 500) }
    .onChange(of: model.presence?.focusedItemID) { _, _ in documentLayout = nil }
    .navigationTitle(model.activeItem.flatMap { $0.title.isEmpty ? nil : $0.title } ?? "Notebook")
    .accessibilityIdentifier("notebook-workspace")
  }

  private var pageIndex: Int {
    guard let p = model.presence else { return 0 }
    if p.mode == .document { return p.documentPageIndex }
    return p.notebookPageID.flatMap { id in p.focusedItemID.flatMap { model.notebookPageIndex(id, in: $0) } } ?? 0
  }
  private var pageCount: Int? {
    guard let p = model.presence, let item = p.focusedItemID else { return nil }
    if p.mode == .document { return model.documents[item].flatMap { documentLayout?.pageCount(for: NotebookAppModel.documentPageSourceRevision($0)) } }
    return model.notebookPageCount(item)
  }
  private func turnPage(_ delta: Int) {
    guard let p = model.presence, let item = p.focusedItemID else { return }
    let target = pageIndex + delta
    guard target >= 0 else { return }
    model.afterPageInput {
      model.macReadingTop()
      if p.mode == .document { _ = model.selectDocumentPage(target, documentID: item) }
      else if let root = model.notebookPageRoot(item) {
        _ = model.notebookPageNavigation.send(.step(delta), ownerID: item, source: root)
      }
    }
  }
}

enum MacNotebookInputTool: Hashable { case pointer, pen, eraser }

extension NotebookAppModel {
  func selectMacInputTool(_ tool: MacNotebookInputTool) {
    afterPageInput { [weak self] in
      guard let self else { return }
      macInputTool = tool
      if tool != .pointer { selectDrawingTool(tool == .pen ? .pen : .eraser) }
    }
  }

  var macCanGoBack: Bool {
    guard let p = presence else { return false }
    return !returnPlaces.isEmpty || p.mode != .board || p.boardID != workspace?.rootBoardID
  }

  func macGoBack() {
    afterPageInput { [self] in
      guard let p = presence else { return }
      if !returnPlaces.isEmpty { requestReturnToPlace(); return }
      cancelRequestedNavigation(); endSurfaceEditing(); macInputTool = .pointer
      if p.mode == .board { _ = leaveBoard() }
      guard let current = presence else { return }
      updatePresence(.init(boardID: current.boardID, mode: .board,
        camera: .init(center: current.camera.center, scale: itemGeometry(current.focusedItemID).coverScale(viewport: current.viewport)),
        viewport: current.viewport, selectedItemID: current.selectedItemID, notebookPageID: current.notebookPageID), settled: true)
    }
  }

  func macOpenItem(_ itemID: UUID) {
    afterPageInput { [self] in
      guard let p = presence, !isItemBeingDeleted(itemID),
        let item = itemForDisplay(id: itemID),
        let center = boardHierarchy?.board(p.boardID)?.focusedCenter(of: itemID) else { return }
      cancelRequestedNavigation(); endSurfaceEditing(); rememberReturnPlace(); selectItem(itemID)
      if item.kind == .board { _ = enterBoard(itemID); return }
      if item.kind == .document { prepareDocumentOpening(itemID, pageIndex: 0) }
      updatePresence(.init(boardID: p.boardID, mode: item.kind == .document ? .document : .page,
        camera: MacReadingCamera.fitted(center: center, geometry: itemGeometry(itemID), viewport: p.viewport, fit: item.kind == .document ? .width : .page),
        viewport: p.viewport, focusedItemID: itemID, openProgress: 1,
        selectedItemID: itemID, notebookPageID: presence?.notebookPageID), settled: true)
      if item.kind == .notebook {
        let index = presence?.notebookPageID.flatMap { notebookPageIndex($0, in: itemID) } ?? 0
        Task { await prepareNotebookPage(at: index, in: itemID) }
      }
    }
  }

  func macCreateItem(_ kind: WorkspaceItemKind) {
    afterPageInput { [self] in
      guard let p = presence else { return }
      let id: UUID?
      switch kind {
      case .notebook: id = createNotebook(at: p.camera.center)
      case .document: id = createDocument(at: p.camera.center, paperSize: .a4)
      case .board: id = createBoard(at: p.camera.center)
      }
      if let id { macOpenItem(id) }
    }
  }
}

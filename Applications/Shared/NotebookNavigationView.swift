import NotebookCore
import SwiftUI

struct NotebookNavigationView: View {
  @Environment(NotebookAppModel.self) private var model
  let presence: SessionPresence
  let documentPageCount: Int
  let onBack: () -> Void
  @State private var showsSearch = false
  @State private var showsPages = false
  @State private var pageWindow = 0

  private var item: WorkspaceItem? { model.workspace?.items.first { $0.id == presence.focusedItemID } }
  private var pageIndex: Int {
    presence.mode == .document ? presence.documentPageIndex : item?.pageIDs.firstIndex(of: model.workspace?.selectedPageID ?? UUID()) ?? 0
  }
  private var pageCount: Int { presence.mode == .document ? max(documentPageCount, pageIndex + 1) : item?.pageIDs.count ?? 1 }
  private var path: [String] {
    var names: [String] = [], id: UUID? = presence.boardID, seen: Set<UUID> = []
    while let current = id, seen.insert(current).inserted {
      names.insert(model.workspace?.items.first { $0.id == current }?.title ?? "Пространство", at: 0)
      id = model.boardHierarchy?.ownerBoardID(of: current)
    }
    if let item { names.append(item.title) }
    return names
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 4) {
        if !model.returnPlaces.isEmpty || presence.mode != .board || presence.boardID != model.workspace?.rootBoardID {
          Button(action: onBack) { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
            .accessibilityLabel(model.returnPlaces.isEmpty ? "Назад" : "Вернуться к прежнему месту")
            .accessibilityIdentifier("leave-nested-board")
        }
        VStack(alignment: .leading, spacing: 2) {
          if path.count > 1 { Text(path.dropLast().joined(separator: " › ")).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
          Text(path.last ?? "Пространство").font(.callout.weight(.semibold)).lineLimit(1)
        }.padding(.leading, 8).frame(maxWidth: 200, alignment: .leading)
        Button { showsSearch = true } label: { Image(systemName: "magnifyingglass").frame(width: 44, height: 44) }
          .accessibilityLabel("Найти мысль").accessibilityIdentifier("notebook-search")
          .keyboardShortcut("f", modifiers: .command)
      }
      .buttonStyle(.plain).padding(4).background(.regularMaterial, in: Capsule())
      Spacer(minLength: 0)
      if presence.mode == .page || presence.mode == .document {
        HStack(spacing: 0) {
          Button { select(pageIndex - 1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
            .disabled(pageIndex == 0).accessibilityLabel("Предыдущая страница").accessibilityIdentifier("previous-page")
          Button { pageWindow = pageIndex / 6; showsPages = true } label: { Text("\(pageIndex + 1) / \(pageCount)").monospacedDigit().frame(minWidth: 64, minHeight: 44) }
            .accessibilityLabel("Страница \(pageIndex + 1) из \(pageCount)")
            .accessibilityHint("Открыть список страниц").accessibilityIdentifier("page-overview")
            .popover(isPresented: $showsPages, arrowEdge: .bottom) { pageOverview }
          Button { select(pageIndex + 1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
            .disabled(presence.mode == .document && pageIndex + 1 >= pageCount)
            .accessibilityLabel("Следующая страница").accessibilityIdentifier("next-page")
        }.buttonStyle(.plain).font(.callout).padding(4).background(.regularMaterial, in: Capsule())
          .frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 18).padding(.bottom, 18)
      }
    }
    .sheet(isPresented: $showsSearch) { NotebookSearchView() }
  }

  private var pageOverview: some View {
      VStack {
        HStack {
          Button { pageWindow -= 1 } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }.disabled(pageWindow == 0).accessibilityLabel("Предыдущие миниатюры")
          Spacer()
          Text("Страницы").font(.headline)
          Spacer()
          Button { pageWindow += 1 } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }.disabled((pageWindow + 1) * 6 >= pageCount).accessibilityLabel("Следующие миниатюры")
        }.buttonStyle(.plain)
        LazyVGrid(columns: [.init(.adaptive(minimum: 100))], spacing: 16) {
          ForEach((pageWindow * 6)..<min(pageCount, (pageWindow + 1) * 6), id: \.self) { index in
            Button { select(index); showsPages = false } label: {
              VStack {
                NotebookPageThumbnail(itemID: item?.id, index: index)
                  .frame(width: 90, height: 128)
                  .background(.background, in: RoundedRectangle(cornerRadius: 6))
                  .overlay { RoundedRectangle(cornerRadius: 6).stroke(index == pageIndex ? Color.accentColor : .secondary.opacity(0.2), lineWidth: 2) }
                Text("\(index + 1)").monospacedDigit()
              }
            }.buttonStyle(.plain).contentShape(Rectangle()).accessibilityLabel("Страница \(index + 1)")
              .accessibilityAddTraits(index == pageIndex ? .isSelected : [])
          }
        }.padding(20)
      }.frame(width: 360, height: pageCount <= 3 ? 260 : 430)
  }

  private func select(_ index: Int) {
    guard let item, index >= 0 else { return }
    model.afterPageInput {
      if presence.mode == .document { _ = model.selectDocumentPage(index, documentID: item.id) }
      else { _ = model.selectNotebookPage(index, notebookID: item.id) }
    }
  }
}

private struct NotebookPageThumbnail: View {
  @Environment(NotebookAppModel.self) private var model
  let itemID: UUID?
  let index: Int
  @State private var ready = false
  @State private var preparationFailed = false
  var body: some View {
    ZStack {
      if let itemID, let document = model.documents[itemID], let state = model.documentStates[itemID] {
        let geometry = WorkspaceItemGeometry.document(document.paperSize)
        DocumentThumbnailView(document: document, state: state, pageIndex: index,
          onRenderReady: .init { value in Task { @MainActor in
            ready = value
            if value { preparationFailed = false }
          } },
          onFailure: { _ in Task { @MainActor in preparationFailed = true } })
          .onChange(of: SceneRasterSource.document(id: document.id,
            token: DocumentSnapshotCache.token(document: document, state: state, pageIndex: index))) { _,_ in
              ready = false; preparationFailed = false
            }
          .frame(width: geometry.width, height: geometry.height)
          .scaleEffect(90 / geometry.width)
          .frame(width: 90, height: 128)
      } else if let item = model.workspace?.items.first(where: { $0.id == itemID }), item.pageIDs.indices.contains(index),
        let page = model.pages[item.pageIDs[index]] {
        PageSurface(page: page, isInteractive: false, isVisible: true, onRenderReady: .init { value in Task { @MainActor in ready = value } })
      }
      if !ready {
        if preparationFailed {
          Image(systemName: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
            .accessibilityLabel("Миниатюра недоступна. Страницу можно открыть.")
        } else { ProgressView().controlSize(.small) }
      }
    }.clipped().allowsHitTesting(false).accessibilityHidden(true)
  }
}

struct NotebookSearchView: View {
  @Environment(NotebookAppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""
  @State private var response: NotebookSearchResponse?
  @State private var error: String?
  @State private var searching = false

  var body: some View {
    NavigationStack {
      Group {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          ContentUnavailableView("Найдите мысль", systemImage: "magnifyingglass", description: Text("Названия, текст и блоки на всех досках. Рукопись доступна через указание области."))
        } else if let error {
          ContentUnavailableView("Поиск недоступен", systemImage: "exclamationmark.magnifyingglass", description: Text(error))
        } else if let response, !response.results.isEmpty {
          List(response.results) { result in
            Button {
              dismiss()
              model.requestShow(result.reference)
            } label: {
              VStack(alignment: .leading, spacing: 6) {
                Text(result.title).font(.headline)
                Text(result.preview).font(.body).lineLimit(3)
                Text(result.path.joined(separator: " › ")).font(.caption).foregroundStyle(.secondary)
              }.frame(minHeight: 44, alignment: .leading)
            }.buttonStyle(.plain)
          }
        } else if searching { ProgressView("Поиск") }
        else { ContentUnavailableView.search(text: query) }
      }
      .searchable(text: $query, prompt: "Текст или название")
      .navigationTitle("Найти мысль")
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
      .task(id: query) {
        response = nil; error = nil
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { searching = false; return }
        searching = true
        do {
          try await Task.sleep(for: .milliseconds(180))
          let store = model.store, query = query
          let result = await Task.detached(priority: .userInitiated) { Result { try store.search(query, limit: 50) } }.value
          try Task.checkCancellation()
          switch result { case .success(let found): response = found; case .failure(let failure): error = failure.localizedDescription }
          searching = false
        } catch { }
      }
    }.frame(minWidth: 360, minHeight: 480)
  }
}

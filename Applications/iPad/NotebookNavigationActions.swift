import NotebookCore
import SwiftUI

struct NotebookNavigationActions: View {
  @Environment(NotebookAppModel.self) private var model
  @State private var showsSearch = false
  var showsActions = true
  var body: some View {
    HStack(spacing: 0) {
        if showsActions, let destination = model.pasteDestination { NotebookActionsMenu(destination:destination) }
        Button { showsSearch = true } label: { Image(systemName: "magnifyingglass").frame(width: 44, height: 44).contentShape(Rectangle()) }
          .accessibilityLabel("Найти мысль").accessibilityIdentifier("notebook-search")
          .keyboardShortcut("f", modifiers: .command)
    }.sheet(isPresented: $showsSearch) { NotebookSearchView() }
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
              model.observeNavigation("search_result_tap", reference: result.reference)
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

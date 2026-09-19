import NotebookCore
import SwiftUI

/// Window-level navigation content. The scene retains the back action and
/// page navigation; its toolbar is laid out once with the other controls.
struct NotebookNavigationHeader: View {
  @Environment(NotebookAppModel.self) private var model
  let presence: SessionPresence
  let onBack: () -> Void
  var showsActions = true
  private var item: WorkspaceItem? { model.workspace?.items.first { $0.id == presence.focusedItemID } }
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
      HStack(spacing: 0) {
        if !model.returnPlaces.isEmpty || presence.mode != .board || presence.boardID != model.workspace?.rootBoardID {
          Button(action: onBack) { Image(systemName: "chevron.left").frame(width: 44, height: 44).contentShape(Rectangle()) }
            .accessibilityLabel(model.returnPlaces.isEmpty ? "Назад" : "Вернуться к прежнему месту")
            .accessibilityIdentifier("leave-nested-board")
        }
        VStack(alignment: .leading, spacing: 2) {
          if path.count > 1 { Text(path.dropLast().joined(separator: " › ")).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
          if let open = model.openWorkspaceLibrary {
            Button(action: open) {
              HStack(spacing: 5) {
                Text(presence.mode == .board && presence.boardID == model.workspace?.rootBoardID
                  ? model.workspaceName : path.last ?? model.workspaceName).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2)
              }.font(.system(size: 14, weight: .medium))
            }.buttonStyle(.plain).accessibilityLabel("Пространства").accessibilityIdentifier("workspaces-open")
          } else { Text(path.last ?? "Пространство").font(.system(size:14,weight:.medium)).lineLimit(1) }
        }.padding(.leading, 8).frame(minWidth: 64, maxWidth: .infinity, alignment: .leading)
        if showsActions { NotebookNavigationActions() }
      }
  }
}

struct NotebookNavigationActions: View {
  @Environment(NotebookAppModel.self) private var model
  @State private var showsSearch = false
  var body: some View {
    HStack(spacing: 0) {
        if let destination = model.pasteDestination { NotebookActionsMenu(destination:destination) }
        Button { showsSearch = true } label: { Image(systemName: "magnifyingglass").frame(width: 44, height: 44).contentShape(Rectangle()) }
          .accessibilityLabel("Найти мысль").accessibilityIdentifier("notebook-search")
          .keyboardShortcut("f", modifiers: .command)
    }.sheet(isPresented: $showsSearch) { NotebookSearchView() }
  }
}

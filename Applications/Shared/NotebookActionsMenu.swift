import SwiftUI
import NotebookCore

/// Opening actions does not read the clipboard. The system paste gesture below
/// captures a physical owner; content chooses its decoder, not the UI.
struct NotebookActionsMenu: View {
  let destination: NotebookPasteDestination
  @Environment(NotebookAppModel.self) private var model
  @State private var openedDestination: NotebookPasteDestination?

  var body: some View {
    Button { openedDestination = destination } label: {
      Image(systemName: "wrench")
        .font(NotebookChrome.iconFont)
        .frame(width: NotebookChrome.controlSize, height: NotebookChrome.controlSize)
        .background {
          Circle().fill(openedDestination == nil ? Color.clear : NotebookChrome.selectionSurface)
            .padding(5)
        }
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain).foregroundStyle(.primary)
    .accessibilityLabel("Действия").accessibilityIdentifier("notebook-actions-open")
    .popover(item: $openedDestination, arrowEdge: .top) { captured in
      NotebookActionsContent(destination: captured)
        .environment(model)
        .presentationCompactAdaptation(.popover)
        .presentationBackground(NotebookChrome.surface)
    }
  }
}

private struct NotebookActionsContent: View {
  let destination: NotebookPasteDestination
  @Environment(NotebookAppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var presentation: Composition?
  @State private var failure: String?
  @State private var loading = false
  private struct Composition: Identifiable {
    let id = UUID()
    let source: String
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      PasteButton(supportedContentTypes: NotebookClipboard.types) { providers in
        loading = true
        failure = nil
        Task {
          defer { loading = false }
          do {
            switch try await NotebookClipboard.read(providers, availableSize: destination.availableSize) {
            case .composition(let source): presentation = .init(source: source)
            case .fragment(let fragment):
              if await model.insertClipboardFragment(fragment, at: destination) { dismiss() }
              else { failure = "Не удалось сохранить. Попробуйте ещё раз." }
            }
          } catch { failure = error.localizedDescription }
        }
      }
      .labelStyle(.titleAndIcon).tint(Color(white: 0.28)).buttonBorderShape(.capsule)
      .font(.system(size: 15)).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
      .disabled(loading).accessibilityLabel("Вставить").accessibilityIdentifier("clipboard-paste")
      if loading { ProgressView().controlSize(.small).accessibilityLabel("Вставляем") }
      if let failure {
        Text(failure).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("paste-error")
      }
    }
    .padding(.horizontal, 16).padding(.vertical, 4)
    .frame(width: failure == nil ? 136 : 280).background(NotebookChrome.surface)
    .sheet(item: $presentation, onDismiss: { dismiss() }) { value in
      NotebookTldrawCompositionView(destinations: [destination], initialSource: value.source,
        onClose: { presentation = nil }).environment(model)
    }
  }
}

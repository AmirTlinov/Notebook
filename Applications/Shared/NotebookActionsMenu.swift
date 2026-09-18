import SwiftUI
import NotebookCore

/// Opening actions does not read the clipboard. The system paste gesture below
/// is the only entry into the existing importer and captures a physical owner.
struct NotebookActionsMenu: View {
  let destination: NotebookTldrawDestination
  @Environment(NotebookAppModel.self) private var model
  @State private var openedDestination: NotebookTldrawDestination?

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
  let destination: NotebookTldrawDestination
  @Environment(NotebookAppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var presentation: Presentation?
  @State private var failure: String?
  @State private var loading = false
  private struct Presentation: Identifiable {
    let id = UUID()
    let source: String
    let destination: NotebookTldrawDestination
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("Действия").font(.system(size: 20, weight: .semibold))
        Spacer()
        Button { dismiss() } label: {
          Image(systemName: "xmark").font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary).frame(width: 44, height: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("Закрыть действия")
          .accessibilityIdentifier("notebook-actions-close")
      }
      VStack(alignment: .leading, spacing: 12) {
        Text("Добавить").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
        HStack(spacing: 12) {
          Image(systemName: "square.on.square").font(.system(size: 18))
          VStack(alignment: .leading, spacing: 3) {
            Text("Из tldraw").font(.system(size: 15, weight: .medium))
            Text("Фигуры, текст и связи").font(.caption).foregroundStyle(.secondary)
          }
          Spacer(minLength: 4)
          PasteButton(supportedContentTypes: NotebookTldrawPaste.types) { providers in
            loading = true
            Task {
              defer { loading = false }
              do {
                presentation = .init(source: try await NotebookTldrawPaste.source(providers), destination: destination)
              } catch { failure = error.localizedDescription }
            }
          }
          .labelStyle(.titleOnly).tint(Color(white: 0.28)).buttonBorderShape(.capsule)
          .disabled(loading).accessibilityLabel("Вставить из tldraw")
          .accessibilityIdentifier("tldraw-paste-open")
        }.padding(14)
          .background(NotebookChrome.insetSurface, in: RoundedRectangle(cornerRadius: NotebookChrome.cardRadius))
        Text(loading ? "Читаем фрагмент…" : "Скопируйте нужные объекты в tldraw, затем вставьте их сюда.")
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if let failure {
          Text(failure).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("tldraw-paste-error")
        }
      }
    }
    .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 20)
    .frame(width: 360).background(NotebookChrome.surface)
    .sheet(item: $presentation, onDismiss: { dismiss() }) { value in
      NotebookTldrawPasteView(destinations: [value.destination], initialSource: value.source,
        onClose: { presentation = nil })
        .environment(model)
    }
  }
}

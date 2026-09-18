import SwiftUI
import NotebookCore

/// System paste control keeps clipboard access tied to the user's gesture.
struct NotebookTldrawPasteControl: View {
  let destination: NotebookTldrawDestination
  @Environment(NotebookAppModel.self) private var model
  @State private var presentation: Presentation?
  @State private var failure: String?
  @State private var loading = false
  private struct Presentation: Identifiable {
    let id = UUID()
    let source: String
    let destination: NotebookTldrawDestination
  }
  var body: some View {
    PasteButton(supportedContentTypes:NotebookTldrawPaste.types) { providers in
      let captured = destination
      loading = true
      Task {
        defer { loading = false }
        do { presentation = .init(source:try await NotebookTldrawPaste.source(providers),destination:captured) }
        catch { failure=error.localizedDescription }
      }
    }
    .labelStyle(.iconOnly).buttonStyle(.plain).frame(width:44,height:44)
    .accessibilityValue(loading ? "Читаем буфер" : presentation == nil ? "Готово к вставке" : "Фрагмент открыт")
    .disabled(loading).accessibilityLabel("Вставить из tldraw").accessibilityIdentifier("tldraw-paste-open")
    .sheet(item:$presentation) { value in
      NotebookTldrawPasteView(destinations:[value.destination],initialSource:value.source,onClose:{presentation=nil})
        .environment(model)
    }
    .alert("Вставка из tldraw",isPresented:Binding(get:{failure != nil},set:{if !$0 { failure=nil }})) {
      Button("Понятно",role:.cancel) { failure=nil }
    } message: { Text(failure ?? "") }
  }
}

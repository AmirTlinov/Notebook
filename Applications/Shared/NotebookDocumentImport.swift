import SwiftUI
import UniformTypeIdentifiers

extension UTType {
  static let notebookDocument = UTType(exportedAs: "com.amirtlinov.notebook.document", conformingTo: .zip)
}

private struct NotebookDocumentImportAction: EnvironmentKey {
  static let defaultValue: @MainActor @Sendable () -> Void = {}
}
extension EnvironmentValues {
  var importNotebookDocument: @MainActor @Sendable () -> Void {
    get { self[NotebookDocumentImportAction.self] }
    set { self[NotebookDocumentImportAction.self] = newValue }
  }
}

/// The picker and Finder/Files use the same import command. Importing a package
/// adds a closed copy; it does not mount or execute the programs it contains.
struct NotebookDocumentImport: ViewModifier {
  let model: NotebookAppModel?
  @State private var isPresented = false
  @State private var pendingURLs: [URL] = []
  @State private var importing = false
  @State private var resultMessage: String?
  @State private var succeeded = false

  func body(content: Content) -> some View {
    content
      .environment(\.importNotebookDocument, { isPresented = true })
      .onChange(of: canImport) { _, _ in importNext() }
      .fileImporter(isPresented: $isPresented, allowedContentTypes: [.notebookDocument]) { result in
        switch result {
        case .success(let url): enqueue(url)
        case .failure(let error):
          if (error as NSError).code != NSUserCancelledError { succeeded = false; resultMessage = error.localizedDescription }
        }
      }
      .onOpenURL { url in
        if url.isFileURL, url.pathExtension.lowercased() == "notex" { enqueue(url) }
      }
      .overlay(alignment: .top) {
        if importing { ProgressView("Импорт документа…").padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) }
      }
      .alert(succeeded ? "Документ добавлен" : "Не удалось импортировать документ",
        isPresented: Binding(get: { resultMessage != nil }, set: { if !$0 { resultMessage = nil } })) {
          Button("Готово") { resultMessage = nil }
        } message: { Text(resultMessage ?? "") }
  }

  private var canImport: Bool { model?.loadState == .ready }
  private func enqueue(_ url: URL) {
    pendingURLs.append(url); importNext()
  }
  private func importNext() {
    guard !importing, canImport, let model, !pendingURLs.isEmpty else { return }
    let url = pendingURLs.removeFirst()
    importing = true
    Task { @MainActor in
      do {
        _ = try await model.importDocumentFile(url)
        succeeded = true; resultMessage = "Создана новая копия. Программы запустятся только после открытия документа."
      } catch { succeeded = false; resultMessage = error.localizedDescription }
      importing = false; importNext()
    }
  }
}

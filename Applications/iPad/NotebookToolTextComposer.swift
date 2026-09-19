import SwiftUI

struct NotebookToolTextComposer: View {
  @Environment(NotebookAppModel.self) private var model
  @FocusState private var focused: Bool
  var body: some View {
    NavigationStack {
      TextEditor(text:Binding(get:{ model.drawingTools.textDraft?.text ?? "" },set:{ model.drawingTools.textDraft?.text = $0 }))
        .font(.system(size:model.drawingTools.textDraft?.style.fontSize ?? 24))
        .padding().focused($focused).accessibilityIdentifier("drawing-tool-text-editor")
        .navigationTitle("Текст")
        .toolbar {
          ToolbarItem(placement:.cancellationAction) { Button("Отмена") { model.drawingTools.textDraft = nil } }
          ToolbarItem(placement:.confirmationAction) {
            Button("Добавить") { model.drawingTools.saveText() }
              .disabled(model.drawingTools.textDraft?.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty != false)
              .accessibilityIdentifier("drawing-tool-text-save")
          }
        }
    }
    .presentationDetents([.medium,.large])
    .task { focused = true }
  }
}

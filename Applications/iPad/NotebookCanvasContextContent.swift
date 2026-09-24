import NotebookCore
import SwiftUI

/// Context presentation only: actions retain the surface captured at hold-up.
struct NotebookCanvasContextContent: View {
  @Environment(NotebookAppModel.self) private var model
  let dismiss: () -> Void
  let destination: NotebookPasteDestination?
  @Binding var documentMode: DocumentViewMode
  let allowsBeside: Bool
  let create: ((WorkspaceItemKind,DocumentPaperSize) -> Void)?
  let back: (() -> Void)?

  var body: some View {
    VStack(alignment:.leading,spacing:4) {
      if let destination { NotebookActionsContent(destination:destination,onClose:dismiss) }
      if let create {
        row("Тетрадь",symbol:"book.closed") { create(.notebook,.a4) }.accessibilityIdentifier("context-create-notebook")
        row("Доска",symbol:"folder") { create(.board,.a4) }.accessibilityIdentifier("create-nested-board")
        Menu {
          Button("A4") { dismiss(); create(.document,.a4) }.accessibilityIdentifier("create-document-a4")
          Button("Letter") { dismiss(); create(.document,.letter) }.accessibilityIdentifier("create-document-letter")
        } label: { Label("Документ",systemImage:"doc.text").frame(maxWidth:.infinity,minHeight:44,alignment:.leading) }
      }
      if model.activeDocument != nil {
        Text("Вид документа").font(.caption).foregroundStyle(.secondary)
        DocumentViewModePicker(mode:$documentMode,allowsBeside:allowsBeside)
      }
      if let back { row("Назад",symbol:"arrow.uturn.backward",action:back).accessibilityIdentifier("leave-nested-board") }
      if let open=model.openWorkspaceLibrary {
        row("Пространства",symbol:"square.grid.2x2") { open(.spaces) }.accessibilityIdentifier("workspaces-open")
        row("Устройства",symbol:"ipad.and.laptop") { open(.devices) }
      }
    }.buttonStyle(.plain).font(.system(size:15)).padding(12).frame(width:300)
      .background(NotebookChrome.surface).accessibilityElement(children:.contain)
      .accessibilityIdentifier("canvas-context-menu")
  }
  private func row(_ title:String,symbol:String,action:@escaping ()->Void) -> some View {
    Button { dismiss(); action() } label: {
      Label(title,systemImage:symbol).frame(maxWidth:.infinity,minHeight:44,alignment:.leading).contentShape(Rectangle())
    }
  }
}

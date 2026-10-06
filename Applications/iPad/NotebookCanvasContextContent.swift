import NotebookCore
import SwiftUI

/// Context presentation only: actions retain the surface captured at hold-up.
struct NotebookCanvasContextContent: View {
  @Environment(NotebookAppModel.self) private var model
  let dismiss: () -> Void
  let contextMenus: NotebookContextMenus
  let presentationIntent: NotebookContextMenus.PresentationIntent
  let destination: NotebookPasteDestination?
  let create: ((WorkspaceItemKind,DocumentTemplate) -> Void)?
  let back: (() -> Void)?
  var importDocument: (() -> Void)? = nil

  var body: some View {
    VStack(alignment:.leading,spacing:4) {
      if let destination {
        NotebookActionsContent(destination:destination,contextMenus:contextMenus,
          presentationIntent:presentationIntent,onClose:dismiss)
      }
      if let create {
        row("Тетрадь",symbol:"book.closed") { create(.notebook,.article) }.accessibilityIdentifier("context-create-notebook")
        row("Доска",symbol:"folder") { create(.board,.article) }.accessibilityIdentifier("create-nested-board")
        Menu {
          ForEach(DocumentTemplate.allCases, id: \.self) { template in
            Button(template.title) { dismiss(); create(.document,template) }.accessibilityIdentifier("create-document-" + template.rawValue)
          }
        } label: { Label("Документ",systemImage:"doc.text").frame(maxWidth:.infinity,minHeight:44,alignment:.leading) }
      }
      if let importDocument { row("Импорт документа…", symbol: "square.and.arrow.down", action: importDocument) }
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

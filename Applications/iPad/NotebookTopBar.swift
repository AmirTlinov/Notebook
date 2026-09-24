import NotebookCore
import SwiftUI

/// Content-sized chrome; it never participates in the paper's camera geometry.
struct NotebookTopBar: View {
  @Environment(NotebookAppModel.self) private var model
  var body: some View {
    ViewThatFits(in:.horizontal) {
      tools
      ScrollView(.horizontal) { tools }.scrollIndicators(.hidden).frame(height:44)
    }
    .font(NotebookChrome.iconFont).buttonStyle(.plain).foregroundStyle(.primary)
    .padding(.horizontal,6).padding(.vertical,2)
    .notebookPanel(radius:NotebookChrome.panelRadius)
    .accessibilityElement(children:.contain).accessibilityIdentifier("notebook-top-bar")
  }
  private var tools: some View {
    HStack(spacing:0) {
      PenControlsView(inkOnly:model.chat?.files.window.isOpen == true && model.chat?.files.document != nil,embedded:true)
      NotebookNavigationActions(showsActions:false)
    }.fixedSize()
  }
}

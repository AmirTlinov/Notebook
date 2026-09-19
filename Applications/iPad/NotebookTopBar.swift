import NotebookCore
import SwiftUI

/// One window-space layout owns the whole upper bar. Narrow windows wrap its
/// controls inside the same surface rather than overlaying independent pills.
struct NotebookTopBar: View {
  @Environment(NotebookAppModel.self) private var model
  let presence: SessionPresence
  @Binding var documentMode: DocumentViewMode
  let allowsBeside: Bool
  let onBack: () -> Void

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 12) {
        navigation.frame(minWidth: 200, maxWidth: .infinity)
        if model.activeDocument != nil { DocumentViewModePicker(mode: $documentMode, allowsBeside: allowsBeside).frame(width: allowsBeside ? 240 : 176) }
        Divider().frame(height: 20)
        tools
      }
      VStack(spacing: 4) {
        HStack(spacing: 8) {
          NotebookNavigationHeader(presence: presence, onBack: onBack, showsActions: false)
          tools
        }
        HStack(spacing: 8) {
          if model.activeDocument != nil { DocumentViewModePicker(mode: $documentMode, allowsBeside: allowsBeside) }
          else { Spacer(minLength: 0) }
          NotebookNavigationActions().fixedSize()
        }.padding(.horizontal, 4).padding(.bottom, 2)
      }
      VStack(spacing: 4) {
        navigation
        if model.activeDocument != nil { DocumentViewModePicker(mode: $documentMode, allowsBeside: allowsBeside) }
        // Keep full-size controls, including an additional selected tool, in
        // narrow split windows. Only the tool row scrolls, never the paper.
        ScrollView(.horizontal) { tools }.scrollIndicators(.hidden).frame(height: 44)
      }
    }
    .font(NotebookChrome.iconFont).buttonStyle(.plain).foregroundStyle(.primary)
    .padding(.horizontal, 8).padding(.vertical, 2)
    .notebookPanel(radius: NotebookChrome.panelRadius)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("notebook-top-bar")
  }
  private var tools: some View {
    PenControlsView(inkOnly: model.chat?.files.window.isOpen == true && model.chat?.files.document != nil, embedded: true).fixedSize()
  }
  private var navigation: some View { NotebookNavigationHeader(presence: presence, onBack: onBack) }
}

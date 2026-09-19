import NotebookCore
import SwiftUI

/// One native editor for page, board and cover text. It writes through the
/// model's addressed persistence owners, never a view-owned store or WebKit.
struct NotebookNativeTextView: View {
  @Environment(NotebookAppModel.self) private var model
  let source: String
  let style: NativeTextStyle
  let reference: EditableElementReference
  let isEditing: Bool
  let onEditingEnded: () -> Void
  var retainedPage: AgentElement? = nil
  @State private var draft = ""
  @State private var submitted = ""
  @State private var hasDraft = false
  @State private var pending: Task<Void,Never>?
  @FocusState private var focused: Bool

  var body: some View {
    Group {
      if isEditing {
        TextEditor(text:$draft).scrollContentBackground(.hidden).focused($focused)
          .accessibilityIdentifier("native-text-editor")
          .task { draft = source; submitted = source; hasDraft = true; focused = true }
          .onChange(of:draft) { _,_ in
            pending?.cancel()
            pending = Task { @MainActor in
              try? await Task.sleep(for:.milliseconds(180))
              if !Task.isCancelled { commit() }
            }
          }
          .onChange(of:focused) { _,value in if !value { commit(finishing:true); onEditingEnded() } }
          .onDisappear { pending?.cancel(); commit(finishing:true) }
      } else {
        Text(source).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
      }
    }
    .font(.system(size:style.fontSize,weight:style.fontWeight))
    .foregroundStyle(Color(red:style.red,green:style.green,blue:style.blue,opacity:style.alpha))
  }
  private func commit(finishing: Bool = false) {
    guard hasDraft else { return }
    if finishing { pending?.cancel(); hasDraft = false }
    guard draft != submitted || (finishing && draft.isEmpty) else { return }
    model.commitNativeText(reference:reference,text:draft,finish:finishing,retainedPage:retainedPage)
    submitted = draft
  }
}

struct NotebookNativeTextSnapshot: View {
  let source: String
  let style: NativeTextStyle
  var body: some View {
    Text(source).font(.system(size:style.fontSize,weight:style.fontWeight))
      .foregroundStyle(Color(red:style.red,green:style.green,blue:style.blue,opacity:style.alpha))
      .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
  }
}

extension NativeTextStyle {
  var fontWeight: Font.Weight {
    switch weight {
    case ..<0.2: .light
    case ..<0.4: .regular
    case ..<0.6: .medium
    case ..<0.8: .semibold
    default: .bold
    }
  }
}

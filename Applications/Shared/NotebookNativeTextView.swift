import NotebookCore
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// One native editor for page, board and cover text. It writes through the
/// model's addressed persistence owners, never a view-owned store or WebKit.
struct NotebookNativeTextView: View {
  @Environment(NotebookAppModel.self) private var model
  let source: String
  let style: NativeTextStyle
  let reference: EditableElementReference
  let frame: PageRect
  var maximumHeight: Double = .greatestFiniteMagnitude
  let isEditing: Bool
  let onEditingEnded: () -> Void
  var retainedPage: AgentElement? = nil
  var retainedSpatial: SpatialElement? = nil
  @State private var draft = ""
  @State private var submitted = ""
  @State private var measuredHeight: Double?
  @State private var hasDraft = false
  @State private var pending: Task<Void,Never>?
  @FocusState private var focused: Bool

  var body: some View {
    Group {
      if isEditing {
        editor
          .onAppear { draft = source; submitted = source; hasDraft = true; focused = true }
          .onChange(of:draft) { _,_ in
            pending?.cancel()
            pending = Task { @MainActor in
              try? await Task.sleep(for:.milliseconds(180))
              if !Task.isCancelled { commit() }
            }
          }
          .onDisappear { pending?.cancel(); commit(finishing:true) }
      } else {
        Text(source).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
      }
    }
    .font(.system(size:style.fontSize,weight:style.fontWeight))
    .foregroundStyle(Color(red:style.red,green:style.green,blue:style.blue,opacity:style.alpha))
  }
  @ViewBuilder private var editor: some View {
    #if os(iOS)
    NotebookInlineTextInput(text:$draft,style:style,
      onHeight:{ measuredHeight = $0 },onFinish:{ commit(finishing:true); onEditingEnded() })
    #else
    TextEditor(text:$draft).scrollContentBackground(.hidden).focused($focused)
      .accessibilityIdentifier("native-text-editor")
      .onChange(of:focused) { _,value in if !value { commit(finishing:true); onEditingEnded() } }
    #endif
  }
  private func commit(finishing: Bool = false) {
    defer { if finishing { model.endNativeTextEditing(reference) } }
    guard hasDraft else { return }
    if finishing { pending?.cancel(); hasDraft = false }
    guard draft != submitted || (finishing && draft.isEmpty) else { return }
    let height = min(maximumHeight,measuredHeight ?? frame.height)
    model.commitNativeText(reference:reference,text:draft,finish:finishing,
      retainedPage:retainedPage,retainedSpatial:retainedSpatial,height:max(1,height))
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

#if os(iOS)
/// UIKit supplies caret, selection, IME and exact TextKit line measurement.
/// Zero insets keep the first glyph at the saved object's origin.
private struct NotebookInlineTextInput: UIViewRepresentable {
  @Binding var text: String
  let style: NativeTextStyle
  let onHeight: (Double) -> Void
  let onFinish: () -> Void
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeUIView(context: Context) -> Input {
    let view = Input()
    view.backgroundColor = .clear
    view.textContainerInset = .zero; view.textContainer.lineFragmentPadding = 0
    view.isScrollEnabled = false
    view.delegate = context.coordinator
    view.accessibilityIdentifier = "native-text-editor"
    view.smartQuotesType = .no; view.smartDashesType = .no
    return view
  }
  func updateUIView(_ view: Input, context: Context) {
    context.coordinator.owner = self
    if view.text != text {
      view.text = text
      view.selectedRange = NSRange(location:text.utf16.count,length:0)
    }
    let weight: UIFont.Weight = switch style.weight {
      case ..<0.2: .light; case ..<0.4: .regular; case ..<0.6: .medium; case ..<0.8: .semibold; default: .bold
    }
    view.font = .systemFont(ofSize:style.fontSize,weight:weight)
    view.textColor = UIColor(red:style.red,green:style.green,blue:style.blue,alpha:style.alpha)
  }
  static func dismantleUIView(_ view: Input, coordinator: Coordinator) {
    view.delegate = nil; view.resignFirstResponder()
  }
  final class Input: UITextView {
    private var requestedFocus = false
    override func didMoveToWindow() {
      super.didMoveToWindow()
      if window != nil, !requestedFocus { requestedFocus = true; becomeFirstResponder() }
    }
  }
  final class Coordinator: NSObject, UITextViewDelegate {
    var owner: NotebookInlineTextInput
    init(_ owner: NotebookInlineTextInput) { self.owner = owner }
    func textViewDidChange(_ view: UITextView) {
      owner.onHeight(ceil(view.sizeThatFits(.init(width:view.bounds.width,height:.greatestFiniteMagnitude)).height))
      owner.text = view.text
    }
    func textViewDidEndEditing(_ view: UITextView) { owner.onFinish() }
  }
}
#endif

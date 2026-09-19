import NotebookCore
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// One native draft writes text and its character formatting atomically through
/// the addressed command queue. The canvas itself only paints immutable text.
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
  var ownsEditor = false
  #if os(iOS)
  var selectionPanelHost: UIView?
  #endif
  @State private var draft = ""
  @State private var draftStyle = NativeTextStyle.standard
  @State private var submitted = ""
  @State private var submittedStyle = NativeTextStyle.standard
  @State private var measuredHeight: Double?
  @State private var hasDraft = false
  @State private var pending: Task<Void,Never>?
  private var editsHere: Bool {
    #if os(iOS)
    isEditing && ownsEditor
    #else
    isEditing
    #endif
  }

  var body: some View {
    Group {
      if editsHere {
        editor
          .onAppear { draft = source; submitted = source; draftStyle = style; submittedStyle = style; hasDraft = true }
          .onChange(of:draft) { scheduleCommit() }
          .onChange(of:draftStyle) { scheduleCommit() }
          .onDisappear { pending?.cancel(); commit(finishing:true) }
      } else {
        NotebookNativeTextSnapshot(source:source,style:style).opacity(isEditing ? 0 : 1)
          .allowsHitTesting(!isEditing)
          .accessibilityHidden(isEditing)
          .environment(\.openURL,OpenURLAction { _ in
            // Keep the text's hit surface above underlying content. Editing
            // a linked word must not also navigate away from the canvas.
            isEditing || model.drawingTool == .text ? .discarded : .systemAction
          })
      }
    }
  }
  @ViewBuilder private var editor: some View {
    #if os(iOS)
    NotebookInlineTextInput(text:$draft,style:$draftStyle,inputGate:model.inputGate,panelHost:selectionPanelHost,
      onHeight:{ measuredHeight = $0; model.measureNativeText(reference,height:$0) },
      onFinish:{ commit(finishing:true); onEditingEnded() })
    #else
    NotebookMacInlineTextInput(text:$draft,style:$draftStyle,
      onFinish:{ commit(finishing:true); onEditingEnded() })
    #endif
  }
  private func scheduleCommit() {
    pending?.cancel()
    pending = Task { @MainActor in
      do { try await Task.sleep(for:.milliseconds(180)) } catch { return }
      commit()
    }
  }
  private func commit(finishing: Bool = false) {
    defer { if finishing { model.endNativeTextEditing(reference) } }
    guard hasDraft else { return }
    if finishing { pending?.cancel(); hasDraft = false }
    guard draft != submitted || draftStyle != submittedStyle || (finishing && draft.isEmpty) else { return }
    let height = min(maximumHeight,measuredHeight ?? frame.height)
    model.commitNativeText(reference:reference,text:draft,finish:finishing,
      retainedPage:retainedPage,retainedSpatial:retainedSpatial,height:max(1,height),style:draftStyle,editingFrame:frame)
    submitted = draft; submittedStyle = draftStyle
  }
}

struct NotebookNativeTextSnapshot: View {
  let source: String
  let style: NativeTextStyle
  var body: some View {
    Text(AttributedString(NotebookTextTypography.attributed(source,style:style)))
      .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
  }
}

#if os(iOS)
private struct NotebookInlineTextInput: UIViewRepresentable {
  @Binding var text: String
  @Binding var style: NativeTextStyle
  let inputGate: NotebookInputGate
  let panelHost: UIView?
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
    view.autocorrectionType = .no; view.spellCheckingType = .no
    view.smartInsertDeleteType = .no
    view.inputAssistantItem.leadingBarButtonGroups = []
    view.inputAssistantItem.trailingBarButtonGroups = []
    context.coordinator.input = view
    view.onLayout = { [weak coordinator = context.coordinator] in coordinator?.updateSelectionPanel() }
    return view
  }
  func updateUIView(_ view: Input, context: Context) {
    let coordinator = context.coordinator
    coordinator.owner = self
    if view.markedTextRange == nil, coordinator.presentedText != text || coordinator.presentedStyle != style {
      let selection = coordinator.presentedText == text ? view.selectedRange : NSRange(location:text.utf16.count,length:0)
      view.attributedText = NotebookTextTypography.attributed(text,style:style,editing:true)
      view.selectedRange = .init(location:min(selection.location,text.utf16.count),length:min(selection.length,max(0,text.utf16.count-selection.location)))
      if text.isEmpty { view.typingAttributes = NotebookTextTypography.attributes(style:style,format:style.format ?? .init(),editing:true) }
      coordinator.presentedText = text; coordinator.presentedStyle = style
    }
  }
  static func dismantleUIView(_ view: Input, coordinator: Coordinator) {
    coordinator.removeSelectionPanel()
    view.onLayout = nil; view.delegate = nil; view.resignFirstResponder()
  }
  final class Input: UITextView {
    var onLayout: (() -> Void)?
    private var requestedFocus = false
    override func layoutSubviews() { super.layoutSubviews(); onLayout?() }
    override func didMoveToWindow() {
      super.didMoveToWindow()
      if window != nil, !requestedFocus { requestedFocus = true; becomeFirstResponder() }
    }
    override func paste(_ sender: Any?) {
      guard let value = UIPasteboard.general.string, let range = selectedTextRange else { return }
      replace(range,withText:value)
    }
  }
  final class Coordinator: NSObject, UITextViewDelegate {
    var owner: NotebookInlineTextInput
    var presentedText: String?
    var presentedStyle: NativeTextStyle?
    weak var input: Input?
    private var selectionPanel: UIVisualEffectView?
    private var formatButton: UIButton?
    private var presentedFormat: NativeTextFormat?
    private var formattingDialog = false
    private var finishing = false
    init(_ owner: NotebookInlineTextInput) { self.owner = owner }
    func textViewDidChange(_ view: UITextView) {
      let style = NotebookTextTypography.style(from:view.attributedText,base:owner.style,editing:true)
      presentedText = view.text; presentedStyle = style
      owner.text = view.text; owner.style = style
      owner.onHeight(ceil(view.sizeThatFits(.init(width:view.bounds.width,height:.greatestFiniteMagnitude)).height))
      updateSelectionPanel()
    }
    func textViewDidChangeSelection(_ view: UITextView) { updateSelectionPanel() }
    func textViewDidBeginEditing(_ view: UITextView) { updateSelectionPanel() }
    func textViewDidEndEditing(_ view: UITextView) { if !formattingDialog { finishEditing() } }
    private func finishEditing() {
      guard !finishing else { return }
      finishing = true
      removeSelectionPanel()
      owner.onFinish()
      input?.resignFirstResponder()
    }
    private func currentFormat(_ view: UITextView) -> NativeTextFormat {
      let range = view.selectedRange
      let attributes = range.length > 0 && range.location < view.attributedText.length
        ? view.attributedText.attributes(at:range.location,effectiveRange:nil) : view.typingAttributes
      return NotebookTextTypography.format(from:attributes,base:owner.style,editing:true)
    }
    private func apply(_ change: (inout NativeTextFormat) -> Void) {
      guard let view = input, view.selectedRange.length > 0 else { return }
      let range = view.selectedRange
      let selection = view.attributedText.attributedSubstring(from:range)
      view.textStorage.beginEditing()
      selection.enumerateAttributes(in:.init(location:0,length:selection.length)) { attributes,part,_ in
        var format = NotebookTextTypography.format(from:attributes,base:owner.style,editing:true); change(&format)
        view.textStorage.setAttributes(NotebookTextTypography.attributes(style:owner.style,format:format,editing:true),
          range:.init(location:range.location+part.location,length:part.length))
      }
      view.textStorage.endEditing()
      textViewDidChange(view)
    }
    func textView(_ textView: UITextView, editMenuForTextInRanges ranges: [NSValue],
      suggestedActions: [UIMenuElement]) -> UIMenu? {
      // The icon panel is the only selection menu. A caret still has native
      // insertion/paste actions, but never a formatting toolbar.
      textView.selectedRange.length > 0 ? UIMenu(children:[]) : nil
    }
    func removeSelectionPanel() {
      selectionPanel?.removeFromSuperview(); selectionPanel = nil; formatButton = nil; presentedFormat = nil
    }
    func updateSelectionPanel() {
      guard !finishing, !formattingDialog, let view = input, view.isFirstResponder,
        let window = view.window, let host = owner.panelHost, host.window === window,
        let range = view.selectedTextRange, !range.isEmpty else {
        removeSelectionPanel(); return
      }
      let local = view.selectionRects(for:range).reduce(CGRect.null) { result, selection in
        selection.rect.isEmpty ? result : result.union(selection.rect)
      }
      guard !local.isNull else { removeSelectionPanel(); return }
      let selection = view.convert(local,to:window)
      guard selection.intersects(window.bounds) else { removeSelectionPanel(); return }
      let panel = selectionPanel ?? makeSelectionPanel()
      // Native button menus need the controller's responder/presentation chain.
      // The panel registers only its own bounds with the existing input gate.
      if panel.superview !== host { host.addSubview(panel) }
      let width = NotebookChrome.controlSize*4+8, height = NotebookChrome.controlSize, gap: CGFloat = 10
      let safe = window.bounds.inset(by:window.safeAreaInsets).insetBy(dx:8,dy:8)
      let x = min(max(selection.midX-width/2,safe.minX),safe.maxX-width)
      let above = selection.minY-height-gap
      let y = min(above >= safe.minY ? above : selection.maxY+gap,safe.maxY-height)
      let frame = host.convert(CGRect(x:x,y:y,width:width,height:height),from:window)
      if panel.frame != frame { panel.frame = frame }
      let format = currentFormat(view)
      if presentedFormat != format {
        formatButton?.menu = formattingMenu(format)
        presentedFormat = format
      }
    }
    private func formattingMenu(_ format: NativeTextFormat) -> UIMenu {
      func action(_ title: String, _ symbol: String, selected: Bool = false,
        change: @escaping (inout NativeTextFormat) -> Void) -> UIAction {
        UIAction(title:title,image:UIImage(systemName:symbol),state:selected ? .on : .off) { [weak self] _ in
          self?.apply(change)
        }
      }
      let fonts = UIMenu(title:"Шрифт",image:UIImage(systemName:"textformat"),children:NotebookTextTypography.fonts.map { value in
        action(value.title,"textformat",selected:format.fontName == value.name) { $0.fontName = value.name }
      })
      return UIMenu(children:[fonts,
        action("Жирный","bold",selected:format.bold == true) { $0.bold = format.bold != true },
        action("Курсив","italic",selected:format.italic == true) { $0.italic = format.italic != true },
        action("Выделить маркером","highlighter",selected:format.highlight != nil) {
          $0.highlight = format.highlight == nil ? .init(red:1,green:0.9,blue:0.35) : nil
        },
        UIAction(title:"Веб-ссылка",image:UIImage(systemName:"link"),state:format.link != nil ? .on : .off) { [weak self] _ in self?.editLink() }
      ])
    }

    private func makeSelectionPanel() -> UIVisualEffectView {
      let panel = UIVisualEffectView(effect:UIGlassEffect(style:.regular))
      panel.accessibilityIdentifier = "native-text-selection-panel"
      panel.cornerConfiguration = .capsule()
      let region = NotebookControlRegionView(gate:owner.inputGate)
      region.autoresizingMask = [.flexibleWidth,.flexibleHeight]
      region.frame = panel.contentView.bounds
      panel.contentView.addSubview(region)
      let stack = UIStackView(); stack.axis = .horizontal; stack.distribution = .fillEqually
      stack.translatesAutoresizingMaskIntoConstraints = false
      panel.contentView.addSubview(stack)
      NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:panel.contentView.leadingAnchor,constant:4),
        stack.trailingAnchor.constraint(equalTo:panel.contentView.trailingAnchor,constant:-4),
        stack.topAnchor.constraint(equalTo:panel.contentView.topAnchor),
        stack.bottomAnchor.constraint(equalTo:panel.contentView.bottomAnchor)])
      func button(_ symbol: String, _ title: String, _ id: String, action: (() -> Void)? = nil) -> UIButton {
        let button = UIButton(type:.system)
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName:symbol)
        configuration.preferredSymbolConfigurationForImage = .init(pointSize:NotebookChrome.iconSize,weight:.regular)
        configuration.baseForegroundColor = .label
        configuration.contentInsets = .zero
        configuration.background.cornerRadius = 8
        configuration.background.backgroundInsets = .init(top:6,leading:6,bottom:6,trailing:6)
        button.configuration = configuration
        button.tintColor = .label
        button.accessibilityLabel = title; button.accessibilityIdentifier = id
        if let action { button.addAction(UIAction { _ in action() },for:.touchUpInside) }
        stack.addArrangedSubview(button)
        return button
      }
      let format = button("textformat","Формат текста","native-text-format")
      format.showsMenuAsPrimaryAction = true
      formatButton = format
      _ = button("scissors","Вырезать","native-text-cut") { [weak self] in self?.input?.cut(nil) }
      _ = button("doc.on.doc","Копировать","native-text-copy") { [weak self] in self?.input?.copy(nil) }
      _ = button("doc.on.clipboard","Вставить","native-text-paste") { [weak self] in self?.input?.paste(nil) }
      selectionPanel = panel
      return panel
    }
    private func editLink() {
      guard let view = input, var controller = view.window?.rootViewController else { return }
      while let presented = controller.presentedViewController { controller = presented }
      let original = currentFormat(view).link
      let dialog = UIAlertController(title:"Веб-ссылка",message:nil,preferredStyle:.alert)
      func resume() {
        // UIAlertController owns its dismissal. Starting a second dismissal from
        // an action interrupts UIKit's transition and loses the editing session.
        view.becomeFirstResponder()
        formattingDialog = false
        updateSelectionPanel()
      }
      let save = UIAlertAction(title:"Применить",style:.default) { [weak self, weak dialog] _ in
        guard let self, let link = dialog?.textFields?.first?.text, NativeTextFormat.isWebLink(link) else { resume(); return }
        apply { $0.link = link }; resume()
      }
      save.isEnabled = original != nil
      dialog.addTextField { [weak save] field in
        field.text = original; field.placeholder = "https://…"; field.keyboardType = .URL
        field.autocapitalizationType = .none; field.autocorrectionType = .no
        field.accessibilityIdentifier = "native-text-link-url"
        field.addAction(UIAction { [weak field, weak save] _ in save?.isEnabled = NativeTextFormat.isWebLink(field?.text ?? "") },for:.editingChanged)
      }
      dialog.addAction(save)
      if original != nil { dialog.addAction(.init(title:"Убрать ссылку",style:.destructive) { [weak self] _ in self?.apply { $0.link = nil }; resume() }) }
      dialog.addAction(.init(title:"Отмена",style:.cancel) { _ in resume() })
      formattingDialog = true
      removeSelectionPanel()
      controller.present(dialog,animated:true)
    }
  }
}
#endif

#if os(macOS)
private struct NotebookMacInlineTextInput: NSViewRepresentable {
  @Binding var text: String
  @Binding var style: NativeTextStyle
  let onFinish: () -> Void
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> Input {
    let view = Input()
    view.drawsBackground = false; view.isRichText = true; view.allowsUndo = true
    view.textContainerInset = .zero; view.textContainer?.lineFragmentPadding = 0
    view.textContainer?.widthTracksTextView = true
    view.isVerticallyResizable = true; view.isHorizontallyResizable = false
    view.delegate = context.coordinator
    view.setAccessibilityIdentifier("native-text-editor")
    return view
  }
  func updateNSView(_ view: Input, context: Context) {
    let coordinator = context.coordinator; coordinator.owner = self
    guard !view.hasMarkedText(), coordinator.presentedText != text || coordinator.presentedStyle != style else { return }
    let selection = coordinator.presentedText == text ? view.selectedRange() : NSRange(location:text.utf16.count,length:0)
    view.textStorage?.setAttributedString(NotebookTextTypography.attributed(text,style:style))
    view.setSelectedRange(.init(location:min(selection.location,text.utf16.count),length:min(selection.length,max(0,text.utf16.count-selection.location))))
    if text.isEmpty { view.typingAttributes = NotebookTextTypography.attributes(style:style,format:style.format ?? .init()) }
    coordinator.presentedText = text; coordinator.presentedStyle = style
  }
  static func dismantleNSView(_ view: Input, coordinator: Coordinator) { view.delegate = nil }
  final class Input: NSTextView {
    private var requestedFocus = false
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let window, !requestedFocus { requestedFocus = true; window.makeFirstResponder(self) }
    }
    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }
  }
  final class Coordinator: NSObject, NSTextViewDelegate {
    var owner: NotebookMacInlineTextInput
    var presentedText: String?
    var presentedStyle: NativeTextStyle?
    init(_ owner: NotebookMacInlineTextInput) { self.owner = owner }
    func textDidChange(_ notification: Notification) {
      guard let view = notification.object as? NSTextView else { return }
      let style = NotebookTextTypography.style(from:view.attributedString(),base:owner.style)
      presentedText = view.string; presentedStyle = style
      owner.text = view.string; owner.style = style
    }
    func textDidEndEditing(_ notification: Notification) { owner.onFinish() }
  }
}
#endif

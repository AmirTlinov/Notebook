import SwiftUI
import NotebookCore
#if os(iOS)
import UIKit
private typealias SourceColor = UIColor
#else
import AppKit
private typealias SourceColor = NSColor
#endif

/// Styling is limited to changed paragraphs; it never rewrites the source or
/// invokes the typesetter from an input callback.
@MainActor private enum SourceSyntax {
  static let tokens = try! NSRegularExpression(pattern: #"(?m)%[^\n]*|\\[a-zA-Z@]+\*?|[{}$]|(?m)^#{1,6}[^\n]*"#)
  static func highlight(_ storage: NSTextStorage, around selection: NSRange, full: Bool = false) {
    let text = storage.string as NSString
    guard text.length > 0 else { return }
    let caret = min(selection.location, text.length)
    let requested = full ? NSRange(location: 0, length: text.length) : text.paragraphRange(for: NSRange(location: caret, length: min(selection.length, text.length - caret)))
    // Extremely long single lines remain editable without an unbounded regex.
    let start = requested.length > 65_536 ? max(requested.location, caret-16_384) : requested.location
    let range = NSRange(location: start, length: min(NSMaxRange(requested)-start, 65_536))
    storage.beginEditing()
    #if os(iOS)
    storage.addAttribute(.foregroundColor, value: SourceColor.label, range: range)
    #else
    storage.addAttribute(.foregroundColor, value: SourceColor.labelColor, range: range)
    #endif
    for match in tokens.matches(in: storage.string, range: range) {
      let token = text.substring(with: match.range)
      let color: SourceColor = token.hasPrefix("%") ? .systemGray : token.hasPrefix("\\") ? .systemBlue : .systemTeal
      storage.addAttribute(.foregroundColor, value: color, range: match.range)
    }
    storage.endEditing()
  }
  static let commands = ["begin", "end", "section", "subsection", "chapter", "frac", "sqrt", "sum", "int", "partial", "alpha", "beta", "gamma", "lambda", "omega", "sin", "cos", "label", "ref", "eqref", "cite", "includegraphics", "textbf", "textit", "usepackage", "newcommand"]
}

#if os(iOS)
/// Inspect the actual generated/file source without opening an editable draft.
struct DocumentNativeSourceViewer: UIViewRepresentable {
  let text: String
  let findRequest: Int
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeUIView(context: Context) -> UITextView {
    let view = UITextView(usingTextLayoutManager: false)
    view.isEditable = false; view.isSelectable = true; view.isFindInteractionEnabled = true
    view.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
    view.textColor = .label; view.backgroundColor = .systemBackground
    view.textContainerInset = .init(top: 16, left: 16, bottom: 16, right: 16)
    return view
  }
  func updateUIView(_ view: UITextView, context: Context) {
    if view.text != text { view.text = text; view.setContentOffset(.zero, animated: false) }
    if context.coordinator.find != findRequest {
      context.coordinator.find = findRequest; view.findInteraction?.presentFindNavigator(showingReplace: false)
    }
  }
  final class Coordinator { var find = 0 }
}

struct DocumentNativeSourceEditor: UIViewRepresentable {
  let session: DocumentSourceEditorSession
  let findRequest: Int
  func makeCoordinator() -> Coordinator { Coordinator(session) }
  func makeUIView(context: Context) -> SourceTextView {
    let view = SourceTextView(usingTextLayoutManager: false)
    view.delegate = context.coordinator; view.sourceUndo = { session.undo() }
    view.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
    view.textColor = .label; view.backgroundColor = .systemBackground
    view.autocorrectionType = .no; view.autocapitalizationType = .none; view.spellCheckingType = .no
    view.smartQuotesType = .no; view.smartDashesType = .no; view.smartInsertDeleteType = .no
    view.isFindInteractionEnabled = true; view.keyboardDismissMode = .interactive
    view.textContainerInset = .init(top: 16, left: 16, bottom: 140, right: 16)
    view.text = session.text; view.selectedRange = session.selection
    SourceSyntax.highlight(view.textStorage, around: view.selectedRange, full: true)
    let bar = UIToolbar(); bar.sizeToFit()
    bar.items = [UIBarButtonItem(title: "\\", primaryAction: UIAction { [weak view] _ in view?.insertText("\\") }),
      UIBarButtonItem(title: "{}", primaryAction: UIAction { [weak view] _ in view?.insertText("{}") }),
      UIBarButtonItem(title: "Дополнить", primaryAction: UIAction { [weak view] _ in view?.completeCommand() }),
      UIBarButtonItem(systemItem: .flexibleSpace),
      UIBarButtonItem(title: "Готово", primaryAction: UIAction { [weak view] _ in view?.resignFirstResponder(); session.finish() })]
    view.inputAccessoryView = bar
    context.coordinator.navigation = session.navigation
    view.initialScroll = session.restoredScroll
    return view
  }
  func updateUIView(_ view: SourceTextView, context: Context) {
    let owner = context.coordinator; owner.applying = true; defer { owner.applying = false }
    if view.text != session.text, view.markedTextRange == nil {
      view.text = session.text; SourceSyntax.highlight(view.textStorage, around: session.selection, full: true)
    }
    if owner.navigation != session.navigation {
      owner.navigation = session.navigation; view.selectedRange = session.selection; SourceSyntax.highlight(view.textStorage, around: session.selection); view.scrollRangeToVisible(session.selection)
    }
    if owner.find != findRequest { owner.find = findRequest; view.findInteraction?.presentFindNavigator(showingReplace: true) }
  }
  static func dismantleUIView(_ view: SourceTextView, coordinator: Coordinator) { coordinator.changed(view); view.delegate = nil; view.resignFirstResponder() }
  @MainActor final class Coordinator: NSObject, UITextViewDelegate {
    let session: DocumentSourceEditorSession
    var applying = false, find = 0
    var navigation: UUID?
    init(_ session: DocumentSourceEditorSession) { self.session = session }
    func changed(_ view: UITextView) {
      guard !applying else { return }
      session.input(view.text, selection: view.selectedRange, composing: view.markedTextRange != nil, scroll: view.contentOffset.y)
    }
    func textViewDidChange(_ view: UITextView) {
      changed(view)
      guard view.markedTextRange == nil else { return }
      applying = true; SourceSyntax.highlight(view.textStorage, around: view.selectedRange); applying = false
    }
    func textViewDidChangeSelection(_ view: UITextView) { changed(view) }
    func scrollViewDidScroll(_ scroll: UIScrollView) {
      guard let view = scroll as? SourceTextView, !applying, view.markedTextRange == nil else { return }
      let bounds = CGRect(origin: view.contentOffset, size: view.bounds.size)
        .offsetBy(dx: -view.textContainerInset.left, dy: -view.textContainerInset.top)
      let glyphs = view.layoutManager.glyphRange(forBoundingRect: bounds, in: view.textContainer)
      let range = view.layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
      guard range.length > 0, view.highlightedViewport != range else { return }
      view.highlightedViewport = range; applying = true
      SourceSyntax.highlight(view.textStorage, around: range); applying = false
    }
    func textView(_ view: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
      view.text.utf16.count - range.length + text.utf16.count <= session.maximumSourceLength
    }
  }
}
final class SourceTextView: UITextView {
  var initialScroll: Double?
  var highlightedViewport: NSRange?
  override func layoutSubviews() {
    super.layoutSubviews()
    if let scroll = initialScroll, bounds.height > 0, window != nil {
      initialScroll = nil
      if scroll > 0 { setContentOffset(.init(x: 0, y: min(scroll, max(0, contentSize.height-bounds.height))), animated: false) }
      else { scrollRangeToVisible(selectedRange) }
    }
  }
  override func didMoveToWindow() {
    super.didMoveToWindow()
    NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    if window != nil {
      NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    }
  }
  @objc private func keyboardChanged(_ notification: Notification) {
    guard let window, let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
    let local = convert(window.convert(frame, from: window.screen.coordinateSpace), from: window)
    let overlap = bounds.intersection(local)
    // A floating keyboard is not a new bottom edge of the whole editor.
    let bottom = !overlap.isNull && overlap.width >= bounds.width * 0.8 && overlap.maxY >= bounds.maxY-1 ? overlap.height : 0
    contentInset.bottom = bottom
    verticalScrollIndicatorInsets.bottom = bottom
    if isFirstResponder { scrollRangeToVisible(selectedRange) }
  }
  var sourceUndo: (() -> Void)?
  override var undoManager: UndoManager? { nil }
  override var keyCommands: [UIKeyCommand]? {
    (super.keyCommands ?? []) + [UIKeyCommand(input: "z", modifierFlags: .command, action: #selector(undoSource)),
      UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(completeCommand))]
  }
  @objc private func undoSource() { sourceUndo?() }
  @objc func completeCommand() {
    let prefix = (text as NSString).substring(to: selectedRange.location)
    guard let slash = prefix.lastIndex(of: "\\") else { return }
    let name = String(prefix[prefix.index(after: slash)...])
    guard !name.isEmpty, name.allSatisfy(\.isLetter), let command = SourceSyntax.commands.first(where: { $0.hasPrefix(name) && $0 != name }) else { return }
    insertText(String(command.dropFirst(name.count)))
  }
}
#else
struct DocumentNativeSourceViewer: NSViewRepresentable {
  let text: String
  let findRequest: Int
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
    let view = NSTextView(frame: .zero)
    view.isEditable = false; view.isSelectable = true; view.isRichText = false
    view.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
    view.usesFindPanel = true; view.isIncrementalSearchingEnabled = true
    view.textContainerInset = .init(width: 16, height: 16)
    view.minSize = .zero; view.maxSize = .init(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    view.isVerticallyResizable = true; view.isHorizontallyResizable = false; view.autoresizingMask = [.width]
    view.textContainer?.widthTracksTextView = true
    view.textContainer?.containerSize = .init(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
    scroll.documentView = view
    return scroll
  }
  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let view = scroll.documentView as? NSTextView else { return }
    if view.string != text { view.string = text; view.scrollRangeToVisible(.init(location: 0, length: 0)) }
    if context.coordinator.find != findRequest {
      context.coordinator.find = findRequest; view.window?.makeFirstResponder(view)
      let sender = NSMenuItem(); sender.tag = NSTextFinder.Action.showFindInterface.rawValue; view.performTextFinderAction(sender)
    }
  }
  final class Coordinator { var find = 0 }
}

struct DocumentNativeSourceEditor: NSViewRepresentable {
  let session: DocumentSourceEditorSession
  let findRequest: Int
  func makeCoordinator() -> Coordinator { Coordinator(session) }
  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
    let view = SourceTextView(frame: .zero)
    view.delegate = context.coordinator; view.sourceUndo = { session.undo() }
    view.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
    view.isRichText = false; view.isEditable = true; view.isSelectable = true
    view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticDashSubstitutionEnabled = false
    view.isAutomaticSpellingCorrectionEnabled = false; view.isContinuousSpellCheckingEnabled = false
    view.usesFindPanel = true; view.isIncrementalSearchingEnabled = true
    view.textContainerInset = .init(width: 16, height: 16)
    view.minSize = .zero; view.maxSize = .init(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    view.isVerticallyResizable = true; view.isHorizontallyResizable = false; view.autoresizingMask = [.width]
    view.textContainer?.widthTracksTextView = true; view.textContainer?.containerSize = .init(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
    view.string = session.text; view.setSelectedRange(session.selection)
    SourceSyntax.highlight(view.textStorage!, around: session.selection, full: true)
    scroll.documentView = view
    view.initialScroll = session.restoredScroll
    context.coordinator.navigation = session.navigation
    scroll.contentView.postsBoundsChangedNotifications = true
    NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.scrolled(_:)),
      name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    return scroll
  }
  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let view = scroll.documentView as? SourceTextView else { return }
    let owner = context.coordinator; owner.applying = true; defer { owner.applying = false }
    if view.string != session.text, !view.hasMarkedText() {
      view.string = session.text; SourceSyntax.highlight(view.textStorage!, around: session.selection, full: true)
    }
    if owner.navigation != session.navigation { owner.navigation = session.navigation; view.setSelectedRange(session.selection); SourceSyntax.highlight(view.textStorage!, around: session.selection); view.scrollRangeToVisible(session.selection) }
    if owner.find != findRequest {
      owner.find = findRequest; view.window?.makeFirstResponder(view)
      let sender = NSMenuItem(); sender.tag = NSTextFinder.Action.showFindInterface.rawValue; view.performTextFinderAction(sender)
    }
  }
  static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
    NotificationCenter.default.removeObserver(coordinator)
    if let view = scroll.documentView as? SourceTextView { coordinator.changed(view); view.delegate = nil }
  }
  @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
    let session: DocumentSourceEditorSession
    var applying = false, find = 0
    var navigation: UUID?
    private var highlightedViewport: NSRange?
    init(_ session: DocumentSourceEditorSession) { self.session = session }
    func changed(_ view: NSTextView) {
      guard !applying else { return }
      session.input(view.string, selection: view.selectedRange(), composing: view.hasMarkedText(), scroll: Double(view.enclosingScrollView?.contentView.bounds.minY ?? 0))
    }
    func textDidChange(_ note: Notification) {
      guard let view = note.object as? NSTextView else { return }; changed(view)
      guard !view.hasMarkedText() else { return }
      applying = true; SourceSyntax.highlight(view.textStorage!, around: view.selectedRange()); applying = false
    }
    func textViewDidChangeSelection(_ note: Notification) { if let view = note.object as? NSTextView { changed(view) } }
    @objc func scrolled(_ note: Notification) {
      guard !applying, let clip = note.object as? NSClipView, let view = clip.documentView as? NSTextView,
        !view.hasMarkedText(), let layout = view.layoutManager, let container = view.textContainer else { return }
      let bounds = clip.bounds.offsetBy(dx: -view.textContainerOrigin.x, dy: -view.textContainerOrigin.y)
      let glyphs = layout.glyphRange(forBoundingRect: bounds, in: container)
      let range = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
      guard range.length > 0, highlightedViewport != range else { return }
      highlightedViewport = range; applying = true
      SourceSyntax.highlight(view.textStorage!, around: range); applying = false
    }
    func textView(_ view: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
      view.string.utf16.count - range.length + (replacementString?.utf16.count ?? 0) <= session.maximumSourceLength
    }
    func textView(_ textView: NSTextView, completions words: [String], forPartialWordRange range: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
      let prefix = (textView.string as NSString).substring(with: range); index?.pointee = 0
      return SourceSyntax.commands.filter { $0.hasPrefix(prefix) }
    }
  }
}
final class SourceTextView: NSTextView {
  var initialScroll: Double?
  override func layout() {
    super.layout()
    if let position = initialScroll, let scroll = enclosingScrollView, scroll.contentSize.height > 0, window != nil {
      initialScroll = nil
      if position > 0 {
        scroll.contentView.scroll(to: .init(x: 0, y: min(position, max(0, bounds.height-scroll.contentSize.height))))
        scroll.reflectScrolledClipView(scroll.contentView)
      } else { scrollRangeToVisible(selectedRange()) }
    }
  }
  var sourceUndo: (() -> Void)?
  override var undoManager: UndoManager? { nil }
  override func keyDown(with event: NSEvent) {
    if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "z" { sourceUndo?(); return }
    if event.keyCode == 48 { complete(nil); return }
    super.keyDown(with: event)
  }
}
#endif

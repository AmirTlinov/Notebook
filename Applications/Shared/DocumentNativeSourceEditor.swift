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
struct DocumentNativeSourceEditor: UIViewRepresentable {
  let session: DocumentSourceEditorSession
  var revealSelection: ((NSRange) -> Void)? = nil
  func makeCoordinator() -> Coordinator { Coordinator(session) }
  func makeUIView(context: Context) -> SourceTextView {
    let view = SourceTextView(usingTextLayoutManager: false)
    view.delegate = context.coordinator; view.sourceUndo = { session.undo() }; view.sourceRedo = { session.redo() }
    view.sourceRevealSelection = revealSelection
    view.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
    view.textColor = .label; view.backgroundColor = .systemBackground
    view.autocorrectionType = .no; view.autocapitalizationType = .none; view.spellCheckingType = .no
    view.smartQuotesType = .no; view.smartDashesType = .no; view.smartInsertDeleteType = .no
    view.keyboardDismissMode = .interactive
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
    view.sourceRevealSelection = revealSelection
    if view.text != session.text, view.markedTextRange == nil {
      view.text = session.text; SourceSyntax.highlight(view.textStorage, around: session.selection, full: true)
    }
    if owner.navigation != session.navigation {
      view.initialScroll = nil
      owner.navigation = session.navigation; view.selectedRange = session.selection; SourceSyntax.highlight(view.textStorage, around: session.selection); view.scrollRangeToVisible(session.selection)
    }
  }
  static func dismantleUIView(_ view: SourceTextView, coordinator: Coordinator) { coordinator.changed(view); view.delegate = nil; view.resignFirstResponder() }
  @MainActor final class Coordinator: NSObject, UITextViewDelegate {
    let session: DocumentSourceEditorSession
    var applying = false
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
    func textView(_ textView: UITextView, editMenuForTextInRanges ranges: [NSValue],
      suggestedActions: [UIMenuElement]) -> UIMenu? {
      guard let view = textView as? SourceTextView, view.selectedRange.length > 0 else { return nil }
      let range = view.selectedRange
      let reveal = UIAction(title: "Показать на листе", image: UIImage(systemName: "doc.viewfinder"),
        attributes: view.sourceRevealSelection == nil ? .disabled : []) { [weak view] _ in
          view?.sourceRevealSelection?(range)
        }
      return UIMenu(children: suggestedActions + [reveal])
    }
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
      guard applying || session.permitsNativeMutation() else { return false }
      return view.text.utf16.count - range.length + text.utf16.count <= session.maximumSourceLength
    }
  }
}
final class SourceTextView: UITextView, NotebookHistoryGestureTarget {
  var initialScroll: Double?
  var highlightedViewport: NSRange?
  private var permitsSourceMutation: Bool {
    (delegate as? DocumentNativeSourceEditor.Coordinator)?.session.permitsNativeMutation() == true
  }
  // UIKit's direct input methods also serve the accessory bar, completion and
  // IME. They can bypass shouldChangeTextIn; read the same live admission before
  // changing native text, rather than relying on a later session callback.
  override func insertText(_ text: String) {
    guard permitsSourceMutation else { return }
    super.insertText(text)
  }
  override func deleteBackward() {
    guard permitsSourceMutation else { return }
    super.deleteBackward()
  }
  override func replace(_ range: UITextRange, withText text: String) {
    guard permitsSourceMutation else { return }
    super.replace(range, withText: text)
  }
  override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
    guard permitsSourceMutation else { return }
    super.setMarkedText(markedText, selectedRange: selectedRange)
  }
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
  var sourceRedo: (() -> Void)?
  var sourceRevealSelection: ((NSRange) -> Void)?
  func undoFromGesture() { sourceUndo?() }
  func redoFromGesture() { sourceRedo?() }
  override var undoManager: UndoManager? { nil }
  override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }
  override var keyCommands: [UIKeyCommand]? {
    (super.keyCommands ?? []) + [UIKeyCommand(input: "z", modifierFlags: .command, action: #selector(undoSource)),
      UIKeyCommand(input: "z", modifierFlags: [.command, .shift], action: #selector(redoSource)),
      UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(completeCommand))]
  }
  @objc private func undoSource() { sourceUndo?() }
  @objc private func redoSource() { sourceRedo?() }
  @objc func completeCommand() {
    let prefix = (text as NSString).substring(to: selectedRange.location)
    guard let slash = prefix.lastIndex(of: "\\") else { return }
    let name = String(prefix[prefix.index(after: slash)...])
    guard !name.isEmpty, name.allSatisfy(\.isLetter), let command = SourceSyntax.commands.first(where: { $0.hasPrefix(name) && $0 != name }) else { return }
    insertText(String(command.dropFirst(name.count)))
  }
}
#else
struct DocumentNativeSourceEditor: NSViewRepresentable {
  let session: DocumentSourceEditorSession
  var revealSelection: ((NSRange) -> Void)? = nil
  func makeCoordinator() -> Coordinator { Coordinator(session) }
  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
    let view = SourceTextView(frame: .zero)
    view.delegate = context.coordinator; view.sourceUndo = { session.undo() }; view.sourceRedo = { session.redo() }
    view.sourceRevealSelection = revealSelection
    view.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
    view.isRichText = false; view.isEditable = true; view.isSelectable = true
    view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticDashSubstitutionEnabled = false
    view.isAutomaticSpellingCorrectionEnabled = false; view.isContinuousSpellCheckingEnabled = false
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
    view.sourceRevealSelection = revealSelection
    if view.string != session.text, !view.hasMarkedText() {
      view.string = session.text; SourceSyntax.highlight(view.textStorage!, around: session.selection, full: true)
    }
    if owner.navigation != session.navigation {
      view.initialScroll = nil
      owner.navigation = session.navigation; view.setSelectedRange(session.selection); SourceSyntax.highlight(view.textStorage!, around: session.selection); view.scrollRangeToVisible(session.selection)
    }
  }
  static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
    NotificationCenter.default.removeObserver(coordinator)
    if let view = scroll.documentView as? SourceTextView { coordinator.changed(view); view.delegate = nil }
  }
  @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
    let session: DocumentSourceEditorSession
    var applying = false
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
      // AppKit uses nil for attributes only; source styling stays available.
      guard let replacementString else { return true }
      guard applying || session.permitsNativeMutation() else { return false }
      return view.string.utf16.count - range.length + replacementString.utf16.count <= session.maximumSourceLength
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
  var sourceRedo: (() -> Void)?
  var sourceRevealSelection: ((NSRange) -> Void)?
  private var menuSelection: NSRange?
  override var undoManager: UndoManager? { nil }
  override func menu(for event: NSEvent) -> NSMenu? {
    let menu = super.menu(for: event)
    if selectedRange().length > 0 {
      menuSelection = selectedRange()
      let item = NSMenuItem(title: "Показать на листе", action: #selector(revealSource), keyEquivalent: "")
      item.target = self; item.isEnabled = sourceRevealSelection != nil
      menu?.addItem(.separator()); menu?.addItem(item)
    }
    return menu
  }
  @objc private func revealSource() { if let menuSelection { sourceRevealSelection?(menuSelection) } }
  override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    if menuItem.action == #selector(revealSource) { return sourceRevealSelection != nil && menuSelection != nil }
    if menuItem.action == #selector(performTextFinderAction(_:)) { return false }
    return super.validateMenuItem(menuItem)
  }
  override func keyDown(with event: NSEvent) {
    if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z" {
      if event.modifierFlags.contains(.shift) { sourceRedo?() } else { sourceUndo?() }; return
    }
    if event.keyCode == 48 { complete(nil); return }
    super.keyDown(with: event)
  }
}
#endif

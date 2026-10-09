#if os(iOS)
import NotebookCore
import UIKit

/// Native actions and accessibility for the exact installed PDF page. All
/// rectangles use that page's physical coordinates; this view owns no camera.
@MainActor
final class DocumentPaperInteractionView: UIView, UIGestureRecognizerDelegate {
  private struct Action {
    let rect: CGRect
    let button: PaperActionButton
    let fileID: String?
  }
  private var actions: [Action] = []
  private var paperSize = CGSize(width: 1, height: 1)
  private var article: UIAccessibilityElement?
  private var onSource: (String, CGPoint) -> Void = { _, _ in }
  private(set) var generation: UInt64?
  var isReadablePresentation: () -> Bool = { false }
  var admitsInput = false {
    didSet {
      // Accepted UIKit contacts keep their terminal route after new admission
      // closes. The enclosing paper host owns delivery until lift/cancel.
      actions.forEach { $0.button.isAccessibilityElement = admitsInput }
    }
  }
  override var accessibilityElements: [Any]? {
    get {
      guard isReadablePresentation() else { return [] }
      // A failed successor keeps the previous PDF readable. Its old actions
      // remain closed while VoiceOver can still read exactly the shown text.
      return admitsInput ? super.accessibilityElements : article.map { [$0] } ?? []
    }
    set { super.accessibilityElements = newValue }
  }
  private func sourceTap() -> UITapGestureRecognizer {
    let recognizer = UITapGestureRecognizer(target: self, action: #selector(openSource(_:)))
    recognizer.numberOfTapsRequired = 2; recognizer.numberOfTouchesRequired = 1
    recognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue),
      NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
    recognizer.delegate = self; recognizer.cancelsTouchesInView = false
    return recognizer
  }

  init() {
    super.init(frame: .zero)
    backgroundColor = .clear; isAccessibilityElement = false
  }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init()") }

  func configure(page: DocumentPreparedPage, source: DocumentSourceSnapshot, generation: UInt64,
    admit: @escaping () -> DocumentLinkAdmission?,
    activateLink: @escaping (String, DocumentLinkAdmission) -> Void,
    activateSource: @escaping (String, CGPoint) -> Void) {
    actions.forEach { $0.button.removeFromSuperview() }; actions = []
    self.generation = generation; onSource = activateSource
    paperSize = page.size
    for region in page.regions where region.kind == .file {
      guard let file = source.document.files.first(where: { $0.id == region.id && $0.isText }) else { continue }
      let rect = CGRect(x: region.frame.x, y: region.frame.y, width: region.frame.width, height: region.frame.height)
      let button = PaperActionButton(source: true)
      button.accessibilityLabel = "Исходник: \(file.path)"
      button.accessibilityIdentifier = "document-source-" + file.id
      button.admit = admit
      button.addGestureRecognizer(sourceTap())
      button.activate = { _ in activateSource(file.id, .init(x: rect.midX, y: rect.midY)) }
      addSubview(button); actions.append(.init(rect: rect, button: button, fileID: file.id))
    }
    let scale = DocumentPaperLayout.pointsToSurface
    for link in page.navigation.links {
      let rect = link.rect.applying(.init(scaleX: scale, y: scale))
      let button = PaperActionButton(source: false)
      button.accessibilityLabel = link.label; button.accessibilityTraits = .link
      button.accessibilityIdentifier = "document-link"
      button.admit = admit; button.activate = { activateLink(link.href, $0) }
      addSubview(button); actions.append(.init(rect: rect, button: button, fileID: nil))
    }
    if let text = page.navigation.pageText[page.printed.pageIndex], !text.isEmpty {
      let article = UIAccessibilityElement(accessibilityContainer: self)
      article.accessibilityLabel = text; article.accessibilityTraits = .staticText
      self.article = article
    } else { article = nil }
    accessibilityElements = (article.map { [$0 as Any] } ?? []) + actions.map { $0.button as Any }
    actions.forEach { $0.button.isAccessibilityElement = admitsInput }
    setNeedsLayout()
  }

  private func physicalPoint(_ point: CGPoint) -> CGPoint {
    .init(x: point.x * paperSize.width / max(1, bounds.width),
      y: point.y * paperSize.height / max(1, bounds.height))
  }
  private func source(at point: CGPoint) -> Action? {
    let point = physicalPoint(point)
    guard !actions.contains(where: { $0.fileID == nil && $0.rect.contains(point) }) else { return nil }
    return actions.first { $0.fileID != nil && $0.rect.contains(point) }
  }
  @objc private func openSource(_ recognizer: UITapGestureRecognizer) {
    guard recognizer.state == .ended, admitsInput,
      let action = source(at: recognizer.location(in: self)), action.button === recognizer.view, let id = action.fileID else { return }
    onSource(id, physicalPoint(recognizer.location(in: self)))
  }
  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    admitsInput && source(at: touch.location(in: self)) != nil
  }
  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    guard admitsInput else { return nil }
    let result = super.hitTest(point, with: event)
    return result === self ? nil : result
  }
  override func layoutSubviews() {
    super.layoutSubviews()
    let scaleX = bounds.width / paperSize.width, scaleY = bounds.height / paperSize.height
    for action in actions {
      action.button.frame = action.rect.applying(.init(scaleX: scaleX, y: scaleY))
    }
    article?.accessibilityFrameInContainerSpace = bounds
  }
}

/// Source touch activation belongs to the completed double tap. Keyboard and
/// VoiceOver retain the platform's ordinary button activation.
@MainActor
private final class PaperActionButton: UIButton, NotebookSceneFingerInputOwner {
  let isSource: Bool
  var admit: () -> DocumentLinkAdmission? = { nil }
  var activate: (DocumentLinkAdmission) -> Void = { _ in }
  private enum Contact {
    case absent, refused
    case accepted(DocumentLinkAdmission)
  }
  private var contact = Contact.absent
  private var endingTouch = false
  // Paper actions reserve completed taps; pan, pinch and page turn still
  // belong to the existing scene gate even though these regions are UIControls.
  func sceneFingerOwner(at point: CGPoint) -> NotebookInputGate.FingerContactOwner? { .scene }
  func cancelTransferredFingerInput() {
    contact = .refused
    NotebookSceneFingerRouting.cancelTransferredFingerInput(in: self)
  }
  init(source: Bool) {
    isSource = source
    super.init(frame: .zero)
    backgroundColor = .clear; accessibilityTraits = .button
    addTarget(self, action: #selector(performActivation), for: .primaryActionTriggered)
  }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init()") }
  override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
    let tracks = super.beginTracking(touch, with: event)
    if !isSource { contact = tracks ? (admit().map(Contact.accepted) ?? .refused) : .refused }
    return tracks
  }
  override func cancelTracking(with event: UIEvent?) {
    contact = .refused; super.cancelTracking(with: event)
  }
  override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
    // Tracking, not the optional UIEvent on target-action, identifies the
    // physical sequence. Never acquire a new admission at touch-up.
    let admission: DocumentLinkAdmission?
    if case .accepted(let accepted) = contact { admission = accepted } else { admission = nil }
    contact = .refused
    let wasEndingTouch = endingTouch
    endingTouch = true
    defer { endingTouch = wasEndingTouch }
    super.endTracking(touch, with: event)
    guard !isSource, let touch, point(inside: touch.location(in: self), with: event),
      let admission, admission.isCurrent() else { return }
    activate(admission)
  }
  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
    endingTouch = true
    defer { endingTouch = false; contact = .absent }
    super.touchesEnded(touches, with: event)
  }
  override func sendAction(_ action: Selector, to target: Any?, for event: UIEvent?) {
    // Touch completion already belongs to endTracking (or the source's
    // double tap). Keyboard target-actions acquire their own admission.
    guard !endingTouch, event?.type != .touches else { return }
    super.sendAction(action, to: target, for: event)
  }
  @objc private func performActivation() {
    guard let admission = admit(), admission.isCurrent() else { return }
    activate(admission)
  }
  override func accessibilityActivate() -> Bool {
    guard let admission = admit(), admission.isCurrent() else { return false }
    activate(admission); return true
  }
}
#endif

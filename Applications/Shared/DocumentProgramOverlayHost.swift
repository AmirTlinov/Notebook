import Foundation
import WebKit

#if os(iOS)
import UIKit

/// One physical program viewport, clipped by the measured paper fragment.
/// The placement never changes the program's DOM viewport to fit a page cut.
@MainActor
struct DocumentProgramPlacement {
  let blockID: String
  let webView: WKWebView
  let rect: CGRect
  let sourceOffset: CGFloat
  let fullSize: CGSize
  var allowsInteraction: Bool = true
}

@MainActor
struct DocumentProgramPassivePlacement {
  let blockID: String
  let raster: RasterLease
  let rect: CGRect
  let sourceOffset: CGFloat
  let fullSize: CGSize
}

@MainActor
struct DocumentProgramPendingPlacement {
  let blockID: String
  let rect: CGRect
  let message: String
  var retry: (() -> Void)? = nil
  var actionTitle: String = "Повторить"
}

/// A receipt may outlive its runtime. It observes, and never retains, the
/// physical WebKit view whose lease and lifetime belong to the block owner.
@MainActor
final class DocumentProgramInstallation {
  private final class Source {
    weak var web: WKWebView?
    let blockID: String
    let rect: CGRect
    let offset: CGFloat
    let size: CGSize
    let allowsInteraction: Bool
    init(_ placement: DocumentProgramPlacement) {
      web = placement.webView; blockID = placement.blockID; rect = placement.rect
      offset = placement.sourceOffset; size = placement.fullSize
      allowsInteraction = placement.allowsInteraction
    }
    var placement: DocumentProgramPlacement? {
      web.map { .init(blockID: blockID, webView: $0, rect: rect, sourceOffset: offset,
        fullSize: size, allowsInteraction: allowsInteraction) }
    }
  }
  private weak var host: DocumentProgramOverlayHost?
  private let sources: [Source]
  private let passive: [DocumentProgramPassiveIdentity]
  private let paperSize: CGSize
  fileprivate init(host: DocumentProgramOverlayHost, placements: [DocumentProgramPlacement], paperSize: CGSize,
    passive: [DocumentProgramPassivePlacement]) {
    self.host = host; sources = placements.map(Source.init); self.paperSize = paperSize
    self.passive = passive.map(DocumentProgramPassiveIdentity.init)
  }
  var isInstalled: Bool {
    guard let host else { return false }
    let placements = sources.compactMap(\.placement)
    return placements.count == sources.count
      && host.presentationFailure(placements, paperSize: paperSize, passiveIdentities: passive) == nil
  }
}

/// An installed receipt observes an entry identity; it cannot extend the lifetime
/// of the pixels after their native view and its accounted pin have gone away.
@MainActor
fileprivate struct DocumentProgramPassiveIdentity {
  let blockID: String
  let entryID: UUID
  let rect: CGRect
  let sourceOffset: CGFloat
  let fullSize: CGSize
  init(_ placement: DocumentProgramPassivePlacement) {
    blockID = placement.blockID; entryID = placement.raster.entryID; rect = placement.rect
    sourceOffset = placement.sourceOffset; fullSize = placement.fullSize
  }
}

@MainActor
final class DocumentProgramOverlayHost: UIView {
  var onContactChange: (String, Bool) -> Void = { _, _ in }
  private let paper = ProgramPassthroughPlane()
  private var clips: [String: ProgramFragmentClip] = [:]
  private var passiveClips: [String: ProgramPassiveClip] = [:]
  private var pendingViews: [String: ProgramPendingView] = [:]
  private var pending: [DocumentProgramPendingPlacement] = []
  private var paperSize = CGSize.zero
  private struct Request {
    var live: [DocumentProgramPlacement]
    let passive: [DocumentProgramPassivePlacement]
    let size: CGSize
    let interactive: Bool
  }
  private var requested: Request?

  init() {
    super.init(frame: .zero)
    isOpaque = false; backgroundColor = .clear; clipsToBounds = true
    addSubview(paper)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("Use init()") }

  /// Repeated presentation of the same block keeps its native view and focus.
  /// A gesture already delivered to that view also keeps its owner until the
  /// touch-up has been delivered; only then can the latest request take effect.
  @discardableResult
  func present(_ placements: [DocumentProgramPlacement], paperSize: CGSize, interactive: Bool,
    passive: [DocumentProgramPassivePlacement] = []) -> Bool {
    // A deferred transfer owns its own pins. Releasing the producer's lease
    // while a touch is finishing cannot leave a queued, unaccounted UIImage.
    var retained: [DocumentProgramPassivePlacement] = []
    for placement in passive {
      guard let raster = placement.raster.retainedCopy() else { return false }
      retained.append(.init(blockID: placement.blockID, raster: raster, rect: placement.rect,
        sourceOffset: placement.sourceOffset, fullSize: placement.fullSize))
    }
    requested = .init(live: placements, passive: retained, size: paperSize, interactive: interactive)
    return applyRequested()
  }

  func installation(for placements: [DocumentProgramPlacement], paperSize: CGSize,
    passive: [DocumentProgramPassivePlacement] = []) -> DocumentProgramInstallation {
    .init(host: self, placements: placements, paperSize: paperSize, passive: passive)
  }

  /// Delivery proof comes from the current native hierarchy, not admission or
  /// a previous successful `present` call. A transfer/detach invalidates it.
  func isPresenting(_ placements: [DocumentProgramPlacement], paperSize: CGSize,
    passive: [DocumentProgramPassivePlacement] = []) -> Bool {
    presentationFailure(placements, paperSize: paperSize, passive: passive) == nil
  }

  func presentationFailure(_ placements: [DocumentProgramPlacement], paperSize: CGSize,
    passive: [DocumentProgramPassivePlacement] = []) -> String? {
    presentationFailure(placements, paperSize: paperSize, passiveIdentities: passive.map(DocumentProgramPassiveIdentity.init))
  }

  fileprivate func presentationFailure(_ placements: [DocumentProgramPlacement], paperSize: CGSize,
    passiveIdentities: [DocumentProgramPassiveIdentity]) -> String? {
    guard let window else { return "detached" }
    guard self.paperSize == paperSize else { return "paper-size: \(self.paperSize) != \(paperSize)" }
    guard !bounds.isEmpty, !convert(bounds, to: window).intersection(window.bounds).isEmpty else { return "outside-window" }
    guard clips.count == placements.count else { return "clip-count: \(clips.count) != \(placements.count)" }
    guard passiveClips.count == passiveIdentities.count else { return "passive-clip-count" }
    var ancestor: UIView? = self
    while let view = ancestor {
      guard !view.isHidden, view.alpha > 0.01 else { return "hidden-ancestor: \(type(of: view))" }
      ancestor = view.superview
    }
    for placement in placements {
      guard let clip = clips[placement.blockID], clip.webView === placement.webView,
        clip.superview === paper, placement.webView.superview === clip,
        placement.webView.window === window else { return "program-owner: \(placement.blockID)" }
      guard !clip.isHidden, clip.alpha > 0.01, !placement.webView.isHidden,
        placement.webView.alpha > 0.01 else { return "hidden-program: \(placement.blockID)" }
      let frame = CGRect(x: 0, y: -placement.sourceOffset, width: placement.fullSize.width, height: placement.fullSize.height)
      guard Self.sameGeometry(clip.frame, placement.rect) else { return "clip-frame: \(clip.frame) != \(placement.rect)" }
      guard Self.sameGeometry(placement.webView.bounds, CGRect(origin: .zero, size: placement.fullSize)) else {
        return "program-bounds: \(placement.webView.bounds) != \(placement.fullSize)"
      }
      guard Self.sameGeometry(placement.webView.frame, frame) else { return "program-frame: \(placement.webView.frame) != \(frame)" }
      guard clip.allowsInteraction == placement.allowsInteraction else { return "program-interaction: \(placement.blockID)" }
    }
    for expected in passiveIdentities {
      guard let clip = passiveClips[expected.blockID], clip.superview === paper,
        clip.raster?.entryID == expected.entryID, clip.raster?.isReleased == false,
        !clip.isHidden, clip.alpha > 0.01, clip.imageView.superview === clip,
        clip.imageView.image != nil, !clip.imageView.isHidden, clip.imageView.alpha > 0.01,
        Self.sameGeometry(clip.frame, expected.rect),
        Self.sameGeometry(clip.imageView.frame, CGRect(x: 0, y: -expected.sourceOffset,
          width: expected.fullSize.width, height: expected.fullSize.height)) else {
        return "passive-program-owner: \(expected.blockID)"
      }
    }
    return nil
  }

  /// UIKit derives frame from center and bounds. Its floating-point round trip
  /// is not an authored geometry change; tolerance remains machine precision,
  /// many orders below a physical display pixel.
  private static func sameGeometry(_ actual: CGRect, _ expected: CGRect) -> Bool {
    let lhs = [actual.minX, actual.minY, actual.width, actual.height]
    let rhs = [expected.minX, expected.minY, expected.width, expected.height]
    let magnitude = (lhs + rhs).reduce(CGFloat(1)) { max($0, abs($1)) }
    let tolerance = 8 * magnitude.ulp
    return zip(lhs, rhs).allSatisfy { $0.isFinite && $1.isFinite && abs($0 - $1) <= tolerance }
  }

  @discardableResult
  private func applyRequested() -> Bool {
    guard let requested else { return false }
    let placements = requested.live, passive = requested.passive, size = requested.size, interactive = requested.interactive
    guard
      size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
      Set(placements.map(\.blockID) + passive.map(\.blockID)).count == placements.count + passive.count,
      Set(placements.map { ObjectIdentifier($0.webView) }).count == placements.count,
      placements.allSatisfy(Self.isValid), passive.allSatisfy(Self.isValid) else { return false }
    let held = clips.values.contains(where: \.hasContact)
    let transferring = placements.compactMap { $0.webView.superview as? ProgramFragmentClip }
      .filter { $0.hasContact && $0.host !== self }
    guard !held && transferring.isEmpty else {
      for clip in transferring { clip.waiters[ObjectIdentifier(self)] = { [weak self] in _ = self?.applyRequested() } }
      return false
    }
    let desired = Set(placements.map(\.blockID))
    let passiveIDs = Set(passive.map(\.blockID))
    CATransaction.begin(); CATransaction.setDisableActions(true)
    for id in Set(clips.keys).subtracting(desired) {
      clips.removeValue(forKey: id)?.retire()
    }
    for id in Set(passiveClips.keys).subtracting(passiveIDs) {
      passiveClips.removeValue(forKey: id)?.retire()
    }
    self.paperSize = size
    for placement in passive {
      let clip = passiveClips[placement.blockID] ?? ProgramPassiveClip()
      if clip.superview == nil { passiveClips[placement.blockID] = clip; paper.addSubview(clip) }
      clip.configure(placement)
    }
    for placement in placements {
      Self.releasePreviousHost(of: placement.webView, keeping: self)
      let clip: ProgramFragmentClip
      if let existing = clips[placement.blockID], existing.webView === placement.webView {
        clip = existing
      } else {
        clips.removeValue(forKey: placement.blockID)?.retire()
        clip = ProgramFragmentClip(blockID: placement.blockID, webView: placement.webView, host: self)
        clips[placement.blockID] = clip; paper.addSubview(clip)
      }
      clip.configure(placement, interactive: interactive)
      paper.bringSubviewToFront(clip)
    }
    layoutPaper()
    applyPending()
    CATransaction.commit()
    return true
  }

  /// Keep an unmounted program attached to a real window for its own snapshot.
  /// The paper bounds exclude this view from display, hit testing and AX.
  @discardableResult
  func park(_ webView: WKWebView, fullSize: CGSize) -> Bool {
    guard fullSize.width.isFinite, fullSize.height.isFinite, fullSize.width > 0, fullSize.height > 0,
      (webView.superview as? ProgramFragmentClip)?.hasContact != true else { return false }
    Self.releasePreviousHost(of: webView, keeping: self)
    forgetRequested(webView)
    for id in clips.keys.filter({ clips[$0]?.webView === webView }) {
      clips.removeValue(forKey: id)?.retire()
    }
    if webView.superview !== self { addSubview(webView) }
    webView.transform = .identity
    webView.frame = CGRect(x: -fullSize.width - 1024, y: 0, width: fullSize.width, height: fullSize.height)
    webView.isUserInteractionEnabled = false; webView.accessibilityElementsHidden = true
    return true
  }

  func removePrograms() {
    pending = []
    requested = .init(live: [], passive: [], size: paperSize, interactive: false)
    _ = applyRequested()
    for web in subviews.compactMap({ $0 as? WKWebView }) { web.removeFromSuperview() }
  }

  /// Preparation and failure belong to their own fragment. Updating them never
  /// covers a neighboring ready runtime or changes the text viewport below it.
  func presentPending(_ entries: [DocumentProgramPendingPlacement]) {
    pending = entries
    applyPending()
  }

  private func applyPending() {
    guard !clips.values.contains(where: \.hasContact) else { return }
    let visible = pending.filter { clips[$0.blockID]?.allowsInteraction != true && !$0.rect.isNull && !$0.rect.isInfinite
      && $0.rect.width > 0 && $0.rect.height > 0 }
    let ids = Set(visible.map(\.blockID))
    for id in Set(pendingViews.keys).subtracting(ids) {
      pendingViews.removeValue(forKey: id)?.removeFromSuperview()
    }
    for entry in visible {
      let view = pendingViews[entry.blockID] ?? ProgramPendingView()
      if view.superview == nil { pendingViews[entry.blockID] = view; paper.addSubview(view) }
      view.configure(entry)
      paper.bringSubviewToFront(view)
    }
    for clip in clips.values where clip.allowsInteraction { paper.bringSubviewToFront(clip) }
  }

  @discardableResult
  func removeProgram(_ webView: WKWebView) -> Bool {
    guard (webView.superview as? ProgramFragmentClip)?.hasContact != true else { return false }
    forgetRequested(webView)
    for id in clips.keys.filter({ clips[$0]?.webView === webView }) {
      clips.removeValue(forKey: id)?.retire()
    }
    if webView.isDescendant(of: self) { webView.removeFromSuperview() }
    return true
  }

  private func forgetRequested(_ webView: WKWebView) {
    requested?.live.removeAll { $0.webView === webView }
  }

  private static func releasePreviousHost(of webView: WKWebView, keeping host: DocumentProgramOverlayHost) {
    let previous = (webView.superview as? ProgramFragmentClip)?.host
      ?? (webView.superview as? DocumentProgramOverlayHost)
    if let previous, previous !== host { _ = previous.removeProgram(webView) }
  }

  fileprivate func contactChanged(_ clip: ProgramFragmentClip, active: Bool) {
    onContactChange(clip.blockID, active)
    if !active { _ = applyRequested() }
  }

  override func layoutSubviews() { super.layoutSubviews(); layoutPaper() }

  private func layoutPaper() {
    guard paperSize.width > 0, paperSize.height > 0 else { return }
    let scale = min(bounds.width / paperSize.width, bounds.height / paperSize.height)
    guard scale.isFinite, scale > 0 else { return }
    paper.bounds = CGRect(origin: .zero, size: paperSize)
    paper.center = CGPoint(x: bounds.midX, y: bounds.midY)
    paper.transform = CGAffineTransform(scaleX: scale, y: scale)
  }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    guard !isHidden, alpha > 0.01, isUserInteractionEnabled, bounds.contains(point) else { return nil }
    return paper.hitTest(convert(point, to: paper), with: event)
  }

  private static func isValid(_ value: DocumentProgramPlacement) -> Bool {
    isValid(blockID: value.blockID, rect: value.rect, offset: value.sourceOffset, size: value.fullSize)
  }
  private static func isValid(_ value: DocumentProgramPassivePlacement) -> Bool {
    !value.raster.isReleased && isValid(blockID: value.blockID, rect: value.rect, offset: value.sourceOffset, size: value.fullSize)
  }
  private static func isValid(blockID: String, rect: CGRect, offset: CGFloat, size: CGSize) -> Bool {
    !blockID.isEmpty && !rect.isNull && !rect.isInfinite
      && rect.minX.isFinite && rect.minY.isFinite
      && rect.width > 0 && rect.height > 0 && size.width.isFinite && size.height.isFinite
      && size.width > 0 && size.height > 0 && offset.isFinite && offset >= 0
      && offset + rect.height <= size.height + 1.0 / 32
      && abs(rect.width - size.width) <= 1.0 / 32
  }
}

@MainActor
private final class ProgramPassiveClip: UIView {
  let imageView = UIImageView()
  private(set) var raster: RasterLease?
  init() {
    super.init(frame: .zero)
    clipsToBounds = true; isOpaque = false; backgroundColor = .clear; isUserInteractionEnabled = false
    imageView.contentMode = .scaleToFill; addSubview(imageView)
  }
  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("Use init()") }
  func configure(_ placement: DocumentProgramPassivePlacement) {
    if raster?.entryID != placement.raster.entryID {
      // The request already owns a valid pin; this native view keeps another
      // until its image is replaced or its final native owner is released.
      let next = placement.raster.retainedCopy()
      imageView.image = next?.image
      raster = next
    }
    frame = placement.rect
    imageView.frame = CGRect(x: 0, y: -placement.sourceOffset,
      width: placement.fullSize.width, height: placement.fullSize.height)
  }
  /// UIKit may retain a departed view through a transition or an outside
  /// observer. The installed image's lifetime ends at native retirement,
  /// independently of when that view is finally deallocated.
  func retire() {
    removeFromSuperview()
    imageView.image = nil
    raster?.release(); raster = nil
  }
  isolated deinit { imageView.image = nil; raster?.release() }
}

@MainActor
private final class ProgramPassthroughPlane: UIView {
  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    let hit = super.hitTest(point, with: event)
    return hit === self ? nil : hit
  }
}

@MainActor
private final class ProgramPendingView: UIView {
  private let label = UILabel()
  private let spinner = UIActivityIndicatorView(style: .medium)
  private let button = UIButton(type: .system)
  private var retry: (() -> Void)?
  init() {
    super.init(frame: .zero)
    clipsToBounds = true; backgroundColor = .clear; isOpaque = false
    label.font = .preferredFont(forTextStyle: .caption1); label.numberOfLines = 2
    label.textAlignment = .center; label.adjustsFontForContentSizeCategory = true
    var configuration = UIButton.Configuration.tinted()
    configuration.title = "Повторить"; configuration.cornerStyle = .medium
    button.configuration = configuration
    button.addTarget(self, action: #selector(retryPressed), for: .touchUpInside)
    let stack = UIStackView(arrangedSubviews: [spinner, label, button])
    stack.axis = .horizontal; stack.alignment = .center; stack.spacing = 8
    stack.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.96)
    stack.layer.cornerRadius = 12; stack.isLayoutMarginsRelativeArrangement = true
    stack.directionalLayoutMargins = .init(top: 6, leading: 8, bottom: 6, trailing: 8)
    stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
    NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: centerYAnchor),
      stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -12),
      button.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
      button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)])
  }
  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("Use init()") }
  func configure(_ entry: DocumentProgramPendingPlacement) {
    frame = entry.rect; label.text = entry.message; retry = entry.retry
    button.setTitle(entry.actionTitle, for: .normal)
    button.isHidden = retry == nil
    button.accessibilityIdentifier = "document-program-retry-" + entry.blockID
    if retry == nil { spinner.startAnimating() } else { spinner.stopAnimating() }
  }
  @objc private func retryPressed() { retry?() }
}

@MainActor
fileprivate final class ProgramFragmentClip: UIView, NotebookSceneFingerInputOwner {
  let blockID: String
  private(set) weak var webView: WKWebView?
  weak var host: DocumentProgramOverlayHost?
  private let observer = ProgramContactObserver()
  private(set) var hasContact = false
  private(set) var allowsInteraction = true
  func sceneFingerOwner(at point: CGPoint) -> NotebookInputGate.FingerContactOwner? {
    allowsInteraction && isUserInteractionEnabled && webView?.superview === self ? .nativeInput(ObjectIdentifier(self)) : nil
  }
  private var contactGeneration: UInt64 = 0
  var waiters: [ObjectIdentifier: () -> Void] = [:]

  init(blockID: String, webView: WKWebView, host: DocumentProgramOverlayHost) {
    self.blockID = blockID; self.webView = webView; self.host = host
    super.init(frame: .zero)
    clipsToBounds = true; isOpaque = false; backgroundColor = .clear
    observer.changed = { [weak self] in self?.receiveContact($0) }
    addGestureRecognizer(observer)
  }
  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("Use init(blockID:webView:host:)") }

  func configure(_ placement: DocumentProgramPlacement, interactive: Bool) {
    guard let webView else { return }
    allowsInteraction = placement.allowsInteraction
    frame = placement.rect
    if webView.superview !== self { addSubview(webView) }
    webView.transform = .identity
    webView.frame = CGRect(x: 0, y: -placement.sourceOffset,
      width: placement.fullSize.width, height: placement.fullSize.height)
    let acceptsInput = interactive && allowsInteraction
    webView.isUserInteractionEnabled = acceptsInput; webView.accessibilityElementsHidden = !acceptsInput
    isUserInteractionEnabled = acceptsInput
  }

  /// Removing this physical cut ends its ownership immediately. A retained
  /// UIKit transition shell must not keep an executor beyond its pool lease.
  func retire() {
    if let webView, webView.superview === self { webView.removeFromSuperview() }
    webView = nil; host = nil; observer.changed = { _ in }
    removeFromSuperview()
  }

  private func receiveContact(_ active: Bool) {
    contactGeneration &+= 1
    if active {
      guard !hasContact else { return }
      hasContact = true; host?.contactChanged(self, active: true)
    } else {
      let generation = contactGeneration
      // The recognizer receives touch-up before WK's event delivery can finish.
      // A page switch here would remove the button before it receives its click.
      DispatchQueue.main.async { [weak self] in
        guard let self, contactGeneration == generation, hasContact else { return }
        hasContact = false
        host?.contactChanged(self, active: false)
        let ready = Array(waiters.values); waiters.removeAll()
        ready.forEach { $0() }
      }
    }
  }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    guard webView?.superview === self else { return nil }
    let hit = super.hitTest(point, with: event)
    return hit === self ? nil : hit
  }
}

@MainActor
private final class ProgramContactObserver: UIGestureRecognizer, UIGestureRecognizerDelegate {
  var changed: (Bool) -> Void = { _ in }
  private var contacts: Set<UITouch> = []
  init() {
    super.init(target: nil, action: nil)
    cancelsTouchesInView = false; delaysTouchesBegan = false; delaysTouchesEnded = false; delegate = self
  }
  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("Use init()") }
  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
    let empty = contacts.isEmpty
    contacts.formUnion(touches)
    if empty { changed(true); state = .began } else { state = .changed }
  }
  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) { state = .changed }
  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches, cancelled: false) }
  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches, cancelled: true) }
  private func finish(_ touches: Set<UITouch>, cancelled: Bool) {
    contacts.subtract(touches)
    if contacts.isEmpty { changed(false); state = cancelled ? .cancelled : .ended }
  }
  override func reset() {
    super.reset()
    if !contacts.isEmpty { contacts.removeAll(); changed(false) }
  }
  override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
  override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
}
#endif

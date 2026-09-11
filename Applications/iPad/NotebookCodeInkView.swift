import SwiftUI
import UIKit
import NotebookCore

/// One viewport-sized Metal canvas. Its text-space projection follows the
/// UITextView offset; the board camera and source samples never participate.
@MainActor
final class NotebookCodeInkPresenter {
  private weak var text: NotebookCodeTextView?
  private let notes: NotebookCodeAnnotations
  private let file: NotebookFileAddress
  private let gate: NotebookInputGate
  private let source = UUID()
  let overlay = NotebookCodePencilOverlay()
  private var captured: (NotebookCodeFragment, CGFloat)?
  private var generation: UInt64 = 0
  private var preparation: Task<Void, Never>?
  private var shown: [NotebookCodeInkPlacement] = []
  private var markers: [UUID: UIButton] = [:]
  private var closed = false
  private var ranges: [UUID: NSRange] = [:]
  private var missingRanges = Set<UUID>()
  private var sourceHash: String?
  private let review: NotebookCodeFragment?
  var isActive: Bool { captured != nil }

  init(text: NotebookCodeTextView, notes: NotebookCodeAnnotations, file: NotebookFileAddress,
    gate: NotebookInputGate, review: NotebookCodeFragment? = nil) {
    self.text = text; self.notes = notes; self.file = file; self.gate = gate; self.review = review
    overlay.backgroundColor = .clear; overlay.isOpaque = false
    text.addSubview(overlay)
    overlay.paper.touchView.accessibilityLabel = "Пометки на коде"
    overlay.paper.touchView.accessibilityIdentifier = "notebook-code-ink"
    overlay.paper.touchView.canBeginAction = { [weak self] in self?.canBegin == true }
    overlay.paper.touchView.onActionWillBegin = { [weak self] in self?.begin() == true }
    overlay.paper.touchView.onActionCancelled = { [weak self] in self?.end() }
    overlay.paper.touchView.onDrawingMutation = { [weak self] action in self?.accept(action) }
    gate.registerPageFinisher(source: source) { [weak self] waits, completion in
      guard let self else { completion(); return }
      finish()
      if waits { Task { _ = await self.notes.flush(); completion() } } else { completion() }
    }
    gate.registerFingerCancellation(source: source) { [weak text] in
      guard let text else { return }
      // UIKit must end deceleration before Pencil leases the visible lines.
      text.setContentOffset(text.contentOffset, animated: false)
      text.panGestureRecognizer.isEnabled = false; text.panGestureRecognizer.isEnabled = true
    }
  }
  private var canBegin: Bool { !closed && review == nil && gate.permitsNewContact && !notes.contactActive && text?.isEditable == false }
  func configure(pen: PenStyle, eraser: EraserStyle, tool: DrawingTool) {
    overlay.acceptsPencil = review == nil && text?.isEditable == false
    overlay.paper.touchView.configure(penStyle: pen, eraserStyle: eraser, drawingTool: tool)
  }
  func layout() {
    guard !closed, let text, text.bounds.width > 0, text.bounds.height > 0 else { return }
    // A measured contact keeps its original line layout and touch plane until
    // lift. Resizing the window can clip it, not rewrap code under the nib.
    guard captured == nil else { return }
    overlay.frame = text.bounds; overlay.setNeedsLayout(); overlay.layoutIfNeeded()
    project()
    rebuild()
  }
  private func project() {
    guard let text else { return }
    let viewport = SpatialPoint(x: overlay.bounds.width, y: overlay.bounds.height)
    let camera = SpatialCamera(center: .init(x: text.contentOffset.x + viewport.x / 2,
      y: text.contentOffset.y + viewport.y / 2), scale: 1)
    overlay.paper.inkView.project(camera: camera, viewport: viewport)
  }
  private func begin() -> Bool {
    guard canBegin, let text, !text.text.isEmpty else { return false }
    text.layoutManager.ensureLayout(for: text.textContainer)
    let visible = CGRect(x: 0, y: max(0, text.contentOffset.y - text.textContainerInset.top),
      width: text.bounds.width, height: text.bounds.height)
    let glyphs = text.layoutManager.glyphRange(forBoundingRect: visible, in: text.textContainer)
    let characters = text.layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
    let sourceText = text.text! as NSString
    guard characters.location < sourceText.length else { return false }
    let range = sourceText.paragraphRange(for: characters)
    let glyphRange = text.layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
    let rect = text.layoutManager.boundingRect(forGlyphRange: glyphRange, in: text.textContainer)
    let origin = rect.minY + text.textContainerInset.top
    // Keep blank space below the last visible line usable for a short note.
    let height = max(rect.height, text.contentOffset.y + text.bounds.height - origin)
    guard let fragment = notes.reserve(file: file, source: text.text, offset: range.location,
      text: sourceText.substring(with: range), width: text.bounds.width, height: max(1, height), fontSize: Double(text.font?.pointSize ?? 15)) else { return false }
    guard gate.beginPencilAction(source: source) else { notes.cancelContact(); return false }
    preparation?.cancel(); generation &+= 1
    captured = (fragment, text.contentOffset.y - origin)
    text.textContainer.widthTracksTextView = false
    text.panGestureRecognizer.isEnabled = false
    overlay.paper.inkView.isHidden = false
    overlay.paper.inkView.beginSpatialAction()
    return true
  }
  private func accept(_ action: PageInkAction) {
    guard let (fragment, offset) = captured else { return }
    // The queue accepts UUID and samples before the input gate is released.
    notes.accept(action, fragment: fragment, originY: offset)
    overlay.paper.inkView.finishSpatialAction(keepingCommittedMesh: true)
    end()
  }
  private func end() {
    guard captured != nil else { return }
    captured = nil; notes.cancelContact()
    text?.textContainer.widthTracksTextView = true
    text?.panGestureRecognizer.isEnabled = true
    gate.endPencilAction(source: source)
    text?.setNeedsLayout()
    layout()
  }
  func finish() { overlay.paper.touchView.finishCurrentAction {} }
  func stop() {
    guard !closed else { return }
    finish(); end(); closed = true; generation &+= 1; preparation?.cancel(); preparation = nil
    overlay.paper.touchView.canBeginAction = { false }
    overlay.paper.touchView.onActionWillBegin = nil; overlay.paper.touchView.onDrawingMutation = nil
    overlay.paper.touchView.onActionCancelled = nil
    gate.unregisterPageFinisher(source: source); gate.unregisterFingerCancellation(source: source)
    let canvas = overlay.paper.inkView
    overlay.removeFromSuperview(); markers.values.forEach { $0.removeFromSuperview() }; markers = [:]
    Task { await canvas.finishSpatialHandoffFrames() }
  }

  func invalidateText() {
    ranges = [:]; missingRanges = []; sourceHash = nil; shown = []
    generation &+= 1; preparation?.cancel()
    overlay.paper.inkView.applySpatial(.init(batches: []))
  }
  private func rebuild() {
    guard let text, captured == nil else { return }
    let candidates = review.map { [$0] } ?? notes.fragments
    var placements: [NotebookCodeInkPlacement] = [], requested: [UUID] = [], activeMarkers = Set<UUID>()
    for fragment in candidates {
      let range: NSRange?
      if review != nil { range = NSRange(location: 0, length: text.text.utf16.count) }
      else if let stored = ranges[fragment.id] { range = stored }
      else if missingRanges.contains(fragment.id) { range = nil }
      else {
        if sourceHash == nil { sourceHash = NotebookFileVersion.hash(Data(text.text.utf8)) }
        range = fragment.range(in: text.text, sourceHash: sourceHash)
        if let range { ranges[fragment.id] = range } else { missingRanges.insert(fragment.id) }
      }
      guard let range else { continue } // The note list retains the original material.
      let glyphs = text.layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
      let rect = text.layoutManager.boundingRect(forGlyphRange: glyphs, in: text.textContainer)
      let y = rect.minY + text.textContainerInset.top
      let compatible = abs(fragment.width - text.bounds.width) < 0.5 && abs(fragment.fontSize - Double(text.font?.pointSize ?? 15)) < 0.01
      let area = CGRect(x: 0, y: y, width: text.bounds.width, height: fragment.height)
      if area.intersects(text.bounds), requested.count < 8 {
        requested.append(fragment.id)
        if compatible, let annotation = notes.annotations[fragment.id] {
          placements.append(.init(annotation: annotation, originY: y))
        }
      }
      if review == nil, area.intersects(text.bounds) {
        activeMarkers.insert(fragment.id)
        let button: UIButton
        if let prior = markers[fragment.id] { button = prior }
        else {
          button = UIButton(type: .system)
          button.setImage(UIImage(systemName: "pencil.tip.crop.circle"), for: .normal)
          button.backgroundColor = .secondarySystemBackground; button.layer.cornerRadius = 18
          button.accessibilityLabel = "Открыть исходный код с пометкой"
          button.addAction(UIAction { [weak self] _ in
            self?.gate.performAfterPageContact { [weak self] in self?.notes.reviewed = fragment }
          }, for: .touchUpInside)
          text.addSubview(button); markers[fragment.id] = button
        }
        button.frame = .init(x: text.bounds.maxX - 44, y: max(text.bounds.minY, y), width: 40, height: 40)
      }
    }
    for id in Set(markers.keys).subtracting(activeMarkers) { markers.removeValue(forKey: id)?.removeFromSuperview() }
    // Calling observable state setters during UIKit layout is deferred, while
    // the projection above follows the actual scroll synchronously.
    if !requested.isEmpty { Task { [weak notes] in notes?.show(requested) } }
    guard placements != shown else { return }
    shown = placements; generation &+= 1; let generation = generation
    preparation?.cancel()
    // A reflow is never shown with an old, incorrectly attached handwriting.
    overlay.paper.inkView.applySpatial(.init(batches: []))
    overlay.paper.inkView.isHidden = true
    preparation = Task { [weak self, placements] in
      do {
        let worker = Task.detached(priority: .userInitiated) {
          var ordered: [(SpatialInkAction, Double, UUID)] = []
          for item in placements { for action in item.annotation.ink.actions where action.isActive { ordered.append((action, item.originY, item.annotation.fragment.id)) } }
          ordered.sort { $0.0.stamp == $1.0.stamp ? $0.0.id.uuidString < $1.0.id.uuidString : $0.0.stamp < $1.0.stamp }
          var batches: [SpatialInkMesh.Batch] = []
          for (action, y, id) in ordered {
            try Task.checkCancellation()
            let mesh = try SpatialInkMesh.prepare(surface: .codeFragment(id), journal: .init(actions: [action], stamp: max(action.stamp, action.stateStamp)))
            batches += mesh.batches.map { .init(tool: $0.tool, vertices: $0.vertices, chunks: $0.chunks, projection: .world(.init(x: 0, y: y))) }
          }
          return SpatialInkMesh(batches: batches)
        }
        let mesh = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        guard !Task.isCancelled, let self, !closed, captured == nil, self.generation == generation else { return }
        overlay.paper.inkView.applySpatial(mesh); project(); overlay.paper.inkView.isHidden = false
        // PaperInput's value describes the represented contacts; this adapter
        // does not serialize a second drawing or replace the spatial owner.
        let actions = placements.flatMap { $0.annotation.ink.actions }.sorted { $0.stamp < $1.stamp }.map { action in
          PageInkAction(id: action.id, tool: action.tool, color: action.color,
            samples: action.spans.flatMap(\.samples), isActive: action.isActive)
        }
        overlay.paper.touchView.acceptCommittedDrawing(.init(actions: actions))
      } catch { /* Cancelled geometry cannot publish over a newer text layout. */ }
    }
  }
}

private struct NotebookCodeInkPlacement: Equatable, Sendable {
  let annotation: NotebookCodeAnnotation
  let originY: Double
  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.originY == rhs.originY && lhs.annotation.fragment == rhs.annotation.fragment
      && lhs.annotation.ink.actions == rhs.annotation.ink.actions
  }
}

@MainActor
final class NotebookCodePencilOverlay: UIView {
  let paper = PaperCanvasContainerView()
  var acceptsPencil = true
  override init(frame: CGRect) { super.init(frame: frame); addSubview(paper) }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
  override func layoutSubviews() { super.layoutSubviews(); paper.frame = bounds }
  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    guard acceptsPencil, self.point(inside: point, with: event) else { return nil }
    var pencil = event?.allTouches?.contains { $0.type == .pencil } == true
    #if DEBUG && targetEnvironment(simulator)
      if ProcessInfo.processInfo.arguments.contains("--notebook-code-pencil-fixture") { pencil = true }
    #endif
    return pencil ? paper.touchView : nil
  }
}

/// The preserved layout is a normal vertical scroll, not a paged notebook or
/// a screenshot. Horizontal scrolling appears only when its original width
/// exceeds the current window; handwriting is never stretched to fit it.
struct NotebookCodeReviewView: View {
  @Environment(NotebookAppModel.self) private var model
  let notes: NotebookCodeAnnotations
  let fragment: NotebookCodeFragment
  var body: some View {
    NavigationStack {
      GeometryReader { geometry in
        ScrollView(.horizontal) {
          NotebookReviewedCode(notes: notes, fragment: fragment, gate: model.inputGate)
            .frame(width: fragment.width, height: geometry.size.height)
        }
      }
      .navigationTitle("Рассмотренный код")
      .toolbar {
        Button("Обсудить") { model.discussCode(fragment); notes.reviewed = nil }
        Button("Готово") { notes.reviewed = nil }
      }
    }
  }
}
private struct NotebookReviewedCode: UIViewRepresentable {
  let notes: NotebookCodeAnnotations
  let fragment: NotebookCodeFragment
  let gate: NotebookInputGate
  func makeUIView(context: Context) -> NotebookCodeTextView {
    let view = NotebookCodeTextView()
    view.text = fragment.text; view.font = .monospacedSystemFont(ofSize: fragment.fontSize, weight: .regular)
    view.textColor = .label; view.backgroundColor = .systemBackground; view.isEditable = false
    view.textContainerInset = .init(top: 18, left: 16, bottom: max(100, fragment.height), right: 24)
    view.ink = .init(text: view, notes: notes, file: fragment.file, gate: gate, review: fragment)
    return view
  }
  func updateUIView(_ view: NotebookCodeTextView, context: Context) { _ = notes.annotations[fragment.id]; view.ink?.layout() }
  static func dismantleUIView(_ view: NotebookCodeTextView, coordinator: Void) { view.ink?.stop(); view.ink = nil }
}

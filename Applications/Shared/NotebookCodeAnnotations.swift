#if os(iOS)
import Foundation
import Observation
import NotebookCore

/// Notebook's notes, not Mac file contents. All accepted contacts enter the
/// same persistence queue synchronously; a failed write retains its operation.
@MainActor @Observable
final class NotebookCodeAnnotations {
  private(set) var fragments: [NotebookCodeFragment] = []
  private(set) var annotations: [UUID: NotebookCodeAnnotation] = [:]
  private(set) var hasMore = false
  private(set) var error: String?
  private(set) var contactActive = false
  private(set) var ready = false
  var reviewed: NotebookCodeFragment?
  @ObservationIgnored private let persistence: NotebookPersistenceQueue
  @ObservationIgnored private let author: UUID
  @ObservationIgnored private var file: NotebookFileAddress?
  @ObservationIgnored private var clock: VersionStamp
  @ObservationIgnored private var history = PencilUndoHistory()
  @ObservationIgnored private var contributionOrder: [UUID] = []
  @ObservationIgnored private var pending: [UUID: (NotebookCodeFragment, NotebookSpatialInkCommand)] = [:]
  @ObservationIgnored private var visible = [UUID]()
  @ObservationIgnored private var refreshing = false
  @ObservationIgnored private var nextPageAfter: UUID?
  @ObservationIgnored private var revision: UInt64 = 0

  init(persistence: NotebookPersistenceQueue, author: UUID) {
    self.persistence = persistence; self.author = author; clock = .init(counter: 0, actor: author)
  }
  var acceptsNewContacts = true
  func select(_ file: NotebookFileAddress?) async {
    guard self.file != file else { await refresh(); return }
    self.file = file; ready = false; revision &+= 1; contributionOrder = []; fragments = []; annotations = [:]; visible = []; reviewed = nil; hasMore = false; nextPageAfter = nil
    await refresh()
  }
  func refresh(more: Bool = false) async {
    guard let file, !refreshing, !contactActive else { return }
    refreshing = true
    defer {
      refreshing = false
      if self.file != file { Task { await refresh() } }
    }
    let after = more ? nextPageAfter : nil, wanted = visible, revision = revision
    do {
      let result = try await persistence.submit { store in
        try store.readTransaction { store in
          let fragments = try store.codeFragments(file: file, after: after)
          let ink = try wanted.compactMap { try store.codeAnnotation($0) }
          return (fragments, ink, try store.readSpatialInk(surfaces: []).stamp)
        }
      }
      guard self.file == file, self.revision == revision, !contactActive else { return }
      clock = max(clock, result.2)
      // Optimistic contacts have arbitrary UUIDs. Only the last stored row of
      // the preceding page can continue the directory without skipping notes.
      if more || nextPageAfter == nil {
        hasMore = result.0.count == 64
        nextPageAfter = result.0.last?.id ?? nextPageAfter
      }
      // Retain expanded pages during refresh; each immutable row is read once.
      if more { for fragment in result.0 where !fragments.contains(where: { $0.id == fragment.id }) { fragments.append(fragment) } }
      else { fragments = result.0 + fragments.filter { old in !result.0.contains { $0.id == old.id } } }
      for (fragment, _) in pending.values where fragment.file == file && !fragments.contains(where: { $0.id == fragment.id }) { fragments.append(fragment) }
      var next: [UUID: NotebookCodeAnnotation] = [:]
      for annotation in result.1 {
        clock = max(clock, annotation.ink.stamp); next[annotation.fragment.id] = annotation
      }
      // No stale database read is allowed to replace an accepted contact.
      for (fragment, command) in pending.values where fragment.file == file {
        var journal = next[fragment.id]?.ink ?? annotations[fragment.id]?.ink ?? .init(stamp: clock)
        switch command {
        case .append(let action, let stamp): _ = journal.merge(.init(actions: [action], stamp: stamp))
        case .state(let id, _, let active, let state, _): _ = Self.setState(&journal, id: id, active: active, stamp: state)
        }
        next[fragment.id] = .init(fragment: fragment, ink: journal)
      }
      annotations = next; ready = true; fragments.sort { $0.id.uuidString < $1.id.uuidString }; error = nil
    } catch { self.error = error.localizedDescription }
  }
  func show(_ ids: [UUID]) {
    let ids = Array(ids.prefix(8))
    guard ids != visible else { return }; visible = ids
    Task { await refresh() }
  }
  func reserve(file: NotebookFileAddress, source: String, offset: Int, text: String, width: Double, height: Double, fontSize: Double) -> NotebookCodeFragment? {
    guard let fragment = material(file: file, source: source, offset: offset, text: text, width: width, height: height, fontSize: fontSize),
      let next = clock.advanced(by: author) else { return nil }
    clock = next; contactActive = true; return fragment
  }
  func material(file: NotebookFileAddress, source: String, offset: Int, text: String, width: Double, height: Double, fontSize: Double) -> NotebookCodeFragment? {
    guard acceptsNewContacts, ready, !contactActive, self.file == file, let next = clock.advanced(by: author) else { return nil }
    let hash = NotebookFileVersion.hash(Data(source.utf8))
    let fragment = fragments.first { $0.sourceHash == hash && $0.utf16Offset == offset && $0.text == text && $0.width == width && $0.height == height && $0.fontSize == fontSize }
      ?? .init(file: file, sourceHash: hash, utf16Offset: offset, text: text, width: width, height: height, fontSize: fontSize, stamp: next)
    guard fragment.isValid else { error = "Рассмотренный фрагмент слишком велик для одной пометки."; return nil }
    return fragment
  }
  func cancelContact() { contactActive = false }
  func review(_ fragment: NotebookCodeFragment) async {
    do {
      let value = try await persistence.submit { try $0.codeAnnotation(fragment.id) }
      guard !contactActive else { return }
      if let value { annotations[fragment.id] = value }
      reviewed = fragment
    } catch { self.error = error.localizedDescription }
  }
  func accept(_ measured: PageInkAction, fragment: NotebookCodeFragment, originY: Double) {
    guard contactActive else { return }
    let stamp = clock.advanced(by: author) ?? clock
    clock = stamp; revision &+= 1
    let samples = measured.samples.map { sample in
      SpatialInkSample(point: .init(x: sample.point.x, y: sample.point.y + originY), timeOffset: sample.timeOffset,
        width: sample.width, opacity: sample.opacity, force: sample.force, azimuth: sample.azimuth, altitude: sample.altitude)
    }
    let action = SpatialInkAction(id: measured.id, tool: measured.tool, color: measured.color,
      spans: [.init(surface: .codeFragment(fragment.id), samples: samples)], stamp: stamp)
    if !fragments.contains(where: { $0.id == fragment.id }) { fragments.append(fragment) }
    var journal = annotations[fragment.id]?.ink ?? .init(stamp: stamp)
    _ = journal.merge(.init(actions: [action], stamp: stamp))
    annotations[fragment.id] = .init(fragment: fragment, ink: journal)
    history.recordAction(ownerID: fragment.id, actionID: action.id); contributionOrder.append(fragment.id)
    contributionOrder = Array(contributionOrder.suffix(32))
    enqueue(fragment, .append(action, journalStamp: stamp))
    contactActive = false
  }
  func undo() {
    guard !contactActive, let id = contributionOrder.last else { return }
    if annotations[id] == nil {
      Task {
        do {
          let value = try await persistence.submit { try $0.codeAnnotation(id) }
          guard let value, value.fragment.file == file, contributionOrder.last == id, !contactActive else { return }
          annotations[id] = value; undo()
        } catch { self.error = error.localizedDescription }
      }
      return
    }
    guard !contactActive, let id = contributionOrder.last, let ids = history.lastContribution(for: id),
      let annotation = annotations[id], let stamp = max(clock, annotation.ink.stamp).advanced(by: author) else { return }
    var journal = annotation.ink
    for action in journal.actions where ids.contains(action.id) && action.stamp.actor == author && action.isActive {
      _ = Self.setState(&journal, id: action.id, active: false, stamp: stamp)
      enqueue(annotation.fragment, .state(actionID: action.id, creationStamp: action.stamp, isActive: false, stateStamp: stamp, journalStamp: stamp))
    }
    clock = stamp; revision &+= 1; annotations[id] = .init(fragment: annotation.fragment, ink: journal)
    history.didRemoveContribution(ids, for: id); contributionOrder.removeLast()
  }
  private func enqueue(_ fragment: NotebookCodeFragment, _ command: NotebookSpatialInkCommand) {
    let token = UUID(); pending[token] = (fragment, command)
    persistence.enqueue(owner: .spatialInk(command.expectedResult.actionID)) { [weak self] store in
      _ = try store.commitCodeInk(fragment: fragment, command: command)
      Task { @MainActor [weak self] in self?.pending[token] = nil }
      return false
    }
  }
  @discardableResult
  private static func setState(_ journal: inout SpatialInkJournal, id: UUID, active: Bool, stamp: VersionStamp) -> Bool {
    guard let old = journal.actions.first(where: { $0.id == id }) else { return false }
    let changed = SpatialInkAction(id: old.id, tool: old.tool, color: old.color, spans: old.spans,
      stamp: old.stamp, isActive: active, stateStamp: stamp)
    return journal.merge(.init(actions: [changed], stamp: max(journal.stamp, stamp)))
  }
  func flush() async -> Bool { await persistence.flush() }
}
#endif

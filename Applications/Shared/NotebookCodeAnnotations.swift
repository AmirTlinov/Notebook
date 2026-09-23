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
  @ObservationIgnored private var stopped = false
  var reviewed: NotebookCodeFragment?
  var rebinding: NotebookCodeFragment?
  private(set) var bindingInFlight = false
  @ObservationIgnored private let persistence: NotebookPersistenceQueue
  @ObservationIgnored private let author: UUID
  @ObservationIgnored private var file: NotebookFileAddress?
  @ObservationIgnored private var clock: VersionStamp
  @ObservationIgnored private var history = PencilUndoHistory()
  @ObservationIgnored private var historyStates: [UUID: NotebookCodeInkState] = [:]
  @ObservationIgnored private var pending: [UUID: (file: NotebookFileAddress, fragmentID: UUID,
    material: NotebookCodeFragment?, command: NotebookSpatialInkCommand)] = [:]
  @ObservationIgnored private var visible = [UUID]()
  @ObservationIgnored private var refreshing = false
  @ObservationIgnored private var refreshRequested = false
  @ObservationIgnored private var moreRequested = false
  @ObservationIgnored private var nextPageAfter: UUID?
  @ObservationIgnored private var revision: UInt64 = 0

  init(persistence: NotebookPersistenceQueue, author: UUID) {
    self.persistence = persistence; self.author = author; clock = .init(counter: 0, actor: author)
  }
  var acceptsNewContacts = true
  var changingFile: NotebookFileAddress?
  func stop() { stopped = true; acceptsNewContacts = false; revision &+= 1 }
  func select(_ file: NotebookFileAddress?) async {
    guard !stopped else { return }
    guard self.file != file else { await refresh(); return }
    self.file = file; ready = false; revision &+= 1; history = .init(); historyStates = [:]; fragments = []; annotations = [:]; visible = []; reviewed = nil; hasMore = false; nextPageAfter = nil; moreRequested = false
    await refresh()
  }
  func refresh(more: Bool = false) async {
    if more { moreRequested = true } else { refreshRequested = true }
    await performRefresh()
  }
  private func performRefresh() async {
    guard !stopped, let file, !refreshing, !contactActive, refreshRequested || moreRequested else { return }
    let more = !refreshRequested && moreRequested
    if more { moreRequested = false } else { refreshRequested = false }
    refreshing = true
    let revision = revision
    defer {
      refreshing = false
      if self.file != file || self.revision != revision { refreshRequested = true }
      resumeRefresh()
    }
    let after = more ? nextPageAfter : nil, wanted = visible, author = author
    let retained = more ? [] : fragments.map(\.id)
    do {
      let result = try await persistence.submit { store in
        try store.readTransaction { store in
          let fragments = try store.codeFragments(file: file, after: after)
          let ink = try wanted.compactMap { try store.codeAnnotation($0) }
          let retained = try retained.filter { id in !fragments.contains { $0.id == id } }
            .compactMap { try store.codeFragment($0) }.filter { $0.currentFile == file }
          let history = try store.codeInkHistory(file: file, actor: author)
          return (fragments, ink, history.stamp, retained, history)
        }
      }
      guard !stopped, self.file == file, self.revision == revision, !contactActive else { return }
      clock = max(clock, result.2)
      for fragment in result.0 + result.3 { clock = max(clock, fragment.location.stamp) }
      // Optimistic contacts have arbitrary UUIDs. Only the last stored row of
      // the preceding page can continue the directory without skipping notes.
      if more || nextPageAfter == nil {
        hasMore = result.0.count == 64
        nextPageAfter = result.0.last?.id ?? nextPageAfter
      }
      // Retain expanded pages during refresh; each immutable row is read once.
      if more { for fragment in result.0 where !fragments.contains(where: { $0.id == fragment.id }) { fragments.append(fragment) } }
      else { fragments = result.0 + result.3 }
      for contact in pending.values where contact.file == file {
        if let fragment = contact.material, !fragments.contains(where: { $0.id == fragment.id }) { fragments.append(fragment) }
      }
      history.restore(result.4.undo, for: .codeFile(file))
      history.restoreRedo(result.4.redo, for: .codeFile(file))
      historyStates = result.4.states
      for state in historyStates.values { clock = max(clock, state.result.stateStamp) }
      var next: [UUID: NotebookCodeAnnotation] = [:]
      for annotation in result.1 {
        clock = max(clock, annotation.ink.stamp); next[annotation.fragment.id] = annotation
      }
      // No stale database read is allowed to replace an accepted contact.
      for contact in pending.values where contact.file == file {
        guard let fragment = next[contact.fragmentID]?.fragment ?? annotations[contact.fragmentID]?.fragment ?? contact.material else { continue }
        var journal = next[fragment.id]?.ink ?? annotations[fragment.id]?.ink ?? .init(stamp: clock)
        switch contact.command {
        case .append(let action, let stamp): _ = journal.merge(.init(actions: [action], stamp: stamp))
        case .state(let id, _, _, let active, let state, _, _): _ = Self.setState(&journal, id: id, active: active, stamp: state)
        }
        next[fragment.id] = .init(fragment: fragment, ink: journal)
      }
      annotations = next; ready = true; fragments.sort { $0.id.uuidString < $1.id.uuidString }; error = nil
    } catch { if !stopped, self.file == file, self.revision == revision { self.error = error.localizedDescription } }
  }
  func show(_ ids: [UUID]) {
    guard !stopped else { return }
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
    guard !stopped, changingFile != file, acceptsNewContacts, ready, !contactActive, self.file == file, let next = clock.advanced(by: author) else { return nil }
    let hash = NotebookFileVersion.hash(Data(source.utf8))
    let fragment = fragments.first { $0.file == file && $0.canOverlayCurrentText && $0.sourceHash == hash && $0.utf16Offset == offset && $0.text == text && $0.width == width && $0.height == height && $0.fontSize == fontSize }
      ?? .init(file: file, sourceHash: hash, utf16Offset: offset, text: text, width: width, height: height, fontSize: fontSize, stamp: next)
    guard fragment.isValid else { error = "Рассмотренный фрагмент слишком велик для одной пометки."; return nil }
    return fragment
  }
  // Coalesce reads, not their intent. Reconciliation requested during an older
  // read or a live contact must run when that owner releases the surface.
  private func resumeRefresh() {
    guard !stopped, file != nil, !refreshing, !contactActive, refreshRequested || moreRequested else { return }
    Task { await performRefresh() }
  }
  func cancelContact() { contactActive = false; resumeRefresh() }
  func review(_ fragment: NotebookCodeFragment) async {
    guard !stopped, file == fragment.currentFile else { return }
    revision &+= 1
    let revision = revision
    do {
      let value = try await persistence.submit { try $0.codeAnnotation(fragment.id) }
      guard !stopped, !contactActive, file == fragment.currentFile, self.revision == revision else { return }
      if let value { annotations[fragment.id] = value }
      reviewed = fragment
    } catch { if !stopped, file == fragment.currentFile, self.revision == revision { self.error = error.localizedDescription } }
  }
  func rebind(to material: NotebookCodeFragment) async {
    guard !stopped, !contactActive, !bindingInFlight, let reviewed = rebinding else { return }
    bindingInFlight = true; defer { bindingInFlight = false }
    let author = author
    do {
      let result = try await persistence.submit(publishesChanges: true) { store in
        try store.rebindCodeFragment(reviewed.id, expected: reviewed.location, to: material, actor: author)
      }
      clock = max(clock, result.location.stamp); revision &+= 1
      rebinding = nil; error = nil
      await refresh()
    } catch {
      self.error = "Связь не изменена: " + error.localizedDescription
      // An unknown receipt must not repeat a different binding. Read back the
      // same owner; retain both the original note and the user's chosen target.
      if let current = try? await persistence.submit({ try $0.codeFragment(reviewed.id) }),
        current.location.file == material.file, current.location.sourceHash == material.sourceHash,
        current.location.utf16Offset == material.utf16Offset, current.location.text == material.text {
        rebinding = nil; self.error = nil; await refresh()
      }
    }
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
    history.recordAction(domain: .codeFile(fragment.currentFile), actionID: action.id)
    let command = NotebookSpatialInkCommand.append(action, journalStamp: stamp)
    historyStates[action.id] = .init(fragmentID: fragment.id, result: command.expectedResult)
    trimHistoryStates(in: .codeFile(fragment.currentFile))
    enqueue(file: fragment.currentFile, fragmentID: fragment.id, material: fragment, command: command)
    contactActive = false
    resumeRefresh()
  }
  func undo() { changeHistory(active: false) }
  func redo() { changeHistory(active: true) }

  private func changeHistory(active: Bool) {
    guard !stopped, ready, acceptsNewContacts, !contactActive, !bindingInFlight,
      let file, changingFile != file else { return }
    let domain = PencilUndoHistory.Domain.codeFile(file)
    let ids = active ? history.lastRedoContribution(for: domain) : history.lastContribution(for: domain)
    guard let ids, ids.count == 1, let id = ids.first, let source = historyStates[id],
      source.result.creationStamp.actor == author, source.result.isActive != active,
      !active || history.lastRedoStateStamp(for: domain) == source.result.stateStamp,
      let stamp = max(clock, source.result.stateStamp).advanced(by: author) else { return }
    let command = NotebookSpatialInkCommand.state(actionID: id, creationStamp: source.result.creationStamp,
      expectedStateStamp: source.result.stateStamp, isActive: active, stateStamp: stamp,
      journalStamp: stamp, nativeRedo: active)
    // Even a scrolled-away fragment reserves its inverse in the FIFO now;
    // loading its measurements later cannot let another contact overtake it.
    if let annotation = annotations[source.fragmentID] {
      var ink = annotation.ink
      _ = Self.setState(&ink, id: id, active: active, stamp: stamp)
      annotations[source.fragmentID] = .init(fragment: annotation.fragment, ink: ink)
    }
    historyStates[id] = .init(fragmentID: source.fragmentID, result: command.expectedResult)
    if active { history.recordAction(domain: domain, actionID: id) }
    else { history.didRemoveContribution(ids, for: domain, stateStamp: stamp) }
    trimHistoryStates(in: domain)
    clock = stamp; revision &+= 1
    enqueue(file: file, fragmentID: source.fragmentID, command: command)
  }

  private func trimHistoryStates(in domain: PencilUndoHistory.Domain) {
    var retained = Set<UUID>()
    for entry in history.entries(for: domain) + history.redoEntries(for: domain) {
      switch entry {
      case .ink(let ids), .inkRedo(let ids, _): retained.formUnion(ids)
      case .command: break
      }
    }
    historyStates = historyStates.filter { retained.contains($0.key) }
  }

  private func enqueue(file: NotebookFileAddress, fragmentID: UUID,
    material: NotebookCodeFragment? = nil, command: NotebookSpatialInkCommand) {
    let token = UUID(); pending[token] = (file, fragmentID, material, command)
    persistence.enqueue(owner: .spatialInk(command.expectedResult.actionID), onRejected: { [weak self] rejection in
      guard let self else { return }
      pending[token] = nil; revision &+= 1
      error = rejection.localizedDescription
      Task { await self.refresh() }
    }) { [weak self] store in
      let result = try material.map { try store.commitCodeInk(fragment: $0, command: command) }
        ?? store.commitSpatialInk(command)
      Task { @MainActor [weak self] in
        guard let self else { return }
        pending[token] = nil
        if result.isActive != command.expectedResult.isActive || result.stateStamp != command.expectedResult.stateStamp {
          revision &+= 1; await refresh()
        }
      }
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

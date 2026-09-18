import Foundation
import NotebookCore
import Observation

/// One local owner of visual feedback. Durable action identity stays in Core;
/// the scene reports installed material, never a network arrival or onAppear.
@MainActor @Observable
final class NotebookAgentFeedback {
  static let resultDuration: TimeInterval = 2.4
  static let pendingLifetime: TimeInterval = 30
  struct Episode: Identifiable, Equatable {
    let subject: NotebookAgentFeedbackChange.Subject
    let startedAt: Date
    let endsAt: Date
    let isAttention: Bool
    var id: String { subject.key }
  }
  private struct Pending {
    var change: NotebookAgentFeedbackChange
    let receivedAt: Date
    var remaining: Set<String>
  }
  private(set) var episodes: [String: Episode] = [:]
  private(set) var attention: [NotebookAgentFeedbackChange.Subject] = []
  private(set) var attentionID: UUID?
  @ObservationIgnored private var known: [UUID: String]?
  @ObservationIgnored private var pending: [UUID: Pending] = [:]
  @ObservationIgnored private var activeActions: [String: UUID] = [:]
  @ObservationIgnored private var expiryDeadline: Date?
  @ObservationIgnored private var expiry: Task<Void, Never>?

  var knownActions: Set<UUID>? { known.map { Set($0.keys) } }
  var trackedActions: Set<UUID> { Set(pending.keys).union(activeActions.values) }
  var pendingSubjects: [NotebookAgentFeedbackChange.Subject] { pending.values.flatMap { value in
    value.change.subjects.filter { value.remaining.contains($0.key) }
  } }

  func receive(actions: [NotebookActionReadModel], changes: [NotebookAgentFeedbackChange], now: Date = Date()) {
    defer { known = Dictionary(uniqueKeysWithValues: actions.map { ($0.id, $0.actionVersion) }); scheduleExpiry(now: now) }
    guard let known else { return } // Opening a notebook does not replay its history.
    let current = Dictionary(uniqueKeysWithValues: changes.map { ($0.actionID, $0) })
    let replacing = Set(changes.flatMap { $0.subjects.map(\.key) })
    let valid = Set(actions.filter { $0.author == .agent && $0.undo == nil }.map(\.id))
    for id in Array(pending.keys) {
      guard let change = current[id], valid.contains(id) else { pending[id] = nil; continue }
      pending[id]?.change = change
    }
    for (key, id) in activeActions {
      if let subject = current[id]?.subjects.first(where: { $0.key == key }), valid.contains(id),
        let old = episodes[key] {
        // Unrelated writes may advance the owner's stamp without changing this
        // material. Rebind the installed proof, never restart its visible time.
        let updated = Episode(subject:subject,startedAt:old.startedAt,endsAt:old.endsAt,isAttention:false)
        if old != updated { episodes[key] = updated }
      } else if !replacing.contains(key) || !valid.contains(id) {
        episodes[key] = nil; activeActions[key] = nil
      }
    }

    for change in changes where known[change.actionID] != change.version {
      guard valid.contains(change.actionID) else { continue }
      let keys = Set(change.subjects.map(\.key))
      // Newer results replace pending versions of the same material, rather
      // than building a backlog of flashes behind a slow renderer.
      for id in Array(pending.keys) { pending[id]?.remaining.subtract(keys) }
      pending[change.actionID] = .init(change: change, receivedAt: now, remaining: keys)
      attention.removeAll { keys.contains($0.key) }
      for key in keys where episodes[key]?.isAttention == true { episodes[key] = nil }
    }
    expire(now: now)
  }

  func setAttention(_ subjects: [NotebookAgentFeedbackChange.Subject], id: UUID) {
    clearAttention()
    attentionID = id; attention = subjects
  }
  func refreshAttention(_ current: [NotebookAgentFeedbackChange.Subject]) {
    let keys = Set(attention.map(\.key))
    let next = current.filter { keys.contains($0.key) }
    if attention != next { attention = next }
    for subject in next {
      guard let old = episodes[subject.key], old.isAttention else { continue }
      let updated = Episode(subject:subject,startedAt:old.startedAt,endsAt:old.endsAt,isAttention:true)
      if old != updated { episodes[subject.key] = updated }
    }
  }
  func clearAttention() {
    attention = []; attentionID = nil
    let kept = episodes.filter { !$0.value.isAttention }
    if kept != episodes { episodes = kept }
  }

  /// Offscreen subjects are consumed, not saved for a surprise replay on return.
  /// Pending onscreen content can wait; its visible duration has not started.
  func presented(ready: Set<String>, offscreen: Set<String>, now: Date = Date()) {
    for id in Array(pending.keys) {
      guard var value = pending[id] else { continue }
      for subject in value.change.subjects where value.remaining.contains(subject.key) {
        if offscreen.contains(subject.key) { value.remaining.remove(subject.key); continue }
        guard ready.contains(subject.key) else { continue }
        let old = episodes[subject.key]
        let start = old.flatMap { !$0.isAttention && $0.endsAt > now ? $0.startedAt : nil } ?? now
        episodes[subject.key] = .init(subject: subject, startedAt: start,
          endsAt: now.addingTimeInterval(Self.resultDuration), isAttention: false)
        activeActions[subject.key] = id
        value.remaining.remove(subject.key)
      }
      pending[id] = value.remaining.isEmpty ? nil : value
    }
    for subject in attention where ready.contains(subject.key) && episodes[subject.key] == nil {
      episodes[subject.key] = .init(subject: subject, startedAt: now, endsAt: .distantFuture, isAttention: true)
    }
    for key in offscreen { episodes[key] = nil; activeActions[key] = nil }
    expire(now: now); scheduleExpiry(now: now)
  }

  func expire(now: Date = Date()) {
    let kept = episodes.filter { $0.value.endsAt > now }
    if kept != episodes { episodes = kept }
    activeActions = activeActions.filter { episodes[$0.key] != nil }
    pending = pending.filter { !$0.value.remaining.isEmpty && now.timeIntervalSince($0.value.receivedAt) < Self.pendingLifetime }
  }
  func stop() {
    expiry?.cancel(); expiry = nil; expiryDeadline = nil
    pending.removeAll(); episodes.removeAll(); activeActions.removeAll(); clearAttention()
  }
  private func scheduleExpiry(now: Date) {
    let dates = episodes.values.filter { !$0.isAttention }.map(\.endsAt)
      + pending.values.map { $0.receivedAt.addingTimeInterval(Self.pendingLifetime) }
    let deadline = dates.min()
    guard deadline != expiryDeadline else { return }
    expiry?.cancel(); expiry = nil; expiryDeadline = deadline
    guard let next = deadline else { return }
    expiry = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(max(0, next.timeIntervalSince(now)))) } catch { return }
      guard let self else { return }
      expiry = nil; expiryDeadline = nil
      expire(); scheduleExpiry(now: Date())
    }
  }
}

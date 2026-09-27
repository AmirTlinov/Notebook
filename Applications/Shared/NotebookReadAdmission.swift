import Foundation
import NotebookCore

/// Local edits admitted after a read starts may not have reached SQLite yet.
/// Track only those concurrent edits, for the lifetime of the read, and validate
/// against its actual owners. Visiting a million items retains no revision map.
@MainActor
final class NotebookReadAdmission {
  private struct Changes { var targets = Set<CollaborationTarget>(); var overflow = false }
  private var reads: [UUID: Changes] = [:]
  func begin() -> UUID { let id = UUID(); reads[id] = .init(); return id }
  func end(_ id: UUID) { reads[id] = nil }
  func changed(_ target: CollaborationTarget) {
    let target = CollaborationTarget(kind: target.kind, id: target.id)
    for id in Array(reads.keys) {
      if reads[id]!.targets.contains(target) { continue }
      if reads[id]!.targets.count < 4096 { reads[id]!.targets.insert(target) }
      else { reads[id]!.overflow = true }
    }
  }
  func permits(_ id: UUID, targets: Set<CollaborationTarget>) -> Bool {
    guard let changes = reads[id], !changes.overflow else { return false }
    return changes.targets.isDisjoint(with: targets.map { CollaborationTarget(kind: $0.kind, id: $0.id) })
  }
}

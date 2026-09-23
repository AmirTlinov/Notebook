import Foundation

/// A completed contact owns only the UUIDs it added, never the whole surface.
public struct PencilUndoHistory: Sendable {
  public enum Domain: Codable, Hashable, Sendable {
    case target(kind: CollaborationTarget.Kind, id: UUID)
    case codeFile(NotebookFileAddress)

    public init(_ target: CollaborationTarget) { self = .target(kind: target.kind, id: target.id) }
    public init?(surface: SurfaceID) {
      // A code fragment is material, while its current file owns the contact
      // order. Only the store can resolve that binding; never invent a UUID.
      guard surface.kind != .codeFragment, let owner = surface.ownerID,
        let kind = CollaborationTarget.Kind(rawValue: surface.kind.rawValue) else { return nil }
      self = .target(kind: kind, id: owner)
    }
    public var key: String {
      switch self {
      case .target(let kind, let id): return kind.rawValue + ":" + id.uuidString.lowercased()
      case .codeFile(let file): return "codeFile:" + file.id
      }
    }
    public static func page(_ id: UUID) -> Self { .init(.init(kind: .page, id: id)) }
    public static func board(_ id: UUID) -> Self { .init(.init(kind: .board, id: id)) }
    public static func cover(_ id: UUID) -> Self { .init(.init(kind: .cover, id: id)) }
    public static func document(_ id: UUID) -> Self { .init(.init(kind: .document, id: id)) }
  }
  private let capacity: Int
  public enum Entry: Codable, Equatable, Sendable {
    case ink(Set<UUID>), inkRedo(Set<UUID>, VersionStamp), command(UUID)
  }
  private var contributions: [Domain: [Entry]] = [:]
  private var repetitions: [Domain: [Entry]] = [:]

  public init(capacity: Int = 32) {
    precondition(capacity > 0)
    self.capacity = capacity
  }

  public mutating func recordAction(domain: Domain, actionID: UUID) {
    record(.ink([actionID]),for:domain)
  }

  public func lastContribution(for domain: Domain) -> Set<UUID>? {
    if case .ink(let ids) = contributions[domain]?.last { return ids }; return nil
  }
  public func lastCommand(for domain: Domain) -> UUID? {
    if case .command(let id) = contributions[domain]?.last { return id }; return nil
  }
  public func lastRedoContribution(for domain: Domain) -> Set<UUID>? {
    switch repetitions[domain]?.last {
    case .ink(let ids), .inkRedo(let ids, _): return ids
    default: return nil
    }
  }
  public func lastRedoStateStamp(for domain: Domain) -> VersionStamp? {
    if case .inkRedo(_, let stamp) = repetitions[domain]?.last { return stamp }; return nil
  }
  public func lastRedoCommand(for domain: Domain) -> UUID? {
    if case .command(let id) = repetitions[domain]?.last { return id }; return nil
  }
  public mutating func recordCommand(domain: Domain, actionID: UUID) {
    record(.command(actionID),for:domain)
  }
  @discardableResult
  public mutating func recordRepeatedCommand(domain:Domain,originalID:UUID,actionID:UUID)->Bool {
    guard var redo=repetitions[domain],redo.last == .command(originalID) else { return false }
    redo.removeLast();repetitions[domain]=redo
    var history=contributions[domain,default:[]];history.append(.command(actionID))
    contributions[domain]=Array(history.suffix(capacity))
    return true
  }
  public mutating func didUndoCommand(domain: Domain, actionID: UUID) {
    undo(.command(actionID),for:domain)
  }

  public mutating func didRemoveContribution(_ ids: Set<UUID>, for domain: Domain,
    stateStamp: VersionStamp? = nil) {
    undo(.ink(ids),for:domain,redo:stateStamp.map { .inkRedo(ids,$0) })
  }

  /// A rejected optimistic command never became an inverse and cannot be redone.
  public mutating func discardCommand(domain: Domain, actionID: UUID) {
    contributions[domain]?.removeAll { $0 == .command(actionID) }
  }

  private mutating func record(_ entry: Entry,for domain: Domain) {
    var history=contributions[domain,default:[]]
    guard !history.contains(entry) else { return }
    var redo=repetitions[domain,default:[]]
    let resumesHead: Bool
    if case .ink(let ids) = entry, case .inkRedo(let redoIDs, _) = redo.last {
      resumesHead = ids == redoIDs
    } else { resumesHead = redo.last == entry }
    if resumesHead { redo.removeLast() } else { redo.removeAll() }
    history.append(entry)
    contributions[domain]=Array(history.suffix(capacity))
    repetitions[domain]=redo
  }

  private mutating func undo(_ entry: Entry,for domain: Domain,redo repeated:Entry? = nil) {
    guard var history=contributions[domain],let index=history.lastIndex(of:entry) else { return }
    history.remove(at:index);contributions[domain]=history
    guard index == history.count else { return } // An out-of-order inverse is not a Redo head.
    var redo=repetitions[domain,default:[]];redo.append(repeated ?? entry)
    repetitions[domain]=Array(redo.suffix(capacity))
  }

  /// A scene read restores only bounded identities in the writer's saved order.
  /// It carries no material, pixels or alternate inverse implementation.
  public func entries(for domain: Domain) -> [Entry] { contributions[domain] ?? [] }
  public func redoEntries(for domain: Domain) -> [Entry] { repetitions[domain] ?? [] }
  public mutating func restore(_ entries: [Entry], for domain: Domain) {
    contributions[domain] = Array(entries.suffix(capacity))
  }
  public mutating func restoreRedo(_ entries: [Entry], for domain: Domain) {
    repetitions[domain] = Array(entries.suffix(capacity))
  }

  public mutating func discardChanges(for domain: Domain) {
    contributions[domain] = nil
    repetitions[domain] = nil
  }
}

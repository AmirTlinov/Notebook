import Foundation

/// A native revision is ordered only inside the producer's current attachment.
extension CodexConversation {
  public func succeeds(_ previous: CodexConversation?) -> Bool {
    guard let previous, previous.threadID == threadID, previous.generation == generation else { return true }
    return revision >= previous.revision
  }
}

/// Native chronological windows overlap by item ID. History cannot overwrite
/// live text, and an older prefix must not become a newly appended tail.
public enum CodexTranscript {
  public static func merging(_ messages: [CodexMessage], _ incoming: [CodexMessage],
    preferIncoming: Bool, before boundary: String? = nil) -> [CodexMessage] {
    let known = Set(messages.map(\.id)), updates = Dictionary(incoming.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    var before: [String: [CodexMessage]] = [:], pending: [CodexMessage] = [], lastShared: String?, seen = Set<String>()
    for item in incoming where seen.insert(item.id).inserted {
      if known.contains(item.id) { before[item.id] = pending; pending = []; lastShared = item.id }
      else { pending.append(item) }
    }
    var result: [CodexMessage] = []
    for item in messages {
      if lastShared == nil, item.id == boundary { result += pending; pending = [] }
      result += before[item.id] ?? []
      result.append(preferIncoming ? updates[item.id] ?? item : item)
      if item.id == lastShared { result += pending; pending = [] }
    }
    return result + pending
  }
}

/// A refresh reads the already expanded window, not just its first page.
/// Presentation and scheduling remain local to each device.
public struct CodexReadWindow<Item: Identifiable & Sendable>: Sendable where Item.ID: Sendable {
  public private(set) var items: [Item] = []
  public private(set) var cursor: String?
  public private(set) var pages = 0
  private var seen = Set<String>()
  public init(cursor: String? = nil) { self.cursor = cursor; if let cursor { seen.insert(cursor) } }
  public mutating func append(_ items: [Item], next: String?) throws {
    if let next, !seen.insert(next).inserted { throw NotebookTransportError.invalidAcknowledgement }
    self.items = Self.appending(self.items, items); cursor = next; pages += 1
  }
  public func needsPage(refreshing: Bool, loadedPages: Int) -> Bool {
    cursor != nil && (items.isEmpty || (refreshing && pages < loadedPages))
  }
  public static func appending(_ existing: [Item], _ incoming: [Item]) -> [Item] {
    var known = Set(existing.map(\.id))
    return existing + incoming.filter { known.insert($0.id).inserted }
  }
}

import Foundation

public struct NotebookReadCoverage: Codable, Equatable, Sendable {
  public let complete: Bool
  public let next: String?
  public init(complete: Bool, next: String? = nil) { self.complete = complete; self.next = next }
}

public struct NotebookSearchFilters: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, CaseIterable, Sendable { case item, page, document, spatial }
  public var kinds: [Kind]?
  public var target: CollaborationTarget?
  public init(kinds: [Kind]? = nil, target: CollaborationTarget? = nil) { self.kinds = kinds; self.target = target }

  func normalized() throws -> Self {
    guard kinds == nil || (!(kinds?.isEmpty ?? true) && kinds!.count <= 4) else {
      throw CollaborationError("invalid_search", "Укажите 1–4 типа источников и точный поддерживаемый target.")
    }
    if let target {
      guard [.page, .document, .board, .cover].contains(target.kind),
        (target.kind == .cover) == (target.boardID != nil) else {
        throw CollaborationError("invalid_search", "Фильтр target требует точный физический адрес владельца.")
      }
    }
    return .init(kinds: kinds.map { Array(Set($0)).sorted { $0.rawValue < $1.rawValue } }, target: target)
  }
}

/// A stateless position, not a server-side search session or authorization.
/// Its format fixes the stable (kind,address) order. Source commits invalidate
/// it; local presence, run events and camera changes do not.
struct NotebookSearchCursor: Codable {
  var version = 1
  let workspaceID: UUID
  let changeCursor: String
  let query: String
  let filters: NotebookSearchFilters
  let kind: String
  let address: String

  func encode() throws -> String { try JSONEncoder().encode(self).base64EncodedString() }
  static func decode(_ token: String) throws -> Self {
    guard token.utf8.count <= 16_384, let data = Data(base64Encoded: token),
      let value = try? JSONDecoder().decode(Self.self, from: data), value.version == 1,
      let cursor = UInt64(value.changeCursor), String(cursor) == value.changeCursor, cursor <= UInt64(Int64.max),
      !value.address.isEmpty, value.address.utf8.count <= 4096, Kind(rawValue: value.kind) != nil else {
      throw CollaborationError("invalid_search_cursor", "Курсор поиска повреждён или не поддерживается; начните новый поиск.")
    }
    return value
  }
  private typealias Kind = NotebookSearchFilters.Kind
}

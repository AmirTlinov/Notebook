import Foundation

/// A physical address stays attached to its owner while the camera moves.
public struct CollaborationTarget: Codable, Hashable, Sendable {
  public enum Kind: String, Codable, Sendable { case workspace, board, cover, page, document }
  public let kind: Kind
  public let id: UUID
  public let boardID: UUID?

  public init(kind: Kind, id: UUID, boardID: UUID? = nil) {
    self.kind = kind
    self.id = id
    self.boardID = boardID
  }

  public var key: String { "\(kind.rawValue):\(id.uuidString.lowercased())" }
}

public struct CollaborationReference: Codable, Equatable, Sendable, Identifiable {
  public let id: UUID
  public let target: CollaborationTarget
  public let elementID: String?
  public let region: PageRect?
  public let worldOrigin: WorldPoint?
  public let pageIndex: Int?
  public let revision: String
  public let label: String

  public init(id: UUID = UUID(), target: CollaborationTarget, elementID: String? = nil,
    region: PageRect? = nil, worldOrigin: WorldPoint? = nil, pageIndex: Int? = nil,
    revision: String, label: String = "") {
    self.id = id
    self.target = target
    self.elementID = elementID
    self.region = region
    self.worldOrigin = worldOrigin
    self.pageIndex = pageIndex
    self.revision = revision
    self.label = label
  }
}

public struct CollaborationExpectation: Codable, Equatable, Sendable {
  public let target: CollaborationTarget
  public let revision: String
  public let stateRevision: String?
  public let sourceRevision: String?
  public let inkRevision: String?

  public init(target: CollaborationTarget, revision: String, stateRevision: String? = nil, sourceRevision: String? = nil, inkRevision: String? = nil) {
    self.target = target
    self.revision = revision
    self.stateRevision = stateRevision
    self.sourceRevision = sourceRevision
    self.inkRevision = inkRevision
  }
}

/// Each operation names its domain action. `values` contains only supplied fields.
public struct CollaborationOperation: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case appendInkStroke
    case insertElement, updateElement, setElementState, removeElement, reorderElements
    case insertBlock, updateBlock, setBlockState, removeBlock, reorderBlocks, setPreamble, replaceDocument
    case createNotebook, createDocument, createBoard, renameItem, moveItem, stackItems
  }
  public let kind: Kind
  public let target: CollaborationTarget
  public let id: String?
  public let values: [String: JSONValue]

  public init(kind: Kind, target: CollaborationTarget, id: String? = nil,
    values: [String: JSONValue] = [:]) {
    self.kind = kind
    self.target = target
    self.id = id
    self.values = values
  }
}

public struct CollaborationAction: Codable, Equatable, Sendable, Identifiable {
  public let id: UUID
  public let contextID: UUID?
  public let requestID: UUID?
  public var resolvedContextID: UUID { contextID ?? id }
  public let additionalOwners: [CollaborationTarget]?
  public let summary: String
  public let references: [CollaborationReference]
  public let expected: [CollaborationExpectation]
  public let operations: [CollaborationOperation]

  public init(id: UUID = UUID(), contextID: UUID? = nil, requestID: UUID? = nil, additionalOwners: [CollaborationTarget]? = nil, summary: String, references: [CollaborationReference] = [],
    expected: [CollaborationExpectation], operations: [CollaborationOperation]) {
    self.id = id
    self.contextID = contextID
    self.requestID = requestID
    self.additionalOwners = additionalOwners
    self.summary = summary
    self.references = references
    self.expected = expected
    self.operations = operations
  }
}

public struct CollaborationError: Error, Codable, Equatable, Sendable, LocalizedError {
  public let code: String
  public let message: String
  public let target: CollaborationTarget?
  public let expected: String?
  public let actual: String?
  public var errorDescription: String? { message }

  public init(_ code: String, _ message: String, target: CollaborationTarget? = nil,
    expected: String? = nil, actual: String? = nil) {
    self.code = code
    self.message = message
    self.target = target
    self.expected = expected
    self.actual = actual
  }
}

/// Stable array members are addressed by identity, so inserting a sibling keeps
/// an inverse attached to its original field rather than an old array index.
public enum CollaborationPathComponent: Codable, Equatable, Sendable {
  case field(String)
  case member(String)
  case order
}

public struct CollaborationFieldChange: Codable, Equatable, Sendable {
  public let file: String
  public let path: [CollaborationPathComponent]
  public let before: JSONValue?
  public let after: JSONValue?
  public var afterVersion: ContentFieldVersion?
}

public struct CollaborationUndoResult: Codable, Equatable, Sendable {
  public let restored: Int
  public let preserved: [CollaborationFieldChange]
  public let completedAt: Date
}

public struct CollaborationContinuation: Codable, Equatable, Sendable {
  public enum Author: String, Codable, Sendable { case human, agent, removed }
  public let file: String
  public let path: [CollaborationPathComponent]
  public let author: Author

  public var elementID: String? {
    path.reversed().compactMap { if case .member(let id) = $0 { return id }; return nil }.first
  }
}

public struct CollaborationReceipt: Codable, Equatable, Sendable, Identifiable {
  public let id: UUID
  public let action: CollaborationAction
  public let createdAt: Date
  public var revisions: [CollaborationExpectation]
  public var changes: [CollaborationFieldChange]
  public var undo: CollaborationUndoResult?

  public var summary: String { action.summary }
}

extension VersionStamp {
  public var revision: String { "\(counter)@\(actor.uuidString.lowercased())" }
}

extension JSONValue {
  var object: [String: JSONValue] { if case .object(let value) = self { value } else { [:] } }
  var array: [JSONValue] { if case .array(let value) = self { value } else { [] } }
  var string: String? { if case .string(let value) = self { value } else { nil } }
  func setting(_ key: String, _ value: JSONValue?) -> JSONValue {
    var result = object
    result[key] = value
    return .object(result)
  }

  var memberIdentity: String? {
    (self["id"]?.string ?? self["itemID"]?.string).map(collaborationIdentity)
  }

  func value(at path: ArraySlice<CollaborationPathComponent>) -> JSONValue? {
    guard let head = path.first else { return self }
    let child: JSONValue?
    switch head {
    case .field(let key): child = self[key]
    case .member(let id): child = array.first { $0.memberIdentity == collaborationIdentity(id) }
    case .order: child = .array(array.compactMap(\.memberIdentity).map(JSONValue.string))
    }
    return child?.value(at: path.dropFirst())
  }

  func setting(at path: ArraySlice<CollaborationPathComponent>, to value: JSONValue?) -> JSONValue? {
    guard let head = path.first else { return value }
    switch head {
    case .field(let key):
      return setting(key, (self[key] ?? .object([:])).setting(at: path.dropFirst(), to: value))
    case .member(let id):
      var items = array
      let index = items.firstIndex { $0.memberIdentity == collaborationIdentity(id) }
      let replacement = (index.map { items[$0] } ?? .object([:]))
        .setting(at: path.dropFirst(), to: value)
      if let index {
        if let replacement { items[index] = replacement } else { items.remove(at: index) }
      } else if let replacement { items.append(replacement) }
      return .array(items)
    case .order:
      let ids = value?.array.compactMap(\.string) ?? []
      return .array(ids.compactMap { id in array.first { $0.memberIdentity == id } }
        + array.filter { !ids.contains($0.memberIdentity ?? "") })
    }
  }
}

func collaborationIdentity(_ id: String) -> String {
  UUID(uuidString: id)?.uuidString.lowercased() ?? id
}

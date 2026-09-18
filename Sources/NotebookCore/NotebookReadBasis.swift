import Foundation

/// Content preconditions, not capabilities. The writer still checks source
/// scope, authorship and every version inside its ordinary transaction.
public struct NotebookReadBasis: Codable, Equatable, Sendable {
  public let workspaceID: UUID
  public let owners: [CollaborationExpectation]
  public init(workspaceID: UUID, owners: [CollaborationExpectation]) {
    self.workspaceID = workspaceID; self.owners = owners
  }

  public static func merging(_ bases: [Self]) throws -> Self {
    guard let workspaceID = bases.first?.workspaceID, bases.allSatisfy({ $0.workspaceID == workspaceID }) else {
      throw CollaborationError("basis_workspace_mismatch", "Основания принадлежат разным пространствам.")
    }
    var owners: [CollaborationTarget: CollaborationExpectation] = [:]
    for owner in bases.flatMap(\.owners) {
      guard owners.count < 1024 || owners[owner.target] != nil else { throw NotebookStorageError.limitExceeded("read_basis") }
      if let old = owners[owner.target] {
        func component(_ lhs: String?, _ rhs: String?) throws -> String? {
          if let lhs, let rhs, lhs.lowercased() != rhs.lowercased() {
            throw CollaborationError("basis_conflict", "Нельзя объединить разные версии одного владельца; выберите согласованное чтение.", target: owner.target, expected: lhs, actual: rhs)
          }
          return (lhs ?? rhs)?.lowercased()
        }
        owners[owner.target] = try .init(target: owner.target, revision: component(old.revision, owner.revision)!,
          stateRevision: component(old.stateRevision, owner.stateRevision), sourceRevision: component(old.sourceRevision, owner.sourceRevision),
          inkRevision: component(old.inkRevision, owner.inkRevision), lifecycleRevision: component(old.lifecycleRevision, owner.lifecycleRevision))
      } else {
        owners[owner.target] = .init(target: owner.target, revision: owner.revision.lowercased(),
          stateRevision: owner.stateRevision?.lowercased(), sourceRevision: owner.sourceRevision?.lowercased(), inkRevision: owner.inkRevision?.lowercased(), lifecycleRevision: owner.lifecycleRevision?.lowercased())
      }
    }
    return .init(workspaceID: workspaceID, owners: owners.values.sorted { ($0.target.key, $0.target.boardID?.uuidString ?? "") < ($1.target.key, $1.target.boardID?.uuidString ?? "") })
  }
}

public struct NotebookSnapshot: Codable, Sendable {
  public let data: JSONValue
  public let basis: NotebookReadBasis
  public let coverage: NotebookReadCoverage
  public let cursor: String
  public init(data: JSONValue, basis: NotebookReadBasis, coverage: NotebookReadCoverage = .init(complete: true), cursor: String) {
    self.data = data; self.basis = basis; self.coverage = coverage; self.cursor = cursor
  }
}

extension CollaborationOperation {
  var needsInkExpectation: Bool { [.appendInkStroke, .convertInkToElement].contains(kind) }
  func requiredOwners(workspaceRootID: UUID) -> [CollaborationTarget] {
    var targets = [target]
    if [.createNotebook, .createDocument, .createBoard, .renameItem].contains(kind) {
      targets.append(.init(kind: .workspace, id: workspaceRootID))
    }
    return Array(Set(targets))
  }
  var createdOwners: Set<CollaborationTarget> {
    guard let id = id.flatMap(UUID.init(uuidString:)), [.createBoard, .createNotebook, .createDocument].contains(kind) else { return [] }
    var result: Set<CollaborationTarget> = [.init(kind: .cover, id: id, boardID: target.id)]
    switch kind {
    case .createBoard: result.insert(.init(kind: .board, id: id))
    case .createDocument: result.insert(.init(kind: .document, id: id))
    case .createNotebook:
      if let page = values["pageID"]?.string.flatMap(UUID.init(uuidString:)) { result.insert(.init(kind: .page, id: page)) }
    default: break
    }
    return result
  }
}

extension NotebookStore {
  public func readBasis(targets: [CollaborationTarget], includeSource: Bool = false) throws -> NotebookReadBasis {
    try readTransaction { _ in
      let workspaceID = try workspaceHeader().workspaceID
      let owners = try Set(targets).map { target -> CollaborationExpectation in
        if target.kind == .page || target.kind == .document {
          let header = try readContentHeader(target: target)
          return .init(target: target, revision: header.contentStamp.revision, stateRevision: header.stateStamp?.revision,
            sourceRevision: try includeSource ? referenceRevision(target: target) : nil, inkRevision: header.inkStamp?.revision)
        }
        return try .init(target: target, revision: targetContentRevision(target: target),
          sourceRevision: includeSource ? referenceRevision(target: target) : nil,
          inkRevision: [.board, .cover, .codeFragment].contains(target.kind) ? inkRevision(on: target) : nil)
      }
      return try .merging([.init(workspaceID: workspaceID, owners: owners)])
    }
  }

  /// This only translates supplied versions. No current content/state/ink
  /// version is read or substituted here. Core validates them after admission.
  public func expectations(base: NotebookReadBasis, operations: [CollaborationOperation]) throws -> [CollaborationExpectation] {
    try readTransaction { _ in
      guard let workspace = try currentSQL!.rows("SELECT value FROM metadata WHERE key='workspace_id'").first?[0].text.flatMap(UUID.init(uuidString:)), workspace == base.workspaceID else {
        throw CollaborationError("basis_workspace_mismatch", "Основание принадлежит другому пространству.")
      }
      let basis = try NotebookReadBasis.merging([base])
      // The catalogue owner uses rootBoardID, not the workspace identity.
      // Read its address only; never its latest stamp to fill a missing basis.
      guard let root = try storedFragments(address: "workspace.json#", descendants: false).first?.value["rootBoardID"]?.string.flatMap(UUID.init(uuidString:)) else {
        throw NotebookStorageError.corruptRecord("workspace root identity")
      }
      var created: Set<CollaborationTarget> = []
      for (index, operation) in operations.enumerated() {
        do {
          for target in operation.requiredOwners(workspaceRootID: root) where !created.contains(target) {
            guard basis.owners.contains(where: { $0.target == target }) else { throw Self.incompleteBasis(target, component: "content") }
          }
          let owner = basis.owners.first { $0.target == operation.target }
          if operation.needsInkExpectation, !created.contains(operation.target), owner?.inkRevision == nil {
            throw Self.incompleteBasis(operation.target, component: "ink")
          }
          if operation.kind == .setBlockState, owner?.stateRevision == nil { throw Self.incompleteBasis(operation.target, component: "state") }
          created.formUnion(operation.createdOwners)
        } catch let error as CollaborationError { throw error.atOperation(index, operation) }
      }
      return basis.owners
    }
  }

  private static func incompleteBasis(_ target: CollaborationTarget, component: String) -> CollaborationError {
    let read = target.kind == .workspace ? "nb.read({kind:'workspaceHeader'})"
      : target.kind == .page ? "nb.read({kind:'pageHeader',id:'\(target.id)'})"
      : target.kind == .document ? "nb.read({kind:'documentHeader',id:'\(target.id)'})"
      : "nb.reference({target:{kind:'\(target.kind.rawValue)',id:'\(target.id)'\(target.boardID.map { ",boardID:'\($0)'" } ?? "")}})"
    return .init("basis_incomplete", "В основании отсутствует \(component) владельца. Выполните \(read) и явно выберите новое основание; версии автоматически не освежаются.", target: target)
  }
}

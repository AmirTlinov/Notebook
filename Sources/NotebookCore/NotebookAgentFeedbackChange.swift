import Foundation

/// A disposable, addressed read of still-current agent results. Not a second
/// action journal: identity and causality belong to the original receipt.
public struct NotebookAgentFeedbackChange: Sendable {
  public struct Subject: Equatable, Sendable {
    public init(reference: CollaborationReference, strokeID: UUID? = nil, expected: CollaborationExpectation) {
      self.reference = reference; self.strokeID = strokeID; self.expected = expected
    }
    public let reference: CollaborationReference
    public let strokeID: UUID?
    public let expected: CollaborationExpectation
    public var key: String {
      let area = reference.region.map { "\($0.x),\($0.y),\($0.width),\($0.height):\(String(describing:reference.worldOrigin)):\(reference.pageIndex ?? 0)" }
      return reference.target.key + ":" + (strokeID?.uuidString ?? reference.elementID ?? area ?? "surface")
    }
  }
  public init(actionID: UUID, version: String, contextID: UUID, subjects: [Subject]) {
    self.actionID = actionID; self.version = version; self.contextID = contextID; self.subjects = subjects
  }
  public let actionID: UUID
  public let version: String
  public let contextID: UUID
  public let subjects: [Subject]
}

extension NotebookStore {
  public func agentFeedbackChanges(_ actions: [NotebookActionReadModel], elementsInScene: [String: [String]] = [:]) throws -> [NotebookAgentFeedbackChange] {
    try readTransaction { _ in
      try actions.compactMap { action in
        guard action.author == .agent, action.undo == nil, !action.revisions.isEmpty else { return nil }
        let continuations = try actionContinuations(action)
        let references = try actionResultReferences(action).flatMap { reference in
          guard reference.elementID == nil, action.action.operations.contains(where: {
            [.reorderElements,.reorderBlocks].contains($0.kind) && $0.target == reference.target
          }) else { return [reference] }
          // Reordering never expands an entire owner just to paint a flash.
          // The already bounded scene supplies the only candidate material.
          let target = reference.target, ids = elementsInScene[reference.target.key] ?? []
          return try ids.compactMap { id in
            if target.kind == .cover || target.kind == .board {
              guard let element = try readSpatialElement(boardID:target.boardID ?? target.id,elementID:id),
                element.surface == (target.kind == .cover ? .cover(target.id) : .board(target.id)) else { return nil }
            }
            return try CollaborationReference(id:action.resultReferenceID(target:target,elementID:id),target:target,elementID:id,revision:referenceRevision(target:target,elementID:id))
          }
        }
        let subjects = try references.compactMap { original -> NotebookAgentFeedbackChange.Subject? in
          if let id = original.elementID {
            let owner = original.target.boardID ?? original.target.id
            if continuations.contains(where: { continuation in
              (continuation.elementID == collaborationIdentity(id) || (continuation.path.last == .order
                && action.action.operations.contains { [.reorderElements,.reorderBlocks].contains($0.kind) && $0.target == original.target })) && (
                continuation.file.contains(original.target.id.uuidString.lowercased())
                || continuation.path.contains(.member(owner.uuidString.lowercased())))
            }) { return nil }
          } else if !continuations.isEmpty { return nil }
          var reference = original
          // Creation is seen as a physical carrier on its containing board, not
          // as the unopened contents of that new document/portal.
          if action.action.operations.contains(where: {
            [.createNotebook, .createDocument, .createBoard].contains($0.kind) && $0.id?.lowercased() == original.target.id.uuidString.lowercased()
          }), let boardID = try ownerBoardID(of: original.target.id) {
            let target = CollaborationTarget(kind:.cover,id:original.target.id,boardID:boardID)
            reference = .init(id:original.id,target:target,revision:try referenceRevision(target:target),label:original.label)
          }
          // Removed content has no new material to paint. Never highlight its
          // entire owner as a substitute for the absent object.
          if action.action.operations.contains(where: {
            [.removeElement, .removeBlock, .deleteItem].contains($0.kind)
              && $0.target == reference.target && ($0.id == reference.elementID || reference.elementID == nil)
          }) { return nil }
          let owner = reference.target.kind == .cover
            ? CollaborationTarget(kind: .board, id: reference.target.boardID!) : reference.target
          guard [.board, .page, .document].contains(owner.kind) else { return nil }
          let header = try [.page, .document].contains(owner.kind) ? readContentHeader(target: owner) : nil
          let ink = action.action.operations.contains { $0.kind == .appendInkStroke && $0.target == reference.target }
          let stroke = action.action.operations.first {
            $0.kind == .appendInkStroke && $0.target == reference.target
              && action.resultReferenceID(target:$0.target,elementID:nil,strokeID:$0.strokeID) == reference.id
          }?.strokeID
          let expected = try CollaborationExpectation(target: owner, revision: targetContentRevision(target: owner),
            stateRevision: header?.stateStamp?.revision,
            inkRevision: ink ? (header?.inkStamp?.revision ?? readSpatialInk(surfaces: []).stamp.revision) : nil)
          return .init(reference: reference, strokeID: stroke, expected: expected)
        }
        var seen = Set<String>()
        let unique = subjects.filter { seen.insert($0.key).inserted }
        guard !unique.isEmpty else { return nil }
        return .init(actionID: action.id, version: action.actionVersion,
          contextID: action.action.resolvedContextID, subjects: unique)
      }
    }
  }
}

extension NotebookStore {
  public func agentAttentionSubjects(_ references: [CollaborationReference]) throws -> [NotebookAgentFeedbackChange.Subject] {
    try readTransaction { _ in
      try references.map { reference in
        guard [.board, .cover, .page, .document].contains(reference.target.kind),
          reference.target.kind != .cover || reference.target.boardID != nil,
          !reference.revision.isEmpty,
          try referenceRevision(target: reference.target, elementID: reference.elementID) == reference.revision else {
          throw CollaborationError("source_conflict", "Предмет внимания изменился.")
        }
        let owner = reference.target.kind == .cover
          ? CollaborationTarget(kind: .board, id: reference.target.boardID!) : reference.target
        let header = try [.page, .document].contains(owner.kind) ? readContentHeader(target: owner) : nil
        return try .init(reference: reference, expected: .init(target: owner,
          revision: targetContentRevision(target: owner), stateRevision: header?.stateStamp?.revision,
          inkRevision: reference.elementID == nil && owner.kind != .document
            ? (header?.inkStamp?.revision ?? readSpatialInk(surfaces:[]).stamp.revision) : nil))
      }
    }
  }
}

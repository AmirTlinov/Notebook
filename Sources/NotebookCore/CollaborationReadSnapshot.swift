import Foundation

/// Disposable history results from one durable SQL cut. The live scene is a
/// bounded rendering projection, not the source of unseen owners' identities.
public struct CollaborationReadSnapshot: Sendable {
  public let results: [UUID: [CollaborationReference]]
  public let continuations: [UUID: [CollaborationContinuation]]
  public let references: [UUID: ReferenceStatus]

  private struct Source: Hashable {
    let target: CollaborationTarget
    let elementID: String?
  }

  public init(store: NotebookStore, actions: [NotebookActionReadModel], references: [CollaborationReference]) throws {
    self = try store.readTransaction { store in
      var results: [UUID: [CollaborationReference]] = [:]
      var continuations: [UUID: [CollaborationContinuation]] = [:]
      var statuses: [UUID: ReferenceStatus] = [:]
      // Repeated receipts share an addressed read only within this transaction.
      // Nothing survives the cut or substitutes a partial scene for an owner.
      var revisions: [Source: Result<String, Error>] = [:]
      func revision(_ target: CollaborationTarget, _ elementID: String?) throws -> String {
        try Task.checkCancellation()
        let source = Source(target: target, elementID: elementID)
        if let result = revisions[source] { return try result.get() }
        let result = Result { try store.referenceRevision(target: target, elementID: elementID) }
        revisions[source] = result
        return try result.get()
      }
      func geometry(_ target: CollaborationTarget, _ elementID: String) throws -> (PageRect, WorldPoint?)? {
        if target.kind == .page,
          let element = try store.storedMember(file: pageFile(target.id), collection: "elements", id: elementID) {
          return try element["frame"].map { (try $0.decode(PageRect.self), nil) }
        }
        if target.kind == .board || target.kind == .cover, let boardID = target.boardID ?? (target.kind == .board ? target.id : nil),
          let element = try store.readSpatialElement(boardID: boardID, elementID: elementID),
          element.surface == (target.kind == .board ? .board(target.id) : .cover(target.id)) {
          return (.init(x: element.frame.x, y: element.frame.y, width: element.frame.width, height: element.frame.height), element.worldOrigin)
        }
        return nil
      }
      for action in actions {
        try Task.checkCancellation()
        guard try store.actionReadModel(action.id).actionVersion == action.actionVersion else {
          throw CollaborationError("source_conflict", "Квитанция изменилась до подготовки истории.")
        }
        results[action.id] = try action.resultReferences(ownerBoardID: store.ownerBoardID,
          elementGeometry: geometry, referenceRevision: revision)
        continuations[action.id] = try store.actionContinuations(action)
      }
      for reference in references {
        try Task.checkCancellation()
        do {
          let revision = try revision(reference.target, reference.elementID)
          let regional = reference.region != nil && reference.elementID == nil && reference.target.kind != .workspace
          statuses[reference.id] = .init(regional ? .checking : revision == reference.revision ? .current : .changed, currentRevision: revision)
        } catch let error as CollaborationError where error.code == "target_missing" {
          statuses[reference.id] = .init(.targetMissing)
        }
      }
      try Task.checkCancellation()
      return Self(results: results, continuations: continuations, references: statuses)
    }
  }

  private init(results: [UUID: [CollaborationReference]], continuations: [UUID: [CollaborationContinuation]],
    references: [UUID: ReferenceStatus]) {
    self.results = results; self.continuations = continuations; self.references = references
  }
}

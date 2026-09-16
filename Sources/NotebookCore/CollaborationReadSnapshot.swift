import Foundation

/// A disposable projection of receipts and their current sources. Preparation
/// encodes each needed owner once; rendering a history row only reads its result.
public struct CollaborationReadSnapshot: Sendable {
  public let results: [UUID: [CollaborationReference]]
  public let continuations: [UUID: [CollaborationContinuation]]
  public let references: [UUID: ReferenceStatus]

  public init(content: CollaborationContent, actions: [NotebookActionReadModel], references: [CollaborationReference]) throws {
    let targets = references.map(\.target) + actions.flatMap { $0.resultTargets(in: content) }
    let paths = content.referenceFilePaths(for: targets).union(actions.flatMap { $0.changes.map(\.file) })
    let files = try content.sourceFiles(including: paths)
    var results: [UUID: [CollaborationReference]] = [:]
    var continuations: [UUID: [CollaborationContinuation]] = [:]
    var statuses: [UUID: ReferenceStatus] = [:]
    var reader = NotebookReferenceReader(files: files)
    func revision(_ target: CollaborationTarget, _ elementID: String?) throws -> String {
      try reader.revision(target: target, elementID: elementID)
    }
    for action in actions {
      try Task.checkCancellation()
      results[action.id] = action.resultReferences(in: content, referenceRevision: revision)
      continuations[action.id] = try action.continuations(in: files)
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
    self.results = results; self.continuations = continuations; self.references = statuses
  }
}

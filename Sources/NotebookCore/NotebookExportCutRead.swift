import Foundation

extension NotebookStore {
  /// The same WAL cut admits both saved data and an explicit immutable capture.
  /// A current journal/cache is never sufficient proof of an actually shown frame.
  public func readDocumentExportCut(documentID: UUID, options: NotebookExportOptions) throws -> NotebookExportCut {
    try options.validate()
    return try readTransaction { store in
      var source: AgentPinnedSource?
      if let attention = options.attention {
        guard let captured = try store.attentionEvidence(contextID: attention.contextID, referenceID: attention.referenceID),
          captured.reference.target.kind == .document, captured.reference.target.id == documentID,
          captured.image?.presentation != nil else {
          throw CollaborationError("export_presentation_unavailable", "Выберите и отправьте готовый фрагмент на iPad/Simulator. Render из saved state не является показанным кадром.")
        }
        guard try store.referenceRevision(target: captured.reference.target, elementID: captured.reference.elementID) == captured.reference.revision else {
          throw CollaborationError("revision_conflict", "Источник выбранного кадра уже изменён. Укажите нужный момент снова.")
        }
        source = captured
      }
      let cut = try NotebookExportCut(document: store.loadDocument(documentID), state: store.loadDocumentState(documentID), presented: source)
      try options.validate(cut: cut)
      return cut
    }
  }
}

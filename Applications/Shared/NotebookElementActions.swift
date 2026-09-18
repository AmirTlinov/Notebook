import NotebookCore

extension NotebookAppModel {
  func editSelectedElement(_ reference: EditableElementReference) {
    guard selectionSession.element == reference else { return }
    switch reference {
    case .page(let owner, let id): interactiveElementFocus = .page(pageID: owner, elementID: id)
    case .spatial(let owner, let id): interactiveElementFocus = .board(boardID: owner, elementID: id)
    }
  }

  func completeElementOrder(_ reference: EditableElementReference) -> [String]? {
    switch reference {
    case .page(let owner, _): return pages[owner]?.elements.map(\.id) ?? []
    // Board/cover scene windows are bounded, not the complete paint order.
    case .spatial: return nil
    }
  }

  func arrangeElement(_ reference: EditableElementReference, front: Bool) {
    guard selectionSession.element == reference else { return }
    performElementOperation(.reorderElements, reference: reference,
      values: [:], summary: front ? "На передний план" : "На задний план", moveToFront: front)
  }
}

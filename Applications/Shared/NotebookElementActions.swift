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

  var availableLayerMoves: Set<NotebookElementLayerMove> {
    guard selectionSession.items.isEmpty, let first = selectionSession.elements.first else { return [] }
    guard let order = completeElementOrder(first) else { return Set(NotebookElementLayerMove.allCases) }
    let ids = Set(selectionSession.elements.map { reference in
      switch reference { case .page(_,let id), .spatial(_,let id): return id }
    })
    return Set(NotebookElementLayerMove.allCases.filter { $0.canApply(to:order,selected:ids) })
  }

  func arrangeSelection(_ move: NotebookElementLayerMove) {
    guard availableLayerMoves.contains(move), let first = selectionSession.elements.first else { return }
    _ = performElementOperations([.init(reference:first,kind:.reorderElements,values:[:])],
      summary:move.title,layerMove:move,readSources:selectionSession.elements)
  }
}

extension NotebookElementLayerMove {
  var title: String {
    switch self {
    case .lower: return "На слой ниже"
    case .higher: return "На слой выше"
    case .toBack: return "В самый низ"
    case .toFront: return "В самый верх"
    }
  }
}

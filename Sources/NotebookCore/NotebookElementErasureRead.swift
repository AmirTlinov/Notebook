import Foundation

extension NotebookStore {
  /// Immutable target membership indexes the same action, including inactive
  /// history. Undo changes only its header; it neither rebuilds nor scans ink.
  func indexElementErasures(_ action: SpatialInkAction, address: String, database: NotebookSQLConnection) throws {
    guard action.tool == .eraser else { return }
    for span in action.spans {
      guard let owner = span.surface.ownerID else { continue }
      for target in span.elementTargets ?? [] {
        try database.run("INSERT OR IGNORE INTO ink_element_erasures(address,kind,owner_id,element_id) VALUES(?,?,?,?)",
          [.text(address),.text(span.surface.kind.rawValue),.text(owner.uuidString.lowercased()),.text(collaborationIdentity(target.elementID))])
      }
    }
  }
  func indexPageElementErasures(_ fragment: NotebookStoredFragment, database: NotebookSQLConnection) throws {
    let owner = URL(fileURLWithPath:fragment.file).deletingPathExtension().lastPathComponent
    for target in try fragment.value["elementTargets"]?.decode([InkElementTarget].self) ?? [] {
      try database.run("INSERT OR IGNORE INTO ink_element_erasures(address,kind,owner_id,element_id) VALUES(?,'page',?,?)",
        [.text(fragment.address),.text(owner),.text(collaborationIdentity(target.elementID))])
    }
  }
  public func readElementErasures(on surface: SurfaceID, elementID: String) throws -> [InkElementErasure] {
    try readTransaction { _ in
      guard let owner = surface.ownerID else { return [] }
      let rows = try currentSQL!.rows("SELECT address FROM ink_element_erasures WHERE kind=? AND owner_id=? AND element_id=? ORDER BY address",
        [.text(surface.kind.rawValue),.text(owner.uuidString.lowercased()),.text(collaborationIdentity(elementID))])
      var result: [InkElementErasure] = []
      for row in rows {
        let address = row[0].text!
        guard let fragment = try storedFragments(address:address,descendants:false).first,
          fragment.value["isActive"] == .bool(true) else { continue }
        if surface.kind == .page {
          let action = try NotebookRecordCodec.decode(storedFragments(address:address),root:address).decode(PageInkAction.self)
          for target in action.elementTargets ?? [] where collaborationIdentity(target.elementID) == collaborationIdentity(elementID) {
            result.append(.init(target:target,samples:action.samples))
          }
          continue
        }
        let action = try readSpatialInkAction(address)
        for span in action.spans where span.surface == surface {
          for target in span.elementTargets ?? [] where collaborationIdentity(target.elementID) == collaborationIdentity(elementID) {
            result.append(.init(target:target,samples:span.samples))
          }
        }
      }
      return result
    }
  }
}

import Foundation

extension NotebookStore {
  /// Projection work is transaction-local and dependency-addressed. It never
  /// authors a repair or scans the board; causal intent stays in its records.
  func noteGraphicIndexChange(_ fragment: NotebookStoredFragment, database: NotebookSQLConnection) throws {
    guard fragment.file == "board.json", let parent = fragment.parent else { return }
    if fragment.collection == "board/elements", fragment.value["graphic"] != nil {
      try database.noteOwner(.graphic, fragment.address)
      // Capture old neighbours before immutable source addresses disappear on
      // owner removal. A previously losing intent may become visible again.
      for row in try database.rows("SELECT DISTINCT b.address FROM graphic_sources a JOIN graphic_sources b ON a.owner=b.owner AND a.stroke_id=b.stroke_id WHERE a.address=?", [.text(fragment.address)]) {
        try database.noteOwner(.graphic, row[0].text!)
      }
    } else if fragment.collection == "board/collaboration/fields" {
      let parts = fragment.member.components(separatedBy: "/")
      guard parts.count == 4, parts[0] == "elements", parts[2] == "graphic", parts[3] == "sourceInkIDs" else { return }
      try database.noteOwner(.graphic, parent + "/board/elements/@" + parts[1])
    }
  }

  func refreshGraphicIndex(database: NotebookSQLConnection) throws {
    while let address = try database.takeOwner(.graphic) {
      guard let fragment = try storedFragments(address: address, descendants: false).first,
        let graphic = try fragment.value["graphic"]?.decode(NotebookGraphic.self),
        let surface = try fragment.value["surface"]?.decode(SurfaceID.self) else { continue }
      let claimants = try graphicClaimants(on: surface, sourceInkIDs: Set(graphic.sourceInkIDs))
      let presentation = NotebookGraphicPresentation(claimants.map(\.candidate))
      let affected = claimants.isEmpty ? [fragment] : claimants.map(\.fragment)
      for affected in affected {
        try database.forgetOwner(.graphic, affected.address)
        let id = affected.value["id"]!.string!
        let shown = claimants.isEmpty ? graphic.showsGeometry : presentation.geometryIDs.contains(id)
        if shown { try indexSpatialElement(affected, database: database) }
        else { try database.run("DELETE FROM spatial_entries WHERE address=?", [.text(affected.address)]) }
      }
    }
  }
}

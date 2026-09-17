import Foundation

extension NotebookStore {
  func observationMembers(_ scope: NotebookObservationScope, layout: ObservationLayout) throws -> [String]? {
    var members: Set<String>
    if let bounds = scope.bounds {
      let rows = try spatialRows(boardID: scope.target.boardID ?? scope.target.id,
        coverID: scope.target.kind == .cover ? scope.target.id : nil, bounds: bounds.validated(), limit: 257, elementsOnly: true)
      guard rows.count <= 256 else {
        throw CollaborationError("observation_scope_full", "В геометрической области больше 256 элементов; сузьте bounds или читайте всю поверхность постранично без bounds.")
      }
      members = Set(rows.map { $0[1].text! })
    } else if let ids = scope.ids { members = Set(ids.map(layout.address)) }
    else { return nil }
    let owner = scope.target.kind.rawValue + ":" + scope.target.id.uuidString.lowercased()
    // One hop only, always from the original ids, not the growing result.
    for id in scope.ids ?? [] {
      let address = layout.address(id)
      if scope.expand.contains(.outgoing) {
        for row in try currentSQL!.rows("SELECT target_id FROM graphic_bindings WHERE address=? AND owner=?", [.text(address), .text(owner)]) {
          members.insert(layout.address(row[0].text!))
        }
      }
      if scope.expand.contains(.incoming) {
        let rows = try currentSQL!.rows("SELECT DISTINCT address FROM graphic_bindings WHERE owner=? AND target_id=? LIMIT 257", [.text(owner), .text(id)])
        members.formUnion(rows.map { $0[0].text! })
      }
      if scope.expand.contains(.neighbors), let row = try currentSQL!.rows("SELECT position,member FROM records WHERE address=?", [.text(address)]).first {
        for direction in ["<", ">"] {
          let table = scope.target.kind == .document ? "records" : "reference_element_order"
          let filter = scope.target.kind == .document ? "parent=? AND collection=?" : "owner_key=?"
          let args: [NotebookSQLValue] = scope.target.kind == .document ? [.text(layout.root), .text(layout.collection)]
            : [.text(owner + (scope.target.kind == .page ? "|elements" : ""))]
          let rows = try currentSQL!.rows("SELECT address FROM \(table) WHERE \(filter) AND (position,member)\(direction)(?,?) ORDER BY position \(direction == "<" ? "DESC" : "ASC"),member \(direction == "<" ? "DESC" : "ASC") LIMIT 1", args + [row[0], row[1]])
          members.formUnion(rows.map { $0[0].text! })
        }
      }
      guard members.count <= 256 else { throw CollaborationError("observation_scope_full", "Раскрытие связей превышает 256 адресов; сузьте ids/expand.") }
    }
    return members.sorted()
  }

  /// SQL selects logical member roots before any current body is decoded. The
  /// existing journal supplies tombstones; existing binding/claim indices add
  /// derived geometry invalidations. UNION deduplicates nested state/fields.
  func observationCandidates(_ scope: NotebookObservationScope, layout: ObservationLayout, from: UInt64?, through: UInt64,
    members: [String]?, previous: [String]?, after: String?, limit: Int) throws -> [String] {
    if from == through { return [] }
    func q(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }
    func unescape(_ expression: String) -> String { "replace(replace(\(expression),'~1','/'),'~0','~')" }
    func head(_ expression: String) -> String { "substr(\(expression),1,instr(\(expression)||'/','/')-1)" }
    let prefix = layout.prefix, owner = scope.target.kind.rawValue + ":" + scope.target.id.uuidString.lowercased()
    let memberFilter: String
    if let members {
      let allowed = Array(Set(members + (previous ?? [])))
      memberFilter = allowed.isEmpty ? "0" : "address IN (\(allowed.map(q).joined(separator: ",")))"
    } else { memberFilter = "1" }
    let source: String
    if let from {
      func changed(_ prefix: String, expression: String) -> String {
        "SELECT \(expression) AS address FROM change_records INDEXED BY sqlite_autoindex_change_records_1 WHERE sequence>\(from) AND sequence<=\(through) AND address>=\(q(prefix)) AND address<\(q(prefix + "\u{10ffff}"))"
      }
      let tail = "substr(address,\(prefix.count + 1))"
      var parts = [changed(prefix, expression: q(prefix) + "||" + head(tail))]
      let fieldsPrefix = layout.root + "/" + layout.fields + "/@" + (scope.target.kind == .document ? "blocks" : "elements") + "~1"
      let fieldTail = unescape("substr(address,\(fieldsPrefix.count + 1))")
      parts.append(changed(fieldsPrefix, expression: q(prefix) + "||" + head(fieldTail)) + " AND instr(\(fieldTail),'/')>0")
      if scope.target.kind == .document, scope.fields.contains(.state) {
        let statePrefix = stateFile(scope.target.id) + "#/records/@"
        parts.append(changed(statePrefix, expression: q(prefix) + "||" + head("substr(address,\(statePrefix.count + 1))")))
      }
      let membershipChanges = Set(members ?? []).symmetricDifference(Set(previous ?? []))
      parts += membershipChanges.map { "SELECT " + q($0) + " AS address" }
      let touched = parts.joined(separator: " UNION ")
      if scope.fields.contains(.geometry) || !scope.expand.isEmpty {
        // Old immutable fragments matter when removal of a winning ink claim
        // reveals a remaining claimant. Only changed roots enter this join.
        source = """
          WITH RECURSIVE touched(address) AS (\(touched)),
          seeds(address) AS (
            SELECT address FROM touched
            UNION SELECT s.address FROM touched t
              JOIN change_records c ON c.address=t.address AND c.sequence=(SELECT MAX(sequence) FROM change_records WHERE address=t.address AND sequence<=\(from))
              JOIN blobs b ON b.hash=c.blob_hash JOIN json_each(json_extract(CAST(b.data AS TEXT),'$.value.graphic.sourceInkIDs')) ink
              JOIN graphic_sources s ON s.owner=\(q(owner)) AND s.stroke_id=lower(ink.value)
          ), affected(address) AS (
            SELECT address FROM seeds
            UNION SELECT b.address FROM affected a JOIN graphic_bindings b
              ON b.owner=\(q(owner)) AND b.target_id=\(unescape("substr(a.address,\(prefix.count + 1))"))
            UNION SELECT b.address FROM affected a JOIN graphic_sources s ON s.address=a.address
              JOIN graphic_sources b ON b.owner=s.owner AND b.stroke_id=s.stroke_id
          ) SELECT address FROM affected
          """
      } else { source = "WITH affected(address) AS (\(touched)) SELECT address FROM affected" }
    } else if let members {
      source = members.isEmpty ? "SELECT address FROM records WHERE 0" : "SELECT column1 AS address FROM (VALUES \(members.map { "(" + q($0) + ")" }.joined(separator: ",")))"
    } else if scope.target.kind == .board || scope.target.kind == .cover {
      source = "SELECT address FROM reference_element_order WHERE owner_key=\(q(owner))"
    } else {
      source = "SELECT address FROM records WHERE parent=\(q(layout.root)) AND collection=\(q(layout.collection))"
    }
    return try currentSQL!.rows("SELECT DISTINCT address FROM (\(source)) WHERE \(memberFilter) AND address>\(q(after ?? "")) ORDER BY address LIMIT \(limit)").map { $0[0].text! }
  }
}

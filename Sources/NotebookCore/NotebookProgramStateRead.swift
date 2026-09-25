import Foundation

extension NotebookStore {
  /// Count JSON backing without constructing the recursive value. Reads one
  /// existing 1 MiB transfer window at a time in one short WAL snapshot.
  public func documentProgramStateReadBytes(documentID: UUID, blockID: String) throws -> Int {
    let address = stateFile(documentID) + "#/records/@" + fieldKey([collaborationIdentity(blockID)])
    return try readTransaction { _ in try programStateReadCost(address: address).cost }
  }

  func programStateFragments(address: String, admittedBytes: Int) throws -> [NotebookStoredFragment] {
    let measured = try programStateReadCost(address: address)
    guard measured.cost <= admittedBytes else { throw NotebookStorageError.limitExceeded("program_state_admission") }
    var result: [NotebookStoredFragment] = [], body = Data(), remaining = Int64(measured.expandedBytes)
    try visitProgramStateBlobs(address: address) { recordAddress, data, final in
      body.append(data)
      if final {
        let row = try currentSQL!.decodedStoredFragment(from: body, remainingBytes: &remaining, budget: "program_state_admission")
        guard row.address == recordAddress, row.position >= 0, row.value.isValid else { throw NotebookStorageError.corruptRecord(recordAddress) }
        result.append(row); body = Data()
      }
    }
    return result
  }

  /// Only declared physical references are metadata. Arbitrary state objects
  /// named inkBody are not dependencies. The sparse scanner never decodes the
  /// recursive state or materializes a portable body before its native credit.
  private func programStateReadCost(address: String) throws -> (cost: Int, expandedBytes: Int) {
    try sqlRead { database in
      var cost = 0, expandedBytes = 0
      try visitProgramStateRows(address: address) { _, hash, count in
        var scanner = ProgramStateJSONCost()
        let reader = ProgramStateJSONWindow(count: count) { offset, length in
          let data = try Self.programStateWindow(database, hash: hash, offset: offset, length: length)
          let before = scanner.nodes
          try scanner.scan(data)
          cost = try Self.addProgramStateCost(cost, data.count * 8 + (scanner.nodes - before) * 64)
          return data
        }
        var paths: [[String]] = []
        try reader.select(paths: [["inkBodies"]]) { data in paths = try JSONDecoder().decode([[String]].self, from: data) }
        cost = try Self.addProgramStateCost(cost, 512)
        guard !paths.isEmpty else { return }
        guard Set(paths).count == paths.count, paths.allSatisfy({ $0.count <= 512 }) else {
          throw NotebookStorageError.corruptRecord(address)
        }
        // The physical path list is sparse metadata, not a second state tree.
        // Prefixes share one selector; all unmatched strings/arrays are skipped
        // directly through the same bounded blob windows.
        let references = ProgramStateJSONWindow(count: count) { offset, length in
          try Self.programStateWindow(database, hash: hash, offset: offset, length: length)
        }
        var found = 0
        try references.select(paths: paths.map { ["value"] + $0 }, maximumCaptureBytes: 256) { data in
          let reference = try JSONDecoder().decode(ProgramStateInkReference.self, from: data)
          guard NotebookPageOrderRegister.validHash(reference.inkBody),
            try JSONValue.encode(reference) == JSONDecoder().decode(JSONValue.self, from: data) else {
            throw NotebookStorageError.corruptRecord(address)
          }
          guard let row = try database.rows("SELECT length(data),substr(data,1,74) FROM blobs WHERE hash=?", [.text(reference.inkBody)]).first,
            let count = row[0].integer, let prefix = row[1].blob else {
            throw NotebookStorageError.blobMissing(reference.inkBody)
          }
          let portable: Int
          if prefix.starts(with: Data("NIB1".utf8)) {
            guard count >= 4, count <= InkStoredBody.maximumBytes - 16 else { throw NotebookStorageError.corruptRecord(address) }
            portable = Int(count) + 16
          } else {
            // NIB2 stores the portable length in its fixed 74-byte root. No
            // graph child, measurement, or base64 string is read for pricing.
            guard count == 74 else { throw NotebookStorageError.corruptRecord(address) }
            portable = try InkStoredBody.portableByteCount(prefix)
          }
          let expanded = (portable + 2) / 3 * 4
          expandedBytes = try Self.addProgramStateCost(expandedBytes, expanded)
          cost = try Self.addProgramStateCost(cost, expanded * 8)
          found += 1
        }
        guard found == paths.count else { throw NotebookStorageError.corruptRecord(address) }
      }
      return (max(1, cost), expandedBytes)
    }
  }

  private static func programStateWindow(_ database: NotebookSQLConnection, hash: String, offset: Int64, length: Int64) throws -> Data {
    guard let data = try database.rows("SELECT substr(data,?,?) FROM blobs WHERE hash=?",
      [.integer(offset + 1), .integer(length), .text(hash)]).first?[0].blob, data.count == length else {
      throw NotebookStorageError.corruptRecord(hash)
    }
    return data
  }

  private func visitProgramStateRows(address: String, visit: (String, String, Int64) throws -> Void) throws {
    try sqlRead { database in
      var after = ""
      while true {
        let rows = try database.rows("""
          SELECT r.address,r.hash,length(b.data) FROM records r CROSS JOIN blobs b ON b.hash=r.hash
          WHERE (r.address=? OR (r.address>=? AND r.address<?)) AND r.address>?
          ORDER BY r.address LIMIT 128
          """, [.text(address), .text(address + "/"), .text(address + "0"), .text(after)])
        guard !rows.isEmpty else { return }
        for row in rows {
          guard let key = row[0].text, let hash = row[1].text, let count = row[2].integer, count > 0 else {
            throw NotebookStorageError.corruptRecord(address)
          }
          try visit(key, hash, count)
          after = key
        }
      }
    }
  }

  private func visitProgramStateBlobs(address: String, visit: (String, Data, Bool) throws -> Void) throws {
    try sqlRead { database in
      try visitProgramStateRows(address: address) { key, hash, count in
        var offset: Int64 = 0
        while offset < count {
          let requested = min(Int64(1_024 * 1_024), count - offset)
          let data = try Self.programStateWindow(database, hash: hash, offset: offset, length: requested)
          offset += requested
          try visit(key, data, offset == count)
        }
      }
    }
  }

  private static func addProgramStateCost(_ left: Int, _ right: Int) throws -> Int {
    let (sum, overflow) = left.addingReportingOverflow(right)
    guard !overflow, sum >= 0 else { throw NotebookStorageError.limitExceeded("program_state_admission") }
    return sum
  }
}

/// JSON syntax is validated by the existing decoder after admission. This
/// lexical pass only counts backing; quoted punctuation never adds fake nodes.
private struct ProgramStateJSONCost {
  var nodes = 0
  private var quoted = false, escaped = false, scalar = false
  mutating func scan(_ data: Data) throws {
    for byte in data {
      if quoted {
        if escaped { escaped = false }
        else if byte == 92 { escaped = true }
        else if byte == 34 { quoted = false }
      } else if byte == 34 { nodes += 1; quoted = true; scalar = false }
      else if byte == 91 || byte == 123 { nodes += 1; scalar = false }
      else if [UInt8(32), 9, 10, 13, 44, 58, 93, 125].contains(byte) { scalar = false }
      else if !scalar { nodes += 1; scalar = true }
      guard nodes <= Int.max / 64 else { throw NotebookStorageError.limitExceeded("program_state_admission") }
    }
  }
}

private struct ProgramStateInkReference: Codable {
  let inkBody: String
  let revision: UUID
}

/// A sparse JSON walk over one immutable blob. Only object keys and selected
/// metadata values are retained; an arbitrarily large ordinary string is not.
/// The established JSON decoder remains the validator after admission.
private final class ProgramStateJSONWindow {
  private final class Selector {
    var selected = false
    var children: [String: Selector] = [:]
    func add(_ path: ArraySlice<String>) {
      guard let key = path.first else { selected = true; return }
      let child = children[key] ?? Selector(); children[key] = child
      child.add(path.dropFirst())
    }
  }
  private let count: Int64
  private let load: (Int64, Int64) throws -> Data
  private var offset: Int64 = 0
  private var window = Data(), index = 0
  init(count: Int64, load: @escaping (Int64, Int64) throws -> Data) { self.count = count; self.load = load }

  private func peek() throws -> UInt8? {
    if index == window.count {
      guard offset < count else { return nil }
      window = try load(offset, min(1_024 * 1_024, count - offset))
      offset += Int64(window.count); index = 0
    }
    return window[index]
  }
  @discardableResult private func take() throws -> UInt8 {
    guard let byte = try peek() else { throw NotebookStorageError.corruptRecord("program state JSON") }
    index += 1; return byte
  }
  private func whitespace() throws { while let byte = try peek(), [UInt8(32), 9, 10, 13].contains(byte) { index += 1 } }
  private func expect(_ byte: UInt8) throws {
    try whitespace()
    guard try take() == byte else { throw NotebookStorageError.corruptRecord("program state JSON") }
  }

  func select(paths: [[String]], maximumCaptureBytes: Int = Int.max, visit: (Data) throws -> Void) throws {
    let selector = Selector()
    for path in paths { selector.add(path[...]) }
    try walk(selector, maximumCaptureBytes: maximumCaptureBytes, visit: visit)
    try whitespace()
    guard try peek() == nil else { throw NotebookStorageError.corruptRecord("program state JSON") }
  }
  private func walk(_ selector: Selector, maximumCaptureBytes: Int, visit: (Data) throws -> Void) throws {
    try whitespace()
    if selector.selected { try visit(value(retain: true, maximumBytes: maximumCaptureBytes)); return }
    if selector.children.isEmpty { _ = try value(retain: false); return }
    switch try peek() {
    case 123:
      try expect(123); try whitespace()
      if try peek() == 125 { try take(); return }
      while true {
        let key = try JSONDecoder().decode(String.self, from: value(retain: true))
        try expect(58)
        if let child = selector.children[key] { try walk(child, maximumCaptureBytes: maximumCaptureBytes, visit: visit) }
        else { _ = try value(retain: false) }
        try whitespace()
        if try take() == 125 { return }
        try whitespace()
      }
    case 91:
      try expect(91); try whitespace()
      if try peek() == 93 { try take(); return }
      var position = 0
      while true {
        if let child = selector.children[String(position)] { try walk(child, maximumCaptureBytes: maximumCaptureBytes, visit: visit) }
        else { _ = try value(retain: false) }
        try whitespace()
        if try take() == 93 { return }
        position += 1
      }
    default: _ = try value(retain: false)
    }
  }

  private func value(retain: Bool, maximumBytes: Int = Int.max) throws -> Data {
    try whitespace()
    var bytes = Data(), depth = 0, quoted = false, escaped = false, started = false
    while let byte = try peek() {
      if started, !quoted, depth == 0, [UInt8(32), 9, 10, 13, 44, 93, 125, 58].contains(byte) { break }
      try take(); started = true
      if retain {
        guard bytes.count < maximumBytes else { throw NotebookStorageError.corruptRecord("program state reference") }
        bytes.append(byte)
      }
      if quoted {
        if escaped { escaped = false }
        else if byte == 92 { escaped = true }
        else if byte == 34 { quoted = false; if depth == 0 { return bytes } }
      } else if byte == 34 { quoted = true }
      else if byte == 123 || byte == 91 { depth += 1 }
      else if byte == 125 || byte == 93 { depth -= 1; if depth == 0 { return bytes } }
    }
    guard started, !quoted, depth == 0 else { throw NotebookStorageError.corruptRecord("program state JSON") }
    return bytes
  }
}

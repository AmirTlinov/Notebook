import Foundation

extension NotebookStore {
  /// Count JSON backing without constructing the recursive value. Reads one
  /// existing 1 MiB transfer window at a time in one short WAL snapshot.
  public func documentProgramStateReadBytes(documentID: UUID, instanceID: String) throws -> Int {
    let address = stateFile(documentID) + "#/records/@" + fieldKey([collaborationIdentity(instanceID)])
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
        let reader = NotebookJSONBlobWindow(count: count, check: database.checkReadAllowance,
          admitCapture: database.admitJSONAllocation) { offset, length in
          let data = try Self.programStateWindow(database, hash: hash, offset: offset, length: length)
          let before = scanner.nodes
          try scanner.scan(data)
          cost = try Self.addProgramStateCost(cost, data.count * 8 + (scanner.nodes - before) * 64)
          return data
        }
        var paths: [[String]] = []
        try reader.select(paths: [["inkBodies"]]) { data in
          try database.admitJSONDecode(data)
          paths = try JSONDecoder().decode([[String]].self, from: data)
        }
        cost = try Self.addProgramStateCost(cost, 512)
        guard !paths.isEmpty else { return }
        guard Set(paths).count == paths.count, paths.allSatisfy({ $0.count <= 512 }) else {
          throw NotebookStorageError.corruptRecord(address)
        }
        // The physical path list is sparse metadata, not a second state tree.
        // Prefixes share one selector; all unmatched strings/arrays are skipped
        // directly through the same bounded blob windows.
        let references = NotebookJSONBlobWindow(count: count, check: database.checkReadAllowance,
          admitCapture: database.admitJSONAllocation) { offset, length in
          try Self.programStateWindow(database, hash: hash, offset: offset, length: length)
        }
        var found = 0
        try references.select(paths: paths.map { ["value"] + $0 }, maximumCaptureBytes: 256) { data in
          try database.admitJSONDecode(data)
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

/// One sparse lexical window for admitted program backing and history physical
/// metadata. It retains selected values and bounded keys, never the skipped
/// authored tree. Authentication and logical JSON validation remain callers'
/// separate responsibilities.
final class NotebookJSONBlobWindow {
  enum ArrayShape: Equatable { case absent, null, elements(Int) }
  /// One explicit bounded array path; child fields are selected per actual
  /// element. No wildcard can silently skip a 257th causal head or an object.
  final class ArrayMetadata {
    let path: [String]
    let elementPaths: [[String]]
    let maximumElements: Int
    let unsignedIntegerPaths: [[String]]
    fileprivate(set) var shape: ArrayShape = .absent
    init(path: [String], elementPaths: [[String]], maximumElements: Int, unsignedIntegerPaths: [[String]] = []) {
      self.path = path; self.elementPaths = elementPaths; self.maximumElements = maximumElements
      self.unsignedIntegerPaths = unsignedIntegerPaths
    }
  }
  private final class Selector {
    var selected = false
    var children: [String: Selector] = [:]
    var array: ArrayMetadata?
    var element: Selector?
    var unsignedIntegers = false
  }
  private let count: Int64
  private let load: (Int64, Int64) throws -> Data
  private let check: () throws -> Void
  private let admitCapture: (Int) throws -> Void
  private var offset: Int64 = 0, consumed = 0
  private var window = Data(), index = 0
  private let maximumDepth = 512
  init(count: Int64, check: @escaping () throws -> Void,
    admitCapture: @escaping (Int) throws -> Void,
    load: @escaping (Int64, Int64) throws -> Data) {
    self.count = count; self.check = check; self.admitCapture = admitCapture; self.load = load
  }

  private func peek() throws -> UInt8? {
    if index == window.count {
      try check()
      guard offset < count else { return nil }
      let length = min(1_024 * 1_024, count - offset)
      window = try load(offset, length)
      guard window.count == length else { throw NotebookStorageError.corruptRecord("JSON blob window") }
      offset += Int64(window.count); index = 0
    }
    return window[index]
  }
  @discardableResult private func take() throws -> UInt8 {
    guard let byte = try peek() else { throw NotebookStorageError.corruptRecord("JSON blob metadata") }
    if consumed & 4095 == 0 { try check() }
    index += 1; consumed += 1; return byte
  }
  private func whitespace() throws {
    while let byte = try peek(), byte == 32 || byte == 9 || byte == 10 || byte == 13 { try take() }
  }
  private func expect(_ byte: UInt8) throws {
    try whitespace()
    guard try take() == byte else { throw NotebookStorageError.corruptRecord("JSON blob metadata") }
  }

  func select(paths: [[String]], maximumCaptureBytes: Int = 16 * 1_024 * 1_024,
    visit: (Data) throws -> Void) throws {
    try selectMetadata(paths: paths, maximumCaptureBytes: maximumCaptureBytes,
      maximumKeyBytes: 16 * 1_024 * 1_024) { _, data in try visit(data) }
  }

  func selectMetadata(paths: [[String]], maximumCaptureBytes: Int,
    maximumKeyBytes: Int = 4_096, array: ArrayMetadata? = nil, unsignedIntegerPaths: [[String]] = [],
    visit: ([String], Data) throws -> Void) throws {
    guard paths.count <= 4_096, unsignedIntegerPaths.count <= 4_096,
      maximumCaptureBytes > 0, maximumKeyBytes > 0 else {
      throw NotebookStorageError.limitExceeded("json_blob_metadata")
    }
    array?.shape = .absent
    try admitCapture(128 + maximumDepth * MemoryLayout<UInt8>.stride)
    let selector = Selector()
    func insert(_ path: [String], into root: Selector) throws -> Selector {
      try check()
      guard path.count <= maximumDepth else { throw NotebookStorageError.limitExceeded("json_decode_depth") }
      var next = root
      for key in path {
        guard key.utf8.count <= maximumKeyBytes else { throw NotebookStorageError.limitExceeded("json_blob_key") }
        if let existing = next.children[key] { next = existing }
        else {
          try admitCapture(192 + key.utf8.count * 2)
          let child = Selector(); next.children[key] = child; next = child
        }
      }
      return next
    }
    for path in paths { let node = try insert(path, into: selector); node.selected = true }
    for path in unsignedIntegerPaths {
      let node = try insert(path, into: selector)
      guard node.selected else { throw NotebookStorageError.corruptRecord("JSON integer metadata selector") }
      node.unsignedIntegers = true
    }
    if let array {
      guard !array.path.isEmpty, array.maximumElements > 0, array.elementPaths.count <= 4_096,
        array.unsignedIntegerPaths.count <= 4_096 else {
        throw NotebookStorageError.limitExceeded("json_blob_array")
      }
      guard !paths.contains(where: { $0.starts(with: array.path) || array.path.starts(with: $0) }) else {
        throw NotebookStorageError.corruptRecord("JSON metadata array selector")
      }
      let node = try insert(array.path, into: selector)
      guard !node.selected, node.children.isEmpty else { throw NotebookStorageError.corruptRecord("JSON metadata array selector") }
      try admitCapture(192)
      let element = Selector()
      for path in array.elementPaths { let child = try insert(path, into: element); child.selected = true }
      for path in array.unsignedIntegerPaths {
        let child = try insert(path, into: element)
        guard child.selected else { throw NotebookStorageError.corruptRecord("JSON integer metadata selector") }
        child.unsignedIntegers = true
      }
      node.array = array; node.element = element
    }
    try walk(selector, path: [], depth: 0, maximumCaptureBytes: maximumCaptureBytes,
      maximumKeyBytes: maximumKeyBytes, visit: visit)
    try whitespace()
    guard try peek() == nil else { throw NotebookStorageError.corruptRecord("JSON blob metadata") }
    try check()
  }

  private func walk(_ selector: Selector, path: [String], depth: Int,
    maximumCaptureBytes: Int, maximumKeyBytes: Int,
    visit: ([String], Data) throws -> Void) throws {
    guard depth <= maximumDepth else { throw NotebookStorageError.limitExceeded("json_decode_depth") }
    try whitespace()
    if let array = selector.array, let element = selector.element {
      guard depth < maximumDepth else { throw NotebookStorageError.limitExceeded("json_decode_depth") }
      if try peek() == 110 {
        guard try value(retain: true, maximumBytes: 4, depth: depth) == Data("null".utf8) else {
          throw NotebookStorageError.corruptRecord("JSON metadata array")
        }
        array.shape = .null; return
      }
      guard try peek() == 91 else { throw NotebookStorageError.corruptRecord("JSON metadata array") }
      try expect(91); try whitespace()
      if try peek() == 93 { try take(); array.shape = .elements(0); return }
      var position = 0
      while true {
        try check()
        guard position < array.maximumElements else { throw NotebookStorageError.limitExceeded("json_blob_array") }
        try admitCapture(128 + (path.count + 1) * MemoryLayout<String>.stride)
        try walk(element, path: path + [String(position)], depth: depth + 1,
          maximumCaptureBytes: maximumCaptureBytes, maximumKeyBytes: maximumKeyBytes, visit: visit)
        position += 1
        try whitespace()
        let delimiter = try take()
        if delimiter == 93 { array.shape = .elements(position); return }
        guard delimiter == 44 else { throw NotebookStorageError.corruptRecord("JSON metadata array delimiter") }
        try whitespace()
      }
    }
    if selector.selected {
      try visit(path, value(retain: true, maximumBytes: maximumCaptureBytes, depth: depth,
        unsignedIntegers: selector.unsignedIntegers)); return
    }
    if selector.children.isEmpty { _ = try value(retain: false, depth: depth); return }
    switch try peek() {
    case 123:
      try expect(123); try whitespace()
      if try peek() == 125 { try take(); return }
      var selectedKeys: Set<String> = []
      while true {
        guard try peek() == 34 else { throw NotebookStorageError.corruptRecord("JSON blob object key") }
        let key = try JSONDecoder().decode(String.self,
          from: value(retain: true, maximumBytes: maximumKeyBytes, depth: depth))
        try expect(58)
        if let child = selector.children[key] {
          guard !selectedKeys.contains(key) else { throw NotebookStorageError.corruptRecord("duplicate JSON metadata key") }
          try admitCapture(128 + key.utf8.count * 2 + (path.count + 1) * MemoryLayout<String>.stride)
          selectedKeys.insert(key)
          try walk(child, path: path + [key], depth: depth + 1,
            maximumCaptureBytes: maximumCaptureBytes, maximumKeyBytes: maximumKeyBytes, visit: visit)
        } else { _ = try value(retain: false, depth: depth + 1) }
        try whitespace()
        let delimiter = try take()
        if delimiter == 125 { return }
        guard delimiter == 44 else { throw NotebookStorageError.corruptRecord("JSON blob object delimiter") }
        try whitespace()
      }
    case 91:
      try expect(91); try whitespace()
      if try peek() == 93 { try take(); return }
      var position = 0
      while true {
        let key = String(position)
        if let child = selector.children[key] {
          try admitCapture(128 + (path.count + 1) * MemoryLayout<String>.stride)
          try walk(child, path: path + [key], depth: depth + 1,
            maximumCaptureBytes: maximumCaptureBytes, maximumKeyBytes: maximumKeyBytes, visit: visit)
        } else { _ = try value(retain: false, depth: depth + 1) }
        try whitespace()
        let delimiter = try take()
        if delimiter == 93 { return }
        guard delimiter == 44 else { throw NotebookStorageError.corruptRecord("JSON blob array delimiter") }
        position += 1
      }
    default: _ = try value(retain: false, depth: depth)
    }
  }

  private func value(retain: Bool, maximumBytes: Int = 0, depth: Int, unsignedIntegers: Bool = false) throws -> Data {
    try whitespace()
    var bytes = Data(), paidCapacity = 0, brackets: [UInt8] = []
    var quoted = false, escaped = false, started = false
    var numberStart: Int?
    while let byte = try peek() {
      if started, !quoted, brackets.isEmpty,
        byte == 32 || byte == 9 || byte == 10 || byte == 13 || byte == 44 || byte == 93 || byte == 125 || byte == 58 { break }
      try take(); started = true
      if retain {
        guard bytes.count < maximumBytes else { throw NotebookStorageError.limitExceeded("json_blob_capture") }
        if bytes.count == paidCapacity {
          let capacity = min(maximumBytes, max(64, paidCapacity * 2))
          try admitCapture((capacity - paidCapacity) * 8 + 64)
          bytes.reserveCapacity(capacity); paidCapacity = capacity
        }
        bytes.append(byte)
      }
      if unsignedIntegers, !quoted {
        let numberByte = (48...57).contains(byte) || byte == 45 || byte == 43 || byte == 46 || byte == 101 || byte == 69
        if let start = numberStart, !numberByte {
          try validateUnsignedInteger(bytes[start..<(bytes.count - 1)]); numberStart = nil
        }
        if numberStart == nil, (48...57).contains(byte) || byte == 45 { numberStart = bytes.count - 1 }
      }
      if quoted {
        if escaped { escaped = false }
        else if byte == 92 { escaped = true }
        else if byte == 34 { quoted = false; if brackets.isEmpty { return bytes } }
      } else if byte == 34 { quoted = true }
      else if byte == 123 || byte == 91 {
        guard depth + brackets.count < maximumDepth else { throw NotebookStorageError.limitExceeded("json_decode_depth") }
        brackets.append(byte == 123 ? 125 : 93)
      } else if byte == 125 || byte == 93 {
        guard brackets.last == byte else { throw NotebookStorageError.corruptRecord("JSON blob brackets") }
        brackets.removeLast(); if brackets.isEmpty { return bytes }
      }
    }
    if let start = numberStart { try validateUnsignedInteger(bytes[start..<bytes.count]) }
    guard started, !quoted, brackets.isEmpty else { throw NotebookStorageError.corruptRecord("JSON blob metadata") }
    return bytes
  }

  /// Validate the already captured raw token, including exact decimal/exponent
  /// integral forms. Foundation's UInt64 decoder can round a high fraction.
  /// This borrows a Data range and allocates no second tree or numeric string.
  private func validateUnsignedInteger(_ token: Data.SubSequence) throws {
    var cursor = token.startIndex, significant = 0, fraction = 0, trailingZeros = 0
    func peekToken() -> UInt8? { cursor < token.endIndex ? token[cursor] : nil }
    func digits(fractional: Bool) throws -> Int {
      var count = 0
      while let byte = peekToken(), (48...57).contains(byte) {
        if count & 4095 == 0 { try check() }
        if fractional { fraction += 1 }
        if significant > 0 || byte != 48 {
          significant += 1; trailingZeros = byte == 48 ? trailingZeros + 1 : 0
        }
        cursor += 1; count += 1
      }
      return count
    }
    guard let first = peekToken(), (48...57).contains(first) else {
      throw NotebookStorageError.corruptRecord("JSON unsigned integer")
    }
    if first == 48 {
      cursor += 1
      if let next = peekToken(), (48...57).contains(next) { throw NotebookStorageError.corruptRecord("JSON unsigned integer") }
    } else { _ = try digits(fractional: false) }
    if peekToken() == 46 {
      cursor += 1
      guard try digits(fractional: true) > 0 else { throw NotebookStorageError.corruptRecord("JSON unsigned integer") }
    }
    let mantissaEnd = cursor
    var exponent = 0, negativeExponent = false
    if peekToken() == 101 || peekToken() == 69 {
      cursor += 1
      if peekToken() == 45 { negativeExponent = true; cursor += 1 }
      else if peekToken() == 43 { cursor += 1 }
      var count = 0
      let cap = token.count + 21
      while let byte = peekToken(), (48...57).contains(byte) {
        if count & 4095 == 0 { try check() }
        // A nonzero mantissa cannot fit an exponent beyond its own digits
        // and UInt64 width. Saturation also avoids parsing an unbounded Int.
        exponent = min(cap, exponent * 10 + Int(byte - 48))
        cursor += 1; count += 1
      }
      guard count > 0 else { throw NotebookStorageError.corruptRecord("JSON unsigned integer") }
    }
    guard cursor == token.endIndex else { throw NotebookStorageError.corruptRecord("JSON unsigned integer") }
    if significant == 0 { return }
    let shift = (negativeExponent ? -exponent : exponent) - fraction
    guard shift >= 0 || -shift <= trailingZeros else { throw NotebookStorageError.corruptRecord("JSON unsigned integer") }
    let width = significant + shift
    guard (1...20).contains(width) else { throw NotebookStorageError.corruptRecord("JSON unsigned integer") }
    let retained = min(significant, width)
    var integer: UInt64 = 0, taken = 0, began = false
    for index in token.startIndex..<mantissaEnd {
      if (index - token.startIndex) & 4095 == 0 { try check() }
      let byte = token[index]
      guard (48...57).contains(byte) else { continue }
      if !began, byte == 48 { continue }
      began = true
      if taken == retained { break }
      let product = integer.multipliedReportingOverflow(by: 10)
      let sum = product.partialValue.addingReportingOverflow(UInt64(byte - 48))
      guard !product.overflow, !sum.overflow else { throw NotebookStorageError.corruptRecord("JSON unsigned integer") }
      integer = sum.partialValue; taken += 1
    }
    for _ in 0..<max(0, shift) {
      let product = integer.multipliedReportingOverflow(by: 10)
      guard !product.overflow else { throw NotebookStorageError.corruptRecord("JSON unsigned integer") }
      integer = product.partialValue
    }
  }
}

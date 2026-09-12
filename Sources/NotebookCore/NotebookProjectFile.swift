import Foundation
import CryptoKit

/// A file belongs to a particular computer and a current Codex project root.
/// Neither a matching absolute path nor a board item is its identity.
public struct NotebookFileAddress: Codable, Hashable, Sendable, Identifiable {
  public let computer: UUID
  public let project: String
  public let root: String
  public let path: String
  public var id: String { NotebookFileVersion.hash(try! JSONEncoder.sorted.encode(self)) }
  public init(computer: UUID, project: String, root: String, path: String) {
    self.computer = computer; self.project = project; self.root = root; self.path = path
  }
  public func child(_ name: String) -> Self { .init(computer: computer, project: project, root: root, path: path.isEmpty ? name : path + "/" + name) }
  public var isValid: Bool {
    !project.isEmpty && project.utf8.count <= 256 && root.hasPrefix("/") && root.utf8.count <= 4096
      && !root.contains("\0") && URL(fileURLWithPath: root).standardizedFileURL.path == root
      && path.utf8.count <= 4096 && !path.contains("\0") && !path.hasPrefix("/")
      && (path.isEmpty || path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." })
  }
}

private extension JSONEncoder {
  static var sorted: JSONEncoder { let value = JSONEncoder(); value.outputFormatting = .sortedKeys; return value }
}

public struct NotebookFileEntry: Codable, Equatable, Sendable, Identifiable {
  public enum Kind: String, Codable, Sendable { case directory, file, symbolicLink, unsupported }
  public let name: String
  public let kind: Kind
  public var id: String { name }
  public init(name: String, kind: Kind) { self.name = name; self.kind = kind }
}
public struct NotebookFileDirectory: Codable, Equatable, Sendable {
  public let entries: [NotebookFileEntry]
  public let next: String?
  public init(entries: [NotebookFileEntry], next: String?) { self.entries = entries; self.next = next }
}
public struct NotebookFileVersion: Codable, Equatable, Sendable {
  public static let maximumBytes = 2 * 1024 * 1024
  public static let chunkBytes = 48 * 1024
  public let hash: String
  public let size: Int
  public init(_ data: Data) { hash = Self.hash(data); size = data.count }
  public static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
  public var isValid: Bool { size >= 0 && size <= Self.maximumBytes && hash.count == 64 && hash.allSatisfy { $0.isHexDigit && !$0.isUppercase } }
}
public struct NotebookFilePart: Codable, Equatable, Sendable {
  public let version: NotebookFileVersion
  public let offset: Int
  public let data: Data
  public init(version: NotebookFileVersion, offset: Int, data: Data) { self.version = version; self.offset = offset; self.data = data }
}
public struct NotebookFileEdit: Codable, Equatable, Sendable {
  public let address: NotebookFileAddress
  public let base: String
  public let text: String
  public init(address: NotebookFileAddress, base: String, text: String) { self.address = address; self.base = base; self.text = text }
  // Encode UTF-8 bytes, not escaped source characters: two accepted 2 MiB
  // versions must fit the same 6 MiB transfer even when every character is a tab.
  private enum CodingKeys: String, CodingKey { case address, base, text }
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    address = try values.decode(NotebookFileAddress.self, forKey: .address)
    guard let base = String(data: try values.decode(Data.self, forKey: .base), encoding: .utf8),
      let text = String(data: try values.decode(Data.self, forKey: .text), encoding: .utf8) else {
      throw DecodingError.dataCorruptedError(forKey: .text, in: values, debugDescription: "File is not UTF-8")
    }
    self.base = base; self.text = text
  }
  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(address, forKey: .address)
    try values.encode(Data(base.utf8), forKey: .base); try values.encode(Data(text.utf8), forKey: .text)
  }
  public var isValid: Bool { address.isValid && !address.path.isEmpty && base.utf8.count <= NotebookFileVersion.maximumBytes && text.utf8.count <= NotebookFileVersion.maximumBytes && !base.contains("\0") && !text.contains("\0") }
}
public struct NotebookFileUpload: Codable, Equatable, Sendable {
  public let id: UUID
  public let digest: String
  public let total: Int
  public let offset: Int
  public let data: Data
  public init(id: UUID, digest: String, total: Int, offset: Int, data: Data) { self.id = id; self.digest = digest; self.total = total; self.offset = offset; self.data = data }
  public var isValid: Bool { digest.count == 64 && total > 0 && total <= 6 * 1024 * 1024 && offset >= 0 && data.count <= NotebookFileVersion.chunkBytes && offset <= total - data.count }
}
public enum NotebookFileQuery: Codable, Equatable, Sendable {
  case directory(NotebookFileAddress, after: String?)
  case read(NotebookFileAddress, version: NotebookFileVersion?, offset: Int)
  case upload(NotebookFileUpload)
  public var address: NotebookFileAddress? { switch self { case .directory(let a, _), .read(let a, _, _): a; case .upload: nil } }
  public var isValid: Bool {
    switch self {
    case .directory(let a, let after): a.isValid && (after?.utf8.count ?? 0) <= 4096
    case .read(let a, let version, let offset): a.isValid && !a.path.isEmpty && offset >= 0 && (version.map { $0.isValid && offset <= $0.size } ?? (offset == 0))
    case .upload(let chunk): chunk.isValid
    }
  }
}
public enum NotebookFileReply: Codable, Equatable, Sendable {
  case directory(NotebookFileDirectory), part(NotebookFilePart), uploaded(Int)
}
public struct NotebookFileResult: Codable, Equatable, Sendable {
  public enum Status: String, Codable, Sendable { case saved, conflict }
  public let address: NotebookFileAddress
  public let status: Status
  /// Exact accepted version, or the other version retained during a conflict.
  public let version: NotebookFileVersion
  public init(address: NotebookFileAddress, status: Status, version: NotebookFileVersion) { self.address = address; self.status = status; self.version = version }
}

/// This device's reading position and unsent work are independent of SessionPresence.
public struct NotebookFileDraft: Codable, Equatable, Sendable {
  public let address: NotebookFileAddress
  public var base: String
  public var text: String
  public var other: String?
  public var selection: Int = 0
  public var scroll: Double = 0
  public var pending: UUID?
  public var submitted: String?
  public init(address: NotebookFileAddress, text: String) { self.address = address; base = text; self.text = text }
  public var isValid: Bool {
    address.isValid && [base, text, other ?? "", submitted ?? ""].allSatisfy { $0.utf8.count <= NotebookFileVersion.maximumBytes }
      && selection >= 0 && selection <= text.utf16.count && scroll.isFinite && scroll >= 0
      && ((pending == nil) == (submitted == nil))
  }
  public mutating func receive(_ remote: String, submitted sent: String? = nil) {
    let ancestor = sent ?? base
    if let merged = NotebookFileMerge.combine(base: ancestor, local: text, remote: remote) {
      text = merged; base = remote; other = nil
    } else { other = remote }
    selection = min(selection, text.utf16.count)
  }
}
public struct NotebookFileWindowState: Codable, Equatable, Sendable {
  public var selected: NotebookFileAddress?
  public var isOpen = false
  public var sidebar = false
  public var terminal: Bool?
  public var runRoot: String?
  public var project: CodexProject?
  public init() { }
}

/// Line edits merge only when their ranges are disjoint. Large unanchored rewrites
/// are deliberately a conflict, not unbounded quadratic work or a guessed merge.
public enum NotebookFileMerge {
  private struct Edit { let range: Range<Int>; let lines: [String] }
  public static func combine(base: String, local: String, remote: String) -> String? {
    if local == base || local == remote { return remote }
    if remote == base { return local }
    let b = base.components(separatedBy: "\n"), l = local.components(separatedBy: "\n"), r = remote.components(separatedBy: "\n")
    guard let left = edits(b, l), let right = edits(b, r) else { return nil }
    var all = left
    for edit in right {
      var identical = false
      for other in left {
        if edit.range == other.range && edit.lines == other.lines { identical = true; break }
        // Insertions at a changed boundary are ambiguous: do not choose an order.
        if edit.range.isEmpty || other.range.isEmpty {
          if edit.range.lowerBound <= other.range.upperBound && other.range.lowerBound <= edit.range.upperBound { return nil }
        } else if edit.range.overlaps(other.range) { return nil }
      }
      if !identical { all.append(edit) }
    }
    var output = b
    for edit in all.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) { output.replaceSubrange(edit.range, with: edit.lines) }
    return output.joined(separator: "\n")
  }
  private static func edits(_ base: [String], _ value: [String]) -> [Edit]? {
    var prefix = 0
    while prefix < min(base.count, value.count), base[prefix] == value[prefix] { prefix += 1 }
    var end = base.count, valueEnd = value.count
    while end > prefix, valueEnd > prefix, base[end - 1] == value[valueEnd - 1] { end -= 1; valueEnd -= 1 }
    let a = Array(base[prefix..<end]), b = Array(value[prefix..<valueEnd])
    // A single insertion/deletion is linear even for an entire large file.
    if a.isEmpty || b.isEmpty { return [.init(range: prefix..<end, lines: b)] }
    guard a.count * b.count <= 4_000_000 else { return nil }
    let difference = b.difference(from: a)
    let removed = Set(difference.removals.map { change in if case .remove(let n, _, _) = change { return n }; return -1 })
    let inserted = Set(difference.insertions.map { change in if case .insert(let n, _, _) = change { return n }; return -1 })
    var i = 0, j = 0, result: [Edit] = []
    while i < a.count || j < b.count {
      if removed.contains(i) || inserted.contains(j) {
        let start = i, first = j
        while removed.contains(i) { i += 1 }
        while inserted.contains(j) { j += 1 }
        result.append(.init(range: (prefix + start)..<(prefix + i), lines: Array(b[first..<j])))
      } else { i += 1; j += 1 }
    }
    return result
  }
}

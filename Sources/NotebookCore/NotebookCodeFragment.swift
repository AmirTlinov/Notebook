import Foundation

/// The material and text layout actually under Pencil, not a live line number.
/// Ink uses this fragment's coordinates; a changed layout can show the original
/// material beside its marker instead of stretching handwriting over other code.
public struct NotebookCodeFragment: Codable, Equatable, Sendable, Identifiable {
  public let id: UUID
  public let file: NotebookFileAddress
  public let sourceHash: String
  public let utf16Offset: Int
  public let text: String
  public let width: Double
  public let height: Double
  public let fontSize: Double
  public let stamp: VersionStamp
  public private(set) var binding: NotebookCodeLocation?

  public init(id: UUID = UUID(), file: NotebookFileAddress, sourceHash: String, utf16Offset: Int,
    text: String, width: Double, height: Double, fontSize: Double, stamp: VersionStamp) {
    self.id = id; self.file = file; self.sourceHash = sourceHash; self.utf16Offset = utf16Offset
    self.text = text; self.width = width; self.height = height; self.fontSize = fontSize; self.stamp = stamp
  }
  public var isValid: Bool {
    file.isValid && !file.path.isEmpty && sourceHash.count == 64 && sourceHash.allSatisfy { "0123456789abcdef".contains($0) }
      && utf16Offset >= 0 && utf16Offset <= NotebookFileVersion.maximumBytes
      && !text.isEmpty && text.utf8.count <= 65_536 && !text.contains("\0")
      && width.isFinite && (1...4096).contains(width) && height.isFinite && (1...8192).contains(height)
      && fontSize.isFinite && (8...72).contains(fontSize) && stamp.counter <= VersionStamp.maximumCounter
      && (binding.map { $0.isValid && $0.stamp > stamp } ?? true)
  }
  public var region: PageRect { .init(x: 0, y: 0, width: width, height: height) }
  /// The original material never changes. A binding only changes where its
  /// marker is found; handwriting can overlay only the same literal excerpt.
  public var location: NotebookCodeLocation { binding ?? .init(file: file, sourceHash: sourceHash,
    utf16Offset: utf16Offset, text: text, stamp: stamp) }
  public var currentFile: NotebookFileAddress { location.file }
  public var canOverlayCurrentText: Bool { location.text == text }
  public func rebinding(to location: NotebookCodeLocation) throws -> Self {
    guard location.isValid, location.stamp > self.location.stamp else { throw NotebookStorageError.transactionConflict }
    var result = self; result.binding = location; return result
  }
  public func merging(_ other: Self) throws -> Self {
    var a = self, b = other; a.binding = nil; b.binding = nil
    guard isValid, other.isValid, a == b,
      location.stamp != other.location.stamp || location == other.location else { throw NotebookStorageError.transactionConflict }
    return location.stamp < other.location.stamp ? other : self
  }
  public func range(in source: String, sourceHash currentHash: String? = nil) -> NSRange? {
    location.range(in: source, sourceHash: currentHash)
  }
}

/// A causally versioned destination within the same immutable review owner.
/// It is not a replacement for the original text or a second ink surface.
public struct NotebookCodeLocation: Codable, Equatable, Sendable {
  public let file: NotebookFileAddress
  public let sourceHash: String
  public let utf16Offset: Int
  public let text: String
  public let stamp: VersionStamp
  public init(file: NotebookFileAddress, sourceHash: String, utf16Offset: Int, text: String, stamp: VersionStamp) {
    self.file = file; self.sourceHash = sourceHash; self.utf16Offset = utf16Offset; self.text = text; self.stamp = stamp
  }
  public var isValid: Bool {
    file.isValid && !file.path.isEmpty && sourceHash.count == 64 && sourceHash.allSatisfy { "0123456789abcdef".contains($0) }
      && utf16Offset >= 0 && utf16Offset <= NotebookFileVersion.maximumBytes
      && !text.isEmpty && text.utf8.count <= 65_536 && !text.contains("\0") && stamp.counter <= VersionStamp.maximumCounter
  }
  /// Exact version preserves even repeated code. After edits, only a unique
  /// unchanged excerpt is a reliable destination; ambiguity retains old material.
  public func range(in source: String, sourceHash currentHash: String? = nil) -> NSRange? {
    let current = source as NSString, length = text.utf16.count
    if (currentHash ?? NotebookFileVersion.hash(Data(source.utf8))) == sourceHash {
      let range = NSRange(location: utf16Offset, length: length)
      return NSMaxRange(range) <= current.length && current.substring(with: range) == text ? range : nil
    }
    let first = current.range(of: text, options: .literal)
    guard first.location != NSNotFound else { return nil }
    let remaining = NSRange(location: first.location + 1, length: current.length - first.location - 1)
    guard current.range(of: text, options: .literal, range: remaining).location == NSNotFound else { return nil }
    return first
  }
}

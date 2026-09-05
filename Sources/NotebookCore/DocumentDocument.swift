import Foundation

public enum DocumentBlockKind: String, Codable, Equatable, Sendable {
  case markdown
  case latex
  case interactive
}

public enum DocumentPaperSize: String, Codable, CaseIterable, Equatable,
  Sendable
{
  case a4
  case letter

  /// Physical dimensions in PostScript points. The live WebKit page and the
  /// exported PDF both derive their aspect ratio from this single contract.
  public var widthPoints: Double {
    switch self {
    case .a4: 595.275590551
    case .letter: 612
    }
  }

  public var heightPoints: Double {
    switch self {
    case .a4: 841.88976378
    case .letter: 792
    }
  }

  public var marginPoints: Double {
    switch self {
    case .a4: 70.8661417323 // 25 mm
    case .letter: 72 // 1 inch
    }
  }
}

public struct DocumentBlock: Codable, Equatable, Identifiable, Sendable {
  public static let maximumSourceLength = 1_000_000
  public static let minimumInteractiveHeight = 48.0
  public static let maximumInteractiveHeight = 2_048.0

  public let id: String
  public let kind: DocumentBlockKind
  public private(set) var source: String
  public private(set) var html: String
  public private(set) var css: String
  public private(set) var javaScript: String
  public private(set) var initialState: JSONValue
  public private(set) var height: Double

  public init(
    id: String,
    kind: DocumentBlockKind,
    source: String,
    html: String = "",
    css: String = "",
    javaScript: String = "",
    initialState: JSONValue = .object([:]),
    height: Double = 320
  ) {
    precondition(!id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    self.id = id
    self.kind = kind
    self.source = source
    self.html = html
    self.css = css
    self.javaScript = javaScript
    self.initialState = initialState
    self.height = height
    precondition(isValid)
  }

  public static func markdown(id: String, source: String) -> Self {
    Self(id: id, kind: .markdown, source: source)
  }

  public static func latex(id: String, source: String) -> Self {
    Self(id: id, kind: .latex, source: source)
  }

  public static func interactive(
    id: String,
    html: String,
    css: String = "",
    javaScript: String = "",
    initialState: JSONValue = .object([:]),
    height: Double = 320
  ) -> Self {
    Self(
      id: id,
      kind: .interactive,
      source: html,
      html: html,
      css: css,
      javaScript: javaScript,
      initialState: initialState,
      height: height
    )
  }

  public func replacingSource(_ source: String) -> Self {
    switch kind {
    case .markdown, .latex:
      Self(id: id, kind: kind, source: source)
    case .interactive:
      Self(
        id: id,
        kind: kind,
        source: source,
        html: source,
        css: css,
        javaScript: javaScript,
        initialState: initialState,
        height: height
      )
    }
  }

  var isValid: Bool {
    guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      id.utf16.count <= 120,
      [source, html, css, javaScript].allSatisfy({
        $0.utf16.count <= Self.maximumSourceLength
      }),
      initialState.isValid,
      height.isFinite
    else { return false }

    switch kind {
    case .markdown, .latex:
      return html.isEmpty && css.isEmpty && javaScript.isEmpty
        && initialState == .object([:])
    case .interactive:
      return source == html
        && height >= Self.minimumInteractiveHeight
        && height <= Self.maximumInteractiveHeight
    }
  }
}

public struct DocumentDocument: Codable, Equatable, Identifiable, Sendable {
  public static let formatVersion = 2
  public static let maximumBlockCount = 512
  public static let maximumPreambleLength = 200_000

  public let format: Int
  public let id: UUID
  public let paperSize: DocumentPaperSize
  public private(set) var preamble: String
  public private(set) var blocks: [DocumentBlock]
  public private(set) var contentStamp: VersionStamp
  public private(set) var collaboration: CollaborativeContent?

  public init(
    id: UUID = UUID(),
    actor: UUID,
    paperSize: DocumentPaperSize = .a4,
    preamble: String = "",
    blocks: [DocumentBlock] = [
      .markdown(id: "body", source: "")
    ]
  ) {
    format = Self.formatVersion
    self.id = id
    self.paperSize = paperSize
    self.preamble = preamble
    self.blocks = blocks
    contentStamp = VersionStamp(counter: 0, actor: actor)
    collaboration = nil
    precondition(isValid)
  }

  var isValid: Bool {
    guard format == Self.formatVersion,
      collaboration?.isValid ?? true,
      preamble.utf16.count <= Self.maximumPreambleLength,
      blocks.count <= Self.maximumBlockCount,
      contentStamp.counter <= VersionStamp.maximumCounter
    else { return false }
    let ids = blocks.map(\.id)
    return Set(ids).count == ids.count && blocks.allSatisfy(\.isValid)
  }

  @discardableResult
  public mutating func replaceContent(
    preamble: String? = nil,
    blocks: [DocumentBlock]? = nil,
    actor: UUID
  ) -> Bool {
    guard let nextStamp = contentStamp.advanced(by: actor) else { return false }
    var candidate = self
    if let preamble { candidate.preamble = preamble }
    if let blocks { candidate.blocks = blocks }
    guard candidate.preamble != self.preamble || candidate.blocks != self.blocks
    else { return false }
    candidate.contentStamp = nextStamp
    candidate.recordContentChange(from: self, stamp: nextStamp)
    guard candidate.isValid else { return false }
    self = candidate
    return true
  }

  @discardableResult
  public mutating func replaceContent(
    preamble: String,
    blocks: [DocumentBlock],
    stamp: VersionStamp
  ) -> Bool {
    guard contentStamp < stamp,
      stamp.counter <= VersionStamp.maximumCounter
    else { return false }
    var candidate = self
    candidate.preamble = preamble
    candidate.blocks = blocks
    candidate.contentStamp = stamp
    candidate.recordContentChange(from: self, stamp: stamp)
    guard candidate.isValid else { return false }
    self = candidate
    return true
  }

  @discardableResult
  public mutating func replaceBlockSource(
    id blockID: String,
    source: String,
    actor: UUID
  ) -> Bool {
    guard source.utf16.count <= DocumentBlock.maximumSourceLength,
      let index = blocks.firstIndex(where: { $0.id == blockID })
    else {
      return false
    }
    var next = blocks
    next[index] = next[index].replacingSource(source)
    return replaceContent(blocks: next, actor: actor)
  }

  private mutating func recordContentChange(from before: Self, stamp: VersionStamp) {
    var metadata = before.collaboration ?? CollaborativeContent()
    if let previous = try? JSONValue.encode(before), let next = try? JSONValue.encode(self) {
      metadata.record(before: previous, after: next, beforeStamp: before.contentStamp, stamp: stamp, human: true)
      collaboration = metadata
    }
  }

  public mutating func merge(_ other: Self) -> Bool {
    guard id == other.id, paperSize == other.paperSize, other.isValid,
      let local = try? JSONValue.encode(self), let incoming = try? JSONValue.encode(other) else { return false }
    let merged = CollaborativeContent.merge(local: local, incoming: incoming,
      localState: collaboration, incomingState: other.collaboration,
      localStamp: contentStamp, incomingStamp: other.contentStamp)
    guard var candidate = try? merged.value.decode(Self.self), candidate.isValid else { return false }
    candidate.collaboration = merged.state
    candidate.contentStamp = mergedContentStamp(local: local, incoming: incoming, result: merged.value,
      localStamp: contentStamp, incomingStamp: other.contentStamp)
    guard candidate != self else { return false }
    self = candidate
    return true
  }

  private enum CodingKeys: String, CodingKey {
    case format
    case id
    case paperSize
    case preamble
    case blocks
    case contentStamp
    case collaboration
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let decodedFormat = try container.decode(Int.self, forKey: .format)
    guard decodedFormat == 1 || decodedFormat == Self.formatVersion else {
      throw DecodingError.dataCorruptedError(
        forKey: .format,
        in: container,
        debugDescription: "Unsupported document format \(decodedFormat)"
      )
    }
    format = Self.formatVersion
    id = try container.decode(UUID.self, forKey: .id)
    paperSize = decodedFormat == 1
      ? .a4
      : try container.decode(DocumentPaperSize.self, forKey: .paperSize)
    preamble = try container.decode(String.self, forKey: .preamble)
    blocks = try container.decode([DocumentBlock].self, forKey: .blocks)
    contentStamp = try container.decode(
      VersionStamp.self,
      forKey: .contentStamp
    )
    collaboration = try container.decodeIfPresent(CollaborativeContent.self, forKey: .collaboration)
    guard isValid else {
      throw DecodingError.dataCorruptedError(
        forKey: .blocks,
        in: container,
        debugDescription: "Document violates its content contract"
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(format, forKey: .format)
    try container.encode(id, forKey: .id)
    try container.encode(paperSize, forKey: .paperSize)
    try container.encode(preamble, forKey: .preamble)
    try container.encode(blocks, forKey: .blocks)
    try container.encode(contentStamp, forKey: .contentStamp)
    try container.encodeIfPresent(collaboration, forKey: .collaboration)
  }
}

public struct DocumentStateRecord: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public private(set) var value: JSONValue
  public private(set) var stamp: VersionStamp

  public init(id: String, value: JSONValue, stamp: VersionStamp) {
    precondition(!id.isEmpty && value.isValid)
    self.id = id
    self.value = value
    self.stamp = stamp
  }

  mutating func replace(_ value: JSONValue, stamp: VersionStamp) -> Bool {
    guard self.stamp < stamp, value.isValid else { return false }
    self.value = value
    self.stamp = stamp
    return true
  }
}

public struct DocumentStateJournal: Codable, Equatable, Identifiable, Sendable {
  public static let formatVersion = 1

  public let format: Int
  public let id: UUID
  public private(set) var records: [DocumentStateRecord]
  public private(set) var stamp: VersionStamp

  public init(
    id: UUID,
    actor: UUID,
    records: [DocumentStateRecord] = []
  ) {
    format = Self.formatVersion
    self.id = id
    self.records = records
    stamp = VersionStamp(counter: 0, actor: actor)
    precondition(isValid)
  }

  public func value(for blockID: String) -> JSONValue? {
    records.first { $0.id == blockID }?.value
  }

  var isValid: Bool {
    let ids = records.map(\.id)
    return format == Self.formatVersion
      && Set(ids).count == ids.count
      && records.allSatisfy {
        !$0.id.isEmpty && $0.id.utf16.count <= 120 && $0.value.isValid
          && $0.stamp.counter <= VersionStamp.maximumCounter
          && $0.stamp <= stamp
      }
      && stamp.counter <= VersionStamp.maximumCounter
  }

  @discardableResult
  public mutating func commit(
    blockID: String,
    value: JSONValue,
    actor: UUID
  ) -> Bool {
    guard !blockID.isEmpty,
      blockID.utf16.count <= 120,
      value.isValid,
      let nextStamp = stamp.advanced(by: actor)
    else { return false }
    if let index = records.firstIndex(where: { $0.id == blockID }) {
      guard records[index].value != value else { return false }
      _ = records[index].replace(value, stamp: nextStamp)
    } else {
      records.append(
        DocumentStateRecord(id: blockID, value: value, stamp: nextStamp)
      )
    }
    stamp = nextStamp
    return true
  }

  public mutating func merge(_ other: Self) -> Bool {
    guard id == other.id, other.isValid else { return false }
    var changed = false
    for incoming in other.records {
      if let index = records.firstIndex(where: { $0.id == incoming.id }) {
        changed = records[index].replace(
          incoming.value,
          stamp: incoming.stamp
        ) || changed
      } else {
        records.append(incoming)
        changed = true
      }
    }
    if stamp < other.stamp {
      stamp = other.stamp
      changed = true
    }
    return changed
  }
}

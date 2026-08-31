import Foundation

public enum DocumentBlockKind: String, Codable, Equatable, Sendable {
  case markdown
  case latex
  case interactive
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
  public static let formatVersion = 1
  public static let maximumBlockCount = 512
  public static let maximumPreambleLength = 200_000

  public let format: Int
  public let id: UUID
  public private(set) var preamble: String
  public private(set) var blocks: [DocumentBlock]
  public private(set) var contentStamp: VersionStamp

  public init(
    id: UUID = UUID(),
    actor: UUID,
    preamble: String = "",
    blocks: [DocumentBlock] = [
      .markdown(id: "body", source: "")
    ]
  ) {
    format = Self.formatVersion
    self.id = id
    self.preamble = preamble
    self.blocks = blocks
    contentStamp = VersionStamp(counter: 0, actor: actor)
    precondition(isValid)
  }

  var isValid: Bool {
    guard format == Self.formatVersion,
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

  public mutating func merge(_ other: Self) -> Bool {
    guard id == other.id, other.isValid, contentStamp < other.contentStamp
    else { return false }
    preamble = other.preamble
    blocks = other.blocks
    contentStamp = other.contentStamp
    return true
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

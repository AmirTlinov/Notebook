import Foundation

/// A file has one durable identity. Paths can move without replacing its text
/// history; binary bytes belong to the existing content-addressed blob store.
public struct DocumentFile: Codable, Equatable, Identifiable, Sendable {
  public static let maximumSourceLength = 4 * 1_024 * 1_024
  static let causalFieldNames = ["exists", "id", "path", "content"]
  static func causalFieldKeys(id: String) -> [String] {
    causalFieldNames.map { fieldKey(["files", collaborationIdentity(id), $0]) }
  }
  public let id: String
  public let path: String
  public let source: String
  public let resource: NotebookProgramPackage.File?
  public var isText: Bool { resource == nil }
  public var byteCount: Int64 { resource?.byteCount ?? Int64(source.utf8.count) }
  public var mimeType: String { NotebookProgramPackage.mimeType(for: path) }

  public init(id: String, path: String, source: String = "", resource: NotebookProgramPackage.File? = nil) {
    self.id = id; self.path = path; self.source = source; self.resource = resource
  }
  /// Source is authored literal text. Canonical Unicode equivalence must not
  /// erase an edit, its causal owner, or the exact text restored by Undo.
  public static func sourcesAreEqual(_ lhs: String, _ rhs: String) -> Bool {
    if lhs.isContiguousUTF8, rhs.isContiguousUTF8 {
      return lhs.utf8.withContiguousStorageIfAvailable { left in
        rhs.utf8.withContiguousStorageIfAvailable { right in
          left.count == right.count && (left.isEmpty || memcmp(left.baseAddress!, right.baseAddress!, left.count) == 0)
        }!
      }!
    }
    return (lhs as NSString).compare(rhs, options: .literal) == .orderedSame
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.id == rhs.id && lhs.path == rhs.path && lhs.resource == rhs.resource
      && sourcesAreEqual(lhs.source, rhs.source)
  }

  /// Only document source leaves use literal equality. Other JSON fields
  /// retain their current comparison semantics, including program state.
  static func sourceValuesAreEqual(_ lhs: JSONValue?, _ rhs: JSONValue?, source: Bool = false) -> Bool {
    switch (lhs, rhs) {
    case (.none, .none): return true
    case (.some(.string(let left)), .some(.string(let right))):
      return source ? sourcesAreEqual(left, right) : left == right
    case (.some(.array(let left)), .some(.array(let right))):
      return left.count == right.count && zip(left, right).allSatisfy {
        sourceValuesAreEqual($0.0, $0.1)
      }
    case (.some(.object(let left)), .some(.object(let right))):
      return left.count == right.count && left.allSatisfy { key, value in
        sourceValuesAreEqual(value, right[key], source: key == "source")
      }
    default: return lhs == rhs
    }
  }
  private enum CodingKeys: String, CodingKey { case id, path, source, resource }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id); path = try c.decode(String.self, forKey: .path)
    source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
    resource = try c.decodeIfPresent(NotebookProgramPackage.File.self, forKey: .resource)
    guard isValid else { throw DecodingError.dataCorruptedError(forKey: .path, in: c, debugDescription: "Invalid document file") }
  }
  public static func validPath(_ path: String) -> Bool { NotebookProgramPackage.validPath(path) }
  public var isValid: Bool {
    guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, id.utf16.count <= 120,
      Self.validPath(path), source.utf8.count <= Self.maximumSourceLength else { return false }
    if let resource { return source.isEmpty && resource.path == path && (try? resource.validate()) != nil }
    return true
  }
  public func replacingSource(_ source: String) -> Self { .init(id: id, path: path, source: source) }
  public func renamed(_ path: String) -> Self {
    .init(id: id, path: path, source: source, resource: resource.map {
      .init(path: path, mimeType: NotebookProgramPackage.mimeType(for: path), byteCount: $0.byteCount, parts: $0.parts)
    })
  }
}

public struct DocumentDocument: Codable, Equatable, Identifiable, Sendable {
  public static let formatVersion = 3
  public static let maximumFileCount = 4096
  public static let maximumSourceBytes = 16 * 1_024 * 1_024
  public let format: Int
  public let id: UUID
  public private(set) var entrypoint: String
  public private(set) var files: [DocumentFile]
  public private(set) var contentStamp: VersionStamp
  public private(set) var collaboration: CollaborativeContent?

  public init(id: UUID = UUID(), actor: UUID, entrypoint: String = "main.tex", files: [DocumentFile] = DocumentTemplate.article.files) {
    format = Self.formatVersion; self.id = id; self.entrypoint = entrypoint
    self.files = files.sorted { collaborationIdentity($0.id) < collaborationIdentity($1.id) }
    contentStamp = .init(counter: 0, actor: actor); collaboration = nil
    precondition(isValid)
  }

  /// The portable parser already owns the bounded typed files and metadata.
  /// Preserve that exact authored cut without another JSON encode/decode tree.
  init(importedID: UUID, entrypoint: String, files: [DocumentFile], contentStamp: VersionStamp,
    collaboration: CollaborativeContent?) throws {
    format = Self.formatVersion; id = importedID; self.entrypoint = entrypoint
    self.files = files.sorted { collaborationIdentity($0.id) < collaborationIdentity($1.id) }
    self.contentStamp = contentStamp; self.collaboration = collaboration
    guard isValid else { throw NotebookPortableDocumentImport.sourceChanged() }
  }

  public var isValid: Bool {
    format == Self.formatVersion && DocumentFile.validPath(entrypoint)
      && files.count <= Self.maximumFileCount && files.allSatisfy(\.isValid)
      && Set(files.map { collaborationIdentity($0.id) }).count == files.count
      && Set(files.map(\.path)).count == files.count
      && files.reduce(Int64(0), { $0 + $1.byteCount }) <= Self.maximumSourceBytes
      && contentStamp.counter <= VersionStamp.maximumCounter && (collaboration?.isValid ?? true)
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    guard lhs.format == rhs.format, lhs.id == rhs.id, lhs.entrypoint == rhs.entrypoint,
      lhs.files == rhs.files, lhs.contentStamp == rhs.contentStamp else { return false }
    switch (lhs.collaboration, rhs.collaboration) {
    case (.none, .none): return true
    case (.some(let left), .some(let right)):
      return left.fields.count == right.fields.count && left.fields.allSatisfy { key, version in
        right.fields[key].map { version.hasSameDocumentSource(as: $0) } ?? false
      }
    default: return false
    }
  }

  public func fileVersion(fileID: String) -> ContentFieldVersion {
    let versions = DocumentFile.causalFieldKeys(id: fileID).compactMap { collaboration?.fields[$0] }
    return .fileBasis(versions, fallback: contentStamp)
  }

  @discardableResult
  public mutating func replaceContent(entrypoint: String? = nil, files: [DocumentFile]? = nil, actor: UUID) -> Bool {
    guard let stamp = contentStamp.advanced(by: actor) else { return false }
    return replaceContent(entrypoint: entrypoint ?? self.entrypoint, files: files ?? self.files, stamp: stamp)
  }

  @discardableResult
  public mutating func replaceContent(entrypoint: String, files: [DocumentFile], stamp: VersionStamp) -> Bool {
    guard contentStamp < stamp, stamp.counter <= VersionStamp.maximumCounter else { return false }
    var candidate = self
    candidate.entrypoint = entrypoint; candidate.files = files.sorted { collaborationIdentity($0.id) < collaborationIdentity($1.id) }
    guard candidate.entrypoint != self.entrypoint || candidate.files != self.files else { return false }
    candidate.contentStamp = stamp
    var metadata = collaboration ?? CollaborativeContent()
    guard let before = try? JSONValue.encode(self), let after = try? JSONValue.encode(candidate) else { return false }
    metadata.record(before: before, after: after, beforeStamp: contentStamp, stamp: stamp, human: true)
    candidate.collaboration = metadata
    guard candidate.isValid else { return false }
    self = candidate; return true
  }

  @discardableResult
  public mutating func replaceFileSource(id: String, source: String, actor: UUID) -> Bool {
    guard let index = files.firstIndex(where: { $0.id == id }), files[index].isText else { return false }
    var next = files; next[index] = next[index].replacingSource(source)
    return replaceContent(files: next, actor: actor)
  }

  @discardableResult
  public mutating func merge(_ other: Self) throws -> Bool {
    guard id == other.id, isValid, other.isValid else { throw NotebookStorageError.invalidTransaction("document merge identity") }
    let local = try JSONValue.encode(self), incoming = try JSONValue.encode(other)
    let merged = try CollaborativeContent.merge(local: local, incoming: incoming,
      localState: collaboration, incomingState: other.collaboration, localStamp: contentStamp, incomingStamp: other.contentStamp)
    var candidate = try merged.value.decode(Self.self)
    candidate.collaboration = merged.state
    candidate.contentStamp = mergedContentStamp(local: local, incoming: incoming, result: merged.value,
      localStamp: contentStamp, incomingStamp: other.contentStamp)
    guard candidate.isValid else { throw NotebookStorageError.invalidTransaction("document merge result") }
    guard candidate != self else { return false }
    self = candidate; return true
  }

  /// An editor receipt reconciles exactly one file, never a stale directory.
  @discardableResult
  public mutating func mergeSource(_ publication: DocumentFileSourcePublication) throws -> Bool {
    guard id == publication.documentID,
      let index = files.firstIndex(where: { collaborationIdentity($0.id) == collaborationIdentity(publication.file.id) }) else { return false }
    let keys = Set(DocumentFile.causalFieldKeys(id: publication.file.id))
    var local = self; local.files = [files[index]]
    local.collaboration = .init(fields: (collaboration?.fields ?? [:]).filter { keys.contains($0.key) })
    var incoming = local; incoming.files = [publication.file]; incoming.contentStamp = publication.contentStamp
    incoming.collaboration = .init(fields: publication.fields)
    try local.merge(incoming)
    guard let file = local.files.first, local.files.count == 1 else { return false }
    var metadata = try collaboration ?? materializingCausalVersions().collaboration ?? CollaborativeContent()
    for (key, version) in local.collaboration?.fields ?? [:] where keys.contains(key) {
      try metadata.joinField(key, version: version, valuesAreEqual: { DocumentFile.sourceValuesAreEqual($0, $1) })
    }
    var candidate = self; candidate.files[index] = file; candidate.collaboration = metadata
    candidate.contentStamp = max(contentStamp, local.contentStamp)
    guard candidate.isValid else { throw NotebookStorageError.invalidTransaction("document source merge result") }
    guard candidate != self else { return false }
    self = candidate; return true
  }

  public func materializingCausalVersions() throws -> Self {
    guard collaboration == nil else { return self }
    var result = self, metadata = CollaborativeContent()
    try metadata.materializeVersions(in: .encode(self), fallback: contentStamp)
    result.collaboration = metadata; return result
  }

  private enum CodingKeys: String, CodingKey { case format, id, entrypoint, files, contentStamp, collaboration }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    format = try c.decode(Int.self, forKey: .format); id = try c.decode(UUID.self, forKey: .id)
    entrypoint = try c.decode(String.self, forKey: .entrypoint)
    files = try c.decode([DocumentFile].self, forKey: .files).sorted { collaborationIdentity($0.id) < collaborationIdentity($1.id) }
    contentStamp = try c.decode(VersionStamp.self, forKey: .contentStamp)
    collaboration = try c.decodeIfPresent(CollaborativeContent.self, forKey: .collaboration)
    guard isValid else { throw DecodingError.dataCorruptedError(forKey: .files, in: c, debugDescription: "Invalid file-backed LaTeX document") }
  }
}

public struct DocumentFileSourcePublication: Codable, Equatable, Sendable {
  public let documentID: UUID
  public let contentStamp: VersionStamp
  public let file: DocumentFile
  let fields: [String: ContentFieldVersion]
  public var sourceVersion: ContentFieldVersion {
    let versions = DocumentFile.causalFieldKeys(id: file.id).compactMap { fields[$0] }
    return .fileBasis(versions, fallback: contentStamp)
  }
  init?(document: DocumentDocument, fileID: String) {
    guard let file = document.files.first(where: { collaborationIdentity($0.id) == collaborationIdentity(fileID) }) else { return nil }
    documentID = document.id; contentStamp = document.contentStamp; self.file = file
    let keys = Set(DocumentFile.causalFieldKeys(id: file.id))
    fields = (document.collaboration?.fields ?? [:]).filter { keys.contains($0.key) }
  }
}

public struct DocumentStateRecord: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public private(set) var value: JSONValue
  public private(set) var stamp: VersionStamp
  public private(set) var fieldVersion: ContentFieldVersion?

  /// Historical records predate per-field clocks; their stored stamp remains
  /// the authoritative version of the value, including a committed JSON null.
  public var valueVersion: ContentFieldVersion { fieldVersion ?? .init(stamp: stamp, human: true) }

  public init(id: String, value: JSONValue, stamp: VersionStamp, fieldVersion: ContentFieldVersion? = nil) {
    precondition(!id.isEmpty && value.isValid)
    self.id = id
    self.value = value
    self.stamp = stamp
    self.fieldVersion = fieldVersion
  }

  func isValid(in journalStamp: VersionStamp) -> Bool {
    !id.isEmpty && id.utf16.count <= 120 && value.isValid
      && stamp.counter <= VersionStamp.maximumCounter && stamp <= journalStamp
      && (fieldVersion.map { $0.isValid && $0.stamp == stamp } ?? true)
  }

  mutating func replace(_ value: JSONValue, version: ContentFieldVersion) -> Bool {
    guard value.isValid else { return false }
    let previous = fieldVersion ?? .init(stamp:self.stamp,human:true)
    guard let resolved = try? previous.resolving(value: self.value, with: version, incomingValue: value),
      let selected = resolved.value else { return false }
    let changed = fieldVersion != resolved.version || self.value != selected
    fieldVersion = resolved.version; self.value = selected; self.stamp = resolved.version.stamp
    return changed
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
    self.records = records.sorted { $0.id < $1.id }
    stamp = VersionStamp(counter: 0, actor: actor)
    precondition(isValid)
  }

  init(importedID: UUID, records: [DocumentStateRecord], stamp: VersionStamp) throws {
    format = Self.formatVersion; id = importedID; self.records = records; self.stamp = stamp
    guard isValid else { throw NotebookPortableDocumentImport.sourceChanged() }
  }

  private enum CodingKeys: String, CodingKey { case format, id, records, stamp }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    format = try values.decode(Int.self, forKey: .format)
    id = try values.decode(UUID.self, forKey: .id)
    records = try values.decode([DocumentStateRecord].self, forKey: .records).sorted { $0.id < $1.id }
    stamp = try values.decode(VersionStamp.self, forKey: .stamp)
  }

  public func value(for instanceID: String) -> JSONValue? {
    records.first { $0.id == instanceID }?.value
  }

  var isValid: Bool {
    let ids = records.map(\.id)
    return format == Self.formatVersion
      && Set(ids).count == ids.count
      && records.allSatisfy { $0.isValid(in: stamp) }
      && stamp.counter <= VersionStamp.maximumCounter
  }

  @discardableResult
  public mutating func commit(
    instanceID: String,
    value: JSONValue,
    actor: UUID,
    human: Bool = true
  ) -> Bool {
    guard !instanceID.isEmpty,
      instanceID.utf16.count <= 120,
      value.isValid,
      let nextStamp = stamp.advanced(by: actor)
    else { return false }
    if let index = records.firstIndex(where: { $0.id == instanceID }) {
      guard records[index].value != value else { return false }
      let previous = records[index].fieldVersion ?? .init(stamp:records[index].stamp,human:true)
      _ = records[index].replace(value, version:.init(stamp:nextStamp,human:human,previous:previous))
    } else {
      let position = records.firstIndex { $0.id > instanceID } ?? records.count
      records.insert(
        DocumentStateRecord(id: instanceID, value: value, stamp: nextStamp, fieldVersion:.init(stamp:nextStamp,human:human)),
        at: position
      )
    }
    stamp = nextStamp
    return true
  }

  /// Absent records in an addressed receipt say nothing about other instances.
  /// A new combination at an old frontier still needs its own aggregate clock.
  @discardableResult
  public mutating func merge(_ publication: NotebookDocumentStatePublication) -> Bool {
    guard publication.documentID == id,
      publication.journalStamp.counter <= VersionStamp.maximumCounter,
      publication.record.isValid(in: publication.journalStamp) else { return false }
    let incoming = publication.record
    let index = records.firstIndex { $0.id == incoming.id }
    let previous = index.map { records[$0] }
    var resolved = previous ?? incoming
    if previous != nil { _ = resolved.replace(incoming.value, version: incoming.valueVersion) }
    var frontier = max(stamp, publication.journalStamp)
    if resolved.value != previous?.value, stamp >= publication.journalStamp {
      guard let advanced = frontier.advanced(by: frontier.actor) else { return false }
      frontier = advanced
    }
    let changed = previous != resolved || stamp != frontier
    if let index {
      records[index] = resolved
    } else {
      let index = records.firstIndex { $0.id > incoming.id } ?? records.count
      records.insert(resolved, at: index)
    }
    stamp = frontier
    return changed
  }

  public mutating func merge(_ other: Self) -> Bool {
    guard id == other.id, other.isValid else { return false }
    let frontier = max(stamp,other.stamp)
    let ownerRecords = stamp > other.stamp ? records : other.records
    var changed = false
    for incoming in other.records {
      if let index = records.firstIndex(where: { $0.id == incoming.id }) {
        changed = records[index].replace(
          incoming.value,
          version:incoming.fieldVersion ?? .init(stamp:incoming.stamp,human:true)
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
    let visible = Dictionary(uniqueKeysWithValues:records.map { ($0.id,$0.value) })
    let ownerVisible = Dictionary(uniqueKeysWithValues:ownerRecords.map { ($0.id,$0.value) })
    if visible != ownerVisible, let mergedStamp = frontier.advanced(by:frontier.actor) {
      stamp = mergedStamp; changed = true
    }
    records.sort { $0.id < $1.id }
    return changed
  }
}

extension ContentFieldVersion {
  /// A file CAS observes several registers, not a merge of their differently
  /// typed values. Keep only their causal vector in this comparison token.
  static func fileBasis(_ versions: [Self], fallback: VersionStamp) -> Self {
    guard let latest = versions.max(by: { $0.stamp < $1.stamp }) else { return .init(stamp: fallback, human: true) }
    var observed: [String: UInt64] = [:]
    for version in versions {
      for (actor, counter) in version.observed { observed[actor] = max(observed[actor] ?? 0, counter) }
    }
    return .init(stamp: latest.stamp, human: latest.human, observed: observed)
  }
}

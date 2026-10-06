import CryptoKit
import Darwin
import Foundation

/// The portable file's preparation and accepted create share one immutable
/// source. Stages expose their real next allocation before the worker runs;
/// only the ready plan can enter the ordinary writer.
public enum NotebookPortableDocumentImport {
  public static let maximumPreparationBytes = 192 * 1_024 * 1_024
  public struct Cost: Sendable {
    public let payloadBytes: Int
    public let completionBytes: Int
    public var bytes: Int { payloadBytes + completionBytes }
    init(payload: Int, completion: Int) throws {
      guard payload >= 0, completion >= 0, payload <= maximumPreparationBytes,
        completion <= maximumPreparationBytes - payload else { throw refusal() }
      payloadBytes = payload; completionBytes = completion
    }
  }
  public static var directoryCost: Cost {
    try! .init(payload: NotebookDocumentZIP.maximumDirectoryBytes,
      completion: NotebookDocumentZIP.readWindowBytes * 2 + 262_144)
  }

  public struct Inspection: Sendable {
    let archive: NotebookDocumentZIP.Archive
    let source: Source
    public let sha256: String
    public var metadataReadCost: Cost {
      get throws {
        guard let metadata = archive.entry("manifest.json"), let state = archive.entry("state.json"),
          metadata.size <= NotebookPortableDocument.maximumMetadataBytes,
          state.size <= NotebookPortableDocument.maximumStateBytes else {
          throw CollaborationError("invalid_portable_document", "В архиве нет допустимого описания или состояния документа.")
        }
        return try .init(payload: archive.retainedDirectoryBytes + metadata.size + state.size,
          completion: max(metadata.size, state.size) + 1_048_576)
      }
    }
    public func readMetadata() throws -> MetadataBytes {
      _ = try metadataReadCost
      return try .init(inspection: self,
        manifest: archive.data(archive.entry("manifest.json")!, maximumBytes: NotebookPortableDocument.maximumMetadataBytes),
        state: archive.data(archive.entry("state.json")!, maximumBytes: NotebookPortableDocument.maximumStateBytes))
    }
  }

  public struct MetadataBytes: Sendable {
    let inspection: Inspection
    let manifest: Data
    let state: Data
    public let decodeCost: Cost
    init(inspection: Inspection, manifest: Data, state: Data) throws {
        let resident = inspection.archive.retainedDirectoryBytes + manifest.count + state.count
        let manifestDecode = try NotebookJSONAdmission.allocationCost(manifest,
          maximumBytes: maximumPreparationBytes - resident - 1_048_576)
        let stateDecode = try NotebookJSONAdmission.allocationCost(state,
          maximumBytes: maximumPreparationBytes - resident - manifestDecode - 1_048_576)
        decodeCost = try .init(payload: resident, completion: manifestDecode + stateDecode + 1_048_576)
        self.inspection = inspection; self.manifest = manifest; self.state = state
    }
    public func decode() throws -> Metadata {
      let cost = decodeCost
      let manifest = try JSONDecoder().decode(NotebookPortableDocument.Manifest.self, from: manifest)
      guard manifest.format == "NotebookDocument/1", manifest.files.count <= DocumentDocument.maximumFileCount,
        Set(manifest.files.map(\.path)).count == manifest.files.count,
        manifest.stateSHA256 == NotebookPortableDocument.hash(state) else {
        throw CollaborationError("invalid_portable_document", "Описание или состояние документа повреждено.")
      }
      let expected = Set(manifest.files.map { "files/" + $0.path }).union(["manifest.json", "state.json"])
      guard expected.isSubset(of: Set(inspection.archive.entries.map(\.path))),
        Set(inspection.archive.entries.map(\.path)).subtracting(expected).isSubset(of: NotebookPortableDocument.derivedNames) else {
        throw CollaborationError("invalid_portable_document", "Состав ZIP не совпадает с описанием документа.")
      }
      let state = try JSONDecoder().decode(DocumentStateJournal.self, from: state)
      // The pre-decode scanner owns Foundation's map and typed containers. The
      // next stage carries a conservative typed upper bound, without raw JSON.
      return .init(inspection: inspection, manifest: manifest, state: state,
        metadataBytes: cost.completionBytes)
    }
  }

  public struct Metadata: Sendable {
    let inspection: Inspection
    let manifest: NotebookPortableDocument.Manifest
    let state: DocumentStateJournal
    let metadataBytes: Int
    public var sourceReadCost: Cost {
      get throws {
        var sourceBytes = 0, textBytes = 0, largest = 0, binary = false
        for entry in manifest.files {
          guard DocumentFile.validPath(entry.path), let stored = inspection.archive.entry("files/" + entry.path),
            stored.size == entry.byteCount, entry.byteCount >= 0,
            entry.byteCount <= DocumentDocument.maximumSourceBytes - sourceBytes,
            !entry.text || entry.byteCount <= DocumentFile.maximumSourceLength else { throw refusal() }
          sourceBytes += entry.byteCount
          if entry.text { textBytes += entry.byteCount; largest = max(largest, entry.byteCount) }
          else if entry.byteCount > 0 { binary = true }
        }
        return try .init(payload: inspection.archive.retainedDirectoryBytes + metadataBytes
          + textBytes * 2 + manifest.files.count * 1_024,
          completion: max(largest * 2, binary ? NotebookProgramPackage.partBytes * 2 : 0)
            + 2 * 1_048_576)
      }
    }
    public func readSources() throws -> Sources {
      _ = try sourceReadCost
      var files: [DocumentFile] = [], parts: [ResourcePart] = [], resourceOffset: Int64 = 0
      for entry in manifest.files {
        try Task.checkCancellation()
        let stored = inspection.archive.entry("files/" + entry.path)!
        if entry.text {
          let bytes = try inspection.archive.data(stored, maximumBytes: DocumentFile.maximumSourceLength)
          guard NotebookPortableDocument.hash(bytes) == entry.sha256,
            let text = String(data: bytes, encoding: .utf8) else { throw sourceChanged() }
          files.append(.init(id: entry.id, path: entry.path, source: text))
        } else {
          var digest = SHA256(), chunk = Data(), fileParts: [NotebookProgramPackage.Part] = []
          func flush() throws {
            guard !chunk.isEmpty else { return }
            let hash = NotebookPortableDocument.hash(chunk), start = resourceOffset
            try inspection.source.resources.write(contentsOf: chunk)
            resourceOffset += Int64(chunk.count)
            parts.append(.init(sha256: hash, range: start..<resourceOffset))
            fileParts.append(.init(sha256: hash, byteCount: chunk.count))
            chunk.removeAll(keepingCapacity: true)
          }
          try inspection.archive.consume(stored) { bytes in
            digest.update(data: bytes)
            var offset = 0
            while offset < bytes.count {
              let count = min(NotebookProgramPackage.partBytes - chunk.count, bytes.count - offset)
              chunk.append(bytes[offset..<offset+count]); offset += count
              if chunk.count == NotebookProgramPackage.partBytes { try flush() }
            }
          }
          try flush()
          guard NotebookHexEncoding.encode(digest.finalize()) == entry.sha256 else { throw sourceChanged() }
          files.append(.init(id: entry.id, path: entry.path, resource: .init(path: entry.path,
            mimeType: NotebookProgramPackage.mimeType(for: entry.path), byteCount: Int64(entry.byteCount), parts: fileParts)))
        }
      }
      try inspection.source.resources.synchronize()
      let document = try DocumentDocument(importedID: manifest.documentID, entrypoint: manifest.entrypoint,
        files: files, contentStamp: manifest.contentStamp, collaboration: manifest.collaboration)
      let cut = try NotebookExportCut(document: document, state: state, presented: manifest.presented)
      // Validate optional ZIP bodies even when no compiler cache will be used.
      for entry in inspection.archive.entries where NotebookPortableDocument.derivedNames.contains(entry.path) {
        try inspection.archive.consume(entry) { _ in }
      }
      return try .init(inspection: inspection, cut: cut, parts: parts, metadataBytes: metadataBytes,
        derivedHashes: manifest.derived)
    }
  }

  public struct Sources: Sendable {
    let inspection: Inspection
    public let cut: NotebookExportCut
    let parts: [ResourcePart]
    let metadataBytes: Int
    private let partsBytes: Int
    public let preparationCost: Cost
    public let completionBytes: Int

    init(inspection: Inspection, cut: NotebookExportCut, parts: [ResourcePart], metadataBytes: Int,
      derivedHashes: [String: String]?) throws {
      self.inspection = inspection; self.cut = cut; self.parts = parts
      self.metadataBytes = metadataBytes; self.derivedHashes = derivedHashes
      let footprint = try Self.createFootprints(cut)
      partsBytes = parts.capacity * MemoryLayout<ResourcePart>.stride + parts.reduce(0) { $0 + $1.sha256.utf8.count * 2 }
      let retained = Self.retainedSourceBytes(cut)
      preparationCost = try .init(payload: retained + inspection.archive.retainedDirectoryBytes + partsBytes,
        completion: footprint.operation.decodingBytes + footprint.operation.wireBytes * 2 + 2 * 1_048_576)
      completionBytes = try footprint.completionBytes(resourceBytes: parts.reduce(0) {
        $0 + Int($1.range.upperBound-$1.range.lowerBound)
      }, fileCount: cut.document.files.count, stateCount: cut.state.records.count, partCount: parts.count)
    }

    private static func retainedSourceBytes(_ cut: NotebookExportCut) -> Int {
      documentBytes(cut.document) + MemoryLayout<DocumentStateJournal>.stride
        + (cut.presented?.retainedPayloadBytes ?? 0)
        + cut.state.records.capacity * MemoryLayout<DocumentStateRecord>.stride
        + cut.state.records.reduce(0) {
          $0 + $1.id.utf8.count * 2 + $1.value.retainedPayloadBytes + ($1.fieldVersion?.retainedPayloadBytes ?? 0)
        }
    }
    private static func createFootprints(_ cut: NotebookExportCut) throws -> CreateFootprints {
      var files = ContentFieldVersion.WriteFootprint.array
      for file in cut.document.files {
        var value = ContentFieldVersion.WriteFootprint.object
        try value.field("id", .string(file.id)); try value.field("path", .string(file.path))
        try value.field("source", .string(file.source))
        if let resource = file.resource {
          var body = ContentFieldVersion.WriteFootprint.object, pieces = ContentFieldVersion.WriteFootprint.array
          try body.field("path", .string(resource.path)); try body.field("mimeType", .string(resource.mimeType))
          try body.field("byteCount", .number)
          for part in resource.parts {
            var piece = ContentFieldVersion.WriteFootprint.object
            try piece.field("sha256", .string(part.sha256)); try piece.field("byteCount", .number)
            try pieces.element(piece)
          }
          try body.field("parts", pieces); try value.field("resource", body)
        }
        try files.element(value)
      }
      var records = ContentFieldVersion.WriteFootprint.array
      for record in cut.state.records {
        var value = ContentFieldVersion.WriteFootprint.object
        try value.field("id", .string(record.id)); try value.field("value", .json(record.value))
        try value.field("stamp", .stamp()); try value.field("fieldVersion", ContentFieldVersion.authoredWriteFootprint(actorCount: 1))
        try records.element(value)
      }
      var state = ContentFieldVersion.WriteFootprint.object
      try state.field("format", .number); try state.field("id", .uuid)
      try state.field("stamp", .stamp()); try state.field("records", records)
      var center = ContentFieldVersion.WriteFootprint.object
      for key in ["tileX", "tileY", "localX", "localY"] { try center.field(key, .number) }
      var values = ContentFieldVersion.WriteFootprint.object
      try values.field("title", .string("Импортированный документ")); try values.field("center", center)
      try values.field("entrypoint", .string(cut.document.entrypoint)); try values.field("files", files)
      try values.field("state", state)
      var fields = ContentFieldVersion.WriteFootprint.object
      let authored = try ContentFieldVersion.authoredWriteFootprint(actorCount: 1)
      try fields.field("entrypoint", authored)
      for file in cut.document.files {
        for key in DocumentFile.causalFieldKeys(id: file.id) { try fields.field(key, authored) }
      }
      var collaboration = ContentFieldVersion.WriteFootprint.object
      try collaboration.field("fields", fields)
      var document = ContentFieldVersion.WriteFootprint.object
      try document.field("format", .number); try document.field("id", .uuid)
      try document.field("entrypoint", .string(cut.document.entrypoint)); try document.field("files", files)
      try document.field("contentStamp", .stamp()); try document.field("collaboration", collaboration)
      return .init(operation: values, document: document, state: state)
    }

    public func prepare(requestID: UUID, targetBoardID: UUID, center: WorldPoint, actor: UUID) throws -> Prepared {
      guard center.isValid else { throw sourceChanged() }
      let documentID = NotebookStore.submissionID(requestID, suffix: "document")
      let records = cut.state.records.enumerated().map { index, original -> DocumentStateRecord in
        let stamp = VersionStamp(counter: UInt64(index+1), actor: actor)
        return .init(id: original.id, value: original.value, stamp: stamp,
          fieldVersion: .init(stamp: stamp, human: true))
      }
      let state = try DocumentStateJournal(importedID: documentID, records: records,
        stamp: .init(counter: UInt64(records.count), actor: actor))
      let operation = CollaborationOperation(kind: .createDocument, target: .init(kind: .board, id: targetBoardID),
        id: documentID.uuidString.lowercased(), values: ["title": .string("Импортированный документ"),
          "center": try .encode(center), "entrypoint": .string(cut.document.entrypoint),
          "files": try .encode(cut.document.files), "state": try .encode(state)])
      let fingerprint = try collaborationHash(JSONValue.object(["domain": .string("NotebookDocumentImport/1"),
        "archive": .string(inspection.sha256), "boardID": .string(targetBoardID.uuidString.lowercased()), "center": try .encode(center)]))
      var cache = Cache(inspection: inspection, document: cut.document, parts: parts,
        hashes: inspectionManifestDerived)
      let authored = JSONValue.object(operation.values).retainedPayloadBytes + inspection.archive.retainedDirectoryBytes
        + partsBytes + 4_096
      let optional = cache == nil ? 0 : documentBytes(cut.document)
      // The useful new owner does not depend on retaining the old causal
      // frontier solely to validate optional print pixels later.
      if optional > maximumPreparationBytes - authored - completionBytes { cache = nil }
      let retained = authored + (cache == nil ? 0 : optional)
      return try .init(requestID: requestID, documentID: documentID, actor: actor, fingerprint: fingerprint,
        operation: operation, source: inspection.source, parts: parts, cache: cache,
        cost: .init(payload: retained, completion: completionBytes))
    }

    private var inspectionManifestDerived: [String: String]? { derivedHashes }
    let derivedHashes: [String: String]?
  }

  /// The ordinary create executor keeps the operation, new owners and exact
  /// receipt. Sequential hashes do not require simultaneous copies of every
  /// earlier codec buffer. Recovery has a different, cumulative SQL/JSON gate.
  private struct CreateFootprints: Sendable {
    let operation: ContentFieldVersion.WriteFootprint
    let document: ContentFieldVersion.WriteFootprint
    let state: ContentFieldVersion.WriteFootprint

    func completionBytes(resourceBytes: Int, fileCount: Int, stateCount: Int, partCount: Int) throws -> Int {
      let maximum = NotebookNativeWriteAllowance.maximumExecutionBytes
      let fixed = 8 * 1_048_576 + fileCount * 8_192 + stateCount * 4_096 + partCount * 2_048
      // Receipt.action carries the operation; changes retain both newly born
      // owners. Framing/placement/expectation/inverse addresses have fixed
      // per-member credit above, separate from source and state tokens.
      let receiptWire = operation.wireBytes + document.wireBytes + state.wireBytes
      let receiptTokens = operation.tokens + document.tokens + state.tokens
      let receiptDecode = receiptWire * 8 + receiptTokens * 512
      // NativeJSONPhase charges 704 bytes/value, 528 bytes/string plus escaped
      // UTF8 and collection capacity. 2048/token includes a key or value's
      // doubled dictionary/array capacity without assuming long scalars.
      let receiptNativePhase = receiptWire * 8 + receiptTokens * 2_048
      // Cold Retry decodes the receipt envelope once and admits the two
      // JSONValue -> typed receipt phases. Its immutable result is already held.
      let recoveryJSON = receiptDecode + receiptNativePhase * 2
      // Creation reads only the new document; Retry reads the larger receipt.
      // Existing resource verification additionally returns every byte once.
      let sqlReturned = resourceBytes + max(document.wireBytes, receiptWire)
      // One codec phase may overlap the accepted operation, new owner trees,
      // receipt map and canonical receipt bytes. These bounds also cover the
      // create executor's temporary typed files and returned exact document.
      let codecPeak = operation.decodingBytes + document.decodingBytes + state.decodingBytes
        + receiptDecode + receiptWire * 2
      guard fixed < maximum, sqlReturned <= (maximum-fixed)/10,
        recoveryJSON <= (maximum-fixed)/5*4, codecPeak <= maximum-fixed else { throw refusal() }
      let jsonCredit = (recoveryJSON + 3) / 4 * 5
      return fixed + max(sqlReturned * 10, jsonCredit, codecPeak)
    }
  }
  struct ResourcePart: Sendable { let sha256: String; let range: Range<Int64> }

  public struct Prepared: Sendable {
    public let requestID: UUID
    public let documentID: UUID
    let actor: UUID
    let fingerprint: String
    let operation: CollaborationOperation
    let source: Source
    let parts: [ResourcePart]
    public let cache: Cache?
    public let cost: Cost

    public func command() -> Command { .init(self) }
  }

  public struct Output: Sendable {
    public let documentID: UUID
    public let receipt: CollaborationReceipt
    public let document: DocumentDocument
  }

  public final class Command: Sendable {
    private let native: NotebookNativeCommand<DocumentDocument>
    let documentID: UUID
    init(_ plan: Prepared) {
      documentID = plan.documentID
      native = .init(allowance: .init(executionBytes: plan.cost.completionBytes)) { store, prepared in
        let receipt = try store.commandTransaction {
          if let saved = try store.collaborationActionIfPresent(plan.requestID) {
            guard saved.requestFingerprint == plan.fingerprint, saved.author == .human,
              saved.action.operations == [plan.operation] else {
              throw CollaborationError("action_id_conflict", "Этот ID уже принадлежит другому импорту.")
            }
            return saved
          }
          try plan.stage(in: store)
          let expected = try store.readBasis(targets: [plan.operation.target,
            .init(kind: .workspace, id: store.workspaceHeader().rootBoardID)]).owners
          return try store.applyCollaborationActionImmediately(.init(id: plan.requestID, summary: "Импорт документа",
            expected: expected, operations: [plan.operation]), actor: plan.actor,
            requestFingerprint: plan.fingerprint, human: true)
        }
        let output = (receipt: receipt, sources: [try store.loadDocument(plan.documentID)])
        prepared(output); return output
      }
    }
    public func apply(to store: NotebookStore) throws -> Output {
      let value = try native.apply(to: store)
      guard let document = value.sources.first else { throw NotebookStorageError.corruptRecord("portable import output") }
      return .init(documentID: documentID, receipt: value.receipt, document: document)
    }
  }

  public struct Cache: Sendable {
    let inspection: Inspection
    let document: DocumentDocument
    let parts: [ResourcePart]
    let hashes: [String: String]
    init?(inspection: Inspection, document: DocumentDocument, parts: [ResourcePart], hashes: [String: String]?) {
      guard let hashes, Set(hashes.keys) == NotebookPortableDocument.derivedNames,
        hashes.values.allSatisfy(NotebookProgramPackage.validHash),
        NotebookPortableDocument.derivedNames.allSatisfy({ inspection.archive.entry($0) != nil }) else { return nil }
      self.inspection = inspection; self.document = document; self.parts = parts; self.hashes = hashes
    }
    public func cost(for accepted: DocumentDocument) -> Cost? {
      let entries = NotebookPortableDocument.derivedNames.compactMap { inspection.archive.entry($0) }
      guard inspection.archive.entry("derived/document.pdf")!.size <= 16 * 1_048_576,
        inspection.archive.entry("derived/document.synctex.gz")!.size <= 4 * 1_048_576,
        inspection.archive.entry("derived/document.nbmap")!.size <= 4 * 1_048_576,
        inspection.archive.entry("derived/source-map.json")!.size <= NotebookPortableDocument.maximumMetadataBytes else { return nil }
      let source = documentBytes(document), received = documentBytes(accepted), derived = entries.reduce(0) { $0+$1.size }
      let resources = accepted.files.reduce(0) { $0 + ($1.resource.map { Int($0.byteCount) } ?? 0) }
      return try? .init(payload: inspection.archive.retainedDirectoryBytes + source + received*2 + derived + resources,
        completion: 2 * derived + source + received + resources*2 + 8 * 1_048_576)
    }
    public func readDerivedBytes(document accepted: DocumentDocument) throws -> CacheBytes? {
      guard let cost = cost(for: accepted) else { return nil }
      var data: [String: Data] = [:]
      for path in NotebookPortableDocument.derivedNames {
        let entry = inspection.archive.entry(path)!, value = try inspection.archive.data(entry, maximumBytes: entry.size)
        guard NotebookPortableDocument.hash(value) == hashes[path] else { return nil }; data[path] = value
      }
      let mapBytes = data["derived/source-map.json"]!
      // This integer-only scan precedes typed allocation. The caller must grow
      // its same optional lease to decodingCost before entering decode().
      let scan = try NotebookJSONAdmission.allocationCost(mapBytes,
        maximumBytes: maximumPreparationBytes-cost.bytes)
      return try .init(cache: self, accepted: accepted, pdf: data["derived/document.pdf"]!,
        syncTeX: data["derived/document.synctex.gz"]!, interactiveMap: data["derived/document.nbmap"]!,
        map: mapBytes, decodingCost: .init(payload: cost.payloadBytes, completion: cost.completionBytes+scan))
    }
    public func readResource(_ file: DocumentFile) throws -> Data {
      guard let resource = file.resource else { return Data(file.source.utf8) }
      var data = Data(); data.reserveCapacity(Int(resource.byteCount))
      for part in resource.parts {
        guard let stored = parts.first(where: { $0.sha256 == part.sha256 }), stored.range.count == part.byteCount else {
          throw NotebookStorageError.blobMissing(part.sha256)
        }
        let bytes = try inspection.source.readResource(stored.range)
        guard NotebookPortableDocument.hash(bytes) == part.sha256 else { throw NotebookStorageError.blobHashMismatch }
        data.append(bytes)
      }
      return data
    }
  }

  public struct CacheBytes: Sendable {
    let cache: Cache
    let accepted: DocumentDocument
    let pdf: Data
    let syncTeX: Data
    let interactiveMap: Data
    let map: Data
    public let decodingCost: Cost
    public func decode(compilerRevision: String) throws -> NotebookPortableDocument.Derived? {
      let sourceMap = try JSONDecoder().decode(DocumentPrintSourceMap.self, from: map)
      guard sourceMap.compilerRevision == compilerRevision else { return nil }
      let derived = NotebookPortableDocument.Derived(pdf: pdf, syncTeX: syncTeX,
        interactiveMap: interactiveMap, sourceMap: sourceMap)
      try derived.validate(document: cache.document, compilerRevision: compilerRevision)
      return try derived.rebinding(to: accepted)
    }
  }

  private static func documentBytes(_ document: DocumentDocument) -> Int {
    MemoryLayout<DocumentDocument>.stride + document.files.capacity * MemoryLayout<DocumentFile>.stride
      + document.entrypoint.utf8.count*2 + document.files.reduce(0) { total, file in
        total + (file.id.utf8.count+file.path.utf8.count+file.source.utf8.count)*2
          + (file.resource.map { $0.parts.capacity*MemoryLayout<NotebookProgramPackage.Part>.stride
            + ($0.path.utf8.count+$0.mimeType.utf8.count)*2 + $0.parts.reduce(0) { $0+$1.sha256.utf8.count*2 } } ?? 0)
      } + (document.collaboration.map { value in
        value.fields.capacity * (MemoryLayout<String>.stride+MemoryLayout<ContentFieldVersion>.stride+32)
          + value.fields.reduce(0) { $0+$1.key.utf8.count*2+$1.value.retainedPayloadBytes }
      } ?? 0)
  }

  /// Snapshot by streaming once. The original path is never reopened by SQL or
  /// Retry; ARC removes only this temporary copy after its last real worker.
  final class Source: @unchecked Sendable {
    let directory: URL
    let archiveURL: URL
    let resourcesURL: URL
    let archive: FileHandle
    let resources: FileHandle
    let byteCount: Int
    let sha256: String

    init(file: URL, expectedHash: String?) throws {
      let input = try NotebookProgramImport.openRegularFile(file)
      defer { try? input.close() }
      var before = stat(), after = stat()
      guard fstat(input.fileDescriptor, &before) == 0, before.st_size >= 22,
        before.st_size <= NotebookDocumentZIP.maximumBytes else { throw refusal() }
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-portable-import-" + UUID().uuidString)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      var complete = false
      defer { if !complete { try? FileManager.default.removeItem(at: directory) } }
      let archiveURL = directory.appendingPathComponent("source.notex"), resourcesURL = directory.appendingPathComponent("resources")
      for url in [archiveURL, resourcesURL] {
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
          throw NotebookStorageError.invalidTransaction("portable import spool")
        }
      }
      let output = try FileHandle(forWritingTo: archiveURL)
      defer { try? output.close() }
      var digest = SHA256(), count = 0
      while count < before.st_size {
        try Task.checkCancellation()
        let bytes = try input.read(upToCount: min(NotebookDocumentZIP.readWindowBytes, Int(before.st_size)-count)) ?? Data()
        guard !bytes.isEmpty else { throw sourceChanged() }
        try output.write(contentsOf: bytes); digest.update(data: bytes); count += bytes.count
      }
      guard (try input.read(upToCount: 1))?.isEmpty != false, fstat(input.fileDescriptor, &after) == 0,
        before.st_dev == after.st_dev, before.st_ino == after.st_ino, before.st_size == after.st_size,
        before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
        before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw sourceChanged() }
      let hash = NotebookHexEncoding.encode(digest.finalize())
      guard expectedHash == nil || expectedHash == hash else { throw sourceChanged() }
      self.directory = directory; self.archiveURL = archiveURL; self.resourcesURL = resourcesURL
      archive = try FileHandle(forReadingFrom: archiveURL); resources = try FileHandle(forWritingTo: resourcesURL)
      byteCount = count; sha256 = hash; complete = true
    }
    func read(_ range: Range<Int>) throws -> Data {
      guard range.lowerBound >= 0, range.upperBound <= byteCount,
        range.count <= 65_557 else { throw NotebookStorageError.invalidTransaction("portable read window") }
      var data = Data(count: range.count)
      try data.withUnsafeMutableBytes { bytes in
        var offset = 0
        while offset < bytes.count {
          try Task.checkCancellation()
          let count = pread(archive.fileDescriptor, bytes.baseAddress!.advanced(by: offset), bytes.count-offset, off_t(range.lowerBound+offset))
          if count < 0, errno == EINTR { continue }
          guard count > 0 else { throw sourceChanged() }; offset += count
        }
      }
      return data
    }
    func readResource(_ range: Range<Int64>) throws -> Data {
      guard range.lowerBound >= 0, range.count <= NotebookProgramPackage.partBytes else {
        throw NotebookStorageError.invalidTransaction("portable resource window")
      }
      let reader = try NotebookProgramImport.openRegularFile(resourcesURL)
      defer { try? reader.close() }
      try reader.seek(toOffset: UInt64(range.lowerBound))
      var bytes = Data(); bytes.reserveCapacity(range.count)
      while bytes.count < range.count {
        try Task.checkCancellation()
        let next = try reader.read(upToCount: min(NotebookDocumentZIP.readWindowBytes, range.count-bytes.count)) ?? Data()
        guard !next.isEmpty else { throw sourceChanged() }; bytes.append(next)
      }
      return bytes
    }
    deinit {
      try? archive.close(); try? resources.close(); try? FileManager.default.removeItem(at: directory)
    }
  }

  public static func inspect(file: URL, expectedHash: String? = nil) throws -> Inspection {
    guard file.isFileURL, expectedHash.map(NotebookProgramPackage.validHash) ?? true else { throw sourceChanged() }
    let source = try Source(file: file, expectedHash: expectedHash)
    return try .init(archive: .init(byteCount: source.byteCount, read: { try source.read($0) }),
      source: source, sha256: source.sha256)
  }
  static func refusal() -> CollaborationError {
    .init("resource_limit", "Подготовка документа превышает доступный резерв памяти. Исходный файл сохранён полностью.")
  }
  static func sourceChanged() -> CollaborationError {
    .init("invalid_portable_document", "Байты документа не совпадают с выбранным исходником или описанием ZIP.")
  }
}

extension NotebookPortableDocumentImport.Prepared {
  fileprivate func stage(in store: NotebookStore) throws {
    let database = store.currentSQL!
    for part in parts {
      if let count = try database.rows("SELECT length(data) FROM blobs WHERE hash=?", [.text(part.sha256)]).first?[0].integer {
        guard count == part.range.count else { throw NotebookStorageError.blobHashMismatch }
        var offset = 0
        while offset < part.range.count {
          let count = min(NotebookDocumentZIP.readWindowBytes, part.range.count-offset)
          let existing = try store.readBlobChunk(hash: part.sha256, offset: Int64(offset), maxBytes: count)
          let start = part.range.lowerBound+Int64(offset)
          guard existing == (try source.readResource(start..<start+Int64(count))) else { throw NotebookStorageError.blobHashMismatch }
          offset += count
        }
      } else {
        try store.stageBlob(file: source.resourcesURL, expectedHash: part.sha256,
          byteCount: Int64(part.range.count), range: part.range)
      }
    }
  }
}

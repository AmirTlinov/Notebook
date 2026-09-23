import CryptoKit
import Foundation

/// Durable writes use the existing persistence executor; committed offers and
/// immutable blob reads use bounded WAL snapshots, not the native write queue.
/// `applyRemoteChange` returns only after content, dedupe and incoming cursor
/// have committed together. Transport receipt never calls it speculatively.
public struct NotebookTransportStorage: Sendable {
  public var journalGeneration: UUID?
  public var changes: @Sendable (UInt64, Int) async throws -> [NotebookDurableChange]
  public var incomingCursor: @Sendable (NotebookReplicationSource) async throws -> UInt64
  public var acknowledgePeer: @Sendable (UUID, UInt64) async throws -> Void
  public var readBlobWindow: @Sendable ([NotebookTransportBlobRequest]) async throws -> [NotebookTransportBlobChunk]
  public var stageBlobs: @Sendable ([NotebookTransportCompletedBlob]) async throws -> Void
  public var prepareIncoming: @Sendable (NotebookReplicationDelivery, [NotebookTransportCompletedBlob]) async throws -> [String]
  public var applyRemoteChange: @Sendable (NotebookReplicationDelivery) async throws -> UInt64

  public init(
    journalGeneration: UUID? = nil,
    changes: @escaping @Sendable (UInt64, Int) async throws -> [NotebookDurableChange],
    incomingCursor: @escaping @Sendable (NotebookReplicationSource) async throws -> UInt64,
    acknowledgePeer: @escaping @Sendable (UUID, UInt64) async throws -> Void,
    readBlobWindow: @escaping @Sendable ([NotebookTransportBlobRequest]) async throws -> [NotebookTransportBlobChunk],
    stageBlobs: @escaping @Sendable ([NotebookTransportCompletedBlob]) async throws -> Void,
    prepareIncoming: @escaping @Sendable (NotebookReplicationDelivery, [NotebookTransportCompletedBlob]) async throws -> [String],
    applyRemoteChange: @escaping @Sendable (NotebookReplicationDelivery) async throws -> UInt64
  ) {
    self.journalGeneration = journalGeneration
    self.changes = changes; self.incomingCursor = incomingCursor; self.acknowledgePeer = acknowledgePeer
    self.readBlobWindow = readBlobWindow; self.stageBlobs = stageBlobs
    self.prepareIncoming = prepareIncoming; self.applyRemoteChange = applyRemoteChange
  }
}

/// The trusted transport's bounded committed reads share one serialized handle.
/// Every call rechecks admission and opens a fresh WAL snapshot. Keeping the
/// useful reader alive avoids checkpointing the entire WAL between dependency
/// windows; FULL commits and SQLite's normal automatic checkpoints are unchanged.
/// Replacing the underlying database requires a new transport, not an offer
/// from another workspace under the existing peer generation.
public actor NotebookTransportReader {
  private let session: NotebookReadSession

  public init(store: NotebookStore) { session = NotebookReadSession(store: store) }

  public func changes(after cursor: UInt64, limit: Int) throws -> [NotebookDurableChange] {
    try session.read { try $0.changeJournal(after: cursor, limit: limit) }
  }

  public func blobs(_ requests: [NotebookTransportBlobRequest]) throws -> [NotebookTransportBlobChunk] {
    try session.read { try $0.readBlobWindow(requests) }
  }
}

extension NotebookStore {
  /// One snapshot for up to sixteen hashes, never a
  /// whole large blob or a transaction held across transport suspension.
  public func readBlobWindow(_ requests: [NotebookTransportBlobRequest]) throws -> [NotebookTransportBlobChunk] {
    try NotebookTransportBlobWindow.validate(requests)
    return try readTransaction { store in
      var chunks: [NotebookTransportBlobChunk] = []
      var remaining = NotebookTransportLimits.maximumBlobWindowBytes
      for request in requests {
        let count = min(remaining, NotebookTransportLimits.maximumChunkBytes)
        guard let row = try store.currentSQL!.rows("SELECT length(data),COALESCE(substr(data,?,?),zeroblob(0)) FROM blobs WHERE hash=?",
          [.integer(request.offset + 1), .integer(Int64(count)), .text(request.hash)]).first,
          let size = row[0].integer, let data = row[1].blob else { throw NotebookStorageError.blobMissing(request.hash) }
        chunks.append(.init(hash: request.hash, offset: request.offset, totalBytes: size, data: data))
        remaining -= data.count
        if remaining == 0 || request.offset + Int64(data.count) < size { break }
      }
      try NotebookTransportBlobWindow.validate(chunks, for: requests)
      return chunks
    }
  }
}

public enum NotebookTransportCompletedBlob: Sendable {
  case bytes(hash: String, data: Data)
  case file(hash: String, url: URL, byteCount: Int64)
  public var hash: String {
    switch self { case .bytes(let hash, _), .file(let hash, _, _): hash }
  }
  public var byteCount: Int64 {
    switch self { case .bytes(_, let data): Int64(data.count); case .file(_, _, let count): count }
  }
}

/// One partial hash owns one temporary file; complete chunks stay bounded in
/// memory. A large blob never becomes a whole Data value; invalid length, offset
/// or final hash removes its disposable assembly.
public actor NotebookTransportBlobAssembly {
  private let directory: URL
  private var hash: String?
  private var totalBytes: Int64 = 0
  private var offset: Int64 = 0
  private var handle: FileHandle?
  private var hasher = SHA256()
  private var isClosed = false

  public init(stagingRoot: URL, generation: UUID) throws {
    directory = stagingRoot.appendingPathComponent(generation.uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
  }

  public func append(_ chunk: NotebookTransportBlobChunk, expectedHash: String, maximumBytes: Int64) throws -> NotebookTransportCompletedBlob? {
    do { return try appendChecked(chunk, expectedHash: expectedHash, maximumBytes: maximumBytes) }
    catch { cancel(); throw error }
  }

  private func appendChecked(_ chunk: NotebookTransportBlobChunk, expectedHash: String, maximumBytes: Int64) throws -> NotebookTransportCompletedBlob? {
    guard !isClosed else { throw NotebookTransportError.disconnected }
    guard NotebookTransportFraming.isSHA256(expectedHash), chunk.hash == expectedHash,
      chunk.totalBytes >= 0, chunk.totalBytes <= min(maximumBytes, NotebookTransportLimits.maximumBlobBytes),
      chunk.data.count <= NotebookTransportLimits.maximumChunkBytes,
      chunk.offset >= 0, chunk.offset <= chunk.totalBytes,
      Int64(chunk.data.count) <= chunk.totalBytes - chunk.offset,
      !chunk.data.isEmpty || chunk.totalBytes == 0
    else { throw NotebookTransportError.invalidBlob }
    if hash == nil {
      guard chunk.offset == 0 else { throw NotebookTransportError.unexpectedBlob }
      // An already complete bounded chunk needs no temporary write/read pair.
      // Large/partial material alone uses the one streaming file below.
      if chunk.totalBytes == chunk.data.count {
        let digest = SHA256.hash(data: chunk.data).map { String(format: "%02x", $0) }.joined()
        guard digest == expectedHash else { throw NotebookTransportError.invalidBlob }
        return .bytes(hash: expectedHash, data: chunk.data)
      }
      hash = expectedHash; totalBytes = chunk.totalBytes; offset = 0; hasher = SHA256()
      let file = directory.appendingPathComponent(expectedHash)
      guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
        throw NotebookTransportError.storageUnavailable
      }
      handle = try FileHandle(forWritingTo: file)
    }
    guard hash == expectedHash, chunk.totalBytes == totalBytes, chunk.offset == offset, let handle else {
      throw NotebookTransportError.unexpectedBlob
    }
    try Task.checkCancellation()
    try handle.write(contentsOf: chunk.data)
    hasher.update(data: chunk.data); offset += Int64(chunk.data.count)
    guard offset == totalBytes else { return nil }
    let file = directory.appendingPathComponent(expectedHash)
    // This is disposable assembly, not the durability boundary. The SQL blob
    // transaction fsyncs the verified bytes before content can be committed.
    // Fsyncing this temporary copy as well serializes every tiny dependency.
    try handle.close(); self.handle = nil; hash = nil
    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    guard digest == expectedHash else {
      try? FileManager.default.removeItem(at: file)
      throw NotebookTransportError.invalidBlob
    }
    return .file(hash: expectedHash, url: file, byteCount: totalBytes)
  }

  public func discardCompleted(_ blob: NotebookTransportCompletedBlob) throws {
    guard case .file(_, let file, _) = blob else { return }
    guard file.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else {
      throw NotebookTransportError.invalidBlob
    }
    try FileManager.default.removeItem(at: file)
  }

  public func cancel() {
    isClosed = true; try? handle?.close(); handle = nil; hash = nil
    try? FileManager.default.removeItem(at: directory)
  }
}

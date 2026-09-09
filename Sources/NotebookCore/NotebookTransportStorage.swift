import CryptoKit
import Foundation

/// App integration runs these closures on the existing persistence executor.
/// `applyRemoteChange` returns only after content, dedupe and incoming cursor
/// have committed together. Transport receipt never calls it speculatively.
public struct NotebookTransportStorage: Sendable {
  public var changes: @Sendable (UInt64, Int) async throws -> [NotebookDurableChange]
  public var incomingCursor: @Sendable (UUID) async throws -> UInt64
  public var acknowledgePeer: @Sendable (UUID, UInt64) async throws -> Void
  public var blobSize: @Sendable (String) async throws -> Int64
  public var readBlobChunk: @Sendable (String, Int64, Int) async throws -> Data
  public var stageBlob: @Sendable (URL, String, Int64) async throws -> Void
  public var missingBlobHashes: @Sendable (NotebookDurableChange, Int, String?) async throws -> [String]
  public var applyRemoteChange: @Sendable (NotebookDurableChange, UUID) async throws -> UInt64

  public init(
    changes: @escaping @Sendable (UInt64, Int) async throws -> [NotebookDurableChange],
    incomingCursor: @escaping @Sendable (UUID) async throws -> UInt64,
    acknowledgePeer: @escaping @Sendable (UUID, UInt64) async throws -> Void,
    blobSize: @escaping @Sendable (String) async throws -> Int64,
    readBlobChunk: @escaping @Sendable (String, Int64, Int) async throws -> Data,
    stageBlob: @escaping @Sendable (URL, String, Int64) async throws -> Void,
    missingBlobHashes: @escaping @Sendable (NotebookDurableChange, Int, String?) async throws -> [String],
    applyRemoteChange: @escaping @Sendable (NotebookDurableChange, UUID) async throws -> UInt64
  ) {
    self.changes = changes; self.incomingCursor = incomingCursor; self.acknowledgePeer = acknowledgePeer
    self.blobSize = blobSize; self.readBlobChunk = readBlobChunk; self.stageBlob = stageBlob
    self.missingBlobHashes = missingBlobHashes; self.applyRemoteChange = applyRemoteChange
  }
}

public struct NotebookTransportCompletedBlob: Sendable {
  public let hash: String
  public let file: URL
  public let byteCount: Int64
}

/// One requested hash owns one temporary file. Incoming chunks never become a
/// whole Data value; invalid length, offset or final hash removes that file.
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
    try handle.synchronize(); try handle.close(); self.handle = nil; hash = nil
    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    guard digest == expectedHash else {
      try? FileManager.default.removeItem(at: file)
      throw NotebookTransportError.invalidBlob
    }
    return NotebookTransportCompletedBlob(hash: expectedHash, file: file, byteCount: totalBytes)
  }

  public func discardCompleted(_ blob: NotebookTransportCompletedBlob) throws {
    guard blob.file.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else {
      throw NotebookTransportError.invalidBlob
    }
    try FileManager.default.removeItem(at: blob.file)
  }

  public func cancel() {
    isClosed = true; try? handle?.close(); handle = nil; hash = nil
    try? FileManager.default.removeItem(at: directory)
  }
}

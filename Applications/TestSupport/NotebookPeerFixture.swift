import Foundation
import NotebookCore
import XCTest
@testable import Notebook

/// A second isolated store authors genuine immutable manifests. The live app
/// receives only completed changes, through its production transport callback.
enum NotebookPeerFixture {
  static func stage(_ change: NotebookDurableChange, from source: NotebookStore, to destination: NotebookStore) throws {
    while true {
      let missing = try destination.missingBlobHashes(for: change, limit: 16)
      if missing.isEmpty { return }
      for hash in missing {
        let size = try source.blobSize(hash: hash)
        guard size <= 16_777_216 else { throw NotebookStorageError.limitExceeded("test fixture blob") }
        var bytes = Data()
        while bytes.count < size {
          let chunk = try source.readBlobChunk(hash: hash, offset: Int64(bytes.count), maxBytes: 1_048_576)
          guard !chunk.isEmpty else { throw NotebookStorageError.blobMissing(hash) }
          bytes.append(chunk)
        }
        try destination.stageBlob(data: bytes, expectedHash: hash)
      }
    }
  }

  static func copy(from source: NotebookStore, to destination: NotebookStore, peerID: UUID) throws {
    if !FileManager.default.fileExists(atPath: destination.databaseURL.path) {
      try destination.prepareEmptyWorkspace(workspaceID: source.workspaceHeader().workspaceID)
    }
    var cursor = try destination.peerCursor(peerID: peerID, direction: .incoming)
    while true {
      let changes = try source.changeJournal(after: cursor, limit: 16)
      if changes.isEmpty { return }
      for change in changes {
        try stage(change, from: source, to: destination)
        cursor = try destination.applyRemoteChange(change, peerID: peerID)
      }
    }
  }

  @MainActor
  static func deliver(from source: NotebookStore, to model: NotebookAppModel, peerID: UUID) async throws {
    var cursor = try model.store.peerCursor(peerID: peerID, direction: .incoming)
    while true {
      let changes = try source.changeJournal(after: cursor, limit: 16)
      if changes.isEmpty { return }
      for change in changes {
        try stage(change, from: source, to: model.store)
        cursor = try await model.applyDurablePeerChange(change, peerID: peerID)
        XCTAssertEqual(try model.store.peerCursor(peerID: peerID, direction: .incoming), cursor,
          "An acknowledgement exists only after the durable cursor and content commit")
      }
    }
  }
}

import CryptoKit
import Foundation

/// A portable program namespace owns exactly the blobs reachable from the
/// copied elements. Paths remain inside their canonical package manifests.
public struct NotebookProgramTransfer: Codable, Equatable, Sendable {
  public static let maximumBytes = 8 * 1_048_576
  public static let maximumPackages = 32
  public static let maximumPartReferences = 16_384
  public static let maximumManifestDecodeBytes = 64 * 1_048_576
  static let maximumBlobs = maximumPartReferences + maximumPackages
  static let readWindowBytes = 1_048_576

  public struct Blob: Codable, Equatable, Sendable {
    public let sha256: String
    public let data: Data
    public init(sha256: String, data: Data) { self.sha256 = sha256; self.data = data }
  }
  public let packageHashes: [String]
  public let blobs: [Blob]

  public init(packageHashes: [String], blobs: [Blob]) {
    self.packageHashes = packageHashes; self.blobs = blobs
  }

  /// Constructed only after the complete portable closure has been admitted.
  /// It travels with the ordinary accepted paste; it owns no execution/retry.
  public struct Prepared: Sendable {
    public let packageHashes: [String]
    public let byteCount: Int
    public let manifestDecodeBytes: Int
    fileprivate let blobs: [Blob]
    fileprivate init(packageHashes: [String], blobs: [Blob], byteCount: Int, manifestDecodeBytes: Int) {
      self.packageHashes = packageHashes; self.blobs = blobs
      self.byteCount = byteCount; self.manifestDecodeBytes = manifestDecodeBytes
    }

    func validate(operations: [CollaborationOperation]) throws {
      guard (1...32).contains(operations.count), operations.allSatisfy({
        $0.kind == .insertElement && [.page, .board, .cover].contains($0.target.kind)
      }) else { throw NotebookProgramTransfer.refusal("Ресурсы программы принадлежат вставке элементов.") }
      var roots: Set<String> = []
      for operation in operations {
        guard let value = operation.values["programPackage"], value != .null else { continue }
        guard let hash = value.string, NotebookProgramPackage.validHash(hash) else {
          throw NotebookProgramTransfer.refusal("Неверный пакет программы в команде вставки.")
        }
        roots.insert(hash)
      }
      guard roots == Set(packageHashes) else {
        throw NotebookProgramTransfer.refusal("Ресурсы не совпадают с программами вставляемого фрагмента.")
      }
    }

    /// Borrow the existing command transaction. A same-hash destination row
    /// must contain these exact bytes before INSERT OR IGNORE may reuse it.
    func stage(in store: NotebookStore) throws {
      guard let database = store.currentSQL, database.writable else { throw NotebookStorageError.readOnlyTransaction }
      let roots = Set(packageHashes)
      for manifest in [false, true] {
        for blob in blobs where roots.contains(blob.sha256) == manifest {
          if let size = try database.rows("SELECT length(data) FROM blobs WHERE hash=?", [.text(blob.sha256)]).first?[0].integer {
            guard size == blob.data.count else {
              throw NotebookProgramTransfer.refusal("Сохранённый ресурс программы повреждён.")
            }
            var offset = 0
            while offset < blob.data.count {
              let end = min(offset + NotebookProgramTransfer.readWindowBytes, blob.data.count)
              let existing = try store.readBlobChunk(hash: blob.sha256, offset: Int64(offset), maxBytes: end - offset)
              let startIndex = blob.data.startIndex + offset
              guard existing == blob.data[startIndex..<(blob.data.startIndex + end)] else {
                throw NotebookProgramTransfer.refusal("Сохранённый ресурс программы повреждён.")
              }
              offset = end
            }
          } else { try store.stageBlob(data: blob.data, expectedHash: blob.sha256) }
        }
      }
    }
  }

  public func prepare(packageHashes expected: [String]) throws -> Prepared {
    guard packageHashes.count <= Self.maximumPackages, expected.count <= Self.maximumPackages,
      blobs.count <= Self.maximumBlobs else { throw Self.refusal("Фрагмент содержит слишком много пакетов или ресурсов.") }
    let roots = Set(packageHashes)
    guard roots.count == packageHashes.count, roots == Set(expected), roots.allSatisfy(NotebookProgramPackage.validHash) else {
      throw Self.refusal("Пакеты не совпадают с программами переносимого фрагмента.")
    }
    var byHash: [String: Blob] = [:], byteCount = 0
    for blob in blobs {
      try Task.checkCancellation()
      guard NotebookProgramPackage.validHash(blob.sha256), !blob.data.isEmpty,
        blob.data.count <= NotebookProgramPackage.partBytes,
        blob.data.count <= Self.maximumBytes - byteCount,
        byHash.updateValue(blob, forKey: blob.sha256) == nil else {
        throw Self.refusal("Ресурсы фрагмента повторяются или превышают предел 8 MiB.")
      }
      byteCount += blob.data.count
    }
    var decodeBytes = 0, packages: [String: NotebookProgramPackage] = [:], manifestSizes: [String: Int] = [:]
    for hash in roots.sorted() {
      guard let blob = byHash[hash] else { throw Self.refusal("В буфере нет manifest программы.") }
      packages[hash] = try Self.decodeManifest(blob.data, hash: hash, decodeBytes: &decodeBytes)
      manifestSizes[hash] = blob.data.count
    }
    let required = try Self.requiredBlobSizes(packages: packages, manifestSizes: manifestSizes)
    guard Set(required.keys) == Set(byHash.keys) else {
      throw Self.refusal("В буфере отсутствуют ресурсы программы или есть посторонние blobs.")
    }
    for (hash, size) in required {
      try Task.checkCancellation()
      let blob = byHash[hash]!
      guard blob.data.count == size, roots.contains(hash) || NotebookProgramPackage.hash(blob.data) == hash else {
        throw Self.refusal("Байты ресурса не совпадают с SHA-256 и длиной из manifest.")
      }
    }
    return .init(packageHashes: roots.sorted(), blobs: blobs.sorted { $0.sha256 < $1.sha256 },
      byteCount: byteCount, manifestDecodeBytes: decodeBytes)
  }

  fileprivate static func refusal(_ message: String) -> CollaborationError {
    .init("incomplete_fragment", message)
  }

  fileprivate static func decodeManifest(_ data: Data, hash: String, decodeBytes: inout Int) throws -> NotebookProgramPackage {
    guard (1...NotebookProgramPackage.maximumManifestBytes).contains(data.count) else {
      throw refusal("Manifest программы превышает предел 1 MiB.")
    }
    do {
      decodeBytes += try NotebookJSONAdmission.allocationCost(data, maximumBytes: maximumManifestDecodeBytes - decodeBytes)
      return try NotebookProgramPackage.decodeCanonicalData(data, expectedHash: hash)
    } catch is CancellationError { throw CancellationError() }
    catch { throw refusal("Manifest программы повреждён или превышает предел памяти.") }
  }

  fileprivate static func requiredBlobSizes(packages: [String: NotebookProgramPackage], manifestSizes: [String: Int]) throws -> [String: Int] {
    var sizes = manifestSizes, references = 0
    for package in packages.values {
      for file in package.files {
        guard file.parts.count <= maximumPartReferences - references else {
          throw refusal("Программы фрагмента содержат слишком много частей.")
        }
        references += file.parts.count
        for part in file.parts {
          if let size = sizes[part.sha256], size != part.byteCount {
            throw refusal("Один SHA-256 назван с разной длиной ресурса.")
          }
          sizes[part.sha256] = part.byteCount
        }
      }
    }
    var bytes = 0
    for size in sizes.values {
      guard size <= maximumBytes - bytes else { throw refusal("Ресурсы фрагмента превышают предел 8 MiB.") }
      bytes += size
    }
    return sizes
  }
}

extension NotebookStore {
  /// The element transfer supplies these authored roots while holding its one
  /// SQL source cut. No paths, display windows, or hash-looking state are read.
  func readProgramTransfer(packageHashes: [String]) throws -> NotebookProgramTransfer? {
    guard packageHashes.count <= NotebookProgramTransfer.maximumPackages else {
      throw NotebookProgramTransfer.refusal("Выделение содержит слишком много программ.")
    }
    let roots = Set(packageHashes)
    guard !roots.isEmpty else { return nil }
    guard roots.count <= NotebookProgramTransfer.maximumPackages,
      roots.allSatisfy(NotebookProgramPackage.validHash), currentSQL != nil else {
      throw NotebookProgramTransfer.refusal("Не удалось прочитать пакеты выделенных программ.")
    }
    func sizes(_ hashes: [String]) throws -> [String: Int] {
      var result: [String: Int] = [:], offset = 0
      while offset < hashes.count {
        try Task.checkCancellation()
        let batch = Array(hashes[offset..<min(offset + 64, hashes.count)])
        let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
        for row in try currentSQL!.rows("SELECT hash,length(data) FROM blobs WHERE hash IN (\(placeholders))", batch.map { .text($0) }) {
          guard let size = row[1].integer, size > 0, size <= NotebookProgramPackage.partBytes else {
            throw NotebookProgramTransfer.refusal("Ресурс программы повреждён или превышает предел части.")
          }
          result[row[0].text!] = Int(size)
        }
        offset += batch.count
      }
      guard result.count == hashes.count else { throw NotebookProgramTransfer.refusal("Не хватает ресурсов выделенной программы.") }
      return result
    }
    func read(_ hash: String, size: Int) throws -> Data {
      var data = Data(), digest = SHA256(), offset = 0
      data.reserveCapacity(size)
      while offset < size {
        try Task.checkCancellation()
        let count = min(NotebookProgramTransfer.readWindowBytes, size - offset)
        let chunk = try readBlobChunk(hash: hash, offset: Int64(offset), maxBytes: count)
        guard chunk.count == count else { throw NotebookProgramTransfer.refusal("Не удалось прочитать ресурс программы целиком.") }
        digest.update(data: chunk); data.append(chunk); offset += count
      }
      guard NotebookHexEncoding.encode(digest.finalize()) == hash else {
        throw NotebookProgramTransfer.refusal("SHA-256 сохранённого ресурса программы не совпадает с его байтами.")
      }
      return data
    }
    let manifestSizes = try sizes(roots.sorted())
    var admittedBytes = 0
    for size in manifestSizes.values {
      guard size <= NotebookProgramPackage.maximumManifestBytes,
        size <= NotebookProgramTransfer.maximumBytes - admittedBytes else {
        throw NotebookProgramTransfer.refusal("Manifest программ фрагмента превышают предел размера.")
      }
      admittedBytes += size
    }
    var blobs: [String: NotebookProgramTransfer.Blob] = [:], packages: [String: NotebookProgramPackage] = [:], decodeBytes = 0
    for hash in roots.sorted() {
      let data = try read(hash, size: manifestSizes[hash]!)
      packages[hash] = try NotebookProgramTransfer.decodeManifest(data, hash: hash, decodeBytes: &decodeBytes)
      blobs[hash] = .init(sha256: hash, data: data)
    }
    let required = try NotebookProgramTransfer.requiredBlobSizes(packages: packages, manifestSizes: manifestSizes)
    let remaining = required.keys.filter { !roots.contains($0) }.sorted()
    let storedSizes = try sizes(remaining)
    for hash in remaining {
      guard storedSizes[hash] == required[hash] else { throw NotebookProgramTransfer.refusal("Длина сохранённого ресурса не совпадает с manifest.") }
    }
    for hash in remaining { blobs[hash] = .init(sha256: hash, data: try read(hash, size: required[hash]!)) }
    return .init(packageHashes: roots.sorted(), blobs: blobs.values.sorted { $0.sha256 < $1.sha256 })
  }
}

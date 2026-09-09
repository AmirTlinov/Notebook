import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import NotebookCore
import UniformTypeIdentifiers

/// Disposable derivatives, never notebook authority. A bounded record binds
/// one exact tile key to a SHA-256-checked PNG. The shared resource owner still
/// reserves the decoded image before a disk hit is allowed to allocate pixels.
actor SceneCompositionTileCache {
  static let maximumRecordBytes = 2 * 1_024 * 1_024
  private let root: URL
  private let byteLimit: Int
  private let entryLimit: Int
  private struct Record: Codable {
    let format: Int
    let key: SceneCompositionTileKey
    let digest: String
    let png: Data
  }
  init(root: URL, byteLimit: Int = 512 * 1_024 * 1_024, entryLimit: Int = 512) {
    self.root = root; self.byteLimit = max(0, byteLimit); self.entryLimit = max(0, entryLimit)
  }
  func load(_ key: SceneCompositionTileKey) throws -> CGImage? {
    try Task.checkCancellation()
    let url = try file(key)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    do {
      let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
      guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
        let size = attributes.fileSize, size > 0, size <= Self.maximumRecordBytes else { throw SceneRenderError.resourceLimit }
      let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
      guard record.format == 1, record.key == key, record.digest == Self.hash(record.png),
        let source = CGImageSourceCreateWithData(record.png as CFData, nil),
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
        properties[kCGImagePropertyPixelWidth] as? Int == CompositionTile.pixelSize,
        properties[kCGImagePropertyPixelHeight] as? Int == CompositionTile.pixelSize,
        let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil),
        let context = CGContext(data: nil, width: 512, height: 512, bitsPerComponent: 8,
          bytesPerRow: 512 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { throw SceneRenderError.snapshotPending("cached_tile") }
      // Force decoding into the charged pixel buffer; the returned CGImage does
      // not retain a lazy unaccounted PNG payload behind its provider.
      context.draw(decoded, in: CGRect(x: 0, y: 0, width: 512, height: 512))
      guard let image = context.makeImage() else { throw SceneRenderError.resourceLimit }
      try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
      try Task.checkCancellation()
      return image
    } catch is CancellationError { throw CancellationError() }
    catch { try? FileManager.default.removeItem(at: url); return nil }
  }
  func store(_ image: CGImage, for key: SceneCompositionTileKey) throws {
    try Task.checkCancellation()
    guard image.width == 512, image.height == 512, entryLimit > 0 else { return }
    let png = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination), png.length <= Self.maximumRecordBytes else { return }
    let data = try JSONEncoder().encode(Record(format: 1, key: key, digest: Self.hash(png as Data), png: png as Data))
    guard data.count <= Self.maximumRecordBytes, data.count <= byteLimit else { return }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try Task.checkCancellation()
    try data.write(to: file(key), options: .atomic)
    try trim()
  }
  private func trim() throws {
    let files = try FileManager.default.contentsOfDirectory(at: root,
      includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]).filter { $0.pathExtension == "tile" }
    let entries = try files.map { url -> (URL, Int, Date) in
      let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
      return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
    }.sorted { $0.2 < $1.2 }
    var count = entries.count, bytes = entries.reduce(0) { $0 + $1.1 }
    for (url, size, _) in entries where count > entryLimit || bytes > byteLimit {
      try FileManager.default.removeItem(at: url); count -= 1; bytes -= size
    }
  }
  private func file(_ key: SceneCompositionTileKey) throws -> URL {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return root.appendingPathComponent(Self.hash(try encoder.encode(key)) + ".tile")
  }
  private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

import CryptoKit
import Foundation
import ImageIO
import NotebookCore
import UniformTypeIdentifiers

/// Pixels from an already-authorized Notebook renderer, not a filename or an external image URL.
struct NotebookAgentImage: Sendable, Equatable {
  static let maximumPNGBytes = 2 * 1_048_576
  static let maximumPixels = 4_194_304
  let png: Data
  let sha256: String
  let pixelWidth: Int
  let pixelHeight: Int
  let mimeType: String

  init(png: Data, sha256: String, pixelWidth: Int, pixelHeight: Int, mimeType: String = "image/png") throws {
    guard mimeType == "image/png", (1...4096).contains(pixelWidth), (1...4096).contains(pixelHeight),
          pixelWidth * pixelHeight <= Self.maximumPixels, (45...Self.maximumPNGBytes).contains(png.count),
          png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]), sha256.utf8.count == 64,
          sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
          SHA256.hash(data: png).map({ String(format: "%02x", $0) }).joined() == sha256 else {
      throw NotebookAgentFailure.invalidImage
    }
    let options = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithData(png as CFData, options),
          CGImageSourceGetType(source) as String? == UTType.png.identifier,
          CGImageSourceGetCount(source) == 1, CGImageSourceGetStatus(source) == .statusComplete,
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
          let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
          width.intValue == pixelWidth, height.intValue == pixelHeight else {
      throw NotebookAgentFailure.invalidImage
    }
    // Dimensions are checked before decoding; malformed/truncated PNG bytes cannot become a vision receipt.
    let decode = [kCGImageSourceShouldCache: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary
    guard let decoded = CGImageSourceCreateImageAtIndex(source, 0, decode),
          decoded.width == pixelWidth, decoded.height == pixelHeight else { throw NotebookAgentFailure.invalidImage }
    self.png = png; self.sha256 = sha256; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.mimeType = mimeType
  }

  var contentItem: JSONValue {
    .object(["type": .string("inputImage"), "imageUrl": .string("data:image/png;base64," + png.base64EncodedString())])
  }
}

struct NotebookAgentToolResult: Sendable, Equatable {
  let value: JSONValue
  let images: [NotebookAgentImage]

  init(value: JSONValue, images: [NotebookAgentImage] = []) {
    self.value = value; self.images = images
  }

  func contentItems() throws -> [JSONValue] {
    let bytes = try JSONEncoder().encode(value)
    guard bytes.count <= 4 * 1_048_576, images.count <= 4,
          images.reduce(0, { $0 + $1.png.count }) <= 4 * 1_048_576 else { throw NotebookAgentFailure.messageLimit }
    let items: [JSONValue] = [.object(["type": .string("inputText"), "text": .string(String(decoding: bytes, as: UTF8.self))])]
      + images.map(\.contentItem)
    // Account for base64 expansion and JSON before entering the bounded stdio writer.
    guard try JSONEncoder().encode(items).count <= 8 * 1_048_576 - 4096 else { throw NotebookAgentFailure.messageLimit }
    return items
  }
}

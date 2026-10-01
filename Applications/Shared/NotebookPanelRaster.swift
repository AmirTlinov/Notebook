import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import NotebookCore

/// Transport for completed native artwork. It carries placement, not a second
/// scene model; the receiving panel may move only independently granted bodies.
struct NotebookPanelRasterLayer {
  let id: String
  let order: Int
  let worldOrigin: WorldPoint
  let frame: PageRect
  let png: Data
  let elementID: String?
  let pixelWidth: Int
  let pixelHeight: Int

  init(id: String, order: Int, worldOrigin: WorldPoint, frame: PageRect, png: Data,
    elementID: String? = nil) throws {
    guard let image = CGImageSourceCreateWithData(png as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
      let values = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
      let width = values[kCGImagePropertyPixelWidth] as? Int,
      let height = values[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else {
      throw SceneRenderError.snapshotPending("panel_pixels")
    }
    self.id = id; self.order = order; self.worldOrigin = worldOrigin; self.frame = frame
    self.png = png; self.elementID = elementID; pixelWidth = width; pixelHeight = height
  }

  var encoded: JSONValue {
    get throws {
      var value: [String: JSONValue] = ["id": .string(id), "order": .number(Double(order)),
        "worldOrigin": try .encode(worldOrigin), "frame": try .encode(frame),
        "pixelWidth": .number(Double(pixelWidth)), "pixelHeight": .number(Double(pixelHeight)),
        "pngBase64": .string(png.base64EncodedString()),
        "sha256": .string(SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined())]
      if let elementID { value["elementID"] = .string(elementID) }
      return .object(value)
    }
  }
}

/// Encoding is bounded before base64 allocation. Native raster reservations
/// remain authoritative, and one output is released before the next is painted.
struct NotebookPanelRasterSet {
  private(set) var layers: [NotebookPanelRasterLayer] = []
  private var byteCount = 0
  private var pixelCount = 0
  mutating func append(_ layer: NotebookPanelRasterLayer) throws {
    let bytes = byteCount + ((layer.png.count + 2) / 3) * 4
    let pixels = pixelCount + layer.pixelWidth * layer.pixelHeight
    guard layers.count < 40, bytes <= 12 * 1024 * 1024, pixels <= NotebookPanelRenderProjection.maximumDecodedPixels else {
      throw SceneRenderError.resourceLimit
    }
    byteCount = bytes; pixelCount = pixels; layers.append(layer)
  }
}

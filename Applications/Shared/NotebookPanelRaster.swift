import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import NotebookCore

/// Completed native artwork and placement. Known immutable pool entries carry
/// no encoded bytes; camera motion never makes another business scene model.
struct NotebookPanelRasterLayer {
  let id: String
  let order: Int
  let worldOrigin: WorldPoint
  let frame: PageRect
  let assetID: UUID
  let png: Data?
  let elementID: String?
  let itemID: UUID?
  let subjectFrame: PageRect?
  let repeatSize: CGSize?
  let pixelWidth: Int
  let pixelHeight: Int

  func withOrder(_ order: Int) -> Self {
    .init(id: id, order: order, worldOrigin: worldOrigin, frame: frame, assetID: assetID,
      png: png, elementID: elementID, itemID: itemID, subjectFrame: subjectFrame,
      repeatSize: repeatSize, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
  }

  @MainActor
  static func completed(id: String, order: Int, worldOrigin: WorldPoint, frame: PageRect,
    raster: RasterLease, knownAssets: Set<UUID>, elementID: String? = nil, itemID: UUID? = nil,
    subjectFrame: PageRect? = nil, repeatSize: CGSize? = nil) async throws -> Self {
    guard let image = raster.sampledImage(for: .init(width: Double.greatestFiniteMagnitude, height: Double.greatestFiniteMagnitude))
    else { throw SceneRenderError.snapshotPending("panel_pixels") }
    let png = knownAssets.contains(raster.entryID) ? nil : try await CompositionPixels.encodePNG(image)
    return .init(id: id, order: order, worldOrigin: worldOrigin, frame: frame, assetID: raster.entryID,
      png: png, elementID: elementID, itemID: itemID, subjectFrame: subjectFrame, repeatSize: repeatSize,
      pixelWidth: image.width, pixelHeight: image.height)
  }

  var encoded: JSONValue {
    get throws {
      var value: [String: JSONValue] = ["id": .string(id), "order": .number(Double(order)),
        "worldOrigin": try .encode(worldOrigin), "frame": try .encode(frame), "assetID": try .encode(assetID),
        "pixelWidth": .number(Double(pixelWidth)), "pixelHeight": .number(Double(pixelHeight))]
      if let png {
        value["pngBase64"] = .string(png.base64EncodedString())
        value["sha256"] = .string(SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined())
      }
      if let elementID { value["elementID"] = .string(elementID) }
      if let itemID { value["itemID"] = try .encode(itemID) }
      if let subjectFrame { value["subjectFrame"] = try .encode(subjectFrame) }
      if let repeatSize {
        value["repeatSize"] = .object(["width": .number(Double(repeatSize.width)), "height": .number(Double(repeatSize.height))])
      }
      return .object(value)
    }
  }
}

/// The shared pool owns pixel residency. Transport admits one finite material
/// cohort and counts every image even when the browser already owns its bytes.
struct NotebookPanelRasterSet {
  private(set) var layers: [NotebookPanelRasterLayer] = []
  private var byteCount = 0
  private var pixelCount = 0
  mutating func append(_ layer: NotebookPanelRasterLayer) throws {
    let bytes = byteCount + (((layer.png?.count ?? 0) + 2) / 3) * 4
    let pixels = pixelCount + layer.pixelWidth * layer.pixelHeight
    guard layers.count < 96, bytes <= 12 * 1024 * 1024, pixels <= NotebookPanelRenderProjection.maximumDecodedPixels else {
      throw SceneRenderError.resourceLimit
    }
    byteCount = bytes; pixelCount = pixels; layers.append(layer)
  }
}

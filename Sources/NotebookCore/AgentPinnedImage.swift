import Foundation
import CryptoKit

/// Final regional pixels of the immutable source considered by one question.
/// This is source evidence, not a certificate that the iPad presented a frame.
public struct AgentPinnedImage: Codable, Equatable, Sendable {
  public let referenceID: UUID
  public let sourceRevision: String
  public let region: PageRect
  public let worldOrigin: WorldPoint?
  public let pageIndex: Int?
  public let pixelWidth: Int
  public let pixelHeight: Int
  public let pixelsPerPoint: Double
  public let png: Data
  public let sha256: String

  public init(referenceID: UUID, sourceRevision: String, region: PageRect,
    worldOrigin: WorldPoint?, pageIndex: Int?, pixelWidth: Int, pixelHeight: Int,
    pixelsPerPoint: Double, png: Data, sha256: String) throws {
    self.referenceID = referenceID; self.sourceRevision = sourceRevision
    self.region = region; self.worldOrigin = worldOrigin; self.pageIndex = pageIndex
    self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
    self.pixelsPerPoint = pixelsPerPoint; self.png = png; self.sha256 = sha256
    try validate()
  }

  public func validate(reference: CollaborationReference? = nil) throws {
    guard (33...2_097_152).contains(png.count), (1...4096).contains(pixelWidth), (1...4096).contains(pixelHeight),
      pixelWidth <= 4_000_000 / pixelHeight,
      pixelsPerPoint.isFinite, pixelsPerPoint > 0,
      region.x.isFinite, region.y.isFinite, region.width.isFinite, region.height.isFinite,
      region.width > 0, region.height > 0, worldOrigin?.isValid != false,
      (pageIndex ?? 0) >= 0,
      Array(png.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10],
      String(data: png.subdata(in: 12..<16), encoding: .ascii) == "IHDR",
      sourceRevision.utf8.count <= 256, !sourceRevision.isEmpty else { throw invalid() }
    func dimension(_ offset: Int) -> Int {
      png[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
    }
    guard dimension(16) == pixelWidth, dimension(20) == pixelHeight,
      SHA256.hash(data: png).map({ String(format: "%02x", $0) }).joined() == sha256 else { throw invalid() }
    if let reference {
      guard reference.id == referenceID, reference.revision == sourceRevision,
        reference.region == region, reference.worldOrigin == worldOrigin, reference.pageIndex == pageIndex else { throw invalid() }
    }
  }
  private func invalid() -> CollaborationError {
    .init("invalid_request_image", "Изображение не удостоверяет закреплённую область либо превышает допустимый размер.")
  }
}

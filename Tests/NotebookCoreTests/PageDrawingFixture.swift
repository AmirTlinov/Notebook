import CryptoKit
import Foundation
@testable import NotebookCore

/// Persistence tests carry a deterministic valid stroke, rather than arbitrary
/// bytes that no production ink decoder can read.
func pageDrawingFixture(_ marker: Data) -> Data {
  let digest = Array(SHA256.hash(data: marker)), id = UUID(uuid: (digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7], digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]))
  let sample = SpatialInkSample(point: .init(x: Double(digest[16]) + 1, y: Double(digest[17]) + 1),
    timeOffset: 0, width: 2, opacity: 1, force: 0.5, azimuth: 0, altitude: 1)
  let action = PageInkAction(id: id, tool: .pen, samples: [sample], sequence: 1)
  return try! PageInkDrawing(actions: [action]).dataRepresentation()
}

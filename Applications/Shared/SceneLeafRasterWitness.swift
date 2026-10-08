import Foundation
import NotebookCore

/// One immutable leaf entry. Publication order is the pool's existing clock;
/// cache access, composition and eviction do not publish new leaf pixels.
struct SceneLeafRasterPublication: Equatable, Sendable {
  let entryID: UUID
  let source: SceneRasterSource
  let pixelScale: Double
  let publication: UInt64
  var captureRegion: PageRect? { source.captureRegion }

  init?(entryID: UUID, source: SceneRasterSource, pixelScale: Double, publication: UInt64) {
    guard source.isLeafRaster, pixelScale.isFinite, pixelScale > 0 else { return nil }
    self.entryID = entryID; self.source = source; self.pixelScale = pixelScale; self.publication = publication
  }
}

extension SceneRasterSource {
  var isLeafRaster: Bool {
    switch self { case .agent, .agentRegion, .document: true; case .composition, .material: false }
  }
}

/// The pixels actually used and an optional missing sharper/current source.
/// Values retain source identity, never a pixel lease or encoded backing.
enum SceneLeafRasterWitness: Equatable, Sendable {
  case pixels(SceneLeafRasterPublication)
  case missing(source: SceneRasterSource, minimumScale: Double, afterPublication: UInt64)

  func isAffected(by event: SceneLeafRasterPublication) -> Bool {
    switch self {
    case .pixels(let used):
      event.publication > used.publication && event.entryID != used.entryID
        && event.source == used.source && event.pixelScale + 0.000_001 >= used.pixelScale
    case .missing(let source, let minimumScale, let afterPublication):
      event.publication > afterPublication && event.source == source
        && event.pixelScale + 0.000_001 >= minimumScale
    }
  }
}

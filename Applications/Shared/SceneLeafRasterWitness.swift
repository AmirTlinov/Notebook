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

/// A finite preparation lifetime covers publications across painter awaits,
/// including a leaf borrowed later through an already composed entry. It owns
/// no source history beyond this one request and never keeps raster bytes alive.
@MainActor
final class SceneLeafRasterWitnessCollector {
  static let maximumPendingPublications = 96
  private let resources: SceneRenderResources
  private var observer: NSObjectProtocol?
  private var publications: [SceneLeafRasterPublication] = []
  private var pixelEntries: Set<UUID> = []
  private var invalidated = false
  private(set) var witnesses: [SceneLeafRasterWitness] = []

  init(resources: SceneRenderResources = .shared) {
    self.resources = resources
    let publicationKey = SceneRenderResources.leafRasterPublicationKey
    observer = NotificationCenter.default.addObserver(forName: SceneRenderResources.didPublishLeafRaster,
      object: nil, queue: .main) { [weak self] notification in
        guard let sender = notification.object as? SceneRenderResources,
          let event = notification.userInfo?[publicationKey] as? SceneLeafRasterPublication else { return }
        MainActor.assumeIsolated {
          guard let self, sender === self.resources else { return }
          self.receive(event)
        }
      }
  }

  func record(_ values: [SceneLeafRasterWitness]) {
    // Latch availability now: those pixels may be evicted before the next
    // checkpoint, and the pool intentionally retains no publication history.
    if !resources.leafRastersAreCurrent(values) { invalidated = true }
    for witness in values {
      if case .pixels(let used) = witness, !pixelEntries.insert(used.entryID).inserted { continue }
      witnesses.append(witness)
      if publications.contains(where: { witness.isAffected(by: $0) }) { invalidated = true }
    }
  }

  var isCurrent: Bool { !invalidated && resources.leafRastersAreCurrent(witnesses) }

  private func receive(_ event: SceneLeafRasterPublication) {
    if witnesses.contains(where: { $0.isAffected(by: event) }) { invalidated = true }
    // Unknown future borrows may refer to an older composed entry. Overflow
    // cannot silently turn an incomplete publication history into a valid cut.
    guard publications.count < Self.maximumPendingPublications else { invalidated = true; return }
    publications.append(event)
  }

  func close() {
    if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
    publications.removeAll()
  }
  isolated deinit { close() }
}

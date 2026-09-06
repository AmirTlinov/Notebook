import Foundation
import NotebookCore
import PencilKit

/// Vertices stay near their physical origin. Camera motion changes one uniform
/// per span, never the measured samples or triangle buffers.
struct SpatialInkMesh: Sendable {
  enum Projection: Equatable, Sendable {
    case local
    case world(WorldPoint)
    case screen(SpatialCamera, SpatialPoint)

    func transform(camera: SpatialCamera?, viewport: SpatialPoint) -> SIMD4<Float> {
      guard let camera else { return .init(1, 1, 0, 0) }
      switch self {
      case .local: return .init(1, 1, 0, 0)
      case .world(let origin):
        let point = camera.worldToScreen(origin, viewport: viewport)
        return .init(Float(camera.scale), Float(camera.scale), Float(point.x), Float(point.y))
      case .screen(let source, let sourceViewport):
        let origin = source.screenToWorld(.init(x: 0, y: 0), viewport: sourceViewport)
        let point = camera.worldToScreen(origin, viewport: viewport)
        let scale = Float(camera.scale / source.scale)
        return .init(scale, scale, Float(point.x), Float(point.y))
      }
    }
  }

  struct Batch: Sendable {
    let tool: SpatialInkTool
    var vertices: [SpatialInkGeometry.Vertex]
    let projection: Projection
  }
  let batches: [Batch]

  static func local(_ layers: [SpatialInkRenderLayer]) -> Self {
    .init(batches: layers.map { layer in
      var vertices: [SpatialInkGeometry.Vertex] = []
      let tool: SpatialInkTool
      switch layer {
      case .ink(let points, let color):
        tool = .pen
        SpatialInkGeometry.appendStrokeVertices(points: points,
          color: .init(Float(color.red), Float(color.green), Float(color.blue), 1), to: &vertices)
      case .erase(let points):
        tool = .eraser
        SpatialInkGeometry.appendStrokeVertices(points: points, color: .init(1, 1, 1, 1), to: &vertices)
      }
      return .init(tool: tool, vertices: vertices, projection: .local)
    })
  }

  static func prepare(surface: SurfaceID, journal: SpatialInkJournal?) throws -> Self {
    var batches: [Batch] = []
    for action in journal?.actions ?? [] where action.isActive {
      try Task.checkCancellation()
      for span in action.spans where span.surface == surface {
        let origin = span.samples.first?.worldPoint.map {
          WorldPoint(tileX: $0.tileX, tileY: $0.tileY, localX: 0, localY: 0)
        }
        let points = span.samples.map { sample in
          let local = origin.flatMap { start in sample.worldPoint.map { start.delta(to: $0) } } ?? sample.point
          return PKStrokePoint(location: .init(x: local.x, y: local.y), timeOffset: sample.timeOffset,
            size: .init(width: sample.width, height: sample.width), opacity: sample.opacity,
            force: sample.force, azimuth: sample.azimuth, altitude: sample.altitude)
        }
        var vertices: [SpatialInkGeometry.Vertex] = []
        let color = action.color
        SpatialInkGeometry.appendStrokeVertices(points: points,
          color: action.tool == .pen ? .init(Float(color.red), Float(color.green), Float(color.blue), 1) : .init(1, 1, 1, 1),
          to: &vertices)
        let projection = origin.map(Projection.world) ?? .local
        if let index = batches.indices.last, batches[index].tool == action.tool, batches[index].projection == projection {
          batches[index].vertices.append(contentsOf: vertices)
        } else {
          batches.append(.init(tool: action.tool, vertices: vertices, projection: projection))
        }
      }
    }
    return .init(batches: batches)
  }
}

/// Ready geometry belongs to its physical surface and exact source, not to the
/// preview or active canvas mounting it. Both use the same bounded cache.
@MainActor
final class SpatialInkMeshCache {
  static let shared = SpatialInkMeshCache()
  fileprivate struct ActionVersion: Equatable, Sendable {
    let id: UUID
    let stamp: VersionStamp
    let state: VersionStamp
  }
  fileprivate struct Entry: Sendable {
    let journal: SpatialInkJournal?
    let versions: [ActionVersion]
    let mesh: SpatialInkMesh
    let cost: Int
    var access: UInt64
  }
  private let capacity: Int
  private let byteLimit: Int
  private var entries: [SurfaceID: Entry] = [:]
  private var clock: UInt64 = 0
  private(set) var retainedBytes = 0
  var count: Int { entries.count }

  init(capacity: Int = 16, byteLimit: Int = 64 * 1024 * 1024) {
    self.capacity = max(0, capacity)
    self.byteLimit = max(0, byteLimit)
  }

  fileprivate func entry(for surface: SurfaceID) -> Entry? {
    guard var entry = entries[surface] else { return nil }
    clock &+= 1; entry.access = clock; entries[surface] = entry
    return entry
  }

  fileprivate func store(_ mesh: SpatialInkMesh, versions: [ActionVersion],
    surface: SurfaceID, journal: SpatialInkJournal?) {
    if let old = entries.removeValue(forKey: surface) { retainedBytes -= old.cost }
    let vertices = mesh.batches.reduce(0) { $0 + $1.vertices.count }
    let samples = journal?.actions.reduce(0) { total, action in
      total + action.spans.reduce(0) { $0 + $1.samples.count }
    } ?? 0
    // Count retained source storage too; shared Swift arrays only reduce the
    // real cost. One oversized surface is used by its canvas but not retained.
    let cost = vertices * MemoryLayout<SpatialInkGeometry.Vertex>.stride
      + samples * MemoryLayout<SpatialInkSample>.stride
      + (journal?.actions.count ?? 0) * MemoryLayout<SpatialInkAction>.stride
    guard capacity > 0, cost <= byteLimit else { return }
    while entries.count >= capacity || retainedBytes + cost > byteLimit {
      guard let oldest = entries.min(by: { $0.value.access < $1.value.access }) else { break }
      retainedBytes -= oldest.value.cost; entries.removeValue(forKey: oldest.key)
    }
    clock &+= 1
    entries[surface] = Entry(journal: journal, versions: versions, mesh: mesh, cost: cost, access: clock)
    retainedBytes += cost
  }
}

/// Cold revisions prepare off the main actor. A portal handoff installs the
/// exact warm mesh synchronously, before any frame can show the former owner.
@MainActor
final class SpatialInkMeshPreparation {
  private let cache: SpatialInkMeshCache
  private var surface: SurfaceID?
  private var journal: SpatialInkJournal?
  private var task: Task<Void, Never>?
  private var versions: [SpatialInkMeshCache.ActionVersion]?

  init(cache: SpatialInkMeshCache = .shared) { self.cache = cache }

  @discardableResult
  func update(surface: SurfaceID, journal: SpatialInkJournal?, apply: @escaping @MainActor (SpatialInkMesh?) -> Void) -> Bool {
    // Array equality takes its shared-storage fast path on camera-only frames;
    // unlike a maximum stamp it also detects independent, lower-clock merges.
    guard self.surface != surface || self.journal != journal else { return false }
    let ownerChanged = self.surface != surface
    let previous = ownerChanged ? nil : versions
    self.surface = surface; self.journal = journal
    task?.cancel(); task = nil
    let cached = cache.entry(for: surface)
    if let cached, cached.journal == journal {
      versions = cached.versions
      apply(cached.mesh)
      return false
    }
    if ownerChanged {
      // An uncached owner never inherits the old board's ink while preparing.
      apply(.init(batches: []))
    }
    let worker = Task.detached(priority: .userInitiated) {
      try Task.checkCancellation()
      let versions = (journal?.actions ?? []).filter { $0.isActive && $0.spans.contains { $0.surface == surface } }
        .map { SpatialInkMeshCache.ActionVersion(id: $0.id, stamp: $0.stamp, state: $0.stateStamp) }
      let mesh: SpatialInkMesh
      if let cached, versions == cached.versions { mesh = cached.mesh }
      else { mesh = try SpatialInkMesh.prepare(surface: surface, journal: journal) }
      return (versions, mesh)
    }
    task = Task { [weak self] in
      await withTaskCancellationHandler {
        guard let result = try? await worker.value, !Task.isCancelled, let self else { return }
        self.versions = result.0
        self.cache.store(result.1, versions: result.0, surface: surface, journal: journal)
        apply(previous == result.0 ? nil : result.1)
      } onCancel: { worker.cancel() }
    }
    return true
  }

  func cancel() { task?.cancel(); task = nil; surface = nil; journal = nil; versions = nil }
  deinit { task?.cancel() }
}

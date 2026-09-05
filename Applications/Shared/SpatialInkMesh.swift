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

/// One cancellable build belongs to a mounted physical surface. Projection is
/// always immediate, including while the next journal revision is preparing.
@MainActor
final class SpatialInkMeshPreparation {
  private var surface: SurfaceID?
  private var stamp: VersionStamp?
  private var task: Task<Void, Never>?
  private struct ActionVersion: Equatable, Sendable {
    let id: UUID
    let stamp: VersionStamp
    let state: VersionStamp
  }
  private var versions: [ActionVersion]?

  @discardableResult
  func update(surface: SurfaceID, journal: SpatialInkJournal?, apply: @escaping @MainActor (SpatialInkMesh?) -> Void) -> Bool {
    guard self.surface != surface || stamp != journal?.stamp else { return false }
    let previous = self.surface == surface ? versions : nil
    self.surface = surface; stamp = journal?.stamp
    task?.cancel()
    let worker = Task.detached(priority: .userInitiated) {
      let versions = (journal?.actions ?? []).filter { $0.isActive && $0.spans.contains { $0.surface == surface } }
        .map { ActionVersion(id: $0.id, stamp: $0.stamp, state: $0.stateStamp) }
      let mesh = versions == previous ? nil : try SpatialInkMesh.prepare(surface: surface, journal: journal)
      return (versions, mesh)
    }
    task = Task { [weak self] in
      await withTaskCancellationHandler {
        guard let result = try? await worker.value, !Task.isCancelled else { return }
        self?.versions = result.0
        apply(result.1)
      } onCancel: { worker.cancel() }
    }
    return true
  }

  func cancel() { task?.cancel(); task = nil; surface = nil; stamp = nil; versions = nil }
  deinit { task?.cancel() }
}

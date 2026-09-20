import NotebookCore
import Foundation

/// A view of accepted measurements, not another decoded point array. Projection
/// changes only display coordinates; tiled world positions and event bits stay
/// in the source. The live canvas, page export and passive scene share this path.
struct SpatialInkRenderLayer: Sendable {
  let source: InkSampleRelations
  var origin: WorldPoint? = nil
  var offset: SpatialPoint = .zero
  var scale: Double = 1
}

enum SpatialInkComposer {
  static func pageLayers(_ drawing: PageInkDrawing) -> [SpatialInkRenderLayer] {
    drawing.activeActions.map { .init(source:.init($0)) }
  }

  static func boardLayers(
    board: SurfaceID, journal: SpatialInkJournal?, camera: SpatialCamera, viewport: SpatialPoint
  ) -> [SpatialInkRenderLayer] {
    layers(for:board,in:journal).map {
      .init(source:$0,origin:camera.center,offset:.init(x:viewport.x/2,y:viewport.y/2),scale:camera.scale)
    }
  }

  static func localLayers(
    for surface: SurfaceID, journal: SpatialInkJournal?, origin: SpatialPoint = .zero
  ) -> [SpatialInkRenderLayer] {
    layers(for:surface,in:journal).map { .init(source:$0,offset:.init(x:-origin.x,y:-origin.y)) }
  }

  private static func layers(for surface: SurfaceID, in journal: SpatialInkJournal?) -> [InkSampleRelations] {
    (journal?.actions ?? []).filter(\.isActive).flatMap { action in
      action.spans.enumerated().filter { $0.element.surface == surface }.map { index,span in
        .init(sourceID:action.id,span:index,measurements:span.samples,
          header:.init(tool:action.tool,color:action.color))
      }
    }
  }
}

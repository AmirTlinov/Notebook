import Foundation

/// One physical rectangle for a workspace item. A document derives it from
/// its immutable paper size; the scene, cover, page, camera and input use it.
public struct WorkspaceItemGeometry: Equatable, Hashable, Sendable {
  public let width: Double
  public let height: Double
  public let cornerRadius: Double

  public static let notebook = Self(
    width: 834, height: 1_194,
    cornerRadius: PhysicalPaper.pointsPerCentimeter * 0.8
  )

  public static func document(_ paper: DocumentPaperSize) -> Self {
    let pointsPerPostScriptPoint = PhysicalPaper.pointsPerCentimeter * 2.54 / 72
    return Self(
      width: paper.widthPoints * pointsPerPostScriptPoint,
      height: paper.heightPoints * pointsPerPostScriptPoint,
      cornerRadius: PhysicalPaper.pointsPerCentimeter * 0.12
    )
  }

  public var size: SpatialPoint { SpatialPoint(x: width, y: height) }

  public func fitScale(viewport: SpatialPoint) -> Double {
    precondition(viewport.x > 0 && viewport.y > 0)
    return min(viewport.x / width, viewport.y / height)
  }

  public func coverScale(viewport: SpatialPoint) -> Double {
    fitScale(viewport: viewport) * 0.72
  }

  public func screenFrame(center: WorldPoint, camera: SpatialCamera, viewport: SpatialPoint) -> SpatialRect {
    let screen = camera.worldToScreen(center, viewport: viewport)
    return SpatialRect(
      x: screen.x - width * camera.scale / 2,
      y: screen.y - height * camera.scale / 2,
      width: width * camera.scale, height: height * camera.scale
    )
  }
}

import Foundation

/// One physical rectangle for a workspace item. A document derives it from
/// its immutable paper size; the scene, cover, page, camera and input use it.
public struct WorkspaceItemGeometry: Equatable, Hashable, Sendable {
  public let width: Double
  public let height: Double
  public let cornerRadius: Double
  public let paperSize: DocumentPaperSize?

  /// Logical display geometry of the 11-inch iPad Pro, including its 18-point corner.
  public static let notebook = Self(
    width: 834, height: 1_194,
    cornerRadius: 18,
    paperSize: nil
  )

  public static func document(_ paper: DocumentPaperSize) -> Self {
    let pointsPerPostScriptPoint = PhysicalPaper.pointsPerCentimeter * 2.54 / 72
    return Self(
      width: paper.widthPoints * pointsPerPostScriptPoint,
      height: paper.heightPoints * pointsPerPostScriptPoint,
      cornerRadius: PhysicalPaper.pointsPerCentimeter * 0.12,
      paperSize: paper
    )
  }

  public var size: SpatialPoint { SpatialPoint(x: width, y: height) }

  public func fitScale(viewport: SpatialPoint) -> Double {
    precondition(viewport.x > 0 && viewport.y > 0)
    return min(viewport.x / width, viewport.y / height)
  }

  /// Reading cannot recede into the board or pan the sheet out of view.
  /// The camera remains the sole projection for paint, hit testing and persistence.
  public func readingCamera(_ camera: SpatialCamera, centeredOn center: WorldPoint,
    viewport: SpatialPoint, margin: Double = 0, maximumScale: Double = SpatialCamera.maximumScale) -> SpatialCamera {
    let available = SpatialPoint(x: max(1, viewport.x - margin * 2), y: max(1, viewport.y - margin * 2))
    let scale = max(fitScale(viewport: available), min(maximumScale, camera.scale))
    let x = max(0, width / 2 - available.x / (2 * scale))
    let y = max(0, height / 2 - available.y / (2 * scale))
    let offset = center.delta(to: camera.center)
    return .init(center: center.offsetBy(x: min(x, max(-x, offset.x)), y: min(y, max(-y, offset.y))), scale: scale)
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

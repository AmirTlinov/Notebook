import Foundation

/// A child's view expressed in the fixed portal viewport. Its scale is a
/// ratio, so it can lie outside the limits of an active screen camera.
public struct BoardPortalCamera: Codable, Equatable, Sendable {
  public let center: WorldPoint
  public let scale: Double

  public init(center: WorldPoint = .zero, scale: Double = 0.22) {
    precondition(center.isValid && scale.isFinite && scale > 0)
    self.center = center
    self.scale = scale
  }

  public var isValid: Bool {
    center.isValid && scale.isFinite && scale > 0
  }
}

/// One geometric contract joins a portal window to the child board behind it.
/// The portal owns a canonical camera; entering only expresses that same
/// camera in the current viewport.
public enum BoardPortalProjection {
  public static let viewport = SpatialPoint(
    x: NotebookGeometry.width,
    y: NotebookGeometry.height
  )

  /// A portal must cover the viewport at handoff. Using `fitScale` would leave
  /// side bands in landscape and make the child scene appear to jump there.
  public static func fillScale(viewport: SpatialPoint) -> Double {
    precondition(viewport.x > 0 && viewport.y > 0)
    return max(
      viewport.x / NotebookGeometry.width,
      viewport.y / NotebookGeometry.height
    )
  }

  public static func entryCamera(
    portalCamera: BoardPortalCamera,
    viewport: SpatialPoint
  ) -> SpatialCamera {
    let resolved = resolvedPortalCamera(
      portalCamera,
      viewport: viewport
    )
    return SpatialCamera(
      center: resolved.center,
      scale: min(
        SpatialCamera.maximumScale,
        max(SpatialCamera.minimumScale, resolved.scale * fillScale(viewport: viewport))
      )
    )
  }

  /// A camera saved at the maximum zoom in one orientation may be seen later
  /// through a wider viewport. Resolve the portal itself to the camera limit
  /// so its boundary frame and the entered child remain identical.
  public static func resolvedPortalCamera(
    _ portalCamera: BoardPortalCamera,
    viewport: SpatialPoint
  ) -> BoardPortalCamera {
    BoardPortalCamera(
      center: portalCamera.center,
      scale: min(
        max(portalCamera.scale, SpatialCamera.minimumScale / fillScale(viewport: viewport)),
        SpatialCamera.maximumScale / fillScale(viewport: viewport)
      )
    )
  }

  public static func portalCamera(
    from camera: SpatialCamera,
    viewport: SpatialPoint
  ) -> BoardPortalCamera {
    BoardPortalCamera(
      center: camera.center,
      scale: camera.scale / fillScale(viewport: viewport)
    )
  }

  /// The preview renders through a legal active camera on this larger canvas,
  /// then scales down into the canonical portal. Its centered crop is exactly
  /// the viewport exposed at handoff, including the minimum camera scale.
  public static func renderViewport(viewport: SpatialPoint) -> SpatialPoint {
    let fill = fillScale(viewport: viewport)
    return SpatialPoint(x: Self.viewport.x * fill, y: Self.viewport.y * fill)
  }

  public static func parentBoundaryCamera(
    portalCenter: WorldPoint,
    viewport: SpatialPoint
  ) -> SpatialCamera {
    SpatialCamera(
      center: portalCenter,
      scale: fillScale(viewport: viewport)
    )
  }
}

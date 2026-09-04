import Foundation

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
    portalCamera: SpatialCamera,
    viewport: SpatialPoint
  ) -> SpatialCamera {
    let resolved = resolvedPortalCamera(
      portalCamera,
      viewport: viewport
    )
    return SpatialCamera(
      center: resolved.center,
      scale: resolved.scale * fillScale(viewport: viewport)
    )
  }

  /// A camera saved at the maximum zoom in one orientation may be seen later
  /// through a wider viewport. Resolve the portal itself to the camera limit
  /// so its boundary frame and the entered child remain identical.
  public static func resolvedPortalCamera(
    _ portalCamera: SpatialCamera,
    viewport: SpatialPoint
  ) -> SpatialCamera {
    SpatialCamera(
      center: portalCamera.center,
      scale: min(
        portalCamera.scale,
        SpatialCamera.maximumScale / fillScale(viewport: viewport)
      )
    )
  }

  public static func portalCamera(
    from camera: SpatialCamera,
    viewport: SpatialPoint
  ) -> SpatialCamera {
    SpatialCamera(
      center: camera.center,
      scale: camera.scale / fillScale(viewport: viewport)
    )
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

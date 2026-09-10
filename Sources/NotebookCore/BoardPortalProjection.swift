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
    x: WorkspaceItemGeometry.notebook.width,
    y: WorkspaceItemGeometry.notebook.height
  )

  /// A portal must cover the viewport at handoff. Using `fitScale` would leave
  /// side bands in landscape and make the child scene appear to jump there.
  public static func fillScale(viewport: SpatialPoint) -> Double {
    precondition(viewport.x > 0 && viewport.y > 0)
    return max(
      viewport.x / WorkspaceItemGeometry.notebook.width,
      viewport.y / WorkspaceItemGeometry.notebook.height
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

  /// Changes coordinate ownership only after the same portal image covers the
  /// screen. An off-centre pinch keeps its centre and scale, without docking.
  public static func enteringCamera(
    from parentCamera: SpatialCamera,
    portalCamera: BoardPortalCamera,
    portalCenter: WorldPoint,
    viewport: SpatialPoint
  ) -> SpatialCamera? {
    guard coverage(camera: parentCamera, portalCenter: portalCenter, viewport: viewport) >= 1 else { return nil }
    let portal = resolvedPortalCamera(portalCamera, viewport: viewport)
    let scale = parentCamera.scale * portal.scale
    guard scale >= SpatialCamera.minimumScale, scale <= SpatialCamera.maximumScale else { return nil }
    let offset = portalCenter.delta(to: parentCamera.center)
    guard let center = portal.center.addressOffset(x: offset.x / portal.scale, y: offset.y / portal.scale) else { return nil }
    return SpatialCamera(center: center, scale: scale)
  }

  public struct ExitProjection: Equatable, Sendable {
    public let portalCamera: BoardPortalCamera
    public let parentCamera: SpatialCamera
  }

  /// The boundary captures the place inspected inside the child. The remaining
  /// finger movement continues in the parent, even at the child's minimum zoom.
  public static func exitingCamera(
    boundary: SpatialCamera,
    magnification: Double = 1,
    centroid: SpatialPoint,
    portalCenter: WorldPoint,
    viewport: SpatialPoint
  ) -> ExitProjection {
    ExitProjection(
      portalCamera: portalCamera(from: boundary, viewport: viewport),
      parentCamera: parentBoundaryCamera(portalCenter: portalCenter, viewport: viewport)
        .pinched(by: magnification, from: centroid, to: centroid, viewport: viewport)
    )
  }

  /// Only the portal's border and surface annotations fade as its aperture
  /// fills the screen. This presentation never corrects the camera trajectory.
  public static func openingProgress(camera: SpatialCamera, portalCenter: WorldPoint, viewport: SpatialPoint) -> Double {
    min(1, max(0, (coverage(camera: camera, portalCenter: portalCenter, viewport: viewport) - 0.5) * 2))
  }

  private static func coverage(camera: SpatialCamera, portalCenter: WorldPoint, viewport: SpatialPoint) -> Double {
    let center = camera.worldToScreen(portalCenter, viewport: viewport)
    return min(
      Self.viewport.x * camera.scale / (viewport.x + 2 * abs(center.x - viewport.x / 2)),
      Self.viewport.y * camera.scale / (viewport.y + 2 * abs(center.y - viewport.y / 2))
    )
  }
}

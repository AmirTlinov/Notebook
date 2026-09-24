import CoreGraphics
import Foundation
import NotebookCore

/// One hierarchy boundary, expressed in the immutable gesture's coordinate
/// system. Presentation may cross it; acceptance happens only at settlement.
struct NotebookZoomPassage: Sendable {
  let itemID: UUID
  let parentID: UUID
  let kind: WorkspaceItemKind
  let center: WorldPoint
  let geometry: WorkspaceItemGeometry
  let opening: Bool
  let closedScale: Double
  let openScale: Double
  /// Only a child-to-parent passage changes the camera's coordinate space.
  let returningPortal: BoardPortalCamera?

  func progress(at scale: Double) -> Double {
    guard scale.isFinite,scale > 0,openScale > closedScale else { return opening ? 0 : 1 }
    return min(1,max(0,log(scale/closedScale)/log(openScale/closedScale)))
  }

  func parentCamera(from child: SpatialCamera) -> SpatialCamera {
    guard let portal=returningPortal else { return child }
    let delta=portal.center.delta(to:child.center)
    return .init(center:center.offsetBy(x:delta.x*portal.scale,y:delta.y*portal.scale),
      scale:min(SpatialCamera.maximumScale,max(SpatialCamera.minimumScale,child.scale/portal.scale)))
  }

  /// The inverse portal is applied once to the immutable start. The same
  /// native pinch formula then remains usable even at the child's minimum zoom.
  func camera(from trajectory:CameraGestureTrajectory,magnification:CGFloat,centroid:CGPoint) -> SpatialCamera {
    let trajectory=CameraGestureTrajectory(startingCamera:parentCamera(from:trajectory.startingCamera),
      startingCentroid:trajectory.startingCentroid,viewport:trajectory.viewport)
    return trajectory.camera(at:magnification,centroid:centroid,maximumScale:SpatialCamera.maximumScale)
  }

  func progress(camera:SpatialCamera) -> Double {
    progress(at:camera.scale*(returningPortal?.scale ?? 1))
  }

  func presentation(camera raw: SpatialCamera, viewport: SpatialPoint, page: Int = 0) -> SessionPresence {
    let progress=progress(camera:raw)
    let camera: SpatialCamera
    if kind == .board && opening {
      camera = .init(center:raw.center.interpolatedAddress(to:center,amount:progress) ?? raw.center,
        scale:min(openScale,raw.scale))
    } else { camera=raw }
    return .init(boardID:parentID,mode:.cover,camera:camera,viewport:viewport,
      focusedItemID:itemID,openProgress:progress,documentPageIndex:page)
  }

  func closed(viewport:SpatialPoint,camera:SpatialCamera) -> SessionPresence {
    .init(boardID:parentID,mode:.board,camera:.init(center:camera.center,
      scale:geometry.coverScale(viewport:viewport)),viewport:viewport)
  }
}

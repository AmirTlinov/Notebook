import NotebookCore
import XCTest
@testable import Notebook

final class NotebookZoomPassageTests: XCTestCase {
  func testProgressIsReversibleAndBoundariesAreGeometric() {
    for size in [SpatialPoint(x:834,y:1194),.init(x:1194,y:834)] {
      let geometry=WorkspaceItemGeometry.notebook
      let closed=geometry.coverScale(viewport:size),open=BoardPortalProjection.fillScale(viewport:size)
      let passage=NotebookZoomPassage(itemID:UUID(),parentID:UUID(),kind:.board,center:.zero,
        geometry:geometry,opening:true,closedScale:closed,openScale:open,returningPortal:nil)
      XCTAssertEqual(passage.progress(at:closed),0);XCTAssertEqual(passage.progress(at:open),1)
      XCTAssertEqual(passage.progress(at:sqrt(closed*open)),0.5,accuracy:1e-9)
      let center=CGPoint(x:300,y:350)
      let trajectory=CameraGestureTrajectory(startingCamera:.init(center:.init(x:30,y:60),scale:closed),startingCentroid:center,viewport:size)
      let camera=passage.camera(from:trajectory,magnification:1.5,centroid:center)
      let first=passage.presentation(camera:camera,viewport:size)
      _ = passage.presentation(camera:passage.camera(from:trajectory,magnification:2,centroid:center),viewport:size)
      XCTAssertEqual(first,passage.presentation(camera:camera,viewport:size))
    }
  }

  func testInversePortalPreservesEveryPointAtBoundaryIncludingMinimumZoom() {
    for size in [SpatialPoint(x:834,y:1194),.init(x:1194,y:834)] {
      for scale in [SpatialCamera.minimumScale,0.22,1.0] {
        let child=SpatialCamera(center:.init(x:-4_000,y:8_000),scale:scale)
        let portal=BoardPortalProjection.portalCamera(from:child,viewport:size)
        let center=WorldPoint(x:2_000,y:-3_000),geometry=WorkspaceItemGeometry.notebook
        let passage=NotebookZoomPassage(itemID:UUID(),parentID:UUID(),kind:.board,center:center,geometry:geometry,
          opening:false,closedScale:portal.scale*geometry.coverScale(viewport:size),openScale:scale,returningPortal:portal)
        let centroid=CGPoint(x:size.x*0.6,y:size.y*0.4)
        let trajectory=CameraGestureTrajectory(startingCamera:child,startingCentroid:centroid,viewport:size)
        let parent=passage.camera(from:trajectory,magnification:1,centroid:centroid)
        XCTAssertEqual(passage.progress(camera:parent),1,accuracy:1e-9)
        for point in [WorldPoint.zero,.init(x:20,y:40),child.center] {
          let delta=portal.center.delta(to:point)
          let projected=center.offsetBy(x:delta.x*portal.scale,y:delta.y*portal.scale)
          let before=child.worldToScreen(point,viewport:size),after=parent.worldToScreen(projected,viewport:size)
          XCTAssertEqual(before.x,after.x,accuracy:1e-8);XCTAssertEqual(before.y,after.y,accuracy:1e-8)
        }
        let out=passage.camera(from:trajectory,magnification:0.4,centroid:centroid)
        XCTAssertLessThan(passage.progress(camera:out),0.5,"A child at minimum scale still has a reversible exit")
        let returned=passage.camera(from:trajectory,magnification:1,centroid:centroid)
        XCTAssertEqual(returned,parent)
      }
    }
  }
}

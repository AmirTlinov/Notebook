import CoreGraphics
import Foundation
import Testing
@testable import NotebookCore

@Suite struct NotebookFreehandAppearanceTests {
  private func sample(_ x:Double,_ y:Double,width:Double = 12) -> SpatialInkSample {
    .init(point:.init(x:x,y:y),timeOffset:(x+y)/240,width:width,opacity:1,force:1,azimuth:0,altitude:1)
  }
  private let frame=PageRect(x:0,y:0,width:100,height:100)
  private func ink(_ samples:[SpatialInkSample]) -> NotebookGraphic {
    .init(shape:.freehand,freehand:.init(layers:[.init(tool:.pen,color:.black,
      measured:.init(sourceID:UUID(),measurements:.init(samples),frame:frame))]))
  }
  private func cut(_ samples:[SpatialInkSample],basis:NotebookGraphicTransform? = nil) -> InkElementErasure {
    .init(target:.init(elementID:"ink",frame:frame,graphicTransform:basis),samples:samples)
  }
  @Test func stateAndLocalQueriesMatchIndependentWholeContour() {
    let graphic=ink([sample(5,50),sample(95,50)])
    let cuts=[cut([sample(40,0,width:18),sample(40,100,width:18)])]
    let size=CGSize(width:100,height:100)
    let actual=NotebookElementAppearance(graphic:graphic,layout:nil,size:size,erasures:cuts)
    let mask=NotebookElementAppearance.erasurePath(cuts,size:size)
    let remaining=graphic.freehand!.paintPath(size:size,transform:nil).subtracting(mask)
    #expect(actual.state == .partial)
    for x in stride(from:0.317,to:100,by:2.0) {
      for y in stride(from:35.193,to:65,by:2.0) {
        for tolerance in [0.0,3.0,8.0] {
          let p=CGPoint(x:x,y:y)
          let expected = !mask.contains(p) && (remaining.contains(p) || (tolerance > 0 && remaining.copy(strokingWithWidth:tolerance*2,lineCap:.round,lineJoin:.round,miterLimit:10).contains(p)))
          #expect(actual.contains(.init(x:x,y:y),tolerance:tolerance) == expected)
        }
      }
    }
    #expect(!actual.intersects([.init(x:37,y:45),.init(x:43,y:45),.init(x:43,y:55),.init(x:37,y:55)]))
    #expect(actual.intersects([.init(x:77,y:45),.init(x:83,y:45),.init(x:83,y:55),.init(x:77,y:55)]))
    let full=NotebookElementAppearance(graphic:graphic,layout:nil,size:size,erasures:[cut([sample(0,50,width:30),sample(100,50,width:30)])])
    #expect(full.state == .erased)
    #expect(!full.contains(.init(x:50,y:50),tolerance:100))
    let miss=NotebookElementAppearance(graphic:graphic,layout:nil,size:size,erasures:[cut([sample(50,0,width:4)])])
    #expect(miss.state == .intact)
  }

  @Test func lassoNeedsTheSamePaintAndVisibilityWitness() {
    var graphic=ink([sample(5,20),sample(95,20)])
    graphic.mask=NotebookGraphicMask().appending(.intersect,
      polygon:[.init(x:0,y:0.5),.init(x:1,y:0.5),.init(x:1,y:1),.init(x:0,y:1)])
    let value=NotebookElementAppearance(graphic:graphic,layout:nil,size:.init(width:100,height:100),erasures:[])
    #expect(!value.intersects([.init(x:10,y:10),.init(x:90,y:10),.init(x:90,y:80),.init(x:10,y:80)]))
    graphic.mask=NotebookGraphicMask().appending(.intersect,
      polygon:[.init(x:0,y:0.1),.init(x:1,y:0.1),.init(x:1,y:0.25),.init(x:0,y:0.25)])
    let visible=NotebookElementAppearance(graphic:graphic,layout:nil,size:.init(width:100,height:100),erasures:[])
    #expect(visible.intersects([.init(x:10,y:10),.init(x:90,y:10),.init(x:90,y:80),.init(x:10,y:80)]))
  }

  @Test func capturedCutSurvivesTurnStretchAndProjectedGroup() throws {
    var graphic=ink([sample(5,50),sample(95,50)])
    let turn=NotebookGraphicTransform(a:0,b:1,c:-1,d:0,tx:1,ty:0)
    graphic.transform=turn
    let page=PageDocument(size:.init(width:1000,height:1000),actor:UUID(),elements:[
      .init(id:"group",kind:.group,frame:.init(x:100,y:100,width:400,height:200),source:"",html:"",basis:.init(size:.init(x:100,y:100),transform:turn)),
      .init(id:"ink",kind:.graphic,frame:frame,source:"",html:"",graphic:graphic,parentID:"group")])
    let layout=try #require(page.graphicGraph().resolve("ink").layout)
    let cuts=[cut([sample(50,20,width:18),sample(50,40,width:18)],basis:turn)]
    let size=CGSize(width:layout.frame.width,height:layout.frame.height)
    let actual=NotebookElementAppearance(graphic:graphic,layout:layout,size:size,erasures:cuts)
    // Explicit export remains the independent full-path oracle. Live queries
    // must not request this property to select a surviving fragment.
    let remaining=actual.remaining,mask=actual.mask
    #expect(actual.state == .partial)
    for x in stride(from:0.37,to:size.width,by:11.0) {
      for y in stride(from:0.19,to:size.height,by:7.0) {
        let p=CGPoint(x:x,y:y),tolerance=5.0
        let expected = !mask.contains(p) && (remaining.contains(p) || remaining.copy(strokingWithWidth:tolerance*2,lineCap:.round,lineJoin:.round,miterLimit:10).contains(p))
        #expect(actual.contains(.init(x:x,y:y),tolerance:tolerance) == expected)
      }
    }
  }

  @Test func coldStateAndSelectionDoNotBuildOneHundredThousandPointContour() {
    let frame=PageRect(x:0,y:0,width:100_000,height:100)
    let samples=(0..<100_000).map { sample(Double($0),50,width:2) }
    let graphic=NotebookGraphic(shape:.freehand,freehand:.init(layers:[.init(tool:.pen,color:.black,
      measured:.init(sourceID:UUID(),measurements:.init(samples),frame:frame))]))
    let cuts=[InkElementErasure(target:.init(elementID:"ink",frame:frame),samples:[sample(30_000,0,width:6),sample(30_000,100,width:6)])]
    let start=ContinuousClock.now
    let value=NotebookElementAppearance(graphic:graphic,layout:nil,size:.init(width:100_000,height:100),erasures:cuts)
    #expect(value.state == .partial)
    #expect(value.contains(.init(x:80_000,y:50),tolerance:2))
    #expect(!value.contains(.init(x:30_000,y:50),tolerance:2))
    #expect(value.intersects([.init(x:79_999,y:49),.init(x:80_001,y:49),.init(x:80_001,y:51),.init(x:79_999,y:51)]))
    let elapsed=start.duration(to:.now)
    print("COLD_FREEHAND_APPEARANCE nodes=100000 elapsed=\(elapsed)")
    #expect(elapsed < .seconds(2))
    let fullStart=ContinuousClock.now
    let fullCut=InkElementErasure(target:.init(elementID:"ink",frame:frame),samples:[sample(0,50,width:8),sample(100_000,50,width:8)])
    let erased=NotebookElementAppearance(graphic:graphic,layout:nil,size:.init(width:100_000,height:100),erasures:[fullCut])
    #expect(erased.state == .erased)
    print("COLD_FREEHAND_FULL_ERASE nodes=100000 elapsed=\(fullStart.duration(to:.now))")
    #expect(fullStart.duration(to:.now) < .seconds(2))
    var fragment=graphic
    fragment.mask=NotebookGraphicMask().appending(.intersect,polygon:[.init(x:0.29999,y:0),
      .init(x:0.30001,y:0),.init(x:0.30001,y:1),.init(x:0.29999,y:1)])
    let regionStart=ContinuousClock.now
    let fragmentAppearance=NotebookElementAppearance(graphic:fragment,layout:nil,size:.init(width:100_000,height:100),erasures:cuts)
    #expect(fragmentAppearance.state == .erased,"Paint outside the retained relative region is not a visibility witness")
    #expect(fragment.mask?.completePathBuildCount == 0)
    #expect(regionStart.duration(to:.now) < .milliseconds(250))

  }
  @Test func labelSurvivesErasedInkAndInvisibleSourceStaysInvisible() {
    var graphic=ink([sample(5,15),sample(95,15)])
    graphic.label="Label"
    let cuts=[cut([sample(0,15,width:24),sample(100,15,width:24)])]
    let value=NotebookElementAppearance(graphic:graphic,layout:nil,size:.init(width:100,height:100),erasures:cuts)
    #expect(value.state == .partial)
    #expect(value.contains(.init(x:50,y:50),tolerance:0))
    #expect(!value.contains(.init(x:50,y:15),tolerance:0))
    #expect(value.intersects([.init(x:45,y:45),.init(x:55,y:45),.init(x:55,y:55),.init(x:45,y:55)]))
    graphic.visible=false
    let hidden=NotebookElementAppearance(graphic:graphic,layout:nil,size:.init(width:100,height:100),erasures:cuts)
    #expect(hidden.state == .erased)
    #expect(!hidden.contains(.init(x:50,y:50),tolerance:10))
  }
  @Test func retainedFrameClipsDisplayNotSourceCoordinates() {
    let graphic=NotebookGraphic(shape:.freehand,
      freehand:.init(layers:[.init(color:.black,vertices:[.init(x:1.1,y:0.2,opacity:1),.init(x:1.3,y:0.2,opacity:1),.init(x:1.2,y:0.4,opacity:1),
        .init(x:1.9,y:0.7,opacity:1),.init(x:2.3,y:0.7,opacity:1),.init(x:2.1,y:0.9,opacity:1)])]),transform:.init(a:0.5,b:0,c:0,d:0.5,tx:0,ty:0))
    let value=NotebookElementAppearance(graphic:graphic,layout:nil,size:.init(width:100,height:100),erasures:[])
    #expect(value.contains(.init(x:60,y:15),tolerance:0))
    #expect(!value.contains(.init(x:110,y:37),tolerance:0))
    #expect(!value.intersects([.init(x:100.1,y:35),.init(x:120,y:35),.init(x:120,y:50),.init(x:100.1,y:50)]))
  }

}

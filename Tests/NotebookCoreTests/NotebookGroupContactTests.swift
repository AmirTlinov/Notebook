import CoreGraphics
import Foundation
import Testing
@testable import NotebookCore

@Suite("Contacts share the whole graphic basis")
struct NotebookGroupContactTests {
  @Test(arguments:[false,true]) func physicalToleranceAndLocalAnchorsSurviveStretchAndTurn(turned: Bool) throws {
    let id=UUID(),origin=WorldPoint(tileX:1_000_000_000_000,tileY:-1_000_000_000_000,localX:3,localY:7)
    let turn=NotebookGraphicTransform(a:0,b:1,c:-1,d:0,tx:1,ty:0)
    let board=BoardDocument(freeItems:[],elements:[
      .init(id:"whole",surface:.board(id),kind:.group,frame:.init(x:40,y:30,width:turned ? 1000 : 100,height:turned ? 100 : 1000),worldOrigin:origin,
        source:"",basis:.init(size:.init(x:100,y:100),transform:turned ? turn : nil),stamp:.init(counter:0,actor:UUID())),
      .init(id:"ellipse",surface:.board(id),kind:.graphic,frame:.init(x:0,y:0,width:100,height:100),worldOrigin:.zero,
        source:"",graphic:.init(shape:.ellipse),parentID:"whole",stamp:.init(counter:0,actor:UUID()))],stamp:.init(counter:0,actor:UUID()))
    let graph=board.graphicGraph(),layout=try #require(graph.resolve("ellipse").layout)
    let contact=origin.offsetBy(x:40,y:30)
    let near=turned ? SpatialPoint(x:1010,y:50) : .init(x:50,y:1010)
    let far=turned ? SpatialPoint(x:1020,y:50) : .init(x:50,y:1020)
    #expect(graph.binding(at:far,origin:contact,surface:.board(id),tolerance:12) == nil)
    let binding=try #require(graph.binding(at:near,origin:contact,surface:.board(id),tolerance:12))
    #expect(binding.isExact)
    #expect(abs(binding.normalizedAnchor.x-0.5)<0.001)
    #expect(abs(binding.normalizedAnchor.y-(turned ? 0 : 1))<0.001)
    let picked=layout.displayedPoint(.init(x:50,y:50))
    let inside=try #require(graph.binding(at:picked,origin:contact,surface:.board(id),tolerance:12))
    #expect(!inside.isExact && inside.normalizedAnchor == .init(x:0.5,y:0.5))
  }

  @Test func quickShapeKeepsTheMeasuredEndpointAndErasureUsesDisplayedCoordinates() throws {
    let page=PageDocument(size:.init(width:800,height:1000),actor:UUID(),elements:[
      .init(id:"whole",kind:.group,frame:.init(x:40,y:30,width:240,height:600),source:"",html:"",
        basis:.init(size:.init(x:200,y:120),transform:.init(a:0,b:1,c:-1,d:0,tx:1,ty:0))),
      .init(id:"shape",kind:.graphic,frame:.init(x:10,y:20,width:100,height:60),source:"",html:"",
        graphic:.init(shape:.rectangle,style:.init(fill:.black)),parentID:"whole")])
    let graph=page.graphicGraph(),layout=try #require(graph.resolve("shape").layout),surface=SurfaceID.page(page.id)
    let p=SpatialPoint(x:180,y:150)
    let fit=NotebookQuickShapeFit(frame:.init(x:0,y:0,width:600,height:800),sampleCount:2,
      connection:.init(start:.init(point:p),end:.init(point:.init(x:600,y:600))))
      .binding(in:graph,surface:surface,tolerance:12)
    let binding=try #require(fit.connection?.start.binding)
    #expect(binding.isExact && binding.isPrecise)
    let local=layout.displayedPoint(.init(x:binding.normalizedAnchor.x*100,y:binding.normalizedAnchor.y*60))
    #expect(abs(layout.frame.x+local.x-p.x)<1e-10 && abs(layout.frame.y+local.y-p.y)<1e-10)
    let cut=PageInkAction(tool:.eraser,samples:[.init(point:p,timeOffset:0,width:20,opacity:1,force:1,azimuth:0,altitude:1)])
      .erasingElements([.init(elementID:"shape",frame:layout.frame,elementTransform:layout.elementTransform)])
    let erasures=try PageInkDrawing.decode(PageInkDrawing(actions:[cut]).dataRepresentation()).elementErasures
    var callbacks=0
    let missing=graph.binding(at:p,origin:.zero,surface:surface,tolerance:0,erasures:erasures,appearance:{ _,graphic,shown,size,cuts in
      callbacks += 1
      #expect(shown == layout)
      return .init(graphic:graphic,layout:shown,size:size,erasures:cuts)
    })
    #expect(missing == nil && callbacks == 1)
    #expect(graph.binding(at:.init(x:180,y:250),surface:surface,tolerance:0,erasures:erasures)?.elementID == "shape")
  }

  @Test func pathHolesAndAQueryBudgetNeverBecomeAnInventedAttraction() throws {
    let path=CGMutablePath();path.addRect(.init(x:0,y:0,width:1,height:1))
    path.move(to:.init(x:0.3,y:0.3));path.addLine(to:.init(x:0.3,y:0.7));path.addLine(to:.init(x:0.7,y:0.7));path.addLine(to:.init(x:0.7,y:0.3));path.closeSubpath()
    let graphic=NotebookGraphic(shape:.path,style:.init(fill:.black),path:.init(path:path,frame:.init(x:0,y:0,width:1,height:1)))
    let surface=SurfaceID.page(UUID()),graph=NotebookGraphicGraph([.init(id:"ring",graphic:graphic,frame:.init(x:0,y:0,width:100,height:100),surface:surface,shown:true)])
    #expect(graph.binding(at:.init(x:50,y:50),surface:surface,tolerance:5) == nil)
    #expect(graph.binding(at:.init(x:20,y:50),surface:surface,tolerance:5)?.elementID == "ring")
    let huge=NotebookGraphicGeometry.outlineContact(.init(shape:.ellipse),size:.init(width:100,height:100),
      transform:.init(scaleX:1e100,y:1e100),point:.init(x:0,y:0),tolerance:12)
    #expect(!huge.inside && huge.distance == .infinity)
  }

  @Test func connectorClipsToTheOriginalCurveAndHoleNotAnEllipseOrOuterPose() throws {
    let path=CGMutablePath();path.move(to:.zero)
    path.addCurve(to:.init(x:1,y:0),control1:.init(x:0,y:1),control2:.init(x:1,y:1));path.closeSubpath()
    let graphic=NotebookGraphic(shape:.path,path:.init(path:path,frame:.init(x:0,y:0,width:1,height:1)))
    let contact=try #require(NotebookGraphicGeometry.outlineRayContact(graphic,size:.init(width:100,height:100),
      from:.init(x:50,y:25),toward:.init(x:50,y:150)))
    #expect(abs(contact.x-50)<1e-10 && abs(contact.y-75)<1e-10)
    func resolve(_ transform: NotebookGraphicTransform?,frame: PageRect) throws -> NotebookGraphicLayout {
      let page=PageDocument(size:.init(width:1000,height:1000),actor:UUID(),elements:[
        .init(id:"whole",kind:.group,frame:frame,source:"",html:"",basis:.init(size:.init(x:300,y:300),transform:transform)),
        .init(id:"shape",kind:.graphic,frame:.init(x:0,y:0,width:100,height:100),source:"",html:"",graphic:graphic,parentID:"whole"),
        .init(id:"arrow",kind:.graphic,frame:.init(x:0,y:0,width:300,height:300),source:"",html:"",
          graphic:.init(shape:.connector,connection:.init(start:.init(point:.zero,binding:.init(elementID:"shape",normalizedAnchor:.init(x:0.5,y:0.25))),
            end:.init(point:.init(x:50,y:150)))),parentID:"whole")])
      return try #require(page.graphicGraph().resolve("arrow").layout)
    }
    let first=try resolve(nil,frame:.init(x:0,y:0,width:300,height:300))
    let turned=try resolve(.init(a:0,b:1,c:-1,d:0,tx:1,ty:0),frame:.init(x:50,y:75,width:900,height:300))
    #expect(first.curves == turned.curves && first.heads == turned.heads)
    #expect(abs(first.frame.y+first.start.y-75)<1e-10)
    let ring=CGMutablePath();ring.addRect(.init(x:0,y:0,width:1,height:1))
    ring.move(to:.init(x:0.3,y:0.3));ring.addLine(to:.init(x:0.3,y:0.7));ring.addLine(to:.init(x:0.7,y:0.7));ring.addLine(to:.init(x:0.7,y:0.3));ring.closeSubpath()
    let hole=try #require(NotebookGraphicGeometry.outlineRayContact(.init(shape:.path,path:.init(path:ring,frame:.init(x:0,y:0,width:1,height:1))),
      size:.init(width:100,height:100),from:.init(x:20,y:50),toward:.init(x:100,y:50)))
    #expect(abs(hole.x-30)<1e-10 && hole.y == 50)
  }


  @Test func physicalAffineEditKeepsTheBodyAndOrderUnderANestedBasis() throws {
    let page=PageDocument(size:.init(width:2000,height:2000),actor:UUID(),elements:[
      .init(id:"outer",kind:.group,frame:.init(x:100,y:75,width:1000,height:900),source:"",html:"",
        basis:.init(size:.init(x:400,y:400),transform:.init(a:0,b:1,c:-1,d:0,tx:1,ty:0))),
      .init(id:"inner",kind:.group,frame:.init(x:30,y:40,width:200,height:120),source:"",html:"",
        parentID:"outer",basis:.init(size:.init(x:200,y:120),transform:.init(a:-1,b:0,c:0,d:1,tx:1,ty:0))),
      .init(id:"shape",kind:.graphic,frame:.init(x:10,y:20,width:100,height:60),source:"",html:"",
        graphic:.init(shape:.ellipse),parentID:"inner")])
    let placement=try #require(page.graphicGraph().node("shape")?.placement)
    let change=CGAffineTransform(translationX:-700,y:-300).concatenating(.init(scaleX:1.5,y:0.8))
      .concatenating(.init(rotationAngle:0.3)).concatenating(.init(translationX:700,y:300))
    let edit=try placement.applyingSurfaceTransform(change),after=try placement.updating(frame:edit.frame,basis:edit.basis)
    #expect(after.localSize == placement.localSize && after.ancestors == placement.ancestors && after.origin == placement.origin)
    for p in [CGPoint.zero,.init(x:100,y:0),.init(x:0,y:60),.init(x:100,y:60),.init(x:25,y:35)] {
      let expected=p.applying(placement.transform).applying(change),actual=p.applying(after.transform)
      #expect(abs(actual.x-expected.x)<1e-9 && abs(actual.y-expected.y)<1e-9)
    }
    let different=CGAffineTransform(rotationAngle:0.3).concatenating(.init(scaleX:1.5,y:0.8))
    #expect(different.a != change.a || different.b != change.b || different.c != change.c || different.d != change.d)
  }


  @Test func aBasisSharesItsImmutablePayloadWithoutReservingItInEveryPlainLeaf() throws {
    #expect(MemoryLayout<NotebookElementBasis>.stride == MemoryLayout<UnsafeRawPointer>.stride)
    #expect(MemoryLayout<NotebookElementBasis?>.stride == MemoryLayout<UnsafeRawPointer>.stride)
    let original=NotebookElementBasis(size:.init(x:100,y:60)),copy=original
    let encoded=try JSONValue.encode(original)
    #expect(encoded == .object(["size":.object(["x":.number(100),"y":.number(60)])]))
    #expect(try encoded.decode(NotebookElementBasis.self) == copy)
    let transformed=NotebookElementBasis(size:original.size,transform:.init(a:0,b:1,c:-1,d:0,tx:1,ty:0))
    #expect(original == copy && original.transform == nil && transformed != original)
  }

}

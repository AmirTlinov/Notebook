import CoreGraphics
import Foundation
import Testing
@testable import NotebookCore

@Suite("Shared group geometry")
struct NotebookGroupGeometryTests {
  private func page(frame: PageRect = .init(x:100,y:100,width:500,height:300),
    pose: NotebookGraphicTransform? = nil, bFrame: PageRect = .init(x:270,y:120,width:70,height:60)) -> PageDocument {
    let connector = NotebookGraphic(shape:.connector,style:.init(strokeWidth:4),label:"Связь",
      connection:.init(start:.init(point:.zero,binding:.init(elementID:"a")),
        end:.init(point:.init(x:300,y:100),binding:.init(elementID:"b")),bend:23))
    return .init(size:.init(width:1000,height:1000),actor:UUID(),elements:[
      .init(id:"outer",kind:.group,frame:frame,source:"",html:"",basis:.init(size:.init(x:500,y:300),transform:pose)),
      .init(id:"inner",kind:.group,frame:.init(x:20,y:30,width:180,height:100),source:"",html:"",parentID:"outer",basis:.init(size:.init(x:180,y:100))),
      .init(id:"a",kind:.graphic,frame:.init(x:10,y:10,width:60,height:50),source:"",html:"",graphic:.init(shape:.ellipse),parentID:"inner"),
      .init(id:"b",kind:.graphic,frame:bFrame,source:"",html:"",graphic:.init(shape:.rectangle),parentID:"outer"),
      .init(id:"link",kind:.graphic,frame:.init(x:25,y:20,width:300,height:180),source:"",html:"",graphic:connector,parentID:"outer")])
  }

  @Test func internalBindingsCancelTheSharedOuterFrameNotFloatingPointMatrices() throws {
    let original = page(), graph = original.graphicGraph()
    let body = try #require(graph.resolve("link").layout).localLayout
    for pose in [NotebookGraphicTransform(a:0,b:1,c:-1,d:0,tx:1,ty:0),
      .init(a:0.6,b:0.23,c:0.31,d:0.7,tx:0.04,ty:0.03),.init(a:-1,b:0,c:0,d:1,tx:1,ty:0)] {
      let changed = page(frame:.init(x:100,y:100,width:371,height:617),pose:pose).graphicGraph()
      let layout = try #require(changed.resolve("link").layout)
      #expect(layout.localLayout == body, "Local cubic controls and heads must not depend on the removed outer frame")
      #expect(layout.projection != nil)
      let moved = page(frame:.init(x:193,y:147,width:371,height:617),pose:pose).graphicGraph()
      let translated = try #require(moved.resolve("link").layout)
      #expect(translated.projection == layout.projection)
      #expect(translated.curves == layout.curves)
      #expect(abs(translated.frame.x-layout.frame.x-93) < 1e-10)
      #expect(abs(translated.frame.y-layout.frame.y-47) < 1e-10)
    }
    let edited = page(bFrame:.init(x:300,y:150,width:90,height:70)).graphicGraph()
    #expect(edited.resolve("link").layout?.localLayout != body)
    #expect(original.graphicGraph(frames:["outer":.init(x:170,y:150,width:500,height:300)]).resolve("link").layout?.localLayout == body)
  }

  @Test func strokesAndExistingCutsTransformTogetherAndRemainPickable() throws {
    let graphic = NotebookGraphic(shape:.rectangle,style:.init(strokeWidth:8,fill:.black))
    let sourceFrame = PageRect(x:0,y:0,width:100,height:60)
    let target = InkElementTarget(elementID:"shape",frame:sourceFrame)
    let cuts = [InkElementErasure(target:target,samples:[10.0,50].map {
      .init(point:.init(x:30,y:$0),timeOffset:0,width:12,opacity:1,force:1,azimuth:0,altitude:1)
    })]
    let source = NotebookElementAppearance(graphic:graphic,layout:nil,size:.init(width:100,height:60),erasures:cuts)
    let page = PageDocument(size:.init(width:600,height:600),actor:UUID(),elements:[
      .init(id:"group",kind:.group,frame:.init(x:80,y:100,width:120,height:300),source:"",html:"",
        basis:.init(size:.init(x:100,y:60),transform:.init(a:0,b:1,c:-1,d:0,tx:1,ty:0))),
      .init(id:"shape",kind:.graphic,frame:sourceFrame,source:"",html:"",graphic:graphic,parentID:"group")])
    let layout = try #require(page.graphicGraph().resolve("shape").layout)
    let result = NotebookElementAppearance(graphic:graphic,layout:layout,
      size:.init(width:layout.frame.width,height:layout.frame.height),erasures:cuts)
    var projection = try #require(layout.projection).transform
    #expect(result.remaining == source.remaining.copy(using:&projection))
    #expect(result.mask == source.mask.copy(using:&projection))
    #expect(result.state == .partial)
    #expect(!result.contains(layout.displayedPoint(.init(x:30,y:30)),tolerance:0))
    #expect(result.contains(layout.displayedPoint(.init(x:75,y:30)),tolerance:0))
    #expect(layout.hitTest(layout.displayedPoint(.init(x:75,y:30)),graphic:graphic,tolerance:0))
  }

  @Test func aNewMeasuredCutUnappliesOuterThenContourBasis() throws {
    let turn = NotebookGraphicTransform(a:0,b:1,c:-1,d:0,tx:1,ty:0)
    let reflection = NotebookGraphicTransform(a:-1,b:0,c:0,d:1,tx:1,ty:0)
    let target = InkElementTarget(elementID:"shape",frame:.init(x:100,y:200,width:120,height:300),
      graphicTransform:reflection,elementTransform:turn)
    // In contact-frame units (0.3,0.7). Undo whole turn, then the contour
    // reflection: source point (0.3,0.7), not the reversed order (0.7,0.3).
    let action = PageInkAction(tool:.eraser,samples:[.init(point:.init(x:136,y:410),
      timeOffset:0,width:12,opacity:1,force:1,azimuth:0,altitude:1)]).erasingElements([target])
    let restored = try PageInkDrawing.decode(PageInkDrawing(actions:[action]).dataRepresentation())
    let cuts = try #require(restored.elementErasures["shape"])
    #expect(cuts.first?.target == target)
    let result = NotebookElementAppearance(graphic:.init(shape:.rectangle,style:.init(fill:.black)),
      layout:nil,size:.init(width:100,height:60),erasures:cuts)
    #expect(result.mask.contains(.init(x:30,y:42)))
    #expect(!result.mask.contains(.init(x:70,y:18)))
    #expect(!result.contains(.init(x:30,y:42),tolerance:0))
    #expect(restored.removing([action.id]).elementErasures.isEmpty)
  }

  @Test func groupsShareFramesAndMissingOrCyclicAncestryDoesNotInventPlacement() throws {
    typealias Source = NotebookElementPlacement.Source
    let frame = PageRect(x:0,y:0,width:100,height:100)
    var sources: [String:Source] = [:]
    for i in 0..<8 { sources["g\(i)"] = .init(frame:frame,origin:.zero,parentID:i == 0 ? nil : "g\(i-1)",basis:.init(size:.init(x:100,y:100)),isGroup:true) }
    let frozen = sources
    var reads = 0
    let resolver = NotebookElementPlacement.Resolver { reads += 1; return frozen[$0] }
    let leaf = Source(frame:frame,origin:.zero,parentID:"g7",basis:nil,isGroup:false)
    for i in 0..<1000 { _ = try #require(try resolver.resolve("leaf\(i)",source:leaf)) }
    #expect(reads == 8, "Ancestry is resolved once per shared group, not once per leaf")
    let missing = NotebookElementPlacement.Resolver { _ in nil }
    #expect(try missing.resolve("leaf",source:leaf) == nil)
    sources["g0"] = .init(frame:frame,origin:.zero,parentID:"g7",basis:nil,isGroup:true)
    let cyclic = sources
    #expect(try NotebookElementPlacement.Resolver { cyclic[$0] }.resolve("leaf",source:leaf) == nil)
  }
}

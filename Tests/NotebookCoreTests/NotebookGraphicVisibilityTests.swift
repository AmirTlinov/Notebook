import CoreGraphics
import Foundation
import Testing
@testable import NotebookCore

@Suite("Graphic local-frame visibility")
struct NotebookGraphicVisibilityTests {
  @Test func detachedMaskRetainsMeasuredCutsThroughCodecAndLocalBasis() throws {
    let frame=PageRect(x:100,y:200,width:200,height:100)
    let measurements=InkMeasurements([210.0,290.0].map {
      .init(point:.init(x:140,y:$0),timeOffset:0,width:20,opacity:1,force:1,azimuth:0,altitude:1)
    })
    let cut=InkElementErasure(target:.init(elementID:"source",frame:frame),measurements:measurements)
    let mask=NotebookGraphicMask().capturing([cut],transform:nil)
      .appending(.intersect,polygon:[.zero,.init(x:0.5,y:0),.init(x:0.5,y:1),.init(x:0,y:1)])
    #expect(mask.isValid)
    let copied=try JSONDecoder().decode(NotebookGraphicMask.self,from:JSONEncoder().encode(mask))
    #expect(copied == mask)
    #expect(copied.operations.first?.erasures?.first?.samples == measurements)
    #expect(!copied.contains(.init(x:0.2,y:0.5)))
    #expect(copied.contains(.init(x:0.35,y:0.5)))
    #expect(!copied.contains(.init(x:0.75,y:0.5)))
    let large=copied.path(in:.init(x:10,y:20,width:400,height:200))
    #expect(!large.contains(.init(x:90,y:120)))
    #expect(large.contains(.init(x:150,y:120)))
  }

  @Test func pageProjectionSharesImmutableSourceButNotChangedClaimsOrElements() async throws {
    let actor=UUID(),a=AgentElement(id:"a",kind:.graphic,frame:.init(x:10,y:10,width:20,height:20),source:"",html:"",graphic:.init(shape:.ellipse))
    var page=PageDocument(size:.init(width:400,height:400),actor:actor,elements:[a])
    let untouched=page,graph=page.graphicGraph(),encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
    let encoded=try encoder.encode(page)
    #expect(page.element(id:"a") == a)
    #expect(page.graphicGraph().sharesSource(with:graph))
    #expect(try encoder.encode(page) == encoded)
    #expect(try JSONDecoder().decode(PageDocument.self,from:encoded) == page)
    let ink=PageInkDrawing(actions:[.init(tool:.pen,samples:[.init(point:.init(x:5,y:5),timeOffset:0,width:2,opacity:1,force:1,azimuth:0,altitude:1)])])
    let drew=page.replaceDrawing(try ink.dataRepresentation(),actor:actor);#expect(drew)
    #expect(page.graphicGraph().sharesSource(with:graph))
    let edited=page.replaceElements([a.updating(frame:.init(x:100,y:100,width:20,height:20))],actor:actor);#expect(edited)
    #expect(!page.graphicGraph().sharesSource(with:graph))
    #expect(untouched.element(id:"a") == a)
    #expect(untouched.graphicGraph().sharesSource(with:graph))
    await withTaskGroup(of:Bool.self) { group in
      for _ in 0..<16 { group.addTask { untouched.graphicGraph().sharesSource(with:graph) } }
      for await shared in group { #expect(shared) }
    }
  }

  @Test func changedFramesAndExternalConnectionsCannotHideBehindOldBounds() throws {
    let page=PageDocument(size:.init(width:1000,height:1000),actor:UUID(),elements:[
      .init(id:"outer",kind:.group,frame:.init(x:20,y:30,width:200,height:200),source:"",html:"",basis:.init(size:.init(x:200,y:200))),
      .init(id:"inner",kind:.group,frame:.init(x:5,y:5,width:100,height:100),source:"",html:"",parentID:"outer",basis:.init(size:.init(x:100,y:100))),
      .init(id:"a",kind:.graphic,frame:.init(x:10,y:10,width:30,height:40),source:"",html:"",graphic:.init(shape:.rectangle),parentID:"inner"),
      .init(id:"b",kind:.graphic,frame:.init(x:800,y:400,width:50,height:60),source:"",html:"",graphic:.init(shape:.ellipse)),
      .init(id:"link",kind:.graphic,frame:.init(x:0,y:0,width:100,height:100),source:"",html:"",
        graphic:.init(shape:.connector,connection:.init(start:.init(point:.zero,binding:.init(elementID:"a")),end:.init(point:.zero,binding:.init(elementID:"b")),bend:40)),parentID:"inner")])
    let base=page.graphicGraph()
    let addressed=NotebookGraphicGraph([try #require(base.node("a"))])
    #expect(addressed.visiblePageGraphics(page.id,in:.init(x:35,y:45,width:30,height:40)).layouts["a"] != nil)
    #expect(addressed.binding(at:.init(x:45,y:55),surface:.page(page.id),tolerance:0)?.elementID == "a")
    _=base.visiblePageGraphics(page.id,in:.init(x:0,y:0,width:10,height:10))
    func inspect(_ graph:NotebookGraphicGraph) throws {
      for id in ["a","b","link"] {
        let layout:NotebookGraphicLayout=try #require(graph.resolve(id).layout)
        let area=CGRect(x:layout.frame.x,y:layout.frame.y,width:layout.frame.width,height:layout.frame.height)
        let result=graph.visiblePageGraphics(page.id,in:area)
        #expect(result.layouts[id] == layout,"Updated group/connection must not use stale indexed bounds")
      }
    }
    var outer=try #require(base.source("outer"));outer.frame = .init(x:500,y:650,width:200,height:200)
    outer.basis = .init(size:.init(x:200,y:200),transform:.init(a:0,b:1,c:-1,d:0,tx:1,ty:0))
    let moved=base.projecting(placements:["outer":outer]);try inspect(moved)
    var a=try #require(base.source("a"));a.parentID=nil;a.frame = .init(x:450,y:850,width:30,height:40)
    let detached=moved.projecting(placements:["a":a]);try inspect(detached)
    let added=NotebookGraphicGraph.Node(id:"new",graphic:.init(shape:.rectangle),frame:.init(x:450,y:850,width:20,height:20),surface:.page(page.id),shown:true)
    let inserted=detached.projecting(adding:[added])
    #expect(inserted.visiblePageGraphics(page.id,in:.init(x:450,y:850,width:20,height:20)).layouts["new"] != nil)
    var hidden=added.graphic;hidden.visible=false
    #expect(inserted.projecting(graphics:["new":hidden]).visiblePageGraphics(page.id,in:.infinite).layouts["new"] == nil)
    #expect(base.resolve("a").layout == page.graphicGraph().resolve("a").layout)
  }

  @Test func labelsAndThickOrInternallyTransformedPaintAreConservative() throws {
    let pageID=UUID()
    var transformed=NotebookGraphic(shape:.rectangle,style:.init(fill:.black))
    transformed.transform = .init(a:1,b:0,c:0,d:1,tx:4,ty:0)
    let nodes:[NotebookGraphicGraph.Node]=[
      .init(id:"transformed",graphic:transformed,frame:.init(x:100,y:10,width:20,height:20),surface:.page(pageID),shown:true),
      .init(id:"thick",graphic:.init(shape:.rectangle,style:.init(strokeWidth:80)),frame:.init(x:50,y:50,width:1,height:1),surface:.page(pageID),shown:true),
      .init(id:"label",graphic:.init(shape:.rectangle,label:"Длинная подпись"),frame:.init(x:800,y:800,width:1,height:1),surface:.page(pageID),shown:true)]
    let graph=NotebookGraphicGraph(nodes)
    #expect(graph.visiblePageGraphics(pageID,in:.init(x:20,y:50,width:1,height:1)).layouts["thick"] != nil)
    #expect(graph.visiblePageGraphics(pageID,in:.init(x:0,y:0,width:1,height:1)).layouts["label"] != nil)
    #expect(graph.visiblePageGraphics(pageID,in:.init(x:185,y:15,width:1,height:1)).layouts["transformed"] != nil)
    #expect(graph.visiblePageGraphics(UUID(),in:.infinite).layouts.isEmpty)
  }

  @Test func boardWholeCandidatesStayLocalAndRetainOnlyCrossBoundaryDependencies() throws {
    let boardID=UUID(),stamp=VersionStamp(counter:1,actor:UUID())
    let group=SpatialElement(id:"whole",surface:.board(boardID),kind:.group,
      frame:.init(x:20,y:30,width:200,height:200),worldOrigin:.zero,source:"",
      basis:.init(size:.init(x:200,y:200)),stamp:stamp)
    let child=SpatialElement(id:"child",surface:.board(boardID),kind:.graphic,
      frame:.init(x:10,y:15,width:30,height:40),worldOrigin:.zero,source:"",
      graphic:.init(shape:.rectangle),parentID:group.id,stamp:stamp)
    let outside=SpatialElement(id:"outside",surface:.board(boardID),kind:.graphic,
      frame:.init(x:500,y:500,width:30,height:40),worldOrigin:.zero,source:"",
      graphic:.init(shape:.ellipse),stamp:stamp)
    let link=SpatialElement(id:"link",surface:.board(boardID),kind:.graphic,
      frame:.init(x:0,y:0,width:1,height:1),worldOrigin:.zero,source:"",
      graphic:.init(shape:.connector,connection:.init(
        start:.init(point:.zero,binding:.init(elementID:child.id)),
        end:.init(point:.zero,binding:.init(elementID:outside.id)))),stamp:stamp)
    let graph=BoardDocument(freeItems:[],elements:[group,child,outside,link],stamp:stamp).graphicGraph()
    graph.prepareVisibility(on:.board(boardID))
    var moved=try #require(graph.source(group.id));moved.frame = .init(x:700,y:800,width:200,height:200)
    moved.basis = .init(size:.init(x:200,y:200),transform:.init(a:0,b:1,c:-1,d:0,tx:1,ty:0))
    let projected=graph.projecting(placements:[group.id:moved])
    let result=projected.visibleGroupCandidates(group.id,on:.board(boardID),
      in:.init(x:8,y:13,width:34,height:44),limit:16)
    #expect(result.ids == [child.id,link.id])
    #expect(!result.overflow)
    #expect(result.visitedIndexNodes < 8)
  }

  @Test func hundredThousandLeavesAreSkippedAfterOneLocalIndexAdmission() throws {
    let pageID=UUID(),source=NotebookElementPlacement.Source(frame:.init(x:100,y:100,width:1000,height:100),basis:.init(size:.init(x:1000,y:100)),isGroup:true)
    let resolver=NotebookElementPlacement.Resolver { $0 == "whole" ? source : nil }
    let nodes=try (0..<100_000).map { i -> NotebookGraphicGraph.Node in
      let frame=PageRect(x:Double(i%1000),y:Double(i/1000),width:0.6,height:0.6)
      let placement:NotebookElementPlacement=try #require(try resolver.resolve("n\(i)",source:.init(frame:frame,parentID:"whole")))
      return .init(id:"n\(i)",graphic:.init(shape:.rectangle,style:.init(strokeWidth:0.1)),frame:frame,surface:.page(pageID),shown:true,placement:placement)
    }
    let graph=NotebookGraphicGraph(nodes,groupSources:["whole":.init(source:source,surface:.page(pageID))],resolvers:[.page(pageID):resolver])
    let area=CGRect(x:400.25,y:140.25,width:1.1,height:1.1),expected:Set<String>=["n40300","n40301","n41300","n41301"]
    let clock=ContinuousClock(),start=clock.now,cold=graph.visiblePageGraphics(pageID,in:area),prepared=clock.now
    #expect(Set(cold.layouts.keys) == expected)
    var times:[Double]=[],maximumVisits=0,maximumResolved=0
    func milliseconds(_ duration:Duration) -> Double {
      let c=duration.components;return Double(c.seconds)*1000+Double(c.attoseconds)/1e15
    }
    for i in 0..<100 {
      var moved=source;moved.frame = .init(x:Double(300+i),y:400,width:1000,height:100)
      let begin=clock.now,next=graph.projecting(placements:["whole":moved])
      let result=next.visiblePageGraphics(pageID,in:area.offsetBy(dx:Double(200+i),dy:300))
      times.append(milliseconds(begin.duration(to:clock.now)))
      maximumVisits=max(maximumVisits,result.visitedIndexNodes);maximumResolved=max(maximumResolved,result.resolvedGraphics)
      #expect(Set(result.layouts.keys) == expected)
      #expect(next.sharesSource(with:graph))
    }
    #expect(maximumVisits<200);#expect(maximumResolved == 4)
    let fullStart=clock.now
    let full=Set(graph.nodes.values.compactMap { node -> String? in
      guard let frame=graph.resolve(node.id).layout?.frame,
        area.intersects(.init(x:frame.x,y:frame.y,width:frame.width,height:frame.height)) else { return nil };return node.id
    })
    let fullEnd=clock.now;#expect(full == expected)
    times.sort()
    print("GUI291 visible 100000: coldLocalIndexQuery=\(milliseconds(start.duration(to:prepared))) ms; 100 whole-pose+query p50=\(times[49]) p95=\(times[94]) ms; fullSourceScan=\(milliseconds(fullStart.duration(to:fullEnd))) ms; maximumIndexVisits=\(maximumVisits), resolvedLeaves=\(maximumResolved), boundsTreeBytes=\(cold.boundsIndexBytes); source admission and painting excluded")
  }

  @Test func hundredThousandNativeElementsUseTheSameBoundedPageIndex() throws {
    let pageID=UUID()
    let elements=Dictionary(uniqueKeysWithValues:(0..<100_000).map { i in
      let source=NotebookElementPlacement.Source(
        frame:.init(x:Double(i%1000),y:Double(i/1000),width:0.6,height:0.6))
      return ("n\(i)",NotebookGraphicGraph.ElementSource(source:source,surface:.page(pageID)))
    })
    let graph=NotebookGraphicGraph([],groupSources:[:],elementSources:elements)
    let area=CGRect(x:300.25,y:40.25,width:1.1,height:1.1)
    let local=graph.visiblePageGraphics(pageID,in:area,limit:96)
    #expect(Set(local.placements.keys) == ["n40300","n40301","n41300","n41301"])
    #expect(local.layouts.isEmpty)
    #expect(!local.overflow)
    #expect(local.visitedIndexNodes<200)
    let dense=graph.visiblePageGraphics(pageID,in:.infinite,limit:96)
    #expect(dense.overflow)
    #expect(dense.visitedIndexNodes<400)
    print("GUI291 native page eraser 100000: local=\(local.placements.count), localIndexVisits=\(local.visitedIndexNodes), denseLimit=96, denseIndexVisits=\(dense.visitedIndexNodes), overflow=\(dense.overflow), boundsTreeBytes=\(local.boundsIndexBytes); exact targets and painting excluded")
  }
}

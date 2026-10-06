import Foundation
import Testing
@testable import NotebookCore

@Suite("Captured lasso source size follows immutable content")
struct NotebookCapturedSourceSizeTests {
  @Test func spatialMaskCaptureKeepsEverySpanAndOldVisibilityRoot() throws {
    let actor=UUID(),surface=SurfaceID.cover(UUID()),target=InkElementTarget(elementID:"shape",frame:.init(x:0,y:0,width:100,height:100))
    func sample(_ x:Double)->SpatialInkSample {
      .init(point:.init(x:x,y:20),timeOffset:0,width:3,opacity:1,force:1,azimuth:0,altitude:1)
    }
    var journal=SpatialInkJournal(stamp:.init(counter:0,actor:actor))
    let appended=journal.append(tool:.eraser,spans:[
      .init(surface:surface,samples:[sample(20)],elementTargets:[target]),
      .init(surface:surface,samples:[sample(80)],elementTargets:[target])],actor:actor)
    let action=try #require(appended)
    let bounds=WorkspaceSpatialBounds(origin:.zero,width:100,height:100)
    let captured=try journal.regionCapture(on:surface,in:bounds,elements:["shape"],excluding:[],maximumCount:4)
    let bytes=captured.erasures.retainedPayloadBytes
    #expect(captured.erasures["shape"]?.map {$0.samples.first!.point.x} == [20,80])
    #expect(captured.erasures.retainedPayloadBytes == bytes,"Disclosure cannot enlarge the admitted mask bound")
    let hidden=journal.deactivate(action.id,actor:actor);#expect(hidden)
    #expect(try journal.regionCapture(on:surface,in:bounds,elements:["shape"],excluding:[],maximumCount:4).erasures.isEmpty)
    let reactivated=journal.activate(action.id,actor:actor);#expect(reactivated)
    let restored=try journal.regionCapture(on:surface,in:bounds,elements:["shape"],excluding:[],maximumCount:4)
    #expect(restored.erasures == captured.erasures)
    #expect(restored.erasures.retainedPayloadBytes == bytes)
  }

  @Test func maskCaptureDoesNotWalkOneHundredThousandCutsOrForeignTargets() throws {
    let actor=UUID(),surface=SurfaceID.cover(UUID()),stamp=VersionStamp(counter:100_001,actor:actor)
    let samples=InkMeasurements([.init(point:.init(x:20,y:20),timeOffset:0,width:3,opacity:1,force:1,azimuth:0,altitude:1)])
    let target=InkElementTarget(elementID:"shape",frame:.init(x:0,y:0,width:100,height:100))
    let bounds=WorkspaceSpatialBounds(origin:.zero,width:100,height:100)
    for history in [true,false] {
      let actions:[PageInkAction]
      if history {
        actions=(1...100_000).map {.init(tool:.eraser,measurements:samples,sequence:UInt64($0),elementTargets:[target])}
      } else {
        let foreign=(1..<100_000).map {InkElementTarget(elementID:"foreign-\($0)",frame:target.frame)}
        actions=[.init(tool:.eraser,measurements:samples,sequence:1,elementTargets:[target]+foreign)]
      }
      let pageStart=ContinuousClock.now
      let document=PageDocument(size:.init(width:834,height:1194),actor:actor,
        drawingData:try PageInkDrawing(actions:actions).dataRepresentation())
      let page=document.inkSource
      try page.prepareForPresentation()
      let pagePrepared=pageStart.duration(to:.now),pageStartCapture=ContinuousClock.now
      let pageCut=try #require(try page.regionCapture(in:bounds,elements:["shape"],excluding:[],maximumCount:4))
      let pageBytes=pageCut.retainedPayloadBytes,pageTime=pageStartCapture.duration(to:.now)
      let spatialStart=ContinuousClock.now
      let journal=SpatialInkJournal(actions:actions.map {action in
        .init(id:action.id,tool:.eraser,spans:[.init(surface:surface,measurements:action.samples,elementTargets:action.elementTargets)],
          stamp:.init(counter:action.sequence,actor:actor))
      },stamp:stamp)
      let spatialPrepared=spatialStart.duration(to:.now),spatialStartCapture=ContinuousClock.now
      let spatialCut=try journal.regionCapture(on:surface,in:bounds,elements:["shape"],excluding:[],maximumCount:4)
      let spatialBytes=spatialCut.retainedPayloadBytes,spatialTime=spatialStartCapture.duration(to:.now)
      #expect(pageCut.contacts.isEmpty && spatialCut.contacts.isEmpty)
      #expect(pageCut.erasures.keys == ["shape"] && spatialCut.erasures.keys == ["shape"])
      #expect(pageBytes == spatialBytes)
      if !history {#expect(pageBytes < 8192,"Foreign target fanout cannot enter an addressed cut")}
      // Array disclosure happens only after the timed capture/accounting path.
      #expect(pageCut.erasures["shape"]?.count == (history ? 100_000:1))
      #expect(spatialCut.erasures["shape"] == pageCut.erasures["shape"])
      #expect(pageCut.retainedPayloadBytes == pageBytes && spatialCut.retainedPayloadBytes == spatialBytes)
      print("LASSO_MASK_OWNER history=\(history) entries=100000 page_preparation=\(pagePrepared) spatial_preparation=\(spatialPrepared) page_capture_and_size=\(pageTime) spatial_capture_and_size=\(spatialTime) captured_bytes=\(pageBytes)")
    }
  }

  @Test func compactInkCaptureReleasesItsJournalAndKeepsOriginalPaintOrder() throws {
    let actor=UUID(),surface=SurfaceID.cover(UUID()),stamp=VersionStamp(counter:1,actor:actor)
    func sample(_ x:Double)->SpatialInkSample {
      .init(point:.init(x:x,y:20),timeOffset:0,width:3,opacity:0.6,force:0.7,azimuth:0.4,altitude:1)
    }
    let earlier=PageInkAction(tool:.eraser,samples:[sample(20)],sequence:1)
    let pen=PageInkAction(tool:.pen,samples:[sample(20),sample(80)],sequence:2)
    let later=PageInkAction(tool:.eraser,samples:[sample(80)],sequence:3,
      elementTargets:[.init(elementID:"shape",frame:.init(x:0,y:0,width:100,height:100))])
    let unrelated=PageInkAction(tool:.pen,samples:[sample(500)],sequence:4)
    let bounds=WorkspaceSpatialBounds(origin:.zero,width:35,height:40)
    weak var pageRoot:PageInkDrawingCache.Source?
    weak var spatialRoot:SpatialInkActionStorage?
    let pageCut:NotebookInkRegionCapture,spatialCut:NotebookInkRegionCapture
    do {
      let page=PageDocument(size:.init(width:834,height:1194),actor:actor,
        drawingData:try PageInkDrawing(actions:[earlier,pen,later,unrelated]).dataRepresentation())
      try page.prepareInkForPresentation();pageRoot=page.inkSource.source
      pageCut=try #require(try page.inkSource.regionCapture(in:bounds,elements:["shape"],excluding:[],maximumCount:4))
      let actions=[earlier,pen,later,unrelated].enumerated().map {i,action in
        SpatialInkAction(id:action.id,tool:action.tool,spans:[.init(surface:surface,measurements:action.samples,elementTargets:action.elementTargets)],
          stamp:.init(counter:UInt64(i+1),actor:actor))
      }
      let journal=SpatialInkJournal(actions:actions,stamp:stamp);spatialRoot=journal.storage
      spatialCut=try journal.regionCapture(on:surface,in:bounds,elements:["shape"],excluding:[],maximumCount:4)
    }
    #expect(pageRoot == nil && spatialRoot == nil,"A compact region cannot retain either original immutable root")
    for cut in [pageCut,spatialCut] {
      #expect(cut.contacts.map(\.id) == [earlier.id,pen.id,later.id])
      #expect(cut.contacts[1].sources[0].measurements == pen.samples)
      #expect(cut.contacts.allSatisfy {$0.sources.allSatisfy {$0.header.elementTargets == nil}},
        "Raw contact relations do not retain an eraser's unrelated target fanout")
      #expect(cut.erasures["shape"]?.count == 1)
      #expect(cut.retainedPayloadBytes < 16_384)
    }
  }

  @Test func capturedFrontierRejectsSameBodyAndLargeForeignReplacementBeforeReadingBodies() throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("captured-frontier-\(UUID())")
    defer {try? FileManager.default.removeItem(at:root)}
    let actor=UUID(),pageID=UUID(),store=NotebookStore(root:root)
    _ = try store.initializeWorkspace(actor:actor,pageSize:.init(width:834,height:1194),initialPageID:pageID)
    let target=CollaborationTarget(kind:.page,id:pageID),frame=PageRect(x:20,y:30,width:100,height:80)
    func mutate(_ kind:CollaborationOperation.Kind,_ values:[String:JSONValue]) throws {
      let revision=try store.targetContentRevision(target:target)
      _ = try store.applyNativeAction(.init(summary:"Peer",
        references:[.init(target:target,elementID:"source",revision:revision)],
        expected:[.init(target:target,revision:revision)],
        operations:[.init(kind:kind,target:target,id:"source",values:values)]),actor:UUID())
    }
    try mutate(.insertElement,["kind":.string("graphic"),"source":.string(""),
      "frame":.encode(frame),"graphic":.encode(NotebookGraphic(shape:.rectangle))])
    let cut=try store.loadPage(pageID).elementSourceSnapshot.capturing(["source"])
    let captured=cut.nativeSource("source",target:target),bytes=try #require(cut.captureSize).bytes
    #expect(captured.versions != nil)
    try mutate(.updateElement,["frame":.encode(PageRect(x:60,y:30,width:100,height:80))])
    try mutate(.updateElement,["frame":.encode(frame)])
    #expect(try store.readNativeElementSource(target:target,id:"source").page == captured.page)
    let edit=CollaborationOperation(kind:.updateElement,target:target,id:"source",
      values:["frame":try .encode(PageRect(x:150,y:30,width:100,height:80))])
    for largeReplacement in [false,true] {
      if largeReplacement {
        try mutate(.updateElement,["graphic":.object([
          "label":.string(String(repeating:"foreign replacement",count:5_000))])])
      }
      let cursor=try store.currentChangeCursor()
      do {
        try store.commandTransaction(readAllowance:.init(rows:256,bytes:131_072,valueBytes:32_768,reason:"captured_frontier")) {
          _ = try store.applyNativeElementEdits([edit],summary:"Old captured cut",sources:[captured],actor:actor)
        }
        Issue.record("A captured causal source cannot borrow a peer's successor")
      } catch let error as CollaborationError {#expect(error.code == "revision_conflict")}
      #expect(try store.currentChangeCursor() == cursor)
      #expect(cut.captureSize?.bytes == bytes)
    }
  }

  @Test func inkAppendAndVisibilityKeepTheCapturedBound() throws {
    let actor=UUID(),surface=SurfaceID.cover(UUID())
    let sample=SpatialInkSample(point:.init(x:10,y:20),timeOffset:0,width:3,opacity:1,force:1,azimuth:0,altitude:1)
    let pen=PageInkAction(tool:.pen,samples:[sample])
    let cut=PageInkAction(tool:.eraser,samples:[sample],elementTargets:[.init(elementID:"shape",frame:.init(x:0,y:0,width:100,height:100))])
    let first=try PageInkDrawing().appending(pen),both=try first.appending(cut)
    #expect(both.retainedPayloadBytes > first.retainedPayloadBytes)
    let hidden=try both.settingActive(false,for:[cut.id],stamp:.init(counter:3,actor:actor))
    #expect(hidden.retainedPayloadBytes == both.retainedPayloadBytes)
    #expect(first.actions.count == 1)
    #expect(try PageInkDrawing.decode(both.dataRepresentation()).retainedPayloadBytes == both.retainedPayloadBytes)
    var page=PageDocument(size:.init(width:100,height:100),actor:actor)
    #expect(page.replaceDrawing(try both.dataRepresentation(),actor:actor))
    let captured=page.inkSource
    try captured.prepareForPresentation()
    #expect(captured.preparedElementErasures?["shape"]?.count == 1)
    let bounds=WorkspaceSpatialBounds(origin:.zero,width:50,height:50)
    let capture=try #require(try captured.regionCapture(in:bounds,elements:["shape"],excluding:[],maximumCount:4))
    #expect(capture.erasures["shape"]?.count == 1)
    #expect(page.replaceDrawing(try hidden.dataRepresentation(),actor:actor))
    try page.inkSource.prepareForPresentation()
    #expect(page.inkSource.preparedElementErasures?["shape"] == nil)
    #expect(captured.preparedElementErasures?["shape"]?.count == 1)
    let changed=try #require(try page.inkSource.regionCapture(in:bounds,elements:["shape"],excluding:[],maximumCount:4))
    #expect(changed.materialBytes < capture.materialBytes)

    var journal=SpatialInkJournal(stamp:.init(counter:0,actor:actor))
    let appended=journal.append(tool:.pen,spans:[.init(surface:surface,samples:[sample])],actor:actor)
    #expect(appended != nil)
    let before=journal
    let addedEraser=journal.append(tool:.eraser,spans:[.init(surface:surface,samples:[sample],elementTargets:cut.elementTargets)],actor:actor)
    let erased=try #require(addedEraser)
    let bytes=journal.retainedPayloadBytes
    #expect(bytes > before.retainedPayloadBytes)
    let hiddenEraser=journal.deactivate(erased.id,actor:actor)
    #expect(hiddenEraser)
    #expect(journal.retainedPayloadBytes <= bytes)
    #expect(journal.action(id:erased.id)?.spans == erased.spans)
    let spatialCapture=try journal.regionCapture(on:surface,in:bounds,elements:["shape"],excluding:[],maximumCount:4)
    #expect(spatialCapture.erasures.isEmpty)
  }

  @Test func claimedRawContactsDoNotSpendTheVisibleCandidateLimit() throws {
    let actor=UUID(),sample=SpatialInkSample(point:.init(x:20,y:20),timeOffset:0,
      width:3,opacity:1,force:1,azimuth:0,altitude:1)
    let contacts=(1...3).map {PageInkAction(tool:.pen,samples:[sample],sequence:UInt64($0))}
    var page=PageDocument(size:.init(width:100,height:100),actor:actor,
      drawingData:try PageInkDrawing(actions:contacts).dataRepresentation())
    try page.prepareInkForPresentation()
    let before=page.inkSource,bounds=WorkspaceSpatialBounds(origin:.zero,width:50,height:50)
    let excluded=Set(contacts.dropFirst().map(\.id))
    let selected=try #require(try before.regionCapture(in:bounds,elements:[],excluding:excluded,maximumCount:1))
    do {
      _ = try before.regionCapture(in:bounds,elements:[],excluding:[],maximumCount:1)
      Issue.record("Visible contacts still obey the unchanged selection limit")
    } catch let error as CollaborationError {#expect(error.code == "selection_limit")}
    let change=try page.prepareLiveInkChange(.setActive(excluded,false),stamp:.init(counter:4,actor:actor))
    let published=page.publishInkChange(change);#expect(published)
    let hidden=try #require(try page.inkSource.regionCapture(in:bounds,elements:[],excluding:[],maximumCount:1))
    #expect(hidden.materialBytes == selected.materialBytes)
    #expect(throws:CollaborationError.self) {
      try before.regionCapture(in:bounds,elements:[],excluding:[],maximumCount:1)
    }
  }

  @Test func oneHundredThousandContactOwnerKeepsAddressedQueryAppendAndVisibility() throws {
    let actor=UUID(),bounds=WorkspaceSpatialBounds(origin:.zero,width:50,height:50)
    func contact(_ sequence:Int,_ point:SpatialPoint)->PageInkAction {
      .init(tool:.pen,samples:[.init(point:point,timeOffset:0,width:3,opacity:1,force:1,azimuth:0,altitude:1)],
        sequence:UInt64(sequence))
    }
    let chosen=contact(1,.init(x:20,y:20)),foreign=(2...100_000).map {contact($0,.init(x:1_500,y:1_500))}
    var page=PageDocument(size:.init(width:2048,height:2048),actor:actor,
      drawingData:try PageInkDrawing(actions:[chosen]+foreign).dataRepresentation())
    let preparation=ContinuousClock.now
    try page.prepareInkForPresentation()
    let prepared=preparation.duration(to:.now),old=page.inkSource,start=ContinuousClock.now
    let selected=try #require(try old.regionCapture(in:bounds,elements:[],excluding:[],maximumCount:1))
    let queried=start.duration(to:.now),excluded=Set(foreign.map(\.id)),all=ContinuousClock.now
    let visible=try #require(try old.regionCapture(in:.init(origin:.zero,width:2048,height:2048),
      elements:[],excluding:excluded,maximumCount:1))
    let excludedQuery=all.duration(to:.now)
    #expect(visible.materialBytes == selected.materialBytes)
    #expect(selected.contacts.map(\.id) == [chosen.id])
    #expect(selected.retainedPayloadBytes < 4096,"Foreign contacts and index memory do not enter the retained cut")
    let sparseVisible=Set([chosen.id]+foreign.enumerated().filter {($0.offset+1).isMultiple(of:256)}.map(\.element.id))
    let interleaved=excluded.subtracting(sparseVisible),mixedStart=ContinuousClock.now
    let mixed=try #require(try old.regionCapture(in:.init(origin:.zero,width:2048,height:2048),
      elements:[],excluding:interleaved,maximumCount:512))
    let mixedQuery=mixedStart.duration(to:.now)
    #expect(mixed.materialBytes > selected.materialBytes)
    #expect(mixed.materialBytes < selected.materialBytes*512)
    let next=contact(100_001,.init(x:30,y:20)),appendStart=ContinuousClock.now
    let append=try page.prepareLiveInkChange(.append(next),stamp:.init(counter:1,actor:actor))
    let published=page.publishInkChange(append);#expect(published)
    let appended=appendStart.duration(to:.now)
    let both=try #require(try page.inkSource.regionCapture(in:bounds,elements:[],excluding:[],maximumCount:2))
    #expect(both.materialBytes > selected.materialBytes)
    let visibilityStart=ContinuousClock.now
    let hide=try page.prepareLiveInkChange(.setActive([next.id],false),stamp:.init(counter:2,actor:actor))
    let publishedHide=page.publishInkChange(hide);#expect(publishedHide)
    let hidden=visibilityStart.duration(to:.now)
    let restored=try #require(try page.inkSource.regionCapture(in:bounds,elements:[],excluding:[],maximumCount:1))
    #expect(restored.materialBytes == selected.materialBytes)
    let groupStart=ContinuousClock.now,ids=Set(foreign.prefix(255).map(\.id))
    let group=try page.prepareLiveInkChange(.setActive(ids,false),stamp:.init(counter:3,actor:actor))
    let publishedGroup=page.publishInkChange(group);#expect(publishedGroup)
    let grouped=groupStart.duration(to:.now)
    #expect(ids.allSatisfy {page.preparedInkDrawing?.action(id:$0)?.isActive == false})
    #expect(old.preparedDrawing?.actionCount == 100_000)
    print("LASSO_CONTACT_OWNER contacts=100000 preparation=\(prepared) sparse_query=\(queried) all_excluded_query=\(excludedQuery) interleaved_query=\(mixedQuery) append=\(appended) visibility=\(hidden) grouped_visibility_255=\(grouped) material_bytes=\(selected.materialBytes) captured_bytes=\(selected.retainedPayloadBytes) root_bytes=\(old.retainedPayloadBytes!)")
  }

  @Test func sourceBoundsFollowProgramStateWithoutChangingTheCapturedValue() throws {
    let actor=UUID(),web=AgentElement(id:"program",kind:.web,frame:.init(x:0,y:0,width:100,height:100),source:"",html:"<p>Saved</p>")
    var page=PageDocument(size:.init(width:834,height:1194),actor:actor,elements:[web])
    let captured=page.elementSourceSnapshot.capturing([web.id]),initial=try #require(captured.captureSize).bytes
    let changed=page.replaceProgramState(.object(["content":.string(String(repeating:"x",count:8192))]),elementID:web.id,actor:actor)
    #expect(changed)
    #expect(try #require(page.elementSourceSnapshot.capturing([web.id]).captureSize).bytes > initial)
    #expect(captured.captureSize?.bytes == initial)
    #expect(captured.pageElement(web.id)?.state == web.state)
    #expect(page.elementSourceSnapshot.pageElement(web.id)?.state != web.state)
  }

  @Test func coldSmallCaptureDoesNotRetainOneHundredThousandForeignBodiesOrClocks() throws {
    struct Archive:Encodable {
      let format=PageDocument.formatVersion,id=UUID(),size=PageSize(width:2048,height:2048),drawingData=Data()
      let drawingStamp:VersionStamp,agentStamp:VersionStamp,elements:[AgentElement],collaboration:CollaborativeContent
    }
    let stamp=VersionStamp(counter:1,actor:UUID())
    var capturedBytes:[Int]=[]
    for count in [1,100_000] {
      let elements=(0..<count).map { i in AgentElement(id:"part-\(i)",kind:.graphic,
        frame:.init(x:i == 0 ? 10 : 1500,y:i == 0 ? 10 : 1500,width:10,height:10),source:"",html:"",
        graphic:.init(shape:.rectangle,style:.init(fill:.black))) }
      let metadata=CollaborativeContent(fields:Dictionary(uniqueKeysWithValues:elements.map {
        (fieldKey(["elements",$0.id,"id"]),ContentFieldVersion(stamp:stamp,human:true))
      }))
      let page=try JSONDecoder().decode(PageDocument.self,from:JSONEncoder().encode(
        Archive(drawingStamp:stamp,agentStamp:stamp,elements:elements,collaboration:metadata)))
      // These are existing scene/identity indices, prepared by the scene owner.
      // No source snapshot or capture-size query is warmed before the clock.
      let preparation=ContinuousClock.now,graph=page.graphicGraph()
      graph.prepareVisibility(on:.page(page.id))
      let prepared=preparation.duration(to:.now),start=ContinuousClock.now
      let visible=graph.visiblePageGraphics(page.id,in:.init(x:5,y:5,width:20,height:20),limit:4096)
      let cut=try graph.capturing(Set(visible.layouts.keys),maximumCount:4096)
      let snapshot=page.elementSourceSnapshot.capturing(cut.ids)
      let bytes=try #require(snapshot.captureSize).bytes+cut.graph.retainedPayloadBytes
      let elapsed=start.duration(to:.now)
      #expect(cut.ids == ["part-0"] && snapshot.orderedIDs(cut.ids) == ["part-0"])
      #expect(snapshot.pageElement("part-99999") == nil)
      #expect(snapshot.captureSize!.editableCausalBytes > 0)
      capturedBytes.append(bytes)
      print("LASSO_COLD_SOURCE bodies=\(count) causal_fields=\(count) scene_index=\(prepared) cold_capture=\(elapsed) retained_bytes=\(bytes)")
    }
    #expect(capturedBytes[0] == capturedBytes[1],"Foreign bodies and clocks do not enter an addressed cut")
  }

  @Test func capturedConnectorKeepsItsExternalEndpointsAndParentFrames() throws {
    let page=PageDocument(size:.init(width:1000,height:1000),actor:UUID(),elements:[
      .init(id:"group",kind:.group,frame:.init(x:80,y:60,width:300,height:200),source:"",html:"",
        basis:.init(size:.init(x:200,y:100),transform:.init(a:0.7,b:0,c:0.3,d:1,tx:0,ty:0))),
      .init(id:"a",kind:.graphic,frame:.init(x:10,y:20,width:60,height:50),source:"",html:"",
        graphic:.init(shape:.rectangle,style:.init(fill:.black)),parentID:"group"),
      .init(id:"b",kind:.graphic,frame:.init(x:500,y:200,width:80,height:100),source:"",html:"",graphic:.init(shape:.ellipse)),
      .init(id:"foreign",kind:.graphic,frame:.init(x:700,y:700,width:10,height:10),source:"",html:"",graphic:.init(shape:.rectangle)),
      .init(id:"link",kind:.graphic,frame:.init(x:50,y:50,width:300,height:100),source:"",html:"",
        graphic:.init(shape:.connector,connection:.init(start:.init(point:.zero,binding:.init(elementID:"a")),
          end:.init(point:.init(x:300,y:100),binding:.init(elementID:"b")),bend:20)))])
    let graph=page.graphicGraph(),cut=try graph.capturing(["link"],maximumCount:4096)
    let snapshot=page.elementSourceSnapshot.capturing(cut.ids)
    #expect(cut.ids == ["link","a","b","group"])
    #expect(snapshot.orderedIDs(cut.ids) == ["group","a","b","link"])
    #expect(snapshot.pageElement("foreign") == nil && cut.graph.node("foreign") == nil)
    let before=try #require(graph.resolve("link").layout),after=try #require(cut.graph.resolve("link").layout)
    #expect(after.frame == before.frame && after.start == before.start && after.end == before.end)
    #expect(cut.graph.node("a")?.placement.ancestors == ["group"])
    #expect(cut.graph.source("group") == graph.source("group"))
    #expect(throws:CollaborationError.self) { try graph.capturing(["link"],maximumCount:3) }
  }
}

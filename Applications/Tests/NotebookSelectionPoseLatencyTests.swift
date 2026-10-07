import Metal
import NotebookCore
import UIKit
import XCTest
@testable import Notebook

/// Replays the ordinary selection owner into a real mounted ink drawable.
/// Foreign body preparation is measured separately; no readback enters motion.
@MainActor final class NotebookSelectionPoseLatencyTests: XCTestCase {
  func testInstalledSelectionPoseLatencyAtOneAnd100000ForeignBodies() async throws {
    #if targetEnvironment(simulator)
    throw XCTSkip("OS Metal presentation receipts require the physical iPad")
    #endif
    for foreignCount in [1,100_000] {try await run(foreignCount:foreignCount)}
  }

  private func run(foreignCount:Int) async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("selection-pose-\(UUID())")
    let model=NotebookAppModel(store:.init(root:root),startsNearbySync:false,
      preferences:UserDefaults(suiteName:UUID().uuidString)!)
    await model.start(pageSize:NotebookAppModel.defaultPageSize)
    let saved=await model.finishPendingPersistence();XCTAssertTrue(saved)
    let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous=scene.windows.first(where:\.isKeyWindow),window=UIWindow(windowScene:scene)
    let controller=UIViewController(),resources=SceneRenderResources(),canvas=InkCanvasView(frame:.zero,resources:resources)
    window.rootViewController=controller;controller.view.backgroundColor = .white
    controller.view.addSubview(canvas);window.makeKeyAndVisible()
    let consumer=Consumer(canvas)
    var page=try XCTUnwrap(model.activePage)
    model.pageInkPublication.register(consumer,pageID:page.id)
    defer {
      model.pageInkPublication.remove(consumer)
      canvas.onOrderedFrameInstalled=nil;canvas.onOrderedFrameResolved=nil
      canvas.removeFromSuperview();window.isHidden=true;window.rootViewController=nil;previous?.makeKey()
      try? FileManager.default.removeItem(at:root)
    }
    do {
      let pageID=page.id,frame=PageRect(x:0,y:0,width:160,height:160)
      func action(_ x:Double,sequence:UInt64)->PageInkAction {
        .init(tool:.pen,samples:[30.0,130].map {dx in
          .init(point:.init(x:x+dx,y:80),timeOffset:dx/240,width:12,opacity:1,force:1,azimuth:0,altitude:.pi/2)
        },sequence:sequence)
      }
      let moving=action(0,sequence:1),neighbor=action(220,sequence:2)
      func graphic(_ action:PageInkAction,frame:PageRect)->NotebookGraphic {
        .init(shape:.freehand,sourceInkIDs:[action.id],freehand:.init(layers:[
          .init(tool:.pen,color:.black,measured:.init(sourceID:action.id,measurements:action.samples,frame:frame))]))
      }
      let movingGraphic=graphic(moving,frame:frame)
      let neighborFrame=PageRect(x:220,y:0,width:160,height:160),neighborGraphic=graphic(neighbor,frame:neighborFrame)
      XCTAssertTrue(page.replaceDrawing(try PageInkDrawing(actions:[moving,neighbor]).dataRepresentation(),actor:model.actorID))
      XCTAssertTrue(page.replaceElements([
        .init(id:"pose-moving",kind:.graphic,frame:frame,source:"",html:"",graphic:movingGraphic),
        .init(id:"pose-neighbor",kind:.graphic,frame:neighborFrame,source:"",html:"",graphic:neighborGraphic)],actor:model.actorID))
      try model.store.savePage(page);await model.reloadExternalChanges()?.value
      canvas.projectPage(region:.init(x:0,y:0,width:400,height:400),sourceSize:.init(width:page.size.width,height:page.size.height),pixelDensity:2)
      canvas.apply(.init(actions:[moving,neighbor]))
      try await ready(canvas)
      let before=footprint(),setupBegan=CACurrentMediaTime()
      var bodies:[NotebookOrderedInkPlan.Body]=[];bodies.reserveCapacity(foreignCount+2)
      func body(_ id:String,_ sourceID:UUID,_ graphic:NotebookGraphic,_ rect:PageRect,_ sequence:UInt64) throws -> NotebookOrderedInkPlan.Body {
        let node=NotebookGraphicGraph.Node(id:id,graphic:graphic,frame:rect,surface:.page(pageID),shown:true)
        let layout=try XCTUnwrap(NotebookGraphicGraph([node]).resolve(id).layout)
        return .init(elementID:id,key:.page(sequence:sequence,id:sourceID),graphic:graphic,layout:layout,erasures:[])
      }
      bodies.append(try body("pose-moving",moving.id,movingGraphic,frame,1))
      bodies.append(try body("pose-neighbor",neighbor.id,neighborGraphic,neighborFrame,2))
      let measurements=InkMeasurements([30.0,130].map {x in
        SpatialInkSample(point:.init(x:x,y:80),timeOffset:x/240,width:12,opacity:1,force:1,azimuth:0,altitude:.pi/2)
      })
      for index in 0..<foreignCount {
        let id=UUID(),rect=PageRect(x:450+Double(index%1_000)*0.1,y:450+Double(index/1_000)*5,width:160,height:160)
        let foreign=NotebookGraphic(shape:.freehand,sourceInkIDs:[id],freehand:.init(layers:[
          .init(tool:.pen,color:.black,measured:.init(sourceID:id,measurements:measurements,frame:frame))]))
        bodies.append(try body("pose-foreign-\(index)",id,foreign,rect,UInt64(index+3)))
      }
      let plan=NotebookOrderedInkPlan(bodies:bodies,suppressedInkIDs:Set(bodies.map(\.sourceID)))
      let setupMS=(CACurrentMediaTime()-setupBegan)*1_000,prepareBegan=CACurrentMediaTime()
      var peak=footprint()
      let memory=Task { @MainActor in
        while !Task.isCancelled {
          peak=max(peak,self.footprint())
          do {try await Task.sleep(for:.milliseconds(100))} catch {return}
        }
      }
      let prepared:InkOrderedGeometry?
      do {prepared=try await canvas.prepareOrderedPlan(plan)} catch {
        memory.cancel()
        let refusal="foreign=\(foreignCount); setupMS=\(setupMS); prepareMS=\((CACurrentMediaTime()-prepareBegan)*1_000); error=\(error); footprintBefore=\(before); footprintNow=\(footprint()); peak=\(peak); accounted=\(resources.residentBytes+resources.reservedBytes)/\(resources.byteLimit). No motion result exists after refused preparation. Ordinary resource admission was unchanged."
        attach(refusal,name:"selection-pose-\(foreignCount)-preparation-refusal")
        throw error
      }
      let prepareMS=(CACurrentMediaTime()-prepareBegan)*1_000,installBegan=CACurrentMediaTime()
      try await canvas.presentOrderedPlan(prepared,plan:plan,canonical:true)
      try await ready(canvas);memory.cancel();peak=max(peak,footprint())
      attach("foreign=\(foreignCount); totalOrdered=\(canvas.orderedInkPlan.bodies.count); setupMS=\(setupMS); prepareMS=\(prepareMS); initialInstallMS=\((CACurrentMediaTime()-installBegan)*1_000); footprintBefore=\(before); footprintPrepared=\(footprint()); preparationPeak=\(peak); accounted=\(resources.residentBytes+resources.reservedBytes)/\(resources.byteLimit); thermal=\(ProcessInfo.processInfo.thermalState.rawValue); lowPower=\(ProcessInfo.processInfo.isLowPowerModeEnabled); screenMax=\(scene.screen.maximumFramesPerSecond); maximumDrawable=\(canvas.drawableSize). SQL and model assembly of foreign members are outside this native owner replay; their geometry, clip buffers and painter ranks are admitted through the ordinary owner.",name:"selection-pose-\(foreignCount)-preparation")
      XCTAssertEqual(canvas.orderedInkPlan.bodies.count,foreignCount+2)
      try pixels(canvas,window:window,points:[(.init(x:80,y:80),.black),(.init(x:300,y:80),.black),(.init(x:80,y:260),.paper)],name:"selection-pose-\(foreignCount)-initial")

      let reference=EditableElementReference.page(pageID:pageID,elementID:"pose-moving")
      XCTAssertTrue(model.selectElements([reference]))
      XCTAssertEqual(model.selectionSession.elements,[reference]);XCTAssertTrue(model.selectionSession.ink.isEmpty)
      let contact=try XCTUnwrap(model.beginElementManipulation(reference,kind:.move))
      let owner=try XCTUnwrap(model.selectionSession.manipulation?.inkPresentation)
      let original=try XCTUnwrap(model.selectionSession.manipulation).original
      let monitor=Motion(canvas:canvas,owner:owner,original:original)
      let began=CACurrentMediaTime()
      for index in 0..<120 {
        let due=began+Double(index)/120,remaining=due-CACurrentMediaTime()
        if remaining>0 {try await Task.sleep(for:.seconds(remaining))}
        let dy=Double(index+1)*1.5
        monitor.input(index:index,due:due,frame:original.offsetBy(dx:0,dy:dy)) {
          model.updateElementManipulation(contact,translation:.init(x:0,y:dy))
        }
      }
      let deadline=CACurrentMediaTime()+5
      while monitor.samples.last?.presented == nil,CACurrentMediaTime()<deadline {
        try await Task.sleep(for:.milliseconds(2))
      }
      monitor.stop()
      monitor.report(self,foreignCount:foreignCount)
      XCTAssertEqual(monitor.samples.count,120,"No omitted input can improve the workload")
      XCTAssertNotNil(monitor.samples.last?.presented,"The final exact pose needs its matching OS receipt")
      XCTAssertEqual(owner.presentedFrame,original.offsetBy(dx:0,dy:180))
      XCTAssertEqual(canvas.orderedInkPlan.bodies.count,foreignCount+2)
      try pixels(canvas,window:window,points:[(.init(x:80,y:80),.paper),(.init(x:80,y:260),.black),(.init(x:300,y:80),.black)],name:"selection-pose-\(foreignCount)-final")
      model.cancelElementManipulation(contact)
      await canvas.finishSpatialHandoffFrames()
      let stopped=await model.shutdown();XCTAssertTrue(stopped)
    } catch {
      model.cancelElementManipulation()
      await canvas.finishSpatialHandoffFrames()
      _=await model.shutdown()
      throw error
    }
  }

  private func ready(_ canvas:InkCanvasView) async throws {
    let deadline=CACurrentMediaTime()+10
    while !canvas.isStableFramePresented,CACurrentMediaTime()<deadline {try await Task.sleep(for:.milliseconds(5))}
    XCTAssertTrue(canvas.isStableFramePresented,"The initial installed drawable needs an OS presentation receipt")
  }
  private func footprint()->UInt64 {
    var info=task_vm_info_data_t(),count=mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size/MemoryLayout<integer_t>.size)
    let status=withUnsafeMutablePointer(to:&info) {pointer in
      pointer.withMemoryRebound(to:integer_t.self,capacity:Int(count)) {task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&count)}
    }
    return status == KERN_SUCCESS ? info.phys_footprint:0
  }
  private func attach(_ text:String,name:String) {
    print(text);fflush(stdout)
    let attachment=XCTAttachment(string:text);attachment.name=name;attachment.lifetime = .keepAlways;add(attachment)
  }
  private func pixels(_ canvas:InkCanvasView,window:UIWindow,points:[(CGPoint,NotebookUXObservation.Color)],name:String) throws {
    let snapshot=try NotebookUXObservation.Pixels(window:window)
    let correct=try snapshot.matches(points.map{(canvas.convert($0.0,to:window),$0.1)})
    XCTAssertTrue(correct,"\(name): motion receipts must leave the moved body, vacant old pose and unchanged neighbor correct")
    let attachment=XCTAttachment(image:snapshot.image);attachment.name=name;attachment.lifetime = .keepAlways;add(attachment)
  }

  @MainActor private final class Consumer:NotebookPageInkConsumer {
    let currentSelectionCanvas:InkCanvasView?
    init(_ canvas:InkCanvasView){currentSelectionCanvas=canvas}
    func receiveOrderedErasing(_ contacts:[NotebookElementErasing],id:UUID){}
    func receiveAcceptedInk(_ change:PreparedPageInkChange,suppressedIDs:Set<UUID>){}
  }

  @MainActor private final class Motion {
    struct Sample {
      let index:Int,due:Double,delivered:Double,requested:CGRect
      var returned:Double?
      var installed:Double?,presented:Double?,receiptDelivered:Double?
      var submission:UUID?,revision:UInt64?
    }
    private struct Key:Hashable {let submission:UUID,revision:UInt64}
    private struct Frame {let index:Int,time:Double,rectangle:CGRect;var presented:Double?}
    private weak var canvas:InkCanvasView?
    private weak var owner:NotebookSelectionPresentation?
    private let original:CGRect
    private var frames:[Key:Frame]=[:]
    private var unmatched=0,unexpected=0
    private(set) var samples:[Sample]=[]
    init(canvas:InkCanvasView,owner:NotebookSelectionPresentation,original:CGRect) {
      precondition(canvas.onOrderedFrameInstalled == nil && canvas.onOrderedFrameResolved == nil)
      self.canvas=canvas;self.owner=owner;self.original=original
      canvas.onOrderedFrameInstalled={ [weak self] id,revision in self?.installed(id,revision:revision) }
      canvas.onOrderedFrameResolved={ [weak self] id,revision,receipt in self?.resolved(id,revision:revision,receipt:receipt) }
    }
    func input(index:Int,due:Double,frame:CGRect,action:()->Void) {
      samples.append(.init(index:index,due:due,delivered:CACurrentMediaTime(),requested:frame))
      action();samples[index].returned=CACurrentMediaTime()
    }
    private func installed(_ submission:UUID,revision:UInt64) {
      guard let rectangle=owner?.presentedFrame else {unexpected += 1;return}
      let index=Int(((rectangle.minY-original.minY)/1.5).rounded())-1
      guard samples.indices.contains(index),samples[index].requested == rectangle else {unexpected += 1;return}
      let time=CACurrentMediaTime(),key=Key(submission:submission,revision:revision)
      frames[key] = .init(index:index,time:time,rectangle:rectangle)
      samples[index].installed=time;samples[index].submission=submission;samples[index].revision=revision
    }
    private func resolved(_ submission:UUID,revision:UInt64,receipt:NotebookMetalFrameReadiness) {
      let key=Key(submission:submission,revision:revision)
      guard var frame=frames[key] else {unmatched += 1;return}
      guard receipt.isReady,let presented=receipt.presentedTime,presented.isFinite,presented>0 else {return}
      frame.presented=presented;frames[key]=frame
      samples[frame.index].presented=presented;samples[frame.index].receiptDelivered=CACurrentMediaTime()
    }
    func stop() {canvas?.onOrderedFrameInstalled=nil;canvas?.onOrderedFrameResolved=nil}
    isolated deinit {stop()}
    func report(_ test:XCTestCase,foreignCount:Int) {
      let shown=frames.filter{$0.value.presented != nil}.sorted{$0.value.presented!<$1.value.presented!}
      func advancing(_ sample:Sample)->(Key,Frame)? {
        shown.first{$0.value.index>=sample.index && $0.value.presented!>=sample.due}.map{($0.key,$0.value)}
      }
      func stats(_ values:[Double])->String {
        let values=values.sorted();guard !values.isEmpty else {return "missing"}
        func p(_ percentile:Double)->Double {values[max(0,Int(ceil(Double(values.count)*percentile))-1)]}
        return "n=\(values.count),p50=\(p(0.5)),p95=\(p(0.95)),p99=\(p(0.99)),max=\(values.last!)"
      }
      let text="foreign=\(foreignCount); fixed120Hz=\(samples.count); exactInstalled=\(frames.count); exactPresented=\(shown.count); superseded=\(samples.filter{$0.installed == nil}.count); unmatchedReceipts=\(unmatched); unexpectedInstalledFrames=\(unexpected); scheduledToDeliveryMS=\(stats(samples.map{($0.delivered-$0.due)*1_000})); deliveryToReturnMS=\(stats(samples.compactMap{s in s.returned.map{($0-s.delivered)*1_000}})); scheduledToExactOSMS=\(stats(samples.compactMap{s in s.presented.map{($0-s.due)*1_000}})); scheduledToNextAdvancingPoseOSMS=\(stats(samples.compactMap{s in advancing(s).map{($0.1.presented!-s.due)*1_000}})). Superseded requests never receive an exact-pose ACK. The advancing-pose lane exposes the backlog for every demand covered by a newer shown pose. Harness completion has no latency budget assertion and does not establish product acceptance, compositor FPS or physical Pencil latency."
      print(text);fflush(stdout)
      let summary=XCTAttachment(string:text);summary.name="selection-pose-\(foreignCount)-summary";summary.lifetime = .keepAlways;test.add(summary)
      let header="index,scheduled,delivered,returned,requested_x,requested_y,requested_w,requested_h,native_installed,os_presented,receipt_delivered,submission,revision,exact_status,next_advancing_os,next_advancing_submission,next_advancing_revision"
      let rows=samples.map {s in
        func number(_ v:Double?)->String {v.map {String($0)} ?? "missing"}
        let next=advancing(s)
        return "\(s.index),\(s.due),\(s.delivered),\(number(s.returned)),\(s.requested.minX),\(s.requested.minY),\(s.requested.width),\(s.requested.height),\(number(s.installed)),\(number(s.presented)),\(number(s.receiptDelivered)),\(s.submission?.uuidString ?? "missing"),\(s.revision.map(String.init) ?? "missing"),\(s.presented != nil ? "exact_presented":s.installed != nil ? "installed_without_os":"superseded"),\(number(next?.1.presented)),\(next?.0.submission.uuidString ?? "missing"),\(next?.0.revision.description ?? "missing")"
      }
      let detail=XCTAttachment(string:header+"\n"+rows.joined(separator:"\n"));detail.name="selection-pose-\(foreignCount)-samples.csv";detail.lifetime = .keepAlways;test.add(detail)
      XCTAssertEqual(unexpected,0,"Every installed receipt must correspond to one exact requested frame")
    }
  }
}

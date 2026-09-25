import Accelerate
import NotebookCore
import PencilKit
import XCTest

@testable import Notebook

final class PageInkGeometryTests: XCTestCase {
  @MainActor
  func testCorrectedActiveTailKeepsTheSameBoundaryForBothRenderers() {
    let stroke=ActiveEraserStroke()
    stroke.replaceMeasuredTail(from:0,with:[point(x:20,y:20),point(x:80,y:80)])
    let firstRevision=stroke.revision
    XCTAssertEqual(stroke.changedStart(after:nil),0)
    XCTAssertEqual(stroke.changedStart(after:nil),0,"Reading a boundary is not destructive")
    stroke.replaceMeasuredTail(from:0,with:[point(x:25,y:20),point(x:85,y:80)])
    XCTAssertEqual(stroke.measured.count,2)
    XCTAssertEqual(stroke.changedStart(after:firstRevision),0)
    XCTAssertEqual(stroke.changedStart(after:firstRevision),0,
      "Page ink and the element mask must both rebuild an estimated correction")
  }

  @MainActor
  func testReloadRetainsMeasuredGeometry() async throws {
    let drawing = PageInkDrawing(actions: [stroke(y: 100)])
    let view = InkCanvasView(
      frame: CGRect(x: 0, y: 0, width: 400, height: 400)
    )

    view.apply(drawing)

    try await prepared(view)
    XCTAssertGreaterThan(view.committedSourceNodeCount, 0)
    XCTAssertEqual(view.pageMeshBuildCount, 1)
    view.frame.size = .init(width: 800, height: 800)
    view.layoutIfNeeded()
    XCTAssertEqual(view.pageMeshBuildCount, 1, "Resizing changes projection, not the source mesh")
  }

  @MainActor
  func testColdSamePageSwapKeepsInstalledMaterialAndWarmUndoOf100000SamplesDoesNotPrepareAgain() async throws {
    let view=InkCanvasView(frame:.init(x:0,y:0,width:400,height:400))
    view.apply(PageInkDrawing(actions:[stroke(y:100)]));try await prepared(view)
    let installed=view.committedSourceNodeCount
    let samples=InkMeasurements((0..<100_000).map { i in
      .init(point:.init(x:20+Double(i%1000)/4,y:20+Double(i/1000)*2),timeOffset:Double(i)/240,
        width:2,opacity:1,force:1,azimuth:0,altitude:1)
    })
    let action=PageInkAction(tool:.pen,measurements:samples)
    let actor=UUID(),page=PageDocument(size:.init(width:400,height:400),actor:actor)
    let added=try page.prepareInkChange(.append(action),stamp:.init(counter:1,actor:actor))
    XCTAssertTrue(page.publishLiveInkChange(added))
    view.apply(added.drawing)
    XCTAssertEqual(view.committedSourceNodeCount,installed,"A cold candidate does not publish an empty frame")
    let deadline=ContinuousClock.now + .seconds(20)
    while !view.pageGeometryIsReady,ContinuousClock.now < deadline { try await Task.sleep(for:.milliseconds(5)) }
    XCTAssertTrue(view.pageGeometryIsReady);XCTAssertEqual(view.committedSourceNodeCount,100_000)
    let builds=view.pageMeshBuildCount,preparations=view.pageMeshPreparationCount
    let undo=try page.prepareInkChange(.setActive([action.id],false),stamp:.init(counter:2,actor:actor))
    XCTAssertTrue(page.publishLiveInkChange(undo));view.settle(undo)
    XCTAssertEqual(view.committedSourceNodeCount,0)
    let redo=try page.prepareInkChange(.setActive([action.id],true),stamp:.init(counter:3,actor:actor))
    XCTAssertTrue(page.publishLiveInkChange(redo));view.settle(redo)
    XCTAssertEqual(view.committedSourceNodeCount,100_000)
    XCTAssertEqual(view.pageMeshPreparationCount,preparations);XCTAssertEqual(view.pageMeshBuildCount,builds)
  }

  @MainActor
  func testWarmUndoRedoAddressesOneOf100000DistinctActionsWithoutRepreparingHistory() async throws {
    let (page,target)=try await Task.detached(priority:.userInitiated) {
      let actor=UUID(),page=PageDocument(size:.init(width:2_048,height:2_048),actor:actor)
      var target=UUID()
      for index in 0..<100_000 {
        try Task.checkCancellation()
        let x=index == 0 ? 100 : index == 50_000 ? 150 : 500+Double(index%300)*4
        let y=index == 0 ? 100 : index == 50_000 ? 150 : 500+Double(index/300)*4
        let action=PageInkAction(tool:.pen,samples:[
          .init(point:.init(x:x,y:y),timeOffset:0,width:2,opacity:1,force:1,azimuth:0,altitude:1),
          .init(point:.init(x:x+1,y:y),timeOffset:0.01,width:2,opacity:1,force:1,azimuth:0,altitude:1)])
        let change=try page.prepareInkChange(.append(action),stamp:.init(counter:UInt64(index+1),actor:actor))
        guard page.publishLiveInkChange(change) else { throw PageInkDrawing.InkError.invalidDrawing }
        if index == 50_000 { target=action.id }
      }
      return (page,target)
    }.value
    let drawing=try page.inkDrawing()
    XCTAssertEqual(drawing.actionCount,100_000)
    let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window=UIWindow(windowScene:scene),host=UIViewController()
    window.rootViewController=host;window.makeKeyAndVisible()
    defer { window.isHidden=true;window.rootViewController=nil }
    let view=InkCanvasView(frame:.zero)
    host.view.addSubview(view)
    view.projectPage(region:.init(x:0,y:0,width:300,height:300),
      sourceSize:.init(width:2_048,height:2_048),pixelDensity:2)
    view.apply(drawing)
    func rendered() async throws {
      let deadline=ContinuousClock.now + .seconds(30)
      while !view.isStableFramePresented,view.renderFailure == nil,ContinuousClock.now < deadline {
        try await Task.sleep(for:.milliseconds(10))
      }
      XCTAssertNil(view.renderFailure);XCTAssertTrue(view.isStableFramePresented)
    }
    try await rendered()
    XCTAssertEqual(view.visibleCommittedChunkCount,2)
    let queries=view.committedBatchQueryVisitCount
    XCTAssertEqual(view.pageMeshBuildCount,100_000)
    let builds=view.pageMeshBuildCount,preparations=view.pageMeshPreparationCount
    let visits=view.pageAcceptedMutationActionVisits,actor=page.drawingStamp.actor
    let undo=try page.prepareInkChange(.setActive([target],false),stamp:.init(counter:100_001,actor:actor))
    XCTAssertTrue(page.publishLiveInkChange(undo));view.settle(undo)
    XCTAssertFalse(try XCTUnwrap(undo.drawing.action(id:target)).isActive)
    XCTAssertEqual(undo.drawing.actionCount,99_999)
    try await rendered();XCTAssertEqual(view.visibleCommittedChunkCount,1)
    let redo=try page.prepareInkChange(.setActive([target],true),stamp:.init(counter:100_002,actor:actor))
    XCTAssertTrue(page.publishLiveInkChange(redo));view.settle(redo)
    XCTAssertTrue(try XCTUnwrap(redo.drawing.action(id:target)).isActive)
    XCTAssertEqual(redo.drawing.actionCount,100_000)
    try await rendered();XCTAssertEqual(view.visibleCommittedChunkCount,2)
    XCTAssertEqual(view.committedBatchQueryVisitCount-queries,2,
      "The actual next frames must not re-query the 99,998 off-crop actions")
    XCTAssertEqual(view.pageAcceptedMutationActionVisits-visits,2,"The accepted delta names one batch per inverse, not the 100k-action history")
    XCTAssertEqual(view.pageMeshPreparationCount,preparations)
    XCTAssertEqual(view.pageMeshBuildCount,builds)
    XCTAssertTrue(view.pageGeometryIsReady)
  }

  @MainActor
  func testAcceptedAppendAlsoAppliesChangedSuppressionToEarlierResidentActions() async throws {
    let actor=UUID(),page=PageDocument(size:.init(width:400,height:400),actor:actor)
    let first=stroke(y:100),second=stroke(y:200)
    let added=try page.prepareInkChange(.append(first),stamp:.init(counter:1,actor:actor))
    XCTAssertTrue(page.publishLiveInkChange(added))
    let view=InkCanvasView(frame:.init(x:0,y:0,width:400,height:400))
    view.apply(added.drawing);try await prepared(view)
    XCTAssertEqual(view.committedSourceNodeCount,2)
    let converted=try page.prepareInkChange(.append(second),stamp:.init(counter:2,actor:actor))
    XCTAssertTrue(page.publishLiveInkChange(converted))
    view.settle(converted,suppressedInkIDs:[first.id,second.id])
    XCTAssertEqual(view.committedSourceNodeCount,0,
      "An accepted multi-stroke conversion cannot keep preceding raw strokes visible")
    XCTAssertTrue(view.pageGeometryIsReady)
    view.setSuppressedPageActions([])
    try await prepared(view)
    XCTAssertEqual(view.committedSourceNodeCount,4,
      "Undoing the conversion also restores the contact that never had a raw mesh")
  }

  @MainActor
  func testReloadedGeometryProducesVisibleInk() async throws {
    let size = CGSize(width: 400, height: 400)
    let scene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.first as? UIWindowScene
    )
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(origin: .zero, size: size)
    let background = UIView(frame: window.bounds)
    background.backgroundColor = .white
    let view = InkCanvasView(frame: background.bounds)
    background.addSubview(view)
    window.rootViewController = UIViewController()
    window.rootViewController?.view = background
    window.makeKeyAndVisible()

    let ready = expectation(description: "геометрия показана")
    view.onRenderReadinessChange = { isReady in
      if isReady { ready.fulfill() }
    }
    view.apply(PageInkDrawing(actions: [stroke(y: 100)]))
    await fulfillment(of: [ready], timeout: 3)

    let image = UIGraphicsImageRenderer(size: size).image { _ in
      background.drawHierarchy(in: background.bounds, afterScreenUpdates: true)
    }
    XCTAssertGreaterThan(
      darkPixelCount(in: image),
      100,
      "Геометрия должна оставить видимые чернила на белой бумаге"
    )
  }

  @MainActor
  func testLiveMeshRemainsDuringDurablePreparation() {
    let view = InkCanvasView(frame: .zero)
    view.apply(PageInkDrawing())

    let active = ActiveInkStroke(style: .standard)
    active.replaceMeasuredTail(
      from: 0,
      with: [point(x: 20, y: 40), point(x: 180, y: 80)]
    )
    view.displayActiveStroke(active)
    let action=active.measured.frozen().restoredAction()
    view.commitActiveStroke(action)
    let liveVertexCount = view.committedSourceNodeCount

    view.settle(try! acceptedChange(appending:action))

    XCTAssertGreaterThan(liveVertexCount, 0)
    XCTAssertEqual(
      view.committedSourceNodeCount,
      liveVertexCount,
      "Подготовка не убирает живой штрих"
    )
  }

  @MainActor
  func testLiveSettledAndReloadedLineKeepTheSamePixels() async throws {
    let size = CGSize(width: 400, height: 400)
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(origin: .zero, size: size)
    let background = UIView(frame: window.bounds)
    background.backgroundColor = .white
    let view = InkCanvasView(frame: background.bounds)
    background.addSubview(view)
    window.rootViewController = UIViewController()
    window.rootViewController?.view = background
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    view.apply(PageInkDrawing())
    var drawing = PageInkDrawing()
    for (index, color) in PenColor.allCases.enumerated() {
      let style = PenStyle(color: color, width: 4, minimumOpacity: 0.18)
      let points: [PKStrokePoint] = (0..<80).map { step in
        let x = CGFloat(30 + step * 4)
        let y = CGFloat(50 + index * 85 + (step % 16 < 8 ? 0 : 28))
        return PKStrokePoint(
          location: CGPoint(x: x, y: y),
          timeOffset: Double(step) / 240, size: CGSize(width: 4, height: 4),
          opacity: 0.18 + 0.82 * Double(step) / 79, force: 1, azimuth: 0, altitude: .pi / 2)
      }
      let active = ActiveInkStroke(style: style)
      active.replaceMeasuredTail(from: 0, with: points)
      view.displayActiveStroke(active)
      let rgb = color.components
      let action = PageInkAction(tool: .pen, color: .init(red: rgb.red, green: rgb.green, blue: rgb.blue), points: points)
      view.commitActiveStroke(action)
      drawing = try drawing.appending(action)
    }
    let eraserPoints = [point(x: 160, y: 20), point(x: 160, y: 380)]
    let eraser = ActiveEraserStroke()
    eraser.replaceMeasuredTail(from: 0, with: eraserPoints)
    view.displayActiveEraser(eraser)
    let eraseAction = PageInkAction(tool: .eraser, points: eraserPoints)
    view.commitActiveEraser(eraseAction)
    drawing = try drawing.appending(eraseAction)
    try await Task.sleep(for: .milliseconds(100))
    func pixels() throws -> Data {
      let format = UIGraphicsImageRendererFormat()
      format.scale = 2
      let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
        background.drawHierarchy(in: background.bounds, afterScreenUpdates: true)
      }
      return try XCTUnwrap(image.cgImage?.dataProvider?.data) as Data
    }
    let live = try pixels()
    let ready = expectation(description: "same geometry settled")
    view.onRenderReadinessChange = { if $0 { ready.fulfill() } }
    view.settle(try acceptedChange(appending: drawing.actions))
    await fulfillment(of: [ready], timeout: 4)
    view.onRenderReadinessChange = nil
    try await Task.sleep(for: .milliseconds(60))
    let settled = try pixels()
    XCTAssertEqual(live.count, settled.count)
    let error =
      zip(live, settled).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(live.count)
    XCTAssertLessThan(
      error, 0.15, "Принятие измеренной сетки сохраняет цвет, толщину и острые повороты")
    XCTAssertEqual(view.pageMeshBuildCount, 0, "Pencil-up/delivery must retain the measured meshes")
    let decoded = try PageInkDrawing.decode(drawing.dataRepresentation())
    view.apply(decoded)
    try await prepared(view)
    try await Task.sleep(for: .milliseconds(100))
    let reloaded = try pixels()
    let reloadError = zip(settled, reloaded).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(settled.count)
    XCTAssertLessThan(reloadError, 0.15, "Reload uses the same geometry, not a resampled 2x page texture")
    let originalRaster = try XCTUnwrap(InkRasterRenderer.shared.page(drawing, size: size))
    let reloadedRaster = try XCTUnwrap(InkRasterRenderer.shared.page(decoded, size: size))
    XCTAssertEqual(
      originalRaster.dataProvider?.data as Data?, reloadedRaster.dataProvider?.data as Data?)
    XCTAssertGreaterThan(darkPixelCount(in: UIImage(cgImage: reloadedRaster)), 100)
  }

  @MainActor
  func testLongAcceptedContactReleasesHiddenGeometryOnceWithoutRebuildingHistory() async throws {
    let view=InkCanvasView(frame:.init(x:0,y:0,width:400,height:400))
    view.apply(PageInkDrawing());try await prepared(view)
    let points=(0..<10_000).map { point(x:CGFloat($0)/2,y:40+CGFloat(sin(Double($0)/8))*5) }
    let active=ActiveInkStroke(style:.standard)
    active.replaceMeasuredTail(from:0,with:points)
    let action=active.measured.frozen().restoredAction()
    view.displayActiveStroke(active);view.commitActiveStroke(action)
    XCTAssertEqual(view.committedPreparedNodeCount,points.count)
    let accepted=try acceptedChange(appending:action)
    view.settle(accepted)
    let deadline=ContinuousClock.now + .seconds(4)
    while view.committedPreparedNodeCount > 0,ContinuousClock.now < deadline {
      try await Task.sleep(for:.milliseconds(5))
    }
    XCTAssertEqual(view.committedPreparedNodeCount,0,"Only the visible neighbourhood may build display nodes after acceptance")
    XCTAssertEqual(view.committedSourceNodeCount,points.count)
    XCTAssertEqual(view.pageMeshBuildCount,1)
    view.settle(accepted);try await prepared(view)
    XCTAssertEqual(view.pageMeshBuildCount,1,"Subsequent delivery reuses the canonical source")
  }

  @MainActor
  func testColdRepeatRestoresPenAndEraserAtTheirOriginalPainterPosition() async throws {
    let size=CGSize(width:400,height:220),actor=UUID()
    func measured(_ x:Double,_ y:Double,_ width:Double,_ opacity:Double) -> SpatialInkSample {
      .init(point:.init(x:x,y:y),timeOffset:0,width:width,opacity:opacity,force:1,azimuth:0,altitude:1)
    }
    let pen=PageInkAction(tool:.pen,color:.init(red:0.8,green:0.15,blue:0.1),
      samples:[measured(20,80,20,0.65),measured(350,80,20,0.65)])
    let eraser=PageInkAction(tool:.eraser,
      samples:[measured(160,20,40,1),measured(160,180,40,1)])
    let later=PageInkAction(tool:.pen,color:.init(red:0.1,green:0.2,blue:0.9),
      samples:[measured(20,120,12,0.9),measured(350,120,12,0.9)])
    let source=PageInkDrawing(actions:[pen,eraser,later])
    let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window=UIWindow(windowScene:scene);window.frame=CGRect(origin:.zero,size:size)
    let background=UIView(frame:window.bounds);background.backgroundColor = .white
    let controller=UIViewController();controller.view=background;window.rootViewController=controller;window.makeKeyAndVisible()
    defer { window.isHidden=true;window.rootViewController=nil }
    func capture(_ view:InkCanvasView, matching expected:UIImage? = nil,
      allowing previous:UIImage? = nil) async throws -> UIImage {
      try await prepared(view)
      let deadline=ContinuousClock.now + .seconds(3)
      while !view.isStableFramePresented,ContinuousClock.now < deadline { try await Task.sleep(for:.milliseconds(5)) }
      XCTAssertTrue(view.isStableFramePresented);XCTAssertNil(view.renderFailure)
      func image() -> UIImage {
        let format=UIGraphicsImageRendererFormat();format.scale=1
        return UIGraphicsImageRenderer(size:size,format:format).image { _ in
          background.drawHierarchy(in:background.bounds,afterScreenUpdates:true)
        }
      }
      guard let expected,let previous else { return image() }
      // Simulator command completion admits readiness but is not an OS display
      // receipt. Observe the actual window; only the complete old or complete new
      // image is legal while it catches up. A later match cannot hide a mixed frame.
      var last:UIImage?,mixed:[Double]=[]
      let observed=try await NotebookUXObservation.observe(since:.now,
        budget:NotebookUXObservation.correctnessTimeout) {
        let current=image();last=current
        let differenceFromExpected=try difference(current,expected)
        if differenceFromExpected >= 0.15,try difference(current,previous) >= 0.15 {
          mixed.append(differenceFromExpected)
        }
        return differenceFromExpected < 0.15
      }
      XCTAssertTrue(mixed.isEmpty,"Cold/warm installation exposed a neither-old-nor-new composition: \(mixed)")
      XCTAssertTrue(observed.passed,"The full restored window image must appear within 100 ms of readiness, including capture: \(observed.milliseconds) ms")
      return try XCTUnwrap(last)
    }
    func difference(_ a:UIImage,_ b:UIImage) throws -> Double {
      let first=try XCTUnwrap(a.cgImage?.dataProvider?.data) as Data
      let second=try XCTUnwrap(b.cgImage?.dataProvider?.data) as Data
      XCTAssertEqual(first.count,second.count)
      return fullImageByteDifference(first,second)
    }
    // Ordinary ink, its cropped retained composite, and the tiled erasure
    // mask all consume the same gate; retained buffers must not revive it.
    for mode in ["ink", "crop", "tiled-mask"] {
      func makeCanvas() -> InkCanvasView {
        let view=InkCanvasView(frame:background.bounds,isErasureMask:mode == "tiled-mask")
        background.addSubview(view)
        if mode != "ink" { view.projectPage(region:background.bounds,sourceSize:size,pixelDensity:4) }
        return view
      }
      let reference=makeCanvas();reference.apply(source)
      let expected=try await capture(reference)
      XCTAssertGreaterThan(darkPixelCount(in:expected),100,"The comparison must contain actual mounted ink")
      reference.removeFromSuperview()
      for action in [pen,eraser] {
        let undone=try source.settingActive(false,for:[action.id],stamp:.init(counter:1,actor:actor))
        var page=PageDocument(size:.init(width:400,height:220),actor:actor,drawingData:try undone.dataRepresentation())
        let view=makeCanvas();view.apply(undone)
        let missing=try await capture(view),built=view.pageMeshBuildCount
        XCTAssertEqual(built,2);XCTAssertGreaterThan(try difference(missing,expected),0.5)
        let repeatChange=try page.prepareInkChange(.setActive([action.id],true),stamp:.init(counter:2,actor:actor))
        XCTAssertTrue(page.publishInkChange(repeatChange));view.settle(repeatChange)
        XCTAssertFalse(view.pageGeometryIsReady,"The missing cold mesh cannot announce a ready frame")
        let restored=try await capture(view,matching:expected,allowing:missing)
        XCTAssertEqual(view.pageMeshBuildCount,built+1,"The other measured batches remain shared")
        XCTAssertLessThan(try difference(restored,expected),0.15,
          "Restoring an old pen must retain later cutouts; restoring an eraser must not cut ink authored after it")
        let attachment=XCTAttachment(image:restored);attachment.name="\(mode)-cold-repeat-\(action.tool)";attachment.lifetime = .keepAlways;add(attachment)
        for active in [false,true] {
          let change=try page.prepareInkChange(.setActive([action.id],active),stamp:page.drawingStamp)
          XCTAssertTrue(page.publishInkChange(change));view.settle(change)
          let shown=try await capture(view,matching:active ? expected : missing,allowing:active ? missing : expected)
          let attachment=XCTAttachment(image:shown);attachment.name="\(mode)-warm-repeat-\(action.tool)-\(active)";attachment.lifetime = .keepAlways;add(attachment)
          XCTAssertLessThan(try difference(shown,active ? expected : missing),0.15,
            "\(mode): the shown \(action.tool) gate must be \(active), not its previous frame")
          XCTAssertEqual(view.pageMeshBuildCount,built+1,"A warm gate only toggles its resident batch")
        }
        view.removeFromSuperview()
      }
    }
  }

  func testFullImageDifferenceMatchesExactReferenceAtDecisionBoundaries() {
    func reference(_ a:Data,_ b:Data) -> Double {
      zip(a,b).reduce(0.0) { $0+abs(Double($1.0)-Double($1.1)) }/Double(a.count)
    }
    let count=10_000,zero=Data(repeating:0,count:10_000)
    for changed in [0,1,1_499,1_500,1_501,4_999,5_000,5_001,10_000] {
      // Place every changed byte at the end: the comparison must not sample
      // a few probes, skip alpha/padding, or round across either UX threshold.
      let data=Data(repeating:0,count:count-changed)+Data(repeating:1,count:changed)
      let expected=reference(zero,data),actual=fullImageByteDifference(zero,data)
      XCTAssertEqual(actual,expected)
      XCTAssertEqual(fullImageByteDifference(data,zero),expected)
      XCTAssertEqual(actual < 0.15,expected < 0.15)
      XCTAssertEqual(actual > 0.5,expected > 0.5)
    }
    let new=Data(repeating:255,count:count)
    let mixed=Data(repeating:0,count:count/2)+Data(repeating:255,count:count/2)
    XCTAssertEqual(fullImageByteDifference(zero,new),255)
    XCTAssertEqual(fullImageByteDifference(mixed,new),reference(mixed,new))
    XCTAssertGreaterThanOrEqual(fullImageByteDifference(mixed,zero),0.15)
    XCTAssertGreaterThanOrEqual(fullImageByteDifference(mixed,new),0.15,
      "A half-old/half-new frame must still fail the actual observer's mixed-image invariant")
    let first=Data((0..<(400*220*4)).map { UInt8(truncatingIfNeeded:$0) })
    let second=Data((0..<(400*220*4)).map { UInt8(truncatingIfNeeded:$0*37+19) })
    let started=ContinuousClock.now,expected=reference(first,second)
    let referenceElapsed=started.duration(to:.now)
    let accelerated=ContinuousClock.now,actual=fullImageByteDifference(first,second)
    let acceleratedElapsed=accelerated.duration(to:.now)
    XCTAssertEqual(actual,expected,"Every byte contributes exactly, even at the full capture size")
    let attachment=XCTAttachment(string:"352000-byte full-image difference; reference=\(referenceElapsed); exact Accelerate=\(acceleratedElapsed); difference=\(actual)")
    attachment.name="page-ink-full-image-observer-cost";attachment.lifetime = .keepAlways;add(attachment)
  }

  @MainActor
  func testColdLoadAndDurableDeliveryPreserveANewerMeasuredTailAndUndo() async throws {
    let base = stroke(y: 100), tail = stroke(y: 160)
    let view = InkCanvasView(frame: .init(x: 0, y: 0, width: 400, height: 400))
    view.apply(.init(actions: [base]))
    let active = ActiveInkStroke(style: .standard)
    active.replaceMeasuredTail(from: 0, with: [point(x: 10, y: 160), point(x: 200, y: 160)])
    view.displayActiveStroke(active)
    view.commitActiveStroke(tail)
    let tailVertices = view.committedSourceNodeCount
    try await prepared(view)
    XCTAssertGreaterThan(view.committedSourceNodeCount, tailVertices, "Cold completion keeps the newer contact")
    let count = view.committedSourceNodeCount, built = view.pageMeshBuildCount
    let (accepted,undone) = try acceptedAndUndone(base:.init(actions:[base]),appending:tail)
    view.settle(accepted)
    try await prepared(view)
    XCTAssertEqual(view.committedSourceNodeCount, count, "Delivery cannot duplicate the already measured tail")
    XCTAssertEqual(view.pageMeshBuildCount, built, "Delivery does not rebuild the history or contact")
    view.settle(undone)
    try await prepared(view)
    XCTAssertEqual(view.committedSourceNodeCount, count - tailVertices)
    XCTAssertEqual(view.pageMeshBuildCount, built, "Undo removes a batch, not rasterizes/rebuilds the page")
  }

  @MainActor
  func testReplacedPreparationCannotInstallOldPageOrLoseAnActiveContact() async throws {
    let view = InkCanvasView(frame: .init(x: 0, y: 0, width: 400, height: 400))
    view.apply(.init(actions: (0..<40).map { stroke(y: CGFloat($0 * 5)) }))
    view.apply(.init())
    let active = ActiveInkStroke(style: .standard)
    active.replaceMeasuredTail(from: 0, with: [point(x: 10, y: 40), point(x: 200, y: 40)])
    view.displayActiveStroke(active)
    try await prepared(view)
    XCTAssertEqual(view.committedSourceNodeCount, 0)
    view.commitActiveStroke(stroke(y: 40))
    XCTAssertGreaterThan(view.committedSourceNodeCount, 0, "Preparation must not discard the active contact")
    XCTAssertEqual(view.pageMeshBuildCount, 0, "The cancelled old page must never publish")
  }

  @MainActor
  func testUnmountedPreparationCanResumeTheSamePageWithoutALateCancellationClearingIt() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene)
    let controller = UIViewController(); window.rootViewController = controller; window.makeKeyAndVisible()
    let view = InkCanvasView(frame: .init(x: 0, y: 0, width: 400, height: 400))
    controller.view.addSubview(view)
    defer { view.removeFromSuperview(); window.isHidden = true; window.rootViewController = nil }
    view.apply(.init(actions: (0..<40).map { stroke(y: CGFloat($0 * 5)) }))
    view.removeFromSuperview()
    controller.view.addSubview(view)
    try await prepared(view)
    XCTAssertGreaterThan(view.committedSourceNodeCount, 0)
    XCTAssertEqual(view.pageMeshBuildCount, 40, "Only the replacement preparation may publish")
  }

  @MainActor
  func testImportedBaselineRemainsVisibleBesideGeometry() async throws {
    let size = CGSize(width: 200, height: 200)
    let format = UIGraphicsImageRendererFormat(); format.scale = 1
    let png = UIGraphicsImageRenderer(size: size, format: format).pngData { context in
      UIColor.black.setFill(); context.fill(.init(x: 20, y: 20, width: 40, height: 40))
    }
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene); window.frame = .init(origin: .zero, size: size)
    let background = UIView(frame: window.bounds); background.backgroundColor = .white
    let view = InkCanvasView(frame: background.bounds); background.addSubview(view)
    let controller = UIViewController(); controller.view = background; window.rootViewController = controller
    window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    view.apply(.init(baselinePNG: png, baselineActionCount: 1, actions: [stroke(y: 120)]))
    try await prepared(view)
    let deadline = ContinuousClock.now + .seconds(3)
    while !view.isStableFramePresented, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(view.isStableFramePresented)
    XCTAssertGreaterThan(view.committedSourceNodeCount, 0, "An imported baseline cannot flatten newly measured ink")
    let image = UIGraphicsImageRenderer(size: size).image { _ in background.drawHierarchy(in: background.bounds, afterScreenUpdates: true) }
    XCTAssertGreaterThan(darkPixelCount(in: image), 5000, "Both original baseline and vector stroke remain visible")
  }

  @MainActor
  func testActivePageFramesCompositeRetainedInkWithoutRedrawingHistory() async throws {
    let size=CGSize(width:400,height:400)
    let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window=UIWindow(windowScene:scene); window.frame = .init(origin:.zero,size:size)
    let controller=UIViewController();window.rootViewController=controller
    let resources=SceneRenderResources(byteLimit:32*1024*1024)
    let view=InkCanvasView(frame:.init(origin:.zero,size:size),resources:resources);controller.view.addSubview(view)
    view.projectPage(region:.init(origin:.zero,size:size),sourceSize:size,pixelDensity:1)
    window.makeKeyAndVisible()
    defer { view.removeFromSuperview();window.isHidden=true;window.rootViewController=nil }
    view.apply(.init(actions:(0..<120).map { stroke(y:CGFloat(($0*3)%380+10)) }))
    try await prepared(view)
    let ready=ContinuousClock.now + .seconds(4)
    while !view.isStableFramePresented,ContinuousClock.now < ready { try await Task.sleep(for:.milliseconds(10)) }
    XCTAssertTrue(view.isStableFramePresented)
    let committed=view.pageCommittedPassCount,composited=view.pageActivePassCount
    XCTAssertGreaterThan(committed,0)

    let active=ActiveInkStroke(style:.standard)
    for index in 0..<24 {
      active.replaceMeasuredTail(from:active.measured.count,with:[point(x:CGFloat(20+index*10),y:200)])
      view.displayActiveStroke(active)
      try await Task.sleep(for:.milliseconds(9))
    }
    XCTAssertEqual(view.pageCommittedPassCount,committed,
      "Pencil frames must sample one retained page instead of encoding every saved stroke")
    XCTAssertGreaterThan(view.pageActivePassCount,composited)

    view.commitActiveStroke(active.measured.frozen().restoredAction())
    let deadline=ContinuousClock.now + .seconds(2)
    while view.pageCommittedPassCount == committed,ContinuousClock.now < deadline {
      try await Task.sleep(for:.milliseconds(10))
    }
    XCTAssertEqual(view.pageCommittedPassCount,committed+1,
      "Only the accepted change invalidates the retained page")
  }

  func testReloadPreservesChronologicalPenErasePenGeometry() throws {
    let pen = stroke(y: 100), erase = PageInkAction(tool: .eraser, points: [point(x: 80, y: 50), point(x: 80, y: 150)]), last = stroke(y: 120)
    let drawing = PageInkDrawing(actions: [pen, erase, last])
    let mesh = try PageInkMesh.prepare(drawing, reusing: [])
    let expected = SpatialInkMesh.local(SpatialInkComposer.pageLayers(drawing))
    XCTAssertEqual(mesh.entries.map { $0.mesh.tool }, [.pen, .eraser, .pen])
    for (entry, batch) in zip(mesh.entries, expected.batches) {
      XCTAssertEqual(entry.mesh.expandedForTesting().nodes, batch.expandedForTesting().nodes)
    }
  }

  @MainActor
  private func prepared(_ view: InkCanvasView) async throws {
    let deadline = ContinuousClock.now + .seconds(4)
    while !view.pageGeometryIsReady, view.renderFailure == nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertNil(view.renderFailure)
    XCTAssertTrue(view.pageGeometryIsReady)
  }

  private func stroke(y: CGFloat) -> PageInkAction {
    PageInkAction(tool: .pen, points: [point(x: 10, y: y), point(x: 200, y: y)])
  }

  private func acceptedChange(base:PageInkDrawing = .init(),appending action:PageInkAction) throws
    -> PreparedPageInkChange {
    try acceptedChange(base:base,appending:[action])
  }

  private func acceptedChange(base:PageInkDrawing = .init(),appending actions:[PageInkAction]) throws
    -> PreparedPageInkChange {
    let actor=UUID()
    var page=PageDocument(size:.init(width:400,height:400),actor:actor,
      drawingData:try base.dataRepresentation())
    var accepted:PreparedPageInkChange?
    for (index,action) in actions.enumerated() {
      let change=try page.prepareInkChange(.append(action),
        stamp:.init(counter:UInt64(index+1),actor:actor))
      XCTAssertTrue(page.publishInkChange(change));accepted=change
    }
    return try XCTUnwrap(accepted)
  }

  private func acceptedAndUndone(base:PageInkDrawing,appending action:PageInkAction) throws
    -> (PreparedPageInkChange,PreparedPageInkChange) {
    let actor=UUID()
    var page=PageDocument(size:.init(width:400,height:400),actor:actor,
      drawingData:try base.dataRepresentation())
    let accepted=try page.prepareInkChange(.append(action),stamp:.init(counter:1,actor:actor))
    XCTAssertTrue(page.publishInkChange(accepted))
    let undone=try page.prepareInkChange(.setActive([action.id],false),stamp:.init(counter:2,actor:actor))
    return (accepted,undone)
  }

  private func point(x: CGFloat, y: CGFloat) -> PKStrokePoint {
    PKStrokePoint(
      location: CGPoint(x: x, y: y),
      timeOffset: 0,
      size: CGSize(width: 4, height: 4),
      opacity: 1,
      force: 1,
      azimuth: 0,
      altitude: .pi / 2
    )
  }

  private func darkPixelCount(in image: UIImage) -> Int {
    guard let cgImage = image.cgImage else { return 0 }
    let bytesPerPixel = 4
    let bytesPerRow = cgImage.width * bytesPerPixel
    var pixels = [UInt8](
      repeating: 0,
      count: cgImage.height * bytesPerRow
    )
    let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress,
          width: cgImage.width,
          height: cgImage.height,
          bitsPerComponent: 8,
          bytesPerRow: bytesPerRow,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
      else { return false }
      context.draw(
        cgImage,
        in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
      )
      return true
    }
    guard rendered else { return 0 }
    return stride(from: 0, to: pixels.count, by: bytesPerPixel).reduce(0) {
      count, offset in
      count + (pixels[offset] < 80 && pixels[offset + 3] > 200 ? 1 : 0)
    }
  }
}

/// The reference sum is an integer until the final division. Byte conversion,
/// subtraction and addition remain exact in Double below 2^53; Accelerate only
/// removes Swift Debug iteration overhead, not pixels or precision.
private func fullImageByteDifference(_ first:Data,_ second:Data) -> Double {
  precondition(!first.isEmpty && first.count == second.count)
  precondition(first.count <= (1 << 53)/255)
  var left=[Double](repeating:0,count:first.count)
  var right=[Double](repeating:0,count:second.count)
  var sum=0.0
  let count=vDSP_Length(first.count)
  first.withUnsafeBytes { firstBytes in second.withUnsafeBytes { secondBytes in
    left.withUnsafeMutableBufferPointer { left in right.withUnsafeMutableBufferPointer { right in
      vDSP_vfltu8D(firstBytes.bindMemory(to:UInt8.self).baseAddress!,1,left.baseAddress!,1,count)
      vDSP_vfltu8D(secondBytes.bindMemory(to:UInt8.self).baseAddress!,1,right.baseAddress!,1,count)
      vDSP_vsubD(right.baseAddress!,1,left.baseAddress!,1,left.baseAddress!,1,count)
      vDSP_vabsD(left.baseAddress!,1,left.baseAddress!,1,count)
      vDSP_sveD(left.baseAddress!,1,&sum,count)
    }}
  }}
  return sum/Double(first.count)
}

import Metal
import NotebookCore
import PencilKit
import UIKit
import XCTest
@testable import Notebook

@MainActor
final class SpatialInkTilePoolTests: XCTestCase {
  func testWholeContactSuppressionBorrowsIndexedChunksWithoutRebuildingOneHundredThousandActions() async throws {
    let fixture=try await Fixture.make(extraContacts:99_999)
    addTeardownBlock { await fixture.close() }
    let canvas=fixture.canvas,first=fixture.journal.actions[0],neighbor=fixture.journal.actions[1]
    XCTAssertEqual(fixture.journal.actions.count,100_000)
    let original=try pixels(canvas),built=canvas.preparedCommittedPointCount,installs=canvas.spatialMeshInstallCount
    let visited=canvas.committedBatchQueryVisitCount,queried=canvas.queriedCommittedPointCount
    let restoration=try XCTUnwrap(canvas.captureSourceRestoration(for:[first.id]))
    let frame=try await canvas.prepareFrame(.ordered(.init(suppressedInkIDs:[first.id])))
    XCTAssertEqual(try pixels(canvas),original,"Preparing suppression cannot hide the old physical owner")
    XCTAssertEqual(canvas.spatialMeshInstallCount,installs)
    XCTAssertEqual(canvas.preparedCommittedPointCount,built,"The unchanged neighboring ranges retain their exact GPU geometry")
    XCTAssertEqual(canvas.committedBatchQueryVisitCount-visited,0,"The prepared frame borrows the unchanged resident visible ranges, not 100k history")
    XCTAssertLessThan(canvas.queriedCommittedPointCount-queried,64)
    canvas.installPreparedFrame(frame);restoration.installed()
    await withCheckedContinuation { continuation in frame.afterPresentationTransaction { continuation.resume() } }
    XCTAssertNotEqual(try pixels(canvas),original)
    XCTAssertGreaterThan(try blackPixels(canvas),0,"A short contact merged into the same batch stays visible")
    XCTAssertEqual(canvas.installedSpatialSource?.suppressedInkIDs,[first.id])
    let second=try await canvas.prepareFrame(.ordered(.init(suppressedInkIDs:[first.id,neighbor.id])))
    let suppressionBegan=ContinuousClock.now
    canvas.installPreparedFrame(second)
    await withCheckedContinuation { continuation in second.afterPresentationTransaction { continuation.resume() } }
    // Transaction completion releases the candidate; it is not the OS's
    // drawable receipt. Keep the same full-image zero-pixel requirement under
    // the existing window budget, timed from installation rather than the wait.
    try await assertUX("whole-contact-indexed-suppression",since:suppressionBegan,window:fixture.window) {
      guard canvas.isStableFramePresented else { return false }
      return try self.blackPixels(canvas) == 0
    }
    XCTAssertEqual(canvas.spatialMeshInstallCount,installs)
    XCTAssertEqual(canvas.preparedCommittedPointCount,built)
    let neighborReturned=try await canvas.prepareFrame(.ordered(.init(suppressedInkIDs:[first.id])))
    canvas.installPreparedFrame(neighborReturned)
    await withCheckedContinuation { continuation in neighborReturned.afterPresentationTransaction { continuation.resume() } }
    // A claimed conversion can fail after the next native Pencil contact has
    // already been accepted. Returning A must retain B, not its old journal.
    let next=SpatialInkAction(tool:.pen,spans:[.init(surface:fixture.surface,samples:[-180.0,-120].map { x in
      .init(point:.zero,worldPoint:.init(x:x,y:160),timeOffset:0,width:12,opacity:1,force:1,azimuth:0,altitude:1)
    })],stamp:.init(counter:100_001,actor:fixture.actor))
    let stroke=ActiveInkStroke(style:.standard,sourceID:next.id)
    stroke.replaceMeasuredTail(from:0,with:[CGFloat(76),136].map { x in
      PKStrokePoint(location:.init(x:x,y:544),timeOffset:0,size:.init(width:12,height:12),opacity:1,force:1,azimuth:0,altitude:1)
    })
    canvas.beginSpatialAction();canvas.displayActiveStroke(stroke);canvas.commitActiveSpatialAction()
    canvas.appendInstalledSpatialAction(next);canvas.finishSpatialAction(keepingCommittedMesh:true)
    let beforeReturn=canvas.preparedCommittedPointCount
    var installed=0,abandoned=0
    let started=ContinuousClock.now
    restoration.restore(install:{ installed += 1 },abandon:{ abandoned += 1 })
    try await assertUX("whole-contact-return-keeps-new-accepted-ink",since:started,window:fixture.window) {
      guard installed == 1 else { return false }
      return try NotebookUXObservation.Pixels(window:fixture.window).matches([
        (canvas.convert(.init(x:76,y:384),to:fixture.window),.black),
        (canvas.convert(.init(x:76,y:464),to:fixture.window),.black),
        (canvas.convert(.init(x:100,y:544),to:fixture.window),.black)])
    }
    XCTAssertEqual(abandoned,0)
    XCTAssertEqual(canvas.installedSpatialSource?.suppressedInkIDs,[])
    XCTAssertEqual(try canvas.installedSpatialSource?.referenceInk().actions.last?.id,next.id)
    XCTAssertEqual(canvas.spatialMeshInstallCount,installs)
    XCTAssertEqual(canvas.preparedCommittedPointCount,beforeReturn,"Unsuppression reuses the same resident chunks")
  }

  func testNearFullRotationReusesPoolsAndKeepsRetinaPixelsAcrossTenPresentations() async throws {
    let fixture = try await Fixture.make()
    addTeardownBlock { await fixture.close() }
    let canvas = fixture.canvas, resources = fixture.resources
    let pools = canvas.spatialTilePoolIDs, bytes = resources.reservedBytes
    XCTAssertEqual(pools.count, 6)
    let pressure = try XCTUnwrap(resources.reserveDerivedBytes(resources.byteLimit - bytes - 4096, priority: .input))
    defer { pressure.release() }
    let held = resources.reservedBytes
    XCTAssertGreaterThan(canvas.spatialDrawableAccountedBytes, resources.byteLimit - held,
      "A second complete target cannot fit; this is the near-full replacement boundary")
    for index in 0..<10 {
      let size = index.isMultiple(of: 2) ? SpatialPoint(x: 768, y: 512) : .init(x: 512, y: 768)
      let before = try pixels(canvas), bounds = canvas.bounds
      let frame = try await canvas.prepareFrame(.spatial(nil,size:size,displayScale:2,camera:nil))
      XCTAssertEqual(canvas.bounds, bounds)
      XCTAssertEqual(try pixels(canvas), before, "Private GPU work has not presented or moved any tile")
      XCTAssertEqual(resources.reservedBytes, held, "A transpose reuses every existing physical pool")
      canvas.installPreparedFrame(frame,spatialSource:.init(surface:fixture.surface,journal:fixture.journal,suppressedInkIDs:[]))
      canvas.frame.origin = .zero
      await withCheckedContinuation { continuation in frame.afterPresentationTransaction { continuation.resume() } }
      XCTAssertEqual(canvas.spatialTilePoolIDs, pools)
      XCTAssertEqual(canvas.drawableSize, CGSize(width: size.x * 2, height: size.y * 2))
      XCTAssertTrue(canvas.isStableFramePrepared)
      XCTAssertEqual(resources.reservedBytes, held)
      XCTAssertEqual(try canvas.installedSpatialSource?.referenceInk(), try fixture.reference)
      XCTAssertGreaterThan(try blackPixels(canvas), 300, "Retained UUIDs must also have real displayed pixels")
      try assertContinuousCenterLine(canvas)
      // The original immediate pixel assertions stay above. Completion of
      // their layer transaction alone is not a drawable presentation receipt.
      let deadline = ContinuousClock.now + .seconds(1)
      while !canvas.isStableFramePresented, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
      XCTAssertTrue(canvas.isStableFramePresented)
    }
    let attachment = XCTAttachment(image: capture(canvas)); attachment.name = "near-full-retina-tile-rotation"
    attachment.lifetime = .keepAlways; add(attachment)
    let bounds = canvas.bounds, before = try pixels(canvas)
    do {
      _ = try await canvas.prepareFrame(.spatial(nil,size:.init(x: 768, y: 768),displayScale:2,camera:nil))
      XCTFail("Real growth cannot allocate past the shared byte ceiling")
    } catch { XCTAssertEqual(error as? SceneRenderError, .resourceLimit) }
    XCTAssertEqual(canvas.bounds, bounds); XCTAssertEqual(try pixels(canvas), before)
    XCTAssertEqual(canvas.spatialTilePoolIDs, pools); XCTAssertEqual(resources.reservedBytes, held)
  }

  func testGrowthCancellationAndRetainedPresentationReceiptsDoNotKeepRetiredPools() async throws {
    let fixture = try await Fixture.make()
    addTeardownBlock { await fixture.close() }
    let canvas = fixture.canvas, resources = fixture.resources
    let before = resources.reservedBytes, oldIDs = canvas.spatialTilePoolIDs
    var cancelled: InkCanvasView.PreparedFrame? = try await canvas.prepareFrame(.spatial(nil,size:.init(x: 768, y: 768),displayScale:2,camera:nil))
    XCTAssertTrue(try XCTUnwrap(cancelled).isValid)
    XCTAssertGreaterThan(resources.reservedBytes, before)
    cancelled = nil
    XCTAssertEqual(resources.reservedBytes, before)
    XCTAssertEqual(canvas.spatialTilePoolIDs, oldIDs)
    let grown = try await canvas.prepareFrame(.spatial(nil,size:.init(x: 768, y: 768),displayScale:2,camera:nil))
    canvas.installPreparedFrame(grown,spatialSource:.init(surface:fixture.surface,journal:fixture.journal,suppressedInkIDs:[]))
    await withCheckedContinuation { continuation in grown.afterPresentationTransaction { continuation.resume() } }
    XCTAssertEqual(canvas.spatialTilePoolIDs.count, 9)
    let shrunk = try await canvas.prepareFrame(.spatial(nil,size:.init(x: 512, y: 768),displayScale:2,camera:nil))
    canvas.installPreparedFrame(shrunk,spatialSource:.init(surface:fixture.surface,journal:fixture.journal,suppressedInkIDs:[]))
    await withCheckedContinuation { continuation in shrunk.afterPresentationTransaction { continuation.resume() } }
    XCTAssertEqual(canvas.spatialTilePoolIDs, oldIDs)
    XCTAssertEqual(resources.reservedBytes, before,
      "Keeping both presentation receipts does not retain their drawable slots or discarded pools")
    withExtendedLifetime((grown, shrunk)) {}
  }

  func testInvalidOrUnrepresentableBackingRefusesBeforeLayoutEvenForEmptyContent() async throws {
    let resources = SceneRenderResources(), canvas = InkCanvasView(frame: .init(x: 0, y: 0, width: 128, height: 128), resources: resources)
    let bounds = canvas.bounds
    for value in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, 0, -1] {
      do {
        _ = try await canvas.prepareFrame(.spatial(.init(batches: []),size:.init(x: 128, y: 128),displayScale:value,camera:nil))
        XCTFail("An invalid extent cannot install an empty successful target")
      } catch { XCTAssertEqual(error as? SceneRenderError, .resourceLimit) }
      XCTAssertEqual(canvas.bounds, bounds); XCTAssertEqual(resources.reservedBytes, 0)
    }
    do {
      _ = try await canvas.prepareFrame(.spatial(.init(batches: []),size:.init(x: .greatestFiniteMagnitude, y: 128),displayScale:2,camera:nil))
      XCTFail("Finite logical coordinates still cannot overflow the pixel extent")
    } catch { XCTAssertEqual(error as? SceneRenderError, .resourceLimit) }
    await canvas.finishSpatialHandoffFrames()
  }

  func testWideBackingKeepsExactDensityBeyondTheFormer4096PixelClamp() async throws {
    let fixture = try await Fixture.make()
    addTeardownBlock { await fixture.close() }
    let frame = try await fixture.canvas.prepareFrame(.spatial(nil,size:.init(x: 2200, y: 128),displayScale:2,camera:nil))
    fixture.canvas.installPreparedFrame(frame,spatialSource:.init(surface:fixture.surface,journal:fixture.journal,suppressedInkIDs:[]))
    await withCheckedContinuation { continuation in frame.afterPresentationTransaction { continuation.resume() } }
    XCTAssertEqual(fixture.canvas.drawableSize, CGSize(width: 4400, height: 256))
    XCTAssertEqual(fixture.canvas.spatialTilePoolIDs.count, 9)
    XCTAssertEqual(try fixture.canvas.installedSpatialSource?.referenceInk(), try fixture.reference)
  }

  func testMeasuredPageMaskUsesChangedTilesAndIgnoresHiddenContactGrowth() async throws {
    let window=UIWindow(windowScene:try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    let controller=UIViewController();window.rootViewController=controller;window.makeKeyAndVisible()
    let canvas=InkCanvasView(frame:.zero,isErasureMask:true)
    controller.view.addSubview(canvas)
    canvas.projectPage(region:.init(x:100,y:200,width:512,height:768),
      sourceSize:.init(width:1000,height:1500),pixelDensity:2)
    addTeardownBlock { @MainActor in
      canvas.removeFromSuperview();window.isHidden=true;window.rootViewController=nil
      await canvas.finishSpatialHandoffFrames()
    }
    try await Task.sleep(for:.milliseconds(150))
    let stroke=ActiveEraserStroke()
    func sample(_ index:Int)->SpatialInkSample {
      .init(point:.init(x:130+Double(index),y:230),timeOffset:Double(index)/240,
        width:18,opacity:1,force:1,azimuth:0,altitude:1)
    }
    stroke.replaceMeasuredTail(from:0,with:(0..<100_000).map(sample))
    let first=canvas.submittedTileCount
    canvas.displayActiveEraser(stroke)
    try await Task.sleep(for:.milliseconds(200))
    XCTAssertNil(canvas.renderFailure)
    XCTAssertGreaterThan(canvas.submittedTileCount,first)
    XCTAssertLessThan(canvas.submittedTileCount-first,canvas.spatialTilePoolIDs.count)
    let shown=canvas.submittedTileCount,uploaded=canvas.activeUploadedByteCount
    stroke.replaceMeasuredTail(from:100_000,with:[sample(100_000)])
    canvas.displayActiveEraser(stroke)
    try await Task.sleep(for:.milliseconds(100))
    XCTAssertEqual(canvas.submittedTileCount,shown,"Growing hidden ink cannot redraw the page")
    XCTAssertLessThan(canvas.activeUploadedByteCount-uploaded,4096,"Upload only the changed tail")
  }

  func testLocalStrokeOnlyRedrawsDamagedTilesAndCancellationClearsOldBounds() async throws {
    let fixture = try await Fixture.make()
    addTeardownBlock { await fixture.close() }
    let canvas = fixture.canvas
    // Establish cache signatures after the private initial presentation.
    canvas.project(camera: .init(scale: 1), viewport: .init(x: 512, y: 768))
    try await Task.sleep(for: .milliseconds(150))
    let before = try pixels(canvas)
    let stroke = ActiveInkStroke(style: .standard)
    func point(_ x: CGFloat, _ y: CGFloat) -> PKStrokePoint {
      .init(
        location: .init(x: x, y: y), timeOffset: 0, size: .init(width: 4, height: 4), opacity: 1,
        force: 1, azimuth: 0, altitude: 1)
    }
    stroke.replaceMeasuredTail(from: 0, with: [point(30, 30), point(110, 80)])
    let submitted = canvas.submittedTileCount
    canvas.displayActiveStroke(stroke)
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertGreaterThan(canvas.submittedTileCount, submitted)
    XCTAssertLessThan(
      canvas.submittedTileCount - submitted, canvas.spatialTilePoolIDs.count,
      "A local contact cannot redraw all six retained tiles")
    XCTAssertNotEqual(try pixels(canvas), before)
    let painted = canvas.submittedTileCount
    canvas.clearActiveAction()
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertGreaterThan(canvas.submittedTileCount, painted)
    XCTAssertLessThan(canvas.submittedTileCount - painted, canvas.spatialTilePoolIDs.count)
    XCTAssertEqual(
      try pixels(canvas), before,
      "Removed content invalidates its old tile even without a new contributor")
    let idle = canvas.submittedTileCount
    try await Task.sleep(for: .milliseconds(80))
    XCTAssertEqual(canvas.submittedTileCount, idle)
  }

  func testMovingAWholeOffscreenClearsItsOldTilesWithoutPreparingHiddenGeometry() async throws {
    let fixture=try await Fixture.make()
    addTeardownBlock { await fixture.close() }
    let canvas=fixture.canvas
    canvas.project(camera:.init(scale:1),viewport:.init(x:512,y:768))
    try await Task.sleep(for:.milliseconds(150))
    let original=try pixels(canvas),built=canvas.preparedCommittedPointCount,submitted=canvas.submittedTileCount
    XCTAssertEqual(canvas.committedPreparedNodeCount,0)
    XCTAssertGreaterThan(built,0)
    let oldRow=CGRect(x:0,y:360,width:512,height:48)
    XCTAssertGreaterThan(try blackPixels(canvas,in:oldRow),0)
    canvas.project(camera:.init(center:.init(x:0,y:200),scale:1),viewport:.init(x:512,y:768))
    try await Task.sleep(for:.milliseconds(150))
    XCTAssertNotEqual(try pixels(canvas),original)
    XCTAssertGreaterThan(try blackPixels(canvas),0)
    XCTAssertEqual(try blackPixels(canvas,in:oldRow),0,"Moving the whole must not leave a second line in the old row")
    XCTAssertGreaterThan(canvas.submittedTileCount,submitted)
    XCTAssertLessThan(canvas.submittedTileCount-submitted,canvas.spatialTilePoolIDs.count)
    let beforeEmpty=canvas.submittedTileCount
    canvas.project(camera:.init(center:.init(x:2000,y:0),scale:1),viewport:.init(x:512,y:768))
    try await Task.sleep(for:.milliseconds(150))
    XCTAssertEqual(try blackPixels(canvas),0,"No old coverage may remain after the whole moves away")
    XCTAssertEqual(canvas.preparedCommittedPointCount,built)
    XCTAssertEqual(canvas.residentCommittedNodeCount,0)
    XCTAssertEqual(canvas.spatialTilePoolIDs.count,0,"A wholly empty projection releases its layers instead of drawing empty tiles")
    XCTAssertEqual(canvas.submittedTileCount,beforeEmpty)
    canvas.project(camera:.init(scale:1),viewport:.init(x:512,y:768))
    try await Task.sleep(for:.milliseconds(150))
    XCTAssertEqual(try pixels(canvas),original)
    XCTAssertGreaterThan(canvas.preparedCommittedPointCount,built)
  }

  func testVisibleCurveOverviewSelectsDetailBeforePreparationAndZoomRevealsSource() async throws {
    var samples:[SpatialInkSample]=[]
    for i in 0..<100_000 {
      let world=WorldPoint(x:(Double(i)-50_000)/32,y:64+sin(Double(i)*Double.pi/50)*0.005)
      samples.append(.init(point:.zero,worldPoint:world,timeOffset:Double(i)/128,width:128,opacity:1,force:0.75,azimuth:0,altitude:1))
    }
    let overview=SpatialCamera(center:.init(x:0,y:64),scale:SpatialCamera.minimumScale)
    let fixture=try await Fixture.make(samples:samples,camera:overview)
    addTeardownBlock { await fixture.close() }
    let canvas=fixture.canvas,original=try pixels(canvas),built=canvas.preparedCommittedPointCount
    XCTAssertEqual(canvas.committedSourceNodeCount,100_000)
    XCTAssertLessThan(built+canvas.queriedCommittedPointCount,32)
    XCTAssertEqual(canvas.residentCommittedNodeCount,4)
    XCTAssertGreaterThan(try blackPixels(canvas),0)
    canvas.project(camera:.init(center:.init(x:0,y:64),scale:1),viewport:.init(x:512,y:768))
    try await Task.sleep(for:.milliseconds(300))
    XCTAssertGreaterThan(canvas.preparedCommittedPointCount,built)
    XCTAssertLessThan(canvas.preparedCommittedPointCount,30_000)
    XCTAssertGreaterThan(canvas.residentCommittedNodeCount,4)
    XCTAssertNotEqual(try pixels(canvas),original)
    let zoomReads=canvas.preparedCommittedPointCount+canvas.queriedCommittedPointCount
    canvas.project(camera:overview,viewport:.init(x:512,y:768))
    try await Task.sleep(for:.milliseconds(200))
    XCTAssertEqual(canvas.residentCommittedNodeCount,4)
    XCTAssertEqual(try pixels(canvas),original,"Returning to coarse detail removes all previous fine pixels")
    XCTAssertLessThan(canvas.preparedCommittedPointCount+canvas.queriedCommittedPointCount-zoomReads,32)
    XCTAssertEqual(canvas.committedSourceNodeCount,100_000)
    let proof=XCTAttachment(image:capture(canvas));proof.name="visible-curve-coarse-overview";proof.lifetime = .keepAlways;add(proof)
  }

  func testSampleFreeOverviewSkipsSourceAndZoomReusesPreparedRanges() async throws {
    let scale=SpatialCamera.minimumScale
    let hidden=SpatialCamera(center:.init(x:0,y:64-0.125/scale),scale:scale)
    let shown=SpatialCamera(center:.init(x:0,y:64),scale:1)
    let samples: [SpatialInkSample]=(0..<100_000).map { i in
      let world=WorldPoint(x:(Double(i)-50_000)*0.4,y:64+sin(Double(i)*0.37)*0.25)
      return SpatialInkSample(point:.zero,worldPoint:world,timeOffset:Double(i)/128,
        width:0.5+Double(i%13)/104,opacity:0.25+Double(i%7)/16,force:0.75,azimuth:0,altitude:1)
    }
    let fixture=try await Fixture.make(samples:samples,camera:hidden)
    addTeardownBlock { await fixture.close() }
    let canvas=fixture.canvas,empty=try pixels(canvas)
    XCTAssertEqual(canvas.preparedCommittedPointCount,0)
    XCTAssertEqual(canvas.committedSourceNodeCount,100_000)
    XCTAssertEqual(canvas.residentCommittedNodeCount,0)
    canvas.project(camera:shown,viewport:.init(x:512,y:768))
    try await Task.sleep(for:.milliseconds(250))
    let visible=try pixels(canvas),built=canvas.preparedCommittedPointCount,bytes=canvas.residentCommittedBufferBytes
    XCTAssertGreaterThan(built,0);XCTAssertLessThan(built,10_000);XCTAssertNotEqual(visible,empty)
    canvas.project(camera:hidden,viewport:.init(x:512,y:768))
    try await Task.sleep(for:.milliseconds(150))
    XCTAssertEqual(canvas.preparedCommittedPointCount,built)
    XCTAssertEqual(canvas.visibleCommittedChunkCount,0)
    XCTAssertEqual(canvas.residentCommittedBufferBytes,bytes,"The existing pool retains only previously admitted detail")
    XCTAssertEqual(try pixels(canvas),empty,"Discarding the last visible range must remove old pixels")
    canvas.project(camera:shown,viewport:.init(x:512,y:768))
    try await Task.sleep(for:.milliseconds(250))
    XCTAssertEqual(try pixels(canvas),visible)
    XCTAssertEqual(canvas.preparedCommittedPointCount,built,"A zoom toggle must not decode the same source again")
  }

  private func assertContinuousCenterLine(_ canvas: UIView) throws {
    let image = try XCTUnwrap(capture(canvas).cgImage)
    let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
      bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: .init(x: 0, y: 0, width: image.width, height: image.height))
    let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
    for x in (image.width / 2 - 200)...(image.width / 2 + 200) {
      let offset = ((image.height / 2) * image.width + x) * 4
      XCTAssertLessThan(max(bytes[offset], bytes[offset + 1], bytes[offset + 2]), 64,
        "A tile seam cannot cut the opaque center of one native stroke at x=\(x)")
    }
  }

  private func capture(_ canvas: UIView) -> UIImage {
    let format = UIGraphicsImageRendererFormat(); format.scale = 1
    return UIGraphicsImageRenderer(size: canvas.bounds.size, format: format).image { context in
      UIColor.white.setFill(); context.fill(canvas.bounds)
      canvas.drawHierarchy(in: canvas.bounds, afterScreenUpdates: true)
    }
  }
  private func pixels(_ canvas: UIView) throws -> Data {
    let image = try XCTUnwrap(capture(canvas).cgImage)
    return try XCTUnwrap(image.dataProvider?.data) as Data
  }
  private func blackPixels(_ canvas: UIView,in region: CGRect? = nil) throws -> Int {
    let image = try XCTUnwrap(capture(canvas).cgImage)
    let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
      bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: .init(x: 0, y: 0, width: image.width, height: image.height))
    let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
    return stride(from: 0, to: image.width * image.height * 4, by: 4).filter {
      let point=CGPoint(x:($0/4)%image.width,y:($0/4)/image.width)
      return (region?.contains(point) ?? true) && bytes[$0] < 160 && bytes[$0 + 1] < 160 && bytes[$0 + 2] < 160
    }.count
  }

  @MainActor
  private final class Fixture {
    let resources = SceneRenderResources(byteLimit: 128 * 1024 * 1024)
    let surface = SurfaceID.board(UUID()), actor = UUID()
    let journal: SpatialInkJournal
    let window: UIWindow, host = Host(), canvas: InkCanvasView
    private var retention: SpatialInkCanvasRetention?
    private weak var oldKeyWindow: UIWindow?
    var reference: NotebookReferenceInk { get throws { try .init(surface: surface, actions: journal.actions) } }

    static func make(samples: [SpatialInkSample]? = nil,camera: SpatialCamera = .init(scale:1),extraContacts:Int = 0) async throws -> Fixture {
      let fixture = try Fixture(samples:samples,extraContacts:extraContacts)
      fixture.window.rootViewController = fixture.host
      fixture.host.view.addSubview(fixture.canvas); fixture.window.makeKeyAndVisible()
      let deadline = ContinuousClock.now + .seconds(5)
      while !fixture.host.appeared, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
      XCTAssertTrue(fixture.host.appeared)
      fixture.retention = fixture.canvas.retainForSpatialHandoff(displayScale: 2)
      fixture.canvas.project(camera: camera, viewport: .init(x: 512, y: 768))
      let mesh = try SpatialInkMesh.prepare(surface: fixture.surface, journal: fixture.journal)
      let frame = try await fixture.canvas.prepareFrame(.spatial(mesh,size:.init(x: 512, y: 768),displayScale:2,camera:nil))
      fixture.canvas.installPreparedFrame(frame,spatialSource:.init(surface:fixture.surface,journal:fixture.journal,suppressedInkIDs:[]))
      await withCheckedContinuation { continuation in frame.afterPresentationTransaction { continuation.resume() } }
      return fixture
    }
    private init(samples: [SpatialInkSample]?,extraContacts:Int) throws {
      let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
      window = UIWindow(windowScene: scene); oldKeyWindow = scene.windows.first(where: \.isKeyWindow)
      canvas = .init(frame: .init(x: 0, y: 0, width: 512, height: 768), resources: resources)
      var drawing = SpatialInkJournal(stamp: .init(counter: 0, actor: actor))
      _ = drawing.append(tool: .pen, spans: [.init(surface: surface, samples: samples ?? (0...600).map { index in
        let x = -220.0+Double(index)*440/600
        return .init(point: .zero, worldPoint: .init(x: x, y: 0), timeOffset: Double(index) / 10,
          width: 12, opacity: 1, force: 1, azimuth: 0, altitude: 1)
      })], actor: actor)
      if extraContacts>0 {
        var actions=drawing.actions
        for index in 0..<extraContacts {
          let visible=index<2,eraser=index == 1
          let samples:[SpatialInkSample]=(0..<2).map { point in
            let world:WorldPoint = eraser ? .init(x:-150,y:Double(point)*40-20)
              : .init(x:visible ? -180+Double(point)*60 : 10_000+Double(index%100),y:visible ? 80 : 10_000+Double(index/100))
            return .init(point:.zero,worldPoint:world,timeOffset:Double(point)/240,
              width:eraser ? 20 : 12,opacity:1,force:1,azimuth:0,altitude:1)
          }
          actions.append(.init(tool:eraser ? .eraser : .pen,spans:[.init(surface:surface,samples:samples)],
            stamp:.init(counter:UInt64(index+2),actor:actor)))
        }
        drawing = .init(actions:actions,stamp:.init(counter:UInt64(extraContacts+1),actor:actor))
      }
      journal = drawing
    }
    func close() async {
      await canvas.finishSpatialHandoffFrames()
      retention = nil; canvas.removeFromSuperview(); window.isHidden = true
      window.rootViewController = nil; oldKeyWindow?.makeKey()
    }
  }

  private final class Host: UIViewController {
    private(set) var appeared = false
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); appeared = true }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); appeared = false }
  }
}

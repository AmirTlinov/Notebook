import SwiftUI
import UIKit
import XCTest
@testable import Notebook

/// Observe real native curl images, independently of the run-loop latency
/// check: screenshot work must not be credited as display frames or FPS.
@MainActor final class NotebookPageMotionUXTests: XCTestCase {
  func testCurlConfiguresTheActualDrawableLayerBeforeItsFirstDisplayUpdate() throws {
    let curl = SheetCurlMetalView(frame: .init(x: 0, y: 0, width: 300, height: 300))
    let layer = try XCTUnwrap(curl.layer as? CAMetalLayer)
    for side in [600.0, 1200.0, 600.0] {
      let size = CGSize(width: side, height: side)
      curl.prepareDrawable(size: size)
      XCTAssertEqual(curl.drawableSize, size)
      XCTAssertEqual(layer.drawableSize, size,
        "A paused MTKView must not leave its custom display clock acquiring old-sized drawables")
      XCTAssertEqual(curl.submittedFrameCount, 0, "Preparing size is not a fake presentation")
    }
    curl.releaseSource()
  }

  func testCurlHasIntermediatePixelsAndDoesNotLeaveABindingShadow() async throws {
    let controller = IPadPageTurnController(), commands = NotebookPageNavigation(), owner = UUID()
    var selected = 0
    func configure() {
      controller.update(ownerID:owner,sequenceRevision:"motion",pageCount:3,selectedIndex:selected,
        navigationIsEnabled:true,pageIsInteractive:true,canBeginNavigation:{true},
        page:{ index,_,ready in
          ready(true)
          return AnyView(Color.white.overlay(alignment:.center) {
            (index == 0 ? Color.blue : Color.red).frame(width:400,height:400)
          })
        },onCommit:{ index,_ in selected=index; configure() },onTransitioningChange:{_ in},notebookNavigation:commands)
    }
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where:\.isKeyWindow), window = UIWindow(windowScene:scene)
    window.frame = .init(x:0,y:0,width:834,height:1194)
    configure(); window.rootViewController=controller; window.makeKeyAndVisible()
    defer { window.isHidden=true; window.rootViewController=nil; previous?.makeKey() }
    try await Task.sleep(for:.milliseconds(100))
    let reservedBefore = SceneRenderResources.shared.reservedBytes
    for (turn, targetIndex) in [1, 0, 1, 0].enumerated() {
      let targetColour: NotebookUXObservation.Color = targetIndex == 0 ? .blue : .red
      let sourceColour: NotebookUXObservation.Color = targetIndex == 0 ? .red : .blue
      XCTAssertTrue(commands.send(.step(targetIndex == 0 ? -1 : 1),ownerID:owner,source:"motion"))
      var intermediate = 0, shadowWidths: [Int] = []
      for frame in 0..<7 {
        try await Task.sleep(for:.milliseconds(55))
        let pixels = try NotebookUXObservation.Pixels(window:window)
        let source = try isSettled(pixels.image, mark: sourceColour)
        let target = try isSettled(pixels.image, mark: targetColour)
        if !source && !target { intermediate += 1 }
        let attachment = XCTAttachment(image:pixels.image)
        attachment.name="Native curl \(turn), frame \(frame)"; attachment.lifetime = .keepAlways; add(attachment)
        shadowWidths.append(try shadowWidth(pixels.image))
      }
      XCTAssertGreaterThan(intermediate,0,"A source→target jump without a bending sheet is not an animation")
      XCTAssertEqual(selected,targetIndex)
      // This screenshot-heavy lane proves shape/shadow, not product latency.
      // The presentation-only lane below owns the 16.67/450 ms deadlines.
      let final = try NotebookUXObservation.Pixels(window:window)
      XCTAssertTrue(try final.matches([(.init(x:417,y:597),targetColour)]))
      XCTAssertLessThanOrEqual(try shadowWidth(final.image),4,"A finished sheet must not retain the curl's binding shadow")
      let note=XCTAttachment(string:"Turn \(turn), left-edge dark widths: \(shadowWidths)")
      note.lifetime = .keepAlways; add(note)
      XCTAssertLessThanOrEqual(shadowWidths.max() ?? 0,32,"Sheet lighting cannot become a wide dark curtain along the screen")
      XCTAssertLessThanOrEqual(SceneRenderResources.shared.reservedBytes,reservedBefore,
        "A completed turn must release its image and drawable backing before another turn")
    }
  }

  func testTenForwardReverseTurnsMeetFirstPresentationAndLandingDeadlines() async throws {
    let controller = IPadPageTurnController(), commands = NotebookPageNavigation(), owner = UUID()
    var selected = 0, committedAt: TimeInterval?
    func configure() {
      controller.update(ownerID: owner, sequenceRevision: "motion-timing", pageCount: 3, selectedIndex: selected,
        navigationIsEnabled: true, pageIsInteractive: true, canBeginNavigation: { true },
        page: { index, _, ready in
          ready(true)
          return AnyView(Color.white.overlay {
            (index == 0 ? Color.blue : Color.red).frame(width: 400, height: 400)
          })
        }, onCommit: { index, _ in selected = index; configure(); committedAt = CACurrentMediaTime() },
        onTransitioningChange: { _ in }, notebookNavigation: commands)
    }
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
    window.frame = .init(x: 0, y: 0, width: 834, height: 1194)
    configure(); window.rootViewController = controller; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    try await Task.sleep(for: .milliseconds(100)) // Mount once; never prewarm a curl.
    let refreshRate = scene.screen.maximumFramesPerSecond
    XCTAssertGreaterThan(refreshRate, 0)
    let framePeriod = 1.0 / Double(max(1, refreshRate))
    // Target the device's advertised refresh rate, not a "budget" inferred from
    // the app's already-slow frames. 0.5 ms only tolerates clock/refresh jitter;
    // it cannot excuse a lost 8.33 ms (120 Hz) or 16.67 ms (60 Hz) interval.
    let presentationTolerance = 0.0005
    for turn in 0..<10 {
      let target = turn.isMultiple(of: 2) ? 1 : 0
      let curl = try XCTUnwrap(controller.sheetController.view.subviews.compactMap { $0 as? SheetCurlMetalView }.first)
      let forwardPresentation = curl.onFramePresented
      var frames: [(progress: Double, presented: TimeInterval, delivered: TimeInterval)] = []
      var submission: [SheetCurlMetalView.FrameTiming] = []
      curl.onFrameMeasured = { submission.append($0) }
      committedAt = nil
      curl.onFramePresented = { image, progress, presentedAt in
        frames.append((progress, presentedAt, CACurrentMediaTime()))
        forwardPresentation?(image, progress, presentedAt) // Preserve the completion owner.
      }
      let start = CACurrentMediaTime()
      XCTAssertTrue(commands.send(.step(target == 1 ? 1 : -1), ownerID: owner, source: "motion-timing"))
      let commandReturned = CACurrentMediaTime()
      while committedAt == nil, CACurrentMediaTime() - start < 1 {
        try await Task.sleep(for: .milliseconds(1))
      }
      curl.onFramePresented = forwardPresentation
      curl.onFrameMeasured = nil
      let encoding = XCTAttachment(string: "Command execution=\((commandReturned-start)*1000) ms\n" + submission.map {
        "start=\(($0.encodingBegan-start)*1000)ms; CPU=\(($0.submitted-$0.encodingBegan)*1000)ms; GPU queue=\(($0.gpuBegan-$0.submitted)*1000)ms; GPU=\(($0.gpuEnded-$0.gpuBegan)*1000)ms; target=\(($0.targetPresentation-start)*1000)ms"
      }.joined(separator: "\n"))
      encoding.name = "Curl submission timing \(turn)"; encoding.lifetime = .keepAlways; add(encoding)
      XCTAssertFalse(frames.isEmpty, "No OS presentation evidence")
      XCTAssertTrue(frames.allSatisfy {
        $0.presented.isFinite && $0.presented > 0 && $0.presented >= start && $0.presented <= $0.delivered
      }, "Zero/dropped, invalid or pre-command timestamps cannot stand in for displayed frames")
      // Delivery onto MainActor can be delayed or reordered. Only the OS clock
      // measures display cadence; callback delay is retained as a separate lane.
      // Missing receipts already fail above. Do not turn their zero timestamp
      // into a meaningless negative first-response or a multi-day frame gap.
      let ordered = frames.filter { $0.presented.isFinite && $0.presented >= start }
        .sorted { $0.presented < $1.presented }
      let first = try XCTUnwrap(ordered.first { $0.progress > 0 && $0.progress < 1 },
        "An unchanged initial image or a source→target jump is not visible animation feedback")
      XCTAssertLessThanOrEqual(Duration.seconds(first.presented - start), NotebookUXObservation.pageFirstResponse)
      let landed = try XCTUnwrap(committedAt, "The requested target never completed presentation")
      XCTAssertLessThanOrEqual(Duration.seconds(landed - start), NotebookUXObservation.pageLanding)
      XCTAssertEqual(selected, target)
      var changingFrames: [TimeInterval] = [], previousProgress: Double?
      for frame in ordered where frame.progress != previousProgress {
        changingFrames.append(frame.presented); previousProgress = frame.progress
      }
      let gaps = zip(changingFrames, changingFrames.dropFirst()).map { $1 - $0 }
      XCTAssertLessThanOrEqual(try XCTUnwrap(gaps.max()), framePeriod + presentationTolerance,
        "Changing displayed frames must meet \(refreshRate) Hz; callback time and average FPS cannot hide a missed interval")
      let note = XCTAttachment(string: "Turn \(turn): first=\((first.presented-start)*1000) ms; landing=\((landed-start)*1000) ms; target=\(refreshRate) Hz; OS presentation gaps=\(gaps); callback delays=\(ordered.map { $0.delivered-$0.presented }) s; unpresented progress=\(frames.filter { $0.presented <= 0 }.map(\.progress))")
      note.name = "Command-to-presentation deadlines"; note.lifetime = .keepAlways; add(note)
    }
  }

  private func isSettled(_ image: UIImage, mark: NotebookUXObservation.Color) throws -> Bool {
    let cg = try XCTUnwrap(image.cgImage), w = cg.width, h = cg.height
    var rgba = [UInt8](repeating: 0, count: w*h*4)
    try rgba.withUnsafeMutableBytes { bytes in
      let context = try XCTUnwrap(CGContext(data:bytes.baseAddress,width:w,height:h,bitsPerComponent:8,
        bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(cg,in:.init(x:0,y:0,width:w,height:h))
    }
    for y in stride(from: 8, to: h, by: 16) {
      for x in stride(from: 8, to: w, by: 16) {
        let colour: NotebookUXObservation.Color = (217..<617).contains(x) && (397..<797).contains(y) ? mark : .paper
        let offset = (y*w+x)*4
        if !colour.matches(Array(rgba[offset..<offset+4])) { return false }
      }
    }
    return true
  }

  private func shadowWidth(_ image:UIImage) throws -> Int {
    let strip = try XCTUnwrap(image.cgImage?.cropping(to:.init(x:2,y:300,width:160,height:1)))
    var rgba = [UInt8](repeating:0,count:640)
    try rgba.withUnsafeMutableBytes { bytes in
      let context = try XCTUnwrap(CGContext(data:bytes.baseAddress,width:160,height:1,bitsPerComponent:8,
        bytesPerRow:640,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(strip,in:.init(x:0,y:0,width:160,height:1))
    }
    return (0..<160).filter { x in (0..<3).allSatisfy { rgba[x*4+$0] < 220 } }.count
  }
}

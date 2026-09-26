import Darwin
import SwiftUI
import UIKit
import XCTest
@testable import Notebook

/// Same fixture for baseline and candidate; no screenshot/readback in the timed
/// lane. OS display time, callback delay, capture, CPU encode and GPU are separate.
@MainActor final class NotebookPageTurnPerformanceTests: XCTestCase {
  func testRecordTwentyPhysicalPageTurns() async throws {
    XCTAssertTrue(MetalFrameCompletion.reportsDisplayTime, "Physical iPad only")
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
    let controller = IPadPageTurnController(), commands = NotebookPageNavigation(), ownerID = UUID()
    var selected = 0, committedAt: Double?
    func configure() {
      controller.update(ownerID: ownerID, sequenceRevision: "page-turn-performance", pageCount: 3, selectedIndex: selected,
        navigationIsEnabled: true, pageIsInteractive: true, canBeginNavigation: { true },
        page: { index, _, ready in
          ready(true)
          return AnyView(Color.white.overlay {
            VStack(spacing: 6) {
              Text("Лист \(index)").font(.largeTitle)
              ForEach(0..<24) { line in Text("\(line) — Точный источник, движение и следующий контакт.").font(.body) }
              Rectangle().fill(index == 0 ? Color.blue : Color.red).frame(height: 200)
            }
          })
        }, onCommit: { index, _ in selected = index; configure(); committedAt = CACurrentMediaTime() },
        onTransitioningChange: { _ in }, notebookNavigation: commands)
    }
    configure(); window.rootViewController = controller; window.makeKeyAndVisible()
    defer { controller.sheetController.cancelMotion(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    try await Task.sleep(for: .milliseconds(100)) // Only mount; no curl warmup.
    let native = controller.sheetController
    let curl = try XCTUnwrap(native.view.subviews.compactMap { $0 as? SheetCurlMetalView }.first)
    let resolve = curl.onFrameResolved
    var rows: [[String: Any]] = []
    let idleBytes = footprint(), reservedBefore = SceneRenderResources.shared.reservedBytes
    for turn in 0..<20 {
      var captures: [IPadSheetCurlController.CaptureTiming] = []
      var frames: [[String: Double]] = [], submits: [[String: Double]] = []
      var peak = footprint(), reservedPeak = SceneRenderResources.shared.reservedBytes
      native.onCaptureMeasured = { captures.append($0) }
      curl.onFrameMeasured = { frame in
        submits.append(["encodeStart": frame.encodingBegan, "submitted": frame.submitted,
          "gpuStart": frame.gpuBegan, "gpuEnd": frame.gpuEnded, "targetDisplay": frame.targetPresentation])
      }
      curl.onFrameResolved = { image, progress, receipt in
        frames.append(["progress": progress, "displayed": receipt.completion.presentationTime ?? 0,
          "callback": CACurrentMediaTime()])
        peak = max(peak, self.footprint())
        reservedPeak = max(reservedPeak, SceneRenderResources.shared.reservedBytes)
        resolve?(image, progress, receipt)
      }
      committedAt = nil
      let start = CACurrentMediaTime(), target = turn.isMultiple(of: 2) ? 1 : 0
      XCTAssertTrue(commands.send(.step(target == 1 ? 1 : -1), ownerID: ownerID, source: "page-turn-performance"))
      let commandEnd = CACurrentMediaTime(), deadline = start + 3
      while committedAt == nil, CACurrentMediaTime() < deadline { try await Task.sleep(for: .milliseconds(2)) }
      XCTAssertEqual(selected, target); XCTAssertNotNil(committedAt)
      rows.append(["turn": turn, "coldCurl": turn == 0, "start": start, "commandEnd": commandEnd,
        "landed": committedAt ?? 0, "captures": captures.map { ["begin": $0.began, "end": $0.ended, "pixels": Double($0.pixels)] },
        "frames": frames, "submits": submits, "peakFootprintSampleBytes": peak,
        "peakReservationBytes": reservedPeak, "thermalState": ProcessInfo.processInfo.thermalState.rawValue])
      try await Task.sleep(for: .milliseconds(20))
      XCTAssertLessThanOrEqual(SceneRenderResources.shared.reservedBytes, reservedBefore)
    }
    let report: [String: Any] = ["os": UIDevice.current.systemVersion,
      "maximumRefreshRate": scene.screen.maximumFramesPerSecond,
      "lowPowerMode": ProcessInfo.processInfo.isLowPowerModeEnabled,
      "idleFootprintBytes": idleBytes, "finalFootprintBytes": footprint(), "turns": rows,
      "scope": "Optimized native test fixture; OS presentation is not optical input-to-photon; footprint samples are not an allocation trace."]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
    attachment.name = "physical-page-turn-performance.json"; attachment.lifetime = .keepAlways; add(attachment)
  }

  private func footprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size/MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : 0
  }
}

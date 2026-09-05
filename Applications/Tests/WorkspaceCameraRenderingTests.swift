import NotebookCore
import SwiftUI
import UIKit
import XCTest
@testable import Notebook

final class WorkspaceCameraRenderingTests: XCTestCase {
  @MainActor
  func testDenseBoardKeepsFramesMovingDuringZoom() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = NotebookAppModel(store: NotebookStore(root: root), startsNearbySync: false)
    model.start(pageSize: NotebookAppModel.defaultPageSize)
    let boardID = try XCTUnwrap(model.workspace?.rootBoardID)
    var journal = try XCTUnwrap(model.spatialInk)
    for index in 0..<8 {
      let center = WorldPoint(x: Double(index % 4) * 1100, y: Double(index / 4) * 1500)
      let id = try XCTUnwrap(model.createNotebook(at: center))
      for stroke in 0..<4 {
        let samples = (0..<120).map { point in
          SpatialInkSample(point: SpatialPoint(x: 100 + Double(point) * 4,
            y: 240 + Double(stroke) * 130 + sin(Double(point) / 5) * 70),
            timeOffset: Double(point) / 120, width: stroke == 3 ? 40 : 5,
            opacity: 1, force: 1, azimuth: 0, altitude: 1)
        }
        _ = journal.append(tool: stroke == 3 ? .eraser : .pen,
          spans: [SpatialInkSpan(surface: .cover(id), samples: samples)], actor: model.actorID)
      }
    }
    model.receivePeerMessage(.spatialInk(journal))
    await model.finishPendingPersistence()
    XCTAssertEqual(model.spatialInk?.actions.count, 32,
      "Камера должна измеряться после приёма чернил всех восьми обложек")
    let size = SpatialPoint(x: 1194, y: 834)
    let center = WorldPoint(x: 1650, y: 750)
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: size.x, height: size.y)
    let host = UIHostingController(rootView: SpatialWorkspaceView().environment(model))
    window.rootViewController = host
    model.updatePresence(SessionPresence(boardID: boardID, mode: .board, camera: SpatialCamera(center: center, scale: 0.15), viewport: size), settled: false)
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    try await Task.sleep(for: .seconds(2))
    let end = expectation(description: "camera frames")
    let driver = CameraFrameDriver()
    driver.step = { frame in
      let scale = exp(log(0.035) + (log(0.8) - log(0.035)) * (sin(Double(frame) / 30) + 1) / 2)
      model.updatePresence(SessionPresence(boardID: boardID, mode: .board,
        camera: SpatialCamera(center: center, scale: scale), viewport: size), settled: false)
      if frame == 120 { driver.stop(); end.fulfill() }
    }
    driver.start()
    await fulfillment(of: [end], timeout: 60)
    driver.stop()
    let times = Array(driver.intervals.dropFirst(10)).sorted()
    XCTAssertGreaterThan(times.count, 100)
    guard !times.isEmpty else { return }
    let p95 = times[times.count * 95 / 100]
    let report = "frames=\(times.count); p50=\(times[times.count / 2]); p95=\(p95); max=\(times.last!)"
    let attachment = XCTAttachment(string: report)
    attachment.name = "Dense board camera frame intervals in seconds"
    attachment.lifetime = .keepAlways
    add(attachment)
    XCTAssertLessThan(p95, 0.1, report)
  }
}

@MainActor
private final class CameraFrameDriver: NSObject {
  var step: ((Int) -> Void)?
  var intervals: [Double] = []
  var link: CADisplayLink?
  var previous: Double?
  var frame = 0
  func start() {
    link = CADisplayLink(target: self, selector: #selector(tick(_:)))
    link?.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
    link?.add(to: .main, forMode: .common)
  }
  func stop() { link?.invalidate(); link = nil; step = nil }
  @objc func tick(_ link: CADisplayLink) {
    let now = CACurrentMediaTime()
    if let previous { intervals.append(now - previous) }
    previous = now
    frame += 1
    step?(frame)
  }
}

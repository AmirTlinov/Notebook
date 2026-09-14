import Foundation
import NotebookCore
import UIKit
import SwiftUI

/// This file is copied into an immutable audit build only. It is not an app
/// source in the working tree and never reads a production container.
@MainActor
enum NotebookCameraAcceptanceFixture {
  static let bundleID = "com.amirtlinov.notebook.cameraaudit"
  static let actor = UUID(uuidString: "CA000000-0000-4000-8000-000000000001")!
  private static var traceURL: URL?
  private static var inputTrace: [[String: Any]] = []
  static var witnessTag: UInt32?
  private static let timebase: mach_timebase_info_data_t = {
    var info = mach_timebase_info_data_t(); mach_timebase_info(&info); return info
  }()
  static func machNanos() -> UInt64 {
    let ticks = mach_absolute_time(), numerator = UInt64(timebase.numer), denominator = UInt64(timebase.denom)
    return (ticks / denominator) * numerator + (ticks % denominator) * numerator / denominator
  }

  /// Observation only: native UIKit contacts, recognizer scale and the camera
  /// before/after its existing owner. No gesture or presentation is injected.
  static func recordContacts(_ recognizer: TwoFingerPaperGestureRecognizer) {
    inputTrace.append([
      "kind": "contacts", "time": Date().timeIntervalSince1970, "machNanos": machNanos(),
      "state": recognizer.state.rawValue, "magnification": Double(recognizer.magnification),
      "points": (0..<recognizer.numberOfTouches).map { index in
        let point = recognizer.location(ofTouch: index, in: recognizer.view)
        return [Double(point.x), Double(point.y)]
      },
    ])
  }

  static func recordCamera(_ phase: WorkspaceMagnificationPhase,
    before: SessionPresence?, after: SessionPresence?) {
    var entry: [String: Any] = ["kind": "camera", "time": Date().timeIntervalSince1970, "machNanos": machNanos()]
    switch phase {
    case .began: entry["phase"] = "began"
    case .changed(let scale, _, _, _): entry["phase"] = "changed"; entry["magnification"] = Double(scale)
    case .ended(let scale, _, _, _): entry["phase"] = "ended"; entry["magnification"] = Double(scale)
    case .cancelled: entry["phase"] = "cancelled"
    }
    entry["beforeScale"] = before?.camera.scale
    entry["afterScale"] = after?.camera.scale
    entry["before"] = camera(before)
    entry["after"] = camera(after)
    inputTrace.append(entry)
    if case .ended = phase, let traceURL,
      let data = try? JSONSerialization.data(withJSONObject: inputTrace, options: [.sortedKeys]) {
      try? data.write(to: traceURL, options: .atomic)
    }
  }

  static func recordPan(_ translation: CGPoint, before: SessionPresence?, after: SessionPresence?) {
    inputTrace.append(["kind": "pan", "time": Date().timeIntervalSince1970, "machNanos": machNanos(),
      "translation": [Double(translation.x), Double(translation.y)],
      "before": camera(before), "after": camera(after)])
  }

  /// Pose samples only associate captured frames with accepted contacts. The
  /// image instrument derives SVG/WK error from observed ink pixels alone.
  private static func camera(_ value: SessionPresence?) -> [String: Double] {
    guard let value else { return [:] }
    let origin = value.camera.worldToScreen(.zero, viewport: value.viewport)
    return ["scale": value.camera.scale, "originX": origin.x, "originY": origin.y,
      "viewportWidth": value.viewport.x, "viewportHeight": value.viewport.y]
  }

  static func makeLaunch() -> NotebookApplicationLaunch {
    #if targetEnvironment(simulator)
    let env = ProcessInfo.processInfo.environment
    guard Bundle.main.bundleIdentifier == bundleID,
      let run = env["NOTEBOOK_CAMERA_AUDIT_RUN"].flatMap(UUID.init(uuidString:)),
      let variant = env["NOTEBOOK_CAMERA_AUDIT_VARIANT"], ["static", "live"].contains(variant),
      NSHomeDirectory().contains("/CoreSimulator/Devices/") else {
      preconditionFailure("Camera audit requires its dedicated Simulator bundle and run identity")
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("NotebookCameraAudit", isDirectory: true)
      .appendingPathComponent(run.uuidString, isDirectory: true)
    witnessTag = nil
    if env["NOTEBOOK_CAMERA_TEMPORAL_WITNESS"] == "1" {
      witnessTag = run.uuidString.lowercased().utf8.reduce(UInt32(2166136261)) { ($0 ^ UInt32($1)) &* 16777619 }
    }
    precondition(!FileManager.default.fileExists(atPath: root.path), "Camera audit runs never reuse a store")
    do {
      let store = NotebookStore(root: root)
      let header = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
      traceURL = root.appendingPathComponent("camera-input-trace.json")
      var index = try store.loadIndex()
      var hierarchy = try store.loadBoard(items: index.items)
      let before = hierarchy
      if let first = index.items.first {
        precondition(hierarchy.moveItem(first.id, in: header.rootBoardID, to: .init(x: -1100, y: 1350), actor: actor))
      }
      hierarchy = try store.saveBoardEdits(before: before, after: hierarchy)
      for x in [0.0, 1100.0] {
        guard let created = index.createNotebook(title: "Camera paper", actor: actor,
          pageSize: .init(width: 834, height: 1194)) else { preconditionFailure("Cannot create audit paper") }
        precondition(hierarchy.addItem(created.item.id, to: header.rootBoardID, near: .init(x: x, y: 1350), actor: actor))
        try store.saveWorkspaceBundle(index: index, page: created.page, board: hierarchy)
      }
      let original = hierarchy
      let svgID = variant == "static" ? "z-camera-svg" : "0-camera-svg"
      let svg = SpatialElement(id: svgID, surface: .board(header.rootBoardID), kind: .web,
        frame: .init(x: 0, y: 0, width: 200, height: 180), worldOrigin: .init(x: -300, y: -150),
        source: "Camera red vector", html: cross(color: "#ed1220", title: "SVG"), css: style,
        stamp: .init(counter: 1, actor: actor))
      precondition(hierarchy.upsertElement(svg, in: header.rootBoardID, expected: nil, actor: actor))
      let control = SpatialElement(id: "0-camera-control", surface: .board(header.rootBoardID), kind: .web,
        frame: .init(x: 0, y: 0, width: 200, height: 180), worldOrigin: .init(x: 100, y: -150),
        source: "Camera live control", html: cross(color: "#17c044", title: "WK") +
          "<button id='pulse' aria-label='Camera pulse' style='position:absolute;left:20px;top:120px;width:160px;height:44px'>Camera pulse</button>",
        css: style, javaScript: """
          let count = Number(window.notebook.state?.count || 0);
          document.getElementById('pulse').onclick = () => {
            window.notebook.commit({count: ++count});
            document.getElementById('pulse').textContent = 'Pulse ' + count;
          };
          """, stamp: .init(counter: 1, actor: actor))
      precondition(hierarchy.upsertElement(control, in: header.rootBoardID, expected: nil, actor: actor))
      // The public owner budget admits seven element owners plus the ink plane.
      // Equal positions and ordering drive either the actual static tile path
      // or the actual native SVG path, without overriding renderer admission.
      for n in 0..<(variant == "static" ? 6 : 5) {
        let filler = SpatialElement(id: "1-camera-filler-\(n)", surface: .board(header.rootBoardID), kind: .nativeText,
          frame: .init(x: 0, y: 0, width: 100, height: 60), worldOrigin: .init(x: -450 + Double(n) * 150, y: -380),
          source: "\(n + 1)", stamp: .init(counter: 1, actor: actor))
        precondition(hierarchy.upsertElement(filler, in: header.rootBoardID, expected: nil, actor: actor))
      }
      _ = try store.saveBoardEdits(before: original, after: hierarchy)
      var ink = SpatialInkJournal(stamp: .init(counter: 0, actor: actor))
      for (x, color) in [(-400.0, SpatialInkColor(red: 0.02, green: 0.25, blue: 1)),
                         (400.0, SpatialInkColor(red: 1, green: 0.5, blue: 0))] {
        for points in [[SpatialPoint(x: x - 16, y: 220), .init(x: x + 16, y: 220)],
                       [SpatialPoint(x: x, y: 204), .init(x: x, y: 236)]] {
          let samples = points.enumerated().map { n, point in
            SpatialInkSample(point: .zero, worldPoint: .init(x: point.x, y: point.y),
              timeOffset: Double(n) * 0.1, width: 8, opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
          }
          precondition(ink.append(tool: .pen, color: color,
            spans: [.init(surface: .board(header.rootBoardID), samples: samples)], actor: actor) != nil)
        }
      }
      try store.saveSpatialInk(ink)
      try store.savePresence(.init(boardID: header.rootBoardID, mode: .board,
        camera: .init(center: .zero, scale: 0.5), viewport: .init(x: 834, y: 1194)))
      let model = NotebookAppModel(store: store, startsNearbySync: false)
      Task { [weak model] in
        do {
          // Real addressed source edits arrive while XCUITest moves the camera.
          // No camera samples, readiness flags or raster caches are synthesized.
          for sequence in 1...2 {
            try await Task.sleep(for: .seconds(10))
            guard let model else { return }
            let currentIndex = try store.loadIndex()
            let old = try store.loadBoard(items: currentIndex.items)
            var changed = old
            let id = "zz-camera-delayed"
            let previous = old.board(header.rootBoardID)?.elements.first { $0.id == id }
            let late = SpatialElement(id: id, surface: .board(header.rootBoardID), kind: .web,
              frame: .init(x: 0, y: 0, width: 120, height: 120), worldOrigin: .init(x: -570, y: -510),
              source: "Delayed revision \(sequence)",
              html: "<div style='background:#9135d9;width:100%;height:100%'>\(sequence)</div><script>window.notebook.ready(new Promise(resolve => setTimeout(resolve, 4500)))</script>",
              css: style, stamp: .init(counter: UInt64(sequence + 10), actor: actor))
            precondition(changed.upsertElement(late, in: header.rootBoardID, expected: previous?.stamp, actor: actor))
            _ = try store.saveBoardEdits(before: old, after: changed)
            await model.reloadExternalChanges()?.value
          }
        } catch { preconditionFailure("Camera audit publication failed: \(error)") }
      }
      return NotebookApplicationLaunch(fixture: model)
    } catch { preconditionFailure("Camera audit seed failed: \(error)") }
    #else
    preconditionFailure("Camera audit is Simulator-only")
    #endif
  }

  private static let style = "html,body{margin:0;width:100%;height:100%;overflow:hidden;background:white}body{position:relative}button{font:14px sans-serif}"
  private static func cross(color: String, title: String) -> String {
    "<svg width='200' height='180' viewBox='0 0 200 180'><path d='M84 70H116M100 54V86' stroke='\(color)' stroke-width='8'/><text x='10' y='22' fill='#111' font-size='15'>\(title)</text></svg>"
  }
}

/// The strip names a monotonically published visual cohort. A display-link tick
/// is scheduling only; neither this sequence nor its cadence is a GPU-frame/FPS claim.
struct NotebookCameraWitnessMount: UIViewRepresentable {
  func makeUIView(context: Context) -> Mount { Mount() }
  func updateUIView(_ uiView: Mount, context: Context) {}
  final class Mount: UIView {
    private var witness: Witness?
    override func didMoveToWindow() {
      super.didMoveToWindow()
      witness?.removeFromSuperview(); witness = nil
      guard let window, let tag = NotebookCameraAcceptanceFixture.witnessTag else { return }
      let view = Witness(tag: tag)
      view.translatesAutoresizingMaskIntoConstraints = false
      window.addSubview(view)
      NSLayoutConstraint.activate([
        view.centerXAnchor.constraint(equalTo: window.centerXAnchor),
        view.topAnchor.constraint(equalTo: window.topAnchor, constant: 84),
        view.widthAnchor.constraint(equalToConstant: 288), view.heightAnchor.constraint(equalToConstant: 6),
      ])
      witness = view
    }
  }
  @MainActor final class Tick: NSObject {
    weak var view: Witness?
    init(_ view: Witness) { self.view = view }
    @objc func publish() { view?.setNeedsDisplay() }
  }
  final class Witness: UIView {
    let runTag: UInt32
    private var sequence: UInt32 = 0
    private var link: CADisplayLink?
    init(tag: UInt32) {
      self.runTag = tag; super.init(frame: .zero)
      isUserInteractionEnabled = false; isAccessibilityElement = false
      accessibilityElementsHidden = true; isOpaque = true; contentMode = .redraw
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func didMoveToWindow() {
      super.didMoveToWindow(); link?.invalidate(); link = nil
      guard window != nil else { return }
      let display = CADisplayLink(target: Tick(self), selector: #selector(Tick.publish))
      display.preferredFrameRateRange = .init(minimum: 30, maximum: 30, preferred: 30)
      display.add(to: .main, forMode: .common); link = display
    }
    override func draw(_ rect: CGRect) {
      guard let context = UIGraphicsGetCurrentContext() else { return }
      precondition(sequence < 0xffffff, "A witness sequence must never wrap")
      sequence += 1
      var payload = [UInt8((runTag >> 24) & 255), UInt8((runTag >> 16) & 255), UInt8((runTag >> 8) & 255), UInt8(runTag & 255),
        UInt8((sequence >> 16) & 255), UInt8((sequence >> 8) & 255), UInt8(sequence & 255)]
      var crc: UInt8 = 0
      for byte in payload {
        crc ^= byte
        for _ in 0..<8 { crc = (crc &<< 1) ^ (crc & 128 != 0 ? 7 : 0) }
      }
      payload.insert(0xa5, at: 0); payload.append(crc)
      context.setShouldAntialias(false)
      for (byteIndex, byte) in payload.enumerated() {
        for bit in 0..<8 {
          let white = byte & (1 << (7-bit)) != 0
          context.setFillColor((white ? UIColor.white : UIColor.black).cgColor)
          context.fill(CGRect(x: CGFloat(byteIndex*8+bit)*4, y: 0, width: 4, height: bounds.height))
        }
      }
    }
  }
}

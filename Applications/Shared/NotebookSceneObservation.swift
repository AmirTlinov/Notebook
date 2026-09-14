import Foundation
import NotebookCore

/// Metadata only: this weak reference cannot extend a paint cohort's lifetime.
@MainActor final class NotebookSceneObservationContext {
  weak var cohort: SceneCompositionCohort?
  let paintID: UUID?
  let worksetContainsTarget: Bool
  init(cohort: SceneCompositionCohort?, worksetContainsTarget: Bool) {
    self.cohort = cohort; paintID = cohort?.paintID
    self.worksetContainsTarget = worksetContainsTarget
  }
}

#if os(iOS)
import Darwin
import UIKit

/// An opt-in observer of existing owners. It never drives layout, focus, camera,
/// input or presentation. UIKit geometry is not evidence of displayed glyphs.
@MainActor enum NotebookSceneObservation {
  static let targetID = "acceptance-native-title"
  private static let recorder = Recorder.configured()
  private final class Binding {
    weak var host: UIView?
    let stamp: VersionStamp?
    init(_ host: UIView, stamp: VersionStamp?) { self.host = host; self.stamp = stamp }
  }
  private static var bindings: [ObjectIdentifier: Binding] = [:]
  static var enabled: Bool { recorder?.sink.accepting == true }

  static func context(cohort: SceneCompositionCohort?, elements: [SpatialElement]) -> NotebookSceneObservationContext? {
    guard enabled else { return nil }
    return .init(cohort: cohort, worksetContainsTarget: elements.contains { $0.id == targetID })
  }

  static func element(_ id: String?, stamp: VersionStamp?, host: UIView?, event: String) {
    guard enabled, id == targetID, let host else { return }
    let began = mach_absolute_time()
    bindings[ObjectIdentifier(host)] = Binding(host, stamp: stamp)
    recorder?.append(["kind": .string(event), "elementID": .string(targetID),
      "native": native(host), "publishedSourceStamp": version(stamp),
      "observationBeginMach": .string(String(began))])
  }

  static func retire(_ id: String?, host: UIView?) {
    guard enabled, id == targetID, let host else { return }
    recorder?.append(["kind": .string("element_retire"), "elementID": .string(targetID), "native": native(host)])
    bindings[ObjectIdentifier(host)] = nil
  }

  static func plane(_ context: NotebookSceneObservationContext?, model: NotebookAppModel?,
    presence: SessionPresence?, anchor: SessionPresence?, host: UIView?, event: String,
    publications: Int, projections: Int, installed: Bool) {
    guard enabled, let context, let presence else { return }
    let began = mach_absolute_time()
    let cohort = context.cohort
    let current = model?.sceneIndex?.element(id: targetID, boardID: presence.boardID)
    let represented = cohort?.frame.index.element(id: targetID, boardID: presence.boardID)
    let viewport = NotebookSceneState.bounds(for: presence, margin: 0)
    var value: [String: JSONValue] = ["kind": .string(event), "elementID": .string(targetID),
      "observationBeginMach": .string(String(began)),
      "camera": camera(presence), "anchor": anchor.map(camera) ?? .null,
      "representedPaintID": uuid(context.paintID), "representedCohortAlive": .bool(cohort != nil),
      "worksetContainsTarget": .bool(context.worksetContainsTarget),
      "publications": .number(Double(publications)), "projections": .number(Double(projections)),
      "planeInstalled": .bool(installed), "currentIndexSource": current.map(source) ?? .null,
      "representedIndexSource": represented.map(source) ?? .null]
    if let host { value["planeHost"] = geometry(host) }
    if let model {
      value["model"] = .object(["phase": .string(model.presencePhase.rawValue),
        "indexID": uuid(model.sceneIndex?.generationID),
        "indexGeneration": .string(String(model.sceneIndexGeneration)),
        "publicationGeneration": .string(String(model.scenePublicationGeneration)),
        "queryCount": .string(String(model.sceneQueryCount)),
        "preparationPending": .bool(model.scenePreparationPending),
        "compositionPreparing": .bool(model.compositionTiles.isPreparing),
        "compositionHasFailure": .bool(model.compositionTiles.failure != nil),
        "publishedPaintID": uuid(model.compositionTiles.published?.paintID),
        "coverageContainsViewport": .bool(model.sceneCoverage[presence.boardID]?.contains(viewport) == true)])
    }
    if let cohort {
      let owner = cohort.plan.liveOwners.first { $0.plane == .board(presence.boardID) && $0.id == .element(targetID) }
      value["cohort"] = .object(["geometryID": uuid(cohort.geometryID), "paintID": uuid(cohort.paintID),
        "revision": .string(String(cohort.plan.revision)), "frameIndexID": uuid(cohort.frame.index.generationID),
        "requestedIndexID": uuid(cohort.requestedSources.generation),
        "requestedContainsTarget": .bool(cohort.requestedSources.boards[presence.boardID]?.contains(.element(targetID)) == true),
        "frameContainsTarget": .bool(cohort.frame.worksets[presence.boardID]?.elements.contains { $0.id == targetID } == true),
        "liveOwner": .bool(owner != nil),
        "liveRank": cohort.plan.rank(id: .element(targetID), in: .board(presence.boardID)).map(JSONValue.number) ?? .null,
        "paintInstalled": .bool(cohort.isPaintInstalled)])
      if let represented, let origin = represented.worldOrigin,
        let index = cohort.frame.index.board(id: presence.boardID)?.elements.firstIndex(where: { $0.id == targetID }) {
        let bounds = WorkspaceSpatialBounds(origin: origin.offsetBy(x: represented.frame.x, y: represented.frame.y),
          width: represented.frame.width, height: represented.frame.height)
        let position = ScenePaintPosition(layer: .elements, zIndex: Double(index), key: targetID)
        let keys = cohort.plan.tiles.filter { key in
          key.plane == .board(presence.boardID) && key.range.layer == .elements
            && (key.range.lower == nil || key.range.lower! < position)
            && (key.range.upper == nil || position < key.range.upper!)
            && key.tile.bounds.intersects(bounds) && key.tile.bounds.intersects(viewport)
        }
        value["representedSourceIntersectsViewport"] = .bool(bounds.intersects(viewport))
        value["staticTiles"] = .array(keys.prefix(SceneCompositionPlan.maximumTiles).map { key in
          let installed = cohort.observedTileInstallation(key)
          return .object(["tile": .object(["level": .number(Double(key.tile.level)),
            "origin": point(key.tile.origin), "worldSize": .number(key.tile.worldSize)]),
            "pixelSize": .number(Double(key.pixelSize)),
            "requiredEntryID": uuid(cohort.rasters[key]?.entryID),
            "installedEntryID": uuid(installed.entryID), "installed": .bool(installed.isInstalled)])
        })
      }
    }
    bindings = bindings.filter { $0.value.host != nil }
    value["nativeBindings"] = .array(bindings.values.compactMap { binding in
      binding.host.map { .object(["native": native($0), "publishedSourceStamp": version(binding.stamp)]) }
    })
    recorder?.append(value)
  }

  private static func source(_ value: SpatialElement) -> JSONValue {
    .object(["kind": .string(value.kind.rawValue), "frame": numbers([value.frame.x, value.frame.y, value.frame.width, value.frame.height]),
      "origin": value.worldOrigin.map(point) ?? .null,
      "stampActor": uuid(value.stamp.actor), "stampCounter": .string(String(value.stamp.counter))])
  }
  private static func camera(_ value: SessionPresence) -> JSONValue {
    .object(["boardID": uuid(value.boardID), "center": point(value.camera.center),
      "scale": .number(value.camera.scale), "viewport": numbers([value.viewport.x, value.viewport.y])])
  }
  private static func point(_ value: WorldPoint) -> JSONValue {
    .object(["tileX": .string(String(value.tileX)), "tileY": .string(String(value.tileY)),
      "localX": .number(value.localX), "localY": .number(value.localY)])
  }
  private static func uuid(_ value: UUID?) -> JSONValue { value.map { .string($0.uuidString) } ?? .null }
  private static func version(_ value: VersionStamp?) -> JSONValue {
    value.map { .object(["actor": uuid($0.actor), "counter": .string(String($0.counter))]) } ?? .null
  }
  private static func numbers(_ values: [Double]) -> JSONValue { .array(values.map { $0.isFinite ? .number($0) : .null }) }
  private static func rect(_ value: CGRect) -> JSONValue { numbers([value.origin.x, value.origin.y, value.width, value.height].map(Double.init)) }
  private static func identity(_ view: UIView) -> JSONValue { .string(String(describing: ObjectIdentifier(view))) }
  private static func geometry(_ view: UIView) -> JSONValue {
    .object(["identity": identity(view), "class": .string(String(describing: type(of: view))),
      "bounds": rect(view.bounds), "windowRect": view.window.map { rect(view.convert(view.bounds, to: $0)) } ?? .null,
      "hasWindow": .bool(view.window != nil), "hidden": .bool(view.isHidden), "alpha": .number(Double(view.alpha)),
      "clipsToBounds": .bool(view.clipsToBounds), "windowScale": view.window.map { .number(Double($0.screen.scale)) } ?? .null])
  }
  private static func native(_ host: UIView) -> JSONValue {
    // Bounded inspection of the already mounted source host, not a coordinate
    // guess or a request to materialize the TextKit layout/glyphs.
    var queue: [(UIView, Int)] = [(host, 0)], index = 0, texts: [UITextView] = []
    while index < queue.count && index < 64 {
      let (view, depth) = queue[index]; index += 1
      if let text = view as? UITextView { texts.append(text) }
      if depth < 16 {
        for child in view.subviews.prefix(max(0, 64 - queue.count)) { queue.append((child, depth + 1)) }
      }
    }
    return .object(["host": geometry(host), "visitedViews": .number(Double(index)),
      "searchReachedLimit": .bool(index == 64), "textViewCount": .number(Double(texts.count)),
      "textViews": .array(texts.map { text in
        .object(["view": geometry(text), "contentSize": numbers([Double(text.contentSize.width), Double(text.contentSize.height)]),
          "contentOffset": numbers([Double(text.contentOffset.x), Double(text.contentOffset.y)]),
          "textContainerSize": numbers([Double(text.textContainer.size.width), Double(text.textContainer.size.height)]),
          "lineFragmentPadding": .number(Double(text.textContainer.lineFragmentPadding)),
          "textContainerInset": numbers([text.textContainerInset.top, text.textContainerInset.left,
            text.textContainerInset.bottom, text.textContainerInset.right].map(Double.init)),
          "editable": .bool(text.isEditable), "selectable": .bool(text.isSelectable),
          "firstResponder": .bool(text.isFirstResponder), "ancestorClipping": clipping(text)])
      }), "displayMeasured": .bool(false)])
  }

  private static func clipping(_ view: UIView) -> JSONValue {
    var current = view.superview, depth = 0, ancestors: [JSONValue] = []
    var visible = true
    while let ancestor = current, depth < 24 {
      visible = visible && !ancestor.isHidden && ancestor.alpha > 0.001
      if ancestor.clipsToBounds { ancestors.append(geometry(ancestor)) }
      current = ancestor.superview; depth += 1
    }
    return .object(["ancestorsVisible": .bool(visible), "clippingAncestors": .array(ancestors),
      "searchReachedLimit": .bool(current != nil)])
  }

  @MainActor private final class Recorder {
    let sink: Sink
    let sessionID: UUID
    let launchID = UUID()
    private var sequence = 0
    init(session: UUID, configuration: NotebookAcceptanceConfiguration) {
      sessionID = session
      let directory = configuration.rootURL.deletingLastPathComponent().appendingPathComponent("scene-observations", isDirectory: true)
      sink = Sink(url: directory.appendingPathComponent("\(session.uuidString.lowercased())-\(launchID.uuidString.lowercased()).ndjson"))
      var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
      let before = mach_absolute_time(), uptime = ProcessInfo.processInfo.systemUptime, after = mach_absolute_time()
      append(["kind": .string("identity"), "elementID": .string(targetID),
        "bundleID": .string(configuration.bundleID), "workspaceID": uuid(configuration.workspaceID),
        "acceptanceRunID": uuid(configuration.runID), "sourceRevision": .string(configuration.sourceRevision),
        "pid": .number(Double(ProcessInfo.processInfo.processIdentifier)),
        "simulatorUDID": .string(ProcessInfo.processInfo.environment["SIMULATOR_UDID"] ?? "unavailable"),
        "executablePath": .string(Bundle.main.executableURL?.path ?? "unavailable"),
        "clock": .object(["name": .string("mach_absolute_time"), "numer": .number(Double(timebase.numer)),
          "denom": .number(Double(timebase.denom)), "machBefore": .string(String(before)),
          "systemUptimeSeconds": .number(uptime), "machAfter": .string(String(after))]),
        "displayMeasured": .bool(false), "textRecorded": .bool(false),
        "limits": .object(["records": .number(12000), "bytes": .number(16 * 1024 * 1024), "pending": .number(128)])])
    }
    static func configured() -> Recorder? {
      #if targetEnvironment(simulator)
      let environment = ProcessInfo.processInfo.environment
      guard let raw = environment["NOTEBOOK_SCENE_OBSERVATION_SESSION_ID"], let session = UUID(uuidString: raw),
        session.uuidString != "00000000-0000-0000-0000-000000000000",
        let manifest = environment[NotebookAcceptanceConfiguration.environmentKey], manifest.hasPrefix("/"),
        let size = try? FileManager.default.attributesOfItem(atPath: manifest)[.size] as? Int,
        size > 0, size <= 16_384, let data = try? Data(contentsOf: URL(fileURLWithPath: manifest)),
        let config = try? JSONDecoder().decode(NotebookAcceptanceConfiguration.self, from: data), config.role == .iPad else { return nil }
      let enabled = (Bundle.main.object(forInfoDictionaryKey: "NotebookAcceptanceEnabled") as? Bool) == true
        || (Bundle.main.object(forInfoDictionaryKey: "NotebookAcceptanceEnabled") as? String) == "YES"
      let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).resolvingSymlinksInPath().path + "/"
      guard (try? config.validate(bundle: Bundle.main.bundleIdentifier, enabled: enabled)) != nil,
        config.rootURL.resolvingSymlinksInPath().path.hasPrefix(home),
        URL(fileURLWithPath: manifest).resolvingSymlinksInPath().path.hasPrefix(home) else { return nil }
      return Recorder(session: session, configuration: config)
      #else
      return nil
      #endif
    }
    func append(_ value: [String: JSONValue]) {
      sequence += 1
      var record = value
      record["format"] = .number(1); record["sequence"] = .number(Double(sequence))
      record["sessionID"] = uuid(sessionID); record["launchID"] = uuid(launchID)
      record["receiptMach"] = .string(String(mach_absolute_time()))
      sink.append(.object(record))
    }
  }

  /// Encoding and all file operations run on this queue. The small locked
  /// mailbox bounds pending work; overload is explicit and never stalls input.
  private final class Sink: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Notebook.scene-observations", qos: .utility)
    private let lock = NSLock()
    private let url: URL
    private var pending = 0, dropped = 0, totalDropped = 0
    private var stopped = false
    private var handle: FileHandle?
    private var bytes = 0, records = 0
    init(url: URL) { self.url = url }
    var accepting: Bool { lock.lock(); defer { lock.unlock() }; return !stopped }
    func append(_ record: JSONValue) {
      lock.lock()
      guard !stopped else { lock.unlock(); return }
      guard pending < 128 else { dropped += 1; totalDropped += 1; lock.unlock(); return }
      pending += 1
      let skipped = dropped; dropped = 0
      lock.unlock()
      queue.async { [self] in
        defer { lock.lock(); pending -= 1; lock.unlock() }
        guard accepting else { return }
        do {
          if handle == nil {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
            handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
          }
          var payload = record
          if case .object(var fields) = record {
            lock.lock(); let droppedCount = totalDropped; lock.unlock()
            if skipped > 0 { fields["droppedBefore"] = .number(Double(skipped)) }
            fields["totalDroppedAtWrite"] = .number(Double(droppedCount)); payload = .object(fields)
          }
          var data = try JSONEncoder().encode(payload); data.append(10)
          guard records < 12_000, bytes + data.count <= 16 * 1_024 * 1_024 else {
            try handle?.write(contentsOf: Data("{\"kind\":\"truncated\",\"reason\":\"diagnostic budget exceeded\"}\n".utf8))
            lock.lock(); stopped = true; lock.unlock(); return
          }
          try handle?.write(contentsOf: data); records += 1; bytes += data.count
        } catch { lock.lock(); stopped = true; lock.unlock() }
      }
    }
  }
}
#endif

import AppKit
import Foundation
import NotebookCore
import Observation
import WebKit

/// A requested immutable document image composes native PDF and isolated program
/// viewports. Paper never constructs a WebKit view; each program borrows the same
/// lifecycle owner as native blocks and has no authored-state writer.
@MainActor
final class DocumentPageRaster {
  let document: DocumentDocument
  let state: DocumentStateJournal
  let pageIndex: Int
  let resources: SceneRenderResources
  let source: DocumentSourceSnapshot
  let isolationID: UUID?
  private let renderSession: DocumentRenderSession
  private let programStore: NotebookStore?
  private let purpose: @MainActor () -> ScenePreparationPurpose
  private let hostID = UUID()
  private var prepared: DocumentPreparedPage?
  private var runtime: DocumentBlockRuntime?
  private var window: NSWindow?
  private var readyWaiter: CheckedContinuation<Void, Error>?
  private var resourceObserver: NSObjectProtocol?
  private var observesPressure = false
  private var rasterWaiter: CheckedContinuation<RasterReservation, Error>?
  private var rasterDemand: (width: Int, height: Int, generation: UInt64)?
  private var programImages: [String: (width: Int, images: [(DocumentBlockRegion, RasterLease)])] = [:]
  private(set) var programVectors: [String: JSONValue] = [:]
  private var stopped = false
  var layout: DocumentLayoutRecord? { source.layout }
  var isWaitingForRasterAdmission: Bool { rasterDemand != nil }
  var checks: [DocumentProgramCheck] = []

  init(document: DocumentDocument, state: DocumentStateJournal, pageIndex: Int,
    resources: SceneRenderResources, programStore: NotebookStore?, isolationID: UUID?,
    renderSession: DocumentRenderSession?, purpose: @escaping @MainActor () -> ScenePreparationPurpose) {
    self.document = document; self.state = state; self.pageIndex = pageIndex; self.resources = resources
    self.programStore = programStore; self.isolationID = isolationID; self.purpose = purpose
    self.renderSession = renderSession ?? DocumentRenderSession(documentID: document.id)
    source = self.renderSession.source(document, store: programStore)
  }

  func prepare() async throws {
    try permitsPreparation()
    prepared = try await source.preparedPage(pageIndex, hostID: hostID, resources: resources, priority: .export)
    try await source.preparePrograms(on: [pageIndex])
    try permitsPreparation()
    let ids = source.programIDs(on: pageIndex) ?? []
    checks = source.programIDs.sorted().map { .init(instanceID: $0, sourceBasis: source.program($0)?.sourceBasis,
      status: ids.contains($0) && source.programFailures[$0] != nil ? .failed : .notChecked) }
    if let id = ids.sorted().first(where: { source.programFailures[$0] != nil }) {
      throw failure(id: id, error: CollaborationError("program_package_unavailable", source.programFailures[id]!))
    }
    try DocumentRenderRegistry.shared.publishNative(source: source,
      token: DocumentSnapshotCache.token(document: document, state: state, pageIndex: pageIndex),
      pageIndex: pageIndex, programs: checks)
  }

  private func permitsPreparation() throws {
    try Task.checkCancellation()
    guard !stopped, resources.allowsOptionalPreparation || purpose() == .required else { throw CancellationError() }
  }

  func close() {
    guard !stopped else { return }; stopped = true
    readyWaiter?.resume(throwing: CancellationError()); readyWaiter = nil
    rasterWaiter?.resume(throwing: CancellationError()); rasterWaiter = nil; rasterDemand = nil
    if let resourceObserver { NotificationCenter.default.removeObserver(resourceObserver) }; resourceObserver = nil
    closeProgramRuntime()
    for item in programImages.values { for (_, image) in item.images { image.release() } }; programImages.removeAll()
    source.releasePage(hostID: hostID, in: nil, retiring: true); prepared = nil
  }
  isolated deinit { close() }

  private func closeProgramRuntime() {
    let owner = runtime; runtime = nil
    window?.orderOut(nil); window?.contentView = nil
    owner?.stop()
    window?.close(); window = nil
  }

  private func programRuntime(_ program: DocumentProgramSource) async throws -> DocumentBlockRuntime {
    try permitsPreparation()
    if let runtime, runtime.matches(program), runtime.ready { return runtime }
    closeProgramRuntime()
    guard let layout, let region = layout.regions(on: pageIndex).first(where: { $0.kind == .program && $0.id == program.id }),
      let height = layout.programHeights(ids: [program.id])[program.id] else { throw DocumentSessionError.invalidLayout }
    let owner = DocumentBlockRuntime(documentID: document.id, program: program,
      value: state.value(for: program.id) ?? program.initialState, stateVersion: state.records.first(where: { $0.id == program.id })?.valueVersion,
      width: region.frame.width, height: height, resources: resources, programStore: programStore)
    owner.requiresStateAcceptance = false; owner.commitsEnabled = false; owner.preparationPurpose = purpose
    owner.onMount = { [weak self] web, size in
      guard let self, !stopped else { return }
      let window = NSWindow(contentRect: .init(x: -20_000, y: -20_000, width: size.width, height: size.height),
        styleMask: .borderless, backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false; window.contentView = web; window.orderBack(nil); self.window = window
    }
    runtime = owner
    do {
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          readyWaiter = continuation
          owner.onChange = { [weak self, weak owner] in
            guard let self, let owner, runtime === owner else { return }; finishReadiness(owner)
          }
          observeResources()
          owner.start(priority: .background)
          finishReadiness(owner)
        }
      } onCancel: { Task { @MainActor [weak self] in self?.close() } }
      checks.removeAll { $0.instanceID == program.id }
      checks.append(.init(instanceID: program.id, sourceBasis: program.sourceBasis, status: .ready))
      return owner
    } catch is CancellationError { throw CancellationError() }
    catch {
      let diagnostic = failure(id: program.id, error: error)
      // Failure starts the runtime's accepted-state boundary. Join that owner
      // before retiring this immutable executor and returning its addressed error.
      _ = try? await owner.checkpoint()
      if runtime === owner { closeProgramRuntime() }
      throw diagnostic
    }
  }

  private func finishReadiness(_ owner: DocumentBlockRuntime) {
    guard let waiter = readyWaiter else { return }
    if stopped || (!resources.allowsOptionalPreparation && purpose() == .optional) {
      readyWaiter = nil; owner.stop(); waiter.resume(throwing: CancellationError())
    } else if let failure = owner.failure { readyWaiter = nil; waiter.resume(throwing: failure) }
    else if owner.ready { readyWaiter = nil; waiter.resume() }
  }
  private func observeResources() {
    if !observesPressure { observesPressure = true; observePressure() }
    guard resourceObserver == nil else { return }
    resourceObserver = NotificationCenter.default.addObserver(forName: SceneRenderResources.didGainRasterAdmission,
      object: resources, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          if let runtime = self.runtime { self.finishReadiness(runtime) }
          self.retryRasterAdmission()
        }
      }
  }
  private func observePressure() {
    guard !stopped else { return }
    withObservationTracking { _ = resources.optionalPreparationGeneration } onChange: { [weak self] in
      MainActor.assumeIsolated {
        guard let self, !self.stopped else { return }
        if self.purpose() == .optional { self.close() }
      }
      Task { @MainActor [weak self] in self?.observePressure() }
    }
  }
  private func failure(id: String, error: Error) -> DocumentRenderingFailure {
    checks.removeAll { $0.instanceID == id }
    checks.append(.init(instanceID: id, sourceBasis: source.program(id)?.sourceBasis, status: .failed))
    let message = (error as? SceneRenderError)?.description ?? error.localizedDescription
    return .init(diagnostics: [.init(kind: "program_error", elementID: id, message: message)],
      buildID: source.layout?.buildID, programs: checks)
  }

  private func export(_ program: DocumentProgramSource, format: String, pixelRatio: Double? = nil, time: Double? = nil) async throws -> JSONValue {
    guard isolationID != nil else { throw CancellationError() }
    let owner = try await programRuntime(program)
    guard let session = owner.session else { throw CancellationError() }
    var request: [String: JSONValue] = ["format": .string(format), "state": state.value(for: program.id) ?? program.initialState]
    if let pixelRatio { request["pixelRatio"] = .number(pixelRatio) }
    if let time { request["time"] = .number(time) }
    return try await session.perform("exportFrame", argument: .object(request))
  }

  func exportSVG(program: DocumentProgramSource, state: JSONValue) async throws -> String {
    guard case .string(let svg) = try await export(program, format: "svg") else { throw SceneRenderError.snapshotPending("export_svg") }
    try NotebookExportSVG.validate(Data(svg.utf8)); return svg
  }

  func retainPreparedSnapshot(pixelWidth: Int, force: Bool = false, waitsForRasterAdmission: Bool = false,
    videoFrame: (blockID: String, time: Double)? = nil) async throws -> RasterLease {
    try permitsPreparation()
    guard let prepared, let layout else { throw DocumentSessionError.invalidLayout }
    let paper = layout.paper(on: pageIndex)
    let width = paper.surfaceWidth, height = paper.surfaceHeight
    let pixelHeight = Int(ceil(Double(pixelWidth) * height / width))
    let token = DocumentSnapshotCache.token(document: document, state: state, pageIndex: pageIndex)
      + (isolationID.map { "|export:" + $0.uuidString.lowercased() } ?? "")
    let rasterSource = SceneRasterSource.document(id: document.id, token: token)
    if !force, let cached = resources.retainRaster(for: rasterSource, minimumScale: Double(pixelWidth) / width) { return cached }
    let reservation = try await reserveRaster(width: pixelWidth, height: pixelHeight, waits: waitsForRasterAdmission)
    var transferred = false
    defer { if !transferred { reservation.release() } }
    let programs = source.programs.filter { source.programIDs(on: pageIndex)?.contains($0.id) == true }
      .sorted { left, right in left.id == videoFrame?.blockID ? false : right.id == videoFrame?.blockID ? true : left.id < right.id }
    if let videoFrame, !programs.contains(where: { $0.id == videoFrame.blockID }) { throw CollaborationError("export_block_missing", "Программы нет на выбранной странице видео.") }
    for program in programs {
      try permitsPreparation()
      if programImages[program.id]?.width == pixelWidth, videoFrame?.blockID != program.id { continue }
      if let old = programImages.removeValue(forKey: program.id) { for (_, image) in old.images { image.release() } }
      let owner = try await programRuntime(program)
      if isolationID != nil {
        _ = try await export(program, format: "raster", pixelRatio: Double(pixelWidth) / width,
          time: videoFrame?.blockID == program.id ? videoFrame?.time : nil)
      } else {
        _ = try await owner.checkpoint()
      }
      var images: [(DocumentBlockRegion, RasterLease)] = []
      do {
        for region in layout.regions(on: pageIndex) where region.kind == .program && region.id == program.id {
          let extent = Int(ceil(region.frame.width * Double(pixelWidth) / width))
          let image = try await owner.capture(sourceOffset: region.sourceOffset, height: region.frame.height, pixelWidth: extent)
          images.append((region, image))
        }
      } catch { for (_, image) in images { image.release() }; throw error }
      programImages[program.id] = (pixelWidth, images)
      if isolationID != nil, videoFrame == nil { programVectors[program.id] = try await export(program, format: "pdf") }
    }
    try permitsPreparation()
    let pixels = try programImages.values.flatMap { entry in try entry.images.map { region, image -> (CGRect, CGImage) in
      guard let cg = image.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw SceneRenderError.resourceLimit }
      let scale = Double(pixelWidth) / width, rect = region.frame
      return (.init(x: rect.x * scale, y: Double(pixelHeight) - (rect.y + rect.height) * scale,
        width: rect.width * scale, height: rect.height * scale), cg)
    } }
    let overlay: CGImage?
    if pixels.isEmpty { overlay = nil }
    else {
      overlay = try await Task.detached(priority: .utility) {
        guard let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: pixelWidth * 4,
          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw SceneRenderError.resourceLimit }
        for (rect, image) in pixels { context.draw(image, in: rect) }
        return context.makeImage()
      }.value
    }
    let cg = try await prepared.printed.image(width: pixelWidth, overlay: overlay)
    try permitsPreparation()
    let image = NSImage(raster: cg, logicalSize: .init(width: width, height: height))
    guard let raster = resources.storeAndRetain(image, for: rasterSource, reservation: reservation, documentLayout: layout) else {
      throw SceneRenderError.resourceLimit
    }
    transferred = true
    try DocumentRenderRegistry.shared.publishNative(source: source, token: token, pageIndex: pageIndex, programs: checks)
    NotificationCenter.default.post(name: DocumentSnapshotCache.didChange, object: document.id)
    return raster
  }

  private func reserveRaster(width: Int, height: Int, waits: Bool) async throws -> RasterReservation {
    try permitsPreparation()
    if let value = resources.reserveRaster(pixelWidth: width, pixelHeight: height, backingCount: 3) { return value }
    let capacity = resources.rasterAdmission
    guard waits, let bytes = SceneRenderResources.estimatedRasterBytes(pixelWidth: width, pixelHeight: height),
      bytes <= capacity.passiveByteLimit * 2 / 3, capacity.countLimit > 0 else { throw SceneRenderError.resourceLimit }
    precondition(rasterWaiter == nil)
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        rasterWaiter = continuation; rasterDemand = (width, height, resources.optionalPreparationGeneration)
        observeResources(); retryRasterAdmission()
      }
    } onCancel: { Task { @MainActor [weak self] in self?.close() } }
  }
  private func retryRasterAdmission() {
    guard let demand = rasterDemand, let waiter = rasterWaiter else { return }
    if stopped || (purpose() == .optional && (!resources.allowsOptionalPreparation || resources.optionalPreparationGeneration != demand.generation)) {
      rasterWaiter = nil; rasterDemand = nil; waiter.resume(throwing: CancellationError()); return
    }
    guard let reservation = resources.reserveRaster(pixelWidth: demand.width, pixelHeight: demand.height, backingCount: 3) else { return }
    rasterWaiter = nil; rasterDemand = nil; waiter.resume(returning: reservation)
  }
}

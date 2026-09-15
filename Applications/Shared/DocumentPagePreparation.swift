import Foundation
import NotebookCore
import WebKit

/// Tracks charges without retaining their buffers or changing their lifetime.
/// A failed attempt uses the actual released subset to distinguish its own
/// cleanup from newly available capacity elsewhere in the scene.
@MainActor
private final class DocumentPreparationCharges {
  final class WeakCharge {
    weak var value: RasterReservation?
    init(_ value: RasterReservation) { self.value = value }
  }
  @MainActor struct Sample {
    fileprivate let charge: WeakCharge
    let bytes: Int
    var releasedBytes: Int { bytes - (charge.value.flatMap { $0.isReleased ? nil : $0.byteCount } ?? 0) }
  }
  private var charges: [WeakCharge] = []
  private var recoveryCapacity: RasterReservation?
  var onAdmissionWait: (Bool) -> Void = { _ in }
  var waitsForAdmission = false {
    didSet { if oldValue != waitsForAdmission { onAdmissionWait(waitsForAdmission) } }
  }

  func adoptRecovery(_ reservation: RasterReservation) {
    precondition(recoveryCapacity == nil && !reservation.isReleased)
    recoveryCapacity = reservation; track(reservation)
  }

  func releaseRecovery() { recoveryCapacity?.release(); recoveryCapacity = nil }

  func consumeRecovery(_ bytes: Int, resources: SceneRenderResources) throws -> RasterReservation? {
    guard let capacity = recoveryCapacity else { return nil }
    if bytes > capacity.byteCount,
      !resources.resizePassiveDerivedReservation(capacity, to: bytes) {
      throw DocumentPreparationAdmission.Deferred(additionalBytes: bytes - capacity.byteCount, charges: snapshot())
    }
    if capacity.byteCount == bytes { recoveryCapacity = nil; return capacity }
    guard let part = resources.splitPassiveDerivedReservation(capacity, bytes: bytes) else {
      throw SceneRenderError.resourceLimit
    }
    track(part)
    return part
  }

  func transferRecovery(to reservation: RasterReservation, upTo bytes: Int, resources: SceneRenderResources) {
    guard bytes > 0, let capacity = recoveryCapacity else { return }
    precondition(resources.transferPassiveDerivedReservation(capacity, to: reservation,
      bytes: min(bytes, capacity.byteCount)))
    if capacity.isReleased { recoveryCapacity = nil }
  }
  func track(_ reservation: RasterReservation) {
    charges.removeAll { $0.value == nil || $0.value?.isReleased == true }
    if !charges.contains(where: { $0.value === reservation }) { charges.append(WeakCharge(reservation)) }
  }
  func snapshot() -> [Sample] {
    charges.compactMap { charge in
      guard let value = charge.value, !value.isReleased else { return nil }
      return Sample(charge: charge, bytes: value.byteCount)
    }
  }
}

@MainActor
private enum DocumentPreparationAdmission {
  struct Deferred: Error, @unchecked Sendable {
    let additionalBytes: Int
    let charges: [DocumentPreparationCharges.Sample]
    @MainActor var recoveryBytes: Int { additionalBytes + charges.reduce(0) { $0 + max(0, $1.releasedBytes) } }
  }

  static func reserve(_ bytes: Int, stage: String, message: DocumentSourceMessage,
    page: Int?, resources: SceneRenderResources, waitsForAdmission: Bool = true,
    charges: DocumentPreparationCharges? = nil, onAdmissionWait: (Bool) -> Void = { _ in }) async throws -> RasterReservation {
    if let reservation = try charges?.consumeRecovery(bytes, resources: resources) {
      resources.observeDocumentReservation(reservation, documentID: message.documentID,
        sourceKey: message.key, page: page, purpose: stage)
      return reservation
    }
    if !waitsForAdmission {
      return try reserveMaterialized(bytes, stage: stage, message: message, page: page,
        resources: resources, charges: charges)
    }
    let before = resources.lastRasterRefusal?.generation
    defer { charges?.waitsForAdmission = false; onAdmissionWait(false) }
    let reservation = try await resources.acquirePassiveDerivedBytes(bytes) {
      charges?.waitsForAdmission = true; onAdmissionWait(true)
      report(stage, kind: "pool_refusal", requested: bytes, limit: nil, message: message, page: page,
        resources: resources, refusal: resources.lastRasterRefusal.flatMap { $0.generation != before ? $0 : nil })
    }
    charges?.track(reservation)
    resources.observeDocumentReservation(reservation, documentID: message.documentID,
      sourceKey: message.key, page: page, purpose: stage)
    return reservation
  }

  static func reserveMaterialized(_ bytes: Int, stage: String, message: DocumentSourceMessage,
    page: Int?, resources: SceneRenderResources, charges: DocumentPreparationCharges?) throws -> RasterReservation {
    if let reservation = try charges?.consumeRecovery(bytes, resources: resources) {
      resources.observeDocumentReservation(reservation, documentID: message.documentID,
        sourceKey: message.key, page: page, purpose: stage)
      return reservation
    }
    let before = resources.lastRasterRefusal?.generation
    guard let reservation = resources.reserveDerivedBytes(bytes, priority: .passive) else {
      report(stage, kind: "pool_refusal", requested: bytes, limit: nil, message: message, page: page,
        resources: resources, refusal: resources.lastRasterRefusal.flatMap { $0.generation != before ? $0 : nil })
      if let charges { throw Deferred(additionalBytes: bytes, charges: charges.snapshot()) }
      throw SceneRenderError.resourceLimit
    }
    charges?.track(reservation)
    resources.observeDocumentReservation(reservation, documentID: message.documentID,
      sourceKey: message.key, page: page, purpose: stage)
    return reservation
  }

  static func transfer(_ reservation: RasterReservation, to bytes: Int, stage: String,
    message: DocumentSourceMessage, page: Int?, resources: SceneRenderResources,
    charges: DocumentPreparationCharges) throws {
    charges.transferRecovery(to: reservation, upTo: max(0, bytes - reservation.byteCount), resources: resources)
    let additional = max(0, bytes - reservation.byteCount), before = resources.lastRasterRefusal?.generation
    guard resources.resizePassiveDerivedReservation(reservation, to: bytes) else {
      report(stage, kind: "pool_refusal", requested: additional, limit: nil, message: message, page: page,
        resources: resources, refusal: resources.lastRasterRefusal.flatMap { $0.generation != before ? $0 : nil })
      throw Deferred(additionalBytes: additional, charges: charges.snapshot())
    }
    resources.observeDocumentReservation(reservation, documentID: message.documentID,
      sourceKey: message.key, page: page, purpose: stage)
  }

  static func require(_ bytes: Int, atMost limit: Int, stage: String, message: DocumentSourceMessage,
    page: Int?, resources: SceneRenderResources) throws {
    guard bytes <= limit else {
      report(stage, kind: "value_limit", requested: bytes, limit: limit, message: message, page: page,
        resources: resources, refusal: nil)
      throw SceneRenderError.resourceLimit
    }
  }

  private static func report(_ stage: String, kind: String, requested: Int, limit: Int?,
    message: DocumentSourceMessage, page: Int?, resources: SceneRenderResources, refusal: SceneRasterRefusal?) {
    guard NotebookNavigationObservation.enabled else { return }
    var fields = resources.documentAllocationObservation()
    fields["sourceKey"] = .string(message.key); fields["phase"] = .string(stage)
    fields["kind"] = .string(kind); fields["page"] = page.map { .number(Double($0)) } ?? .null
    fields["requestedBytes"] = .number(Double(requested))
    fields["valueLimit"] = limit.map { .number(Double($0)) } ?? .null
    fields["refusalGeneration"] = refusal.map { .string(String($0.generation)) } ?? .null
    NotebookNavigationObservation.recordDocument("document_preparation_admission_refused",
      ownerID: UUID(uuidString: message.key) ?? message.documentID, documentID: message.documentID, fields: fields)
  }
}

struct DocumentBrowserRegion: Codable, Sendable {
  let id: String
  let pageIndex: Int
  let x: Double
  let y: Double
  let width: Double
  let height: Double
  let sourceOffset: Double
}

struct DocumentBrowserDiagnostic: Codable, Sendable {
  let kind: String
  let message: String
  let blockID: String?
}

struct DocumentPageFragment: Codable, Sendable {
  let format: Int
  let sourceKey: String
  let pageIndex: Int
  let width: Double
  let height: Double
  let contentTop: Double
  let contentBottom: Double
  let blockIDs: [String]
  let regions: [DocumentBrowserRegion]
  let html: String
  let nodeCount: Int
  let utf8Bytes: Int
}

private struct DocumentPreparedLayout: Decodable {
  let sourceKey: String
  let pageCount: Int
  let diagnostics: [DocumentBrowserDiagnostic]
  let mathStyles: String
  let indexedNodes: Int
  let indexedEdges: Int
  let preparationPhasesMS: [String: Double]?
}

struct DocumentPacketDescriptor: Decodable {
  let sourceKey: String
  let pageIndex: Int?
  let utf8Bytes: Int

  static func decode(_ json: String, sourceKey: String, pageIndex: Int?, maximumBytes: Int) throws -> Self {
    guard json.utf8.count <= 512 else { throw DocumentSessionError.invalidLayout }
    let value = try JSONDecoder().decode(Self.self, from: Data(json.utf8))
    guard value.sourceKey == sourceKey, value.pageIndex == pageIndex,
      value.utf8Bytes > 0, value.utf8Bytes <= maximumBytes else { throw DocumentSessionError.invalidLayout }
    return value
  }
}

private struct DocumentPageSource: Encodable, Sendable {
  let source: DocumentSourceMessage
  let pageCount: Int
  let diagnostics: [DocumentBrowserDiagnostic]
  let mathStyles: String
  let fragment: DocumentPageFragment
}

@MainActor
final class DocumentPageMessage {
  let json: String
  private let reservation: RasterReservation
  init(json: String, reservation: RasterReservation) { self.json = json; self.reservation = reservation }
  isolated deinit { reservation.release() }
}

@MainActor
final class DocumentPreparedPage {
  let fragment: DocumentPageFragment
  private let envelope: DocumentPageSource
  private let encodingBudget: Int
  private let reservation: RasterReservation
  private let mathStyleReservation: RasterReservation
  fileprivate init(envelope: DocumentPageSource, encodingBudget: Int, reservation: RasterReservation, mathStyleReservation: RasterReservation) {
    fragment = envelope.fragment; self.envelope = envelope; self.encodingBudget = encodingBudget; self.reservation = reservation
    self.mathStyleReservation = mathStyleReservation
  }
  /// The snapshot keeps one DOM fragment, not one full source encoding per
  /// historical page. Only the physical host's current bridge message is encoded.
  func encodedMessage(resources: SceneRenderResources, onAdmissionWait: (Bool) -> Void = { _ in }) async throws -> DocumentPageMessage {
    // The bound belongs to this page, not every source block in the book.
    // Twice the browser JSON bounds Swift's slash escaping.
    // Both encoder output and the submitted script stay charged until callback.
    try DocumentPreparationAdmission.require(encodingBudget, atMost: 40 * 1024 * 1024,
      stage: "page_encoding_bound", message: envelope.source, page: fragment.pageIndex, resources: resources)
    let reservation = try await DocumentPreparationAdmission.reserve(encodingBudget * 2,
      stage: "page_encoding", message: envelope.source, page: fragment.pageIndex, resources: resources, onAdmissionWait: onAdmissionWait)
    do {
      let envelope = envelope
      let json = try await Task.detached(priority: .userInitiated) {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(envelope), as: UTF8.self)
      }.value
      try Task.checkCancellation()
      try DocumentPreparationAdmission.require(json.utf8.count, atMost: encodingBudget,
        stage: "page_encoded_size", message: envelope.source, page: fragment.pageIndex, resources: resources)
      return DocumentPageMessage(json: json, reservation: reservation)
    } catch { reservation.release(); throw error }
  }
  isolated deinit { reservation.release() }
}

/// The canonical source layout and its passive DOM index are distinct from the
/// bounded physical fragments currently needed by mounted page hosts.
@MainActor
private final class DocumentPreparedSource {
  var layout: DocumentLayoutRecord
  let measured: DocumentPreparedLayout
  let blocks: [String: DocumentBlock]
  let bodyBytes: [String: Int]
  let sourceBytes: Int
  let allBodyBytes: Int
  let diagnosticsBytes: Int
  let mathStyleReservation: RasterReservation
  let indexReservation: RasterReservation

  init(layout: DocumentLayoutRecord, measured: DocumentPreparedLayout, blocks: [String: DocumentBlock],
    bodyBytes: [String: Int], sourceBytes: Int, diagnosticsBytes: Int,
    mathStyleReservation: RasterReservation, indexReservation: RasterReservation) {
    self.layout = layout; self.measured = measured; self.blocks = blocks; self.bodyBytes = bodyBytes
    self.sourceBytes = sourceBytes; allBodyBytes = bodyBytes.values.reduce(0, +); self.diagnosticsBytes = diagnosticsBytes
    self.mathStyleReservation = mathStyleReservation; self.indexReservation = indexReservation
  }
  isolated deinit { indexReservation.release() }
}

/// One source owner measures once on an existing physical WebKit and serves
/// individually admitted pages. It does not retain traversal history or a fifth
/// WebKit when its measurement host leaves the mounted window.
@MainActor
final class DocumentPagePreparation {
  private final class WeakOwner {
    weak var value: DocumentPagePreparation?
    init(_ value: DocumentPagePreparation) { self.value = value }
  }
  private static var producers: [ObjectIdentifier: WeakOwner] = [:]
  private struct FragmentMismatch: Error { let detail: String }
  private final class ReaderSurface {
    weak var web: WKWebView?
    weak var lease: WebSurfaceLease?
    init(web: WKWebView, lease: WebSurfaceLease) { self.web = web; self.lease = lease }
  }
  private struct Waiter {
    let pageIndex: Int
    let ordinal: UInt64
    let hostID: UUID
    let surface: ReaderSurface
    let onAdmissionWait: (Bool) -> Void
    let continuation: CheckedContinuation<DocumentPreparedPage, Error>
  }
  private let message: DocumentSourceMessage
  private let sourceJSON: Task<String, Error>
  private let resources: SceneRenderResources
  private var task: Task<Void, Never>?
  private var admissionRetry: Task<Void, Never>?
  private var admissionRetryID: UUID?
  private let charges = DocumentPreparationCharges()
  private var retirement: Task<Void, Never>?
  private var error: Error?
  private var waiters: [UUID: Waiter] = [:]
  private var demand: [UUID: Int] = [:]
  private var nextOrdinal: UInt64 = 0
  private var pageErrors: [Int: Error] = [:]
  private var idleReclaimer: UUID?
  private let reclamationID = UUID()
  private var admissionObserver: NSObjectProtocol?
  private var deferredPrefetchAdmission: SceneRasterAdmission?
  private var pages: [Int: DocumentPreparedPage] = [:]
  private var measured: DocumentPreparedSource?
  private(set) var layout: DocumentLayoutRecord?
  private var deliveredPage = false
  private weak var web: WKWebView?
  private weak var lease: WebSurfaceLease?
  private var retiring = false
  private(set) var measurementCount = 0
  private(set) var compiledPageCount = 0
  // Durations describe actual source work, including scheduling and IPC waits.
  // They do not participate in readiness, admission, or page selection.
  private(set) var preparationPhasesMS: [String: Double] = [:]
  private var firstFragmentMeasurement = 0
  private(set) var lastLayoutMismatch: String?
  var pendingReaderCount: Int { waiters.count }
  var retainedPageIndices: Set<Int> { Set(pages.keys) }
  var failed: Bool { error != nil }

  private func observeProducer(_ stage: String, reason: String) {
    guard NotebookNavigationObservation.enabled else { return }
    NotebookNavigationObservation.recordDocument(stage,
      ownerID: UUID(uuidString: message.key) ?? message.documentID, documentID: message.documentID,
      fields: ["sourceKey": .string(message.key), "reason": .string(reason),
        "measurementCount": .number(Double(measurementCount)), "measured": .bool(measured != nil),
        "waiters": .number(Double(waiters.count)), "demandCount": .number(Double(demand.count)),
        "preparedPages": .array(pages.keys.sorted().prefix(32).map { .number(Double($0)) }),
        "webID": web.map { .string(String(describing: ObjectIdentifier($0))) } ?? .null,
        "taskActive": .bool(task != nil), "retiring": .bool(retirement != nil)])
  }

  init(message: DocumentSourceMessage, sourceJSON: Task<String, Error>, resources: SceneRenderResources) {
    self.message = message; self.sourceJSON = sourceJSON; self.resources = resources
    charges.onAdmissionWait = { [weak self] waiting in
      guard let self else { return }
      for waiter in Array(waiters.values) { waiter.onAdmissionWait(waiting) }
    }
    idleReclaimer = resources.registerReclamationOwner { [weak self] in
      guard let self, task == nil, admissionRetry == nil, retirement == nil,
        waiters.isEmpty, let measured else { return [] }
      return [.init(id: reclamationID, bytes: measured.indexReservation.byteCount, rasterCount: 0,
        value: .canonicalLayout, distance: demand.isEmpty ? 1 : 0,
        restorationMilliseconds: preparationPhasesMS["nativeSourceMeasurement"] ?? 1_000,
        release: { [weak self] in self?.reclaimIdle() })]
    }
    admissionObserver = NotificationCenter.default.addObserver(forName: SceneRenderResources.didGainRasterAdmission,
      object: resources, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.admissionImproved() }
      }
  }

  private func reclaimIdle() -> Task<Void, Never>? {
    guard task == nil, admissionRetry == nil, waiters.isEmpty else { return nil }
    pages.removeAll(); deferredPrefetchAdmission = nil
    retireProducer(reason: "idle_resource_reclamation")
    return retirement
  }

  private func admissionImproved() {
    guard let attempted = deferredPrefetchAdmission, admissionImproved(since: attempted),
      task == nil, retirement == nil, measured != nil else { return }
    deferredPrefetchAdmission = nil
    start()
  }

  private func admissionImproved(since previous: SceneRasterAdmission) -> Bool {
    let current = resources.rasterAdmission
    // The notification is deferred: our own failed packet can release its
    // staging allocation before that notification arrives. Compare actual
    // capacity after cleanup, not the notification generation.
    return current.byteLimit - current.heldBytes > previous.byteLimit - previous.heldBytes
      || current.passiveByteLimit - current.pinnedBytes - current.passiveReservedBytes
        > previous.passiveByteLimit - previous.pinnedBytes - previous.passiveReservedBytes
      || current.countLimit - current.pinnedCount - current.reservedCount
        > previous.countLimit - previous.pinnedCount - previous.reservedCount
  }

  func retainPage(_ pageIndex: Int, hostID: UUID) {
    demand[hostID] = max(0, pageIndex)
    trimPages()
    if measured != nil { start() }
  }

  func releasePage(hostID: UUID, in web: WKWebView?) {
    demand[hostID] = nil
    for (id, waiter) in Array(waiters) where waiter.hostID == hostID {
      waiters[id] = nil; waiter.continuation.resume(throwing: CancellationError())
    }
    trimPages()
    if let web, self.web === web { retireProducer(reason: "measurement_web_released") }
    if demand.isEmpty {
      cancelAdmissionRetry()
      pages.removeAll()
      if waiters.isEmpty { task?.cancel(); retireProducer(reason: "last_page_demand_released") }
    }
  }

  /// The idle measured DOM is disposable under pressure. Accepted geometry is
  /// retained by its readers; a later measurement must agree with it exactly.
  func discardIdlePreparation() async {
    pages.removeAll()
    retireProducer(reason: "explicit_idle_preparation_discard")
    await retirement?.value
    pages.removeAll()
  }

  func page(_ requested: Int, hostID: UUID, in web: WKWebView, lease: WebSurfaceLease,
    onAdmissionWait: @escaping (Bool) -> Void = { _ in }) async throws -> DocumentPreparedPage {
    try Task.checkCancellation()
    retainPage(requested, hostID: hostID)
    if let error { throw error }
    if let layout, let error = pageErrors[min(max(0, requested), layout.pageCount - 1)] { throw error }
    if let page = cachedPage(requested) { start(); return page }
    // Retiring a producer drains its actual browser callbacks before the same
    // admitted WebKit can become another source's measurement host.
    await retirement?.value
    try Task.checkCancellation()
    if let page = cachedPage(requested) { start(); return page }
    if self.web == nil || self.lease?.isReleased != false {
      self.web = web; self.lease = lease; retiring = false
    }
    let id = UUID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
        nextOrdinal &+= 1
        waiters[id] = Waiter(pageIndex: max(0, requested), ordinal: nextOrdinal, hostID: hostID,
          surface: ReaderSurface(web: web, lease: lease), onAdmissionWait: onAdmissionWait, continuation: continuation)
        onAdmissionWait(charges.waitsForAdmission)
        start()
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.cancelWaiter(id) }
    }
  }

  private func cachedPage(_ requested: Int) -> DocumentPreparedPage? {
    guard let layout else { return nil }
    return pages[min(max(0, requested), layout.pageCount - 1)]
  }

  private var neededPages: Set<Int> {
    guard let layout else { return [] }
    // The scene's page plan already includes its neighbours. A producer serves
    // exact consumers; extending each demand again multiplies the working set.
    return Set(demand.values.map { min($0, layout.pageCount - 1) })
  }

  private func trimPages() {
    let needed = neededPages
    pages = pages.filter { needed.contains($0.key) }
  }

  private func cancelWaiter(_ id: UUID) {
    waiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    if waiters.isEmpty { cancelAdmissionRetry() }
    if waiters.isEmpty, demand.isEmpty { task?.cancel(); retireProducer(reason: "last_waiter_cancelled") }
  }

  private func start() {
    guard task == nil, admissionRetry == nil, retirement == nil,
      !waiters.isEmpty || (measured != nil && !neededPages.subtracting(pages.keys).subtracting(pageErrors.keys).isEmpty
        && deferredPrefetchAdmission.map { admissionImproved(since: $0) } != false),
      let web, let lease, !lease.isReleased else { return }
    let borrow: WebSurfaceBorrow
    do { borrow = try lease.borrow() }
    catch { fail(error); return }
    task = Task { @MainActor [weak self] in
      defer { borrow.release() }
      guard let self else { return }
      defer { charges.releaseRecovery() }
      do {
        if measured == nil {
          let identity = ObjectIdentifier(web)
          if let previous = Self.producers[identity]?.value, previous !== self {
            previous.retireProducer(reason: "measurement_web_assigned_to_another_source")
            await previous.retirement?.value
          }
          try Task.checkCancellation()
          Self.producers = Self.producers.filter { $0.value.value != nil }
          Self.producers[identity] = WeakOwner(self)
          // Publish one accepted measurement's diagnostics together with its
          // count. A concurrent reader cannot pair a new partial measurement
          // with the previous accepted measurement's identity or first fragment.
          var measuredPhasesMS: [String: Double] = [:]
          let encodingStarted = ProcessInfo.processInfo.systemUptime
          let json = try await sourceJSON.value
          measuredPhasesMS["nativeSourceEncodingWait"] = (ProcessInfo.processInfo.systemUptime - encodingStarted) * 1_000
          try Task.checkCancellation()
          let measurementStarted = ProcessInfo.processInfo.systemUptime
          let value = try await Self.measure(message: message, json: json, in: web, resources: resources, charges: charges)
          measuredPhasesMS["nativeSourceMeasurement"] = (ProcessInfo.processInfo.systemUptime - measurementStarted) * 1_000
          for (name, duration) in value.measured.preparationPhasesMS ?? [:]
            where name.utf8.count <= 80 && duration.isFinite && duration >= 0 {
            measuredPhasesMS["browser_" + name] = duration
          }
          if let layout, !layout.matches(value.layout) {
            lastLayoutMismatch = "remeasure pages=\(layout.pageCount)/\(value.layout.pageCount); old=\(Array(layout.regions.prefix(3))); new=\(Array(value.layout.regions.prefix(3)))"
            throw DocumentSessionError.inconsistentLayout
          }
          if let layout { value.layout = layout } else { layout = value.layout }
          measured = value; measurementCount += 1
          preparationPhasesMS = measuredPhasesMS
          observeProducer("document_source_measured", reason: "canonical_measurement_accepted")
        }
        while !Task.isCancelled, let measured {
          // Foreground readers always precede speculative neighbours. Resolve a
          // page immediately; no other fragment stands between it and its host.
          for (id, waiter) in Array(waiters) {
            if let page = cachedPage(waiter.pageIndex) {
              deliveredPage = true
              waiters[id] = nil; waiter.onAdmissionWait(false); waiter.continuation.resume(returning: page)
            }
          }
          let requested = waiters.values.min(by: { $0.ordinal < $1.ordinal }).map { min($0.pageIndex, measured.layout.pageCount - 1) }
          let neighbor = !retiring ? neededPages.subtracting(pages.keys).subtracting(pageErrors.keys).sorted().first : nil
          guard let index = requested ?? neighbor else { break }
          let page: DocumentPreparedPage
          let fragmentStarted = ProcessInfo.processInfo.systemUptime
          do { page = try await Self.compile(index, message: message, prepared: measured, in: web, resources: resources,
            waitsForAdmission: requested != nil, charges: charges) }
          catch {
            _ = try? await Self.evaluate("window.notebookRenderer.discardPreparedPacket(key, index); return 'discarded';",
              arguments: ["key": message.key, "index": index], in: web)
            if let mismatch = error as? FragmentMismatch { lastLayoutMismatch = mismatch.detail }
            if error is CancellationError { throw error }
            if requested != nil {
              if error is DocumentPreparationAdmission.Deferred || (error as? SceneRenderError) == .resourceLimit { throw error }
              let failure = error is FragmentMismatch ? DocumentSessionError.inconsistentLayout : error
              pageErrors[index] = failure
              for (id, waiter) in Array(waiters) where min(waiter.pageIndex, measured.layout.pageCount - 1) == index {
                waiters[id] = nil; waiter.continuation.resume(throwing: failure)
              }
              continue
            }
            // Speculative work cannot turn an already usable page into an
            // error. Remember a deterministic page error for its future reader;
            // admission failure remains retryable on the next actual demand.
            if error is DocumentPreparationAdmission.Deferred || (error as? SceneRenderError) == .resourceLimit { deferredPrefetchAdmission = resources.rasterAdmission }
            else { pageErrors[index] = error }
            break
          }
          if firstFragmentMeasurement != measurementCount {
            firstFragmentMeasurement = measurementCount
            preparationPhasesMS["nativeFirstFragment"] = (ProcessInfo.processInfo.systemUptime - fragmentStarted) * 1_000
          }
          try Task.checkCancellation()
          compiledPageCount += 1
          pages[index] = page
          for (id, waiter) in Array(waiters) where min(waiter.pageIndex, measured.layout.pageCount - 1) == index {
            deliveredPage = true
            waiters[id] = nil; waiter.onAdmissionWait(false); waiter.continuation.resume(returning: page)
          }
          trimPages()
          await Task.yield()
        }
        if Task.isCancelled, !retiring { fail(CancellationError()) }
      } catch {
        _ = try? await Self.evaluate("window.notebookRenderer.finishSourcePreparation(key); return 'finished';",
          arguments: ["key": message.key], in: web)
        measured = nil
        if !deliveredPage { layout = nil }
        charges.releaseRecovery()
        if let deferred = error as? DocumentPreparationAdmission.Deferred, !Task.isCancelled, !waiters.isEmpty {
          waitForReleasedCapacity(deferred)
        } else if !Task.isCancelled || !retiring { fail(error) }
      }
      task = nil
    }
  }

  private func cancelAdmissionRetry() {
    admissionRetryID = nil; admissionRetry?.cancel(); admissionRetry = nil
    charges.releaseRecovery(); charges.waitsForAdmission = false
  }

  func retryPage(_ index: Int) {
    let page = layout.map { min(max(0, index), $0.pageCount - 1) } ?? max(0, index)
    pageErrors[page] = nil
  }

  private func waitForReleasedCapacity(_ deferred: DocumentPreparationAdmission.Deferred) {
    let bytes = max(1, deferred.recoveryBytes), identity = UUID()
    admissionRetryID = identity
    charges.waitsForAdmission = true
    // Recreating our released working set plus the full failed allocation (or
    // full resize growth, never only the shortage) must fit. Our own cleanup
    // cannot satisfy this gate; a concurrent external release is not lost.
    admissionRetry = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let capacity = try await resources.acquirePassiveDerivedBytes(bytes)
        guard !Task.isCancelled, admissionRetryID == identity, !waiters.isEmpty else {
          capacity.release(); return
        }
        charges.adoptRecovery(capacity); charges.waitsForAdmission = false
        admissionRetry = nil; admissionRetryID = nil
        start()
      } catch {
        guard admissionRetryID == identity else { return }
        admissionRetry = nil; admissionRetryID = nil; charges.waitsForAdmission = false
        if !(error is CancellationError) { fail(error) }
      }
    }
  }

  private func fail(_ error: Error) {
    if !(error is CancellationError) { self.error = error }
    let pending = waiters.values; waiters.removeAll()
    for waiter in pending { waiter.continuation.resume(throwing: error) }
  }

  /// Capture the cleanup borrow synchronously, before the physical host returns
  /// its lease. The cleanup task can then wait for another reader's page packet.
  private func retireProducer(reason: String) {
    guard retirement == nil, let web else { return }
    cancelAdmissionRetry()
    observeProducer("document_source_retire_requested", reason: reason)
    retiring = true
    // Existing readers share this actual measurement. Drain their required
    // fragments on its borrowed WebKit; retirement suppresses only prefetch.
    // A request still waiting for bytes has submitted no such browser work and
    // can transfer to an already admitted surviving reader immediately.
    if waiters.isEmpty || charges.waitsForAdmission { task?.cancel() }
    let borrow = try? lease?.borrow()
    let preceding = task
    retirement = Task { @MainActor [self] in
      defer { borrow?.release() }
      await preceding?.value
      _ = try? await Self.evaluate("window.notebookRenderer.finishSourcePreparation(key); return 'finished';",
        arguments: ["key": message.key], in: web)
      measured = nil
      if Self.producers[ObjectIdentifier(web)]?.value === self { Self.producers[ObjectIdentifier(web)] = nil }
      self.web = nil; lease = nil; retiring = false; retirement = nil
      observeProducer("document_source_retired", reason: reason)
      adoptRemainingReader()
    }
  }

  /// A physical measurement host can leave while another reader is already
  /// suspended on the same source. Drain the retired producer first, then move
  /// the unfinished demand to that reader's own still-admitted WebKit.
  private func adoptRemainingReader() {
    for (id, waiter) in waiters.sorted(by: { $0.value.ordinal < $1.value.ordinal }) {
      guard let web = waiter.surface.web, let lease = waiter.surface.lease, !lease.isReleased else {
        waiters[id] = nil; demand[waiter.hostID] = nil
        waiter.continuation.resume(throwing: CancellationError())
        continue
      }
      self.web = web; self.lease = lease
      start()
      break
    }
  }

  isolated deinit {
    if let idleReclaimer { resources.unregisterReclamationOwner(idleReclaimer) }
    if let admissionObserver { NotificationCenter.default.removeObserver(admissionObserver) }
    task?.cancel(); admissionRetry?.cancel()
    for waiter in waiters.values { waiter.continuation.resume(throwing: CancellationError()) }
    // Normally the last mounted demand retires the producer. This path also
    // covers an abandoned source snapshot retained only by diagnostic readers.
    if let web, retirement == nil {
      let borrow = try? lease?.borrow()
      let retained = measured
      web.callAsyncJavaScript("window.notebookRenderer.finishSourcePreparation(key); return true;",
        arguments: ["key": message.key], in: nil, in: .page) { _ in
          borrow?.release(); withExtendedLifetime(retained) {}
        }
    }
  }

  private static func evaluate(_ script: String, arguments: [String: Any], in web: WKWebView) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
      web.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { result in
        switch result {
        case .success(let value):
          if let string = value as? String { continuation.resume(returning: string) }
          else { continuation.resume(throwing: DocumentSessionError.invalidLayout) }
        case .failure(let error): continuation.resume(throwing: error)
        }
      }
    }
  }

  private static func measure(message: DocumentSourceMessage, json: String, in web: WKWebView,
    resources: SceneRenderResources, charges: DocumentPreparationCharges) async throws -> DocumentPreparedSource {
    let geometry = WorkspaceItemGeometry.document(message.paper.kind), sourceBytes = json.utf8.count
    try DocumentPreparationAdmission.require(sourceBytes, atMost: 16 * 1024 * 1024,
      stage: "source_size", message: message, page: nil, resources: resources)
    let (raw, layoutPacket) = try await readPacket(
      preparing: "return JSON.stringify(await window.notebookRenderer.beginSourcePreparation(JSON.parse(source)));",
      arguments: ["source": json], sourceKey: message.key, pageIndex: nil,
      maximumBytes: 16 * 1024 * 1024, inputBytes: sourceBytes, message: message, in: web, resources: resources, charges: charges)
    // Keep every materialized-stage charge alive through browser cleanup if
    // a later synchronous growth is refused. No index or packet waits uncharged.
    var heldCharges = [layoutPacket]
    do {
      guard let receipt = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? NSDictionary else { throw DocumentSessionError.invalidLayout }
      let blocks = Dictionary(uniqueKeysWithValues: message.blocks.map { ($0.id, $0) }), blockIDs = Set(blocks.keys)
      let bodyBytes = Dictionary(uniqueKeysWithValues: message.blocks.map { block in
        (block.id, block.source.utf8.count + block.html.utf8.count + block.css.utf8.count + block.javaScript.utf8.count)
      })
      guard bodyBytes.values.reduce(0, +) <= sourceBytes else { throw DocumentSessionError.invalidLayout }
      let layout = try DocumentLayoutRecord(receipt: receipt, sourceKey: message.key, blockIDs: blockIDs,
        geometry: geometry, reservation: layoutPacket)
      let measured = try JSONDecoder().decode(DocumentPreparedLayout.self, from: Data(raw.utf8))
      guard measured.sourceKey == message.key, measured.pageCount == layout.pageCount,
        (1...4096).contains(layout.pageCount), (0...262144).contains(measured.indexedNodes),
        (0...524288).contains(measured.indexedEdges) else { throw DocumentSessionError.invalidLayout }
      let diagnosticsBytes = try JSONEncoder().encode(measured.diagnostics).count
      let mathStyleBytes = measured.mathStyles.utf8.count
      try DocumentPreparationAdmission.require(diagnosticsBytes, atMost: 64 * 1024,
        stage: "diagnostics_size", message: message, page: nil, resources: resources)
      try DocumentPreparationAdmission.require(mathStyleBytes, atMost: 128 * 1024,
        stage: "math_style_size", message: message, page: nil, resources: resources)
      let mathStyleReservation = try DocumentPreparationAdmission.reserveMaterialized(max(1, mathStyleBytes),
        stage: "math_style", message: message, page: nil, resources: resources, charges: charges)
      heldCharges.append(mathStyleReservation)
      let indexReservation = try DocumentPreparationAdmission.reserveMaterialized(max(1, sourceBytes * 2 + measured.indexedNodes * 128 + measured.indexedEdges * 64),
        stage: "source_index", message: message, page: nil, resources: resources, charges: charges)
      heldCharges.append(indexReservation)
      try DocumentPreparationAdmission.transfer(layoutPacket, to: raw.utf8.count * 3, stage: "source_packet",
        message: message, page: nil, resources: resources, charges: charges)
      return DocumentPreparedSource(layout: layout, measured: measured, blocks: blocks, bodyBytes: bodyBytes,
        sourceBytes: sourceBytes, diagnosticsBytes: diagnosticsBytes,
        mathStyleReservation: mathStyleReservation, indexReservation: indexReservation)
    } catch {
      _ = try? await evaluate("window.notebookRenderer.finishSourcePreparation(key); return 'finished';",
        arguments: ["key": message.key], in: web)
      withExtendedLifetime(heldCharges) {}
      throw error
    }
  }

  private static func compile(_ pageIndex: Int, message: DocumentSourceMessage, prepared: DocumentPreparedSource,
    in web: WKWebView, resources: SceneRenderResources, waitsForAdmission: Bool,
    charges: DocumentPreparationCharges) async throws -> DocumentPreparedPage {
    let (json, staging) = try await readPacket(
      preparing: "return JSON.stringify(window.notebookRenderer.preparePagePacket(key, index));",
      arguments: ["key": message.key, "index": pageIndex], sourceKey: message.key, pageIndex: pageIndex,
      maximumBytes: 8 * 1024 * 1024, message: message, in: web, resources: resources,
      waitsForAdmission: waitsForAdmission, charges: charges)
    var transferred = false
    defer { if !transferred { staging.release() } }
    let fragment = try JSONDecoder().decode(DocumentPageFragment.self, from: Data(json.utf8))
    let blocks = prepared.blocks, layout = prepared.layout
    guard fragment.format == 1, fragment.sourceKey == message.key, fragment.pageIndex == pageIndex,
      fragment.utf8Bytes == fragment.html.utf8.count, fragment.utf8Bytes <= 4 * 1024 * 1024,
      fragment.nodeCount <= 16_384, fragment.contentTop.isFinite, fragment.contentBottom.isFinite,
      fragment.contentTop >= 0, fragment.contentBottom >= fragment.contentTop, fragment.contentBottom <= fragment.height,
      Set(fragment.blockIDs).count == fragment.blockIDs.count,
      fragment.blockIDs.allSatisfy({ blocks[$0] != nil }),
      Set(fragment.regions.map(\.id)) == Set(fragment.blockIDs) else { throw DocumentSessionError.invalidLayout }
    var fragmentReceipt = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] ?? [:]
    fragmentReceipt["layoutScope"] = "page"
    fragmentReceipt["layoutCanonical"] = true; fragmentReceipt["pageCount"] = layout.pageCount
    let physical = try DocumentLayoutRecord(receipt: fragmentReceipt as NSDictionary, sourceKey: message.key,
      blockIDs: Set(blocks.keys), geometry: WorkspaceItemGeometry.document(message.paper.kind))
    guard layout.matches(physical, pageIndex: pageIndex) else {
      throw FragmentMismatch(detail: "compiled page=\(pageIndex); pages=\(layout.pageCount)/\(physical.pageCount); old=\(Array(layout.regions.filter { $0.pageIndex == pageIndex }.prefix(3))); new=\(Array(physical.regions.prefix(3)))")
    }
    let source = DocumentSourceMessage(key: message.key, documentID: message.documentID, paper: message.paper,
      blocks: fragment.blockIDs.compactMap { blocks[$0] },
      sourceVersions: Dictionary(uniqueKeysWithValues: fragment.blockIDs.compactMap { id in message.sourceVersions[id].map { (id, $0) } }))
    let envelope = DocumentPageSource(source: source, pageCount: layout.pageCount,
      diagnostics: prepared.measured.diagnostics, mathStyles: prepared.measured.mathStyles, fragment: fragment)
    let retainedBytes = max(1, json.utf8.count)
    try DocumentPreparationAdmission.transfer(staging, to: retainedBytes, stage: "retained_page",
      message: message, page: pageIndex, resources: resources, charges: charges)
    transferred = true
    let pageSourceBytes = prepared.sourceBytes - prepared.allBodyBytes
      + fragment.blockIDs.reduce(0) { $0 + (prepared.bodyBytes[$1] ?? 0) }
    return DocumentPreparedPage(envelope: envelope,
      encodingBudget: pageSourceBytes + json.utf8.count * 2 + prepared.diagnosticsBytes + prepared.measured.mathStyles.utf8.count * 6 + 256,
      reservation: staging, mathStyleReservation: prepared.mathStyleReservation)
  }

  /// The browser first freezes one bounded packet and announces its byte count.
  /// Admission precedes transfer; the same source/page and exact UTF-8 length
  /// must come back. No maximum-size buffer occupies the pool between pages.
  private static func readPacket(preparing script: String, arguments: [String: Any],
    sourceKey: String, pageIndex: Int?, maximumBytes: Int, inputBytes: Int = 0,
    message: DocumentSourceMessage, in web: WKWebView, resources: SceneRenderResources,
    waitsForAdmission: Bool = true, charges: DocumentPreparationCharges) async throws -> (String, RasterReservation) {
    let staging = try await DocumentPreparationAdmission.reserve(512 * 3 + inputBytes * 2,
      stage: pageIndex == nil ? "source_announcement" : "page_announcement",
      message: message, page: pageIndex, resources: resources, waitsForAdmission: waitsForAdmission, charges: charges)
    var transferred = false
    defer { if !transferred { staging.release() } }
    do {
      let raw = try await evaluate(script, arguments: arguments, in: web)
      try Task.checkCancellation()
      let descriptor = try DocumentPacketDescriptor.decode(raw, sourceKey: sourceKey, pageIndex: pageIndex, maximumBytes: maximumBytes)
      // The input/measurement backing remains charged through measurement.
      // Page packets transfer the same charge instead of release + async admit.
      try DocumentPreparationAdmission.transfer(staging, to: max(staging.byteCount, descriptor.utf8Bytes * 3),
        stage: pageIndex == nil ? "source_packet" : "page_packet", message: message, page: pageIndex,
        resources: resources, charges: charges)
      let json = try await evaluate("return window.notebookRenderer.readPreparedPacket(key, index);",
        arguments: ["key": sourceKey, "index": pageIndex.map { $0 as Any } ?? NSNull()], in: web)
      try Task.checkCancellation()
      guard json.utf8.count == descriptor.utf8Bytes else { throw DocumentSessionError.invalidLayout }
      transferred = true
      return (json, staging)
    } catch {
      _ = try? await evaluate(pageIndex == nil
        ? "window.notebookRenderer.finishSourcePreparation(key); return 'discarded';"
        : "window.notebookRenderer.discardPreparedPacket(key, index); return 'discarded';",
        arguments: ["key": sourceKey, "index": pageIndex.map { $0 as Any } ?? NSNull()], in: web)
      throw error
    }
  }
}

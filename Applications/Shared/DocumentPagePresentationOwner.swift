#if os(iOS)
import Foundation
import NotebookCore
import UIKit
import WebKit

/// Inputs of a physical paper presentation. Only the selected presentation
/// admits user input; all presentations share the same document runtime.
@MainActor
struct DocumentPagePresentation {
  let document: DocumentDocument
  let state: DocumentStateJournal
  let pageIndex: Int
  let isCurrent: Bool
  let isVisible: Bool
  let isInteractive: Bool
  let pageTurnActive: Bool
  let onRenderReady: PageTurnReadiness
  let onPageLayout: (DocumentPageLayout) -> Void
  let onStateChange: (DocumentProgramSource, JSONValue) async throws -> ContentFieldVersion?
  let onLinkActivation: (DocumentLinkActivation) -> Void
  let snapshotPixelWidth: Int?
  let onPreparationFailure: (Error) -> Void
  var onStateCheckpoint: (String, JSONValue, DocumentProgramSource, ContentFieldVersion?) async throws -> ContentFieldVersion? = { _, _, _, _ in nil }
  var onStateDrained: () async -> Void = {}
  var measurements: DocumentPresentationRecorder? = nil
  var programStore: NotebookStore? = nil
  var paperToken: String { DocumentSnapshotCache.paperToken(sourceRevision: document.contentStamp.revision, pageIndex: pageIndex) }
  var token: String { DocumentSnapshotCache.token(document: document, state: state, pageIndex: pageIndex) }
  /// A full physical page retains the open document even while UIKit has not
  /// yet selected it. A thumbnail owns only its bounded static preparation.
  var retainsOpenDocument: Bool { snapshotPixelWidth == nil }
}

@MainActor
final class DocumentPhysicalPageCoordinator {
  let id = UUID()
  private var owner: DocumentPagePresentationOwner?
  func update(_ input: DocumentPagePresentation, in host: DocumentWebHost, resources: SceneRenderResources) {
    if owner?.documentID != input.document.id || owner?.resources !== resources {
      owner?.unregister(id)
      owner = DocumentPagePresentationOwner.shared(documentID: input.document.id, resources: resources)
    }
    owner?.update(id, input: input, host: host)
  }
  func invalidate() { owner?.unregister(id); owner = nil }
  isolated deinit { owner?.unregister(id) }
}

/// An accepted turn borrows exactly one print cut until its terminal outcome.
/// Holding this value retains the source's layout allocation, never a new compiler.
@MainActor
final class DocumentTurnSourceLease {
  let source: DocumentSourceSnapshot
  let layout: DocumentLayoutRecord
  init(source: DocumentSourceSnapshot, layout: DocumentLayoutRecord) { self.source = source; self.layout = layout }
}

/// Owns paper preparation, composition and native handoff. Program execution
/// and checkpoint tasks belong to DocumentProgramOwner and cannot stall it.
@MainActor
final class DocumentPagePresentationOwner {
  private struct Key: Hashable { let documentID: UUID; let resources: ObjectIdentifier }
  private final class WeakOwner {
    weak var value: DocumentPagePresentationOwner?
    var closingValue: DocumentPagePresentationOwner?
    init(_ value: DocumentPagePresentationOwner) { self.value = value }
  }
  private struct TurnFrameKey: Equatable {
    enum Material: Equatable { case picture(UUID), paper(ObjectIdentifier) }
    let material: Material
    let token: String
    let source: String
    let size: CGSize
    let scale: Double
  }
  private struct TurnFrameMaterial {
    let key: TurnFrameKey
    let image: CGImage
    let owner: AnyObject
  }
  @MainActor private final class Entry {
    let id: UUID
    weak var host: DocumentWebHost?
    var input: DocumentPagePresentation
    var activity: PageTurnActivity?
    var activityObserver: UUID?
    var preparationObserver: UUID?
    var turnFrameKey: TurnFrameKey?
    var turnFrame: PageTurnFrame?
    var turnFramePreparation: Task<PageTurnFrame, Error>?
    var turnFramePreparationID: UUID?
    var turnFramePreparationIsRequired = false
    var turnFrameRefusal: SceneRasterAdmission?
    var acceptedTurnCaptures = 0
    func releaseTurnFrame(reason: String = #function, line: UInt = #line) {
      if let observe = NotebookNavigationObservation.onPageMaterialPreparation,
        turnFrame != nil || turnFramePreparation != nil {
        observe("document_turn_release reason=\(reason):\(line) page=\(input.pageIndex) key=\(String(reflecting: turnFrameKey)) fallback=\(String(describing: host?.snapshotEntryID))",
          id, nil, turnFrame?.id, turnFramePreparationID, CACurrentMediaTime())
      }
      turnFramePreparation?.cancel(); turnFramePreparation = nil; turnFramePreparationID = nil
      turnFramePreparationIsRequired = false
      turnFrame = nil; turnFrameKey = nil; turnFrameRefusal = nil
    }
    var requiresPreparation: Bool {
      input.retainsOpenDocument || (input.isVisible && host?.window != nil)
    }
    private var readiness: PageTurnReadiness.State?
    private weak var readinessHandler: PageTurnReadiness?
    init(id: UUID, input: DocumentPagePresentation, host: DocumentWebHost) {
      self.id = id; self.input = input; self.host = host
    }
    func stopObserving() {
      if let activityObserver { activity?.removeObserver(activityObserver) }
      if let preparationObserver { activity?.removePreparationObserver(preparationObserver) }
      activityObserver = nil; preparationObserver = nil; activity = nil
    }
    func publishReadiness(_ presented: Bool, capturable: Bool = false) {
      // An offscreen neighbour owns prepared material before it owns a
      // projected live layer. Only a current paper claims installed geometry.
      let installed = presented && (!input.retainsOpenDocument || !input.isCurrent || host?.hasCanonicalPaperProjection == true)
      let value = PageTurnReadiness.State(presented: installed, capturable: capturable)
      guard readiness != value || readinessHandler !== input.onRenderReady else { return }
      readiness = value; readinessHandler = input.onRenderReady
      input.onRenderReady(value.presented, capturable: value.capturable)
    }
    isolated deinit { stopObserving(); turnFramePreparation?.cancel() }
  }
  private struct Picture {
    let token: String
    let source: String
    let raster: RasterLease
  }
  private struct CurrentTarget: Equatable {
    let id: UUID
    let page: Int
    let source: VersionStamp
  }
  /// UIKit may retire the outgoing page before publishing the incoming current
  /// host. During that handoff the document owner, rather than either page,
  /// retains the admitted WebKit and its immutable bridge state.
  private struct PaperTransfer {
    let renderer: DocumentWebCoordinator
    let web: WKWebView
    let admission: WebSurfaceBorrow
  }
  private static var owners: [Key: WeakOwner] = [:]
  /// An open document outlives any one SwiftUI/UIKit representation. This
  /// explicit lease belongs to the model's open/close transition, not a timer.
  @MainActor final class OpenDocument {
    let documentID: UUID
    private var owner: DocumentPagePresentationOwner?
    private var isReturn = false
    fileprivate init(_ owner: DocumentPagePresentationOwner) {
      documentID = owner.documentID; self.owner = owner; owner.openDocuments += 1
    }
    func abortBootstrapPreparation() {
      guard let owner else { return }
      owner.abortBootstrapPreparation()
      close()
    }
    func close() {
      guard let owner else { return }; self.owner = nil
      owner.openDocuments -= 1
      if isReturn { owner.returnDocuments -= 1 }
      if owner.entries.isEmpty && owner.openDocuments == 0 { owner.stop() }
      else { owner.retirePaperAfterDocumentClose(); owner.schedule() }
    }
    func parkForReturn() {
      guard let owner, !isReturn else { return }
      isReturn = true; owner.returnDocuments += 1
      owner.retirePaperAfterDocumentClose()
    }
    func resume() {
      guard let owner, isReturn else { return }
      isReturn = false; owner.returnDocuments -= 1
      owner.paper.offerIdleReclamation(nil)
      owner.programOwner.resumeFromReturn()
    }
    func cameraDidChange() { owner?.refreshVisiblePrograms() }
    isolated deinit { close() }
  }
  /// The accepted opening owns one cancellable reader of this owner's source.
  /// It starts no WebKit, pixel capture or program and adds no second compiler.
  @MainActor final class OpeningPreparation {
    let documentID: UUID
    private let document: DocumentDocument
    private(set) var outcome: DocumentRenderSession.Opening.Outcome?
    var onOutcome: (DocumentRenderSession.Opening.Outcome) -> Void = { _ in }
    fileprivate var isPending: Bool { source != nil }
    private let hostID = UUID()
    private var lifetime: OpenDocument?
    private var source: DocumentSourceSnapshot?
    private var task: Task<Void, Never>?
    fileprivate init(owner: DocumentPagePresentationOwner, document: DocumentDocument,
      pageIndex: Int, store: NotebookStore) {
      documentID = document.id; self.document = document; lifetime = owner.retainOpenDocument()
      let source = owner.renderSession.source(document, store: store)
      self.source = source
      let hostID = hostID, resources = owner.resources
      task = Task { @MainActor [weak self] in
        do {
          try await source.prepareOpening(pageIndex: pageIndex, hostID: hostID, resources: resources)
          guard let self, outcome == nil else { return }
          task = nil
        } catch {
          guard let self, outcome == nil else { return }
          finish(error is CancellationError ? .cancelled : .failed(error.localizedDescription))
        }
      }
    }
    func matches(_ document: DocumentDocument) -> Bool { self.document == document }
    fileprivate func handoff(to installedSource: DocumentSourceSnapshot) {
      guard source === installedSource else { return }
      finish(.completed)
    }
    func close() { finish(.cancelled) }
    private func finish(_ result: DocumentRenderSession.Opening.Outcome) {
      guard outcome == nil else { return }
      outcome = result
      task?.cancel(); task = nil
      source?.releasePage(hostID: hostID, in: nil); source = nil
      lifetime?.close(); lifetime = nil
      let completion = onOutcome; onOutcome = { _ in }; completion(result)
    }
    isolated deinit { close() }
  }
  private final class WeakOpeningPreparation {
    weak var value: OpeningPreparation?
    init(_ value: OpeningPreparation) { self.value = value }
  }
  private var openingPreparations: [WeakOpeningPreparation] = []
  func prepareOpening(document: DocumentDocument, pageIndex: Int, store: NotebookStore) -> OpeningPreparation {
    precondition(document.id == documentID)
    openingPreparations.removeAll { $0.value?.isPending != true }
    let opening = OpeningPreparation(owner: self, document: document, pageIndex: pageIndex, store: store)
    openingPreparations.append(WeakOpeningPreparation(opening))
    return opening
  }
  private var closingPrograms: Task<Void, Never>?
  private var openDocuments = 0
  private var returnDocuments = 0
  func retainOpenDocument() -> OpenDocument { OpenDocument(self) }
  static func shared(documentID: UUID, resources: SceneRenderResources) -> DocumentPagePresentationOwner {
    let key = Key(documentID: documentID, resources: ObjectIdentifier(resources))
    if let owner = owners[key]?.value, !owner.stopped { return owner }
    owners = owners.filter { $0.value.value != nil }
    let owner = DocumentPagePresentationOwner(documentID: documentID, resources: resources)
    owners[key] = WeakOwner(owner)
    return owner
  }

  static func retainTurnSource(documentID: UUID, resources: SceneRenderResources) -> DocumentTurnSourceLease? {
    guard let owner = owners[Key(documentID: documentID, resources: ObjectIdentifier(resources))]?.value,
      !owner.stopped, let source = owner.source, let layout = source.layout else { return nil }
    return .init(source: source, layout: layout)
  }

  static func resolveTurnLanding(_ lease: DocumentTurnSourceLease, page: Int,
    document: DocumentDocument, store: NotebookStore?, resources: SceneRenderResources) async throws -> Int {
    guard lease.source.document.id == document.id else { throw CancellationError() }
    let session = DocumentRenderRegistry.shared.session(documentID: document.id, resources: resources)
    let successor = session.source(document, store: store), reader = UUID()
    defer { successor.releasePage(hostID: reader, in: nil) }
    try await successor.prepareOpening(pageIndex: page, hostID: reader, resources: resources)
    try Task.checkCancellation()
    guard let layout = successor.layout else { throw DocumentSessionError.invalidLayout }
    let anchor = lease.layout.reading.anchor(page: page, fileOrder: lease.layout.readingFileOrder)
    return anchor.flatMap { layout.reading.page(for: $0, survivingFileOrder: layout.readingFileOrder, regions: layout.regions) }
      ?? min(max(0, page), layout.pageCount-1)
  }

  static func retryRetiringPrograms(resources: SceneRenderResources = .shared) {
    for entry in Array(owners.values) {
      if let owner = entry.closingValue, owner.resources === resources { owner.stop() }
    }
  }

  static func checkpointFocusedProgram(documentID: UUID, resources: SceneRenderResources = .shared, resume: Bool) async -> Bool {
    guard let owner = owners[Key(documentID: documentID, resources: ObjectIdentifier(resources))]?.value else { return true }
    return await owner.programOwner.checkpointFocused(resume: resume)
  }

  static func checkpointPrograms(documentID: UUID? = nil, resources: SceneRenderResources = .shared, resume: Bool) async -> Bool {
    let current = owners.values.compactMap(\.value).filter {
      !$0.stopped && $0.resources === resources && (documentID == nil || $0.documentID == documentID)
    }
    let tasks = current.map { owner in Task { @MainActor in await owner.programOwner.checkpointAll(resume: resume) } }
    var accepted = true
    for task in tasks { if !(await task.value) { accepted = false } }
    return accepted
  }

  static func pauseForAttention(documentID: UUID, blockID: String, resources: SceneRenderResources = .shared) async throws -> NotebookProgramAttentionPause {
    guard let owner = owners[Key(documentID: documentID, resources: ObjectIdentifier(resources))]?.value,
      let runtime = owner.programOwner.runtime(for: blockID), runtime.ready,
      let web = runtime.webView, SceneSourceVisibility.isVisible(web) else {
      throw SceneRenderError.snapshotPending("document_attention_owner")
    }
    let attentionID = UUID(); runtime.attentionPauseID = attentionID
    await runtime.blur()
    let value: JSONValue
    do {
      value = try await runtime.checkpoint()
      let raster = try await runtime.capture(sourceOffset: 0, height: runtime.viewportSize.height,
        pixelWidth: max(1, Int(ceil(runtime.blockWidth * 2))))
      raster.release()
      guard owner.programOwner.runtime(for: blockID) === runtime, runtime.value == value else { throw CancellationError() }
      runtime.onChange()
    } catch {
      if runtime.attentionPauseID == attentionID { await owner.programOwner.resumeAfterAttention(blockID, runtime: runtime, attentionID: attentionID) }
      throw error
    }
    return .init(value: value, isCurrent: { [weak owner, weak runtime] in
      guard let runtime else { return false }
      return owner?.programOwner.runtime(for: blockID) === runtime && runtime.value == value
        && runtime.attentionPauseID == attentionID && runtime.hasFrozenFrame
    }, resume: { [weak owner, weak runtime] in
      guard let runtime, owner?.programOwner.runtime(for: blockID) === runtime, runtime.value == value,
        runtime.attentionPauseID == attentionID else { return }
      await owner?.programOwner.resumeAfterAttention(blockID, runtime: runtime, attentionID: attentionID)
    })
  }

  static func resumePrograms(resources: SceneRenderResources = .shared) async {
    for owner in owners.values.compactMap(\.value) where !owner.stopped && owner.resources === resources {
      await owner.programOwner.resumeAll()
    }
  }

  static func presentationDiagnostic(documentID: UUID, resources: SceneRenderResources) -> String {
    guard let owner = owners[Key(documentID: documentID, resources: ObjectIdentifier(resources))]?.value else { return "no document owner" }
    func path(_ view: UIView?) -> String {
      var result: [String] = [], node = view
      while let current = node {
        result.append("\(type(of: current))@\(ObjectIdentifier(current)):input=\(current.isUserInteractionEnabled)")
        node = current.superview
      }
      return result.joined(separator: "/")
    }
    let entries = owner.entries.values.map { entry in
      "\(entry.id):page=\(entry.input.pageIndex),current=\(entry.input.isCurrent),host=\(entry.host.map { String(describing: ObjectIdentifier($0)) } ?? "nil"),window=\(entry.host?.window != nil)"
    }.sorted()
    return "current=\(String(describing: owner.current?.id)) mounted=\(String(describing: owner.mountedID)) entries=\(entries) paperPage=\(String(describing: owner.paper.payload?.pageIndex)) canonical=\(owner.paper.hasCanonicalPixels) paper=\(path(owner.paper.webView)) paperToken=\(owner.paper.payload?.renderToken ?? "nil") currentToken=\(owner.current?.input.token ?? "nil") work=\(String(describing: owner.workID)) needsWork=\(owner.needsWork) passivePage=\(String(describing: owner.passive?.payload?.pageIndex)) passiveStage=\(owner.passiveStage) passiveCanonical=\(owner.passive?.hasCanonicalPixels == true) passiveError=\(String(describing: owner.passive?.acquisitionError)) passiveView=\(path(owner.passive?.webView)) pictures=\(owner.pictures.mapValues { "\($0.raster.image.cgImage?.width ?? 0)x\($0.raster.image.cgImage?.height ?? 0)" }) admission=\(owner.resources.rasterAdmission) pendingReaders=\(owner.source?.pendingPreparationReaderCount ?? 0) gesture=\(owner.gestureLocked) focused=\(owner.programOwner.hasFocus) terminal=\(owner.terminalFailures.sorted()) pressure=\(owner.failures.keys.sorted())"
  }

  /// Submission freezes the installed native paper and all clipped program
  /// surfaces together before yielding the main actor. It does not wait for a
  /// neighboring snapshot or ask a program to render a later frame.
  static func capturePresented(documentID: UUID, pageIndex: Int, token: String, region: PageRect,
    resources: SceneRenderResources = .shared, blockID: String? = nil) throws -> NotebookSubmittedPixels? {
    guard let owner = owners[Key(documentID: documentID, resources: ObjectIdentifier(resources))]?.value,
      let entry = owner.current, entry.input.pageIndex == pageIndex, entry.input.token == token,
      owner.mountedID == entry.id, let host = entry.host, host.window != nil, !host.hasSnapshot,
      owner.paper.hasCanonicalPixels, !owner.gestureLocked,
      owner.programsReady(on: pageIndex, scope: .region(region)), owner.isInstalled(entry) else { return nil }
    guard host.window?.windowScene?.activationState == .foregroundActive else { return nil }
    #if targetEnvironment(simulator)
      let device = AgentPinnedImage.Presentation.Device.iOSSimulator
    #else
      let device = AgentPinnedImage.Presentation.Device.iPad
    #endif
    let program: AgentPinnedImage.Presentation.Program?
    if let blockID, let runtime = owner.programOwner.runtime(for: blockID),
      runtime.attentionPauseID != nil, runtime.hasFrozenFrame,
      runtime.sourceBasis == owner.source?.program(blockID)?.sourceBasis,
      runtime.value == (entry.input.state.value(for: blockID) ?? runtime.program.initialState),
      let placement = owner.placements(on: entry).first(where: { $0.blockID == blockID }),
      placement.rect.intersects(CGRect(x: region.x, y: region.y, width: region.width, height: region.height)) {
      program = .init(instanceID: blockID, programPath: runtime.program.path, sourceBasis: runtime.sourceBasis, state: runtime.value)
    } else { program = nil }
    let pixels = try NotebookSubmittedPixels.capture(view: host,
      physicalSize: owner.physicalSize(entry.input), region: region, resources: resources,
      semanticSelection: owner.semanticSelection(on: entry, blockID: blockID, region: region),
      presentation: .init(device: device, program: program))
    guard owner.current?.id == entry.id, entry.input.token == token, !owner.gestureLocked,
      owner.mountedID == entry.id, owner.isInstalled(entry) else { return nil }
    return pixels
  }

  static func captureCurrent(documentID: UUID, pageIndex: Int, token: String,
    resources: SceneRenderResources = .shared) async throws -> RasterLease? {
    guard let owner = owners[Key(documentID: documentID, resources: ObjectIdentifier(resources))]?.value,
      let entry = owner.current, entry.input.pageIndex == pageIndex, entry.input.token == token,
      owner.mountedID == entry.id, entry.host?.window != nil, entry.host?.hasSnapshot == false,
      owner.paper?.hasCanonicalPixels == true, !owner.gestureLocked,
      owner.programsReady(on: pageIndex), owner.isInstalled(entry) else { return nil }
    let raster = try await owner.capture(entry, using: owner.paper)
    guard owner.current?.id == entry.id, entry.input.token == token, !owner.gestureLocked,
      owner.mountedID == entry.id, owner.isInstalled(entry) else { raster.release(); return nil }
    return raster
  }

  let documentID: UUID
  let resources: SceneRenderResources
  private let renderSession: DocumentRenderSession
  private let installationID = UUID()
  private var installationGeneration: UInt64 = 0
  private var entries: [UUID: Entry] = [:]
  private var selectedID: UUID?
  private var mountedID: UUID?
  private var paper: DocumentWebCoordinator!
  private var paperTransfer: PaperTransfer?
  private var passive: DocumentWebCoordinator?
  private let passiveHost = DocumentWebHost()
  private enum PassiveStage { case idle, preparing, capturing, staged }
  private var passiveStage = PassiveStage.idle
  private struct StagedPaper {
    let entryID: UUID
    let token: String
    let demandID: UUID
  }
  private var stagedPaper: StagedPaper?
  private var source: DocumentSourceSnapshot?
  private var programDemandTask: Task<Void, Never>?
  private var programDemandKey: String?
  private let programOwner: DocumentProgramOwner
  private var contacts: Set<String> = []
  private var pictures: [Int: Picture] = [:]
  private var failures: [String: SceneRasterAdmission] = [:]
  private var terminalFailures: Set<String> = []
  private var work: Task<Void, Never>?
  private var workID: UUID?
  private var needsWork = false
  private var stopped = false
  private var admissionObserver: NSObjectProtocol?
  private var reclamationOwner: UUID?
  private var captureTail: Task<RasterLease, Error>?
  private var captureID: UUID?
  private var preparationDemand: PageTurnActivity.PreparationDemand?

  /// The configured passive request, including a real queued WebKit admission.
  /// This observation neither starts preparation nor changes readiness.
  var pendingPassivePageIndex: Int? { passive?.payload?.pageIndex }

  private init(documentID: UUID, resources: SceneRenderResources) {
    self.documentID = documentID; self.resources = resources
    renderSession = DocumentRenderRegistry.shared.session(documentID: documentID, resources: resources)
    programOwner = DocumentProgramOwner(documentID: documentID, resources: resources)
    paper = makePaper()
    programOwner.onChange = { [weak self] in
      guard let self else { return }
      if let current, current.id == mountedID, !gestureLocked { installPrograms(on: current) }
      schedule()
    }
    programOwner.onMount = { [weak self] web, size in
      guard let host = self?.driver?.host else { return }
      host.installProgramOverlay(); host.programOverlay.park(web, fullSize: size)
    }
    programOwner.onLink = { [weak self] block, version, href in
      guard let self, let current, current.id == mountedID, let host = current.host,
        source?.program(block)?.sourceBasis == version,
        let origin = paper.currentLinkOrigin, let layout = origin.source.layout,
        origin.source.matches(current.input.document), origin.pageIndex == current.input.pageIndex,
        layout.blockIDs(on: [origin.pageIndex], kind: .program).contains(block),
        host.programOverlay.isPresenting(placements(on: current), paperSize: physicalSize(current.input),
          passive: passivePlacements(on: current)) else { return }
      paper.resolveLink(href, origin: origin, deliver: current.input.onLinkActivation)
    }
    reclamationOwner = resources.registerReclamationOwner { [weak self] in self?.reclamationCandidates() ?? [] }
    observe("document_owner_created")
    admissionObserver = NotificationCenter.default.addObserver(forName: SceneRenderResources.didGainRasterAdmission,
      object: resources, queue: .main) { [weak self] _ in
      Task { @MainActor [weak self] in self?.retryAfterAdmission() }
    }
  }

  /// Observes an already scheduled presentation turn without scheduling work,
  /// extending its lifetime, or changing readiness. Tests use the exact task
  /// boundary to exercise a delayed incoming native host without a sleep.
  func observePendingPresentationWork() async {
    let pending = work
    await pending?.value
  }

  private func observe(_ stage: String, entryID: UUID? = nil, page: Int? = nil,
    reason: String? = nil, renderer: DocumentWebCoordinator? = nil) {
    guard NotebookNavigationObservation.enabled else { return }
    func uuid(_ id: UUID?) -> JSONValue { id.map { .string($0.uuidString) } ?? .null }
    func rendererValue(_ value: DocumentWebCoordinator?) -> JSONValue {
      guard let value else { return .null }
      return .object(["objectID": .string(String(describing: ObjectIdentifier(value))),
        "coordinatorID": uuid(value.pagePreparationTrace?.identity.coordinatorID),
        "runtimeID": uuid(value.payload?.runtimeID),
        "sourceKey": value.payload.map { .string($0.source.message.key) } ?? .null,
        "stateKey": value.payload.map { .string($0.state.message.key) } ?? .null,
        "page": value.payload.map { .number(Double($0.pageIndex)) } ?? .null,
        "canonical": .bool(value.hasCanonicalPixels), "invalidated": .bool(value.isInvalidated)])
    }
    let details: [String: JSONValue] = ["entryID": uuid(entryID),
      "page": page.map { .number(Double($0)) } ?? .null,
      "reason": reason.map(JSONValue.string) ?? .null,
      "selectedID": uuid(selectedID), "currentID": uuid(current?.id), "mountedID": uuid(mountedID),
      "workID": uuid(workID), "stopped": .bool(stopped), "needsWork": .bool(needsWork),
      "preparationDemandID": uuid(preparationDemand?.id),
      "preparationTarget": preparationDemand.map { .number(Double($0.pageIndex)) } ?? .null,
      "gestureLocked": .bool(gestureLocked), "inputLocked": .bool(inputLocked),
      "parkedPaper": .bool(paperTransfer != nil), "openDocument": .bool(hasOpenDocumentPresentations),
      "paper": rendererValue(paper),
      "passive": rendererValue(passive), "operationRenderer": rendererValue(renderer),
      "sourceKey": source.map { .string($0.message.key) } ?? .null,
      "activeWebSurfaces": .number(Double(resources.activeWebSurfaceCount)),
      "pendingWebRequests": .number(Double(resources.pendingWebRequestCount)),
      "entries": .array(entries.values.sorted { $0.id.uuidString < $1.id.uuidString }.map { value in
        .object(["id": uuid(value.id), "page": .number(Double(value.input.pageIndex)),
          "current": .bool(value.input.isCurrent), "visible": .bool(value.input.isVisible),
          "retainsOpenDocument": .bool(value.input.retainsOpenDocument),
          "interactive": .bool(value.input.isInteractive), "window": .bool(value.host?.window != nil),
          "pictureReady": .bool(picture(for: value) != nil)])
      })]
    NotebookNavigationObservation.recordDocument(stage, ownerID: installationID,
      documentID: documentID, fields: details)
  }

  private func makePaper() -> DocumentWebCoordinator {
    let renderer = DocumentWebCoordinator(resources: resources, renderSession: renderSession, onRenderReady: .init { _ in },
      onPageLayout: { _ in },  onStateChange: { _, _ in nil })
    bindPaper(renderer)
    return renderer
  }

  private func bindPaper(_ renderer: DocumentWebCoordinator) {
    renderer.externallyHostedPrograms = true
    renderer.onPaperReady = { [weak self, weak renderer] in
      guard let self, let renderer, paper === renderer, let current,
        current.id == mountedID, renderer.payload?.source.matches(current.input.document) == true,
        renderer.payload?.pageIndex == current.input.pageIndex, renderer.paperIsReady else { return }
      refreshProgramDemand()
      installPrograms(on: current)
    }
    renderer.onSurfaceRetirement = { [weak self, weak renderer] web in
      guard let self, let renderer, let transfer = paperTransfer,
        transfer.renderer === renderer, transfer.web === web else { return }
      paperTransfer = nil
    }
    renderer.onPresentationChange = { [weak self] in self?.schedule() }
    renderer.onBeforeRuntimeRestart = { [weak self, weak renderer] in
      guard let self, let renderer else { return }
      if passive === renderer {
        if passiveStage == .idle { retirePassiveRenderer(); schedule() }
        else { renderer.offerIdleReclamation(nil) }
        // Active preparation keeps this coordinator's own bounded recovery
        // counter and target; it never restarts from the current paper's input.
        return
      }
      guard renderer === paper, let input = current?.input else { return }
      work?.cancel(); work = nil; workID = nil
      configure(renderer, input: input, page: input.pageIndex); schedule()
    }
  }

  private var current: Entry? {
    if let selectedID, let entry = entries[selectedID], entry.input.isCurrent { return entry }
    return entries.values.first { $0.input.isCurrent }
  }
  private var driver: Entry? { current ?? entries.values.first { $0.input.isVisible && $0.host?.window != nil } }
  private var hasOpenDocumentPresentations: Bool { openDocuments > 0 || entries.values.contains { $0.input.retainsOpenDocument } }

  /// Full physical presentations own the document lifetime. The selected input
  /// page may disappear during an ordinary handoff; that is not a document
  /// close. Conversely, surviving thumbnails cannot retain its live paper.
  private var holdsReturnPaper: Bool {
    openDocuments > 0 && returnDocuments == openDocuments && current == nil
      && !entries.values.contains { $0.input.retainsOpenDocument }
  }

  private func retirePaperAfterDocumentClose() {
    if holdsReturnPaper {
      paper.parkForReturn()
      programOwner.parkForReturn()
      paper.offerIdleReclamation { [weak self] in
        guard let self, holdsReturnPaper else { return }
        paper.invalidate(); paperTransfer = nil; paper = makePaper()
      }
      return
    }
    guard !hasOpenDocumentPresentations,
      paper.payload != nil || paperTransfer != nil || mountedID != nil else { return }
    observe("document_paper_replace", reason: "last_full_presentation_closed")
    paper.invalidate(); paperTransfer = nil; paper = makePaper(); mountedID = nil
  }
  private var currentTarget: CurrentTarget? {
    current.map { .init(id: $0.id, page: $0.input.pageIndex, source: $0.input.document.contentStamp) }
  }
  private var stateOwner: Entry? { current ?? entries.values.first { $0.input.snapshotPixelWidth == nil } }
  private var gestureLocked: Bool {
    !contacts.isEmpty || entries.values.contains { $0.activity?.isTransitioning == true || $0.input.pageTurnActive }
  }
  private var inputLocked: Bool { gestureLocked || programOwner.hasFocus }

  func update(_ id: UUID, input: DocumentPagePresentation, host: DocumentWebHost) {
    guard !stopped else { return }
    // Only a matching pending action is observed. Its target may still be a
    // prewarming native host; selection is the result of that preparation.
    input.measurements?.demand(documentID: documentID, pageIndex: input.pageIndex, token: input.token)
    let previousTarget = currentTarget
    let previousToken = entries[id]?.input.token
    let previousPaperToken = entries[id]?.input.paperToken
    let createsEntry = entries[id] == nil
    let entry: Entry
    if let existing = entries[id] {
      if existing.host !== host { existing.host?.releasePresentationCallbacks(for: id) }
      entry = existing; entry.input = input; entry.host = host
    }
    else { entry = Entry(id: id, input: input, host: host); entries[id] = entry }
    input.onRenderReady.setFrameProvider { [weak self, weak entry] priority in
      guard let self, let entry, self.entries[id] === entry else { throw CancellationError() }
      return try await self.prepareTurnFrame(entry, priority: priority)
    }
    if previousToken != input.token { entry.releaseTurnFrame() }
    if input.isCurrent { selectedID = id }
    if mountedID == id {
      refreshMountedInput()
    }
    if entry.activity !== input.onRenderReady.activity {
      entry.stopObserving(); entry.activity = input.onRenderReady.activity
      entry.activityObserver = entry.activity?.observe { [weak self] active in
        if active { self?.interruptPassiveWork() }
        else { Task { @MainActor [weak self] in self?.schedule() } }
      }
      entry.preparationObserver = entry.activity?.observePreparation { [weak self] change in
        guard case .demand = change else { return }
        self?.refreshPreparationDemand()
      }
    }
    host.claimPresentationCallbacks(for: id)
    host.onContactChange = { [weak self] active in self?.contact("paper:\(id)", active: active) }
    host.programOverlay.onContactChange = { [weak self] block, active in self?.contact(block, active: active) }
    host.onSizeChange = { [weak self, weak entry] in
      guard let self, let entry, self.entries[id] === entry else { return }
      self.refreshMountedInput()
      // A canonical source may have become ready while its old A4 scene
      // rectangle was still installed. The real layout edge admits it now.
      if entry.id == self.mountedID, self.paper.paperIsReady { self.installPrograms(on: entry) }
      self.schedule()
    }
    host.onWindowChange = { [weak self] in self?.hostAttachmentChanged(id) }
    if mountedID != id, entry.requiresPreparation {
      host.configure(size: physicalSize(input), interactive: false)
      if hasStagedPaper(for: entry) { entry.publishReadiness(true) }
      else if requestsLivePaper(for: entry) {
        entry.publishReadiness(false)
      }
      else if let picture = picture(for: entry) {
        host.installSnapshot(picture.raster); entry.publishReadiness(true, capturable: canCapture(entry))
      }
      else { host.showLoading(); entry.publishReadiness(false) }
    }
    if entry.requiresPreparation { source?.retainPage(input.pageIndex, hostID: id) }
    else {
      // UIKit can retain a closed overview. Its native attachment, not deinit,
      // owns thumbnail demand and pins; off-window RAF cannot hold up a reader.
      source?.releasePage(hostID: id, in: nil)
      entry.releaseTurnFrame()
      host.removeFallback(); entry.publishReadiness(false)
      if let passive, passive.webView?.window == nil {
        work?.cancel(); work = nil; workID = nil
        captureTail?.cancel(); captureTail = nil; captureID = nil
        retirePassiveRenderer()
      }
    }
    if previousTarget != currentTarget
      || (previousToken != input.token && previousToken != nil && passive?.payload?.renderToken == previousPaperToken) {
      interruptPassiveWork()
    }
    refreshPreparationDemand()
    if createsEntry || previousTarget != currentTarget {
      observe("physical_page_update", entryID: id, page: input.pageIndex,
        reason: createsEntry ? "registered" : "current_changed")
    }
    retirePaperAfterDocumentClose()
    refreshProgramDemand()
    trim(); schedule()
  }

  private func hostAttachmentChanged(_ id: UUID) {
    guard let entry = entries[id], let host = entry.host else { return }
    update(id, input: entry.input, host: host)
  }

  /// A requested physical page cannot wait behind a detached neighbour's
  /// snapshot deadline. Only passive work is discarded; the current paper and
  /// every accepted program context remain owned until the native handoff.
  private func interruptPassiveWork() {
    if work != nil || passive != nil { observe("document_work_interrupt") }
    work?.cancel(); work = nil; workID = nil
    captureTail?.cancel(); captureTail = nil; captureID = nil
    if let stagedPaper, let entry = entries[stagedPaper.entryID], hasStagedPaper(for: entry),
      entry.input.isCurrent || preparationDemand?.id == stagedPaper.demandID
        || entry.activity?.installedPreparation?.id == stagedPaper.demandID
        || (preparationDemand == nil && entry.activity?.isTransitioning == true) { return }
    if stagedPaper != nil { retirePassiveRenderer(); return }
    let sourceChanged = current.map { current in
      passive?.payload.map { !$0.source.matches(current.input.document) } ?? false
    } ?? false
    if passiveStage == .capturing || sourceChanged || passive?.webView == nil { retirePassiveRenderer() }
    else if let passive { offerPassiveRenderer(passive) }
  }

  private func retirePassiveRenderer() {
    if let stagedPaper, let entry = entries[stagedPaper.entryID] { entry.publishReadiness(false) }
    stagedPaper = nil
    passive?.offerIdleReclamation(nil)
    passive?.invalidate(); passive = nil; passiveStage = .idle
    passiveHost.removeFromSuperview()
  }

  private func offerPassiveRenderer(_ renderer: DocumentWebCoordinator) {
    guard passive === renderer, stagedPaper == nil else { return }
    passiveStage = .idle
    renderer.releasePreparedPageDemand()
    renderer.offerIdleReclamation { [weak self, weak renderer] in
      guard let self, let renderer, self.passive === renderer, self.passiveStage == .idle else { return }
      self.retirePassiveRenderer()
    }
  }

  private func refreshPreparationDemand() {
    let latest = stateOwner?.activity?.preparationDemand
    guard preparationDemand != latest else { return }
    preparationDemand = latest
    if latest?.presentation == .live {
      for entry in entries.values where requestsLivePaper(for: entry) && !hasStagedPaper(for: entry) {
        entry.publishReadiness(false)
      }
    }
    observe("document_preparation_target", page: latest?.pageIndex,
      reason: latest == nil ? "retired" : "accepted")
    // Current paper preparation and accepted input keep their owner. Only an
    // unrelated passive preparation/capture can be preempted by this demand.
    if passive != nil { interruptPassiveWork() }
    schedule()
  }

  private func contact(_ id: String, active: Bool) {
    if active { contacts.insert(id) }
    else { contacts.remove(id); refreshMountedInput(); schedule() }
  }

  /// Input belongs to the currently installed paper, independently of whether
  /// its source or pixels need work. A contact already accepted by that native
  /// subtree keeps native delivery and editing callbacks until its contact ends.
  /// New hits follow the current policy; link completion has a stable model owner.
  private func refreshMountedInput() {
    guard !stopped, let id = mountedID, let entry = entries[id],
      let host = entry.host else { return }
    let input = entry.input
    // Program state and its paint receipt belong to each retained runtime;
    // independent state changes never send another frame through the paper.
    let matches = current?.id == id && paper.payload?.pageIndex == input.pageIndex
      && paper.payload?.source.matches(input.document) == true
    if matches, contacts.isEmpty {
      paper.updateInteractionCallbacks(
         onLinkActivation: input.onLinkActivation)
    }
    paper.updateInputAdmission(in: host,
      isInteractive: matches && input.isVisible && input.isInteractive)
    recordInstallation(on: entry)
  }

  private func recordInstallation(on entry: Entry) {
    guard let measurements = entry.input.measurements, measurements.enabled,
      let host = entry.host else { return }
    let installed = current?.id == entry.id && mountedID == entry.id
      && entry.input.isVisible && entry.input.isInteractive && !gestureLocked
      && paper.payload?.renderToken == entry.input.paperToken && paper.hasCanonicalPixels
      && host.hasCanonicalPaperProjection && paper.nativeInputIsReady(in: host)
    measurements.installationChanged(documentID: documentID, pageIndex: entry.input.pageIndex,
      token: entry.input.token, installed: installed,
      publish: { [weak host] value in host?.accessibilityValue = value })
  }

  func unregister(_ id: UUID) {
    let previousTarget = currentTarget
    guard let entry = entries.removeValue(forKey: id) else { return }
    observe("physical_page_unregister", entryID: id, page: entry.input.pageIndex)
    if mountedID == id, let web = paper.webView, entry.host?.ownsSurface(web) == true,
      let admission = paper.borrowSurfaceForTransfer(web) {
      paperTransfer = .init(renderer: paper, web: web, admission: admission)
      if let stagedPaper, let incoming = entries[stagedPaper.entryID], hasStagedPaper(for: incoming),
        incoming.activity?.installedPreparation?.id == stagedPaper.demandID,
        let destination = incoming.host, destination.window != nil {
        // UIKit has actually completed this non-curl landing. Keep the retired
        // paper's existing physical subtree in that same window, without a
        // render/mount or an intermediate WebKit detach. Its next passive
        // request reuses this projection; the idle resource offer may retire it.
        destination.installPreparationHost(passiveHost, size: physicalSize(entry.input))
        passiveHost.install(web, size: physicalSize(entry.input))
      }
    }
    if mountedID == id { mountedID = nil }
    entry.releaseTurnFrame()
    entry.stopObserving(); entry.host?.releasePresentationCallbacks(for: id)
    // SwiftUI/UIKit can retain the departed host after its coordinator ends.
    // Native installation, including its raster pins, ends at this boundary.
    // The overlay defers any accepted contact before applying the empty set.
    entry.host?.programOverlay.removePrograms()
    entry.host?.removeFallback(); entry.host?.removeSurface()
    entry.host?.removeFailure(); entry.host?.removeLoading()
    source?.releasePage(hostID: id, in: nil)
    contacts.remove("paper:\(id)")
    if selectedID == id { selectedID = nil }
    if previousTarget != currentTarget { interruptPassiveWork() }
    refreshPreparationDemand()
    trim()
    if entries.isEmpty && openDocuments == 0 { stop() } else { retirePaperAfterDocumentClose(); schedule() }
  }

  private func trim() {
    let requestedTokens = Set(entries.values.filter(\.requiresPreparation).map { $0.input.token })
    // Page numbers survive source/state edits; their old pixels do not. The
    // installed native host owns its own fallback lease through the handoff.
    // This preparation owner only pins images a current presentation can use.
    pictures = pictures.filter { requestedTokens.contains($0.value.token) }
    for entry in entries.values where !entry.requiresPreparation { entry.releaseTurnFrame() }
    failures = failures.filter { requestedTokens.contains($0.key) }
    terminalFailures = terminalFailures.intersection(requestedTokens)
  }

  /// UIKit's adjacent controllers can remain mounted without being displayed.
  /// Their snapshots are preparation, while the current/turn/contact surface
  /// remains mandatory. The host still owns every installed image lease.
  private func reclamationCandidates() -> [SceneResourceReclamationCandidate] {
    guard !stopped, !gestureLocked else { return [] }
    let frames: [SceneResourceReclamationCandidate] = entries.values.compactMap { entry in
      guard let frame = entry.turnFrame else { return nil }
      let frameID = frame.id, bytes = frame.byteCount
      return .init(id: frameID, bytes: bytes, rasterCount: 1, value: .unused,
        distance: abs(entry.input.pageIndex - (current?.input.pageIndex ?? entry.input.pageIndex)), restorationMilliseconds: 1,
        release: { [weak entry] in
          guard entry?.turnFrame?.id == frameID else { return nil }
          entry?.releaseTurnFrame(); return nil
        })
    }
    return frames + pictures.compactMap { page, picture in
      guard canReclaimPicture(page: page, rasterID: picture.raster.entryID) else { return nil }
      let rasterID = picture.raster.entryID
      let installed = entries.values.contains { $0.host?.snapshotEntryID == rasterID }
      return .init(id: rasterID, bytes: picture.raster.accountedByteCount, rasterCount: 1,
        value: installed ? .neighbour : .unused, distance: abs(page - (current?.input.pageIndex ?? page)),
        restorationMilliseconds: 1,
        release: { [weak self] in self?.reclaimPicture(page: page, rasterID: rasterID); return nil })
    }
  }

  private func canReclaimPicture(page: Int, rasterID: UUID) -> Bool {
    guard !stopped, !gestureLocked, preparationDemand?.pageIndex != page,
      pictures[page]?.raster.entryID == rasterID else { return false }
    return !entries.values.contains { entry in
      entry.host?.snapshotEntryID == rasterID
        && ((!entry.input.retainsOpenDocument && entry.host?.hasVisibleSnapshot == true) || entry.id == current?.id
          || entry.id == mountedID || entry.input.pageTurnActive)
    }
  }

  private func reclaimPicture(page: Int, rasterID: UUID) {
    guard canReclaimPicture(page: page, rasterID: rasterID) else { return }
    for entry in entries.values where entry.host?.snapshotEntryID == rasterID {
      entry.releaseTurnFrame()
      entry.host?.removeFallback(); entry.publishReadiness(false)
    }
    pictures[page] = nil
    observe("document_picture_reclaimed", page: page, reason: "not_displayed_or_accepting_input")
  }

  private func schedule() {
    guard !stopped else { return }
    resources.reclamationOffersChanged()
    refreshResidentTurnFrames()
    refreshProgramDemand()
    needsWork = true
    guard work == nil else { return }
    let operation = UUID(); workID = operation
    work = Task { @MainActor [weak self] in
      await Task.yield()
      guard let self else { return }
      while needsWork, !stopped, !Task.isCancelled, workID == operation {
        needsWork = false
        observe("document_reconcile_start")
        let attemptedEntry = driver, attemptedToken = driver?.input.token
        do { try await reconcile() }
        catch is CancellationError { }
        catch {
          if !Task.isCancelled, workID == operation, let entry = attemptedEntry,
            entries[entry.id] === entry, entry.input.token == attemptedToken {
            // The current paper reports its own failure even when the native
            // waiter succeeds. Its throwing waiter must not report it twice.
            let reportedByPaper = current === entry && paper.acquisitionError != nil
              && paper.payload?.renderToken == entry.input.paperToken
            if !reportedByPaper { show(error, on: entry) }
          }
        }
      }
      observe("document_reconcile_finished", reason: workID == operation ? "owner_completed" : "superseded")
      if workID == operation { work = nil; workID = nil }
    }
  }

  private func reconcile() async throws {
    guard let entry = driver, let host = entry.host, host.window != nil else { return }
    let input = entry.input
    guard !hasTerminalFailure(for: entry) else { return }
    if paper.payload?.pageIndex != input.pageIndex, !gestureLocked {
      await programOwner.blurFocused()
    }
    if current != nil, (mountedID != entry.id || paper.payload?.renderToken != input.paperToken || !paper.hasCanonicalPixels) {
      guard !inputLocked else { return }
      // Only a deliberate physical navigation changes this paper viewport.
      // Programs live above it, and a state echo never disables their input.
      if mountedID != entry.id, let old = mountedID.flatMap({ entries[$0] }) {
        if let picture = picture(for: old) { old.host?.installSnapshot(picture.raster) }
        else {
          // UIKit has finished the accepted curl before this transfer. The
          // departed shell is prepared by the passive renderer before another
          // gesture may select it, never by blocking on its detached WebKit.
          old.publishReadiness(false); old.host?.showLoading()
        }
      }
      try Task.checkCancellation()
      guard !inputLocked, entry.input.token == input.token else { return }
      if hasStagedPaper(for: entry), let incoming = passive {
        // The non-curl destination already owns canonical pixels in its native
        // container. Exchange the two existing paper coordinators; do not render
        // the destination again or manufacture a full-page bridge snapshot.
        let outgoing = paper!
        stagedPaper = nil; passive = nil
        paper = incoming
        outgoing.releaseInputOwnership()
        // UIKit has already installed the incoming host. Parking the retired
        // WebKit here would synchronously rebuild an offscreen viewport before
        // admitting the person's input. Keep its existing idle lease; the next
        // actual passive request mounts it, or the resource owner reclaims it.
        passive = outgoing; offerPassiveRenderer(outgoing)
        paperTransfer = nil
        observe("document_live_target_adopted", entryID: entry.id, page: input.pageIndex, renderer: incoming)
      }
      // Blur/draft flushing may have yielded while SwiftUI refreshed callbacks
      // for this same source token. Configure from the current entry so that
      // resuming preparation cannot restore the pre-await navigation closure.
      func mountCurrentPaper(_ renderer: DocumentWebCoordinator) {
        if paper !== renderer {
          observe("document_paper_replace", reason: "adopt_common_shell", renderer: renderer)
          paper.invalidate(); paper = renderer; bindPaper(renderer)
        }
        configure(renderer, input: entry.input, page: input.pageIndex)
        renderer.holdsEditingOwnership = entry.input.isInteractive
        renderer.preservesFallback = true
        renderer.mount(in: host, physicalSize: physicalSize(entry.input), isInteractive: entry.input.isInteractive, priority: .currentPage)
      }
      // Only the first real current paper consumes an unused common shell.
      // Its preparation host survives this entire synchronous configure/mount;
      // passive neighbouring pictures never consume it.
      let adopted = paper.payload == nil && paper.webView == nil
        && resources.documentShellPreparation?.adoptForCurrentPage(mountCurrentPaper) == true
      if !adopted { mountCurrentPaper(paper) }
      mountedID = entry.id
      observe("document_current_mounted", entryID: entry.id, page: input.pageIndex)
      refreshMountedInput()
      if let transfer = paperTransfer,
        transfer.renderer !== paper || transfer.web !== paper.webView || host.ownsSurface(transfer.web) {
        // Installation synchronously gives the incoming native subtree the
        // same runtime. A replaced/failed renderer cannot keep a departed one.
        paperTransfer = nil
      }
      try await paper.awaitPaperReady(token: input.paperToken)
    } else if current == nil, source == nil {
      let renderer = passiveRenderer(in: host, input: input)
      configure(renderer, input: input, page: input.pageIndex)
      renderer.mount(in: passiveHost, physicalSize: physicalSize(input), isInteractive: false, priority: .visible)
      try await renderer.awaitPaperReady(token: input.paperToken)
    }
    guard let layout = source?.layout else { return }
    try Task.checkCancellation()
    // A staged landing is held until UIKit completes its native handoff. It
    // cannot be reused for a speculative neighbour while selection catches up.
    if let stagedPaper, let staged = entries[stagedPaper.entryID], hasStagedPaper(for: staged) {
      if preparationDemand?.id == stagedPaper.demandID || staged.activity?.isTransitioning == true
        || staged.activity?.installedPreparation?.id == stagedPaper.demandID { return }
      retirePassiveRenderer()
    }
    refreshProgramDemand()
    if let current, !gestureLocked, current.id == mountedID { installPrograms(on: current) }
    guard !gestureLocked else { return }
    // Every passive cut uses an independent non-executing paper renderer and
    // immutable captures of the existing block viewports. Current input stays live.
    // The page controller cannot publish the new current page until its
    // landing has pixels. Its explicit demand therefore precedes both nearby
    // speculative pages and higher-resolution refinements of ready pictures.
    let target = preparationDemand?.pageIndex
    if let target, !entries.values.contains(where: { $0.input.pageIndex == target }) { return }
    let candidates = entries.values.filter {
      guard $0.requiresPreparation else { return false }
      guard let target else { return true }
      // A retained overview thumbnail is a picture consumer, not the native
      // destination of a page request. Wait for the physical host if needed.
      return $0.input.pageIndex == target
        && (preparationDemand?.presentation != .live || $0.input.retainsOpenDocument)
    }
    for candidate in candidates.sorted(by: {
      return abs($0.input.pageIndex - input.pageIndex) < abs($1.input.pageIndex - input.pageIndex)
    }) {
      guard !stopped, !Task.isCancelled else { return }
      if candidate.id == current?.id { continue }
      guard needsPicture(candidate), failures[candidate.input.token] == nil,
        !hasTerminalFailure(for: candidate) else { continue }
      if requestsLivePaper(for: candidate), candidate.host?.window == nil { continue }
      let token = candidate.input.token
      let measurements = candidate.input.measurements
      var landingTrace: DocumentPagePreparationTrace?
      let preparingOperation = workID
      do {
        let renderer = passiveRenderer(in: host, input: candidate.input)
        observe("passive_page_prepare_start", entryID: candidate.id, page: candidate.input.pageIndex, renderer: renderer)
        // A hidden paper bitmap is preparation backing, not the final native
        // page picture. Budget both simultaneously before starting its decode;
        // a fixed 1024px intermediate otherwise defeats low-quality admission.
        // Optional GPU copies yield before choosing the new paper's density;
        // captureWidth intentionally sees actual free bytes, not eviction offers.
        if !requestsLivePaper(for: candidate) {
          for cached in residentTurnEntries.reversed() {
            guard captureWidth(candidate, includesPaperBacking: true) < requestedWidth(candidate) else { break }
            cached.releaseTurnFrame()
          }
        }
        let paperWidth = requestsLivePaper(for: candidate) ? 1024 : max(1, min(1024, captureWidth(candidate, includesPaperBacking: true)))
        configure(renderer, input: candidate.input, page: candidate.input.pageIndex, paperPixelWidth: paperWidth)
        observe("passive_page_configured", entryID: candidate.id, page: candidate.input.pageIndex, renderer: renderer)
        landingTrace = renderer.pagePreparationTrace
        measurements?.observeLanding(landingTrace, stage: .preparing)
        let liveDemand = requestsLivePaper(for: candidate) ? preparationDemand : nil
        // Only curl needs an immutable composite. A non-curl landing transfers
        // canonical paper and mounts each program at the actual handoff.
        let preparationHost = liveDemand == nil ? passiveHost : (candidate.host ?? passiveHost)
        renderer.preservesFallback = true
        renderer.mount(in: preparationHost, physicalSize: physicalSize(candidate.input), isInteractive: false, priority: .visible)
        observe("passive_page_mounted", entryID: candidate.id, page: candidate.input.pageIndex, renderer: renderer)
        if liveDemand != nil { try await renderer.awaitPresentation(token: candidate.input.paperToken) }
        else { try await renderer.awaitPaperReady(token: candidate.input.paperToken) }
        observe("passive_page_paper_ready", entryID: candidate.id, page: candidate.input.pageIndex, renderer: renderer)
        if let liveDemand {
          try Task.checkCancellation()
          guard preparationDemand == liveDemand, entries[candidate.id] === candidate, candidate.input.token == token,
            candidate.host === preparationHost else { throw CancellationError() }
          stagedPaper = .init(entryID: candidate.id, token: token, demandID: liveDemand.id)
          passiveStage = .staged
          preparationHost.installProgramOverlay()
          _ = preparationHost.programOverlay.present([], paperSize: physicalSize(candidate.input), interactive: false)
          preparationHost.programOverlay.presentPending(layout.regions(on: candidate.input.pageIndex).compactMap { region in
            guard region.kind == .program, source?.programIDs.contains(region.id) == true else { return nil }
            return .init(blockID: region.id, rect: .init(x: region.frame.x, y: region.frame.y,
              width: region.frame.width, height: region.frame.height), message: source?.programFailures[region.id] ?? "Подготовка программы…")
          })
          preparationHost.removeFallback(); preparationHost.removeLoading(); preparationHost.removeFailure()
          measurements?.observeLanding(landingTrace, stage: .completed)
          observe("document_live_target_prepared", entryID: candidate.id, page: candidate.input.pageIndex, renderer: renderer)
          candidate.publishReadiness(true)
          refreshResidentTurnFrames()
          return
        }
        passiveStage = .capturing
        measurements?.observeLanding(landingTrace, stage: .capturing)
        let raster = try await capture(candidate, using: renderer)
        measurements?.observeLanding(landingTrace, stage: .completed)
        observe("passive_page_capture_finished", entryID: candidate.id, page: candidate.input.pageIndex, renderer: renderer)
        guard candidate.input.token == token, entries[candidate.id] === candidate else { raster.release(); continue }
        pictures[candidate.input.pageIndex] = Picture(token: token, source: source?.message.key ?? "", raster: raster)
        offerPassiveRenderer(renderer)
        candidate.host?.installSnapshot(raster); candidate.host?.removeFailure()
        candidate.publishReadiness(true, capturable: canCapture(candidate))
        refreshResidentTurnFrames()
      } catch is CancellationError {
        measurements?.observeLanding(landingTrace, stage: .cancelled)
        if workID == preparingOperation, passiveStage != .idle { retirePassiveRenderer() }
        throw CancellationError()
      } catch {
        measurements?.observeLanding(landingTrace, stage: Task.isCancelled ? .cancelled : .failed)
        if workID == preparingOperation, passiveStage != .idle { retirePassiveRenderer() }
        try Task.checkCancellation()
        if entries[candidate.id] === candidate, candidate.input.token == token { show(error, on: candidate) }
      }
    }
    try Task.checkCancellation()
    // A completed static executor remains reusable while this document is open.
    // The shared pool can reclaim this exact idle lease for queued work.
    if !hasOpenDocumentPresentations || !programOwner.retainedIDs.isEmpty { retirePassiveRenderer() }
    else if let passive { offerPassiveRenderer(passive) }
    retirePaperAfterDocumentClose()
  }

  private func physicalSize(_ input: DocumentPagePresentation) -> CGSize {
    let geometry = source?.layout?.paper(on: input.pageIndex).geometry
      ?? paper.retainedGeometry(on: input.pageIndex) ?? WorkspaceItemGeometry.uncompiledDocument
    return .init(width: geometry.width, height: geometry.height)
  }

  private func hasStagedPaper(for entry: Entry) -> Bool {
    guard let stagedPaper, stagedPaper.entryID == entry.id, stagedPaper.token == entry.input.token,
      let passive, passive.payload?.renderToken == entry.input.paperToken, passive.hasCanonicalPixels,
      let web = passive.webView, entry.host?.ownsSurface(web) == true else { return false }
    return true
  }

  private func requestsLivePaper(for entry: Entry) -> Bool {
    entry.input.retainsOpenDocument && preparationDemand?.presentation == .live
      && preparationDemand?.pageIndex == entry.input.pageIndex && source?.layout != nil
  }

  private func passiveRenderer(in host: DocumentWebHost, input: DocumentPagePresentation) -> DocumentWebCoordinator {
    host.installPreparationHost(passiveHost, size: physicalSize(input))
    passiveStage = .preparing
    if let passive { passive.offerIdleReclamation(nil); return passive }
    let renderer = makePaper(); passive = renderer; return renderer
  }

  private func configure(_ renderer: DocumentWebCoordinator, input: DocumentPagePresentation, page: Int, paperPixelWidth: Int = 1024) {
    renderer.programStore = input.programStore
    renderer.update(document: input.document, state: input.state, selectedPageIndex: page, capturesSnapshot: false,
      onRenderReady: .init { _ in }, onPageLayout: { [weak self] layout in
        self?.entries.values.forEach { $0.input.onPageLayout(layout) }
      },  onStateChange: { _, _ in nil },
      paperPreparationPixelWidth: input.snapshotPixelWidth ?? paperPixelWidth,
      onPreparationFailure: { [weak self, weak renderer] error in
        guard let self, !stopped, let renderer, paper === renderer, let current,
          renderer.payload?.renderToken == current.input.paperToken else { return }
        // Native paper may already be ready when its interaction surface
        // fails. Its independent waiter cannot publish that failure for us.
        show(error, on: current)
      },
      onLinkActivation: input.onLinkActivation,
      preparationRequestID: input.measurements?.preparationRequestID(documentID: documentID, pageIndex: page, token: input.token))
    if source !== renderer.payload?.source {
      for entry in entries.values { source?.releasePage(hostID: entry.id, in: nil) }
      source?.onProgramsChanged = {}
      source = renderer.payload?.source
      source?.onProgramsChanged = { [weak self, weak source] in
        guard let self, let source, self.source === source else { return }
        refreshProgramDemand(); schedule()
      }
    }
    for entry in entries.values where entry.requiresPreparation {
      source?.retainPage(entry.input.pageIndex, hostID: entry.id)
    }
    // A positive camera pose only retains the document owner. Transfer the
    // early source reader after this exact native payload has registered its
    // real page demand, so cancellation cannot fall into an unowned interval.
    if let source {
      for opening in openingPreparations.compactMap(\.value) { opening.handoff(to: source) }
      openingPreparations.removeAll { $0.value?.isPending != true }
    }
  }

  private func visiblePrograms() -> Set<String> {
    guard let source, let layout = source.layout else { return [] }
    var visibleIDs: Set<String> = []
    if let entry = current, entry.input.isVisible, let host = entry.host {
      let size = physicalSize(entry.input), bounds = host.bounds
      let scale = min(bounds.width / size.width, bounds.height / size.height)
      if scale.isFinite, scale > 0 {
        let visible = SceneSourceVisibility.visibleRect(host)
        guard !visible.isNull, !visible.isEmpty else { return [] }
        let rect = CGRect(x: (visible.minX - bounds.midX) / scale + size.width / 2,
          y: (visible.minY - bounds.midY) / scale + size.height / 2,
          width: visible.width / scale, height: visible.height / scale)
        visibleIDs = Set(layout.regions(on: entry.input.pageIndex).filter { region in
          region.kind == .program && rect.intersects(CGRect(x: region.frame.x, y: region.frame.y, width: region.frame.width, height: region.frame.height))
        }.map(\.id))
      }
    }
    return visibleIDs.intersection(source.programIDs)
  }

  private func refreshVisiblePrograms() {
    guard !stopped, visiblePrograms() != programOwner.visibleIDs else { return }
    refreshProgramDemand()
    if let current, current.id == mountedID, !gestureLocked { installPrograms(on: current) }
  }

  private func refreshProgramDemand() {
    guard !holdsReturnPaper else { return }
    let hiddenOpenPaper = current.map { $0.input.retainsOpenDocument && !$0.input.isVisible } == true
    if hiddenOpenPaper { programOwner.parkForReturn() }
    guard let input = stateOwner?.input ?? entries.values.first?.input, let layout = source?.layout,
      source?.matches(input.document) == true else { return }
    let pages = Set(entries.values.filter(\.requiresPreparation).map { min($0.input.pageIndex, layout.pageCount - 1) })
    if let source {
      // Existing heaps remain publication owners while their new descriptor is
      // being resolved. Absence in a lazy result is not proof of source deletion.
      let retained = programOwner.runtimeIDs
      let required = layout.blockIDs(on: pages, kind: .program).union(retained).intersection(source.programIDs)
      let key = source.message.key + ":" + required.sorted().joined(separator: ",")
      if programDemandKey != key {
        programDemandTask?.cancel(); programDemandKey = key
        programDemandTask = Task { @MainActor [weak self, weak source] in
          guard let self, let source else { return }
          do {
            let immediate = current.map { Set([$0.input.pageIndex]) } ?? []
            try await source.preparePrograms(on: immediate, retaining: retained)
            guard !Task.isCancelled, self.source === source, programDemandKey == key else { return }
            refreshProgramDemand(); schedule()
            try await source.preparePrograms(on: pages)
          } catch { return }
          guard !Task.isCancelled, self.source === source, programDemandKey == key else { return }
          refreshProgramDemand(); schedule()
        }
      }
    }
    var densities: [String: Double] = [:]
    for entry in entries.values where entry.requiresPreparation {
      for id in layout.blockIDs(on: [entry.input.pageIndex], kind: .program) {
        densities[id] = max(densities[id] ?? 0, requiredScale(entry))
      }
    }
    programOwner.update(input: input, layout: layout, programs: source?.programs ?? [], pages: pages,
      currentPage: current?.input.pageIndex, visibleIDs: visiblePrograms(), preparationPage: preparationDemand?.pageIndex,
      blocked: gestureLocked, contacts: contacts, densities: densities,
      unresolvedProgramIDs: (source?.programIDs ?? []).subtracting(Set(source?.programs.map(\.id) ?? []).union(source?.programFailures.keys.map { $0 } ?? [])))
    if !hiddenOpenPaper { programOwner.resumeFromReturn() }
  }

  private func installPrograms(on entry: Entry) {
    guard let host = entry.host, let layout = source?.layout, paper.paperIsReady,
      paper.payload?.renderToken == entry.input.paperToken else { return }
    CATransaction.begin(); CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    refreshMountedInput()
    let currentIDs = layout.blockIDs(on: [entry.input.pageIndex], kind: .program)
    host.installProgramOverlay()
    for runtime in programOwner.activeRuntimes where !currentIDs.contains(runtime.program.id) {
      if let web = runtime.webView { host.programOverlay.park(web, fullSize: web.bounds.size) }
    }
    let placements = placements(on: entry)
    let passive = passivePlacements(on: entry)
    guard host.programOverlay.present(placements, paperSize: physicalSize(entry.input), interactive: entry.input.isInteractive, passive: passive) else {
      entry.publishReadiness(true, capturable: false)
      return
    }
    host.programOverlay.presentPending(pendingPlacements(on: entry))
    paper.preservesFallback = false; host.removeFallback(); host.removeLoading()
    if paper.acquisitionError == nil { host.removeFailure() }
    refreshMountedInput()
    entry.publishReadiness(true, capturable: canCapture(entry))
    refreshResidentTurnFrames()
    installationGeneration &+= 1
    let installedToken = entry.input.token
    let installation = host.programOverlay.installation(for: placements, paperSize: physicalSize(entry.input), passive: passive)
    let isInstalled: @MainActor (DocumentPresentationScope) -> Bool = { [weak self, weak host, weak entry] scope in
        guard let self, let host, let entry else { return false }
        return current?.id == entry.id && entry.input.token == installedToken
          && paper.payload?.renderToken == entry.input.paperToken && mountedID == entry.id && host.window?.isKeyWindow == true
          && !host.hasSnapshot && host.hasCanonicalPaperProjection && paper.hasCanonicalPixels
          && programsReady(on: entry.input.pageIndex, scope: scope)
          && installation.isInstalled
      }
    DocumentRenderRegistry.shared.publishLive(documentID: documentID, token: installedToken,
      pageIndex: entry.input.pageIndex, hostID: installationID, generation: installationGeneration,
      paper: { [weak self] in self?.paper.installedPaper }, isAttached: isInstalled)
    if paper.hasCanonicalPixels, let measurements = entry.input.measurements, measurements.enabled {
      if NotebookNavigationObservation.enabled {
        observe("document_content_published", entryID: entry.id, page: entry.input.pageIndex,
          reason: "installed=\(isInstalled(.page)), nativeInput=\(paper.nativeInputIsReady(in: host))")
      }
      measurements.contentReady(documentID: documentID, pageIndex: entry.input.pageIndex, token: installedToken,
        sourcePreparationPhasesMS: source?.preparationPhasesMS ?? [:], sourcePreparationMeasurement: source?.measurementCount,
        sourcePreparationBeganAt: source?.preparationBeganAt, sourcePreparationCompletedAt: source?.preparationCompletedAt,
        pagePreparation: paper.pagePreparationTrace)
      recordInstallation(on: entry)
    }
  }

  private func pendingPlacements(on entry: Entry) -> [DocumentProgramPendingPlacement] {
    guard let layout = source?.layout else { return [] }
    return layout.regions(on: entry.input.pageIndex).compactMap { region in
      guard region.kind == .program, source?.programIDs.contains(region.id) == true else { return nil }
      let id = region.id, runtime = programOwner.runtime(for: id)
      let message: String, actionTitle: String, action: (() -> Void)?
      if let failure = source?.programFailures[id] {
        message = failure; actionTitle = ""; action = nil
      } else if source?.program(id) == nil || (runtime != nil && source?.program(id)?.sourceBasis != runtime?.sourceBasis) {
        message = "Подготовка программы…"; actionTitle = ""; action = nil
      } else if programOwner.isRetiring(id) {
        message = "Сохраняем состояние программы…"; actionTitle = ""; action = nil
      } else if runtime?.failure != nil || programOwner.pauseFailure(for: id) != nil {
        message = "Не удалось подготовить программу"; actionTitle = "Повторить"
        action = { [weak self] in
          self?.programOwner.retry(id)
        }
      } else if runtime?.ready != true || !programOwner.liveIDs.contains(id) {
        message = runtime?.webView == nil && programOwner.liveIDs.contains(id)
          ? "Ожидаем свободные ресурсы…" : "Подготовка программы…"
        actionTitle = ""; action = nil
      } else { return nil }
      return DocumentProgramPendingPlacement(blockID: id,
        rect: .init(x: region.frame.x, y: region.frame.y, width: region.frame.width, height: region.frame.height),
        message: message, retry: action, actionTitle: actionTitle)
    }
  }

  private func placements(on entry: Entry) -> [DocumentProgramPlacement] {
    guard let layout = source?.layout else { return [] }
    return layout.regions(on: entry.input.pageIndex).compactMap { region in
      guard region.kind == .program, let runtime = programOwner.runtime(for: region.id), runtime.ready,
        source?.program(region.id)?.sourceBasis == runtime.sourceBasis,
        programOwner.liveIDs.contains(region.id) || programOwner.isRetiring(region.id),
        let web = runtime.webView else { return nil }
      return .init(blockID: region.id, webView: web,
        rect: .init(x: region.frame.x, y: region.frame.y, width: region.frame.width, height: region.frame.height),
        sourceOffset: region.sourceOffset, fullSize: web.bounds.size,
        allowsInteraction: !programOwner.isRetiring(region.id) && programOwner.pauseFailure(for: region.id) == nil)
    }
  }

  private func passivePlacements(on entry: Entry) -> [DocumentProgramPassivePlacement] {
    guard let layout = source?.layout else { return [] }
    return layout.regions(on: entry.input.pageIndex).compactMap { region in
      guard region.kind == .program else { return nil }
      if programOwner.runtime(for: region.id)?.ready == true,
        programOwner.liveIDs.contains(region.id) || programOwner.isRetiring(region.id) { return nil }
      guard let saved = programOwner.paused(region.id) else { return nil }
      return .init(blockID: region.id, raster: saved.raster,
        rect: .init(x: region.frame.x, y: region.frame.y, width: region.frame.width, height: region.frame.height),
        sourceOffset: region.sourceOffset, fullSize: saved.size)
    }
  }

  private func semanticSelection(on entry: Entry, blockID: String?, region: PageRect) -> ProgramSemanticSelection? {
    guard let blockID else { return nil }
    if let runtime = programOwner.runtime(for: blockID),
      let selection = runtime.frozenSemanticSelection,
      let placement = placements(on: entry).first(where: { $0.blockID == blockID }) {
      return selection.mapped(from: .init(x: placement.rect.minX,
        y: placement.rect.minY - placement.sourceOffset,
        width: placement.fullSize.width, height: placement.fullSize.height), into: region)
    }
    guard let placement = passivePlacements(on: entry).first(where: { $0.blockID == blockID }),
      let selection = placement.raster.semanticSelection else { return nil }
    // Only the installed immutable passive raster can bind author data to Send.
    // A running WebKit, even with equal source/state, cannot supply this evidence.
    return selection.mapped(from: .init(x: placement.rect.minX,
      y: placement.rect.minY - placement.sourceOffset,
      width: placement.fullSize.width, height: placement.fullSize.height), into: region)
  }

  private func isInstalled(_ entry: Entry) -> Bool {
    guard let host = entry.host, mountedID == entry.id,
      host.hasCanonicalPaperProjection,
      paper.payload?.renderToken == entry.input.paperToken else { return false }
    return host.programOverlay.isPresenting(placements(on: entry), paperSize: physicalSize(entry.input), passive: passivePlacements(on: entry))
  }

  /// Curl captures what is actually installed, including an explicit pending
  /// or failed slot. Program interactivity is a separate readiness contract.
  private func canCapture(_ entry: Entry) -> Bool {
    guard let host = entry.host, let source, source.matches(entry.input.document),
      let layout = source.layout else { return false }
    if let picture = picture(for: entry), host.snapshotEntryID == picture.raster.entryID {
      return !picture.raster.isReleased
    }
    guard mountedID == entry.id, !host.hasSnapshot, paper.paperIsReady, host.hasCanonicalPaperProjection,
      paper.payload?.renderToken == entry.input.paperToken, paper.installedPaper != nil,
      let web = paper.webView, host.ownsSurface(web) else { return false }
    let live = placements(on: entry), passive = passivePlacements(on: entry), pending = pendingPlacements(on: entry)
    let covered = Set(live.map(\.blockID)).union(passive.map(\.blockID)).union(pending.map(\.blockID))
    return layout.blockIDs(on: [entry.input.pageIndex], kind: .program).isSubset(of: covered)
      && host.programOverlay.isPresenting(live, paperSize: physicalSize(entry.input), passive: passive)
      && host.programOverlay.isPresentingPending(pending)
  }

  private func programsReady(on page: Int, scope: DocumentPresentationScope = .page) -> Bool {
    guard let source, let layout = source.layout, (0..<layout.pageCount).contains(page) else { return false }
    switch scope {
    case .paper: return true
    case .block(let id):
      return layout.blockIDs(on: [page]).contains(id) && (!source.programIDs.contains(id) || programOwner.presents(id))
    case .region(let region):
      let crop = CGRect(x: region.x, y: region.y, width: region.width, height: region.height)
      guard [region.x, region.y, region.width, region.height].allSatisfy(\.isFinite), !crop.isEmpty,
        CGRect(x: 0, y: 0, width: layout.paper(on: page).surfaceWidth, height: layout.paper(on: page).surfaceHeight).contains(crop) else { return false }
      return layout.regions(on: page).filter { $0.kind == .program && source.programIDs.contains($0.id)
        && crop.intersects(CGRect(x: $0.frame.x, y: $0.frame.y, width: $0.frame.width, height: $0.frame.height))
      }.allSatisfy { programOwner.presents($0.id) }
    case .page: return layout.blockIDs(on: [page], kind: .program).intersection(source.programIDs).allSatisfy { programOwner.presents($0) }
    }
  }

  private func capture(_ entry: Entry, using renderer: DocumentWebCoordinator) async throws -> RasterLease {
    let preceding = captureTail, operation = UUID(), token = entry.input.token
    let task = Task { @MainActor [self] in
      if let preceding { _ = try? await preceding.value }
      try Task.checkCancellation()
      guard !stopped, entry.input.token == token, renderer.payload?.renderToken == entry.input.paperToken else { throw CancellationError() }
      return try await capturePixels(entry, using: renderer)
    }
    captureTail = task; captureID = operation
    defer { if captureID == operation { captureTail = nil; captureID = nil } }
    return try await withTaskCancellationHandler {
      let raster = try await task.value
      guard !Task.isCancelled else { raster.release(); throw CancellationError() }
      return raster
    } onCancel: { task.cancel() }
  }

  @MainActor private final class TurnLayers {
    let images: [PageTurnFrame.ImageLayer]
    let retained: [AnyObject]
    init(images: [PageTurnFrame.ImageLayer], retained: [AnyObject]) {
      self.images = images; self.retained = retained
    }
  }

  /// Only the finite native page window owns resident GPU frames. Thumbnails
  /// keep their existing CPU picture and never compete with opening input.
  private var residentTurnEntries: [Entry] {
    let currentPage = current?.input.pageIndex ?? driver?.input.pageIndex ?? 0
    return Array(entries.values.filter { $0.input.retainsOpenDocument && $0.requiresPreparation }.sorted {
      @MainActor func rank(_ entry: Entry) -> Int {
        if entry.id == current?.id { return 0 }
        if entry.input.pageIndex == preparationDemand?.pageIndex { return 1 }
        return 2
      }
      if rank($0) != rank($1) { return rank($0) < rank($1) }
      let a = abs($0.input.pageIndex - currentPage), b = abs($1.input.pageIndex - currentPage)
      return a == b ? $0.id.uuidString < $1.id.uuidString : a < b
    }.prefix(PageTurnPrewarmWindow.capacity))
  }

  private func staticTurnMaterial(_ entry: Entry) -> TurnFrameMaterial? {
    guard let source, let layout = source.layout, source.matches(entry.input.document) else { return nil }
    let size = physicalSize(entry.input), scale = requiredScale(entry)
    guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
      scale.isFinite, scale > 0, size.width * scale <= 8192, size.height * scale <= 8192 else { return nil }
    let hasPrograms = layout.regions(on: entry.input.pageIndex).contains { $0.kind == .program }
    let renderer = entry.id == mountedID ? paper : passive
    let currentPaperMatches = renderer?.payload?.renderToken == entry.input.paperToken
      && renderer?.payload?.source.matches(entry.input.document) == true && renderer?.paperIsReady == true
    // A passive picture is the actual installed cut. A plain page may continue
    // borrowing it after native paper landing when it covers the same print at
    // full density. The transparent DOM's later input receipt does not change
    // these pixels; canCapture owns admission of a new physical turn.
    // Live slots always take a new cut once this entry becomes current.
    if let picture = picture(for: entry), picture.source == source.message.key,
      let image = picture.raster.image.cgImage,
      (entry.host?.snapshotEntryID == picture.raster.entryID
        || (!hasPrograms && currentPaperMatches && entry.id == mountedID
          && image.width >= Int(ceil(size.width * scale)) && image.height >= Int(ceil(size.height * scale)))) {
      return .init(key: .init(material: .picture(picture.raster.entryID), token: entry.input.token,
        source: source.message.key, size: size, scale: scale), image: image, owner: picture.raster)
    }
    guard !hasPrograms, currentPaperMatches, entry.id == mountedID || hasStagedPaper(for: entry),
      let paper = renderer?.installedPaper, entry.host?.hasSnapshot == false else { return nil }
    return .init(key: .init(material: .paper(ObjectIdentifier(paper)), token: entry.input.token,
      source: source.message.key, size: size, scale: scale), image: paper.image, owner: paper)
  }

  /// Immutable observation of the existing owner; does not acquire material.
  func turnFrameDiagnostic(page: Int) -> String {
    entries.values.filter { $0.input.pageIndex == page }.sorted { $0.id.uuidString < $1.id.uuidString }
      .map { turnFrameDiagnostic($0) }.joined(separator: "\n")
  }

  private func turnFrameDiagnostic(_ entry: Entry) -> String {
    let renderer = entry.id == mountedID ? paper : passive
    let picture = picture(for: entry)
    let size = physicalSize(entry.input), scale = requiredScale(entry)
    let paperID = (renderer?.installedPaper).map { ObjectIdentifier($0) }
    return "entry=\(entry.id) page=\(entry.input.pageIndex) current=\(current?.id == entry.id) mounted=\(mountedID == entry.id) frame=\(String(describing: entry.turnFrame?.id)) cached=\(String(reflecting: entry.turnFrameKey)) actual=\(String(reflecting: staticTurnMaterial(entry)?.key)) size=\(size) scale=\(scale) token=\(entry.input.token) source=\(source?.message.key ?? "nil") fallback=\(String(describing: entry.host?.snapshotEntryID)) picture=\(String(describing: picture?.raster.entryID)) pixels=\(picture?.raster.image.cgImage?.width ?? 0)x\(picture?.raster.image.cgImage?.height ?? 0) paper=\(String(describing: paperID)) canonical=\(renderer?.hasCanonicalPixels == true) paperToken=\(renderer?.payload?.renderToken ?? "nil")"
  }

  private func observeTurnFrame(_ stage: String, entry: Entry) {
    guard let observe = NotebookNavigationObservation.onPageMaterialPreparation else { return }
    observe("\(stage) \(turnFrameDiagnostic(entry))", entry.id, nil,
      entry.turnFrame?.id, entry.turnFramePreparationID, CACurrentMediaTime())
  }

  private func refreshResidentTurnFrames() {
    guard !stopped else { return }
    let retained = residentTurnEntries, ids = Set(retained.map(\.id))
    for entry in entries.values where !ids.contains(entry.id) { entry.releaseTurnFrame() }
    // CPU paper/pictures get the first admission. A speculative GPU copy must
    // not consume the single available raster slot before a neighbour can use it.
    let mayPrewarm = !entries.values.contains {
      $0.requiresPreparation && $0.id != current?.id && needsPicture($0)
    }
    for entry in retained {
      guard let material = staticTurnMaterial(entry) else {
        if entry.turnFrame != nil || entry.turnFramePreparation != nil { observeTurnFrame("document_turn_unavailable", entry: entry) }
        entry.releaseTurnFrame(); continue
      }
      if entry.turnFrameKey != material.key {
        if entry.turnFrame != nil || entry.turnFramePreparation != nil { observeTurnFrame("document_turn_key_changed", entry: entry) }
        entry.releaseTurnFrame()
      }
      guard mayPrewarm, entry.acceptedTurnCaptures == 0,
        entry.turnFrame == nil, entry.turnFramePreparation == nil else { continue }
      _ = prepareResidentTurnFrame(entry, material: material, opportunistic: true)
    }
  }

  private func prepareResidentTurnFrame(_ entry: Entry, material: TurnFrameMaterial,
    opportunistic: Bool) -> Task<PageTurnFrame, Error>? {
    if entry.turnFrameKey != material.key { entry.releaseTurnFrame() }
    if let task = entry.turnFramePreparation {
      if !opportunistic { entry.turnFramePreparationIsRequired = true }
      return task
    }
    let key = material.key, admission = resources.rasterAdmission
    guard let bytes = SceneRenderResources.estimatedRasterBytes(pixelWidth: Int(ceil(key.size.width * key.scale)),
      pixelHeight: Int(ceil(key.size.height * key.scale))) else { return nil }
    if opportunistic {
      // No pending allocation and no reclamation for a speculative GPU copy.
      // Paper readiness/input have already been published by their owner.
      guard resources.pendingDerivedRequestCount == 0, entry.turnFrameRefusal != admission,
        admission.fits(additionalBytes: bytes / 2, additionalCount: 1) else { return nil }
    }
    let operation = UUID()
    entry.turnFrameKey = key; entry.turnFramePreparationID = operation
    entry.turnFramePreparationIsRequired = !opportunistic
    let resources = resources
    let task = Task { @MainActor [weak self, weak entry] in
      do {
        try Task.checkCancellation()
        if entry?.turnFramePreparationIsRequired != true {
          guard resources.pendingDerivedRequestCount == 0,
            resources.rasterAdmission.fits(additionalBytes: bytes / 2, additionalCount: 1) else { throw SceneRenderError.resourceLimit }
        }
        let frame = try await PageTurnFrame.compose(size: key.size, scale: key.scale,
          images: [.init(image: material.image, frame: .init(origin: .zero, size: key.size))], resources: resources,
          retaining: [material.owner])
        try Task.checkCancellation()
        guard let self, let entry, self.entries[entry.id] === entry,
          entry.turnFramePreparationID == operation, entry.turnFrameKey == key,
          self.staticTurnMaterial(entry)?.key == key else { throw CancellationError() }
        entry.turnFrame = frame; entry.turnFramePreparation = nil; entry.turnFramePreparationID = nil
        entry.turnFramePreparationIsRequired = false; entry.turnFrameRefusal = nil
        resources.reclamationOffersChanged()
        return frame
      } catch {
        if let entry, entry.turnFramePreparationID == operation {
          entry.turnFramePreparation = nil; entry.turnFramePreparationID = nil
          entry.turnFramePreparationIsRequired = false; entry.turnFrameRefusal = resources.rasterAdmission
        }
        throw error
      }
    }
    entry.turnFramePreparation = task
    return task
  }

  /// A curl borrows an already resident immutable static frame. Live programs
  /// contribute an atomic cut of their existing slots at this acceptance.
  private func prepareTurnFrame(_ entry: Entry, priority: SceneAllocationPriority) async throws -> PageTurnFrame {
    guard canCapture(entry) else { throw SceneRenderError.snapshotPending("document_installed_slots") }
    if priority == .input { entry.acceptedTurnCaptures += 1 }
    defer { if priority == .input { entry.acceptedTurnCaptures -= 1 } }
    let token = entry.input.token, size = physicalSize(entry.input)
    if let material = staticTurnMaterial(entry) {
      if entry.turnFrameKey == material.key, let frame = entry.turnFrame { return frame }
      if priority == .input {
        // Reuse an already submitted passive GPU copy when possible. A refused
        // speculative allocation must not veto this accepted physical turn.
        if let task = entry.turnFramePreparation {
          do {
            let frame = try await task.value
            try Task.checkCancellation()
            guard entries[entry.id] === entry, staticTurnMaterial(entry)?.key == material.key else { throw CancellationError() }
            return frame
          } catch {
            try Task.checkCancellation()
            guard entries[entry.id] === entry, staticTurnMaterial(entry)?.key == material.key else { throw CancellationError() }
            guard error is CancellationError || error as? SceneRenderError == .resourceLimit else { throw error }
          }
        }
        let frame = try await PageTurnFrame.compose(size: material.key.size, scale: material.key.scale,
          images: [.init(image: material.image, frame: .init(origin: .zero, size: material.key.size))],
          resources: resources, priority: .input, retaining: [material.owner])
        try Task.checkCancellation()
        guard entries[entry.id] === entry, staticTurnMaterial(entry)?.key == material.key else { throw CancellationError() }
        return frame
      }
      guard let task = prepareResidentTurnFrame(entry, material: material, opportunistic: false) else {
        throw SceneRenderError.snapshotPending("document_turn_material")
      }
      let frame = try await task.value
      try Task.checkCancellation()
      guard entries[entry.id] === entry, staticTurnMaterial(entry)?.key == material.key else { throw CancellationError() }
      return frame
    }
    entry.releaseTurnFrame()
    let renderer = entry.id == mountedID ? paper : passive
    guard let renderer, let raster = renderer.installedPaper,
      renderer.payload?.renderToken == entry.input.paperToken else { throw SceneRenderError.snapshotPending("document_paper") }
    let layers = try await turnLayers(entry, paper: raster, width: requestedWidth(entry), exactInstalled: true, priority: priority)
    guard entries[entry.id] === entry, entry.input.token == token,
      renderer.installedPaper === raster else { throw CancellationError() }
    let frame = try await PageTurnFrame.compose(size: size, scale: requiredScale(entry), images: layers.images, resources: resources, priority: priority, retaining: layers.retained)
    guard entries[entry.id] === entry, entry.input.token == token else { throw CancellationError() }
    return frame
  }

  private func turnLayers(_ entry: Entry, paper: DocumentPaperRaster, width: Int, exactInstalled: Bool,
    priority: SceneAllocationPriority = .passive) async throws -> TurnLayers {
    guard let layout = source?.layout else { throw SceneRenderError.snapshotPending("document_layout") }
    let size = physicalSize(entry.input), token = entry.input.token
    var images: [PageTurnFrame.ImageLayer] = [.init(image: paper.image, frame: .init(origin: .zero, size: size))]
    var retained: [AnyObject] = [paper]
    let regions = layout.regions(on: entry.input.pageIndex).filter { $0.kind == .program }
    let slots: [Int: TurnLayers]
    if priority == .input {
      // Independent installed executors share display opportunities instead of
      // spending one afterScreenUpdates snapshot round per program. One runtime
      // still serializes its own crops. All cuts survive until composition,
      // so serial waves cannot reduce their final charged memory peak.
      let programs = Dictionary(grouping: regions.indices, by: { regions[$0].id }).values
        .sorted { $0[0] < $1[0] }
      let capture: @MainActor @Sendable ([Int]) async throws -> [Int: TurnLayers] = { [self] indices in
        var cuts: [Int: TurnLayers] = [:]
        for index in indices {
          try Task.checkCancellation()
          guard entry.input.token == token else { throw CancellationError() }
          cuts[index] = try await turnProgramLayers(entry, region: regions[index], width: width,
            exactInstalled: exactInstalled, priority: priority)
        }
        return cuts
      }
      slots = try await withThrowingTaskGroup(of: [Int: TurnLayers].self) { group in
        var result: [Int: TurnLayers] = [:]
        for indices in programs { group.addTask { try await capture(indices) } }
        while let cuts = try await group.next() {
          result.merge(cuts) { _, latest in latest }
        }
        return result
      }

    } else {
      var result: [Int: TurnLayers] = [:]
      for index in regions.indices {
        result[index] = try await turnProgramLayers(entry, region: regions[index], width: width,
          exactInstalled: exactInstalled, priority: priority)
      }
      slots = result
    }
    try Task.checkCancellation()
    guard entry.input.token == token else { throw CancellationError() }
    for index in regions.indices {
      guard let layers = slots[index] else { throw SceneRenderError.snapshotPending("document_program_layers") }
      images.append(contentsOf: layers.images); retained.append(contentsOf: layers.retained)
    }
    return .init(images: images, retained: retained)
  }

  private func turnProgramLayers(_ entry: Entry, region: DocumentBlockRegion, width: Int,
    exactInstalled: Bool, priority: SceneAllocationPriority) async throws -> TurnLayers {
    let size = physicalSize(entry.input), token = entry.input.token
    let rect = CGRect(x: region.frame.x, y: region.frame.y, width: region.frame.width, height: region.frame.height)
    let pixelWidth = max(1, Int(ceil(Double(width) * rect.width / size.width)))
    var images: [PageTurnFrame.ImageLayer] = [], retained: [AnyObject] = []
    func appendRuntime(_ runtime: DocumentBlockRuntime) async throws {
      if priority == .input {
        let cut = try await runtime.captureCurrentCut(sourceOffset: region.sourceOffset,
          height: min(region.frame.height, runtime.viewportSize.height-region.sourceOffset), pixelWidth: pixelWidth)
        images.append(.init(image: cut.image, frame: rect)); retained.append(cut)
      } else {
        let raster = try await runtime.capture(sourceOffset: region.sourceOffset,
          height: min(region.frame.height, runtime.viewportSize.height-region.sourceOffset), pixelWidth: pixelWidth)
        if let image = raster.image.cgImage { images.append(.init(image: image, frame: rect)); retained.append(raster) }
      }
    }
    func appendPaused(_ paused: DocumentProgramOwner.PausedProgram) {
      guard let sourceImage = paused.raster.image.cgImage else { return }
      let scale = Double(sourceImage.width)/paused.size.width
      let crop = CGRect(x: 0, y: region.sourceOffset*scale, width: Double(sourceImage.width), height: rect.height*scale)
      if let image = sourceImage.cropping(to: crop), let pin = paused.raster.retainedCopy() {
        images.append(.init(image: image, frame: rect)); retained.append(pin)
      }
    }
    // A status overlays a retiring/failed runtime. Preserve its installed
    // pixels instead of freezing a hidden heap and calling it readiness.
    if let status = pendingPlacements(on: entry).first(where: { $0.blockID == region.id }) {
      if let paused = programOwner.paused(region.id) { appendPaused(paused) }
      else if let runtime = programOwner.runtime(for: region.id), runtime.ready,
        source?.program(region.id)?.sourceBasis == runtime.sourceBasis,
        programOwner.isRetiring(region.id) || programOwner.liveIDs.contains(region.id) {
        try await appendRuntime(runtime)
      }
      let pixelHeight = max(1, Int(ceil(Double(pixelWidth)*rect.height/rect.width)))
      guard let reservation = resources.reserveRaster(pixelWidth: pixelWidth, pixelHeight: pixelHeight,
        priority: priority) else { throw SceneRenderError.resourceLimit }
      var transferred = false
      defer { if !transferred { reservation.release() } }
      let image: UIImage
      if exactInstalled {
        guard let installed = entry.host?.programOverlay.pendingImage(blockID: region.id, pixelWidth: pixelWidth) else {
          throw SceneRenderError.snapshotPending("document_program_status")
        }
        image = installed
      } else { image = DocumentProgramOverlayHost.pendingImage(status, pixelWidth: pixelWidth) }
      if priority == .input {
        guard let cut = resources.currentWebCut(image,
          for: .document(id: documentID, token: "status:" + UUID().uuidString), reservation: reservation)
        else { throw SceneRenderError.resourceLimit }
        transferred = true
        images.append(.init(image: cut.image, frame: rect)); retained.append(cut)
      } else if let raster = resources.storeAndRetain(image,
        for: .document(id: documentID, token: "status:" + UUID().uuidString), reservation: reservation),
        let pixels = raster.image.cgImage {
        images.append(.init(image: pixels, frame: rect)); retained.append(raster)
      } else { throw SceneRenderError.resourceLimit }
    } else if let runtime = programOwner.runtime(for: region.id), runtime.ready {
      try await appendRuntime(runtime)
    } else if let paused = programOwner.paused(region.id) { appendPaused(paused) }
    try Task.checkCancellation()
    guard entry.input.token == token else { throw CancellationError() }
    return .init(images: images, retained: retained)
  }

  private func capturePixels(_ entry: Entry, using renderer: DocumentWebCoordinator) async throws -> RasterLease {
    guard let layout = source?.layout, let paper = renderer.installedPaper else { throw SceneRenderError.snapshotPending("document_paper") }
    let input = entry.input, token = input.token, physical = physicalSize(input)
    let width = captureWidth(entry), height = Int(ceil(Double(width)*physical.height/physical.width))
    guard width > 0, let reservation = resources.reserveRaster(pixelWidth: width, pixelHeight: height) else { throw SceneRenderError.resourceLimit }
    defer { reservation.release() }
    let layers = try await turnLayers(entry, paper: paper, width: width, exactInstalled: false)
    guard !Task.isCancelled, !stopped, entry.input.token == token,
      renderer.payload?.renderToken == input.paperToken else { throw CancellationError() }
    // Passive native hosts need a reusable UIImage. This composes the existing
    // paper image and local slots once, without a whole-page WebKit readback.
    // Admission and the later full-density borrow use these integral extents.
    // A fractional UIKit canvas can round one axis down, making the same plain
    // picture ineligible as soon as landing removes its snapshot view.
    let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
    let pixels = UIGraphicsImageRenderer(size: .init(width: width, height: height), format: format).image { context in
      context.cgContext.scaleBy(x: Double(width)/physical.width, y: Double(height)/physical.height)
      for layer in layers.images { UIImage(cgImage: layer.image).draw(in: layer.frame) }
    }
    guard let bitmap = pixels.cgImage else { throw SceneRenderError.resourceLimit }
    let image = UIImage(cgImage: bitmap, scale: Double(width)/physical.width, orientation: .up)
    withExtendedLifetime(layers.retained) {}
    guard let raster = DocumentSnapshotCache.shared.storeAndRetain(image: image, documentID: documentID,
      token: token, layout: layout, reservation: reservation, resources: resources) else { throw SceneRenderError.resourceLimit }
    return raster
  }

  private func requiredScale(_ entry: Entry) -> Double {
    let physical = physicalSize(entry.input)
    if let width = entry.input.snapshotPixelWidth { return Double(width) / physical.width }
    guard let host = entry.host else { return 1 }
    return host.projectedPixelScale(for: physical)
  }
  private func requestedWidth(_ entry: Entry) -> Int {
    max(1, entry.input.snapshotPixelWidth ?? Int(ceil(physicalSize(entry.input).width * requiredScale(entry))))
  }

  /// Budget the complete capture, including its temporary paper and program
  /// layers, against the actual shared pool before asking WebKit for pixels.
  /// An existing native image remains pinned until the new image is installed.
  private func captureWidth(_ entry: Entry, includesPaperBacking: Bool = false) -> Int {
    let admission = resources.rasterAdmission
    let available = min(admission.byteLimit - admission.heldBytes,
      admission.passiveByteLimit - admission.pinnedBytes - admission.passiveReservedBytes)
    let physical = physicalSize(entry.input)
    let statuses = Set(pendingPlacements(on: entry).map(\.blockID))
    let slots = (source?.layout?.regions(on: entry.input.pageIndex) ?? []).filter { $0.kind == .program }.map { region in
      let runtime = programOwner.runtime(for: region.id)
      let hasStatus = statuses.contains(region.id)
      let capturesRuntime = runtime?.ready == true && (!hasStatus || (programOwner.paused(region.id) == nil
        && source?.program(region.id)?.sourceBasis == runtime?.sourceBasis
        && (programOwner.isRetiring(region.id) || programOwner.liveIDs.contains(region.id))))
      return (region: region, count: (hasStatus ? 1 : 0) + (capturesRuntime ? 1 : 0))
    }
    let pageCount = includesPaperBacking ? 2 : 1
    func cost(_ width: Int) -> Int {
      guard let page = SceneRenderResources.estimatedRasterBytes(pixelWidth: width,
        pixelHeight: Int(ceil(Double(width) * physical.height / physical.width))) else { return Int.max }
      return slots.reduce(page * pageCount) { sum, slot in
        sum + slot.count * (SceneRenderResources.estimatedRasterBytes(
          pixelWidth: max(1, Int(ceil(Double(width) * slot.region.frame.width / physical.width))),
          pixelHeight: max(1, Int(ceil(Double(width) * slot.region.frame.height / physical.width)))) ?? Int.max / 16)
      }
    }
    let count = slots.reduce(pageCount) { $0 + $1.count }
    guard available > 0, count <= admission.countLimit - admission.pinnedCount - admission.reservedCount else { return 0 }
    var lower = 0, upper = requestedWidth(entry)
    while lower < upper {
      let candidate = lower + (upper - lower + 1) / 2
      if cost(candidate) <= available { lower = candidate } else { upper = candidate - 1 }
    }
    return lower
  }

  private func picture(for entry: Entry) -> Picture? {
    guard let picture = pictures[entry.input.pageIndex], picture.token == entry.input.token else { return nil }
    return picture
  }

  private func needsPicture(_ entry: Entry) -> Bool {
    if requestsLivePaper(for: entry), !hasStagedPaper(for: entry) { return true }
    guard let picture = picture(for: entry), let image = picture.raster.image.cgImage else { return true }
    // Both axes are quantized by the snapshot API. Compare integral pixel
    // requirements, not a fractional scale that rounded pixels cannot reach.
    let wanted = requestedWidth(entry)
    if image.width >= wanted { return false }
    return captureWidth(entry) > image.width
  }

  private func hasTerminalFailure(for entry: Entry) -> Bool {
    terminalFailures.contains(entry.input.token)
  }

  private func show(_ error: Error, on entry: Entry) {
    let token = entry.input.token
    if error as? SceneRenderError == .resourceLimit { failures[token] = resources.rasterAdmission }
    else { terminalFailures.insert(token) }
    if NotebookNavigationObservation.enabled {
      let native = error as NSError
      let knownCase: String?
      switch error {
      case DocumentSessionError.invalidLayout: knownCase = "document_layout_invalid"
      case DocumentSessionError.inconsistentLayout: knownCase = "document_layout_inconsistent"
      case SceneRenderError.resourceLimit: knownCase = "resource_limit"
      case SceneRenderError.snapshotPending: knownCase = "snapshot_pending"
      case is CancellationError: knownCase = "cancelled"
      default: knownCase = nil
      }
      // Classification only: NSError.userInfo, descriptions and associated
      // source strings may contain document data and never enter this journal.
      NotebookNavigationObservation.recordDocument("document_page_preparation_failure",
        ownerID: installationID, documentID: documentID, fields: [
          "entryID": .string(entry.id.uuidString), "page": .number(Double(entry.input.pageIndex)),
          "isCurrent": .bool(entry.id == current?.id),
          "sourceKey": source.map { .string($0.message.key) } ?? .null,
          "preparationDemandID": preparationDemand.map { .string($0.id.uuidString) } ?? .null,
          "preparationTarget": preparationDemand.map { .number(Double($0.pageIndex)) } ?? .null,
          "errorType": .string(String(String(reflecting: type(of: error)).prefix(160))),
          "errorDomain": .string(String(native.domain.prefix(160))),
          "errorCode": .number(Double(native.code)),
          "errorCase": knownCase.map(JSONValue.string) ?? .null])
    }
    entry.input.measurements?.failed(documentID: documentID, pageIndex: entry.input.pageIndex,
      token: entry.input.token, message: error.localizedDescription)
    recordInstallation(on: entry)
    entry.input.onPreparationFailure(error)
    guard entries[entry.id] === entry, entry.input.token == token else { return }
    let retry: @MainActor () -> Void = { [weak self, weak entry] in
      guard let self, let entry, entries[entry.id] === entry, entry.input.token == token else { return }
      failures[entry.input.token] = nil; terminalFailures.remove(entry.input.token)
      if current?.id == entry.id, paper.acquisitionError != nil { paper.retryPreparation() }
      for id in source?.layout?.blockIDs(on: [entry.input.pageIndex]) ?? [] where programOwner.runtime(for: id)?.failure != nil {
        programOwner.retry(id)
      }
      entry.host?.removeFailure(); schedule()
    }
    let message = paper.retainsPreviousPrint
      ? "Исходник сохранён. Показана предыдущая сборка; текущую не удалось подготовить."
      : "Не удалось подготовить страницу. Можно повторить попытку."
    let kind: PageTurnPreparationFailure.Kind
    switch error {
    case SceneRenderError.resourceLimit: kind = .resourceLimit
    case SceneRenderError.snapshotPending: kind = .snapshotPending
    default: kind = .preparationFailed
    }
    entry.host?.showFailure(message, retry: retry)
    entry.input.onRenderReady.failed(.init(kind: kind, message: message, retry: retry))
  }
  private func retryAfterAdmission() {
    refreshResidentTurnFrames()
    let next = resources.rasterAdmission
    var recovered = false
    for (page, old) in failures where next.byteLimit - next.heldBytes > old.byteLimit - old.heldBytes
      || next.passiveByteLimit - next.pinnedBytes - next.passiveReservedBytes > old.passiveByteLimit - old.pinnedBytes - old.passiveReservedBytes {
      failures[page] = nil; recovered = true
    }
    if recovered || entries.values.contains(where: {
      $0.id != current?.id && failures[$0.input.token] == nil
        && !hasTerminalFailure(for: $0) && needsPicture($0)
    }) { schedule() }
  }
  private func stop() {
    guard !stopped, closingPrograms == nil else { return }
    guard programOwner.hasRuntimes else { finishStop(); return }
    let key = Key(documentID: documentID, resources: ObjectIdentifier(resources))
    Self.owners[key]?.closingValue = self
    closingPrograms = Task { @MainActor [self] in
      let saved = await programOwner.checkpointAll(resume: false)
      closingPrograms = nil
      guard !stopped, !Task.isCancelled else { return }
      if entries.isEmpty && openDocuments == 0 {
        if saved { finishStop() }
        // Failed persistence retains the same owner and admits explicit retry.
      } else {
        await programOwner.resumeAll()
        Self.owners[key]?.closingValue = nil
        schedule()
      }
    }
  }

  private func abortBootstrapPreparation() {
    guard !stopped else { return }
    closingPrograms?.cancel(); closingPrograms = nil
    finishStop()
  }

  private func finishStop() {
    observe("document_owner_stop", reason: "document_and_presentations_closed")
    stopped = true
    entries.values.forEach { $0.releaseTurnFrame() }
    programDemandTask?.cancel(); programDemandTask = nil; programDemandKey = nil; work?.cancel(); work = nil; captureTail?.cancel(); captureTail = nil
    paper?.invalidate(); passive?.invalidate(); programOwner.stop()
    paperTransfer = nil
    stagedPaper = nil
    pictures.removeAll(); passiveHost.removeFromSuperview()
    if let reclamationOwner { resources.unregisterReclamationOwner(reclamationOwner); self.reclamationOwner = nil }
    DocumentRenderRegistry.shared.revokeLive(hostID: installationID, through: installationGeneration)
    Self.owners[Key(documentID: documentID, resources: ObjectIdentifier(resources))] = nil
  }
  isolated deinit {
    observe("document_owner_deinit")
    DocumentRenderRegistry.shared.revokeLive(hostID: installationID, through: installationGeneration)
    programDemandTask?.cancel(); work?.cancel(); paper?.invalidate(); passive?.invalidate(); programOwner.stop()
    paperTransfer = nil
    if let admissionObserver { NotificationCenter.default.removeObserver(admissionObserver) }
    if let reclamationOwner { resources.unregisterReclamationOwner(reclamationOwner) }
    entries.values.forEach { $0.stopObserving(); $0.releaseTurnFrame() }
  }
}
#endif

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
  let onStateChange: (String, JSONValue) -> ContentFieldVersion?
  let onLinkActivation: (DocumentLinkActivation) -> Void
  let snapshotPixelWidth: Int?
  let onPreparationFailure: (Error) -> Void
  var onStateCheckpoint: (String, JSONValue, ContentFieldVersion, ContentFieldVersion?) async throws -> ContentFieldVersion? = { _, _, _, _ in nil }
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
  @MainActor private final class Entry {
    let id: UUID
    weak var host: DocumentWebHost?
    var input: DocumentPagePresentation
    var activity: PageTurnActivity?
    var activityObserver: UUID?
    var preparationObserver: UUID?
    var requiresPreparation: Bool {
      input.retainsOpenDocument || (input.isVisible && host?.window != nil)
    }
    private var readiness: Bool?
    private weak var readinessHandler: PageTurnReadiness?
    init(id: UUID, input: DocumentPagePresentation, host: DocumentWebHost) {
      self.id = id; self.input = input; self.host = host
    }
    func stopObserving() {
      if let activityObserver { activity?.removeObserver(activityObserver) }
      if let preparationObserver { activity?.removePreparationObserver(preparationObserver) }
      activityObserver = nil; preparationObserver = nil; activity = nil
    }
    func publishReadiness(_ value: Bool) {
      guard readiness != value || readinessHandler !== input.onRenderReady else { return }
      readiness = value; readinessHandler = input.onRenderReady; input.onRenderReady(value)
    }
    isolated deinit { stopObserving() }
  }
  private struct Picture {
    let token: String
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

  static func retryRetiringPrograms(resources: SceneRenderResources = .shared) {
    for entry in Array(owners.values) {
      if let owner = entry.closingValue, owner.resources === resources { owner.stop() }
    }
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
    return "current=\(String(describing: owner.current?.id)) mounted=\(String(describing: owner.mountedID)) entries=\(entries) paperPage=\(String(describing: owner.paper.payload?.pageIndex)) canonical=\(owner.paper.hasCanonicalPixels) paper=\(path(owner.paper.webView)) paperToken=\(owner.paper.payload?.renderToken ?? "nil") currentToken=\(owner.current?.input.token ?? "nil") work=\(String(describing: owner.workID)) needsWork=\(owner.needsWork) passivePage=\(String(describing: owner.passive?.payload?.pageIndex)) gesture=\(owner.gestureLocked) focused=\(owner.programOwner.hasFocus) terminal=\(owner.terminalFailures.keys.sorted()) pressure=\(owner.failures.keys.sorted())"
  }

  /// Submission freezes the installed native paper and all clipped program
  /// surfaces together before yielding the main actor. It does not wait for a
  /// neighboring snapshot or ask a program to render a later frame.
  static func capturePresented(documentID: UUID, pageIndex: Int, token: String, region: PageRect,
    resources: SceneRenderResources = .shared) throws -> NotebookSubmittedPixels? {
    guard let owner = owners[Key(documentID: documentID, resources: ObjectIdentifier(resources))]?.value,
      let entry = owner.current, entry.input.pageIndex == pageIndex, entry.input.token == token,
      owner.mountedID == entry.id, let host = entry.host, host.window != nil, !host.hasSnapshot,
      owner.paper.hasCanonicalPixels, !owner.gestureLocked,
      owner.programsReady(on: pageIndex, scope: .region(region)), owner.isInstalled(entry) else { return nil }
    let pixels = try NotebookSubmittedPixels.capture(view: host,
      physicalSize: owner.physicalSize(entry.input), region: region, resources: resources)
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
  private let programOwner: DocumentProgramOwner
  private var contacts: Set<String> = []
  private var pictures: [Int: Picture] = [:]
  private var failures: [String: SceneRasterAdmission] = [:]
  private enum FailureScope { case paper, composite }
  private var terminalFailures: [String: FailureScope] = [:]
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
        current.input.document.sourceVersion(blockID: block) == version,
        let origin = paper.currentLinkOrigin, let layout = origin.source.layout,
        origin.source.matches(current.input.document), origin.pageIndex == current.input.pageIndex,
        layout.blockIDs(on: [origin.pageIndex]).contains(block),
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
    let renderer = DocumentWebCoordinator(resources: resources, onRenderReady: .init { _ in },
      onPageLayout: { _ in },  onStateChange: { _, _ in nil })
    bindPaper(renderer)
    return renderer
  }

  private func bindPaper(_ renderer: DocumentWebCoordinator) {
    renderer.externallyHostedPrograms = true
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
    if let existing = entries[id] { entry = existing; entry.input = input; entry.host = host }
    else { entry = Entry(id: id, input: input, host: host); entries[id] = entry }
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
      entry.preparationObserver = entry.activity?.observePreparation { [weak self] in
        self?.refreshPreparationDemand()
      }
    }
    host.onContactChange = { [weak self] active in self?.contact("paper:\(id)", active: active) }
    host.programOverlay.onContactChange = { [weak self] block, active in self?.contact(block, active: active) }
    host.onSizeChange = { [weak self] in self?.schedule() }
    host.onWindowChange = { [weak self] in self?.hostAttachmentChanged(id) }
    if mountedID != id, entry.requiresPreparation {
      let geometry = WorkspaceItemGeometry.document(input.document.paperSize)
      host.configure(size: .init(width: geometry.width, height: geometry.height), interactive: false)
      if hasStagedPaper(for: entry) { entry.publishReadiness(true) }
      else if requestsLivePaper(for: entry) {
        entry.publishReadiness(false)
      }
      else if let picture = picture(for: entry) { host.installSnapshot(picture.raster); entry.publishReadiness(true) }
      else { host.showLoading(); entry.publishReadiness(false) }
    }
    if entry.requiresPreparation { source?.retainPage(input.pageIndex, hostID: id) }
    else {
      // UIKit can retain a closed overview. Its native attachment, not deinit,
      // owns thumbnail demand and pins; off-window RAF cannot hold up a reader.
      source?.releasePage(hostID: id, in: nil)
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
    entry.stopObserving(); entry.host?.onContactChange = { _ in }; entry.host?.onSizeChange = { }
    entry.host?.onWindowChange = { }
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
    failures = failures.filter { requestedTokens.contains($0.key) }
    terminalFailures = terminalFailures.filter { requestedTokens.contains($0.key) }
  }

  /// UIKit's adjacent controllers can remain mounted without being displayed.
  /// Their snapshots are preparation, while the current/turn/contact surface
  /// remains mandatory. The host still owns every installed image lease.
  private func reclamationCandidates() -> [SceneResourceReclamationCandidate] {
    guard !stopped, !gestureLocked else { return [] }
    return pictures.compactMap { page, picture in
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
      entry.host?.removeFallback(); entry.publishReadiness(false)
    }
    pictures[page] = nil
    observe("document_picture_reclaimed", page: page, reason: "not_displayed_or_accepting_input")
  }

  private func schedule() {
    guard !stopped else { return }
    resources.reclamationOffersChanged()
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
            entries[entry.id] === entry, entry.input.token == attemptedToken { show(error, on: entry) }
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
      try await paper.awaitPresentation(token: input.paperToken)
    } else if current == nil, source == nil {
      let renderer = passiveRenderer(in: host, input: input)
      configure(renderer, input: input, page: input.pageIndex)
      renderer.mount(in: passiveHost, physicalSize: physicalSize(input), isInteractive: false, priority: .visible)
      try await renderer.awaitPresentation(token: input.paperToken)
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
      if !requestsLivePaper(for: candidate), !programsReady(on: candidate.input.pageIndex) {
        let ids = layout.blockIDs(on: [candidate.input.pageIndex])
        if let error = ids.compactMap({ programOwner.runtimes[$0]?.failure }).first {
          show(error, on: candidate, scope: .composite)
        }
        continue
      }
      let token = candidate.input.token
      let measurements = candidate.input.measurements
      var landingTrace: DocumentPagePreparationTrace?
      let preparingOperation = workID
      do {
        let renderer = passiveRenderer(in: host, input: candidate.input)
        observe("passive_page_prepare_start", entryID: candidate.id, page: candidate.input.pageIndex, renderer: renderer)
        configure(renderer, input: candidate.input, page: candidate.input.pageIndex)
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
        try await renderer.awaitPresentation(token: candidate.input.paperToken)
        observe("passive_page_canonical_ready", entryID: candidate.id, page: candidate.input.pageIndex, renderer: renderer)
        if let liveDemand {
          try Task.checkCancellation()
          guard preparationDemand == liveDemand, entries[candidate.id] === candidate, candidate.input.token == token,
            candidate.host === preparationHost else { throw CancellationError() }
          stagedPaper = .init(entryID: candidate.id, token: token, demandID: liveDemand.id)
          passiveStage = .staged
          preparationHost.installProgramOverlay()
          _ = preparationHost.programOverlay.present([], paperSize: physicalSize(candidate.input), interactive: false)
          preparationHost.programOverlay.presentPending(layout.regions(on: candidate.input.pageIndex).compactMap { region in
            guard source?.programIDs.contains(region.id) == true else { return nil }
            return .init(blockID: region.id, rect: .init(x: region.frame.x, y: region.frame.y,
              width: region.frame.width, height: region.frame.height), message: "Подготовка программы…")
          })
          preparationHost.removeFallback(); preparationHost.removeLoading(); preparationHost.removeFailure()
          measurements?.observeLanding(landingTrace, stage: .completed)
          observe("document_live_target_prepared", entryID: candidate.id, page: candidate.input.pageIndex, renderer: renderer)
          candidate.publishReadiness(true)
          return
        }
        passiveStage = .capturing
        measurements?.observeLanding(landingTrace, stage: .capturing)
        let raster = try await capture(candidate, using: renderer)
        measurements?.observeLanding(landingTrace, stage: .completed)
        observe("passive_page_capture_finished", entryID: candidate.id, page: candidate.input.pageIndex, renderer: renderer)
        guard candidate.input.token == token, entries[candidate.id] === candidate else { raster.release(); continue }
        pictures[candidate.input.pageIndex] = Picture(token: token, raster: raster)
        offerPassiveRenderer(renderer)
        candidate.host?.installSnapshot(raster); candidate.host?.removeFailure(); candidate.publishReadiness(true)
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
    let geometry = WorkspaceItemGeometry.document(input.document.paperSize)
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

  private func configure(_ renderer: DocumentWebCoordinator, input: DocumentPagePresentation, page: Int) {
    renderer.programStore = input.programStore
    renderer.update(document: input.document, state: input.state, selectedPageIndex: page, capturesSnapshot: false,
      onRenderReady: .init { _ in }, onPageLayout: { [weak self] layout in
        self?.entries.values.forEach { $0.input.onPageLayout(layout) }
      },  onStateChange: { _, _ in nil },
      onLinkActivation: input.onLinkActivation,
      preparationRequestID: input.measurements?.preparationRequestID(documentID: documentID, pageIndex: page, token: input.token))
    if source !== renderer.payload?.source {
      for entry in entries.values { source?.releasePage(hostID: entry.id, in: nil) }
      source = renderer.payload?.source
    }
    for entry in entries.values where entry.requiresPreparation {
      source?.retainPage(entry.input.pageIndex, hostID: entry.id)
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
          rect.intersects(CGRect(x: region.frame.x, y: region.frame.y, width: region.frame.width, height: region.frame.height))
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
    var densities: [String: Double] = [:]
    for entry in entries.values where entry.requiresPreparation {
      for id in layout.blockIDs(on: [entry.input.pageIndex]) {
        densities[id] = max(densities[id] ?? 0, requiredScale(entry))
      }
    }
    programOwner.update(input: input, layout: layout, pages: pages,
      currentPage: current?.input.pageIndex, visibleIDs: visiblePrograms(), preparationPage: preparationDemand?.pageIndex,
      blocked: gestureLocked, contacts: contacts, densities: densities)
    if !hiddenOpenPaper { programOwner.resumeFromReturn() }
  }

  private func installPrograms(on entry: Entry) {
    guard let host = entry.host, let layout = source?.layout, paper.renderIsReady,
      paper.payload?.renderToken == entry.input.paperToken else { return }
    CATransaction.begin(); CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    refreshMountedInput()
    let currentIDs = layout.blockIDs(on: [entry.input.pageIndex])
    host.installProgramOverlay()
    for (id, runtime) in programOwner.runtimes where !currentIDs.contains(id) {
      if let web = runtime.webView { host.programOverlay.park(web, fullSize: web.bounds.size) }
    }
    let placements = placements(on: entry)
    let passive = passivePlacements(on: entry)
    guard host.programOverlay.present(placements, paperSize: physicalSize(entry.input), interactive: entry.input.isInteractive, passive: passive) else { return }
    host.programOverlay.presentPending(layout.regions(on: entry.input.pageIndex).compactMap { region in
      guard source?.programIDs.contains(region.id) == true else { return nil }
      let id = region.id, runtime = programOwner.runtimes[id]
      let message: String, actionTitle: String, action: (() -> Void)?
      if programOwner.retiringIDs.contains(id) {
        message = "Сохраняем состояние программы…"; actionTitle = ""; action = nil
      } else if runtime?.failure != nil || programOwner.pauseFailures[id] != nil {
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
    })
    paper.preservesFallback = false; host.removeFallback(); host.removeLoading(); host.removeFailure()
    refreshMountedInput()
    entry.publishReadiness(true)
    installationGeneration &+= 1
    let installedToken = entry.input.token
    let installation = host.programOverlay.installation(for: placements, paperSize: physicalSize(entry.input), passive: passive)
    let isInstalled: @MainActor (DocumentPresentationScope) -> Bool = { [weak self, weak host, weak entry] scope in
        guard let self, let host, let entry else { return false }
        return current?.id == entry.id && entry.input.token == installedToken
          && paper.payload?.renderToken == entry.input.paperToken && mountedID == entry.id && host.window?.isKeyWindow == true
          && !host.hasSnapshot && paper.hasCanonicalPixels && programsReady(on: entry.input.pageIndex, scope: scope)
          && installation.isInstalled
      }
    DocumentRenderRegistry.shared.publishLive(documentID: documentID, token: installedToken,
      pageIndex: entry.input.pageIndex, hostID: installationID, generation: installationGeneration,
      feedback: { [weak self] episodes in self?.paper.setAgentFeedback(episodes) }, isAttached: isInstalled)
    if let measurements = entry.input.measurements, measurements.enabled {
      if NotebookNavigationObservation.enabled {
        observe("document_content_published", entryID: entry.id, page: entry.input.pageIndex,
          reason: "installed=\(isInstalled(.page)), nativeInput=\(paper.nativeInputIsReady(in: host))")
      }
      measurements.contentReady(documentID: documentID, pageIndex: entry.input.pageIndex, token: installedToken,
        sourcePreparationPhasesMS: source?.preparationPhasesMS ?? [:], sourcePreparationMeasurement: source?.measurementCount,
        pagePreparation: paper.pagePreparationTrace)
      var observedInstallation: Bool?
      measurements.observeInstallation(documentID: documentID, pageIndex: entry.input.pageIndex, token: installedToken,
        isInstalled: { [weak self, weak entry, weak host] in
          guard let self, let entry, let host else { return false }
          let installed = isInstalled(.page) && entry.input.isInteractive && !self.gestureLocked
            && self.paper.nativeInputIsReady(in: host)
          if NotebookNavigationObservation.enabled, observedInstallation != installed {
            observedInstallation = installed
            self.observe("document_input_installation_observed", entryID: entry.id, page: entry.input.pageIndex,
              reason: installed ? "ready" : Self.presentationDiagnostic(documentID: self.documentID, resources: self.resources))
          }
          return installed
        }, publish: { [weak host] value in host?.accessibilityValue = value })
    }
  }

  private func placements(on entry: Entry) -> [DocumentProgramPlacement] {
    guard let layout = source?.layout else { return [] }
    return layout.regions(on: entry.input.pageIndex).compactMap { region in
      guard let runtime = programOwner.runtimes[region.id], runtime.ready,
        programOwner.liveIDs.contains(region.id) || programOwner.retiringIDs.contains(region.id),
        let web = runtime.webView else { return nil }
      return .init(blockID: region.id, webView: web,
        rect: .init(x: region.frame.x, y: region.frame.y, width: region.frame.width, height: region.frame.height),
        sourceOffset: region.sourceOffset, fullSize: web.bounds.size,
        allowsInteraction: !programOwner.retiringIDs.contains(region.id) && programOwner.pauseFailures[region.id] == nil)
    }
  }

  private func passivePlacements(on entry: Entry) -> [DocumentProgramPassivePlacement] {
    guard let layout = source?.layout else { return [] }
    return layout.regions(on: entry.input.pageIndex).compactMap { region in
      if programOwner.runtimes[region.id]?.ready == true,
        programOwner.liveIDs.contains(region.id) || programOwner.retiringIDs.contains(region.id) { return nil }
      guard let saved = programOwner.paused(region.id),
        let block = entry.input.document.blocks.first(where: { $0.id == region.id }) else { return nil }
      return .init(blockID: region.id, raster: saved.raster,
        rect: .init(x: region.frame.x, y: region.frame.y, width: region.frame.width, height: region.frame.height),
        sourceOffset: region.sourceOffset, fullSize: .init(width: region.frame.width, height: block.height))
    }
  }

  private func isInstalled(_ entry: Entry) -> Bool {
    guard let host = entry.host, mountedID == entry.id,
      paper.payload?.renderToken == entry.input.paperToken else { return false }
    return host.programOverlay.isPresenting(placements(on: entry), paperSize: physicalSize(entry.input), passive: passivePlacements(on: entry))
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
        CGRect(x: 0, y: 0, width: layout.width, height: layout.height).contains(crop) else { return false }
      return layout.regions(on: page).filter { source.programIDs.contains($0.id)
        && crop.intersects(CGRect(x: $0.frame.x, y: $0.frame.y, width: $0.frame.width, height: $0.frame.height))
      }.allSatisfy { programOwner.presents($0.id) }
    case .page: return layout.blockIDs(on: [page]).intersection(source.programIDs).allSatisfy { programOwner.presents($0) }
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

  private func capturePixels(_ entry: Entry, using renderer: DocumentWebCoordinator) async throws -> RasterLease {
    guard let layout = source?.layout, programsReady(on: entry.input.pageIndex) else { throw SceneRenderError.snapshotPending("document_program") }
    let input = entry.input, token = input.token, physical = physicalSize(input)
    let width = captureWidth(entry)
    guard width > 0 else { throw SceneRenderError.resourceLimit }
    let hasPrograms = !layout.blockIDs(on: [input.pageIndex]).intersection(source?.programIDs ?? []).isEmpty
    let liveRegions = layout.regions(on: input.pageIndex).compactMap { region -> (DocumentBlockRegion, DocumentBlockRuntime)? in
      guard let runtime = programOwner.runtimes[region.id], runtime.ready else { return nil }
      return (region, runtime)
    }
    let pageHeight = Int(ceil(Double(width) * physical.height / physical.width))
    let baseSize = renderer.webView?.bounds.size ?? physical
    var sizes = [(width: width, height: max(pageHeight, Int(ceil(Double(width) * baseSize.height / baseSize.width))))]
    for (region, runtime) in liveRegions {
      let pixels = max(1, Int(ceil(Double(width) * region.frame.width / physical.width)))
      sizes.append((pixels, Int(ceil(Double(pixels) * min(region.frame.height, runtime.block.height - region.sourceOffset) / runtime.blockWidth))))
    }
    if hasPrograms { sizes.append((width, pageHeight)) }
    guard let reservations = resources.reserveRasterBatch(sizes) else { throw SceneRenderError.resourceLimit }
    defer { reservations.forEach { $0.release() } }
    let base = try await renderer.retainPreparedSnapshot(pixelWidth: width, force: true, reservation: reservations[0])
    renderer.releasePreparedSnapshot()
    guard !Task.isCancelled, !stopped, entry.input.token == token, renderer.payload?.renderToken == entry.input.paperToken else {
      base.release(); throw CancellationError()
    }
    if !hasPrograms { return base }
    defer { base.release() }
    var layers: [(DocumentBlockRegion, RasterLease, Bool)] = []
    defer { layers.forEach { $0.1.release() } }
    for region in layout.regions(on: input.pageIndex) {
      if let index = liveRegions.firstIndex(where: { $0.0 == region }) {
        let runtime = liveRegions[index].1
        let image = try await runtime.capture(sourceOffset: region.sourceOffset, height: min(region.frame.height, runtime.block.height - region.sourceOffset),
          pixelWidth: sizes[index + 1].width, reservation: reservations[index + 1])
        layers.append((region, image, false))
      } else if let image = programOwner.paused(region.id)?.raster.retainedCopy() {
        layers.append((region, image, true))
      }
    }
    try Task.checkCancellation()
    guard entry.input.token == token, renderer.payload?.renderToken == entry.input.paperToken else { throw CancellationError() }
    let reservation = reservations[reservations.count - 1]
    let format = UIGraphicsImageRendererFormat(); format.scale = Double(width) / physical.width; format.opaque = true
    let image = UIGraphicsImageRenderer(size: physical, format: format).image { context in
      base.image.draw(in: .init(origin: .zero, size: physical))
      for (region, raster, fullProgram) in layers {
        let rect = CGRect(x: region.frame.x, y: region.frame.y, width: region.frame.width, height: region.frame.height)
        context.cgContext.saveGState(); context.cgContext.clip(to: rect)
        if fullProgram {
          raster.image.draw(in: .init(x: rect.minX, y: rect.minY - region.sourceOffset,
            width: rect.width, height: input.document.blocks.first(where: { $0.id == region.id })?.height ?? raster.image.size.height))
        } else { raster.image.draw(in: rect) }
        context.cgContext.restoreGState()
      }
    }
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
  private func captureWidth(_ entry: Entry) -> Int {
    let admission = resources.rasterAdmission
    let available = min(admission.byteLimit - admission.heldBytes,
      admission.passiveByteLimit - admission.pinnedBytes - admission.passiveReservedBytes)
    let physical = physicalSize(entry.input)
    let allProgramRegions = source?.layout?.regions(on: entry.input.pageIndex).filter {
      source?.programIDs.contains($0.id) == true
    } ?? []
    let programRegions = allProgramRegions.filter { programOwner.runtimes[$0.id]?.ready == true }
    func cost(_ width: Int) -> Int {
      guard let page = SceneRenderResources.estimatedRasterBytes(pixelWidth: width,
        pixelHeight: Int(ceil(Double(width) * physical.height / physical.width))) else { return Int.max }
      if allProgramRegions.isEmpty { return page }
      return programRegions.reduce(page * 2) { sum, region in
        sum + (SceneRenderResources.estimatedRasterBytes(
          pixelWidth: max(1, Int(ceil(Double(width) * region.frame.width / physical.width))),
          pixelHeight: max(1, Int(ceil(Double(width) * region.frame.height / physical.width)))) ?? Int.max / 16)
      }
    }
    let count = programRegions.count + (allProgramRegions.isEmpty ? 1 : 2)
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
    switch terminalFailures[entry.input.token] {
    case .paper: return true
    case .composite: return entry.id != current?.id && !requestsLivePaper(for: entry) && !programsReady(on: entry.input.pageIndex)
    case nil: return false
    }
  }

  private func show(_ error: Error, on entry: Entry, scope: FailureScope = .paper) {
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
    entry.input.onPreparationFailure(error)
    if error as? SceneRenderError == .resourceLimit { failures[entry.input.token] = resources.rasterAdmission }
    else { terminalFailures[entry.input.token] = scope }
    let token = entry.input.token
    let retry: @MainActor () -> Void = { [weak self, weak entry] in
      guard let self, let entry, entries[entry.id] === entry, entry.input.token == token else { return }
      failures[entry.input.token] = nil; terminalFailures[entry.input.token] = nil
      if current?.id == entry.id, paper.acquisitionError != nil { paper.retryPreparation() }
      for id in source?.layout?.blockIDs(on: [entry.input.pageIndex]) ?? [] where programOwner.runtimes[id]?.failure != nil {
        programOwner.retry(id)
      }
      entry.host?.removeFailure(); schedule()
    }
    let message = "Не удалось подготовить страницу. Можно повторить попытку."
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
    guard !programOwner.runtimes.isEmpty else { finishStop(); return }
    let key = Key(documentID: documentID, resources: ObjectIdentifier(resources))
    Self.owners[key]?.closingValue = self
    closingPrograms = Task { @MainActor [self] in
      let saved = await programOwner.checkpointAll(resume: false)
      closingPrograms = nil
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

  private func finishStop() {
    observe("document_owner_stop", reason: "document_and_presentations_closed")
    stopped = true; work?.cancel(); work = nil; captureTail?.cancel(); captureTail = nil
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
    work?.cancel(); paper?.invalidate(); passive?.invalidate(); programOwner.stop()
    paperTransfer = nil
    if let admissionObserver { NotificationCenter.default.removeObserver(admissionObserver) }
    if let reclamationOwner { resources.unregisterReclamationOwner(reclamationOwner) }
    entries.values.forEach { $0.stopObserving() }
  }
}
#endif

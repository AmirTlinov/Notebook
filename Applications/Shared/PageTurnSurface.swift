import SwiftUI
import Observation
import NotebookCore

#if os(iOS)
  import UIKit
#elseif os(macOS)
  import AppKit
#endif

private struct RendersSettledPageSnapshotKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  var rendersSettledPageSnapshot: Bool {
    get { self[RendersSettledPageSnapshotKey.self] }
    set { self[RendersSettledPageSnapshotKey.self] = newValue }
  }
}

/// A small callback object keeps render readiness outside durable page state.
/// Metal and WebKit report when their exact mounted page has presented once.
@Observable @MainActor
final class PageTurnActivity {
  private(set) var rasters = PageRasterPreparation()
  private var rasterPriority: (displayed: Int, target: Int?, ready: Bool)?
  func prioritizeRasters(displayed: Int, target: Int?, displayedContentReady: Bool = true) {
    rasterPriority = (displayed, target, displayedContentReady)
    rasters.prioritize(displayed: displayed, target: target, displayedContentReady: displayedContentReady)
  }
  func bindRasters(_ owner: PageRasterPreparation) {
    guard rasters !== owner else { return }; rasters = owner
    if let rasterPriority {
      owner.prioritize(displayed: rasterPriority.displayed, target: rasterPriority.target,
        displayedContentReady: rasterPriority.ready)
    }
  }
  struct PreparationDemand: Equatable {
    enum Presentation { case snapshot, live }
    let id: UUID
    let pageIndex: Int
    let presentation: Presentation
  }
  #if os(iOS)
  enum ElementFrameContent: Equatable { case raster, runtime, status }
  struct ElementFrameVersion: Equatable {
    let id: UUID
    let content: ElementFrameContent
  }
  enum ElementFrameAcquisition {
    case raster(RasterLease)
    case status(SceneRasterCut)
    case runtime(@MainActor (SceneAllocationPriority) async throws -> PageTurnElementFrame)
    var content: ElementFrameContent {
      switch self { case .raster: .raster; case .runtime: .runtime; case .status: .status }
    }
  }
  // Native installation/layout replaces these borrows. They are an addressed
  // registry, not view state: readiness is delivered by the installed owner.
  @MainActor private struct ElementFrameProvider {
    let owner: UUID
    let source: AgentElement
    let installation: SceneSourceInstallation
    // Sample the native receipt when its owner publishes. The old wrapper
    // reads today's hierarchy too, so it cannot remember a visibility edge.
    let isInstalled: Bool
    let version: ElementFrameVersion
    let acquisition: ElementFrameAcquisition?
    var current: Self {
      let available = acquisition != nil && installation.isInstalled
      return .init(owner: owner, source: source, installation: installation,
        isInstalled: available, version: version, acquisition: available ? acquisition : nil)
    }
  }
  @MainActor private struct ElementFrameCandidates {
    var raster: ElementFrameProvider?
    var status: ElementFrameProvider?
    var runtime: ElementFrameProvider?
    var published: ElementFrameProvider
    var installed: ElementFrameProvider? {
      if let status, status.acquisition != nil, status.installation.isInstalled { return status }
      if let runtime, runtime.acquisition != nil, runtime.installation.isInstalled { return runtime }
      if let raster, raster.acquisition != nil, raster.installation.isInstalled { return raster }
      return nil
    }
    func candidate(_ content: ElementFrameContent) -> ElementFrameProvider? {
      switch content { case .runtime: runtime; case .raster: raster; case .status: status }
    }
  }
  @ObservationIgnored private var elementFrames: [Int: [String: ElementFrameCandidates]] = [:]
  func installElementFrame(page: Int, element: String, owner: UUID, source: AgentElement,
    installation: SceneSourceInstallation, acquisition: ElementFrameAcquisition) {
    let content = acquisition.content
    let previous = elementFrames[page]?[element]
    let sameOwner = previous?.published.owner == owner && previous?.published.source == source
    let priorCandidate = sameOwner ? previous?.candidate(content) : nil
    // Installation wrappers are recreated by layout. Only a new accepted
    // source, native owner, raster or runtime replaces the borrowed material.
    let changed = priorCandidate?.installation.source != installation.source
      || priorCandidate?.installation.ownerIdentity != installation.ownerIdentity
      || priorCandidate?.installation.entryID != installation.entryID
      || priorCandidate?.installation.runtimeToken != installation.runtimeToken
      || priorCandidate?.installation.requiresVisibility != installation.requiresVisibility
    let isInstalled = installation.isInstalled
    // Loss can revoke only this exact native borrow. A detached predecessor
    // must not replace the raster/runtime which has already taken its place.
    guard isInstalled || (priorCandidate != nil && !changed) else { return }
    let candidate = ElementFrameProvider(owner: owner, source: source,
      installation: installation, isInstalled: isInstalled,
      version: changed ? .init(id: UUID(), content: content) : priorCandidate!.version,
      acquisition: isInstalled ? acquisition : nil)
    var candidates = sameOwner ? previous! : .init(published: candidate)
    switch content {
    case .runtime: candidates.runtime = candidate
    case .raster: candidates.raster = candidate
    case .status: candidates.status = candidate
    }
    candidates.status = candidates.status?.current
    candidates.runtime = candidates.runtime?.current
    candidates.raster = candidates.raster?.current
    // Keep both mounted owners through their handoff. A late bridge layout
    // cannot replace live pixels; runtime withdrawal selects an already
    // installed bridge without waiting for another layout of that bridge.
    let selected = candidates.installed ?? candidates.candidate(candidates.published.version.content) ?? candidate
    candidates.published = selected
    elementFrames[page, default: [:]][element] = candidates
    let materialChanged = previous?.published.version != selected.version
    guard materialChanged || previous?.published.isInstalled != selected.isInstalled else { return }
    for observer in Array(preparationObservers.values) {
      observer(.elementFrames(pageIndex: page, materialChanged: materialChanged))
    }
  }
  func removeElementFrame(page: Int, element: String, owner: UUID) {
    guard elementFrames[page]?[element]?.published.owner == owner else { return }
    elementFrames[page]?[element] = nil
    if elementFrames[page]?.isEmpty == true { elementFrames[page] = nil }
    for observer in Array(preparationObservers.values) {
      observer(.elementFrames(pageIndex: page, materialChanged: true))
    }
  }
  func remapElementFrames(_ indices: [Int: Int]) {
    elementFrames = Dictionary(uniqueKeysWithValues: elementFrames.compactMap { old, frames in
      indices[old].map { ($0, frames) }
    })
  }
  func retireElementFrames(at page: Int) { elementFrames[page] = nil }
  func acquireElementFrame(page: Int, source: AgentElement, priority: SceneAllocationPriority) async throws -> PageTurnElementFrame {
    guard let provider = elementFrames[page]?[source.id]?.installed, provider.source == source,
      let acquisition = provider.acquisition else { throw PageTurnMaterialUnavailable.changed }
    try Task.checkCancellation()
    let frame: PageTurnElementFrame
    switch acquisition {
    case .raster(let raster): frame = try Self.borrow(raster)
    case .status(let cut): frame = .init(cut: cut)
    case .runtime(let acquire): frame = try await acquire(priority)
    }
    guard elementFrameVersion(page: page, source: source) == provider.version else { throw PageTurnMaterialUnavailable.changed }
    return frame
  }
  /// The installed raster is already immutable. Borrow it in this actor turn;
  /// runtime pixels still require their accepted WebKit capture and fence.
  func borrowRasterElementFrame(page: Int, source: AgentElement) throws -> PageTurnElementFrame? {
    try Task.checkCancellation()
    guard let provider = elementFrames[page]?[source.id]?.installed, provider.source == source,
      let acquisition = provider.acquisition else { throw PageTurnMaterialUnavailable.changed }
    switch acquisition {
    case .raster(let raster): return try Self.borrow(raster)
    case .status(let cut): return .init(cut: cut)
    case .runtime: return nil
    }
  }
  private static func borrow(_ raster: RasterLease) throws -> PageTurnElementFrame {
    guard let retained = raster.retainedCopy() else { throw SceneRenderError.snapshotPending("page_element_pixels") }
    return .init(raster: retained)
  }
  func elementFrameVersion(page: Int, source: AgentElement) -> ElementFrameVersion? {
    guard let provider = elementFrames[page]?[source.id]?.installed, provider.source == source else { return nil }
    return provider.version
  }
  func hasElementFrame(page: Int, source: AgentElement) -> Bool {
    elementFrames[page]?[source.id]?.installed?.source == source
  }
  func hasUncroppedElementFrame(page: Int, source: AgentElement) -> Bool {
    guard let provider = elementFrames[page]?[source.id]?.installed, provider.source == source else { return false }
    return provider.installation.source.captureRegion == nil
  }
  #endif
  private(set) var isTransitioning = false
  private(set) var preparationDemand: PreparationDemand?
  private(set) var installedPreparation: PreparationDemand?
  @ObservationIgnored private var observers: [UUID: @MainActor (Bool) -> Void] = [:]
  enum PreparationChange {
    case demand
    case refine(pageIndex: Int)
    case stage(pageIndex: Int)
    case elementFrames(pageIndex: Int, materialChanged: Bool)
  }
  @ObservationIgnored private var preparationObservers: [UUID: @MainActor (PreparationChange) -> Void] = [:]

  /// The native page controller owns the one accepted landing still waiting
  /// for pixels. Repeated view updates preserve its identity; a new landing
  /// replaces it without making the currently installed page noninteractive.
  func prepare(_ pageIndex: Int?, presentation: PreparationDemand.Presentation = .snapshot) {
    guard preparationDemand?.pageIndex != pageIndex
      || (pageIndex != nil && preparationDemand?.presentation != presentation) else { return }
    preparationDemand = pageIndex.map { PreparationDemand(id: UUID(), pageIndex: $0, presentation: presentation) }
    for observer in Array(preparationObservers.values) { observer(.demand) }
  }

  @discardableResult
  func observePreparation(_ observer: @escaping @MainActor (PreparationChange) -> Void) -> UUID {
    let id = UUID(); preparationObservers[id] = observer; return id
  }

  func removePreparationObserver(_ id: UUID) { preparationObservers[id] = nil }

  /// The installed page prepares its actual native pose before a stationary
  /// opening consumes readiness. This does not replace the pending page demand.
  func refinePresentation(at pageIndex: Int) {
    for observer in Array(preparationObservers.values) { observer(.refine(pageIndex: pageIndex)) }
  }

  /// The curl endpoint has exposed this live host. Unlike layout refinement,
  /// this one visibility edge requests its actual OS presentation receipt.
  func stagePresentation(at pageIndex: Int) {
    for observer in Array(preparationObservers.values) { observer(.stage(pageIndex: pageIndex)) }
  }

  /// Native completion precedes the SwiftUI current-page update. Retain that
  /// exact prepared surface across the gap, not a guess based on host lifetime.
  func didInstall(_ demand: PreparationDemand?) {
    guard installedPreparation != demand else { return }
    installedPreparation = demand
    for observer in Array(preparationObservers.values) { observer(.demand) }
  }

  /// Native owners consult this value in the same event that accepts a curl.
  /// Publishing SwiftUI state later must not permit a capture or a reparent in
  /// the interval between accepting the gesture and updating the view tree.
  func update(_ value: Bool) {
    guard isTransitioning != value else { return }
    isTransitioning = value
    for observer in Array(observers.values) { observer(value) }
  }

  @discardableResult
  func observe(_ observer: @escaping @MainActor (Bool) -> Void) -> UUID {
    let id = UUID()
    observers[id] = observer
    return id
  }

  func removeObserver(_ id: UUID) { observers[id] = nil }
}

/// Terminal result of one admitted source/target pair. Native callbacks may
/// expose a Boolean landing result, but the operation preserves why it ended.
enum PageTurnOutcome: Equatable { case completed, cancelled, superseded, failed }

/// Navigation subscribes to the installed page's readiness edges. It owns its
/// subscription only while preparing that page; no display tick polls a reader.
@MainActor
final class PageTurnPreparationSource {
  private(set) var isRetired = false
  private var probe: (@MainActor (Bool) -> PageTurnPreparationState)?
  private var pageIdentity: (@MainActor () -> UUID?)?
  var currentPageID: UUID? { pageIdentity?() }
  private var observers: [UUID: @MainActor () -> Void] = [:]
  init(currentPageID: (@MainActor () -> UUID?)? = nil,
    _ probe: @escaping @MainActor (Bool) -> PageTurnPreparationState) {
    pageIdentity = currentPageID; self.probe = probe
  }
  func state(refinesDetails: Bool) -> PageTurnPreparationState { probe?(refinesDetails) ?? .waiting }
  @discardableResult func observe(_ changed: @escaping @MainActor () -> Void) -> UUID {
    let id = UUID(); observers[id] = changed; return id
  }
  func removeObserver(_ id: UUID) { observers[id] = nil }
  func changed() { for observer in Array(observers.values) { observer() } }
  func retire() {
    guard !isRetired else { return }
    isRetired = true; probe = nil; pageIdentity = nil; changed(); observers.removeAll()
  }
}

@MainActor
final class PageTurnReadiness {
  /// One host receipt distinguishes writable paper, complete content and its
  /// borrowable turn cut. Opening does not wait for programs; landing retains
  /// the complete visible-content boundary and its independent curl material.
  struct State: Equatable {
    let presented: Bool
    let capturable: Bool
    let paperReady: Bool
    init(presented: Bool, capturable: Bool, paperReady: Bool? = nil) {
      self.presented = presented; self.capturable = capturable
      self.paperReady = paperReady ?? presented
    }
    static let waiting = Self(presented: false, capturable: false)
  }
  private(set) var state = State.waiting
  private(set) var isRetired = false
  private(set) var materialRevision: UInt64 = 0
  #if DEBUG
  var presentationDiagnostic: (() -> String)?
  #endif
  enum AgentPreparationSource {
    case autonomous
    case notebook((@MainActor () -> NotebookPagePreparationWindow.NativeSource?)?)
  }
  private var agentPreparationSource: AgentPreparationSource
  private var agentPreparationMount: NotebookPagePreparationWindow.Mount?
  func acceptNotebookPage(_ pageID: UUID, from window: NotebookPagePreparationWindow) -> Bool {
    guard !isRetired else { return false }
    switch agentPreparationSource {
    case .autonomous: return true
    case .notebook(let source):
      _ = window.admissionRevision
      guard let source = source?(), let entry = window.entry(for: source, pageID: pageID) else { return false }
      borrowAgentPreparations(entry)
      return agentPreparationMount?.entry === entry
    }
  }
  var agentPreparations: PageAgentPreparationOwner? { agentPreparationMount?.entry.preparations }
  var notebookPageSource: NotebookPagePreparationWindow.Entry? { agentPreparationMount?.entry }
  func borrowAgentPreparations(_ entry: NotebookPagePreparationWindow.Entry) {
    guard !isRetired, let activity else { return }
    if agentPreparationMount?.entry !== entry {
      agentPreparationMount?.close(); agentPreparationMount = entry.borrow()
    }
    activity.bindRasters(entry.rasters)
    entry.preparations.bindPresentation(activity: activity, pageIndex: pageIndex)
  }
  let activity: PageTurnActivity?
  var pageIndex: Int
  var rasterContext: PageRasterPreparation.Context? {
    activity.map { .init(owner: $0.rasters, pageIndex: pageIndex) }
  }
  /// The native motion owns its live source and underlay, independently of next-page preparation.
  let isInActiveTurn: @MainActor () -> Bool
  private let handler: @MainActor (Bool) -> Void
  private let failureHandler: @MainActor (PageTurnPreparationFailure) -> Void
  private let materialChangedHandler: @MainActor () -> Void

  init(activity: PageTurnActivity? = nil, pageIndex: Int = 0,
    agentPreparationSource: AgentPreparationSource = .autonomous,
    isInActiveTurn: @escaping @MainActor () -> Bool = { false },
    onFailure: @escaping @MainActor (PageTurnPreparationFailure) -> Void = { _ in },
    onMaterialChanged: @escaping @MainActor () -> Void = {},
    _ handler: @escaping @MainActor (Bool) -> Void) {
    self.activity = activity
    self.agentPreparationSource = agentPreparationSource
    self.pageIndex = pageIndex
    self.isInActiveTurn = isInActiveTurn
    self.handler = handler
    failureHandler = onFailure
    materialChangedHandler = onMaterialChanged
  }

  #if os(iOS)
  var inkFrame: (@MainActor () -> InkCanvasView.AcceptedFrameLease?)?
  var inkFrameIsEmpty: (@MainActor () -> Bool)?
  var inkFrameIsReady: (@MainActor () -> Bool)?
  private var frameProvider: (@MainActor (SceneAllocationPriority) async throws -> PageTurnFrame)?
  func setFrameProvider(_ provider: @escaping @MainActor (SceneAllocationPriority) async throws -> PageTurnFrame) {
    guard !isRetired else { return }; frameProvider = provider
  }
  func acquireFrame(priority: SceneAllocationPriority = .passive) async throws -> PageTurnFrame {
    guard !isRetired, let frameProvider else { throw PageTurnMaterialUnavailable.changed }
    // The material owner validates its exact source/provider/ink cut. A wake
    // counter can change while that same cut remains installed or returns.
    let frame = try await frameProvider(priority)
    guard !isRetired else {
      NotebookNavigationObservation.onPageMaterialPreparation?("acquire_rejected_readiness_retired",
        frame.id, notebookPageSource?.pageID, frame.id, nil, CACurrentMediaTime())
      throw PageTurnMaterialUnavailable.changed
    }
    return frame
  }
  #endif

  func retire() {
    guard !isRetired else { return }
    isRetired = true; state = .waiting; materialRevision &+= 1
    #if DEBUG
    presentationDiagnostic = nil
    #endif
    agentPreparationMount?.close(); agentPreparationMount = nil
    if case .notebook = agentPreparationSource { agentPreparationSource = .notebook(nil) }
    #if os(iOS)
    frameProvider = nil; inkFrame = nil; inkFrameIsEmpty = nil; inkFrameIsReady = nil
    #endif
  }

  func callAsFunction(_ ready: Bool, capturable: Bool? = nil, paperReady: Bool? = nil) {
    guard !isRetired else { return }
    // A covered neighbour can have an immutable GPU cut before its live layer
    // receives an OS presentation. Only the landing uses the visible receipt.
    state = .init(presented: ready, capturable: capturable ?? ready, paperReady: paperReady)
    handler(ready)
  }

  func failed(_ failure: PageTurnPreparationFailure) { if !isRetired { failureHandler(failure) } }

  func materialDidChange() {
    guard !isRetired else { return }
    materialRevision &+= 1; materialChangedHandler()
  }

  /// Visibility can wake an accepted cut without replacing its pixels/source.
  func materialAvailabilityDidChange() {
    guard !isRetired else { return }; materialChangedHandler()
  }

  func captureFailed(_ failure: PageTurnPreparationFailure) {
    guard !isRetired else { return }
    failureHandler(.init(id: failure.id, kind: failure.kind, requiresCapture: true,
      message: failure.message, retry: failure.retry))
  }
}

/// Chooses the small set of live pages that must already have a first frame.
///
/// An adjacent turn keeps both immediate neighbours. Once a turn has a
/// direction, the page beyond its landing point is prepared during the turn,
/// rather than after the landing. This is the difference between a continuous
/// stack of paper and a stack that pauses to manufacture its next sheet.
enum PageTurnPrewarmWindow {
  static let capacity = 4

  static func indices(
    displayedIndex: Int,
    anticipatedIndex: Int?,
    lastDirection: Int?,
    pageCount: Int,
    existingIndices: Set<Int>,
    turningIndex: Int? = nil
  ) -> Set<Int> {
    guard pageCount > 0 else { return [] }
    var result = Set<Int>()
    insert(displayedIndex, pageCount: pageCount, into: &result)
    if let turningIndex { insert(turningIndex, pageCount: pageCount, into: &result) }

    // The page under the hand, its landing and the page beyond the landing
    // precede speculative neighbours, including for an explicit distant jump.
    if let anticipatedIndex {
      insert(anticipatedIndex, pageCount: pageCount, into: &result)
      let direction = sign(anticipatedIndex - displayedIndex)
      if direction != 0 {
        insert(
          anticipatedIndex + direction,
          pageCount: pageCount,
          into: &result
        )
      }
    } else if let lastDirection, sign(lastDirection) != 0 {
      insert(
        displayedIndex + sign(lastDirection) * 2,
        pageCount: pageCount,
        into: &result
      )
    }
    insert(displayedIndex - 1, pageCount: pageCount, into: &result)
    insert(displayedIndex + 1, pageCount: pageCount, into: &result)

    // Retain existing nearby content for a quick reverse, but spare capacity
    // is not a request to build more pages on a cold opening.
    for distance in 1..<capacity where result.count < min(capacity, pageCount) {
      for index in [displayedIndex - distance, displayedIndex + distance] where existingIndices.contains(index) {
        insert(index, pageCount: pageCount, into: &result)
      }
    }
    return result
  }

  private static func insert(
    _ index: Int,
    pageCount: Int,
    into result: inout Set<Int>
  ) {
    guard result.count < capacity, index >= 0, index < pageCount else { return }
    result.insert(index)
  }

  private static func sign(_ value: Int) -> Int {
    value == 0 ? 0 : (value > 0 ? 1 : -1)
  }
}

/// Keeps the page under the hand authoritative while its durable selection
/// catches up. Several quick landings may be acknowledged one by one; an old
/// acknowledgement must never pull the visible stack backwards.
struct PageTurnSelectionTracker {
  private(set) var displayedIndex: Int
  private var pendingLanding: Int?

  init(displayedIndex: Int) {
    self.displayedIndex = displayedIndex
  }

  var pendingIndex: Int? { pendingLanding }
  mutating func remap(to index: Int, pending: Int?) { displayedIndex = index; pendingLanding = pending }

  var awaitsLocalAcknowledgement: Bool {
    pendingLanding != nil
  }

  mutating func reset(to index: Int) {
    displayedIndex = index
    pendingLanding = nil
  }

  mutating func recordLocalLanding(at index: Int) {
    guard index != displayedIndex else { return }
    displayedIndex = index
    pendingLanding = index
  }

  /// Model publication acknowledges a landing; it never issues navigation.
  /// Old configurations cannot clear a newer landing or replay an old page.
  mutating func acknowledge(_ modelIndex: Int) {
    if modelIndex == pendingLanding { pendingLanding = nil }
  }
}

/// The only owner of a page turn. Notebook and document code provide pages and
/// accept a completed selection; they never animate or replace a page.
///
/// UIKit keeps the nearby live pages and owns the curl on iPad. Mac prepares
/// one non-interactive physical page for export; it has no page-turn runtime.
struct PageTurnSurface: View {
  @Environment(\.rendersSettledPageSnapshot) private var rendersSettledSnapshot

  let ownerID: UUID
  let sequenceRevision: String
  let pageCount: Int
  let selectedIndex: Int
  let allowsTrailingPageCreation: Bool
  let navigationIsEnabled: Bool
  let pageIsInteractive: Bool
  let canBeginNavigation: @MainActor () -> Bool
  let page:
    @MainActor (
      _ index: Int,
      _ isCurrent: Bool,
      _ readiness: PageTurnReadiness
    ) -> AnyView
  let onCommit: @MainActor (Int, String) -> Void
  let onTransitioningChange: @MainActor (Bool) -> Void
  var onReadinessProbe: (@MainActor (PageTurnPreparationSource) -> Void)? = nil
  var canonicalDocumentLayout: DocumentPageLayout? = nil
  var documentSelection: DocumentPageNavigationRequest? = nil
  var documentNavigation: DocumentPageNavigationCallbacks? = nil
  var notebookNavigation: NotebookPageNavigation? = nil
  var onWindowChange: @MainActor (Set<Int>, Int?, String, UUID) -> Void = { _, _, _, _ in }
  var inputGate: NotebookInputGate? = nil
  var pageIdentities: [Int: UUID] = [:]

  var body: some View {
    Group {
      #if DEBUG && os(iOS)
      if NotebookNavigationObservation.pageTurnDiagnosticsEnabled { surface }
      else { surface.accessibilityValue(pageAccessibilityValue) }
      #else
      surface.accessibilityValue(pageAccessibilityValue)
      #endif
    }
    .accessibilityIdentifier("page-turn-surface")
    // The page's activation point belongs to paper navigation. A container's
    // inferred child hit point can instead activate an embedded program.
    .accessibilityActivationPoint(.center)
    // Preparing paper behind the cover does not expose its controls to VoiceOver.
    .accessibilityHidden(!pageIsInteractive)
  }

  private var pageAccessibilityValue: String {
    documentNavigation != nil && canonicalDocumentLayout?.pageCount(for: sequenceRevision) == nil
      ? "Страница \(selectedIndex + 1), число страниц уточняется"
      : "Страница \(selectedIndex + 1) из \(max(1, pageCount))"
  }

  private var surface: some View {
    Group {
      #if os(macOS)
        page(clampedSelectedIndex, true, PageTurnReadiness { _ in })
          .environment(\.rendersSettledPageSnapshot, true)
          .allowsHitTesting(false)
      #else
      if rendersSettledSnapshot {
        page(
          clampedSelectedIndex,
          true,
          PageTurnReadiness { _ in }
        )
        .allowsHitTesting(false)
      } else {
        PlatformPageTurnSurface(
          ownerID: ownerID,
          sequenceRevision: sequenceRevision,
          pageCount: max(1, pageCount),
          selectedIndex: clampedSelectedIndex,
          allowsTrailingPageCreation: allowsTrailingPageCreation,
          navigationIsEnabled: navigationIsEnabled,
          pageIsInteractive: pageIsInteractive,
          canBeginNavigation: canBeginNavigation,
          page: page,
          onCommit: onCommit,
          onTransitioningChange: onTransitioningChange,
          onReadinessProbe:onReadinessProbe,
          canonicalDocumentLayout: canonicalDocumentLayout,
          documentSelection: documentSelection,
          documentNavigation: documentNavigation,
          notebookNavigation: notebookNavigation,
          onWindowChange: onWindowChange,
          inputGate: inputGate, pageIdentities: pageIdentities
        )
      }
      #endif
    }
  }

  private var clampedSelectedIndex: Int {
    min(max(0, selectedIndex), max(0, pageCount - 1))
  }
}

#if os(iOS)
  private struct PlatformPageTurnSurface: UIViewControllerRepresentable {
    let ownerID: UUID
    let sequenceRevision: String
    let pageCount: Int
    let selectedIndex: Int
    let allowsTrailingPageCreation: Bool
    let navigationIsEnabled: Bool
    let pageIsInteractive: Bool
    let canBeginNavigation: @MainActor () -> Bool
    let page:
      @MainActor (
        Int,
        Bool,
        PageTurnReadiness
      ) -> AnyView
    let onCommit: @MainActor (Int, String) -> Void
    let onTransitioningChange: @MainActor (Bool) -> Void
    let onReadinessProbe: (@MainActor (PageTurnPreparationSource) -> Void)?
    let canonicalDocumentLayout: DocumentPageLayout?
    let documentSelection: DocumentPageNavigationRequest?
    let documentNavigation: DocumentPageNavigationCallbacks?
    let notebookNavigation: NotebookPageNavigation?
    let onWindowChange: @MainActor (Set<Int>, Int?, String, UUID) -> Void
    let inputGate: NotebookInputGate?
    let pageIdentities: [Int: UUID]

    func makeUIViewController(context: Context) -> IPadPageTurnController {
      let controller = IPadPageTurnController()
      update(controller)
      return controller
    }

    func updateUIViewController(
      _ controller: IPadPageTurnController,
      context: Context
    ) {
      update(controller)
    }

    static func dismantleUIViewController(_ controller: IPadPageTurnController, coordinator: ()) {
      controller.uninstall()
    }

    private func update(_ controller: IPadPageTurnController) {
      controller.update(
        ownerID: ownerID,
        sequenceRevision: sequenceRevision,
        pageCount: pageCount,
        selectedIndex: selectedIndex,
        allowsTrailingPageCreation: allowsTrailingPageCreation,
        navigationIsEnabled: navigationIsEnabled,
        pageIsInteractive: pageIsInteractive,
        canBeginNavigation: canBeginNavigation,
        page: page,
        onCommit: onCommit,
        onTransitioningChange: onTransitioningChange,
        canonicalDocumentLayout: canonicalDocumentLayout,
        documentSelection: documentSelection,
        documentNavigation: documentNavigation,
        notebookNavigation: notebookNavigation,
        onWindowChange: onWindowChange,
        inputGate: inputGate, pageIdentities: pageIdentities
      )
      onReadinessProbe?(controller.preparationSource)
    }
  }
#endif

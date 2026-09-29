import Combine
import NotebookCore
import Observation
import SwiftUI

/// Accepted input and native execution belong to a retained physical page.
/// A SwiftUI shell borrows this state and reports its own installation only.
@Observable @MainActor
final class PreparedAgentElementPreparationOwner {
  struct RuntimePaintIdentity: Equatable {
    let loadToken: String
    let program: AgentProgramSource
  }
  struct PaintedRuntime: Equatable {
    let leaseID: UUID
    let program: AgentProgramSource
    let runtimeToken: String?
  }
  struct Demand: Equatable {
    let source: AgentElement
    let basis: NotebookProgramStateBasis?
    let active: Bool
    let inputEnabled: Bool
    let focused: Bool
    let permitsPreparation: Bool
    let policy: AgentSnapshotPolicy
    let capture: SceneSourceDemand?
    let fallbackEntryID: UUID?
    let runtimeFailure: AgentWebSourceFailure?
    var webPriority: WebPriority { active ? (inputEnabled && focused ? .input : .liveProgram) : .visible }
    func hasSamePreparation(as other: Self) -> Bool {
      source == other.source && basis == other.basis && active == other.active
        && permitsPreparation == other.permitsPreparation && policy == other.policy
        && capture == other.capture && fallbackEntryID == other.fallbackEntryID
        && runtimeFailure == other.runtimeFailure
        && (focused || permitsPreparation) == (other.focused || other.permitsPreparation)
    }
  }
  struct Configuration {
    weak var model: NotebookAppModel?
    let demand: Demand
    let focus: InteractiveElementReference
    weak var pageTurnActivity: PageTurnActivity?
    let rasterPreparation: PageRasterPreparation.Context?
    let cohort: SceneCompositionCohort?
    let onState: NotebookProgramStateWriter
  }
  @MainActor final class Consumer {
    weak var owner: PreparedAgentElementPreparationOwner?
    var onRenderReady: (Bool) -> Void = { _ in }
    var onFailure: (PageTurnPreparationFailure) -> Void = { _ in }
  }
  let pageFrameOwner = UUID()
  @ObservationIgnored private let resources: SceneRenderResources
  @ObservationIgnored private var configuration: Configuration?
  @ObservationIgnored private(set) var demand: Demand?
  @ObservationIgnored private var request: UUID?
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var interactionUpdate: Task<Void, Never>?
  @ObservationIgnored private var notifications: Set<AnyCancellable> = []
  @ObservationIgnored private weak var consumer: Consumer?
  @ObservationIgnored private var lastFailure: PageTurnPreparationFailure?
  @ObservationIgnored private(set) var isRetired = false
  @ObservationIgnored private var nativeRuntimeToken: String?
  private var paintedRuntime: PaintedRuntime?
  private(set) var session: AgentWebNativeSession?
  private(set) var raster: RasterLease?
  private(set) var web: WebSurfaceLease?
  private(set) var preparedSource: AgentElement?
  private(set) var liveProgram: AgentProgramSource?
  private var failedPaintRuntime: RuntimePaintIdentity?
  private var runtimeWasPresented = false
  @ObservationIgnored private var runtimeAddress: SceneSourceAddress?
  @ObservationIgnored private var runtimeLeaseID: UUID?
  private(set) var failure: String?
  private var failedSource: AgentElement?
  private var failedCapturePolicy: AgentSnapshotPolicy?
  @ObservationIgnored private var failedCaptureAdmission: SceneRasterAdmission?
  private var waitingForAdmission = false

  init(resources: SceneRenderResources = .shared) { self.resources = resources }

  /// Acceptance does not publish observed state during a SwiftUI transaction.
  /// A changed demand cancels only this owner's subscriber; submitted native
  /// work remains charged until its existing physical completion fence.
  func accept(_ configuration: Configuration) {
    guard !isRetired else { return }
    self.configuration = configuration
    guard demand != configuration.demand else { return }
    let previous = demand
    demand = configuration.demand
    if let previous, configuration.demand.hasSamePreparation(as: previous), !waitingForAdmission {
      // Input/focus changes reconfigure this accepted job. They do not replace
      // its queue position, timeout or in-flight passive WebKit capture.
      if let request { resources.updatePendingWebPriority(request, priority: configuration.demand.webPriority) }
      updateInteraction()
    } else { restart() }
  }
  private func updateInteraction() {
    guard interactionUpdate == nil else { return }
    let request = request
    interactionUpdate = Task { @MainActor [weak self] in
      guard let self, !Task.isCancelled, !self.isRetired, self.request == request else { return }
      defer { self.interactionUpdate = nil }
      guard let model = self.configuration?.model, model.shutdownPhase != .stopped,
        let demand = self.demand else { return }
      if let web = self.web, let session = self.session {
        web.updatePriority(demand.webPriority)
        self.runtimeView(web, session: session, basis: demand.basis).prepare()
      }
    }
  }
  func acceptSource(_ source: AgentElement, policy: AgentSnapshotPolicy) {
    guard !isRetired, let previous = configuration, let model = previous.model, let old = demand else { return }
    accept(.init(model: model,
      demand: .init(source: source, basis: model.programStateBasis(focus: previous.focus, rendered: source),
        active: old.active && source.requiresLiveRuntime, inputEnabled: old.inputEnabled, focused: old.focused,
        permitsPreparation: old.permitsPreparation, policy: policy, capture: old.capture,
        fallbackEntryID: old.fallbackEntryID, runtimeFailure: nil),
      focus: previous.focus, pageTurnActivity: previous.pageTurnActivity, rasterPreparation: previous.rasterPreparation,
      cohort: previous.cohort, onState: previous.onState))
  }
  /// Binding a physical consumer does not replace the accepted source or task.
  /// It happens before constructing its native shell and publishes no state.
  func bindPresentation(activity: PageTurnActivity, context: PageRasterPreparation.Context) {
    guard !isRetired, let previous = configuration else { return }
    configuration = .init(model: previous.model, demand: previous.demand, focus: previous.focus,
      pageTurnActivity: activity, rasterPreparation: context, cohort: previous.cohort, onState: previous.onState)
  }
  private func restart() {
    guard !isRetired, demand != nil else { return }
    interactionUpdate?.cancel(); interactionUpdate = nil
    task?.cancel(); let id = UUID(); request = id
    task = Task { @MainActor [weak self] in
      guard let self, self.request == id else { return }
      self.observeResourcesIfNeeded()
      await self.prepare()
      if self.request == id { self.task = nil }
    }
  }
  func waitForPreparation() async { await task?.value }
  func attach(_ consumer: Consumer) {
    guard !isRetired else { return }
    self.consumer = consumer; consumer.owner = self
    if let lastFailure { consumer.onFailure(lastFailure) }
  }
  func detach(_ consumer: Consumer) {
    guard self.consumer === consumer, consumer.owner === self else { return }
    self.consumer = nil; consumer.owner = nil; consumer.onRenderReady(false)
  }
  private func publishReady(_ ready: Bool) {
    guard !isRetired else { return }
    if ready { lastFailure = nil }
    if consumer?.owner === self { consumer?.onRenderReady(ready) }
  }
  private func publishFailure(_ failure: PageTurnPreparationFailure) {
    guard !isRetired else { return }
    lastFailure = failure
    if consumer?.owner === self { consumer?.onFailure(failure) }
  }
  func retryPreparation() {
    guard !isRetired, configuration?.model != nil else { return }
    if let address = sourceAddress, runtimeFailure != nil { model.compositionTiles.retrySource(address) }
    failedSource = nil; failure = nil; lastFailure = nil; restart()
  }
  private func observeResourcesIfNeeded() {
    guard notifications.isEmpty else { return }
    NotificationCenter.default.publisher(for: SceneRenderResources.didChange).sink { [weak self] note in
      let id = note.object as? String
      Task { @MainActor [weak self] in
        guard let self, !self.isRetired, id == self.demand?.source.id else { return }
        self.adoptPreparedRaster()
      }
    }.store(in: &notifications)
    NotificationCenter.default.publisher(for: SceneRenderResources.didGainRasterAdmission).sink { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self, !self.isRetired else { return }; self.retryAfterRasterAdmission()
      }
    }.store(in: &notifications)
    observeWebAdmission()
  }
  private func observeWebAdmission() {
    guard !isRetired else { return }
    withObservationTracking { _ = resources.webAdmissionGeneration } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self, !self.isRetired else { return }
        if self.waitingForAdmission { self.waitingForAdmission = false; self.restart() }
        self.observeWebAdmission()
      }
    }
  }
  func retire(afterUpdate: Bool = false) {
    guard !isRetired else { return }
    isRetired = true; request = nil; task?.cancel(); task = nil
    interactionUpdate?.cancel(); interactionUpdate = nil
    // Native ownership is revoked now. Observed presentation state may belong
    // to the SwiftUI update which removed this source, so its clearing waits
    // for that transaction while the existing checkpoint retains its writer.
    session?.retire(); retireRuntime()
    #if os(iOS)
    if let context = rasterPreparation {
      pageTurnActivity?.removeElementFrame(page: context.pageIndex, element: element.id, owner: pageFrameOwner)
    }
    #endif
    notifications.removeAll(); lastFailure = nil
    if afterUpdate {
      task = Task { @MainActor [self] in finishRetirement(); task = nil }
    } else { finishRetirement() }
  }
  private func finishRetirement() {
    if consumer?.owner === self { consumer?.onRenderReady(false); consumer?.owner = nil }; consumer = nil
    session = nil; web = nil; raster = nil; preparedSource = nil; liveProgram = nil
    nativeRuntimeToken = nil; paintedRuntime = nil; configuration = nil; demand = nil
  }
  isolated deinit { retire() }
  private func install(_ session: AgentWebNativeSession) {
    precondition(self.session == nil); self.session = session
  }
  private func retireSession() {
    let previous = session; session = nil; previous?.retire()
  }

  private var model: NotebookAppModel { configuration!.model! }
  var element: AgentElement { demand!.source }
  private var focus: InteractiveElementReference { configuration!.focus }
  private var pageTurnActivity: PageTurnActivity? { configuration?.pageTurnActivity }
  private var rasterPreparation: PageRasterPreparation.Context? { configuration?.rasterPreparation }
  var isActive: Bool { demand?.active == true }
  private var hasFocus: Bool { demand?.focused == true }
  var runtimeFailure: AgentWebSourceFailure? { demand?.runtimeFailure }
  var snapshotPolicy: AgentSnapshotPolicy { demand!.policy }
  var rasterSource: SceneRasterSource { snapshotPolicy.rasterSource(for: element) }
  var requiredScale: Double { snapshotPolicy.minimumScale(for: element) }
  private var sourceAddress: SceneSourceAddress? {
    guard case .board(let boardID, let id) = focus, let cohort = configuration?.cohort else { return nil }
    let addresses = cohort.sourceReceipts.keys.filter { $0.plane.boardID == boardID && $0.elementID == id }
    return addresses.count == 1 ? addresses.first : nil
  }

  var showsLiveProgram: Bool {
    web != nil && (isActive || runtimeWasPresented) && liveProgram == AgentProgramSource(element)
  }
  var hasPaintedLiveProgram: Bool {
    return nativeRuntimeToken != nil
      && paintedRuntime?.runtimeToken == nativeRuntimeToken
      && paintedRuntime?.leaseID == web?.id
      && paintedRuntime?.program == AgentProgramSource(element)
  }
  var bridgesFirstLivePaint: Bool {
    guard web != nil, !hasPaintedLiveProgram, preparedSource == element else { return false }
    if let failure = failedPaintRuntime, failure.program == AgentProgramSource(element),
      nativeRuntimeToken?.hasPrefix(failure.loadToken + "/") != false { return false }
    return raster?.image(for: rasterSource, minimumScale: requiredScale) != nil
  }
  var awaitsRasterSource: Bool {
    guard let installed = raster?.source.agentElement else { return true }
    // Refining the same source is not a content update. Keep its pixels quiet
    // while the independent density/crop demand still reports not-ready.
    return SceneRasterSource.agent(installed) != .agent(element)
  }

  func adoptPreparedRaster() {
    guard !isRetired, configuration?.model != nil, model.shutdownPhase != .stopped else { return }
    if let next = resources.retainRaster(for: rasterSource, minimumScale: requiredScale) {
      if raster?.entryID != next.entryID { raster = next }
      preparedSource = element
      if runtimeFailure == nil { failure = nil; failedSource = nil }
      if runtimeFailure != nil { publishReady(false) }
      // Acquiring pixels is not installing them. The native raster callback
      // below certifies the frame before a waiting page may begin its curl.
      return
    }
    if let raster, !ScenePreparedRasterFallback.hasValidGeometry(raster, for: element) { self.raster = nil }
    if raster == nil, let previous = ScenePreparedRasterFallback.retain(from: configuration?.cohort, focus: focus, for: element),
      ScenePreparedRasterFallback.hasValidGeometry(previous, for: element) {
      raster = previous
    }
    // The old source/crop or density remains unfinished work. In particular a
    // remounted portal cannot acknowledge the new demand using its predecessor.
    preparedSource = nil
    publishReady(false)
  }

  @MainActor private struct InstallationContext {
    let element: AgentElement
    let rasterSource: SceneRasterSource
    let requiredScale: Double
    let focus: InteractiveElementReference
    weak var pageTurnActivity: PageTurnActivity?
    let rasterPreparation: PageRasterPreparation.Context?
    let pageFrameOwner: UUID
    let cohort: SceneCompositionCohort?
    func record(_ installation: SceneSourceInstallation, raster: RasterLease? = nil) {
      guard let installedSource = installation.source.agentElement else { return }
      let isInstalled = installation.isInstalled
      if isInstalled { NotebookNavigationObservation.onSourceInstalled?(installation, .now) }
      #if os(iOS)
      if let pageTurnActivity, let context = rasterPreparation,
        !isInstalled || (installedSource == element
          && ((raster == nil && installation.runtimeToken != nil)
            || raster?.image(for: rasterSource, minimumScale: requiredScale) != nil)) {
        // The callback's native owner determines the borrow. During the first
        // live paint both views are mounted; a raster callback cannot certify
        // the runtime, even though the SwiftUI value already shows that runtime.
        // Withdrawal addresses its original native source, even when the view's
        // new demand needs different content or density. The registry alone
        // decides whether that exact candidate is still owned.
        let acquisition: PageTurnActivity.ElementFrameAcquisition
        if let raster { acquisition = .raster(raster) }
        else {
          acquisition = .runtime { [installation, element = installedSource, focus] priority in
            guard installation.isInstalled else { throw PageTurnMaterialUnavailable.changed }
            if priority == .input {
              guard let captured = try await AgentWebCoordinator.captureCurrentCut(focus: focus, element: element) else {
                guard installation.isInstalled else { throw PageTurnMaterialUnavailable.changed }
                throw SceneRenderError.snapshotPending("page_program_pixels")
              }
              return PageTurnElementFrame(cut: captured)
            }
            guard let captured = try await AgentWebCoordinator.captureCurrent(focus: focus, element: element) else {
              guard installation.isInstalled else { throw PageTurnMaterialUnavailable.changed }
              throw SceneRenderError.snapshotPending("page_program_pixels")
            }
            return PageTurnElementFrame(raster: captured)
          }
        }
        pageTurnActivity.installElementFrame(page: context.pageIndex, element: installedSource.id, owner: pageFrameOwner,
          source: installedSource, installation: installation, acquisition: acquisition)
      }
      #endif
      guard case .board(let boardID, let id) = focus, let cohort else { return }
      for address in cohort.sourceReceipts.keys where address.plane.boardID == boardID && address.elementID == id {
        if isInstalled, let raster, let demand = cohort.sourceReceipts[address]?.demand,
          raster.image(for: demand.rasterSource, minimumScale: demand.minimumScale) == nil { continue }
        cohort.didInstallSource(address, installation: installation)
      }
    }
  }

  private var installationContext: InstallationContext {
    .init(element: element, rasterSource: rasterSource, requiredScale: requiredScale,
      focus: focus, pageTurnActivity: pageTurnActivity, rasterPreparation: rasterPreparation,
      pageFrameOwner: pageFrameOwner, cohort: configuration?.cohort)
  }

  func rasterInstalled(_ installation: SceneSourceInstallation, raster installed: RasterLease) {
    guard !isRetired, configuration?.model != nil else { return }
    installationContext.record(installation, raster: installed)
    Task { @MainActor [weak self] in
      guard let self, !self.isRetired, installation.isInstalled, self.runtimeFailure == nil,
        self.raster?.entryID == installed.entryID, self.preparedSource == self.element,
        installed.image(for: self.rasterSource, minimumScale: self.requiredScale) != nil else { return }
      self.publishReady(true)
    }
  }

  func runtimeView(_ web: WebSurfaceLease, session: AgentWebNativeSession,
    basis: NotebookProgramStateBasis?) -> AgentWebElementView {
    let owner = self, model = model, element = element, focus = focus
    let policy = snapshotPolicy, source = rasterSource, scale = requiredScale
    let installationContext = installationContext, resources = resources
    return AgentWebElementView(element: element, stateBasis: basis, programOwner: model,
      allowsStateCommits: isActive && hasFocus, session: session, snapshotPolicy: policy,
      preparesPassiveSnapshot: !isActive || bridgesFirstLivePaint,
      showsContent: showsLiveProgram, focus: focus,
      onRenderReady: { [weak owner, weak model] ready in
        guard let owner, let model, !owner.isRetired, model.shutdownPhase != .stopped, owner.web?.id == web.id, !web.isReleased,
          let current = owner.demand, current.source == element else { return }
        if ready, let next = resources.retainRaster(for: source, minimumScale: scale) {
          if let address = owner.runtimeAddress { model.compositionTiles.runtimeSourceBecameReady(address, leaseID: web.id, source: element) }
          if owner.raster?.entryID != next.entryID { owner.raster = next }
          owner.preparedSource = element; owner.failure = nil; owner.failedSource = nil
          if !current.active && !owner.runtimeWasPresented {
            owner.retireRuntime(); owner.releaseWeb()
          }
        } else if !ready, owner.preparedSource != element { owner.publishReady(false) }
      }, onInteractionReady: { [weak owner, weak model] ready in
        guard let owner, let model, !owner.isRetired, model.shutdownPhase != .stopped, owner.web?.id == web.id, !web.isReleased else { return }
        let next = ready ? AgentProgramSource(element) : nil
        if owner.liveProgram != next { owner.liveProgram = next }
        if !ready { owner.nativeRuntimeToken = nil; owner.paintedRuntime = nil }
      }, onInteraction: { [weak owner, weak model] in
        guard let owner, let model, owner.demand?.active == true, owner.demand?.inputEnabled == true,
          owner.liveProgram == AgentProgramSource(element), owner.web?.id == web.id else { return }
        if model.interactiveElementFocus != focus { model.interactiveElementFocus = focus }
      }, onInstalled: { [weak owner] installation in
        guard let installed = installation.source.agentElement else { return }
        if !installation.isInstalled { installationContext.record(installation); return }
        guard let owner, !owner.isRetired,
          SceneRasterSource.agent(installed) == .agent(element),
          owner.demand?.active == true || owner.runtimeWasPresented,
          owner.web?.id == web.id, owner.liveProgram == AgentProgramSource(installed) else { return }
        installationContext.record(installation)
        Task { @MainActor [weak owner] in
          guard let owner, !owner.isRetired, installation.isInstalled, owner.web?.id == web.id,
            owner.liveProgram == AgentProgramSource(element) else { return }
          owner.nativeRuntimeToken = installation.runtimeToken
          if owner.demand?.active == true, !owner.runtimeWasPresented { owner.runtimeWasPresented = true }
          owner.publishReady(true)
        }
      }, onFramePainted: { [weak owner] installation in
        guard let owner, !owner.isRetired, owner.web?.id == web.id, !web.isReleased, installation.isInstalled,
          let installed = installation.source.agentElement,
          AgentProgramSource(installed) == AgentProgramSource(element) else { return }
        let receipt = PaintedRuntime(leaseID: web.id,
          program: AgentProgramSource(installed), runtimeToken: installation.runtimeToken)
        guard owner.paintedRuntime != receipt || owner.failedPaintRuntime != nil else { return }
        owner.nativeRuntimeToken = installation.runtimeToken; owner.paintedRuntime = receipt
        if owner.failedPaintRuntime != nil { owner.failedPaintRuntime = nil }
      }, onFailure: { [weak owner, weak model] event in
        guard let owner, let model, !owner.isRetired, model.shutdownPhase != .stopped, owner.web?.id == event.leaseID, web.id == event.leaseID,
          !web.isReleased, SceneRasterSource.agent(event.source) == .agent(element),
          let current = owner.demand, current.source == element,
          event.policy == nil || event.policy == policy else { return }
        owner.failedPaintRuntime = .init(loadToken: event.loadToken, program: AgentProgramSource(event.source))
        let owned = owner.runtimeAddress.map { model.compositionTiles.failRuntimeSource($0, failure: event) } ?? false
        switch event.diagnostic.kind {
        case "resource_limit": owner.failure = "Недостаточно ресурсов для изображения"
        case "load_error": owner.failure = "Не удалось загрузить схему"
        default: owner.failure = "Не удалось подготовить изображение"
        }
        owner.failedSource = owned ? nil : event.source
        owner.failedCapturePolicy = event.policy
        owner.failedCaptureAdmission = event.diagnostic.kind == "resource_limit" ? event.rasterAdmission : nil
        if event.policy == nil || !current.active || owner.liveProgram != AgentProgramSource(element) {
          owner.liveProgram = nil; owner.runtimeWasPresented = false
          owner.retireRuntime(); owner.releaseWeb()
        }
        owner.publishReady(false)
      }, onState: configuration!.onState)
  }

  private func releaseWeb() {
    retireSession()
    web = nil
  }

  @MainActor
  private func bindRuntime(_ lease: WebSurfaceLease, demand: Demand) {
    guard demand.active else { return }
    let address = model.compositionTiles.registerRuntimeSource(focus: focus, source: demand.source,
      policy: demand.policy, leaseID: lease.id, cohort: configuration?.cohort)
    if runtimeAddress != address || runtimeLeaseID != lease.id {
      retireRuntime(); runtimeAddress = address; runtimeLeaseID = address == nil ? nil : lease.id
    }
  }

  @MainActor
  private func retireRuntime() {
    if let runtimeAddress, let runtimeLeaseID {
      configuration?.model?.compositionTiles.retireRuntimeSource(runtimeAddress, leaseID: runtimeLeaseID)
    }
    runtimeAddress = nil; runtimeLeaseID = nil
  }

  func failureMessage(_ diagnostic: RenderDiagnostic) -> String {
    switch diagnostic.kind {
    case "resource_limit": "Недостаточно ресурсов для изображения"
    case "load_error": "Не удалось загрузить схему"
    default: "Не удалось подготовить изображение"
    }
  }

  @MainActor
  func retryAfterRasterAdmission() {
    // A mounted coordinator owns its submitted capture. Composition owns a
    // retired board producer; only a standalone retired consumer retries here.
    guard !isRetired, configuration?.model != nil, web == nil, failedSource == element,
      failedCapturePolicy == snapshotPolicy,
      let previous = failedCaptureAdmission else { return }
    let current = resources.rasterAdmission
    // A notification is only a wake-up. The failed source retries after a real
    // capacity improvement that admits its whole capture, never on its own
    // staging release or while the same impossible request remains unchanged.
    guard AgentWebSourceFailure.captureFitsAfterImprovement(source: element, policy: snapshotPolicy,
      previous: previous, current: current) else { return }
    failedSource = nil; failedCapturePolicy = nil; failedCaptureAdmission = nil
    failure = nil; restart()
  }

  @MainActor
  private func prepare() async {
    guard !Task.isCancelled, !isRetired, configuration?.model != nil, model.shutdownPhase != .stopped,
      let request, let demand else { return }
    let model = model, focus = focus, rasterPreparation = rasterPreparation
    waitingForAdmission = false
    if !demand.active, runtimeWasPresented, let retiring = web,
      liveProgram == AgentProgramSource(demand.source) {
      // Input has ended, but the same native pixels stay visible until their
      // current program frame is retained. No source job boots a second copy;
      // its keyed admission waits for this owner's final submitted borrow.
      do {
        let (accepted, captured) = try await AgentWebCoordinator.checkpointCurrent(focus: focus, element: demand.source) { value, basis, admittedBytes in
          return try await model.checkpointProgramState(focus: focus, rendered: demand.source, value: value, basis: basis, admittedStateBytes: admittedBytes)
        }
        guard !Task.isCancelled, self.request == request,
          self.web?.id == retiring.id, self.demand?.active == false else {
          captured.release(); await AgentWebCoordinator.resumeCurrent(focus: focus); return
        }
        raster = captured; preparedSource = accepted
        failure = nil; failedSource = nil
      } catch {
        guard !Task.isCancelled, self.request == request,
          self.web?.id == retiring.id, self.demand?.active == false else { return }
        failure = "Не удалось сохранить состояние программы"
        // Writer refusal is not permission to destroy a live browser context.
        return
      }
      runtimeWasPresented = false; retireRuntime(); releaseWeb(); liveProgram = nil
      if failure != nil || preparedSource != demand.source { publishReady(false) }
      return
    }
    if preparedSource != demand.source || raster?.source != rasterSource || (raster?.pixelScale ?? 0) + 0.000_001 < requiredScale {
      adoptPreparedRaster()
    }
    if demand.runtimeFailure != nil { return }
    if failedSource == demand.source, failedCapturePolicy == nil || failedCapturePolicy == demand.policy { return }
    failedSource = nil; failedCapturePolicy = nil; failedCaptureAdmission = nil
    failure = nil
    if preparedSource != demand.source { publishReady(false) }
    if !demand.active && preparedSource == demand.source {
      retireRuntime(); releaseWeb(); liveProgram = nil; runtimeWasPresented = false; return
    }
    if let web, let session = session {
      bindRuntime(web, demand: demand)
      web.updatePriority(demand.webPriority)
      runtimeView(web, session: session, basis: demand.basis).prepare()
      return
    }
    guard demand.focused || demand.permitsPreparation else { return }
    if let rasterPreparation, !demand.active {
      do {
        let next = try await rasterPreparation.owner.prepare(demand.source, policy: demand.policy,
          pageIndex: rasterPreparation.pageIndex, store: model.store, permits: { model.permitsPagePreparation })
        guard !Task.isCancelled, self.request == request,
          model.shutdownPhase != .stopped, let current = self.demand else { next.release(); return }
        raster = next; preparedSource = current.source
      } catch is CancellationError { return }
      catch {
        guard !Task.isCancelled, self.request == request else { return }
        failure = "Не удалось подготовить изображение"
        failedSource = demand.source; failedCapturePolicy = demand.policy
        publishReady(false)
        publishFailure(.init(message: failure!) { [weak self] in
          self?.retryPreparation()
        })
      }
      return
    }
    if !demand.active, case .board(let boardID, let id) = focus,
      configuration?.cohort?.sourceReceipts.keys.contains(where: { $0.plane.boardID == boardID && $0.elementID == id }) == true {
      // The addressed scene job is already this static source's producer.
      // Mounting its consumer must not start a duplicate WebKit executor.
      return
    }
    do {
      NotebookNavigationObservation.webPreparation("prepared_admission_requested", ownerID: request, sourceID: demand.source.id)
      let acquired = try await resources.acquireWebSurface(
        priority: demand.webPriority, source: focus, constructsRuntime: demand.active,
        deadline: .now + .seconds(8), requestID: request)
      NotebookNavigationObservation.webPreparation("prepared_admission_acquired", ownerID: request, sourceID: demand.source.id)
      guard !Task.isCancelled, self.request == request,
        model.shutdownPhase != .stopped, let current = self.demand else { acquired.release(); return }
      // Input may have changed while this exact request waited. Apply its
      // current role before constructing or exposing the admitted runtime.
      acquired.updatePriority(current.webPriority)
      bindRuntime(acquired, demand: current)
      let session = AgentWebNativeSession(lease: acquired, resources: resources, snapshotPolicy: current.policy)
      install(session)
      web = acquired
      // The accepted grant starts the one browser immediately. SwiftUI mounts
      // its physical output later; it is no longer a navigation scheduler.
      runtimeView(acquired, session: session, basis: current.basis).prepare()
    } catch is CancellationError {
      return
    } catch {
      guard !Task.isCancelled, self.request == request else { return }
      failure = "Недостаточно ресурсов для программы"
      waitingForAdmission = true
      publishReady(false)
    }
  }
}

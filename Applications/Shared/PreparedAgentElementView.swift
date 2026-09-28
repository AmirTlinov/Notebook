import NotebookCore
import SwiftUI

/// Input is attached to a physical owner, never to the current camera's owner.
enum InteractiveElementReference: Hashable, Sendable {
  case page(pageID: UUID, elementID: String)
  case board(boardID: UUID, elementID: String)
}

/// A newly mounted projection borrows the image retained by its physical
/// source's published history. This is continuity, never a readiness claim.
@MainActor
enum ScenePreparedRasterFallback {
  static func retain(from cohort: SceneCompositionCohort?, focus: InteractiveElementReference,
    for element: AgentElement) -> RasterLease? {
    guard let cohort, case .board(let boardID, let id) = focus, id == element.id else { return nil }
    let addresses = cohort.sourceReceipts.keys.filter { $0.plane.boardID == boardID && $0.elementID == id }
    guard addresses.count == 1, let address = addresses.first,
      let receipt = cohort.sourceReceipts[address],
      let raster = cohort.sourceRasters[address], !raster.isReleased,
      let installed = receipt.installedSource, let source = raster.source.agentElement,
      hasValidGeometry(raster, for: element), hasCompatibleGeometry(receipt.demand.source, element),
      SceneRasterSource.agent(installed) == .agent(source),
      receipt.installedRegion == raster.source.captureRegion,
      receipt.installedScale == raster.pixelScale else { return nil }
    return raster.retainedCopy()
  }

  static func hasCompatibleGeometry(_ source: AgentElement, _ element: AgentElement) -> Bool {
    source.id == element.id && source.kind == element.kind
      && source.frame.width == element.frame.width && source.frame.height == element.frame.height
      && element.frame.width.isFinite && element.frame.height.isFinite
      && element.frame.width > 0 && element.frame.height > 0
  }

  static func hasValidGeometry(_ raster: RasterLease, for element: AgentElement) -> Bool {
    guard !raster.isReleased, let source = raster.source.agentElement,
      hasCompatibleGeometry(source, element) else { return false }
    guard let crop = raster.source.captureRegion else { return true }
    return [crop.x, crop.y, crop.width, crop.height].allSatisfy(\.isFinite)
      && crop.x >= 0 && crop.y >= 0 && crop.width > 0 && crop.height > 0
      && crop.x + crop.width <= element.frame.width && crop.y + crop.height <= element.frame.height
  }
}

/// A visible interactive surface prepares its input before the first tap.
/// Focus owns state writes, while the shared allocator owns bounded WebKit
/// admission; selecting an element is not a prerequisite to pressing a control.
struct PreparedAgentElementView: View {
  private struct RuntimePaintIdentity: Equatable {
    let loadToken: String
    let program: AgentProgramSource
  }
  @Environment(NotebookAppModel.self) private var model
  @Environment(\.displayScale) private var displayScale
  @Environment(\.sceneComposition) private var composition
  let element: AgentElement
  /// Whether this physical owner keeps its program running. Camera gestures
  /// only change inputEnabled; they do not revoke a current page's runtime.
  let allowsInteraction: Bool
  let inputEnabled: Bool
  let allowsProgramExecution: Bool
  let requestedCapture: AgentSnapshotPolicy?
  let focus: InteractiveElementReference
  let pageTurnActivity: PageTurnActivity?
  let rasterPreparation: PageRasterPreparation.Context?
  let onFailure: (PageTurnPreparationFailure) -> Void
  let onRenderReady: (Bool) -> Void
  let onState: NotebookProgramStateWriter

  @State private var pageFrameOwner = UUID()
  @State private var preparationOwner = PreparationOwner()
  @State private var raster: RasterLease?
  @State private var web: WebSurfaceLease?
  @State private var preparedSource: AgentElement?
  @State private var liveProgram: AgentProgramSource?
  @State private var paintRevision: UInt64 = 0
  @State private var failedPaintRuntime: RuntimePaintIdentity?
  @State private var runtimeWasPresented = false
  @State private var runtimeAddress: SceneSourceAddress?
  @State private var runtimeLeaseID: UUID?
  @State private var failure: String?
  @State private var failedSource: AgentElement?
  @State private var failedCapturePolicy: AgentSnapshotPolicy?
  @State private var failedCaptureAdmission: SceneRasterAdmission?
  @State private var waitingForAdmission = false
  @State private var retry: UInt64 = 0

  init(element: AgentElement, allowsInteraction: Bool, inputEnabled: Bool = true,
    allowsProgramExecution: Bool = true, capturePolicy: AgentSnapshotPolicy? = nil, focus: InteractiveElementReference,
    pageTurnActivity:PageTurnActivity? = nil,
    rasterPreparation:PageRasterPreparation.Context? = nil,
    onFailure: @escaping (PageTurnPreparationFailure) -> Void = { _ in },
    onRenderReady: @escaping (Bool) -> Void, onState: @escaping NotebookProgramStateWriter) {
    self.element = element
    self.allowsInteraction = allowsInteraction
    self.inputEnabled = inputEnabled
    self.allowsProgramExecution = allowsProgramExecution
    requestedCapture = capturePolicy
    self.focus = focus
    self.pageTurnActivity = pageTurnActivity
    self.rasterPreparation = rasterPreparation
    self.onFailure = onFailure
    self.onRenderReady = onRenderReady
    self.onState = onState
  }

  private var isActive: Bool {
    guard allowsInteraction, element.requiresLiveRuntime else { return false }
    // Focus retains an accepted input owner. Every actually visible program
    // is otherwise demanded by its physical cohort, not by an activation tap.
    if hasFocus { return true }
    guard allowsProgramExecution else { return false }
    guard case .board(let boardID, let id) = focus, let cohort = composition.cohort else { return true }
    return cohort.runtimeOwners.contains { $0.plane.boardID == boardID && $0.elementID == id }
  }

  private var hasFocus: Bool { model.interactiveElementFocus == focus }
  private var showsLiveProgram: Bool {
    web != nil && (isActive || runtimeWasPresented) && liveProgram == AgentProgramSource(element)
  }
  private var hasPaintedLiveProgram: Bool {
    _ = paintRevision
    return preparationOwner.nativeRuntimeToken != nil
      && preparationOwner.paintedRuntime?.runtimeToken == preparationOwner.nativeRuntimeToken
      && preparationOwner.paintedRuntime?.leaseID == web?.id
      && preparationOwner.paintedRuntime?.program == AgentProgramSource(element)
  }
  private var bridgesFirstLivePaint: Bool {
    guard web != nil, !hasPaintedLiveProgram, preparedSource == element else { return false }
    if let failure = failedPaintRuntime, failure.program == AgentProgramSource(element),
      preparationOwner.nativeRuntimeToken?.hasPrefix(failure.loadToken + "/") != false { return false }
    return raster?.image(for: rasterSource, minimumScale: requiredScale) != nil
  }
  private var awaitsRasterSource: Bool {
    guard let installed = raster?.source.agentElement else { return true }
    // Refining the same source is not a content update. Keep its pixels quiet
    // while the independent density/crop demand still reports not-ready.
    return SceneRasterSource.agent(installed) != .agent(element)
  }

  private var sourceDemand: SceneSourceDemand? {
    sourceAddress.flatMap { composition.cohort?.sourceReceipts[$0]?.demand }
  }
  private var sourceAddress: SceneSourceAddress? {
    guard case .board(let boardID, let id) = focus, let cohort = composition.cohort else { return nil }
    let addresses = cohort.sourceReceipts.keys.filter { $0.plane.boardID == boardID && $0.elementID == id }
    return addresses.count == 1 ? addresses.first : nil
  }
  private var runtimeFailure: AgentWebSourceFailure? {
    model.compositionTiles.runtimeFailure(at: sourceAddress, source: element, policy: snapshotPolicy)
  }

  private var snapshotPolicy: AgentSnapshotPolicy { sourceDemand?.policy ?? requestedCapture ?? .display(scale: snapshotScale) }
  private var rasterSource: SceneRasterSource { snapshotPolicy.rasterSource(for: element) }

  private var snapshotScale: Double {
    if case .board(let boardID, _) = focus,
      let projection = composition.cohort?.frame.pixelScales[boardID] {
      return projection * displayScale
    }
    return displayScale
  }

  private var requiredScale: Double {
    snapshotPolicy.minimumScale(for: element)
  }

  private func adoptPreparedRaster() {
    guard model.shutdownPhase != .stopped else { return }
    if let next = SceneRenderResources.shared.retainRaster(for: rasterSource, minimumScale: requiredScale) {
      if raster?.entryID != next.entryID { raster = next }
      preparedSource = element
      if runtimeFailure == nil { failure = nil; failedSource = nil }
      if runtimeFailure != nil { onRenderReady(false) }
      // Acquiring pixels is not installing them. The native raster callback
      // below certifies the frame before a waiting page may begin its curl.
      return
    }
    if let raster, !ScenePreparedRasterFallback.hasValidGeometry(raster, for: element) { self.raster = nil }
    if raster == nil, let previous = ScenePreparedRasterFallback.retain(from: composition.cohort, focus: focus, for: element),
      ScenePreparedRasterFallback.hasValidGeometry(previous, for: element) {
      raster = previous
    }
    // The old source/crop or density remains unfinished work. In particular a
    // remounted portal cannot acknowledge the new demand using its predecessor.
    preparedSource = nil
    onRenderReady(false)
  }

  private func recordInstalled(_ installation: SceneSourceInstallation, raster: RasterLease? = nil) {
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
    guard case .board(let boardID, let id) = focus, let cohort = composition.cohort else { return }
    for address in cohort.sourceReceipts.keys where address.plane.boardID == boardID && address.elementID == id {
      if isInstalled, let raster, let demand = cohort.sourceReceipts[address]?.demand,
        raster.image(for: demand.rasterSource, minimumScale: demand.minimumScale) == nil { continue }
      cohort.didInstallSource(address, installation: installation)
    }
  }

  private struct Demand: Equatable {
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
    let retry: UInt64
  }

  /// Async/native callbacks borrow the currently accepted role, never the
  /// SwiftUI value that happened to install their closure. This is ownership
  /// bookkeeping, not observable view state.
  @MainActor private final class PreparationOwner {
    struct PaintedRuntime: Equatable {
      let leaseID: UUID
      let program: AgentProgramSource
      let runtimeToken: String?
    }
    var demand: Demand?
    var request: UUID?
    var nativeRuntimeToken: String?
    var paintedRuntime: PaintedRuntime?
    func accept(_ demand: Demand) -> UUID {
      let id = UUID(); self.demand = demand; request = id; return id
    }
    func withdraw() { demand = nil; request = nil; nativeRuntimeToken = nil; paintedRuntime = nil }
  }

  var body: some View {
    let fallbackEntryID: UUID? = {
      guard case .board(let boardID, let id) = focus else { return nil }
      return composition.cohort?.sourceRasters.first { $0.key.plane.boardID == boardID && $0.key.elementID == id }?.value.entryID
    }()
    let basis = model.programStateBasis(focus: focus, rendered: element)
    let demand = Demand(source: element, basis: basis, active: isActive, inputEnabled: inputEnabled, focused: hasFocus,
      // Visible static page material needs camera admission too, not just live
      // programs. Hidden neighbours keep the bounded curl/background route.
      permitsPreparation: rasterPreparation != nil ? model.permitsPagePreparation
        : allowsInteraction ? model.permitsScenePreparation
        : (pageTurnActivity?.isTransitioning == true || model.permitsBackgroundPreparation),
      policy: snapshotPolicy, capture: sourceDemand,
      fallbackEntryID: fallbackEntryID, runtimeFailure: runtimeFailure, retry: retry)
    ZStack {
      // A ready script can precede its first remote WebKit paint. Keep the
      // installed fallback underneath the transparent native view until that
      // exact runtime has returned pixels; input never waits for cache storage.
      if let raster, !showsLiveProgram || bridgesFirstLivePaint {
        AgentElementSnapshotView(raster: raster, onSourceInstalled: { installation, installed in
          recordInstalled(installation, raster: installed)
          Task { @MainActor in
            // Installation can originate in updateUIView. Start navigation
            // after that transaction, and revoke it if the native source left.
            if installation.isInstalled, runtimeFailure == nil,
              self.raster?.entryID == installed.entryID, preparedSource == element,
              installed.image(for:rasterSource,minimumScale:requiredScale) != nil {
              onRenderReady(true)
            }
          }
        })
      }
      if let web {
        AgentWebElementView(element: element, stateBasis: basis, programOwner: model, allowsStateCommits: isActive && hasFocus, lease: web,
          snapshotPolicy: snapshotPolicy,
          preparesPassiveSnapshot: !isActive || bridgesFirstLivePaint,
          showsContent: showsLiveProgram,
          focus: focus,
          onRenderReady: { ready in
            guard model.shutdownPhase != .stopped, self.web?.id == web.id, !web.isReleased,
              let current = preparationOwner.demand, current.source == element else { return }
            if ready, let next = SceneRenderResources.shared.retainRaster(for: rasterSource, minimumScale: requiredScale) {
              if let runtimeAddress { model.compositionTiles.runtimeSourceBecameReady(runtimeAddress, leaseID: web.id, source: element) }
              if raster?.entryID != next.entryID { raster = next }
              preparedSource = element
              failure = nil
              failedSource = nil
              // The representable retains the grant until WebKit is dismantled.
              if !current.active && !runtimeWasPresented { retireRuntime(); self.web = nil }
            } else if !ready, preparedSource != element {
              onRenderReady(false)
            }
          }, onInteractionReady: { ready in
            guard model.shutdownPhase != .stopped, self.web?.id == web.id, !web.isReleased else { return }
            liveProgram = ready ? AgentProgramSource(element) : nil
            if !ready {
              preparationOwner.nativeRuntimeToken = nil; preparationOwner.paintedRuntime = nil
            }
            if ready && preparationOwner.demand?.active == true { runtimeWasPresented = true }
          }, onInteraction: {
            guard isActive, inputEnabled, liveProgram == AgentProgramSource(element), self.web?.id == web.id else { return }
            if !hasFocus { model.interactiveElementFocus = focus }
          }, onInstalled: { installation in
            if let source = installation.source.agentElement,
              !installation.isInstalled || (SceneRasterSource.agent(source) == .agent(element)
                && showsLiveProgram && liveProgram == AgentProgramSource(source)) {
              recordInstalled(installation)
              Task { @MainActor in
                if installation.isInstalled, self.web?.id == web.id,
                  liveProgram == AgentProgramSource(element) {
                  preparationOwner.nativeRuntimeToken = installation.runtimeToken
                  onRenderReady(true)
                }
              }
            }
          }, onFramePainted: { installation in
            guard self.web?.id == web.id, !web.isReleased, installation.isInstalled,
              let source = installation.source.agentElement,
              AgentProgramSource(source) == AgentProgramSource(element) else { return }
            let receipt = PreparationOwner.PaintedRuntime(leaseID: web.id,
              program: AgentProgramSource(source), runtimeToken: installation.runtimeToken)
            guard preparationOwner.paintedRuntime != receipt || failedPaintRuntime != nil else { return }
            let removesBridge = bridgesFirstLivePaint
            preparationOwner.nativeRuntimeToken = installation.runtimeToken
            preparationOwner.paintedRuntime = receipt
            // An accepted curl cut also proves paint, but that proof does not
            // change an unbridged live view. Keep it for a later raster handoff
            // without rebuilding every program during the curl's first frame.
            if removesBridge { paintRevision &+= 1 }
            if failedPaintRuntime != nil { failedPaintRuntime = nil }
          }, onFailure: { event in
            guard model.shutdownPhase != .stopped, self.web?.id == event.leaseID, web.id == event.leaseID,
              !web.isReleased, SceneRasterSource.agent(event.source) == .agent(element),
              let current = preparationOwner.demand, current.source == element,
              event.policy == nil || event.policy == snapshotPolicy else { return }
            // A functioning transparent runtime must not retain old fallback
            // pixels indefinitely when its physical capture has failed.
            failedPaintRuntime = .init(loadToken: event.loadToken, program: AgentProgramSource(event.source))
            let owned = runtimeAddress.map { model.compositionTiles.failRuntimeSource($0, failure: event) } ?? false
            switch event.diagnostic.kind {
            case "resource_limit": failure = "Недостаточно ресурсов для изображения"
            case "load_error": failure = "Не удалось загрузить схему"
            default: failure = "Не удалось подготовить изображение"
            }
            failedSource = owned ? nil : event.source
            failedCapturePolicy = event.policy
            failedCaptureAdmission = event.diagnostic.kind == "resource_limit" ? event.rasterAdmission : nil
            // Snapshot pressure must not dismantle a functioning control.
            if event.policy == nil || !current.active || liveProgram != AgentProgramSource(element) {
              liveProgram = nil
              runtimeWasPresented = false
              retireRuntime()
              self.web = nil
            }
            onRenderReady(false)
          }, onState: onState)
          .id(web.id)
          .allowsHitTesting(isActive && inputEnabled && liveProgram == AgentProgramSource(element))
      }
      // An old raster can bridge preparation, but is never presented as current.
      if let failure = runtimeFailure.map({ failureMessage($0.diagnostic) }) ?? failure, !showsLiveProgram {
        VStack(spacing: 4) {
          Text(failure).font(.caption)
          Button("Повторить") {
            if runtimeFailure != nil, let sourceAddress { model.compositionTiles.retrySource(sourceAddress) }
            failedSource = nil
            self.failure = nil
            retry &+= 1
          }.frame(minWidth: 44, minHeight: 44)
        }
        .padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
      } else if (awaitsRasterSource || isActive) && !showsLiveProgram {
        Text(isActive ? (web == nil ? "Ожидаем свободные ресурсы…" : "Запуск программы…") : (raster == nil ? "Подготовка…" : "Обновление…"))
          .font(.caption).foregroundStyle(.secondary)
          .padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
          .allowsHitTesting(false)
      }
    }
    .onAppear {
      guard model.shutdownPhase != .stopped else { return }
      NotebookNavigationObservation.webPreparation("prepared_appeared", ownerID: pageFrameOwner, sourceID: element.id)
      // Mounting, not constructing a cached SwiftUI value, acquires the lease.
      // This synchronous callback supplies cached pixels before the first frame;
      // asynchronous WebKit preparation remains the existing task's job.
      adoptPreparedRaster()
    }
    .onReceive(NotificationCenter.default.publisher(for: SceneRenderResources.didChange)) { note in
      if note.object as? String == element.id { adoptPreparedRaster() }
    }
    .onReceive(NotificationCenter.default.publisher(for: SceneRenderResources.didGainRasterAdmission)) { note in
      guard note.object as? SceneRenderResources === SceneRenderResources.shared else { return }
      retryAfterRasterAdmission()
    }
    .task(id: demand) { await prepare(demand) }
    .onChange(of: SceneRenderResources.shared.webAdmissionGeneration) { _, _ in
      guard waitingForAdmission else { return }
      waitingForAdmission = false
      retry &+= 1
    }
    .onDisappear {
      preparationOwner.withdraw()
      #if os(iOS)
      if let context = rasterPreparation {
        pageTurnActivity?.removeElementFrame(page: context.pageIndex, element: element.id, owner: pageFrameOwner)
      }
      #endif
      retireRuntime()
      web = nil
      raster = nil
      preparedSource = nil
      liveProgram = nil
      failedPaintRuntime = nil
      runtimeWasPresented = false
      waitingForAdmission = false
      failedCaptureAdmission = nil
      onRenderReady(false)
    }
  }

  @MainActor
  private func bindRuntime(_ lease: WebSurfaceLease, demand: Demand) {
    guard demand.active else { return }
    let address = model.compositionTiles.registerRuntimeSource(focus: focus, source: demand.source,
      policy: demand.policy, leaseID: lease.id, cohort: composition.cohort)
    if runtimeAddress != address || runtimeLeaseID != lease.id {
      retireRuntime(); runtimeAddress = address; runtimeLeaseID = address == nil ? nil : lease.id
    }
  }

  @MainActor
  private func retireRuntime() {
    if let runtimeAddress, let runtimeLeaseID {
      model.compositionTiles.retireRuntimeSource(runtimeAddress, leaseID: runtimeLeaseID)
    }
    runtimeAddress = nil; runtimeLeaseID = nil
  }

  private func failureMessage(_ diagnostic: RenderDiagnostic) -> String {
    switch diagnostic.kind {
    case "resource_limit": "Недостаточно ресурсов для изображения"
    case "load_error": "Не удалось загрузить схему"
    default: "Не удалось подготовить изображение"
    }
  }

  @MainActor
  private func retryAfterRasterAdmission() {
    // A mounted coordinator owns its submitted capture. Composition owns a
    // retired board producer; only a standalone retired consumer retries here.
    guard web == nil, failedSource == element,
      failedCapturePolicy == snapshotPolicy,
      let previous = failedCaptureAdmission else { return }
    let current = SceneRenderResources.shared.rasterAdmission
    // A notification is only a wake-up. The failed source retries after a real
    // capacity improvement that admits its whole capture, never on its own
    // staging release or while the same impossible request remains unchanged.
    guard AgentWebSourceFailure.captureFitsAfterImprovement(source: element, policy: snapshotPolicy,
      previous: previous, current: current) else { return }
    failedSource = nil; failedCapturePolicy = nil; failedCaptureAdmission = nil
    failure = nil; retry &+= 1
  }

  @MainActor
  private func prepare(_ demand: Demand) async {
    guard !Task.isCancelled, model.shutdownPhase != .stopped else { return }
    let request = preparationOwner.accept(demand)
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
        guard !Task.isCancelled, preparationOwner.request == request,
          self.web?.id == retiring.id, preparationOwner.demand?.active == false else {
          captured.release(); await AgentWebCoordinator.resumeCurrent(focus: focus); return
        }
        raster = captured; preparedSource = accepted
        failure = nil; failedSource = nil
      } catch {
        guard !Task.isCancelled, preparationOwner.request == request,
          self.web?.id == retiring.id, preparationOwner.demand?.active == false else { return }
        failure = "Не удалось сохранить состояние программы"
        // Writer refusal is not permission to destroy a live browser context.
        return
      }
      runtimeWasPresented = false; retireRuntime(); web = nil; liveProgram = nil
      if failure != nil || preparedSource != demand.source { onRenderReady(false) }
      return
    }
    if preparedSource != demand.source || raster?.source != rasterSource || (raster?.pixelScale ?? 0) + 0.000_001 < requiredScale {
      adoptPreparedRaster()
    }
    if demand.runtimeFailure != nil { return }
    if failedSource == demand.source, failedCapturePolicy == nil || failedCapturePolicy == demand.policy { return }
    failedSource = nil; failedCapturePolicy = nil; failedCaptureAdmission = nil
    failure = nil
    if preparedSource != demand.source { onRenderReady(false) }
    if !demand.active && preparedSource == demand.source {
      retireRuntime(); web = nil; liveProgram = nil; runtimeWasPresented = false; return
    }
    if let web {
      bindRuntime(web, demand: demand)
      web.updatePriority(demand.active ? (demand.inputEnabled && demand.focused ? .input : .liveProgram) : .visible)
      return
    }
    guard demand.focused || demand.permitsPreparation else { return }
    if let rasterPreparation, !demand.active {
      do {
        let next = try await rasterPreparation.owner.prepare(demand.source, policy: demand.policy,
          pageIndex: rasterPreparation.pageIndex, store: model.store, permits: { model.permitsPagePreparation })
        guard !Task.isCancelled, preparationOwner.request == request,
          model.shutdownPhase != .stopped else { next.release(); return }
        raster = next; preparedSource = demand.source
      } catch is CancellationError { return }
      catch {
        guard !Task.isCancelled, preparationOwner.request == request else { return }
        failure = "Не удалось подготовить изображение"
        failedSource = demand.source; failedCapturePolicy = demand.policy
        onRenderReady(false)
        onFailure(.init(message: failure!) {
          failedSource = nil; failure = nil; retry &+= 1
        })
      }
      return
    }
    if !demand.active, case .board(let boardID, let id) = focus,
      composition.cohort?.sourceReceipts.keys.contains(where: { $0.plane.boardID == boardID && $0.elementID == id }) == true {
      // The addressed scene job is already this static source's producer.
      // Mounting its consumer must not start a duplicate WebKit executor.
      return
    }
    do {
      NotebookNavigationObservation.webPreparation("prepared_admission_requested", ownerID: request, sourceID: demand.source.id)
      let acquired = try await SceneRenderResources.shared.acquireWebSurface(
        priority: demand.active ? (demand.inputEnabled && demand.focused ? .input : .liveProgram) : .visible,
        source: focus, constructsRuntime: demand.active, deadline: .now + .seconds(8))
      NotebookNavigationObservation.webPreparation("prepared_admission_acquired", ownerID: request, sourceID: demand.source.id)
      guard !Task.isCancelled, preparationOwner.request == request,
        model.shutdownPhase != .stopped else { acquired.release(); return }
      bindRuntime(acquired, demand: demand)
      web = acquired
    } catch is CancellationError {
      return
    } catch {
      guard !Task.isCancelled, preparationOwner.request == request else { return }
      failure = "Недостаточно ресурсов для программы"
      waitingForAdmission = true
      onRenderReady(false)
    }
  }
}

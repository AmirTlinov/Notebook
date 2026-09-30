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

  let preparations: PageAgentPreparationOwner?
  @State private var standaloneOwner = PreparedAgentElementPreparationOwner()
  @State private var consumer = PreparedAgentElementPreparationOwner.Consumer()
  private var owner: PreparedAgentElementPreparationOwner { preparations?.owner(for: element.id) ?? standaloneOwner }

  init(element: AgentElement, allowsInteraction: Bool, inputEnabled: Bool = true,
    allowsProgramExecution: Bool = true, capturePolicy: AgentSnapshotPolicy? = nil, focus: InteractiveElementReference,
    pageTurnActivity:PageTurnActivity? = nil,
    preparations: PageAgentPreparationOwner? = nil,
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
    self.preparations = preparations
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
  private var configuration: PreparedAgentElementPreparationOwner.Configuration {
    let sourceAddress: SceneSourceAddress? = {
      guard case .board(let boardID, let id) = focus, let cohort = composition.cohort else { return nil }
      let addresses = cohort.sourceReceipts.keys.filter { $0.plane.boardID == boardID && $0.elementID == id }
      return addresses.count == 1 ? addresses.first : nil
    }()
    let capture = sourceAddress.flatMap { composition.cohort?.sourceReceipts[$0]?.demand }
    let scale: Double = {
      if case .board(let boardID, _) = focus, let value = composition.cohort?.frame.pixelScales[boardID] { return value * displayScale }
      return displayScale
    }()
    let policy = capture?.policy ?? requestedCapture ?? .display(scale: scale)
    let fallback = sourceAddress.flatMap { composition.cohort?.sourceRasters[$0]?.entryID }
    let writer: NotebookProgramStateWriter
    if preparations != nil, case .page(let pageID, let elementID) = focus {
      let model = model
      writer = { [weak model] state, completion in
        model?.commitElementState(pageID: pageID, elementID: elementID, state: state, onCommitted: completion) ?? false
      }
    } else { writer = onState }
    return .init(model: model, demand: .init(source: element,
      basis: model.programStateBasis(focus: focus, rendered: element), active: isActive,
      inputEnabled: inputEnabled, focused: hasFocus,
      permitsPreparation: rasterPreparation != nil ? model.permitsPagePreparation
        : allowsInteraction ? model.permitsScenePreparation
        : (pageTurnActivity?.isTransitioning == true || model.permitsBackgroundPreparation),
      policy: policy, capture: capture, fallbackEntryID: fallback,
      runtimeFailure: model.compositionTiles.runtimeFailure(at: sourceAddress, source: element, policy: policy)),
      focus: focus, pageTurnActivity: pageTurnActivity, rasterPreparation: rasterPreparation,
      cohort: composition.cohort, onState: writer)
  }

  var body: some View {
    let owner = owner, configuration = configuration
    #if os(iOS)
    let status = owner.statusPresentation
    #endif
    ZStack {
      if let web = owner.web, let session = owner.session, session.lease === web {
        owner.runtimeView(web, session: session, basis: configuration.demand.basis)
          .id(web.id)
          .allowsHitTesting(isActive && inputEnabled && owner.liveProgram == AgentProgramSource(element))
      }
      // Keep the accepted pixels above the new native surface until its
      // exact first paint. WebKit stays visible underneath, so installation
      // and its real snapshot can finish without a visibility dependency.
      if let raster = owner.raster, !owner.showsLiveProgram || owner.bridgesFirstLivePaint {
        #if os(iOS)
        if status == nil {
          AgentElementSnapshotView(raster: raster, onSourceInstalled: { [weak owner] installation, installed in
            owner?.rasterInstalled(installation, raster: installed)
          })
        }
        #else
        AgentElementSnapshotView(raster: raster, onSourceInstalled: { [weak owner] installation, installed in
          owner?.rasterInstalled(installation, raster: installed)
        })
        #endif
      }
      #if os(iOS)
      if case .page = focus {
        if let presentation = owner.statusPresentation {
          PageElementStatusView(presentation: presentation,
            onInstallation: { [weak owner] value, installation in owner?.statusInstalled(value, installation: installation) },
            retry: { [weak owner] in owner?.retryPreparation() })
        }
      } else {
      if let failure = owner.runtimeFailure.map({ owner.failureMessage($0.diagnostic) }) ?? owner.failure, !owner.showsLiveProgram {
        VStack(spacing: 4) {
          Text(failure).font(.caption)
          Button("Повторить") { owner.retryPreparation() }.frame(minWidth: 44, minHeight: 44)
        }.padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
      } else if (owner.awaitsRasterSource || isActive) && !owner.showsLiveProgram {
        Text(isActive ? (owner.web == nil ? "Ожидаем свободные ресурсы…" : "Запуск программы…") : (owner.raster == nil ? "Подготовка…" : "Обновление…"))
          .font(.caption).foregroundStyle(.secondary)
          .padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
          .allowsHitTesting(false)
      }
      }
      #else
      if let failure = owner.runtimeFailure.map({ owner.failureMessage($0.diagnostic) }) ?? owner.failure, !owner.showsLiveProgram {
        VStack(spacing: 4) {
          Text(failure).font(.caption)
          Button("Повторить") { owner.retryPreparation() }.frame(minWidth: 44, minHeight: 44)
        }.padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
      } else if (owner.awaitsRasterSource || isActive) && !owner.showsLiveProgram {
        Text(isActive ? (owner.web == nil ? "Ожидаем свободные ресурсы…" : "Запуск программы…") : (owner.raster == nil ? "Подготовка…" : "Обновление…"))
          .font(.caption).foregroundStyle(.secondary)
          .padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
          .allowsHitTesting(false)
      }
      #endif
    }
    #if os(iOS)
    .onChange(of: owner.requestedStatus, initial: true) { _, key in owner.prepareStatus(key) }
    #endif
    .onAppear {
      NotebookNavigationObservation.webPreparation("prepared_appeared", ownerID: owner.pageFrameOwner, sourceID: element.id)
      consumer.onRenderReady = onRenderReady; consumer.onFailure = onFailure
      owner.attach(consumer); owner.accept(configuration)
    }
    .onChange(of: ObjectIdentifier(owner)) { _, _ in
      consumer.onRenderReady = onRenderReady; consumer.onFailure = onFailure
      owner.attach(consumer); owner.accept(configuration)
    }
    .onChange(of: configuration.demand) { _, _ in
      consumer.onRenderReady = onRenderReady; consumer.onFailure = onFailure
      owner.accept(configuration)
    }
    .onDisappear {
      owner.detach(consumer)
      if preparations == nil { owner.retire(); standaloneOwner = PreparedAgentElementPreparationOwner() }
    }
  }
}

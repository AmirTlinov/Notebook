#if os(iOS)
import NotebookCore
import Metal
import SwiftUI

/// The admitted page owner was replaced before its immutable cut was borrowed.
/// Its successor's material/readiness edge resumes the same physical motion.
enum PageTurnMaterialUnavailable: Error { case changed }

/// A slot cut belongs to the installed program/raster owner. Its lifetime is
/// independent of the cache alias or subsequent program state publications.
@MainActor
final class PageTurnElementFrame {
  enum Pixels { case raster(RasterLease), cut(SceneRasterCut) }
  let pixels: Pixels
  var source: SceneRasterSource {
    switch pixels { case .raster(let raster): raster.source; case .cut(let cut): cut.source }
  }
  private let onRelease: (@MainActor () -> Void)?
  init(raster: RasterLease, onRelease: (@MainActor () -> Void)? = nil) {
    pixels = .raster(raster); self.onRelease = onRelease
  }
  init(cut: SceneRasterCut) {
    pixels = .cut(cut); onRelease = nil
  }
  isolated deinit { onRelease?() }
}

/// Resident paper prepares immutable native artwork when its material changes.
/// Pen appends borrow the canvas's accepted GPU backing and do not repaint text,
/// decode images, or replay handwriting. Live programs contribute only a local
/// installed slot cut when the physical turn is accepted.
@MainActor
final class PageTurnMaterialOwner {
  private let observationID = UUID()
  private func observe(_ stage: String, frameID: UUID? = nil, pageID: UUID? = nil) {
    guard let receive = NotebookNavigationObservation.onPageMaterialPreparation else { return }
    receive(stage, observationID, pageID ?? sourcePage?.id, frameID, nil, CACurrentMediaTime())
  }
  private func compositionObservation(_ operationID: UUID? = nil, pageID: UUID)
    -> (@MainActor (String, TimeInterval) -> Void)? {
    guard let receive = NotebookNavigationObservation.onPageMaterialPreparation else { return nil }
    let ownerID = observationID, operationID = operationID ?? UUID()
    return { stage, time in receive(stage, ownerID, pageID, nil, operationID, time) }
  }
  private struct PaperKey: Hashable {
    let resources: ObjectIdentifier
    let width, height, scale: Double
  }
  private final class PaperReference {
    weak var frame: PageTurnFrame?
    init(_ frame: PageTurnFrame) { self.frame = frame }
  }
  // The grid is the same immutable material on equal physical paper. The
  // directory never owns pixels: the last resident page releases them. A small
  // single-flight directory prevents adjacent pages uploading it concurrently.
  private static var paperFrames: [PaperKey: PaperReference] = [:]
  private struct PaperPreparation {
    let id = UUID()
    let priority: SceneAllocationPriority
    let task: Task<PageTurnFrame, Error>
  }
  private static var paperPreparations: [PaperKey: PaperPreparation] = [:]
  private struct Key: Equatable {
    let native: [AgentElement]
    let slots: [String: NotebookElementPresentation]
    let staticSources: [String: SceneRasterSource]
    let size: PageSize
    let erasures: InkElementErasureMap
    let ordered: Set<String>
    let scale: Double
  }
  private struct NativeKey: Equatable, Sendable {
    let source: AgentElement
    let layout: NotebookGraphicLayout?
    let projection: NotebookGraphicLayout.Projection?
    let size: CGSize
    let bodySize: CGSize?
    let transform: CGAffineTransform?
    let cuts: [InkElementErasure]
    let paintsBody: Bool
    let scale: Double
  }
  private struct NativeMaterial: Sendable {
    let key: NativeKey
    let frame: PageTurnFrame
  }
  private struct SlotKey: Equatable {
    let source: AgentElement
    let size: CGSize
    let bodySize: CGSize
    let transform: CGAffineTransform
    let cuts: [InkElementErasure]
    let scale: Double
    let provider: PageTurnActivity.ElementFrameVersion
  }
  private struct SlotMaterial { let key: SlotKey; let frame: PageTurnFrame }
  private struct PreparedLayers: Sendable { let layers: [Layer]; let native: [String: NativeMaterial] }
  // These records belong to this resident page. Order/translation changes
  // rebuild the small directory, retaining unchanged local pixel owners.
  private var nativeMaterials: [String: NativeMaterial] = [:]
  private var slotMaterials: [String: SlotMaterial] = [:]
  var preparedMaterialIDs: [String: UUID] {
    nativeMaterials.mapValues { $0.frame.id }.merging(slotMaterials.mapValues { $0.frame.id }) { _, right in right }
  }
  private enum Layer: Sendable {
    case image(PageTurnFrame, CGRect)
    case element(AgentElement, NotebookElementPresentation, [InkElementErasure], CGRect)
  }
  @MainActor private final class SlotPixels {
    let image: CGImage
    private let owner: AnyObject
    init(image: CGImage, owner: AnyObject) { self.image = image; self.owner = owner }
  }
  private struct FrameBasis: Equatable {
    let pageID: UUID
    let material: UInt64
    let liveSource: UInt64
    let providers: [String: PageTurnActivity.ElementFrameVersion]
    let inkGeneration: UInt64?
    let inkTexture: ObjectIdentifier?
    var hasRuntime: Bool { providers.values.contains { $0.content == .runtime } }
  }
  private struct FrameInput {
    let basis: FrameBasis
    let key: Key
    let layers: [Layer]
    let sources: [String: AgentElement]
    let ink: InkCanvasView.AcceptedFrameLease?
  }
  @MainActor private final class FramePreparation {
    let id: UUID
    let basis: FrameBasis
    var task: Task<Void, Never>?
    private var result: Result<PageTurnFrame, Error>?
    private var waiters: [UUID: CheckedContinuation<PageTurnFrame, Error>] = [:]
    init(id: UUID, basis: FrameBasis) { self.id = id; self.basis = basis }

    func value() async throws -> PageTurnFrame {
      let id = UUID()
      return try await withTaskCancellationHandler {
        try Task.checkCancellation()
        task?.escalatePriority(to: Task.currentPriority)
        return try await withCheckedThrowingContinuation { continuation in
          if let result { continuation.resume(with: result) }
          else { waiters[id] = continuation }
        }
      } onCancel: {
        Task { @MainActor in self.waiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
      }
    }

    func finish(_ result: Result<PageTurnFrame, Error>) {
      guard self.result == nil else { return }
      self.result = result; task = nil
      for waiter in waiters.values { waiter.resume(with: result) }
      waiters.removeAll()
    }

    func cancel() {
      task?.cancel()
      // The producer retains its immutable inputs until any submitted GPU
      // command drains. Consumers do not own that fence and can leave now.
      finish(.failure(CancellationError()))
    }
  }
  private var key: Key?
  // Retain the current source behind its identity; a recycled object address
  // must not make a different page's elements reuse the previous artwork.
  private var sourcePage: PageDocument?
  // Program state/code changes replace the live slot input, not the already
  // prepared paper and native artwork. Capture freezes this separate basis.
  private var liveSources: [String: AgentElement] = [:]
  private var liveSourceGeneration: UInt64 = 0
  private var preparation: Task<PreparedLayers, Error>?
  private var slotPreparation: Task<Void, Never>?
  private var slotPreparationHasWake = false
  private var layers: [Layer]?
  private var notifyReady: (@MainActor () -> Void)?
  private var notifySlotsReady: (@MainActor () -> Void)?
  private var materialGeneration: UInt64 = 0
  private var cachedFrame: (basis: FrameBasis, frame: PageTurnFrame)?
  // A texture address can be reused after its canvas retires. Do not retain
  // the ink lease in the cache: that would force copying on the next stroke.
  private weak var cachedInkTexture: (any MTLTexture)?
  private var framePreparation: FramePreparation?
  private var preparesPassiveFrame = false
  // Reclamation/refusal suppresses speculation for this exact material until
  // it changes. An accepted turn may still acquire an ephemeral input cut.
  private var deferredFrameBasis: FrameBasis?
  private weak var frameReadiness: PageTurnReadiness?
  private weak var slotActivity: PageTurnActivity?
  private weak var slotReadiness: PageTurnReadiness?
  private var slotObserver: UUID?
  private var reclamationOwner: UUID?
  init() {
    reclamationOwner = SceneRenderResources.shared.registerReclamationOwner { [weak self] in
      guard let self, frameReadiness?.isInActiveTurn() != true, let frame = cachedFrame?.frame else { return [] }
      let id = frame.id, bytes = frame.byteCount
      return [.init(id: id, bytes: bytes, rasterCount: 1, value: .unused,
        distance: 1, restorationMilliseconds: 1, release: { [weak self] in
          guard self?.cachedFrame?.frame.id == id else { return nil }
          self?.observe("passive_reclaimed", frameID: id)
          self?.deferredFrameBasis = self?.cachedFrame?.basis
          self?.cachedFrame = nil
          self?.cachedInkTexture = nil
          return nil
        })]
    }
  }
  private func staticMaterial(for layer: Layer, provider: PageTurnActivity.ElementFrameVersion? = nil) -> SlotMaterial? {
    guard case .element(let element, let presentation, let cuts, let frame) = layer,
      let key, let material = slotMaterials[element.id] else { return nil }
    let expected = SlotKey(source: element, size: frame.size, bodySize: presentation.bodySize,
      transform: presentation.transform, cuts: cuts, scale: key.scale, provider: provider ?? material.key.provider)
    return material.key == expected ? material : nil
  }
  var isPrepared: Bool {
    guard let layers else { return false }
    return layers.allSatisfy { layer in
      guard case .element(let element, _, _, _) = layer, !element.requiresLiveRuntime else { return true }
      return staticMaterial(for: layer) != nil
    }
  }

  func isCapturable(readiness: PageTurnReadiness) -> Bool {
    guard isPrepared, let layers else { return false }
    return layers.allSatisfy { layer in
      guard case .element(let element, _, _, _) = layer else { return true }
      let source = element.requiresLiveRuntime ? liveSources[element.id] : element
      guard let source, let version = readiness.activity?.elementFrameVersion(page: readiness.pageIndex, source: source) else { return false }
      return element.requiresLiveRuntime || staticMaterial(for: layer, provider: version) != nil
    }
  }

  func prepare(page: PageDocument, erasures: InkElementErasureMap, ordered: Set<String>, scale: Double,
    onReady: @escaping @MainActor () -> Void,
    onFailure: @escaping @MainActor (PageTurnPreparationFailure) -> Void) {
    let scale = min(scale, sqrt(4_000_000 / (page.size.width * page.size.height)))
    let key: Key
    if sourcePage?.elementSourceIdentity == page.elementSourceIdentity, let previous = self.key {
      key = .init(native: previous.native, slots: previous.slots, staticSources: previous.staticSources,
        size: page.size, erasures: erasures, ordered: ordered, scale: scale)
    } else {
      let graph = page.graphicGraph()
      let slots = page.elements.filter { $0.kind != .group && $0.graphic == nil && $0.kind != .nativeText }
      let currentLiveSources = Dictionary(uniqueKeysWithValues: slots.filter(\.requiresLiveRuntime).map {
        ($0.id, agentElementSnapshotSource($0))
      })
      if liveSources != currentLiveSources {
        liveSources = currentLiveSources; liveSourceGeneration &+= 1; invalidateFrame(reason: "live_source")
      }
      key = .init(native: page.elements.filter { $0.graphic != nil || $0.kind == .nativeText || $0.kind == .group },
        slots: Dictionary(uniqueKeysWithValues: slots.compactMap { element in
          graph.placement(element.id).map { (element.id, NotebookElementPresentation(element, placement: $0)) }
        }), staticSources: Dictionary(uniqueKeysWithValues: slots.filter { !$0.requiresLiveRuntime }.map { ($0.id, .agent($0)) }),
        size: page.size, erasures: erasures, ordered: ordered, scale: scale)
    }
    sourcePage = page
    notifyReady = onReady
    guard self.key != key else { if layers != nil { notifyReady = nil }; return }
    self.key = key; materialGeneration &+= 1
    invalidateFrame(reason: "native_material"); preparation?.cancel(); slotPreparation?.cancel(); slotPreparation = nil
    slotPreparationHasWake = false
    notifySlotsReady = nil; layers = nil
    let retainedNative = nativeMaterials
    preparation = Task { @MainActor [weak self] in
      do {
        let result = try await Self.prepareLayers(page: page, erasures: erasures, ordered: ordered, scale: scale,
          retained: retainedNative)
        try Task.checkCancellation()
        if let self, self.key == key {
          self.layers = result.layers; self.nativeMaterials = result.native
          let slots = Set(result.layers.compactMap { layer -> String? in
            if case .element(let element, _, _, _) = layer, !element.requiresLiveRuntime { return element.id }; return nil
          })
          self.slotMaterials = self.slotMaterials.filter { slots.contains($0.key) }
          let notify = self.notifyReady; self.notifyReady = nil; notify?()
        }
        return result
      } catch {
        if !(error is CancellationError), let self, self.key == key {
          self.notifyReady = nil
          onFailure(.init(kind: error as? SceneRenderError == .resourceLimit ? .resourceLimit : .preparationFailed,
            message: "Не удалось подготовить лист для перелистывания", retry: { [weak self] in
              guard let self else { return }; self.key = nil
              self.prepare(page: page, erasures: erasures, ordered: ordered, scale: scale, onReady: onReady, onFailure: onFailure)
            }))
        }
        throw error
      }
    }
  }

  /// Keep slot identity in the directory after flattening. A pending/error cut
  /// and its later real pixels update this one entry, not every static sibling.
  func prepareStaticSlots(readiness: PageTurnReadiness,
    onReady: @escaping @MainActor () -> Void,
    onFailure: @escaping @MainActor (PageTurnPreparationFailure) -> Void) {
    guard let layers, let key else { return }
    notifySlotsReady = key.staticSources.isEmpty ? nil : onReady
    slotReadiness = readiness
    if slotActivity !== readiness.activity {
      if let slotObserver { slotActivity?.removePreparationObserver(slotObserver) }
      slotActivity = readiness.activity
      slotObserver = slotActivity?.observePreparation { [weak self] change in
        guard case .elementFrames(let page, let changed) = change, let self,
          let readiness = self.slotReadiness, readiness.pageIndex == page else { return }
        if changed { self.invalidateFrame(reason: "slot_material") }
        // Live frames already carry their provider version and availability.
        // They never need the parent's static-slot preparation loop on a page
        // whose slots are all live; their material/readiness edge remains below.
        if self.key?.staticSources.isEmpty == false {
          self.slotPreparationHasWake = true
          if self.slotPreparation == nil { self.notifySlotsReady?() }
        }
        self.refreshPassiveFrame()
        let capturable = self.isCapturable(readiness: readiness) && readiness.inkFrameIsReady?() == true
        if capturable != readiness.state.capturable {
          readiness(readiness.state.presented, capturable: capturable, paperReady: readiness.state.paperReady)
        } else if changed { readiness.materialDidChange() }
        else { readiness.materialAvailabilityDidChange() }
      }
    }
    guard !key.staticSources.isEmpty, slotPreparation == nil else { return }
    var missing: [(AgentElement, NotebookElementPresentation, [InkElementErasure], CGRect, SlotKey)] = []
    for layer in layers {
      guard case .element(let element, let presentation, let cuts, let frame) = layer,
        !element.requiresLiveRuntime else { continue }
      guard let version = readiness.activity?.elementFrameVersion(page: readiness.pageIndex, source: element) else { continue }
      let next = SlotKey(source: element, size: frame.size, bodySize: presentation.bodySize,
        transform: presentation.transform, cuts: cuts, scale: key.scale, provider: version)
      if slotMaterials[element.id]?.key != next { missing.append((element, presentation, cuts, frame, next)) }
    }
    guard !missing.isEmpty else { return }
    slotPreparationHasWake = false
    slotPreparation = Task { @MainActor [weak self] in
      do {
        for (element, presentation, cuts, frame, next) in missing {
          try Task.checkCancellation()
          let pixels = try await Self.slotPixels(element: element, presentation: presentation,
            cuts: cuts, frame: frame, scale: next.scale, readiness: readiness, priority: .passive)
          let image = try await PageTurnFrame.compose(size: frame.size, scale: next.scale,
            images: [.init(image: pixels.image, frame: CGRect(origin: .zero, size: frame.size))], retaining: [pixels])
          try Task.checkCancellation()
          guard let self, self.key == key,
            readiness.activity?.elementFrameVersion(page: readiness.pageIndex, source: element) == next.provider else {
            throw PageTurnMaterialUnavailable.changed
          }
          self.slotMaterials[element.id] = .init(key: next, frame: image)
        }
        guard let self, self.key == key else { return }
        self.slotPreparation = nil; self.slotPreparationHasWake = false
        self.notifySlotsReady?()
      } catch {
        guard !(error is CancellationError), let self, self.key == key else { return }
        self.slotPreparation = nil
        if error is PageTurnMaterialUnavailable {
          let wake = self.slotPreparationHasWake; self.slotPreparationHasWake = false
          if wake { self.notifySlotsReady?() }; return
        }
        self.slotPreparationHasWake = false
        onFailure(.init(kind: error as? SceneRenderError == .resourceLimit ? .resourceLimit : .preparationFailed,
          message: "Не удалось подготовить элемент листа", retry: { [weak self] in
            self?.prepareStaticSlots(readiness: readiness, onReady: onReady, onFailure: onFailure)
          }))
      }
    }
  }

  func retire() {
    preparation?.cancel(); preparation = nil
    slotPreparation?.cancel(); slotPreparation = nil
    slotPreparationHasWake = false
    notifyReady = nil; notifySlotsReady = nil
    if let slotObserver { slotActivity?.removePreparationObserver(slotObserver) }
    slotObserver = nil; slotActivity = nil; slotReadiness = nil
    key = nil; sourcePage = nil; layers = nil; nativeMaterials.removeAll(); slotMaterials.removeAll()
    liveSources = [:]; liveSourceGeneration &+= 1
    invalidateFrame(reason: "retired"); preparesPassiveFrame = false; frameReadiness = nil
  }

  /// The page's existing source, provider and ink readiness events prepare a
  /// covered neighbour. The visible writing page never composes on every lift.
  func preparePassiveFrame(readiness: PageTurnReadiness, enabled: Bool) {
    if preparesPassiveFrame, !enabled, !readiness.isInActiveTurn() {
      if framePreparation != nil { observe("passive_cancelled_role") }
      framePreparation?.cancel(); framePreparation = nil
    }
    frameReadiness = readiness; preparesPassiveFrame = enabled
    refreshPassiveFrame()
  }

  private func invalidateFrame(reason: String) {
    if cachedFrame != nil || framePreparation != nil { observe("invalidated_" + reason, frameID: cachedFrame?.frame.id) }
    framePreparation?.cancel(); framePreparation = nil
    cachedFrame = nil; cachedInkTexture = nil; deferredFrameBasis = nil
  }

  private func frameInput(readiness: PageTurnReadiness) -> FrameInput? {
    guard !readiness.isRetired, isPrepared, let key, let layers, let sourcePage,
      readiness.inkFrameIsReady?() == true else { return nil }
    let ink = readiness.inkFrame?()
    guard ink != nil || readiness.inkFrameIsEmpty?() == true else { return nil }
    var providers: [String: PageTurnActivity.ElementFrameVersion] = [:]
    var acceptedLayers: [Layer] = []
    for layer in layers {
      guard case .element(let element, _, _, let rect) = layer else { acceptedLayers.append(layer); continue }
      guard let source = element.requiresLiveRuntime ? liveSources[element.id] : element,
        let version = readiness.activity?.elementFrameVersion(page: readiness.pageIndex, source: source) else { return nil }
      providers[element.id] = version
      if element.requiresLiveRuntime { acceptedLayers.append(layer) }
      else {
        guard let material = staticMaterial(for: layer, provider: version) else { return nil }
        acceptedLayers.append(.image(material.frame, rect))
      }
    }
    return .init(basis: .init(pageID: sourcePage.id, material: materialGeneration,
      liveSource: liveSourceGeneration, providers: providers,
      inkGeneration: ink?.generation, inkTexture: ink.map { ObjectIdentifier($0.texture) }),
      key: key, layers: acceptedLayers, sources: liveSources, ink: ink)
  }

  private func refreshPassiveFrame() {
    guard preparesPassiveFrame || cachedFrame != nil || framePreparation != nil else { return }
    guard let readiness = frameReadiness else { return }
    guard let input = frameInput(readiness: readiness) else {
      // A temporary native detach or ink installation gap prevents borrowing,
      // but does not change pixels already borrowed by the page. Both pending
      // and completed cuts retain their original basis; installation and that
      // full basis are checked again before an accepted turn can acquire them.
      return
    }
    if cachedFrame?.basis != input.basis || cachedInkTexture !== input.ink?.texture {
      if let cachedFrame { observe("passive_basis_changed", frameID: cachedFrame.frame.id) }
      cachedFrame = nil; cachedInkTexture = nil
    }
    if let pending = framePreparation, pending.basis != input.basis {
      observe("passive_cancelled_basis")
      pending.cancel(); framePreparation = nil
    }
    guard preparesPassiveFrame, !input.basis.hasRuntime, cachedFrame == nil,
      framePreparation == nil, deferredFrameBasis != input.basis else { return }
    _ = prepareFrame(input, readiness: readiness)
  }

  /// A turn joins the exact producer already preparing its accepted basis.
  /// Cancellation of one consumer does not cancel the page's material task.
  private func prepareFrame(_ input: FrameInput, readiness: PageTurnReadiness) -> FramePreparation {
    if let framePreparation, framePreparation.basis == input.basis { return framePreparation }
    framePreparation?.cancel()
    let id = UUID()
    let pending = FramePreparation(id: id, basis: input.basis)
    let observation = compositionObservation(id, pageID: input.basis.pageID)
    observe("passive_started", pageID: input.basis.pageID)
    let task = Task { @MainActor [weak self, weak readiness] in
      do {
        guard let readiness else { throw PageTurnMaterialUnavailable.changed }
        let frame = try await Self.compose(input, readiness: readiness, priority: .passive, observation: observation)
        try Task.checkCancellation()
        guard let self, !readiness.isRetired, framePreparation?.id == id else { throw PageTurnMaterialUnavailable.changed }
        if let current = frameInput(readiness: readiness), current.basis != input.basis {
          throw PageTurnMaterialUnavailable.changed
        }
        framePreparation = nil
        if frame.allocationPriority == .passive {
          cachedFrame = (input.basis, frame)
          cachedInkTexture = input.ink?.texture
          SceneRenderResources.shared.reclamationOffersChanged()
        }
        observe("passive_completed", frameID: frame.id, pageID: input.basis.pageID)
        pending.finish(.success(frame))
      } catch {
        self?.observe(error is CancellationError ? "passive_cancelled" : "passive_failed", pageID: input.basis.pageID)
        if let self, framePreparation?.id == id {
          framePreparation = nil
          // A refused allocation waits for a new basis or an accepted turn's
          // input allowance. A native loss before borrowing instead waits for
          // its next installation edge, without suppressing that edge or retrying.
          if error as? SceneRenderError == .resourceLimit { deferredFrameBasis = input.basis }
        }
        pending.finish(.failure(error))
      }
    }
    pending.task = task
    framePreparation = pending
    return pending
  }

  func acquire(page: PageDocument, readiness: PageTurnReadiness,
    priority: SceneAllocationPriority) async throws -> PageTurnFrame {
    frameReadiness = readiness
    guard let preparation, let key,
      sourcePage?.elementSourceIdentity == page.elementSourceIdentity else { throw PageTurnMaterialUnavailable.changed }
    let liveGeneration = liveSourceGeneration
    // Installed layers already belong to this owner. Await only an unfinished
    // preparation; a completed task must not put a cache hit behind other work
    // waiting for the main actor.
    if layers == nil {
      observe("acquire_wait_native", pageID: page.id)
      do { _ = try await preparation.value }
      catch {
        guard self.key == key, liveSourceGeneration == liveGeneration else { throw PageTurnMaterialUnavailable.changed }
        throw error
      }
    }
    try Task.checkCancellation()
    guard self.key == key, liveSourceGeneration == liveGeneration,
      let input = frameInput(readiness: readiness) else { throw PageTurnMaterialUnavailable.changed }
    if !input.basis.hasRuntime, let cachedFrame, cachedFrame.basis == input.basis,
      cachedInkTexture === input.ink?.texture {
      observe("acquire_cached", frameID: cachedFrame.frame.id)
      return cachedFrame.frame
    }
    let frame: PageTurnFrame
    if input.basis.hasRuntime {
      observe("acquire_live")
      // A mounted runtime may change without a durable state publication.
      // Freeze it now; never reuse the preceding turn's live DOM/CSS pixels.
      frame = try await Self.compose(input, readiness: readiness, priority: priority,
        observation: compositionObservation(pageID: input.basis.pageID))
    } else {
      if NotebookNavigationObservation.onPageMaterialPreparation != nil {
        observe(framePreparation?.basis == input.basis ? "acquire_join_passive"
          : deferredFrameBasis == input.basis ? "acquire_after_deferral"
          : cachedFrame != nil ? "acquire_changed_basis" : "acquire_uncached")
      }
      do { frame = try await prepareFrame(input, readiness: readiness).value() }
      catch SceneRenderError.resourceLimit where priority == .input {
        observe("acquire_input_fallback")
        // Optional page storage may be full while an accepted turn still has
        // its input allowance. Only this cancellable consumer owns that cut;
        // the shared passive producer never inherits input admission.
        try Task.checkCancellation()
        guard frameInput(readiness: readiness)?.basis == input.basis else { throw PageTurnMaterialUnavailable.changed }
        frame = try await Self.compose(input, readiness: readiness, priority: .input,
          observation: compositionObservation(pageID: input.basis.pageID))
      }
    }
    try Task.checkCancellation()
    guard frameInput(readiness: readiness)?.basis == input.basis else {
      observe("acquire_rejected_basis", frameID: frame.id)
      throw PageTurnMaterialUnavailable.changed
    }
    observe("acquire_completed", frameID: frame.id)
    return frame
  }

  private static func compose(_ input: FrameInput, readiness: PageTurnReadiness,
    priority: SceneAllocationPriority, observation: (@MainActor (String, TimeInterval) -> Void)? = nil) async throws -> PageTurnFrame {
    var materials: [PageTurnFrame.Layer] = []
    var retained: [AnyObject] = []
    observation?("slots_started", CACurrentMediaTime())
    let slots = try await acquireSlots(layers: input.layers, sources: input.sources,
      scale: input.key.scale, readiness: readiness, priority: priority)
    observation?("slots_ready", CACurrentMediaTime())
    try Task.checkCancellation()
    for (index, layer) in input.layers.enumerated() {
      switch layer {
      case .image(let pixels, let frame):
        materials.append(.frame(pixels, frame)); retained.append(pixels)
      case .element(_, _, _, let frame):
        guard let pixels = slots[index] else { throw PageTurnMaterialUnavailable.changed }
        materials.append(.image(pixels.image, frame)); retained.append(pixels)
      }
    }
    let measurement: (@MainActor (PageTurnFrame.CompositionTiming, TimeInterval) -> Void)?
    if let observation {
      measurement = { timing, resumed in
        observation("composition_worker_started", timing.workerBegan)
        observation("composition_encode_started", timing.encodingBegan)
        observation("composition_encode_finished", timing.encodingEnded)
        observation("composition_submitted", timing.submitted)
        observation("composition_gpu_started", timing.gpuBegan)
        observation("composition_gpu_finished", timing.gpuEnded)
        observation("composition_gpu_callback", timing.completionReceived)
        observation("composition_owner_resumed", resumed)
      }
    } else { measurement = nil }
    observation?("composition_started", CACurrentMediaTime())
    let frame = try await PageTurnFrame.compose(size: .init(width: input.key.size.width, height: input.key.size.height),
      scale: input.key.scale, layers: materials, priority: input.basis.hasRuntime ? priority : .passive,
      inputFallback: !input.basis.hasRuntime && priority == .input,
      ink: input.ink, retaining: retained, onCompositionMeasured: measurement)
    observation?("composition_ready", CACurrentMediaTime())
    return frame
  }

  private static func acquireSlots(layers: [Layer], sources: [String: AgentElement],
    scale: Double, readiness: PageTurnReadiness, priority: SceneAllocationPriority) async throws -> [Int: SlotPixels] {
    let indices = layers.indices.filter { if case .element = layers[$0] { return true }; return false }
    guard !indices.isEmpty else { return [:] }
    guard let activity = readiness.activity else { throw SceneRenderError.snapshotPending("page_material_slots") }
    var borrowed: [Int: SlotPixels] = [:], asynchronous: [Int] = []
    var direct = Set<Int>()
    for index in indices {
      try Task.checkCancellation()
      guard case .element(let element, let presentation, let cuts, _) = layers[index],
        let source = element.requiresLiveRuntime ? sources[element.id] : element else {
        throw PageTurnMaterialUnavailable.changed
      }
      if cuts.isEmpty, !presentation.requiresRasterTransform,
        activity.hasUncroppedElementFrame(page: readiness.pageIndex, source: source) {
        if let frame = try activity.borrowRasterElementFrame(page: readiness.pageIndex, source: source) {
          borrowed[index] = try untransformedPixels(frame)
          continue
        }
        direct.insert(index)
      }
      asynchronous.append(index)
    }
    guard !asynchronous.isEmpty else { return borrowed }
    let capture: @MainActor @Sendable (Int) async throws -> (Int, SlotPixels) = { index in
      try Task.checkCancellation()
      guard case .element(let element, let presentation, let cuts, let frame) = layers[index],
        let source = element.requiresLiveRuntime ? sources[element.id] : element else {
        throw PageTurnMaterialUnavailable.changed
      }
      return (index, try await slotPixels(element: source, presentation: presentation,
        cuts: cuts, frame: frame, scale: scale, readiness: readiness, priority: priority))
    }
    return try await withThrowingTaskGroup(of: (Int, SlotPixels).self) { group in
      // Submit on this material owner's actor before waiting. A generic-pool
      // child would first queue back to MainActor just to call WebKit, spreading
      // one accepted cohort across unrelated layout/preparation work. Immediate
      // children keep the group's cancellation and submitted resource fences.
      // Live providers reserve their pixels before WK submission and need no
      // serial copy allowance; installed raster borrows above need no tasks.
      // Copies/transforms still have four in flight: their temporary input and
      // output coexist, unlike the direct cuts retained until final composition.
      var remaining = asynchronous.filter { !direct.contains($0) }.makeIterator()
      var result = borrowed
      for index in asynchronous where direct.contains(index) { group.addImmediateTask { try await capture(index) } }
      for _ in 0..<4 {
        if let index = remaining.next() { group.addImmediateTask { try await capture(index) } }
      }
      while let (index, pixels) = try await group.next() {
        result[index] = pixels
        if !direct.contains(index), let next = remaining.next() { group.addImmediateTask { try await capture(next) } }
      }
      return result
    }
  }

  private static func slotPixels(element: AgentElement, presentation: NotebookElementPresentation,
    cuts: [InkElementErasure], frame: CGRect, scale: Double, readiness: PageTurnReadiness,
    priority: SceneAllocationPriority) async throws -> SlotPixels {
    guard let activity = readiness.activity else { throw SceneRenderError.snapshotPending("page_material_slots") }
    let cut = try await activity.acquireElementFrame(page: readiness.pageIndex, source: element,
      priority: priority)
    try Task.checkCancellation()
    if cuts.isEmpty, !presentation.requiresRasterTransform, cut.source.captureRegion == nil {
      // The accepted slot already has exactly these local pixels. Retain its
      // owner through GPU upload instead of copying it through another canvas.
      return try untransformedPixels(cut)
    }
    // Keep the canonical transform/erasure painter and the installed slot owner.
    let canvas = try await SceneRasterCompositor.create(size: frame.size, scale: scale, resources: .shared,
      priority: priority)
    let local = CGRect(origin: .zero, size: frame.size)
    let destination: CGRect
    if let crop = cut.source.captureRegion {
      let cropped = CGRect(x: crop.x, y: crop.y, width: crop.width, height: crop.height)
      destination = cropped.applying(presentation.transform)
    } else { destination = local }
    switch cut.pixels {
    case .cut(let pixels):
      try await canvas.draw(pixels, in: destination, erasures: cuts, elementFrame: local, presentation: presentation)
    case .raster(let raster):
      try await canvas.draw(raster, in: destination, erasures: cuts, elementFrame: local, presentation: presentation)
    }
    let pixels = try await canvas.finishImage()
    return .init(image: pixels.image, owner: pixels)
  }

  private static func untransformedPixels(_ frame: PageTurnElementFrame) throws -> SlotPixels {
    let image: CGImage?
    switch frame.pixels { case .cut(let pixels): image = pixels.image; case .raster(let raster): image = raster.image.cgImage }
    guard let image else { throw SceneRenderError.snapshotPending("page_element_pixels") }
    return .init(image: image, owner: frame)
  }

  private static func prepareLayers(page: PageDocument, erasures: InkElementErasureMap,
    ordered: Set<String>, scale: Double, retained: [String: NativeMaterial]) async throws -> PreparedLayers {
    let size = CGSize(width: page.size.width, height: page.size.height)
    let paperFrame = try await preparedPaper(size: size, scale: scale)
    var result: [Layer] = [.image(paperFrame, CGRect(origin: .zero, size: size))]
    var materials: [String: NativeMaterial] = [:]
    let graph = page.graphicGraph()
    let region = PageRect(x: 0, y: 0, width: page.size.width, height: page.size.height)
    for element in PageCompositionRenderer.elements(in: page, region: region, elementID: nil) {
      try Task.checkCancellation()
      let layout = element.graphic == nil ? nil : graph.resolve(element.id).layout
      let presentation = element.graphic == nil ? graph.placement(element.id).map { NotebookElementPresentation(element, placement: $0) } : nil
      guard let value = layout?.frame ?? presentation?.frame else { continue }
      let frame = CGRect(x: value.x, y: value.y, width: value.width, height: value.height)
      let cuts = erasures[element.id] ?? []
      let paintsBody = !ordered.contains(element.id)
      if !paintsBody, element.graphic?.label.isEmpty != false { continue }
      if element.graphic == nil, element.kind != .nativeText, let presentation {
        result.append(.element(agentElementSnapshotSource(element), presentation, cuts, frame)); continue
      }
      let nativeKey = NativeKey(source: agentElementSnapshotSource(element), layout: layout?.localLayout,
        projection: layout?.projection, size: frame.size, bodySize: presentation?.bodySize,
        transform: presentation?.transform, cuts: cuts, paintsBody: paintsBody, scale: scale)
      if let previous = retained[element.id], previous.key == nativeKey {
        materials[element.id] = previous; result.append(.image(previous.frame, frame)); continue
      }
      let appearance = try await NotebookElementErasureCache.Input(graphic: element.graphic,
        layout: layout, size: presentation?.bodySize ?? frame.size, erasures: cuts).prepared()
      let canvas = try await SceneRasterCompositor.create(size: frame.size, scale: scale, resources: .shared)
      let local = CGRect(origin: .zero, size: frame.size)
      if let graphic = element.graphic {
        if graphic.freehand != nil, paintsBody { try await InkRasterRenderer.shared.prepareInk() }
        try await canvas.drawView(NotebookGraphicView(graphic: graphic, layout: layout, erasures: cuts,
          appearance: appearance, live: false, paintsMeasuredBody: paintsBody), size: frame.size, in: local)
      } else {
        try await canvas.drawView(NotebookPlacedElement(presentation: presentation) {
          NotebookNativeTextSnapshot(source: element.source, style: element.textStyle ?? .standard)
            .snapshotErased(by: cuts, appearance: appearance)
        }, size: frame.size, in: local)
      }
      let pixels = try await canvas.finishImage()
      let material = try await PageTurnFrame.compose(size: frame.size, scale: scale,
        images: [.init(image: pixels.image, frame: local)], retaining: [pixels])
      materials[element.id] = .init(key: nativeKey, frame: material)
      result.append(.image(material, frame))
    }
    return .init(layers: result, native: materials)
  }

  /// The trailing creation slot borrows precisely this grid, without the
  /// neighbouring page's elements/ink or another full-page raster/upload.
  static func preparedPaper(size: CGSize, scale: Double,
    resources: SceneRenderResources = .shared,
    priority: SceneAllocationPriority = .passive) async throws -> PageTurnFrame {
    let key = PaperKey(resources: ObjectIdentifier(resources), width: size.width, height: size.height, scale: scale)
    paperFrames = paperFrames.filter { $0.value.frame != nil }
    if let frame = paperFrames[key]?.frame { return frame }
    if let pending = paperPreparations[key] {
      do { return try await pending.task.value }
      catch SceneRenderError.resourceLimit where priority == .input && pending.priority == .passive {
        // A real turn can join a speculative grid whose passive admission was
        // refused. Promote that demand once; no availability polling/retry loop.
        try Task.checkCancellation()
        if paperPreparations[key]?.id == pending.id { paperPreparations[key] = nil }
        return try await preparedPaper(size: size, scale: scale, resources: resources, priority: .input)
      }
    }
    guard paperPreparations.count < 8 else { throw SceneRenderError.resourceLimit }
    let task = Task { @MainActor in
      let paper = try await SceneRasterCompositor.create(size: size, scale: scale, resources: resources, priority: priority)
      try await paper.drawPaper(size: size, in: CGRect(origin: .zero, size: size))
      let pixels = try await paper.finishImage()
      return try await PageTurnFrame.compose(size: size, scale: scale,
        images: [.init(image: pixels.image, frame: CGRect(origin: .zero, size: size))], resources: resources,
        priority: priority, retaining: [pixels])
    }
    let pending = PaperPreparation(priority: priority, task: task)
    paperPreparations[key] = pending
    defer { if paperPreparations[key]?.id == pending.id { paperPreparations[key] = nil } }
    let frame = try await task.value
    if paperFrames.count < 8 { paperFrames[key] = PaperReference(frame) }
    return frame
  }

  isolated deinit {
    preparation?.cancel(); slotPreparation?.cancel(); framePreparation?.cancel()
    if let slotObserver { slotActivity?.removePreparationObserver(slotObserver) }
    if let reclamationOwner { SceneRenderResources.shared.unregisterReclamationOwner(reclamationOwner) }
  }
}
#endif

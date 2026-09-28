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
  private struct PaperKey: Hashable { let width, height, scale: Double }
  private final class PaperReference {
    weak var frame: PageTurnFrame?
    init(_ frame: PageTurnFrame) { self.frame = frame }
  }
  // The grid is the same immutable material on equal physical paper. The
  // directory never owns pixels: the last resident page releases them. A small
  // single-flight directory prevents adjacent pages uploading it concurrently.
  private static var paperFrames: [PaperKey: PaperReference] = [:]
  private static var paperPreparations: [PaperKey: Task<PageTurnFrame, Error>] = [:]
  private struct Key: Equatable {
    let native: [AgentElement]
    let slots: [String: NotebookElementPresentation]
    let staticSources: [String: SceneRasterSource]
    let size: PageSize
    let erasures: [String: [InkElementErasure]]
    let ordered: Set<String>
    let scale: Double
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
  private struct FramePreparation {
    let id: UUID
    let basis: FrameBasis
    let task: Task<PageTurnFrame, Error>
  }
  private var key: Key?
  // Retain the current source behind its identity; a recycled object address
  // must not make a different page's elements reuse the previous artwork.
  private var sourcePage: PageDocument?
  // Program state/code changes replace the live slot input, not the already
  // prepared paper and native artwork. Capture freezes this separate basis.
  private var liveSources: [String: AgentElement] = [:]
  private var liveSourceGeneration: UInt64 = 0
  private var preparation: Task<[Layer], Error>?
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
          self?.deferredFrameBasis = self?.cachedFrame?.basis
          self?.cachedFrame = nil
          self?.cachedInkTexture = nil
          return nil
        })]
    }
  }
  var isPrepared: Bool {
    guard let layers else { return false }
    return !layers.contains { if case .element(let element, _, _, _) = $0 { return !element.requiresLiveRuntime }; return false }
  }

  func isCapturable(readiness: PageTurnReadiness) -> Bool {
    guard isPrepared, let layers else { return false }
    return layers.allSatisfy { layer in
      guard case .element(let element, _, _, _) = layer else { return true }
      let source = element.requiresLiveRuntime ? liveSources[element.id] : element
      guard let source else { return false }
      return readiness.activity?.hasElementFrame(page: readiness.pageIndex, source: source) == true
    }
  }

  func prepare(page: PageDocument, erasures: [String: [InkElementErasure]], ordered: Set<String>, scale: Double,
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
        liveSources = currentLiveSources; liveSourceGeneration &+= 1; invalidateFrame()
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
    invalidateFrame(); preparation?.cancel(); slotPreparation?.cancel(); slotPreparation = nil
    slotPreparationHasWake = false
    notifySlotsReady = nil; layers = nil
    preparation = Task { @MainActor [weak self] in
      do {
        let result = try await Self.prepareLayers(page: page, erasures: erasures, ordered: ordered, scale: scale)
        try Task.checkCancellation()
        if let self, self.key == key {
          self.layers = result
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

  /// Static WebKit output is already owned by the installed element. Flatten its
  /// transform and erasures once during readiness, not at the first sheet bend.
  func prepareStaticSlots(readiness: PageTurnReadiness,
    onReady: @escaping @MainActor () -> Void,
    onFailure: @escaping @MainActor (PageTurnPreparationFailure) -> Void) {
    guard let layers, let key,
      layers.contains(where: { if case .element = $0 { return true }; return false }) else {
      notifySlotsReady = nil
      if let slotObserver { slotActivity?.removePreparationObserver(slotObserver) }
      slotObserver = nil; slotActivity = nil; slotReadiness = nil
      return
    }
    // Live slots keep one addressed observer after static preparation. Its
    // weak receipt publishes capture readiness without retaining PageSurface.
    notifySlotsReady = isPrepared ? nil : onReady
    slotReadiness = readiness
    if slotActivity !== readiness.activity {
      if let slotObserver { slotActivity?.removePreparationObserver(slotObserver) }
      slotActivity = readiness.activity
      slotObserver = slotActivity?.observePreparation { [weak self] change in
        guard case .elementFrames(let page, let materialChanged) = change, let self,
          let readiness = slotReadiness, readiness.pageIndex == page else { return }
        if isPrepared {
          if materialChanged { invalidateFrame() }
          refreshPassiveFrame()
          let capturable = isCapturable(readiness: readiness) && readiness.inkFrameIsReady?() == true
          if capturable != readiness.state.capturable {
            readiness(readiness.state.presented, capturable: capturable)
          } else { readiness.materialDidChange() }
        } else if slotPreparation == nil { notifySlotsReady?() }
        else { slotPreparationHasWake = true }
      }
    }
    guard !isPrepared, slotPreparation == nil else { return }
    // The slot's own native installation certifies its exact pixels. The
    // page-wide overlay also includes live masks whose OS display can wait
    // until this covered leaf is exposed at the curl endpoint.
    guard layers.allSatisfy({ layer in
      guard case .element(let element, _, _, _) = layer, !element.requiresLiveRuntime else { return true }
      return readiness.activity?.hasElementFrame(page: readiness.pageIndex, source: element) == true
    }) else { return }
    slotPreparationHasWake = false
    slotPreparation = Task { @MainActor [weak self] in
      do {
        var prepared: [Layer] = []
        for layer in layers {
          try Task.checkCancellation()
          if case .element(let element, let presentation, let cuts, let frame) = layer,
            !element.requiresLiveRuntime {
            let pixels = try await Self.slotPixels(element: element, presentation: presentation,
              cuts: cuts, frame: frame, scale: key.scale, readiness: readiness, priority: .passive)
            let image = try await PageTurnFrame.compose(size: frame.size, scale: key.scale,
              images: [.init(image: pixels.image, frame: CGRect(origin: .zero, size: frame.size))], retaining: [pixels])
            prepared.append(.image(image, frame))
          } else { prepared.append(layer) }
        }
        try Task.checkCancellation()
        guard let self, self.key == key else { return }
        self.layers = prepared; self.slotPreparation = nil
        self.slotPreparationHasWake = false
        let notify = self.notifySlotsReady; self.notifySlotsReady = nil; notify?()
      } catch {
        guard !(error is CancellationError), let self, self.key == key else { return }
        if error is PageTurnMaterialUnavailable {
          // Consume an installation edge received during this borrow once.
          // The admission guard still requires every static provider to be
          // current. With no new edge, wait instead of retrying this task.
          let needsWake = self.slotPreparationHasWake
          self.slotPreparationHasWake = false
          self.slotPreparation = nil
          if needsWake { self.notifySlotsReady?() }
          return
        }
        self.slotPreparation = nil; self.notifySlotsReady = nil
        self.slotPreparationHasWake = false
        onFailure(.init(kind: error as? SceneRenderError == .resourceLimit ? .resourceLimit : .preparationFailed,
          message: "Не удалось подготовить элементы листа для перелистывания", retry: { [weak self] in
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
    key = nil; sourcePage = nil; layers = nil
    liveSources = [:]; liveSourceGeneration &+= 1
    invalidateFrame(); preparesPassiveFrame = false; frameReadiness = nil
  }

  /// The page's existing source, provider and ink readiness events prepare a
  /// covered neighbour. The visible writing page never composes on every lift.
  func preparePassiveFrame(readiness: PageTurnReadiness, enabled: Bool) {
    if preparesPassiveFrame, !enabled, !readiness.isInActiveTurn() {
      framePreparation?.task.cancel(); framePreparation = nil
    }
    frameReadiness = readiness; preparesPassiveFrame = enabled
    refreshPassiveFrame()
  }

  private func invalidateFrame() {
    framePreparation?.task.cancel(); framePreparation = nil
    cachedFrame = nil; cachedInkTexture = nil; deferredFrameBasis = nil
  }

  private func frameInput(readiness: PageTurnReadiness) -> FrameInput? {
    guard !readiness.isRetired, isPrepared, let key, let layers, let sourcePage,
      readiness.inkFrameIsReady?() == true else { return nil }
    let ink = readiness.inkFrame?()
    guard ink != nil || readiness.inkFrameIsEmpty?() == true else { return nil }
    var providers: [String: PageTurnActivity.ElementFrameVersion] = [:]
    for layer in layers {
      guard case .element(let element, _, _, _) = layer else { continue }
      guard let source = element.requiresLiveRuntime ? liveSources[element.id] : element,
        let version = readiness.activity?.elementFrameVersion(page: readiness.pageIndex, source: source) else { return nil }
      providers[element.id] = version
    }
    return .init(basis: .init(pageID: sourcePage.id, material: materialGeneration,
      liveSource: liveSourceGeneration, providers: providers,
      inkGeneration: ink?.generation, inkTexture: ink.map { ObjectIdentifier($0.texture) }),
      key: key, layers: layers, sources: liveSources, ink: ink)
  }

  private func refreshPassiveFrame() {
    guard preparesPassiveFrame || cachedFrame != nil || framePreparation != nil else { return }
    guard let readiness = frameReadiness else { return }
    guard let input = frameInput(readiness: readiness) else {
      // A temporary native detach or ink installation gap prevents borrowing,
      // but does not change already accepted pixels. Revalidate their full
      // source/provider/ink basis when installation returns.
      framePreparation?.task.cancel(); framePreparation = nil
      return
    }
    if cachedFrame?.basis != input.basis || cachedInkTexture !== input.ink?.texture {
      cachedFrame = nil; cachedInkTexture = nil
    }
    if let pending = framePreparation, pending.basis != input.basis {
      pending.task.cancel(); framePreparation = nil
    }
    guard preparesPassiveFrame, !input.basis.hasRuntime, cachedFrame == nil,
      framePreparation == nil, deferredFrameBasis != input.basis else { return }
    _ = prepareFrame(input, readiness: readiness)
  }

  /// A turn joins the exact producer already preparing its accepted basis.
  /// Cancellation of one consumer does not cancel the page's material task.
  private func prepareFrame(_ input: FrameInput, readiness: PageTurnReadiness) -> Task<PageTurnFrame, Error> {
    if framePreparation?.basis == input.basis, let task = framePreparation?.task { return task }
    framePreparation?.task.cancel()
    let id = UUID()
    let task = Task { @MainActor [weak self, weak readiness] in
      do {
        guard let readiness else { throw PageTurnMaterialUnavailable.changed }
        let frame = try await Self.compose(input, readiness: readiness, priority: .passive)
        try Task.checkCancellation()
        guard let self, !readiness.isRetired, framePreparation?.id == id,
          frameInput(readiness: readiness)?.basis == input.basis else { throw PageTurnMaterialUnavailable.changed }
        framePreparation = nil
        if frame.allocationPriority == .passive {
          cachedFrame = (input.basis, frame)
          cachedInkTexture = input.ink?.texture
          SceneRenderResources.shared.reclamationOffersChanged()
        }
        return frame
      } catch {
        if let self, framePreparation?.id == id {
          framePreparation = nil
          // Optional preparation cannot block installed paper/input or spin on
          // a refused allocation. The accepted turn reports its own failure.
          deferredFrameBasis = input.basis
        }
        throw error
      }
    }
    framePreparation = .init(id: id, basis: input.basis, task: task)
    return task
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
      cachedInkTexture === input.ink?.texture { return cachedFrame.frame }
    let frame: PageTurnFrame
    if input.basis.hasRuntime {
      // A mounted runtime may change without a durable state publication.
      // Freeze it now; never reuse the preceding turn's live DOM/CSS pixels.
      frame = try await Self.compose(input, readiness: readiness, priority: priority)
    } else {
      do { frame = try await prepareFrame(input, readiness: readiness).value }
      catch SceneRenderError.resourceLimit where priority == .input {
        // Optional page storage may be full while an accepted turn still has
        // its input allowance. Only this cancellable consumer owns that cut;
        // the shared passive producer never inherits input admission.
        try Task.checkCancellation()
        guard frameInput(readiness: readiness)?.basis == input.basis else { throw PageTurnMaterialUnavailable.changed }
        frame = try await Self.compose(input, readiness: readiness, priority: .input)
      }
    }
    try Task.checkCancellation()
    guard frameInput(readiness: readiness)?.basis == input.basis else { throw PageTurnMaterialUnavailable.changed }
    return frame
  }

  private static func compose(_ input: FrameInput, readiness: PageTurnReadiness,
    priority: SceneAllocationPriority) async throws -> PageTurnFrame {
    var materials: [PageTurnFrame.Layer] = []
    var retained: [AnyObject] = []
    let slots = try await acquireSlots(layers: input.layers, sources: input.sources,
      scale: input.key.scale, readiness: readiness, priority: priority)
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
    return try await PageTurnFrame.compose(size: .init(width: input.key.size.width, height: input.key.size.height),
      scale: input.key.scale, layers: materials, priority: input.basis.hasRuntime ? priority : .passive,
      inputFallback: !input.basis.hasRuntime && priority == .input,
      ink: input.ink, retaining: retained)
  }

  private static func acquireSlots(layers: [Layer], sources: [String: AgentElement],
    scale: Double, readiness: PageTurnReadiness, priority: SceneAllocationPriority) async throws -> [Int: SlotPixels] {
    let indices = layers.indices.filter { if case .element = layers[$0] { return true }; return false }
    let direct = Set(indices.filter { index in
      guard priority == .input,
        case .element(let element, let presentation, let cuts, _) = layers[index],
        cuts.isEmpty, !presentation.requiresRasterTransform,
        let source = element.requiresLiveRuntime ? sources[element.id] : element else { return false }
      return readiness.activity?.hasUncroppedElementFrame(page: readiness.pageIndex, source: source) == true
    })
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
      // Each provider reserves its physical pixels before WK submission.
      // Copies/transforms still have four in flight: their temporary input and
      // output coexist, unlike the direct cuts retained until final composition.
      var remaining = indices.filter { !direct.contains($0) }.makeIterator()
      var result: [Int: SlotPixels] = [:]
      for index in indices where direct.contains(index) { group.addTask { try await capture(index) } }
      for _ in 0..<4 {
        if let index = remaining.next() { group.addTask { try await capture(index) } }
      }
      while let (index, pixels) = try await group.next() {
        result[index] = pixels
        if !direct.contains(index), let next = remaining.next() { group.addTask { try await capture(next) } }
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
      let image: CGImage?
      switch cut.pixels { case .cut(let pixels): image = pixels.image; case .raster(let raster): image = raster.image.cgImage }
      guard let image else { throw SceneRenderError.snapshotPending("page_element_pixels") }
      // The accepted slot already has exactly these local pixels. Retain its
      // owner through GPU upload instead of copying it through another canvas.
      return .init(image: image, owner: cut)
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

  private static func prepareLayers(page: PageDocument, erasures: [String: [InkElementErasure]],
    ordered: Set<String>, scale: Double) async throws -> [Layer] {
    let size = CGSize(width: page.size.width, height: page.size.height)
    let paperFrame = try await preparedPaper(size: size, scale: scale)
    var result: [Layer] = [.image(paperFrame, CGRect(origin: .zero, size: size))]
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
      let appearance = try await NotebookElementErasureCache.Input(graphic: element.graphic,
        layout: layout, size: presentation?.bodySize ?? frame.size, erasures: cuts).prepared()
      let canvas = try await SceneRasterCompositor.create(size: frame.size, scale: scale, resources: .shared)
      let local = CGRect(origin: .zero, size: frame.size)
      if let graphic = element.graphic {
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
      result.append(.image(material, frame))
    }
    return result
  }

  private static func preparedPaper(size: CGSize, scale: Double) async throws -> PageTurnFrame {
    let key = PaperKey(width: size.width, height: size.height, scale: scale)
    paperFrames = paperFrames.filter { $0.value.frame != nil }
    if let frame = paperFrames[key]?.frame { return frame }
    if let pending = paperPreparations[key] { return try await pending.value }
    guard paperPreparations.count < 8 else { throw SceneRenderError.resourceLimit }
    let task = Task { @MainActor in
      let paper = try await SceneRasterCompositor.create(size: size, scale: scale, resources: .shared)
      try await paper.drawView(GridPaperView(), size: size, in: CGRect(origin: .zero, size: size))
      let pixels = try await paper.finishImage()
      return try await PageTurnFrame.compose(size: size, scale: scale,
        images: [.init(image: pixels.image, frame: CGRect(origin: .zero, size: size))], retaining: [pixels])
    }
    paperPreparations[key] = task
    defer { paperPreparations[key] = nil }
    let frame = try await task.value
    if paperFrames.count < 8 { paperFrames[key] = PaperReference(frame) }
    return frame
  }

  isolated deinit {
    preparation?.cancel(); slotPreparation?.cancel(); framePreparation?.task.cancel()
    if let slotObserver { slotActivity?.removePreparationObserver(slotObserver) }
    if let reclamationOwner { SceneRenderResources.shared.unregisterReclamationOwner(reclamationOwner) }
  }
}
#endif

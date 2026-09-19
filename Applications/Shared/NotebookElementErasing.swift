import CoreGraphics
import Foundation
import Observation
import NotebookCore

struct NotebookElementErasing {
  let id: UUID
  let surface: SurfaceID
  let samples: [SpatialInkSample]
  let targets: [InkElementTarget]
  var accepted = false

  var masks: [String: [InkElementErasure]] {
    Dictionary(uniqueKeysWithValues: targets.map {
      ($0.elementID, [InkElementErasure(target: $0, samples: samples)])
    })
  }
}

/// One model-owned derived projection for paint, picking and accessibility.
/// Authored erasures remain in their ink actions. No state is persisted here.
@MainActor @Observable final class NotebookElementErasureCache {
  struct Input: Equatable, Sendable {
    let graphic: NotebookGraphic?
    let layout: NotebookGraphicLayout?
    let size: CGSize
    let erasures: [InkElementErasure]
    init(graphic: NotebookGraphic?, layout: NotebookGraphicLayout?, size: CGSize, erasures: [InkElementErasure]) {
      self.graphic = graphic
      self.layout = graphic?.shape == .connector ? layout : nil
      self.size = size; self.erasures = erasures
    }
    static func == (a: Self, b: Self) -> Bool {
      // Layout curves/heads are local. Translating the element or its camera
      // does not invalidate pixels; resizing or moving a bound endpoint does.
      a.graphic == b.graphic && a.size == b.size && a.erasures == b.erasures
        && a.layout?.curves == b.layout?.curves && a.layout?.heads == b.layout?.heads
        && a.layout?.label == b.layout?.label
    }
    func prepare() -> NotebookElementAppearance {
      .init(graphic:graphic,layout:layout,size:size,erasures:erasures)
    }

    /// CPU snapshots must never rasterize the live overlapping triangle mask
    /// on MainActor. Cancellation also revokes the worker's unpublished result.
    func prepared() async throws -> NotebookElementAppearance? {
      guard !erasures.isEmpty else { return nil }
      let worker = Task.detached(priority: .userInitiated) {
        try Task.checkCancellation()
        let value = prepare()
        try Task.checkCancellation()
        return value
      }
      return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
  }
  private struct Address: Hashable { let surface: SurfaceID; let id: String }
  private struct Entry {
    let input: Input
    let token: UInt64
    let task: Task<Void, Never>
    var value: NotebookElementAppearance?
  }
  private actor Preparation {
    func prepare(_ input: Input) -> NotebookElementAppearance? {
      guard !Task.isCancelled else { return nil }
      let value = input.prepare()
      return Task.isCancelled ? nil : value
    }
  }
  @ObservationIgnored private let preparation = Preparation()
  @ObservationIgnored private var entries: [Address: Entry] = [:]
  @ObservationIgnored private var sequence: UInt64 = 0
  @ObservationIgnored private var stopped = false
  @ObservationIgnored private(set) var preparationCount = 0
  private var publication: UInt64 = 0

  /// A changed input never receives an old appearance. While preparation is
  /// pending, measured ink still paints, but cannot become a ghost hit target.
  func appearance(surface: SurfaceID, id: String, graphic: NotebookGraphic?,
    layout: NotebookGraphicLayout?, size: CGSize, erasures: [InkElementErasure]) -> NotebookElementAppearance? {
    _ = publication
    guard !stopped else { return nil }
    let address = Address(surface:surface,id:id)
    guard !erasures.isEmpty else {
      if entries[address]?.value == nil { entries.removeValue(forKey:address)?.task.cancel() }
      return nil
    }
    if erasures.contains(where: { $0.target.wholeElement }) {
      entries.removeValue(forKey: address)?.task.cancel()
      return .init(graphic: nil, layout: nil, size: size, erasures: erasures)
    }
    let input = Input(graphic:graphic,layout:layout,size:size,erasures:erasures)
    sequence &+= 1
    if let entry = entries[address], entry.input == input { return entry.value }
    entries.removeValue(forKey:address)?.task.cancel()
    let token = sequence, worker = preparation
    let task = Task { [weak self] in
      let value = await worker.prepare(input)
      guard !Task.isCancelled, let self, !self.stopped,
        self.entries[address]?.token == token, let value else { return }
      self.entries[address]?.value = value
      self.publication &+= 1
    }
    preparationCount += 1
    entries[address] = Entry(input:input,token:token,task:task,value:nil)
    return nil
  }

  // Lifetime follows the already bounded model workset. An arbitrary entry
  // count would evict still-mounted siblings and restart them on every publish.
  func retain(pages: [UUID: PageDocument]) {
    let owners = pages.mapValues { Set($0.elements.map(\.id)) }
    discard { address in
      address.surface.kind == .page && !(address.surface.ownerID.flatMap { owners[$0] }?.contains(address.id) ?? false)
    }
    self.pages = self.pages.filter { pages[$0.key] != nil }
  }

  func retain(hierarchy: BoardHierarchy?) {
    var owners: [SurfaceID: Set<String>] = [:]
    for node in hierarchy?.boards ?? [] {
      for element in node.board.elements { owners[element.surface, default: []].insert(element.id) }
    }
    discard { $0.surface.kind != .page && !(owners[$0.surface]?.contains($0.id) ?? false) }
  }

  private func discard(where removes: (Address) -> Bool) {
    for address in entries.keys.filter(removes) { entries.removeValue(forKey:address)?.task.cancel() }
  }

  func stop() async {
    stopped = true
    let tasks = entries.values.map(\.task)
    for task in tasks { task.cancel() }
    entries.removeAll(); pages.removeAll(); spatial.removeAll()
    for task in tasks { await task.value }
  }

  @ObservationIgnored private var pages: [UUID: (Data, [String: [InkElementErasure]])] = [:]
  @ObservationIgnored private var spatial: [SurfaceID: [String: [InkElementErasure]]] = [:]
  func record(_ change: PreparedPageInkChange) {
    if pages.count >= 8 { pages.removeAll() }
    pages[change.pageID] = (change.data, change.drawing.elementErasures)
  }
  func page(_ page: PageDocument) -> [String: [InkElementErasure]] {
    if let cached = pages[page.id], cached.0 == page.drawingData { return cached.1 }
    let masks = (try? PageInkDrawing.decode(page.drawingData).elementErasures) ?? [:]
    if pages.count >= 8 { pages.removeAll() }
    pages[page.id] = (page.drawingData, masks)
    return masks
  }
  func invalidateSpatial() { spatial.removeAll() }
  func masks(on surface: SurfaceID, journal: SpatialInkJournal?) -> [String: [InkElementErasure]] {
    if let cached = spatial[surface] { return cached }
    let masks = journal?.elementErasures(on: surface) ?? [:]
    spatial[surface] = masks
    return masks
  }
}

extension NotebookAppModel {
  func eraserTargets(pageID: UUID) -> [InkElementTarget] {
    guard let page = pages[pageID] else { return [] }
    let graph = graphicGraph(page: page)
    return pageElementsForDisplay(page).compactMap { element in
      let frame: PageRect
      if element.graphic != nil {
        guard let layout = graph.resolve(element.id).layout else { return nil }; frame = layout.frame
      } else { frame = element.frame }
      return .init(elementID: element.id, frame: frame, wholeElement: element.kind == .web,graphicTransform:element.graphic?.transform)
    }
  }

  func eraserTargets(boardID: UUID, cohort: SceneCompositionCohort) -> [SurfaceID: [InkElementTarget]] {
    let graph = presentedGraphicGraph(boardID: boardID, cohort: cohort)
    let board = cohort.frame.index.capturedHierarchy.board(boardID).map { presentedBoard($0, boardID: boardID, cohort: cohort) }
    var result: [SurfaceID: [InkElementTarget]] = [:]
    for element in board?.elements ?? [] where element.graphic == nil {
      result[element.surface, default: []].append(.init(elementID: element.id,
        frame: .init(x: element.frame.x, y: element.frame.y, width: element.frame.width, height: element.frame.height),
        worldOrigin: element.worldOrigin, wholeElement: element.kind == .web,graphicTransform:element.graphic?.transform))
    }
    for node in graph.nodes.values {
      guard let layout = graph.resolve(node.id).layout else { continue }
      result[node.surface, default: []].append(.init(elementID: node.id, frame: layout.frame,
        worldOrigin: node.surface.kind == .board ? node.origin : nil,graphicTransform:node.graphic.transform))
    }
    return result
  }

  func updateElementErasing(_ contact: [NotebookElementErasing], id: UUID) {
    // Once lift transfers this contact to the model, an old paper's refresh
    // or teardown cannot retract it while preparation is still pending.
    guard workingElementErasures[id]?.contains(where: \.accepted) != true else { return }
    let visible = contact.filter { !$0.targets.isEmpty }
    if visible.isEmpty {
      // An inactive canvas may cancel during every SwiftUI update. A no-op
      // must not publish another update and strand the opened paper in a loop.
      if workingElementErasures[id] != nil { workingElementErasures[id] = nil }
    } else { workingElementErasures[id] = visible }
  }

  func elementErasures(on surface: SurfaceID, fallback: SpatialInkJournal? = nil) -> [String: [InkElementErasure]] {
    var result: [String: [InkElementErasure]]
    if surface.kind == .page, let id = surface.ownerID, let page = pages[id] {
      result = elementErasureCache.page(page)
    } else if loadedInkSurfaces.contains(surface) || fallback == nil {
      result = elementErasureCache.masks(on: surface, journal: spatialInk)
    } else { result = fallback?.elementErasures(on: surface) ?? [:] }
    for contacts in workingElementErasures.values {
      for contact in contacts where contact.surface == surface {
        result.merge(contact.masks) { $0 + $1 }
      }
    }
    return result
  }
}

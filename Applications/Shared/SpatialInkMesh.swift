import Foundation
import NotebookCore

/// The source installed by one physical canvas. Retaining it and appending a
/// finished contact do not walk or copy the baseline's sample arrays.
struct SpatialInkInstalledSource: Sendable {
  let surface: SurfaceID
  let suppressedInkIDs: Set<UUID>
  private let baseline: SpatialInkJournal
  private var finished: [SpatialInkAction] = []

  init(surface: SurfaceID, journal: SpatialInkJournal, suppressedInkIDs: Set<UUID> = []) {
    self.surface = surface; baseline = journal; self.suppressedInkIDs = suppressedInkIDs
  }

  var journalRevision: String {
    finished.reduce(baseline.stamp) { max($0, max($1.stamp, $1.stateStamp)) }.revision
  }

  func appending(_ action: SpatialInkAction) -> Self {
    var value = self
    value.finished.append(action)
    return value
  }

  /// Only the persistence worker resolves the retained tail and exact records.
  func referenceInk() throws -> NotebookReferenceInk {
    var actions = Dictionary(uniqueKeysWithValues: baseline.actions.filter { $0.spans.contains { $0.surface == surface } }.map { ($0.id, $0) })
    for action in finished where action.spans.contains(where: { $0.surface == surface }) {
      if let previous = actions[action.id], previous != action {
        throw CollaborationError("capture_source_changed", "Один контакт получил несовместимые источники чернил.")
      }
      actions[action.id] = action
    }
    return try .init(surface: surface, actions: Array(actions.values))
  }

  /// Runs on the mesh worker. Canonical undo wins by the journal's existing
  /// causal rule; a finished local contact not yet echoed by SQL is retained.
  /// The old baseline is not merged back into a newly read source.
  func reconciled(with journal: SpatialInkJournal) throws -> SpatialInkJournal {
    let incoming = journal.actions.filter { $0.spans.contains { $0.surface == surface } }
    let byID = Dictionary(uniqueKeysWithValues: incoming.map { ($0.id, $0) })
    for action in finished {
      if let other = byID[action.id],
        (other.stamp != action.stamp || other.tool != action.tool || other.color != action.color || other.spans != action.spans) {
        throw CollaborationError("capture_source_changed", "Неизменяемые точки принятого контакта получили другой источник.")
      }
    }
    var result = SpatialInkJournal(actions: incoming, stamp: journal.stamp)
    let tailStamp = finished.reduce(baseline.stamp) { max($0, max($1.stamp, $1.stateStamp)) }
    _ = result.merge(.init(actions: finished, stamp: tailStamp))
    return result
  }
}

/// Nodes stay near their physical origin. Camera motion changes one uniform
/// per span, never the measured samples or compact node buffers.
struct SpatialInkMesh: Sendable {
  enum Projection: Equatable, Sendable {
    case local
    case world(WorldPoint)
    case screen(SpatialCamera, SpatialPoint)

    func transform(camera: SpatialCamera?, viewport: SpatialPoint) -> SIMD4<Float> {
      guard let camera else { return .init(1, 1, 0, 0) }
      switch self {
      case .local: return .init(1, 1, 0, 0)
      case .world(let origin):
        let point = camera.worldToScreen(origin, viewport: viewport)
        return .init(Float(camera.scale), Float(camera.scale), Float(point.x), Float(point.y))
      case .screen(let source, let sourceViewport):
        let origin = source.screenToWorld(.init(x: 0, y: 0), viewport: sourceViewport)
        let point = camera.worldToScreen(origin, viewport: viewport)
        let scale = Float(camera.scale / source.scale)
        return .init(scale, scale, Float(point.x), Float(point.y))
      }
    }
  }

  typealias Chunk = SpatialInkGeometry.Chunk

  struct Batch: Sendable {
    typealias Part = SpatialInkGeometry.Source
    let tool: SpatialInkTool
    let projection: Projection
    let parts: [Part]
    private let starts: [Int]
    private let partIndex: InkBoundsIndex?
    let chunkCount: Int
    var sourceNodeCount: Int { parts.reduce(0) { $0+$1.sourceNodeCount } }
    var preparedNodeCount: Int { parts.reduce(0) { $0+$1.preparedNodeCount } }
    var isEmpty: Bool { chunkCount == 0 }
    private var indexBytes: Int { (partIndex?.byteCount ?? 0)+starts.count*MemoryLayout<Int>.stride+parts.count*MemoryLayout<Part>.stride }
    var byteCount: Int { indexBytes+parts.reduce(0) { $0+$1.byteCount } }
    var auxiliaryBytes: Int { indexBytes+parts.reduce(0) { $0+$1.auxiliaryBytes } }
    init(tool: SpatialInkTool,projection: Projection,parts: [Part]) {
      self.tool=tool;self.projection=projection;self.parts=parts
      var count=0,starts:[Int]=[]
      for part in parts { starts.append(count);count += part.chunkCount }
      self.starts=starts;chunkCount=count;partIndex = parts.count > 1 ? .init(parts.map(\.bounds)) : nil
    }
    init(source: InkSampleRelations,projection: Projection,sampleProjection: InkSampleProjection = .init()) {
      self.init(tool:source.header.tool,projection:projection,parts:[.init(source:source,projection:sampleProjection)])
    }
    init(tool: SpatialInkTool,nodes: [SpatialInkGeometry.Node],color: SIMD4<Float>,projection: Projection) {
      self.init(tool:tool,nodes:nodes,chunks:SpatialInkGeometry.chunks(for:nodes,color:color,eraser:tool == .eraser),projection:projection)
    }
    init(tool: SpatialInkTool,nodes: [SpatialInkGeometry.Node],chunks: [Chunk],projection: Projection) {
      self.init(tool:tool,projection:projection,parts:[.init(nodes:nodes,chunks:chunks)])
    }
    func query(viewport: CGRect,affine: InkAffine,admitting: ((CGRect) -> Bool)? = nil) -> (chunks: [Range<Int>],cost: InkSampleRelations.AccessCost) {
      let viewport=viewport.insetBy(dx:-1,dy:-1)
      let candidates: [Int]
      var cost=InkSampleRelations.AccessCost()
      if let partIndex,affine.x.y == 0,affine.y.x == 0,affine.x.x > 0,affine.y.y > 0 {
        let area=CGRect(x:(viewport.minX-Double(affine.x.z))/Double(affine.x.x),y:(viewport.minY-Double(affine.y.z))/Double(affine.y.y),
          width:viewport.width/Double(affine.x.x),height:viewport.height/Double(affine.y.y))
        let q=partIndex.query(area);candidates=q.indices;cost.visitedNodes=q.visitedNodes
      } else { candidates=parts.indices.filter { affine.bounds(parts[$0].bounds).intersects(viewport) };cost.visitedNodes=parts.count }
      var result:[Range<Int>]=[]
      for id in candidates {
        let q=parts[id].query(viewport:viewport,affine:affine,admitting:admitting)
        result.append(contentsOf:q.chunks.map { (starts[id]+$0.lowerBound)..<(starts[id]+$0.upperBound) })
        cost.visitedNodes += q.cost.visitedNodes;cost.jumps += q.cost.jumps;cost.decodedSamples += q.cost.decodedSamples
      }
      return (result,cost)
    }
    func prepareChunk(_ selection: Range<Int>) -> (chunk: SpatialInkGeometry.PreparedChunk,decodedPoints: Int) {
      precondition(!selection.isEmpty && selection.lowerBound >= 0 && selection.upperBound <= chunkCount)
      let id=selection.lowerBound
      var low=0,high=parts.count
      while low+1 < high { let mid=(low+high)/2;if starts[mid] <= id { low=mid } else { high=mid } }
      return parts[low].prepare((id-starts[low])..<(selection.upperBound-starts[low]))
    }
  }
  let batches: [Batch]
  static func local(_ layers: [SpatialInkRenderLayer]) -> Self {
    .init(batches:layers.map { .init(source:$0.source,projection:.local,
      sampleProjection:.init(origin:$0.origin,offset:$0.offset,scale:$0.scale)) })
  }
  static func prepare(surface: SurfaceID,journal: SpatialInkJournal?,suppressedInkIDs: Set<UUID> = []) throws -> Self {
    var batches:[Batch]=[],parts:[Batch.Part]=[],tool: SpatialInkTool?,projection: Projection?
    var nodes:[SpatialInkGeometry.Node]=[],chunks:[Chunk]=[]
    func sealPrepared() {
      if !nodes.isEmpty { parts.append(.init(nodes:nodes,chunks:chunks));nodes=[];chunks=[] }
    }
    func append(_ part: Batch.Part) {
      switch part.storage {
      case .relative: sealPrepared();parts.append(part)
      case .prepared(let incoming,let descriptors,_):
        let offset=nodes.count
        nodes.append(contentsOf:incoming)
        chunks.append(contentsOf:descriptors.map {
          .init(nodes:($0.nodes.lowerBound+offset)..<($0.nodes.upperBound+offset),
            bounds:$0.bounds,color:$0.color,flags:$0.flags,levels:$0.levels)
        })
      }
    }
    func seal() {
      guard let tool,let projection else { return }
      sealPrepared();batches.append(.init(tool:tool,projection:projection,parts:parts));parts=[]
    }
    for action in journal?.actions ?? [] where action.isActive && !suppressedInkIDs.contains(action.id) {
      try Task.checkCancellation()
      for (spanIndex,span) in action.spans.enumerated() where span.surface == surface {
        let origin=span.samples.first?.worldPoint.map { WorldPoint(tileX:$0.tileX,tileY:$0.tileY,localX:0,localY:0) }
        let next=origin.map(Projection.world) ?? .local
        if tool != action.tool || projection != next { seal();tool=action.tool;projection=next }
        let source=InkSampleRelations(sourceID:action.id,span:spanIndex,measurements:span.samples,
          header:.init(tool:action.tool,color:action.color))
        append(.init(source:source,projection:.init(origin:origin)))
      }
    }
    seal();return .init(batches:batches)
  }
}

/// Page actions use exactly the board/live triangle generator. Durable delivery
/// reuses finished measured meshes; undo removes a batch rather than baking a PNG.
struct PageInkMesh: Sendable {
  struct Entry: Sendable {
    let action: PageInkAction
    let mesh: SpatialInkMesh.Batch
    let reusedIndex: Int?
  }
  let entries: [Entry]
  var builtActionCount: Int { entries.filter { $0.reusedIndex == nil }.count }

  static func prepare(_ drawing: PageInkDrawing, reusing old: [Entry]) throws -> Self {
    let byID = Dictionary(old.enumerated().map { ($0.element.action.id, $0.offset) }, uniquingKeysWith: { _, last in last })
    var entries: [Entry] = []
    for action in drawing.actions where action.isActive {
      try Task.checkCancellation()
      if let index = byID[action.id] {
        let previous = old[index]
        // Ordering/tombstones belong to the drawing, not the measured mesh.
        if previous.action.tool == action.tool, previous.action.color == action.color,
          previous.action.samples == action.samples {
          entries.append(.init(action: action, mesh: previous.mesh, reusedIndex: index))
          continue
        }
      }
      let source=InkSampleRelations(action)
      entries.append(.init(action:action,mesh:.init(source:source,projection:.local),reusedIndex:nil))
    }
    return .init(entries: entries)
  }
}

/// Ready geometry belongs to its physical surface and exact source, not to the
/// preview or active canvas mounting it. Both use the same bounded cache.
@MainActor
final class SpatialInkMeshCache {
  static let shared = SpatialInkMeshCache()
  fileprivate struct ActionVersion: Equatable, Sendable {
    let id: UUID
    let stamp: VersionStamp
    let state: VersionStamp
  }
  fileprivate struct Entry: Sendable {
    let journal: SpatialInkJournal?
    let versions: [ActionVersion]
    let mesh: SpatialInkMesh
    let cost: Int
    var access: UInt64
  }
  private let capacity: Int
  private let byteLimit: Int
  private var entries: [SurfaceID: Entry] = [:]
  private var clock: UInt64 = 0
  private(set) var retainedBytes = 0
  var count: Int { entries.count }

  init(capacity: Int = 16, byteLimit: Int = 64 * 1024 * 1024) {
    self.capacity = max(0, capacity)
    self.byteLimit = max(0, byteLimit)
  }

  fileprivate func entry(for surface: SurfaceID) -> Entry? {
    guard var entry = entries[surface] else { return nil }
    clock &+= 1; entry.access = clock; entries[surface] = entry
    return entry
  }

  fileprivate func store(_ mesh: SpatialInkMesh, versions: [ActionVersion],
    surface: SurfaceID, journal: SpatialInkJournal?) {
    if let old = entries.removeValue(forKey: surface) { retainedBytes -= old.cost }
    let sourceBytes = journal?.actions.reduce(0) { total, action in
      total + action.spans.reduce(0) { $0 + $1.samples.payloadBytes }
    } ?? 0
    // Include canonical source retained for reconciliation, relative metadata,
    // and any explicitly required full normalization; visible caches own theirs.
    let cost = mesh.batches.reduce(0) { $0+$1.auxiliaryBytes }
      + sourceBytes
      + (journal?.actions.count ?? 0) * MemoryLayout<SpatialInkAction>.stride
    guard capacity > 0, cost <= byteLimit else { return }
    while entries.count >= capacity || retainedBytes + cost > byteLimit {
      guard let oldest = entries.min(by: { $0.value.access < $1.value.access }) else { break }
      retainedBytes -= oldest.value.cost; entries.removeValue(forKey: oldest.key)
    }
    clock &+= 1
    entries[surface] = Entry(journal: journal, versions: versions, mesh: mesh, cost: cost, access: clock)
    retainedBytes += cost
  }
}

/// Cold revisions prepare off the main actor. A portal handoff installs the
/// exact warm mesh synchronously, before any frame can show the former owner.
@MainActor
final class SpatialInkMeshPreparation {
  private let cache: SpatialInkMeshCache
  private var surface: SurfaceID?
  private var journal: SpatialInkJournal?
  private var needsSource = true
  private var task: Task<Void, Never>?
  private var versions: [SpatialInkMeshCache.ActionVersion]?

  init(cache: SpatialInkMeshCache = .shared) { self.cache = cache }

  @discardableResult
  func update(surface: SurfaceID, journal: SpatialInkJournal?, apply: @escaping @MainActor (SpatialInkMesh?, SpatialInkJournal?) -> Void) -> Bool {
    // Array equality takes its shared-storage fast path on camera-only frames;
    // unlike a maximum stamp it also detects independent, lower-clock merges.
    guard needsSource || self.surface != surface || self.journal != journal else { return false }
    let ownerChanged = self.surface != surface
    let previous = ownerChanged ? nil : versions
    self.surface = surface; self.journal = journal
    needsSource = false
    task?.cancel(); task = nil
    if let journal, journal.actions.isEmpty {
      versions = []
      let mesh = SpatialInkMesh(batches: [])
      cache.store(mesh, versions: [], surface: surface, journal: journal)
      apply(mesh, journal)
      return false
    }
    let cached = cache.entry(for: surface)
    if let cached, cached.journal == journal {
      versions = cached.versions
      apply(cached.mesh, journal)
      return false
    }
    if ownerChanged {
      // An uncached owner never inherits the old board's ink while preparing.
      apply(.init(batches: []), nil)
    }
    let worker = Task.detached(priority: .userInitiated) {
      try Task.checkCancellation()
      let versions = (journal?.actions ?? []).filter { $0.isActive && $0.spans.contains { $0.surface == surface } }
        .map { SpatialInkMeshCache.ActionVersion(id: $0.id, stamp: $0.stamp, state: $0.stateStamp) }
      let mesh: SpatialInkMesh
      if let cached, versions == cached.versions { mesh = cached.mesh }
      else { mesh = try SpatialInkMesh.prepare(surface: surface, journal: journal) }
      return (versions, mesh)
    }
    task = Task { [weak self] in
      await withTaskCancellationHandler {
        guard let result = try? await worker.value, !Task.isCancelled, let self else { return }
        self.versions = result.0
        self.cache.store(result.1, versions: result.0, surface: surface, journal: journal)
        apply(previous == result.0 ? nil : result.1, journal)
      } onCancel: { worker.cancel() }
    }
    return true
  }

  /// A completed local action already lives in this canvas. Cancel obsolete
  /// replay, not its physical owner: the next source replaces it atomically.
  func invalidateSource() {
    task?.cancel(); task = nil; journal = nil; versions = nil; needsSource = true
  }

  func cancel() { invalidateSource(); surface = nil }
  deinit { task?.cancel() }
}

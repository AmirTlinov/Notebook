import Foundation
import NotebookCore

/// One element action's resident bodies and simultaneous finish workspace.
/// Counts the immutable source/patch structure without encoding a second tree
/// merely to decide admission. Shared bodies are conservatively charged again.
enum NotebookElementWriteAllowance {
  static let maximumCost = NotebookPersistenceAdmission.Cost(
    payloadBytes: 48 * 1_024 * 1_024, completionBytes: 144 * 1_024 * 1_024)

  static func cost(_ plan: NotebookElementCommandPlan,
    resolvedSources: [NotebookNativeElementSource]? = nil) throws -> NotebookPersistenceAdmission.Cost {
    var meter = Meter()
    var retainedGraphs:[NotebookGraphicGraph]=[]
    try meter.add(MemoryLayout<NotebookElementCommandPlan>.stride + plan.references.count * 256, wire: 4_096)
    try meter.string(plan.summary)
    for operation in plan.operations {
      try meter.string(operation.id ?? "")
      try meter.json(.object(operation.values))
    }
    for source in resolvedSources ?? Array(plan.sources.values) { try meter.source(source) }
    for (key, value) in plan.copiedFrom { try meter.string(key); try meter.string(value) }
    if let witness = plan.transferWitness {
      for source in witness.sources { try meter.source(source) }
      for (key, children) in witness.groupChildren {
        try meter.string(key)
        try meter.add(children.capacity * MemoryLayout<String>.stride, wire: children.count * 2)
        for child in children { try meter.string(child) }
      }
    }
    for set in plan.inkReadSets {
      try meter.add(set.retainedPayloadBytes,
        wire: 1_024 + set.erasers.count * 512)
    }
    for draft in plan.drafts.values {
      if let graphic = draft.graphic { try meter.graphic(graphic) }
      try meter.string(draft.textSource ?? ""); try meter.string(draft.textHTML ?? "")
      if let capture=draft.capture {
        if !retainedGraphs.contains(where: { $0.sharesSource(with:capture.graph) }) {
          try meter.retain(capture.graph.retainedSourceBytes)
          retainedGraphs.append(capture.graph)
        }
        try meter.retain(capture.graph.retainedProjectionBytes + MemoryLayout<NotebookGraphicGraph>.stride
          + MemoryLayout<NotebookElementPlacement.Source>.stride + MemoryLayout<CGRect>.stride + 64)
      }
    }
    for working in plan.working { try meter.graphic(working.graphic) }
    // At execution the old typed source, resolved new source and inverse can
    // coexist. The codecs keep JSON/blob buffers and their SQL binding alive;
    // this finish credit stays charged while an uncertain command is retained.
    let resources = plan.retainedProgramResources
    if let resources { try meter.retain(resources.byteCount) }
    let finish = meter.resident * 3 + meter.wire * 2 + 131_072 + plan.references.count * 4_096
      + resourceFinishBytes(resources)
    let cost = NotebookPersistenceAdmission.Cost(payloadBytes: meter.resident + meter.retained, completionBytes: finish)
    guard cost.bytes <= maximumCost.bytes else { throw limit() }
    return cost
  }

  static func clipboardCost(fragment:NotebookPasteFragment,operations:[CollaborationOperation],
    programResources:NotebookProgramTransfer.Prepared?) throws -> NotebookPersistenceAdmission.Cost {
    guard let target=operations.first?.target else { throw limit() }
    var meter=Meter()
    try meter.add(MemoryLayout<NotebookPasteFragment>.stride + operations.count * 256,wire:4_096)
    for operation in operations { try meter.string(operation.id ?? "");try meter.json(.object(operation.values)) }
    // Preparation holds the typed source alongside the JSON action. These
    // bodies may use separate allocations even when their value is identical.
    for element in fragment.elements { try meter.source(.init(target:target,id:element.id,page:element)) }
    if let programResources { try meter.retain(programResources.byteCount) }
    let cost=NotebookPersistenceAdmission.Cost(payloadBytes:meter.resident+meter.retained,
      completionBytes:meter.resident * 3 + meter.wire * 2 + 131_072 + resourceFinishBytes(programResources))
    guard cost.bytes <= maximumCost.bytes else { throw limit() }
    return cost
  }

  private static func resourceFinishBytes(_ resources:NotebookProgramTransfer.Prepared?) -> Int {
    guard let resources else { return 0 }
    // Hash verification, canonical descriptor decoding, staging/bind buffers
    // and comparison with an existing destination row share this finish peak.
    return resources.byteCount * 3 + resources.manifestDecodeBytes * 2 + 2 * 1_024 * 1_024
  }

  static func programStateCost(boardID:UUID,rendered:SpatialElement,state:JSONValue,basis:NotebookProgramStateBasis) throws -> NotebookPersistenceAdmission.Cost {
    var meter=Meter()
    try meter.source(.init(target:.init(kind:rendered.surface.kind == .cover ? .cover : .board,
      id:rendered.surface.ownerID ?? boardID),id:rendered.id,spatial:rendered))
    try meter.json(state)
    try meter.versionPayload(basis.retainedPayloadBytes)
    let cost=NotebookPersistenceAdmission.Cost(payloadBytes:meter.resident,
      completionBytes:meter.resident * 3 + meter.wire * 2 + 131_072)
    guard cost.bytes <= maximumCost.bytes else { throw limit() }
    return cost
  }

  static func pageProgramStateCost(state:JSONValue,basis:NotebookProgramStateBasis,
    command:NotebookPageProgramStateCommand? = nil) throws -> NotebookPersistenceAdmission.Cost {
    var meter=Meter()
    try meter.json(state)
    try meter.versionPayload(basis.retainedPayloadBytes)
    if let command { try meter.versionPayload(command.retainedPayloadBytes) }
    let cost=NotebookPersistenceAdmission.Cost(payloadBytes:meter.resident,
      completionBytes:meter.resident * 3 + meter.wire * 2 + 131_072)
    guard cost.bytes <= maximumCost.bytes else { throw limit() }
    return cost
  }

  private static func limit() -> CollaborationError {
    .init("resource_limit", "Подготовка изменения превышает резерв 192 МиБ. Уменьшите выделение.")
  }

  private struct Meter {
    var resident = 0
    var wire = 0
    var retained = 0
    mutating func retain(_ bytes:Int) throws {
      guard bytes >= 0, bytes <= maximumCost.bytes - retained else { throw limit() }
      retained += bytes
    }
    mutating func versionPayload(_ bytes:Int) throws {
      guard bytes <= maximumCost.bytes / 6 else { throw limit() }
      try add(bytes,wire:bytes * 6)
    }
    mutating func add(_ bytes: Int, wire encoded: Int) throws {
      guard bytes >= 0, encoded >= 0, bytes <= maximumCost.payloadBytes - resident,
        encoded <= maximumCost.bytes - wire else { throw limit() }
      resident += bytes; wire += encoded
    }
    mutating func string(_ value: String) throws {
      let count = value.utf8.count
      guard count <= maximumCost.payloadBytes / 2 else { throw limit() }
      // Native String's grown backing allocation may retain spare capacity.
      try add(MemoryLayout<String>.stride + count * 2, wire: 2)
      for byte in value.utf8 {
        wire += byte < 0x20 ? 6 : byte == 0x22 || byte == 0x5c || byte == 0x2f ? 2 : 1
        guard wire <= maximumCost.bytes else { throw limit() }
      }
    }
    mutating func json(_ value: JSONValue, depth: Int = 0) throws {
      guard depth < 128 else { throw limit() }
      try add(MemoryLayout<JSONValue>.stride, wire: 24)
      switch value {
      case .null, .bool, .number: break
      case .string(let value): try string(value)
      case .array(let values):
        try add(values.capacity * MemoryLayout<JSONValue>.stride, wire: values.count)
        for value in values { try json(value, depth: depth + 1) }
      case .object(let values):
        try add(values.capacity * (MemoryLayout<String>.stride + MemoryLayout<JSONValue>.stride + 32), wire: values.count * 2)
        for (key, value) in values { try string(key); try json(value, depth: depth + 1) }
      }
    }
    mutating func source(_ source: NotebookNativeElementSource) throws {
      try add(MemoryLayout<NotebookNativeElementSource>.stride, wire: 1_024)
      try string(source.id)
      if let page = source.page {
        for value in [page.source, page.html, page.css, page.javaScript, page.programPackage ?? "", page.parentID ?? ""] { try string(value) }
        try json(page.state)
        if let graphic = page.graphic { try self.graphic(graphic) }
        if let style = page.textStyle { try text(style) }
      }
      if let spatial = source.spatial {
        for value in [spatial.source, spatial.html, spatial.css, spatial.javaScript, spatial.programPackage ?? "", spatial.parentID ?? ""] { try string(value) }
        try json(spatial.state); try text(spatial.textStyle)
        if let graphic = spatial.graphic { try self.graphic(graphic) }
      }
      for (key, version) in source.versions ?? [:] {
        try string(key)
        try add(MemoryLayout<ContentFieldVersion>.stride + version.observed.capacity * 64, wire: 128)
        for actor in version.observed.keys { try string(actor); try add(8, wire: 24) }
        try versionPayload(version.retainedHeadsBytes)
      }
    }
    mutating func text(_ style: NativeTextStyle) throws {
      try add(MemoryLayout<NativeTextStyle>.stride, wire: 256)
      if let format = style.format { try string(format.fontName ?? ""); try string(format.link ?? "") }
      let runs = style.runs ?? []
      try add(runs.capacity * MemoryLayout<NativeTextRun>.stride, wire: runs.count * 256)
      for run in runs { try string(run.format.fontName ?? ""); try string(run.format.link ?? "") }
    }
    mutating func graphic(_ graphic: NotebookGraphic) throws {
      try add(MemoryLayout<NotebookGraphic>.stride, wire: 2_048)
      try string(graphic.label)
      try add(graphic.sourceInkIDs.capacity * MemoryLayout<UUID>.stride, wire: graphic.sourceInkIDs.count * 40)
      let vertices = graphic.vertices ?? []
      try add(vertices.capacity * MemoryLayout<SpatialPoint>.stride, wire: vertices.count * 64)
      for binding in graphic.connection?.bindings ?? [] { try string(binding.elementID) }
      for command in graphic.path?.commands ?? [] {
        try add(MemoryLayout<NotebookVectorPath.Command>.stride + command.points.capacity * MemoryLayout<SpatialPoint>.stride,
          wire: 128 + command.points.count * 64)
      }
      for layer in graphic.freehand?.layers ?? [] {
        try add(MemoryLayout<NotebookFreehand.Layer>.stride + layer.vertices.capacity * MemoryLayout<NotebookFreehand.Vertex>.stride,
          wire: 512 + layer.vertices.count * 96)
        if let eraser = layer.eraser {
          try add(eraser.samples.capacity * MemoryLayout<NotebookFreehand.Eraser.Sample>.stride,
            wire: eraser.samples.count * 96)
        }
        if let body = layer.measured?.measurements {
          // Exact relation nodes encode their representation, including virtual
          // generators. Event count must not inflate a compressed source.
          let bytes = body.payloadBytes
          try add(bytes, wire: bytes * 8)
        }
      }
      for operation in graphic.mask?.operations ?? [] {
        try add(MemoryLayout<NotebookGraphicMask.Operation>.stride + operation.polygon.capacity * MemoryLayout<SpatialPoint>.stride,
          wire: 256 + operation.polygon.count * 64)
        for erasure in operation.erasures ?? [] {
          try string(erasure.target.elementID)
          let bytes = erasure.samples.payloadBytes
          try add(bytes + MemoryLayout<InkElementErasure>.stride, wire: bytes * 8 + 512)
        }
      }
    }
  }
}

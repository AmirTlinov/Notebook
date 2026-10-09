import Foundation
import NotebookCore

/// Discovery keeps source witnesses. One admitted document remains alive until
/// its actual print operation finishes, then only its geometry escapes.
enum NotebookRenderDocumentGeometry {
  // observe admits SQL32 MiB and JSON96 MiB. The JSON meter includes the
  // storedData wire scratch, Foundation map and both transient decodings.
  static let sourceReadBytes = 128 * 1_024 * 1_024
  private static let maximumBoards = 4
  private static let maximumEntriesPerBoard = 256
  private enum Failure {
    static let invalidSurface = CollaborationError("invalid_snapshot", "Поверхность изображения недоступна.")
    static let sourceChanged = CollaborationError("snapshot_changed", "Источник изображения изменился во время подготовки.")
  }

  fileprivate struct Reference: Sendable {
    let id: UUID
    let witness: NotebookSourceWitness
  }
  struct Capture: Sendable {
    let header: NotebookWorkspaceHeader
    let identity: PreviewSourceIdentity
    fileprivate let presence: SessionPresence
    fileprivate let reader: NotebookSceneReader
    fileprivate let references: [Reference]
    fileprivate let metadataCharge: RasterReservation
  }
  struct Prepared: Sendable {
    let values: [UUID: WorkspaceItemGeometry]
    private let references: [Reference]
    private let metadataCharge: RasterReservation?
    static let empty = Self(values: [:], references: [], metadataCharge: nil)
    fileprivate init(values: [UUID: WorkspaceItemGeometry], references: [Reference], metadataCharge: RasterReservation?) {
      self.values = values; self.references = references; self.metadataCharge = metadataCharge
    }
    /// Board/cover digests intentionally omit document text. These witnesses
    /// survive composition and are checked in the final publication cut.
    func isCurrent(_ store: NotebookStore) throws -> Bool {
      try store.readTransaction { store in
        for reference in references where try !reference.witness.isCurrent(store) { return false }
        return true
      }
    }
  }

  #if DEBUG
    struct AcceptanceConfiguration {
      let storeRoot: URL
      var beforeBodyRead: @MainActor (UUID) -> Void = { _ in }
      var sourceLoaded: @MainActor (DocumentSourceSnapshot) -> Void = { _ in }
      var printed: @MainActor (UUID) throws -> Void = { _ in }
    }
    @MainActor static var acceptanceConfiguration: AcceptanceConfiguration?
  #endif

  /// The caller's header, expected image identity and document witnesses are
  /// captured in ONE WAL cut before returning to its image preparation.
  @MainActor static func capture(store: NotebookStore, presence: SessionPresence,
    expectedIdentity: PreviewSourceIdentity? = nil, resources: SceneRenderResources = .shared) async throws -> Capture {
    precondition(presence.mode == .board || presence.mode == .cover)
    let reader = NotebookSceneReader(store: store)
    do {
      let charge = try await resources.acquirePassiveDerivedBytes(sourceReadBytes)
      let value: Capture
      do {
        value = try await read(reader) { store in
          let header = try store.workspaceHeader()
          guard try store.readBoardNodeHeader(presence.boardID) != nil else { throw Failure.invalidSurface }
          let identity = try PreviewSourceIdentity.read(store, presence: presence)
          guard expectedIdentity == nil || identity == expectedIdentity else { throw Failure.sourceChanged }
          return Capture(header: header, identity: identity, presence: presence, reader: reader,
            references: try discover(store, presence: presence), metadataCharge: charge)
        }
        // Each witness contains one ≤512-UTF16 item header, two scalar file
        // digests and fixed UUID/dictionary metadata, never a document body.
        guard resources.resizePassiveDerivedReservation(charge, to: 65_536 + value.references.count * 8_192) else {
          throw SceneRenderError.resourceLimit
        }
      } catch { charge.release(); throw error }
      return value
    } catch { await reader.close(); throw error }
  }

  /// Paint-order pages contain IDs and bounds only. No element, document or
  /// losing causal body is materialized just to discover visible documents.
  private static func discover(_ store: NotebookStore, presence: SessionPresence) throws -> [Reference] {
    var pending = [presence], visited = Set<UUID>(), documents = Set<UUID>(), references: [Reference] = []
    func include(_ id: UUID, view: SessionPresence) throws {
      guard let item = try store.readItemHeader(id) else { throw Failure.sourceChanged }
      if item.kind == .document, documents.insert(id).inserted {
        let witness = try store.readSourceWitness(itemIDs: [], pageIDs: [], boardIDs: [], documentIDs: [id])
        references.append(.init(id: id, witness: witness))
      } else if item.kind == .board, id == view.focusedItemID, view.openProgress > 0,
        pending.count + visited.count < maximumBoards, let node = try store.readBoardNodeHeader(id) {
        pending.append(.init(boardID: id, mode: .board,
          camera: BoardPortalProjection.entryCamera(portalCamera: node.portalCamera, viewport: BoardPortalProjection.viewport),
          viewport: BoardPortalProjection.viewport))
      }
    }
    while !pending.isEmpty {
      try Task.checkCancellation()
      let view = pending.removeFirst()
      guard visited.insert(view.boardID).inserted else { continue }
      guard visited.count <= maximumBoards else { throw SceneRenderError.resourceLimit }
      if view.mode == .cover {
        guard let id = view.focusedItemID else { throw Failure.invalidSurface }
        try include(id, view: view)
        continue
      }
      let bounds = WorkspaceSpatialBounds(
        origin: view.camera.screenToWorld(.init(x: -256, y: -256), viewport: view.viewport),
        width: (view.viewport.x + 512) / view.camera.scale, height: (view.viewport.y + 512) / view.camera.scale)
      var after: NotebookScenePaintPosition?, count = 0
      repeat {
        let page = try store.readCurrentScenePaintOrder(boardID: view.boardID, bounds: bounds, after: after)
        guard page.entries.count <= maximumEntriesPerBoard - count else { throw SceneRenderError.resourceLimit }
        count += page.entries.count
        for entry in page.entries { if case .item(let id) = entry.id { try include(id, view: view) } }
        after = page.next?.position
      } while after != nil
      // The focused owner remains mandatory outside the padded scalar window.
      if let id = view.focusedItemID, !documents.contains(id) { try include(id, view: view) }
    }
    return references
  }

  @MainActor static func prepare(store: NotebookStore, capture: Capture,
    resources: SceneRenderResources = .shared) async throws -> Prepared {
    do {
      var values: [UUID: WorkspaceItemGeometry] = [:]
      for reference in capture.references {
        try Task.checkCancellation()
        values[reference.id] = try await prepareDocument(store: store, capture: capture,
          reference: reference, resources: resources)
      }
      await capture.reader.close()
      return .init(values: values, references: capture.references, metadataCharge: capture.metadataCharge)
    } catch { await capture.reader.close(); throw error }
  }

  @MainActor private static func prepareDocument(store: NotebookStore, capture: Capture,
    reference: Reference, resources: SceneRenderResources) async throws -> WorkspaceItemGeometry {
    // Only geometry crosses this return. The full document, print task and its
    // source credit have ended before another read reservation can be awaited.
    let geometry = try await loadAndPrint(store: store, capture: capture, reference: reference, resources: resources)
    try Task.checkCancellation()
    let validationCharge = try await resources.acquirePassiveDerivedBytes(sourceReadBytes)
    defer { validationCharge.release() }
    try await read(capture.reader) { try requireCurrent($0, capture: capture, reference: reference) }
    return geometry
  }

  @MainActor private static func loadAndPrint(store: NotebookStore, capture: Capture,
    reference: Reference, resources: SceneRenderResources) async throws -> WorkspaceItemGeometry {
    let charge = try await resources.acquirePassiveDerivedBytes(sourceReadBytes)
    defer { charge.release() }
    #if DEBUG
      let acceptance = acceptanceConfiguration.flatMap { $0.storeRoot == store.root ? $0 : nil }
      acceptance?.beforeBodyRead(reference.id)
    #endif
    let (document, retained) = try await read(capture.reader) { store in
      try requireCurrent(store, capture: capture, reference: reference)
      let document = try store.loadDocument(reference.id)
      return (document, try preparationBytes(document))
    }
    // Resize after the SQL worker joins; source/input credit then survives the
    // existing compiler's real completion, including caller cancellation.
    guard resources.resizePassiveDerivedReservation(charge, to: retained) else { throw SceneRenderError.resourceLimit }
    try Task.checkCancellation()
    let page = capture.presence.focusedItemID == reference.id ? capture.presence.documentPageIndex : 0
    let printing = Task { @MainActor in
      let source = DocumentSourceSnapshot(document, store: store)
      #if DEBUG
        acceptance?.sourceLoaded(source)
      #endif
      let printed = try await source.printedSource(resources: resources)
      return withExtendedLifetime(printed) { source.paper(on: page).geometry }
    }
    // Submitted print work is joined instead of releasing source credit with
    // a departing subscriber. Cancellation prevents the next document.
    let geometry = try await printing.value
    #if DEBUG
      try acceptance?.printed(reference.id)
    #endif
    return geometry
  }

  private static func requireCurrent(_ store: NotebookStore, capture: Capture, reference: Reference) throws {
    guard try store.storedWorkspaceID() == capture.header.workspaceID,
      try PreviewSourceIdentity.read(store, presence: capture.presence) == capture.identity,
      try reference.witness.isCurrent(store) else { throw Failure.sourceChanged }
  }

  private static func preparationBytes(_ document: DocumentDocument) throws -> Int {
    var retained = MemoryLayout<DocumentDocument>.stride + document.files.capacity * MemoryLayout<DocumentFile>.stride
      + document.entrypoint.utf8.count * 2
    var inputBytes = 0, largestFile = 0
    for file in document.files {
      try Task.checkCancellation()
      retained += (file.id.utf8.count + file.path.utf8.count + file.source.utf8.count) * 2
      let bytes = Int(file.byteCount)
      inputBytes += bytes; largestFile = max(largestFile, bytes)
      if let resource = file.resource {
        retained += MemoryLayout<NotebookProgramPackage.File>.stride
          + (resource.path.utf8.count + resource.mimeType.utf8.count) * 2
          + resource.parts.capacity * MemoryLayout<NotebookProgramPackage.Part>.stride
          + resource.parts.reduce(0) { $0 + $1.sha256.utf8.count * 2 }
      }
    }
    if let collaboration = document.collaboration {
      retained += collaboration.fields.capacity * (MemoryLayout<String>.stride + MemoryLayout<ContentFieldVersion>.stride + 32)
      for (key, version) in collaboration.fields {
        try Task.checkCancellation()
        retained += key.utf8.count * 2 + version.retainedPayloadBytes
      }
    }
    // Closed input ≤16 MiB plus one file's validation/hash copy. The bounded
    // path/namespace indexes have separate scratch; VM/output belongs to print.
    let bytes = retained + inputBytes + largestFile + document.files.count * 4_096 + 4 * 1_024 * 1_024
    guard bytes > 0, bytes <= sourceReadBytes else { throw SceneRenderError.resourceLimit }
    return bytes
  }

  /// observe borrows this serial reader's already-open cut and applies its
  /// existing JSON/SQL lease. It opens no additional physical connection.
  @MainActor private static func read<Value: Sendable>(_ reader: NotebookSceneReader,
    _ operation: @escaping @Sendable (NotebookStore) throws -> Value) async throws -> Value {
    let worker = Task.detached(priority: .utility) {
      try await reader.read { store in
        let observer = NotebookReadSession(store: store)
        return try observer.observe { _ in try operation(store) }
      }
    }
    return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
  }
}

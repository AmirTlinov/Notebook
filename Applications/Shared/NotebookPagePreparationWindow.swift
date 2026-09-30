import NotebookCore
import SwiftUI

/// The finite addressed read window owns accepted page preparation. A native
/// host borrows its slot; creating or replacing SwiftUI is not a work request.
@MainActor @Observable
final class NotebookPagePreparationWindow {
  struct Address: Hashable { let itemID: UUID; let index: Int; let root: String }
  /// Admission of one paper is independent of board/cover paint. The existing
  /// item host borrows this accepted geometry; native camera projection still
  /// owns its actual pose and the page registry proves installed content.
  struct ReaderPresentation: Equatable {
    let address: Address
    let pageID: UUID
    let boardID: UUID
    let rendered: RenderedWorkspaceItem
  }
  private(set) var presentations: [UUID: ReaderPresentation] = [:]
  struct NativeSource {
    let address: Address
    let pageID: UUID?
    let controllerID: UUID
  }
  /// A loading native shell observes admission from this owner. It cannot
  /// start an independent program while its finite read window is pending.
  private(set) var admissionRevision: UInt64 = 0
  private struct Window: Equatable { let root: String; let indices: Set<Int>; let target: Int?; let controllerID: UUID? }
  private struct Identity: Hashable { let itemID: UUID; let pageID: UUID }
  private struct Reader {
    let itemID: UUID
    let pageID: UUID?
    var identity: Identity? { pageID.map { .init(itemID: itemID, pageID: $0) } }
  }
  private struct Preparation { let operationID: UUID; let reader: Reader? }

  /// Durable value equality deliberately ignores these in-process roots. A
  /// mounted paper must observe their replacement even when its bytes agree.
  struct SourceVersion: Equatable {
    let ink: ObjectIdentifier
    let elements: ObjectIdentifier
    let size: PageSize
    let drawing: VersionStamp
    let graphics: VersionStamp
    init(_ page: PageDocument) {
      ink = page.inkSource.identity; elements = page.elementSourceIdentity
      size = page.size; drawing = page.drawingStamp; graphics = page.agentStamp
    }
  }

  @MainActor @Observable final class Entry {
    let pageID: UUID
    let preparations: PageAgentPreparationOwner
    let rasters: PageRasterPreparation
    private(set) var sourceVersion: SourceVersion
    @ObservationIgnored private var acceptedDocument: PageDocument
    var document: PageDocument { _ = sourceVersion; return acceptedDocument }
    @ObservationIgnored fileprivate var address: Address
    @ObservationIgnored fileprivate var mounts: Set<UUID> = []
    @ObservationIgnored fileprivate var onLastMountReleased: ((Entry) -> Void)?
    fileprivate init(address: Address, page: PageDocument, resources: SceneRenderResources, rasters: PageRasterPreparation) {
      self.address = address; pageID = page.id; self.rasters = rasters
      acceptedDocument = page; sourceVersion = .init(page)
      preparations = .init(resources: resources)
    }
    fileprivate func accept(_ page: PageDocument, model: NotebookAppModel) {
      acceptedDocument = page
      sourceVersion = .init(page)
      preparations.reconcile(page: page, model: model)
    }
    func borrow() -> Mount {
      let id = UUID(); mounts.insert(id)
      return .init(entry: self, id: id)
    }
    fileprivate func retire() { preparations.retire(afterUpdate: true) }
  }
  @MainActor final class Mount {
    let entry: Entry
    private var id: UUID?
    fileprivate init(entry: Entry, id: UUID) { self.entry = entry; self.id = id }
    func close() {
      guard let id else { return }; self.id = nil; entry.mounts.remove(id)
      if entry.mounts.isEmpty { entry.onLastMountReleased?(entry) }
    }
    isolated deinit { close() }
  }

  @ObservationIgnored var addresses: [Address: UUID] = [:] {
    didSet {
      for (identity, entry) in entries {
        guard let address = addresses.first(where: { $0.key.itemID == identity.itemID && $0.value == identity.pageID })?.key else {
          entries.removeValue(forKey: identity)?.retire(); continue
        }
        entry.address = address
      }
      retirePresentations()
      if oldValue != addresses { admissionRevision &+= 1 }
    }
  }
  @ObservationIgnored private let resources: SceneRenderResources
  @ObservationIgnored private var rasterOwners: [UUID: PageRasterPreparation] = [:]
  @ObservationIgnored private var windows: [UUID: Window] = [:]
  @ObservationIgnored private var tasks: [Address: Task<Void, Never>] = [:]
  @ObservationIgnored private var entries: [Identity: Entry] = [:]
  @ObservationIgnored private weak var model: NotebookAppModel?
  @ObservationIgnored private var pages: [UUID: PageDocument] = [:]
  @ObservationIgnored private var current: Reader?
  @ObservationIgnored private var preparation: Preparation?
  @ObservationIgnored private var stopped = false

  init(resources: SceneRenderResources = .shared) {
    self.resources = resources
  }

  func retain(_ indices: Set<Int>, in itemID: UUID, root: String, target: Int?, targetIsLoaded: Bool,
    controllerID: UUID? = nil) {
    guard !stopped else { return }
    if let controllerID {
      if indices.isEmpty {
        guard windows[itemID]?.controllerID == controllerID else { return }
      } else {
        guard admittedItems.contains(itemID) else { return }
      }
    }
    let next: Window? = indices.isEmpty ? nil : .init(root: root, indices: indices, target: target, controllerID: controllerID)
    let admissionChanged = windows[itemID] != next
    windows[itemID] = next
    for (address, task) in tasks where address.itemID == itemID
      && (address.root != root || !indices.contains(address.index) || (!targetIsLoaded && target != nil && address.index != target)) {
      task.cancel()
    }
    for (identity, entry) in entries where identity.itemID == itemID
      && !readers.contains(identity) && (entry.address.root != root || !indices.contains(entry.address.index)) {
      entries.removeValue(forKey: identity)?.retire()
    }
    if indices.isEmpty, !admittedItems.contains(itemID) { rasterOwners[itemID] = nil }
    if admissionChanged { admissionRevision &+= 1 }
  }

  func permits(_ address: Address) -> Bool {
    guard !stopped else { return false }
    guard let window = windows[address.itemID] else { return true }
    return window.root == address.root && window.indices.contains(address.index)
  }
  func retainedIndices(in itemID: UUID, root: String) -> Set<Int>? {
    windows[itemID].flatMap { $0.root == root ? $0.indices : nil }
  }

  func prepare(_ address: Address, isLoaded: @escaping @MainActor (Address) -> Bool,
    isCurrent: @escaping @MainActor (Address) -> Bool,
    read: @escaping @MainActor (Address) async -> Void) async {
    guard !Task.isCancelled, permits(address), isCurrent(address), !isLoaded(address) else { return }
    while let window = windows[address.itemID], window.root == address.root,
      let target = window.target, target != address.index {
      let destination = Address(itemID: address.itemID, index: target, root: address.root)
      if isLoaded(destination) { break }
      await prepare(destination, isLoaded: isLoaded, isCurrent: isCurrent, read: read)
      guard !Task.isCancelled, permits(address), isCurrent(address) else { return }
      if windows[address.itemID]?.target == target, !isLoaded(destination) { return }
    }
    if let pending = tasks[address] {
      await pending.value
      if pending.isCancelled, !Task.isCancelled, permits(address), isCurrent(address),
        windows[address.itemID]?.indices.contains(address.index) == true {
        await prepare(address, isLoaded: isLoaded, isCurrent: isCurrent, read: read)
      }
      return
    }
    let task = Task { [weak self] in
      guard let self else { return }
      defer { tasks[address] = nil }
      await read(address)
    }
    tasks[address] = task
    await task.value
  }

  func acceptedPages(_ pages: [UUID: PageDocument], model: NotebookAppModel) {
    let previous = readers, previousItems = admittedItems
    self.model = model; self.pages = pages
    for (identity, entry) in entries {
      if let page = pages[identity.pageID] { entry.accept(page, model: model) }
      else {
        entries.removeValue(forKey: identity); entry.retire()
        if current?.identity == identity { current = nil }
      }
    }
    retireReaders(previous, previousItems: previousItems)
  }

  func presentation(itemID: UUID, boardID: UUID) -> ReaderPresentation? {
    guard let value = presentations[itemID], value.boardID == boardID,
      model?.isItemBeingDeleted(itemID) != true else { return nil }
    return value
  }

  private func retirePresentations() {
    for (item, value) in presentations {
      let reader = (current?.identity).flatMap { $0.itemID == item ? $0 : nil }
        ?? (preparation?.reader?.identity).flatMap { $0.itemID == item ? $0 : nil }
      guard !stopped, let reader, pages[reader.pageID] != nil,
        let address = addresses.first(where: { $0.key.itemID == item && $0.value == reader.pageID })?.key else {
        presentations[item] = nil; continue
      }
      if address != value.address || reader.pageID != value.pageID {
        presentations[item] = .init(address: address, pageID: reader.pageID,
          boardID: value.boardID, rendered: value.rendered)
      }
    }
  }

  private static func reader(_ presence: SessionPresence?) -> Reader? {
    guard let presence, presence.mode == .page || presence.mode == .cover,
      let itemID = presence.focusedItemID else { return nil }
    return .init(itemID: itemID, pageID: presence.notebookPageID)
  }
  private var readers: Set<Identity> { Set([current?.identity, preparation?.reader?.identity].compactMap { $0 }) }
  private var admittedItems: Set<UUID> { Set([current?.itemID, preparation?.reader?.itemID].compactMap { $0 }) }

  /// A held or reversing pinch still owns its reader at the fully covered
  /// pose. Only an accepted board/other-owner pose ends that actual lifetime.
  func updatePresence(_ presence: SessionPresence?) {
    guard !stopped else { return }
    let previous = readers, previousItems = admittedItems
    let next = Self.reader(presence)
    // A stationary closed cover does not start execution. Zero progress can
    // retain a reader already admitted by the actual pose or camera operation.
    if let next, presence?.mode == .cover, presence?.openProgress == 0, !previousItems.contains(next.itemID) {
      current = nil
    } else { current = next }
    retireReaders(previous, previousItems: previousItems)
  }

  /// Camera operations admit their destination before its first actual pose.
  /// The existing camera ID, rather than a composition callback, owns its end.
  func acceptPreparation(_ presence: SessionPresence?, operationID: UUID) {
    guard !stopped else { return }
    let previous = readers, previousItems = admittedItems
    preparation = .init(operationID: operationID, reader: Self.reader(presence))
    retireReaders(previous, previousItems: previousItems)
  }
  func endPreparation(operationID: UUID) {
    guard preparation?.operationID == operationID else { return }
    let previous = readers, previousItems = admittedItems
    preparation = nil
    retireReaders(previous, previousItems: previousItems)
  }
  private func retireReaders(_ previous: Set<Identity>, previousItems: Set<UUID>) {
    let retained = readers
    retirePresentations()
    for identity in previous.subtracting(retained) where entries[identity]?.mounts.isEmpty == true {
      entries.removeValue(forKey: identity)?.retire()
    }
    for itemID in previousItems.subtracting(admittedItems) {
      // Terminal withdrawal wins over a still-mounted outgoing UIKit host.
      for (identity, entry) in entries where identity.itemID == itemID {
        entries.removeValue(forKey: identity); entry.retire()
      }
      for (address, task) in tasks where address.itemID == itemID { task.cancel() }
      windows[itemID] = nil; rasterOwners[itemID] = nil
    }
    if previous != retained || previousItems != admittedItems { admissionRevision &+= 1 }
  }

  private func entry(at address: Address, pageID: UUID) -> Entry? {
    guard permits(address), addresses[address] == pageID, let page = pages[pageID] else { return nil }
    let key = Identity(itemID: address.itemID, pageID: pageID)
    if let existing = entries[key] { return existing }
    let rasters: PageRasterPreparation
    if let existing = rasterOwners[address.itemID] { rasters = existing }
    else { rasters = .init(resources: resources); rasterOwners[address.itemID] = rasters }
    let entry = Entry(address: address, page: page, resources: resources, rasters: rasters)
    entry.onLastMountReleased = { [weak self] released in
      guard let self, self.entries[key] === released, !self.readers.contains(key) else { return }
      self.entries.removeValue(forKey: key)?.retire()
    }
    entries[key] = entry
    if let model { entry.preparations.reconcile(page: page, model: model) }
    return entry
  }

  func entry(at index: Int, in itemID: UUID, root: String) -> Entry? {
    let address = Address(itemID: itemID, index: index, root: root)
    guard let pageID = addresses[address],
      readers.contains(Identity(itemID: itemID, pageID: pageID))
        || (windows[itemID]?.root == root && windows[itemID]?.indices.contains(index) == true) else { return nil }
    return entry(at: address, pageID: pageID)
  }

  func entry(for source: NativeSource, pageID: UUID) -> Entry? {
    // Reading this revision subscribes the existing SwiftUI loading shell to
    // actual window/address admission and terminal withdrawal, without a retry.
    _ = admissionRevision
    let address = source.address
    guard !stopped, admittedItems.contains(address.itemID),
      let window = windows[address.itemID], window.controllerID == source.controllerID,
      window.root == address.root, window.indices.contains(address.index),
      source.pageID == nil || source.pageID == pageID else { return nil }
    return entry(at: address, pageID: pageID)
  }

  /// Runs at accepted scene demand, before composition and before a native view
  /// factory. Only the current paper gets early execution; neighbours retain
  /// their existing, explicitly requested passive preparation.
  func prepareCurrent(model: NotebookAppModel, presence: SessionPresence, frame: WorkspaceSceneFrame, displayScale: Double,
    operationID: UUID? = nil) {
    let pending = preparation.flatMap { $0.operationID == operationID ? $0.reader : nil }
    guard !stopped, model.permitsPagePreparation, presence.mode == .cover || presence.mode == .page,
      frame.index.generationID == model.sceneIndex?.generationID,
      let itemID = presence.focusedItemID,
      let pageID = presence.notebookPageID ?? (pending?.itemID == itemID ? pending?.pageID : nil)
        ?? (current?.itemID == itemID ? current?.pageID : nil),
      current?.identity == Identity(itemID: itemID, pageID: pageID) || pending?.identity == Identity(itemID: itemID, pageID: pageID),
      let page = model.pages[pageID], let root = model.notebookPageRoot(itemID),
      !model.isItemBeingDeleted(itemID), frame.index.ownerBoard(itemID: itemID) == presence.boardID,
      let address = addresses.first(where: { $0.key.itemID == itemID && $0.key.root == root && $0.value == pageID })?.key,
      let rendered = frame.workset(boardID: presence.boardID).items.first(where: { $0.id == itemID && $0.item.kind == .notebook }),
      let entry = entry(at: address, pageID: pageID),
      let visible = PageAgentPreparationOwner.visibleRegion(page: page, item: rendered, presence: presence) else { return }
    let presentation = ReaderPresentation(address: address, pageID: pageID, boardID: presence.boardID, rendered: rendered)
    if presentations[itemID] != presentation { presentations[itemID] = presentation }
    guard entry.mounts.isEmpty else { return }
    let scale = min(rendered.geometry.width / page.size.width, rendered.geometry.height / page.size.height)
      * rendered.geometry.fitScale(viewport: presence.viewport)
    entry.rasters.prioritize(displayed: address.index, target: nil, displayedContentReady: false)
    entry.preparations.prepare(page: page, model: model, renderingScale: scale, displayScale: displayScale,
      allowsInteraction: true, inputEnabled: false, visibleRegion: visible,
      activity: nil, rasterPreparation: .init(owner: entry.rasters, pageIndex: address.index), cohort: nil)
  }

  func stop() -> [Task<Void, Never>] {
    stopped = true
    presentations.removeAll()
    let pending = Array(tasks.values)
    for task in pending { task.cancel() }
    for entry in entries.values { entry.retire() }
    entries.removeAll(); windows.removeAll(); rasterOwners.removeAll(); pages.removeAll(); model = nil; current = nil; preparation = nil
    admissionRevision &+= 1
    return pending
  }
  isolated deinit { _ = stop() }
}

import CoreGraphics
import Foundation
import Testing
@testable import NotebookCore

private struct PageInkWindowFixture {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("page-ink-window-" + UUID().uuidString)
  let actor = UUID(), itemID = UUID(), pageID = UUID()
  let store: NotebookStore
  init() throws {
    store = NotebookStore(root: root)
    _ = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194),
      initialNotebookID: itemID, initialPageID: pageID)
  }
  func clean() { try? FileManager.default.removeItem(at: root) }
  func action(x: Double, y: Double, endX: Double? = nil, sequence: UInt64, tool: SpatialInkTool = .pen) -> PageInkAction {
    .init(tool: tool, samples: [x, endX ?? x + 4].enumerated().map { i, x in
      .init(point: .init(x: x, y: y), timeOffset: Double(i) / 120, width: tool == .eraser ? 10 : 2,
        opacity: 1, force: 1, azimuth: 0, altitude: 1)
    }, sequence: sequence)
  }
  func append(_ action: PageInkAction) throws {
    let base = try #require(store.readContentHeader(target: .init(kind: .page, id: pageID)).inkStamp)
    _ = try store.commitPageInk(pageID: pageID, command: .append(action, baseStamp: base,
      stamp: try #require(base.advanced(by: actor))))
  }
  func source(pins: Set<UUID> = [], elements: Set<String> = []) throws -> NotebookPageMaterialSource {
    try store.readPageMaterialSource(itemID: itemID, pageID: pageID,
      bounds: .init(x: 0, y: 0, width: 100, height: 100), historyPins: pins, elementPins: elements)
  }
}

@Suite("Cold native page ink retains exact contacts and global painter order")
struct NotebookPageInkWindowTests {
  @Test func admissionAddsExistingPensWithoutChangingCanonicalHistory() throws {
    let f = try PageInkWindowFixture(); defer { f.clean() }
    let pen = f.action(x: 10, y: 10, sequence: 1)
    try f.append(pen)
    let history = try f.store.nativeHistory(domain: .page(f.pageID), actor: f.actor)
    #expect(history == [.ink([pen.id])])
    let read = try f.store.currentReadCursor(), change = try f.store.currentChangeCursor()
    try retirePageMaterialFixtureTo29(f.store)
    let database = try NotebookSQLConnection(url: f.store.databaseURL, writable: false, create: false)
    #expect(try database.rows("PRAGMA user_version").first?[0].integer == 29)
    #expect(try database.rows("SELECT address FROM ink_surfaces WHERE kind='page' AND tool='pen'").isEmpty)
    let before = try pageMaterialAuthoredSnapshot(database)
    do {
      _ = try f.store.readTransaction(using: database) { _ in try f.source() }
      Issue.record("An unadmitted legacy page cannot certify empty ink")
    } catch let error as CollaborationError { #expect(error.code == "page_material_not_admitted") }
    _ = try f.store.prepareDatabase()
    let source = try f.source()
    #expect(source.preparedInkDrawing?.actions.map(\.id) == [pen.id])
    #expect(try f.store.currentReadCursor() == read)
    #expect(try f.store.currentChangeCursor() == change)
    #expect(try pageMaterialAuthoredSnapshot(database) == before)
    #expect(try f.store.nativeHistory(domain: .page(f.pageID), actor: f.actor) == history)
    #expect(try database.rows("PRAGMA user_version").first?[0].integer == NotebookStore.currentDatabaseVersion)
  }

  @Test func contactClosurePinsAndAppendKeepGlobalOrderAndImmutableCuts() throws {
    let f = try PageInkWindowFixture(); defer { f.clean() }
    let pen = f.action(x: 10, y: 10, endX: 700, sequence: 1)
    let eraser = f.action(x: 690, y: 10, sequence: 2, tool: .eraser)
    let remote = f.action(x: 700, y: 700, sequence: 9)
    for action in [pen, eraser, remote] { try f.append(action) }
    let source = try f.source(), original = source.inkSource
    #expect(Set(try original.drawing().actions.map(\.id)) == [pen.id, eraser.id])
    #expect(source.inkWindow.sequenceFrontier == 9)
    #expect(throws: CollaborationError.self) {
      try source.prepareLiveInkChange(.setActive([remote.id], false), stamp: .init(counter: 20, actor: f.actor))
    }
    let first = f.action(x: 20, y: 20, sequence: 0), second = f.action(x: 30, y: 30, sequence: 0)
    let one = try source.prepareLiveInkChange(.append(first), stamp: .init(counter: 20, actor: f.actor))
    #expect(one.drawing.action(id: first.id)?.sequence == 10)
    #expect(source.publishLiveInkChange(one))
    let two = try source.prepareLiveInkChange(.append(second), stamp: .init(counter: 21, actor: f.actor))
    #expect(two.drawing.action(id: second.id)?.sequence == 11)
    #expect(source.publishLiveInkChange(two))
    #expect(try original.drawing().actions.count == 2)
    _ = try f.store.commitPageInk(pageID: f.pageID, command: .init(one))
    _ = try f.store.commitPageInk(pageID: f.pageID, command: .init(two))
    let pinned = try f.source(pins: [remote.id])
    let undo = try pinned.prepareLiveInkChange(.setActive([remote.id], false), stamp: .init(counter: 22, actor: f.actor))
    _ = try f.store.commitPageInk(pageID: f.pageID, command: .init(undo))
    let inactive = try f.source(pins: [remote.id])
    #expect(inactive.preparedInkDrawing?.action(id: remote.id)?.isActive == false)
    let complete = try f.store.loadPage(f.pageID).inkDrawing()
    #expect(complete.actions.count == 5)
    #expect(complete.action(id: pen.id) == pen)
    #expect(complete.action(id: eraser.id) == eraser)
    #expect(complete.action(id: remote.id)?.sequence == 9)
  }

  @Test func durableInkAcknowledgementRetainsInstalledRootsAndNewCutWhileForeignMaterialReplacesThem() throws {
    let f = try PageInkWindowFixture(); defer { f.clean() }
    var current = try f.source()
    let mounted = current, pen = f.action(x: 20, y: 20, sequence: 0)
    let materialIdentity = current.elementSourceIdentity
    for mutation in [PageInkMutation.append(pen), .setActive([pen.id], false), .setActive([pen.id], true)] {
      let change = try current.prepareLiveInkChange(mutation, stamp: #require(current.drawingStamp.advanced(by: f.actor)))
      #expect(current.publishLiveInkChange(change))
      let acceptedInk = current.inkSource, oldCut = current.window.snapshotIdentity
      _ = try f.store.commitPageInk(pageID: f.pageID, command: .init(change))
      let fresh = try f.source(pins: [pen.id])
      current = fresh.retainingPresentation(from: current)
      #expect(current.inkSource.identity == acceptedInk.identity)
      #expect(current.elementSourceIdentity == materialIdentity)
      #expect(current.window.snapshotIdentity == fresh.window.snapshotIdentity)
      #expect(current.window.snapshotIdentity != oldCut)
      #expect(current.inkWindow.snapshotIdentity == fresh.inkWindow.snapshotIdentity)
      #expect(current.window.sourceRevision == fresh.window.sourceRevision)
      #expect(current.inkWindow.pinnedActionIDs == fresh.inkWindow.pinnedActionIDs)
      #expect(current.inkWindow.sequenceFrontier == fresh.inkWindow.sequenceFrontier)
      #expect(mounted.inkSource.identity == acceptedInk.identity,
        "An existing native mount keeps the same live ink owner after a durable ACK")
    }
    let accepted = current
    var page = try f.store.loadPage(f.pageID)
    let replaced = page.replaceElements([.init(id: "new-text", kind: .nativeText,
      frame: .init(x: 10, y: 10, width: 50, height: 30), source: "New", html: "")], actor: f.actor)
    #expect(replaced)
    try f.store.savePage(page)
    let changed = try f.source(pins: [pen.id]).retainingPresentation(from: accepted)
    #expect(changed.elementSourceIdentity != accepted.elementSourceIdentity)
    #expect(changed.inkSource.identity == accepted.inkSource.identity,
      "A graphics-only replacement does not rebuild equal ink")
    #expect(changed.elements.map(\.id) == ["new-text"])
    try f.append(f.action(x: 50, y: 50, sequence: 2, tool: .eraser))
    let erased = try f.source(pins: [pen.id]).retainingPresentation(from: changed)
    #expect(erased.inkSource.identity != changed.inkSource.identity)
    #expect(erased.preparedInkDrawing != changed.preparedInkDrawing)
  }

  @Test func explicitMissingElementPinKeepsCausalTombstoneAndUnknownRemainsUnknown() throws {
    let f = try PageInkWindowFixture(); defer { f.clean() }
    var page = try f.store.loadPage(f.pageID)
    _ = page.replaceElements([.init(id: "text", kind: .nativeText,
      frame: .init(x: 10, y: 10, width: 50, height: 20), source: "Text", html: "")], actor: f.actor)
    try f.store.savePage(page)
    let before = try #require(f.source(elements: ["text"]).nativeElementSource(id: "text"))
    _ = try f.store.applyNativeElementEdits([.init(kind: .removeElement, target: before.target, id: before.id)],
      summary: "Remove pinned text", sources: [before], actor: f.actor)
    let source = try f.source(elements: ["text"])
    let removed = try #require(source.nativeElementSource(id: "text"))
    #expect(removed.page == nil)
    #expect(removed.versions?.isEmpty == false)
    let exact = try f.store.readNativeElementSource(target: before.target, id: "text")
    #expect(removed == exact)
    #expect(source.nativeElementSource(id: "unknown") == nil)
    #expect(source.elementSourceSnapshot.nativeSource("text", target: before.target) == exact)
    #expect(source.elementIdentityStamp("text") == nil)
  }

  @Test func materialAndInkFromSeparateCutsCannotBeCombinedEvenWithoutAnInterveningWrite() throws {
    let f = try PageInkWindowFixture(); defer { f.clean() }
    let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
    let material = try f.store.readPageMaterialWindow(itemID: f.itemID, pageID: f.pageID, bounds: bounds)
    let ink = try f.store.readPageInkWindow(pageID: f.pageID, bounds: bounds)
    #expect(throws: NotebookStorageError.self) { try NotebookPageMaterialSource(material: material, ink: ink) }
    let coherent = try f.source()
    #expect(coherent.window.readCursor == coherent.inkWindow.readCursor)
    #expect(coherent.window.sourceRevision == coherent.inkWindow.sourceRevision)
    #expect(coherent.coversMaterial(in: bounds))
    #expect(!coherent.coversMaterial(in: bounds.offsetBy(dx: 1, dy: 0)))
  }

  @Test func pinnedReferencePreservesOffWindowContentAcrossPendingAppendUndoAndRedo() throws {
    for initiallyEmpty in [true, false] {
      let f = try PageInkWindowFixture(); defer { f.clean() }
      if !initiallyEmpty {
        try f.append(f.action(x: 10, y: 10, sequence: 3))
        try f.append(f.action(x: 700, y: 700, sequence: 17))
      }
      let source = try f.source(), complete = try f.store.loadPage(f.pageID)
      try complete.prepareInkForPresentation()
      #expect(try source.referenceRevision() == complete.referenceRevision())
      let first = f.action(x: 20, y: 20, sequence: 0), second = f.action(x: 30, y: 30, sequence: 0)
      for (offset, mutation) in [PageInkMutation.append(first), .append(second), .setActive([first.id], false), .setActive([first.id], true)].enumerated() {
        let frozen = source.frozenForPresentation(), frozenComplete = complete.frozenForPresentation()
        let previous = try frozen.referenceRevision(elementID: nil)
        let stamp = VersionStamp(counter: UInt64(50 + offset), actor: f.actor)
        let local = try source.prepareLiveInkChange(mutation, stamp: stamp)
        let whole = try complete.prepareLiveInkChange(mutation, stamp: stamp)
        #expect(source.publishLiveInkChange(local))
        #expect(complete.publishLiveInkChange(whole))
        #expect(try source.referenceRevision() == complete.referenceRevision())
        #expect(try frozen.referenceRevision(elementID: nil) == previous)
        #expect(try frozenComplete.referenceRevision(elementID: nil) == previous)
        _ = try f.store.commitPageInk(pageID: f.pageID, command: .init(local))
        #expect(try source.referenceRevision() == f.store.referenceRevision(target: .init(kind: .page, id: f.pageID)))
      }
      let reference = CollaborationReference(target: .init(kind: .page, id: f.pageID),
        region: .init(x: 0, y: 0, width: 100, height: 100), revision: try source.referenceRevision())
      let pinned = try AgentPinnedSource.capture(requestID: UUID(), reference: reference, page: source.frozenForPresentation())
      #expect(pinned.payload["paperSize"] == (try .encode(complete.size)))
      #expect(pinned.payload["elements"]?.array.isEmpty == true)
      #expect(pinned.payload["drawingData"] == nil)
    }
  }
}

@Test("Cold page ink decodes the same viewport contacts at 1000 and 100000 actions")
func pageInkWindowAtOneHundredThousandActions() throws {
  let f = try PageInkWindowFixture(); defer { f.clean() }
  let parent = pageFile(f.pageID) + "#/drawingData"
  var previous = 0, counts: [Int] = []
  for count in [1000, 100000] {
    try f.store.commandTransaction {
      for i in previous..<count {
        let action = f.action(x: i < 3 ? 10 + Double(i) * 10 : 600, y: i < 3 ? 10 : 600, sequence: UInt64(i + 1))
        let member = action.id.uuidString.lowercased(), address = parent + "/actions/@" + member
        let fragments = try NotebookRecordCodec.encode(.encode(action), file: pageFile(f.pageID), address: address,
          parent: parent, collection: "actions", member: member, position: i)
        for fragment in fragments.sorted(by: { ($0.address == address ? 1 : 0) < ($1.address == address ? 1 : 0) }) {
          try f.store.writeFragment(fragment, database: f.store.currentSQL!)
        }
      }
    }
    previous = count
    let trace = PageMaterialSQLTrace()
    try f.store.readTransaction { _ in
      let database = f.store.currentSQL!
      try database.limitReads(.init(rows: 256, bytes: 128_000, valueBytes: 16_000,
        reason: "Cold page ink reads only whole contacts needed by the viewport", jsonDecodeBytes: 1_000_000, sqlSteps: 10_000))
      trace.attach(database)
      defer { trace.detach(database) }
      let source = try f.source()
      #expect(source.preparedInkDrawing?.actions.count == 3)
      #expect(source.inkWindow.sequenceFrontier == UInt64(count))
      counts.append(database.decodedFragmentCount)
      #expect(try source.referenceRevision() == f.store.referenceRevision(target: .init(kind: .page, id: f.pageID)))
      print("PAGE_INK_COLD total=\(count) visible=3 decoded_fragments=\(database.decodedFragmentCount) decoded_bytes=\(database.decodedFragmentBytes) sql_vm_steps=\(trace.steps)")
    }
    try trace.reportPlans(f.store, label: "PAGE_INK_\(count)")
    if count == 100000 {
      let source = try f.source()
      #expect(try source.referenceRevision() == f.store.loadPage(f.pageID).referenceRevision())
    }
  }
  #expect(counts[0] == counts[1])
}

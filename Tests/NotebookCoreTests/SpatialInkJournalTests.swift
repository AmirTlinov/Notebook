import Foundation
import Darwin
import Testing
@testable import NotebookCore

struct SpatialInkJournalTests {
  private func span(_ surface: SurfaceID = .board) -> SpatialInkSpan {
    .init(surface: surface, samples: [.init(point: .zero, worldPoint: surface.kind == .board ? .zero : nil,
      timeOffset: 0, width: 4, opacity: 0.5, force: 1, azimuth: 0, altitude: 1)])
  }

  private func admitNewNodes<K, V>(_ root: InkActionMapNode<K, V>?, known: inout Set<ObjectIdentifier>) -> Int {
    guard let root, known.insert(ObjectIdentifier(root)).inserted else { return 0 }
    return 1 + admitNewNodes(root.left, known: &known) + admitNewNodes(root.right, known: &known)
  }

  @Test func addressedInverseAndAppendShareHundredThousandActionSnapshots() throws {
    let actor = UUID(), span = span()
    let actions = (0..<100_000).map { SpatialInkAction(tool: .pen, spans: [span], stamp: .init(counter: UInt64($0 + 1), actor: actor)) }
    var journal = SpatialInkJournal(actions: actions, stamp: actions.last!.stamp)
    var captured = [journal], orderNodes = Set<ObjectIdentifier>(), idNodes = Set<ObjectIdentifier>()
    #expect(admitNewNodes(journal.storage.order, known: &orderNodes) == 100_000)
    #expect(admitNewNodes(journal.storage.ids, known: &idNodes) == 100_000)
    var maximumGateNodes = 0, maximumAppendNodes = 0, gateTime = Duration.zero, appendTime = Duration.zero
    for counter in 1...32 {
      let prior = journal, id = actions[[0, 50_000, 99_999][((counter - 1) / 2) % 3]].id
      let action = try #require(prior.action(id: id)), state = VersionStamp(counter: 100_000 + UInt64(counter), actor: actor)
      let result = NotebookSpatialInkCommand.state(actionID: id, creationStamp: action.stamp,
        expectedStateStamp: action.stateStamp, isActive: counter.isMultiple(of: 2), stateStamp: state,
        journalStamp: state, nativeRedo: counter.isMultiple(of: 2)).expectedResult
      let started = ContinuousClock.now
      let applied = journal.applyState(result)
      let sameSource = prior.hasSameActionStates(as: journal)
      let current = journal.action(id: id)
      gateTime += started.duration(to: .now)
      #expect(applied && !sameSource && current?.isActive == result.isActive)
      #expect(current?.stateStamp == result.stateStamp && current?.spans[0].samples.storage === span.samples.storage)
      #expect(prior.action(id: id) == action, "A retained scene/contact cannot observe the live owner's next gate")
      #expect(journal.storage.ids === prior.storage.ids && journal.storage.predecessorToken === prior.storage.token)
      let changed = admitNewNodes(journal.storage.order, known: &orderNodes)
      maximumGateNodes = max(maximumGateNodes, changed)
      #expect(changed <= 18 && journal.actionCount == 100_000)
      captured.append(journal)
    }
    for _ in 0..<32 {
      let prior = journal, started = ContinuousClock.now
      let action = journal.append(tool: .pen, spans: [span], actor: actor)
      let sameSource = prior.hasSameActionStates(as: journal)
      appendTime += started.duration(to: .now)
      #expect(action != nil && !sameSource && journal.actionCount == prior.actionCount + 1)
      let changed = admitNewNodes(journal.storage.order, known: &orderNodes)
        + admitNewNodes(journal.storage.ids, known: &idNodes)
      maximumAppendNodes = max(maximumAppendNodes, changed)
      #expect(changed <= 64)
      captured.append(journal)
    }
    let prior = journal
    let duplicate = journal.append(tool: .eraser, spans: [span], actor: actor, id: actions[50_000].id)
    #expect(duplicate == nil && prior.storage === journal.storage && prior.stamp == journal.stamp)
    #expect(captured[0].actions == actions && journal.actions.prefix(100_000).map(\.id) == actions.map(\.id))
    #expect(captured.count == 65)
    #expect(Array(journal.orderedActions) == journal.actions)
    var iterator = captured[0].orderedActions.makeIterator()
    #expect(iterator.next() == actions[0], "The streaming reader stays pinned to its original root")
    let order = try #require(journal.storage.order), ids = try #require(journal.storage.ids)
    let nodeBytes = malloc_size(Unmanaged.passUnretained(order).toOpaque()) + malloc_size(Unmanaged.passUnretained(ids).toOpaque())
    #expect(journal.retainedMetadataBytes >= journal.actionCount * nodeBytes,
      "The render cache must charge both real node allocations, not only the former action array")
    let tail = try #require(prior.storage.order?.last(where: { _ in true }))
    let tailStarted = ContinuousClock.now, undone = journal.undoLast(actor: actor)
    let tailTime = tailStarted.duration(to: .now)
    #expect(undone?.id == tail.id && undone?.isActive == false)
    #expect(prior.action(id: tail.id)?.isActive == true)
    #expect(admitNewNodes(journal.storage.order, known: &orderNodes) <= 18)
    print("SPATIAL_JOURNAL_100K inverses=32 appends=32 gateNewNodesMax=\(maximumGateNodes) appendNewNodesMax=\(maximumAppendNodes) gateTime=\(gateTime) appendTime=\(appendTime)")
    print("SPATIAL_JOURNAL_100K tailUndoTime=\(tailTime)")
  }

  private struct WireJournal: Codable {
    let format: Int
    let actions: [SpatialInkAction]
    let stamp: VersionStamp
  }

  @Test func wireAndIndependentWindowComparisonPreserveMembershipAndCausalGates() throws {
    let actor = UUID()
    var journal = SpatialInkJournal(stamp: .init(counter: 0, actor: actor))
    let firstAppend = journal.append(tool: .pen, spans: [span()], actor: actor)
    let first = try #require(firstAppend)
    _ = journal.append(tool: .eraser, spans: [span()], actor: actor)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let wire = WireJournal(format: 2, actions: journal.actions, stamp: journal.stamp)
    let bytes = try encoder.encode(wire)
    #expect(try encoder.encode(journal) == bytes, "The existing format and action order do not change")
    var external = try JSONDecoder().decode(SpatialInkJournal.self, from: bytes)
    #expect(external == journal && external.hasSameActionStates(as: journal))
    let changed = external.deactivate(first.id, actor: actor); #expect(changed)
    let reloaded = try JSONDecoder().decode(SpatialInkJournal.self, from: encoder.encode(external))
    #expect(!journal.hasSameActionStates(as: reloaded), "An external gate must invalidate the observable window")
    #expect(external.hasSameActionStates(as: reloaded))
    let reordered = SpatialInkJournal(actions: journal.actions.reversed(), stamp: journal.stamp)
    #expect(!journal.hasSameActionStates(as: reordered))
    let invalid = WireJournal(format: 2, actions: [first, first], stamp: journal.stamp)
    var decodedInvalid = try JSONDecoder().decode(SpatialInkJournal.self, from: encoder.encode(invalid))
    #expect(!decodedInvalid.isValid)
    _ = decodedInvalid.append(tool: .pen, spans: [span()], actor: actor)
    #expect(!decodedInvalid.isValid, "An append cannot admit a previously malformed journal")
  }

  @Test func addressedStatePreservesColdWindowAndRejectsStaleOrConflictingGates() throws {
    let actor = UUID()
    var journal = SpatialInkJournal(stamp: .init(counter: 0, actor: actor))
    let actionAppend = journal.append(tool: .pen, spans: [span()], actor: actor)
    let action = try #require(actionAppend)
    func state(_ id: UUID, _ active: Bool, _ counter: UInt64, creation: VersionStamp? = nil) -> NotebookSpatialInkResult {
      .init(actionID: id, creationStamp: creation ?? action.stamp, isActive: active,
        stateStamp: .init(counter: counter, actor: actor), journalStamp: .init(counter: counter, actor: actor))
    }
    let original = journal, undo = state(action.id, false, 2), redo = state(action.id, true, 3)
    let removed = journal.applyState(undo); #expect(removed)
    let restored = journal.applyState(redo); #expect(restored)
    #expect(!journal.hasSameActionStates(as: original), "ABA has a new causal gate even when its pixels match")
    let accepted = journal
    let retry = journal.applyState(redo); #expect(retry && journal.storage === accepted.storage)
    let stale = journal.applyState(undo); #expect(!stale && journal == accepted)
    let conflict = journal.applyState(state(action.id, false, 3)); #expect(!conflict && journal == accepted)
    let wrongSource = journal.applyState(state(action.id, false, 4, creation: .init(counter: 2, actor: actor)))
    #expect(!wrongSource && journal == accepted)
    let cold = journal.applyState(state(UUID(), false, 5)); #expect(cold)
    #expect(journal.storage === accepted.storage && journal.hasSameActionStates(as: accepted))
    #expect(journal.stamp.counter == 5 && journal.actionCount == 1)
  }

  @Test func lastActiveTraversalPreservesSurfaceAndPainterOrder() throws {
    let actor = UUID(), cover = SurfaceID.cover(UUID())
    var journal = SpatialInkJournal(stamp: .init(counter: 0, actor: actor))
    let firstAppend = journal.append(tool: .pen, spans: [span()], actor: actor)
    let first = try #require(firstAppend)
    let crossingAppend = journal.append(tool: .eraser, spans: [span(), span(cover)], actor: actor)
    let crossing = try #require(crossingAppend)
    let lastAppend = journal.append(tool: .pen, spans: [span(cover)], actor: actor)
    let last = try #require(lastAppend)
    let boardUndo = journal.undoLast(actor: actor, touching: .board)
    #expect(boardUndo?.id == crossing.id)
    let coverUndo = journal.undoLast(actor: actor, touching: cover)
    #expect(coverUndo?.id == last.id)
    let finalUndo = journal.undoLast(actor: actor)
    #expect(finalUndo?.id == first.id)
    let emptyUndo = journal.undoLast(actor: actor); #expect(emptyUndo == nil)
    #expect(journal.actions.map(\.id) == [first.id, crossing.id, last.id])
  }
}

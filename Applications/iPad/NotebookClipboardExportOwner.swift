import Foundation
import UIKit
import NotebookCore

/// The system clipboard has one publication owner across windows. Repeated
/// gestures replace one metadata request while the actual old producer drains.
@MainActor
final class NotebookClipboardExportOwner {
  static let shared = NotebookClipboardExportOwner()
  typealias Encoder = @Sendable (NotebookSelectionExport) async throws -> NotebookClipboard.Export

  @MainActor private struct SelectionWitness {
    let selection: UUID
    let references: [EditableElementReference]
    let ink: [NotebookSelectedInk.Key]
    let region: UUID?
    let targets: [CollaborationTarget]
    let revisions: [String?]
    let surfaces: [SurfaceID]
    let inkRevisions: [String?]
    let commands: [UUID?]
    let membership: UInt64
    let cursor: UInt64
    let contact: UInt64
    let navigation: UInt64

    init(_ model: NotebookAppModel) throws {
      let session = model.selectionSession
      references = session.region?.graphics ?? session.elements
      guard model.canExportSelection, references.count <= 32 else { throw Self.changed() }
      selection = session.id; ink = session.ink.map(\.key); region = session.region?.id
      var owners: [CollaborationTarget] = []
      for reference in references {
        guard model.elementCommandDrafts[reference] == nil else { throw Self.changed() }
        let target: CollaborationTarget
        switch reference {
        case .page(let owner,let id):
          guard model.pagePresentationSource(owner)?.element(id:id) != nil else { throw Self.changed() }
          target = .init(kind:.page,id:owner)
        case .spatial(let owner,let id):
          guard let surface = model.boardHierarchy?.board(owner)?.element(id:id)?.surface
            ?? model.scenePublication.pinnedElementSources[reference]?.spatial?.surface else { throw Self.changed() }
          target = surface.kind == .cover
            ? .init(kind:.cover,id:surface.ownerID!,boardID:owner) : .init(kind:.board,id:owner)
        }
        if !owners.contains(target) { owners.append(target) }
      }
      for target in session.ink.map({ $0.address.target }) + (session.region.map { [$0.address.target] } ?? []) {
        if !owners.contains(target) { owners.append(target) }
      }
      targets = owners; revisions = owners.map(model.collaborationRevision)
      surfaces = owners.map { target in
        target.kind == .page ? .page(target.id) : target.kind == .cover ? .cover(target.id) : .board(target.id)
      }
      inkRevisions = surfaces.map(model.selectionInkRevision)
      commands = references.map { model.elementCommandSources[$0]?.id }
      membership = model.lassoMembershipRevision; cursor = model.sceneContentCursor
      contact = model.inputGate.acceptedContactGeneration; navigation = model.navigationGeneration
    }

    func matches(_ model: NotebookAppModel) -> Bool {
      let session = model.selectionSession
      return model.shutdownPhase == .running && model.canExportSelection && session.id == selection
        && (session.region?.graphics ?? session.elements) == references
        && session.ink.map(\.key) == ink && session.region?.id == region
        && targets.map(model.collaborationRevision) == revisions
        && surfaces.map(model.selectionInkRevision) == inkRevisions
        && references.map({ model.elementCommandSources[$0]?.id }) == commands
        && references.allSatisfy({ model.elementCommandDrafts[$0] == nil })
        && model.lassoMembershipRevision == membership && model.sceneContentCursor == cursor
        && model.inputGate.acceptedContactGeneration == contact && model.navigationGeneration == navigation
    }

    static func changed() -> CollaborationError {
      .init("selection_not_ready", "Выделение изменилось. Повторите копирование или вырезание.")
    }
  }

  @MainActor private final class Request {
    weak var owner: NotebookContextMenus?
    weak var model: NotebookAppModel?
    let witness: SelectionWitness?
    let cut: Bool
    let clipboardVersion: Int
    init(owner: NotebookContextMenus, model: NotebookAppModel, witness: SelectionWitness?, cut: Bool,
      clipboardVersion: Int) {
      self.owner = owner; self.model = model; self.witness = witness; self.cut = cut
      self.clipboardVersion = clipboardVersion
    }
  }

  private struct Prepared: Sendable {
    let exported: NotebookClipboard.Export
    let material: NotebookSelectionExport
  }
  @MainActor private final class Flight {
    let request: Request
    var snapshot: NotebookSelectionExport?
    var worker: Task<Prepared, Error>?
    var cancelled = false
    init(request: Request, snapshot: NotebookSelectionExport, encoder: @escaping Encoder) {
      self.request = request; self.snapshot = snapshot
      worker = Task.detached(priority: .userInitiated) {
        // Even an immediately superseded request must join its already-started
        // addressed source read before relinquishing the provisional credit.
        let material = try await snapshot.materialized()
        try Task.checkCancellation()
        let exported = try await encoder(material)
        return .init(exported: exported, material: material)
      }
    }
    func cancel() { cancelled = true; snapshot?.transfer?.cancel(); worker?.cancel() }
    func discardProducer() -> NotebookClipboardWorkLease? {
      let work=snapshot?.workLease
      snapshot=nil;worker=nil
      return work
    }
  }

  private let encoder: Encoder
  private var running: Flight?
  private var waiting: Request?
  private var drainTask: Task<Void, Never>?

  init(encoder: @escaping Encoder = { material in
    try NotebookClipboard.prepareExport(material.prepare().fragment)
  }) { self.encoder = encoder }

  func task(for owner: NotebookContextMenus) -> Task<Void, Never>? {
    running?.request.owner === owner || waiting?.owner === owner ? drainTask : nil
  }

  func copySelection(_ model: NotebookAppModel, owner: NotebookContextMenus, selection: UUID, cut: Bool) {
    guard model.selectionSession.id == selection else { return }
    let clipboardVersion=UIPasteboard.general.changeCount
    do {
      if let running {
        running.cancel()
        waiting=nil
        waiting = try Request(owner:owner,model:model,witness:.init(model),cut:cut,clipboardVersion:clipboardVersion)
        return
      }
      // The first gesture freezes its material synchronously. Copy can finish
      // after a later selection change without following that new selection.
      let request = Request(owner:owner,model:model,witness:nil,cut:cut,clipboardVersion:clipboardVersion)
      let snapshot = try model.clipboardSelectionSnapshot()
      running = .init(request: request, snapshot: snapshot, encoder: encoder)
      drainTask = Task { await drain() }
    } catch { model.showCue(error.localizedDescription) }
  }

  func cancel(_ owner: NotebookContextMenus) {
    if waiting?.owner === owner { waiting = nil }
    if running?.request.owner === owner { running?.cancel() }
  }

  private func finish(_ flight: Flight) async {
    guard let worker=flight.worker else { return }
    do {
      let prepared = try await worker.value
      if !flight.cancelled, let owner = flight.request.owner, let model = flight.request.model,
        model.shutdownPhase == .running, UIPasteboard.general.changeCount == flight.request.clipboardVersion {
        if flight.request.cut && !model.selectionStillMatches(prepared.material) {
          model.showCue("Выделение изменилось. Повторите вырезание.")
        } else if !owner.publishClipboard(prepared.exported) {
          model.showCue("Не удалось записать буфер. Выделение сохранено.")
        } else if flight.request.cut {
          // This enters the accepted FIFO in the same actor turn as system
          // publication. A subsequent Copy does not await or revoke that Cut.
          model.cutExportedSelection(prepared.material)
        }
      }
    } catch is CancellationError {} catch {
      if !flight.cancelled { flight.request.model?.showCue(error.localizedDescription) }
    }
  }

  private func drain() async {
    while let flight = running {
      // The helper returns with every borrowed Prepared/Task result out of
      // scope. Clear Flight's source and result pins before admitting a new body.
      await finish(flight)
      var work=flight.discardProducer()
      running = nil
      if let work {
        work.finish()
        // finish() schedules a release from arbitrary worker threads. Here the
        // actual producer is joined, so make that credit available immediately.
        // The admission owner ignores a reservation transferred to an accepted Cut.
        flight.request.model?.releaseClipboardWork(work.reservation)
      }
      work=nil
      guard let request = waiting else { break }
      waiting = nil
      guard request.owner != nil, let model = request.model, model.shutdownPhase == .running,
        UIPasteboard.general.changeCount == request.clipboardVersion else { continue }
      guard request.witness?.matches(model) == true else {
        model.showCue(SelectionWitness.changed().localizedDescription); continue
      }
      do {
        let snapshot = try model.clipboardSelectionSnapshot()
        // Keep the queued request's identity and clipboard version across the join.
        running = .init(request: request, snapshot: snapshot, encoder: encoder)
      } catch { model.showCue(error.localizedDescription) }
    }
    drainTask = nil
  }
}

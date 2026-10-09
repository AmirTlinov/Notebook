import Foundation
import NotebookCore

extension SceneRenderResources {
  /// The validated viewport admits its program owners before a SwiftUI mount.
  /// Physical consumers borrow these same executors and alone enable input.
  func preparePrograms(in cohort: SceneCompositionCohort, model: NotebookAppModel) {
    guard profile == .interactive, model.permitsScenePreparation else { return }
    let modelID = ObjectIdentifier(model)
    var demanded = Set<ProgramPreparationKey>()
    for address in cohort.runtimeOwners.sorted(by: { $0.elementID < $1.elementID }) {
      guard let receipt = cohort.sourceReceipts[address], receipt.demand.source.requiresLiveRuntime else { continue }
      let focus = InteractiveElementReference.board(boardID: address.plane.boardID, elementID: address.elementID)
      let key = ProgramPreparationKey(model: modelID, focus: focus)
      demanded.insert(key)
      // A mounted owner already receives its current source and input role.
      // Source publication must not turn off an accepted physical contact.
      if programPreparations[key]?.owner.hasAttachedConsumer == true { continue }
      let rendered: SpatialElement?
      if let coverID = address.plane.coverID {
        rendered = cohort.frame.covers[coverID]?.elements.first { $0.id == address.elementID }
      } else {
        rendered = cohort.frame.workset(boardID: address.plane.boardID).elements.first { $0.id == address.elementID }
      }
      guard let rendered else { continue }
      let demand = receipt.demand, source = demand.source
      let owner = programPreparation(focus: focus, model: model)
      NotebookNavigationObservation.webPreparation("scene_program_preparation_accepted", ownerID: owner.pageFrameOwner,
        sourceID: source.id)
      owner.acceptPublishedCohort(.init(model: model,
        demand: .init(source: source, basis: model.programStateBasis(focus: focus, rendered: source),
          active: true, inputEnabled: false, focused: model.interactiveElementFocus == focus,
          permitsPreparation: model.permitsScenePreparation, policy: demand.policy,
          capture: demand, fallbackEntryID: cohort.sourceRasters[address]?.entryID,
          runtimeFailure: model.compositionTiles.runtimeFailure(at: address, source: source, policy: demand.policy)),
        focus: focus, pageTurnActivity: nil, rasterPreparation: nil, cohort: cohort,
        onState: { [weak model] state, completion in
          model?.commitSpatialElementState(boardID: address.plane.boardID, rendered: rendered,
            state: state, onCommitted: completion) ?? false
        }))
    }
    // A superseded viewport can disappear before mounting its first consumer.
    // Withdraw that admitted demand through the existing residency lifecycle.
    for (key, entry) in programPreparations where key.model == modelID && !demanded.contains(key) {
      guard case .board = key.focus, !entry.owner.hasAttachedConsumer else { continue }
      leaveProgramPreparation(entry.owner, focus: key.focus, model: model)
    }
  }

  func programPreparation(focus: InteractiveElementReference, model: NotebookAppModel) -> PreparedAgentElementPreparationOwner {
    let key = ProgramPreparationKey(model: ObjectIdentifier(model), focus: focus)
    if let entry = programPreparations[key], !entry.owner.isRetired {
      entry.isMounted = true; return entry.owner
    }
    let owner = PreparedAgentElementPreparationOwner(resources: self)
    programPreparations[key] = .init(model: model, owner: owner)
    owner.onResidentRelease = { [weak self, weak owner] in
      guard let self, let owner, let entry = self.programPreparations[key], entry.owner === owner,
        owner.isRetired || !entry.isMounted else { return }
      self.programPreparations[key] = nil; owner.retire(afterUpdate: true)
    }
    return owner
  }

  func leaveProgramPreparation(_ owner: PreparedAgentElementPreparationOwner,
    focus: InteractiveElementReference, model: NotebookAppModel) {
    let key = ProgramPreparationKey(model: ObjectIdentifier(model), focus: focus)
    guard let entry = programPreparations[key], entry.owner === owner, !owner.hasAttachedConsumer else { return }
    entry.isMounted = false
    if !owner.leaveViewport() {
      programPreparations[key] = nil; owner.retire(afterUpdate: true)
    }
  }

  func retireProgramPreparations(ownedBy model: NotebookAppModel) {
    let keys = programPreparations.keys.filter { $0.model == ObjectIdentifier(model) }
    for key in keys { programPreparations.removeValue(forKey: key)?.owner.retire(afterUpdate: true) }
  }
}

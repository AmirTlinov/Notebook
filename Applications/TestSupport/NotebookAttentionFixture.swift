import NotebookCore
@testable import Notebook

/// Projection-only fixtures use the exact complete live payload prepared by
/// their cohort. Installed-canvas and portal-handoff tests supply real receipts.
@MainActor
func cohortInkSources(_ cohort: SceneCompositionCohort) -> [SurfaceID: SpatialInkInstalledSource] {
  let surfaces = [SurfaceID.board(cohort.plan.rootBoardID)] + cohort.plan.liveOwners.compactMap { owner -> SurfaceID? in
    if case .item(let id) = owner.id { return .cover(id) }; return nil
  }
  return Dictionary(uniqueKeysWithValues: surfaces.map { ($0, .init(surface: $0, journal: cohort.liveData.ink)) })
}

import NotebookCore
import SwiftUI

struct NotebookAgentFeedbackOverlay: View {
  @Environment(NotebookAppModel.self) private var model
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let presence: SessionPresence

  var body: some View {
    let viewport = CGRect(x:0,y:0,width:presence.viewport.x,height:presence.viewport.y)
    let materials = model.agentFeedback.episodes.values.sorted { $0.id < $1.id }.flatMap { episode -> [(NotebookAgentFeedback.Episode, NotebookAgentFeedbackSurface)] in
      guard model.agentFeedbackRevisionIsCurrent(episode.subject) else { return [] }
      var subjects = [episode.subject]
      let reference = episode.subject.reference
      if reference.target.kind == .document, reference.elementID == nil, reference.region == nil,
        let document = model.documents[reference.target.id] {
        subjects = document.blocks.filter { $0.kind == .interactive }.map { block in
          .init(reference:.init(target:reference.target,elementID:block.id,revision:reference.revision),expected:episode.subject.expected)
        }
      }
      return subjects.compactMap { subject in
        guard let surface = NotebookAttentionProjection.agentFeedback(subject,model:model,presence:presence),
          surface.rect.intersects(viewport) else { return nil }
        return (.init(subject:subject,startedAt:episode.startedAt,endsAt:episode.endsAt,isAttention:episode.isAttention),surface)
      }
    }

    ZStack(alignment:.topLeading) {
      if !materials.isEmpty {
        TimelineView(.animation(minimumInterval:1/30, paused:reduceMotion || materials.allSatisfy { $0.0.isAttention })) { time in
          ZStack(alignment:.topLeading) {
            ForEach(materials, id:\.0.id) { episode, surface in
              NotebookAgentFeedbackMaterial(surface:surface,episode:episode,date:time.date,reduceMotion:reduceMotion)
            }
          }.frame(width:viewport.width,height:viewport.height,alignment:.topLeading)
        }
      }
    }
    .allowsHitTesting(false).accessibilityHidden(true)
    .task(id:model.presentationPlayer.stage?.id) {
      await model.prepareAgentAttention(model.presentationPlayer.stage)
    }
    .onChange(of:model.agentFeedback.episodes) { _, _ in
      model.publishAgentDocumentFeedback()
    }
    .onDisappear { model.agentFeedback.stop(); DocumentRenderRegistry.shared.setAgentFeedback([]) }
  }
}

extension NotebookAppModel {
  func publishAgentDocumentFeedback() {
    guard let presence else { DocumentRenderRegistry.shared.setAgentFeedback([]); return }
    let current = agentFeedback.episodes.values.filter { episode in
      let subject = episode.subject, reference = subject.reference
      guard reference.target.kind == .document, reference.elementID != nil || reference.region == nil,
        agentFeedbackRevisionIsCurrent(subject),
        presence.mode == .document, presence.focusedItemID == reference.target.id,
        let document = documents[reference.target.id], let state = documentStates[document.id] else { return false }
      return DocumentRenderRegistry.shared.hasLiveSurface(document:document,state:state,pageIndex:presence.documentPageIndex,
        scope:reference.elementID.map(DocumentPresentationScope.block) ?? .page)
    }
    DocumentRenderRegistry.shared.setAgentFeedback(Array(current))
  }

  func agentFeedbackRevisionIsCurrent(_ subject: NotebookAgentFeedbackChange.Subject) -> Bool {
    let expected = subject.expected
    return collaborationRevision(expected.target) == expected.revision
      && (expected.stateRevision == nil || documentStates[expected.target.id]?.stamp.revision == expected.stateRevision)
      && (expected.inkRevision == nil || (expected.target.kind == .page
        ? pages[expected.target.id]?.drawingStamp.revision : spatialInk?.stamp.revision) == expected.inkRevision)
  }

  func confirmAgentFeedback(presence visible: SessionPresence, scene: WorkspaceSceneWorkset?, cohort: SceneCompositionCohort?) {
    #if os(iOS)
    guard permitsScenePreparation, presencePhase == .settled, presence == visible,
      let cohort, cohort.isPaintInstalled, cohort.frame.index.generationID == sceneIndex?.generationID else { return }
    let subjects = agentFeedback.pendingSubjects + agentFeedback.attention + agentFeedback.episodes.values.map(\.subject)
    guard !subjects.isEmpty else { DocumentRenderRegistry.shared.setAgentFeedback([]); return }
    let viewport = CGRect(x:0,y:0,width:visible.viewport.x,height:visible.viewport.y)
    var ready = Set<String>(), offscreen = Set<String>()
    for subject in subjects {
      let reference = subject.reference
      let inScope: Bool = switch reference.target.kind {
      case .page: visible.mode == .page && workspace?.selectedPageID == reference.target.id
      case .document: visible.mode == .document && visible.focusedItemID == reference.target.id
      case .board: visible.boardID == reference.target.id
      case .cover: visible.boardID == reference.target.boardID
      case .workspace, .codeFragment: false
      }
      guard inScope else { offscreen.insert(subject.key); continue }
      guard agentFeedbackRevisionIsCurrent(subject) else { continue }
      guard let rect = NotebookAttentionProjection.frame(reference,model:self,presence:visible) else { continue }
      guard viewport.intersects(rect) else { offscreen.insert(subject.key); continue }
      let installed: Bool
      switch reference.target.kind {
      case .page: installed = pages[reference.target.id].map { pagePresentations.isPresented($0) } ?? false
      case .document:
        if let document = documents[reference.target.id], let state = documentStates[document.id] {
          installed = DocumentRenderRegistry.shared.hasLiveSurface(document:document,state:state,pageIndex:visible.documentPageIndex,
            scope:reference.elementID.map(DocumentPresentationScope.block) ?? .page)
        } else { installed = false }
      case .board, .cover:
        installed = scene.map { sceneRepresents(reference,in:$0,cohort:cohort,presence:visible,inkRevision:subject.expected.inkRevision) } ?? false
      case .workspace, .codeFragment: installed = false
      }
      if installed { ready.insert(subject.key) }
    }
    agentFeedback.presented(ready:ready,offscreen:offscreen)
    if let stageID = agentFeedback.attentionID, !agentFeedback.attention.isEmpty,
      agentFeedback.attention.allSatisfy({ ready.contains($0.key) }) { presentationPlayer.rendered(stageID,material:.attention) }
    publishAgentDocumentFeedback()
    #endif
  }
}

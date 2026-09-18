import Foundation
import Testing
@testable import NotebookCore

struct NotebookAgentFeedbackTests {
  private func fixture(_ body: (NotebookStore, UUID, CollaborationTarget) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-feedback-\(UUID())")
    defer { try? FileManager.default.removeItem(at:root) }
    let store = NotebookStore(root:root), actor = UUID()
    let header = try store.initializeWorkspace(actor:actor,pageSize:.init(width:834,height:1194))
    try body(store,actor,.init(kind:.board,id:header.rootBoardID))
  }
  private func insert(_ id: String, store: NotebookStore, target: CollaborationTarget, actor: UUID, human: Bool = false) throws -> CollaborationReceipt {
    let action = CollaborationAction(summary:id,expected:[.init(target:target,revision:try store.targetContentRevision(target:target))],
      operations:[.init(kind:.insertElement,target:target,id:id,values:["kind":.string("graphic"),"source":.string(""),
        "worldOrigin":try .encode(WorldPoint.zero), "frame":try .encode(PageRect(x:100,y:100,width:180,height:120)),
        "graphic":try .encode(NotebookGraphic(shape:.triangle))])])
    return try human ? store.applyNativeGraphicAction(action,actor:actor) : store.applyCollaborationAction(action,actor:actor)
  }
  @Test func feedbackNamesExactCurrentMaterialWithoutPreparingHistory() throws {
    try fixture { store, actor, target in
      let agent = try insert("agent",store:store,target:target,actor:UUID())
      let human = try insert("human",store:store,target:target,actor:actor,human:true)
      let actions = try [agent,human].map(NotebookActionReadModel.init)
      let before = try store.currentChangeCursor()
      let changes = try store.agentFeedbackChanges(actions)
      #expect(changes.count == 1)
      #expect(changes.first?.actionID == agent.id)
      #expect(changes.first?.subjects.first?.reference.elementID == "agent")
      #expect(changes.first?.subjects.first?.expected.revision == (try store.targetContentRevision(target:target)))
      #expect(try store.currentChangeCursor() == before)
    }
  }
  @Test func continuedOrUndoneMaterialCannotMasqueradeAsAnAgentResult() throws {
    try fixture { store, actor, target in
      let agent = try insert("shape",store:store,target:target,actor:UUID())
      _ = try store.applyNativeGraphicAction(.init(summary:"human continuation",
        expected:[.init(target:target,revision:store.targetContentRevision(target:target))],operations:[
          .init(kind:.updateElement,target:target,id:"shape",values:["graphic":.object(["label":.string("human")])])]),actor:actor)
      #expect(try store.agentFeedbackChanges([store.actionReadModel(agent.id)]).isEmpty)
      let other = try insert("other",store:store,target:target,actor:UUID())
      _ = try store.undoCollaborationAction(other.id,actor:actor)
      #expect(try store.agentFeedbackChanges([store.actionReadModel(other.id)]).isEmpty)
    }
  }
  @Test func explicitAttentionIsAddressedAndRejectsStaleReferencesWithoutWrites() throws {
    try fixture { store, actor, target in
      let receipt = try insert("shape",store:store,target:target,actor:UUID())
      let ref = try #require(store.actionResultReferences(NotebookActionReadModel(receipt)).first)
      let cursor = try store.currentChangeCursor()
      #expect(try store.agentAttentionSubjects([ref]).first?.reference == ref)
      #expect(try store.currentChangeCursor() == cursor)
      _ = try store.applyNativeGraphicAction(.init(summary:"change",expected:[.init(target:target,revision:store.targetContentRevision(target:target))],operations:[
        .init(kind:.updateElement,target:target,id:"shape",values:["graphic":.object(["label":.string("new")])])]),actor:actor)
      #expect(throws: CollaborationError.self) { try store.agentAttentionSubjects([ref]) }
    }
  }
  @Test func reorderingNamesTheMembersAndNewDocumentsNameTheirPhysicalCover() throws {
    try fixture { store, actor, target in
      _ = try insert("first",store:store,target:target,actor:actor)
      _ = try insert("second",store:store,target:target,actor:actor)
      let reordered = try store.applyCollaborationAction(.init(additionalOwners:[target],summary:"Reorder",expected:[.init(target:target,revision:store.targetContentRevision(target:target))],
        operations:[.init(kind:.reorderElements,target:target,values:["ids":.array([.string("second"),.string("first")])])]),actor:UUID())
      let result = try #require(store.agentFeedbackChanges([NotebookActionReadModel(reordered)],elementsInScene:[target.key:["first","second"]]).first)
      #expect(Set(result.subjects.compactMap(\.reference.elementID)) == ["first","second"])
      let bounded = try store.agentFeedbackChanges([NotebookActionReadModel(reordered)],elementsInScene:[target.key:["first"]])
      #expect(bounded.first?.subjects.compactMap(\.reference.elementID) == ["first"])
      #expect(try store.agentFeedbackChanges([NotebookActionReadModel(reordered)]).isEmpty)
      let documentID = UUID(), workspace = CollaborationTarget(kind:.workspace,id:target.id)
      let created = try store.applyCollaborationAction(.init(summary:"New document",expected:[target,workspace].map {
        try .init(target:$0,revision:store.targetContentRevision(target:$0))
      },operations:[.init(kind:.createDocument,target:target,id:documentID.uuidString,values:["center":try .encode(WorldPoint.zero),
        "paperSize":.string("a4"),"blocks":.array([])])]),actor:UUID())
      let cover = try #require(store.agentFeedbackChanges([NotebookActionReadModel(created)]).first?.subjects.first)
      #expect(cover.reference.target == CollaborationTarget(kind:.cover,id:documentID,boardID:target.id))
      #expect(cover.expected.target == target)
    }
  }

  @Test func equalStrokeBoundsStillNameTwoDistinctActions() throws {
    try fixture { store, actor, target in
      let ids = [UUID(),UUID()]
      let values: [String:JSONValue] = ["width":.number(4),"opacity":.number(1),"worldOrigin":try .encode(WorldPoint.zero),
        "points":.array([.object(["x":.number(100),"y":.number(120)]),.object(["x":.number(160),"y":.number(190)])])]
      let action = try store.applyCollaborationAction(.init(summary:"Two strokes",expected:[.init(target:target,
        revision:store.targetContentRevision(target:target),inkRevision:store.readSpatialInk(surfaces:[]).stamp.revision)],
        operations:ids.map { .init(kind:.appendInkStroke,target:target,id:$0.uuidString,values:values) }),actor:actor)
      let subjects = try #require(store.agentFeedbackChanges([NotebookActionReadModel(action)]).first?.subjects)
      #expect(Set(subjects.compactMap(\.strokeID)) == Set(ids))
      #expect(Set(subjects.map(\.key)).count == 2)
    }
  }

  @Test func attentionUsesExistingBoundedPresentationWithoutCamera() throws {
    let reference = CollaborationReference(target:.init(kind:.board,id:UUID()),elementID:"shape",revision:"exact")
    let step = NotebookPresentationStep(duration:3,transition:0,attention:[reference])
    #expect(step.isValid && step.camera == nil && step.focus == nil && step.svg == nil)
    #expect(try JSONDecoder().decode(NotebookPresentationStep.self,from:JSONEncoder().encode(step)) == step)
    #expect(!NotebookPresentationStep(attention:[]).isValid)
    #expect(!NotebookPresentationStep(attention:[.init(target:reference.target,revision:"")]).isValid)
  }
}

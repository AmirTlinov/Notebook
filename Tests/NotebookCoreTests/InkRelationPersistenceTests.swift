import Foundation
import Testing
@testable import NotebookCore

@Suite(.serialized)
struct InkRelationPersistenceTests {
  private enum Failure: Error { case disk }
  private func source(count: Int = 1_000_000) throws -> InkSampleRelations {
    let samples: [SpatialInkSample]=(0..<100).map { i in
      let point=SpatialPoint(x:Double(i)/4,y:Double(i%13)/2)
      return SpatialInkSample(point:point,
      timeOffset:Double(i)/128,width:4,opacity:0.5,force:Double(i%7)/8,azimuth:Double(i%9)/8,altitude:0.5) }
    let body=InkSampleRelations(sourceID:UUID(),revision:UUID(),samples:samples,header:.init(tool:.pen,color:.black))
      .settingExit(.init(x:InkDyadic(32)!,y:.zero,time:.one),revision:UUID())
    return try #require(body.repeated(count/100,revision:UUID()))
  }
  private func fixture(_ work: (NotebookStore,NotebookStore,UUID,UUID,UUID) throws -> Void) throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("ink-relations-\(UUID())")
    defer { try? FileManager.default.removeItem(at:root) }
    let a=NotebookStore(root:root.appendingPathComponent("a")),b=NotebookStore(root:root.appendingPathComponent("b")),actor=UUID()
    let header=try a.initializeWorkspace(actor:actor,pageSize:.init(width:834,height:1194))
    try b.prepareEmptyWorkspace(workspaceID:header.workspaceID)
    let index=try a.loadIndex(),page=try #require(index.selectedPageID)
    try work(a,b,actor,index.selectedItemID,page)
  }
  private func bound(_ action: SpatialInkAction) -> InkSampleRelations {
    .init(sourceID:action.id,measurements:action.spans[0].samples,header:.init(tool:action.tool,color:action.color))
  }
  private func row(_ id: UUID) -> String { "spatial-ink.json#/actions/@\(id.uuidString.lowercased())/spans" }
  private func bodyHash(_ store: NotebookStore,_ address: String) throws -> String {
    try store.sqlRead { try #require($0.rows("SELECT hash FROM records WHERE address=?",[.text(address)]).first?[0].text) }
  }

  @Test func millionEventSourceSurvivesSQLiteReopenDeliveryAndUndoWithoutExpansion() throws {
    try fixture { a,b,actor,cover,page in
      let source=try source(),stamp=VersionStamp(counter:1,actor:actor)
      let action=SpatialInkAction(id:source.sourceID,tool:.pen,
        spans:[.init(surface:.cover(cover),measurements:source.measurements)],stamp:stamp)
      let start=ContinuousClock.now
      _=try a.commitSpatialInk(.append(action,journalStamp:stamp))
      let save=start.duration(to:.now),openStart=ContinuousClock.now
      let reopened=try #require(NotebookStore(root:a.root).readSpatialInk(surfaces:[.cover(cover)]).actions.first)
      let restore=openStart.duration(to:.now)
      #expect(try bound(reopened).measurements.encodedRelations() == source.measurements.encodedRelations())
      #expect(bound(reopened).allocationSummary.nodes == source.allocationSummary.nodes)
      #expect(try a.blobSize(hash:bodyHash(a,row(action.id))) < 15_000)
      // A page uses exactly the same body, not a full array hidden in drawingData.
      let originalPage=try a.loadPage(page)
      let drawing=PageInkDrawing(actions:[source.restoredAction()])
      _=try a.savePage(.init(id:page,size:originalPage.size,actor:actor,drawingData:try drawing.dataRepresentation()))
      let paper=try #require(try a.readPageInkAction(pageID:page,actionID:source.sourceID)).action
      #expect(try paper.samples.encodedRelations() == source.measurements.encodedRelations())
      let observed=try #require(try a.readPageInkAction(pageID:page,actionID:source.sourceID))
      #expect(throws:NotebookStorageError.limitExceeded("ink_measurement_read")) { try observed.measuredReadProjection() }
      let through=try a.currentChangeCursor(),transferStart=ContinuousClock.now
      try receiveFixtureChanges(from:a,to:b,peerID:actor)
      let transfer=transferStart.duration(to:.now)
      #expect(try b.currentChangeCursor() > 0)
      let remote=try #require(NotebookStore(root:b.root).readSpatialInk(surfaces:[.cover(cover)]).actions.first)
      #expect(try bound(remote).measurements.encodedRelations() == source.measurements.encodedRelations())
      #expect(try b.readPageInkAction(pageID:page,actionID:source.sourceID)?.action == paper)
      let hash=try bodyHash(a,row(action.id)),state=VersionStamp(counter:2,actor:actor)
      _=try a.commitSpatialInk(.state(actionID:action.id,creationStamp:stamp,isActive:false,stateStamp:state,journalStamp:state))
      for change in try a.changeJournal(after:through) {
        try receiveFixtureChanges(.init(source:.init(deviceID:actor,generation:actor),change:change),from:a,to:b)
      }
      #expect(try bodyHash(a,row(action.id)) == hash && bodyHash(b,row(action.id)) == hash)
      let undone=try #require(b.readSpatialInk(surfaces:[.cover(cover)]).actions.first)
      #expect(!undone.isActive && undone.stateStamp == state)
      let middle=500_027,restored=bound(undone)
      let read=try restored.access(restored.address(at:middle))
      #expect(read.cost.decodedSamples == 1 && read.cost.visitedNodes <= 3)
      let edited=try restored.editing(restored.address(at:middle),to:source.sample(at:0),revision:UUID())
      #expect(edited.payloadBytes < source.payloadBytes+25_000)
      #expect(InkSampleRelations.sameBits(restored.sample(at:middle),source.sample(at:middle)))
      print("RELATION_SQLITE logical=1000000 save=\(save) reopen=\(restore) delivery=\(transfer) storedBytes=\(try a.blobSize(hash:hash)) nodes=\(restored.allocationSummary.nodes)")
    }
  }

  @Test func alternateExactEncodingKeepsAcceptedRevisionAndNeverResurrectsOrConflicts() throws {
    try fixture { a,b,actor,cover,page in
      let original=try source(count:1000),stamp=VersionStamp(counter:1,actor:actor)
      let action=SpatialInkAction(id:original.sourceID,tool:.pen,
        spans:[.init(surface:.cover(cover),measurements:original.measurements)],stamp:stamp)
      _=try a.commitSpatialInk(.append(action,journalStamp:stamp))
      let alternate=InkSampleRelations(sourceID:original.sourceID,revision:UUID(),samples:original.decoded(),header:original.header)
        .settingExit(original.storage.exit,revision:UUID())
      #expect(original.measurements == alternate.measurements)
      #expect(try original.measurements.encodedRelations() != alternate.measurements.encodedRelations())
      let echo=SpatialInkAction(id:action.id,tool:.pen,spans:[.init(surface:.cover(cover),measurements:alternate.measurements)],stamp:stamp)
      let before=try a.currentChangeCursor(),hash=try bodyHash(a,row(action.id))
      _=try a.commitSpatialInk(.append(echo,journalStamp:stamp))
      try a.commandTransaction {
        let accepted=try #require(a.storedFragments(address:row(action.id),descendants:false).first)
        #expect(try !a.writeFragment(accepted.replacing(value:.encode(echo.spans)),database:a.currentSQL!))
      }
      #expect(try bodyHash(a,row(action.id)) == hash && a.currentChangeCursor() == before)
      let state=VersionStamp(counter:2,actor:actor)
      _=try a.commitSpatialInk(.state(actionID:action.id,creationStamp:stamp,isActive:false,stateStamp:state,journalStamp:state))
      #expect(try !a.commitSpatialInk(.append(echo,journalStamp:stamp)).isActive)
      #expect(try bodyHash(a,row(action.id)) == hash)
      let drawing=PageInkDrawing(actions:[original.restoredAction()]).removing([original.sourceID])
      let replay=try drawing.appending(alternate.restoredAction())
      #expect(try replay.dataRepresentation() == drawing.dataRepresentation())
      // Bit identity, not Double ==: signed zero is part of the measurement.
      let zero=SpatialInkSample(point:.zero,timeOffset:0,width:1,opacity:1,force:0,azimuth:0,altitude:1)
      let negative=SpatialInkSample(point:.init(x:-0.0,y:0),timeOffset:0,width:1,opacity:1,force:0,azimuth:0,altitude:1)
      #expect(InkMeasurements([zero]) != InkMeasurements([negative]))
      let changed=try original.editing(original.address(at:500),to:negative,revision:UUID())
      let collision=SpatialInkAction(id:action.id,tool:.pen,spans:[.init(surface:.cover(cover),measurements:changed.measurements)],stamp:stamp)
      #expect(throws:NotebookStorageError.transactionConflict) { try a.commitSpatialInk(.append(collision,journalStamp:stamp)) }
    }
  }

  @Test(arguments:[NotebookStorageFault.afterRecordWrites,.beforeCommit,.afterCommit])
  func interruptedCompactPublicationRetriesExactlyOnce(fault: NotebookStorageFault) throws {
    try fixture { a,_,actor,cover,_ in
      let source=try source(),stamp=VersionStamp(counter:1,actor:actor)
      let action=SpatialInkAction(id:source.sourceID,tool:.pen,spans:[.init(surface:.cover(cover),measurements:source.measurements)],stamp:stamp)
      let before=try a.currentChangeCursor()
      let failing=NotebookStore(root:a.root) { if String(describing:$0) == String(describing:fault) { throw Failure.disk } }
      #expect(throws:Failure.self) { try failing.commitSpatialInk(.append(action,journalStamp:stamp)) }
      _=try NotebookStore(root:a.root).commitSpatialInk(.append(action,journalStamp:stamp))
      #expect(try a.currentChangeCursor() == before+1)
      let restored=try #require(a.readSpatialInk(surfaces:[.cover(cover)]).actions.first)
      #expect(try restored.spans[0].samples.encodedRelations() == source.measurements.encodedRelations())
      #expect(bound(restored).allocationSummary.nodes == source.allocationSummary.nodes)
    }
  }
}

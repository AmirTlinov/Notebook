import Foundation
import Testing
@testable import NotebookCore

@Suite(.serialized)
struct InkRelationMigrationTests {
  private enum Failure: Error { case disk }
  private struct Fixture {
    let store: NotebookStore, actor: UUID, peer: UUID, cover: UUID, page: UUID
    let paper: PageInkAction, spatial: SpatialInkAction
  }
  private func fixture(_ work: (Fixture) throws -> Void) throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("ink-migration-\(UUID())")
    defer { try? FileManager.default.removeItem(at:root) }
    let store=NotebookStore(root:root),actor=UUID(),peer=UUID()
    _=try store.initializeWorkspace(actor:actor,pageSize:.init(width:834,height:1194))
    let index=try store.loadIndex(),page=try #require(index.selectedPageID),cover=index.selectedItemID
    let samples: [SpatialInkSample]=(0..<300).map { i in
      let point=SpatialPoint(x:Double(i)/4,y:Double(i%7)/2)
      return .init(point:point,timeOffset:Double(i)/128,width:4,opacity:0.5,force:0.75,azimuth:0,altitude:1)
    }
    let paper=PageInkAction(tool:.pen,samples:samples,sequence:1)
    _=try store.savePage(.init(id:page,size:.init(width:834,height:1194),actor:actor,
      drawingData:PageInkDrawing(actions:[paper]).dataRepresentation()))
    let spatial=SpatialInkAction(tool:.pen,spans:[.init(surface:.cover(cover),samples:samples)],stamp:.init(counter:1,actor:actor))
    _=try store.commitSpatialInk(.append(spatial,journalStamp:spatial.stamp))
    try work(.init(store:store,actor:actor,peer:peer,cover:cover,page:page,paper:paper,spatial:spatial))
  }
  private func old(_ row: NotebookStoredFragment) throws -> NotebookStoredFragment {
    if row.isInkMeasurementBody {
      if row.collection == "samples" { return try row.replacing(value:.encode(row.value.decode(InkMeasurements.self).materialized())) }
      return try row.replacing(value:.array(row.value.array.map { span in
        try span.setting("samples",.encode(span["samples"]!.decode(InkMeasurements.self).materialized()))
      }))
    }
    if row.address == "spatial-ink.json#" { return row.replacing(value:row.value.setting("format",.number(1))) }
    return row
  }
  /// Manufacture the prior admitted serialization, not an archive import. The
  /// fixture keeps real record addresses, clocks, references and ownership.
  private func downgrade(_ f: Fixture) throws -> [String:Data] {
    var bodies:[String:Data]=[:]
    let db=try NotebookSQLConnection(url:f.store.databaseURL,writable:true)
    try db.run("BEGIN IMMEDIATE")
    do {
      let rows=try db.rows("SELECT b.data FROM records r JOIN blobs b ON b.hash=r.hash WHERE (r.file LIKE 'pages/%' AND r.collection='samples') OR r.file='spatial-ink.json' ORDER BY r.address")
      for data in rows.compactMap({ $0[0].blob }) {
        let row=try JSONDecoder().decode(NotebookStoredFragment.self,from:data),previous=try old(row)
        guard previous != row else { continue }
        let data=try NotebookStore.storageEncoder.encode(previous),hash=try db.putBlob(data)
        bodies[hash]=data
        try db.run("UPDATE records SET hash=? WHERE address=?",[.text(hash),.text(row.address)])
      }
      try db.run("PRAGMA user_version=16")
      try db.run("COMMIT")
    } catch { try? db.run("ROLLBACK");throw error }
    return bodies
  }
  private func version(_ store: NotebookStore) throws -> Int64 {
    let db=try NotebookSQLConnection(url:store.databaseURL,writable:false)
    return try db.rows("PRAGMA user_version").first![0].integer!
  }
  @Test func currentPairConversionPreservesBitsIDsClocksAndAcknowledgedHistory() throws {
    try fixture { f in
      let cursor=try f.store.currentChangeCursor(),workspace=try f.store.workspaceHeader().workspaceID
      try f.store.acknowledgePeer(peerID:f.peer,through:cursor)
      let oldBodies=try downgrade(f),opened=NotebookStore(root:f.store.root)
      let paper=try #require(try opened.readPageInkAction(pageID:f.page,actionID:f.paper.id)).action
      let spatial=try #require(opened.readSpatialInk(surfaces:[.cover(f.cover)]).actions.first)
      #expect(paper == f.paper && spatial == f.spatial)
      #expect(try opened.workspaceHeader().workspaceID == workspace)
      #expect(try version(opened) == NotebookStore.currentDatabaseVersion)
      #expect(try opened.peerCursor(peerID:f.peer,direction:.outgoing) == cursor)
      #expect(try opened.currentChangeCursor() == cursor+1)
      for (hash,bytes) in oldBodies { #expect(try opened.readBlobChunk(hash:hash,offset:0,maxBytes:1_048_576) == bytes) }
      #expect(throws:CollaborationError.self) { try opened.changeJournal(after:cursor-1) }
      let changes=try opened.changeJournal(after:cursor)
      #expect(changes.count == 1)
      let proof=try opened.archiveContentProof()
      #expect(try NotebookStore(root:opened.root).archiveContentProof() == proof)
      #expect(try NotebookStore(root:opened.root).currentChangeCursor() == cursor+1)
    }
  }
  enum DeliveryState: CaseIterable { case drained,unacknowledged,anotherPeerPending }
  @Test(arguments:DeliveryState.allCases)
  func incomingJournalGenerationsDoNotBecomeAdditionalDeliveryPeers(state: DeliveryState) throws {
    try fixture { f in
      let sources=[NotebookReplicationSource(deviceID:f.peer,generation:f.peer),
        .init(deviceID:f.peer,generation:UUID()),.init(deviceID:f.peer,generation:UUID())]
      for (i,source) in sources.enumerated() {
        _=try f.store.admitReplicationSource(source)
        try f.store.commandTransaction(advancesReadRevision:false) {
          try f.store.currentSQL!.run("INSERT INTO peer_cursors(peer_id,direction,sequence) VALUES(?,'incoming',?)",
            [.text(source.cursorKey),.integer(Int64(i+3))])
        }
      }
      let cursor=try f.store.currentChangeCursor()
      let acknowledged=state != .unacknowledged ? cursor : 1
      try f.store.acknowledgePeer(peerID:f.peer,through:acknowledged)
      if state == .anotherPeerPending { try f.store.acknowledgePeer(peerID:UUID(),through:0) }
      _=try downgrade(f)
      let opened=NotebookStore(root:f.store.root)
      if state == .drained {
        #expect(try opened.readPageInkAction(pageID:f.page,actionID:f.paper.id)?.action == f.paper)
        #expect(try opened.peerCursor(peerID:f.peer,direction:.outgoing) == cursor)
        for (i,source) in sources.enumerated() { #expect(try opened.incomingCursor(source:source) == UInt64(i+3)) }
        #expect(try opened.currentChangeCursor() == cursor+1)
      } else {
        do { _=try opened.workspaceHeader();Issue.record("A journal generation cannot acknowledge delivery") }
        catch let error as CollaborationError { #expect(error.code == "ink_migration_pending_peer") }
        #expect(try version(f.store) == 16)
        let db=try NotebookSQLConnection(url:f.store.databaseURL,writable:false)
        #expect(try db.rows("SELECT sequence FROM peer_cursors WHERE peer_id=? AND direction='outgoing'",[.text(f.peer.uuidString.lowercased())]).first?[0].integer == Int64(acknowledged))
        #expect(try db.rows("SELECT peer_id FROM peer_cursors").count == (state == .anotherPeerPending ? 5 : 4))
      }
    }
  }
  @Test func pendingPeerRefusesMigrationWithoutChangingAnyStoredBytesOrCursor() throws {
    try fixture { f in
      try f.store.acknowledgePeer(peerID:f.peer,through:1)
      let bodies=try downgrade(f),db=try NotebookSQLConnection(url:f.store.databaseURL,writable:false)
      let before=try db.rows("SELECT address,hash FROM records ORDER BY address").map { "\($0[0].text!)|\($0[1].text!)" }
      do { _=try NotebookStore(root:f.store.root).workspaceHeader();Issue.record("Lost pending delivery") }
      catch let error as CollaborationError { #expect(error.code == "ink_migration_pending_peer") }
      #expect(try version(f.store) == 16)
      #expect(try db.rows("SELECT address,hash FROM records ORDER BY address").map { "\($0[0].text!)|\($0[1].text!)" } == before)
      #expect(try db.rows("SELECT value FROM metadata WHERE key='ink_outgoing_floor'").isEmpty)
      for (hash,data) in bodies { #expect(try db.blob(hash) == data) }
    }
  }
  @Test(arguments:[NotebookStorageFault.afterRecordWrites,.beforeCommit,.afterCommit])
  func interruptedAdmissionIsAtomicAndReopenDoesNotConvertTwice(fault: NotebookStorageFault) throws {
    try fixture { f in
      let cursor=try f.store.currentChangeCursor()
      _=try downgrade(f)
      let failing=NotebookStore(root:f.store.root) { if String(describing:$0) == String(describing:fault) { throw Failure.disk } }
      #expect(throws:Failure.self) { try failing.workspaceHeader() }
      let opened=NotebookStore(root:f.store.root)
      #expect(try opened.readPageInkAction(pageID:f.page,actionID:f.paper.id)?.action == f.paper)
      #expect(try opened.readSpatialInk(surfaces:[.cover(f.cover)]).actions == [f.spatial])
      #expect(try opened.currentChangeCursor() == cursor+1)
      #expect(try version(opened) == NotebookStore.currentDatabaseVersion)
    }
  }
  @Test func migratedLifecyclePreimagesKeepTheOriginalActionAndStillUndoItsInk() throws {
    try fixture { f in
      let header=try f.store.workspaceHeader(),board=CollaborationTarget(kind:.board,id:header.rootBoardID)
      let page=CollaborationTarget(kind:.page,id:f.page),cover=CollaborationTarget(kind:.cover,id:f.cover,boardID:header.rootBoardID)
      let added=UUID(),paperID=UUID(),spatialID=UUID()
      let points: JSONValue = .array([.object(["x":.number(20),"y":.number(40)]),.object(["x":.number(60),"y":.number(80)])])
      let operations: [CollaborationOperation] = [
        .init(kind:.appendInkStroke,target:page,id:paperID.uuidString,values:["points":points]),
        .init(kind:.appendInkStroke,target:cover,id:spatialID.uuidString,values:["points":points]),
        .init(kind:.createNotebook,target:board,id:added.uuidString,values:["center":try .encode(WorldPoint.zero),"pageID":try .encode(UUID())])]
      let basis=try f.store.readBasis(targets:[page,cover,board,.init(kind:.workspace,id:header.rootBoardID)])
      let action=CollaborationAction(summary:"Штрихи и новый блокнот",expected:basis.owners,operations:operations)
      let receipt=try f.store.applyCollaborationAction(action,actor:f.actor)
      let inverse=try #require(receipt.lifecycleInverse)
      var oldReference=inverse,oldBodies=0
      try f.store.commandTransaction {
        let db=f.store.currentSQL!,root=try f.store.readLifecycleInverseRoot(reference:inverse,actionID:receipt.id)
        var parts:[String]=[]
        for (ordinal,hash) in root.parts.enumerated() {
          let part=try f.store.readLifecycleInversePart(hash:hash,actionID:receipt.id,ordinal:ordinal)
          let records=try part.records.map { record -> NotebookActionRecordChange in
            func previous(_ hash:String?) throws -> String? {
              guard let hash else { return nil }
              let current=try f.store.readLifecycleInverseFragment(hash:hash,address:record.address),previous=try old(current)
              if current != previous { oldBodies += 1 }
              return try db.putBlob(NotebookStore.storageEncoder.encode(previous))
            }
            return try .init(address:record.address,beforeHash:previous(record.beforeHash),afterHash:previous(record.afterHash))
          }
          parts.append(try db.putBlob(NotebookStore.storageEncoder.encode(NotebookLifecycleInversePart(format:part.format,
            workspaceID:part.workspaceID,actionID:part.actionID,ordinal:part.ordinal,records:records))))
        }
        let oldRoot=NotebookLifecycleInverseRoot(format:root.format,workspaceID:root.workspaceID,actionID:root.actionID,
          recordCount:root.recordCount,parts:parts)
        oldReference=try .init(rootHash:db.putBlob(NotebookStore.storageEncoder.encode(oldRoot)),recordCount:root.recordCount)
        var historical=receipt;historical.lifecycleInverse=oldReference
        try f.store.publishRecords(writes:["collaboration/actions/"+receipt.id.uuidString.lowercased()+".json":.encode(historical)])
      }
      #expect(oldBodies >= 2 && oldReference != inverse)
      _=try downgrade(f)
      let reopened=NotebookStore(root:f.store.root),migrated=try reopened.collaborationAction(receipt.id)
      #expect(migrated.action == receipt.action && migrated.createdAt == receipt.createdAt)
      #expect(migrated.requestFingerprint == receipt.requestFingerprint && migrated.changes == receipt.changes)
      #expect(migrated.lifecycleInverse == inverse)
      // The old manifest remains authenticated evidence; no blob is overwritten.
      try reopened.visitLifecycleInverse(reference:oldReference,actionID:receipt.id) { _ in }
      _=try reopened.undoCollaborationAction(receipt.id,actor:f.actor)
      #expect(try PageInkDrawing.decode(reopened.loadPage(f.page).drawingData).activeActions.map(\.id) == [f.paper.id])
      #expect(try reopened.readSpatialInk(surfaces:[.cover(f.cover)]).actions.filter(\.isActive).map(\.id) == [f.spatial.id])
      #expect(try reopened.readItemHeader(added) == nil)
    }
  }

}

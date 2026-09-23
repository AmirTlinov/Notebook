import Foundation
import CryptoKit
import Testing
@testable import NotebookCore

@Suite(.serialized)
struct PageInkVisibilityTests {
  private enum Failure: Error { case disk }
  private func sample(_ i: Int) -> SpatialInkSample {
    .init(point:.init(x:Double(i % 700),y:40 + Double(i % 31)),timeOffset:Double(i)/240,
      width:4,opacity:0.375,force:Double((i * 17) % 997)/1024,azimuth:-0.0,altitude:1)
  }
  private func stroke(count: Int = 2) -> PageInkAction {
    .init(tool:.pen,color:.init(red:0.125,green:0.25,blue:0.75),samples:(0..<count).map(sample))
  }
  private func commit(_ mutation: PageInkMutation, in store: NotebookStore, page: UUID, actor: UUID) throws -> PreparedPageInkChange {
    let source=try store.loadPage(page)
    let change=try source.prepareInkChange(mutation,stamp:.init(counter:source.drawingStamp.counter,actor:actor))
    _=try store.commitPageInk(pageID:page,command:.init(change))
    return change
  }

  @Test func addressedGateInHundredThousandActionsSharesTheOriginalMaterialAndOrder() throws {
    let actor=UUID(), measured=stroke().samples
    let actions=(0..<100_000).map { _ in PageInkAction(tool:.pen,measurements:measured) }
    let source=PageInkDrawing(actions:actions), id=actions[50_001].id
    let original=try #require(source.action(id:id))
    var drawing=source
    let start=ContinuousClock.now
    for counter in 1...32 {
      drawing=try drawing.settingActive(counter.isMultiple(of:2),for:[id],stamp:.init(counter:UInt64(counter),actor:actor))
      let action=try #require(drawing.action(id:id))
      #expect(action.id == original.id && action.sequence == original.sequence)
      #expect(action.samples.storage === measured.storage && action.samples.revision == measured.revision)
      #expect(action.color == original.color && action.elementTargets == original.elementTargets)
      #expect(drawing.actionCount == 100_000 - (counter.isMultiple(of:2) ? 0 : 1))
      #expect(drawing.action(id:actions[99_999].id) == source.action(id:actions[99_999].id))
    }
    print("PAGE_GATE_100K actions=100000 transitions=32 elapsed=\(start.duration(to:.now)) sharedBody=true")
    #expect(drawing.appendedActions(after:source.actionCursor) == nil)
    #expect(source.action(id:id) == original, "Old snapshots are immutable, not another live gate owner")
  }

  @Test func onlyANewerExplicitGateCanRestoreTheSameAction() throws {
    let actor=UUID(), target=InkElementTarget(elementID:"shape",frame:.init(x:0,y:0,width:100,height:100))
    let eraser=PageInkAction(tool:.eraser,samples:[sample(1),sample(2)],elementTargets:[target])
    let source=PageInkDrawing(actions:[stroke(),eraser,stroke()])
    let undone=try source.settingActive(false,for:[eraser.id],stamp:.init(counter:2,actor:actor))
    let repeated=try undone.settingActive(true,for:[eraser.id],stamp:.init(counter:3,actor:actor))
    #expect(try source.merging(undone) == undone && undone.merging(source) == undone)
    #expect(try undone.merging(repeated) == repeated && repeated.merging(undone) == repeated)
    #expect(repeated.actions.map(\.id) == source.actions.map(\.id))
    let restored=try #require(repeated.action(id:eraser.id))
    #expect(restored.samples.storage === eraser.samples.storage && restored.elementTargets == [target])
    let collision=try source.settingActive(false,for:[eraser.id],stamp:.init(counter:3,actor:actor))
    #expect(throws:PageInkDrawing.InkError.self) { try repeated.merging(collision) }
    let old=try source.settingActive(false,for:[eraser.id],stamp:.init(counter:1,actor:actor))
    #expect(try repeated.merging(old) == repeated)
    #expect(try repeated.appending(eraser) == repeated, "A repeated contact cannot overwrite its explicit state")
  }

  @Test(arguments:[NotebookStorageFault.beforeCommit,.afterCommit])
  func undoAndRepeatRetryTheirExactGateWithoutReadingOrWritingTheHundredThousandSampleBody(_ fault: NotebookStorageFault) throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let store=NotebookStore(root:root),actor=UUID()
    _=try store.initializeWorkspace(actor:actor,pageSize:.init(width:834,height:1194))
    let page=try #require(store.loadIndex().selectedPageID), action=stroke(count:100_000)
    let appended=try commit(.append(action),in:store,page:page,actor:actor)
    let samples=pageFile(page)+"#/drawingData/actions/@"+action.id.uuidString.lowercased()+"/samples"
    let initialHash=try store.sqlRead { try #require($0.rows("SELECT hash FROM records WHERE address=?",[.text(samples)]).first?[0].text) }
    for active in [false,true] {
      let source=try store.loadPage(page)
      let change=try source.prepareInkChange(.setActive([action.id],active),stamp:.init(counter:source.drawingStamp.counter,actor:actor))
      let failing=NotebookStore(root:root) { point in
        if String(describing:point) == String(describing:fault) { throw Failure.disk }
      }
      #expect(throws:Failure.self) { try failing.commitPageInk(pageID:page,command:.init(change)) }
      let didCommit:Bool
      if case .afterCommit=fault { didCommit=true } else { didCommit=false }
      #expect(try store.readPageInkAction(pageID:page,actionID:action.id)?.action.isActive == (didCommit ? active : !active))
      let start=ContinuousClock.now
      _=try store.commandTransaction(readAllowance:.init(rows:512,bytes:262_144,valueBytes:65_536,reason:"gate_must_not_read_samples")) {
        try store.commitPageInk(pageID:page,command:.init(change))
      }
      print("PAGE_GATE_HEADER_ONLY active=\(active) samples=100000 retry=\(fault) elapsed=\(start.duration(to:.now))")
      let cursor=try store.currentChangeCursor()
      _=try store.commitPageInk(pageID:page,command:.init(change))
      #expect(try store.currentChangeCursor() == cursor)
      let accepted=try #require(store.readPageInkAction(pageID:page,actionID:action.id)?.action)
      #expect(accepted.visibility == .init(isActive:active,stateStamp:change.stamp))
      #expect(accepted.sequence == appended.drawing.action(id:action.id)?.sequence)
      #expect(accepted.color == action.color && accepted.samples.revision == action.samples.revision)
      #expect(try accepted.samples.encodedRelations() == action.samples.encodedRelations())
      #expect(try store.nativeHistory(domain:.page(page),actor:actor) == (active ? [.ink([action.id])] : []))
      #expect(try store.sqlRead { try $0.rows("SELECT hash FROM records WHERE address=?",[.text(samples)]).first?[0].text } == initialHash)
    }
  }

  @Test func staleInverseRollsBackHistoryAndEveryAddressedGateIncludingSameStampConflicts() throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let store=NotebookStore(root:root),actor=UUID()
    _=try store.initializeWorkspace(actor:actor,pageSize:.init(width:834,height:1194))
    let page=try #require(store.loadIndex().selectedPageID),a=stroke(),b=stroke()
    _=try commit(.append(a),in:store,page:page,actor:actor)
    _=try commit(.append(b),in:store,page:page,actor:actor)
    let stale=try store.loadPage(page).prepareInkChange(.setActive([a.id,b.id],false),stamp:.init(counter:20,actor:actor))
    _=try commit(.setActive([a.id],false),in:store,page:page,actor:actor)
    let restored=try commit(.setActive([a.id],true),in:store,page:page,actor:actor)
    let before=try store.loadPage(page),history=try store.nativeHistory(domain:.page(page),actor:actor),cursor=try store.currentChangeCursor()
    #expect(throws:CollaborationError.self) { try store.commitPageInk(pageID:page,command:.init(stale)) }
    let accepted=try #require(restored.drawing.action(id:a.id))
    #expect(throws:CollaborationError.self) {
      try store.commitPageInk(pageID:page,command:.state([a.id:accepted.visibility],isActive:false,baseStamp:before.drawingStamp,stamp:restored.stamp))
    }
    #expect(try store.loadPage(page) == before)
    #expect(try store.nativeHistory(domain:.page(page),actor:actor) == history)
    #expect(try store.currentChangeCursor() == cursor)
  }

  @Test func deliveryAndDelayedSnapshotsPreserveTheNewGateWithoutDuplicatingMaterial() throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let a=NotebookStore(root:root.appendingPathComponent("a")),b=NotebookStore(root:root.appendingPathComponent("b")),actor=UUID(),peer=UUID()
    let header=try a.initializeWorkspace(actor:actor,pageSize:.init(width:834,height:1194))
    try b.prepareEmptyWorkspace(workspaceID:header.workspaceID)
    let page=try #require(a.loadIndex().selectedPageID),stroke=stroke()
    _=try commit(.append(stroke),in:a,page:page,actor:actor)
    _=try commit(.setActive([stroke.id],false),in:a,page:page,actor:actor)
    try receiveFixtureChanges(from:a,to:b,peerID:actor)
    let old=try b.loadPage(page)
    let repeated=try commit(.setActive([stroke.id],true),in:a,page:page,actor:actor)
    let peerStroke=self.stroke()
    _=try commit(.append(peerStroke),in:b,page:page,actor:peer)
    try receiveFixtureChanges(from:b,to:a,peerID:peer)
    try receiveFixtureChanges(from:a,to:b,peerID:actor)
    for store in [a,b] {
      _=try store.savePage(old)
      let drawing=try store.loadPage(page).inkDrawing()
      #expect(drawing.actions.map(\.id) == [stroke.id,peerStroke.id])
      #expect(drawing.action(id:stroke.id)?.visibility == repeated.drawing.action(id:stroke.id)?.visibility)
      #expect(try drawing.action(id:stroke.id)?.samples.encodedRelations() == stroke.samples.encodedRelations())
    }
    _=try commit(.setActive([stroke.id],false),in:a,page:page,actor:actor)
    try receiveFixtureChanges(from:a,to:b,peerID:actor)
    _=try b.savePage(.init(id:page,size:old.size,actor:actor,drawingData:repeated.data))
    #expect(try b.loadPage(page).inkDrawing().action(id:stroke.id)?.isActive == false)
    try receiveFixtureChanges(from:a,to:b,peerID:actor)
    #expect(try b.loadPage(page).inkDrawing() == a.loadPage(page).inkDrawing())
  }

  @Test func referenceAdmissionSeparatesExistingMaterialAtomicallyWithoutRewritingContentOrDelivery() throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let store=NotebookStore(root:root),actor=UUID(),peer=UUID()
    _=try store.initializeWorkspace(actor:actor,pageSize:.init(width:834,height:1194))
    let page=try #require(store.loadIndex().selectedPageID),action=stroke()
    _=try commit(.append(action),in:store,page:page,actor:actor)
    let accepted=try #require(store.readPageInkAction(pageID:page,actionID:action.id)?.action)
    let target=CollaborationTarget(kind:.page,id:page),expected=try store.referenceRevision(target:target)
    let cursor=try store.currentChangeCursor()
    try store.acknowledgePeer(peerID:peer,through:cursor)
    let readCursor=try store.currentReadCursor()
    let rows=try store.sqlRead { try $0.rows("SELECT address,hash FROM records ORDER BY address").map { [$0[0].text!,$0[1].text!] } }
    let history=try store.nativeHistory(domain:.page(page),actor:actor)
    let owner=target.key,address=pageFile(page)+"#/drawingData/actions/@"+action.id.uuidString.lowercased()
    let database=try NotebookSQLConnection(url:store.databaseURL,writable:true)
    // Recreate admission 19's actual joined action contribution, not an empty
    // index. Migration must subtract it before adding header + measured body.
    var digest=try #require(database.rows("SELECT digest FROM reference_owners WHERE owner_key=?",[.text(owner)]).first?[0].blob)
    func toggle(_ address:String,_ hash:String) {
      let contribution=Data(SHA256.hash(data:Data(("reference-contribution-v2\n"+address+"\n"+hash).utf8)))
      for (offset,byte) in contribution.enumerated() { digest[offset] ^= byte }
    }
    for row in try database.rows("SELECT address,hash FROM reference_contributions WHERE address=? OR address=?",[.text(address),.text(address+"/samples")]) {
      toggle(row[0].text!,row[1].text!)
    }
    let oldHash=try collaborationHash(JSONValue.encode(accepted));toggle(address,oldHash)
    let oldRevision=SHA256.hash(data:Data(("reference-owner-v2\n"+owner+"\n").utf8)+digest).map { String(format:"%02x",$0) }.joined()
    #expect(oldRevision != expected)
    try database.run("BEGIN IMMEDIATE")
    try database.run("UPDATE reference_owners SET digest=?,hash=? WHERE owner_key=?",[.blob(digest),.text(oldRevision),.text(owner)])
    try database.run("UPDATE reference_contributions SET hash=? WHERE address=?",[.text(oldHash),.text(address)])
    try database.run("DELETE FROM reference_contributions WHERE address=?",[.text(address+"/samples")])
    try database.run("PRAGMA user_version=19");try database.run("COMMIT")
    let interrupted=NotebookStore(root:root) { if case .beforeCommit=$0 { throw Failure.disk } }
    #expect(throws:Failure.self) { try interrupted.workspaceHeader() }
    #expect(try database.rows("PRAGMA user_version").first?[0].integer == 19)
    #expect(try database.rows("SELECT hash FROM reference_owners WHERE owner_key=?",[.text(owner)]).first?[0].text == oldRevision)
    let reopened=NotebookStore(root:root)
    #expect(try reopened.referenceRevision(target:target) == expected)
    #expect(try reopened.referenceRevision(target:target) == NotebookStore.referenceRevision(target:target,files:reopened.collaborationSnapshot()))
    #expect(try reopened.sqlRead { try $0.rows("SELECT address,hash FROM records ORDER BY address").map { [$0[0].text!,$0[1].text!] } } == rows)
    #expect(try reopened.currentChangeCursor() == cursor && reopened.currentReadCursor() == readCursor)
    #expect(try reopened.peerCursor(peerID:peer,direction:.outgoing) == cursor)
    #expect(try reopened.nativeHistory(domain:.page(page),actor:actor) == history)
    #expect(try NotebookStore(root:root).referenceRevision(target:target) == expected)
  }
}

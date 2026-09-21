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

  @Test func independentOccurrencesPersistAndDeliverOneBodyWithSeparateRevisions() throws {
    try fixture { a,b,actor,cover,page in
      let original=try source(), started=ContinuousClock.now
      var actions:[SpatialInkAction]=[]
      for i in 1...24 {
        // Reconstruct an independent source, not just another pointer to the
        // first action; the immutable description is nevertheless exact.
        let same=try source(),stamp=VersionStamp(counter:UInt64(i),actor:actor)
        let action=SpatialInkAction(tool:.pen,spans:[.init(surface:.cover(cover),measurements:same.measurements)],stamp:stamp)
        _=try a.commitSpatialInk(.append(action,journalStamp:stamp));actions.append(action)
      }
      let drawing=PageInkDrawing(actions:actions.map {
        .init(id:$0.id,tool:$0.tool,measurements:$0.spans[0].samples)
      })
      _=try a.savePage(.init(id:page,size:.init(width:834,height:1194),actor:actor,drawingData:drawing.dataRepresentation()))
      let save=started.duration(to:.now)
      let bodies=try a.sqlRead { try $0.rows("SELECT hash,length(data) FROM blobs WHERE substr(data,1,4) IN (?,?)",[.blob(Data("NIB1".utf8)),.blob(Data("NIB2".utf8))]) }
      #expect(bodies.count == 1)
      let shared=try #require(bodies.first?[0].text),bytes=try #require(bodies.first?[1].integer)
      let bodyBytes=try a.sqlRead { try $0.rows("SELECT sum(length(data)) FROM blobs WHERE substr(data,1,3) IN (?,?)",[.blob(Data("NIB".utf8)),.blob(Data("NIN".utf8))]).first![0].integer! }
      #expect(bodyBytes < Int64(try original.measurements.encodedRelations().count+256))
      let reopened=try NotebookStore(root:a.root).readSpatialInk(surfaces:[.cover(cover)])
      #expect(reopened.actions.map(\.id) == actions.map(\.id))
      #expect(Set(reopened.actions.map { $0.spans[0].samples.revision }).count == 24)
      #expect(reopened.actions.allSatisfy { $0.spans[0].samples.storage === reopened.actions[0].spans[0].samples.storage })
      var transmittedBodies:[String]=[],transmitted:[String]=[],totalBytes=0,waitedForBody=false
      let transferStart=ContinuousClock.now
      var cursor:UInt64=0
      while true {
       let page=try a.changeJournal(after:cursor)
       guard let last=page.last else { break }
       for change in page {
        let delivery=NotebookReplicationDelivery(source:.init(deviceID:actor,generation:actor),change:change)
        _=try b.admitReplicationSource(delivery.source)
        while true {
          let missing=try b.missingBlobHashes(for:change)
          if missing.isEmpty { break }
          if missing.contains(shared),!waitedForBody {
            let before=try b.incomingCursor(source:delivery.source)
            #expect(throws:NotebookStorageError.self) { try b.applyDelivery(delivery) }
            #expect(try b.incomingCursor(source:delivery.source) == before)
            waitedForBody=true
          }
          for hash in missing {
            let data=try a.readBlobChunk(hash:hash,offset:0,maxBytes:1_048_576)
            #expect(data.count == (try a.blobSize(hash:hash)))
            totalBytes += data.count
            transmitted.append(hash)
            if data.starts(with:Data("NIB".utf8)) || data.starts(with:Data("NIN".utf8)) { transmittedBodies.append(hash) }
            try b.stageBlob(data:data,expectedHash:hash)
          }
        }
        try b.applyDelivery(delivery)
        try b.applyDelivery(delivery)
       }
       cursor=last.sequence
      }
      let transfer=transferStart.duration(to:.now)
      #expect(waitedForBody && transmittedBodies.filter { $0 == shared }.count == 1)
      #expect(Set(transmittedBodies).count == transmittedBodies.count)
      #expect(try transmittedBodies.reduce(Int64(0)) { try $0+a.blobSize(hash:$1) } == bodyBytes)
      let received=try NotebookStore(root:b.root).readSpatialInk(surfaces:[.cover(cover)])
      #expect(received == reopened)
      #expect(try PageInkDrawing.decode(b.loadPage(page).drawingData) == drawing)
      let inlineBytes=try a.sqlRead { database in
        try transmitted.reduce(0) { total,hash in
          let data=try database.blob(hash)
          if data.starts(with:Data("NIB".utf8)) || data.starts(with:Data("NIN".utf8)) { return total }
          guard (try? JSONDecoder().decode(NotebookStoredFragment.self,from:data)) != nil else { return total+data.count }
          return try total+NotebookStore.storageEncoder.encode(database.decodedStoredFragment(from:data)).count
        }
      }
      #expect(totalBytes < inlineBytes/2)
      let state=VersionStamp(counter:25,actor:actor)
      _=try a.commitSpatialInk(.state(actionID:actions[0].id,creationStamp:actions[0].stamp,isActive:false,stateStamp:state,journalStamp:state))
      #expect(try a.blobSize(hash:shared) == bytes)
      #expect(try a.readSpatialInk(surfaces:[.cover(cover)]).actions.filter(\.isActive).count == 23)
      print("INK_DURABLE_SHARED occurrences=48 logicalEvents=48000000 rootBytes=\(bytes) bodyBytes=\(bodyBytes) uniqueBodies=1 transferredBodyBytes=\(bodyBytes) allTransferredBytes=\(totalBytes) inlineControlBytes=\(inlineBytes) save=\(save) delivery=\(transfer)")
    }
  }

  @Test func oneLocalEditDeliversOnlyChangedGraphPartsAndStillUndoesAtThePeer() throws {
    try fixture { a,b,actor,_,page in
      let values:[SpatialInkSample]=(0..<100_000).map { i in
        let point=SpatialPoint(x:Double(i)/2,y:64+sin(Double(i)*0.31)*20)
        let force=Double((i*17)%997)/1024
        return .init(point:point,timeOffset:Double(i)/128,width:4,opacity:0.75,force:force,azimuth:0,altitude:1)
      }
      let source=InkSampleRelations(sourceID:UUID(),revision:UUID(),samples:values,header:.init(tool:.pen,color:.black))
      let frame=PageRect(x:0,y:0,width:50_000,height:128),target=CollaborationTarget(kind:.page,id:page)
      func freehand(_ source: InkSampleRelations) -> NotebookFreehand {
        .init(layers:[.init(tool:.pen,color:.black,measured:.init(sourceID:source.sourceID,measurements:source.measurements,frame:frame))])
      }
      let graphic=NotebookGraphic(shape:.freehand,freehand:freehand(source)),start=ContinuousClock.now
      _=try a.applyNativeElementEdits([.init(kind:.insertElement,target:target,id:"source",values:[
        "kind":.string("graphic"),"source":.string(""),"frame":try .encode(PageRect(x:0,y:0,width:600,height:128)),"graphic":try .encode(graphic)])],
        summary:"Общий источник",sources:[.init(target:target,id:"source")],actor:actor)
      try receiveFixtureChanges(from:a,to:b,peerID:actor)
      let initial=start.duration(to:.now),cursor=try a.currentChangeCursor()
      let before=try #require(try a.readPageElement(pageID:page,elementID:"source"))
      let changed=try source.editing(source.address(at:50_027),to:.init(point:values[50_027].point,timeOffset:values[50_027].timeOffset,
        width:12,opacity:1,force:0.5,azimuth:0,altitude:1),revision:UUID())
      let saveStart=ContinuousClock.now
      let receipt=try a.applyNativeElementEdits([.init(kind:.updateElement,target:target,id:"source",values:[
        "graphic":.object(["freehand":try .encode(freehand(changed))])])],summary:"Одна локальная правка",
        sources:[.init(target:target,id:"source",page:before)],actor:actor).receipt
      let save=saveStart.duration(to:.now),transferStart=ContinuousClock.now
      var sourceBytes=0,allBytes=0,newParts=0,refusedChild=false
      for change in try a.changeJournal(after:cursor) {
        let delivery=NotebookReplicationDelivery(source:.init(deviceID:actor,generation:actor),change:change)
        while true {
          let missing=try b.missingBlobHashes(for:change)
          if missing.isEmpty { break }
          for hash in missing {
            let data=try a.readBlobChunk(hash:hash,offset:0,maxBytes:1_048_576)
            #expect(data.count == (try a.blobSize(hash:hash)))
            if data.starts(with:Data("NIN1".utf8)) {
              newParts += 1
              if !refusedChild {
                let through=try b.incomingCursor(source:delivery.source)
                #expect(throws:NotebookStorageError.self) { try b.applyDelivery(delivery) }
                #expect(try b.incomingCursor(source:delivery.source) == through)
                refusedChild=true
              }
            }
            if data.starts(with:Data("NIB".utf8)) || data.starts(with:Data("NIN".utf8)) { sourceBytes += data.count }
            allBytes += data.count;try b.stageBlob(data:data,expectedHash:hash)
          }
        }
        try b.applyDelivery(delivery);try b.applyDelivery(delivery)
      }
      let transfer=transferStart.duration(to:.now),portableBytes=try changed.measurements.encodedRelations()
      #expect(refusedChild && newParts < 32)
      #expect(sourceBytes < portableBytes.count/100 && allBytes < portableBytes.count/20)
      let peer=NotebookStore(root:b.root),loaded=try #require(try peer.readPageElement(pageID:page,elementID:"source"))
      #expect(try loaded.graphic?.freehand?.layers[0].measured?.measurements.encodedRelations() == portableBytes)
      #expect(InkSampleRelations.sameBits(source.sample(at:50_027),values[50_027]))
      _=try peer.undoCollaborationAction(receipt.id,actor:UUID())
      #expect(try peer.readPageElement(pageID:page,elementID:"source")?.graphic == graphic)
      print("INK_GRAPH_LOCAL_EDIT events=100000 fullBodyBytes=\(portableBytes.count) newParts=\(newParts) sourceTransferredBytes=\(sourceBytes) allTransferredBytes=\(allBytes) initialSaveAndDelivery=\(initial) editSave=\(save) editDelivery=\(transfer)")
    }
  }

  @Test func declaredBodyPathsPreserveUnrelatedValuesAndRejectCorruptReferences() throws {
    try fixture { a,_,_,_,_ in
      let original=try source(),portable=try JSONValue.encode(original.measurements)
      let small=try JSONValue.encode(InkMeasurements([original.sample(at:0)]))
      let lookalike:JSONValue = .object(["inkBody":.string(String(repeating:"a",count:64)),"revision":.string(UUID().uuidString)])
      let invalid:JSONValue = .string((Data("NIM1".utf8)+Data(repeating:0,count:2048)).base64EncodedString())
      let value:JSONValue = .object(["nested":.array([portable]),"ordinary":lookalike,"small":small,
        "invalid":invalid,"noncanonical":.string(portable.string!+"\n")])
      let fragment=NotebookStoredFragment(address:"local/ink-codec.json#",file:"local/ink-codec.json",parent:nil,
        collection:"",member:"",position:0,value:value,collections:[])
      let data=try a.commandTransaction { try a.currentSQL!.encodedStoredFragment(fragment) }
      let raw=try JSONDecoder().decode(NotebookStoredFragment.self,from:data)
      #expect(raw.inkBodies == [["nested","0"]])
      #expect(raw.value["ordinary"] == lookalike && raw.value["small"] == small)
      #expect(raw.value["invalid"] == invalid && raw.value["noncanonical"] == value["noncanonical"])
      #expect(try a.sqlRead { try $0.decodedStoredFragment(from:data) } == fragment)
      for paths in [[["missing"]],[["nested","00"]],[["ordinary"]],[["nested","0"],["nested","0"]]] {
        let bad=try JSONValue.encode(raw).setting("inkBodies",.encode(paths))
        let bytes=try NotebookStore.storageEncoder.encode(bad)
        #expect(throws:(any Error).self) { try a.sqlRead { try $0.decodedStoredFragment(from:bytes) } }
      }
      let hash=try #require(raw.inkBodyHashes.first),body=try a.sqlRead { try $0.blob(hash) }
      try a.commandTransaction { try a.currentSQL!.run("DELETE FROM blobs WHERE hash=?",[.text(hash)]) }
      #expect(throws:NotebookStorageError.blobMissing(hash)) { try a.sqlRead { try $0.decodedStoredFragment(from:data) } }
      try a.stageBlob(data:body,expectedHash:hash)
      try a.commandTransaction {
        var corrupt=body;corrupt[corrupt.count-1] ^= 1
        try a.currentSQL!.run("UPDATE blobs SET data=? WHERE hash=?",[.blob(corrupt),.text(hash)])
      }
      #expect(throws:NotebookStorageError.blobHashMismatch) { try a.sqlRead { try $0.decodedStoredFragment(from:data) } }
      // A pre-existing hash is never sufficient evidence of exact equality.
      #expect(throws:NotebookStorageError.blobHashMismatch) {
        try a.commandTransaction { try a.currentSQL!.encodedStoredFragment(fragment) }
      }
    }
  }

  @Test func boundedAddressedReadChargesTheBodyAndNotOnlyItsReference() throws {
    try fixture { a,_,actor,cover,_ in
      let source=try source(),stamp=VersionStamp(counter:1,actor:actor)
      let action=SpatialInkAction(tool:.pen,spans:[.init(surface:.cover(cover),measurements:source.measurements)],stamp:stamp)
      _=try a.commitSpatialInk(.append(action,journalStamp:stamp))
      let address=row(action.id),hash=try bodyHash(a,address),physical=try a.blobSize(hash:hash)
      #expect(physical < 1024)
      #expect(throws:NotebookStorageError.limitExceeded("shared body budget")) {
        try a.boundedStoredFragments([(address,false)],maximumCount:1,maximumBytes:physical+128,budget:"shared body budget")
      }
      let read=try #require(a.boundedStoredFragments([(address,false)],maximumCount:1,maximumBytes:16_384,budget:"shared body budget").first)
      #expect(try read.value.decode([SpatialInkSpan].self) == action.spans)
      let data=try a.sqlRead { try $0.blob(hash) },expanded=try source.measurements.encodedRelations().base64EncodedString().utf8.count
      #expect(throws:NotebookStorageError.limitExceeded("shared command budget")) {
        try a.commandTransaction {
          let db=a.currentSQL!
          _=try db.decodedStoredFragment(from:data) // Warm the bounded body cache.
          try db.run("INSERT INTO metadata VALUES('ink_budget_partial','must roll back')")
          try db.limitReads(.init(rows:100,bytes:expanded+100,valueBytes:expanded+1024,reason:"shared command budget"))
          _=try db.decodedStoredFragment(from:data)
          _=try? db.decodedStoredFragment(from:data)
        }
      }
      #expect(try a.sqlRead { try $0.rows("SELECT 1 FROM metadata WHERE key='ink_budget_partial'").isEmpty })

    }
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

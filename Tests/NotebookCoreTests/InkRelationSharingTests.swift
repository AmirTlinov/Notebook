import Foundation
import Testing
@testable import NotebookCore

@Suite struct InkRelationSharingTests {
  private func samples(_ count: Int = 64) -> [SpatialInkSample] {
    (0..<count).map { i in
      .init(point:.init(x:Double(i)/8,y:Double(i%7)),timeOffset:Double(i)/128,
        width:4,opacity:0.5,force:0.75,azimuth:-0.0,altitude:1)
    }
  }

  @Test func reopenedIndependentBodiesShareStorageButNotIdentityOrRevision() throws {
    let values=samples(), a=InkMeasurements(values,revision:UUID()), b=InkMeasurements(values,revision:UUID())
    #expect(a.storage !== b.storage)
    let drawing=PageInkDrawing(actions:[.init(tool:.pen,measurements:a),.init(tool:.pen,measurements:b)])
    let data=try drawing.dataRepresentation(), reopened=try PageInkDrawing.decode(data)
    #expect(reopened.actions[0].samples.storage === reopened.actions[1].samples.storage)
    #expect(reopened.actions.map(\.id) == drawing.actions.map(\.id))
    #expect(reopened.actions.map(\.samples.revision) == [a.revision,b.revision])
    #expect(try reopened.dataRepresentation() == data)
    let typed=try JSONValue.encode(drawing).decode(PageInkDrawing.self)
    #expect(typed.actions[0].samples.storage === typed.actions[1].samples.storage)
    let next=try PageInkDrawing.decode(data)
    #expect(next.actions[0].samples.storage !== reopened.actions[0].samples.storage,
      "Sharing ends with one read; it is not a process-wide cache")
    let source=InkSampleRelations(sourceID:reopened.actions[0].id,measurements:reopened.actions[0].samples,
      header:.init(tool:.pen,color:.black))
    let edited=try source.editing(source.address(at:31),to:values[0],revision:UUID())
    #expect(InkSampleRelations.sameBits(edited.sample(at:31),values[0]))
    #expect(InkSampleRelations.sameBits(reopened.actions[1].samples[31],values[31]))
  }

  @Test func addressedSpatialReadSharesBodiesWithinItsSQLSnapshot() throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("shared-relations-\(UUID())")
    defer { try? FileManager.default.removeItem(at:root) }
    let store=NotebookStore(root:root),actor=UUID()
    _=try store.initializeWorkspace(actor:actor,pageSize:.init(width:834,height:1194))
    let cover=try store.loadIndex().selectedItemID, surface=SurfaceID.cover(cover)
    let values=samples()
    for i in 1...3 {
      let stamp=VersionStamp(counter:UInt64(i),actor:actor)
      let action=SpatialInkAction(tool:.pen,spans:[.init(surface:surface,
        measurements:InkMeasurements(values,revision:UUID()))],stamp:stamp)
      _=try store.commitSpatialInk(.append(action,journalStamp:stamp))
    }
    let reopened=try NotebookStore(root:root).readSpatialInk(surfaces:[surface])
    #expect(reopened.actions.count == 3)
    let bodies=reopened.actions.map { $0.spans[0].samples }
    #expect(Set(reopened.actions.map(\.id)).count == 3)
    #expect(Set(bodies.map(\.revision)).count == 3)
    #expect(bodies.allSatisfy { $0.storage === bodies[0].storage })
    let again=try store.readSpatialInk(surfaces:[surface])
    #expect(again.actions[0].spans[0].samples.storage !== bodies[0].storage)
  }

  @Test func exactKeysKeepSignedZeroAndRejectDamagedWarmInputs() throws {
    let context=InkRelationDecoding(),decoder=InkRelationDecoding.decoder(sharing:context)
    func decode(_ data: Data) throws -> InkMeasurements {
      try decoder.decode(InkMeasurements.self,from:JSONEncoder().encode(data))
    }
    let positive=SpatialInkSample(point:.zero,timeOffset:0,width:1,opacity:1,force:0,azimuth:0,altitude:1)
    let negative=SpatialInkSample(point:.init(x:-0.0,y:0),timeOffset:0,width:1,opacity:1,force:0,azimuth:0,altitude:1)
    let bytes=try InkMeasurements([positive]).encodedRelations(),a=try decode(bytes)
    let b=try decode(InkMeasurements([negative]).encodedRelations())
    #expect(a.storage !== b.storage)
    #expect(a[0].point.x.bitPattern != b[0].point.x.bitPattern)
    #expect(try decode(bytes).storage === a.storage)
    for end in [0,4,19,20,bytes.count-1] {
      #expect(throws:(any Error).self) { try decode(bytes.prefix(end)) }
    }
    var magic=bytes;magic[0]=0
    var invalidFlag=bytes;invalidFlag[54]=2
    for malformed in [magic,invalidFlag,bytes+Data([0])] {
      #expect(throws:(any Error).self) { try decode(malformed) }
    }
    #expect(context.entryCount == 2)
  }

  @Test func candidateLifetimeAndAdmissionAreBounded() throws {
    let context=InkRelationDecoding(entryLimit:2,byteLimit:4096)
    let decoder=InkRelationDecoding.decoder(sharing:context)
    func encoded(_ i: Int) throws -> Data { try JSONEncoder().encode(InkMeasurements([samples(8)[i]])) }
    let a=try decoder.decode(InkMeasurements.self,from:encoded(0))
    _=try decoder.decode(InkMeasurements.self,from:encoded(1))
    let c=try decoder.decode(InkMeasurements.self,from:encoded(2))
    #expect(context.entryCount == 2 && context.retainedBytes <= context.byteLimit)
    #expect(try decoder.decode(InkMeasurements.self,from:encoded(0)).storage === a.storage)
    #expect(try decoder.decode(InkMeasurements.self,from:encoded(2)).storage !== c.storage)
    let tiny=InkRelationDecoding(byteLimit:1)
    #expect(try InkRelationDecoding.decoder(sharing:tiny).decode(InkMeasurements.self,from:encoded(0)).count == 1)
    #expect(tiny.entryCount == 0 && tiny.retainedBytes == 0)
    weak var released: InkRelationDecoding?
    let retained: InkMeasurements = try {
      let scope=InkRelationDecoding();released=scope
      return try InkRelationDecoding.decoder(sharing:scope).decode(InkMeasurements.self,from:encoded(0))
    }()
    #expect(released == nil && retained.count == 1)
  }

  @Test func acceptedOutputReplacesRawPartsWithoutEnlargingTheScope() {
    let scope=InkRelationDecoding(entryLimit:2,byteLimit:1024)
    scope.retainStoredBody(Data([1]),hash:"first")
    scope.retainStoredBody(Data([2]),hash:"second")
    let body=Data(repeating:3,count:200)
    scope.retainStoredOutput(body,hash:"whole")
    #expect(scope.storedBody("first") == nil && scope.storedBody("second") == nil)
    #expect(scope.storedOutput(body) == "whole" && scope.storedOutputBody("whole") == body)
    #expect(scope.entryCount == 1 && scope.retainedBytes == body.count+320)
    scope.retainStoredOutput(Data(repeating:4,count:300),hash:"too-large")
    #expect(scope.storedOutputBody("too-large") == nil)
    #expect(scope.retainedBytes <= scope.byteLimit && scope.entryCount <= scope.entryLimit)
    let disabled=InkRelationDecoding(entryLimit:0)
    disabled.retainStoredOutput(body,hash:"none")
    #expect(disabled.retainedBytes == 0 && disabled.storedOutputBody("none") == nil)
  }

}

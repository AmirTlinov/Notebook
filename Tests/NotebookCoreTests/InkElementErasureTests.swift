import CryptoKit
import Foundation
import Testing
@testable import NotebookCore

@Suite("Element cutouts belong to the measured eraser action")
struct InkElementErasureTests {
  private func sample(_ x: Double, _ y: Double, world: WorldPoint? = nil) -> SpatialInkSample {
    .init(point: .init(x: x, y: y), worldPoint: world, timeOffset: 0, width: 12,
      opacity: 1, force: 1, azimuth: 0, altitude: 1)
  }
  private var target: InkElementTarget {
    .init(elementID: "circle", frame: .init(x: 100, y: 100, width: 200, height: 120))
  }

  @Test func wholeObjectEraseIsImmediateUndoableAndSurvivesEncoding() throws {
    let object = InkElementTarget(elementID: "program", frame: target.frame, wholeElement: true)
    let action = PageInkAction(tool: .eraser, samples: [sample(100, 160)]).erasingElements([object])
    let drawing = try PageInkDrawing().appending(action)
    let decoded = try PageInkDrawing.decode(drawing.dataRepresentation())
    let cuts = try #require(decoded.elementErasures[object.elementID])
    let appearance = NotebookElementAppearance(graphic: nil, layout: nil,
      size: .init(width: 200, height: 120), erasures: cuts)
    #expect(appearance.state == .erased)
    #expect(appearance.remaining.isEmpty)
    #expect(!appearance.contains(.init(x: 199, y: 119), tolerance: 20))
    #expect(try decoded.settingActive(false,for:[action.id],stamp:.init(counter:1,actor:UUID())).elementErasures.isEmpty)
    #expect(PageInkAction(tool: .eraser, samples: [sample(20, 20)]).erasingElements([object]).elementTargets?.isEmpty != false)
    let old = try JSONDecoder().decode(InkElementTarget.self, from: JSONEncoder().encode(target))
    #expect(!old.wholeElement, "Existing measured cutouts keep their authored meaning")
  }

  @Test func wholeObjectsRequireSweptContactNotDiagonalBoundingBoxes() {
    let object = InkElementTarget(elementID: "program", frame: target.frame, wholeElement: true)
    #expect(!object.intersects([sample(0, 180), sample(180, 0)]))
    #expect(object.intersects([sample(50, 160), sample(350, 160)]))
    #expect(!object.intersects([sample(95, 95)]), "Outside the rounded contact corner")
    #expect(object.intersects([sample(96, 96)]))
    #expect(object.intersects([sample(100, 94), sample(300, 94)]))
  }

  @Test(arguments:[false,true]) func transformedWholeObjectsUseTheirBodyAndPhysicalEraserRadius(reflected:Bool) throws {
    let basis=NotebookGraphicTransform(a:reflected ? -0.5 : 0.5,b:reflected ? -0.5 : 0.5,
      c:-0.5,d:0.5,tx:reflected ? 1 : 0.5,ty:reflected ? 0.5 : 0)
    let object=InkElementTarget(elementID:"program",frame:target.frame,wholeElement:true,elementTransform:basis)
    #expect(!object.intersects([sample(105,105),sample(145,105)]),"An empty corner of the outer frame is not the program")
    #expect(object.intersects([sample(50,160),sample(350,160)]))
    #expect(object.intersects([sample(200,160)]))
    // Middle of the slanted upper-right edge, offset along its physical normal.
    let length=hypot(0.6,1)
    #expect(object.intersects([sample(250+5*0.6/length,130-5/length)]))
    #expect(!object.intersects([sample(250+7*0.6/length,130-7/length)]))
    #expect(!object.intersects([sample(200,93)]))
    #expect(object.intersects([sample(200,95)]))
    let restored=try JSONDecoder().decode(InkElementTarget.self,from:JSONEncoder().encode(object))
    #expect(restored == object)
    #expect(!restored.intersects([sample(105,105)]))
  }

  @Test func sweptEraserRecordsOnlySeenTargetsAndUndoRestoresBothKindsOfPaint() throws {
    let eraser = PageInkAction(tool: .eraser, samples: [sample(50, 160), sample(350, 160)])
      .erasingElements([target, .init(elementID: "far", frame: .init(x: 900, y: 900, width: 20, height: 20))])
    #expect(eraser.elementTargets == [target], "Crossing endpoints outside the element still cut its contour")
    let drawing = try PageInkDrawing().appending(eraser)
    let decoded = try PageInkDrawing.decode(drawing.dataRepresentation())
    #expect(decoded == drawing)
    #expect(decoded.elementErasures.keys.sorted() == ["circle"])
    #expect(try decoded.appending(eraser) == decoded)
    let undone = try decoded.settingActive(false,for:[eraser.id],stamp:.init(counter:1,actor:UUID()))
    #expect(undone.elementErasures.isEmpty)
    #expect(try undone.merging(decoded) == undone, "An old peer cannot restore the erase after undo")
    #expect(decoded.elementErasures["created-later"] == nil)
    let altered = PageInkAction(id: eraser.id, tool: .eraser, measurements: eraser.samples)
    #expect(throws: PageInkDrawing.InkError.self) { try decoded.appending(altered) }
  }

  @Test func spatialCutoutsKeepFarWorldPrecisionAndStayWithTheElementBasis() throws {
    let surface = SurfaceID.board(UUID()), actor = UUID()
    let origin = WorldPoint(tileX: 8_000_000_000_000_000, tileY: -8_000_000_000_000_000, localX: 1, localY: 2)
    let target = InkElementTarget(elementID: "circle", frame: self.target.frame, worldOrigin: origin)
    let span = SpatialInkSpan(surface: surface, samples: [sample(0, 0, world: origin.offsetBy(x: 100, y: 160))])
      .erasingElements([target])
    #expect(target.localPoint(span.samples[0]) == .init(x: 0, y: 60))
    var journal = SpatialInkJournal(stamp: .init(counter: 0, actor: actor))
    let appended = journal.append(tool: .eraser, spans: [span], actor: actor)
    let action = try #require(appended)
    #expect(journal.elementErasures(on: surface)["circle"]?.first?.target == target)
    #expect(journal.elementErasures(on: .cover(UUID())).isEmpty)
    let decoded = try JSONDecoder().decode(SpatialInkJournal.self, from: JSONEncoder().encode(journal))
    #expect(decoded == journal)
    let deactivated = journal.deactivate(action.id, actor: actor)
    #expect(deactivated)
    #expect(journal.elementErasures(on: surface).isEmpty)
    _ = journal.merge(decoded)
    #expect(journal.elementErasures(on: surface).isEmpty)
  }

  @Test func independentErasuresUnionRatherThanOverwriteAnElementField() throws {
    let first = try PageInkDrawing().appending(PageInkAction(tool: .eraser, samples: [sample(100, 160)]).erasingElements([target]))
    let second = try PageInkDrawing().appending(PageInkAction(tool: .eraser, samples: [sample(300, 160)]).erasingElements([target]))
    let merged = try first.merging(second)
    #expect(merged.elementErasures["circle"]?.count == 2)
    #expect(try merged.merging(first) == merged)
    #expect(try merged.settingActive(false,for:[first.actions[0].id],stamp:.init(counter:1,actor:UUID())).elementErasures["circle"]?.count == 1)
  }

  @Test(arguments: [false, true]) func cutoutsSurviveAddressedStorageReplicationReplayAndUndo(whole: Bool) throws {
    let target = InkElementTarget(elementID:self.target.elementID,frame:self.target.frame,wholeElement:whole,
      elementTransform:.init(a:0,b:1,c:-1,d:0,tx:1,ty:0))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let a = NotebookStore(root: root.appendingPathComponent("a")), b = NotebookStore(root: root.appendingPathComponent("b"))
    let actor = UUID(), peer = UUID()
    let header = try a.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    try b.prepareEmptyWorkspace(workspaceID: header.workspaceID)
    let pageID = try #require(a.loadIndex().selectedPageID), surface = SurfaceID.board(header.rootBoardID)
    var page = try a.loadPage(pageID)
    let erase = PageInkAction(tool: .eraser, samples: [sample(100, 160)]).erasingElements([target])
    let change = try page.prepareInkChange(.append(erase), stamp: .init(counter: 20, actor: actor))
    let published = page.publishInkChange(change); #expect(published)
    try a.savePage(page)
    let origin = WorldPoint(x: 9000, y: -12000)
    let span = SpatialInkSpan(surface: surface, samples: [sample(0, 0, world: origin.offsetBy(x: 100, y: 160))])
      .erasingElements([.init(elementID: "circle", frame:target.frame,worldOrigin:origin,elementTransform:target.elementTransform)])
    let action = SpatialInkAction(tool: .eraser, spans: [span], stamp: .init(counter: 21, actor: actor))
    try a.commitSpatialInk(.append(action, journalStamp: action.stamp))
    for record in try a.changeJournal(after: 0) {
      try transfer(record, from: a, to: b, peer: peer)
      let cursor = try b.currentChangeCursor()
      try transfer(record, from: a, to: b, peer: peer)
      #expect(try b.currentChangeCursor() == cursor)
    }
    let reopened = NotebookStore(root: b.root)
    #expect(try PageInkDrawing.decode(reopened.loadPage(pageID).drawingData).elementErasures == change.drawing.elementErasures)
    #expect(try reopened.readSpatialInk(surfaces: [surface]).actions.first?.spans == action.spans)
    #expect(try reopened.readElementErasures(on:.page(pageID),elementID:"circle").count == 1)
    #expect(try reopened.readElementErasures(on:surface,elementID:"circle").count == 1)
    let before = try a.currentChangeCursor()
    let undo = try page.prepareInkChange(.setActive([erase.id],false), stamp: .init(counter: 22, actor: actor))
    let removed = page.publishInkChange(undo); #expect(removed)
    try a.savePage(page)
    let state = VersionStamp(counter: 23, actor: actor)
    try a.commitSpatialInk(.state(actionID: action.id, creationStamp: action.stamp,
      isActive: false, stateStamp: state, journalStamp: state))
    for record in try a.changeJournal(after: before) { try transfer(record, from: a, to: b, peer: peer) }
    #expect(try PageInkDrawing.decode(reopened.loadPage(pageID).drawingData).elementErasures.isEmpty)
    #expect(try reopened.readSpatialInk(surfaces: [surface]).elementErasures(on: surface).isEmpty)
    #expect(try reopened.readElementErasures(on:.page(pageID),elementID:"circle").isEmpty)
    #expect(try reopened.readElementErasures(on:surface,elementID:"circle").isEmpty)
  }

  @Test(arguments:[4,5,6,7,8,9,12,13,14,15,16,17,18,19,20,21,22,23]) func oldManifestsRequirePeerUpgradeWithoutChangingContentOrCursor(legacyFormat: Int) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let a = NotebookStore(root: root.appendingPathComponent("a")), b = NotebookStore(root: root.appendingPathComponent("b"))
    let actor = UUID(), header = try a.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    try b.prepareEmptyWorkspace(workspaceID: header.workspaceID)
    let initial = try #require(a.changeJournal(after: 0).first)
    let data = try a.readBlobChunk(hash: initial.manifestHash, offset: 0, maxBytes: 1_048_576)
    let value = try JSONDecoder().decode(JSONValue.self, from: data)
    #expect(value["format"] == .number(Double(NotebookChangeManifest.currentFormat)))
    let old = try JSONEncoder().encode(value.setting("format", .number(Double(legacyFormat))))
    let hash = SHA256.hash(data: old).map { String(format: "%02x", $0) }.joined()
    try a.stageBlob(data: old, expectedHash: hash)
    let queued = NotebookDurableChange(sequence: initial.sequence, transactionID: initial.transactionID,
      manifestHash: hash, byteCount: initial.byteCount + old.count - data.count)
    let cursor=try b.peerCursor(peerID:actor,direction:.incoming)
    let change=try b.currentChangeCursor()
    do { try transfer(queued,from:a,to:b,peer:actor);Issue.record("Retired manifest was admitted") }
    catch let error as CollaborationError { #expect(error.code == "placement_peer_upgrade_required") }
    #expect(try b.peerCursor(peerID:actor,direction:.incoming) == cursor)
    #expect(try b.currentChangeCursor() == change)
    try transfer(initial,from:a,to:b,peer:actor)
    #expect(try b.loadIndex() == a.loadIndex())
  }

  private func transfer(_ change: NotebookDurableChange, from source: NotebookStore,
    to destination: NotebookStore, peer: UUID) throws {
    while true {
      let missing = try destination.missingBlobHashes(for: change)
      if missing.isEmpty { break }
      for hash in missing {
        var data = Data()
        let size = try source.blobSize(hash: hash)
        while Int64(data.count) < size {
          data += try source.readBlobChunk(hash: hash, offset: Int64(data.count), maxBytes: 1_048_576)
        }
        try destination.stageBlob(data: data, expectedHash: hash)
      }
    }
    _ = try destination.applyRemoteChange(change, peerID: peer)
  }

  @Test func oldMeasuredActionsDecodeWithoutInventingTargets() throws {
    let action = PageInkAction(tool: .eraser, samples: [sample(100, 160)])
    let data = try JSONEncoder().encode(action)
    #expect(!String(decoding: data, as: UTF8.self).contains("elementTargets"))
    #expect(try JSONDecoder().decode(PageInkAction.self, from: data).elementTargets == nil)
    let invalid = try JSONValue.encode(action.erasingElements([target])).setting("tool", .string("pen"))
    #expect(throws: (any Error).self) { try invalid.decode(PageInkAction.self) }
  }
}

@testable import NotebookCore
import CryptoKit
import UIKit
import XCTest
@testable import Notebook

@MainActor final class NotebookLaserContextTests: XCTestCase {
  func testLatestFiveCropsStayWithTheirNextMessageUntilSavedOrExplicitlyCleared() async throws {
    let queue = NotebookLaserContext()
    let scope = NotebookLaserContext.Scope(computer:UUID(),thread:"current")
    var rendered: [Int] = []
    let image = try image()
    for index in 0..<7 { queue.append(scope:scope) { rendered.append(index); return [image] } }
    XCTAssertEqual(queue.count,5); XCTAssertTrue(rendered.isEmpty)
    let batch = queue.snapshot(scope:scope); queue.reserve(batch)
    XCTAssertEqual(batch.count,5)
    XCTAssertEqual(queue.count,5,"A submitted batch stays available while preparation is pending")
    _ = try await NotebookLaserContext.images(batch)
    XCTAssertEqual(rendered,[2,3,4,5,6])
    queue.finish(batch,consumed:false)
    XCTAssertEqual(queue.snapshot(scope:scope).count,5,"Failed Send leaves the exact pointing available")
    queue.finish(batch,consumed:true); XCTAssertEqual(queue.count,0)
    queue.append(scope:scope) { XCTFail("Cleared crop rendered"); return [image] }
    queue.clear(); XCTAssertTrue(queue.snapshot(scope:scope).isEmpty)
    queue.append(scope:scope) { return [image] }
    XCTAssertTrue(queue.snapshot(scope:.init(computer:scope.computer,thread:"another")).isEmpty)
    XCTAssertEqual(queue.count,1,"Sending elsewhere does not destroy this draft's pointing")
    let other = NotebookLaserContext.Scope(computer:UUID(),thread:"another")
    queue.append(scope:other) { [image] }
    XCTAssertEqual(queue.count(scope:scope),0,"New pointing cannot revive a previous context")
    XCTAssertEqual(queue.count(scope:other),1)
  }

  func testRedLaserContourUsesFrozenCropCoordinatesWithoutChangingItsSource() async throws {
    let region = PageRect(x:100,y:200,width:40,height:30)
    let reference = CollaborationReference(target:.init(kind:.page,id:UUID()),region:region,revision:"frozen-page")
    let format = UIGraphicsImageRendererFormat(); format.scale = 2; format.opaque = true
    let png = UIGraphicsImageRenderer(size:.init(width:40,height:30),format:format).pngData { context in
      UIColor.white.setFill(); context.fill(.init(x:0,y:0,width:40,height:30))
      UIColor.blue.setFill(); context.fill(.init(x:0,y:0,width:40,height:3))
    }
    let source = try AgentPinnedImage(referenceID:reference.id,sourceRevision:reference.revision,
      region:region,worldOrigin:nil,pageIndex:nil,pixelWidth:80,pixelHeight:60,pixelsPerPoint:2,
      png:png,sha256:SHA256.hash(data:png).map { String(format:"%02x",$0) }.joined(),
      presentation:.init(device:.iPad))
    // A nonzero screen origin and zoom place the open L at crop (5,5)→(25,5)→(25,20).
    let outline = NotebookLaserContext.Outline(points:[.init(x:25,y:15),.init(x:45,y:15),.init(x:45,y:30)],
      sourceOrigin:.init(x:-30,y:10),cropOrigin:.init(x:10,y:30),scale:2,width:2)
    let resources = SceneRenderResources(byteLimit:16*1024*1024)
    let marked = try await NotebookLaserContext.outlining(source,with:outline,resources:resources)
    try marked.validate(reference:reference)
    XCTAssertEqual(marked.region,source.region); XCTAssertEqual(marked.pixelWidth,80); XCTAssertEqual(marked.pixelHeight,60)
    XCTAssertNotEqual(marked.sha256,source.sha256)
    XCTAssertNil(marked.presentation,"Annotated context cannot certify an unmodified program export")
    XCTAssertEqual(try pixel(marked.png,x:30,y:10),[255,0,0,255],"The real horizontal contour is red")
    XCTAssertEqual(try pixel(marked.png,x:50,y:30),[255,0,0,255],"The second segment uses the same frozen crop basis")
    XCTAssertEqual(try pixel(marked.png,x:10,y:35),[255,255,255,255],"An open contour is not closed into an invented rectangle")
    XCTAssertEqual(try pixel(marked.png,x:30,y:30),[255,255,255,255],"The crop content remains visible")
    XCTAssertEqual(try pixel(marked.png,x:30,y:2),[0,0,255,255],"Source pixels are not flipped or replaced")
    XCTAssertEqual(try pixel(source.png,x:30,y:10),[255,255,255,255],"The frozen source itself is unchanged")
    XCTAssertEqual(resources.reservedBytes,0)
  }

  func testFailedCropIsNotSilentlyConsumedOrSentWithoutPixels() async throws {
    let queue = NotebookLaserContext(), scope = NotebookLaserContext.Scope(computer:nil,thread:"draft")
    queue.append(scope:scope) { throw Failure.injected }
    let batch = queue.snapshot(scope:scope); queue.reserve(batch)
    do { _ = try await NotebookLaserContext.images(batch); XCTFail("Missing pixels cannot silently become plain text") }
    catch { }
    queue.finish(batch,consumed:false); XCTAssertEqual(queue.count(scope:scope),1)
  }

  func testCompletedPointerWithUnavailableSceneCannotSendAnUnmarkedViewport() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("unavailable-pointer-"+UUID().uuidString)
    let model = NotebookAppModel(store:.init(root:root),startsNearbySync:false)
    retainNotebookUntilTeardown(model,removing:root)
    await model.start(pageSize:NotebookAppModel.defaultPageSize)
    let chat = try XCTUnwrap(model.chat), scope = chat.pointingScope
    // The address belonged to the contact, but its page is no longer the
    // mounted board when the completed pointer asks for visible pixels.
    let address = NotebookToolAddress(surface:.page(UUID()),boardID:nil,worldOrigin:nil,bounds:nil)
    let contact = NotebookDrawingToolController.LaserContact(id:UUID(),address:.material(address),
      scope:scope,screenScale:1,contour:NotebookToolContour([.init(x:20,y:20)],capacity:256))
    model.captureLaserContext(contact)
    XCTAssertEqual(model.laserContext.count(scope:scope),1)
    chat.draft = "Посмотри на указанный фрагмент"
    var saved = true
    await model.sendChatMessage { saved = $0 }?.value
    XCTAssertFalse(saved)
    XCTAssertTrue(chat.jobs.isEmpty)
    XCTAssertEqual(chat.draft,"Посмотри на указанный фрагмент")
    XCTAssertTrue(model.agentRequestError?.contains("Изображение указки ещё не готово") == true)
    XCTAssertEqual(model.laserContext.count,1,
      "A failed Send retains the exact pointer until the user corrects or clears it")
    let stopped = await model.shutdown(); XCTAssertTrue(stopped)
  }

  func testPreparedPointingSurvivesJournalFailureForExistingAndNewChat() async throws {
    for newChat in [false,true] {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent("pointing-retry-"+UUID().uuidString)
      let blocked = root.appendingPathComponent("fail-chat-write")
      let store = NotebookStore(root:root) { point in
        if case .beforeCommit = point, FileManager.default.fileExists(atPath:blocked.path) { throw Failure.injected }
      }
      let model = NotebookAppModel(store:store,startsNearbySync:false)
      retainNotebookUntilTeardown(model,removing:root)
      defer { try? FileManager.default.removeItem(at:blocked); model.retryPendingPersistence() }
      await model.start(pageSize:NotebookAppModel.defaultPageSize)
      await model.finishPendingPersistence()
      let chat = try XCTUnwrap(model.chat)
      if !newChat { chat.select(.init(id:UUID().uuidString,title:"Existing",cwd:"/tmp")) }
      let originalScope = chat.pointingScope
      let image = try image()
      var rendered = 0
      model.laserContext.append(scope:originalScope) { rendered += 1; return [image] }
      chat.draft = "Объясни показанное"
      let frozen = model.captureChatSubmissionContext(chat)
      var preparationCount = 0
      var preparedImages: [CodexInputAttachment] = []
      let captured = NotebookAppModel.ChatSubmissionContext(selectionID:frozen.selectionID,attachments:frozen.attachments,pointing:frozen.pointing) {
        preparationCount += 1
        let value = try await frozen.prepare(); preparedImages = value.images
        try Data().write(to:blocked)
        return value
      }
      var saved = true
      await model.sendChatMessage(context:captured) { saved = $0 }?.value
      XCTAssertFalse(saved); XCTAssertEqual(rendered,1); XCTAssertEqual(preparationCount,1)
      XCTAssertTrue(chat.jobs.isEmpty); XCTAssertEqual(preparedImages.count,1)
      XCTAssertEqual(chat.draft,"Объясни показанное", "Failed storage cannot report the message as saved or clear its draft")
      XCTAssertEqual(model.laserContext.count,1)
      try FileManager.default.removeItem(at:blocked)
      // This fault blocks every commit, including already accepted panel writes,
      // not only saveChatSubmission. Use the visible persistence Retry owner;
      // Send must not secretly resume or overtake the failed writer.
      model.retryPendingPersistence()
      let recovered = await model.finishPendingPersistence()
      XCTAssertTrue(recovered); XCTAssertNil(model.persistenceFailure)
      await model.sendChatMessage { saved = $0 }?.value
      XCTAssertTrue(saved); XCTAssertEqual(rendered,1); XCTAssertEqual(preparationCount,1)
      XCTAssertEqual(chat.jobs.count,1); XCTAssertEqual(model.laserContext.count,0)
      let job = try XCTUnwrap(chat.jobs.first)
      let attachments = newChat ? try store.chatFirstMessage(job.id)?.attachments : job.input.attachments
      XCTAssertEqual(attachments,preparedImages,"Retry keeps exactly the first saved immutable image addresses")
      XCTAssertEqual(try store.resolvedChatImageAttachments(try XCTUnwrap(attachments))?.first?.imagePNG,image.image.png)
    }
  }

  func testChangedPointingAttachmentOrSelectionIntentAfterRejectedWriteDoesNotResendOldImages() async throws {
    for (newChat, removed) in [(false,"pointing"),(true,"pointing"),(false,"attachment"),(true,"attachment"),(false,"selection"),(true,"selection")] {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent("changed-chat-intent-"+UUID().uuidString)
      let blocked = root.appendingPathComponent("fail-chat-write")
      let store = NotebookStore(root:root) { point in
        if case .beforeCommit = point, FileManager.default.fileExists(atPath:blocked.path) { throw Failure.injected }
      }
      let model = NotebookAppModel(store:store,startsNearbySync:false)
      retainNotebookUntilTeardown(model,removing:root)
      defer { try? FileManager.default.removeItem(at:blocked); model.retryPendingPersistence() }
      await model.start(pageSize:NotebookAppModel.defaultPageSize)
      await model.finishPendingPersistence()
      let chat = try XCTUnwrap(model.chat)
      if !newChat { chat.select(.init(id:UUID().uuidString,title:"Existing",cwd:"/tmp")) }
      let shown = try image()
      if removed == "pointing" { model.laserContext.append(scope:chat.pointingScope) { [shown] } }
      else if removed == "attachment" {
        let attachment = try XCTUnwrap(store.saveChatImageAttachments([shown],author:model.actorID).first)
        chat.attach(attachment)
      } else {
        let attachment = try XCTUnwrap(store.saveChatImageAttachments([shown],author:model.actorID).first)
        let contextID = try XCTUnwrap(attachment.imageReference?.contextID)
        model.selectSharedContext(contextID)
        _ = await model.finishPendingPersistence()
        let deadline = ContinuousClock.now + .seconds(5)
        while model.selectionSession.isResolvingContext, .now < deadline { await Task.yield() }
        XCTAssertEqual(model.agentQuestion?.contextID,contextID)
      }
      chat.draft = "Same text, changed image intent"
      let frozen = model.captureChatSubmissionContext(chat)
      let captured = NotebookAppModel.ChatSubmissionContext(selectionID:frozen.selectionID,attachments:frozen.attachments,pointing:frozen.pointing) {
        let prepared = try await frozen.prepare()
        try Data().write(to:blocked)
        return prepared
      }
      var saved = true
      await model.sendChatMessage(context:captured) { saved = $0 }?.value
      XCTAssertFalse(saved); XCTAssertTrue(chat.jobs.isEmpty)
      try FileManager.default.removeItem(at:blocked)
      model.retryPendingPersistence(); _ = await model.finishPendingPersistence()
      if removed == "pointing" { model.laserContext.clear() }
      else if removed == "attachment" { for attachment in chat.attachments { chat.removeAttachment(attachment.id) } }
      else { model.clearSelection(); XCTAssertNil(model.agentQuestion); XCTAssertNotEqual(model.selectionSession.id,frozen.selectionID) }
      await model.sendChatMessage { saved = $0 }?.value
      XCTAssertTrue(saved); XCTAssertEqual(chat.jobs.count,1)
      let job = try XCTUnwrap(chat.jobs.first)
      let attachments = newChat ? try store.chatFirstMessage(job.id)?.attachments : job.input.attachments
      XCTAssertTrue(attachments?.isEmpty != false,"The exact explicitly removed image cannot return through cached Retry")
      XCTAssertEqual(model.laserContext.count,0)
      if removed == "selection" {
        let contextID = newChat ? try store.chatFirstMessage(job.id)?.attentionContextID : job.input.attentionContextID
        XCTAssertNil(contextID,"Clearing attention cannot resend its old context under unchanged text")
      }
    }
  }

  func testPointingReservationDoesNotChangeExplicitIntentButClearDoes() throws {
    let context = NotebookLaserContext(), scope = NotebookLaserContext.Scope(computer:nil,thread:"draft")
    let shown = try image()
    context.append(scope:scope) { [shown] }
    let batch = context.snapshot(scope:scope), intent = context.intentGeneration
    context.reserve(batch); context.rebind(batch,to:scope)
    context.finish(batch,consumed:false)
    XCTAssertEqual(context.intentGeneration,intent)
    XCTAssertEqual(context.snapshot(scope:scope).count,1,"Failed preparation does not expire the pending crop")
    context.clear(); XCTAssertNotEqual(context.intentGeneration,intent,"Explicit removal revokes the cached batch")
  }

  func testChangedIntentRecoversExactDurableAttemptWithoutDispatchingNewInput() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("known-chat-attempt-"+UUID().uuidString)
    let blocked = root.appendingPathComponent("fail-chat-write"), capturedInput = root.appendingPathComponent("rejected-input.json")
    let author = UUID(), thread = UUID().uuidString, id = UUID()
    let store = NotebookStore(root:root) { point in
      if case .beforeCommit = point, FileManager.default.fileExists(atPath:blocked.path) {
        // The current same-root transaction exposes the exact uncommitted
        // input, including createdAt, before this injected rollback.
        if let input = try NotebookStore(root:root).chatJob(id)?.input {
          try JSONEncoder().encode(input).write(to:capturedInput)
        }
        throw Failure.injected
      }
    }
    let queue = NotebookPersistenceQueue(store:store)
    _ = try store.initializeWorkspace(actor:author,pageSize:.init(width:834,height:1194))
    let chat = NotebookChatController(persistence:queue,author:author) { _,_ in XCTFail("Recovery cannot dispatch native work") }
    await chat.start(); chat.select(.init(id:thread,title:"Existing",cwd:"/tmp")); chat.draft = "Changed draft"
    _ = await queue.flush()
    try Data().write(to:blocked)
    let saved = await chat.sendMessage(to:.thread(thread),text:"Old message",context:"Frozen old context",dictationID:id)
    XCTAssertFalse(saved)
    try FileManager.default.removeItem(at:blocked); queue.retry(); _ = await queue.flush()
    // The same exact durable input becomes observable after an uncertain local
    // receipt. This is real addressed storage, not a synthetic recovery result.
    let input = try JSONDecoder().decode(NotebookChatInput.self,from:Data(contentsOf:capturedInput))
    XCTAssertEqual(input.id,id)
    _ = try await queue.submit { try $0.saveChatSubmission(input,to:nil) }
    let readBlocked = root.appendingPathComponent("block-recovery")
    try Data().write(to:readBlocked)
    queue.enqueue { _ in
      if FileManager.default.fileExists(atPath:readBlocked.path) { throw Failure.injected }
      return false
    }
    let blockedRead = await queue.flush(); XCTAssertFalse(blockedRead)
    do { _ = try await chat.reconcileFailedMessageForChangedIntent(); XCTFail("Unknown receipt cannot authorize a replacement") }
    catch { }
    XCTAssertEqual(chat.draft,"Changed draft")
    try FileManager.default.removeItem(at:readBlocked); queue.retry(); _ = await queue.flush()
    let recovery = try await chat.reconcileFailedMessageForChangedIntent()
    XCTAssertEqual(recovery,.saved); XCTAssertEqual(chat.jobs.count,1)
    XCTAssertEqual(chat.jobs.first?.input.id,id); XCTAssertEqual(chat.draft,"Changed draft")
    XCTAssertTrue(chat.error?.contains("Изменённый черновик не отправлен") == true)
    await chat.stop(); _ = await queue.flush()
    try? FileManager.default.removeItem(at:root)
  }

  func testCombinedImageOverflowKeepsDraftAndCanBeCorrectedBeforeExistingOrNewChatSend() async throws {
    for (newChat,replacingError) in [(false,false),(false,true),(true,false),(true,true)] {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent("pointing-budget-"+UUID().uuidString)
      let store = NotebookStore(root:root), model = NotebookAppModel(store:store,startsNearbySync:false)
      retainNotebookUntilTeardown(model,removing:root)
      await model.start(pageSize:NotebookAppModel.defaultPageSize)
      await model.finishPendingPersistence()
      let chat = try XCTUnwrap(model.chat)
      if !newChat { chat.select(.init(id:UUID().uuidString,title:"Existing",cwd:"/tmp")) }
      let selectedImages = try [image(bytes:1_500_000),image(bytes:1_500_000)]
      let actor = model.actorID
      let selected = try store.saveChatImageAttachments(selectedImages,author:actor)
      let contextID = try XCTUnwrap(selected.first?.imageReference?.contextID)
      model.selectSharedContext(contextID)
      await model.finishPendingPersistence()
      let deadline = ContinuousClock.now + .seconds(5)
      while model.selectionSession.isResolvingContext, .now < deadline { await Task.yield() }
      XCTAssertEqual(model.agentQuestion?.contextID,contextID)
      let pointed = try image(bytes:1_500_000)
      model.laserContext.append(scope:chat.pointingScope) { [pointed] }
      chat.draft = "Keep this draft"
      var saved = true
      await model.sendChatMessage { saved = $0 }?.value
      XCTAssertFalse(saved); XCTAssertTrue(chat.jobs.isEmpty)
      XCTAssertEqual(chat.draft,"Keep this draft"); XCTAssertNotNil(model.agentRequestError)
      XCTAssertEqual(model.laserContext.count,1)
      var unrelatedError: String?
      if replacingError {
        let sendError = model.agentRequestError
        model.selectProgramForAttention(.init(target:.init(kind:.page,id:UUID()),elementID:"missing",point:.zero,label:"Missing program"))
        unrelatedError = try XCTUnwrap(model.agentRequestError)
        XCTAssertNotEqual(unrelatedError,sendError,"A separate attention command owns its own failure")
      }
      model.laserContext.clear()
      await model.sendChatMessage { saved = $0 }?.value
      XCTAssertTrue(saved,"Removing the extra pointer retries current preparation, not a cached rejected packet")
      XCTAssertEqual(model.agentRequestError,unrelatedError,
        "Correction clears only this send owner's error, not a later error from another action")
      let job = try XCTUnwrap(chat.jobs.first)
      let submitted = newChat ? try store.chatFirstMessage(job.id)?.attachments : job.input.attachments
      let expected = selected.map { CodexInputAttachment(kind:.image,name:"Выбранный фрагмент",path:$0.path) }
      XCTAssertEqual(submitted,expected, "Selecting existing evidence changes its label, never its frozen image address")
      XCTAssertEqual(try store.resolvedChatImageAttachments(try XCTUnwrap(submitted))?.compactMap(\.imagePNG),selectedImages.map { $0.image.png })
      XCTAssertEqual(chat.jobs.count,1)
    }
  }

  private enum Failure: Error { case injected }
  private func image(bytes: Int? = nil) throws -> NotebookChatImage {
    let region = PageRect(x:0,y:0,width:1,height:1)
    let reference = CollaborationReference(target:.init(kind:.page,id:UUID()),region:region,revision:"frozen")
    var png = try XCTUnwrap(Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="))
    if let bytes { png.append(Data(repeating:0,count:bytes-png.count)) }
    let value = try AgentPinnedImage(referenceID:reference.id,sourceRevision:reference.revision,region:region,
      worldOrigin:nil,pageIndex:nil,pixelWidth:1,pixelHeight:1,pixelsPerPoint:1,png:png,
      sha256:SHA256.hash(data:png).map { String(format:"%02x",$0) }.joined())
    return .init(reference:reference,image:value)
  }

  func testNativeTypingAndHeldObjectsExcludePageNavigationUntilTheirContactEnds() {
    let gate = NotebookInputGate(), contact = NSObject(), view = NSObject()
    let id = ObjectIdentifier(contact)
    XCTAssertTrue(gate.permitsPageNavigation)
    _ = gate.fingerContactOwner(for:id) { .nativeInput(ObjectIdentifier(view)) }
    XCTAssertFalse(gate.permitsPageNavigation)
    gate.endFingerContacts([id])
    _ = gate.fingerContactOwner(for:id) { .scene }
    gate.claimSceneObjectContact(id)
    XCTAssertFalse(gate.permitsPageNavigation)
    gate.endFingerContacts([id]); XCTAssertTrue(gate.permitsPageNavigation)
  }
  private func pixel(_ png: Data, x: Int, y: Int) throws -> [UInt8] {
    let image = try XCTUnwrap(UIImage(data:png)?.cgImage)
    let context = try XCTUnwrap(CGContext(data:nil,width:image.width,height:image.height,
      bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpaceCreateDeviceRGB(),
      bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image,in:.init(x:0,y:0,width:image.width,height:image.height))
    let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to:UInt8.self)
    return Array(UnsafeBufferPointer(start:bytes+(y*image.width+x)*4,count:4))
  }
}

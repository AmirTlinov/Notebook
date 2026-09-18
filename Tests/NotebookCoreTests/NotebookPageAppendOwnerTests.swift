import Foundation
import Testing
@testable import NotebookCore

@Suite("Native and agent append share one addressed content owner", .serialized)
struct NotebookPageAppendOwnerTests {
  private final class Fixture {
    let store: NotebookStore, actor = UUID()
    let size = PageSize(width: 834, height: 1194)
    let base: WorkspaceIndex

    init() throws {
      store = NotebookStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("page-append-owner-\(UUID())"))
      _ = try store.initializeWorkspace(actor: actor, pageSize: size)
      base = try store.loadIndex()
    }

    deinit { try? FileManager.default.removeItem(at: store.root) }

    func nativeIntent(actor: UUID) throws -> (WorkspaceIndex, PageDocument) {
      var index = base
      let selected = index.appendPage(in: base.selectedItemID, actor: actor, pageSize: size)
      return try (index, #require(selected?.createdPage))
    }

    func presence() throws -> SessionPresence {
      let value = SessionPresence(mode: .board, camera: .init(center: .init(x: 17, y: 29), scale: 0.7),
        viewport: .init(x: 834, y: 1194), selectedItemID: base.selectedItemID, notebookPageID: base.selectedPageID)
      try store.savePresence(value)
      return value
    }

    func field(_ name: String, pageID: UUID? = nil) throws -> ContentFieldVersion {
      let parts = ["items", base.selectedItemID.uuidString.lowercased(), name]
        + (pageID.map { [$0.uuidString.lowercased()] } ?? [])
      let address = "workspace.json#/collaboration/fields/@" + fieldKey([fieldKey(parts)])
      return try #require(try store.storedFragments(address: address, descendants: false).first?.value.decode(ContentFieldVersion.self))
    }
  }

  @Test func agentAppendNeedsNoPresenceAndAuthorsTheCurrentBoundedOwner() throws {
    let f = try Fixture(), actor = UUID(), page = PageDocument(size: f.size, actor: UUID())
    try f.store.publishRecords(writes: [:], removals: ["last-context.json"])
    let itemVersion = try f.field("exists"), orderVersion = try f.field("pageIDs")
    try f.store.commandTransaction {
      // Neither existing page bodies nor the scene belong to append's source.
      for address in ["board.json#/boards/@" + f.base.rootBoardID.uuidString.lowercased(), pageFile(f.base.selectedPageID!) + "#/drawingData"] {
        try f.store.currentSQL!.run("UPDATE blobs SET data=? WHERE hash=(SELECT hash FROM records WHERE address=?)",
          [.blob(Data("not an append source".utf8)), .text(address)])
      }
    }
    let admission = try f.store.commandTransaction {
      let admission = try f.store.makePageAppendAdmission(itemID: f.base.selectedItemID, pageID: page.id, actor: actor, human: false)
      #expect(admission.itemVersion.includes(itemVersion))
      #expect(admission.orderVersion.includes(orderVersion))
      try f.store.publishPageAppend(page: page, admission: admission, human: false)
      return admission
    }
    #expect(try f.store.pageCount(in: f.base.selectedItemID) == 2)
    #expect(try f.store.pageID(at: 1, in: f.base.selectedItemID) == page.id)
    #expect(try f.store.loadPage(page.id) == page)
    #expect(try !f.store.hasStoredValue("last-context.json"))
    #expect(try !f.field("exists").human)
    #expect(try !f.field("pageIDs").human)
    #expect(try f.field("pageIDs", pageID: page.id) == admission.birthVersion)
    let order = try f.store.readPageOrder(f.base.selectedItemID)
    #expect(order.heads.allSatisfy { !$0.version.human })
  }

  @Test func preparedAgentBirthSurvivesAnOvertakingNativeAppendAndFirstStrokeRetry() throws {
    let f = try Fixture(), actor = UUID(), page = PageDocument(size: f.size, actor: UUID())
    let presence = try f.presence()
    let admission = try f.store.commandTransaction {
      try f.store.makePageAppendAdmission(itemID: f.base.selectedItemID, pageID: page.id, actor: actor, human: false)
    }
    let (native, nativePage) = try f.nativeIntent(actor: f.actor)
    _ = try f.store.saveWorkspaceSelection(index: native, createdPage: nativePage)
    try f.store.commandTransaction { try f.store.publishPageAppend(page: page, admission: admission, human: false) }
    #expect(try f.store.pageCount(in: f.base.selectedItemID) == 3)
    #expect(try f.store.pageID(at: 1, in: f.base.selectedItemID) == nativePage.id)
    #expect(try f.store.pageID(at: 2, in: f.base.selectedItemID) == page.id)
    #expect(try f.field("pageIDs", pageID: page.id) == admission.birthVersion)
    #expect(try f.store.loadPresence() == presence.selecting(itemID: f.base.selectedItemID, pageID: nativePage.id))
    var drawn = page
    _ = drawn.replaceDrawing(pageDrawingFixture(Data("first human stroke".utf8)), actor: f.actor)
    _ = try f.store.savePage(drawn)
    let cursor = try f.store.currentChangeCursor(), order = try f.store.readPageOrder(f.base.selectedItemID)
    let stamp = try f.store.workspaceHeader().stamp
    try f.store.commandTransaction { try f.store.publishPageAppend(page: page, admission: admission, human: false) }
    #expect(try f.store.currentChangeCursor() == cursor)
    #expect(try f.store.readPageOrder(f.base.selectedItemID) == order)
    #expect(try f.store.workspaceHeader().stamp == stamp)
    #expect(try f.store.loadPage(page.id) == drawn)
    #expect(try f.field("pageIDs", pageID: page.id) == admission.birthVersion)
  }

  @Test func nativeAdapterKeepsPreparedBirthsCurrentTailAndHumanSelection() throws {
    let f = try Fixture(), presence = try f.presence()
    let (first, firstPage) = try f.nativeIntent(actor: f.actor)
    let (second, secondPage) = try f.nativeIntent(actor: UUID())
    let key = fieldKey(["items", f.base.selectedItemID.uuidString.lowercased(), "pageIDs", firstPage.id.uuidString.lowercased()])
    let birth = try #require(first.collaboration.fields[key])
    _ = try f.store.saveWorkspaceSelection(index: first, createdPage: firstPage)
    var drawn = firstPage
    _ = drawn.replaceDrawing(pageDrawingFixture(Data("native first stroke".utf8)), actor: f.actor)
    _ = try f.store.savePage(drawn)
    _ = try f.store.saveWorkspaceSelection(index: second, createdPage: secondPage)
    let cursor = try f.store.currentChangeCursor(), order = try f.store.readPageOrder(f.base.selectedItemID)
    _ = try f.store.saveWorkspaceSelection(index: first, createdPage: firstPage)
    #expect(try f.store.currentChangeCursor() == cursor)
    #expect(try f.store.pageCount(in: f.base.selectedItemID) == 3)
    #expect(try f.store.pageID(at: 1, in: f.base.selectedItemID) == firstPage.id)
    #expect(try f.store.pageID(at: 2, in: f.base.selectedItemID) == secondPage.id)
    #expect(try f.store.readPageOrder(f.base.selectedItemID) == order)
    #expect(try f.field("pageIDs", pageID: firstPage.id) == birth)
    #expect(try f.store.loadPage(firstPage.id) == drawn)
    #expect(try f.store.loadPresence() == presence.selecting(itemID: f.base.selectedItemID, pageID: firstPage.id))
  }

  @Test func admissionCannotMintAnExistingBirthOrPublishAnotherIdentityOrAuthor() throws {
    let f = try Fixture(), page = PageDocument(size: f.size, actor: UUID())
    let cursor = try f.store.currentChangeCursor()
    #expect(throws: (any Error).self) {
      try f.store.commandTransaction {
        try f.store.makePageAppendAdmission(itemID: f.base.selectedItemID, pageID: f.base.selectedPageID!, actor: UUID(), human: false)
      }
    }
    let admission = try f.store.commandTransaction {
      try f.store.makePageAppendAdmission(itemID: f.base.selectedItemID, pageID: page.id, actor: UUID(), human: false)
    }
    #expect(throws: (any Error).self) {
      try f.store.commandTransaction {
        try f.store.publishPageAppend(page: PageDocument(size: f.size, actor: UUID()), admission: admission, human: false)
      }
    }
    #expect(throws: (any Error).self) {
      try f.store.commandTransaction { try f.store.publishPageAppend(page: page, admission: admission, human: true) }
    }
    #expect(try f.store.currentChangeCursor() == cursor)
    #expect(try f.store.pageCount(in: f.base.selectedItemID) == 1)
  }
}

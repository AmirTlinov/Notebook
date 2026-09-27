import Foundation
import Testing
@testable import NotebookCore

private let legacyActor = UUID(
  uuidString: "00000000-0000-4000-8000-000000000001"
)!
private let legacyItemID = UUID(
  uuidString: "00000000-0000-4000-8000-000000000002"
)!
private let legacyPageID = UUID(
  uuidString: "00000000-0000-4000-8000-000000000003"
)!

@Test("Старый каталог требует внешнего преобразования")
func legacyWorkspaceDecodesWithRootBoard() throws {
  let data = try JSONSerialization.data(withJSONObject: [
    "format": 1,
    "notebooks": [[
      "id": legacyItemID.uuidString,
      "title": "Старая тетрадь",
      "pageIDs": [legacyPageID.uuidString]
    ]],
    "selectedNotebookID": legacyItemID.uuidString,
    "selectedPageID": legacyPageID.uuidString,
    "stamp": ["counter": 4, "actor": legacyActor.uuidString]
  ])

  #expect(throws: DecodingError.self) { try JSONDecoder().decode(WorkspaceIndex.self, from: data) }
}

@Test("Старая доска и присутствие требуют внешнего преобразования")
func legacySpatialOwnersRequireExternalConversion() throws {
  let stamp: [String: Any] = [
    "counter": 2,
    "actor": legacyActor.uuidString
  ]
  let world: [String: Any] = [
    "tileX": 0,
    "tileY": 0,
    "localX": 12.0,
    "localY": 34.0
  ]
  let boardData = try JSONSerialization.data(withJSONObject: [
    "format": 1,
    "freeNotebooks": [[
      "notebookID": legacyItemID.uuidString,
      "center": world,
      "zIndex": 1,
      "stamp": stamp
    ]],
    "stacks": [],
    "elements": [],
    "stamp": stamp
  ])
  let presenceData = try JSONSerialization.data(withJSONObject: [
    "format": 1,
    "mode": "page",
    "camera": ["center": world, "scale": 0.7],
    "viewport": ["x": 834.0, "y": 1_194.0],
    "focusedNotebookID": legacyItemID.uuidString,
    "openProgress": 1.0
  ])

  #expect(throws: DecodingError.self) { try JSONDecoder().decode(BoardDocument.self, from: boardData) }
  #expect(throws: DecodingError.self) { try JSONDecoder().decode(SessionPresence.self, from: presenceData) }
}

@Test("Присутствие до пагинации документа открывается на первом листе")
func versionTwoPresenceDefaultsToFirstDocumentPage() throws {
  let data = try JSONSerialization.data(withJSONObject: [
    "format": 2,
    "mode": "document",
    "camera": [
      "center": [
        "tileX": 0,
        "tileY": 0,
        "localX": 0.0,
        "localY": 0.0
      ],
      "scale": 1.0
    ],
    "viewport": ["x": 834.0, "y": 1_194.0],
    "focusedItemID": legacyItemID.uuidString,
    "openProgress": 1.0
  ])

  #expect(throws: DecodingError.self) { try JSONDecoder().decode(SessionPresence.self, from: data) }
}



@Test("Документ выбирается без тетрадного листа")
func documentSelectionHasNoNotebookPage() throws {
  let initial = WorkspaceIndex.initial(
    actor: legacyActor,
    pageSize: PageSize(width: 834, height: 1_194),
    itemID: legacyItemID,
    pageID: legacyPageID
  )
  var workspace = initial.index
  let creation = workspace.createDocument(
    title: "Доказательство",
    actor: legacyActor
  )
  let document = try #require(creation)

  #expect(document.kind == .document)
  #expect(workspace.selectedItemID == document.id)
  #expect(workspace.selectedPageID == nil)
  #expect(workspace.isValid)
  #expect(workspace.selectPage(
    at: 0,
    in: document.id,
    actor: legacyActor,
    pageSize: initial.page.size
  ) == nil)
}

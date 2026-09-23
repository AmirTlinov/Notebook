import Foundation
import Testing
@testable import NotebookCore

@Test("Камера возвращает мировую точку после проекции на экран")
func cameraRoundTrip() {
  let camera = SpatialCamera(
    center: WorldPoint(tileX: 91, tileY: -37, localX: 211, localY: 3_900),
    scale: 0.43
  )
  let viewport = SpatialPoint(x: 1_024, y: 1_366)
  let original = camera.center.offsetBy(x: 731.25, y: -412.75)
  let screen = camera.worldToScreen(original, viewport: viewport)
  let restored = camera.screenToWorld(screen, viewport: viewport)
  let error = restored.delta(to: original)
  #expect(abs(error.x) < 0.000_001)
  #expect(abs(error.y) < 0.000_001)
}

@Test("Мировая точка под щипком остаётся под пальцами при увеличении")
func pinchKeepsItsWorldAnchorUnderTheFingers() {
  let camera = SpatialCamera(
    center: WorldPoint(tileX: 91, tileY: -37, localX: 211, localY: 3_900),
    scale: 0.43
  )
  let viewport = SpatialPoint(x: 1_024, y: 1_366)
  let fingers = SpatialPoint(x: 781, y: 428)
  let worldAnchor = camera.screenToWorld(fingers, viewport: viewport)

  let pinched = camera.pinched(
    by: 2.1,
    from: fingers,
    to: fingers,
    viewport: viewport
  )

  let projected = pinched.worldToScreen(worldAnchor, viewport: viewport)
  #expect(abs(projected.x - fingers.x) < 0.000_001)
  #expect(abs(projected.y - fingers.y) < 0.000_001)
}

@Test("Мировая точка следует за движущимся центром щипка")
func pinchAnchorFollowsTheCurrentFingerCentroid() {
  let camera = SpatialCamera(
    center: WorldPoint(tileX: -48, tileY: 76, localX: 2_111, localY: 903),
    scale: 0.31
  )
  let viewport = SpatialPoint(x: 1_366, y: 1_024)
  let start = SpatialPoint(x: 982, y: 271)
  let current = SpatialPoint(x: 811, y: 496)
  let worldAnchor = camera.screenToWorld(start, viewport: viewport)

  let pinched = camera.pinched(
    by: 1.73,
    from: start,
    to: current,
    viewport: viewport
  )

  let projected = pinched.worldToScreen(worldAnchor, viewport: viewport)
  #expect(abs(projected.x - current.x) < 0.000_001)
  #expect(abs(projected.y - current.y) < 0.000_001)
}

@Test("Обратный щипок возвращает исходную камеру")
func pinchIsReversible() {
  let camera = SpatialCamera(
    center: WorldPoint(tileX: 15, tileY: -21, localX: 512, localY: 712),
    scale: 0.37
  )
  let viewport = SpatialPoint(x: 1_024, y: 1_366)
  let start = SpatialPoint(x: 792, y: 514)
  let current = SpatialPoint(x: 701, y: 623)
  let magnification = 2.25

  let expanded = camera.pinched(
    by: magnification,
    from: start,
    to: current,
    viewport: viewport
  )
  let restored = expanded.pinched(
    by: 1 / magnification,
    from: current,
    to: start,
    viewport: viewport
  )
  let centerError = camera.center.delta(to: restored.center)

  #expect(abs(restored.scale - camera.scale) < 0.000_001)
  #expect(abs(centerError.x) < 0.000_001)
  #expect(abs(centerError.y) < 0.000_001)
}

@Test("Смена пропорций экрана и возврат сохраняют масштаб доски")
func viewportProjectionIsReversible() {
  let portrait = SpatialPoint(x: 834, y: 1_194)
  let landscape = SpatialPoint(x: 1_194, y: 834)
  let original = SessionPresence(
    mode: .board,
    camera: SpatialCamera(center: WorldPoint(x: 180, y: -90), scale: 0.41),
    viewport: portrait
  )

  let restored = original
    .adapted(to: landscape, geometry: .notebook)
    .adapted(to: portrait, geometry: .notebook)

  #expect(restored.camera.center == original.camera.center)
  #expect(abs(restored.camera.scale - original.camera.scale) < 0.000_000_1)
}

@Test("Открытый лист сохраняет явно выбранный зум, а не повторяет переход открытия")
func stablePagePreservesExplicitViewportScale() {
  let viewport = SpatialPoint(x: 834, y: 1_194)
  let itemID = UUID()
  let original = SessionPresence(
    mode: .page,
    camera: SpatialCamera(scale: 0.487_891_719_906_063),
    viewport: viewport,
    focusedItemID: itemID,
    openProgress: 1
  )

  let projected = original.adapted(to: viewport, geometry: .notebook)

  #expect(projected == original)
  let landscape = SpatialPoint(x: 1194, y: 834)
  let returned = original.adapted(to: landscape, geometry: .notebook).adapted(to: viewport, geometry: .notebook)
  #expect(abs(returned.camera.scale - original.camera.scale) < 1e-12)
}

@Test("Смена окна сохраняет выбранный лист документа")
func documentPageSelectionSurvivesViewportProjection() {
  let documentID = UUID()
  let portrait = SpatialPoint(x: 834, y: 1_194)
  let landscape = SpatialPoint(x: 1_194, y: 834)
  let original = SessionPresence(
    mode: .document,
    camera: SpatialCamera(scale: 1),
    viewport: portrait,
    focusedItemID: documentID,
    openProgress: 1,
    documentPageIndex: 4
  )

  let projected = original.adapted(to: landscape, geometry: .notebook)

  #expect(projected.documentPageIndex == 4)
  #expect(projected.isValid)
}

@Test("Ограничение масштаба сохраняет точку под пальцами")
func clampedPinchStillKeepsItsAnchor() {
  let camera = SpatialCamera(center: WorldPoint(x: 2_400, y: -900), scale: 0.4)
  let viewport = SpatialPoint(x: 1_024, y: 1_366)
  let start = SpatialPoint(x: 210, y: 904)
  let current = SpatialPoint(x: 331, y: 812)
  let worldAnchor = camera.screenToWorld(start, viewport: viewport)

  let pinched = camera.pinched(
    by: 20,
    from: start,
    to: current,
    viewport: viewport,
    maximumScale: 0.9
  )
  let projected = pinched.worldToScreen(worldAnchor, viewport: viewport)

  #expect(pinched.scale == 0.9)
  #expect(abs(projected.x - current.x) < 0.000_001)
  #expect(abs(projected.y - current.y) < 0.000_001)
}

@Test("Уменьшение открытого листа останавливается на целом листе, доска остаётся свободной")
func paperZoomStopsAtWholeSheet() {
  for viewport in [SpatialPoint(x: 834, y: 1_194), SpatialPoint(x: 1_194, y: 834)] {
    for geometry in [WorkspaceItemGeometry.notebook, .document(.a4), .document(.letter)] {
      let center = WorldPoint(tileX: 91, tileY: -37, localX: 211, localY: 3_900)
      let raw = SpatialCamera(center: center.offsetBy(x: 12_000, y: -19_000), scale: 0.02)
      let paper = geometry.readingCamera(raw, centeredOn: center, viewport: viewport)
      #expect(paper.scale == geometry.fitScale(viewport: viewport))
      #expect(paper.center == center)
      #expect(raw.scale == 0.02)
      let enlarged = geometry.readingCamera(.init(center: center, scale: 3), centeredOn: center, viewport: viewport)
      #expect(enlarged.scale == 3)
      #expect(enlarged.center == center)
      let edge = geometry.readingCamera(.init(center: raw.center, scale: 3), centeredOn: center, viewport: viewport)
      let offset = center.delta(to: edge.center)
      #expect(abs(offset.x - max(0, geometry.width / 2 - viewport.x / 6)) < 0.000_001)
      #expect(abs(offset.y + max(0, geometry.height / 2 - viewport.y / 6)) < 0.000_001)
    }
  }
}

@Test("Тетрадь повторяет геометрию дисплея iPad; документ сохраняет свой формат")
func workspaceItemGeometryKeepsPaperIdentityAndPhysicalCorners() {
  #expect(WorkspaceItemGeometry.notebook.width == 834)
  #expect(WorkspaceItemGeometry.notebook.height == 1_194)
  #expect(WorkspaceItemGeometry.notebook.cornerRadius == 18)
  #expect(WorkspaceItemGeometry.notebook.paperSize == nil)
  for paper in DocumentPaperSize.allCases {
    #expect(WorkspaceItemGeometry.document(paper).paperSize == paper)
  }
}

@Test("Тетрадь принадлежит либо доске, либо одной стопке")
func boardHasOnePlacementOwner() {
  let actor = UUID()
  let first = UUID()
  let second = UUID()
  let third = UUID()
  var board = BoardDocument.initial(
    itemIDs: [first, second, third],
    actor: actor
  )
  let stackID = board.createStack(
    moving: second,
    onto: first,
    actor: actor
  )
  #expect(stackID != nil)
  #expect(board.placement(of: first) == nil)
  #expect(board.placement(of: second) == nil)
  #expect(board.stack(containing: first)?.id == stackID)
  #expect(board.stack(containing: second)?.id == stackID)
  #expect(board.isValid(itemIDs: [first, second, third]))

  let extracted = WorldPoint(x: 2_000, y: -900)
  let didUnstack = board.unstackItem(second, at: extracted, actor: actor)
  #expect(didUnstack)
  #expect(board.stack(containing: second) == nil)
  #expect(board.placement(of: second)?.center == extracted)
  #expect(board.isValid(itemIDs: [first, second, third]))
}

@Test("Камера и веер стопки получают один центр выбранной тетради")
func stackFocusUsesOneCameraIndependentRelationship() throws {
  let actor = UUID()
  let lower = UUID()
  let upper = UUID()
  var board = BoardDocument.initial(
    itemIDs: [lower, upper],
    actor: actor
  )
  let createdStackID = board.createStack(
    moving: upper,
    onto: lower,
    actor: actor
  )
  let stackID = try #require(createdStackID)
  let stack = try #require(board.stacks.first { $0.id == stackID })
  let lowerCenter = try #require(board.focusedCenter(of: lower))
  let upperCenter = try #require(board.focusedCenter(of: upper))
  #expect(lowerCenter == WorkspaceItemStackPresentation.focusedCenter(of:lower,in:stack))
  #expect(upperCenter == WorkspaceItemStackPresentation.focusedCenter(of:upper,in:stack))
  #expect(
    abs(lowerCenter.delta(to: upperCenter).x
      - WorkspaceItemGeometry.notebook.width * 0.62) < 0.000_001
  )
}

@Test("Стопка принимает пять тетрадей, а шестая остаётся на доске")
func stackCapacityPreservesAReadableLayout() throws {
  let actor = UUID()
  let itemIDs = (0..<6).map { _ in UUID() }
  var board = BoardDocument.initial(
    itemIDs: itemIDs,
    actor: actor
  )

  #expect(board.createStack(
    moving: itemIDs[1],
    onto: itemIDs[0],
    actor: actor
  ) != nil)
  for index in 2..<WorkspaceItemStack.maximumItemCount {
    #expect(board.createStack(
      moving: itemIDs[index],
      onto: itemIDs[0],
      actor: actor
    ) != nil)
  }

  #expect(board.stack(containing: itemIDs[0])?.itemIDs.count == 5)
  let stack = try #require(board.stack(containing: itemIDs[0]))
  let firstCenter=try #require(WorkspaceItemStackPresentation.focusedCenter(of:itemIDs[0],in:stack))
  let lastCenter=try #require(WorkspaceItemStackPresentation.focusedCenter(of:itemIDs[4],in:stack))
  #expect(
    abs(firstCenter.delta(to: lastCenter).x
      - WorkspaceItemGeometry.notebook.width * 0.62) < 0.000_001
  )
  #expect(board.createStack(
    moving: itemIDs[5],
    onto: itemIDs[0],
    actor: actor
  ) == nil)
  #expect(board.placement(of: itemIDs[5]) != nil)
  #expect(board.isValid(itemIDs: Set(itemIDs)))
}

@Test("Удаление из пары распускает стопку и уносит элементы обложки")
func deletingNotebookRepairsItsBoardOwner() throws {
  let actor = UUID()
  let first = UUID()
  let removed = UUID()
  let third = UUID()
  var board = BoardDocument.initial(
    itemIDs: [first, removed, third],
    actor: actor
  )
  let stackID = board.createStack(
    moving: removed,
    onto: first,
    actor: actor
  )
  _ = try #require(stackID)
  let coverElement = SpatialElement(
    id: "cover-label",
    surface: .cover(removed),
    kind: .markdown,
    frame: SpatialRect(x: 20, y: 20, width: 200, height: 100),
    source: "Удаляется вместе с обложкой",
    stamp: VersionStamp(counter: 0, actor: actor)
  )
  let inserted = board.upsertElement(coverElement, expected: nil, actor: actor)
  #expect(inserted)

  let deleted = board.deleteItem(removed, actor: actor)
  #expect(deleted)

  #expect(board.stack(containing: first) == nil)
  #expect(board.placement(of: first) != nil)
  #expect(board.placement(of: third) != nil)
  #expect(board.elements.allSatisfy { $0.surface != .cover(removed) })
  #expect(board.isValid(itemIDs: [first, third]))
}

@Test("Каталог публикует новую тетрадь после её страницы и размещения")
func boardAcceptsAStagedPlacementButNeverMissesAPublishedNotebook() {
  let actor = UUID()
  let published = UUID()
  let staged = UUID()
  let board = BoardDocument.initial(
    itemIDs: [published, staged],
    actor: actor
  )

  #expect(board.isValid(itemIDs: [published]))
  #expect(board.isValid(itemIDs: [published, staged]))
  #expect(!board.isValid(itemIDs: [published, staged, UUID()]))
}

@Test("Один штрих через доску и обложку отменяется одним действием")
func crossSurfaceInkIsOneUndoAction() {
  let actor = UUID()
  let itemID = UUID()
  let stamp = VersionStamp(counter: 0, actor: actor)
  let coverSample = SpatialInkSample(
    point: .zero,
    timeOffset: 0,
    width: 4,
    opacity: 0.7,
    force: 0.4,
    azimuth: 0,
    altitude: 1
  )
  let boardSample = SpatialInkSample(
    point: .zero,
    worldPoint: .zero,
    timeOffset: 0,
    width: 4,
    opacity: 0.7,
    force: 0.4,
    azimuth: 0,
    altitude: 1
  )
  let spans = [
    SpatialInkSpan(surface: .board, samples: [boardSample]),
    SpatialInkSpan(surface: .cover(itemID), samples: [coverSample]),
    SpatialInkSpan(surface: .board, samples: [boardSample]),
  ]
  var journal = SpatialInkJournal(stamp: stamp)
  let action = journal.append(
    tool: .pen,
    spans: spans,
    actor: actor
  )
  #expect(action?.spans.count == 3)
  #expect(journal.actions.count == 1)
  #expect(journal.undoLast(actor: actor)?.id == action?.id)
  #expect(journal.actions.count == 1)
  #expect(journal.actions[0].isActive == false)
}

@Test("Записанный ластик остаётся активным после старого сетевого снимка")
func staleSpatialSnapshotKeepsCommittedEraserActive() {
  let actor = UUID()
  let sample = SpatialInkSample(
    point: .zero,
    worldPoint: .zero,
    timeOffset: 0,
    width: 24,
    opacity: 1,
    force: 1,
    azimuth: 0,
    altitude: 1
  )
  var current = SpatialInkJournal(
    stamp: VersionStamp(counter: 0, actor: actor)
  )
  #expect(current.append(
    tool: .pen,
    spans: [SpatialInkSpan(surface: .board, samples: [sample])],
    actor: actor
  ) != nil)
  let stale = current
  let eraser = current.append(
    tool: .eraser,
    spans: [SpatialInkSpan(surface: .board, samples: [sample])],
    actor: actor
  )

  #expect(eraser != nil)
  #expect(current.merge(stale) == false)
  #expect(current.actions.last?.tool == .eraser)
  #expect(current.actions.last?.isActive == true)
}

@Test("Хранилище создаёт пространственный слой для существующих тетрадей")
func storeCreatesBoardBesideExistingWorkspace() throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let actor = UUID()
  let store = NotebookStore(root: root)
  let loaded = try store.loadOrCreate(
    actor: actor,
    pageSize: PageSize(width: 834, height: 1_194)
  )
  let board = try store.loadOrCreateBoard(workspace: loaded.0, actor: actor)
  let journal = try store.loadOrCreateSpatialInk(actor: actor)
  #expect(board.itemIDs == loaded.0.items.map(\.id))
  #expect(journal.actions.isEmpty)
  #expect(try store.hasStoredValue("board.json"))
  #expect(try store.hasStoredValue("spatial-ink.json"))
}

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
    .adapted(to: landscape)
    .adapted(to: portrait)

  #expect(restored.camera.center == original.camera.center)
  #expect(abs(restored.camera.scale - original.camera.scale) < 0.000_000_1)
}

@Test("Полностью открытый лист восстанавливает канонический масштаб")
func stablePageRepairsLossyViewportScale() {
  let viewport = SpatialPoint(x: 834, y: 1_194)
  let notebookID = UUID()
  let corrupted = SessionPresence(
    mode: .page,
    camera: SpatialCamera(scale: 0.487_891_719_906_063),
    viewport: viewport,
    focusedNotebookID: notebookID,
    openProgress: 1
  )

  let repaired = corrupted.adapted(to: viewport)

  #expect(repaired.camera.scale == 1)
  #expect(repaired.focusedNotebookID == notebookID)
  #expect(repaired.openProgress == 1)
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

@Test("Открытый лист одним щипком уменьшается до масштаба всей доски")
func pagePinchCanReachADeepBoardOverview() {
  let viewport = SpatialPoint(x: 834, y: 1_194)
  let fingers = SpatialPoint(x: 417, y: 597)
  let camera = SpatialCamera(scale: 1)

  let overview = camera.pinched(
    by: 0.02,
    from: fingers,
    to: fingers,
    viewport: viewport,
    maximumScale: 1
  )

  #expect(overview.scale == 0.02)
  #expect(overview.scale < NotebookPresentation.coverScale(viewport: viewport))
}

@Test("Половина открытия соответствует половине отношения масштабов")
func notebookOpeningProgressUsesThePinchRatio() {
  let coverScale = 0.72
  let pageScale = 1.25
  let halfwayScale = sqrt(coverScale * pageScale)

  #expect(NotebookOpeningTransition.progress(
    cameraScale: coverScale / 2,
    coverScale: coverScale,
    pageScale: pageScale
  ) == 0)
  #expect(abs(NotebookOpeningTransition.progress(
    cameraScale: halfwayScale,
    coverScale: coverScale,
    pageScale: pageScale
  ) - 0.5) < 0.000_001)
  #expect(NotebookOpeningTransition.progress(
    cameraScale: pageScale * 2,
    coverScale: coverScale,
    pageScale: pageScale
  ) == 1)
}

@Test("Небольшой щипок оставляет управление у камеры доски")
func smallBoardPinchDoesNotAcquireANotebook() {
  #expect(NotebookOpeningIntent.engagement(
    magnification: 1.24,
    velocity: 0.7,
    elapsed: 0.4,
    cameraScale: 0.3,
    coverScale: 0.72
  ) == nil)
  #expect(NotebookOpeningIntent.engagement(
    magnification: 3,
    velocity: 4,
    elapsed: 0.4,
    cameraScale: 0.6,
    coverScale: 0.72
  ) == nil)
}

@Test("Близкая тетрадь принимает спокойный или резкий щипок")
func nearbyNotebookAcceptsDeliberateAndSharpPinches() {
  #expect(NotebookOpeningIntent.engagement(
    magnification: 1.1,
    velocity: 0.4,
    elapsed: 0.4,
    cameraScale: 0.72,
    coverScale: 0.72
  ) == .deliberate)
  #expect(NotebookOpeningIntent.engagement(
    magnification: 1.05,
    velocity: 2.8,
    elapsed: 0.12,
    cameraScale: 0.73,
    coverScale: 0.72
  ) == .sharp)
  #expect(NotebookOpeningIntent.engagement(
    magnification: 1.04,
    velocity: 4,
    elapsed: 0.12,
    cameraScale: 0.73,
    coverScale: 0.72
  ) == nil)
  #expect(NotebookOpeningIntent.engagement(
    magnification: 1.8,
    velocity: 8,
    elapsed: 0.03,
    cameraScale: 0.9,
    coverScale: 0.72
  ) == nil)
}

@Test("Раскрытие начинается непрерывно с кадра подтверждения")
func engagedOpeningStartsWithoutAProgressJump() {
  let engagedAt = 0.72
  let pageScale = 1.0
  #expect(NotebookOpeningIntent.progress(
    cameraScale: engagedAt,
    engagedAtCameraScale: engagedAt,
    pageScale: pageScale
  ) == 0)
  #expect(abs(NotebookOpeningIntent.progress(
    cameraScale: sqrt(engagedAt * pageScale),
    engagedAtCameraScale: engagedAt,
    pageScale: pageScale
  ) - 0.5) < 0.000_001)
  #expect(NotebookOpeningIntent.progress(
    cameraScale: pageScale,
    engagedAtCameraScale: engagedAt,
    pageScale: pageScale
  ) == 1)
}

@Test("Резкий щипок открывает лист, а обратное движение возвращает доску")
func openingReleaseAlwaysChoosesAWholeState() {
  #expect(NotebookOpeningIntent.releaseMode(
    progress: 0,
    cameraScale: 0.72,
    engagedAtCameraScale: 0.72,
    engagement: .sharp,
    velocity: 0
  ) == .page)
  #expect(NotebookOpeningIntent.releaseMode(
    progress: 0,
    cameraScale: 0.64,
    engagedAtCameraScale: 0.72,
    engagement: .deliberate,
    velocity: -1
  ) == .board)
  #expect(NotebookOpeningIntent.releaseMode(
    progress: 0.2,
    cameraScale: 0.78,
    engagedAtCameraScale: 0.72,
    engagement: .deliberate,
    velocity: 0
  ) == .cover)
}

@Test("Продолжение закрывающего щипка свободно выпускает на доску")
func closingReleaseDoesNotPullBackToTheCover() {
  #expect(NotebookOpeningTransition.releaseMode(
    openProgress: 0,
    cameraScale: 0.72,
    coverScale: 0.72,
    velocity: 0
  ) == .cover)
  #expect(NotebookOpeningTransition.releaseMode(
    openProgress: 0,
    cameraScale: 0.67,
    coverScale: 0.72,
    velocity: 0
  ) == .board)
  #expect(NotebookOpeningTransition.releaseMode(
    openProgress: 0,
    cameraScale: 0.71,
    coverScale: 0.72,
    velocity: -0.8
  ) == .board)
  #expect(NotebookOpeningTransition.releaseMode(
    openProgress: 0.6,
    cameraScale: 0.86,
    coverScale: 0.72,
    velocity: 0
  ) == .page)
}

@Test("Угол листа равен одному физическому сантиметру")
func notebookCornerMatchesTheFullSizeIPadSilhouette() {
  #expect(NotebookGeometry.cornerRadius == PhysicalPaper.pointsPerCentimeter)
}

@Test("Сила выбора растёт по мере приближения щипка к центру обложки")
func selectionFieldGrowsTowardCenter() {
  let cover = SpatialRect(x: 100, y: 100, width: 300, height: 420)
  let outside = NotebookSelectionField.influence(
    centroid: SpatialPoint(x: 800, y: 800),
    cover: cover
  )
  let edge = NotebookSelectionField.influence(
    centroid: SpatialPoint(x: 110, y: 310),
    cover: cover
  )
  let center = NotebookSelectionField.influence(
    centroid: SpatialPoint(x: 250, y: 310),
    cover: cover
  )
  #expect(outside == 0)
  #expect(edge > outside)
  #expect(center > edge)
  #expect(center == 1)
}

@Test("Тетрадь принадлежит либо доске, либо одной стопке")
func boardHasOnePlacementOwner() {
  let actor = UUID()
  let first = UUID()
  let second = UUID()
  let third = UUID()
  var board = BoardDocument.initial(
    notebookIDs: [first, second, third],
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
  #expect(board.isValid(notebookIDs: [first, second, third]))

  let extracted = WorldPoint(x: 2_000, y: -900)
  let didUnstack = board.unstackNotebook(second, at: extracted, actor: actor)
  #expect(didUnstack)
  #expect(board.stack(containing: second) == nil)
  #expect(board.placement(of: second)?.center == extracted)
  #expect(board.isValid(notebookIDs: [first, second, third]))
}

@Test("Каталог публикует новую тетрадь после её страницы и размещения")
func boardAcceptsAStagedPlacementButNeverMissesAPublishedNotebook() {
  let actor = UUID()
  let published = UUID()
  let staged = UUID()
  let board = BoardDocument.initial(
    notebookIDs: [published, staged],
    actor: actor
  )

  #expect(board.isValid(notebookIDs: [published]))
  #expect(board.isValid(notebookIDs: [published, staged]))
  #expect(!board.isValid(notebookIDs: [published, staged, UUID()]))
}

@Test("Один штрих через доску и обложку отменяется одним действием")
func crossSurfaceInkIsOneUndoAction() {
  let actor = UUID()
  let notebookID = UUID()
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
    SpatialInkSpan(surface: .cover(notebookID), samples: [coverSample]),
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
  #expect(board.notebookIDs == loaded.0.notebooks.map(\.id))
  #expect(journal.actions.isEmpty)
  #expect(FileManager.default.fileExists(atPath: store.boardURL.path))
  #expect(FileManager.default.fileExists(atPath: store.spatialInkURL.path))
}

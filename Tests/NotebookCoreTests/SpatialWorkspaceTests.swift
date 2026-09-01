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
  let itemID = UUID()
  let corrupted = SessionPresence(
    mode: .page,
    camera: SpatialCamera(scale: 0.487_891_719_906_063),
    viewport: viewport,
    focusedItemID: itemID,
    openProgress: 1
  )

  let repaired = corrupted.adapted(to: viewport)

  #expect(repaired.camera.scale == 1)
  #expect(repaired.focusedItemID == itemID)
  #expect(repaired.openProgress == 1)
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

  let projected = original.adapted(to: landscape)

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
    openingScale: coverScale,
    pageScale: pageScale
  ) == 0)
  #expect(abs(NotebookOpeningTransition.progress(
    cameraScale: halfwayScale,
    openingScale: coverScale,
    pageScale: pageScale
  ) - 0.5) < 0.000_001)
  #expect(NotebookOpeningTransition.progress(
    cameraScale: pageScale * 2,
    openingScale: coverScale,
    pageScale: pageScale
  ) == 1)
}

@Test("Повторный щипок продолжает частичное открытие с той же кривой")
func partialOpeningRecoversItsOriginalScale() {
  let openingScale = 0.61
  let pageScale = 1.0
  let cameraScale = 0.78
  let progress = NotebookOpeningTransition.progress(
    cameraScale: cameraScale,
    openingScale: openingScale,
    pageScale: pageScale
  )
  let recovered = NotebookOpeningTransition.openingScale(
    cameraScale: cameraScale,
    pageScale: pageScale,
    progress: progress,
    fallback: 0.72
  )

  #expect(abs(recovered - openingScale) < 0.000_001)
}

@Test("Небольшой щипок оставляет управление у камеры доски")
func smallBoardPinchDoesNotAcquireANotebook() {
  #expect(!NotebookOpeningIntent.shouldEngage(
    isApproaching: true,
    cameraScale: 0.3,
    coverScale: 0.72
  ))
  #expect(!NotebookOpeningIntent.shouldEngage(
    isApproaching: true,
    cameraScale: 0.6,
    coverScale: 0.72
  ))
}

@Test("Близкая тетрадь принимает уже распознанный щипок без второго порога")
func nearbyNotebookAcceptsTheRecognizedPinch() {
  let coverScale = 0.72
  let entryScale = coverScale * NotebookOpeningIntent.entryScaleRatio
  #expect(!NotebookOpeningIntent.shouldEngage(
    isApproaching: true,
    cameraScale: entryScale - 0.001,
    coverScale: coverScale
  ))
  #expect(NotebookOpeningIntent.shouldEngage(
    isApproaching: true,
    cameraScale: entryScale,
    coverScale: coverScale
  ))
  #expect(NotebookOpeningIntent.shouldEngage(
    isApproaching: true,
    cameraScale: 0.73,
    coverScale: coverScale
  ))
  #expect(!NotebookOpeningIntent.shouldEngage(
    isApproaching: false,
    cameraScale: 0.8,
    coverScale: coverScale
  ))
  #expect(!NotebookOpeningIntent.shouldDisengage(
    cameraScale: entryScale,
    coverScale: coverScale
  ))
  #expect(NotebookOpeningIntent.shouldDisengage(
    cameraScale: coverScale * 0.75,
    coverScale: coverScale
  ))
}

@Test("Притяжение к тетради усиливается по мере приближения")
func pageDockingFieldGrowsThroughoutTheApproach() {
  let viewport = SpatialPoint(x: 834, y: 1_194)
  let center = WorldPoint(x: 300, y: -180)
  let farScale = SpatialCamera(center: center, scale: 0.5)
  let approaching = SpatialCamera(center: center, scale: 0.65)
  let focusedCover = SpatialCamera(center: center, scale: 0.72)
  let nearby = SpatialCamera(center: center, scale: 0.9)
  let offCenter = SpatialCamera(
    center: WorldPoint(x: 600, y: 400),
    scale: nearby.scale
  )

  #expect(NotebookDockingField.strength(
    camera: farScale,
    viewport: viewport
  ) == 0)
  let approachingStrength = NotebookDockingField.strength(
    camera: approaching,
    viewport: viewport
  )
  let coverStrength = NotebookDockingField.strength(
    camera: focusedCover,
    viewport: viewport
  )
  let nearbyStrength = NotebookDockingField.strength(
    camera: nearby,
    viewport: viewport
  )
  let offCenterStrength = NotebookDockingField.strength(
    camera: offCenter,
    viewport: viewport
  )
  #expect(approachingStrength > 0)
  #expect(approachingStrength < coverStrength)
  #expect(coverStrength < nearbyStrength)
  #expect(nearbyStrength > 0.8)
  #expect(offCenterStrength == nearbyStrength)

  let approachingCamera = NotebookDockingField.attractedCamera(
    approaching,
    toward: .zero,
    viewport: viewport,
    correction: NotebookDockingField.approachCorrection(
      currentStrength: approachingStrength,
      startingStrength: 0
    )
  )
  let coverCamera = NotebookDockingField.attractedCamera(
    focusedCover,
    toward: .zero,
    viewport: viewport,
    correction: NotebookDockingField.approachCorrection(
      currentStrength: coverStrength,
      startingStrength: 0
    )
  )
  let nearbyCamera = NotebookDockingField.attractedCamera(
    nearby,
    toward: .zero,
    viewport: viewport,
    correction: NotebookDockingField.approachCorrection(
      currentStrength: nearbyStrength,
      startingStrength: 0
    )
  )
  func distanceToTarget(_ point: WorldPoint) -> Double {
    let delta = point.delta(to: .zero)
    return hypot(delta.x, delta.y)
  }
  let originalDistance = distanceToTarget(center)
  let approachingRemainder = distanceToTarget(
    approachingCamera.center
  ) / originalDistance
  let coverRemainder = distanceToTarget(
    coverCamera.center
  ) / originalDistance
  let nearbyRemainder = distanceToTarget(
    nearbyCamera.center
  ) / originalDistance
  #expect(approachingRemainder < 1)
  #expect(approachingRemainder > coverRemainder)
  #expect(coverRemainder > nearbyRemainder)
}

@Test("Магнит приближает камеру, а разворот щипка освобождает её")
func pageDockingFollowsTheCurrentPinchDirection() {
  let viewport = SpatialPoint(x: 834, y: 1_194)
  let notebookCenter = WorldPoint.zero
  let camera = SpatialCamera(
    center: WorldPoint(x: 15, y: -10),
    scale: 0.95
  )
  let strength = NotebookDockingField.strength(
    camera: camera,
    viewport: viewport
  )
  let attracted = NotebookDockingField.attractedCamera(
    camera,
    toward: notebookCenter,
    viewport: viewport,
    correction: NotebookDockingField.approachCorrection(
      currentStrength: strength,
      startingStrength: 0
    )
  )

  #expect(attracted.scale > camera.scale)
  #expect(
    hypot(
      attracted.center.delta(to: notebookCenter).x,
      attracted.center.delta(to: notebookCenter).y
    )
      < hypot(
        camera.center.delta(to: notebookCenter).x,
        camera.center.delta(to: notebookCenter).y
      ) * 0.1
  )
  let correction = NotebookDockingField.approachCorrection(
    currentStrength: strength,
    startingStrength: 0
  )
  #expect(correction.scaleWeight > 0)
  #expect(NotebookDockingField.shouldDock(
    openProgress: 0.08,
    isApproaching: true,
    releaseVelocity: 0
  ))
  #expect(!NotebookDockingField.shouldDock(
    openProgress: 0.08,
    isApproaching: false,
    releaseVelocity: -0.2
  ))
}

@Test("Новый щипок не применяет уже видимое притяжение второй раз")
func dockingCorrectionStartsFromTheCurrentVisibleCamera() {
  #expect(NotebookDockingField.approachCorrection(
    currentStrength: 0.7,
    startingStrength: 0.7
  ) == .zero)
  let closer = NotebookDockingField.approachCorrection(
    currentStrength: 0.85,
    startingStrength: 0.7
  )
  #expect(closer.centerWeight > closer.scaleWeight)
  #expect(closer.scaleWeight > 0)
  #expect(closer.scaleWeight < 1)
  #expect(NotebookDockingField.approachCorrection(
    currentStrength: 0.7,
    startingStrength: 0.85
  ) == .zero)
  let complete = NotebookDockingField.approachCorrection(
    currentStrength: 1,
    startingStrength: 0.7
  )
  #expect(complete.centerWeight == 1)
  #expect(complete.scaleWeight == 1)
}

@Test("Продолженный магнит приходит в ту же камеру, что и один жест")
func resumedDockingComposesWithoutASecondAttraction() {
  let viewport = SpatialPoint(x: 834, y: 1_194)
  let target = WorldPoint.zero
  let raw = SpatialCamera(
    center: WorldPoint(x: 180, y: -95),
    scale: 0.7
  )
  let firstStrength = 0.56
  let finalStrength = 0.84
  let first = NotebookDockingField.attractedCamera(
    raw,
    toward: target,
    viewport: viewport,
    correction: NotebookDockingField.approachCorrection(
      currentStrength: firstStrength,
      startingStrength: 0
    )
  )
  let resumed = NotebookDockingField.attractedCamera(
    first,
    toward: target,
    viewport: viewport,
    correction: NotebookDockingField.approachCorrection(
      currentStrength: finalStrength,
      startingStrength: firstStrength
    )
  )
  let direct = NotebookDockingField.attractedCamera(
    raw,
    toward: target,
    viewport: viewport,
    correction: NotebookDockingField.approachCorrection(
      currentStrength: finalStrength,
      startingStrength: 0
    )
  )
  let centerDifference = resumed.center.delta(to: direct.center)

  #expect(abs(centerDifference.x) < 0.000_001)
  #expect(abs(centerDifference.y) < 0.000_001)
  #expect(abs(resumed.scale - direct.scale) < 0.000_001)
}

@Test("Обложка принимает уже видимый магнит без скачка")
func coverEngagementContinuesTheApproachCorrection() {
  let gestureStartStrength = 0.18
  let entryStrength = 0.46
  let visibleAtEntry = NotebookDockingField.approachCorrection(
    currentStrength: entryStrength,
    startingStrength: gestureStartStrength
  )
  let firstOpeningFrame = NotebookDockingField.openingCorrection(
    currentProgress: 0,
    startingProgress: 0,
    continuingFrom: visibleAtEntry
  )
  let nextOpeningFrame = NotebookDockingField.openingCorrection(
    currentProgress: 0.04,
    startingProgress: 0,
    continuingFrom: visibleAtEntry
  )
  let reversedApproach = NotebookDockingField.approachCorrection(
    currentStrength: entryStrength - 0.04,
    startingStrength: gestureStartStrength
  )

  #expect(firstOpeningFrame == visibleAtEntry)
  #expect(nextOpeningFrame.centerWeight > visibleAtEntry.centerWeight)
  #expect(nextOpeningFrame.scaleWeight > visibleAtEntry.scaleWeight)
  #expect(reversedApproach.centerWeight < visibleAtEntry.centerWeight)
  #expect(reversedApproach.scaleWeight < visibleAtEntry.scaleWeight)
}

@Test("После начала раскрытия магнит заметно притягивает камеру в глубину")
func openingCoverPullsTheCameraTowardThePaper() {
  let viewport = SpatialPoint(x: 834, y: 1_194)
  let target = WorldPoint.zero
  let coverScale = NotebookPresentation.coverScale(viewport: viewport)
  let startingCamera = SpatialCamera(
    center: WorldPoint(x: 100 / coverScale, y: -70 / coverScale),
    scale: coverScale
  )
  let rawCamera = SpatialCamera(
    center: startingCamera.center,
    scale: coverScale * 1.05
  )
  let rawOpeningProgress = NotebookOpeningTransition.progress(
    cameraScale: rawCamera.scale,
    openingScale: startingCamera.scale,
    pageScale: NotebookPresentation.fitScale(viewport: viewport)
  )
  let correction = NotebookDockingField.openingCorrection(
    currentProgress: rawOpeningProgress,
    startingProgress: 0,
    continuingFrom: .zero
  )
  let attracted = NotebookDockingField.attractedCamera(
    rawCamera,
    toward: target,
    viewport: viewport,
    correction: correction
  )
  let originalError = hypot(
    rawCamera.center.delta(to: target).x,
    rawCamera.center.delta(to: target).y
  )
  let remainingError = hypot(
    attracted.center.delta(to: target).x,
    attracted.center.delta(to: target).y
  )

  #expect(correction.centerWeight > 0.15)
  #expect(correction.scaleWeight == correction.centerWeight)
  #expect(remainingError < originalError * 0.85)
  #expect(attracted.scale > rawCamera.scale * 1.04)
}

@Test("Притяжение начинается вместе с раскрытием и растёт без второй ямки")
func openingPullFollowsTheCoverProgress() {
  let firstVisible = NotebookDockingField.openingCorrection(
    currentProgress: 0.01,
    startingProgress: 0,
    continuingFrom: .zero
  )
  let halfway = NotebookDockingField.openingCorrection(
    currentProgress: 0.5,
    startingProgress: 0,
    continuingFrom: .zero
  )
  let resumed = NotebookDockingField.openingCorrection(
    currentProgress: 0.5,
    startingProgress: 0.5,
    continuingFrom: .zero
  )

  #expect(firstVisible.scaleWeight > 0)
  #expect(firstVisible.scaleWeight < halfway.scaleWeight)
  #expect(halfway.centerWeight == halfway.scaleWeight)
  #expect(resumed == .zero)
}

@Test("Первое видимое раскрытие доезжает, а обратный щипок остаётся у руки")
func openingReleaseUsesTheCurrentDirection() {
  #expect(!NotebookDockingField.shouldDock(
    openProgress: 0,
    isApproaching: true,
    releaseVelocity: 0
  ))
  #expect(NotebookDockingField.shouldDock(
    openProgress: 0.01,
    isApproaching: true,
    releaseVelocity: 0
  ))
  #expect(!NotebookDockingField.shouldDock(
    openProgress: 0.2,
    isApproaching: false,
    releaseVelocity: 0
  ))
  #expect(!NotebookDockingField.shouldDock(
    openProgress: 0.2,
    isApproaching: true,
    releaseVelocity: -0.2
  ))
}

@Test("Чем ближе раскрытие, тем короче оставшийся путь")
func openingSettlementKeepsReleaseEnergy() {
  let edgeDuration = NotebookDockingField.settlementDuration(
    openProgress: 0.01,
    releaseVelocity: 0
  )
  let deepDuration = NotebookDockingField.settlementDuration(
    openProgress: 0.75,
    releaseVelocity: 0
  )
  let thrownDuration = NotebookDockingField.settlementDuration(
    openProgress: 0.75,
    releaseVelocity: 1
  )

  #expect(edgeDuration <= 0.42)
  #expect(deepDuration < edgeDuration)
  #expect(thrownDuration < deepDuration)
  #expect(thrownDuration >= 0.18)
}

@Test("Угол листа равен восьми физическим миллиметрам")
func notebookCornerMatchesTheFullSizeIPadSilhouette() {
  #expect(
    NotebookGeometry.cornerRadius
      == PhysicalPaper.pointsPerCentimeter * 0.8
  )
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
func stackFocusUsesTheSameCenterAsTheReadableBoardLayout() throws {
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
  let viewports = [
    SpatialPoint(x: 834, y: 1_194),
    SpatialPoint(x: 1_194, y: 834),
    SpatialPoint(x: 600, y: 800),
    SpatialPoint(x: 320, y: 320),
  ]

  for viewport in viewports {
    let coverScale = NotebookPresentation.coverScale(viewport: viewport)
    for itemID in [lower, upper] {
      let boardCenter = try #require(WorkspaceItemStackPresentation.boardCenter(
        of: itemID,
        in: stack,
        cameraScale: coverScale,
        viewport: viewport
      ))
      let focusedCenter = try #require(board.focusedCenter(of: itemID))
      let difference = boardCenter.delta(to: focusedCenter)
      #expect(abs(difference.x) < 0.000_001)
      #expect(abs(difference.y) < 0.000_001)
    }
  }

  let lowerCenter = try #require(board.focusedCenter(of: lower))
  let upperCenter = try #require(board.focusedCenter(of: upper))
  #expect(
    abs(lowerCenter.delta(to: upperCenter).x
      - NotebookGeometry.width * 0.62) < 0.000_001
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
  let viewport = SpatialPoint(x: 834, y: 1_194)
  let coverScale = NotebookPresentation.coverScale(viewport: viewport)
  let firstCenter = try #require(WorkspaceItemStackPresentation.boardCenter(
    of: itemIDs[0],
    in: stack,
    cameraScale: coverScale,
    viewport: viewport
  ))
  let lastCenter = try #require(WorkspaceItemStackPresentation.boardCenter(
    of: itemIDs[4],
    in: stack,
    cameraScale: coverScale,
    viewport: viewport
  ))
  #expect(
    abs(firstCenter.delta(to: lastCenter).x
      - NotebookGeometry.width * 0.62) < 0.000_001
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
  #expect(FileManager.default.fileExists(atPath: store.boardURL.path))
  #expect(FileManager.default.fileExists(atPath: store.spatialInkURL.path))
}

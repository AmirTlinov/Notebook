import Foundation
import Testing
@testable import NotebookCore

private func publicationStroke() -> PageInkAction {
  .init(tool: .pen, samples: [.init(point: .init(x: 10, y: 20), timeOffset: 0,
    width: 2, opacity: 1, force: 1, azimuth: 0, altitude: 1)])
}

@Test("Готовый штрих публикует только чернила и сохраняет новые элементы")
func preparedInkKeepsUnrelatedFields() throws {
  let actor = UUID(), stroke = publicationStroke()
  var page = PageDocument(size: .init(width: 834, height: 1194), actor: actor)
  let prepared = try page.prepareInkChange(.append(stroke), stamp: .init(counter: 1, actor: actor))
  let element = AgentElement(id: "note", kind: .markdown, frame: .init(x: 10, y: 10, width: 100, height: 50), source: "note", html: "note")
  let published1 = page.replaceElements([element], actor: UUID())
  #expect(published1)
  let published2 = page.publishInkChange(prepared)
  #expect(published2)
  #expect(page.elements == [element])
  #expect(page.drawingData == prepared.data)
  #expect(try PageInkDrawing.decode(page.drawingData) == prepared.drawing)
}

@Test("Входящий штрих инвалидирует подготовку, повтор включает обе стороны")
func preparedInkRetriesCurrentDrawing() throws {
  let actor = UUID(), local = publicationStroke(), remote = publicationStroke()
  var page = PageDocument(size: .init(width: 834, height: 1194), actor: actor)
  let requested = VersionStamp(counter: 1, actor: actor)
  let stale = try page.prepareInkChange(.append(local), stamp: requested)
  let incoming = try page.prepareInkChange(.append(remote), stamp: .init(counter: 5, actor: UUID()))
  let published3 = page.publishInkChange(incoming)
  #expect(published3)
  let published4 = !page.publishInkChange(stale)
  #expect(published4)
  let retry = try page.prepareInkChange(.append(local), stamp: requested)
  let published5 = page.publishInkChange(retry)
  #expect(published5)
  #expect(retry.stamp.counter == 6)
  #expect(Set(retry.drawing.activeActions.map(\.id)) == [local.id, remote.id])
  let undo = try page.prepareInkChange(.remove([local.id]), stamp: .init(counter: 7, actor: actor))
  let published6 = page.publishInkChange(undo)
  #expect(published6)
  #expect(undo.drawing.activeActions.map(\.id) == [remote.id])
  #expect(undo.drawing.actions.first { $0.id == local.id }?.isActive == false)
}

@Test("Подготовка другого листа не пересекает физического владельца")
func preparedInkCannotCrossPageOwner() throws {
  let actor = UUID()
  let first = PageDocument(size: .init(width: 834, height: 1194), actor: actor)
  var second = PageDocument(size: first.size, actor: actor)
  let prepared = try first.prepareInkChange(.append(publicationStroke()), stamp: .init(counter: 1, actor: actor))
  let published7 = !second.publishInkChange(prepared)
  #expect(published7)
  #expect(second.drawingData.isEmpty)
}

@Test("Завершение отмены сохраняет историю штриха, добавленного во время подготовки")
func undoCompletionKeepsNewerContact() throws {
  let pageID = UUID(), first = UUID(), next = UUID()
  var history = PencilUndoHistory()
  history.recordAction(ownerID: pageID, actionID: first)
  history.recordAction(ownerID: pageID, actionID: next)
  history.didRemoveContribution([first], for: pageID)
  #expect(history.lastContribution(for: pageID) == [next])
  history.didRemoveContribution([next], for: pageID)
  #expect(history.lastContribution(for: pageID) == nil)
}

@Test("Уже удалённый вклад завершает отмену без лишней ревизии чернил")
func preparedNoOpDoesNotAdvanceDrawing() throws {
  let page = PageDocument(size: .init(width: 834, height: 1194), actor: UUID())
  let prepared = try page.prepareInkChange(.remove([UUID()]), stamp: .init(counter: 1, actor: UUID()))
  #expect(prepared.stamp == page.drawingStamp)
  #expect(prepared.data == page.drawingData)
}

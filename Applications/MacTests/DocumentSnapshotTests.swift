import AppKit
@testable import Notebook
import NotebookCore
import XCTest

final class DocumentSnapshotTests: XCTestCase {
  @MainActor
  func testSnapshotBelongsToExactContentAndStateRevisions() throws {
    let actor = UUID()
    var document = DocumentDocument(
      id: UUID(),
      actor: actor,
      blocks: [.markdown(id: "body", source: "# Первый кадр")]
    )
    var state = DocumentStateJournal(id: document.id, actor: actor)
    let image = NSImage(size: NSSize(width: 834, height: 1_194))
    let firstToken = DocumentSnapshotCache.token(
      document: document,
      state: state,
      pageIndex: 0
    )

    DocumentSnapshotCache.shared.store(
      image: image,
      documentID: document.id,
      token: firstToken
    )
    XCTAssertNotNil(
      DocumentSnapshotCache.shared.image(
        for: document,
        state: state,
        pageIndex: 0
      )
    )

    XCTAssertTrue(document.replaceBlockSource(
      id: "body",
      source: "# Второй кадр",
      actor: actor
    ))
    XCTAssertNil(
      DocumentSnapshotCache.shared.image(
        for: document,
        state: state,
        pageIndex: 0
      ),
      "Снимок старого исходника не должен подписывать новую квитанцию"
    )

    let secondToken = DocumentSnapshotCache.token(
      document: document,
      state: state,
      pageIndex: 0
    )
    DocumentSnapshotCache.shared.store(
      image: image,
      documentID: document.id,
      token: secondToken
    )
    XCTAssertTrue(state.commit(
      blockID: "counter",
      value: .number(1),
      actor: actor
    ))
    XCTAssertNil(
      DocumentSnapshotCache.shared.image(
        for: document,
        state: state,
        pageIndex: 0
      ),
      "Снимок старого интерактивного состояния не должен подписывать новую квитанцию"
    )
  }

  @MainActor
  func testSnapshotBelongsToTheSelectedPhysicalPage() {
    let actor = UUID()
    let document = DocumentDocument(id: UUID(), actor: actor)
    let state = DocumentStateJournal(id: document.id, actor: actor)
    let image = NSImage(size: NSSize(width: 834, height: 1_194))
    let token = DocumentSnapshotCache.token(
      document: document,
      state: state,
      pageIndex: 2
    )

    DocumentSnapshotCache.shared.store(
      image: image,
      documentID: document.id,
      token: token
    )

    XCTAssertNotNil(
      DocumentSnapshotCache.shared.image(
        for: document,
        state: state,
        pageIndex: 2
      )
    )
    XCTAssertNil(
      DocumentSnapshotCache.shared.image(
        for: document,
        state: state,
        pageIndex: 1
      )
    )
  }
}

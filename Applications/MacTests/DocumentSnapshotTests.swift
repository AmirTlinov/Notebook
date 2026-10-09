import AppKit
@testable import Notebook
import NotebookCore
import XCTest

final class DocumentSnapshotTests: XCTestCase {
  @MainActor
  private func measuredLayout(_ document: DocumentDocument) throws -> DocumentLayoutRecord {
    try DocumentLayoutFixture.make(pages: Array(repeating: .uncompiled, count: 3))
  }

  private func bitmap(width: Int, height: Int) -> NSImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return NSImage(cgImage: context.makeImage()!, size: NSSize(width: width, height: height))
  }

  @MainActor
  func testAgentSnapshotBelongsToExactElementSourceAndState() {
    let image = bitmap(width: 240, height: 120)
    let element = AgentElement(
      id: "counter",
      kind: .web,
      frame: PageRect(x: 20, y: 30, width: 240, height: 120),
      source: "<button>0</button>",
      html: "<button>0</button>",
      javaScript: "",
      state: .object(["count": .number(0)])
    )

    SceneRenderResources.shared.store(image, for: element)
    XCTAssertNotNil(SceneRenderResources.shared.image(for: element))
    XCTAssertNil(
      SceneRenderResources.shared.image(
        for: element.updating(state: .object(["count": .number(1)]))
      ),
      "Снимок прежнего состояния не должен подписывать новый составной лист"
    )
  }

  @MainActor
  func testSnapshotBelongsToExactContentAndStateRevisions() throws {
    let actor = UUID()
    var document = DocumentTestFiles.document(
      id: UUID(),
      actor: actor,
      contents: [.tex(id: "body", source: "\\section{Первый кадр}"),
        .program(id: "counter", html: "<button>Counter</button>", height: 100)]
    )
    var state = DocumentStateJournal(id: document.id, actor: actor)
    let image = bitmap(width: 834, height: 1_194)
    let firstToken = DocumentSnapshotCache.token(
      document: document,
      state: state,
      pageIndex: 0
    )

    DocumentSnapshotCache.shared.store(
      image: image,
      documentID: document.id,
      token: firstToken, layout: try measuredLayout(document)
    )
    XCTAssertNotNil(
      DocumentSnapshotCache.shared.image(
        for: document,
        state: state,
        pageIndex: 0
      )
    )

    XCTAssertTrue(document.replaceFileSource(
      id: "body",
      source: "\\section{Второй кадр}",
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
      token: secondToken, layout: try measuredLayout(document)
    )
    XCTAssertTrue(state.commit(instanceID: "unrelated", value: .number(1), actor: actor))
    XCTAssertNil(DocumentSnapshotCache.shared.image(for: document, state: state, pageIndex: 0),
      "Until a compiler map identifies live instances, a new journal record conservatively invalidates the old image")
    DocumentSnapshotCache.shared.store(image: image, documentID: document.id,
      token: DocumentSnapshotCache.token(document: document, state: state, pageIndex: 0), layout: try measuredLayout(document))
    XCTAssertTrue(state.commit(
      instanceID: "counter",
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
  func testSnapshotBelongsToTheSelectedPhysicalPage() throws {
    let actor = UUID()
    let document = DocumentDocument(id: UUID(), actor: actor)
    let state = DocumentStateJournal(id: document.id, actor: actor)
    let image = bitmap(width: 834, height: 1_194)
    let token = DocumentSnapshotCache.token(
      document: document,
      state: state,
      pageIndex: 2
    )

    DocumentSnapshotCache.shared.store(
      image: image,
      documentID: document.id,
      token: token, layout: try measuredLayout(document)
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

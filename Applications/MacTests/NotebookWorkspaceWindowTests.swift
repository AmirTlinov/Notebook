import AppKit
import XCTest
@testable import Notebook

@MainActor final class NotebookWorkspaceWindowTests: XCTestCase {
  func testVaultWindowOwnsUsableGeometryInsteadOfTheListsEmptyIntrinsicSize() async throws {
    let lifecycle = NotebookMacLifecycle()
    lifecycle.showWorkspaces()
    let window = try XCTUnwrap(NSApplication.shared.windows.first { $0.identifier?.rawValue == "notebook.workspaces.window" })
    defer { window.close() }
    await Task.yield()
    window.contentView?.layoutSubtreeIfNeeded()
    let content = try XCTUnwrap(window.contentView)
    XCTAssertGreaterThanOrEqual(content.bounds.width, 460)
    XCTAssertGreaterThanOrEqual(content.bounds.height, 360)
    XCTAssertEqual(window.contentMinSize, .init(width: 460, height: 360))
    XCTAssertTrue(window.isVisible)
  }
}

import Foundation
import XCTest
@testable import Notebook

extension XCTestCase {
  /// The lifetime of the real writer extends through its background readers.
  /// On a failed shutdown leave the database intact as failure evidence.
  @MainActor
  func retainNotebookUntilTeardown(_ model: NotebookAppModel, removing root: URL) {
    addTeardownBlock {
      let stopped = await model.shutdown()
      let failure = await model.persistenceFailure
      XCTAssertTrue(stopped, "The store cannot be removed before its writer and background work acknowledge shutdown: \(failure ?? "no persistence diagnostic")")
      guard stopped else { return }
      if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }
  }
}

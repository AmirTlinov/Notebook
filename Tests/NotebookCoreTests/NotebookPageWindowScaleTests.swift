import Foundation
import Testing

extension NotebookSQLScaleTests {
  @Test func oneNotebookReadWindowDoesNotMaterializeOneHundredThousandPageIDs() throws {
    let started = ContinuousClock.now
    let fixture = try PageWindowFixture(count: 100_000); defer { fixture.clean() }
    print("PAGE_WINDOW_SEED pages=100000 elapsed=\(started.duration(to: .now))")
    try assertBoundedPageReads(fixture)
  }
}

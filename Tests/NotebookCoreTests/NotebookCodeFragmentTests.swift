import Foundation
import Testing
@testable import NotebookCore

@Suite("Handwriting keeps the exact code it explained")
struct NotebookCodeFragmentTests {
  private func fragment(_ source: String, offset: Int, text: String) -> NotebookCodeFragment {
    .init(file: .init(computer: UUID(), project: "code", root: "/project", path: "main.py"),
      sourceHash: NotebookFileVersion.hash(Data(source.utf8)), utf16Offset: offset, text: text,
      width: 600, height: 120, fontSize: 15, stamp: .init(counter: 1, actor: UUID()))
  }
  @Test func repeatedTextKeepsItsExactVersionButDoesNotGuessAfterAnEdit() {
    let source = "x = 1\nx = 1\n", note = fragment(source, offset: 6, text: "x = 1")
    #expect(note.isValid); #expect(note.range(in: source) == NSRange(location: 6, length: 5))
    #expect(note.range(in: "# new\n" + source) == nil)
    #expect(note.text == "x = 1")
  }
  @Test func uniqueUnchangedCodeFollowsAnInsertionButChangedOrDeletedCodeRetainsItsSource() {
    let source = "let 😀 = 4\nreturn value\n", note = fragment(source, offset: 11, text: "return value")
    #expect(note.range(in: "# note\n" + source) == NSRange(location: 18, length: 12))
    #expect(note.range(in: "let 😀 = 4\nreturn other\n") == nil)
    #expect(note.range(in: "let 😀 = 4\n") == nil)
    #expect(note.text == "return value" && note.width == 600)
  }
  @Test func overlappingMatchesAreAmbiguousAndAnIncorrectExactOffsetNeverRedirects() {
    let note = fragment("aaaa", offset: 0, text: "aaa")
    #expect(note.range(in: "baaaa") == nil)
    let malformed = fragment("abc", offset: 1, text: "abc")
    #expect(malformed.range(in: "abc") == nil)
  }
}

import Foundation
import Testing
@testable import NotebookCore

@Suite("Structured clipboard representation identity")
struct NotebookTldrawRecognitionTests {
  @Test func explicitIdentitySurvivesMalformedAndTruncatedBodies() {
    for source in [
      #"{"type":"application/tldraw","data":"#,
      #"{"type":"application/tldraw"broken"#,
      #"{"tldrawFileFormatVersion":"#,
      #"{"schema":{},"shapes":["#,
      #"{"shapes":[],"schema":"#,
      #"<meta charset='utf-8'><div data-tldraw>broken"#,
      #"<DIV class='content' DATA-TLDRAW="#,
    ] { #expect(NotebookTldrawImport.recognizes(source), "\(source)") }
  }

  @Test func onlyRootFieldsAndActualHtmlAttributesIdentifyTheRepresentation() {
    for source in [
      #"{"label":"application/tldraw"}"#,
      #"{"label":"{\"type\":\"application/tldraw\"}"}"#,
      #"{"label":"<div data-tldraw>"}"#,
      #"{"nested":{"type":"application/tldraw","tldrawFileFormatVersion":1}}"#,
      #"{"nested":{"schema":{},"shapes":[]}}"#,
      #"{"schema":{},"nested":{"shapes":[]}}"#,
      #"{"shapes":[],"nested":{"schema":{}}}"#,
      #"[{"type":"application/tldraw"}]"#,
      #"["<div data-tldraw>"]"#,
      #""<div data-tldraw>""#,
      #"{"schema":{},"shapes":"[]"}"#,
      #"{"schema":{},"shapes":{}}"#,
      #"{"type":"application/tldraw-other"}"#,
      #"{"type":"application/tldraw"#,
      #"{"label":"unterminated,\"type\":\"application/tldraw\""#,
      #"<div title='<div data-tldraw>'>ordinary</div>"#,
      #"<!-- <div data-tldraw> -->"#,
      #"<script>const label='<div data-tldraw>';</script>"#,
      #"<div data-tldraw-other>ordinary</div>"#,
    ] { #expect(!NotebookTldrawImport.recognizes(source), "\(source)") }
  }

  @Test func escapedIdentityAndOpaquePrecedingValuesKeepRootBoundaries() {
    for source in [
      #"{"\u0074ype":"application\/tldraw","data":"#,
      #"{"tldrawFileFormat\u0056ersion":1,"records":"#,
      #"{"\u0073chema":{},"\u0073hapes":["#,
      #"{"label":"escaped \\\" quote","nested":[{"label":"}"}],"type":"application/tldraw","data":"#,
      #"{"ignored":-2.5e+10,"ready":false,"empty":null,"type":"application/tldraw","data":"#,
    ] { #expect(NotebookTldrawImport.recognizes(source), "\(source)") }
    for source in [
      #"{"label":"\q","type":"application/tldraw"}"#,
      #"{"ignored":01,"type":"application/tldraw"}"#,
      #"{"nested":[},"type":"application/tldraw"}"#,
    ] { #expect(!NotebookTldrawImport.recognizes(source), "\(source)") }
  }

  @Test func theScanHasAFinitePrefixButAnObservedHeaderRemainsAuthoritative() {
    let limit = NotebookTldrawClipboard.maximumBytes
    let identity = #"{"type":"application/tldraw","data":"#
    #expect(NotebookTldrawImport.recognizes(identity + String(repeating: "x", count: limit)))
    #expect(NotebookTldrawImport.recognizes("<div data-tldraw>" + String(repeating: "x", count: limit)))
    #expect(!NotebookTldrawImport.recognizes(String(repeating: " ", count: limit) + identity))
    #expect(!NotebookTldrawImport.recognizes(#"{"label":""# + String(repeating: "x", count: limit)
      + #"","type":"application/tldraw"}"#))
    let depth = NotebookJSONAdmission.maximumDepth
    #expect(!NotebookTldrawImport.recognizes(#"{"ignored":"# + String(repeating: "[", count: depth)
      + "0" + String(repeating: "]", count: depth) + #", "type":"application/tldraw"}"#))
  }

  @Test func htmlPreamblesKeepTheAlreadySupportedWholeImporterPath() throws {
    let content = try NotebookTldrawImportTests.content([NotebookTldrawImportTests.shape("preamble")])
    let fragment = "<div data-tldraw>" + content + "</div>"
    let before = "<html><body><!--StartFragment-->", after = "<!--EndFragment--></body></html>"
    func header(_ offsets: [Int]) -> String {
      "Version:1.0\r\n" + zip(["StartHTML", "EndHTML", "StartFragment", "EndFragment"], offsets)
        .map { key, offset in key + ":" + String(format: "%010d", offset) + "\r\n" }.joined()
    }
    let startHTML = header([0, 0, 0, 0]).utf8.count
    let startFragment = startHTML + before.utf8.count, endFragment = startFragment + fragment.utf8.count
    let cfHtml = header([startHTML, endFragment + after.utf8.count, startFragment, endFragment])
      + before + fragment + after
    let expected = try NotebookTldrawImport.prepare(source: fragment, namespace: NotebookTldrawImportTests.namespace)
    for source in [cfHtml, "Copied diagram\r\n" + fragment] {
      #expect(NotebookTldrawImport.recognizes(source))
      let imported = try NotebookTldrawImport.prepare(source: source, namespace: NotebookTldrawImportTests.namespace)
      #expect(imported.elements == expected.elements)
    }
  }

  @Test func aDeepIgnoredSubtreeBeforeTheRootHeaderStillBelongsToTheImporter() throws {
    let content = try NotebookTldrawImportTests.content([NotebookTldrawImportTests.shape("depth")])
    for depth in [95, 96, NotebookJSONAdmission.maximumDepth - 1] {
      let ignored = String(repeating: "[", count: depth) + "0" + String(repeating: "]", count: depth)
      let source = #"{"ignored":"# + ignored + #", "type":"application/tldraw","kind":"content","data":"# + content + "}"
      #expect(NotebookTldrawImport.recognizes(source))
      if depth == 95 {
        let imported = try NotebookTldrawImport.prepare(source: source, namespace: NotebookTldrawImportTests.namespace)
        #expect(imported.canInsert)
      } else {
        #expect(throws: (any Error).self) {
          try NotebookTldrawImport.prepare(source: source, namespace: NotebookTldrawImportTests.namespace)
        }
      }
    }
  }

  @Test func recognitionDoesNotAcceptMalformedContentForInsertion() {
    let source = #"{"type":"application/tldraw","kind":"content","data":"#
    #expect(NotebookTldrawImport.recognizes(source))
    #expect(throws: (any Error).self) { try NotebookTldrawImport.prepare(source: source, namespace: .init()) }
  }
}

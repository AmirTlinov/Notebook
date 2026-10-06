import Foundation
import Testing
@testable import NotebookCore

@Suite("Portable structural HTML search text")
struct NotebookSearchTextTests {
  @Test func quotesCommentsRawTextAndBlockBoundariesKeepOnlyStructuralText() throws {
    let html = """
      <head><title>HeadNeedle</title></head><p title="quoted > QuotedNeedle">ab<span>cd</span><!--CommentNeedle-->ef</p>
      <p>next<br>line</p><ScRiPt>if (a < b) { 'RawNeedle' }</sCrIpT><style>x{content:'StyleNeedle'}</style>
      <template>TemplateNeedle<template>NestedNeedle</template></template><div>最後</div>
      """
    #expect(try NotebookSearchText.html(html) == "abcdef next line 最後")
    #expect(try NotebookSearchText.html("a<script>'<p>raw</p>'</script>b<style>raw</style>c") == "abc")
    #expect(try NotebookSearchText.html("<textarea>&lt;em&gt;literal&lt;/em&gt; <b>raw</b></textarea>") == "<em>literal</em> <b>raw</b>")
  }

  @Test func entitiesDecodeOnceAndUnknownOrMalformedNamesStayLiteral() throws {
    #expect(try NotebookSearchText.html("<p>&lt;script&gt; &amp;lt; &quot; &#39; &#x1F58B; &nbsp; Caf&eacute; &alpha; &#128;</p>")
      == "<script> &lt; \" ' 🖋 Café α €")
    #expect(try NotebookSearchText.html("<p>&unknown; &not_closed &#0; &#xD800; &#1114112; &#bogus;</p>")
      == "&unknown; &not_closed � � � &#bogus;")
  }

  @Test func malformedMarkupHasADeterministicTailContractWithoutDroppingLiteralAngles() throws {
    #expect(try NotebookSearchText.html("a < 2 > 1 and <3>") == "a < 2 > 1 and <3>")
    #expect(try NotebookSearchText.html("before <span title='unfinished > secret") == "before")
    #expect(try NotebookSearchText.html("before <!-- unfinished secret") == "before")
    #expect(try NotebookSearchText.html("before <script>unfinished secret") == "before")
    #expect(try NotebookSearchText.html("before <template>unfinished secret") == "before")
  }

  @Test func sourceLimitsRefuseWholeExtractionBeforeAllocatingAWorkingCopy() throws {
    let oversized = String(repeating: "x", count: NotebookSearchText.maximumHTMLBytes + 1)
    #expect(throws: NotebookStorageError.limitExceeded("search_html_bytes")) { _ = try NotebookSearchText.html(oversized) }
    #expect(throws: NotebookStorageError.limitExceeded("search_text_bytes")) { _ = try NotebookSearchText.plain(oversized) }
    #expect(throws: NotebookStorageError.limitExceeded("search_html_depth")) {
      _ = try NotebookSearchText.html(String(repeating: "<template>", count: 257))
    }
  }
}

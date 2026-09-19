import NotebookCore
import UIKit
import XCTest
@testable import Notebook

@MainActor final class NotebookTextTypographyTests: XCTestCase {
  func testSelectedUTF16FormattingSurvivesNativeInsertionAndStaticRendering() throws {
    let marked = NativeTextFormat(fontName:"Georgia",bold:true,italic:true,
      highlight:.init(red:1,green:0.9,blue:0.35),link:"https://example.com")
    let base = NativeTextStyle(fontSize:24,format:.init(fontName:"Menlo-Regular"),
      runs:[.init(location:2,length:4,format:marked)])
    let text = NSMutableAttributedString(attributedString:NotebookTextTypography.attributed("🙂Text tail",style:base))
    let selected = text.attributes(at:2,effectiveRange:nil)
    let font = try XCTUnwrap(selected[.font] as? UIFont)
    XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.traitBold))
    XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.traitItalic))
    XCTAssertEqual(selected[.link] as? URL,URL(string:"https://example.com"))
    XCTAssertNotNil(selected[.backgroundColor])
    text.insert(.init(string:"!",attributes:selected),at:6)
    let result = NotebookTextTypography.style(from:text,base:base)
    XCTAssertEqual(result.runs?.first(where: { $0.location == 2 })?.length,5)
    XCTAssertEqual(result.runs?.first(where: { $0.location == 2 })?.format,marked)
    let staticText = NSAttributedString(AttributedString(NotebookTextTypography.attributed(text.string,style:result)))
    XCTAssertEqual(staticText.attribute(.font,at:2,effectiveRange:nil) as? UIFont,font)
    XCTAssertEqual(staticText.attribute(.link,at:2,effectiveRange:nil) as? URL,URL(string:"https://example.com"))
  }
}

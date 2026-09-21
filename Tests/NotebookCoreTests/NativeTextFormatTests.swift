import Foundation
import Testing
@testable import NotebookCore

@Suite struct NativeTextFormatTests {
  @Test func nativeAttributeFormatsUseValueHashes() throws {
    let formats: [NativeTextFormat] = [.init(), .init(fontName:"Georgia"), .init(bold:true),
      .init(italic:true), .init(highlight:.init(red:1,green:0.9,blue:0.3)), .init(link:"https://example.com")]
    var hashes: [AnyHashable] = []
    for format in formats {
      let value: Any = format, copy: Any = try JSONDecoder().decode(NativeTextFormat.self,from:JSONEncoder().encode(format))
      let hash = try #require(value as? AnyHashable), copiedHash = try #require(copy as? AnyHashable)
      let native = value as AnyObject, copiedNative = copy as AnyObject
      #expect(hash == copiedHash && hash.hashValue == copiedHash.hashValue)
      #expect(native.isEqual(copiedNative) && native.hash == hash.hashValue)
      hashes.append(hash)
    }
    #expect(Set(hashes).count == formats.count)
    #expect(NSSet(array:formats + formats).count == formats.count)
    let positive = NativeTextFormat(highlight:.init(red:0,green:0,blue:0))
    let negative = NativeTextFormat(highlight:.init(red:-0.0,green:0,blue:0))
    #expect(positive == negative && positive.hashValue == negative.hashValue)
  }
  @Test func stylesRoundTripWithUTF16RangesAndOldPlainTextStillDecodes() throws {
    let format = NativeTextFormat(fontName:"Georgia",bold:true,italic:true,
      highlight:.init(red:1,green:0.9,blue:0.3),link:"https://example.com")
    let style = NativeTextStyle(format:.init(fontName:"Menlo-Regular"),
      runs:[.init(location:2,length:5,format:format)])
    #expect(style.isValid(for:"🙂Привет"))
    #expect(try JSONDecoder().decode(NativeTextStyle.self,from:JSONEncoder().encode(style)) == style)
    let old = Data(#"{"fontSize":34,"weight":0.45,"red":0.09,"green":0.09,"blue":0.08,"alpha":1}"#.utf8)
    #expect(try JSONDecoder().decode(NativeTextStyle.self,from:old) == .standard)
  }
  @Test func malformedCharacterRangesAndExecutableLinksAreRejected() {
    #expect(!NativeTextStyle(runs:[.init(location:0,length:4,format:.init()),.init(location:3,length:1,format:.init())]).isValid(for:"hello"))
    #expect(!NativeTextStyle(runs:[.init(location:Int.max,length:1,format:.init())]).isValid(for:"hello"))
    #expect(!NativeTextStyle(runs:[.init(location:0,length:6,format:.init())]).isValid(for:"hello"))
    #expect(!NativeTextStyle(format:.init(link:"javascript:alert(1)")).isValid)
    #expect(!NativeTextStyle(format:.init(link:"file:///tmp/private")).isValid)
    #expect(NativeTextFormat.isWebLink("https://example.com/path"))
  }
  @Test func linePatternsHaveOnePhysicalWidthDependentDefinition() {
    #expect(NotebookGraphic.Style(strokeWidth:2,dash:.solid).dashPattern.isEmpty)
    #expect(NotebookGraphic.Style(strokeWidth:2,dash:.dashed).dashPattern == [8,6])
    #expect(NotebookGraphic.Style(strokeWidth:2,dash:.dotted).dashPattern == [0,6])
    #expect(NotebookGraphic.Style(strokeWidth:2,dash:.dashDot).dashPattern == [8,6,0,6])
  }
}

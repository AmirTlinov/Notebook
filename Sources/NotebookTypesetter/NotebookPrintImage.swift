import Foundation

/// Only inspect bounded headers on the host. Pixel decompression and PDF
/// encoding run inside the same interruptible fixed-memory image kernel as SVG.
/// No ImageIO/Quartz decoder can keep a cancelled typesetting job alive.
enum NotebookPrintImage {
  static func embeddedSVG(_ data: Data, mediaType: String) throws -> Data {
    let bytes = [UInt8](data)
    func u16(_ i: Int) -> Int { Int(bytes[i]) << 8 | Int(bytes[i+1]) }
    func u32(_ i: Int) -> Int { (0..<4).reduce(0) { ($0 << 8) | Int(bytes[i+$1]) } }
    var width = 0, height = 0
    if mediaType == "image/png", bytes.count >= 24,
      bytes.prefix(8).elementsEqual([137, 80, 78, 71, 13, 10, 26, 10]),
      bytes[12..<16].elementsEqual(Array("IHDR".utf8)) {
      width = u32(16); height = u32(20)
    } else if mediaType == "image/jpeg", bytes.count >= 4, bytes[0] == 255, bytes[1] == 216 {
      var i = 2
      while i+4 <= bytes.count {
        try Task.checkCancellation()
        guard bytes[i] == 255 else { break }
        while i < bytes.count, bytes[i] == 255 { i += 1 }
        guard i+3 <= bytes.count else { break }
        let marker = bytes[i]; i += 1
        if marker == 217 || marker == 218 { break }
        if marker == 1 || (208...215).contains(marker) { continue }
        let size = u16(i)
        guard size >= 2, size <= bytes.count-i else { break }
        if [192,193,194,195,197,198,199,201,202,203,205,206,207].contains(marker), size >= 8 {
          height = u16(i+3); width = u16(i+5); break
        }
        i += size
      }
    }
    guard width > 0, height > 0, width <= 16_384, height <= 16_384, width*height <= 16_777_216 else {
      throw NotebookTypesetterError("print_image_dimensions: PNG/JPEG exceeds 16384 px / 16 megapixels or has an invalid header")
    }
    let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(width)\" height=\"\(height)\"><image width=\"\(width)\" height=\"\(height)\" href=\"data:\(mediaType);base64,\(data.base64EncodedString())\"/></svg>"
    guard svg.utf8.count <= 8*1024*1024 else { throw NotebookTypesetterError("print_image_input_limit") }
    return Data(svg.utf8)
  }
}

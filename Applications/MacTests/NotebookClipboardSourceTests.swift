import CoreGraphics
import Foundation
import ImageIO
import NotebookCore
import UniformTypeIdentifiers
import XCTest
@testable import Notebook

@MainActor final class NotebookClipboardSourceTests: XCTestCase {
  func testUnreadableAndOversizedOptionalHTMLCanUseThePlainTextRepresentation() async throws {
    for html in [Data([0xff, 0xfe, 0x42]), Data(repeating: 65, count: 1_048_577)] {
      let input = provider([(.html, html), (.plainText, Data("Complete text".utf8))])
      guard case .fragment(let fragment) = try await NotebookClipboard.read([input],
        availableSize: .init(x: 834, y: 1194)) else { return XCTFail() }
      XCTAssertEqual(fragment.elements.count, 1)
      XCTAssertTrue(fragment.elements[0].html.contains("Complete text"))
    }
    let input = provider([(.plainText, Data("Provider fallback".utf8))])
    input.registerDataRepresentation(forTypeIdentifier: UTType.html.identifier, visibility: .all) { complete in
      complete(nil, NSError(domain: "clipboard-provider", code: 7)); return nil
    }
    guard case .fragment(let fragment) = try await NotebookClipboard.read([input],
      availableSize: .init(x: 834, y: 1194)) else { return XCTFail() }
    XCTAssertTrue(fragment.elements[0].html.contains("Provider fallback"))
  }

  func testAuthoritativeNativeAndRecognizableStructuredContentNeverFlattenIntoText() async throws {
    let input = provider([(NotebookClipboard.fragmentType, Data("broken native".utf8)),
      (.plainText, Data("labels".utf8))])
    do {
      _ = try await NotebookClipboard.read([input], availableSize: .init(x: 834, y: 1194))
      XCTFail("A damaged native fragment must refuse the whole paste")
    } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
    let html = provider([(.html, Data("<div data-tldraw>broken</div>".utf8)), (.plainText, Data("labels".utf8))])
    guard case .composition(let source) = try await NotebookClipboard.read([html],
      availableSize: .init(x: 834, y: 1194)) else { return XCTFail() }
    XCTAssertThrowsError(try NotebookTldrawImport.prepare(source: source, namespace: UUID()))
  }

  func testOversizedStructuredUtf16AndJSONPrefixesRefuseThePlainTextAlternative() async throws {
    let source = "<div data-tldraw>" + String(repeating: "x", count: 600_000)
    var utf16 = Data([0xFF, 0xFE])
    for unit in source.utf16 { utf16.append(UInt8(unit & 255)); utf16.append(UInt8(unit >> 8)) }
    let json = Data(("{\"type\":\"application/tldraw\",\"data\":\"" + String(repeating: "x", count: 1_048_576)).utf8)
    for (type, bytes) in [(UTType.html, utf16), (UTType.json, json)] {
      let input = provider([(type, bytes), (.plainText, Data("Visible labels only".utf8))])
      do {
        _ = try await NotebookClipboard.read([input], availableSize: .init(x: 834, y: 1194))
        XCTFail("An explicit structured source must refuse as a whole")
      } catch let error as CollaborationError { XCTAssertEqual(error.code, "clipboard_structure_limit") }
    }
  }

  func testCancellationOfAnOptionalProviderDoesNotProceedToItsPlainText() async throws {
    let entered = expectation(description: "HTML provider entered")
    let input = provider([(.plainText, Data("Must not paste".utf8))])
    input.registerDataRepresentation(forTypeIdentifier: UTType.html.identifier, visibility: .all) { complete in
      let progress = Progress(totalUnitCount: 1)
      progress.cancellationHandler = { complete(nil, CancellationError()) }
      entered.fulfill(); return progress
    }
    let task = Task { try await NotebookClipboard.read([input], availableSize: .init(x: 834, y: 1194)) }
    await fulfillment(of: [entered], timeout: 5)
    task.cancel()
    do { _ = try await task.value; XCTFail("Cancellation must reach the clipboard owner") }
    catch { XCTAssertTrue(error is CancellationError, "\(error)") }
  }

  func testCanonicalImageKeepsResolutionAndExactPixelsBeyondTheOldThumbnailBoundary() throws {
    let source = try image(width: 3001, height: 3)
    let encoded = try encode(source, type: .png)
    let canonical = try NotebookClipboardImage.prepare(encoded, totalInputBytes: encoded.count, retainedHTMLBytes: 0)
    let decoded = try decode(canonical.png)
    XCTAssertEqual(canonical.width, 3001); XCTAssertEqual(canonical.height, 3)
    XCTAssertEqual(try rgba(decoded), try rgba(source), "No resampling or JPEG quantization belongs in author content")
  }

  func testEveryExifOrientationKeepsTheSourcePixelPermutationAndClearsPrivateMetadata() throws {
    let source = try image(width: 4, height: 3), pixels = try rgba(source)
    for orientation in 1...8 {
      let encoded = try encode(source, type: .tiff, properties: [
        kCGImagePropertyOrientation: orientation,
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "private artist"]])
      let sourceContainer = try XCTUnwrap(CGImageSourceCreateWithData(encoded as CFData, nil))
      let sourceProperties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(sourceContainer, 0, nil) as? [CFString: Any])
      XCTAssertEqual((sourceProperties[kCGImagePropertyOrientation] as? NSNumber)?.intValue, orientation)
      let canonical = try NotebookClipboardImage.prepare(encoded, totalInputBytes: encoded.count, retainedHTMLBytes: 0)
      let output = try decode(canonical.png), actual = try rgba(output)
      let width = orientation >= 5 ? source.height : source.width
      let height = orientation >= 5 ? source.width : source.height
      XCTAssertEqual(output.width, width); XCTAssertEqual(output.height, height)
      // Fixed EXIF oracle for a labelled 4×3 source; independent of the
      // production coordinate transform and of CoreGraphics interpolation.
      let orders = [
        [0,1,2,3,4,5,6,7,8,9,10,11],
        [3,2,1,0,7,6,5,4,11,10,9,8],
        [11,10,9,8,7,6,5,4,3,2,1,0],
        [8,9,10,11,4,5,6,7,0,1,2,3],
        [0,4,8,1,5,9,2,6,10,3,7,11],
        [8,4,0,9,5,1,10,6,2,11,7,3],
        [11,7,3,10,6,2,9,5,1,8,4,0],
        [3,7,11,2,6,10,1,5,9,0,4,8]]
      let expected = orders[orientation - 1].flatMap { Array(pixels[($0 * 4)..<($0 * 4 + 4)]) }
      XCTAssertEqual(actual, expected, "orientation \(orientation)")
      let container = try XCTUnwrap(CGImageSourceCreateWithData(canonical.png as CFData, nil))
      let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(container, 0, nil) as? [CFString: Any])
      XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
      XCTAssertNil((properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFArtist])
      XCTAssertTrue(properties[kCGImagePropertyOrientation] == nil || (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue == 1)
    }
  }

  func testImageFinishCapacityRefusesInsteadOfChangingQuality() throws {
    let encoded = try encode(image(width: 10, height: 10), type: .png)
    XCTAssertThrowsError(try NotebookClipboardImage.prepare(encoded, totalInputBytes: encoded.count,
      retainedHTMLBytes: NotebookClipboardImage.maximumPreparationBytes))
  }

  func testCanonicalImagePreservesTransparencyAndSixteenBitSamples() throws {
    for depth in [8, 16] {
      let samples: [UInt16] = [0, 0, 0, 0, 67, 128, 192, 255, 257, 1023, 4095, 32768,
        8191, 16383, 32767, 65535]
      let bytes = depth == 8 ? Data([0, 0, 0, 0, 17, 57, 123, 128, 67, 128, 192, 255, 143, 78, 19, 63])
        : samples.withUnsafeBufferPointer { pointer in
          Data(pointer.flatMap { [UInt8($0 >> 8), UInt8($0 & 255)] })
        }
      let dataProvider = try XCTUnwrap(CGDataProvider(data: bytes as CFData))
      var info = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
      if depth == 16 { info.insert(.byteOrder16Big) }
      let image = try XCTUnwrap(CGImage(width: 4, height: 1, bitsPerComponent: depth,
        bitsPerPixel: depth * 4, bytesPerRow: depth * 2, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: info, provider: dataProvider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
      let source = try encode(image, type: .png), decodedSource = try decode(source)
      XCTAssertEqual(decodedSource.bitsPerComponent, depth)
      let canonical = try NotebookClipboardImage.prepare(source, totalInputBytes: source.count, retainedHTMLBytes: 0)
      let output = try decode(canonical.png)
      XCTAssertEqual(output.bitsPerComponent, depth)
      XCTAssertEqual(output.bitsPerPixel, decodedSource.bitsPerPixel)
      XCTAssertEqual(output.bitmapInfo, decodedSource.bitmapInfo)
      let sourcePixels = try XCTUnwrap(decodedSource.dataProvider?.data)
      let outputPixels = try XCTUnwrap(output.dataProvider?.data)
      let meaningfulBytes = decodedSource.width * decodedSource.bitsPerPixel / 8
      XCTAssertEqual(Data((sourcePixels as Data).prefix(meaningfulBytes)),
        Data((outputPixels as Data).prefix(meaningfulBytes)), "\(depth)-bit color and alpha samples")
    }
  }

  private func provider(_ values: [(UTType, Data)]) -> NSItemProvider {
    let result = NSItemProvider()
    for (type, bytes) in values {
      result.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { complete in
        complete(bytes, nil); return nil
      }
    }
    return result
  }
  private func image(width: Int, height: Int) throws -> CGImage {
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for index in 0..<(width * height) {
      pixels[index * 4] = UInt8(index % 251)
      pixels[index * 4 + 1] = UInt8((index * 3) % 253)
      pixels[index * 4 + 2] = UInt8((index * 7) % 255)
    }
    let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
    return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: .init(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
      decode: nil, shouldInterpolate: false, intent: .defaultIntent))
  }
  private func encode(_ image: CGImage, type: UTType, properties: [CFString: Any] = [:]) throws -> Data {
    let data = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return data as Data
  }
  private func decode(_ data: Data) throws -> CGImage {
    let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
    return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
  }
  private func rgba(_ image: CGImage) throws -> [UInt8] {
    let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
      bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.interpolationQuality = .none; context.setBlendMode(.copy)
    context.draw(image, in: .init(x: 0, y: 0, width: image.width, height: image.height))
    return Array(UnsafeBufferPointer(start: try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self),
      count: image.width * image.height * 4))
  }
}

import CoreGraphics
import ImageIO
import NotebookCore
import NotebookTypesetter
import XCTest
@testable import Notebook

@MainActor final class DocumentPrintImageTests: XCTestCase {
  func testOfflineSVGPNGAndJPEGBecomeBoundedAssetsOfTheActualPrintArtifact() async throws {
    let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 64*4,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
    let image = try XCTUnwrap(context.makeImage())
    var inputs: [(String, Data)] = [("image/svg+xml", Data("<svg xmlns='http://www.w3.org/2000/svg' width='64' height='48'><rect width='64' height='48' fill='red'/></svg>".utf8))]
    for (type, media) in [("public.png", "image/png"), ("public.jpeg", "image/jpeg")] {
      let bytes = NSMutableData()
      let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, type as CFString, 1, nil))
      CGImageDestinationAddImage(destination, image, nil)
      XCTAssertTrue(CGImageDestinationFinalize(destination))
      inputs.append((media, bytes as Data))
    }
    for (media, bytes) in inputs {
      let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "image", source:
        "<img width='64' height='48' src='data:\(media);base64,\(bytes.base64EncodedString())'>")])
      let artifact = try await DocumentCanonicalPrint.store.artifact(for: document)
      XCTAssertEqual(artifact.assets.count, 1)
      XCTAssertTrue(artifact.assets[0].data.starts(with: Data("%PDF-".utf8)))
      let resources = SceneRenderResources(), charge = try XCTUnwrap(resources.reserveDerivedBytes(artifact.pdf.count, priority: .passive))
      let source = DocumentPrintedSource(artifact: artifact, pdf: .init(artifact.pdf), reservation: charge)
      let page = DocumentPrintedPage(source: source, pageIndex: 0, width: document.paperSize.widthPoints, height: document.paperSize.heightPoints)
      let raster = try await page.image(width: 595)
      let pixels = try XCTUnwrap(raster.dataProvider?.data) as Data
      let red = stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0] > 200 && pixels[$0+1] < 60 && pixels[$0+2] < 60 }
      XCTAssertGreaterThan(red.count, 200, "Converted \(media) must appear on the actual printed page")
    }
  }
}

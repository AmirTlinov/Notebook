import CoreGraphics
import CryptoKit
import ImageIO
import NotebookCore
import NotebookTypesetter
import XCTest
@testable import Notebook

@MainActor final class DocumentPrintImageTests: XCTestCase {
  func testPNGJPEGAndVectorPDFRemainActualAddressedFilesInThePrintedArtifact() async throws {
    let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 64*4,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
    let image = try XCTUnwrap(context.makeImage())
    let svg = Data("<svg xmlns='http://www.w3.org/2000/svg' width='64' height='48'><rect width='64' height='48' fill='red'/></svg>".utf8)
    var inputs = [("figures/image.pdf", try await DocumentCanonicalPrint.store.vectorPDF(svg))]
    for (type, path) in [("public.png", "figures/image.png"), ("public.jpeg", "figures/image.jpg")] {
      let bytes = NSMutableData(), destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, type as CFString, 1, nil))
      CGImageDestinationAddImage(destination, image, nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
      inputs.append((path, bytes as Data))
    }
    for (path, bytes) in inputs {
      let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
      let resource = NotebookProgramPackage.File(path: path, mimeType: NotebookProgramPackage.mimeType(for: path), byteCount: Int64(bytes.count),
        parts: [.init(sha256: hash, byteCount: bytes.count)])
      let tex = "\\documentclass{article}\n\\usepackage{graphicx}\n\\begin{document}\n\\includegraphics[width=64bp,height=48bp]{\(path)}\n\\end{document}\n"
      let document = DocumentDocument(actor: UUID(), files: [.init(id: "main", path: "main.tex", source: tex), .init(id: "image", path: path, resource: resource)])
      let input = try NotebookTypesetterInput(document: document, readResource: { _ in bytes })
      let artifact = try await DocumentCanonicalPrint.store.artifact(for: document, input: input)
      XCTAssertTrue(artifact.dependencies.lookups.contains { $0.path == path })
      let resources = SceneRenderResources(), charge = try XCTUnwrap(resources.reserveDerivedBytes(artifact.pdf.count, priority: .passive))
      let source = DocumentPrintedSource(artifact: artifact, pdf: .init(artifact.pdf), reservation: charge,
        lineIndices: Dictionary(uniqueKeysWithValues: artifact.document.files.filter { $0.resource == nil }.map { ($0.id, DocumentPrintLineIndex($0.source)) }),
        slots: Dictionary(grouping: artifact.interactiveRegions, by: \.pageIndex))
      let page = DocumentPrintedPage(source: source, pageIndex: 0, width: artifact.pages[0].width, height: artifact.pages[0].height)
      let raster = try await page.image(width: 595), pixels = try XCTUnwrap(raster.dataProvider?.data) as Data
      let red = stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0] > 200 && pixels[$0+1] < 60 && pixels[$0+2] < 60 }
      XCTAssertGreaterThan(red.count, 200, "\(path) must appear on the actual printed page")
    }
  }
}

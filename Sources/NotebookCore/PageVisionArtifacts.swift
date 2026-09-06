import CryptoKit
import Foundation

// A map is ready only when every file named by its receipt matches the source.
extension NotebookStore {
  public func hasCurrentPageVision(_ page: PageDocument) -> Bool {
    guard let receiptData = try? Data(
      contentsOf: self.previewVisionReceiptURL(page.id)
    ),
      let receipt = try? JSONDecoder().decode(
        PageVisionReceipt.self,
        from: receiptData
      ),
      receipt.isValid,
      receipt.pageID == page.id,
      receipt.pageSize == page.size,
      receipt.drawingStamp == page.drawingStamp,
      let preview = try? Data(contentsOf: self.previewURL(page.id)),
      pageVisionHash(preview) == receipt.previewPNG_SHA256,
      let ink = try? Data(contentsOf: self.previewInkURL(page.id)),
      pageVisionHash(ink) == receipt.inkPNG_SHA256
    else { return false }

    let directory = self.previewRegionsURL(page.id)
    return receipt.regions.allSatisfy { region in
      guard let faithful = try? Data(contentsOf: directory.appendingPathComponent("\(region.id).faithful.png")),
        pageVisionHash(faithful) == region.faithfulPNG_SHA256,
        let cleanInk = try? Data(contentsOf: directory.appendingPathComponent("\(region.id).ink.png"))
      else { return false }
      return pageVisionHash(cleanInk) == region.inkPNG_SHA256
    }
  }

  private func pageVisionHash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

import Foundation
import NotebookCore

enum PagePreviewWriter {
  static func write(_ page: PageDocument, store: NotebookStore) throws {
    try Task.checkCancellation()
    let previewURL = store.previewURL(page.id)
    let render = try PageVisionRenderer.render(page)
    try Task.checkCancellation()
    let regionsURL = store.previewRegionsURL(page.id)
    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: previewURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try fileManager.createDirectory(
      at: regionsURL,
      withIntermediateDirectories: true
    )
    try archivePreviousReceipt(page: page, store: store)

    var expectedRegionFiles = Set<String>()
    for region in render.regions {
      let faithfulURL = regionURL(
        in: regionsURL,
        regionID: region.receipt.id,
        mode: "faithful"
      )
      let inkURL = regionURL(
        in: regionsURL,
        regionID: region.receipt.id,
        mode: "ink"
      )
      try region.faithfulPNG.write(to: faithfulURL, options: [.atomic])
      try region.inkPNG.write(to: inkURL, options: [.atomic])
      expectedRegionFiles.insert(faithfulURL.lastPathComponent)
      expectedRegionFiles.insert(inkURL.lastPathComponent)
    }

    let receipt = PageVisionReceipt(
      page: page,
      renderScale: PageVisionRenderer.scale,
      gridSpacing: PhysicalPaper.gridSpacing,
      pixelSize: render.pixelSize,
      visibleInkBounds: render.visibleInkBounds,
      occupiedCells: render.occupiedCells,
      regions: render.regions.map(\.receipt),
      previewPNG_SHA256: PageVisionRenderer.sha256(render.faithfulPNG),
      inkPNG_SHA256: PageVisionRenderer.sha256(render.inkPNG)
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let receiptData = try encoder.encode(receipt)

    // The receipt is the commit marker. Readers verify its hashes, so a read
    // during publication is rejected instead of mixing two page revisions.
    try render.faithfulPNG.write(to: previewURL, options: [.atomic])
    try render.inkPNG.write(
      to: store.previewInkURL(page.id),
      options: [.atomic]
    )
    try receiptData.write(
      to: store.previewVisionReceiptURL(page.id),
      options: [.atomic]
    )
    let replacedRevisionURL = previewURL.deletingPathExtension()
      .appendingPathExtension("revision")
    try? fileManager.removeItem(at: replacedRevisionURL)

    let existingRegionFiles = try fileManager.contentsOfDirectory(
      at: regionsURL,
      includingPropertiesForKeys: nil
    )
    for url in existingRegionFiles
      where !expectedRegionFiles.contains(url.lastPathComponent)
    {
      try? fileManager.removeItem(at: url)
    }
  }

  private static func regionURL(
    in directory: URL,
    regionID: String,
    mode: String
  ) -> URL {
    directory.appendingPathComponent("\(regionID).\(mode).png")
  }

  private static func archivePreviousReceipt(
    page: PageDocument,
    store: NotebookStore
  ) throws {
    let currentURL = store.previewVisionReceiptURL(page.id)
    guard let data = try? Data(contentsOf: currentURL),
          let previous = try? JSONDecoder().decode(PageVisionReceipt.self, from: data),
          previous.isValid,
          previous.pageID == page.id,
          previous.drawingStamp != page.drawingStamp
    else { return }

    let historyURL = store.previewVisionHistoryURL(page.id)
    try FileManager.default.createDirectory(
      at: historyURL,
      withIntermediateDirectories: true
    )
    let actor = previous.drawingStamp.actor.uuidString.lowercased()
    let archivedURL = historyURL.appendingPathComponent(
      "\(previous.drawingStamp.counter)-\(actor).json"
    )
    try data.write(to: archivedURL, options: [.atomic])

    let historyFiles = try FileManager.default.contentsOfDirectory(
      at: historyURL,
      includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "json" }
    var archivedReceipts: [(URL, VersionStamp)] = []
    for url in historyFiles {
      guard let data = try? Data(contentsOf: url),
            let receipt = try? JSONDecoder().decode(
              PageVisionReceipt.self,
              from: data
            ),
            receipt.isValid,
            receipt.pageID == page.id
      else {
        try? FileManager.default.removeItem(at: url)
        continue
      }
      archivedReceipts.append((url, receipt.drawingStamp))
    }
    archivedReceipts.sort { $0.1 > $1.1 }
    for obsolete in archivedReceipts.dropFirst(8) {
      try? FileManager.default.removeItem(at: obsolete.0)
    }
  }
}

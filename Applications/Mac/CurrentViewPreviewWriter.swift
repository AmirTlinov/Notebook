import AppKit
import CryptoKit
import SwiftUI
import NotebookCore

enum CurrentViewPreviewWriter {
  @MainActor
  static func write(
    model: NotebookAppModel,
    viewport: CGSize,
    workspace: WorkspaceIndex,
    board: BoardDocument,
    spatialInk: SpatialInkJournal,
    presence: SessionPresence,
    page: PageDocument?,
    document: DocumentDocument?,
    documentState: DocumentStateJournal?,
    pngURL: URL,
    receiptURL: URL
  ) throws {
    if let document, let documentState,
      DocumentSnapshotCache.shared.image(
        for: document,
        state: documentState,
        pageIndex: presence.documentPageIndex
      ) == nil
    {
      throw PreviewError.documentSnapshotPending
    }
    let content = SpatialWorkspaceView()
      .environment(model)
      .environment(\.rendersDocumentSnapshot, true)
      .frame(width: viewport.width, height: viewport.height)
    let renderer = ImageRenderer(content: content)
    renderer.proposedSize = ProposedViewSize(viewport)
    renderer.scale = 2
    guard let image = renderer.nsImage,
      let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:])
    else { throw PreviewError.pngEncoding }

    let digest = SHA256.hash(data: png).map { String(format: "%02x", $0) }
      .joined()
    let receipt = CurrentViewReceipt(
      workspace: workspace,
      board: board,
      spatialInk: spatialInk,
      presence: presence,
      renderViewport: SpatialPoint(x: viewport.width, y: viewport.height),
      page: page,
      document: document,
      documentState: documentState,
      pngSHA256: digest
    )
    guard receipt.isValid else { throw PreviewError.invalidReceipt }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let receiptData = try encoder.encode(receipt)
    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: pngURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try png.write(to: pngURL, options: [.atomic])
    try receiptData.write(to: receiptURL, options: [.atomic])
  }

  private enum PreviewError: Error {
    case documentSnapshotPending
    case invalidReceipt
    case pngEncoding
  }
}

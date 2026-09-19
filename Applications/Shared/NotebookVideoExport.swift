#if os(macOS)
import AppKit
import AVFoundation
import CoreVideo
import NotebookCore

/// Offline frame production, not an animation clock. One existing canonical
/// renderer seeks explicit model times; AVFoundation supplies encoder backpressure.
@MainActor enum NotebookVideoExport {
  static func write(to url: URL, cut: NotebookExportCut, options: NotebookExportOptions,
    jobID: UUID, store: NotebookStore) async throws {
    try options.validate()
    guard let video = options.video, let width = options.pixelWidth, let blockID = options.blockID else { throw SceneRenderError.resourceLimit }
    let geometry = WorkspaceItemGeometry.document(cut.document.paperSize)
    let sourceHeight = Int(ceil(Double(width)*geometry.height/geometry.width))
    let height = sourceHeight + sourceHeight % 2 // One white bottom pixel, never a rescale/crop.
    let resources = SceneRenderResources.shared
    // The canonical raster has its own existing lease. Account the additional
    // conversion/encoder buffers separately, independent of frame count.
    guard let storage = resources.reserveDerivedBytes(width*height*4*2, priority: .passive) else { throw SceneRenderError.resourceLimit }
    defer { storage.release() }
    let encoder = NotebookVideoEncoder(url: url, width: width, height: height, video: video)
    try await withTaskCancellationHandler {
      do {
        try await encoder.start()
        try await DocumentSnapshotCache.shared.withPreparedPage(document: cut.document, state: cut.state,
          pageIndex: options.pageIndex ?? 0, resources: resources, programStore: store, isolationID: jobID) { coordinator in
          for index in 0..<video.frameCount {
            try Task.checkCancellation()
            let time = video.start + Double(index)/Double(video.framesPerSecond)
            let raster = try await coordinator.retainPreparedSnapshot(pixelWidth: width, force: true,
              waitsForRasterAdmission: false, videoFrame: (blockID, time))
            defer { raster.release() }
            var rect = CGRect(origin: .zero, size: raster.image.size)
            guard let image = raster.image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              image.width == width, image.height == sourceHeight else { throw SceneRenderError.snapshotPending("video_pixel_extent") }
            // Exactly one submitted image. The encoder converts off the UI actor
            // and suspends for backpressure instead of building a frame sequence.
            try await encoder.append(image, index: index)
          }
        }
        try await encoder.finish()
      } catch { await encoder.cancel(); throw error }
    } onCancel: { Task { await encoder.cancel() } }
  }
}

/// All codec creation, conversion and append work has one off-main owner.
/// Reentrancy during receiver.append lets cancellation unblock the codec.
private actor NotebookVideoEncoder {
  let url: URL, width: Int, height: Int, video: NotebookExportOptions.Video
  private var writer: AVAssetWriter?
  private var receiver: AVAssetWriterInput.PixelBufferReceiver?
  private var cancelled = false
  init(url: URL, width: Int, height: Int, video: NotebookExportOptions.Video) {
    self.url = url; self.width = width; self.height = height; self.video = video
  }
  func start() throws {
    try Task.checkCancellation(); guard !cancelled else { throw CancellationError() }
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    self.writer = writer
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
      AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: width*height*8,
        AVVideoExpectedSourceFrameRateKey: video.framesPerSecond, AVVideoAllowFrameReorderingKey: false]])
    receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: attributes)
    try writer.start(); writer.startSession(atSourceTime: .zero)
  }
  private var attributes: CVPixelBufferCreationAttributes {
    .init(pixelFormatType: .init(rawValue: kCVPixelFormatType_32BGRA), size: .init(width: width, height: height))
  }
  func append(_ image: CGImage, index: Int) async throws {
    try Task.checkCancellation(); guard !cancelled, let receiver else { throw CancellationError() }
    let buffer = try Self.pixelBuffer(image, attributes: attributes, height: height)
    try await receiver.append(buffer, with: CMTime(value: Int64(index), timescale: Int32(video.framesPerSecond)))
    try Task.checkCancellation()
  }
  func finish() async throws {
    try Task.checkCancellation(); guard !cancelled, let writer, let receiver else { throw CancellationError() }
    receiver.finish()
    writer.endSession(atSourceTime: CMTime(value: Int64(video.frameCount), timescale: Int32(video.framesPerSecond)))
    await writer.finishWriting()
    try Task.checkCancellation(); guard !cancelled else { throw CancellationError() }
    guard writer.status == .completed else { throw writer.error ?? SceneRenderError.snapshotPending("video_encoding") }
  }
  func cancel() { cancelled = true; writer?.cancelWriting() }

  private nonisolated static func pixelBuffer(_ image: CGImage, attributes: CVPixelBufferCreationAttributes, height: Int) throws -> CVReadOnlyPixelBuffer {
    try Task.checkCancellation()
    let buffer = try CVMutablePixelBuffer(attributes)
    try buffer.withUnsafeBuffer { value in
      guard CVPixelBufferLockBaseAddress(value, []) == kCVReturnSuccess else { throw SceneRenderError.resourceLimit }
      defer { CVPixelBufferUnlockBaseAddress(value, []) }
      guard let context = CGContext(data: CVPixelBufferGetBaseAddress(value), width: image.width, height: height,
        bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(value), space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else { throw SceneRenderError.resourceLimit }
      context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: image.width, height: height))
      context.draw(image, in: CGRect(x: 0, y: height-image.height, width: image.width, height: image.height))
    }
    return CVReadOnlyPixelBuffer(buffer)
  }
}
#endif

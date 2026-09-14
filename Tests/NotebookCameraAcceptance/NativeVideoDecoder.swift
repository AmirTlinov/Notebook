import Foundation
import AVFoundation
import CoreVideo

/// Offline decode only. AVFoundation owns chroma positioning and color conversion;
/// no camera coordinates, resampling, image shifts, or error thresholds enter here.
@main struct NativeVideoDecoder {
  static let output = FileHandle.standardOutput

  static func record(_ value: [String: Any]) throws {
    let json = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    var length = UInt32(json.count).bigEndian
    try withUnsafeBytes(of: &length) { try output.write(contentsOf: Data($0)) }
    try output.write(contentsOf: json)
  }

  static func colorMetadata(_ pixel: CVPixelBuffer) -> [String: String] {
    let keys: [(String, CFString)] = [
      ("primaries", kCVImageBufferColorPrimariesKey),
      ("transferFunction", kCVImageBufferTransferFunctionKey),
      ("yCbCrMatrix", kCVImageBufferYCbCrMatrixKey),
      ("chromaLocationTopField", kCVImageBufferChromaLocationTopFieldKey),
      ("chromaLocationBottomField", kCVImageBufferChromaLocationBottomFieldKey),
    ]
    return Dictionary(uniqueKeysWithValues: keys.compactMap { name, key in
      guard let value = CVBufferCopyAttachment(pixel, key, nil) else { return nil }
      return (name, String(describing: value))
    })
  }

  static func run() async throws {
    guard CommandLine.arguments.count == 2 else { throw Failure("Expected one source video path") }
    let asset = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[1]))
    let tracks = try await asset.loadTracks(withMediaType: .video)
    guard tracks.count == 1 else { throw Failure("Expected exactly one video track") }
    let track = tracks[0]
    let naturalSize = try await track.load(.naturalSize)
    let transform = try await track.load(.preferredTransform)
    guard transform == .identity else { throw Failure("Rotated/transformed video is not a raw device-pixel recording") }
    try output.write(contentsOf: Data("NBAVR001".utf8))
    try record(["kind": "header", "protocol": 1, "decoder": "AVAssetReaderTrackOutput",
      "width": Int(naturalSize.width), "height": Int(naturalSize.height),
      "preferredTransform": [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty],
      "pixelFormat": "BGRA", "colorConversion": "AVFoundation; source attachments retained"])
    let reader = try AVAssetReader(asset: asset)
    let trackOutput = AVAssetReaderTrackOutput(track: track,
      outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(trackOutput)
    guard reader.startReading() else { throw reader.error ?? Failure("Reader did not start") }
    var index = 0
    while let sample = trackOutput.copyNextSampleBuffer() {
      guard let pixel = CMSampleBufferGetImageBuffer(sample) else { throw Failure("Missing decoded image") }
      let pts = CMSampleBufferGetPresentationTimeStamp(sample)
      guard pts.isNumeric, pts.timescale > 0, CVPixelBufferGetPixelFormatType(pixel) == kCVPixelFormatType_32BGRA else {
        throw Failure("Invalid presentation timestamp or decoded pixel format")
      }
      CVPixelBufferLockBaseAddress(pixel, .readOnly)
      defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
      let width = CVPixelBufferGetWidth(pixel), height = CVPixelBufferGetHeight(pixel)
      let stride = CVPixelBufferGetBytesPerRow(pixel)
      guard width == Int(naturalSize.width), height == Int(naturalSize.height), stride >= width * 4,
        let address = CVPixelBufferGetBaseAddress(pixel) else { throw Failure("Unexpected decoded geometry") }
      try record(["kind": "frame", "index": index, "ptsValue": pts.value, "ptsTimescale": pts.timescale,
        "width": width, "height": height, "bytesPerRow": stride, "payloadBytes": stride * height,
        "pixelFormat": "BGRA", "colorMetadata": colorMetadata(pixel)])
      try output.write(contentsOf: Data(bytesNoCopy: address, count: stride * height, deallocator: .none))
      index += 1
    }
    guard reader.status == .completed else { throw reader.error ?? Failure("Reader did not complete") }
    try record(["kind": "end", "frames": index, "status": "completed"])
  }

  static func main() async {
    do { try await run() }
    catch {
      try? FileHandle.standardError.write(contentsOf: Data("NativeVideoDecoder: \(error)\n".utf8))
      exit(1)
    }
  }

  struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
  }
}

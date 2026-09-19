import Foundation
import CoreGraphics

/// Quartz writes directly into a capped sink. Checking the final Data length
/// would allow an oversized PDF to allocate before the limit was noticed.
public final class NotebookPDFBuffer {
  private var bytes = Data()
  private var rejected = false
  private let limit: Int
  public init(limit: Int) { self.limit = limit }
  public func consumer() -> CGDataConsumer? {
    var callbacks = CGDataConsumerCallbacks(putBytes: { info, buffer, count in
      guard let info else { return 0 }
      let sink = Unmanaged<NotebookPDFBuffer>.fromOpaque(info).takeUnretainedValue()
      guard !sink.rejected, count <= sink.limit-sink.bytes.count else { sink.rejected = true; return 0 }
      sink.bytes.append(buffer.assumingMemoryBound(to: UInt8.self), count: count)
      return count
    }, releaseConsumer: { info in
      if let info { Unmanaged<NotebookPDFBuffer>.fromOpaque(info).release() }
    })
    let retained = Unmanaged.passRetained(self)
    guard let consumer = CGDataConsumer(info: retained.toOpaque(), cbks: &callbacks) else { retained.release(); return nil }
    return consumer
  }
  public func result() throws -> Data {
    guard !rejected, bytes.starts(with: Data("%PDF-".utf8)) else { throw NotebookTypesetterError("print_output_limit") }
    return bytes
  }
}

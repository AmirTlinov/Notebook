import Foundation
import Testing
@testable import NotebookCore

@Test("Любое содержимое полного blob chunk укладывается в transport frame", arguments: [UInt8(0), 0xfe, 0xff])
func fullBlobChunkFitsTheTransportFrame(byte: UInt8) throws {
  let data = Data(repeating: byte, count: NotebookTransportLimits.maximumChunkBytes)
  let packet = NotebookTransportPacket(sequence: UInt64.max, message: .blob(.init(
    hash: String(repeating: "f", count: 64), offset: NotebookTransportLimits.maximumBlobBytes - Int64(data.count),
    totalBytes: NotebookTransportLimits.maximumBlobBytes, data: data)))
  let frame = try NotebookTransportFraming.encode(packet)
  #expect(frame.count <= NotebookTransportLimits.maximumFrameBytes)
  #expect(try NotebookTransportFraming.payloadLength(Data(frame.prefix(4))) == frame.count - 4)
  #expect(try NotebookTransportFraming.decode(Data(frame.dropFirst(4))) == packet)
}

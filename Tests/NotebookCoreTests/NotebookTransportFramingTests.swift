import Foundation
import Testing
@testable import NotebookCore

@Test("Любое содержимое полного blob window укладывается в transport frame", arguments: [UInt8(0), 0xfe, 0xff])
func fullBlobWindowFitsTheTransportFrame(byte: UInt8) throws {
  let data = Data(repeating: byte, count: NotebookTransportLimits.maximumChunkBytes)
  let chunks: [NotebookTransportBlobChunk] = [
    .init(hash: String(repeating: "f", count: 64), offset: NotebookTransportLimits.maximumBlobBytes - Int64(data.count),
      totalBytes: NotebookTransportLimits.maximumBlobBytes, data: data),
    .init(hash: String(repeating: "e", count: 64), offset: 0, totalBytes: Int64(data.count), data: data)]
  try NotebookTransportBlobWindow.validate(chunks, for: chunks.map { .init(hash: $0.hash, offset: $0.offset) })
  let packet = NotebookTransportPacket(sequence: UInt64.max, message: .blobs(chunks))
  let frame = try NotebookTransportFraming.encode(packet)
  #expect(frame.count <= NotebookTransportLimits.maximumFrameBytes)
  #expect(try NotebookTransportFraming.payloadLength(Data(frame.prefix(4))) == frame.count - 4)
  #expect(try NotebookTransportFraming.decode(Data(frame.dropFirst(4))) == packet)
}

@Suite struct NotebookTransportBlobWindowTests {
  private let a = String(repeating: "a", count: 64), b = String(repeating: "b", count: 64)
  private let c = String(repeating: "c", count: 64)

  @Test func requestsHaveOnePartialHeadAndNoDuplicatesOrUnboundedOffsets() throws {
    try NotebookTransportBlobWindow.validate([.init(hash: a, offset: 32_768), .init(hash: b)])
    let invalid: [[NotebookTransportBlobRequest]] = [[], [.init(hash: "bad")],
      [.init(hash: a), .init(hash: a)], [.init(hash: a, offset: -1)],
      [.init(hash: a, offset: Int64.max)], [.init(hash: a, offset: NotebookTransportLimits.maximumBlobBytes)],
      [.init(hash: a), .init(hash: b, offset: 1)],
      (0..<17).map { .init(hash: String(format: "%064x", $0)) }]
    for requests in invalid {
      #expect(throws: NotebookTransportError.unexpectedBlob) { try NotebookTransportBlobWindow.validate(requests) }
    }
  }

  @Test func responseIsANonemptyOrderedPrefixWithOnlyItsLastChunkPartial() throws {
    let requests: [NotebookTransportBlobRequest] = [.init(hash: a), .init(hash: b), .init(hash: c)]
    let first = chunk(a), second = chunk(b)
    try NotebookTransportBlobWindow.validate([first], for: requests)
    try NotebookTransportBlobWindow.validate([first, .init(hash: b, offset: 0, totalBytes: 10, data: Data([2]))], for: requests)
    try NotebookTransportBlobWindow.validate([.init(hash: a, offset: 0, totalBytes: 0, data: Data())], for: requests)
    for response in [[], [second], [first, first], [second, first], [first, chunk(c)],
      [.init(hash: a, offset: 1, totalBytes: 2, data: Data([1]))]] as [[NotebookTransportBlobChunk]] {
      #expect(throws: NotebookTransportError.unexpectedBlob) { try NotebookTransportBlobWindow.validate(response, for: requests) }
    }
    let invalid: [[NotebookTransportBlobChunk]] = [
      [.init(hash: a, offset: 0, totalBytes: 2, data: Data([1])), second],
      [.init(hash: a, offset: 0, totalBytes: -1, data: Data())],
      [.init(hash: a, offset: 0, totalBytes: NotebookTransportLimits.maximumBlobBytes + 1, data: Data([1]))],
      [.init(hash: a, offset: 0, totalBytes: 1, data: Data())],
      [.init(hash: a, offset: 0, totalBytes: 1, data: Data([1, 2]))],
      [chunk(a, bytes: 32_769)],
      [chunk(a, bytes: 32_768), chunk(b, bytes: 32_768), chunk(c)]]
    for response in invalid {
      #expect(throws: NotebookTransportError.invalidBlob) { try NotebookTransportBlobWindow.validate(response, for: requests) }
    }
  }

  private func chunk(_ hash: String, bytes: Int = 1) -> NotebookTransportBlobChunk {
    .init(hash: hash, offset: 0, totalBytes: Int64(bytes), data: Data(repeating: 1, count: bytes))
  }
}

@Suite struct NotebookHistoryResumeFramingTests {
  @Test func terminalRefusalRoundTripsOnlyBoundedTypedMetadata() throws {
    let source = NotebookReplicationSource(deviceID: UUID(), generation: UUID())
    let refusal = NotebookHistoryControl.Refusal(origin: source, code: .resourceLimit, reason: .resourceLimit,
      stage: .reading, sourceSection: .acceptedPhysicalHistory, transactionID: UUID(), identifier: "read_sql_work")
    for failure in [nil, refusal] as [NotebookHistoryControl.Refusal?] {
      let packet = NotebookTransportPacket(sequence: 3,
        message: .historyReadiness(.resume(requestID: UUID(), refusal: failure)))
      let frame = try NotebookTransportFraming.encode(packet)
      #expect(frame.count < 2_048)
      #expect(try NotebookTransportFraming.decode(Data(frame.dropFirst(4))) == packet)
    }
    let bytes = try JSONEncoder().encode(refusal)
    var fields = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    fields["reason"] = "arbitrary private context"
    #expect(throws: DecodingError.self) {
      _ = try JSONDecoder().decode(NotebookHistoryControl.Refusal.self,
        from: JSONSerialization.data(withJSONObject: fields))
    }
  }

  @Test func invalidRefusalContextAndIdentifiersCannotEnterTheTransportFrame() throws {
    let source = NotebookReplicationSource(deviceID: UUID(), generation: UUID())
    let invalid: [NotebookHistoryControl.Refusal] = [
      .init(origin: source, code: .staleCut, reason: .readerChanged, stage: .resuming, transactionID: UUID()),
      .init(origin: source, code: .staleCut, reason: .readerChanged, stage: .comparing, sourceSection: .finalReader),
    ] + ["", "_limit", "9limit", "limit/secret", "private context", "é", String(repeating: "a", count: 81)].map {
      .init(origin: source, code: .resourceLimit, reason: .resourceLimit, stage: .reading, identifier: $0)
    }
    for refusal in invalid {
      let packet = NotebookTransportPacket(sequence: 3,
        message: .historyReadiness(.resume(requestID: UUID(), refusal: refusal)))
      #expect(throws: NotebookTransportError.invalidFrame) { _ = try NotebookTransportFraming.encode(packet) }
      let unadmitted = try JSONEncoder().encode(packet)
      #expect(throws: NotebookTransportError.invalidFrame) { _ = try NotebookTransportFraming.decode(unadmitted) }
    }
  }
}

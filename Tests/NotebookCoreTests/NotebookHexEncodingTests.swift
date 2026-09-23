import CryptoKit
import Foundation
import Testing
@testable import NotebookCore

struct NotebookHexEncodingTests {
  @Test func preservesEveryByteAndNonzeroSliceIndices() {
    let bytes = Data((0...255).map(UInt8.init))
    for data in [Data(), bytes, bytes[9..<173], Data([0, 1, 15, 16, 127, 128, 255])] {
      let expected = data.map { String(format: "%02x", $0) }.joined()
      #expect(NotebookHexEncoding.encode(data) == expected)
      #expect(NotebookHexEncoding.encode(data).utf8.count == data.count * 2)
    }
  }

  @Test func retainsStandardSHA256Identities() {
    for (input, expected) in [
      ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
      ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    ] {
      #expect(NotebookHexEncoding.encode(SHA256.hash(data: Data(input.utf8))) == expected)
    }
  }

  @Test func streamingAndCompleteBlobKeepTheSameAddress() {
    let data = Data((0..<70_000).map { UInt8(truncatingIfNeeded: $0 * 17) })
    let digest = SHA256.hash(data: data)
    let expected = digest.map { String(format: "%02x", $0) }.joined()
    var streaming = SHA256()
    for offset in stride(from: 0, to: data.count, by: 1_021) {
      streaming.update(data: data[offset..<min(data.count, offset + 1_021)])
    }
    #expect(NotebookHexEncoding.encode(digest) == expected)
    #expect(NotebookHexEncoding.encode(streaming.finalize()) == expected)
  }
}

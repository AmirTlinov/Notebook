import Foundation

/// Content-addressed writes and delivery validation encode the same bytes.
/// Avoid 32 Foundation formatters/temporary strings for every SHA-256 digest.
enum NotebookHexEncoding {
  static func encode(_ bytes: some ContiguousBytes) -> String {
    bytes.withUnsafeBytes { source in
      String(unsafeUninitializedCapacity: source.count * 2) { target in
        for (index, byte) in source.enumerated() {
          let high = byte >> 4, low = byte & 15
          target[index * 2] = high + (high < 10 ? 48 : 87)
          target[index * 2 + 1] = low + (low < 10 ? 48 : 87)
        }
        return source.count * 2
      }
    }
  }
}

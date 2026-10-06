import Foundation
import CZlib

/// Bounded ZIP transport for one document. Nothing is extracted to a filesystem;
/// central and local names, extents, CRCs and sizes agree before bytes are used.
enum NotebookDocumentZIP {
  static let maximumBytes = 64*1024*1024
  static let maximumEntries = 8192
  private static let maximumPathBytes = 1024 + "files/".utf8.count
  static let readWindowBytes = 65_536
  static var maximumDirectoryBytes: Int {
    // Entries, their Array growth, path backing, duplicate-name Set, range
    // sort and central/local framing all coexist during directory admission.
    maximumEntries * (MemoryLayout<Entry>.stride * 2 + maximumPathBytes * 4 + 160)
      + 65_557 + readWindowBytes * 2 + 262_144
  }

  struct Entry: Sendable {
    let path: String
    let size: Int
    let packed: Range<Int>
    let extent: Range<Int>
    let method: UInt16
    let checksum: UInt32
  }

  /// One validated directory over an immutable byte source. Native import
  /// borrows a private file; in-memory readers use the same codec and checks.
  struct Archive: Sendable {
    let entries: [Entry]
    let byteCount: Int
    private let byPath: [String: Int]
    private let read: @Sendable (Range<Int>) throws -> Data
    var retainedDirectoryBytes: Int {
      entries.capacity * MemoryLayout<Entry>.stride + byPath.capacity * (MemoryLayout<String>.stride + MemoryLayout<Int>.stride + 32)
        + entries.reduce(0) { $0 + $1.path.utf8.count * 2 + 64 }
    }

    init(byteCount: Int, read: @escaping @Sendable (Range<Int>) throws -> Data) throws {
      guard (22...maximumBytes).contains(byteCount) else { throw invalid("Неверный размер ZIP.") }
      let tailOffset = max(0, byteCount - 65_557), tail = try read(tailOffset..<byteCount)
      guard tail.count == byteCount - tailOffset else { throw invalid("ZIP не завершён.") }
      func u16(_ data: Data, _ offset: Int) -> UInt16 { UInt16(data[offset]) | UInt16(data[offset+1]) << 8 }
      func u32(_ data: Data, _ offset: Int) -> UInt32 { UInt32(u16(data, offset)) | UInt32(u16(data, offset+2)) << 16 }
      guard let end = stride(from: tail.count-22, through: 0, by: -1).first(where: {
        u32(tail, $0) == 0x06054b50 && $0+22+Int(u16(tail, $0+20)) == tail.count
      }) else { throw invalid("ZIP не завершён.") }
      let count = Int(u16(tail, end+10)), centralSize = Int(u32(tail, end+12)), centralOffset = Int(u32(tail, end+16))
      let centralEnd = tailOffset + end
      guard u16(tail, end+4) == 0, u16(tail, end+6) == 0, Int(u16(tail, end+8)) == count,
        count <= maximumEntries, centralOffset <= centralEnd, centralSize == centralEnd-centralOffset else {
        throw invalid("Многотомный или недопустимый ZIP.")
      }
      var cursor = centralOffset, total = 0, entries: [Entry] = [], paths = Set<String>()
      entries.reserveCapacity(count)
      for _ in 0..<count {
        try Task.checkCancellation()
        guard cursor+46 <= centralEnd else { throw invalid("Повреждён каталог ZIP.") }
        let header = try read(cursor..<cursor+46)
        guard header.count == 46, u32(header, 0) == 0x02014b50 else { throw invalid("Повреждён каталог ZIP.") }
        let version = u16(header, 6), flags = u16(header, 8), method = u16(header, 10), hash = u32(header, 16)
        let compressed = Int(u32(header, 20)), size = Int(u32(header, 24))
        let nameCount = Int(u16(header, 28)), extra = Int(u16(header, 30)), comment = Int(u16(header, 32))
        let local = Int(u32(header, 42)), mode = u32(header, 38) >> 16
        guard version <= 20, flags & ~UInt16(0x0808) == 0, [UInt16(0), 8].contains(method), u16(header, 34) == 0,
          mode & 0o170000 != 0o120000, nameCount <= maximumPathBytes,
          cursor+46+nameCount+extra+comment <= centralEnd, local+30 <= centralOffset,
          size <= maximumBytes-total, compressed <= maximumBytes else {
          throw invalid("ZIP содержит неподдерживаемый или слишком большой файл.")
        }
        let name = try read(cursor+46..<cursor+46+nameCount), localHeader = try read(local..<local+30)
        guard name.count == nameCount, let path = String(data: name, encoding: .utf8), validPath(path), paths.insert(path).inserted,
          localHeader.count == 30, u32(localHeader, 0) == 0x04034b50, u16(localHeader, 6) == flags,
          u16(localHeader, 8) == method, Int(u16(localHeader, 26)) == nameCount else {
          throw invalid("Неверный или повторный путь ZIP.")
        }
        let start = local+30+nameCount+Int(u16(localHeader, 28)), stop = start+compressed
        guard start <= centralOffset, stop <= centralOffset,
          try read(local+30..<local+30+nameCount) == name else { throw invalid("Имя или границы ZIP не совпадают.") }
        var localEnd = stop
        if flags & 8 == 0 {
          guard u32(localHeader, 14) == hash, Int(u32(localHeader, 18)) == compressed,
            Int(u32(localHeader, 22)) == size else { throw invalid("Размеры ZIP не совпадают.") }
        } else {
          guard stop+12 <= centralOffset else { throw invalid("Неверный data descriptor ZIP.") }
          let prefix = try read(stop..<min(stop+16, centralOffset))
          let descriptor = u32(prefix, 0) == 0x08074b50 ? 4 : 0
          guard prefix.count >= descriptor+12, u32(prefix, descriptor) == hash,
            Int(u32(prefix, descriptor+4)) == compressed, Int(u32(prefix, descriptor+8)) == size else {
            throw invalid("Неверный data descriptor ZIP.")
          }
          localEnd = stop+descriptor+12
        }
        guard method != 0 || compressed == size else { throw invalid("Неверный размер stored ZIP.") }
        entries.append(.init(path: path, size: size, packed: start..<stop, extent: local..<localEnd,
          method: method, checksum: hash))
        total += size; cursor += 46+nameCount+extra+comment
      }
      guard cursor == centralEnd else { throw invalid("Лишние записи каталога ZIP.") }
      let ordered = entries.sorted { $0.extent.lowerBound < $1.extent.lowerBound }
      guard zip(ordered, ordered.dropFirst()).allSatisfy({ $0.extent.upperBound <= $1.extent.lowerBound }) else {
        throw invalid("Файлы ZIP пересекаются.")
      }
      self.entries = entries; self.byteCount = byteCount; self.read = read
      byPath = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($0.element.path, $0.offset) })
    }

    init(data: Data) throws {
      try self.init(byteCount: data.count) { range in data.subdata(in: range) }
    }

    func entry(_ path: String) -> Entry? { byPath[path].map { entries[$0] } }

    func data(_ entry: Entry, maximumBytes: Int) throws -> Data {
      guard entry.size <= maximumBytes else { throw CollaborationError("resource_limit", "Часть документа превышает резерв подготовки.") }
      var data = Data(); data.reserveCapacity(entry.size)
      try consume(entry) { data.append($0) }
      return data
    }

    /// Inflated output never exceeds one window. CRC and exact input/output
    /// extents are checked even for optional cache entries which are discarded.
    func consume(_ entry: Entry, _ consume: (Data) throws -> Void) throws {
      var checksum = UInt32(0), emitted = 0
      func emit(_ data: Data) throws {
        guard data.count <= entry.size - emitted else { throw invalid("Неверный поток deflate.") }
        checksum = data.withUnsafeBytes { UInt32(crc32(uLong(checksum), $0.bindMemory(to: UInt8.self).baseAddress, uInt(data.count))) }
        emitted += data.count; try consume(data)
      }
      if entry.method == 0 {
        var offset = entry.packed.lowerBound
        while offset < entry.packed.upperBound {
          try Task.checkCancellation()
          let end = min(offset+readWindowBytes, entry.packed.upperBound), data = try read(offset..<end)
          guard data.count == end-offset else { throw invalid("Неверный размер stored ZIP.") }
          try emit(data); offset = end
        }
      } else {
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
          throw invalid("Не удалось открыть deflate.")
        }
        defer { inflateEnd(&stream) }
        var offset = entry.packed.lowerBound, ended = false
        while offset < entry.packed.upperBound && !ended {
          try Task.checkCancellation()
          let end = min(offset+readWindowBytes, entry.packed.upperBound), input = try read(offset..<end)
          guard input.count == end-offset else { throw invalid("Неверный поток deflate.") }
          try input.withUnsafeBytes { bytes in
            stream.next_in = UnsafeMutablePointer(mutating: bytes.bindMemory(to: UInt8.self).baseAddress)
            stream.avail_in = uInt(input.count)
            repeat {
              try Task.checkCancellation()
              var output = Data(count: readWindowBytes)
              let result = output.withUnsafeMutableBytes { target in
                stream.next_out = target.bindMemory(to: UInt8.self).baseAddress; stream.avail_out = uInt(target.count)
                return CZlib.inflate(&stream, Z_NO_FLUSH)
              }
              guard result == Z_OK || result == Z_STREAM_END else { throw invalid("Неверный поток deflate.") }
              output.count = readWindowBytes-Int(stream.avail_out); try emit(output)
              if result == Z_STREAM_END { ended = true; break }
            } while stream.avail_in > 0 || stream.avail_out == 0
          }
          offset = end
        }
        guard ended, stream.total_in == entry.packed.count, stream.total_out == entry.size else {
          throw invalid("Неверный поток deflate.")
        }
      }
      guard emitted == entry.size, checksum == entry.checksum else { throw invalid("Контрольная сумма ZIP не совпадает.") }
    }
  }
  static func isWithinSizeBudget(_ files: [String: Data]) -> Bool {
    guard files.count <= maximumEntries else { return false }
    var remaining = maximumBytes-22
    for (path, bytes) in files {
      let headers = 76+2*path.utf8.count
      guard headers <= remaining, bytes.count <= remaining-headers else { return false }
      remaining -= headers+bytes.count
    }
    return true
  }
  static func encode(_ files: [String: Data]) throws -> Data {
    guard isWithinSizeBudget(files) else { throw CollaborationError("resource_limit", "Размер архива превышает 64 МиБ.") }
    var output = Data(), central = Data()
    for path in files.keys.sorted() {
      try Task.checkCancellation()
      guard validPath(path), let bytes = files[path] else { throw invalid("Неверный путь файла.") }
      let name = Data(path.utf8), hash = crc(bytes), offset = output.count
      output.append32(0x04034b50); output.append16(20); output.append16(0x0800); output.append16(0)
      output.append16(0); output.append16(0); output.append32(hash)
      output.append32(UInt32(bytes.count)); output.append32(UInt32(bytes.count)); output.append16(UInt16(name.count)); output.append16(0)
      output.append(name); output.append(bytes)
      central.append32(0x02014b50); central.append16(0x0314); central.append16(20); central.append16(0x0800); central.append16(0)
      central.append16(0); central.append16(0); central.append32(hash)
      central.append32(UInt32(bytes.count)); central.append32(UInt32(bytes.count)); central.append16(UInt16(name.count))
      central.append16(0); central.append16(0); central.append16(0); central.append16(0)
      central.append32(0o100600 << 16); central.append32(UInt32(offset)); central.append(name)
    }
    let offset = output.count
    output.append(central); output.append32(0x06054b50); output.append16(0); output.append16(0)
    output.append16(UInt16(files.count)); output.append16(UInt16(files.count))
    output.append32(UInt32(central.count)); output.append32(UInt32(offset)); output.append16(0)
    guard output.count <= maximumBytes else { throw invalid("Размер архива превышен.") }
    return output
  }
  static func decode(_ data: Data) throws -> [String: Data] {
    let archive = try Archive(data: data)
    var files: [String: Data] = [:]
    for entry in archive.entries { files[entry.path] = try archive.data(entry, maximumBytes: maximumBytes) }
    return files
  }
  private static func crc(_ data: Data) -> UInt32 {
    data.withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, uInt(data.count))) }
  }
  private static func validPath(_ path: String) -> Bool {
    !path.isEmpty && path.utf8.count <= maximumPathBytes && !path.contains("\\") && !path.contains("\0")
      && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
  }
  private static func invalid(_ reason: String) -> CollaborationError { .init("invalid_portable_document", reason) }
}
private extension Data {
  mutating func append16(_ number: UInt16) { var value = number.littleEndian; Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) } }
  mutating func append32(_ number: UInt32) { var value = number.littleEndian; Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) } }
}

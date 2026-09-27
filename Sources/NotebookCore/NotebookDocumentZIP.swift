import Foundation
import CZlib

/// Bounded ZIP transport for one document. Nothing is extracted to a filesystem;
/// central and local names, extents, CRCs and sizes agree before bytes are used.
enum NotebookDocumentZIP {
  static let maximumBytes = 64*1024*1024
  static let maximumEntries = 8192
  private static let maximumPathBytes = 1024 + "files/".utf8.count
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
  static func decode(_ archive: Data) throws -> [String: Data] {
    guard (22...maximumBytes).contains(archive.count) else { throw invalid("Неверный размер ZIP.") }
    let data = Data(archive)
    func u16(_ offset: Int) -> UInt16 { UInt16(data[offset]) | UInt16(data[offset+1]) << 8 }
    func u32(_ offset: Int) -> UInt32 { UInt32(u16(offset)) | UInt32(u16(offset+2)) << 16 }
    guard let end = stride(from: data.count-22, through: max(0, data.count-65_557), by: -1).first(where: {
      u32($0) == 0x06054b50 && $0+22+Int(u16($0+20)) == data.count
    }) else { throw invalid("ZIP не завершён.") }
    let count = Int(u16(end+10)), centralSize = Int(u32(end+12)), centralOffset = Int(u32(end+16))
    guard u16(end+4) == 0, u16(end+6) == 0, Int(u16(end+8)) == count, count <= maximumEntries,
      centralOffset <= end, centralSize == end-centralOffset else { throw invalid("Многотомный или недопустимый ZIP.") }
    var cursor = centralOffset, total = 0, files: [String: Data] = [:], ranges: [Range<Int>] = []
    for _ in 0..<count {
      try Task.checkCancellation()
      guard cursor+46 <= end, u32(cursor) == 0x02014b50 else { throw invalid("Повреждён каталог ZIP.") }
      let version = u16(cursor+6), flags = u16(cursor+8), method = u16(cursor+10), hash = u32(cursor+16)
      let compressed = Int(u32(cursor+20)), size = Int(u32(cursor+24))
      let nameCount = Int(u16(cursor+28)), extra = Int(u16(cursor+30)), comment = Int(u16(cursor+32))
      let local = Int(u32(cursor+42)), mode = u32(cursor+38) >> 16
      guard version <= 20, flags & ~UInt16(0x0808) == 0, [UInt16(0), 8].contains(method), u16(cursor+34) == 0,
        mode & 0o170000 != 0o120000, nameCount <= maximumPathBytes,
        cursor+46+nameCount+extra+comment <= end, local+30 <= centralOffset,
        size <= maximumBytes-total, compressed <= maximumBytes else { throw invalid("ZIP содержит неподдерживаемый или слишком большой файл.") }
      let name = data.subdata(in: cursor+46..<cursor+46+nameCount)
      guard let path = String(data: name, encoding: .utf8), validPath(path), files[path] == nil,
        u32(local) == 0x04034b50, u16(local+6) == flags, u16(local+8) == method,
        Int(u16(local+26)) == nameCount else { throw invalid("Неверный или повторный путь ZIP.") }
      let start = local+30+nameCount+Int(u16(local+28)), stop = start+compressed
      guard start <= centralOffset, stop <= centralOffset,
        data.subdata(in: local+30..<local+30+nameCount) == name else { throw invalid("Имя или границы ZIP не совпадают.") }
      var localEnd = stop
      if flags & 8 == 0 {
        guard u32(local+14) == hash, Int(u32(local+18)) == compressed, Int(u32(local+22)) == size else { throw invalid("Размеры ZIP не совпадают.") }
      } else {
        let descriptor = stop+4 <= centralOffset && u32(stop) == 0x08074b50 ? stop+4 : stop
        guard descriptor+12 <= centralOffset, u32(descriptor) == hash,
          Int(u32(descriptor+4)) == compressed, Int(u32(descriptor+8)) == size else { throw invalid("Неверный data descriptor ZIP.") }
        localEnd = descriptor+12
      }
      let packed = data.subdata(in: start..<stop)
      let bytes: Data
      if method == 0 {
        guard compressed == size else { throw invalid("Неверный размер stored ZIP.") }; bytes = packed
      } else { bytes = try inflate(packed, size: size) }
      guard crc(bytes) == hash else { throw invalid("Контрольная сумма ZIP не совпадает.") }
      files[path] = bytes; total += size; ranges.append(local..<localEnd)
      cursor += 46+nameCount+extra+comment
    }
    guard cursor == end else { throw invalid("Лишние записи каталога ZIP.") }
    let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
    guard zip(sorted, sorted.dropFirst()).allSatisfy({ $0.upperBound <= $1.lowerBound }) else { throw invalid("Файлы ZIP пересекаются.") }
    return files
  }
  private static func inflate(_ source: Data, size: Int) throws -> Data {
    var stream = z_stream()
    guard inflateInit2_(&stream, -MAX_WBITS, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw invalid("Не удалось открыть deflate.") }
    defer { inflateEnd(&stream) }
    var output = Data(count: max(1, size))
    let status: Int32 = source.withUnsafeBytes { input in output.withUnsafeMutableBytes { target in
      stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: UInt8.self).baseAddress)
      stream.avail_in = uInt(source.count)
      stream.next_out = target.bindMemory(to: UInt8.self).baseAddress; stream.avail_out = uInt(target.count)
      return CZlib.inflate(&stream, Z_FINISH)
    } }
    guard status == Z_STREAM_END, stream.total_in == source.count, stream.total_out == size else { throw invalid("Неверный поток deflate.") }
    output.count = size; return output
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

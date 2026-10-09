import Foundation

/// Admission precedes Foundation's JSON map and the decoded Swift containers.
/// This scan allocates no value tree and leaves syntax validation to the decoder.
public enum NotebookJSONAdmission {
  static let maximumDepth = 256
  public static func allocationCost(_ data:Data,maximumBytes:Int, observesCancellation:Bool = true) throws -> Int {
    guard maximumBytes >= 0,data.count <= maximumBytes/8 else {
      throw NotebookStorageError.limitExceeded("json_decode_memory")
    }
    var cost=data.count*8,depth=0,inString=false,escaped=false,inScalar=false
    try data.withUnsafeBytes { (bytes:UnsafeRawBufferPointer) in
      var index=0
      while index < bytes.count {
        if observesCancellation && index & 4095 == 0 { try Task.checkCancellation() }
        let byte=bytes[index]
        index += 1
        if inString {
          if escaped { escaped=false }
          else if byte == 92 { escaped=true }
          else if byte == 34 { inString=false }
          continue
        }
        switch byte {
        case 34:
          inString=true;inScalar=false
        case 91,123:
          depth += 1;inScalar=false
          guard depth <= maximumDepth else { throw NotebookStorageError.limitExceeded("json_decode_depth") }
        case 93,125:
          depth -= 1;inScalar=false;continue
        case 9,10,13,32,44,58:
          inScalar=false;continue
        default:
          if inScalar { continue };inScalar=true
        }
        // Includes the Foundation token map, both transient decodings of a
        // stored envelope, collection capacity, keys, and Swift value headers.
        guard cost <= maximumBytes-512 else { throw NotebookStorageError.limitExceeded("json_decode_memory") }
        cost += 512
      }
    }
    return cost
  }
}

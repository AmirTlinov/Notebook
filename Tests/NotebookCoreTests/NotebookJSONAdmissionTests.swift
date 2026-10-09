import Foundation
import Testing
@testable import NotebookCore

@Suite("JSON decoding is admitted before value allocation")
struct NotebookJSONAdmissionTests {
  @Test func smallWireCanExceedItsDecodedAllowance() throws {
    let data=Data(("["+Array(repeating:"0",count:2_000).joined(separator:",")+"]").utf8)
    #expect(data.count < 8_192)
    #expect(throws:NotebookStorageError.self) {
      try NotebookJSONAdmission.allocationCost(data,maximumBytes:65_536)
    }
    let escaped=Data(#"{"source":"Пример 🖋️ [0,0] \"\\\/\u0001"}"#.utf8)
    // Object, key and value: brackets and escapes inside the value are text.
    let exact=escaped.count*8+3*512
    #expect(try NotebookJSONAdmission.allocationCost(escaped,maximumBytes:exact) == exact)
    #expect(try NotebookJSONAdmission.allocationCost(escaped,maximumBytes:Int.max) == exact)
    #expect(throws:NotebookStorageError.self) {
      try NotebookJSONAdmission.allocationCost(escaped,maximumBytes:exact-1)
    }
    #expect(try NotebookJSONAdmission.allocationCost(Data(),maximumBytes:0) == 0)
    #expect(throws:NotebookStorageError.self) {
      try NotebookJSONAdmission.allocationCost(Data(),maximumBytes:-1)
    }
  }

  @Test func cancelledReaderStopsTheScanAndAnAcceptedWriterCanFinish() async throws {
    let data=Data(("\""+String(repeating:"Пример ",count:2_000)+"\"").utf8)
    let exact=data.count*8+512
    try await Task.detached { () throws -> Void in
      withUnsafeCurrentTask { $0?.cancel() }
      #expect(throws:CancellationError.self) {
        try NotebookJSONAdmission.allocationCost(data,maximumBytes:exact)
      }
      #expect(try NotebookJSONAdmission.allocationCost(data,maximumBytes:exact,observesCancellation:false) == exact)
    }.value
  }

  @Test func aCaughtDecodeRefusalStillVetoesTheSourceCut() throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("json-lease-\(UUID())")
    defer { try? FileManager.default.removeItem(at:root) }
    let store=NotebookStore(root:root)
    _ = try store.initializeWorkspace(actor:UUID(),pageSize:.init(width:834,height:1194))
    let row=NotebookStoredFragment(address:"test.json#",file:"test.json",parent:nil,collection:"",member:"",
      position:0,value:.array(Array(repeating:.number(0),count:2_000)),collections:[])
    let data=try JSONEncoder().encode(row)
    #expect(throws:NotebookStorageError.self) {
      try store.readTransaction { _ in
        let sql=try #require(store.currentSQL)
        try sql.limitReads(.init(rows:8,bytes:65_536,valueBytes:65_536,reason:"source_memory",jsonDecodeBytes:65_536))
        do { _ = try sql.decodeFragmentEnvelope(data);Issue.record("Unadmitted source decoded") }
        catch {}
      }
    }
  }
}

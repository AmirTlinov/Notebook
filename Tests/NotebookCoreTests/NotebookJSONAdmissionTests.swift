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
    #expect(try NotebookJSONAdmission.allocationCost(Data("{\"source\":\"[0,0]\\\"\"}".utf8),maximumBytes:65_536) < 65_536)
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

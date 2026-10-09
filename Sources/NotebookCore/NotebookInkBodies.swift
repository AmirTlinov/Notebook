import Foundation
import CryptoKit

/// Durable references use the existing immutable blob store. Revision belongs
/// to the occurrence, not to the exact body shared by independent contacts.
private struct NotebookInkBodyReference: Codable {
  let inkBody: String
  let revision: UUID
  func validate() throws {
    guard NotebookPageOrderRegister.validHash(inkBody) else { throw NotebookStorageError.invalidTransaction("ink body hash") }
  }
}

extension NotebookStoredFragment {
  /// The accepted physical envelope stores small NIM1 values inline and large
  /// values by an explicit body reference. Selection proof needs only occurrence
  /// UUIDs: read the 20-byte portable header, never expand a body graph or samples.
  func inkMeasurementRevisions(at paths:[[String]]) throws -> [UUID] {
    let referenced=Set(inkBodies)
    guard referenced.count == inkBodies.count else {throw NotebookStorageError.corruptRecord(address)}
    return try paths.map { path in
      let stored=try value.inkValue(at:path)
      if referenced.contains(path) {
        let reference=try stored.decode(NotebookInkBodyReference.self)
        try reference.validate()
        guard try JSONValue.encode(reference) == stored else {throw NotebookStorageError.corruptRecord(address)}
        return reference.revision
      }
      guard case .string(let text)=stored,
        let header=Data(base64Encoded:String(text.prefix(28))),header.count>=20,
        header.starts(with:Data("NIM1".utf8)) else {throw NotebookStorageError.corruptRecord(address)}
      return try InkStoredBody.revision(in:header)
    }
  }

  var inkBodyHashes: [String] {
    get throws {
      guard Set(inkBodies).count == inkBodies.count else { throw NotebookStorageError.invalidTransaction("duplicate ink body path") }
      return try Set(inkBodies.map { path in
        let reference=try value.inkValue(at:path).decode(NotebookInkBodyReference.self)
        try reference.validate()
        guard try JSONValue.encode(reference) == value.inkValue(at:path) else { throw NotebookStorageError.invalidTransaction("ink body reference") }
        return reference.inkBody
      }).sorted()
    }
  }
}

private extension JSONValue {
  func inkValue(at path: [String]) throws -> JSONValue {
    guard path.count <= 512 else { throw NotebookStorageError.limitExceeded("ink body path") }
    var value=self
    for key in path {
      switch value {
      case .object(let fields):
        guard let child=fields[key] else { throw NotebookStorageError.invalidTransaction("ink body path") };value=child
      case .array(let array):
        guard let index=Int(key),String(index) == key,array.indices.contains(index) else { throw NotebookStorageError.invalidTransaction("ink body path") };value=array[index]
      default: throw NotebookStorageError.invalidTransaction("ink body path")
      }
    }
    return value
  }
  func replacingInk(at path: ArraySlice<String>, with replacement: JSONValue) throws -> JSONValue {
    guard let key=path.first else { return replacement }
    switch self {
    case .object(var fields):
      guard let child=fields[key] else { throw NotebookStorageError.invalidTransaction("ink body path") }
      fields[key]=try child.replacingInk(at:path.dropFirst(),with:replacement);return .object(fields)
    case .array(var array):
      guard let index=Int(key),String(index) == key,array.indices.contains(index) else { throw NotebookStorageError.invalidTransaction("ink body path") }
      array[index]=try array[index].replacingInk(at:path.dropFirst(),with:replacement);return .array(array)
    default: throw NotebookStorageError.invalidTransaction("ink body path")
    }
  }
  /// Replacing a leaf copies only its ancestor containers; retained sibling
  /// values and Strings keep their immutable storage. Admit those buffers
  /// before the recursive COW updates, without building a measuring tree.
  func inkReplacementBytes(at path: [String]) throws -> Int {
    guard path.count <= 512 else { throw NotebookStorageError.limitExceeded("ink body path") }
    var value=self,bytes=0
    func add(_ capacity:Int,_ stride:Int) throws {
      let (payload,overflow)=capacity.multipliedReportingOverflow(by:stride)
      let (withHeader,headerOverflow)=payload.addingReportingOverflow(128)
      let (buffers,bufferOverflow)=withHeader.multipliedReportingOverflow(by:2)
      let (total,totalOverflow)=bytes.addingReportingOverflow(buffers)
      guard !overflow,!headerOverflow,!bufferOverflow,!totalOverflow else {
        throw NotebookStorageError.limitExceeded("json_decode_memory")
      }
      bytes=total
    }
    for key in path {
      switch value {
      case .object(let fields):
        guard let child=fields[key] else { throw NotebookStorageError.invalidTransaction("ink body path") }
        try add(fields.capacity,MemoryLayout<String>.stride+MemoryLayout<JSONValue>.stride+32)
        value=child
      case .array(let values):
        guard let index=Int(key),String(index) == key,values.indices.contains(index) else {
          throw NotebookStorageError.invalidTransaction("ink body path")
        }
        try add(values.capacity,MemoryLayout<JSONValue>.stride);value=values[index]
      default: throw NotebookStorageError.invalidTransaction("ink body path")
      }
    }
    return bytes
  }
}

extension NotebookSQLConnection {
  func encodedStoredFragment(_ fragment: NotebookStoredFragment) throws -> Data {
    guard fragment.inkBodies.isEmpty else { throw NotebookStorageError.invalidTransaction("unresolved ink body write") }
    var paths:[[String]]=[],expandedBytes=0
    func visit(_ value: JSONValue, path: [String]) throws -> JSONValue {
      switch value {
      case .object(let fields):
        var next=fields
        for key in fields.keys.sorted() {
          let count=paths.count,child=try visit(fields[key]!,path:path+[key])
          if paths.count != count { next[key]=child }
        }
        return .object(next)
      case .array(let values):
        var next=values
        for i in values.indices {
          let count=paths.count,child=try visit(values[i],path:path+[String(i)])
          if paths.count != count { next[i]=child }
        }
        return .array(next)
      case .string(let text):
        // Canonical portable ink can also occur in a receipt or undo payload.
        // Explicit physical paths prevent arbitrary user objects with the same
        // keys from ever being interpreted as references on read.
        guard path.count <= 512,text.hasPrefix("TklNM"),text.utf8.count > 1368,
          let encoded=Data(base64Encoded:text),encoded.starts(with:Data("NIM1".utf8)),encoded.count > 1024,
          encoded.base64EncodedString() == text else { return value }
        let body=encoded.dropFirst(20),hash:String
        if let found=inkDecoding.storedOutput(body) { hash=found }
        else {
          guard let plan=try? InkStoredBody.Plan(encoded) else { return value }
          hash=try plan.write { bytes in
            let hash=try putBlob(bytes)
            // Hash equality alone must not merge different bytes.
            guard try !rows("SELECT 1 FROM blobs WHERE hash=? AND data=?",[.text(hash),.blob(bytes)]).isEmpty else {
              throw NotebookStorageError.blobHashMismatch
            }
            return hash
          }
          inkDecoding.retainStoredOutput(body,hash:hash)
        }
        let reference=try JSONValue.encode(NotebookInkBodyReference(inkBody:hash,revision:InkStoredBody.revision(in:encoded)))
        expandedBytes += text.utf8.count+2-(try NotebookStore.storageEncoder.encode(reference).count)
        guard expandedBytes <= 256*1024*1024 else { throw NotebookStorageError.limitExceeded("blob_too_large") }
        paths.append(path);return reference
      default: return value
      }
    }
    let value=try visit(fragment.value,path:[])
    let stored=NotebookStoredFragment(address:fragment.address,file:fragment.file,parent:fragment.parent,
      collection:fragment.collection,member:fragment.member,position:fragment.position,value:value,collections:fragment.collections,inkBodies:paths)
    let data=try NotebookStore.storageEncoder.encode(stored)
    guard data.count+expandedBytes <= 256*1024*1024 else { throw NotebookStorageError.limitExceeded("blob_too_large") }
    return data
  }

  func decodedStoredFragment(from data: Data, remainingBytes: inout Int64, budget: String,
    expandingInk:Bool = true) throws -> NotebookStoredFragment {
    let raw=try decodeFragmentEnvelope(data)
    return try expandedStoredFragment(raw, encodedBytes: data.count, remainingBytes: &remainingBytes,
      budget: budget, expandingInk: expandingInk)
  }

  /// A typed addressed reader can borrow an already admitted envelope. The
  /// same owner validates and charges every referenced body exactly once.
  func expandedStoredFragment(_ raw: NotebookStoredFragment, encodedBytes: Int,
    remainingBytes: inout Int64, budget: String, expandingInk: Bool = true) throws -> NotebookStoredFragment {
    _=try raw.inkBodyHashes
    var value=raw.value
    for path in raw.inkBodies {
      let stored=try raw.value.inkValue(at:path)
      let reference=try stored.decode(NotebookInkBodyReference.self)
      try reference.validate()
      guard try JSONValue.encode(reference) == stored else { throw NotebookStorageError.invalidTransaction("ink body reference") }
      let accepted=inkDecoding.storedOutputBody(reference.inkBody)
      var root:Data?,graph=false
      var coldFootprint:InkStoredBody.ReadFootprint?
      let portableBytes:Int
      if let accepted { portableBytes=accepted.count+20 }
      else {
        let info=try inkBlobInfo(reference.inkBody)
        if info.header.starts(with:Data("NIB1".utf8)) {
          coldFootprint=try InkStoredBody.readFootprint(info.header,storedBytes:info.count)
        } else {
          root=try inkBlob(reference.inkBody);graph=true
          coldFootprint=try InkStoredBody.readFootprint(root!,storedBytes:info.count)
        }
        portableBytes=coldFootprint!.portableBytes
      }
      // Each referenced body is one bounded value, just like its inline
      // fragment. A receipt may name before/after/request bodies together:
      // it is not one larger measurement. The total command lease still pays
      // EVERY expansion, even repeated references already in this cache.
      let (rounded,roundOverflow)=portableBytes.addingReportingOverflow(2)
      let (base64Bytes,base64Overflow)=(rounded/3).multipliedReportingOverflow(by:4)
      let (valueBytes,valueOverflow)=encodedBytes.addingReportingOverflow(base64Bytes)
      guard portableBytes >= 0,!roundOverflow,!base64Overflow,!valueOverflow else {
        throw NotebookStorageError.limitExceeded(budget)
      }
      let expanded=Int64(base64Bytes)
      guard expanded <= remainingBytes else { throw NotebookStorageError.limitExceeded(budget) }
      remainingBytes -= expanded
      try admitExpandedRead(bytes:expandingInk ? base64Bytes : 0,valueBytes:valueBytes)
      // Provenance visits need authenticated record envelopes, not another
      // base64 copy of paint. Still validate cold bodies with the same codec;
      // only this connection's already accepted graph may skip that work.
      if !expandingInk,accepted != nil { continue }
      // Cold work retains physical parts, portable output, decoded literal or
      // field payloads and cache keys. Pay actual codec nodes separately from
      // those binary buffers. A validated warm body only restores its revision;
      // it creates neither graph parts nor another measurement tree.
      func allocation(_ bytes:Int,_ multiplier:Int,_ overhead:Int) throws -> Int {
        let (scaled,scaleOverflow)=bytes.multipliedReportingOverflow(by:multiplier)
        let (total,totalOverflow)=scaled.addingReportingOverflow(overhead)
        guard bytes >= 0,!scaleOverflow,!totalOverflow else {
          throw NotebookStorageError.limitExceeded("json_decode_memory")
        }
        return total
      }
      let nodes=try allocation(coldFootprint?.nodeCount ?? 0,InkStoredBody.decodingNodeBytes,2_048)
      try admitJSONAllocation(bytes:allocation(portableBytes,accepted == nil ? 8 : 2,nodes))
      if expandingInk {
        // Local base64/bridged String buffers and their growth; this owner does
        // not JSON-encode or slash-escape output. A later typed/codec phase
        // pays its own actual output through the same remaining allowance.
        try admitJSONAllocation(bytes:allocation(base64Bytes,8,512+192+512+16))
        try admitJSONAllocation(bytes:value.inkReplacementBytes(at:path))
      }
      let encoded:Data
      if let accepted { encoded=InkStoredBody.restoringRevision(reference.revision,body:accepted) }
      else {
        encoded=try InkStoredBody.portable(root ?? inkBlob(reference.inkBody),revision:reference.revision,load:inkBlob)
        _=try InkMeasurements(encodedRelations:encoded,sharing:inkDecoding)
        // A validated graph has the writer's exact physical representation.
        // Older aggregate NIB1 blobs must still pass through the migrator's
        // writer, not be mistaken for today's canonical shared-parts output.
        if graph { inkDecoding.retainStoredOutput(encoded.dropFirst(20),hash:reference.inkBody) }
      }
      if expandingInk { value=try value.replacingInk(at:path[...],with:.string(encoded.base64EncodedString())) }
    }
    return expandingInk ? raw.replacing(value:value) : raw
  }

  private func inkBlobInfo(_ hash: String) throws -> (count:Int,header:Data) {
    let count:Int,header:Data
    if let cached=inkDecoding.storedBody(hash) { count=cached.count;header=cached.prefix(InkStoredBody.readHeaderBytes) }
    else {
      guard let row=try rows("SELECT length(data),substr(data,1,?) FROM blobs WHERE hash=?",
        [.integer(Int64(InkStoredBody.readHeaderBytes)),.text(hash)]).first else {
        throw NotebookStorageError.blobMissing(hash)
      }
      count=Int(row[0].integer!);header=row[1].blob!
    }
    let signature=header.prefix(4)
    let valid=signature == Data("NIB1".utf8) ? (4...InkStoredBody.maximumBytes-16).contains(count)
      : signature == Data("NIB2".utf8) ? count == 74
      : signature == Data("NIN1".utf8) && (6...32_768).contains(count)
    guard valid else { throw NotebookStorageError.invalidTransaction("ink body signature or size") }
    return (count,header)
  }

  func inkBlob(_ hash: String) throws -> Data {
    if let cached=inkDecoding.storedBody(hash) { return cached }
    _=try inkBlobInfo(hash)
    let bytes=try blob(hash)
    guard SHA256.hash(data:bytes).map({ String(format:"%02x",$0) }).joined() == hash else { throw NotebookStorageError.blobHashMismatch }
    // Spend the bounded entry budget on measurement payloads, not tiny graph
    // edges. Linkage alone must not exhaust the slots before useful leaves.
    if try !bytes.starts(with:Data("NIN1".utf8)) || InkStoredBody.dependencies(bytes).isEmpty {
      inkDecoding.retainStoredBody(bytes,hash:hash)
    }
    return bytes
  }

  func decodedStoredFragment(from data: Data,expandingInk:Bool = true) throws -> NotebookStoredFragment {
    var remaining=max(0,Int64(256*1024*1024-data.count))
    return try decodedStoredFragment(from:data,remainingBytes:&remaining,budget:"ink body read",expandingInk:expandingInk)
  }
}

extension NotebookStore {
  static func prepareInkBodyDependencies(_ database: NotebookSQLConnection) throws {
    try database.run("CREATE TABLE IF NOT EXISTS manifest_ink_discovery(manifest_hash TEXT PRIMARY KEY REFERENCES manifests(hash)) WITHOUT ROWID")
    try database.run("CREATE TABLE IF NOT EXISTS manifest_ink_bodies(manifest_hash TEXT NOT NULL REFERENCES manifests(hash),hash TEXT NOT NULL,expanded INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(manifest_hash,hash)) WITHOUT ROWID")
    if try !database.rows("PRAGMA table_info(manifest_ink_bodies)").contains(where:{ $0[1].text == "expanded" }) {
      try database.run("ALTER TABLE manifest_ink_bodies ADD COLUMN expanded INTEGER NOT NULL DEFAULT 0")
    }
    try database.run("CREATE INDEX IF NOT EXISTS manifest_ink_pending ON manifest_ink_bodies(manifest_hash,expanded,hash)")
  }

  func noteInkBodyDependencies(manifestHash: String, fragment: NotebookStoredFragment) throws {
    for hash in try fragment.inkBodyHashes {
      try currentSQL!.run("INSERT OR IGNORE INTO manifest_ink_bodies(manifest_hash,hash) VALUES(?,?)",[.text(manifestHash),.text(hash)])
    }
  }

  /// Discovery is disk-backed and incremental through the existing dependency
  /// queue. A present graph root never substitutes for its absent children.
  func missingInkBodyDependencies(manifestHash: String, limit: Int) throws -> [String] {
    let database=currentSQL!
    while true {
      try Task.checkCancellation()
      let pending=try database.rows("SELECT hash FROM manifest_ink_bodies WHERE manifest_hash=? AND expanded=0 ORDER BY hash LIMIT 64",[.text(manifestHash)])
      if pending.isEmpty { break }
      var missing:[String]=[]
      for row in pending {
        let hash=row[0].text!
        if try database.rows("SELECT 1 FROM blobs WHERE hash=?",[.text(hash)]).isEmpty {
          missing.append(hash);if missing.count == limit { return missing };continue
        }
        for child in try InkStoredBody.dependencies(database.inkBlob(hash)) {
          try database.run("INSERT OR IGNORE INTO manifest_ink_bodies(manifest_hash,hash) VALUES(?,?)",[.text(manifestHash),.text(child)])
        }
        try database.run("UPDATE manifest_ink_bodies SET expanded=1 WHERE manifest_hash=? AND hash=?",[.text(manifestHash),.text(hash)])
      }
      if !missing.isEmpty { return missing }
    }
    return try database.rows("SELECT i.hash FROM manifest_ink_bodies i LEFT JOIN blobs b ON b.hash=i.hash WHERE i.manifest_hash=? AND b.hash IS NULL ORDER BY i.hash LIMIT ?",
      [.text(manifestHash),.integer(Int64(limit))]).compactMap { $0[0].text }
  }

  func missingInkBodyBlobs(manifestHash: String, limit: Int) throws -> [String] {
    let database=currentSQL!
    try Self.prepareInkBodyDependencies(database)
    if try database.rows("SELECT 1 FROM manifest_ink_discovery WHERE manifest_hash=?",[.text(manifestHash)]).isEmpty {
      var after=""
      while let row=try database.rows("""
        SELECT m.address,m.blob_hash FROM manifest_records m CROSS JOIN blobs b ON b.hash=m.blob_hash
        WHERE m.manifest_hash=? AND m.address>? AND json_type(CAST(b.data AS TEXT),'$.inkBodies')='array'
        ORDER BY m.address LIMIT 1
        """,[.text(manifestHash),.text(after)]).first {
        try Task.checkCancellation();after=row[0].text!
        let fragment=try JSONDecoder().decode(NotebookStoredFragment.self,from:database.blob(row[1].text!))
        guard fragment.address == after else { throw NotebookStorageError.invalidTransaction("ink dependency address") }
        try noteInkBodyDependencies(manifestHash:manifestHash,fragment:fragment)
      }
      try database.run("INSERT INTO manifest_ink_discovery VALUES(?)",[.text(manifestHash)])
    }
    return try missingInkBodyDependencies(manifestHash:manifestHash,limit:limit)
  }
}

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
          encoded.base64EncodedString() == text,
          let source=try? InkMeasurements(encodedRelations:encoded,sharing:inkDecoding) else { return value }
        let bytes=Data("NIB1".utf8)+encoded.dropFirst(20),hash=try putBlob(bytes)
        // Hash equality alone must not merge different bytes.
        guard try !rows("SELECT 1 FROM blobs WHERE hash=? AND data=?",[.text(hash),.blob(bytes)]).isEmpty else { throw NotebookStorageError.blobHashMismatch }
        let reference=try JSONValue.encode(NotebookInkBodyReference(inkBody:hash,revision:source.revision))
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

  func decodedStoredFragment(from data: Data, remainingBytes: inout Int64, budget: String) throws -> NotebookStoredFragment {
    let raw=try JSONDecoder().decode(NotebookStoredFragment.self,from:data)
    _=try raw.inkBodyHashes
    var value=raw.value,logicalBytes=data.count
    for path in raw.inkBodies {
      let stored=try raw.value.inkValue(at:path)
      let reference=try stored.decode(NotebookInkBodyReference.self)
      try reference.validate()
      guard try JSONValue.encode(reference) == stored else { throw NotebookStorageError.invalidTransaction("ink body reference") }
      let cached=inkDecoding.storedBody(reference.inkBody)
      guard let count=try cached.map({ Int64($0.count) }) ?? rows("SELECT length(data) FROM blobs WHERE hash=?",[.text(reference.inkBody)]).first?[0].integer else {
        throw NotebookStorageError.blobMissing(reference.inkBody)
      }
      guard count >= 4,count <= 128*1024*1024-16 else { throw NotebookStorageError.limitExceeded("ink body bytes") }
      // A bounded logical read must charge what it returns, not just the small
      // reference. Reject before copying the body out of SQLite.
      let expanded=((count+16+2)/3)*4
      guard expanded <= remainingBytes else { throw NotebookStorageError.limitExceeded(budget) }
      remainingBytes -= expanded
      logicalBytes += Int(expanded)
      try admitExpandedRead(bytes:Int(expanded),valueBytes:logicalBytes)
      let bytes=try cached ?? blob(reference.inkBody)
      if cached == nil {
        guard bytes.starts(with:Data("NIB1".utf8)) else { throw NotebookStorageError.invalidTransaction("ink body signature") }
        guard SHA256.hash(data:bytes).map({ String(format:"%02x",$0) }).joined() == reference.inkBody else { throw NotebookStorageError.blobHashMismatch }
        inkDecoding.retainStoredBody(bytes,hash:reference.inkBody)
      }
      var revision=reference.revision.uuid
      var encoded=Data("NIM1".utf8)
      withUnsafeBytes(of:&revision) { encoded.append(contentsOf:$0) }
      encoded.append(bytes.dropFirst(4))
      value=try value.replacingInk(at:path[...],with:.string(encoded.base64EncodedString()))
    }
    return raw.replacing(value:value)
  }

  func decodedStoredFragment(from data: Data) throws -> NotebookStoredFragment {
    var remaining=max(0,Int64(256*1024*1024-data.count))
    return try decodedStoredFragment(from:data,remainingBytes:&remaining,budget:"ink body read")
  }
}

extension NotebookStore {
  static func prepareInkBodyDependencies(_ database: NotebookSQLConnection) throws {
    try database.run("CREATE TABLE IF NOT EXISTS manifest_ink_discovery(manifest_hash TEXT PRIMARY KEY REFERENCES manifests(hash)) WITHOUT ROWID")
    try database.run("CREATE TABLE IF NOT EXISTS manifest_ink_bodies(manifest_hash TEXT NOT NULL REFERENCES manifests(hash),hash TEXT NOT NULL,PRIMARY KEY(manifest_hash,hash)) WITHOUT ROWID")
  }

  func noteInkBodyDependencies(manifestHash: String, fragment: NotebookStoredFragment) throws -> [String] {
    let database=currentSQL!
    var missing:[String]=[]
    for hash in try fragment.inkBodyHashes {
      try database.run("INSERT OR IGNORE INTO manifest_ink_bodies VALUES(?,?)",[.text(manifestHash),.text(hash)])
      if try database.rows("SELECT 1 FROM blobs WHERE hash=?",[.text(hash)]).isEmpty { missing.append(hash) }
    }
    return missing
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
        _=try noteInkBodyDependencies(manifestHash:manifestHash,fragment:fragment)
      }
      try database.run("INSERT INTO manifest_ink_discovery VALUES(?)",[.text(manifestHash)])
    }
    return try database.rows("SELECT i.hash FROM manifest_ink_bodies i LEFT JOIN blobs b ON b.hash=i.hash WHERE i.manifest_hash=? AND b.hash IS NULL ORDER BY i.hash LIMIT ?",
      [.text(manifestHash),.integer(Int64(limit))]).compactMap { $0[0].text }
  }

  func visitInkBodyDependencies(manifestHash: String, _ visit: (String) throws -> Void) throws {
    var after=""
    while let hash=try currentSQL!.rows("SELECT hash FROM manifest_ink_bodies WHERE manifest_hash=? AND hash>? ORDER BY hash LIMIT 1",
      [.text(manifestHash),.text(after)]).first?[0].text {
      try visit(hash);after=hash
    }
  }
}

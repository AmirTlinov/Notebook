import Foundation
import Testing
@testable import NotebookCore

@Suite("Portable program closure follows the ordinary native paste")
struct NotebookProgramTransferTests {
  private enum Fault: Error { case disk, timedOut }
  private final class Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("program-transfer-\(UUID())")
    let a: NotebookStore, b: NotebookStore
    let actor = UUID()
    let source: CollaborationTarget, destination: CollaborationTarget
    let binary = Data(repeating: 29, count: NotebookProgramPackage.partBytes)
    let tail = Data([0, 255, 11, 73])
    let wasm = Data([0, 97, 115, 109, 1, 0, 0, 0])
    let script = Data("globalThis.resource = './payload.bin';".utf8)

    init() throws {
      a = NotebookStore(root: root.appendingPathComponent("a")); b = NotebookStore(root: root.appendingPathComponent("b"))
      let ah = try a.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
      let bh = try b.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
      source = .init(kind: .board, id: ah.rootBoardID); destination = .init(kind: .board, id: bh.rootBoardID)
    }
    deinit { try? FileManager.default.removeItem(at: root) }

    func package(module: Bool) -> NotebookProgramPackage {
      func part(_ bytes: Data) -> NotebookProgramPackage.Part {
        .init(sha256: NotebookProgramPackage.hash(bytes), byteCount: bytes.count)
      }
      return .init(javaScript: "main.js", module: module, files: [
        .init(path: "main.js", mimeType: "text/javascript", byteCount: Int64(script.count), parts: [part(script)]),
        .init(path: "model.wasm", mimeType: "application/wasm", byteCount: Int64(wasm.count), parts: [part(wasm)]),
        .init(path: "payload.bin", mimeType: "application/octet-stream", byteCount: Int64(binary.count + tail.count), parts: [part(binary), part(tail)])
      ])
    }

    func transfer() throws -> NotebookElementTransfer {
      for data in [script, wasm, binary, tail] { try a.stageBlob(data: data, expectedHash: NotebookProgramPackage.hash(data)) }
      let hashes = try [true, false].map { try a.stageProgramPackage(package(module: $0)) }
      let elements: [AgentElement] = [
        .init(id: "whole", kind: .group, frame: .init(x: 0, y: 0, width: 400, height: 300), source: "", html: "",
          basis: .init(size: .init(x: 400, y: 300))),
        .init(id: "text", kind: .nativeText, frame: .init(x: 10, y: 10, width: 100, height: 40), source: "Текст рядом", html: "", parentID: "whole"),
        .init(id: "program-a", kind: .web, frame: .init(x: 10, y: 60, width: 150, height: 120), source: "", html: "",
          programPackage: hashes[0], state: .object(["value": .number(7)]), parentID: "whole"),
        .init(id: "program-b", kind: .web, frame: .init(x: 170, y: 60, width: 150, height: 120), source: "", html: "",
          programPackage: hashes[1], state: .object(["value": .number(9)]), parentID: "whole")
      ]
      let operations = try elements.map { element -> CollaborationOperation in
        var values = try JSONValue.encode(element).object
        values.removeValue(forKey: "id"); values["worldOrigin"] = try .encode(WorldPoint.zero)
        return .init(kind: .insertElement, target: source, id: element.id, values: values)
      }
      _ = try a.applyNativeAction(.init(summary: "Source group", expected: [.init(target: source,
        revision: a.targetContentRevision(target: source))], operations: operations), actor: actor)
      return try a.readElementTransfer(target: source, rootIDs: ["whole"])
    }

    func fragment(_ transfer: NotebookElementTransfer) -> NotebookPasteFragment {
      .init(elements: transfer.elements, size: .init(x: 400, y: 300), programResources: transfer.programResources)
    }
    func action(_ fragment: NotebookPasteFragment, id: UUID = UUID()) throws -> CollaborationAction {
      .init(id: id, summary: "Paste complete group", expected: [.init(target: destination,
        revision: try b.targetContentRevision(target: destination))],
        operations: try fragment.operations(target: destination, worldOrigin: .zero))
    }
    func blobCount() throws -> Int64 {
      try b.sqlRead { try $0.rows("SELECT COUNT(*) FROM blobs")[0][0].integer! }
    }
  }

  @Test func mixedGroupMovesBetweenWorkspacesWithExactBinaryBytesAndDeduplicatedParts() throws {
    let f = try Fixture(), transfer = try f.transfer(), resources = try #require(transfer.programResources)
    #expect(resources.packageHashes.count == 2)
    #expect(resources.blobs.count == 6, "Two manifests share four exact resource parts")
    let original = f.fragment(transfer), wire = try JSONEncoder().encode(original)
    _ = try NotebookJSONAdmission.allocationCost(wire, maximumBytes: 96 * 1_048_576)
    #expect(wire.count <= 16 * 1_048_576)
    let copied = try JSONDecoder().decode(NotebookPasteFragment.self, from: wire).reidentified()
    #expect(copied.programResources == resources)
    #expect(copied.elements.map(\.programPackage) == original.elements.map(\.programPackage))
    #expect(copied.elements.map(\.state) == original.elements.map(\.state))
    #expect(Set(copied.elements.map(\.id)).isDisjoint(with: original.elements.map(\.id)))
    let resourcePlan = try copied.prepareProgramResources()
    let prepared = try #require(resourcePlan)
    #expect(prepared.byteCount == resources.blobs.reduce(0) { $0 + $1.data.count })
    #expect(prepared.byteCount < NotebookProgramTransfer.maximumBytes)
    let action = try f.action(copied), before = try f.b.currentChangeCursor()
    let receipt = try f.b.applyNativeAction(action, actor: f.actor, programResources: prepared)
    #expect(try f.b.currentChangeCursor() == before + 1)
    #expect(try f.b.applyNativeAction(action, actor: f.actor, programResources: prepared) == receipt)
    #expect(try f.b.currentChangeCursor() == before + 1)
    let cold = NotebookStore(root: f.b.root)
    let board = try #require(cold.loadBoard(items: cold.loadIndex().items).board(f.destination.id))
    #expect(board.elements.count == 4)
    for hash in resources.packageHashes {
      let package = try cold.readProgramPackage(hash)
      #expect(package == f.package(module: package.module))
      #expect(try cold.readProgramFile(package.files[1], offset: 0, maxBytes: 32) == f.wasm)
      #expect(try cold.readProgramFile(package.files[2], offset: Int64(f.binary.count - 2), maxBytes: 6) == Data([29, 29, 0, 255, 11, 73]))
    }
    #expect(try cold.readBlobChunk(hash: NotebookProgramPackage.hash(f.script), offset: 0, maxBytes: 1024) == f.script)
  }

  @Test func missingTamperedDuplicateAndUnreferencedBlobsRefuseTheWholeFragment() throws {
    let f = try Fixture(), transfer = try f.transfer(), resources = try #require(transfer.programResources)
    let part = try #require(resources.blobs.first { !resources.packageHashes.contains($0.sha256) })
    var damaged = part.data; damaged[0] ^= 1
    let extra = Data("unreferenced".utf8)
    let variants = [
      NotebookProgramTransfer(packageHashes: resources.packageHashes, blobs: resources.blobs.filter { $0.sha256 != part.sha256 }),
      .init(packageHashes: resources.packageHashes, blobs: resources.blobs.map { $0.sha256 == part.sha256 ? .init(sha256: part.sha256, data: damaged) : $0 }),
      .init(packageHashes: resources.packageHashes, blobs: resources.blobs + [part]),
      .init(packageHashes: resources.packageHashes, blobs: resources.blobs + [.init(sha256: NotebookProgramPackage.hash(extra), data: extra)]),
      .init(packageHashes: [], blobs: resources.blobs)
    ]
    let before = try f.b.currentChangeCursor(), count = try f.blobCount()
    for invalid in variants {
      let fragment = NotebookPasteFragment(elements: transfer.elements, size: .init(x: 400, y: 300), programResources: invalid)
      #expect(throws: CollaborationError.self) { try fragment.reidentified() }
      #expect(throws: CollaborationError.self) { try fragment.operations(target: f.destination, worldOrigin: .zero) }
    }
    let text = AgentElement(id: "plain", kind: .nativeText, frame: .init(x: 0, y: 0, width: 100, height: 40), source: "Plain", html: "")
    #expect(throws: CollaborationError.self) {
      try NotebookPasteFragment(elements: [text], size: .init(x: 100, y: 40), programResources: resources).reidentified()
    }
    #expect(try f.b.currentChangeCursor() == before)
    #expect(try f.blobCount() == count)
  }

  @Test func noncanonicalManifestAndRawByteOverflowCannotBecomePreparedTransfers() throws {
    let f = try Fixture(), transfer = try f.transfer(), resources = try #require(transfer.programResources)
    let root = resources.packageHashes[0], manifest = try #require(resources.blobs.first { $0.sha256 == root })
    let bytes = manifest.data + Data([32]), replacement = NotebookProgramPackage.hash(bytes)
    let noncanonical = NotebookProgramTransfer(packageHashes: resources.packageHashes.map { $0 == root ? replacement : $0 },
      blobs: resources.blobs.map { $0.sha256 == root ? .init(sha256: replacement, data: bytes) : $0 })
    #expect(throws: CollaborationError.self) { try noncanonical.prepare(packageHashes: noncanonical.packageHashes) }
    let second = Data(repeating: 30, count: NotebookProgramPackage.partBytes)
    let package = NotebookProgramPackage(javaScript: "main.js", files: [
      .init(path: "main.js", mimeType: "text/javascript", byteCount: Int64(f.script.count),
        parts: [.init(sha256: NotebookProgramPackage.hash(f.script), byteCount: f.script.count)]),
      .init(path: "payload.bin", mimeType: "application/octet-stream", byteCount: Int64(f.binary.count + second.count),
        parts: [f.binary, second].map { .init(sha256: NotebookProgramPackage.hash($0), byteCount: $0.count) })
    ])
    let canonical = try package.canonicalData(), hash = try package.sha256
    let overflow = NotebookProgramTransfer(packageHashes: [hash], blobs: [canonical, f.script, f.binary, second].map {
      .init(sha256: NotebookProgramPackage.hash($0), data: $0)
    })
    #expect(throws: CollaborationError.self) { try overflow.prepare(packageHashes: [hash]) }
  }

  @Test func corruptSameLengthDestinationPartRefusesWithoutKeepingEarlierStaging() throws {
    let f = try Fixture(), transfer = try f.transfer(), resources = try #require(transfer.programResources)
    let copied = try f.fragment(transfer).reidentified()
    let resourcePlan = try copied.prepareProgramResources()
    let prepared = try #require(resourcePlan)
    let part = try #require(resources.blobs.first { !resources.packageHashes.contains($0.sha256) })
    var damaged = part.data; damaged[0] ^= 1
    try f.b.commandTransaction {
      try f.b.currentSQL!.run("INSERT INTO blobs(hash,data) VALUES(?,?)", [.text(part.sha256), .blob(damaged)])
    }
    let action = try f.action(copied), before = try f.b.currentChangeCursor(), read = try f.b.currentReadCursor(), count = try f.blobCount()
    #expect(throws: CollaborationError.self) { try f.b.applyNativeAction(action, actor: f.actor, programResources: prepared) }
    #expect(try f.b.currentChangeCursor() == before)
    #expect(try f.b.currentReadCursor() == read)
    #expect(try f.blobCount() == count)
    #expect(try f.b.collaborationActionIfPresent(action.id) == nil)
    try f.a.commandTransaction {
      try f.a.currentSQL!.run("UPDATE blobs SET data=? WHERE hash=?", [.blob(damaged), .text(part.sha256)])
    }
    #expect(throws: CollaborationError.self) { try f.a.readElementTransfer(target: f.source, rootIDs: ["whole"]) }
  }

  @Test func failedPasteCommitRollsBackBlobsElementsAndReceiptTogether() throws {
    let f = try Fixture(), transfer = try f.transfer(), copied = try f.fragment(transfer).reidentified()
    let resourcePlan = try copied.prepareProgramResources()
    let prepared = try #require(resourcePlan), action = try f.action(copied)
    let before = try f.b.currentChangeCursor(), read = try f.b.currentReadCursor(), count = try f.blobCount()
    let unavailable = NotebookStore(root: f.b.root, storageFault: { if $0 == .beforeCommit { throw Fault.disk } })
    #expect(throws: Fault.self) { try unavailable.applyNativeAction(action, actor: f.actor, programResources: prepared) }
    #expect(try f.b.currentChangeCursor() == before)
    #expect(try f.b.currentReadCursor() == read)
    #expect(try f.blobCount() == count)
    #expect(try f.b.collaborationActionIfPresent(action.id) == nil)
    #expect(try f.b.loadBoard(items: f.b.loadIndex().items).board(f.destination.id)?.elements.isEmpty == true)
    for hash in prepared.packageHashes { #expect(throws: NotebookStorageError.self) { try f.b.blobSize(hash: hash) } }
    _ = try f.b.applyNativeAction(action, actor: f.actor, programResources: prepared)
    #expect(try f.b.currentChangeCursor() == before + 1)
  }

  @Test func actionReuseCannotAttachProgramResourcesToAnUnrelatedSavedAction() throws {
    let f = try Fixture(), transfer = try f.transfer()
    let fragment = f.fragment(transfer), resourcePlan = try fragment.prepareProgramResources()
    let prepared = try #require(resourcePlan)
    let text = AgentElement(id: "plain", kind: .nativeText, frame: .init(x: 0, y: 0, width: 100, height: 40), source: "Plain", html: "")
    let plain = NotebookPasteFragment(elements: [text], size: .init(x: 100, y: 40))
    let original = try f.action(plain), fingerprint = "same-client-request"
    _ = try f.b.applyNativeAction(original, actor: f.actor, requestFingerprint: fingerprint)
    let before = try f.b.currentChangeCursor(), count = try f.blobCount()
    #expect(throws: CollaborationError.self) {
      try f.b.applyNativeAction(original, actor: f.actor, requestFingerprint: fingerprint, programResources: prepared)
    }
    let incoming = try f.action(f.fragment(transfer).reidentified(), id: original.id)
    #expect(throws: CollaborationError.self) {
      try f.b.applyNativeAction(incoming, actor: f.actor, requestFingerprint: fingerprint, programResources: prepared)
    }
    #expect(try f.b.currentChangeCursor() == before)
    #expect(try f.blobCount() == count)
    #expect(try f.b.collaborationAction(original.id).action == original)
  }

  private final class WriteJob: @unchecked Sendable {
    private let lock = NSLock(), done = DispatchSemaphore(value: 0)
    private var result: Result<Void, Error>?
    init(_ operation: @escaping @Sendable () throws -> Void) {
      DispatchQueue.global(qos: .userInitiated).async { [self] in
        let result = Result { try operation() }
        lock.lock(); self.result = result; lock.unlock(); done.signal()
      }
    }
    func wait() throws {
      guard done.wait(timeout: .now() + 20) == .success else { throw Fault.timedOut }
      lock.lock(); defer { lock.unlock() }
      try result!.get()
    }
  }

  @Test func selectionAndBinaryClosureBorrowTheSameSQLSourceCut() throws {
    let f = try Fixture(), initial = try f.transfer()
    let program = try #require(initial.elements.first { $0.id == "program-a" })
    let originalHash = try #require(program.programPackage)
    let newer = try #require(initial.elements.first { $0.id == "program-b" }?.programPackage)
    let actor = f.actor, writer = NotebookStore(root: f.a.root), target = f.source
    let action = CollaborationAction(summary: "Change source during copy", expected: [.init(target: target,
      revision: try writer.targetContentRevision(target: target))],
      operations: [.init(kind: .updateElement, target: target, id: program.id, values: ["programPackage": .string(newer)])])
    let captured = try f.a.readTransaction { snapshot in
      let observed = try snapshot.readNativeElementSource(target: target, id: program.id)
      try WriteJob { _ = try writer.applyNativeAction(action, actor: actor) }.wait()
      return try snapshot.readElementTransfer(target: target, rootIDs: [program.id], observedSources: [observed])
    }
    #expect(captured.elements.first?.programPackage == program.programPackage)
    #expect(captured.programResources?.packageHashes == [originalHash])
    #expect(try writer.readNativeElementSource(target: target, id: program.id).spatial?.programPackage == newer)
  }
}

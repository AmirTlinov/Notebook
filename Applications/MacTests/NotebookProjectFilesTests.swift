import XCTest
import NotebookCore
@testable import Notebook

final class NotebookProjectFilesTests: XCTestCase {
  private func fixture(_ body: (NotebookStore, CodexProject, NotebookFileAddress, UUID) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-files-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let projectRoot = root.appendingPathComponent("project")
    try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
    let project = CodexProject(id: "real-project", name: "Code", roots: [projectRoot.path])
    let address = NotebookFileAddress(computer: UUID(), project: project.id, root: projectRoot.path, path: "main.py")
    let store = NotebookStore(root: root.appendingPathComponent("notebook")), author = UUID()
    _ = try store.initializeWorkspace(actor: author, pageSize: .init(width: 834, height: 1194))
    try body(store, project, address, author)
  }
  private func stage(_ edit: NotebookFileEdit, store: NotebookStore, author: UUID) throws -> UUID {
    let data = try JSONEncoder().encode(edit), id = UUID(), digest = NotebookFileVersion.hash(data)
    var offset = 0
    while offset < data.count {
      let end = min(data.count, offset + NotebookFileVersion.chunkBytes)
      _ = try store.stageFileUpload(.init(id: id, digest: digest, total: data.count, offset: offset, data: data.subdata(in: offset..<end)), author: author)
      offset = end
    }
    return id
  }
  func testRealFileMergeConflictPermissionsAndRecoveryNeverRepeatWrites() throws {
    try fixture { store, project, address, author in
      let file = URL(fileURLWithPath: address.root).appendingPathComponent(address.path)
      try Data("a\nb\nc".utf8).write(to: file)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
      let id = try stage(.init(address: address, base: "a\nb\nc", text: "A\nb\nc"), store: store, author: author)
      try Data("a\nb\nC".utf8).write(to: file)
      let result = try MacNotebookProjectFiles.commit(id, author: author, address: address, project: project, store: store)
      XCTAssertEqual(result.status, .saved)
      XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "A\nb\nC")
      XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o755)
      try Data("newer human content".utf8).write(to: file)
      XCTAssertEqual(try MacNotebookProjectFiles.reconcile(id, project: project, store: store), result)
      XCTAssertThrowsError(try MacNotebookProjectFiles.commit(id, author: author, address: address, project: project, store: store))
      XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "newer human content")
      let conflict = try stage(.init(address: address, base: "A\nb\nC", text: "A\nlocal\nC"), store: store, author: author)
      XCTAssertEqual(try MacNotebookProjectFiles.commit(conflict, author: author, address: address, project: project, store: store).status, .conflict)
      XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "newer human content")
      XCTAssertEqual(try store.stagedFileEdit(conflict, author: author).text, "A\nlocal\nC")
    }
  }
  func testSymlinkEscapeRevokedRootAndDirectoryPagination() throws {
    try fixture { _, project, address, _ in
      let root = URL(fileURLWithPath: address.root), file = root.appendingPathComponent(address.path)
      try FileManager.default.createSymbolicLink(at: file, withDestinationURL: root.deletingLastPathComponent())
      XCTAssertThrowsError(try MacNotebookProjectFiles.read(address, project: project))
      let nested = address.child("secret")
      XCTAssertThrowsError(try MacNotebookProjectFiles.read(nested, project: project))
      XCTAssertThrowsError(try MacNotebookProjectFiles.read(address, project: .init(id: project.id, name: "revoked", roots: [])))
      for index in 0..<130 { try Data("code".utf8).write(to: root.appendingPathComponent(String(format: "%03d.py", index))) }
      let dir = NotebookFileAddress(computer: address.computer, project: address.project, root: address.root, path: "")
      let first = try MacNotebookProjectFiles.list(dir, project: project, after: nil)
      let second = try MacNotebookProjectFiles.list(dir, project: project, after: first.next)
      XCTAssertEqual(first.entries.count, 64); XCTAssertEqual(second.entries.count, 64)
      XCTAssertTrue(Set(first.entries.map(\.name)).isDisjoint(with: second.entries.map(\.name)))
    }
  }
  func testPreparedUnknownWriteOnlyReconcilesTheObservedHash() throws {
    try fixture { store, project, address, _ in
      let file = URL(fileURLWithPath: address.root).appendingPathComponent(address.path), id = UUID()
      let old = Data("before".utf8), new = Data("after".utf8)
      try old.write(to: file); try store.prepareFileCommit(id, address: address, before: old, after: new)
      XCTAssertNil(try MacNotebookProjectFiles.reconcile(id, project: project, store: store))
      XCTAssertEqual(try Data(contentsOf: file), old)
      try new.write(to: file)
      XCTAssertEqual(try MacNotebookProjectFiles.reconcile(id, project: project, store: store)?.status, .saved)
    }
  }
}

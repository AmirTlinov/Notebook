import Foundation
import Darwin
import NotebookCore

/// Called on NotebookPersistenceQueue, never the main actor. Every path walk
/// holds directory descriptors and refuses symlinks, devices and hard links.
/// Codex supplies the current project roots; the iPad cannot grant itself a root.
enum MacNotebookProjectFiles {
  struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }
  private static func failure(_ message: String) -> Failure { .init(message: message) }
  private static func systemFailure() -> Failure { failure(String(cString: strerror(errno))) }

  private static func directory(_ address: NotebookFileAddress, project: CodexProject, parent: Bool) throws -> Int32 {
    guard address.isValid, address.project == project.id, project.roots.contains(address.root) else { throw failure("Проект больше не разрешает эту папку.") }
    let root = URL(fileURLWithPath: address.root).resolvingSymlinksInPath().path
    var fd = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw systemFailure() }
    let components = address.path.split(separator: "/").map(String.init)
    do {
      for name in parent ? Array(components.dropLast()) : components {
        let next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard next >= 0 else { throw failure("Папка недоступна или является символической ссылкой: \(name)") }
        close(fd); fd = next
      }
      return fd
    } catch { close(fd); throw error }
  }
  static func list(_ address: NotebookFileAddress, project: CodexProject, after: String?) throws -> NotebookFileDirectory {
    let fd = try directory(address, project: project, parent: false)
    guard let stream = fdopendir(fd) else { close(fd); throw systemFailure() }
    defer { closedir(stream) }
    var entries: [NotebookFileEntry] = []
    while let entry = readdir(stream) {
      let name = withUnsafePointer(to: &entry.pointee.d_name) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(validatingCString: $0) }
      }
      guard let name, name != ".", name != "..", after == nil || name > after! else { continue }
      var info = stat()
      guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
      let kind: NotebookFileEntry.Kind
      switch info.st_mode & S_IFMT {
      case S_IFDIR: kind = .directory
      case S_IFREG: kind = .file
      case S_IFLNK: kind = .symbolicLink
      default: kind = .unsupported
      }
      entries.append(.init(name: name, kind: kind)); entries.sort { $0.name < $1.name }
      if entries.count > 65 { entries.removeLast() }
    }
    let more = entries.count > 64
    return .init(entries: Array(entries.prefix(64)), next: more ? entries[63].name : nil)
  }
  private static func data(_ fd: Int32) throws -> Data {
    var before = stat(), after = stat()
    guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { throw failure("Это не обычный файл.") }
    guard before.st_size >= 0, before.st_size <= NotebookFileVersion.maximumBytes else { throw failure("Файл больше 2 МиБ; он не загружен и не изменён.") }
    var value = Data(count: Int(before.st_size))
    let count = value.count
    try value.withUnsafeMutableBytes { bytes in
      var offset = 0
      while offset < count {
        let readCount = pread(fd, bytes.baseAddress!.advanced(by: offset), count - offset, off_t(offset))
        if readCount < 0, errno == EINTR { continue }
        guard readCount > 0 else { throw failure("Файл изменился во время чтения; прочитайте его заново.") }
        offset += readCount
      }
    }
    guard fstat(fd, &after) == 0, same(before, after) else { throw failure("Файл изменился во время чтения; прочитайте его заново.") }
    guard let text = String(data: value, encoding: .utf8), !text.contains("\0") else { throw failure("Этот файл не является текстом UTF-8; редактирование отключено.") }
    return value
  }
  private static func same(_ a: stat, _ b: stat) -> Bool {
    a.st_ino == b.st_ino && a.st_dev == b.st_dev && a.st_size == b.st_size
      && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
      && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
  }
  static func read(_ address: NotebookFileAddress, project: CodexProject) throws -> Data {
    let parent = try directory(address, project: project, parent: true); defer { close(parent) }
    let fd = openat(parent, (address.path as NSString).lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw systemFailure() }; defer { close(fd) }
    return try data(fd)
  }
  static func commit(_ id: UUID, author: UUID, address: NotebookFileAddress, project: CodexProject, store: NotebookStore) throws -> NotebookFileResult {
    guard try store.fileCommit(id) == nil else { throw failure("Сохранение уже начиналось; проверяется исход прежней записи.") }
    let edit = try store.stagedFileEdit(id, author: author)
    guard edit.address == address else { throw failure("Адрес черновика не совпадает с сохранением.") }
    var result: Result<NotebookFileResult, Error>?
    var coordinationError: NSError?
    let url = URL(fileURLWithPath: address.root).appendingPathComponent(address.path)
    NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { _ in
      result = Result { try coordinatedCommit(id, edit: edit, project: project, store: store) }
    }
    if let coordinationError { throw coordinationError }
    guard let result else { throw failure("Файл недоступен для согласованной записи.") }
    return try result.get()
  }
  private static func coordinatedCommit(_ id: UUID, edit: NotebookFileEdit, project: CodexProject, store: NotebookStore) throws -> NotebookFileResult {
    let address = edit.address
    let parent = try directory(address, project: project, parent: true); defer { close(parent) }
    let name = (address.path as NSString).lastPathComponent
    let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw systemFailure() }; defer { close(fd) }
    var before = stat(); guard fstat(fd, &before) == 0, before.st_nlink == 1 else { throw failure("Запись файла с несколькими жёсткими ссылками отключена.") }
    let current = try data(fd), remote = String(decoding: current, as: UTF8.self)
    guard let merged = NotebookFileMerge.combine(base: edit.base, local: edit.text, remote: remote) else {
      let outcome = NotebookFileResult(address: address, status: .conflict, version: .init(current))
      try store.prepareFileCommit(id, address: address, before: current, after: current)
      try store.finishFileCommit(id, result: outcome); return outcome
    }
    let proposed = Data(merged.utf8)
    guard proposed.count <= NotebookFileVersion.maximumBytes else { throw failure("Объединённый файл превышает 2 МиБ; обе версии сохранены.") }
    let temporary = ".notebook-write-" + id.uuidString
    let output = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard output >= 0 else { throw systemFailure() }
    defer { close(output); unlinkat(parent, temporary, 0) }
    guard fcopyfile(fd, output, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0 else { throw systemFailure() }
    try proposed.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let written = write(output, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        if written < 0, errno == EINTR { continue }
        guard written > 0 else { throw systemFailure() }; offset += written
      }
    }
    guard fsync(output) == 0 else { throw systemFailure() }
    var latest = stat()
    guard fstatat(parent, name, &latest, AT_SYMLINK_NOFOLLOW) == 0, same(before, latest), try data(fd) == current else { throw failure("Код изменился во время сохранения. Черновик остался на iPad; обновите файл.") }
    // Durable intent precedes atomic filesystem publication. Recovery observes
    // this exact hash; it never repeats a write with an unknown outcome.
    try store.prepareFileCommit(id, address: address, before: current, after: proposed)
    guard renameat(parent, temporary, parent, name) == 0, fsync(parent) == 0 else { throw systemFailure() }
    let accepted = try read(address, project: project)
    guard accepted == proposed else { throw failure("После записи файл снова изменился. Исход сохранения проверяется без повторной записи.") }
    let outcome = NotebookFileResult(address: address, status: .saved, version: .init(proposed))
    try store.finishFileCommit(id, result: outcome); return outcome
  }
  static func reconcile(_ id: UUID, project: CodexProject, store: NotebookStore) throws -> NotebookFileResult? {
    guard let commit = try store.fileCommit(id) else { return nil }
    if let result = commit.result { return result }
    let observed = try read(commit.address, project: project)
    guard NotebookFileVersion.hash(observed) == commit.hash else { return nil }
    let result = NotebookFileResult(address: commit.address, status: .saved, version: .init(observed))
    try store.finishFileCommit(id, result: result); return result
  }
}

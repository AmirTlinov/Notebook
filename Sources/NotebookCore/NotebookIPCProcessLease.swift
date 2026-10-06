import Foundation
import Darwin

/// One runtime claims its stable endpoint before opening any workspace. Keep
/// this lease until accepted writes drain; child processes must not inherit it.
public final class NotebookIPCProcessLease: Sendable {
  let descriptor: Int32
  let acceptedWitnessLeaseIdentity: String
  let acceptedWitnessGeneration = UUID()

  public init(socketURL: URL = NotebookIPC.defaultSocketURL) throws {
    try SocketIO.validateDirectory(socketURL.deletingLastPathComponent(), create: true)
    let path = socketURL.appendingPathExtension("owner").path
    let fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw SocketIO.failure("Не удалось открыть владение Notebook runtime.") }
    do {
      var info = stat(), current = stat()
      guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
        info.st_uid == geteuid(), info.st_mode & 0o777 == 0o600, info.st_nlink == 1,
        lstat(path, &current) == 0, current.st_dev == info.st_dev, current.st_ino == info.st_ino else {
        throw CollaborationError("ipc_unauthorized", "Файл владельца Notebook должен принадлежать пользователю с правами 0600.")
      }
      guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
        if errno == EWOULDBLOCK { throw SocketIO.ownerRunning() }
        throw SocketIO.failure("Не удалось занять владение Notebook runtime.")
      }
      descriptor = fd
      acceptedWitnessLeaseIdentity = socketURL.appendingPathExtension("owner").standardizedFileURL.resolvingSymlinksInPath().path
        + ":" + String(info.st_dev) + ":" + String(info.st_ino)
    } catch { close(fd); throw error }
  }

  // Never unlink this file: a waiting launcher must lock the same inode after
  // the previous process exits. Closing the sole descriptor releases the lock.
  deinit { close(descriptor) }
}

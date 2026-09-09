import Foundation
import Darwin
import NotebookCore

// This executable is only an IPC client. A missing helper never opens another writer.
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
do {
  guard CommandLine.arguments.count == 1 else { throw CollaborationError("invalid_command", "Notebook bridge принимает одну JSON команду через stdin.") }
  var data = Data()
  let deadline = Date().addingTimeInterval(NotebookIPC.requestTimeout)
  while true {
    let remaining = deadline.timeIntervalSinceNow
    guard remaining > 0 else { throw CollaborationError("ipc_timeout", "Ввод команды не завершён вовремя.") }
    var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
    let ready = poll(&descriptor, 1, Int32(remaining * 1_000))
    if ready < 0 && errno == EINTR { continue }
    guard ready > 0 else { throw CollaborationError("ipc_timeout", "Ввод команды не завершён вовремя.") }
    var buffer = [UInt8](repeating: 0, count: 65_536)
    let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
    if count < 0 && errno == EINTR { continue }
    guard count >= 0 else { throw CollaborationError("ipc_protocol", "Команда не прочитана.") }
    if count == 0 { break }
    guard data.count + count <= NotebookIPC.maximumFrameBytes else { throw CollaborationError("resource_limit", "IPC команда превышает 32 МиБ.") }
    data.append(contentsOf: buffer.prefix(count))
  }
  let request = try NotebookIPC.decodeCommand(data)
  let socket = ProcessInfo.processInfo.environment["NOTEBOOK_SOCKET"].map { URL(fileURLWithPath: $0) }
    ?? NotebookIPC.defaultSocketURL
  let value = try NotebookIPCClient(socketURL: socket).send(request)
  FileHandle.standardOutput.write(try encoder.encode(value))
} catch {
  let result = (error as? CollaborationError) ?? CollaborationError("operation_failed", error.localizedDescription)
  FileHandle.standardOutput.write(try encoder.encode(result))
  exit(1)
}

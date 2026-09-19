# Executor for accepted IPC requests

`NotebookIPCServer` accepts sockets on user-request-priority transport queues.
It owns an `IPCRequestExecutor` for asynchronous handler continuations, separate
from blocking socket workers. Model actors and the existing SQLite writer retain
their isolation; the executor owns neither model state nor storage.

An accepted task retains its server and executor until the handler finishes.
Disconnecting does not cancel an accepted command. Shutdown waits for accepted
work, including a handler whose executor queue has not started yet.
Malformed frames are rejected by transport without waiting for that queue or
calling the writer. Connection limits, frame limits, and deadlines remain in
the transport owner.

The implementation uses
[Swift task executor preference](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0417-task-executor-preference.md).

## Verification

IPC tests exercise queue suspension/resumption, a real MainActor hop and return,
invalid frames while the handler queue is suspended, and completion after shutdown.
The original failure was starvation under concurrent synchronous Core work despite
passing isolated command tests. Historical negative and positive runs remain in
the [verification history](verification.md); they are not current installed-MCP
or physical-pair acceptance.

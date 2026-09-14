# Accepted persistence boundary

The five contracts use the production `NotebookPersistenceQueue` with controlled
FIFO operations in an isolated temporary store. The shared contract source also
runs in `NotebookPersistenceFenceTests` inside the native test target.

They check that later work and coalescing cannot extend or replace an accepted
prefix; cancelling a waiter retains all accepted writes; a failed predecessor
keeps the last write for retry; a later failure cannot revoke a completed prefix;
and empty fences neither announce commits nor remain in the queue.

The CPU executable imports an explicitly selected build of `NotebookCore`; it
starts no application, Simulator, or Xcode runner. Compile the production queue,
`Applications/TestSupport/NotebookPersistenceFenceContract.swift` and `main.swift`
with `-D NOTEBOOK_QUEUE_STANDALONE`. Native navigation and shutdown acceptance
remain separate: these contracts do not measure UI or storage performance.

`flush()` registers an ordering fence synchronously before its first suspension.
Its completion belongs to the FIFO owner after that marker is removed. Cancelling
only resolves the waiting continuation; retry retains the failed durable prefix.
Navigation finishes the accepted page-input tail and one writer cut, then performs
its addressed read through the same writer. Explicit shutdown/cutover retains the
quiescent wait for background publication owners.

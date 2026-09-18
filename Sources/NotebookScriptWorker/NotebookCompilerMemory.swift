import Darwin

/// Resource observation is independent of Foundation's asynchronous exit
/// notification. ESRCH means that the kernel no longer exposes this task; it
/// neither measures zero resident bytes nor supplies the child's exit status.
enum NotebookCompilerMemory {
  enum Observation: Equatable {
    case resident(bytes: UInt64)
    case taskAbsent
    case unavailable(errorNumber: Int32, returnedBytes: Int32)

    func exceeds(_ maximum: UInt64) -> Bool {
      if case .resident(let bytes) = self { return bytes > maximum }
      return false
    }
  }

  struct Usage { let memory: Observation; let cpuNanoseconds: UInt64? }

  static func observe(_ pid: Int32) -> Observation { measure(pid).memory }

  static func measure(_ pid: Int32) -> Usage {
    var value = proc_taskinfo()
    let size = Int32(MemoryLayout<proc_taskinfo>.stride)
    errno = 0
    let count = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &value, size)
    let errorNumber = errno
    let sum = value.pti_total_user.addingReportingOverflow(value.pti_total_system)
    return .init(memory: interpret(returnedBytes: count, errorNumber: errorNumber, residentBytes: value.pti_resident_size),
      cpuNanoseconds: count == size ? (sum.overflow ? UInt64.max : sum.partialValue) : nil)
  }

  /// Keep the syscall result intact: a denied or partial probe must never
  /// silently disable the memory limit. Only the documented absent-task
  /// result can await the existing terminal owner and its normal deadline.
  static func interpret(returnedBytes: Int32, errorNumber: Int32, residentBytes: UInt64) -> Observation {
    if returnedBytes == Int32(MemoryLayout<proc_taskinfo>.stride) { return .resident(bytes: residentBytes) }
    if returnedBytes == 0, errorNumber == ESRCH { return .taskAbsent }
    return .unavailable(errorNumber: errorNumber, returnedBytes: returnedBytes)
  }
}

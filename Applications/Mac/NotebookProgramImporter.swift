import Foundation
import NotebookCore

/// Bounded, disposable file-import work. The model's existing persistence queue
/// owns every staged part. Completed imports are rediscovered by their immutable
/// manifest, not a second journal; retry skips already accepted SHA blobs.
@MainActor
final class NotebookProgramImporter {
  private final class Job {
    var task: Task<Void, Never>?
    var status = "staging"
    var stagedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var message: String?
  }
  private let persistence: NotebookPersistenceQueue
  private let workspaceID: UUID
  private var jobs: [String: Job] = [:]
  init(persistence: NotebookPersistenceQueue, workspaceID: UUID) {
    self.persistence = persistence; self.workspaceID = workspaceID
  }

  func handle(_ request: NotebookProgramImportRequest) async throws -> JSONValue {
    guard NotebookProgramPackage.validHash(request.packageHash) else {
      throw CollaborationError("invalid_program_package", "Нужен SHA-256 подготовленного manifest.")
    }
    if request.op == .cancel {
      jobs[request.packageHash]?.task?.cancel()
      return receipt(hash: request.packageHash, job: jobs[request.packageHash], absent: "not_started")
    }
    if let job = jobs[request.packageHash], job.task != nil { return receipt(hash: request.packageHash, job: job) }
    if let admitted = try await persistence.submit({ store -> NotebookProgramPackage? in
      do { return try store.readProgramPackage(request.packageHash) }
      catch NotebookStorageError.blobMissing { return nil }
    }) {
      let job = Job(); job.status = "ready"; job.totalBytes = admitted.files.reduce(0) { $0 + $1.byteCount }; job.stagedBytes = job.totalBytes
      return receipt(hash: request.packageHash, job: job)
    }
    if request.op == .status { return receipt(hash: request.packageHash, job: jobs[request.packageHash], absent: "not_started") }
    guard let path = request.manifestPath, path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 4096 else {
      throw CollaborationError("invalid_program_package", "Импорт требует абсолютный путь к подготовленному manifest.")
    }
    guard jobs.values.filter({ $0.task != nil }).count < 2 else {
      throw CollaborationError("program_import_busy", "Два импорта уже читают файлы. Повторите после их завершения.")
    }
    // Failed metadata is cheap to retain for a status poll, but not unbounded.
    if jobs.count >= 16 { jobs = jobs.filter { $0.value.task != nil } }
    let job = Job(), hash = request.packageHash
    jobs[hash] = job
    job.task = Task { @MainActor [self, job] in
      defer { job.task = nil }
      do {
        let descriptor = try await Task.detached(priority: .utility) {
          try NotebookProgramImport.read(file: URL(fileURLWithPath: path), expectedHash: hash)
        }.value
        job.totalBytes = descriptor.package.files.reduce(0) { $0 + $1.byteCount }
        let sources = Dictionary(uniqueKeysWithValues: descriptor.sources.map { ($0.path, $0) })
        for file in descriptor.package.files {
          let source = sources[file.path]!
          var offset: Int64 = 0
          for (index, part) in file.parts.enumerated() {
            try Task.checkCancellation()
            let start = source.partPaths == nil ? offset : 0
            let url = URL(fileURLWithPath: source.partPaths?[index] ?? source.sourcePath!)
            let range = start..<(start + Int64(part.byteCount))
            try await persistence.submit { store in
              try store.stageBlob(file: url, expectedHash: part.sha256, byteCount: Int64(part.byteCount), range: range)
            }
            offset = range.upperBound; job.stagedBytes += Int64(part.byteCount)
            // Native contacts and small edits keep their position in the same
            // FIFO between parts; a 300 MiB file never owns one long write.
            await Task.yield()
          }
        }
        try Task.checkCancellation()
        let admitted = try await persistence.submit { try $0.stageProgramPackage(descriptor.package) }
        guard admitted == hash else { throw NotebookStorageError.blobHashMismatch }
        job.status = "ready"
      } catch is CancellationError { job.status = "cancelled" }
      catch { job.status = "error"; job.message = "Импорт отклонён: файл, размер, hash или manifest не совпадает с подготовленным пакетом." }
    }
    return receipt(hash: hash, job: job)
  }

  func stop() { for job in jobs.values { job.task?.cancel() } }

  private func receipt(hash: String, job: Job?, absent: String = "not_started") -> JSONValue {
    var result: [String: JSONValue] = ["status": .string(job?.status ?? absent), "packageHash": .string(hash),
      "workspaceID": .string(workspaceID.uuidString.lowercased()), "stagedBytes": .number(Double(job?.stagedBytes ?? 0)),
      "totalBytes": .number(Double(job?.totalBytes ?? 0))]
    if let message = job?.message { result["message"] = .string(message) }
    return .object(result)
  }
}

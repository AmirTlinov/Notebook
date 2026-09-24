import Foundation
// Structural probe: exact production queue, fake normalizer costs 100 ms.
typealias JSONValue = Int
struct CollaborationError: Error { init(_ code: String, _ message: String) {} }
struct WorkerRequest { let id: UUID; let code: String; let arguments: Data }
struct Reply { var value: Data? = nil; var code: String? = nil; var message: String? = nil }
actor Calls { var count = 0; func begin() { count += 1 }; func total() -> Int { count } }
let calls = Calls()
final class NotebookXPCWorker: @unchecked Sendable {
  init(serviceName: String, host: @escaping @Sendable (Int) async -> Reply) {}
  func invalidate() {}
  func execute(_ request: WorkerRequest, deadline: ContinuousClock.Instant, timeoutCode: String) async -> Reply {
    await calls.begin(); try? await Task.sleep(for: .milliseconds(100))
    return Reply(value: request.arguments)
  }
}
actor NotebookMarkupQueue {
  private let serviceName: String
  private var tail: Task<JSONValue, Error>?
  private var tailID: UUID?
  init(serviceName: String) { self.serviceName = serviceName }
  func normalize(_ arguments: JSONValue) async throws -> JSONValue {
    let id = UUID()
    let previous = tail, serviceName = serviceName
    let task = Task<JSONValue, Error> {
      _ = try? await previous?.value
      let worker = NotebookXPCWorker(serviceName: serviceName) { _ in .init(code: "host_unavailable") }
      defer { worker.invalidate() }
      let reply = await worker.execute(.init(id: UUID(), code: "", arguments: try JSONEncoder().encode(arguments)),
        deadline: .now + .seconds(8), timeoutCode: "normalization_timeout")
      if let code = reply.code { throw CollaborationError(code, reply.message ?? "Доверенная нормализация не завершилась.") }
      guard let value = reply.value else { throw CollaborationError("normalization_failed", "Нет результата нормализации.") }
      return try JSONDecoder().decode(JSONValue.self, from: value)
    }
    tail = task
    tailID = id
    // A completed Task retains its result. Drop only our own final tail: a
    // later normalization may already be waiting on it while this awaits.
    defer { if tailID == id { tail = nil; tailID = nil } }
    return try await task.value
  }

}

@main struct Probe {
 static func main() async {
   let queue = NotebookMarkupQueue(serviceName: "fake"), start = ContinuousClock.now
   var tasks: [Task<Int, Error>] = []
   for i in 0..<4 { tasks.append(Task { try await queue.normalize(i) }); try? await Task.sleep(for: .milliseconds(5)) }
   let before = await calls.total(); tasks.forEach { $0.cancel() }
   var results: [Int] = []; for task in tasks { if let value = try? await task.value { results.append(value) } }
   print("exactQueue=true fakeWorker100ms=true workersAtCancel=\(before) workersAfterCancel=\(await calls.total()) results=\(results) elapsed=\(start.duration(to: .now))")
 }
}

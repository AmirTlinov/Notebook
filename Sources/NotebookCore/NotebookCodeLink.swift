import Foundation

/// Click-only navigation in window space. Machine identity is part of a file
/// link, not inferred from a path or from whichever computer is now connected.
public enum NotebookCodeLink: Equatable, Sendable {
  case fragment(UUID)
  case file(NotebookFileAddress, line: Int)
  case conversation(computer: UUID, thread: UUID)

  public init?(url: URL) {
    guard url.scheme == "notebook", url.user == nil, url.password == nil, url.port == nil,
      url.fragment == nil, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
    let paths = url.path.split(separator: "/", omittingEmptySubsequences: false)
    if url.host == "chat" {
      guard paths.count == 3, paths[0].isEmpty, let computer = UUID(uuidString: String(paths[1])),
        let thread = UUID(uuidString: String(paths[2])), components.queryItems == nil else { return nil }
      self = .conversation(computer: computer, thread: thread); return
    }
    guard paths.count == 2, paths[0].isEmpty, let id = UUID(uuidString: String(paths[1])) else { return nil }
    switch url.host {
    case "code":
      guard components.queryItems == nil else { return nil }; self = .fragment(id)
    case "file":
      let items = components.queryItems ?? []
      guard items.count == 4, Set(items.map(\.name)) == Set(["project", "root", "path", "line"]) else { return nil }
      let values = Dictionary(uniqueKeysWithValues: items.compactMap { item in item.value.map { (item.name, $0) } })
      guard values.count == 4, let line = Int(values["line"]!), (1...2_097_152).contains(line) else { return nil }
      let address = NotebookFileAddress(computer: id, project: values["project"]!, root: values["root"]!, path: values["path"]!)
      guard address.isValid, !address.path.isEmpty else { return nil }; self = .file(address, line: line)
    default: return nil
    }
  }
  public var url: URL {
    var value = URLComponents(); value.scheme = "notebook"
    switch self {
    case .fragment(let id): value.host = "code"; value.path = "/" + id.uuidString.lowercased()
    case .conversation(let computer, let thread): value.host = "chat"; value.path = "/" + computer.uuidString.lowercased() + "/" + thread.uuidString.lowercased()
    case .file(let file, let line):
      value.host = "file"; value.path = "/" + file.computer.uuidString.lowercased()
      value.queryItems = [.init(name: "project", value: file.project), .init(name: "root", value: file.root),
        .init(name: "path", value: file.path), .init(name: "line", value: String(line))]
    }
    return value.url!
  }
}

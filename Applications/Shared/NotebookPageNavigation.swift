import Foundation
import Observation

/// Commands go straight to the mounted turn owner. Presence remains the last
/// confirmed landing; pressing an arrow never publishes a page prematurely.
@Observable @MainActor
final class NotebookPageNavigation {
  enum Command { case step(Int), jump(Int), cancel }
  struct Status {
    let ownerID: UUID
    let target: Int
    let failure: PageTurnPreparationFailure?
  }
  private(set) var status: Status?
  private struct Binding {
    let id: UUID
    let source: String
    let send: @MainActor (Command) -> Bool
  }
  @ObservationIgnored private var bindings: [UUID: Binding] = [:]

  func bind(_ id: UUID, ownerID: UUID, source: String, send: @escaping @MainActor (Command) -> Bool) {
    bindings[ownerID] = .init(id: id, source: source, send: send)
  }
  func unbind(_ id: UUID) {
    let retired = Set(bindings.filter { $0.value.id == id }.keys)
    bindings = bindings.filter { $0.value.id != id }
    Task { @MainActor [weak self] in
      guard let self, let owner = status?.ownerID, retired.contains(owner), bindings[owner] == nil else { return }
      status = nil
    }
  }
  @discardableResult
  func send(_ command: Command, ownerID: UUID, source: String) -> Bool {
    guard let binding = bindings[ownerID], binding.source == source else { return false }
    return binding.send(command)
  }
  func isBound(ownerID: UUID, source: String) -> Bool { bindings[ownerID]?.source == source }
  func report(_ value: Status?, ownerID: UUID, controllerID: UUID, source: String) {
    guard let binding = bindings[ownerID], binding.id == controllerID, binding.source == source else { return }
    if let value { status = value }
    else if status?.ownerID == ownerID { status = nil }
  }
}

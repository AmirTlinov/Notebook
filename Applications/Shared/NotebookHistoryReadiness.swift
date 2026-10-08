import Foundation
import Observation
import NotebookCore

/// The workspace's one admission phase for a coordinated history cut. Closing
/// authorship does not close transport, acknowledgements, or accepted writes.
@MainActor
@Observable
final class NotebookHistoryReadiness {
  struct Request: Equatable, Sendable {
    let id: UUID
    let workspaceID: UUID
    let devices: Set<UUID>
    let acceptedGeneration: UInt64
  }

  enum Phase: Equatable {
    case open
    case draining(Request)
    case sealed(Request, writerSeal: UUID)
    case resuming(Request)
  }

  private(set) var phase = Phase.open
  @ObservationIgnored var coordination: Coordination?

  var permitsAuthorship: Bool { phase == .open }
  var authoredAdmissionError: CollaborationError? {
    permitsAuthorship ? nil : .init("history_readiness_pending",
      "Дождитесь завершения сверки истории.")
  }

  func begin(_ request: Request) throws {
    guard request.devices.count == 2 else {
      throw CollaborationError("invalid_history_fleet", "Сверка требует двух установленных устройств.")
    }
    switch phase {
    case .open: phase = .draining(request)
    case .draining(let current), .sealed(let current, _), .resuming(let current):
      guard current == request else {
        throw CollaborationError("history_readiness_pending", "Сверка истории уже начата.")
      }
    }
  }

  func seal(_ request: Request, writerSeal: UUID) throws {
    guard phase == .draining(request) else {
      throw CollaborationError("stale_history_readiness", "Граница сверки истории изменилась.")
    }
    phase = .sealed(request, writerSeal: writerSeal)
  }

  func finish(_ request: Request, releaseWriter: (UUID) -> Void) throws {
    let seal: UUID?
    switch phase {
    case .draining(let current) where current == request: seal = nil
    case .sealed(let current, let value) where current == request: seal = value
    case .resuming(let current) where current == request: seal = nil
    default:
      throw CollaborationError("stale_history_readiness", "Запрос сверки истории уже завершён.")
    }
    if let seal { releaseWriter(seal) }
    phase = .open
  }

  func releaseWriterForResume(_ request: Request, releaseWriter: (UUID) -> Void) throws {
    guard case .sealed(let current, let seal) = phase, current == request else {
      throw CollaborationError("stale_history_readiness", "Запечатанная граница сверки изменилась.")
    }
    releaseWriter(seal)
    phase = .resuming(request)
  }
}

import Foundation

/// Durability and display are different facts. Until native installation, the
/// exact saved text remains available even if WebKit cannot present it.
struct DocumentSavePresentation: Equatable {
  enum Phase: Equatable { case saving, saved, installed }
  let sessionID: UUID
  let documentID: UUID
  let blockID: String
  var phase: Phase
  var source: String?
}

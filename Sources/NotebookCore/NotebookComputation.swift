import Foundation

/// An interpretation names an immutable cut of ink, not a second editable document.
public struct NotebookComputationSource: Codable, Equatable, Sendable {
  public let notebookID: UUID
  public let pageID: UUID
  public let region: PageRect
  public let drawingStamp: VersionStamp
  public let inkHash: String

  var isValid: Bool {
    drawingStamp.counter <= VersionStamp.maximumCounter && NotebookPageOrderRegister.validHash(inkHash)
      && region.x.isFinite && region.y.isFinite && region.width.isFinite && region.height.isFinite
      && region.x >= 0 && region.y >= 0 && region.width > 0 && region.height > 0
      && region.x + region.width <= PageSize.maximumDimension
      && region.y + region.height <= PageSize.maximumDimension
  }
}

/// Half-open indices refer to the original samples, before raster clipping.
public struct NotebookInkSampleRange: Codable, Equatable, Sendable {
  public let strokeID: UUID
  public let lowerBound: Int
  public let upperBound: Int

  public init(strokeID: UUID, lowerBound: Int, upperBound: Int) {
    self.strokeID = strokeID; self.lowerBound = lowerBound; self.upperBound = upperBound
  }

  var isValid: Bool { lowerBound >= 0 && upperBound > lowerBound && upperBound <= 1_000_000 }
}

/// A bounded read snapshot. The native ink renderer must clip this ordered pen/
/// eraser drawing to source.region; feeding pen samples alone changes the source.
public struct NotebookComputationInk: Sendable {
  public let source: NotebookComputationSource
  public let pageSize: PageSize
  public let drawing: PageInkDrawing
  public var sampleRanges: [NotebookInkSampleRange] {
    drawing.actions.map { .init(strokeID: $0.id, lowerBound: 0, upperBound: $0.samples.count) }
  }
}

public struct NotebookRecognitionCandidate: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable { case mathematics, python }
  public let kind: Kind
  /// Exact UTF-8 output: no trimming, case folding, indentation or sign repair.
  public let text: String
  /// Empty means region-level recognition, never invented symbol alignment.
  public let bindings: [NotebookRecognitionBinding]

  public init(kind: Kind, text: String, bindings: [NotebookRecognitionBinding] = []) {
    self.kind = kind; self.text = text; self.bindings = bindings
  }

  var isValid: Bool {
    guard !text.isEmpty, text.utf8.count <= 32_768, !text.utf8.contains(0), bindings.count <= 2_048 else { return false }
    let bytes = Array(text.utf8)
    func boundary(_ offset: Int) -> Bool {
      offset >= 0 && offset <= bytes.count && (offset == bytes.count || bytes[offset] & 0xc0 != 0x80)
    }
    return bindings.allSatisfy {
      $0.utf8LowerBound < $0.utf8UpperBound && boundary($0.utf8LowerBound) && boundary($0.utf8UpperBound)
        && !$0.samples.isEmpty && $0.samples.count <= 64 && $0.samples.allSatisfy(\.isValid)
    }
  }
}

public struct NotebookRecognitionBinding: Codable, Equatable, Sendable {
  public let utf8LowerBound: Int
  public let utf8UpperBound: Int
  public let samples: [NotebookInkSampleRange]

  public init(utf8LowerBound: Int, utf8UpperBound: Int, samples: [NotebookInkSampleRange]) {
    self.utf8LowerBound = utf8LowerBound; self.utf8UpperBound = utf8UpperBound; self.samples = samples
  }
}

public struct NotebookRecognitionCandidates: Codable, Equatable, Sendable {
  public let recognizer: String
  public let candidates: [NotebookRecognitionCandidate]

  public init(recognizer: String, candidates: [NotebookRecognitionCandidate]) {
    self.recognizer = recognizer; self.candidates = candidates
  }

  var isValid: Bool {
    !recognizer.isEmpty && recognizer.utf8.count <= 256 && (1...4).contains(candidates.count)
      && candidates.allSatisfy(\.isValid)
      && candidates.reduce(0, { $0 + $1.text.utf8.count }) <= 65_536
      && candidates.reduce(0, { $0 + $1.bindings.reduce(0, { $0 + $1.samples.count }) }) <= 1_024
      && ((try? NotebookStore.storageEncoder.encode(self).count) ?? Int.max) <= 196_608
  }
}

/// The page owns this addressed record and its tombstone. Order is assigned once
/// at activation; recognition, cancellation and movement never assign another slot.
public struct NotebookComputation: Codable, Equatable, Identifiable, Sendable {
  public enum Phase: String, Codable, Sendable {
    case awaitingRecognition, recognizing, needsReview, stopped, removed
  }
  public let id: UUID
  public let origin: NotebookComputationSource
  public let order: VersionStamp
  public internal(set) var source: NotebookComputationSource
  public internal(set) var stamp: VersionStamp
  public internal(set) var predecessor: String?
  public internal(set) var phase: Phase
  public internal(set) var attemptID: UUID?
  public internal(set) var recognition: NotebookRecognitionCandidates?

  public var revision: String { get throws { try collaborationHash(self) } }

  var isValid: Bool {
    guard origin.isValid, source.isValid, order.counter > 0, order.counter <= stamp.counter,
      stamp.counter <= VersionStamp.maximumCounter, origin.notebookID == source.notebookID,
      origin.pageID == source.pageID, origin.region == source.region else { return false }
    if phase != .awaitingRecognition {
      guard stamp.counter > order.counter, let predecessor, NotebookPageOrderRegister.validHash(predecessor) else { return false }
    }
    switch phase {
    case .awaitingRecognition: return attemptID == nil && recognition == nil && predecessor == nil && source == origin && stamp == order
    case .recognizing: return attemptID != nil && recognition == nil
    case .needsReview: return attemptID != nil && recognition?.isValid == true
    case .stopped, .removed: return recognition == nil
    }
  }

  func joining(_ other: Self) throws -> Self {
    guard id == other.id, origin == other.origin, order == other.order,
      isValid, other.isValid else { throw NotebookStorageError.transactionConflict }
    if stamp == other.stamp {
      guard self == other else { throw NotebookStorageError.transactionConflict }
      return self
    }
    // Removal is permanent for this UUID, including a concurrent recognition.
    if phase == .removed || other.phase == .removed {
      if phase != other.phase { return phase == .removed ? self : other }
    }
    return stamp > other.stamp ? self : other
  }

  static func ordered(_ left: Self, _ right: Self) -> Bool {
    left.order == right.order ? left.id.uuidString < right.id.uuidString : left.order < right.order
  }
}

public struct NotebookComputationRead: Codable, Equatable, Sendable {
  public let computation: NotebookComputation
  /// Derived from current ink in the same WAL snapshot, never a saved ready bit.
  public let sourceIsCurrent: Bool
}

/// Recognition runs outside the persistence queue. Publication rechecks both the
/// record revision and the ink source; cancellation cannot be undone by a callback.
public struct NotebookRecognitionInput: Sendable {
  public let computationID: UUID
  public let revision: String
  public let attemptID: UUID
  public let ink: NotebookComputationInk

  public func preparing(_ output: NotebookRecognitionCandidates) throws -> PreparedNotebookRecognition {
    guard output.isValid else { throw CollaborationError("invalid_recognition", "Распознаватель вернул некорректные варианты.") }
    let strokes = Dictionary(uniqueKeysWithValues: ink.drawing.actions.map { ($0.id, $0) })
    for candidate in output.candidates {
      for binding in candidate.bindings {
        for range in binding.samples {
          guard let stroke = strokes[range.strokeID], stroke.tool == .pen,
            range.upperBound <= stroke.samples.count else {
            throw CollaborationError("invalid_recognition", "Привязка знака должна называть исходные точки ручки.")
          }
        }
      }
    }
    return .init(input: self, output: output)
  }
}

/// Only validation against the immutable input creates this publication packet.
/// It retains no drawing or image, so waiting for SQL does not retain OCR memory.
public struct PreparedNotebookRecognition: Sendable {
  let computationID: UUID
  let revision: String
  let attemptID: UUID
  let source: NotebookComputationSource
  let output: NotebookRecognitionCandidates

  fileprivate init(input: NotebookRecognitionInput, output: NotebookRecognitionCandidates) {
    computationID = input.computationID; revision = input.revision; attemptID = input.attemptID
    source = input.ink.source; self.output = output
  }
}

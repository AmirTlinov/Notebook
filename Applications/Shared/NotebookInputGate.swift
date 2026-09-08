import Foundation

typealias NotebookInputCompletion = @MainActor @Sendable () -> Void
typealias NotebookInputFinisher = (_ waitsForPublication: Bool, @escaping NotebookInputCompletion) -> Void

@MainActor
final class NotebookInputGate {
  private var pageFinishers: [UUID: NotebookInputFinisher] = [:]
  private var currentPageSource: UUID?
  private var activePencilSources: Set<UUID> = []
  private(set) var pencilGeneration: UInt64 = 0
  private var fingerCancellations: [UUID: @MainActor () -> Void] = [:]
  private var commandsAfterPencil: [NotebookInputCompletion] = []
  private var contactSources: Set<UUID> = []
  private var settlingTask: Task<Void, Never>?
  private var activityGeneration: UInt64 = 0
  private(set) var isActive = false
  var hasActivePencil: Bool { !activePencilSources.isEmpty }
  var onActivityChange: ((Bool) -> Void)?

  func beginContact(source: UUID) {
    contactSources.insert(source)
    updateActivity()
  }

  func endContact(source: UUID) {
    contactSources.remove(source)
    updateActivity()
  }

  private func updateActivity() {
    activityGeneration &+= 1
    let generation = activityGeneration
    settlingTask?.cancel()
    settlingTask = nil
    if !contactSources.isEmpty || !activePencilSources.isEmpty {
      if !isActive { isActive = true; onActivityChange?(true) }
      return
    }
    guard isActive else { return }
    // UIKit delivers the same lift to several owners. Let their commits finish
    // before merging the incoming cut, including the current page's ink tail.
    settlingTask = Task { [weak self] in
      await Task.yield()
      guard !Task.isCancelled, let self else { return }
      performAfterPageInput { [weak self] in
        guard let self, activityGeneration == generation, contactSources.isEmpty, activePencilSources.isEmpty else { return }
        isActive = false
        settlingTask = nil
        onActivityChange?(false)
      }
    }
  }

  func registerPageFinisher(
    source: UUID,
    _ finisher: @escaping NotebookInputFinisher
  ) {
    pageFinishers[source] = finisher
  }

  func unregisterPageFinisher(source: UUID) {
    pageFinishers[source] = nil
    if currentPageSource == source { currentPageSource = nil }
  }

  /// Several live sheets may be mounted for a curl, but only the sheet that
  /// currently accepts Pencil is allowed to delay a following command.
  func setCurrentPageSource(_ source: UUID, isCurrent: Bool) {
    if isCurrent {
      currentPageSource = source
    } else if currentPageSource == source {
      currentPageSource = nil
    }
  }

  func performAfterPageInput(_ action: @escaping NotebookInputCompletion) {
    guard activePencilSources.isEmpty else {
      commandsAfterPencil.append(action)
      return
    }
    let generation = pencilGeneration
    finishPage(waitsForPublication: true) {
      // The page finisher captures one serialization tail. A later contact
      // can already be lifted when that older tail completes.
      if !self.activePencilSources.isEmpty || self.pencilGeneration != generation {
        self.performAfterPageInput(action)
      } else {
        action()
      }
    }
  }

  /// Camera handoff waits only for the measured contact, never for its archive.
  func performAfterPageContact(_ action: @escaping NotebookInputCompletion) {
    finishPage(waitsForPublication: false, action)
  }

  private func finishPage(waitsForPublication: Bool, _ action: @escaping NotebookInputCompletion) {
    if let currentPageSource,
      let pageFinisher = pageFinishers[currentPageSource]
    {
      pageFinisher(waitsForPublication, action)
    } else {
      action()
    }
  }

  /// Pencil owns the surface from contact to lift. A later finger command may
  /// wait for the page finisher, while any pair overlapping this contact stays
  /// part of the hand movement rather than becoming a second command.
  func beginPencilAction(source: UUID) {
    guard activePencilSources.insert(source).inserted else { return }
    pencilGeneration &+= 1
    updateActivity()
    // Cancel a camera already moving before this Pencil-down synchronously.
    // Waiting for SwiftUI or the next finger event would move measured ink.
    for cancel in Array(fingerCancellations.values) { cancel() }
  }

  func registerFingerCancellation(source: UUID, _ cancel: @escaping @MainActor () -> Void) {
    fingerCancellations[source] = cancel
  }

  func unregisterFingerCancellation(source: UUID) {
    fingerCancellations.removeValue(forKey: source)
  }

  func endPencilAction(source: UUID) {
    activePencilSources.remove(source)
    updateActivity()
    guard activePencilSources.isEmpty, !commandsAfterPencil.isEmpty else { return }
    let commands = commandsAfterPencil
    commandsAfterPencil = []
    for command in commands { performAfterPageInput(command) }
  }

  func beginFingerSequence() -> UInt64? {
    activePencilSources.isEmpty ? pencilGeneration : nil
  }

  func acceptsFingerSequence(_ revision: UInt64) -> Bool {
    activePencilSources.isEmpty && revision == pencilGeneration
  }
}

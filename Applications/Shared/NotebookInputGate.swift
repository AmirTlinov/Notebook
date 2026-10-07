import Foundation

typealias NotebookInputCompletion = @MainActor @Sendable () -> Void
typealias NotebookInputFinisher = (_ waitsForPublication: Bool, @escaping NotebookInputCompletion) -> Void

@MainActor
final class NotebookInputGate {
  /// Only an admitted, isolated Simulator launch may label measured direct
  /// contacts as Pencil input. Physical devices always use UITouch's real type.
  let simulatesPencilContacts: Bool
  init(simulatesPencilContacts: Bool = false) {
    #if targetEnvironment(simulator)
      self.simulatesPencilContacts = simulatesPencilContacts
    #else
      self.simulatesPencilContacts = false
    #endif
  }
  enum ContactKind { case finger, pencil }
  enum FingerContactOwner: Equatable {
    case scene
    /// Selected material or an explicit pickup reserves this finger. A
    /// second finger may navigate, but never revives the cancelled object drag.
    case sceneObject
    /// A recognized Undo hold changes material; it does not freeze the scene
    /// it is changing. The contact observer still owns physical lift.
    case history
    /// A browser link owns a tap, not a drag or material hold. Once native
    /// camera motion or a lift wins, UIKit cancels the original link contact.
    case webLink(ObjectIdentifier)
    /// A program owns one-finger input and pairs inside its own runtime. A
    /// pair spanning paper or another program belongs to the scene camera.
    case webInput(ObjectIdentifier)
    case nativeInput(ObjectIdentifier)

    var webOwnerID: ObjectIdentifier? {
      switch self {
      case .webInput(let id), .webLink(let id): id
      default: nil
      }
    }

    var permitsSceneNavigation: Bool {
      switch self {
      case .scene, .sceneObject, .webLink: true
      case .history, .webInput, .nativeInput: false
      }
    }
  }
  // Identity only: neither a UITouch nor its native view is retained. The
  // window contact observer retires these claims at lift/cancellation.
  private var fingerContactOwners: [ObjectIdentifier: FingerContactOwner] = [:]
  private var fingerSequenceHadMultipleContacts = false
  enum NavigationKind: Equatable { case cameraPan, cameraPinch, pageTurn }
  private struct NavigationClaim {
    let source: UUID
    let kind: NavigationKind
    let cancel: @MainActor () -> Void
  }
  private var navigationClaim: NavigationClaim?
  private var navigationContacts: [UUID: [ObjectIdentifier: FingerContactOwner]] = [:]

  /// A recognizer consumes the final sample even if the passive observer has
  /// already seen physical lift in the same UIKit event. Retain only identities
  /// and their admitted routing, until that recognizer finishes or cancels.
  func retainNavigationContacts(source: UUID, contacts: Set<ObjectIdentifier>) {
    for contact in contacts {
      if let owner = fingerContactOwners[contact] { navigationContacts[source, default: [:]][contact] = owner }
    }
  }

  func navigationContactOwner(source: UUID, contact: ObjectIdentifier) -> FingerContactOwner? {
    fingerContactOwners[contact] ?? navigationContacts[source]?[contact]
  }

  func ownsNavigation(source: UUID) -> Bool { navigationClaim?.source == source }

  /// Recognizers report an intent; the gate transfers the accepted physical
  /// contact. A pinch may take over a pan or curl, including its settling tail.
  /// A late horizontal sample cannot take an already accepted pinch back.
  @discardableResult
  func claimNavigation(source: UUID, kind: NavigationKind, contacts: Set<ObjectIdentifier>,
    cancel: @escaping @MainActor () -> Void) -> Bool {
    guard permitsNewContact, !hasActivePencil else { return false }
    if navigationClaim?.source == source { return true }
    let owners = contacts.map { navigationContactOwner(source: source, contact: $0) }
    if kind == .cameraPinch {
      let includesWebInput = owners.contains { if case .webInput? = $0 { true } else { false } }
      let webOwners = owners.compactMap { $0?.webOwnerID }
      // A control plus a link in the same runtime is still that runtime's
      // pair. Links without a control retain their existing scene navigation.
      guard owners.allSatisfy({ owner in
        if case .webInput? = owner { return true }
        return owner?.permitsSceneNavigation == true
      }), !(includesWebInput && webOwners.count == 2 && webOwners[0] == webOwners[1]) else { return false }
    } else {
      guard owners.allSatisfy({ $0?.permitsSceneNavigation == true }) else { return false }
    }
    switch kind {
    case .cameraPan:
      guard contacts.count == 1, !fingerSequenceHadMultipleContacts,
        owners.allSatisfy({ $0 != .sceneObject }) else { return false }
    case .cameraPinch: guard contacts.count == 2 else { return false }
    case .pageTurn:
      guard owners.allSatisfy({ $0 != .sceneObject }) else { return false }
    }
    if let previous = navigationClaim {
      guard kind == .cameraPinch, previous.kind != .cameraPinch else { return false }
    }
    let previous = navigationClaim
    navigationClaim = .init(source: source, kind: kind, cancel: cancel)
    previous?.cancel()
    return navigationClaim?.source == source
  }

  func endNavigation(source: UUID) {
    if navigationClaim?.source == source { navigationClaim = nil }
    navigationContacts[source] = nil
  }
  var admittedFingerContactCount: Int { fingerContactOwners.count }
  /// A remaining finger after zoom is not a fresh pickup, even if another
  /// recognizer has already reset. Only the physical observer ends a sequence.
  var permitsObjectPickup: Bool {
    permitsNewContact && !hasActivePencil && navigationClaim == nil && !fingerSequenceHadMultipleContacts
  }
  var hasSceneObjectContact: Bool { fingerContactOwners.values.contains(.sceneObject) }
  var hasOnlyHistoryContacts: Bool {
    !hasActivePencil && fingerContactOwners.count == 2
      && fingerContactOwners.values.allSatisfy { $0 == .history }
  }

  func claimHistoryContacts(_ contacts: Set<ObjectIdentifier>, nativeInput: ObjectIdentifier? = nil) {
    guard contacts.count == 2, !hasPencilContact, contacts.allSatisfy({ contact in
      switch fingerContactOwners[contact] {
      case .scene?, .webLink?: nativeInput == nil
      case .nativeInput(let owner)?: owner == nativeInput
      default: false
      }
    }) else { return }
    for contact in contacts { fingerContactOwners[contact] = .history }
  }

  func releaseHistoryContacts(_ contacts: Set<ObjectIdentifier>, nativeInput: ObjectIdentifier? = nil) {
    for contact in contacts where fingerContactOwners[contact] == .history {
      fingerContactOwners[contact] = nativeInput.map(FingerContactOwner.nativeInput) ?? .scene
    }
  }

  /// Selection refines a selected hit or a deliberate pickup. Native controls
  /// cannot be claimed, and only the window contact observer retires the claim.
  func claimSceneObjectContact(_ contact: ObjectIdentifier) {
    guard permitsObjectPickup else { return }
    switch fingerContactOwners[contact] {
    case .scene?, .webLink?: break
    default: return
    }
    fingerContactOwners[contact] = .sceneObject
  }

  func permitsSingleFingerNavigation(_ contact: ObjectIdentifier) -> Bool {
    guard let owner = fingerContactOwners[contact] else { return false }
    return owner.permitsSceneNavigation && owner != .sceneObject
  }

  var permitsPageNavigation: Bool {
    permitsNewContact && !hasActivePencil && (navigationClaim == nil || navigationClaim?.kind == .pageTurn) && !hasSceneObjectContact
      && !fingerContactOwners.values.contains {
        switch $0 {
        case .nativeInput, .webInput: true
        default: false
        }
      }
  }

  func fingerContactOwner(for contact: ObjectIdentifier,
    resolve: () -> FingerContactOwner) -> FingerContactOwner {
    if let owner = fingerContactOwners[contact] { return owner }
    let owner = resolve()
    fingerContactOwners[contact] = owner
    if fingerContactOwners.count > 1 { fingerSequenceHadMultipleContacts = true }
    return owner
  }

  func endFingerContacts(_ contacts: Set<ObjectIdentifier>) {
    for contact in contacts { fingerContactOwners[contact] = nil }
    if fingerContactOwners.isEmpty { fingerSequenceHadMultipleContacts = false }
  }

  func transferFingerContacts(_ contacts: Set<ObjectIdentifier>, to next: NotebookInputGate) {
    let hadMultipleContacts = fingerSequenceHadMultipleContacts
    for contact in contacts {
      guard let owner = fingerContactOwners.removeValue(forKey: contact) else { continue }
      _ = next.fingerContactOwner(for: contact) { owner }
      if hadMultipleContacts { next.fingerSequenceHadMultipleContacts = true }
    }
    if fingerContactOwners.isEmpty { fingerSequenceHadMultipleContacts = false }
  }
  enum ControlContactIntent: Equatable { case startsSceneIntent, continuesSceneIntent }
  private struct ControlRegion {
    let intent: ControlContactIntent
    let contains: @MainActor (CGPoint, ContactKind) -> Bool
  }
  private var controlRegions: [UUID: ControlRegion] = [:]
  private var pageFinishers: [UUID: NotebookInputFinisher] = [:]
  private var currentPageSource: UUID?
  private var activePencilSources: Set<UUID> = []
  private var downPencilSources: Set<UUID> = []
  private(set) var pencilGeneration: UInt64 = 0
  private var fingerCancellations: [UUID: @MainActor () -> Void] = [:]
  private var commandsAfterPencil: [NotebookInputCompletion] = []
  private var commandsAfterIdle: [NotebookInputCompletion] = []
  private var publicationWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
  private var contactSources: Set<UUID> = []
  private var settlingTask: Task<Void, Never>?
  private var activityGeneration: UInt64 = 0
  private(set) var isActive = false
  var hasActivePencil: Bool { !activePencilSources.isEmpty }
  var hasPencilContact: Bool { !downPencilSources.isEmpty }
  private var newContactAdmission: @MainActor () -> Bool = { true }
  var permitsNewContact: Bool { newContactAdmission() }
  var onActivityChange: ((Bool) -> Void)?
  var onNewAcceptedContact: (() -> Void)?
  private(set) var acceptedContactGeneration: UInt64 = 0

  /// Native down events are distinct from aggregate activity: an existing
  /// Pencil or a pose animation may keep activity true across another contact.
  func notifyAcceptedContact() {
    guard permitsNewContact else { return }
    acceptedContactGeneration &+= 1
    onNewAcceptedContact?()
  }

  /// The model's lifecycle remains the only admission state. Closing it never
  /// cancels a contact already measured by this gate or skips its final delivery.
  func bindNewContactAdmission(_ admission: @escaping @MainActor () -> Bool) {
    newContactAdmission = admission
  }

  /// Native control bounds are evaluated when a contact starts. A card can
  /// move with the keyboard without changing the scene camera or taking a
  /// contact which already belongs to Pencil outside it.
  func registerControlRegion(source: UUID, intent: ControlContactIntent = .startsSceneIntent,
    contains: @escaping @MainActor (CGPoint, ContactKind) -> Bool) {
    controlRegions[source] = .init(intent: intent, contains: contains)
  }

  func unregisterControlRegion(source: UUID) { controlRegions[source] = nil }

  func permitsSceneContact(at windowPoint: CGPoint, kind: ContactKind, excludingControl source: UUID? = nil) -> Bool {
    permitsNewContact && !controlRegions.contains { $0.key != source && $0.value.contains(windowPoint, kind) }
  }

  /// Grips and scene controls start a new intent; a menu continues the intent
  /// captured when it opened. Both retain their existing routing exclusion.
  func permitsSceneIntent(at windowPoint: CGPoint, kind: ContactKind) -> Bool {
    permitsNewContact && !controlRegions.values.contains {
      $0.intent == .continuesSceneIntent && $0.contains(windowPoint, kind)
    }
  }

  func beginContact(source: UUID) {
    guard contactSources.contains(source) || permitsNewContact else { return }
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
        let commands = commandsAfterIdle
        commandsAfterIdle = []
        for command in commands { performAfterIdle(command) }
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
      // A finisher joins the deliveries known when it is called. A later
      // contact can already be lifted before those deliveries complete.
      if !self.activePencilSources.isEmpty || self.pencilGeneration != generation {
        self.performAfterPageInput(action)
      } else {
        action()
      }
    }
  }

  /// Native commands wait for their own released contact and its publication
  /// marker. They do not bypass the writer's human-input barrier.
  func performAfterIdle(_ action: @escaping NotebookInputCompletion) {
    if isActive { commandsAfterIdle.append(action); return }
    performAfterPageInput { [self] in
      if isActive { commandsAfterIdle.append(action) } else { action() }
    }
  }

  /// Cancellation revokes a navigation subscriber, never the measured contact
  /// or its accepted publication. Queued callbacks retain only a weak owner/id.
  func waitUntilIdle() async -> Bool { await waitForPublication(idle: true) }
  func waitUntilPageInputFinishes() async -> Bool { await waitForPublication(idle: false) }

  private func waitForPublication(idle: Bool) async -> Bool {
    let id = UUID()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard !Task.isCancelled else { continuation.resume(returning: false); return }
        publicationWaiters[id] = continuation
        let completed: NotebookInputCompletion = { [weak self] in
          self?.publicationWaiters.removeValue(forKey: id)?.resume(returning: true)
        }
        if idle { performAfterIdle(completed) } else { performAfterPageInput(completed) }
      }
    } onCancel: { [weak self] in
      Task { @MainActor in self?.publicationWaiters.removeValue(forKey: id)?.resume(returning: false) }
    }
  }

  /// Camera handoff waits only for the measured contact, never for its archive.
  func performAfterPageContact(_ action: @escaping NotebookInputCompletion) {
    finishPage(waitsForPublication: false, action)
  }

  private func finishPage(waitsForPublication: Bool, _ action: @escaping NotebookInputCompletion) {
    // A code document may accept Pencil above a still-mounted notebook. Finish
    // the actual active owner as well as the current page, without replacing
    // that page's registration or making code navigation a paper transition.
    let sources = activePencilSources.union(currentPageSource.map { [$0] } ?? [])
    let finishers = sources.compactMap { pageFinishers[$0] }
    guard !finishers.isEmpty else { action(); return }
    var remaining = finishers.count
    for finisher in finishers {
      finisher(waitsForPublication) { remaining -= 1; if remaining == 0 { action() } }
    }
  }

  /// Pencil owns the surface from contact to lift. A later finger command may
  /// wait for the page finisher, while any pair overlapping this contact stays
  /// part of the hand movement rather than becoming a second command.
  @discardableResult
  func beginPencilAction(source: UUID) -> Bool {
    if activePencilSources.contains(source) { return true }
    guard permitsNewContact else { return false }
    activePencilSources.insert(source)
    downPencilSources.insert(source)
    let navigation = navigationClaim; navigationClaim = nil; navigation?.cancel()
    pencilGeneration &+= 1
    notifyAcceptedContact()
    updateActivity()
    // Cancel a camera already moving before this Pencil-down synchronously.
    // Waiting for SwiftUI or the next finger event would move measured ink.
    for cancel in Array(fingerCancellations.values) { cancel() }
    return true
  }

  func registerFingerCancellation(source: UUID, _ cancel: @escaping @MainActor () -> Void) {
    fingerCancellations[source] = cancel
  }

  func unregisterFingerCancellation(source: UUID) {
    fingerCancellations.removeValue(forKey: source)
  }

  func endPencilAction(source: UUID) {
    downPencilSources.remove(source)
    activePencilSources.remove(source)
    updateActivity()
    guard activePencilSources.isEmpty, !commandsAfterPencil.isEmpty else { return }
    let commands = commandsAfterPencil
    commandsAfterPencil = []
    for command in commands { performAfterPageInput(command) }
  }

  func beginFingerSequence() -> UInt64? {
    permitsNewContact && downPencilSources.isEmpty ? pencilGeneration : nil
  }

  func acceptsFingerSequence(_ revision: UInt64) -> Bool {
    downPencilSources.isEmpty && revision == pencilGeneration
  }

  /// Estimates retain the released action's publication fence, while an
  /// explicit following command may finish its latest measured contents.
  func releasePencilContact(source: UUID) { downPencilSources.remove(source) }
}

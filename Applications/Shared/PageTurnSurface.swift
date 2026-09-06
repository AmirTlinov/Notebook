import SwiftUI

#if os(iOS)
  import UIKit
#elseif os(macOS)
  import AppKit
#endif

private struct RendersSettledPageSnapshotKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  var rendersSettledPageSnapshot: Bool {
    get { self[RendersSettledPageSnapshotKey.self] }
    set { self[RendersSettledPageSnapshotKey.self] = newValue }
  }
}

/// A small callback object keeps render readiness outside durable page state.
/// Metal and WebKit report when their exact mounted page has presented once.
@MainActor
final class PageTurnReadiness {
  private let handler: @MainActor (Bool) -> Void

  init(_ handler: @escaping @MainActor (Bool) -> Void) {
    self.handler = handler
  }

  func callAsFunction(_ ready: Bool) {
    handler(ready)
  }
}

/// Chooses the small set of live pages that must already have a first frame.
///
/// An adjacent turn keeps both immediate neighbours. Once a turn has a
/// direction, the page beyond its landing point is prepared during the turn,
/// rather than after the landing. This is the difference between a continuous
/// stack of paper and a stack that pauses to manufacture its next sheet.
enum PageTurnPrewarmWindow {
  static let capacity = 4

  static func indices(
    displayedIndex: Int,
    anticipatedIndex: Int?,
    lastDirection: Int?,
    pageCount: Int
  ) -> Set<Int> {
    guard pageCount > 0 else { return [] }
    var result = Set<Int>()
    insert(displayedIndex, pageCount: pageCount, into: &result)

    // The page under the hand, its landing and the page beyond the landing
    // precede speculative neighbours, including for an explicit distant jump.
    if let anticipatedIndex {
      insert(anticipatedIndex, pageCount: pageCount, into: &result)
      let direction = sign(anticipatedIndex - displayedIndex)
      if direction != 0 {
        insert(
          anticipatedIndex + direction,
          pageCount: pageCount,
          into: &result
        )
      }
    } else if let lastDirection, sign(lastDirection) != 0 {
      insert(
        displayedIndex + sign(lastDirection) * 2,
        pageCount: pageCount,
        into: &result
      )
    }
    insert(displayedIndex - 1, pageCount: pageCount, into: &result)
    insert(displayedIndex + 1, pageCount: pageCount, into: &result)

    // At a finite edge there is no forward sheet to use the remaining slot.
    // Keep the nearest reverse sheets instead of destroying a ready page only
    // to rebuild it on the next turn. Work is bounded independently of count.
    for distance in 1..<capacity where result.count < min(capacity, pageCount) {
      insert(displayedIndex - distance, pageCount: pageCount, into: &result)
      insert(displayedIndex + distance, pageCount: pageCount, into: &result)
    }
    return result
  }

  private static func insert(
    _ index: Int,
    pageCount: Int,
    into result: inout Set<Int>
  ) {
    guard result.count < capacity, index >= 0, index < pageCount else { return }
    result.insert(index)
  }

  private static func sign(_ value: Int) -> Int {
    value == 0 ? 0 : (value > 0 ? 1 : -1)
  }
}

/// Keeps the page under the hand authoritative while its durable selection
/// catches up. Several quick landings may be acknowledged one by one; an old
/// acknowledgement must never pull the visible stack backwards.
struct PageTurnSelectionTracker {
  private(set) var displayedIndex: Int
  private(set) var pendingLocalTargets: [Int] = []
  private var localOrigin: Int?

  init(displayedIndex: Int) {
    self.displayedIndex = displayedIndex
  }

  var awaitsLocalAcknowledgement: Bool {
    !pendingLocalTargets.isEmpty
  }

  mutating func reset(to index: Int) {
    displayedIndex = index
    clearPendingLandings()
  }

  mutating func recordLocalLanding(at index: Int) {
    guard index != displayedIndex else { return }
    if pendingLocalTargets.isEmpty { localOrigin = displayedIndex }
    displayedIndex = index
    pendingLocalTargets.append(index)
  }

  mutating func recordExternalLanding(at index: Int) {
    displayedIndex = index
    clearPendingLandings()
  }

  /// Returns a visual target only when the model change came from somewhere
  /// other than the still-being-acknowledged local page turns.
  mutating func externalTarget(forModelIndex modelIndex: Int) -> Int? {
    if modelIndex == displayedIndex {
      clearPendingLandings()
      return nil
    }
    if !pendingLocalTargets.isEmpty {
      if modelIndex == localOrigin { return nil }
      if let acknowledged = pendingLocalTargets.firstIndex(of: modelIndex) {
        pendingLocalTargets.removeFirst(acknowledged + 1)
        if pendingLocalTargets.isEmpty { localOrigin = nil }
        return nil
      }
    }
    clearPendingLandings()
    return modelIndex
  }

  private mutating func clearPendingLandings() {
    pendingLocalTargets.removeAll(keepingCapacity: true)
    localOrigin = nil
  }
}

/// The only owner of a page turn. Notebook and document code provide pages and
/// accept a completed selection; they never animate or replace a page.
///
/// Both platform executors keep nearby pages mounted and move the exact rendered
/// page under the hand. On iPad UIKit owns the system curl; on Mac the native
/// Core Animation surface owns the equivalent trackpad motion.
struct PageTurnSurface: View {
  @Environment(\.rendersSettledPageSnapshot) private var rendersSettledSnapshot

  let ownerID: UUID
  let pageCount: Int
  let selectedIndex: Int
  let allowsTrailingPageCreation: Bool
  let navigationIsEnabled: Bool
  let pageIsInteractive: Bool
  let canBeginNavigation: @MainActor () -> Bool
  let page:
    @MainActor (
      _ index: Int,
      _ isCurrent: Bool,
      _ readiness: PageTurnReadiness
    ) -> AnyView
  let onCommit: @MainActor (Int) -> Void
  let onTransitioningChange: @MainActor (Bool) -> Void

  var body: some View {
    Group {
      if rendersSettledSnapshot {
        page(
          clampedSelectedIndex,
          true,
          PageTurnReadiness { _ in }
        )
        .allowsHitTesting(false)
      } else {
        PlatformPageTurnSurface(
          ownerID: ownerID,
          pageCount: max(1, pageCount),
          selectedIndex: clampedSelectedIndex,
          allowsTrailingPageCreation: allowsTrailingPageCreation,
          navigationIsEnabled: navigationIsEnabled,
          pageIsInteractive: pageIsInteractive,
          canBeginNavigation: canBeginNavigation,
          page: page,
          onCommit: onCommit,
          onTransitioningChange: onTransitioningChange
        )
      }
    }
    .accessibilityIdentifier("page-turn-surface")
    .accessibilityValue("Страница \(selectedIndex + 1) из \(max(1, pageCount))")
  }

  private var clampedSelectedIndex: Int {
    min(max(0, selectedIndex), max(0, pageCount - 1))
  }
}

enum PageTurnDecision {
  static let commitProgress: CGFloat = 0.34
  static let projectionDuration: CGFloat = 0.20

  static func commits(progress: CGFloat, velocity: CGFloat) -> Bool {
    progress + velocity * projectionDuration >= commitProgress
  }
}

#if os(iOS)
  private struct PlatformPageTurnSurface: UIViewControllerRepresentable {
    let ownerID: UUID
    let pageCount: Int
    let selectedIndex: Int
    let allowsTrailingPageCreation: Bool
    let navigationIsEnabled: Bool
    let pageIsInteractive: Bool
    let canBeginNavigation: @MainActor () -> Bool
    let page:
      @MainActor (
        Int,
        Bool,
        PageTurnReadiness
      ) -> AnyView
    let onCommit: @MainActor (Int) -> Void
    let onTransitioningChange: @MainActor (Bool) -> Void

    func makeUIViewController(context: Context) -> IPadPageTurnController {
      let controller = IPadPageTurnController()
      update(controller)
      return controller
    }

    func updateUIViewController(
      _ controller: IPadPageTurnController,
      context: Context
    ) {
      update(controller)
    }

    private func update(_ controller: IPadPageTurnController) {
      controller.update(
        ownerID: ownerID,
        pageCount: pageCount,
        selectedIndex: selectedIndex,
        allowsTrailingPageCreation: allowsTrailingPageCreation,
        navigationIsEnabled: navigationIsEnabled,
        pageIsInteractive: pageIsInteractive,
        canBeginNavigation: canBeginNavigation,
        page: page,
        onCommit: onCommit,
        onTransitioningChange: onTransitioningChange
      )
    }
  }
#elseif os(macOS)
  private struct PlatformPageTurnSurface: NSViewRepresentable {
    let ownerID: UUID
    let pageCount: Int
    let selectedIndex: Int
    let allowsTrailingPageCreation: Bool
    let navigationIsEnabled: Bool
    let pageIsInteractive: Bool
    let canBeginNavigation: @MainActor () -> Bool
    let page:
      @MainActor (
        Int,
        Bool,
        PageTurnReadiness
      ) -> AnyView
    let onCommit: @MainActor (Int) -> Void
    let onTransitioningChange: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> MacPageTurnView {
      let view = MacPageTurnView()
      update(view)
      return view
    }

    func updateNSView(_ view: MacPageTurnView, context: Context) {
      update(view)
    }

    private func update(_ view: MacPageTurnView) {
      view.update(
        ownerID: ownerID,
        pageCount: pageCount,
        selectedIndex: selectedIndex,
        allowsTrailingPageCreation: allowsTrailingPageCreation,
        navigationIsEnabled: navigationIsEnabled,
        pageIsInteractive: pageIsInteractive,
        canBeginNavigation: canBeginNavigation,
        page: page,
        onCommit: onCommit,
        onTransitioningChange: onTransitioningChange
      )
    }
  }
#endif

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

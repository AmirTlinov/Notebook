import NotebookCore
import SwiftUI

/// Input is attached to a physical owner, never to the current camera's owner.
enum InteractiveElementReference: Equatable, Sendable {
  case page(pageID: UUID, elementID: String)
  case board(boardID: UUID, elementID: String)
}

/// A surface consumes a prepared raster until the person activates its input.
/// The shared resource owner grants every WebKit instance before it is mounted.
struct PreparedAgentElementView: View {
  @Environment(NotebookAppModel.self) private var model
  @Environment(\.displayScale) private var displayScale
  let element: AgentElement
  let allowsInteraction: Bool
  let focus: InteractiveElementReference
  let onRenderReady: (Bool) -> Void
  let onState: (JSONValue) -> Void

  @State private var raster: RasterLease?
  @State private var web: WebSurfaceLease?
  @State private var preparedSource: AgentElement?
  @State private var failure: String?
  @State private var failedSource: AgentElement?
  @State private var waitingForAdmission = false
  @State private var retry: UInt64 = 0

  init(element: AgentElement, allowsInteraction: Bool, focus: InteractiveElementReference,
    onRenderReady: @escaping (Bool) -> Void, onState: @escaping (JSONValue) -> Void) {
    self.element = element
    self.allowsInteraction = allowsInteraction
    self.focus = focus
    self.onRenderReady = onRenderReady
    self.onState = onState
    // A prepared portal must have pixels in its first frame, before .task runs.
    let retained = SceneRenderResources.shared.retainRaster(for: element)
    _raster = State(initialValue: retained)
    _preparedSource = State(initialValue: retained == nil ? nil : element)
  }

  private var isActive: Bool {
    allowsInteraction && !element.javaScript.isEmpty && model.interactiveElementFocus == focus
  }

  private struct Demand: Equatable {
    let source: AgentElement
    let active: Bool
    let permitsPreparation: Bool
    let displayScale: Double
    let retry: UInt64
  }

  var body: some View {
    let demand = Demand(source: element, active: isActive,
      permitsPreparation: model.permitsBackgroundPreparation, displayScale: displayScale, retry: retry)
    ZStack {
      if let raster {
        AgentElementSnapshotView(raster: raster)
      }
      if let web {
        AgentWebElementView(element: element, lease: web,
          snapshotPolicy: .display(scale: displayScale),
          onRenderReady: { ready in
            guard self.web?.id == web.id, !web.isReleased else { return }
            if ready, let next = SceneRenderResources.shared.retainRaster(for: element) {
              raster = next
              preparedSource = element
              failure = nil
              failedSource = nil
              onRenderReady(true)
              // The representable retains the grant until WebKit is dismantled.
              if !isActive { self.web = nil }
            } else if !ready, preparedSource != element {
              onRenderReady(false)
            }
          }, onFailure: { diagnostic in
            guard self.web?.id == web.id, !web.isReleased else { return }
            switch diagnostic.kind {
            case "resource_limit": failure = "Недостаточно ресурсов для изображения"
            case "load_error": failure = "Не удалось загрузить схему"
            default: failure = "Не удалось подготовить изображение"
            }
            failedSource = element
            self.web = nil
            onRenderReady(false)
          }, onState: { value in
            guard isActive, self.web?.id == web.id, !web.isReleased else { return }
            onState(value)
          })
          .id(web.id)
          .opacity(isActive && preparedSource == element ? 1 : 0)
          .allowsHitTesting(isActive && preparedSource == element && !model.scenePreparationPending)
      }
      if allowsInteraction && !element.javaScript.isEmpty && !isActive {
        Button {
          failedSource = nil
          failure = nil
          model.interactiveElementFocus = focus
        } label: {
          Color.clear.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Открыть интерактивную схему")
        .accessibilityIdentifier("activate-agent-element-\(element.id)")
      }
      // An old raster can bridge preparation, but is never presented as current.
      if let failure {
        VStack(spacing: 4) {
          Text(failure).font(.caption)
          Button("Повторить") {
            failedSource = nil
            self.failure = nil
            retry &+= 1
          }.frame(minWidth: 44, minHeight: 44)
        }
        .padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
      } else if preparedSource != element {
        Text(raster == nil ? "Подготовка…" : "Обновление…")
          .font(.caption).foregroundStyle(.secondary)
          .padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
          .allowsHitTesting(false)
      }
    }
    .task(id: demand) { await prepare(demand) }
    .onChange(of: SceneRenderResources.shared.webAdmissionGeneration) { _, _ in
      guard waitingForAdmission else { return }
      waitingForAdmission = false
      retry &+= 1
    }
    .onDisappear {
      web = nil
      raster = nil
      preparedSource = nil
      waitingForAdmission = false
      onRenderReady(false)
    }
  }

  @MainActor
  private func prepare(_ demand: Demand) async {
    waitingForAdmission = false
    if failedSource == demand.source { return }
    failure = nil
    if preparedSource != demand.source {
      if !demand.active { web = nil }
      let current = SceneRenderResources.shared.retainRaster(for: demand.source)
      if let current { raster = current }
      preparedSource = current == nil ? nil : demand.source
    }
    onRenderReady(preparedSource == demand.source)
    if !demand.active && preparedSource == demand.source { web = nil; return }
    guard demand.active || demand.permitsPreparation else { return }
    if let web {
      web.updatePriority(demand.active ? .input : .visible)
      return
    }
    do {
      let acquired = try await SceneRenderResources.shared.acquireWebSurface(
        priority: demand.active ? .input : .visible)
      guard !Task.isCancelled else { acquired.release(); return }
      web = acquired
    } catch is CancellationError {
      return
    } catch {
      guard !Task.isCancelled else { return }
      failure = "Ожидает свободных ресурсов"
      waitingForAdmission = true
      onRenderReady(false)
    }
  }
}

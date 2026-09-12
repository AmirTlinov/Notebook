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
  @Environment(\.sceneComposition) private var composition
  let element: AgentElement
  let allowsInteraction: Bool
  let focus: InteractiveElementReference
  let onRenderReady: (Bool) -> Void
  let onState: (JSONValue) -> Void

  @State private var raster: RasterLease?
  @State private var web: WebSurfaceLease?
  @State private var preparedSource: AgentElement?
  @State private var liveProgram: AgentProgramSource?
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
  }

  private var isActive: Bool {
    allowsInteraction && !element.javaScript.isEmpty && model.interactiveElementFocus == focus
  }

  private var snapshotScale: Double {
    if case .board(let boardID, _) = focus,
      let projection = composition.cohort?.frame.pixelScales[boardID] {
      return projection * displayScale
    }
    return displayScale
  }

  private var requiredScale: Double {
    AgentSnapshotPolicy.display(scale: snapshotScale).rasterizationScale(for: element, displayScale: displayScale)
  }

  private func adoptPreparedRaster() {
    guard model.shutdownPhase != .stopped,
      let next = SceneRenderResources.shared.retainRaster(for: element, minimumScale: requiredScale) else { return }
    if raster?.entryID != next.entryID { raster = next }
    preparedSource = element; failure = nil; failedSource = nil
    onRenderReady(true)
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
      permitsPreparation: model.permitsBackgroundPreparation, displayScale: snapshotScale, retry: retry)
    ZStack {
      if let raster {
        AgentElementSnapshotView(raster: raster)
      }
      if let web {
        AgentWebElementView(element: element, lease: web,
          snapshotPolicy: .display(scale: snapshotScale),
          onRenderReady: { ready in
            guard model.shutdownPhase != .stopped, self.web?.id == web.id, !web.isReleased else { return }
            if ready, let next = SceneRenderResources.shared.retainRaster(for: element, minimumScale: requiredScale) {
              liveProgram = AgentProgramSource(element)
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
            guard model.shutdownPhase != .stopped, self.web?.id == web.id, !web.isReleased else { return }
            switch diagnostic.kind {
            case "resource_limit": failure = "Недостаточно ресурсов для изображения"
            case "load_error": failure = "Не удалось загрузить схему"
            default: failure = "Не удалось подготовить изображение"
            }
            failedSource = element
            liveProgram = nil
            self.web = nil
            onRenderReady(false)
          }, onState: { value in
            guard isActive, self.web?.id == web.id, !web.isReleased else { return }
            onState(value)
          })
          .id(web.id)
          .opacity(isActive && liveProgram == AgentProgramSource(element) ? 1 : 0)
          .allowsHitTesting(isActive && liveProgram == AgentProgramSource(element))
      }
      #if os(macOS)
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
      #endif
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
      } else if preparedSource != element && !(isActive && liveProgram == AgentProgramSource(element)) {
        Text(raster == nil ? "Подготовка…" : "Обновление…")
          .font(.caption).foregroundStyle(.secondary)
          .padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
          .allowsHitTesting(false)
      }
    }
    .onAppear {
      guard model.shutdownPhase != .stopped else { return }
      // Mounting, not constructing a cached SwiftUI value, acquires the lease.
      // This synchronous callback supplies cached pixels before the first frame;
      // asynchronous WebKit preparation remains the existing task's job.
      adoptPreparedRaster()
    }
    .onReceive(NotificationCenter.default.publisher(for: SceneRenderResources.didChange)) { note in
      if note.object as? String == element.id { adoptPreparedRaster() }
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
      liveProgram = nil
      waitingForAdmission = false
      onRenderReady(false)
    }
  }

  @MainActor
  private func prepare(_ demand: Demand) async {
    guard model.shutdownPhase != .stopped else { return }
    waitingForAdmission = false
    if failedSource == demand.source { return }
    failure = nil
    if preparedSource != demand.source || (raster?.pixelScale ?? 0) + 0.000_001 < requiredScale {
      if !demand.active { web = nil }
      let current = SceneRenderResources.shared.retainRaster(for: demand.source, minimumScale: requiredScale)
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
      guard !Task.isCancelled, model.shutdownPhase != .stopped else { acquired.release(); return }
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

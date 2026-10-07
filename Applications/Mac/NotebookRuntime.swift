import AppKit
import OSLog

/// The plugin owns this process. AppKit supplies the event loop required by
/// the document and XPC adapters; the working surface lives in Codex.
@main @MainActor
enum NotebookRuntime {
  static func main() {
    NotebookRuntimeIdentity.recordStartup("process.entry")
    #if DEBUG
      // XCTest supplies explicit isolated owners and never starts this model.
      // Release and signed acceptance processes always validate the full seal.
      let requiresAdmission = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
    #else
      let requiresAdmission = true
    #endif
    if requiresAdmission, case .failure(let failure) = NotebookRuntimeIdentity.admission {
      Logger(subsystem: "com.amirtlinov.notebook", category: "Runtime")
        .error("Runtime admission refused: \(failure.localizedDescription, privacy: .public)")
      exit(EXIT_FAILURE)
    }
    let application = NSApplication.shared
    let lifecycle = NotebookRuntimeLifecycle()
    application.delegate = lifecycle
    application.setActivationPolicy(.accessory)
    withExtendedLifetime(lifecycle) { application.run() }
  }
}

@MainActor
final class NotebookRuntimeLifecycle: NSObject, NSApplicationDelegate {
  let launch: NotebookApplicationLaunch
  private var launchTask: Task<Void, Never>?
  private var terminationTask: Task<Void, Never>?
  private var terminationSignals: [DispatchSourceSignal] = []
  private let isRunningTests: Bool

  init(launch: NotebookApplicationLaunch? = nil) {
    isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    self.launch = launch ?? NotebookAcceptanceConfiguration.requestedLaunch()
      ?? (isRunningTests ? NotebookApplicationLaunch(fixture: nil) : NotebookApplicationLaunch())
    super.init()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    guard !isRunningTests else { return }
    NotebookRuntimeIdentity.recordStartup("launch.delegate")
    // OS termination joins the same saved boundary as a requested quit.
    // Closing an MCP connection or a panel never invokes this path.
    for number in [SIGTERM, SIGINT] {
      signal(number, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
      source.setEventHandler { Self.requestTermination() }
      source.resume()
      terminationSignals.append(source)
    }
    start()
  }

  func start() {
    guard launchTask == nil else { return }
    launchTask = Task {
      defer { launchTask = nil }
      await launch.waitForAdmission()
      guard !Task.isCancelled else { return }
      if launch.existingRuntimeSocketURL != nil {
        // Another launch won the lease. It already serves the plugin and no
        // store was opened in this process.
        Self.requestTermination()
        return
      }
      await launch.model?.start(pageSize: NotebookAppModel.defaultPageSize)
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  private nonisolated static func requestTermination() {
    // AppKit nests a run loop while waiting for terminateLater. Entering that
    // loop from a MainActor job would prevent the saving task from running.
    RunLoop.main.perform(inModes: [.common]) {
      MainActor.assumeIsolated { NSApplication.shared.terminate(nil) }
    }
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard terminationTask == nil else { return .terminateLater }
    terminationTask = Task {
      launchTask?.cancel()
      await launchTask?.value
      let saved = await launch.shutdown()
      if !saved {
        Logger(subsystem: "com.amirtlinov.notebook", category: "Runtime")
          .error("Runtime retained unsaved work while termination was requested.")
      }
      sender.reply(toApplicationShouldTerminate: saved)
      terminationTask = nil
    }
    return .terminateLater
  }
}

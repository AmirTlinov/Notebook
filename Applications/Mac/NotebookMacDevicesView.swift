import SwiftUI

@MainActor
final class NotebookMacDevicesWindowController: NSWindowController {
  init(launch: NotebookApplicationLaunch, retry: @escaping () -> Void) {
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 520, height: 380),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    window.title = "Notebook — Устройства"
    window.identifier = .init("notebook.devices.window")
    window.setAccessibilityIdentifier("notebook.devices.window")
    window.minSize = .init(width: 440, height: 300)
    window.isReleasedWhenClosed = false
    window.collectionBehavior = [.moveToActiveSpace]
    window.contentViewController = NSHostingController(rootView: NotebookMacDevicesView(launch: launch, retry: retry))
    window.center()
    super.init(window: window)
  }
  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("Programmatic devices window") }
  func showDevices() {
    showWindow(nil); window?.makeKeyAndOrderFront(nil); NSApplication.shared.activate()
  }
}

private struct NotebookMacDevicesView: View {
  let launch: NotebookApplicationLaunch
  let retry: () -> Void
  var body: some View {
    if let model = launch.model {
      Form { NotebookDevicesContent(model: model) }.formStyle(.grouped)
    } else {
      VStack(spacing: 16) {
        Text(launch.message)
        if launch.failure != nil { Button("Повторить", action: retry) }
      }.padding(24)
    }
  }
}
